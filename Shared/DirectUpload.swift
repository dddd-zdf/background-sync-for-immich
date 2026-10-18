import Foundation
import Photos
import UniformTypeIdentifiers

/// EXPERIMENT (Advanced > "Test upload without the server container"): uploads straight to Immich's
/// `POST /api/assets`, no companion container. PhotoKit's upload jobs can only send a resource's raw
/// bytes, so here the extension writes the multipart body to a file in the app group itself and hands
/// it to a background URLSession, which iOS keeps running after the extension (and app) are gone.
/// Open questions this answers: does iOS allow it from the upload extension, does it finish with the
/// app swiped away, and who gets the result (the extension, or the app relaunched in the background).
/// Results go to the shared log only; upload state is not touched.
enum DirectUpload {
    /// Only one process may hold a background session at a time (else NSURLErrorDomain -996), and the
    /// app keeps the one iOS woke it for. So each extension instance gets its own session; the app
    /// connects to it only to collect results, then lets go.
    static let sessionPrefix = "direct-upload."

    static func newSessionID() -> String { sessionPrefix + UUID().uuidString }

    static func session(id: String, delegate: Delegate) -> URLSession {
        let config = URLSessionConfiguration.background(withIdentifier: id)
        config.sharedContainerIdentifier = AppGroup.identifier
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    /// Queues the newest photo and the newest video. Immich answering "duplicate" is still a full
    /// success: it only knows after receiving every byte (checksum).
    static func startTest(session: URLSession) async {
        guard let base = URL(string: Settings.serverURL), !Settings.apiKey.isEmpty else {
            SharedLog.write("direct", "no server URL or API key")
            return
        }
        for type in [PHAssetMediaType.image, .video] {
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "mediaType == %d", type.rawValue)
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.fetchLimit = 1
            guard let asset = PHAsset.fetchAssets(with: options).firstObject else { continue }
            let started = Date()
            do {
                let (file, boundary, name) = try await writeBody(for: asset)
                var request = URLRequest(url: base.appendingPathComponent("api/assets"))
                request.httpMethod = "POST"
                request.setValue(Settings.apiKey, forHTTPHeaderField: "x-api-key")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                request.allowsCellularAccess = !Settings.wifiOnly
                let task = session.uploadTask(with: request, fromFile: file)
                task.taskDescription = "\(name)|\(file.lastPathComponent)"
                task.resume()
                let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
                SharedLog.write("direct", "queued \(name), \(size / 1024) KB, body written in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            } catch {
                SharedLog.write("direct", "could not prepare \(asset.localIdentifier): \(error.localizedDescription)")
            }
        }
    }

    /// The same multipart form the companion container builds (see proxy/main.go `uploadFields`).
    private static func writeBody(for asset: PHAsset) async throws -> (URL, String, String) {
        guard let container = AppGroup.container else { throw failure("no app group container") }
        let resources = PHAssetResource.assetResources(for: asset)
        let types: [PHAssetResourceType] = asset.mediaType == .video ? [.fullSizeVideo, .video] : [.fullSizePhoto, .photo]
        guard let resource = types.lazy.compactMap({ type in resources.first { $0.type == type } }).first
        else { throw failure("no photo or video file") }
        let resourceName = resource.filename ?? "upload"
        let original = resources.first { $0.type == .photo || $0.type == .video }?.filename ?? resourceName
        let name = ((original as NSString).deletingPathExtension as NSString)
            .appendingPathExtension((resourceName as NSString).pathExtension) ?? resourceName

        let dir = container.appendingPathComponent("direct", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(UUID().uuidString + ".multipart")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }

        let boundary = "BackgroundSync-\(UUID().uuidString)"
        let iso = ISO8601DateFormatter()
        let created = asset.creationDate ?? Date()
        var fields = [("fileCreatedAt", iso.string(from: created)),
                      ("fileModifiedAt", iso.string(from: asset.modificationDate ?? created)),
                      ("isFavorite", asset.isFavorite ? "true" : "false"),
                      ("filename", name)]
        if asset.mediaType == .video { fields.append(("duration", String(Int(asset.duration * 1000)))) }
        var head = ""
        for (key, value) in fields {
            head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n"
        }
        let mime = UTType(resource.uniformTypeIdentifier)?.preferredMIMEType ?? "application/octet-stream"
        let quoted = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"assetData\"; filename=\"\(quoted)\"\r\nContent-Type: \(mime)\r\n\r\n"
        try handle.write(contentsOf: Data(head.utf8))

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let writer = Writer(handle)
        let ok = await withCheckedContinuation { continuation in
            _ = PHAssetResourceManager.default().requestData(for: resource, options: options,
                dataReceivedHandler: { writer.write($0) },
                completionHandler: { continuation.resume(returning: $0 == nil) })
        }
        guard ok, writer.error == nil else {
            try? FileManager.default.removeItem(at: file)
            throw failure("reading \(name) from Photos failed")
        }
        try handle.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        return (file, boundary, name)
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

    /// Logs each finished upload. Used by whichever process iOS hands the results to.
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
            let parts = (task.taskDescription ?? "?|").split(separator: "|", maxSplits: 1).map(String.init)
            let code = (task.response as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            let result = error.map { "error \(($0 as NSError).domain) \(($0 as NSError).code)" }
                ?? "HTTP \(code) \(json["status"] ?? json["message"] ?? "") \(json["id"] ?? "")"
            SharedLog.write("direct", "done in \(process): \(parts.first ?? "?") \(result), sent \(task.countOfBytesSent / 1024) KB")
            if parts.count > 1, let dir = AppGroup.container?.appendingPathComponent("direct") {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(parts[1]))
            }
        }

        func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
            SharedLog.write("direct", "all events delivered to \(process)")
            DispatchQueue.main.async { self.finishedEvents?(); self.finishedEvents = nil }
        }
    }
}
