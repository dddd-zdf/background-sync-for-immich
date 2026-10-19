import AuthenticationServices
import Photos
import SwiftUI

/// First run (and "Sign in again"): server address, sign in, then Photos access and background upload.
struct SetupView: View {
    /// Called when setup is complete (or, for a re-sign-in, once signed in).
    let onDone: () -> Void
    var canCancel = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @ObservedObject private var model = AppModel.shared
    @State private var address = Settings.serverURL
    @State private var server: ImmichAuth.Server?
    @State private var email = ""
    @State private var password = ""
    @State private var apiKey = ""
    @State private var useKey = false
    @State private var signedIn = false
    @State private var busy = false
    @State private var error = ""

    var body: some View {
        NavigationStack {
            Form {
                if !signedIn {
                    serverSection
                    if let server { signInSections(server) }
                } else {
                    finishSection
                }
                if !error.isEmpty {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .disabled(busy)
            .navigationTitle(signedIn ? "Almost done" : "Connect to Immich")
            .toolbar {
                if busy { ToolbarItem(placement: .topBarTrailing) { ProgressView() } }
                if canCancel {
                    ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                }
            }
        }
        .interactiveDismissDisabled(!canCancel)
    }

    private var serverSection: some View {
        Section {
            TextField("photos.example.com", text: $address)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .textContentType(.URL)
                .onSubmit { Task { await probe() } }
                .onChange(of: address) { _, _ in server = nil }
            if server == nil {
                Button("Continue") { Task { await probe() } }
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Your Immich server")
        } footer: {
            Text("The address you open Immich at. It has to work over HTTPS from wherever your iPhone is.")
        }
    }

    @ViewBuilder
    private func signInSections(_ server: ImmichAuth.Server) -> some View {
        if useKey || !(server.passwordLogin || server.oauth) {
            Section {
                SecureField("API key", text: $apiKey)
                Button("Save key") { Task { await saveKey(server) } }.disabled(apiKey.isEmpty)
            } header: {
                Text("API key")
            } footer: {
                Text("Immich: Account settings > API keys. Permissions: \(Diagnostics.requiredPermissions.joined(separator: ", ")).")
            }
            if server.passwordLogin || server.oauth {
                Button("Sign in with your account instead") { useKey = false }
            }
        } else {
            if server.passwordLogin {
                Section {
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textContentType(.username)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .onSubmit { Task { await signIn(server) } }
                    Button("Sign in") { Task { await signIn(server) } }
                        .disabled(email.isEmpty || password.isEmpty)
                } header: {
                    Text("Sign in")
                } footer: {
                    Text("Your password goes only to your server and isn't kept. The app makes its own API key, which you can see and remove in Immich under Account settings > API keys.")
                }
            }
            if server.oauth {
                Section {
                    Button(server.oauthButton) { Task { await signInWithOAuth(server) } }
                }
            }
            Section {
                Button("Use an API key instead") { useKey = true }
            }
        }
    }

    private var finishSection: some View {
        Section {
            Button("Allow access and start") { Task { await finish() } }
        } footer: {
            Text("Next, iOS asks to let the app see your photos: choose Allow Full Access. Then new photos upload on their own, even with the app closed.")
        }
    }

    // MARK: - Steps

    private func probe() async {
        await run {
            server = try await ImmichAuth.probe(address)
            address = server?.url ?? address
        }
    }

    private func signIn(_ server: ImmichAuth.Server) async {
        await run {
            let token = try await ImmichAuth.login(server, email: email, password: password)
            try await ImmichAuth.finishSignIn(server, token: token)
            password = ""
            signedInDone()
        }
    }

    private func signInWithOAuth(_ server: ImmichAuth.Server) async {
        await run {
            let start = try await ImmichAuth.oauthStart(server)
            let callback = try await webAuthenticationSession.authenticate(
                using: start.url, callbackURLScheme: ImmichAuth.oauthScheme, preferredBrowserSession: .ephemeral)
            let token = try await ImmichAuth.oauthFinish(server, callback: callback, start: start)
            try await ImmichAuth.finishSignIn(server, token: token)
            signedInDone()
        }
    }

    private func saveKey(_ server: ImmichAuth.Server) async {
        await run {
            try await ImmichAuth.useKey(server, key: apiKey)
            apiKey = ""
            signedInDone()
        }
    }

    /// Re-sign-in from an existing setup ends here; a first setup goes on to permissions.
    private func signedInDone() {
        model.refresh()
        if model.photosStatus == .authorized && model.extensionEnabled && model.autoOn {
            onDone()
        } else {
            signedIn = true
        }
    }

    private func finish() async {
        await run {
            await model.requestPhotosAccess()
            guard model.photosStatus == .authorized else {
                throw ImmichAuth.Failure(message: "The app needs full access to Photos. Change it in the iPhone's Settings > Apps > BG Sync > Photos > Full Access, then try again.")
            }
            model.setExtension(true)
            if Settings.autoSince == nil { Settings.autoSince = Date() }
            SharedLog.write("app", "setup done, upload on")
            model.refresh()
            onDone()
        }
    }

    private func run(_ step: () async throws -> Void) async {
        busy = true
        error = ""
        do {
            try await step()
        } catch let failure as ASWebAuthenticationSessionError where failure.code == .canceledLogin {
            // closed the sign-in page: nothing to say
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }
}
