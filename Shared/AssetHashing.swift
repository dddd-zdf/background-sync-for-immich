import CryptoKit
import Foundation
import Photos

/// Reads PhotoKit resources for hashing (both targets).
enum AssetHashing {
    /// "original" when the asset has no edits, else a hash of its adjustment data. nil if unreadable.
    /// Used to tell real edits apart from other modificationDate changes (favorites, albums, analysis).
    static func editFingerprint(of asset: PHAsset) async -> String? {
        guard let adjustment = PHAssetResource.assetResources(for: asset).first(where: { $0.type == .adjustmentData }) else {
            return "original"
        }
        let hasher = StreamHasher<SHA256>()
        guard await read(adjustment, into: hasher) else { return nil }
        return hasher.digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Base64 SHA1 of the resource's bytes: the same value as Immich's `checksum`.
    static func sha1(of resource: PHAssetResource) async -> String? {
        let hasher = StreamHasher<Insecure.SHA1>()
        guard await read(resource, into: hasher) else { return nil }
        return Data(hasher.digest).base64EncodedString()
    }

    private static func read<H>(_ resource: PHAssetResource, into hasher: StreamHasher<H>) async -> Bool {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            _ = PHAssetResourceManager.default().requestData(for: resource, options: options,
                dataReceivedHandler: { hasher.update($0) },
                completionHandler: { continuation.resume(returning: $0 == nil) })
        }
    }

    final class StreamHasher<H: HashFunction>: @unchecked Sendable {
        private let lock = NSLock()
        private var function = H()
        func update(_ data: Data) { lock.withLock { function.update(data: data) } }
        var digest: [UInt8] { lock.withLock { Array(function.finalize()) } }
    }
}
