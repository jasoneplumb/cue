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
    /// Untagged on a sparsely tagged class, but the rider drew a custom zone
    /// over it (#38). Same confidence as a well-covered absence, not the
    /// higher explicit-tag value: the rider's drawing substitutes for the
    /// coverage evidence that is missing, it does not become a survey.
    static let confidenceRiderAsserted: UInt8 = 165

    /// All three §7 evidence bits — the qualification rule is their
    /// conjunction, so every zone carries the full mask. Values come from
    /// kernel/cue_policy.h, never redeclared here.
    static let reasonsMask = UInt16(
        CUE_REASON_NARROW_LANE | CUE_REASON_NO_SHOULDER_OR_BIKE_LANE
        | CUE_REASON_HIGH_SPEED_CONTEXT)

    /// Score the imported region. Deterministic for identical input.
    ///
    /// `riderAsserted` names segments the rider has drawn a custom zone over.
    /// They satisfy the meaningful-absence requirement that a sparsely tagged
    /// class otherwise fails (#38) — see `score`. Empty by default, so a
    /// caller with no custom zones scores exactly as before.
    public static func scoreZones(from segments: [RoadSegment],
                                  riderAsserted: Set<UInt32> = []) -> [SqueezeZone] {
        let coverage = ridingSpaceTagCoverage(byClass: segments)
        var scored: [UInt32: (RoadSegment, severity: UInt8, confidence: UInt8)] = [:]
        for segment in segments {
            guard let result = score(segment, coverage: coverage,
                                     riderAsserted: riderAsserted.contains(segment.id))
            else { continue }
            scored[segment.id] = (segment, result.severity, result.confidence)
        }
        return mergeZones(scored)
    }

    /// Share of each highway class's segments carrying ANY riding-space
    /// tag (positive or explicit-no). Segment-weighted: long ways split
    /// into more segments and count proportionally more, approximating
    /// length weighting without geometry math.
    public static func ridingSpaceTagCoverage(byClass segments: [RoadSegment]) -> [String: Double] {
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
    ///
    /// `riderAsserted` (#38) stands in for the coverage evidence a sparsely
    /// tagged class cannot supply. It is deliberately narrow: it substitutes
    /// for MISSING evidence, never contradicts present evidence. A segment
    /// tagged with real riding space still returns nil however emphatically
    /// the rider drew over it, and the class, lane and speed gates are
    /// untouched — a drawn zone on a residential street still does not score.
    static func score(_ segment: RoadSegment, coverage: [String: Double],
                      riderAsserted: Bool = false)
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
            if riderAsserted {
                // The rider drew a zone here. Silence in OSM still means
                // nothing, but the rider's own judgment is the evidence the
                // tags were supposed to carry — which is what the custom-zone
                // overlay was documented to be for, and could not do while
                // this gate rejected every unscored road (#38).
                confidence = confidenceRiderAsserted
            } else {
                guard coverage[attrs.highway, default: 0] >= meaningfulAbsenceCoverage else {
                    return nil  // silence on a sparsely tagged class means nothing
                }
                confidence = confidenceMeaningfulAbsence
            }
        }
        return (mph >= 45 ? severityAtHighSpeed : severityAtFloor, confidence)
    }

    /// Why `score` returned nil for this segment, or nil when it scored.
    /// Human-readable and for diagnostics only — no caller branches on it.
    ///
    /// Exists because "my drawn zone does nothing" has five different causes
    /// with five different remedies (redraw it, edit OSM, accept the scorer's
    /// judgment, nothing), and without this the operator cannot tell them
    /// apart except by reading the scorer (#38).
    public static func rejectionReason(_ segment: RoadSegment,
                                       coverage: [String: Double],
                                       riderAsserted: Bool = false) -> String? {
        let attrs = segment.attributes
        guard arterialClasses.contains(attrs.highway) else {
            return "highway=\(attrs.highway) is not an arterial class"
        }
        guard let lanes = attrs.lanes else {
            return "no lanes tag — the narrow-lane proxy has nothing to read"
        }
        guard lanes <= maxSqueezeLanes else {
            return "lanes=\(lanes) exceeds \(maxSqueezeLanes): not the narrow-lane case"
        }
        guard let mph = attrs.maxspeedMph else {
            return "no maxspeed tag — no basis for high-speed context or severity"
        }
        guard mph >= minSqueezeMph else {
            return "maxspeed=\(mph) mph is below the \(minSqueezeMph) mph floor"
        }
        switch attrs.ridingSpace {
        case .dedicatedSpace:
            return "tagged with dedicated riding space — not a squeeze"
        case .explicitNone, .untagged:
            if attrs.ridingSpace == .untagged, !riderAsserted,
               coverage[attrs.highway, default: 0] < meaningfulAbsenceCoverage {
                return "untagged riding space on a class tagged "
                    + String(format: "%.0f%%", coverage[attrs.highway, default: 0] * 100)
                    + " in this region (needs \(Int(meaningfulAbsenceCoverage * 100))%) "
                    + "— draw a custom zone over it to assert the absence yourself"
            }
            return nil
        }
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
