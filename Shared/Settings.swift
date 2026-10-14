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

    /// When set, the extension uploads every photo/video created after this date.
    static var autoSince: Date? {
        get { d.object(forKey: "autoSince") as? Date }
        set { d.set(newValue, forKey: "autoSince") }
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
