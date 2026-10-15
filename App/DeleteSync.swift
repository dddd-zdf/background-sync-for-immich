import Foundation
import Photos
import UserNotifications

/// Two-way delete sync between the iPhone library and Immich. Runs in the app (on open, the Sync
/// button, background refresh, or the Shortcuts action), never in the extension. Deleting photos
/// needs iOS's confirmation prompt, which only the app in the foreground can show, so a background
/// run that finds photos trashed in Immich plans a notification; tapping it shows the prompt.
///
/// - Deleted on the iPhone -> moved to Immich's trash (automatic up to `autoTrashLimit` at once).
/// - Trashed in Immich -> listed in `pendingRemoval`; deleted from the iPhone after iOS's prompt.
/// - Library photos that reached Immich another way are linked first: same file name or capture
///   time finds a candidate, the SHA1 of the photo's bytes must equal Immich's checksum.
@MainActor
final class DeleteSync: ObservableObject {
    static let shared = DeleteSync()

    /// More iPhone deletions than this in one go wait for a tap in the app (e.g. Photos access lost).
    static let autoTrashLimit = 25

    @Published private(set) var store = SyncStore.load()
    @Published private(set) var running = false
    @Published private(set) var progress = ""
    /// Set when the notification is tapped; the app then goes straight to the delete prompt.
    @Published var removalRequested = false

    static let notificationID = "trashed-in-immich"

    func reload() {
        if !running { store = SyncStore.load() }
    }

    /// One sync pass. `linkBudget`: seconds to spend matching unlinked photos (hashing); nil = all.
    @discardableResult
    func run(linkBudget: TimeInterval?) async -> String {
        guard !running else { return "A sync is already running." }
        running = true
        defer { running = false; progress = "" }
        var store = SyncStore.load()
        let result: String
        do {
            result = try await pass(&store, linkBudget: linkBudget)
        } catch {
            result = "Sync failed: \(error.localizedDescription)"
        }
        store.lastSync = Date()
        store.lastResult = result
        store.save()
        self.store = store
        await updateAskNotification()
        SharedLog.write("sync", result)
        return result
    }

    private func pass(_ store: inout SyncStore, linkBudget: TimeInterval?) async throws -> String {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw Immich.Failure(message: "needs full Photos access")
        }
        guard !Settings.apiKey.isEmpty else { throw Immich.Failure(message: "no API key") }

        progress = "Reading the Immich library..."
        let remote = try await Immich.index()
        guard !remote.isEmpty else { throw Immich.Failure(message: "Immich returned no photos, so nothing was changed") }
        let byID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        progress = "Reading the iPhone library..."
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        let fetched = PHAsset.fetchAssets(with: options)
        var phone: [String: PHAsset] = [:]
        for i in 0..<fetched.count {
            let asset = fetched.object(at: i)
            phone[asset.localIdentifier] = asset
        }
        guard !phone.isEmpty else { throw Immich.Failure(message: "the iPhone library looks empty, so nothing was changed") }

        let state = UploadState.load()
        let busy = Set(state.inflight.values)

        // 1. Deleted on the iPhone -> Immich's trash.
        var missing: [String: SyncStore.Pending] = [:]
        let tracked = Set(state.uploaded.keys).union(store.links.keys).union(state.replacing.keys).subtracting(store.gone)
        for id in tracked where phone[id] == nil && !busy.contains(id) {
            guard let immichID = store.immichID(for: id, state) ?? state.replacing[id],
                  let asset = byID[immichID], !asset.isTrashed else {
                store.markGone(id)  // already trashed in Immich, or not visible to us: nothing to do
                continue
            }
            missing[id] = .init(immichID: immichID, file: asset.originalFileName, videoID: asset.livePhotoVideoId)
        }
        var trashed = 0
        if missing.count > Self.autoTrashLimit {
            store.heldTrash = missing
        } else {
            store.heldTrash = [:]
            try await trash(missing, &store)
            trashed = missing.count
        }

