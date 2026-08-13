// Intent: Composite squeeze-zone scoring (RFC 0003 D1b, spec §7): turn
//         imported segments into confidence-scored squeeze ZONES at import
//         time. A zone is the static half of a kernel RouteEvent — the
//         ride engine adds the per-sample distance fields live.
// Context: Calibrated by the obs00004 region audit and validated by the
//          D6 desk simulator: width/shoulder fields are effectively absent
//          region-wide, so the evidence is a CONJUNCTION of proxies —
//          arterial class + explicit lanes<=2 + maxspeed>=40 mph + no
//          dedicated riding space. "No space" from silence counts only
//          where the class's cycleway tagging is systematic in the
//          imported region (meaningful absence); explicit cycleway=no /
//          shoulder=no counts anywhere. Missing evidence -> no event:
//          missed coverage beats noisy cueing (NFR-001).
// Pattern: Reason-bit values come from the kernel C header (CCuePolicy) —
//          one source of truth, no Swift mirror (D3). All thresholds are
//          initial calibration for the spec §13 tuning loop and sit well
//          above the §8 placeholder gates (128) so the POLICY, not the
//          scorer, decides.
import CCuePolicy
import Foundation

/// The static description of one composite squeeze zone: contiguous
/// qualifying segments merged across way boundaries.
public struct SqueezeZone: Codable, Equatable, Sendable {
    /// Stable across re-imports the same way segment ids are: the zone's
    /// smallest member segment id (content-derived, never 0). Membership
    /// changes upstream change the id — the conservative direction.
    public let eventID: UInt32
    /// Member segment ids, ascending (geometric ordering is the ride
    /// engine's job — it holds the geometry).
    public let segmentIDs: [UInt32]
    public let severity: UInt8
    public let confidence: UInt8
    public let reasonsBitmask: UInt16
    public let lengthM: Double
}

public enum SqueezeScorer {
    /// Road classes where squeeze exposure is plausible and cycleway
    /// tagging is systematic enough to reason about (obs00004).
    public static let arterialClasses: Set<String> = [
        "primary", "secondary", "trunk", "primary_link", "secondary_link",
    ]
    /// §7 high_speed_context floor (obs00004: the felt zones are 40–45 mph).
    public static let minSqueezeMph = 40
    /// §7 narrow_lane proxy: at most one lane per direction.
    public static let maxSqueezeLanes = 2
    /// Untagged riding space reads as "none" only when at least this share
    /// of the class's segments in the region carry riding-space tags —
    /// obs00004 measured ~40% on the arterial vs ~0% on residential.
    public static let meaningfulAbsenceCoverage = 0.25

    // Calibration (initial values, spec §13 tuning loop adjusts):
    // severity tracks exposure (speed), confidence tracks evidence quality.
    static let severityAtHighSpeed: UInt8 = 200  // >= 45 mph
    static let severityAtFloor: UInt8 = 180      // 40–44 mph
    static let confidenceExplicit: UInt8 = 190   // tagged cycleway/shoulder=no
    static let confidenceMeaningfulAbsence: UInt8 = 165  // untagged, covered class

    /// All three §7 evidence bits — the qualification rule is their
    /// conjunction, so every zone carries the full mask. Values come from
    /// kernel/cue_policy.h, never redeclared here.
    static let reasonsMask = UInt16(
        CUE_REASON_NARROW_LANE | CUE_REASON_NO_SHOULDER_OR_BIKE_LANE
        | CUE_REASON_HIGH_SPEED_CONTEXT)

    /// Score the imported region. Deterministic for identical input.
    public static func scoreZones(from segments: [RoadSegment]) -> [SqueezeZone] {
        let coverage = ridingSpaceTagCoverage(byClass: segments)
        var scored: [UInt32: (RoadSegment, severity: UInt8, confidence: UInt8)] = [:]
        for segment in segments {
            guard let result = score(segment, coverage: coverage) else { continue }
            scored[segment.id] = (segment, result.severity, result.confidence)
        }
        return mergeZones(scored)
    }

    /// Share of each highway class's segments carrying ANY riding-space
    /// tag (positive or explicit-no). Segment-weighted: long ways split
    /// into more segments and count proportionally more, approximating
    /// length weighting without geometry math.
    static func ridingSpaceTagCoverage(byClass segments: [RoadSegment]) -> [String: Double] {
        var total: [String: Int] = [:]
        var tagged: [String: Int] = [:]
        for segment in segments {
            total[segment.attributes.highway, default: 0] += 1
            if segment.attributes.ridingSpace != .untagged {
                tagged[segment.attributes.highway, default: 0] += 1
            }
        }
        return total.reduce(into: [:]) { result, entry in
            result[entry.key] = Double(tagged[entry.key] ?? 0) / Double(entry.value)
        }
    }

    /// One segment's §7 conjunction, or nil (no event — NFR-001 direction).
    static func score(_ segment: RoadSegment, coverage: [String: Double])
        -> (severity: UInt8, confidence: UInt8)? {
        let attrs = segment.attributes
        guard arterialClasses.contains(attrs.highway),
              let lanes = attrs.lanes, lanes <= maxSqueezeLanes,
              let mph = attrs.maxspeedMph, mph >= minSqueezeMph else { return nil }
        let confidence: UInt8
        switch attrs.ridingSpace {
        case .dedicatedSpace:
            return nil  // rider space exists — not a squeeze
        case .explicitNone:
            confidence = confidenceExplicit
        case .untagged:
            guard coverage[attrs.highway, default: 0] >= meaningfulAbsenceCoverage else {
                return nil  // silence on a sparsely tagged class means nothing
            }
            confidence = confidenceMeaningfulAbsence
        }
        return (mph >= 45 ? severityAtHighSpeed : severityAtFloor, confidence)
    }

    /// Merge contiguous qualifying segments (shared boundary nodes) into
    /// zones. Aggregation is conservative in both directions: severity is
    /// the strongest member (do not understate exposure), confidence the
    /// weakest (do not overstate evidence).
    static func mergeZones(
        _ scored: [UInt32: (RoadSegment, severity: UInt8, confidence: UInt8)]
    ) -> [SqueezeZone] {
        var byBoundaryNode: [Int64: [UInt32]] = [:]
        for (id, entry) in scored {
            for node in [entry.0.nodeIDs.first, entry.0.nodeIDs.last].compactMap({ $0 }) {
                byBoundaryNode[node, default: []].append(id)
            }
        }
        var zones: [SqueezeZone] = []
        var visited: Set<UInt32> = []
        for id in scored.keys.sorted() {
            guard !visited.contains(id) else { continue }
            var members: [UInt32] = []
            var stack = [id]
            while let current = stack.popLast() {
                guard !visited.contains(current) else { continue }
                visited.insert(current)
                members.append(current)
                let segment = scored[current]!.0
                for node in [segment.nodeIDs.first, segment.nodeIDs.last].compactMap({ $0 }) {
                    stack.append(contentsOf: byBoundaryNode[node] ?? [])
                }
            }
            members.sort()
            let entries = members.map { scored[$0]! }
            zones.append(SqueezeZone(
                eventID: members[0],
                segmentIDs: members,
                severity: entries.map(\.severity).max()!,
                confidence: entries.map(\.confidence).min()!,
                reasonsBitmask: reasonsMask,
                lengthM: entries.map(\.0.lengthM).reduce(0, +)))
        }
        return zones.sorted { $0.eventID < $1.eventID }
    }
}
