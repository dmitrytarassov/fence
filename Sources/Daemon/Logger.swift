import Foundation

/// Append-only file logger with a simple size rotation.
final class Logger {
    private let path: String
    private let queue = DispatchQueue(label: "fence.log")
    private let formatter: DateFormatter
    private let echoToStdout: Bool
    private let maxBytes: UInt64 = 5 * 1024 * 1024

    init(path: String) {
        self.path = path
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        echoToStdout = isatty(1) != 0
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    func info(_ message: String) { write("INFO", message) }
    func warn(_ message: String) { write("WARN", message) }
    func error(_ message: String) { write("ERROR", message) }

    /// Wait until every queued line is on disk.
    func flush() { queue.sync {} }

    private func write(_ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        queue.async {
            self.rotateIfNeeded()
            if let handle = FileHandle(forWritingAtPath: self.path) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                handle.closeFile()
            } else {
                FileManager.default.createFile(atPath: self.path, contents: Data(line.utf8), attributes: [.posixPermissions: 0o644])
            }
            if self.echoToStdout {
                FileHandle.standardOutput.write(Data(line.utf8))
            }
        }
    }

    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64, size > maxBytes else { return }
        let rotated = path + ".1"
        try? FileManager.default.removeItem(atPath: rotated)
        try? FileManager.default.moveItem(atPath: path, toPath: rotated)
    }
}