        // 2. Link photos that reached Immich some other way.
        let byName = Dictionary(grouping: remote) { Self.nameKey($0.originalFileName) }
        let bySecond = Dictionary(grouping: remote) { Int($0.fileCreatedAt.timeIntervalSince1970) }
        let deadline = linkBudget.map { Date().addingTimeInterval($0) }
        let todo = phone.values.filter { asset in
            let id = asset.localIdentifier
            return store.immichID(for: id, state) == nil && state.replacing[id] == nil && !busy.contains(id)
                && store.unmatched[id] != (asset.modificationDate ?? .distantPast)
        }
        var linked = 0
        for (n, asset) in todo.enumerated() {
            if let deadline, Date() > deadline { break }
            if n % 25 == 0 {
                progress = "Matching iPhone photos with Immich: \(n) of \(todo.count)"
                store.save()
            }
            let id = asset.localIdentifier
            let resources = PHAssetResource.assetResources(for: asset)
            var candidates = Set(resources.compactMap { $0.filename.map(Self.nameKey) }).flatMap { byName[$0] ?? [] }
            if let created = asset.creationDate.map({ Int($0.timeIntervalSince1970) }) {
                for second in (created - 2)...(created + 2) { candidates += bySecond[second] ?? [] }
            }
            let checked = asset.modificationDate ?? .distantPast
            guard !candidates.isEmpty else { store.unmatched[id] = checked; continue }

            var match: Immich.Asset?
            var unreadable = false
            for resource in Self.hashOrder(resources, asset) {
                guard let sha1 = await AssetHashing.sha1(of: resource) else { unreadable = true; continue }
                if let found = candidates.first(where: { $0.checksum == sha1 }) { match = found; break }
            }
            if let match {
                let fingerprint = await AssetHashing.editFingerprint(of: asset) ?? "unknown"
                store.links[id] = .init(immichID: match.id, version: .init(modified: checked, fingerprint: fingerprint))
                store.unmatched[id] = nil
                linked += 1
            } else if !unreadable {
                store.unmatched[id] = checked  // not in Immich (or a different version of it)
            }
        }
        let leftToMatch = todo.count - linked - todo.filter { store.unmatched[$0.localIdentifier] != nil }.count

        // 3. Trashed in Immich -> waiting to be deleted from the iPhone.
        var pending: [String: SyncStore.Pending] = [:]
        for id in phone.keys where state.replacing[id] == nil && !busy.contains(id) {
            guard let immichID = store.immichID(for: id, state), let asset = byID[immichID], asset.isTrashed else { continue }
            pending[id] = .init(immichID: immichID, file: asset.originalFileName, videoID: asset.livePhotoVideoId)
        }
        store.pendingRemoval = pending

