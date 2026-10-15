import AppIntents

/// Shortcuts action for running the delete sync on a schedule, the only way to run it without
/// opening the app (iOS doesn't wake the extension for deletions) (Shortcuts > Automation, e.g. daily
/// or when charging, set to Run Immediately). Runs in the background; if photos trashed in Immich
/// are waiting, it posts a notification, and tapping it shows iOS's delete prompt.
struct SyncDeletionsIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync Immich deletions"
    static let description = IntentDescription(
        "Moves photos deleted on this iPhone to Immich's trash, and puts photos trashed in Immich in the \"Trashed in Immich\" album. Follow it with Find Photos (Album is Trashed in Immich) and Delete Photos to delete them from this iPhone.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let summary = await DeleteSync.shared.runInBackground()
        return .result(dialog: "\(summary)")
    }
}

struct ImmichBackupShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SyncDeletionsIntent(),
                    phrases: ["Sync deletions in \(.applicationName)"],
                    shortTitle: "Sync deletions",
                    systemImageName: "trash")
    }
}
