// Intent: RFC 0002 desk-tool merge contract: a custom zone snapped to a
//         region segment produces personal_memory[] change points at
//         exactly the samples where that segment was observed, replacing
//         (not appending to) any prior personal_memory[], with
//         schema_version always written as 2. Synthetic fixtures only
//         (NFR-005 — no real ride/region data).
import XCTest
@testable import CueMapImport

final class CustomZoneMergeTests: XCTestCase {
    /// One rideable way (id 42) at the equator, long enough to derive one
    /// segment — used to learn the deterministic segment id the fixture
    /// trace below must reference.
    private func regionJSON() -> Data {
        Data("""
        {
          "elements": [
            { "type": "way", "id": 42,
              "tags": { "highway": "secondary" },
              "nodes": [1, 2],
              "geometry": [{ "lat": 0, "lon": 0 }, { "lat": 0, "lon": 0.001 }] }
          ]
        }
        """.utf8)
    }

    private func segmentID() throws -> UInt32 {
        let extract = try OverpassExtract(data: regionJSON())
        let segments = try SegmentImporter.deriveSegments(from: extract)
        return try XCTUnwrap(segments.first).id
    }

    /// The way runs east (lon 0 -> 0.001), so a zone drawn west-to-east runs
    /// WITH its segment's node order and one drawn east-to-west runs against.
    private func directionalZonesJSON(eastbound: Bool) -> Data {
        let coordinates = eastbound
            ? "[[0.0003, 0.00001], [0.0007, 0.00001]]"
            : "[[0.0007, 0.00001], [0.0003, 0.00001]]"
        return Data("""
        {
          "type": "FeatureCollection",
          "features": [
            { "type": "Feature",
              "geometry": { "type": "LineString", "coordinates": \(coordinates) },
              "properties": { "kind": "custom_zone", "id": "zone-1",
                              "created_at": "2026-07-22T00:00:00.000Z",
                              "directional": true } }
          ]
        }
        """.utf8)
    }

    /// The fixture trace with a course on every sample — 90 is eastbound,
    /// 270 westbound. The headingless variant above is what a policy-tuning
    /// trace looks like (heading_deg_x10 is optional per NFR-005).
    private func headedTraceJSON(segmentID: UInt32, headingDegX10: Int) -> Data {
        let base = String(decoding: traceJSON(segmentID: segmentID), as: UTF8.self)
        return Data(base.replacingOccurrences(
            of: "\"speed_cmps\": 500",
            with: "\"speed_cmps\": 500, \"heading_deg_x10\": \(headingDegX10)").utf8)
    }

    private func customZonesJSON() -> Data {
        // Two vertices right on the way's geometry (lon 0.0003-0.0007) snap to it.
        Data("""
        {
          "type": "FeatureCollection",
          "features": [
            { "type": "Feature",
              "geometry": { "type": "LineString", "coordinates": [[0.0003, 0.00001], [0.0007, 0.00001]] },
              "properties": { "kind": "custom_zone", "id": "zone-1",
                              "created_at": "2026-07-22T00:00:00.000Z" } }
          ]
        }
        """.utf8)
    }

