import Foundation

/// Upload bookkeeping, written only by the extension and read by the app.
/// `uploaded` maps a Photos local identifier to its Immich asset ID: the link
/// that later two-way sync (deletes, edits) will build on.
struct UploadState: Codable {
    var uploaded: [String: String] = [:]
    /// PhotoKit job local identifier -> Photos local identifier.
    var inflight: [String: String] = [:]
    var failures: [String: Int] = [:]
    var recent: [String] = []

    static var fileURL: URL? { AppGroup.container?.appendingPathComponent("state.json") }

    static func load() -> UploadState {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(UploadState.self, from: data) else { return UploadState() }
        return state
    }

    func save() {
        guard let url = Self.fileURL, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }

    mutating func note(_ line: String) {
        recent.insert("\(ISO8601DateFormatter().string(from: Date())) \(line)", at: 0)
        if recent.count > 50 { recent.removeLast(recent.count - 50) }
    }
}
