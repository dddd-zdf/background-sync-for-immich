import Foundation

/// Two-way delete sync bookkeeping, written only by the app (the extension reads `links`).
/// `links` covers photos that reached Immich some other way (the library migrated with the
/// official Immich app), matched by name/time and confirmed by SHA1. Photos this app uploaded
/// are in `UploadState.uploaded` instead.
struct SyncStore: Codable {
    struct Link: Codable {
        var immichID: String
        /// Edit baseline when linked, so the extension can spot later edits.
        var version: UploadState.Version?
    }

    struct Pending: Codable {
        var immichID: String
        var file: String
        /// A Live Photo's video: Immich doesn't trash it along with the still.
        var videoID: String?
    }

    var links: [String: Link] = [:]
    /// Photos with no Immich match: Photos ID -> modificationDate when checked (rechecked if it changes).
    var unmatched: [String: Date] = [:]
    /// Deleted from the iPhone and handled; ignored from now on (their old entries in UploadState stay).
    var gone: Set<String> = []
    /// Trashed in Immich, waiting to be deleted from the iPhone (needs the user's OK in iOS's prompt).
    var pendingRemoval: [String: Pending] = [:]
    /// Missing from the iPhone but too many at once to trash in Immich without asking.
    var heldTrash: [String: Pending] = [:]
    var lastSync: Date?
    var lastResult = ""

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        links = try c.decodeIfPresent([String: Link].self, forKey: .links) ?? [:]
        unmatched = try c.decodeIfPresent([String: Date].self, forKey: .unmatched) ?? [:]
        gone = try c.decodeIfPresent(Set<String>.self, forKey: .gone) ?? []
        pendingRemoval = try c.decodeIfPresent([String: Pending].self, forKey: .pendingRemoval) ?? [:]
        heldTrash = try c.decodeIfPresent([String: Pending].self, forKey: .heldTrash) ?? [:]
        lastSync = try c.decodeIfPresent(Date.self, forKey: .lastSync)
        lastResult = try c.decodeIfPresent(String.self, forKey: .lastResult) ?? ""
    }

    static var fileURL: URL? { AppGroup.container?.appendingPathComponent("sync.json") }

    static func load() -> SyncStore {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let store = try? JSONDecoder().decode(SyncStore.self, from: data) else { return SyncStore() }
        return store
    }

    func save() {
        guard let url = Self.fileURL, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// The photo is deleted from the iPhone and its Immich asset trashed: stop tracking it.
    mutating func markGone(_ id: String) {
        gone.insert(id)
        links[id] = nil
        unmatched[id] = nil
        pendingRemoval[id] = nil
        heldTrash[id] = nil
    }

    /// The Immich asset that currently stands for this photo: this app's upload wins over a link.
    func immichID(for id: String, _ state: UploadState) -> String? {
        if gone.contains(id) { return nil }
        return state.uploaded[id] ?? links[id]?.immichID
    }
}
