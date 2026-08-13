// Intent: Map matcher (RFC 0003 D2): GPS fixes match to imported segments
//         by distance-to-polyline over a spatial index, gated by heading
//         agreement, with hysteresis so the match does not flap at
//         intersections. Deterministic for a given fix sequence, cheap,
//         debuggable directly from logged traces. Matcher output is
//         trace-first-class (NFR-003): the ride engine records the matched
//         segment_id per sample and replay never re-matches.
// Context: Calibration constants mirror tools/d6_gpx_sim.py, which
//          validated them over real loop geometry (obs00010: 95–96%
//          correct-way matching, zero unmatched, distance error median
//          ~3 m / p95 ~13 m). Known weakness — parallel nearby roads — is
//          accepted for the Phase 3 field loops; probabilistic (HMM/
//          Viterbi) matching is deliberately deferred until a field trace
//          demonstrates the need (D2 recorded decision).
// Pattern: Hysteresis operates at WAY granularity (as in the sim): flap
//          happens between different roads at intersections, while
//          transitions between consecutive segments of the held way are
//          unambiguous (shared boundary node) and switch freely. Three
//          deliberate refinements over the sim, all documented against
//          it: the heading gate applies per EDGE before the per-way
//          reduction (a curving way's perpendicular stretch cannot veto
//          its parallel stretch); a fix with no gated candidate returns
//          nil instead of repeating the held way without a projection —
//          an unmatched sample (segment_id 0) is the conservative
//          direction (NFR-001); and a held way that is IN radius but
//          heading-gated out (a course transient near a cross road) is
//          not evicted on that one fix — the challenger clock runs and
//          the sample reports unmatched until it expires, so a single
//          heading spike cannot flap the match the way it would in the
//          sim's immediate-reacquire path.
import Foundation

/// One GPS fix as the ride engine receives it (CoreLocation vocabulary,
/// no CoreLocation dependency — tests run on macOS).
public struct GPSFix: Equatable, Sendable {
    public let lat: Double
    public let lon: Double
    /// Compass course over ground in degrees [0, 360), or nil when the
    /// receiver reports none (CoreLocation course < 0, e.g. standstill).
    /// Without a heading the gate cannot reject anything; hysteresis
    /// alone damps flapping until course returns.
    public let headingDeg: Double?

    public init(lat: Double, lon: Double, headingDeg: Double?) {
        self.lat = lat
        self.lon = lon
        self.headingDeg = headingDeg
    }
}

/// Where a fix landed on the imported map: everything the ride engine
/// needs to log the sample and later compute event distances from the
/// segment's node graph.
public struct SegmentMatch: Equatable, Sendable {
    public let segmentID: UInt32
    public let osmWayID: Int64
    /// Matched edge within the segment polyline: edge i spans points
    /// i..i+1 of the segment's coordinate arrays.
    public let edgeIndex: Int
    /// Normalized position along that edge, in [0, 1].
    public let edgeT: Double
    /// Perpendicular distance from the fix to the matched edge, meters.
    public let distanceM: Double
}

/// Stateful nearest-segment matcher. Create one per ride; feed fixes in
/// order. Value semantics: copying forks the hysteresis state.
public struct SegmentMatcher {
    // Calibration (mirrors tools/d6_gpx_sim.py — change BOTH or the desk
    // sim stops predicting app behavior):
    /// Candidate search radius around a fix.
    public static let matchRadiusM = 50.0
    /// Max undirected bearing disagreement between fix course and edge.
    public static let headingGateDeg = 50.0
    /// A challenger way must beat the held way by this margin ...
    public static let hysteresisMarginM = 3.0
    /// ... for this many consecutive fixes before the match switches.
    public static let hysteresisSamples = 2

