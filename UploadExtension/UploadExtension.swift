import ExtensionFoundation
import Foundation
import Photos
import UniformTypeIdentifiers

/// PhotoKit background upload extension (iOS 27). iOS launches this on its own schedule,
/// whether or not the app is running, and performs the uploads we queue as jobs.
@main
final class UploadExtension: PHBackgroundResourceUploadJobExtension {
    private let cancelled = Flag()

    required init() {
        SharedLog.write("ext", "init, app group \(AppGroup.identifier), container \(AppGroup.container != nil ? "ok" : "MISSING")")
    }

    func processJobs() async -> PHBackgroundResourceUploadProcessingResult {
        Settings.lastInvocation = Date()
        Settings.invocationCount += 1
        var state = UploadState.load()
        defer { state.save() }
        do {
            try acknowledgeFinishedJobs(&state)
            guard !cancelled.value else { return .processing }
            let created = try createJobs(&state)
            let active = !state.inflight.isEmpty
            SharedLog.write("ext", "processJobs done: created \(created), inflight \(state.inflight.count)")
            return created > 0 || active ? .processing : .completed
        } catch let error as NSError where error.domain == PHPhotosErrorDomain && error.code == PHPhotosError.limitExceeded.rawValue {
            SharedLog.write("ext", "job limit reached")
            return .processing
        } catch {
            SharedLog.write("ext", "processJobs error: \(error)")
            return .failure
        }
    }

    func willTerminate() async {
        cancelled.value = true
        SharedLog.write("ext", "willTerminate")
    }

    // MARK: - Finished jobs

    /// Records each finished job's result, then acknowledges it to free a job slot.
    /// Failed jobs are not retried in place; the asset is simply picked up again
    /// by `createJobs` until it has failed `maxAttempts` times.
    private func acknowledgeFinishedJobs(_ state: inout UploadState) throws {
        let jobs = PHAssetResourceUploadJob.fetchJobs(action: .acknowledge, options: nil)
        for i in 0..<jobs.count {
            let job = jobs.object(at: i)
            let assetID = job.destination.value(forHTTPHeaderField: Header.assetID) ?? state.inflight[job.localIdentifier] ?? "?"
            let headers = job.responseHeaderFields ?? [:]
            let immichID = headers["x-immich-asset-id"] ?? ""
            let status = headers["x-immich-status"] ?? "-"

            if !immichID.isEmpty {
                state.uploaded[assetID] = immichID
                state.failures[assetID] = nil
                state.note("ok \(status) \(job.destination.value(forHTTPHeaderField: Header.filename) ?? "") -> \(immichID)")
            } else {
                let error = job.error.map { "\(($0 as NSError).domain) \(($0 as NSError).code)" } ?? "no error"
                state.failures[assetID, default: 0] += 1
                state.note("fail state=\(job.state.rawValue) http=\(status) \(error) \(headers["x-immich-error"] ?? "")")
            }
            SharedLog.write("ext", "job \(job.localIdentifier) state \(job.state.rawValue) immich \(status) \(immichID)")

            try PHPhotoLibrary.shared().performChangesAndWait {
                PHAssetResourceUploadJobChangeRequest(for: job)?.acknowledge()
            }
            state.inflight[job.localIdentifier] = nil
        }
    }

    // MARK: - New jobs

    private static let maxAttempts = 3

    private func createJobs(_ state: inout UploadState) throws -> Int {
        guard let url = Settings.uploadURL, !Settings.apiKey.isEmpty else {
            SharedLog.write("ext", "no server URL or API key; nothing to do")
            return 0
        }
        var assets: [PHAsset] = []
        if Settings.testUploadRequested {
            Settings.testUploadRequested = false
            assets += newestAssets(limit: 1, after: nil, mediaType: .image)
            SharedLog.write("ext", "test upload requested, found \(assets.count) photo")
        }
        if let since = Settings.autoSince {
            let busy = Set(state.inflight.values)
            assets += newestAssets(limit: 200, after: since, mediaType: nil).filter {
                state.uploaded[$0.localIdentifier] == nil && !busy.contains($0.localIdentifier)
                    && state.failures[$0.localIdentifier, default: 0] < Self.maxAttempts
            }
        }

        let slots = max(0, min(PHAssetResourceUploadJob.jobLimit, 20) - state.inflight.count)
        var created = 0
        for asset in assets.prefix(slots) {
            guard !cancelled.value, let resource = primaryResource(of: asset) else { continue }
            let request = destination(url: url, asset: asset, resource: resource)
            var jobID: String?
            try PHPhotoLibrary.shared().performChangesAndWait {
                jobID = PHAssetResourceUploadJobChangeRequest
                    .creationRequestForJob(destination: request, resource: resource)
                    .placeholderForCreatedAssetResourceUploadJob?.localIdentifier
            }
            if let jobID {
                state.inflight[jobID] = asset.localIdentifier
                created += 1
                SharedLog.write("ext", "queued \(resource.originalFilename) as job \(jobID)")
            }
        }
        return created
    }

    /// Oldest first, so a backlog uploads in the order photos were taken.
    private func newestAssets(limit: Int, after: Date?, mediaType: PHAssetMediaType?) -> [PHAsset] {
        let options = PHFetchOptions()
        var predicates: [NSPredicate] = []
        if let after { predicates.append(NSPredicate(format: "creationDate > %@", after as NSDate)) }
        if let mediaType { predicates.append(NSPredicate(format: "mediaType == %d", mediaType.rawValue)) }
        if !predicates.isEmpty { options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates) }
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: after != nil)]
        options.fetchLimit = limit
        let result = PHAsset.fetchAssets(with: options)
        return (0..<result.count).map { result.object(at: $0) }
    }

    /// The version you see in Photos: the edited render if there is one, else the original.
    private func primaryResource(of asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        let order: [PHAssetResourceType] = asset.mediaType == .video
            ? [.fullSizeVideo, .video]
            : [.fullSizePhoto, .photo]
        for type in order {
            if let match = resources.first(where: { $0.type == type }) { return match }
        }
        return nil
    }

    private func destination(url: URL, asset: PHAsset, resource: PHAssetResource) -> URLRequest {
        let iso = ISO8601DateFormatter()
        let created = asset.creationDate ?? Date()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(Settings.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(asset.localIdentifier, forHTTPHeaderField: Header.assetID)
        request.setValue(resource.originalFilename.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "upload",
                         forHTTPHeaderField: Header.filename)
        request.setValue(UTType(resource.uniformTypeIdentifier)?.preferredMIMEType ?? "application/octet-stream",
                         forHTTPHeaderField: "X-Content-Type")
        request.setValue(iso.string(from: created), forHTTPHeaderField: "X-File-Created-At")
        request.setValue(iso.string(from: asset.modificationDate ?? created), forHTTPHeaderField: "X-File-Modified-At")
        request.setValue(asset.isFavorite ? "true" : "false", forHTTPHeaderField: "X-Is-Favorite")
        if asset.mediaType == .video {
            request.setValue(String(Int(asset.duration * 1000)), forHTTPHeaderField: "X-Duration-Ms")
        }
        return request
    }
}

enum Header {
    static let assetID = "X-Asset-Id"
    static let filename = "X-Filename"
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
