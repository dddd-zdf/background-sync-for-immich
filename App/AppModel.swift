import Photos
import SwiftUI

/// State shared by the home and settings screens.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var photosStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published var extensionEnabled = PHPhotoLibrary.shared().uploadJobExtensionEnabled
    @Published var extensionError = ""
    @Published var snapshot = Diagnostics.Snapshot()
    @Published var waiting: Int?

    var autoOn: Bool { Settings.autoSince != nil }
    var hasServer: Bool { !Settings.apiKey.isEmpty }

    /// Photos on the iPhone known to be in Immich (uploaded here or linked).
    var onImmich: Int {
        let sync = DeleteSync.shared.store
        return Set(snapshot.state.uploaded.keys).union(sync.links.keys).subtracting(sync.gone).count
    }

    func refresh() {
        photosStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        extensionEnabled = PHPhotoLibrary.shared().uploadJobExtensionEnabled
        snapshot = Diagnostics.Snapshot()
        DeleteSync.shared.reload()
        let state = snapshot.state
        Task.detached(priority: .utility) {
            let count = Diagnostics.waitingCount(state)
            await MainActor.run { self.waiting = count }
        }
    }

    func requestPhotosAccess() async {
        photosStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    func retryFailed() {
        Settings.retryFailedRequested = true
        SharedLog.write("app", "retry failed requested")
        wakeExtension()
    }

    /// After the extension reports .completed, iOS only wakes it on a photo library change;
    /// a settings change isn't one. Re-enabling it makes iOS run it right away.
    func wakeExtension() {
        guard extensionEnabled else { refresh(); return }
        setExtension(false)
        setExtension(true)
    }

    func setExtension(_ on: Bool) {
        let library = PHPhotoLibrary.shared()
        do {
            // Enabling twice throws (PHPhotosErrorDomain 3202), so only call on a real change.
            if on && !library.uploadJobExtensionEnabled {
                try library.enableUploadJobExtension(with: PHAssetResourceUploadJobOptions())
            } else if !on && library.uploadJobExtensionEnabled {
                try library.disableUploadJobExtension()
            }
            extensionError = ""
            SharedLog.write("app", "extension enabled = \(library.uploadJobExtensionEnabled)")
        } catch {
            let ns = error as NSError
            extensionError = "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
            SharedLog.write("app", "enable/disable extension (\(on)) failed: \(extensionError) \(ns.userInfo)")
        }
        refresh()
    }
}

extension PHAuthorizationStatus {
    var label: String {
        switch self {
        case .authorized: "Full access"
        case .limited: "Limited (needs full)"
        case .denied: "Denied (change in Settings)"
        case .restricted: "Restricted"
        case .notDetermined: "Not asked yet"
        @unknown default: "Unknown"
        }
    }
}
