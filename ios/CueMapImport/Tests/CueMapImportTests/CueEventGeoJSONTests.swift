// Intent: The cue-events GeoJSON export contract (webmap.dev#231, GPS:
//         webmap.dev#236) pinned: one Point per fired cue or rider marker
//         at the matched segment's midpoint (approx: true), RFC 7946
//         [lon, lat] order, review and latency joins by event id, absent
//         optionals OMITTED (never null), unmatched segments skipped and
//         counted, byte-stable output. With GPS fixes in the trace: one
//         kind:"track" LineString (≥ 2 fixes, ordered by t_ms), events at
//         their fix with approx omitted (cues within the 2 s tolerance,
//         markers via their own coordinates), and byte-identical output
//         for traces without GPS. Synthetic equator fixture (NFR-005 —
//         no real ride data).
import XCTest
@testable import CueMapImport

final class CueEventGeoJSONTests: XCTestCase {
    // Two straight ways on the equator: one carries the cue's zone, one
    // the rider marker. lat values are distinct from every lon value so a
    // swapped axis order fails the midpoint assertions. The cue way has
    // THREE nodes with a 1:2 edge-length split (~56 m + ~111 m, under the
    // 250 m segment cap), so the along-length midpoint (~83 m) falls a
    // QUARTER of the way into the second edge — an implementation that
    // picks "first edge at least half the total long" instead of walking
    // the accumulated length returns lon 0.00125, not 0.00075.
    private func makeSegments() throws -> (all: [RoadSegment],
                                           cueSegment: RoadSegment,
                                           markerSegment: RoadSegment) {
        let cueWay = OverpassWay(
            id: 300, tags: ["highway": "secondary"], nodes: [1, 2, 3],
            geometry: [OverpassCoordinate(lat: 0.0002, lon: 0),
                       OverpassCoordinate(lat: 0.0002, lon: 0.0005),
                       OverpassCoordinate(lat: 0.0002, lon: 0.0015)])
        let markerWay = OverpassWay(
            id: 400, tags: ["highway": "residential"], nodes: [3, 4],
            geometry: [OverpassCoordinate(lat: 0.0008, lon: 0.002),
                       OverpassCoordinate(lat: 0.0008, lon: 0.003)])
        let segments = try SegmentImporter.deriveSegments(
            from: OverpassExtract(ways: [cueWay, markerWay]))
        return (segments,
                segments.first { $0.osmWayID == 300 }!,
                segments.first { $0.osmWayID == 400 }!)
    }

    /// Schema-v1 trace subset: one suppressed decision (must not export),
    /// one HEAD_UP at t_ms 627000 ("10:27"), two observations for the
    /// event (the FIRST carries the join segment), a marker, a review.
    private func makeTraceJSON(cueSegmentID: UInt32,
                               markerSegmentID: UInt32,
                               reviewed: Bool = true,
                               samples: String = "[]",
                               markerGPS: String = "") -> Data {
        let reviews = reviewed
            ? #"[{"event_id": 42, "outcome": "useful"}]"# : "[]"
        return Data("""
        {
          "schema_version": 1,
          "ride_id": "synthetic",
          "started_at": "2026-01-01T00:00:00Z",
          "policy_config": {},
          "samples": \(samples),
          "route_events": [
            {"t_ms": 626000, "event_id": 42, "family": "COMPOSITE_SQUEEZE_ZONE",
             "segment_id": \(cueSegmentID), "severity": 200, "confidence": 165,
             "reasons_bitmask": 7, "distance_to_start_m": 120,
             "distance_to_end_m": 300},
            {"t_ms": 627000, "event_id": 42, "family": "COMPOSITE_SQUEEZE_ZONE",
             "segment_id": \(markerSegmentID), "severity": 200, "confidence": 165,
             "reasons_bitmask": 7, "distance_to_start_m": 90,
             "distance_to_end_m": 270}
          ],
          "cue_decisions": [
            {"t_ms": 1000, "type": "NONE", "event_id": 42,
             "reason_code": 5, "lead_time_s": -1},
            {"t_ms": 627000, "type": "HEAD_UP", "event_id": 42,
             "reason_code": 0, "lead_time_s": 15}
          ],
          "markers": [
            {"t_ms": 700000, "segment_id": \(markerSegmentID),
             \(markerGPS)"type": "unsafe_here"}
          ],
          "reviews": \(reviews)
        }
        """.utf8)
    }