    private func traceJSON(segmentID: UInt32, existingPersonalMemory: String = "[]") -> Data {
        Data("""
        {
          "schema_version": 1,
          "ride_id": "synthetic-custom-zone-merge-001",
          "started_at": "2026-07-22T00:00:00Z",
          "policy_config": {
            "severity_threshold": 128, "confidence_threshold": 128,
            "min_notice_s": 5, "max_notice_s": 15,
            "min_cooldown_s": 15, "min_cooldown_m": 75, "min_speed_kmh": 4
          },
          "samples": [
            { "t_ms": 0, "speed_cmps": 500, "segment_id": 99 },
            { "t_ms": 1000, "speed_cmps": 500, "segment_id": \(segmentID) },
            { "t_ms": 2000, "speed_cmps": 500, "segment_id": \(segmentID) },
            { "t_ms": 3000, "speed_cmps": 500, "segment_id": 100 }
          ],
          "route_events": [
            { "t_ms": 1000, "event_id": 501, "family": "COMPOSITE_SQUEEZE_ZONE",
              "segment_id": \(segmentID), "severity": 50, "confidence": 200,
              "reasons_bitmask": 1, "distance_to_start_m": 50, "distance_to_end_m": 170 },
            { "t_ms": 2000, "event_id": 501, "family": "COMPOSITE_SQUEEZE_ZONE",
              "segment_id": \(segmentID), "severity": 50, "confidence": 200,
              "reasons_bitmask": 1, "distance_to_start_m": 30, "distance_to_end_m": 150 }
          ],
          "cue_decisions": [],
          "markers": [],
          "reviews": [],
          "personal_memory": \(existingPersonalMemory)
        }
        """.utf8)
    }

    func testMatchedSegmentProducesActivationAndDeactivationChangePoints() throws {
        let segmentID = try segmentID()
        let (mergedData, summary) = try CueCustomZoneMerge.merge(
            trace: traceJSON(segmentID: segmentID),
            customZones: customZonesJSON(),
            region: regionJSON())

        XCTAssertEqual(summary.zonesMatched, 1)
        XCTAssertEqual(summary.zonesUnmatched, 0)
        XCTAssertEqual(summary.segmentsMatched, 1)
        XCTAssertEqual(summary.changePoints, 2, "activation at t=1000, deactivation at t=3000")

        let merged = try JSONSerialization.jsonObject(with: mergedData) as! [String: Any]
        XCTAssertEqual(merged["schema_version"] as? Int, 2)
        let personalMemory = merged["personal_memory"] as! [[String: Any]]
        XCTAssertEqual(personalMemory.count, 2)
        XCTAssertEqual(personalMemory[0]["t_ms"] as? Int, 1000)
        XCTAssertEqual(personalMemory[0]["state"] as? String, "UNSAFE")
        XCTAssertEqual(personalMemory[0]["segment_id"] as? Int, Int(segmentID))
        XCTAssertEqual(personalMemory[1]["t_ms"] as? Int, 3000)
        XCTAssertEqual(personalMemory[1]["state"] as? String, "NEUTRAL")
    }

    func testReplacesRatherThanAppendsToExistingPersonalMemory() throws {
        let segmentID = try segmentID()
        let (mergedData, _) = try CueCustomZoneMerge.merge(
            trace: traceJSON(segmentID: segmentID,
                             existingPersonalMemory: """
                             [{ "t_ms": 0, "segment_id": 12345, "state": "SUPPRESS", "notice_bonus_s": 4 }]
                             """),
            customZones: customZonesJSON(),
            region: regionJSON())
        let merged = try JSONSerialization.jsonObject(with: mergedData) as! [String: Any]
        let personalMemory = merged["personal_memory"] as! [[String: Any]]
        // The prior SUPPRESS record for an unrelated segment is GONE — this
        // tool replaces, it does not merge two carry-forward streams.
        XCTAssertFalse(personalMemory.contains { ($0["segment_id"] as? Int) == 12345 })
    }

    func testUnmatchedZoneProducesNoChangePointsButIsReportedNotDropped() throws {
        let segmentID = try segmentID()
        let farAwayZone = Data("""
        {
          "type": "FeatureCollection",
          "features": [
            { "type": "Feature",
              "geometry": { "type": "LineString", "coordinates": [[5, 5], [5.001, 5]] },
              "properties": { "kind": "custom_zone", "id": "zone-far",
                              "created_at": "2026-07-22T00:00:00.000Z" } }
          ]
        }
        """.utf8)
        let (mergedData, summary) = try CueCustomZoneMerge.merge(
            trace: traceJSON(segmentID: segmentID), customZones: farAwayZone, region: regionJSON())
        XCTAssertEqual(summary.zonesMatched, 0)
        XCTAssertEqual(summary.zonesUnmatched, 1)
        XCTAssertEqual(summary.changePoints, 0)
        let merged = try JSONSerialization.jsonObject(with: mergedData) as! [String: Any]
        XCTAssertEqual((merged["personal_memory"] as! [Any]).count, 0)
        // schema_version is still bumped — the exporter's own contract
        // (once this tool runs, the trace is personal-memory-aware) is
        // unconditional, matching RideTraceRecorder's live behavior.
        XCTAssertEqual(merged["schema_version"] as? Int, 2)
    }

