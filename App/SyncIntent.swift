import AppIntents

/// Shortcuts action for running the delete sync on a schedule (Shortcuts > Automation, e.g. daily
/// or when charging, set to Run Immediately). Runs in the background; if photos trashed in Immich
/// are waiting, it posts a notification, and tapping it shows iOS's delete prompt.
struct SyncDeletionsIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync Immich deletions"
    static let description = IntentDescription(
        "Moves photos deleted on this iPhone to Immich's trash. Photos trashed in Immich get a notification; tap it to remove them from this iPhone.")

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
