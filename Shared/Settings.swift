import Foundation

/// Settings shared by the app (writes) and the extension (reads), stored in the app group.
enum Settings {
    private static var d: UserDefaults { AppGroup.defaults }

    /// e.g. https://photos.example.com (the proxy route lives under it).
    static var serverURL: String {
        get { d.string(forKey: "serverURL") ?? "https://photos.example.com" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "serverURL") }
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

    /// Days between "ask to delete" notifications while photos trashed in Immich wait; 0 = never.
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

    /// One-shot request from the app: upload the newest photo once.
    static var testUploadRequested: Bool {
        get { d.bool(forKey: "testUploadRequested") }
        set { d.set(newValue, forKey: "testUploadRequested") }
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
