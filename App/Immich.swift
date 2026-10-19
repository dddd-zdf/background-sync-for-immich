import Foundation

/// The few Immich API calls the app makes itself (uploads go through the extension).
enum Immich {
    struct Asset: Decodable {
        let id: String
        let checksum: String
        let originalFileName: String
        let fileCreatedAt: Date
        let isTrashed: Bool
        let livePhotoVideoId: String?
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Every timeline and archived asset, trashed ones included. Live Photo videos (hidden) are
    /// reached through their still's `livePhotoVideoId`; locked assets aren't visible to an API key.
    static func index() async throws -> [Asset] {
        var all: [Asset] = []
        for visibility in ["timeline", "archive"] {
            var page = 1
            while true {
                let body: [String: Any] = ["page": page, "size": 1000, "withDeleted": true, "visibility": visibility]
                let data = try await call("POST", "api/search/metadata", body)
                let response = try decoder.decode(SearchResponse.self, from: data)
                all += response.assets.items
                guard let next = response.assets.nextPage.flatMap(Int.init), next > page else { break }
                page = next
            }
        }
        return all
    }

    /// Moves assets to Immich's trash (never a permanent delete).
    static func trash(_ ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        _ = try await call("DELETE", "api/assets", ["ids": ids])
    }

    private struct SearchResponse: Decodable {
        struct Page: Decodable {
            let items: [Asset]
            let nextPage: String?
        }
        let assets: Page
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = fractional.date(from: text) ?? plain.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(text)"))
        }
        return decoder
    }()

    private static func call(_ method: String, _ path: String, _ body: [String: Any]) async throws -> Data {
        guard let base = URL(string: Settings.serverURL) else { throw Failure(message: "Invalid server URL") }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue(Settings.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { Settings.keyRejected = true }
        guard (200..<300).contains(code) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"]
            throw Failure(message: "Immich \(method) \(path): HTTP \(code) \(message.map { "\($0)" } ?? "")")
        }
        return data
    }
}