    private func decodeFeatures(_ geojson: Data) throws -> [[String: Any]] {
        let root = try JSONSerialization.jsonObject(with: geojson) as! [String: Any]
        XCTAssertEqual(root["type"] as? String, "FeatureCollection")
        return root["features"] as! [[String: Any]]
    }

    func testCueFeatureCarriesContractProperties() throws {
        let (segments, cueSegment, markerSegment) = try makeSegments()
        let trace = try CueEventGeoJSON.decodeTrace(
            makeTraceJSON(cueSegmentID: cueSegment.id,
                          markerSegmentID: markerSegment.id))
        XCTAssertEqual(trace.cues.count, 1)  // the NONE decision is filtered
        let (geojson, summary) = try CueEventGeoJSON.encode(
            trace: trace,
            latencyByEventID: [42: .init(delivered: true, latencyMs: 752)],
            segments: segments)
        let features = try decodeFeatures(geojson)
        XCTAssertEqual(features.count, 2)

        let cue = features[0]
        let geometry = cue["geometry"] as! [String: Any]
        XCTAssertEqual(geometry["type"] as? String, "Point")
        // Along-length midpoint of the asymmetric cue way (see fixture
        // comment), [lon, lat] per RFC 7946: the fixture's lat (0.0002)
        // matches no lon midpoint, so swapped axes fail.
        let coordinates = geometry["coordinates"] as! [Double]
        XCTAssertEqual(coordinates[0], 0.00075, accuracy: 1e-9)
        XCTAssertEqual(coordinates[1], 0.0002, accuracy: 1e-9)

        let properties = cue["properties"] as! [String: Any]
        XCTAssertEqual(properties["kind"] as? String, "cue")
        XCTAssertEqual(properties["event_id"] as? Int, 42)
        // Joined from the FIRST observation for event 42.
        XCTAssertEqual(properties["segment_id"] as? Int, Int(cueSegment.id))
        XCTAssertEqual(properties["ride_clock"] as? String, "10:27")
        XCTAssertEqual(properties["lead_time_s"] as? Int, 15)
        XCTAssertEqual(properties["severity"] as? Int, 200)
        XCTAssertEqual(properties["confidence"] as? Int, 165)
        XCTAssertEqual(properties["reasons_bitmask"] as? Int, 7)
        XCTAssertEqual(properties["delivered"] as? Bool, true)
        XCTAssertEqual(properties["latency_ms"] as? Int, 752)
        XCTAssertEqual(properties["outcome"] as? String, "useful")
        XCTAssertEqual(properties["approx"] as? Bool, true)

        XCTAssertEqual(summary, CueEventGeoJSON.Summary(
            cuesIn: 1, markersIn: 1, samplesIn: 0, samplesWithFix: 0,
            cueFeatures: 1, markerFeatures: 1,
            trackEmitted: false, exactCues: 0, exactMarkers: 0,
            gradedCues: 1, latencyJoins: 1,
            skippedNoEvidence: 0, skippedNoSegment: 0))
    }

