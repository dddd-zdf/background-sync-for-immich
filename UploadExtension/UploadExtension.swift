import ExtensionFoundation
import Foundation
import Photos
import UniformTypeIdentifiers

/// PhotoKit background upload extension (iOS 27). iOS launches this on its own schedule,
/// whether or not the app is running, and performs the uploads we queue as jobs.
///
/// Each job uploads one file. A Live Photo takes two jobs in sequence: its video first, then,
/// once the video's Immich ID is known, the still with `X-Live-Photo-Video-Id` so Immich pairs them.
@main
final class UploadExtension: PHBackgroundResourceUploadJobExtension {
    private let cancelled = Flag()
    /// The app's links to photos that reached Immich another way (read-only here).
    private var sync = SyncStore()

    required init() {
        SharedLog.write("ext", "init, app group \(AppGroup.identifier), container \(AppGroup.container != nil ? "ok" : "MISSING")")
    }

    func processJobs() async -> PHBackgroundResourceUploadProcessingResult {
        // iOS can reuse this instance after willTerminate(), so the stop flag is per run.
        cancelled.value = false
        Settings.lastInvocation = Date()
        Settings.invocationCount += 1
        SharedLog.write("ext", "processJobs #\(Settings.invocationCount) start")
        var state = UploadState.load()
        sync = SyncStore.load()
        defer { state.save() }
        do {
            try acknowledgeFinishedJobs(&state)
            guard !cancelled.value else {
                SharedLog.write("ext", "stopped early (willTerminate)")
                return .processing
            }
            if Settings.retryFailedRequested {
                Settings.retryFailedRequested = false
                SharedLog.write("ext", "retrying \(state.failed.count) failed")
                state.failed = [:]
            }
            if Settings.keepOriginalsRequested {
                Settings.keepOriginalsRequested = false
                keepOriginalsOfEditedPhotos(&state)
            }
            await trashDeletedOnPhone(&state)
            await findEdits(&state)
            let created = try await createJobs(&state)
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
    /// by `createJobs` until it has failed `UploadState.maxAttempts` times.
    private func acknowledgeFinishedJobs(_ state: inout UploadState) throws {
        let jobs = PHAssetResourceUploadJob.fetchJobs(action: .acknowledge, options: nil)
        for i in 0..<jobs.count {
            let job = jobs.object(at: i)
            let sent = job.destination
            let assetID = sent.value(forHTTPHeaderField: Header.assetID) ?? state.inflight[job.localIdentifier] ?? "?"
            let part = Part(rawValue: sent.value(forHTTPHeaderField: Header.part) ?? "") ?? .main
            let file = sent.value(forHTTPHeaderField: Header.filename)?.removingPercentEncoding ?? "?"
            let headers = job.responseHeaderFields ?? [:]
            let immichID = headers["x-immich-asset-id"] ?? ""
            let status = headers["x-immich-status"] ?? "-"
            let result = headers["x-immich-result"] ?? ""
            let replaced = (headers["x-immich-replaced"].map { " replaced: \($0)" } ?? "")
                + (headers["x-immich-stacked"].map { " stacked: \($0)" } ?? "")
                + (headers["x-immich-restored"].map { " restored: \($0)" } ?? "")

            if !immichID.isEmpty {
                switch part {
                case .originalVideo:
                    state.originalVideos[assetID] = immichID
                case .original:
                    state.originals[assetID] = immichID
                case .video:
                    state.liveVideos[assetID] = immichID
                case .main:
                    state.uploaded[assetID] = immichID
                    // Set when the render reused the original's video instead of uploading one.
                    if let video = sent.value(forHTTPHeaderField: "X-Live-Photo-Video-Id") { state.liveVideos[assetID] = video }
                    state.replacing[assetID] = nil
                    state.requested.remove(assetID)
                    if let modified = sent.value(forHTTPHeaderField: Header.modified).flatMap(Double.init),
                       let fingerprint = sent.value(forHTTPHeaderField: Header.fingerprint) {
                        state.versions[assetID] = .init(modified: Date(timeIntervalSince1970: modified), fingerprint: fingerprint)
                    }
                }
                state.failed[assetID] = nil
                state.lastUpload = Date()
                state.note("ok \(result) \(file) -> \(immichID)\(replaced)")
            } else {
                let error = job.error.map { "\(($0 as NSError).domain) \(($0 as NSError).code)" }
                let reason = [status == "-" ? nil : "HTTP \(status)", headers["x-immich-error"], error]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
                let count = (state.failed[assetID]?.count ?? 0) + 1
                state.failed[assetID] = .init(count: count, reason: reason.isEmpty ? "no response" : reason, file: file, date: Date())
                if count >= UploadState.maxAttempts { state.requested.remove(assetID) }
                state.note("fail \(file) state=\(job.state.rawValue) \(reason)")
            }
            SharedLog.write("ext", "job \(job.localIdentifier) \(part.rawValue) state \(job.state.rawValue) immich \(status) \(result) \(immichID)\(replaced)")

            try PHPhotoLibrary.shared().performChangesAndWait {
                PHAssetResourceUploadJobChangeRequest(for: job)?.acknowledge()
            }
            state.inflight[job.localIdentifier] = nil
        }
    }

    // MARK: - Deleted on the iPhone

    /// iOS runs the extension on every photo library change, deletions included, so this is where
    /// a delete on the iPhone reaches Immich's trash without the app. Over `Settings.bulkTrashLimit`
    /// at once is left for the app to ask about (it may be lost Photos access, not deletions).
    private func trashDeletedOnPhone(_ state: inout UploadState) async {
        guard Settings.syncPhoneDeletes, PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized,
              let base = URL(string: Settings.serverURL), !Settings.apiKey.isEmpty else { return }
        let tracked = Set(state.uploaded.keys).union(sync.links.keys)
            .subtracting(sync.gone).subtracting(state.trashed)
            .subtracting(state.inflight.values).subtracting(state.replacing.keys)
        guard !tracked.isEmpty else { return }
        // Scan the library rather than fetching by ID: a fetch by ID may still return photos that
        // are only in Recently Deleted. (Same check as the app's sync.)
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        let library = PHAsset.fetchAssets(with: options)
        guard library.count > 0 else { return }  // nothing visible at all: not trusting that
        var present = Set<String>()
        for i in 0..<library.count { present.insert(library.object(at: i).localIdentifier) }
        let missing = tracked.subtracting(present)
        SharedLog.write("ext", "delete check: \(tracked.count) tracked, \(missing.count) gone from iPhone")
        guard !missing.isEmpty else { return }
        guard missing.count <= Settings.bulkTrashLimit else {
            SharedLog.write("ext", "\(missing.count) gone from iPhone at once; leaving them for the app to ask")
            return
        }

        var trashedNow: Set<String> = []
        for id in missing {
            let ids = [state.uploaded[id] ?? sync.links[id]?.immichID, state.liveVideos[id] ?? sync.links[id]?.videoID,
                       state.originals[id], state.originalVideos[id]].compactMap { $0 }
            switch await trashInImmich(Array(Set(ids)), base: base) {
            case 200..<300, 400:  // trashed, or already gone from Immich: nothing more to do
                trashedNow.insert(id)
            case let code:
                SharedLog.write("ext", "trash in Immich failed for \(id): HTTP \(code); will retry")
            }
        }
        state.trashed.formUnion(trashedNow)
        if !trashedNow.isEmpty {
            state.note("trashed \(trashedNow.count) in Immich (deleted on iPhone)")
            SharedLog.write("ext", "trashed \(trashedNow.count) in Immich, deleted on iPhone")
        }
    }

    /// `DELETE /api/assets` moves to Immich's trash. Returns the HTTP status, 0 if unreachable.
    private func trashInImmich(_ ids: [String], base: URL) async -> Int {
        guard !ids.isEmpty else { return 400 }
        return await immich("DELETE", "api/assets", body: ["ids": ids], base: base).status
    }

    /// One Immich API call. Status 0 if unreachable.
    private func immich(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil,
                        base: URL) async -> (status: Int, data: Data) {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { return (0, Data()) }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue(Settings.apiKey, forHTTPHeaderField: "x-api-key")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch {
            SharedLog.write("ext", "\(method) \(path) failed: \(error.localizedDescription)")
            return (0, Data())
        }
    }

    // MARK: - Edits

    /// Finds uploaded assets edited since their upload. Their next upload replaces the old
    /// Immich asset (the proxy copies albums over, then trashes the old one). A Live Photo's
    /// video is sent again too; Immich deletes the old video with the old still once nothing uses it.
    /// `modificationDate` also changes for favorites, albums and Photos' own analysis, so an
    /// edit is confirmed by a change in the asset's adjustment data.
    private func findEdits(_ state: inout UploadState) async {
        // Not advancing `editsCheckedUntil`: edits made meanwhile are found if edits are turned back on.
        guard Settings.editMode != .ignore else { return }
        let scanStart = Date()
        let result: PHFetchResult<PHAsset>
        if let checked = state.editsCheckedUntil {
            // A day of overlap catches edits made while the upload was still in flight.
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "modificationDate > %@", checked.addingTimeInterval(-86400) as NSDate)
            result = PHAsset.fetchAssets(with: options)
        } else {
            result = PHAsset.fetchAssets(withLocalIdentifiers: Array(state.uploaded.keys), options: nil)
        }

        var complete = true
        for i in 0..<result.count {
            if cancelled.value { complete = false; break }
            let asset = result.object(at: i)
            let id = asset.localIdentifier
            guard let current = sync.immichID(for: id, state), state.replacing[id] == nil,
                  let modified = asset.modificationDate else { continue }
            let recorded = state.uploaded[id] != nil ? state.versions[id] : sync.links[id]?.version
            if let recorded, modified <= recorded.modified { continue }
            guard let fingerprint = await AssetHashing.editFingerprint(of: asset) else { complete = false; continue }
            guard let known = recorded, known.fingerprint != "unknown" else {
                // Uploaded before versions were recorded: take what's there now as the baseline.
                state.versions[id] = .init(modified: modified, fingerprint: fingerprint)
                continue
            }
            if fingerprint == known.fingerprint {
                state.versions[id] = .init(modified: modified, fingerprint: fingerprint)
                continue
            }
            if fingerprint == "original", let original = state.originals[id] {
                // Reverted in Photos: the original is already in Immich, under the edit.
                guard await revert(render: current, original: original) else { complete = false; continue }
                state.uploaded[id] = original
                state.liveVideos[id] = state.originalVideos[id]
                state.originals[id] = nil
                state.originalVideos[id] = nil
                state.versions[id] = .init(modified: modified, fingerprint: fingerprint)
                state.note("reverted \(id): original \(original) shown again, \(current) trashed")
                SharedLog.write("ext", "revert: \(id) back to original \(original)")
                continue
            }
            if Settings.editMode == .stack, fingerprint != "original", state.originals[id] == nil, known.fingerprint == "original" {
                // First edit of a photo that reached Immich unedited: Immich already has the original.
                state.originals[id] = current
                state.originalVideos[id] = state.liveVideos[id] ?? sync.links[id]?.videoID
            }
            state.replacing[id] = current
            state.uploaded[id] = nil
            state.liveVideos[id] = nil
            state.failed[id] = nil
            state.note("edited \(id), will replace \(state.replacing[id] ?? "?")")
            SharedLog.write("ext", "edit found: \(id)")
        }
        if complete { state.editsCheckedUntil = scanStart }
    }

    /// Puts the original back on top after Revert in Photos: removes the render's stack, copies its
    /// albums, shared links and favorite to the original, then trashes the render. False to try again next run.
    private func revert(render: String, original: String) async -> Bool {
        guard render != original else { return true }
        guard let base = URL(string: Settings.serverURL), !Settings.apiKey.isEmpty else { return false }
        func ok(_ status: Int, _ step: String) -> Bool {
            if (200..<300).contains(status) { return true }
            SharedLog.write("ext", "revert \(render): \(step) HTTP \(status)")
            return false
        }
        let found = await immich("GET", "api/stacks", query: [URLQueryItem(name: "primaryAssetId", value: render)], base: base)
        guard ok(found.status, "stack lookup") else { return false }
        let stacks = (try? JSONSerialization.jsonObject(with: found.data)) as? [[String: Any]] ?? []
        for case let stack? in stacks.map({ $0["id"] as? String }) {
            guard ok(await immich("DELETE", "api/stacks/\(stack)", base: base).status, "unstack") else { return false }
        }
        let copied = await immich("PUT", "api/assets/copy",
                                  body: ["sourceId": render, "targetId": original, "stack": false, "favorite": true], base: base)
        guard copied.status == 400 || ok(copied.status, "copy") else { return false }  // 400: render already gone
        let trashed = await trashInImmich([render], base: base)
        return trashed == 400 || ok(trashed, "trash")
    }

    /// For photos edited before originals were kept: queue each one like a new edit, so its original
    /// uploads (Immich matches it if already there) and its render goes on top of a stack.
    private func keepOriginalsOfEditedPhotos(_ state: inout UploadState) {
        let tracked = Set(state.uploaded.keys).union(sync.links.keys)
            .subtracting(sync.gone).subtracting(state.trashed).subtracting(state.inflight.values)
            .subtracting(sync.pendingRemoval.keys)  // trashed in Immich: on their way off the iPhone
            .filter { state.originals[$0] == nil && state.replacing[$0] == nil }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(tracked), options: nil)
        var queued = 0
        for i in 0..<assets.count {
            let asset = assets.object(at: i)
            let id = asset.localIdentifier
            guard Self.render(of: asset, PHAssetResource.assetResources(for: asset)) != nil,
                  let current = sync.immichID(for: id, state) else { continue }
            state.replacing[id] = current
            state.uploaded[id] = nil
            state.failed[id] = nil
            queued += 1
        }
        state.note("keeping originals: \(queued) edited photos queued")
        SharedLog.write("ext", "keep originals: \(queued) edited photos queued")
    }

