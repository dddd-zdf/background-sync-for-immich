import SwiftUI
import UserNotifications

// No BGAppRefreshTask: iOS rejected its identifier under SideStore signing ("Unrecognized
// Identifier", 2026-10-15) and never runs it for swiped-away apps anyway. Background checks come
// from the upload extension (on new photos) and the Shortcuts action.
@main
struct ImmichBackupApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// Tapping the "trashed in Immich" notification opens the app and asks to remove them.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Experiment: iOS launches the app in the background with the results of `DirectUpload` uploads
    /// the extension started, if the extension is gone by then.
    private var directSession: URLSession?
    private let directDelegate = DirectUpload.Delegate(process: "app")

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        SharedLog.write("direct", "app launched for background session \(identifier)")
        guard identifier == DirectUpload.sessionID else { completionHandler(); return }
        directDelegate.finishedEvents = completionHandler
        directSession = DirectUpload.session(delegate: directDelegate)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.identifier == DeleteSync.notificationID else { return }
        await MainActor.run { DeleteSync.shared.removalRequested = true }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
