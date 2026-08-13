// Intent: Derive road segments with STABLE ids from a validated extract
//         (RFC 0003 D1a). Traces, markers, reviews, and the RFC 0002
//         memory store all key on segment_id, so ids are content-derived
//         from (osm_way_id, split_sequence): re-importing the same region
//         yields identical ids; upstream OSM edits change a way's ids and
//         any memory keyed to the old ids reverts to neutral — the
//         conservative failure direction (NFR-001, RFC 0002 eviction).
// Context: RFC 0003 D1 prefers a REVERSIBLE encoding over a hash, but
//          reversible is arithmetically unavailable: OSM way ids already
//          exceed 2^30, so even two split-sequence bits overflow uint32.
//          The RFC's fallback therefore applies: a 64-bit mix folded to
//          32 bits, a computed 0 remapped to a fixed non-zero constant,
//          and a whole-region collision audit that fails the import
//          loudly rather than silently merging two segments' histories.
import Foundation

/// What the map says about dedicated rider operating space (§7 bit 1).
/// Tag PRESENCE is not evidence of infrastructure: `cycleway=no` and
/// `shoulder=no` are explicit statements that space is ABSENT — stronger
/// squeeze evidence than an untagged road, not weaker.
public enum RidingSpaceEvidence: String, Codable, Sendable {
    /// Any cycleway/shoulder value indicating usable rider space.
    case dedicatedSpace
    /// Tagged, and every tag says no space (`no`/`none`).
    case explicitNone
    /// No cycleway/shoulder tags at all — meaning depends on how
    /// systematically the road class is tagged in this region (obs00004).
    case untagged
}

/// The §7 evidence the D1b scorer consumes, parsed once at import time.
public struct RoadAttributes: Codable, Equatable, Sendable {
    public let highway: String
    public let name: String?
    public let lanes: Int?
    public let maxspeedMph: Int?
    public let ridingSpace: RidingSpaceEvidence
    public let widthTag: String?

    init(tags: [String: String]) {
        highway = tags["highway"] ?? ""
        name = tags["name"]
        lanes = tags["lanes"].flatMap { Int($0) }
        maxspeedMph = Self.parseMaxspeedMph(tags["maxspeed"])
        ridingSpace = Self.parseRidingSpace(tags)
        widthTag = tags["width"] ?? tags["est_width"]
    }

    static func parseRidingSpace(_ tags: [String: String]) -> RidingSpaceEvidence {
        let negatives: Set<String> = ["no", "none"]
        var sawExplicitNone = false
        for (key, value) in tags
        where key == "cycleway" || key.hasPrefix("cycleway:")
            || key == "shoulder" || key.hasPrefix("shoulder:") {
            if negatives.contains(value) {
                sawExplicitNone = true
            } else {
                // Any positive value wins regardless of dictionary order:
                // one real lane/track/shoulder means space exists.
                return .dedicatedSpace
            }
        }
        return sawExplicitNone ? .explicitNone : .untagged
    }

    /// OSM bare numbers default to km/h per spec; "mph" is explicit (US/UK).
    /// Mirrors tools/d6_gpx_sim.py so desk sims and the app agree.
    static func parseMaxspeedMph(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let parts = raw.split(separator: " ")
        guard let first = parts.first, let value = Int(first) else { return nil }
        if parts.count >= 2, parts[1].lowercased() == "mph" { return value }
        return Int((Double(value) / 1.60934).rounded())
    }
}

/// One matchable stretch of road: the unit segment_id refers to across
/// the kernel, traces, markers, and personal route memory.
public struct RoadSegment: Codable, Equatable, Sendable {
    public let id: UInt32
    public let osmWayID: Int64
    public let splitSequence: UInt16
    /// Node ids parallel to the polyline — the D2 matcher's graph edges.
    public let nodeIDs: [Int64]
    /// Kernel-unit coordinates (degrees * 1e7), parallel to `nodeIDs`.
    public let latE7: [Int32]
    public let lonE7: [Int32]
    public let lengthM: Double
    public let attributes: RoadAttributes
}

public enum SegmentImportError: Error, Equatable {
    /// Two distinct (way, split) pairs folded to one uint32 — the import
    /// must fail loudly, never silently merge two segments' histories.
    case idCollision(id: UInt32, a: String, b: String)
    /// A single way needed more splits than the id space encodes.
    case tooManySplits(osmWayID: Int64)
}

