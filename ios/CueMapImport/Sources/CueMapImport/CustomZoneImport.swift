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
}

public enum CustomZoneImportError: Error, Equatable {
    case invalidJSON
    case notAFeatureCollection
    case malformedFeature(index: Int, reason: String)
}

/// Result of snapping a set of custom zones to a region's segments.
public struct CustomZoneMatchResult: Equatable, Sendable {
    /// Segment ids matched per zone id — a drawn zone can span several
    /// segments, same as a derived SqueezeZone's member segments.
    public let matches: [String: Set<UInt32>]
    /// Zone ids with no segment within the snap distance — surfaced to the
    /// caller rather than silently dropped.
    public let unmatchedZoneIDs: [String]
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
            result.append(CustomZoneFeature(
                id: id, createdAt: createdAt,
                label: properties["label"] as? String,
                coordinates: rawCoordinates))
        }
        return result
    }

    /// Snap each zone's vertices to the nearest RoadSegment edge within
    /// `maxDistanceM` (default: SegmentMatcher's own live-match radius, so
    /// an imported custom zone and a live GPS fix agree on "close enough").
    /// A zone matches every DISTINCT segment any of its vertices lands on —
    /// a drawn zone can legitimately span more than one segment.
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

        func nearestSegment(lat: Double, lon: Double) -> UInt32? {
            let p = project(lat: lat, lon: lon)
            var best: (distanceM: Double, segmentID: UInt32)?
            for edge in edges {
                let distance = pointToEdgeDistance(p, edge.a, edge.b)
                if best == nil || distance < best!.distanceM {
                    best = (distance, edge.segmentID)
                }
            }
            guard let best, best.distanceM <= maxDistanceM else { return nil }
            return best.segmentID
        }

        var matches: [String: Set<UInt32>] = [:]
        var unmatched: [String] = []
        for feature in features {
            var matchedIDs: Set<UInt32> = []
            for coordinate in feature.coordinates {
                // GeoJSON order: [lng, lat], optionally [lng, lat, alt] — a
                // 3D position (altitude) is still a valid vertex to snap.
                guard coordinate.count >= 2 else { continue }
                if let segmentID = nearestSegment(lat: coordinate[1], lon: coordinate[0]) {
                    matchedIDs.insert(segmentID)
                }
            }
            if matchedIDs.isEmpty {
                unmatched.append(feature.id)
            } else {
                matches[feature.id] = matchedIDs
            }
        }
        return CustomZoneMatchResult(matches: matches, unmatchedZoneIDs: unmatched)
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
