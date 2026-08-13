// Intent: Zone → live RouteEvent conversion (RFC 0003, ride-engine half of
//         D1/D2): each matched 1 Hz sample turns the static squeeze zones
//         into the per-sample RouteEvent observations the kernel consumes,
//         with distance_to_start computed as GRAPH distance from the matched
//         projection to the zone boundary (the phone knows the road graph
//         and its matched position — NOT a planned route; D2 rejected
//         route-locked matching).
// Context: Semantics mirror tools/d6_gpx_sim.py's phone-side distance model,
//          validated in obs00010: per zone, shortest-path distances are
//          precomputed from each zone endpoint; per sample, the nearest
//          endpoint is the approach "start", and a DIRECTED heading gate
//          (±90°, full circle) drops zones that lie behind the rider. The
//          kernel gates only on distance_to_start_m (<= 0 means inside);
//          distance_to_end_m is recorded for the trace and §13 tuning.
// Pattern: Deterministic for a given fix sequence (NFR-003): observations
//          sort by (distance_to_start, event_id) and cap at the replay
//          harness's per-sample limit. Matcher output is trace-first-class —
//          replay feeds recorded observations to the kernel and never
//          re-runs this tracker.
import CCuePolicy
import CueKernel
import CueMapImport
import Foundation

/// Converts static squeeze zones into per-sample kernel observations.
/// Create one per ride: it tracks which endpoint each zone was approached
/// through so `distance_to_start_m` stays anchored while inside.
public struct RouteEventTracker {
    /// Observation horizon on approach — mirrors tools/d6_gpx_sim.py
    /// (--horizon-m default). A §13-tunable initial value: beyond this the
    /// kernel would gate TOO_EARLY anyway at rideable speeds.
    public static let horizonM = 600.0

    /// Directed gate: the bearing from the matched position toward the
    /// zone's near endpoint must lie within this of the fix course, or the
    /// zone is behind the rider (full-circle difference, unlike the
    /// matcher's mod-180 gate — approach direction matters here).
    public static let approachGateDeg = 90.0

    private struct Point {
        let x: Double
        let y: Double
    }

    private struct Zone {
        let event: SqueezeZone
        let memberIDs: Set<UInt32>
        /// Chain endpoints (boundary nodes appearing once among member
        /// segments' ends), ascending. A cycle (no such node) falls back to
        /// the smallest boundary node — degenerate but deterministic.
        let endpointNodes: [Int64]
        /// Shortest-path distance maps, one per endpoint, over the whole
        /// imported graph (Dijkstra at init, like the desk sim).
        let distanceByEndpoint: [[Int64: Double]]
    }

    private let zones: [Zone]
    private let nodeXY: [Int64: Point]
    private let segmentsByID: [UInt32: RoadSegment]
    // Equirectangular projection around the region bbox midpoint — same
    // scale constants as SegmentImporter.edgeLengthM / SegmentMatcher.
    // Only self-consistency matters; a different anchor than the matcher's
    // is fine because distances never mix across the two.
    private let anchorLat: Double
    private let anchorLon: Double
    private let metersPerLonDegree: Double
    private static let metersPerLatDegree = 110_540.0

    /// Which endpoint each zone was last approached through (event_id →
    /// node): while inside, distance_to_start anchors to the entry the
    /// rider actually used instead of flapping to whichever end is nearer.
    private var entryEndpoint: [UInt32: Int64] = [:]

