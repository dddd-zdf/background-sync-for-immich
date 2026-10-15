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

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.identifier == DeleteSync.notificationID else { return }
        await MainActor.run { DeleteSync.shared.removalRequested = true }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
