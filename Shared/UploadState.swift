import Foundation

/// Upload bookkeeping, written only by the extension and read by the app.
/// `uploaded` maps a Photos local identifier to its Immich asset ID: the link
/// that later two-way sync (deletes) will build on.
struct UploadState: Codable {
    /// Photos ID -> Immich asset ID of the photo or video (the still, for a Live Photo).
    var uploaded: [String: String] = [:]
    /// Photos ID -> Immich asset ID of a Live Photo's video part.
    var liveVideos: [String: String] = [:]
    /// Photos ID -> version that was uploaded (modification date and edit fingerprint).
    var versions: [String: Version] = [:]
    /// Edited after upload: Photos ID -> Immich ID the new upload replaces (moved to Immich's trash).
    var replacing: [String: String] = [:]
    /// Uploaded even if already uploaded or older than the start date (the test photo).
    var requested: Set<String> = []
    /// PhotoKit job local identifier -> Photos local identifier.
    var inflight: [String: String] = [:]
    var failed: [String: Failure] = [:]
    var lastUpload: Date?
    /// Edits are looked for among assets modified after this.
    var editsCheckedUntil: Date?
    var recent: [String] = []

    struct Version: Codable, Equatable {
        var modified: Date
        var fingerprint: String
    }

    struct Failure: Codable {
        var count: Int
        var reason: String
        var file: String
        var date: Date
    }

    init() {}

    // Every key is optional so older state.json files keep loading (a failed load would
    // forget what's uploaded).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uploaded = try c.decodeIfPresent([String: String].self, forKey: .uploaded) ?? [:]
        liveVideos = try c.decodeIfPresent([String: String].self, forKey: .liveVideos) ?? [:]
        versions = try c.decodeIfPresent([String: Version].self, forKey: .versions) ?? [:]
        replacing = try c.decodeIfPresent([String: String].self, forKey: .replacing) ?? [:]
        requested = try c.decodeIfPresent(Set<String>.self, forKey: .requested) ?? []
        inflight = try c.decodeIfPresent([String: String].self, forKey: .inflight) ?? [:]
        failed = try c.decodeIfPresent([String: Failure].self, forKey: .failed) ?? [:]
        lastUpload = try c.decodeIfPresent(Date.self, forKey: .lastUpload)
        editsCheckedUntil = try c.decodeIfPresent(Date.self, forKey: .editsCheckedUntil)
        recent = try c.decodeIfPresent([String].self, forKey: .recent) ?? []
    }

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

    static let maxAttempts = 3

    func gaveUp(on id: String) -> Bool { failed[id].map { $0.count >= Self.maxAttempts } ?? false }
}
