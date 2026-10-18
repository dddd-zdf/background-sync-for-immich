import Foundation
import Photos

/// Experimental upload path without the companion container (Settings.directUpload).
///
/// PhotoKit's upload jobs can only send a resource's raw bytes, which Immich doesn't accept, so here
/// the extension writes Immich's multipart body to a file in the app group itself and hands it to a
/// background URLSession: iOS finishes the transfer after the extension (and app) are gone, and wakes
/// whichever of them holds the session to report back. That process saves the result to a file; the
/// extension's next run turns it into upload state (`UploadExtension.applyDirectResults`).
///
/// Files in `<app group>/direct/`, per upload ID: `<id>.json` (the request headers built by
/// `UploadExtension.destination`), `<id>.multipart` (the body, deleted once sent), `<id>.result.json`.
enum DirectUpload {
    /// Only one process may hold a background session at a time (else NSURLErrorDomain -996), and the
    /// app keeps the one iOS woke it for. So each extension instance gets its own session; the app
    /// connects to it only to collect results, then lets go.
    static let sessionPrefix = "direct-upload."
    /// `UploadState.inflight` key prefix for direct uploads (PhotoKit jobs use their own IDs).
    static let keyPrefix = "direct:"

    static func newSessionID() -> String { sessionPrefix + UUID().uuidString }

