// Intent: Import webmap.dev's "Custom squeeze zones" GeoJSON export (rider-
//         drawn zones — no OSM tags, so no severity/confidence/reasons_bitmask
//         to score from) and snap each zone's geometry to the imported
//         region's RoadSegments, so a caller can feed the matched segment ids
//         into personal route memory (RFC 0002) as explicit rider judgment.
// Context: Shared by the live app's "Import custom zones…" action
//          (ios/Cue/RideSessionController.swift) and the cue-custom-zone-merge
//          CLI tool (tools/cue-custom-zone-merge), so the snapping logic has
//          exactly one implementation.
// Pattern: One-shot import over a modest region-scale segment count — brute-
//          force nearest-edge search per vertex, not SegmentMatcher's grid
//          index (built for a live 1 Hz stream). A fresh equirectangular
//          projection anchored to the SEGMENTS' own bbox, same convention as
//          SegmentMatcher/RouteEventTracker — each consumer owns its
//          projection; only self-consistency matters (they never compare
//          distances across each other).
import Foundation

public struct CustomZoneFeature: Codable, Equatable, Sendable {
    public let id: String
    public let createdAt: String
    public let label: String?
    /// [lng, lat] pairs, GeoJSON coordinate order — mirrors webmap.dev's export.
    public let coordinates: [[Double]]
    /// The zone applies only while travelling its own vertex order, first ->
    /// last (cue#30 / webmap.dev#277). False for a zone drawn without the
    /// property, so every file exported before it existed keeps its exact
    /// meaning: bidirectional.
    public let directional: Bool

    /// `directional` defaults to the pre-cue#30 meaning so existing call
    /// sites — and any caller constructing a zone that carries no direction —
    /// read as bidirectional without restating it.
    public init(id: String, createdAt: String, label: String?,
                coordinates: [[Double]], directional: Bool = false) {
        self.id = id
        self.createdAt = createdAt
        self.label = label
        self.coordinates = coordinates
        self.directional = directional
    }

    enum CodingKeys: String, CodingKey {
        case id, createdAt, label, coordinates, directional
    }

    /// Hand-written so `directional` decodes as false when the key is absent.
    /// The memberwise default above is invisible to a synthesized decoder,
    /// which requires every non-optional property to be present — so a value
    /// encoded before this property existed would fail to decode outright.
    /// `parseFeatures` reads GeoJSON through JSONSerialization and never
    /// takes this path, but the public Codable conformance is a contract in
    /// its own right, and "absent means bidirectional" has to hold on both.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        coordinates = try container.decode([[Double]].self, forKey: .coordinates)
        directional = try container.decodeIfPresent(Bool.self, forKey: .directional) ?? false
    }
}

public enum CustomZoneImportError: Error, Equatable {
    case invalidJSON
    case notAFeatureCollection
    case malformedFeature(index: Int, reason: String)
}

/// Result of snapping a set of custom zones to a region's segments.
public struct CustomZoneMatchResult: Equatable, Sendable {
    /// Per zone id, the segments it matched and the direction along each
    /// segment's node order the zone applies in — a drawn zone can span
    /// several segments, same as a derived SqueezeZone's member segments,
    /// and a zone that doubles back within one segment unions to `.both`.
    /// A non-directional zone maps every match to `.both`.
    public let matches: [String: [UInt32: ZoneDirectionMask]]
    /// Zone ids with no segment within the snap distance — surfaced to the
    /// caller rather than silently dropped.
    public let unmatchedZoneIDs: [String]

    /// Every segment any zone matched, with the directions unioned across
    /// zones — the whole-file view callers that fold zones into per-segment
    /// state need (two opposing one-way zones on one road are one segment
    /// flagged `.both`, which is what the rider drew).
    public var directionsBySegment: [UInt32: ZoneDirectionMask] {
        var unioned: [UInt32: ZoneDirectionMask] = [:]
        for segmentDirections in matches.values {
            for (segmentID, directions) in segmentDirections {
                unioned[segmentID, default: []].formUnion(directions)
            }
        }
        return unioned
    }
}

