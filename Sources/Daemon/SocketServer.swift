import Foundation

/// Unix socket server. One text command per connection, one JSON reply.
///
/// The socket file is world writable so the menu bar app can connect. The server then checks
/// the uid of every peer with getpeereid() and rejects every uid that `authorize` does not accept.
final class SocketServer {
    private let path: String
    private let log: Logger
    private let authorize: (uid_t) -> Bool
    private let handler: (FenceCommand) -> DaemonState
    private var fd: Int32 = -1
    /// Clients served at the same time. More clients get the connection closed at once.
    private let slots = DispatchSemaphore(value: 8)

    init(path: String, log: Logger, authorize: @escaping (uid_t) -> Bool,
         handler: @escaping (FenceCommand) -> DaemonState) {
        self.path = path
        self.log = log
        self.authorize = authorize
        self.handler = handler
    }

    func start() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        unlink(path)

        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketClientError(message: "socket(): \(UnixSocket.errnoText())") }
        guard var addr = UnixSocket.address(path) else { throw SocketClientError(message: "socket path is too long") }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, UnixSocket.addressLength)
            }
        }
        guard rc == 0 else { throw SocketClientError(message: "bind(\(path)): \(UnixSocket.errnoText())") }
        chmod(path, 0o666)
        guard listen(fd, 32) == 0 else { throw SocketClientError(message: "listen(): \(UnixSocket.errnoText())") }

        let thread = Thread { [self] in self.acceptLoop() }
        thread.name = "fence.socket"
        thread.start()
        log.info("socket: listening on \(path)")
    }

    private func acceptLoop() {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                log.error("socket: accept failed: \(UnixSocket.errnoText())")
                sleep(1)
                continue
            }
            // One slow client must not hold the others. Each client gets its own thread.
            if slots.wait(timeout: .now()) == .timedOut {
                close(client)
                continue
            }
            DispatchQueue.global().async { [self] in
                defer { slots.signal() }
                handle(client)
            }
        }
    }

    private func handle(_ client: Int32) {
        defer { close(client) }
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        let tvLen = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, tvLen)
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &tv, tvLen)

        var uid = uid_t.max
        var gid = gid_t(0)
        guard getpeereid(client, &uid, &gid) == 0 else {
            log.warn("socket: getpeereid failed: \(UnixSocket.errnoText())")
            return
        }
        guard authorize(uid) else {
            log.warn("socket: denied uid \(uid)")
            var denied = DaemonState()
            denied.lastError = "access denied for uid \(uid)"
            reply(client, denied)
            return
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 256)
        while data.count < 256 {
            let n = read(client, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
            if buffer[n - 1] == 0x0A { break }
        }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let command = FenceCommand(line: text) else {
            log.warn("socket: unknown command '\(Self.printable(text))' from uid \(uid)")
            return
        }
        reply(client, handler(command))
    }

    private func reply(_ client: Int32, _ state: DaemonState) {
        guard var data = try? JSONCoding.encoder.encode(state) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = write(client, base + offset, raw.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }

    /// Printable ASCII only, so a client cannot write fake lines into the log.
    private static func printable(_ text: String) -> String {
        String(text.prefix(64).filter { ($0.asciiValue ?? 0) >= 32 && ($0.asciiValue ?? 0) < 127 })
    }
}