    func testOtherTraceFieldsRoundTripUntouched() throws {
        let segmentID = try segmentID()
        let (mergedData, _) = try CueCustomZoneMerge.merge(
            trace: traceJSON(segmentID: segmentID), customZones: customZonesJSON(), region: regionJSON())
        let merged = try JSONSerialization.jsonObject(with: mergedData) as! [String: Any]
        XCTAssertEqual(merged["ride_id"] as? String, "synthetic-custom-zone-merge-001")
        XCTAssertEqual((merged["samples"] as! [Any]).count, 4)
        XCTAssertEqual((merged["route_events"] as! [Any]).count, 2)
    }

    func testMalformedRegionThrows() {
        XCTAssertThrowsError(try CueCustomZoneMerge.merge(
            trace: traceJSON(segmentID: 1), customZones: customZonesJSON(),
            region: Data("{not json".utf8))) {
            guard case CueCustomZoneMergeError.malformedRegion = $0 else {
                return XCTFail("expected .malformedRegion, got \($0)")
            }
        }
    }

    func testMalformedCustomZonesThrows() throws {
        let segmentID = try segmentID()
        XCTAssertThrowsError(try CueCustomZoneMerge.merge(
            trace: traceJSON(segmentID: segmentID), customZones: Data("{not json".utf8),
            region: regionJSON())) {
            guard case CueCustomZoneMergeError.malformedCustomZones = $0 else {
                return XCTFail("expected .malformedCustomZones, got \($0)")
            }
        }
    }

    func testMalformedTraceThrows() {
        XCTAssertThrowsError(try CueCustomZoneMerge.merge(
            trace: Data("{not json".utf8), customZones: customZonesJSON(), region: regionJSON())) {
            guard case CueCustomZoneMergeError.malformedTrace = $0 else {
                return XCTFail("expected .malformedTrace, got \($0)")
            }
        }
    }

    func testSamplesOutOfOrderThrows() throws {
        let segmentID = try segmentID()
        let unordered = Data("""
        {
          "schema_version": 1,
          "ride_id": "synthetic-custom-zone-merge-unordered",
          "started_at": "2026-07-22T00:00:00Z",
          "policy_config": {
            "severity_threshold": 128, "confidence_threshold": 128,
            "min_notice_s": 5, "max_notice_s": 15,
            "min_cooldown_s": 15, "min_cooldown_m": 75, "min_speed_kmh": 4
          },
          "samples": [
            { "t_ms": 1000, "speed_cmps": 500, "segment_id": \(segmentID) },
            { "t_ms": 0, "speed_cmps": 500, "segment_id": 99 }
          ],
          "route_events": [],
          "cue_decisions": [], "markers": [], "reviews": [], "personal_memory": []
        }
        """.utf8)
        XCTAssertThrowsError(try CueCustomZoneMerge.merge(
            trace: unordered, customZones: customZonesJSON(), region: regionJSON())) {
            guard case CueCustomZoneMergeError.malformedTrace(let reason) = $0 else {
                return XCTFail("expected .malformedTrace, got \($0)")
            }
            XCTAssertTrue(reason.contains("strictly increasing"), "reason was: \(reason)")
        }
    }