public enum CustomZoneImport {
    /// Parse + validate webmap.dev's custom-zones FeatureCollection.
    /// All-or-nothing: throws on the first malformed feature rather than
    /// returning a partial list, matching the exporter's own contract.
    public static func parseFeatures(from data: Data) throws -> [CustomZoneFeature] {
        let root: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CustomZoneImportError.invalidJSON
            }
            root = parsed
        } catch {
            throw CustomZoneImportError.invalidJSON
        }
        guard root["type"] as? String == "FeatureCollection",
              let features = root["features"] as? [[String: Any]] else {
            throw CustomZoneImportError.notAFeatureCollection
        }
        var result: [CustomZoneFeature] = []
        for (index, feature) in features.enumerated() {
            guard feature["type"] as? String == "Feature" else {
                throw CustomZoneImportError.malformedFeature(index: index, reason: "not a Feature")
            }
            guard let geometry = feature["geometry"] as? [String: Any],
                  geometry["type"] as? String == "LineString",
                  let rawCoordinates = geometry["coordinates"] as? [[Double]],
                  rawCoordinates.count >= 2 else {
                throw CustomZoneImportError.malformedFeature(
                    index: index, reason: "geometry must be a LineString with >= 2 positions")
            }
            guard let properties = feature["properties"] as? [String: Any],
                  properties["kind"] as? String == "custom_zone",
                  let id = properties["id"] as? String, !id.isEmpty,
                  let createdAt = properties["created_at"] as? String, !createdAt.isEmpty else {
                throw CustomZoneImportError.malformedFeature(
                    index: index, reason: "properties must have kind=\"custom_zone\", id, created_at")
            }
            // Absent means bidirectional (the pre-cue#30 contract); present
            // but not a boolean is malformed, same all-or-nothing rule as
            // every other property. JSON `1`/`0` also satisfies `as? Bool`
            // through NSNumber bridging — a lenient reading of an
            // unambiguous intent, and webmap.dev's own parser rejects it at
            // the only place these files are authored.
            var directional = false
            if let rawDirectional = properties["directional"] {
                guard let flag = rawDirectional as? Bool else {
                    throw CustomZoneImportError.malformedFeature(
                        index: index, reason: "property directional must be a boolean")
                }
                directional = flag
            }
            result.append(CustomZoneFeature(
                id: id, createdAt: createdAt,
                label: properties["label"] as? String,
                coordinates: rawCoordinates,
                directional: directional))
        }
        return result
    }

    /// Snap each zone's vertices to the nearest RoadSegment edge within
    /// `maxDistanceM` (default: SegmentMatcher's own live-match radius, so
    /// an imported custom zone and a live GPS fix agree on "close enough").
    /// A zone matches every DISTINCT segment any of its vertices lands on —
    /// a drawn zone can legitimately span more than one segment.
    ///
    /// For a `directional` zone each match also resolves WHICH WAY along that
    /// segment's node order the zone runs (cue#30): the zone's LOCAL edge
    /// bearing at the snapped vertex against the bearing of the segment edge
    /// it snapped to. Local, not the zone's overall start->end bearing — a
    /// drawn zone can curve across several segments, and one bearing for the
    /// whole zone would misjudge every segment but the straightest. A
    /// non-directional zone, a lone vertex, or a vertex with no usable local
    /// edge (duplicate consecutive points) resolves `.both`, which is both
    /// the pre-cue#30 behavior and the conservative direction.
    ///
    /// Both bearings are taken in this function's own projected space, so
    /// they are directly comparable; only self-consistency matters (see the
    /// file header's projection note).
    public static func matchSegments(
        for features: [CustomZoneFeature], segments: [RoadSegment],
        maxDistanceM: Double = SegmentMatcher.matchRadiusM
    ) -> CustomZoneMatchResult {
        guard !segments.isEmpty else {
            return CustomZoneMatchResult(matches: [:], unmatchedZoneIDs: features.map(\.id))
        }
        var minLat = Int32.max, maxLat = Int32.min
        var minLon = Int32.max, maxLon = Int32.min
        for segment in segments {
            minLat = min(minLat, segment.latE7.min() ?? minLat)
            maxLat = max(maxLat, segment.latE7.max() ?? maxLat)
            minLon = min(minLon, segment.lonE7.min() ?? minLon)
            maxLon = max(maxLon, segment.lonE7.max() ?? maxLon)
        }
        let anchorLat = Double(minLat) / 2e7 + Double(maxLat) / 2e7
        let anchorLon = Double(minLon) / 2e7 + Double(maxLon) / 2e7
        let metersPerLonDegree = 111_320.0 * cos(anchorLat * .pi / 180)
        let metersPerLatDegree = 110_540.0

        func project(latE7: Int32, lonE7: Int32) -> (x: Double, y: Double) {
            ((Double(lonE7) / 1e7 - anchorLon) * metersPerLonDegree,
             (Double(latE7) / 1e7 - anchorLat) * metersPerLatDegree)
        }
        func project(lat: Double, lon: Double) -> (x: Double, y: Double) {
            ((lon - anchorLon) * metersPerLonDegree, (lat - anchorLat) * metersPerLatDegree)
        }
        // Flatten every segment into its edges once, up front, rather than
        // per-vertex — a one-shot import scans this list len(vertices) times,
        // acceptable at region scale (not a live 1 Hz path).
        var edges: [(segmentID: UInt32, a: (x: Double, y: Double), b: (x: Double, y: Double))] = []
        for segment in segments {
            let points = zip(segment.latE7, segment.lonE7).map { project(latE7: $0, lonE7: $1) }
            for i in 0..<max(0, points.count - 1) {
                edges.append((segment.id, points[i], points[i + 1]))
            }
        }

        /// `edgeBearingDeg` is nil when the winning edge is zero-length
        /// (consecutive duplicate OSM nodes): atan2(0, 0) reports north, and
        /// judging a zone's direction against a phantom bearing could flip
        /// forward and backward outright. SegmentMatcher drops such edges
        /// when building its index; here the edge is KEPT so a zone near a
        /// degenerate segment still snaps to it as it always has — only the
        /// direction is withheld, which the caller reads as `.both`.
        func nearestSegment(lat: Double, lon: Double)
            -> (segmentID: UInt32, edgeBearingDeg: Double?)? {
            let p = project(lat: lat, lon: lon)
            var best: (distanceM: Double, segmentID: UInt32, bearingDeg: Double?)?
            for edge in edges {
                let distance = pointToEdgeDistance(p, edge.a, edge.b)
                if best == nil || distance < best!.distanceM {
                    let degenerate = edge.a.x == edge.b.x && edge.a.y == edge.b.y
                    best = (distance, edge.segmentID,
                            degenerate ? nil : bearingDeg(edge.a, edge.b))
                }
            }
            guard let best, best.distanceM <= maxDistanceM else { return nil }
            return (best.segmentID, best.bearingDeg)
        }

        var matches: [String: [UInt32: ZoneDirectionMask]] = [:]
        var unmatched: [String] = []
        for feature in features {
            let projected = feature.coordinates.map { coordinate -> (x: Double, y: Double)? in
                // GeoJSON order: [lng, lat], optionally [lng, lat, alt] — a
                // 3D position (altitude) is still a valid vertex to snap.
                coordinate.count >= 2 ? project(lat: coordinate[1], lon: coordinate[0]) : nil
            }
            var matchedIDs: [UInt32: ZoneDirectionMask] = [:]
            for (index, coordinate) in feature.coordinates.enumerated() {
                guard coordinate.count >= 2,
                      let hit = nearestSegment(lat: coordinate[1], lon: coordinate[0])
                else { continue }
                let directions: ZoneDirectionMask
                if feature.directional,
                   let zoneBearing = localBearingDeg(of: projected, at: index),
                   let edgeBearing = hit.edgeBearingDeg {
                    directions = ZoneDirectionMask(TravelDirection.resolve(
                        headingDeg: zoneBearing, alongBearingDeg: edgeBearing))
                } else {
                    directions = .both
                }
                matchedIDs[hit.segmentID, default: []].formUnion(directions)
            }
            if matchedIDs.isEmpty {
                unmatched.append(feature.id)
            } else {
                matches[feature.id] = matchedIDs
            }
        }
        return CustomZoneMatchResult(matches: matches, unmatchedZoneIDs: unmatched)
    }

    /// The zone's own direction of travel AT vertex `index`: the edge leaving
    /// that vertex, or — for the last vertex, which has none — the edge
    /// arriving at it. nil when neither exists or both are zero-length
    /// (a lone vertex, or a double-tapped point), leaving the caller to fall
    /// back to `.both` rather than judging direction off a phantom bearing,
    /// the same reason SegmentMatcher skips zero-length edges outright.
    private static func localBearingDeg(of projected: [(x: Double, y: Double)?],
                                        at index: Int) -> Double? {
        guard let here = projected[index] else { return nil }
        if index + 1 < projected.count, let next = projected[index + 1],
           next.x != here.x || next.y != here.y {
            return bearingDeg(here, next)
        }
        if index > 0, let previous = projected[index - 1],
           here.x != previous.x || here.y != previous.y {
            return bearingDeg(previous, here)
        }
        return nil
    }

    /// Compass bearing of a->b in the caller's projected space, degrees
    /// [0, 360) — same formula as SegmentMatcher.bearingDeg, duplicated for
    /// the same reason pointToEdgeDistance is (that one is private to
    /// SegmentMatcher's own projection; this consumer owns its anchor).
    private static func bearingDeg(_ a: (x: Double, y: Double),
                                   _ b: (x: Double, y: Double)) -> Double {
        let bearing = atan2(b.x - a.x, b.y - a.y) * 180 / .pi
        return bearing < 0 ? bearing + 360 : bearing
    }

    /// (distance) from point p to edge a-b, projection clamped to the edge —
    /// same formula as SegmentMatcher.pointToEdge, duplicated rather than
    /// shared (that method is private to SegmentMatcher's own projection;
    /// this consumer owns its own anchor, same pattern as
    /// RouteEventTracker's independent copy of the same geometry).
    private static func pointToEdgeDistance(
        _ p: (x: Double, y: Double), _ a: (x: Double, y: Double), _ b: (x: Double, y: Double)
    ) -> Double {
        let vx = b.x - a.x, vy = b.y - a.y
        let lengthSquared = vx * vx + vy * vy
        let t = lengthSquared == 0 ? 0
            : min(1, max(0, ((p.x - a.x) * vx + (p.y - a.y) * vy) / lengthSquared))
        let px = a.x + t * vx, py = a.y + t * vy
        let dx = p.x - px, dy = p.y - py
        return (dx * dx + dy * dy).squareRoot()
    }

    /// One carry-forward change point (RFC 0002 D6), schema-shaped
    /// (`state` already the schema's string enum) so a caller can encode
    /// it into `personal_memory[]` directly.
    public struct PersonalMemoryChangePoint: Equatable, Sendable {
        public let tMs: UInt32
        public let segmentID: UInt32
        public let state: String
        public let noticeBonusS: UInt8
    }

    /// Offline counterpart to RideTraceRecorder's live carry-forward
    /// tracking: walks a replay trace's samples in order and resolves,
    /// per sample, whether any of `matchedSegmentIDs` was OBSERVED that
    /// step (a route_event's segment_id at that sample's t_ms — the same
    /// v1 approach-window scoping RideEngine.resolveMemory uses live: only
    /// segments producing a RouteEvent this step are eligible). Emits a
    /// change point only when the resolved state changes, exactly
    /// mirroring the live exporter's compression, so a synthetic
    /// "what if this segment had been rider-flagged unsafe all along"
    /// trace stays as small as the live equivalent would have been.
    ///
    /// Every matched segment resolves to the same UNSAFE state (custom
    /// zones carry no severity/suppress distinction), so ties between
    /// several matched segments observed in the same step break on the
    /// smallest segment id — deterministic regardless of route_events
    /// array order (NFR-003). This is DELIBERATELY simpler than RFC 0002
    /// D5's live tiebreak (nearest segment ahead, via distance_to_start_m):
    /// a desk tool merging a what-if trace has no live approach context to
    /// rank by, and the simultaneous-multiple-matched-segment case this
    /// tiebreak governs is rare. A trace where it fires can produce a
    /// personal_memory[] naming a different segment than the live engine
    /// would have chosen for the same ride — a known, bounded divergence
    /// from D5, not a determinism bug in this tool's own output.
    public static func personalMemoryChangePoints(
        matchedSegmentIDs: Set<UInt32>,
        sampleTMs: [UInt32],
        observedSegmentIDs: [UInt32: [UInt32]]
    ) -> [PersonalMemoryChangePoint] {
        var changePoints: [PersonalMemoryChangePoint] = []
        var last: (segmentID: UInt32, state: String, noticeBonusS: UInt8) = (0, "NEUTRAL", 0)
        for tMs in sampleTMs {
            let observed = observedSegmentIDs[tMs] ?? []
            let applicable = observed.filter { matchedSegmentIDs.contains($0) }.min()
            let current: (segmentID: UInt32, state: String, noticeBonusS: UInt8)
            if let applicable {
                current = (applicable, "UNSAFE", 0)
            } else if last.segmentID != 0 {
                // Clearing an active record: keep ITS segment_id — 0 is the
                // reserved "no record" sentinel (RFC 0002 D5) and
                // replay_main.c's decoder rejects it outright; the kernel
                // only needs state == NEUTRAL to stop applying the record.
                current = (last.segmentID, "NEUTRAL", 0)
            } else {
                current = (0, "NEUTRAL", 0)
            }
            if current != last {
                changePoints.append(PersonalMemoryChangePoint(
                    tMs: tMs, segmentID: current.segmentID,
                    state: current.state, noticeBonusS: current.noticeBonusS))
                last = current
            }
        }
        return changePoints
    }
}
