import Foundation
import Photos

enum Diagnostics {
    struct Snapshot {
        var appGroup = AppGroup.identifier
        var containerOK = AppGroup.container != nil
        var invocations: String = {
            guard let last = Settings.lastInvocation else { return "never" }
            return "\(Settings.invocationCount), last \(last.formatted(date: .omitted, time: .shortened))"
        }()
        var jobs: String = [PHAssetResourceUploadJob.Action.process, .retry, .acknowledge]
            .map { String(PHAssetResourceUploadJob.fetchJobs(action: $0, options: nil).count) }
            .joined(separator: " / ")
        var uploadedCount = UploadState.load().uploaded.count
        var recent = Array(UploadState.load().recent.prefix(10))
    }

    /// Checks the API key against Immich, then that the upload proxy answers PhotoKit's
    /// preflight (it must reply 501 so PhotoKit uses a plain, non-resumable upload).
    static func checkServer() async -> String {
        guard let base = URL(string: Settings.serverURL), let upload = Settings.uploadURL else { return "Invalid URL" }
        var lines: [String] = []

        var me = URLRequest(url: base.appendingPathComponent("api/users/me"))
        me.setValue(Settings.apiKey, forHTTPHeaderField: "x-api-key")
        do {
            let (data, response) = try await URLSession.shared.data(for: me)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let name = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["name"] as? String
            lines.append(code == 200 ? "Immich: signed in as \(name ?? "?")" : "Immich: HTTP \(code)")
        } catch {
            lines.append("Immich: \(error.localizedDescription)")
        }

        var preflight = URLRequest(url: upload)
        preflight.httpMethod = "OPTIONS"
        do {
            let (_, response) = try await URLSession.shared.data(for: preflight)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            lines.append(code == 501 ? "Upload proxy: ok" : "Upload proxy: HTTP \(code) (expected 501)")
        } catch {
            lines.append("Upload proxy: \(error.localizedDescription)")
        }
        return lines.joined(separator: "\n")
    }
}