    // MARK: - New jobs

    private func createJobs(_ state: inout UploadState) async throws -> Int {
        guard let url = Settings.uploadURL, !Settings.apiKey.isEmpty else {
            SharedLog.write("ext", "no server URL or API key; nothing to do")
            return 0
        }
        let slots = max(0, min(PHAssetResourceUploadJob.jobLimit, 20) - state.inflight.count)
        guard slots > 0 else { return 0 }

        // An asset with a job in flight waits: a Live Photo's still goes only after its video.
        var picked = Set(state.inflight.values)
        var assets: [PHAsset] = []
        func add(_ asset: PHAsset) {
            if assets.count < slots, picked.insert(asset.localIdentifier).inserted { assets.append(asset) }
        }
        func addNeeded(_ result: PHFetchResult<PHAsset>) {
            for i in 0..<result.count where assets.count < slots {
                let id = result.object(at: i).localIdentifier
                let new = sync.immichID(for: id, state) == nil
                let needed = new || state.replacing[id] != nil || state.requested.contains(id)
                // The filters only hold back new uploads; edits of what's already in Immich still sync.
                if needed && !state.gaveUp(on: id) && (!new || state.requested.contains(id) || Self.wanted(result.object(at: i))) {
                    add(result.object(at: i))
                }
            }
        }

        if Settings.testUploadRequested {
            Settings.testUploadRequested = false
            let newest = fetch(after: nil, ascending: false, mediaType: .image, limit: 1)
            if newest.count > 0 {
                let id = newest.object(at: 0).localIdentifier
                state.requested.insert(id)
                state.failed[id] = nil
            }
            SharedLog.write("ext", "test upload requested, found \(newest.count) photo")
        }
        // Edited photos and the test photo (they can be older than the backup start date).
        let pending = Set(state.replacing.keys).union(state.requested)
        if !pending.isEmpty {
            let found = PHAsset.fetchAssets(withLocalIdentifiers: Array(pending), options: nil)
            let ids = Set((0..<found.count).map { found.object(at: $0).localIdentifier })
            for id in pending where !ids.contains(id) {  // deleted from Photos
                state.replacing[id] = nil
                state.requested.remove(id)
            }
            addNeeded(found)
        }
        if let since = Settings.autoSince {
            // Photos from the last day first (newest first), so a backlog doesn't hold them up;
            // then the backlog, oldest first.
            let dayAgo = Date().addingTimeInterval(-86400)
            addNeeded(fetch(after: max(since, dayAgo), ascending: false, mediaType: nil, limit: 0))
            if since < dayAgo { addNeeded(fetch(after: since, ascending: true, mediaType: nil, limit: 0)) }
            // Older photos the app's library check found missing from Immich (no name/time
            // candidate, or none with the same bytes): this is what replaces a backlog start date.
            if Settings.uploadOlder, !sync.unmatched.isEmpty {
                addNeeded(PHAsset.fetchAssets(withLocalIdentifiers: Array(sync.unmatched.keys), options: nil))
            }
        }

        var created = 0
        for asset in assets {
            guard !cancelled.value else { break }
            guard let next = nextUpload(of: asset, state) else {
                let count = (state.failed[asset.localIdentifier]?.count ?? 0) + 1
                state.failed[asset.localIdentifier] = .init(count: count, reason: "no photo or video file found in Photos",
                                                            file: asset.localIdentifier, date: Date())
                continue
            }
            let (resource, part) = next
            let request = await destination(url: url, asset: asset, resource: resource, part: part, state: state)
            var jobID: String?
            try PHPhotoLibrary.shared().performChangesAndWait {
                jobID = PHAssetResourceUploadJobChangeRequest
                    .creationRequestForJob(destination: request, resource: resource)
                    .placeholderForCreatedAssetResourceUploadJob?.localIdentifier
            }
            if let jobID {
                state.inflight[jobID] = asset.localIdentifier
                created += 1
                SharedLog.write("ext", "queued \(part.rawValue) \(request.value(forHTTPHeaderField: Header.filename) ?? "?") as job \(jobID)")
            }
        }
        return created
    }