        var parts: [String] = []
        if trashed > 0 { parts.append("moved \(trashed) deleted on iPhone to Immich's trash") }
        if !store.heldTrash.isEmpty { parts.append("\(store.heldTrash.count) gone from iPhone wait for your OK") }
        if linked > 0 { parts.append("linked \(linked) more photos") }
        if leftToMatch > 0 { parts.append("\(leftToMatch) still to match") }
        if !pending.isEmpty { parts.append("\(pending.count) trashed in Immich to remove from iPhone") }
        return parts.isEmpty ? "In sync." : parts.joined(separator: "; ").capitalizedFirst + "."
    }

    /// For background refresh and the Shortcut: a short sync (`run` also plans the notification).
    func runInBackground() async -> String {
        await run(linkBudget: 20)
    }

    /// While photos trashed in Immich wait, keeps one notification planned at the chosen local time,
    /// at least `Settings.askEveryDays` after the last one (if `askEnabled`). Tapping it opens the app
    /// straight into iOS's delete prompt. Nothing is planned when nothing waits.
    func updateAskNotification() async {
        let center = UNUserNotificationCenter.current()
        let defaults = AppGroup.defaults
        let pending = store.pendingRemoval.count
        var planned = defaults.object(forKey: "askAt") as? Date
        let now = Date()
        if let at = planned, at <= now {
            defaults.set(at, forKey: "lastAsk")  // that one has gone off
            defaults.removeObject(forKey: "askAt")
            planned = nil
        }
        guard pending > 0, Settings.askEnabled else {
            center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
            if pending == 0 { center.removeDeliveredNotifications(withIdentifiers: [Self.notificationID]) }
            defaults.removeObject(forKey: "askAt")
            return
        }
        let fireAt: Date
        if let at = planned {
            fireAt = at  // keep the planned time; just refresh the count
        } else {
            let last = defaults.object(forKey: "lastAsk") as? Date
            // A few hours' slack so a run that's a bit late doesn't push it back a whole cycle.
            let earliest = max(now, last.map { $0.addingTimeInterval(Double(max(Settings.askEveryDays, 1)) * 86400 - 4 * 3600) } ?? now)
            fireAt = Calendar.current.nextDate(after: earliest,
                                                matching: DateComponents(hour: Settings.askHour, minute: Settings.askMinute),
                                                matchingPolicy: .nextTime) ?? earliest
        }
        let content = UNMutableNotificationContent()
        content.title = "\(pending) photo\(pending == 1 ? "" : "s") trashed in Immich"
        content.body = "Tap to delete \(pending == 1 ? "it" : "them") from this iPhone."
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireAt)
        let request = UNNotificationRequest(identifier: Self.notificationID, content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
        do {
            try await center.add(request)
            defaults.set(fireAt, forKey: "askAt")
        } catch {
            SharedLog.write("sync", "notification not planned: \(error)")
        }
    }

    /// New interval or time: plan the next notification from scratch.
    func replanAskNotification() async {
        AppGroup.defaults.removeObject(forKey: "askAt")
        await updateAskNotification()
    }

    static func requestNotifications() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Deletes the photos trashed in Immich from the iPhone. iOS asks first; they then sit in
    /// Recently Deleted for 30 days.
    func removePendingFromPhone() async -> String {
        await run(linkBudget: 0)  // fresh check: drops anything restored in Immich since the last sync
        var store = SyncStore.load()
        let ids = Array(store.pendingRemoval.keys)
        guard !ids.isEmpty else { return "Nothing to remove." }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }
        } catch {
            let result = "Nothing removed: \(error.localizedDescription)"
            SharedLog.write("sync", result)
            return result
        }
        for id in ids { store.markGone(id) }
        store.save()
        self.store = store
        await updateAskNotification()
        let result = "Removed \(ids.count) from the iPhone (in Recently Deleted for 30 days)."
        SharedLog.write("sync", result)
        return result
    }

    /// Trashes in Immich the photos held back because too many disappeared from the iPhone at once.
    func trashHeld() async -> String {
        var store = SyncStore.load()
        // Skip any that came back to the iPhone (restored from Recently Deleted) since the sync.
        let back = PHAsset.fetchAssets(withLocalIdentifiers: Array(store.heldTrash.keys), options: nil)
        for i in 0..<back.count { store.heldTrash[back.object(at: i).localIdentifier] = nil }
        let held = store.heldTrash
        do {
            try await trash(held, &store)
        } catch {
            return "Not trashed: \(error.localizedDescription)"
        }
        store.heldTrash = [:]
        store.save()
        self.store = store
        let result = "Moved \(held.count) to Immich's trash."
        SharedLog.write("sync", result)
        return result
    }

    private func trash(_ items: [String: SyncStore.Pending], _ store: inout SyncStore) async throws {
        guard !items.isEmpty else { return }
        let ids = items.values.flatMap { [$0.immichID] + ($0.videoID.map { [$0] } ?? []) }
        try await Immich.trash(ids)
        for id in items.keys { store.markGone(id) }
        SharedLog.write("sync", "trashed in Immich: " + items.values.map(\.file).joined(separator: ", "))
    }

    /// Name without extension, lowercased: IMG_1234.HEIC and IMG_1234.jpg are candidates for each other.
    private static func nameKey(_ name: String) -> String {
        (name as NSString).deletingPathExtension.lowercased()
    }

    /// The bytes Immich may hold: the current version (what the Immich app uploads), then the original.
    private static func hashOrder(_ resources: [PHAssetResource], _ asset: PHAsset) -> [PHAssetResource] {
        let types: [PHAssetResourceType] = asset.mediaType == .video ? [.fullSizeVideo, .video] : [.fullSizePhoto, .photo]
        return types.compactMap { type in resources.first { $0.type == type } }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
