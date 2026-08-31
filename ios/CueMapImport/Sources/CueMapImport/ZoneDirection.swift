// Intent: Shared direction vocabulary for directional custom squeeze zones
//         (cue#30): which way along a segment's own node order a zone's
//         "unsafe here" judgment applies, and the one rule that decides
//         whether a rider's course is travelling that way.
// Context: A drawn zone is a LineString, so it already carries a direction
//          (first vertex -> last). Expressing that as a direction along the
//          MATCHED SEGMENT's node order — rather than storing the zone's
//          bearing — makes the ride-time comparison exact instead of a fuzzy
//          bearing match, survives a zone that curves across several
//          segments, and costs two bits.
// Pattern: One implementation, three consumers — CustomZoneImport (which way
//          does this zone run along this segment?), the live resolver, and
//          the cue-custom-zone-merge desk tool. They must agree exactly or a
//          desk what-if stops predicting live behavior, the same discipline
//          SegmentMatcher's calibration constants keep with d6_gpx_sim.py.
import Foundation

/// Which way the rider is travelling along a segment, relative to that
/// segment's own node order (`RoadSegment.nodeIDs` first -> last).
public enum TravelDirection: Sendable, Equatable {
    /// With the segment's node order.
    case forward
    /// Against it.
    case backward

    /// "Somewhat aligned" is the same side of perpendicular. Deliberately
    /// wide, for three reasons: it is exactly the coming-and-going
    /// discrimination directional zones exist to make, and nothing narrower
    /// is needed to get it; it matches the directed gate already shipped and
    /// calibrated as `RouteEventTracker.approachGateDeg` (rather than
    /// inventing a third threshold alongside `SegmentMatcher.headingGateDeg`,
    /// which is a mod-180 gate with different semantics); and anything
    /// tighter would start dropping legitimate cues on curving roads and on
    /// approach, where course and segment bearing legitimately diverge —
    /// there the conservative direction (NFR-001) is to keep cueing, since
    /// too wide a gate degrades at worst to the pre-cue#30 behavior of firing
    /// both ways. One constant, so §13 tuning has a single knob.
    public static let alignmentGateDeg = 90.0

    /// Resolve a course against the bearing of the thing being travelled
    /// along (a matched segment edge, or a zone's own local edge). Compass
    /// degrees; both arguments may be outside [0, 360). Exactly
    /// `alignmentGateDeg` apart resolves `.forward` — perpendicular is
    /// arbitrary either way, and a stated tie-break beats an accidental one
    /// (NFR-003).
    public static func resolve(headingDeg: Double, alongBearingDeg: Double) -> TravelDirection {
        angularSeparationDeg(headingDeg, alongBearingDeg) <= alignmentGateDeg ? .forward : .backward
    }

    /// Unsigned separation between two bearings, in [0, 180]. Full-circle,
    /// unlike `SegmentMatcher.undirectedDiff`'s mod-180 reduction — that is
    /// what lets 91° read as "the other way" rather than "nearly aligned".
    /// The magnitude is all the caller needs; deliberately NOT a signed
    /// angle, and named so nobody reaches for it as one.
    static func angularSeparationDeg(_ a: Double, _ b: Double) -> Double {
        var diff = abs(a - b).truncatingRemainder(dividingBy: 360)
        if diff > 180 { diff = 360 - diff }
        return diff
    }
}

/// The directions in which a segment's rider-asserted "unsafe" evidence
/// applies. `.both` is the bidirectional case — a zone drawn without
/// `directional`, an in-ride marker tap (FR-006), or two opposing zones on
/// the same segment, which union to it naturally.
///
/// Stored as one byte so it can ride along on a personal-memory record
/// without disturbing RFC 0002 D7's fixed-size budget.
public struct ZoneDirectionMask: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Coded as a bare integer. The synthesized conformance would wrap it as
    /// {"rawValue": N} — legal, but it would leak an implementation detail
    /// into every persisted file and wire format that ever carries a mask,
    /// and silently fail to decode a plain number written by anything else.
    public init(from decoder: any Decoder) throws {
        // Reserved bits are masked off rather than trusted. A value carrying
        // only them is non-empty but contains neither direction, so it would
        // apply on an unknown course (which tests isEmpty) while refusing
        // both known ones — the gate inverted by a byte nobody wrote on
        // purpose.
        rawValue = try decoder.singleValueContainer().decode(UInt8.self)
            & ZoneDirectionMask.both.rawValue
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public init(_ direction: TravelDirection) {
        self = direction == .forward ? .forward : .backward
    }

    public static let forward = ZoneDirectionMask(rawValue: 1 << 0)
    public static let backward = ZoneDirectionMask(rawValue: 1 << 1)
    public static let both: ZoneDirectionMask = [.forward, .backward]

    /// Whether evidence carrying this mask applies to a rider travelling
    /// `direction`. A `nil` direction means the course is unknown
    /// (standstill, or CoreLocation reporting course < 0): the gate cannot
    /// reject anything, exactly as in `SegmentMatcher`'s heading gate, so any
    /// non-empty mask applies.
    public func applies(to direction: TravelDirection?) -> Bool {
        guard let direction else { return !isEmpty }
        return contains(ZoneDirectionMask(direction))
    }
}
