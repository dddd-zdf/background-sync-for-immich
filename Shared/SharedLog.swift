import Foundation
import OSLog

/// Plain-text log in the app group, readable from the app (there is no Mac to read Console logs).
/// With Settings.sendDebugLog on, new lines are also sent to the server's debug log (`flush`).
enum SharedLog {
    private static let maxBytes = 512 * 1024
    private static let logger = Logger(subsystem: "com.difei.immichbackup", category: "log")
    private static let lock = NSLock()

    static var fileURL: URL? { AppGroup.container?.appendingPathComponent("log.txt") }
    /// Lines not yet sent to the server, and a batch being sent (kept if the send fails).
    private static var pendingURL: URL? { AppGroup.container?.appendingPathComponent("log-pending.txt") }
    private static var sendingURL: URL? { AppGroup.container?.appendingPathComponent("log-sending.txt") }

    static func write(_ source: String, _ message: String) {
        logger.notice("[\(source, privacy: .public)] \(message, privacy: .public)")
        guard let url = fileURL else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(source)] \(message)\n"
        lock.lock(); defer { lock.unlock() }
        if Settings.sendDebugLog, let pending = pendingURL { append(line, to: pending) }
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

    private static func append(_ line: String, to url: URL) {
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// Sends the lines written since the last send to the server's debug log (the companion
    /// container prints them; see proxy/main.go `logHandler`). Called at the end of each extension
    /// run and app sync. On failure the lines wait for the next call (newest 256 KB kept).
    static func flush() async {
        guard Settings.sendDebugLog, let pending = pendingURL, let sending = sendingURL,
              let url = Settings.uploadURL, !Settings.apiKey.isEmpty else { return }
        lock.withLock {
            if FileManager.default.fileExists(atPath: pending.path) {
                let old = (try? Data(contentsOf: sending)) ?? Data()
                let new = (try? Data(contentsOf: pending)) ?? Data()
                try? Data((old + new).suffix(256 * 1024)).write(to: sending)
                try? FileManager.default.removeItem(at: pending)
            }
        }
        guard let body = try? Data(contentsOf: sending), !body.isEmpty else { return }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue(Settings.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("1", forHTTPHeaderField: "X-Debug-Log")
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        if case let (_, response)? = try? await URLSession.shared.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 204 {
            try? FileManager.default.removeItem(at: sending)
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