    /// Grid cell edge; with the 3×3 neighborhood scan this covers every
    /// candidate within matchRadiusM. INVARIANT: gridCellM ≥ matchRadiusM
    /// (asserted in init) — raise gridCellM or widen the scan if
    /// matchRadiusM is ever tuned above it. 100 m keeps per-cell buckets
    /// small at the 50 m radius.
    static let gridCellM = 100.0

    private struct GridKey: Hashable {
        let x: Int
        let y: Int
    }

    private struct Point {
        let x: Double
        let y: Double
    }

    private struct StoredSegment {
        let id: UInt32
        let osmWayID: Int64
        let points: [Point]
    }

    private struct Candidate {
        let segmentIndex: Int
        let edgeIndex: Int
        let edgeT: Double
        let distanceM: Double
    }

    private let segments: [StoredSegment]
    private let grid: [GridKey: [(segmentIndex: Int, edgeIndex: Int)]]
    // Equirectangular anchor: bbox midpoint of the imported region. Same
    // scale constants as SegmentImporter.edgeLengthM — fine at region
    // scale, and only self-consistency matters here.
    private let anchorLat: Double
    private let anchorLon: Double
    private let metersPerLonDegree: Double
    private static let metersPerLatDegree = 110_540.0

    // Hysteresis state (way-granular, see header). The two challenge
    // mechanisms — closer-by-margin and gate-eviction — count
    // INDEPENDENTLY: a challenge only accumulates while consecutive
    // fixes present the same kind of evidence, so a distance challenge
    // followed by one heading spike is two count-1 challenges, never a
    // switch. Each mechanism alone still needs hysteresisSamples fixes.
    private var currentWayID: Int64?
    private var challengerWayID: Int64?
    private var challengeCount = 0
    private var challengeViaEviction = false

    public init(segments: [RoadSegment]) {
        assert(Self.gridCellM >= Self.matchRadiusM,
               "3×3 scan misses candidates when gridCellM < matchRadiusM")
        var minLat = Int32.max, maxLat = Int32.min
        var minLon = Int32.max, maxLon = Int32.min
        for segment in segments {
            minLat = min(minLat, segment.latE7.min() ?? minLat)
            maxLat = max(maxLat, segment.latE7.max() ?? maxLat)
            minLon = min(minLon, segment.lonE7.min() ?? minLon)
            maxLon = max(maxLon, segment.lonE7.max() ?? maxLon)
        }
        anchorLat = segments.isEmpty ? 0 : Double(minLat) / 2e7 + Double(maxLat) / 2e7
        anchorLon = segments.isEmpty ? 0 : Double(minLon) / 2e7 + Double(maxLon) / 2e7
        metersPerLonDegree = 111_320.0 * cos(anchorLat * .pi / 180)

        // Locals: instance properties cannot be read in closures mid-init.
        let anchorLat = self.anchorLat, anchorLon = self.anchorLon
        let metersPerLonDegree = self.metersPerLonDegree
        var stored: [StoredSegment] = []
        var grid: [GridKey: [(segmentIndex: Int, edgeIndex: Int)]] = [:]
        for segment in segments {
            let points = zip(segment.latE7, segment.lonE7).map { lat, lon in
                Point(x: (Double(lon) / 1e7 - anchorLon) * metersPerLonDegree,
                      y: (Double(lat) / 1e7 - anchorLat) * Self.metersPerLatDegree)
            }
            let segmentIndex = stored.count
            stored.append(StoredSegment(
                id: segment.id, osmWayID: segment.osmWayID, points: points))
            for edgeIndex in 0..<max(0, points.count - 1) {
                let a = points[edgeIndex], b = points[edgeIndex + 1]
                // Zero-length edges (consecutive duplicate OSM nodes) have
                // no direction: atan2(0, 0) would report north and let the
                // heading gate judge a phantom bearing. They contribute no
                // geometry their neighbors don't already cover — skip.
                guard a.x != b.x || a.y != b.y else { continue }
                let x0 = Int((min(a.x, b.x) / Self.gridCellM).rounded(.down))
                let x1 = Int((max(a.x, b.x) / Self.gridCellM).rounded(.down))
                let y0 = Int((min(a.y, b.y) / Self.gridCellM).rounded(.down))
                let y1 = Int((max(a.y, b.y) / Self.gridCellM).rounded(.down))
                for x in x0...x1 {
                    for y in y0...y1 {
                        grid[GridKey(x: x, y: y), default: []]
                            .append((segmentIndex, edgeIndex))
                    }
                }
            }
        }
        self.segments = stored
        self.grid = grid
    }