public enum SegmentImporter {
    /// Max node-aligned segment length — a SOFT cap: splits happen only at
    /// nodes, so a single edge longer than this becomes one over-cap
    /// segment (routine on rural roads with sparse nodes). The cap keeps
    /// typical segments well inside int16 distance fields and gives
    /// markers/matching (RFC 0002 §9 approach windows are 25–100 m) a
    /// useful granularity; a rare 800 m edge still fits int16 fine.
    public static let maxSegmentLengthM = 250.0

    /// Split sequence occupies 10 bits of the id-derivation key.
    static let maxSplitsPerWay = 1 << 10

    /// Fixed remap for a computed id of 0 (0 is reserved — RFC 0002 D5).
    static let zeroRemapID: UInt32 = 0xFFFF_FFFF

    public static func deriveSegments(from extract: OverpassExtract) throws -> [RoadSegment] {
        var segments: [RoadSegment] = []
        var owners: [UInt32: (Int64, UInt16)] = [:]
        for way in extract.ways {
            let attributes = RoadAttributes(tags: way.tags)
            for (sequence, range) in splitRanges(for: way).enumerated() {
                guard sequence < maxSplitsPerWay else {
                    throw SegmentImportError.tooManySplits(osmWayID: way.id)
                }
                let id = segmentID(osmWayID: way.id, splitSequence: UInt16(sequence))
                if let prior = owners[id], prior != (way.id, UInt16(sequence)) {
                    throw SegmentImportError.idCollision(
                        id: id,
                        a: "way \(prior.0) seq \(prior.1)",
                        b: "way \(way.id) seq \(sequence)")
                }
                owners[id] = (way.id, UInt16(sequence))
                let nodes = Array(way.nodes[range])
                let coords = way.geometry[range]
                segments.append(RoadSegment(
                    id: id,
                    osmWayID: way.id,
                    splitSequence: UInt16(sequence),
                    nodeIDs: nodes,
                    latE7: coords.map { Int32(($0.lat * 1e7).rounded()) },
                    lonE7: coords.map { Int32(($0.lon * 1e7).rounded()) },
                    lengthM: polylineLengthM(coords),
                    attributes: attributes))
            }
        }
        return segments
    }

    /// Deterministic uint32 from (osm_way_id, split_sequence): splitmix64
    /// finalizer over the packed key, folded to 32 bits. splitmix64 is a
    /// fixed published constant set — NOT tunable, or every stored
    /// segment_id association on the device silently orphans.
    static func segmentID(osmWayID: Int64, splitSequence: UInt16) -> UInt32 {
        var z = (UInt64(bitPattern: osmWayID) << 10) | UInt64(splitSequence)
        z = (z &+ 0x9E37_79B9_7F4A_7C15)
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        let folded = UInt32(truncatingIfNeeded: z ^ (z >> 32))
        return folded == 0 ? zeroRemapID : folded
    }

    /// Node-aligned split points: cut before the edge whose addition would
    /// exceed the cap (every segment keeps at least one edge). Segments
    /// share their boundary node so the D2 graph stays connected.
    static func splitRanges(for way: OverpassWay) -> [ClosedRange<Int>] {
        var ranges: [ClosedRange<Int>] = []
        var start = 0
        var accumulated = 0.0
        for i in 1..<way.geometry.count {
            let edge = edgeLengthM(way.geometry[i - 1], way.geometry[i])
            if accumulated > 0, accumulated + edge > maxSegmentLengthM {
                ranges.append(start...(i - 1))
                start = i - 1
                accumulated = 0
            }
            accumulated += edge
        }
        ranges.append(start...(way.geometry.count - 1))
        return ranges
    }

    static func polylineLengthM(_ coords: ArraySlice<OverpassCoordinate>) -> Double {
        var total = 0.0
        var previous: OverpassCoordinate?
        for coord in coords {
            if let previous { total += edgeLengthM(previous, coord) }
            previous = coord
        }
        return total
    }

    /// Equirectangular edge length — centimeter-exact at segment scale and
    /// dependency-free. Deterministic per device/binary, but NOT guaranteed
    /// bit-identical across devices: `cos` is not IEEE-754 correctly
    /// rounded, and a sub-ULP disagreement at exactly the split cap could
    /// shift a split point and thus segment ids. Acceptable for the
    /// single-rider prototype (RFC 0003 D8, one device pair; replay is
    /// insulated because traces record matched ids, D2) — revisit before
    /// any multi-device history sharing.
    static func edgeLengthM(_ a: OverpassCoordinate, _ b: OverpassCoordinate) -> Double {
        let midLatRad = (a.lat + b.lat) / 2 * .pi / 180
        let dx = (b.lon - a.lon) * 111_320.0 * cos(midLatRad)
        let dy = (b.lat - a.lat) * 110_540.0
        return (dx * dx + dy * dy).squareRoot()
    }
}