    public init(segments: [RoadSegment], zones: [SqueezeZone]) {
        var minLat = Int32.max, maxLat = Int32.min
        var minLon = Int32.max, maxLon = Int32.min
        for segment in segments {
            minLat = min(minLat, segment.latE7.min() ?? minLat)
            maxLat = max(maxLat, segment.latE7.max() ?? maxLat)
            minLon = min(minLon, segment.lonE7.min() ?? minLon)
            maxLon = max(maxLon, segment.lonE7.max() ?? maxLon)
        }
        let anchorLat = segments.isEmpty ? 0 : Double(minLat) / 2e7 + Double(maxLat) / 2e7
        let anchorLon = segments.isEmpty ? 0 : Double(minLon) / 2e7 + Double(maxLon) / 2e7
        let metersPerLonDegree = 111_320.0 * cos(anchorLat * .pi / 180)
        self.anchorLat = anchorLat
        self.anchorLon = anchorLon
        self.metersPerLonDegree = metersPerLonDegree

        var nodeXY: [Int64: Point] = [:]
        var adjacency: [Int64: [(node: Int64, lengthM: Double)]] = [:]
        var segmentsByID: [UInt32: RoadSegment] = [:]
        for segment in segments {
            segmentsByID[segment.id] = segment
            var previous: (id: Int64, point: Point)?
            for (nodeID, latLon) in zip(segment.nodeIDs, zip(segment.latE7, segment.lonE7)) {
                let point = Point(
                    x: (Double(latLon.1) / 1e7 - anchorLon) * metersPerLonDegree,
                    y: (Double(latLon.0) / 1e7 - anchorLat) * Self.metersPerLatDegree)
                nodeXY[nodeID] = point
                if let previous {
                    let length = Self.euclid(previous.point, point)
                    adjacency[previous.id, default: []].append((nodeID, length))
                    adjacency[nodeID, default: []].append((previous.id, length))
                }
                previous = (nodeID, point)
            }
        }
        self.nodeXY = nodeXY
        self.segmentsByID = segmentsByID

        // SqueezeZone is public Codable, so a memberless zone can arrive
        // (edited JSON, future construction paths) — drop it here rather
        // than trap on segmentIDs[0] at observation time; it could never
        // produce an observation anyway.
        self.zones = zones.filter { !$0.segmentIDs.isEmpty }.map { zone in
            var endCounts: [Int64: Int] = [:]
            for id in zone.segmentIDs {
                guard let segment = segmentsByID[id] else { continue }
                for node in [segment.nodeIDs.first, segment.nodeIDs.last].compactMap({ $0 }) {
                    endCounts[node, default: 0] += 1
                }
            }
            var endpoints = endCounts.filter { $0.value == 1 }.keys.sorted()
            if endpoints.isEmpty, let fallback = endCounts.keys.min() {
                endpoints = [fallback]
            }
            // Full-graph Dijkstra per endpoint, once at ride start — fine
            // at loop-region scale (~10⁴ nodes × ~2 endpoints × ~12 zones).
            // Profile before city-scale imports; the mitigation then is a
            // buffered subgraph or distance maps precomputed at import.
            let maps = endpoints.map { Self.dijkstra(from: $0, adjacency: adjacency) }
            return Zone(event: zone, memberIDs: Set(zone.segmentIDs),
                        endpointNodes: endpoints, distanceByEndpoint: maps)
        }
    }

    /// The observations for one matched sample, kernel-ready: sorted by
    /// (distance_to_start, event_id) and capped at the replay harness's
    /// per-sample limit so live never exceeds what replay accepts.
    public mutating func observations(for match: SegmentMatch,
                                      headingDeg: Double?) -> [RouteEvent] {
        guard let projection = projectedPoint(of: match) else { return [] }
        var events: [RouteEvent] = []
        for zone in zones {
            guard let observed = observe(zone, at: projection,
                                         matchedSegmentID: match.segmentID,
                                         headingDeg: headingDeg) else { continue }
            events.append(observed)
        }
        events.sort {
            ($0.distance_to_start_m, $0.event_id) < ($1.distance_to_start_m, $1.event_id)
        }
        return Array(events.prefix(CuePolicy.maxEventsPerSample))
    }