    func testMarkerFeatureAndAbsentOptionalsAreOmitted() throws {
        let (segments, cueSegment, markerSegment) = try makeSegments()
        let trace = try CueEventGeoJSON.decodeTrace(
            makeTraceJSON(cueSegmentID: cueSegment.id,
                          markerSegmentID: markerSegment.id,
                          reviewed: false))
        // No sidecar, no review: the cue must omit delivered / latency_ms /
        // outcome entirely (absent keys, never null).
        let (geojson, summary) = try CueEventGeoJSON.encode(
            trace: trace, segments: segments)
        let features = try decodeFeatures(geojson)

        let cueProperties = features[0]["properties"] as! [String: Any]
        XCTAssertEqual(
            Set(cueProperties.keys),
            ["kind", "event_id", "segment_id", "ride_clock", "lead_time_s",
             "severity", "confidence", "reasons_bitmask", "approx"])

        // Markers carry ONLY kind, segment_id, ride_clock, approx.
        let marker = features[1]
        let markerProperties = marker["properties"] as! [String: Any]
        XCTAssertEqual(Set(markerProperties.keys),
                       ["kind", "segment_id", "ride_clock", "approx"])
        XCTAssertEqual(markerProperties["kind"] as? String, "marker")
        XCTAssertEqual(markerProperties["segment_id"] as? Int,
                       Int(markerSegment.id))
        XCTAssertEqual(markerProperties["ride_clock"] as? String, "11:40")
        XCTAssertEqual(markerProperties["approx"] as? Bool, true)
        let coordinates = (marker["geometry"] as! [String: Any])["coordinates"] as! [Double]
        XCTAssertEqual(coordinates[0], 0.0025, accuracy: 1e-9)
        XCTAssertEqual(coordinates[1], 0.0008, accuracy: 1e-9)

        XCTAssertEqual(summary.gradedCues, 0)
        XCTAssertEqual(summary.latencyJoins, 0)
    }

    func testDeliveredWithoutMeasuredLatencyOmitsLatencyMs() throws {
        let (segments, cueSegment, markerSegment) = try makeSegments()
        let trace = try CueEventGeoJSON.decodeTrace(
            makeTraceJSON(cueSegmentID: cueSegment.id,
                          markerSegmentID: markerSegment.id))
        // Acked but latency unmeasured (clock skew / unreadable timestamp):
        // delivered joins, latency_ms stays absent.
        let (geojson, _) = try CueEventGeoJSON.encode(
            trace: trace,
            latencyByEventID: [42: .init(delivered: true, latencyMs: nil)],
            segments: segments)
        let properties = try decodeFeatures(geojson)[0]["properties"] as! [String: Any]
        XCTAssertEqual(properties["delivered"] as? Bool, true)
        XCTAssertNil(properties["latency_ms"])
    }

    func testUnmatchedSegmentsAreSkippedAndCounted() throws {
        let (segments, cueSegment, markerSegment) = try makeSegments()
        let trace = try CueEventGeoJSON.decodeTrace(
            makeTraceJSON(cueSegmentID: cueSegment.id,
                          markerSegmentID: markerSegment.id))
        // Extract without the cue's segment (stale ids after OSM edits):
        // the cue is skipped and reported, the marker still renders.
        let pruned = segments.filter { $0.id != cueSegment.id }
        let (geojson, summary) = try CueEventGeoJSON.encode(
            trace: trace, segments: pruned)
        let features = try decodeFeatures(geojson)
        XCTAssertEqual(features.count, 1)
        XCTAssertEqual((features[0]["properties"] as! [String: Any])["kind"] as? String,
                       "marker")
        XCTAssertEqual(summary.skippedNoSegment, 1)
        XCTAssertEqual(summary.skippedNoEvidence, 0)
        XCTAssertEqual(summary.cueFeatures, 0)
        XCTAssertEqual(summary.markerFeatures, 1)
    }

    func testCueWithNoObservationIsSkippedAndCounted() throws {
        let (segments, _, markerSegment) = try makeSegments()
        // A trace whose HEAD_UP references an event id with no route-event
        // observation at all — nothing to resolve geometry from.
        let trace = try CueEventGeoJSON.decodeTrace(Data("""
        {
          "schema_version": 1,
          "route_events": [],
          "cue_decisions": [
            {"t_ms": 5000, "type": "HEAD_UP", "event_id": 99,
             "reason_code": 0, "lead_time_s": 10}
          ],
          "markers": [
            {"t_ms": 6000, "segment_id": \(markerSegment.id),
             "type": "unsafe_here"}
          ],
          "reviews": []
        }
        """.utf8))
        XCTAssertNil(trace.cues[0].evidence)
        let (geojson, summary) = try CueEventGeoJSON.encode(
            trace: trace, segments: segments)
        XCTAssertEqual(try decodeFeatures(geojson).count, 1)
        XCTAssertEqual(summary.skippedNoEvidence, 1)
        XCTAssertEqual(summary.skippedNoSegment, 0)
    }

