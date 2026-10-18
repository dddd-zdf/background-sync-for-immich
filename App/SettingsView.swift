import Photos
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var model = AppModel.shared
    @ObservedObject private var sync = DeleteSync.shared
    @State private var serverURL = Settings.serverURL
    @State private var apiKey = Settings.apiKey
    @State private var serverCheck = ""
    @State private var checking = false
    @State private var autoOn = Settings.autoSince != nil
    @State private var wifiOnly = Settings.wifiOnly
    @State private var includeVideos = Settings.includeVideos
    @State private var skipScreenshots = Settings.skipScreenshots
    @State private var uploadOlder = Settings.uploadOlder
    @State private var editMode = Settings.editMode
    @State private var phoneDeletes = Settings.syncPhoneDeletes
    @State private var immichDeletes = Settings.syncImmichDeletes
    @State private var bulkLimit = Settings.bulkTrashLimit
    @State private var askOn = Settings.askEnabled
    @State private var askEvery = Settings.askEveryDays
    @State private var askTime = Calendar.current.date(
        from: DateComponents(hour: Settings.askHour, minute: Settings.askMinute)) ?? Date()
    @FocusState private var daysFocused: Bool

    var body: some View {
        Form {
            Section {
                Toggle("Upload new photos", isOn: Binding(
                    get: { autoOn },
                    set: { on in
                        autoOn = on
                        Settings.autoSince = on ? (Settings.autoSince ?? Date()) : nil
                        SharedLog.write("app", "upload \(on ? "on" : "off")")
                        model.refresh()
                    }))
                Toggle("Wi-Fi only", isOn: Binding(
                    get: { wifiOnly },
                    set: { on in
                        wifiOnly = on
                        Settings.wifiOnly = on
                        SharedLog.write("app", "wifi only \(on)")
                    }))
                toggle("Videos", $includeVideos) { Settings.includeVideos = $0 }
                toggle("Screenshots", Binding(get: { !skipScreenshots }, set: { skipScreenshots = !$0 })) {
                    Settings.skipScreenshots = !$0
                }
                toggle("Older photos", $uploadOlder) { Settings.uploadOlder = $0 }
            } header: {
                Text("Upload")
            } footer: {
                Text("Uploads every photo on this iPhone that isn't in Immich yet: new ones right away. With Older photos, also those from before upload was turned on that the library check finds missing. Live Photos always keep their video.")
            }

            Section {
                Picker("Edited photos", selection: Binding(
                    get: { editMode },
                    set: { mode in
                        editMode = mode
                        Settings.editMode = mode
                        SharedLog.write("app", "edits: \(mode.rawValue)")
                    })) {
                    ForEach(Settings.EditMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Edits")
            } footer: {
                switch editMode {
                case .stack: Text("Like Photos: Immich shows the edit, with the untouched original stacked under it. Revert in Photos brings the original back.")
                case .latest: Text("Immich keeps only the current version; each edit replaces the last one (albums and favorites move over). Applies to new edits.")
                case .ignore: Text("A photo uploads as it is when first uploaded; edits after that stay on this iPhone.")
                }
            }

            Section {
                toggle("Deleted on iPhone: trash in Immich", $phoneDeletes) { Settings.syncPhoneDeletes = $0 }
                if phoneDeletes {
                    Stepper("Ask first if over \(bulkLimit)", value: Binding(
                        get: { bulkLimit },
                        set: { bulkLimit = $0; Settings.bulkTrashLimit = $0 }), in: 0...500, step: 5)
                }
                toggle("Trashed in Immich: delete from iPhone", Binding(
                    get: { immichDeletes },
                    set: { on in
                        immichDeletes = on
                        Task { _ = await sync.run(linkBudget: 0); model.refresh() }  // empties or refills the list
                    })) { Settings.syncImmichDeletes = $0 }
            } header: {
                Text("Delete sync")
            } footer: {
                Text("Turn both off for a backup that never deletes. Deletes made while a direction is off are never synced. Immich's trash keeps photos 30 days; Recently Deleted on the iPhone too.")
            }

            if immichDeletes {
            Section {
                Toggle("Ask to delete", isOn: Binding(
                    get: { askOn },
                    set: { on in
                        askOn = on
                        Settings.askEnabled = on
                        SharedLog.write("app", "ask to delete \(on ? "on" : "off")")
                        Task { await sync.replanAskNotification() }
                    }))
                if askOn {
                    HStack {
                        Text("Every")
                        Spacer()
                        TextField("7", value: $askEvery, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                            .focused($daysFocused)
                        Text(askEvery == 1 ? "day" : "days").foregroundStyle(.secondary)
                    }
                    .onChange(of: askEvery) { _, days in
                        let clamped = min(max(days, 1), 365)
                        if clamped != days { askEvery = clamped; return }
                        Settings.askEveryDays = clamped
                        SharedLog.write("app", "ask to delete every \(clamped) days")
                        Task { await sync.replanAskNotification() }
                    }
                    DatePicker("At", selection: Binding(
                        get: { askTime },
                        set: { time in
                            askTime = time
                            let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
                            Settings.askHour = parts.hour ?? 19
                            Settings.askMinute = parts.minute ?? 0
                            Task { await sync.replanAskNotification() }
                        }), displayedComponents: .hourAndMinute)
                }
                Button {
                    Task { _ = await sync.run(linkBudget: nil); model.refresh() }
                } label: {
                    HStack {
                        Text("Check Immich now")
                        Spacer()
                        if sync.running { ProgressView() }
                    }
                }
                .disabled(sync.running)
            } header: {
                Text("Deletes")
            } footer: {
                Text("""
                Deleted on this iPhone goes to Immich's trash. Trashed in Immich gets a notification while it waits \
                (nothing when there's nothing to delete); tapping it goes straight to the delete prompt. \
                For a daily check: Shortcuts > Automation > Time of Day > "Sync Immich deletions" > Run Immediately.
                """)
            }
            }

            Section {
                TextField("https://photos.example.com", text: $serverURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("API key", text: $apiKey)
                Button {
                    Task { await saveAndCheck() }
                } label: {
                    HStack {
                        Text("Save and check")
                        Spacer()
                        if checking { ProgressView() }
                    }
                }
                if !serverCheck.isEmpty { Text(serverCheck).font(.footnote).foregroundStyle(.secondary) }
            } header: {
                Text("Immich server")
            } footer: {
                Text("API key permissions: \(Diagnostics.requiredPermissions.joined(separator: ", ")).")
            }

            Section("Permissions") {
                LabeledContent("Photos", value: model.photosStatus.label)
                if model.photosStatus != .authorized {
                    Button("Allow full access") { Task { await model.requestPhotosAccess() } }
                }
                Toggle("Background upload", isOn: Binding(
                    get: { model.extensionEnabled }, set: { model.setExtension($0) }))
                    .disabled(model.photosStatus != .authorized)
                if !model.extensionError.isEmpty {
                    Text(model.extensionError).font(.footnote).foregroundStyle(.red)
                }
            }

            Section {
                NavigationLink("Advanced") { DiagnosticsView() }
            } footer: {
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
            }
        }
        .navigationTitle("Settings")
        .toolbar {
            // The number pad has no return key.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { daysFocused = false }
            }
        }
    }

    /// A toggle that saves to Settings and logs the change.
    private func toggle(_ title: String, _ value: Binding<Bool>, save: @escaping (Bool) -> Void) -> some View {
        Toggle(title, isOn: Binding(
            get: { value.wrappedValue },
            set: { on in
                value.wrappedValue = on
                save(on)
                SharedLog.write("app", "\(title): \(on ? "on" : "off")")
            }))
    }

    private func saveAndCheck() async {
        Settings.serverURL = serverURL
        serverURL = Settings.serverURL  // shows the cleaned-up form
        Settings.apiKey = apiKey
        checking = true
        serverCheck = await Diagnostics.checkServer()
        checking = false
        SharedLog.write("app", "server check: \(serverCheck)")
        model.refresh()
    }
}

struct DiagnosticsView: View {
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        List {
            Section("Extension") {
                LabeledContent("Runs", value: model.snapshot.invocations)
                LabeledContent("Jobs (process / retry / ack)", value: model.snapshot.jobs)
                LabeledContent("App group", value: model.snapshot.appGroup)
                LabeledContent("Group container", value: model.snapshot.containerOK ? "ok" : "MISSING")
                Button("Upload newest photo (test)") {
                    Settings.testUploadRequested = true
                    SharedLog.write("app", "test upload requested")
                    model.wakeExtension()
                }
                .disabled(!model.extensionEnabled)
                if Settings.testUploadRequested {
                    Text("Waiting for the extension to run").font(.footnote).foregroundStyle(.secondary)
                }
                if Settings.editMode == .stack {
                Button("Keep originals of edited photos") {
                    Settings.keepOriginalsRequested = true
                    SharedLog.write("app", "keep originals requested")
                    model.wakeExtension()
                }
                .disabled(!model.extensionEnabled)
                if Settings.keepOriginalsRequested {
                    Text("Waiting for the extension to run").font(.footnote).foregroundStyle(.secondary)
                }
                }
            }
            Section("Recent") {
                ForEach(model.snapshot.state.recent.prefix(15), id: \.self) {
                    Text($0).font(.caption2.monospaced())
                }
            }
            Section {
                NavigationLink("Log") { LogView() }
            }
        }
        .navigationTitle("Advanced")
        .refreshable { model.refresh() }
    }
}

struct FailuresView: View {
    let failures: [Diagnostics.FailureItem]
    let retry: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                ForEach(failures) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.failure.file).font(.subheadline)
                        Text(item.failure.reason).font(.caption).foregroundStyle(.red)
                        Text("\(item.failure.count) of \(UploadState.maxAttempts) tries, last \(item.failure.date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("After \(UploadState.maxAttempts) tries a photo is skipped until you retry.")
            }
            Button("Retry all") { retry(); dismiss() }
        }
        .navigationTitle("Failed uploads")
    }
}

struct LogView: View {
    @State private var text = SharedLog.read()

    var body: some View {
        ScrollView {
            Text(text).font(.caption2.monospaced()).textSelection(.enabled).padding()
        }
        .navigationTitle("Log")
        .toolbar {
            ShareLink(item: text)
            Button("Clear") { SharedLog.clear(); text = SharedLog.read() }
        }
        .refreshable { text = SharedLog.read() }
    }
}