    private mutating func observe(_ zone: Zone, at projection: Point,
                                  matchedSegmentID: UInt32,
                                  headingDeg: Double?) -> RouteEvent? {
        guard let matched = segmentsByID[matchedSegmentID] else { return nil }
        // Distance from the projection to each zone endpoint: enter the
        // graph through the matched edge... the projection lies between
        // consecutive polyline nodes of the matched segment, so the nearest
        // graph entry points are that segment's nodes. Using the segment's
        // two OUTER nodes would overstate distance mid-segment; using every
        // node of the matched segment keeps the error at most one edge.
        var reaches: [(distanceM: Double, endpoint: Int64, via: Int64)] = []
        for (index, distanceMap) in zone.distanceByEndpoint.enumerated() {
            var best: (Double, Int64)?
            for node in matched.nodeIDs {
                guard let mapped = distanceMap[node], let xy = nodeXY[node] else { continue }
                let total = mapped + Self.euclid(projection, xy)
                if best == nil || total < best!.0 { best = (total, node) }
            }
            if let best {
                reaches.append((best.0, zone.endpointNodes[index], best.1))
            }
        }
        guard let nearest = reaches.min(by: { ($0.distanceM, $0.endpoint) < ($1.distanceM, $1.endpoint) })
        else { return nil }  // zone unreachable from the matched component
        let farthestM = reaches.map(\.distanceM).max() ?? nearest.distanceM

        let startM: Double
        let endM: Double
        if zone.memberIDs.contains(matchedSegmentID) {
            // Inside: anchor "start" to the endpoint the rider entered
            // through (recorded on approach); fall back to the nearer end
            // when the ride began inside the zone.
            let entry = entryEndpoint[zone.event.eventID] ?? nearest.endpoint
            let entryDistance = reaches.first { $0.endpoint == entry }?.distanceM
                ?? nearest.distanceM
            startM = -entryDistance
            endM = reaches.first { $0.endpoint != entry }?.distanceM ?? farthestM
        } else {
            // Approaching (or departed): nearest endpoint is the start.
            // The directed gate is what drops zones behind the rider —
            // after passing through, the near endpoint points backward.
            if let headingDeg, let towardXY = nodeXY[nearest.via],
               Self.euclid(projection, towardXY) > 1.0 {
                let bearing = Self.bearingDeg(projection, towardXY)
                var diff = abs(headingDeg - bearing).truncatingRemainder(dividingBy: 360)
                diff = min(diff, 360 - diff)
                if diff > Self.approachGateDeg { return nil }
            }
            guard nearest.distanceM <= Self.horizonM else { return nil }
            entryEndpoint[zone.event.eventID] = nearest.endpoint
            startM = nearest.distanceM
            endM = farthestM
        }

        return RouteEvent(
            event_id: zone.event.eventID,
            family: UInt8(CUE_EVENT_FAMILY_COMPOSITE_SQUEEZE_ZONE),
            segment_id: zone.event.segmentIDs[0],
            severity: zone.event.severity,
            confidence: zone.event.confidence,
            reasons_bitmask: zone.event.reasonsBitmask,
            distance_to_start_m: Self.clampInt16(startM),
            distance_to_end_m: Self.clampInt16(endM))
    }

    private func projectedPoint(of match: SegmentMatch) -> Point? {
        guard let segment = segmentsByID[match.segmentID],
              match.edgeIndex + 1 < segment.latE7.count else { return nil }
        func point(_ index: Int) -> Point {
            Point(x: (Double(segment.lonE7[index]) / 1e7 - anchorLon) * metersPerLonDegree,
                  y: (Double(segment.latE7[index]) / 1e7 - anchorLat) * Self.metersPerLatDegree)
        }
        let a = point(match.edgeIndex), b = point(match.edgeIndex + 1)
        return Point(x: a.x + (b.x - a.x) * match.edgeT,
                     y: a.y + (b.y - a.y) * match.edgeT)
    }

    // MARK: - Graph + geometry helpers

    private static func dijkstra(from source: Int64,
                                 adjacency: [Int64: [(node: Int64, lengthM: Double)]])
        -> [Int64: Double] {
        var distance: [Int64: Double] = [source: 0]
        // Binary min-heap of (distance, node); ties break on node id so the
        // settle order — and thus float summation order — is deterministic.
        var heap: [(Double, Int64)] = [(0, source)]
        func less(_ a: (Double, Int64), _ b: (Double, Int64)) -> Bool { a < b }
        func pop() -> (Double, Int64)? {
            guard !heap.isEmpty else { return nil }
            heap.swapAt(0, heap.count - 1)
            let top = heap.removeLast()
            var i = 0
            while true {
                let l = 2 * i + 1, r = 2 * i + 2
                var smallest = i
                if l < heap.count, less(heap[l], heap[smallest]) { smallest = l }
                if r < heap.count, less(heap[r], heap[smallest]) { smallest = r }
                if smallest == i { break }
                heap.swapAt(i, smallest)
                i = smallest
            }
            return top
        }
        func push(_ element: (Double, Int64)) {
            heap.append(element)
            var i = heap.count - 1
            while i > 0 {
                let parent = (i - 1) / 2
                guard less(heap[i], heap[parent]) else { break }
                heap.swapAt(i, parent)
                i = parent
            }
        }
        while let (d, node) = pop() {
            guard d <= distance[node, default: .infinity] else { continue }
            for edge in adjacency[node] ?? [] {
                let candidate = d + edge.lengthM
                if candidate < distance[edge.node, default: .infinity] {
                    distance[edge.node] = candidate
                    push((candidate, edge.node))
                }
            }
        }
        return distance
    }

    private static func euclid(_ a: Point, _ b: Point) -> Double {
        let dx = a.x - b.x, dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Compass bearing a→b, degrees [0, 360).
    private static func bearingDeg(_ a: Point, _ b: Point) -> Double {
        let bearing = atan2(b.x - a.x, b.y - a.y) * 180 / .pi
        return bearing < 0 ? bearing + 360 : bearing
    }

    private static func clampInt16(_ value: Double) -> Int16 {
        Int16(max(Double(Int16.min), min(Double(Int16.max), value.rounded())))
    }
}
