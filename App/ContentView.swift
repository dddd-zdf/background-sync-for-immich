import Photos
import SwiftUI

/// Home screen: is everything in sync, and is anything waiting for me. Everything else is in Settings.
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var model = AppModel.shared
    @ObservedObject private var sync = DeleteSync.shared
    @State private var message = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    StatusHeader(model: model, syncing: sync.running)
                        .listRowBackground(Color.clear)
                }

                if !problems.isEmpty {
                    Section {
                        ForEach(problems) { problem in
                            problem.row
                        }
                    }
                }

                if !sync.store.pendingRemoval.isEmpty {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(sync.store.pendingRemoval.count) trashed in Immich")
                                    .font(.headline)
                                Text(Self.names(sync.store.pendingRemoval))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        } icon: {
                            Image(systemName: "trash").foregroundStyle(.red)
                        }
                        Button(role: .destructive) {
                            Task { message = await sync.removePendingFromPhone(); model.refresh() }
                        } label: {
                            Text("Delete from iPhone").frame(maxWidth: .infinity)
                        }
                        .disabled(sync.running)
                    } footer: {
                        Text("iOS asks first. They stay in Recently Deleted for 30 days.")
                    }
                }

                if !sync.store.heldTrash.isEmpty {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(sync.store.heldTrash.count) gone from iPhone").font(.headline)
                                Text(Self.names(sync.store.heldTrash))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        } icon: {
                            Image(systemName: "questionmark.circle").foregroundStyle(.orange)
                        }
                        Button(role: .destructive) {
                            Task { message = await sync.trashHeld(); model.refresh() }
                        } label: {
                            Text("Move to Immich's trash").frame(maxWidth: .infinity)
                        }
                        .disabled(sync.running)
                    } footer: {
                        Text("Held back: more than \(Settings.bulkTrashLimit) disappeared at once, so it waits for you.")
                    }
                }

                Section {
                    row("On Immich", "\(model.onImmich)", icon: "photo.on.rectangle")
                    row("Waiting to upload", model.waiting.map(String.init) ?? "…", icon: "clock")
                    row("Last checked Immich", sync.store.lastSync.map(Self.relative) ?? "never", icon: "arrow.triangle.2.circlepath")
                } footer: {
                    if sync.running {
                        Text(sync.progress)
                    } else if !message.isEmpty {
                        Text(message)
                    }
                }
            }
            .navigationTitle("Immich Sync")
            .toolbar {
                NavigationLink {
                    SettingsView()
                } label: {
                    Image(systemName: "gearshape")
                }
            }
            .refreshable {
                model.refresh()
                message = await sync.run(linkBudget: nil)
                model.refresh()
            }
            .onAppear { model.refresh(); autoSync() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.refresh(); autoSync(); removeIfRequested() }
            }
            .onChange(of: sync.removalRequested) { _, _ in removeIfRequested() }
        }
    }

    private func row(_ title: String, _ value: String, icon: String) -> some View {
        LabeledContent {
            Text(value)
        } label: {
            Label(title, systemImage: icon)
        }
    }

    private var problems: [Problem] {
        var list: [Problem] = []
        if model.photosStatus != .authorized {
            list.append(Problem(id: "photos", text: "Needs full access to Photos", icon: "photo") {
                Button("Allow") { Task { await model.requestPhotosAccess() } }
            })
        }
        if !model.hasServer {
            list.append(Problem(id: "server", text: "Add your Immich server", icon: "server.rack") {
                NavigationLink("Set up") { SettingsView() }
            })
        }
        if model.photosStatus == .authorized && !model.extensionEnabled {
            list.append(Problem(id: "ext", text: "Background upload is off", icon: "pause.circle") {
                Button("Turn on") { model.setExtension(true) }
            })
        }
        if !model.snapshot.state.failed.isEmpty {
            list.append(Problem(id: "failed", text: "\(model.snapshot.state.failed.count) failed to upload", icon: "exclamationmark.triangle") {
                NavigationLink("See why") { FailuresView(failures: model.snapshot.failures, retry: model.retryFailed) }
            })
        }
        return list
    }

    /// From the notification: iOS's delete prompt needs the app in the foreground.
    private func removeIfRequested() {
        guard sync.removalRequested, scenePhase == .active else { return }
        sync.removalRequested = false
        Task { message = await sync.removePendingFromPhone(); model.refresh() }
    }

    /// Checks Immich on open, at most every 15 minutes.
    private func autoSync() {
        guard !sync.running, !sync.removalRequested, model.photosStatus == .authorized, model.hasServer,
              (sync.store.lastSync ?? .distantPast) < Date().addingTimeInterval(-900) else { return }
        Task { await sync.run(linkBudget: nil); model.refresh() }
    }

    static func names(_ items: [String: SyncStore.Pending]) -> String {
        let names = items.values.map(\.file).sorted()
        return names.prefix(6).joined(separator: ", ") + (names.count > 6 ? " and \(names.count - 6) more" : "")
    }

    static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }
}

/// The big "In sync" / "Syncing" header.
private struct StatusHeader: View {
    @ObservedObject var model: AppModel
    let syncing: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 54, weight: .regular))
                .foregroundStyle(color)
                .symbolEffect(.pulse, isActive: busy)
                .frame(height: 64)
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var state: UploadState { model.snapshot.state }
    private var off: Bool { !model.autoOn || !model.extensionEnabled || !model.hasServer || model.photosStatus != .authorized }
    private var busy: Bool { !off && (!state.inflight.isEmpty || syncing) }

    private var symbol: String {
        if off { return "icloud.slash" }
        if !state.inflight.isEmpty || (model.waiting ?? 0) > 0 { return "arrow.up.circle" }
        return "checkmark.icloud"
    }

    private var color: Color {
        if off { return .orange }
        if !state.inflight.isEmpty || (model.waiting ?? 0) > 0 { return .accentColor }
        return .green
    }

    private var title: String {
        if off { return "Sync is off" }
        if !state.inflight.isEmpty { return "Syncing \(state.inflight.count)" }
        if let waiting = model.waiting, waiting > 0 { return "\(waiting) to upload" }
        return "In sync"
    }

    private var subtitle: String {
        if off && !model.autoOn { return "Turn on Upload new photos in Settings." }
        guard let last = state.lastUpload else { return "Nothing uploaded yet." }
        return "Last upload \(ContentView.relative(last))"
    }
}

private struct Problem: Identifiable {
    let id: String
    let text: String
    let icon: String
    let action: AnyView

    init<A: View>(id: String, text: String, icon: String, @ViewBuilder action: () -> A) {
        self.id = id
        self.text = text
        self.icon = icon
        self.action = AnyView(action())
    }

    var row: some View {
        HStack {
            Label(text, systemImage: icon).foregroundStyle(.orange)
            Spacer()
            action.buttonStyle(.borderless)
        }
    }
}
