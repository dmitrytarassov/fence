import Foundation

struct ShellResult {
    let status: Int32
    let stdout: String
    let stderr: String
    var ok: Bool { status == 0 }
}

/// Run a child process with posix_spawn and reap it with waitpid.
///
/// Foundation's Process is not used on purpose. Its waitUntilExit can wait forever when the
/// exit notification is lost. This happened in production and froze the daemon.
enum Shell {
    /// Run a program and wait for it. Send SIGTERM after `timeout` seconds, SIGKILL 2 seconds later.
    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 20) -> ShellResult {
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            return ShellResult(status: -1, stdout: "", stderr: "pipe(): \(String(cString: strerror(errno)))")
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        // The child gets only fds 0, 1 and 2. No other pipe or socket leaks into it.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        // A fixed environment. Nothing from the daemon's environment reaches the child.
        let envp: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/bin:/bin:/usr/sbin:/sbin"), nil]
        defer { envp.forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attr, argv, envp)
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attr)
        close(outPipe[1])
        close(errPipe[1])

        guard rc == 0 else {
            close(outPipe[0])
            close(errPipe[0])
            return ShellResult(status: -1, stdout: "", stderr: "\(path): \(String(cString: strerror(rc)))")
        }

        let (outData, errData) = readBoth(outPipe[0], errPipe[0], pid: pid, timeout: timeout)
        let status = reap(pid)
        return ShellResult(
            status: status,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    /// Read both pipes until EOF. Kill the child when `timeout` passes.
    /// Stop reading 4 seconds after the timeout even without EOF: a grandchild may hold the pipe.
    private static func readBoth(_ outFD: Int32, _ errFD: Int32, pid: pid_t, timeout: TimeInterval) -> (Data, Data) {
        var out = Data()
        var err = Data()
        var open: [Int32: Bool] = [outFD: true, errFD: true]
        var buffer = [UInt8](repeating: 0, count: 16384)
        let start = Date()
        var sentTerm = false
        var sentKill = false

        while open[outFD] == true || open[errFD] == true {
            let elapsed = Date().timeIntervalSince(start)
            if elapsed >= timeout + 4 { break }
            if elapsed >= timeout + 2, !sentKill {
                kill(pid, SIGKILL)
                sentKill = true
            } else if elapsed >= timeout, !sentTerm {
                kill(pid, SIGTERM)
                sentTerm = true
            }

            var fds = [outFD, errFD].filter { open[$0] == true }.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            let waitMs = Int32(max(50, min(500, (timeout + 4 - elapsed) * 1000)))
            let n = poll(&fds, nfds_t(fds.count), waitMs)
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            for entry in fds where entry.revents != 0 {
                let got = read(entry.fd, &buffer, buffer.count)
                if got > 0 {
                    if entry.fd == outFD { out.append(buffer, count: got) } else { err.append(buffer, count: got) }
                } else {
                    open[entry.fd] = false
                }
            }
        }
        close(outFD)
        close(errFD)
        return (out, err)
    }

    /// Wait for the child to exit. Poll with WNOHANG so a lost notification cannot block the caller.
    private static func reap(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(5)
        var killed = false
        while true {
            let rc = waitpid(pid, &status, WNOHANG)
            if rc == pid { break }
            if rc < 0 && errno != EINTR { return -1 }
            if Date() >= deadline {
                if killed { return -1 }
                kill(pid, SIGKILL)
                killed = true
            }
            usleep(20_000)
        }
        let low = status & 0x7f
        if low == 0 { return (status >> 8) & 0xff }
        return 128 + low
    }
}
