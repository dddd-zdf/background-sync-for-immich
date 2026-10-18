import Foundation
import Photos

/// Settings shared by the app (writes) and the extension (reads), stored in the app group.
enum Settings {
    private static var d: UserDefaults { AppGroup.defaults }

    /// e.g. https://photos.example.com.
    static var serverURL: String {
        get { d.string(forKey: "serverURL") ?? "" }
        set { d.set(normalized(newValue), forKey: "serverURL") }
    }

    /// Accepts what people paste: no scheme (https assumed), a trailing slash, or the Immich app's
    /// ".../api" form.
    static func normalized(_ url: String) -> String {
        var url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return url }
        if !url.contains("://") { url = "https://" + url }
        while url.hasSuffix("/") { url.removeLast() }
        if url.lowercased().hasSuffix("/api") { url.removeLast(4) }
        return url
    }

    static var apiKey: String {
        get { d.string(forKey: "apiKey") ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "apiKey") }
    }

    /// When set, the extension uploads every photo/video created after this date. Defaults to
    /// when automatic backup was turned on; moving it earlier uploads the backlog.
    static var autoSince: Date? {
        get { d.object(forKey: "autoSince") as? Date }
        set { d.set(newValue, forKey: "autoSince") }
    }

    /// Applies to jobs queued after the change (each upload request carries it).
    static var wifiOnly: Bool {
        get { d.bool(forKey: "wifiOnly") }
        set { d.set(newValue, forKey: "wifiOnly") }
    }

    /// Upload videos (a Live Photo's video always goes with its photo).
    static var includeVideos: Bool {
        get { d.object(forKey: "includeVideos") as? Bool ?? true }
        set { d.set(newValue, forKey: "includeVideos") }
    }

    static var skipScreenshots: Bool {
        get { d.bool(forKey: "skipScreenshots") }
        set { d.set(newValue, forKey: "skipScreenshots") }
    }

    /// The upload filters above, for a photo not in Immich yet.
    static func wantsUpload(_ asset: PHAsset) -> Bool {
        if asset.mediaType == .video && !includeVideos { return false }
        if skipScreenshots && asset.mediaSubtypes.contains(.photoScreenshot) { return false }
        return true
    }

    /// Upload photos from before upload was turned on that the library check finds missing in Immich.
    static var uploadOlder: Bool {
        get { d.object(forKey: "uploadOlder") as? Bool ?? true }
        set { d.set(newValue, forKey: "uploadOlder") }
    }

    enum EditMode: String, CaseIterable {
        /// The edit on top of a stack, the untouched original under it (like Photos).
        case stack
        /// Only the current version; each edit replaces the last one in Immich.
        case latest
        /// Upload what's there at first upload; later edits stay on the iPhone.
        case ignore

        var label: String {
            switch self {
            case .stack: "Keep the original under the edit"
            case .latest: "Latest edit only"
            case .ignore: "Don't sync edits"
            }
        }
    }

    static var editMode: EditMode {
        get { d.string(forKey: "editMode").flatMap(EditMode.init) ?? .stack }
        set { d.set(newValue.rawValue, forKey: "editMode") }
    }

    /// Deleted on the iPhone -> moved to Immich's trash.
    static var syncPhoneDeletes: Bool {
        get { d.object(forKey: "syncPhoneDeletes") as? Bool ?? true }
        set { d.set(newValue, forKey: "syncPhoneDeletes") }
    }

    /// Trashed in Immich -> deleted from the iPhone (after iOS's prompt or the album Shortcut).
    static var syncImmichDeletes: Bool {
        get { d.object(forKey: "syncImmichDeletes") as? Bool ?? true }
        set { d.set(newValue, forKey: "syncImmichDeletes") }
    }

    /// More iPhone deletions than this at once wait for a tap (e.g. Photos access lost).
    static var bulkTrashLimit: Int {
        get { d.object(forKey: "bulkTrashLimit") as? Int ?? 25 }
        set { d.set(newValue, forKey: "bulkTrashLimit") }
    }

    /// Notify while photos trashed in Immich wait to be deleted from the iPhone.
    static var askEnabled: Bool {
        get { d.object(forKey: "askEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "askEnabled") }
    }

    /// Days between those notifications (1-365).
    static var askEveryDays: Int {
        get { d.object(forKey: "askEveryDays") as? Int ?? 7 }
        set { d.set(newValue, forKey: "askEveryDays") }
    }

    /// Local time of day for that notification (device time zone).
    static var askHour: Int {
        get { d.object(forKey: "askHour") as? Int ?? 19 }
        set { d.set(newValue, forKey: "askHour") }
    }

    static var askMinute: Int {
        get { d.integer(forKey: "askMinute") }
        set { d.set(newValue, forKey: "askMinute") }
    }

    /// One-shot request from the app: forget failures so those assets are tried again.
    /// (The app never writes state.json; the extension owns it.)
    static var retryFailedRequested: Bool {
        get { d.bool(forKey: "retryFailedRequested") }
        set { d.set(newValue, forKey: "retryFailedRequested") }
    }

    /// Developer option: send the log to a debug receiver at the server address (proxy/, which prints
    /// it; not part of a normal setup). Off by default.
    static var sendDebugLog: Bool {
        get { d.bool(forKey: "sendDebugLog") }
        set { d.set(newValue, forKey: "sendDebugLog") }
    }

    /// One-shot request from the app: upload the newest photo once.
    static var testUploadRequested: Bool {
        get { d.bool(forKey: "testUploadRequested") }
        set { d.set(newValue, forKey: "testUploadRequested") }
    }

    /// One-shot request from the app: give photos edited before 0.6.0 their original in Immich
    /// (stacked under the edit), like new edits get.
    static var keepOriginalsRequested: Bool {
        get { d.bool(forKey: "keepOriginalsRequested") }
        set { d.set(newValue, forKey: "keepOriginalsRequested") }
    }

    static var lastInvocation: Date? {
        get { d.object(forKey: "lastInvocation") as? Date }
        set { d.set(newValue, forKey: "lastInvocation") }
    }

    static var invocationCount: Int {
        get { d.integer(forKey: "invocationCount") }
        set { d.set(newValue, forKey: "invocationCount") }
    }

    static var uploadURL: URL? {
        URL(string: serverURL)?.appendingPathComponent("api/assets/background")
    }
}