    func testOutOfSpecOutcomeIsDroppedNotExported() throws {
        let (segments, cueSegment, markerSegment) = try makeSegments()
        // A review outcome outside the FR-008 enum must not reach the
        // overlay's colour key — the cue exports ungraded instead.
        var json = String(decoding: makeTraceJSON(
            cueSegmentID: cueSegment.id, markerSegmentID: markerSegment.id),
            as: UTF8.self)
        json = json.replacingOccurrences(of: "\"useful\"", with: "\"amazing\"")
        let trace = try CueEventGeoJSON.decodeTrace(Data(json.utf8))
        XCTAssertNil(trace.cues[0].outcome)
        let (geojson, summary) = try CueEventGeoJSON.encode(
            trace: trace, segments: segments)
        let properties = try decodeFeatures(geojson)[0]["properties"] as! [String: Any]
        XCTAssertNil(properties["outcome"])
        XCTAssertEqual(summary.gradedCues, 0)
    }

    func testUnsupportedSchemaVersionThrows() {
        // 3 is unknown; 1 and 2 are both readable (see the v2 test below).
        let data = Data("""
        {"schema_version": 3, "route_events": [], "cue_decisions": [],
         "markers": [], "reviews": []}
        """.utf8)
        XCTAssertThrowsError(try CueEventGeoJSON.decodeTrace(data)) { error in
            XCTAssertEqual(error as? CueEventExportError,
                           .unsupportedSchemaVersion(3))
        }
    }

    func testSupportedSchemaVersionsSetsAreEqual() {
        // Both halves of the grading round trip must accept the same traces.
        // If either set gains a version the other doesn't, a ride can export
        // to the map but its grades cannot be merged back (or vice versa).
        XCTAssertEqual(CueEventGeoJSON.supportedSchemaVersions,
                       CueReviewMerge.supportedSchemaVersions)
    }

    func testSchemaVersion2TraceDecodes() throws {
        // The phone stamps 2 on every ride; refusing it meant no current
        // ride could be exported to the map to be graded at all.
        // personal_memory[] is present and simply ignored.
        let data = Data("""
        {"schema_version": 2,
         "route_events": [
           {"t_ms": 1000, "event_id": 101, "family": "COMPOSITE_SQUEEZE_ZONE",
            "segment_id": 7, "severity": 200, "confidence": 165,
            "reasons_bitmask": 7, "distance_to_start_m": 80,
            "distance_to_end_m": 200}],
         "cue_decisions": [
           {"type": "HEAD_UP", "event_id": 101, "reason_code": 0,
            "lead_time_s": 15, "t_ms": 1000}],
         "personal_memory": [
           {"segment_id": 7, "state": "NEUTRAL", "notice_bonus_s": 2,
            "t_ms": 0}],
         "markers": [],
         "reviews": [{"event_id": 101, "outcome": "too_late"}]}
        """.utf8)
        let events = try CueEventGeoJSON.decodeTrace(data)
        XCTAssertEqual(events.cues.count, 1)
        XCTAssertEqual(events.cues[0].eventID, 101)
        XCTAssertEqual(events.cues[0].evidence?.segmentID, 7)
        XCTAssertEqual(events.cues[0].outcome, "too_late")
    }

