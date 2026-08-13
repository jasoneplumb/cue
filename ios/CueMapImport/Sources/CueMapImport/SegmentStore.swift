// Intent: Local segment cache (RFC 0003 D1a): the region is imported
//         once, parsed segments are cached on-device, and re-import
//         refreshes the cache. The manifest pins the source extract's
//         SHA-256 so a changed extract is detectable and a stale cache
//         is never silently mixed with new data.
// Privacy: Everything stays on-device (NFR-005) — the store writes to a
//          caller-supplied directory (the app passes Application Support).
import CryptoKit
import Foundation

public struct SegmentCacheManifest: Codable, Equatable, Sendable {
    /// Bump on any RoadSegment/manifest shape change; loads refuse
    /// unknown versions rather than misreading old caches.
    /// v2: RoadAttributes cycleway/shoulder booleans -> ridingSpace enum.
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let sourceSHA256: String
    public let segmentCount: Int
}

public enum SegmentStoreError: Error, Equatable {
    case unknownSchemaVersion(Int)
    case segmentCountMismatch(manifest: Int, actual: Int)
}

public enum SegmentStore {
    static let manifestFile = "manifest.json"
    static let segmentsFile = "segments.json"

    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Replace the cache in `directory` with `segments` parsed from an
    /// extract whose raw bytes hash to `sourceSHA256`.
    public static func save(_ segments: [RoadSegment], sourceSHA256: String,
                            to directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]  // byte-stable cache files
        let manifest = SegmentCacheManifest(
            schemaVersion: SegmentCacheManifest.currentSchemaVersion,
            sourceSHA256: sourceSHA256,
            segmentCount: segments.count)
        // Manifest deleted FIRST, rewritten LAST: a crash anywhere in
        // between leaves no manifest, so load() reports no usable cache —
        // on first writes and refreshes alike. Without the delete, a
        // refresh crash after the segments write could pair new segments
        // with the old manifest (stale sourceSHA256, and a silently
        // passing count check when counts happen to match).
        let manifestURL = directory.appendingPathComponent(manifestFile)
        try? FileManager.default.removeItem(at: manifestURL)
        try encoder.encode(segments)
            .write(to: directory.appendingPathComponent(segmentsFile), options: .atomic)
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    }

    /// Load the cache, or nil when none exists (including after an
    /// interrupted save — the manifest is absent for the whole write
    /// window). Throws on a cache that exists but cannot be trusted
    /// (schema drift, count mismatch — external tampering/corruption).
    ///
    /// Caller contract: the store cannot know whether the cache matches
    /// the extract you are ABOUT to import — when freshness matters,
    /// compare `manifest.sourceSHA256` against `sha256Hex` of the current
    /// extract bytes and re-import on mismatch.
    public static func load(from directory: URL) throws -> (SegmentCacheManifest, [RoadSegment])? {
        let manifestURL = directory.appendingPathComponent(manifestFile)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        let decoder = JSONDecoder()
        let manifest = try decoder.decode(
            SegmentCacheManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.schemaVersion == SegmentCacheManifest.currentSchemaVersion else {
            throw SegmentStoreError.unknownSchemaVersion(manifest.schemaVersion)
        }
        let segments = try decoder.decode(
            [RoadSegment].self,
            from: Data(contentsOf: directory.appendingPathComponent(segmentsFile)))
        guard segments.count == manifest.segmentCount else {
            throw SegmentStoreError.segmentCountMismatch(
                manifest: manifest.segmentCount, actual: segments.count)
        }
        return (manifest, segments)
    }
}
