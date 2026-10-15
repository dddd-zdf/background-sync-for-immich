import BackgroundTasks
import SwiftUI
import UserNotifications

@main
struct ImmichBackupApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { BackgroundSync.schedule() }
        }
        // iOS picks the time; apps that are rarely opened get fewer runs (a Shortcut automation is reliable).
        .backgroundTask(.appRefresh(BackgroundSync.identifier)) {
            BackgroundSync.schedule()
            _ = await DeleteSync.shared.runInBackground()
        }
    }
}

enum BackgroundSync {
    static let identifier = "com.difei.immichbackup.sync"

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date().addingTimeInterval(6 * 3600)
        Task {
            do {
                try await BGTaskScheduler.shared.submitTaskRequest(request)
            } catch {
                SharedLog.write("app", "background refresh not scheduled: \(error)")
            }
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