    /// Match one fix. Returns nil when no in-radius, heading-compatible
    /// edge exists (GPS dropout) — the held way survives for the next fix
    /// — or while the fix's course contradicts an in-radius held way and
    /// the challenger clock has not yet expired. Either way the sample
    /// logs as unmatched (segment_id 0), the conservative NFR-001
    /// direction.
    public mutating func match(_ fix: GPSFix) -> SegmentMatch? {
        let p = Point(x: (fix.lon - anchorLon) * metersPerLonDegree,
                      y: (fix.lat - anchorLat) * Self.metersPerLatDegree)
        let scan = scanCandidates(around: p, headingDeg: fix.headingDeg,
                                  heldWayID: currentWayID)
        let candidatesByWay = scan.byWay
        guard !candidatesByWay.isEmpty else { return nil }

        // Deterministic best: distance, then way id (Python dict order is
        // insertion order in the sim; an explicit tie-break is stricter).
        let bestWayID = candidatesByWay.min {
            ($0.value.distanceM, $0.key) < ($1.value.distanceM, $1.key)
        }!.key

        if let held = currentWayID, let heldCandidate = candidatesByWay[held] {
            if bestWayID != held,
               candidatesByWay[bestWayID]!.distanceM
                   < heldCandidate.distanceM - Self.hysteresisMarginM {
                if challengerWayID == bestWayID, !challengeViaEviction {
                    challengeCount += 1
                } else {
                    challengerWayID = bestWayID
                    challengeCount = 1
                    challengeViaEviction = false
                }
                if challengeCount >= Self.hysteresisSamples {
                    currentWayID = bestWayID
                    challengerWayID = nil
                    challengeCount = 0
                    challengeViaEviction = false
                }
            } else {
                challengerWayID = nil
                challengeCount = 0
                challengeViaEviction = false
            }
        } else if currentWayID != nil, scan.heldGateEvicted {
            // The held way is still in radius; only the fix's course
            // contradicts it. A course transient near a cross road must
            // not flap the match on one fix, so the challenger clock runs
            // here too — and until it expires the sample reports
            // unmatched: a contradicted hold is worse than a missed
            // sample (NFR-001). A real turn pays one unmatched fix.
            // Eviction evidence never rides a distance challenge's count
            // (or vice versa) — see the state comment above.
            if challengerWayID == bestWayID, challengeViaEviction {
                challengeCount += 1
            } else {
                challengerWayID = bestWayID
                challengeCount = 1
                challengeViaEviction = true
            }
            guard challengeCount >= Self.hysteresisSamples else { return nil }
            currentWayID = bestWayID
            challengerWayID = nil
            challengeCount = 0
            challengeViaEviction = false
        } else {
            // Cold start, or the held way physically left the search
            // radius: take the best immediately (the sim reacquires
            // without hysteresis too).
            currentWayID = bestWayID
            challengerWayID = nil
            challengeCount = 0
            challengeViaEviction = false
        }

        let chosen = candidatesByWay[currentWayID!]!
        let segment = segments[chosen.segmentIndex]
        return SegmentMatch(
            segmentID: segment.id,
            osmWayID: segment.osmWayID,
            edgeIndex: chosen.edgeIndex,
            edgeT: chosen.edgeT,
            distanceM: chosen.distanceM)
    }

    private struct EdgeID: Hashable {
        let segmentIndex: Int
        let edgeIndex: Int
    }

