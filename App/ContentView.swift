import Photos
import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var serverURL = Settings.serverURL
    @State private var apiKey = Settings.apiKey
    @State private var serverCheck = ""
    @State private var photosStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var extensionEnabled = PHPhotoLibrary.shared().uploadJobExtensionEnabled
    @State private var extensionError = ""
    @State private var autoOn = Settings.autoSince != nil
    @State private var since = Settings.autoSince ?? Date()
    @State private var wifiOnly = Settings.wifiOnly
    @State private var snapshot = Diagnostics.Snapshot()
    @State private var waiting: Int?

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    LabeledContent("Last upload", value: snapshot.state.lastUpload?.formatted(date: .abbreviated, time: .shortened) ?? "none yet")
                    LabeledContent("Uploading", value: "\(snapshot.state.inflight.count)")
                    LabeledContent("Waiting", value: waiting.map(String.init) ?? "counting...")
                    LabeledContent("Backed up", value: "\(snapshot.state.uploaded.count)")
                    if snapshot.state.failed.isEmpty {
                        LabeledContent("Failed", value: "0")
                    } else {
                        NavigationLink {
                            FailuresView(failures: snapshot.failures, retry: retryFailed)
                        } label: {
                            LabeledContent("Failed", value: "\(snapshot.state.failed.count)")
                                .foregroundStyle(.red)
                        }
                    }
                    if !extensionEnabled {
                        Text("The upload extension is off, so nothing uploads.").font(.footnote).foregroundStyle(.red)
                    }
                }

                Section {
                    Toggle("Back up automatically", isOn: Binding(
                        get: { autoOn },
                        set: { on in
                            autoOn = on
                            Settings.autoSince = on ? (Settings.autoSince ?? Date()) : nil
                            since = Settings.autoSince ?? Date()
                            SharedLog.write("app", "auto backup \(on ? "on since \(since)" : "off")")
                            refresh()
                        }))
                    if autoOn {
                        DatePicker("Photos taken since", selection: Binding(
                            get: { since },
                            set: { date in
                                since = date
                                Settings.autoSince = date
                                SharedLog.write("app", "backup start date \(date)")
                                wakeExtension()
                            }), in: ...Date())
                    }
                    Toggle("Wi-Fi only", isOn: Binding(
                        get: { wifiOnly },
                        set: { on in
                            wifiOnly = on
                            Settings.wifiOnly = on
                            SharedLog.write("app", "wifi only \(on)")
                        }))
                } header: {
                    Text("Backup")
                } footer: {
                    Text("""
                    Backup starts from when you turned it on. Pick an earlier date to back up older photos too. \
                    Immich skips photos it already has, but each one is still sent in full first, so a big backlog \
                    uses a lot of data (turn on Wi-Fi only). Edited photos replace their old version in Immich \
                    (the old one goes to Immich's trash). Wi-Fi only applies to uploads queued after you change it.
                    """)
                }

                Section {
                    TextField("https://photos.example.com", text: $serverURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Immich API key", text: $apiKey)
                    Button("Save and check") { Task { await saveAndCheck() } }
                    if !serverCheck.isEmpty { Text(serverCheck).font(.footnote) }
                } header: {
                    Text("Server")
                } footer: {
                    Text("API key permissions: asset.upload, user.read, plus asset.copy and asset.delete (used to replace edited photos).")
                }

                Section {
                    LabeledContent("Photos access", value: photosStatus.label)
                    if photosStatus != .authorized {
                        Button("Allow full access") {
                            Task {
                                photosStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                            }
                        }
                    }
                    Toggle("Background upload extension", isOn: Binding(
                        get: { extensionEnabled }, set: { setExtension($0) }))
                        .disabled(photosStatus != .authorized)
                    if !extensionError.isEmpty { Text(extensionError).font(.footnote).foregroundStyle(.red) }
                    Button("Upload newest photo (test)") {
                        Settings.testUploadRequested = true
                        SharedLog.write("app", "test upload requested")
                        wakeExtension()
                    }
                    .disabled(!extensionEnabled)
                } header: {
                    Text("Setup")
                } footer: {
                    Text("iOS decides when the extension runs, usually within minutes on Wi-Fi.")
                }

                Section("Diagnostics") {
                    LabeledContent("App group", value: snapshot.appGroup)
                    LabeledContent("Group container", value: snapshot.containerOK ? "ok" : "MISSING")
                    LabeledContent("Extension runs", value: snapshot.invocations)
                    LabeledContent("Jobs (process/retry/ack)", value: snapshot.jobs)
                    if Settings.testUploadRequested { Text("Test upload waiting for the extension to run").font(.footnote) }
                    ForEach(snapshot.state.recent.prefix(10), id: \.self) { Text($0).font(.caption2.monospaced()) }
                    NavigationLink("Log") { LogView() }
                }
            }
            .navigationTitle("Immich Backup")
            .refreshable { refresh() }
            .onAppear(perform: refresh)
            .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
        }
    }

    private func refresh() {
        photosStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        extensionEnabled = PHPhotoLibrary.shared().uploadJobExtensionEnabled
        snapshot = Diagnostics.Snapshot()
        let state = snapshot.state
        Task.detached(priority: .utility) {
            let count = Diagnostics.waitingCount(state)
            await MainActor.run { waiting = count }
        }
    }

    private func retryFailed() {
        Settings.retryFailedRequested = true
        SharedLog.write("app", "retry failed requested")
        wakeExtension()
    }

    /// After the extension reports .completed, iOS only wakes it on a photo library change;
    /// a settings change isn't one. Re-enabling it makes iOS run it right away.
    private func wakeExtension() {
        guard extensionEnabled else { refresh(); return }
        setExtension(false)
        setExtension(true)
    }

    private func setExtension(_ on: Bool) {
        let library = PHPhotoLibrary.shared()
        do {
            // Enabling twice throws (PHPhotosErrorDomain 3202), so only call on a real change.
            if on && !library.uploadJobExtensionEnabled {
                try library.enableUploadJobExtension(with: PHAssetResourceUploadJobOptions())
            } else if !on && library.uploadJobExtensionEnabled {
                try library.disableUploadJobExtension()
            }
            extensionError = ""
            SharedLog.write("app", "extension enabled = \(library.uploadJobExtensionEnabled)")
        } catch {
            let ns = error as NSError
            extensionError = "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
            SharedLog.write("app", "enable/disable extension (\(on)) failed: \(extensionError) \(ns.userInfo)")
        }
        refresh()
    }

    private func saveAndCheck() async {
        Settings.serverURL = serverURL
        Settings.apiKey = apiKey
        serverCheck = await Diagnostics.checkServer()
        SharedLog.write("app", "server check: \(serverCheck)")
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

extension PHAuthorizationStatus {
    var label: String {
        switch self {
        case .authorized: "Full access"
        case .limited: "Limited (needs full)"
        case .denied: "Denied (change in Settings)"
        case .restricted: "Restricted"
        case .notDetermined: "Not asked yet"
        @unknown default: "Unknown"
        }
    }
}
