import Foundation

/// Development logging, enabled by creating /tmp/notchdeck.debug.
enum Debug {
    static let enabled = FileManager.default.fileExists(atPath: "/tmp/notchdeck.debug")
    private static let url = URL(fileURLWithPath: "/tmp/notchdeck.log")

    static func log(_ message: String) {
        guard enabled else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let stamp = formatter.string(from: Date())
        let line = "\(stamp) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