    func testDecodeLatencySidecar() throws {
        // Shape as CueDispatcher.exportLatencyLog writes it; extra fields
        // must be ignored, absent latency_ms must decode to nil.
        let entries = try CueEventGeoJSON.decodeLatencySidecar(Data("""
        {"cues": [
           {"delivered": true, "delivery_ts_ms": 1783975687146,
            "dispatch_ts_ms": 1783975686999, "event_id": 57053650,
            "expires_after_s": 14, "latency_ms": 147, "path": "live"},
           {"delivered": false, "dispatch_ts_ms": 1783975700000,
            "event_id": 7, "expires_after_s": 10, "path": "queued"}
         ],
         "p95_latency_ms": 147, "ride_id": "r", "undelivered_count": 1}
        """.utf8))
        XCTAssertEqual(entries[57053650],
                       .init(delivered: true, latencyMs: 147))
        XCTAssertEqual(entries[7], .init(delivered: false, latencyMs: nil))
    }

    func testRideClockFormatting() {
        XCTAssertEqual(CueEventGeoJSON.rideClock(627_000), "10:27")
        XCTAssertEqual(CueEventGeoJSON.rideClock(0), "0:00")
        XCTAssertEqual(CueEventGeoJSON.rideClock(59_999), "0:59")
        // Long rides keep counting minutes — no hour rollover.
        XCTAssertEqual(CueEventGeoJSON.rideClock(3_661_000), "61:01")
    }