    func testSamplesWithEqualTimestampsThrows() throws {
        // replay_main.c's decode_samples requires STRICTLY increasing t_ms
        // (unlike personal_memory[], which tolerates non-decreasing) — a
        // trace with two samples at the same t_ms must be rejected here
        // rather than merging "successfully" and failing later at replay.
        let segmentID = try segmentID()
        let duplicateTMs = Data("""
        {
          "schema_version": 1,
          "ride_id": "synthetic-custom-zone-merge-duplicate-tms",
          "started_at": "2026-07-22T00:00:00Z",
          "policy_config": {
            "severity_threshold": 128, "confidence_threshold": 128,
            "min_notice_s": 5, "max_notice_s": 15,
            "min_cooldown_s": 15, "min_cooldown_m": 75, "min_speed_kmh": 4
          },
          "samples": [
            { "t_ms": 0, "speed_cmps": 500, "segment_id": 99 },
            { "t_ms": 1000, "speed_cmps": 500, "segment_id": \(segmentID) },
            { "t_ms": 1000, "speed_cmps": 500, "segment_id": \(segmentID) }
          ],
          "route_events": [],
          "cue_decisions": [], "markers": [], "reviews": [], "personal_memory": []
        }
        """.utf8)
        XCTAssertThrowsError(try CueCustomZoneMerge.merge(
            trace: duplicateTMs, customZones: customZonesJSON(), region: regionJSON())) {
            guard case CueCustomZoneMergeError.malformedTrace(let reason) = $0 else {
                return XCTFail("expected .malformedTrace, got \($0)")
            }
            XCTAssertTrue(reason.contains("strictly increasing"), "reason was: \(reason)")
        }
    }
}

extension CustomZoneMergeTests {
    // MARK: - Directional zones (cue#30)

    private func mergedStates(zones: Data, trace: Data) throws -> (states: [String], ungated: Int) {
        let (data, summary) = try CueCustomZoneMerge.merge(
            trace: trace, customZones: zones, region: regionJSON())
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let memory = try XCTUnwrap(root["personal_memory"] as? [[String: Any]])
        return (memory.compactMap { $0["state"] as? String }, summary.ungatedSamples)
    }

    func testDirectionalZoneAppliesOnAMatchingCourseOnly() throws {
        let segmentID = try segmentID()
        let withIt = try mergedStates(
            zones: directionalZonesJSON(eastbound: true),
            trace: headedTraceJSON(segmentID: segmentID, headingDegX10: 900))
        XCTAssertEqual(withIt.states, ["UNSAFE", "NEUTRAL"])
        XCTAssertEqual(withIt.ungated, 0)

        let againstIt = try mergedStates(
            zones: directionalZonesJSON(eastbound: false),
            trace: headedTraceJSON(segmentID: segmentID, headingDegX10: 900))
        XCTAssertEqual(againstIt.states, [],
                       "a zone drawn the other way must not fire on this ride")
        XCTAssertEqual(againstIt.ungated, 0)
    }

    func testATraceWithoutHeadingAppliesDirectionalZonesBothWaysAndReportsIt() throws {
        let segmentID = try segmentID()
        let merged = try mergedStates(
            zones: directionalZonesJSON(eastbound: false),
            trace: traceJSON(segmentID: segmentID))
        XCTAssertEqual(merged.states, ["UNSAFE", "NEUTRAL"],
                       "ungatable: falls back to the pre-cue#30 answer rather than guessing")
        XCTAssertEqual(merged.ungated, 2, "and says so, so the what-if cannot overstate itself")
    }

    func testABidirectionalZoneOnAHeadinglessTraceReportsNothingUngated() throws {
        let segmentID = try segmentID()
        let merged = try mergedStates(
            zones: customZonesJSON(), trace: traceJSON(segmentID: segmentID))
        XCTAssertEqual(merged.states, ["UNSAFE", "NEUTRAL"])
        XCTAssertEqual(merged.ungated, 0)
    }
}
