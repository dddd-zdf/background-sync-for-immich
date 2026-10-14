import Foundation
import OSLog

/// Plain-text log in the app group, readable from the app (there is no Mac to read Console logs).
enum SharedLog {
    private static let maxBytes = 512 * 1024
    private static let logger = Logger(subsystem: "com.difei.immichbackup", category: "log")
    private static let lock = NSLock()

    static var fileURL: URL? { AppGroup.container?.appendingPathComponent("log.txt") }

    static func write(_ source: String, _ message: String) {
        logger.notice("[\(source, privacy: .public)] \(message, privacy: .public)")
        guard let url = fileURL else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(source)] \(message)\n"
        lock.lock(); defer { lock.unlock() }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            if let size = try? handle.seekToEnd(), size > maxBytes {
                trim(url)
                _ = try? handle.seekToEnd()
            }
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    static func read() -> String {
        guard let url = fileURL, let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "(no log yet; app group: \(AppGroup.identifier), container: \(AppGroup.container?.path ?? "missing"))"
        }
        return text
    }

    static func clear() {
        guard let url = fileURL else { return }
        try? Data().write(to: url)
    }

    /// Keeps the newest half of the file.
    private static func trim(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        try? data.suffix(maxBytes / 2).write(to: url)
    }
}
