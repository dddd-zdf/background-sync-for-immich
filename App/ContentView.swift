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
    @State private var snapshot = Diagnostics.Snapshot()

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("https://photos.example.com", text: $serverURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Immich API key", text: $apiKey)
                    Button("Save and check") { Task { await saveAndCheck() } }
                    if !serverCheck.isEmpty { Text(serverCheck).font(.footnote) }
                }

                Section("Photos access") {
                    LabeledContent("Status", value: photosStatus.label)
                    if photosStatus != .authorized {
                        Button("Allow full access") {
                            Task {
                                photosStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                            }
                        }
                    }
                }

                Section {
                    Toggle("Background upload extension", isOn: Binding(
                        get: { extensionEnabled }, set: { setExtension($0) }))
                        .disabled(photosStatus != .authorized)
                    if !extensionError.isEmpty { Text(extensionError).font(.footnote).foregroundStyle(.red) }
                    Toggle("Back up new photos automatically", isOn: Binding(
                        get: { autoOn },
                        set: { on in
                            autoOn = on
                            Settings.autoSince = on ? (Settings.autoSince ?? Date()) : nil
                            SharedLog.write("app", "auto backup \(on ? "on since \(Settings.autoSince!)" : "off")")
                        }))
                    Button("Upload newest photo (test)") {
                        Settings.testUploadRequested = true
                        SharedLog.write("app", "test upload requested")
                        refresh()
                    }
                    .disabled(!extensionEnabled)
                } header: {
                    Text("Background upload")
                } footer: {
                    Text("iOS decides when the extension runs, usually within minutes on Wi-Fi. Automatic backup covers photos taken after you turn it on.")
                }

                Section("Status") {
                    LabeledContent("App group", value: snapshot.appGroup)
                    LabeledContent("Group container", value: snapshot.containerOK ? "ok" : "MISSING")
                    LabeledContent("Extension runs", value: snapshot.invocations)
                    LabeledContent("Jobs (process/retry/ack)", value: snapshot.jobs)
                    LabeledContent("Uploaded", value: "\(snapshot.uploadedCount)")
                    if Settings.testUploadRequested { Text("Test upload waiting for the extension to run").font(.footnote) }
                    ForEach(snapshot.recent, id: \.self) { Text($0).font(.caption2.monospaced()) }
                }

                Section {
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
