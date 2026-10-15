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
            } header: {
                Text("Upload")
            } footer: {
                Text("Uploads every photo on this iPhone that isn't in Immich yet: new ones right away, older ones once the library check finds them missing. Edited photos replace their old version in Immich.")
            }

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
                Text("API key permissions: asset.upload, asset.read, asset.copy, asset.delete, user.read.")
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

    private func saveAndCheck() async {
        Settings.serverURL = serverURL
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
