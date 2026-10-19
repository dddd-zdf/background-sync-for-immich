import CryptoKit
import Foundation

/// Signing in with an Immich account instead of pasting an API key: log in (email and password, or
/// the server's OAuth), create an API key with exactly the permissions the app needs, then end that
/// login session so only the key remains. The password and session token are never stored.
enum ImmichAuth {
    struct Server {
        /// Normalized address, e.g. https://photos.example.com
        let url: String
        let passwordLogin: Bool
        let oauth: Bool
        let oauthButton: String
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// What Immich's own app uses; servers with OAuth already allow it as a redirect.
    static let oauthRedirect = "app.immich:///oauth-callback"
    static let oauthScheme = "app.immich"

    /// Checks there's an Immich server at `input` and which ways to sign in it offers.
    static func probe(_ input: String) async throws -> Server {
        let url = Settings.normalized(input)
        guard let base = URL(string: url), base.host != nil else {
            throw Failure(message: "That doesn't look like a web address.")
        }
        let ping: [String: Any]
        do {
            ping = try await call("GET", base, "api/server/ping").json
        } catch {
            throw Failure(message: "Couldn't reach \(url): \(error.localizedDescription)")
        }
        guard ping["res"] as? String == "pong" else { throw Failure(message: "No Immich server answered at \(url).") }
        let features = (try? await call("GET", base, "api/server/features").json) ?? [:]
        let config = (try? await call("GET", base, "api/server/config").json) ?? [:]
        let button = (config["oauthButtonText"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Sign in with OAuth"
        return Server(url: url, passwordLogin: features["passwordLogin"] as? Bool ?? true,
                      oauth: features["oauth"] as? Bool ?? false, oauthButton: button)
    }

    /// Email and password: returns a session token.
    static func login(_ server: Server, email: String, password: String) async throws -> String {
        let (status, json) = try await call("POST", base(server), "api/auth/login",
                                            body: ["email": email.trimmingCharacters(in: .whitespaces), "password": password])
        guard status == 201 || status == 200, let token = json["accessToken"] as? String else {
            throw Failure(message: status == 401 ? "Wrong email or password." : "Sign-in failed: \(describe(status, json))")
        }
        return token
    }

    struct OAuthStart {
        let url: URL
        let state: String
        let verifier: String
    }

    /// OAuth, step 1: the page to open (with PKCE).
    static func oauthStart(_ server: Server) async throws -> OAuthStart {
        let verifier = randomString()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = randomString()
        let (status, json) = try await call("POST", base(server), "api/oauth/authorize",
                                            body: ["redirectUri": oauthRedirect, "state": state, "codeChallenge": challenge])
        guard (200..<300).contains(status), let page = (json["url"] as? String).flatMap(URL.init(string:)) else {
            throw Failure(message: "OAuth isn't available: \(describe(status, json))")
        }
        return OAuthStart(url: page, state: state, verifier: verifier)
    }

    /// OAuth, step 2: the URL the provider sent back to `oauthRedirect`. Returns a session token.
    static func oauthFinish(_ server: Server, callback: URL, start: OAuthStart) async throws -> String {
        let (status, json) = try await call("POST", base(server), "api/oauth/callback",
                                            body: ["url": callback.absoluteString, "state": start.state, "codeVerifier": start.verifier])
        guard (200..<300).contains(status), let token = json["accessToken"] as? String else {
            throw Failure(message: "OAuth sign-in failed: \(describe(status, json))")
        }
        return token
    }

    /// Creates the app's API key with the session, then logs the session out. Saves server and key.
    /// Returns the account's name.
    @discardableResult
    static func finishSignIn(_ server: Server, token: String) async throws -> String {
        let base = base(server)
        let (status, json) = try await call("POST", base, "api/api-keys", bearer: token,
                                            body: ["name": "Background Sync for Immich (iPhone)",
                                                   "permissions": Diagnostics.requiredPermissions])
        guard (200..<300).contains(status), let secret = json["secret"] as? String else {
            throw Failure(message: "Couldn't create the app's API key: \(describe(status, json))")
        }
        let me = (try? await call("GET", base, "api/users/me", bearer: token).json) ?? [:]
        _ = try? await call("POST", base, "api/auth/logout", bearer: token)
        save(server.url, key: secret)
        SharedLog.write("app", "signed in, API key created")
        return me["name"] as? String ?? ""
    }

    /// A pasted API key: checked against Immich before it's saved.
    static func useKey(_ server: Server, key: String) async throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        var request = URLRequest(url: base(server).appendingPathComponent("api/users/me"), timeoutInterval: 20)
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw Failure(message: status == 401 ? "Immich doesn't accept that key." : "Checking the key failed: HTTP \(status)")
        }
        save(server.url, key: key)
        SharedLog.write("app", "API key saved")
    }

    private static func save(_ url: String, key: String) {
        Settings.serverURL = url
        Settings.apiKey = key
        Settings.keyRejected = false
    }

    // MARK: - HTTP

    private static func base(_ server: Server) -> URL { URL(string: server.url)! }

    @discardableResult
    private static func call(_ method: String, _ base: URL, _ path: String, bearer: String? = nil,
                             body: [String: Any]? = nil) async throws -> (status: Int, json: [String: Any]) {
        var request = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, json)
    }

    private static func describe(_ status: Int, _ json: [String: Any]) -> String {
        "HTTP \(status)" + (json["message"].map { " \($0)" } ?? "")
    }

    private static func randomString() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URL
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