    private struct Scan {
        var byWay: [Int64: Candidate] = [:]
        /// The held way has an in-radius edge, yet no gated candidate:
        /// only the fix's course disagrees with it (see match()).
        var heldGateEvicted = false
    }

    /// Best in-radius, heading-compatible edge per way. The gate applies
    /// per edge BEFORE the per-way reduction (see header); per-way ties
    /// between edges break on (distance, segment id, edge index) so equal
    /// geometry cannot flap the reported edge.
    private func scanCandidates(around p: Point, headingDeg: Double?,
                                heldWayID: Int64?) -> Scan {
        let cellX = Int((p.x / Self.gridCellM).rounded(.down))
        let cellY = Int((p.y / Self.gridCellM).rounded(.down))
        var seenEdges: Set<EdgeID> = []  // an edge can occupy several neighboring cells
        var heldInRadius = false
        var scan = Scan()
        for dx in -1...1 {
            for dy in -1...1 {
                for (segmentIndex, edgeIndex)
                    in grid[GridKey(x: cellX + dx, y: cellY + dy)] ?? [] {
                    guard seenEdges.insert(
                        EdgeID(segmentIndex: segmentIndex, edgeIndex: edgeIndex)
                    ).inserted else { continue }
                    let segment = segments[segmentIndex]
                    let a = segment.points[edgeIndex]
                    let b = segment.points[edgeIndex + 1]
                    let (distance, t) = Self.pointToEdge(p, a, b)
                    guard distance <= Self.matchRadiusM else { continue }
                    if segment.osmWayID == heldWayID { heldInRadius = true }
                    if let heading = headingDeg,
                       Self.undirectedDiff(heading, Self.bearingDeg(a, b))
                           > Self.headingGateDeg { continue }
                    let candidate = Candidate(
                        segmentIndex: segmentIndex, edgeIndex: edgeIndex,
                        edgeT: t, distanceM: distance)
                    if let existing = scan.byWay[segment.osmWayID] {
                        let existingKey = (existing.distanceM,
                                           segments[existing.segmentIndex].id,
                                           existing.edgeIndex)
                        let candidateKey = (distance, segment.id, edgeIndex)
                        if candidateKey < existingKey {
                            scan.byWay[segment.osmWayID] = candidate
                        }
                    } else {
                        scan.byWay[segment.osmWayID] = candidate
                    }
                }
            }
        }
        if let heldWayID {
            scan.heldGateEvicted = heldInRadius && scan.byWay[heldWayID] == nil
        }
        return scan
    }

    /// (distance, t) from point to edge a-b, projection clamped to the edge.
    private static func pointToEdge(_ p: Point, _ a: Point, _ b: Point) -> (Double, Double) {
        let vx = b.x - a.x, vy = b.y - a.y
        let lengthSquared = vx * vx + vy * vy
        let t = lengthSquared == 0 ? 0
            : min(1, max(0, ((p.x - a.x) * vx + (p.y - a.y) * vy) / lengthSquared))
        let px = a.x + t * vx, py = a.y + t * vy
        let dx = p.x - px, dy = p.y - py
        return ((dx * dx + dy * dy).squareRoot(), t)
    }

    /// Compass bearing of the edge a→b, degrees [0, 360).
    private static func bearingDeg(_ a: Point, _ b: Point) -> Double {
        let bearing = atan2(b.x - a.x, b.y - a.y) * 180 / .pi
        return bearing < 0 ? bearing + 360 : bearing
    }

    /// Bearing disagreement modulo 180° — the rider travels edges in
    /// either direction, so 0° and 180° both mean "along the road".
    static func undirectedDiff(_ h1: Double, _ h2: Double) -> Double {
        var d = abs(h1 - h2).truncatingRemainder(dividingBy: 360)
        d = min(d, 360 - d)
        return min(d, 180 - d)
    }
}