    private func fetch(after: Date?, ascending: Bool, mediaType: PHAssetMediaType?, limit: Int) -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        var predicates: [NSPredicate] = []
        if let after { predicates.append(NSPredicate(format: "creationDate > %@", after as NSDate)) }
        if let mediaType { predicates.append(NSPredicate(format: "mediaType == %d", mediaType.rawValue)) }
        if !predicates.isEmpty { options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates) }
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: ascending)]
        options.fetchLimit = limit
        return PHAsset.fetchAssets(with: options)
    }

    /// The next file to send for this asset, one per job, in this order:
    /// - edited and its original not in Immich yet: the original (a Live Photo's original video first),
    /// - a Live Photo's video until it has an Immich ID (an edit that left the video alone reuses
    ///   the original's),
    /// - then the version you see in Photos (the edited render if there is one, else the original).
    ///   An edit's render is stacked on top of the original by the proxy.
    private func nextUpload(of asset: PHAsset, _ state: UploadState) -> (PHAssetResource, Part)? {
        let id = asset.localIdentifier
        let resources = PHAssetResource.assetResources(for: asset)
        func first(_ type: PHAssetResourceType) -> PHAssetResource? { resources.first { $0.type == type } }
        let live = asset.mediaType == .image && asset.mediaSubtypes.contains(.photoLive)
        let original = first(asset.mediaType == .video ? .video : .photo)
        let render = Self.render(of: asset, resources)
        if Settings.editMode == .stack, render != nil, state.originals[id] == nil, let original {
            if live, state.originalVideos[id] == nil, let video = first(.pairedVideo) { return (video, .originalVideo) }
            return (original, .original)
        }
        if live, state.liveVideos[id] == nil {
            if let video = first(.fullSizePairedVideo) { return (video, .video) }
            if render == nil || state.originalVideos[id] == nil, let video = first(.pairedVideo) { return (video, .video) }
        }
        return (render ?? original).map { ($0, .main) }
    }

    /// The upload filters in Settings.
    private static func wanted(_ asset: PHAsset) -> Bool {
        if asset.mediaType == .video && !Settings.includeVideos { return false }
        if Settings.skipScreenshots && asset.mediaSubtypes.contains(.photoScreenshot) { return false }
        return true
    }

    /// The edited render, if the asset has been edited in Photos.
    static func render(of asset: PHAsset, _ resources: [PHAssetResource]) -> PHAssetResource? {
        let type: PHAssetResourceType = asset.mediaType == .video ? .fullSizeVideo : .fullSizePhoto
        return resources.first { $0.type == type }
    }

    private func destination(url: URL, asset: PHAsset, resource: PHAssetResource, part: Part, state: UploadState) async -> URLRequest {
        let iso = ISO8601DateFormatter()
        let id = asset.localIdentifier
        let created = asset.creationDate ?? Date()
        let modified = asset.modificationDate ?? created
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.allowsCellularAccess = !Settings.wifiOnly
        request.allowsExpensiveNetworkAccess = !Settings.wifiOnly
        request.setValue(Settings.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(id, forHTTPHeaderField: Header.assetID)
        request.setValue(part.rawValue, forHTTPHeaderField: Header.part)
        request.setValue(filename(for: resource, of: asset).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "upload",
                         forHTTPHeaderField: Header.filename)
        request.setValue(UTType(resource.uniformTypeIdentifier)?.preferredMIMEType ?? "application/octet-stream",
                         forHTTPHeaderField: "X-Content-Type")
        request.setValue(iso.string(from: created), forHTTPHeaderField: "X-File-Created-At")
        request.setValue(iso.string(from: modified), forHTTPHeaderField: "X-File-Modified-At")
        switch part {
        case .video, .originalVideo:
            request.setValue("false", forHTTPHeaderField: "X-Is-Favorite")
        case .original:
            // Under the edit in a stack; the favorite goes on the edit.
            request.setValue("false", forHTTPHeaderField: "X-Is-Favorite")
            if asset.mediaType == .video {
                request.setValue(String(Int(asset.duration * 1000)), forHTTPHeaderField: "X-Duration-Ms")
            }
            request.setValue(state.originalVideos[id], forHTTPHeaderField: "X-Live-Photo-Video-Id")
        case .main:
            request.setValue(asset.isFavorite ? "true" : "false", forHTTPHeaderField: "X-Is-Favorite")
            if asset.mediaType == .video {
                request.setValue(String(Int(asset.duration * 1000)), forHTTPHeaderField: "X-Duration-Ms")
            }
            let edited = Self.render(of: asset, PHAssetResource.assetResources(for: asset)) != nil
            let video = state.liveVideos[id] ?? (edited ? state.originalVideos[id] : nil)
            request.setValue(video, forHTTPHeaderField: "X-Live-Photo-Video-Id")
            request.setValue(state.replacing[id], forHTTPHeaderField: Header.replace)
            // The proxy stacks the render on top of the original.
            if edited { request.setValue(state.originals[id], forHTTPHeaderField: Header.stackOriginal) }
            // Read back on acknowledge to record which version was uploaded (edit detection).
            request.setValue(String(modified.timeIntervalSince1970), forHTTPHeaderField: Header.modified)
            request.setValue(await AssetHashing.editFingerprint(of: asset) ?? "unknown", forHTTPHeaderField: Header.fingerprint)
        }
        return request
    }

    /// Edited renders are named FullSizeRender.*; keep the original's name with the render's extension.
    private func filename(for resource: PHAssetResource, of asset: PHAsset) -> String {
        let name = resource.filename ?? "upload"
        guard name.hasPrefix("FullSizeRender") else { return name }
        let originals: [PHAssetResourceType] = [.photo, .video]
        guard let original = PHAssetResource.assetResources(for: asset).first(where: { originals.contains($0.type) })?.filename
        else { return name }
        return ((original as NSString).deletingPathExtension as NSString).appendingPathExtension((name as NSString).pathExtension) ?? name
    }
}

enum Part: String {
    case main, video
    /// An edited photo's untouched original (and a Live Photo's original video), sent before the edit.
    case original, originalVideo
}

enum Header {
    static let assetID = "X-Asset-Id"
    static let part = "X-Upload-Part"
    static let filename = "X-Filename"
    static let replace = "X-Replace-Asset-Id"
    static let stackOriginal = "X-Stack-Original-Id"
    static let modified = "X-Asset-Modified"
    static let fingerprint = "X-Edit-Fingerprint"
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