    static func session(id: String, delegate: Delegate) -> URLSession {
        let config = URLSessionConfiguration.background(withIdentifier: id)
        config.sharedContainerIdentifier = AppGroup.identifier
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    private static var directory: URL? { AppGroup.container?.appendingPathComponent("direct", isDirectory: true) }

    fileprivate static func file(_ id: String, _ suffix: String) -> URL? { directory?.appendingPathComponent(id + suffix) }

    private static func id(of key: String) -> String { String(key.dropFirst(keyPrefix.count)) }

    // MARK: - Sending

    /// Writes the body for `request` (headers as for the container, see proxy/main.go `uploadFields`)
    /// and starts the transfer to `POST /api/assets`. Returns the `inflight` key.
    static func queue(_ request: URLRequest, resource: PHAssetResource, session: URLSession) async throws -> String {
        guard let base = URL(string: Settings.serverURL), let directory else { throw failure("no server URL or app group") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        guard let manifest = file(id, ".json"), let body = file(id, ".multipart") else { throw failure("no app group") }
        let headers = request.allHTTPHeaderFields ?? [:]
        try JSONSerialization.data(withJSONObject: ["headers": headers, "date": Date().timeIntervalSince1970])
            .write(to: manifest, options: .atomic)
        let boundary: String
        do {
            boundary = try await writeBody(to: body, request: request, resource: resource)
        } catch {
            forget(keyPrefix + id)
            throw error
        }
        var upload = URLRequest(url: base.appendingPathComponent("api/assets"))
        upload.httpMethod = "POST"
        upload.setValue(Settings.apiKey, forHTTPHeaderField: "x-api-key")
        upload.setValue("application/json", forHTTPHeaderField: "Accept")
        upload.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        upload.allowsCellularAccess = request.allowsCellularAccess
        upload.allowsExpensiveNetworkAccess = request.allowsExpensiveNetworkAccess
        let task = session.uploadTask(with: upload, fromFile: body)
        task.taskDescription = id
        task.resume()
        return keyPrefix + id
    }

    private static func writeBody(to file: URL, request: URLRequest, resource: PHAssetResource) async throws -> String {
        func header(_ name: String) -> String? { request.value(forHTTPHeaderField: name).flatMap { $0.isEmpty ? nil : $0 } }
        let now = ISO8601DateFormatter().string(from: Date())
        let created = header("X-File-Created-At") ?? now
        let filename = header("X-Filename")?.removingPercentEncoding ?? "upload"
        var fields = [("fileCreatedAt", created),
                      ("fileModifiedAt", header("X-File-Modified-At") ?? created),
                      ("isFavorite", header("X-Is-Favorite") ?? "false")]
        if let duration = header("X-Duration-Ms") { fields.append(("duration", duration)) }
        if let video = header("X-Live-Photo-Video-Id") { fields.append(("livePhotoVideoId", video)) }
        fields.append(("filename", filename))

        let boundary = "BackgroundSync-\(UUID().uuidString)"
        var head = ""
        for (key, value) in fields {
            head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n"
        }
        let quoted = filename.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"assetData\"; filename=\"\(quoted)\"\r\n"
        head += "Content-Type: \(header("X-Content-Type") ?? "application/octet-stream")\r\n\r\n"

        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data(head.utf8))
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true  // photos kept only in iCloud
        let writer = Writer(handle)
        let ok = await withCheckedContinuation { continuation in
            _ = PHAssetResourceManager.default().requestData(for: resource, options: options,
                dataReceivedHandler: { writer.write($0) },
                completionHandler: { continuation.resume(returning: $0 == nil) })
        }
        guard ok, writer.error == nil else { throw failure("reading \(filename) from Photos failed") }
        try handle.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        return boundary
    }

    private static func failure(_ text: String) -> NSError {
        NSError(domain: "DirectUpload", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }

    private final class Writer: @unchecked Sendable {
        private let handle: FileHandle
        private let lock = NSLock()
        private(set) var error: Error?
        init(_ handle: FileHandle) { self.handle = handle }
        func write(_ data: Data) {
            lock.withLock {
                guard error == nil else { return }
                do { try handle.write(contentsOf: data) } catch { self.error = error }
            }
        }
    }

    // MARK: - Results

    struct Result {
        let key: String
        let request: URLRequest
        /// Immich's HTTP status, 0 if the transfer failed.
        let status: Int
        let immichID: String?
        /// "created" or "duplicate".
        let immichResult: String?
        let message: String?
        /// Transfer error, e.g. "NSURLErrorDomain -1001".
        let error: String?
    }

    /// The request headers saved when the upload was queued.
    static func request(for key: String) -> URLRequest? {
        guard let manifest = file(id(of: key), ".json"), let data = try? Data(contentsOf: manifest),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let headers = json["headers"] as? [String: String] else { return nil }
        var request = URLRequest(url: URL(fileURLWithPath: "/"))
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    static func hasResults() -> Bool {
        guard let directory, let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return false }
        return names.contains { $0.hasSuffix(".result.json") }
    }

    /// Finished uploads not yet recorded; their files are removed.
    static func takeResults() -> [Result] {
        guard let directory, let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var results: [Result] = []
        for name in names where name.hasSuffix(".result.json") {
            let key = keyPrefix + String(name.dropLast(".result.json".count))
            defer { forget(key) }
            guard let request = request(for: key),
                  let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let body = (json["body"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
            let response = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            results.append(Result(key: key, request: request, status: json["status"] as? Int ?? 0,
                                  immichID: response["id"] as? String, immichResult: response["status"] as? String,
                                  message: response["message"].map { "\($0)" }, error: json["error"] as? String))
        }
        return results
    }

    /// No result a day after queuing (or its files are gone): the transfer was lost.
    static func isLost(_ key: String) -> Bool {
        let id = id(of: key)
        guard let manifest = file(id, ".json"), let data = try? Data(contentsOf: manifest),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let date = json["date"] as? Double else { return true }
        if let result = file(id, ".result.json"), FileManager.default.fileExists(atPath: result.path) { return false }
        return Date().timeIntervalSince1970 - date > 86400
    }

    static func forget(_ key: String) {
        let id = id(of: key)
        for suffix in [".json", ".multipart", ".result.json"] {
            if let url = file(id, suffix) { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Saves each finished transfer's result for the extension. Used by whichever process iOS
    /// delivers the session's events to.
    final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let process: String
        private let lock = NSLock()
        private var bodies: [Int: Data] = [:]
        /// Set by the app when iOS launched it in the background for these events.
        var finishedEvents: (() -> Void)?

        init(process: String) { self.process = process }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.withLock { bodies[dataTask.taskIdentifier, default: Data()].append(data) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let body = lock.withLock { bodies.removeValue(forKey: task.taskIdentifier) } ?? Data()
            guard let id = task.taskDescription else { return }
            // -997: this process lost the session to the other one (the app woken for its events),
            // which reports the real result. Seen for the extension's old session on its next run.
            if (error as NSError?)?.domain == NSURLErrorDomain && (error as NSError?)?.code == -997 { return }
            let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
            var result: [String: Any] = ["status": status, "body": body.base64EncodedString()]
            if let error { result["error"] = "\((error as NSError).domain) \((error as NSError).code)" }
            if let url = DirectUpload.file(id, ".result.json"),
               let data = try? JSONSerialization.data(withJSONObject: result) {
                try? data.write(to: url, options: .atomic)
            }
            if let body = DirectUpload.file(id, ".multipart") { try? FileManager.default.removeItem(at: body) }
            let name = DirectUpload.request(for: DirectUpload.keyPrefix + id)?
                .value(forHTTPHeaderField: "X-Filename")?.removingPercentEncoding ?? id
            let errorText = result["error"].map { ", \($0)" } ?? ""
            SharedLog.write("direct", "sent \(name) in \(process): HTTP \(status), \(task.countOfBytesSent / 1024) KB\(errorText)")
        }

        func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
            DispatchQueue.main.async { self.finishedEvents?(); self.finishedEvents = nil }
        }
    }
}
