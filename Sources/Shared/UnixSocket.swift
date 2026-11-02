import Foundation

enum UnixSocket {
    static var addressLength: socklen_t { socklen_t(MemoryLayout<sockaddr_un>.size) }

    /// Build a sockaddr_un for `path`. Return nil when the path does not fit.
    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    static func errnoText() -> String {
        String(cString: strerror(errno))
    }
}

struct SocketClientError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// Client side of the daemon socket. One command per connection.
enum SocketClient {
    static func send(_ command: FenceCommand, timeoutSeconds: Int = 4) throws -> DaemonState {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketClientError(message: "socket(): \(UnixSocket.errnoText())") }
        defer { close(fd) }

        var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        let tvLen = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, tvLen)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, tvLen)

        guard var addr = UnixSocket.address(FencePaths.socketPath) else {
            throw SocketClientError(message: "socket path is too long")
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, UnixSocket.addressLength)
            }
        }
        guard rc == 0 else {
            throw SocketClientError(message: "connect(\(FencePaths.socketPath)): \(UnixSocket.errnoText())")
        }

        let payload = Array((command.line + "\n").utf8)
        guard write(fd, payload, payload.count) == payload.count else {
            throw SocketClientError(message: "write(): \(UnixSocket.errnoText())")
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 { throw SocketClientError(message: "read(): \(UnixSocket.errnoText())") }
            if n == 0 { break }
            data.append(buffer, count: n)
            if buffer[n - 1] == 0x0A { break }
        }
        do {
            return try JSONCoding.decoder.decode(DaemonState.self, from: data)
        } catch {
            throw SocketClientError(message: "bad reply from daemon: \(error.localizedDescription)")
        }
    }
}