    func testTrackAndExactPositionsWithGPS() throws {
        let (segments, cueSegment, markerSegment) = try makeSegments()
        // ~1 Hz samples around the cue's t_ms (627000), deliberately out
        // of order in the JSON (an out-of-spec producer) — the track must
        // still come out ordered by t_ms. The 629000 sample has no fix
        // and must appear nowhere; the marker carries its own fix.
        let trace = try CueEventGeoJSON.decodeTrace(makeTraceJSON(
            cueSegmentID: cueSegment.id, markerSegmentID: markerSegment.id,
            samples: """
            [
              {"t_ms": 628000, "speed_cmps": 500,
               "segment_id": \(cueSegment.id), "lat_e7": 3000, "lon_e7": 12000},
              {"t_ms": 626000, "speed_cmps": 500,
               "segment_id": \(cueSegment.id), "lat_e7": 1000, "lon_e7": 10000},
              {"t_ms": 627000, "speed_cmps": 500,
               "segment_id": \(cueSegment.id), "lat_e7": 2000, "lon_e7": 11000},
              {"t_ms": 629000, "speed_cmps": 500,
               "segment_id": \(cueSegment.id)}
            ]
            """,
            markerGPS: #""lat_e7": 9000, "lon_e7": 26000, "#))
        let (geojson, summary) = try CueEventGeoJSON.encode(
            trace: trace, segments: segments)
        let features = try decodeFeatures(geojson)
        XCTAssertEqual(features.count, 3)

        // Track first: one LineString over the three fixed samples,
        // [lon, lat], scaled 1e-7, ordered by t_ms — and no per-event
        // keys, not even approx (every track coordinate IS a fix).
        let track = features[0]
        let trackGeometry = track["geometry"] as! [String: Any]
        XCTAssertEqual(trackGeometry["type"] as? String, "LineString")
        let trackCoordinates = trackGeometry["coordinates"] as! [[Double]]
        XCTAssertEqual(trackCoordinates.count, 3)
        for (index, expected) in [[0.0010, 0.0001], [0.0011, 0.0002],
                                  [0.0012, 0.0003]].enumerated() {
            XCTAssertEqual(trackCoordinates[index][0], expected[0], accuracy: 1e-9)
            XCTAssertEqual(trackCoordinates[index][1], expected[1], accuracy: 1e-9)
        }
        XCTAssertEqual(Set((track["properties"] as! [String: Any]).keys),
                       ["kind"])
        XCTAssertEqual((track["properties"] as! [String: Any])["kind"] as? String,
                       "track")

        // Cue at the 627000 fix (distance 0), approx OMITTED.
        let cue = features[1]
        let cueCoordinates = (cue["geometry"] as! [String: Any])["coordinates"] as! [Double]
        XCTAssertEqual(cueCoordinates[0], 0.0011, accuracy: 1e-9)
        XCTAssertEqual(cueCoordinates[1], 0.0002, accuracy: 1e-9)
        let cueProperties = cue["properties"] as! [String: Any]
        XCTAssertNil(cueProperties["approx"])
        XCTAssertEqual(cueProperties["kind"] as? String, "cue")

        // Marker at its own fix, approx OMITTED.
        let marker = features[2]
        let markerCoordinates = (marker["geometry"] as! [String: Any])["coordinates"] as! [Double]
        XCTAssertEqual(markerCoordinates[0], 0.0026, accuracy: 1e-9)
        XCTAssertEqual(markerCoordinates[1], 0.0009, accuracy: 1e-9)
        XCTAssertNil((marker["properties"] as! [String: Any])["approx"])

        XCTAssertEqual(summary, CueEventGeoJSON.Summary(
            cuesIn: 1, markersIn: 1, samplesIn: 4, samplesWithFix: 3,
            cueFeatures: 1, markerFeatures: 1,
            trackEmitted: true, exactCues: 1, exactMarkers: 1,
            gradedCues: 1, latencyJoins: 0,
            skippedNoEvidence: 0, skippedNoSegment: 0))
    }

    func testTraceWithoutFixesIsByteIdenticalToNoSamples() throws {
        // The #113 regression gate: samples WITHOUT coordinates must not
        // change one byte of output versus the pre-GPS export shape.
        let (segments, cueSegment, markerSegment) = try makeSegments()
        func encode(_ samples: String) throws -> Data {
            let trace = try CueEventGeoJSON.decodeTrace(makeTraceJSON(
                cueSegmentID: cueSegment.id,
                markerSegmentID: markerSegment.id,
                samples: samples))
            return try CueEventGeoJSON.encode(
                trace: trace, segments: segments).geojson
        }
        let withoutSamples = try encode("[]")
        let withPlainSamples = try encode("""
        [{"t_ms": 626000, "speed_cmps": 500, "segment_id": \(cueSegment.id)},
         {"t_ms": 627000, "speed_cmps": 500, "segment_id": \(cueSegment.id)}]
        """)
        XCTAssertEqual(withoutSamples, withPlainSamples)
        // And the shape is the pre-GPS one: no track, approx everywhere.
        let features = try decodeFeatures(withPlainSamples)
        XCTAssertEqual(features.count, 2)
        for feature in features {
            XCTAssertEqual((feature["properties"] as! [String: Any])["approx"] as? Bool,
                           true)
        }
    }

    func testCueFixToleranceBoundary() throws {
        let (segments, cueSegment, markerSegment) = try makeSegments()
        func encode(fixTMs: UInt32) throws -> (features: [[String: Any]],
                                               summary: CueEventGeoJSON.Summary) {
            let trace = try CueEventGeoJSON.decodeTrace(makeTraceJSON(
                cueSegmentID: cueSegment.id,
                markerSegmentID: markerSegment.id,
                samples: """
                [{"t_ms": \(fixTMs), "speed_cmps": 500,
                  "segment_id": \(cueSegment.id),
                  "lat_e7": 4000, "lon_e7": 14000}]
                """))
            let (geojson, summary) = try CueEventGeoJSON.encode(
                trace: trace, segments: segments)
            return (try decodeFeatures(geojson), summary)
        }

        // Exactly 2000 ms from the cue's 627000: still exact — and a
        // single fix is no track, so exact positioning must not depend
        // on track emission.
        let atBoundary = try encode(fixTMs: 625_000)
        XCTAssertEqual(atBoundary.features.count, 2)  // no track
        XCTAssertFalse(atBoundary.summary.trackEmitted)
        XCTAssertEqual(atBoundary.summary.exactCues, 1)
        let exactCue = atBoundary.features[0]
        let exactCoordinates = (exactCue["geometry"] as! [String: Any])["coordinates"] as! [Double]
        XCTAssertEqual(exactCoordinates[0], 0.0014, accuracy: 1e-9)
        XCTAssertEqual(exactCoordinates[1], 0.0004, accuracy: 1e-9)
        XCTAssertNil((exactCue["properties"] as! [String: Any])["approx"])

        // One millisecond farther: midpoint fallback, approx: true.
        let pastBoundary = try encode(fixTMs: 624_999)
        XCTAssertEqual(pastBoundary.summary.exactCues, 0)
        let approxCue = pastBoundary.features[0]
        let approxCoordinates = (approxCue["geometry"] as! [String: Any])["coordinates"] as! [Double]
        XCTAssertEqual(approxCoordinates[0], 0.00075, accuracy: 1e-9)
        XCTAssertEqual(approxCoordinates[1], 0.0002, accuracy: 1e-9)
        XCTAssertEqual((approxCue["properties"] as! [String: Any])["approx"] as? Bool,
                       true)
    }

    func testCueFixDistanceTieKeepsEarlierFix() throws {
        let (segments, cueSegment, markerSegment) = try makeSegments()
        // 626000 and 628000 are both 1000 ms from the cue's 627000 — the
        // earlier fix must win, deterministically.
        let trace = try CueEventGeoJSON.decodeTrace(makeTraceJSON(
            cueSegmentID: cueSegment.id, markerSegmentID: markerSegment.id,
            samples: """
            [{"t_ms": 626000, "speed_cmps": 500,
              "segment_id": \(cueSegment.id), "lat_e7": 1000, "lon_e7": 10000},
             {"t_ms": 628000, "speed_cmps": 500,
              "segment_id": \(cueSegment.id), "lat_e7": 3000, "lon_e7": 12000}]
            """))
        let (geojson, _) = try CueEventGeoJSON.encode(
            trace: trace, segments: segments)
        let cue = try decodeFeatures(geojson)[1]  // features[0] is the track
        let coordinates = (cue["geometry"] as! [String: Any])["coordinates"] as! [Double]
        XCTAssertEqual(coordinates[0], 0.0010, accuracy: 1e-9)
        XCTAssertEqual(coordinates[1], 0.0001, accuracy: 1e-9)
    }

    func testCueHeadingFromNearestFixPresentOnlyWithCourse() throws {
        // #144: a cue positioned at a GPS fix carries the fix's direction
        // of travel as heading_deg (degrees clockwise from north,
        // heading_deg_x10 / 10); a courseless fix omits the key entirely
        // — "unknown" must never read as "due north".
        let (segments, cueSegment, markerSegment) = try makeSegments()
        func cueProperties(samples: String) throws -> [String: Any] {
            let trace = try CueEventGeoJSON.decodeTrace(makeTraceJSON(
                cueSegmentID: cueSegment.id,
                markerSegmentID: markerSegment.id,
                samples: samples))
            let (geojson, _) = try CueEventGeoJSON.encode(
                trace: trace, segments: segments)
            let cue = try decodeFeatures(geojson).first {
                ($0["properties"] as! [String: Any])["kind"] as? String == "cue"
            }!
            return cue["properties"] as! [String: Any]
        }
        let withCourse = try cueProperties(samples: """
        [{"t_ms": 627000, "speed_cmps": 500,
          "segment_id": \(cueSegment.id),
          "lat_e7": 2000, "lon_e7": 11000, "heading_deg_x10": 2453}]
        """)
        XCTAssertEqual(withCourse["heading_deg"] as? Double ?? -1,
                       245.3, accuracy: 1e-9)
        let courseless = try cueProperties(samples: """
        [{"t_ms": 627000, "speed_cmps": 500,
          "segment_id": \(cueSegment.id),
          "lat_e7": 2000, "lon_e7": 11000}]
        """)
        XCTAssertNil(courseless["heading_deg"])
        // Genuine due north (heading_deg_x10: 0) must encode as 0.0, not
        // vanish — otherwise it would be indistinguishable from a
        // courseless fix in the consumer.
        let dueNorth = try cueProperties(samples: """
        [{"t_ms": 627000, "speed_cmps": 500,
          "segment_id": \(cueSegment.id),
          "lat_e7": 2000, "lon_e7": 11000, "heading_deg_x10": 0}]
        """)
        XCTAssertEqual(dueNorth["heading_deg"] as? Double ?? -1,
                       0.0, accuracy: 1e-9)
        // A bearing is 0–3599 tenths; a malformed value ≥ 3600 is omitted
        // (honest omission), never emitted as heading_deg > 360.
        let outOfRange = try cueProperties(samples: """
        [{"t_ms": 627000, "speed_cmps": 500,
          "segment_id": \(cueSegment.id),
          "lat_e7": 2000, "lon_e7": 11000, "heading_deg_x10": 3600}]
        """)
        XCTAssertNil(outOfRange["heading_deg"])
        // Midpoint-positioned cues never carry a heading — the exact-keys
        // assertion in testMarkerFeatureAndAbsentOptionalsAreOmitted pins
        // that alongside every other absent optional.
    }

    func testMarkerWithPartialFixFallsBackToMidpoint() throws {
        let (segments, cueSegment, markerSegment) = try makeSegments()
        // lat without lon is not a usable fix — midpoint + approx, and
        // the marker must not count as exact.
        let trace = try CueEventGeoJSON.decodeTrace(makeTraceJSON(
            cueSegmentID: cueSegment.id, markerSegmentID: markerSegment.id,
            markerGPS: #""lat_e7": 9000, "#))
        let (geojson, summary) = try CueEventGeoJSON.encode(
            trace: trace, segments: segments)
        let marker = try decodeFeatures(geojson)[1]
        let coordinates = (marker["geometry"] as! [String: Any])["coordinates"] as! [Double]
        XCTAssertEqual(coordinates[0], 0.0025, accuracy: 1e-9)
        XCTAssertEqual(coordinates[1], 0.0008, accuracy: 1e-9)
        XCTAssertEqual((marker["properties"] as! [String: Any])["approx"] as? Bool,
                       true)
        XCTAssertEqual(summary.exactMarkers, 0)
    }

    func testExportIsDeterministic() throws {
        // Two INDEPENDENT decode+import+encode runs — byte stability is
        // the file's contract, matching ZoneGeoJSON.
        func run() throws -> Data {
            let (segments, cueSegment, markerSegment) = try makeSegments()
            let trace = try CueEventGeoJSON.decodeTrace(
                makeTraceJSON(cueSegmentID: cueSegment.id,
                              markerSegmentID: markerSegment.id))
            return try CueEventGeoJSON.encode(
                trace: trace,
                latencyByEventID: [42: .init(delivered: true, latencyMs: 752)],
                segments: segments).geojson
        }
        XCTAssertEqual(try run(), try run())
    }

    func testExportIsDeterministicWithGPS() throws {
        // The GPS path adds a sort, a track feature, and the nearestFix
        // branch — pin its byte stability too (NFR-003), including the
        // out-of-order samples the sort has to normalize.
        func run() throws -> Data {
            let (segments, cueSegment, markerSegment) = try makeSegments()
            let trace = try CueEventGeoJSON.decodeTrace(makeTraceJSON(
                cueSegmentID: cueSegment.id,
                markerSegmentID: markerSegment.id,
                samples: """
                [{"t_ms": 628000, "speed_cmps": 500,
                  "segment_id": \(cueSegment.id), "lat_e7": 3000, "lon_e7": 12000},
                 {"t_ms": 626000, "speed_cmps": 500,
                  "segment_id": \(cueSegment.id), "lat_e7": 1000, "lon_e7": 10000},
                 {"t_ms": 627000, "speed_cmps": 500,
                  "segment_id": \(cueSegment.id), "lat_e7": 2000, "lon_e7": 11000,
                  "heading_deg_x10": 2453}]
                """,
                markerGPS: #""lat_e7": 9000, "lon_e7": 26000, "#))
            return try CueEventGeoJSON.encode(
                trace: trace,
                latencyByEventID: [42: .init(delivered: true, latencyMs: 752)],
                segments: segments).geojson
        }
        XCTAssertEqual(try run(), try run())
    }
}
