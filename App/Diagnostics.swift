import Foundation
import Photos

enum Diagnostics {
    struct Snapshot {
        var appGroup = AppGroup.identifier
        var containerOK = AppGroup.container != nil
        var invocations: String = {
            guard let last = Settings.lastInvocation else { return "never" }
            return "\(Settings.invocationCount), last \(last.formatted(date: .abbreviated, time: .shortened))"
        }()
        var jobs: String = [PHAssetResourceUploadJob.Action.process, .retry, .acknowledge]
            .map { String(PHAssetResourceUploadJob.fetchJobs(action: $0, options: nil).count) }
            .joined(separator: " / ")
        var state = UploadState.load()

        var failures: [FailureItem] {
            state.failed.map { FailureItem(id: $0.key, failure: $0.value) }.sorted { $0.failure.date > $1.failure.date }
        }
    }

    struct FailureItem: Identifiable {
        let id: String
        let failure: UploadState.Failure
    }

    /// Photos the extension still has to start: new since upload was turned on, older ones the
    /// library check found missing from Immich, and edits waiting to replace their old version.
    /// Excludes ones that gave up.
    static func waitingCount(_ state: UploadState) -> Int {
        let busy = Set(state.inflight.values)
        let count = state.replacing.keys.filter { !busy.contains($0) && !state.gaveUp(on: $0) }.count
        guard let since = Settings.autoSince else { return count }
        let sync = SyncStore.load()
        func needed(_ id: String) -> Bool {
            sync.immichID(for: id, state) == nil && state.replacing[id] == nil && !busy.contains(id) && !state.gaveUp(on: id)
        }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate > %@", since as NSDate)
        var counted = Set<String>()
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
            if needed(asset.localIdentifier) { counted.insert(asset.localIdentifier) }
        }
        PHAsset.fetchAssets(withLocalIdentifiers: Array(sync.unmatched.keys), options: nil).enumerateObjects { asset, _, _ in
            if needed(asset.localIdentifier) { counted.insert(asset.localIdentifier) }
        }
        return count + counted.count
    }

    /// Checks the API key against Immich, then that the upload proxy answers PhotoKit's
    /// preflight (it must reply 501 so PhotoKit uses a plain, non-resumable upload).
    static func checkServer() async -> String {
        guard let base = URL(string: Settings.serverURL), let upload = Settings.uploadURL else { return "Invalid URL" }
        var lines: [String] = []

        var me = URLRequest(url: base.appendingPathComponent("api/users/me"))
        me.setValue(Settings.apiKey, forHTTPHeaderField: "x-api-key")
        do {
            let (data, response) = try await URLSession.shared.data(for: me)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let name = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["name"] as? String
            lines.append(code == 200 ? "Immich: signed in as \(name ?? "?")" : "Immich: HTTP \(code)")
        } catch {
            lines.append("Immich: \(error.localizedDescription)")
        }

        var preflight = URLRequest(url: upload)
        preflight.httpMethod = "OPTIONS"
        do {
            let (_, response) = try await URLSession.shared.data(for: preflight)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            lines.append(code == 501 ? "Upload proxy: ok" : "Upload proxy: HTTP \(code) (expected 501)")
        } catch {
            lines.append("Upload proxy: \(error.localizedDescription)")
        }
        return lines.joined(separator: "\n")
    }
}
