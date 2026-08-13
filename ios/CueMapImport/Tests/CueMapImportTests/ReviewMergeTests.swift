// Intent: The review-merge contract pinned (webmap.dev#239): overwrite
//         semantics with latest wins (in place, duplicates collapsed),
//         untouched reviews and all non-review trace content preserved,
//         new reviews appended in sidecar order, byte-idempotent
//         re-merge; unknown event ids (wrong ride's sidecar), malformed
//         input, and out-of-spec outcomes each fail with nothing
//         produced. Synthetic fixtures only (NFR-005 — no real ride
//         data).
import XCTest
@testable import CueMapImport

final class ReviewMergeTests: XCTestCase {
    /// Schema-v1 trace: HEAD_UP cues for events 101 and 102, a
    /// NONE-only decision for 103 (a review for it must NOT merge — no
    /// cue fired), full policy_config so the fixture is schema-valid.
    private func makeTrace(reviews: String) -> Data {
        Data("""
        {
          "schema_version": 1,
          "ride_id": "synthetic-merge-001",
          "started_at": "2026-01-01T00:00:00Z",
          "policy_config": {
            "severity_threshold": 128,
            "confidence_threshold": 128,
            "min_notice_s": 5,
            "max_notice_s": 15,
            "min_cooldown_s": 15,
            "min_cooldown_m": 75,
            "min_speed_kmh": 4
          },
          "samples": [
            { "t_ms": 0, "speed_cmps": 500, "segment_id": 7 },
            { "t_ms": 1000, "speed_cmps": 500, "segment_id": 7 }
          ],
          "route_events": [
            { "t_ms": 0, "event_id": 101, "family": "COMPOSITE_SQUEEZE_ZONE",
              "segment_id": 7, "severity": 200, "confidence": 220,
              "reasons_bitmask": 7, "distance_to_start_m": 90,
              "distance_to_end_m": 210 },
            { "t_ms": 1000, "event_id": 102, "family": "COMPOSITE_SQUEEZE_ZONE",
              "segment_id": 8, "severity": 210, "confidence": 230,
              "reasons_bitmask": 3, "distance_to_start_m": 70,
              "distance_to_end_m": 150 }
          ],
          "cue_decisions": [
            { "t_ms": 0, "type": "HEAD_UP", "event_id": 101,
              "reason_code": 0, "lead_time_s": 12 },
            { "t_ms": 500, "type": "NONE", "event_id": 103,
              "reason_code": 2, "lead_time_s": 8 },
            { "t_ms": 1000, "type": "HEAD_UP", "event_id": 102,
              "reason_code": 0, "lead_time_s": 9 }
          ],
          "markers": [],
          "reviews": \(reviews)
        }
        """.utf8)
    }

    private func sidecar(_ json: String) -> Data { Data(json.utf8) }

    private func reviewsArray(of trace: Data) throws -> [[String: Any]] {
        let root = try JSONSerialization.jsonObject(with: trace) as! [String: Any]
        return root["reviews"] as! [[String: Any]]
    }

    // MARK: - Merge semantics

    func testOverwritesInPlacePreservesOthersAppendsNew() throws {
        // 101 already reviewed (overwrite target), 103 reviewed but not
        // mentioned by the incoming sidecar (must survive verbatim), 102
        // unreviewed (append).
        let trace = makeTrace(reviews: """
        [
          { "event_id": 101, "outcome": "too_late",
            "reviewed_at": "2026-01-01T01:00:00Z" },
          { "event_id": 103, "outcome": "unrecognized" }
        ]
        """)
        let incoming = sidecar("""
        [
          { "event_id": 102, "outcome": "false_alarm",
            "reviewed_at": "2026-01-02T09:00:00Z" },
          { "event_id": 101, "outcome": "useful",
            "reviewed_at": "2026-01-02T09:01:00Z" }
        ]
        """)
        let (merged, summary) = try CueReviewMerge.merge(trace: trace,
                                                         sidecar: incoming)
        XCTAssertEqual(summary, .init(merged: 2, added: 1, overwrote: 1))
        let reviews = try reviewsArray(of: merged)
        XCTAssertEqual(reviews.count, 3)
        // 101 overwritten IN PLACE (position 0), incoming fields intact.
        XCTAssertEqual(reviews[0]["event_id"] as? Int, 101)
        XCTAssertEqual(reviews[0]["outcome"] as? String, "useful")
        XCTAssertEqual(reviews[0]["reviewed_at"] as? String,
                       "2026-01-02T09:01:00Z")
        // 103 preserved verbatim (not mentioned by the incoming sidecar).
        XCTAssertEqual(reviews[1]["event_id"] as? Int, 103)
        XCTAssertEqual(reviews[1]["outcome"] as? String, "unrecognized")
        XCTAssertNil(reviews[1]["reviewed_at"])
        // 102 appended (sidecar order).
        XCTAssertEqual(reviews[2]["event_id"] as? Int, 102)
        XCTAssertEqual(reviews[2]["outcome"] as? String, "false_alarm")
    }

    func testNonReviewContentPreservedAndRemergeByteIdempotent() throws {
        let trace = makeTrace(reviews:
            #"[{ "event_id": 101, "outcome": "too_late" }]"#)
        let incoming = sidecar("""
        [{ "event_id": 101, "outcome": "useful",
           "reviewed_at": "2026-01-02T09:00:00Z" }]
        """)
        let (merged, _) = try CueReviewMerge.merge(trace: trace,
                                                   sidecar: incoming)
        // Everything outside reviews[] is value-identical to the input.
        var inputRoot = try JSONSerialization.jsonObject(with: trace)
            as! [String: Any]
        var outputRoot = try JSONSerialization.jsonObject(with: merged)
            as! [String: Any]
        inputRoot["reviews"] = nil
        outputRoot["reviews"] = nil
        XCTAssertEqual(NSDictionary(dictionary: inputRoot),
                       NSDictionary(dictionary: outputRoot))
        // Re-merging the same sidecar into the merged trace changes
        // nothing — byte-identical output (deterministic sortedKeys).
        let (remerged, summary) = try CueReviewMerge.merge(trace: merged,
                                                           sidecar: incoming)
        XCTAssertEqual(remerged, merged)
        XCTAssertEqual(summary, .init(merged: 1, added: 0, overwrote: 1))
    }

    func testMergedTraceJoinsOutcomesThroughTheExporterDecoder() throws {
        // The acceptance loop: after a merge, cue-events-export sees the
        // grades — its decoder joins outcome by event id.
        let trace = makeTrace(reviews: "[]")
        let incoming = sidecar("""
        [
          { "event_id": 101, "outcome": "useful",
            "reviewed_at": "2026-01-02T09:00:00Z" },
          { "event_id": 102, "outcome": "too_late",
            "reviewed_at": "2026-01-02T09:01:00Z" }
        ]
        """)
        let (merged, summary) = try CueReviewMerge.merge(trace: trace,
                                                         sidecar: incoming)
        XCTAssertEqual(summary, .init(merged: 2, added: 2, overwrote: 0))
        let decoded = try CueEventGeoJSON.decodeTrace(merged)
        XCTAssertEqual(decoded.cues.count, 2)
        XCTAssertEqual(decoded.cues[0].outcome, "useful")
        XCTAssertEqual(decoded.cues[1].outcome, "too_late")
    }

    func testTooEarlyOutcomeMergesAndDecodes() throws {
        // too_early joined the FR-008 vocabulary (#143): the merge must
        // accept it and the exporter decoder must join it — both gates
        // share CueEventGeoJSON.validOutcomes.
        let trace = makeTrace(reviews: "[]")
        let incoming = sidecar("""
        [{ "event_id": 101, "outcome": "too_early",
           "reviewed_at": "2026-01-02T09:00:00Z" }]
        """)
        let (merged, summary) = try CueReviewMerge.merge(trace: trace,
                                                         sidecar: incoming)
        XCTAssertEqual(summary, .init(merged: 1, added: 1, overwrote: 0))
        let decoded = try CueEventGeoJSON.decodeTrace(merged)
        XCTAssertEqual(decoded.cues[0].outcome, "too_early")
    }

    func testSidecarDuplicateEventIDLatestWins() throws {
        let trace = makeTrace(reviews: "[]")
        let incoming = sidecar("""
        [
          { "event_id": 101, "outcome": "false_alarm",
            "reviewed_at": "2026-01-02T09:00:00Z" },
          { "event_id": 101, "outcome": "useful",
            "reviewed_at": "2026-01-02T09:05:00Z" }
        ]
        """)
        let (merged, summary) = try CueReviewMerge.merge(trace: trace,
                                                         sidecar: incoming)
        XCTAssertEqual(summary, .init(merged: 1, added: 1, overwrote: 0))
        let reviews = try reviewsArray(of: merged)
        XCTAssertEqual(reviews.count, 1)
        XCTAssertEqual(reviews[0]["outcome"] as? String, "useful")
        XCTAssertEqual(reviews[0]["reviewed_at"] as? String,
                       "2026-01-02T09:05:00Z")
    }

    func testDuplicateExistingReviewsCollapseOnOverwrite() throws {
        // An out-of-spec producer wrote two reviews for 101; overwriting
        // it leaves exactly one (FR-008: one review per reviewed cue).
        let trace = makeTrace(reviews: """
        [
          { "event_id": 101, "outcome": "too_late" },
          { "event_id": 101, "outcome": "false_alarm" }
        ]
        """)
        let incoming = sidecar(
            #"[{ "event_id": 101, "outcome": "useful" }]"#)
        let (merged, _) = try CueReviewMerge.merge(trace: trace,
                                                   sidecar: incoming)
        let reviews = try reviewsArray(of: merged)
        XCTAssertEqual(reviews.count, 1)
        XCTAssertEqual(reviews[0]["outcome"] as? String, "useful")
    }

    // MARK: - Validation failures (all-or-nothing)

    private func assertMergeThrows(trace: Data, sidecar: Data,
                                   _ expected: CueReviewMergeError,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) {
        XCTAssertThrowsError(try CueReviewMerge.merge(trace: trace,
                                                      sidecar: sidecar),
                             file: file, line: line) { error in
            XCTAssertEqual(error as? CueReviewMergeError, expected,
                           file: file, line: line)
        }
    }

    func testUnknownEventIDFailsWholeMerge() throws {
        // 999 never observed; 103 decided but NONE — neither is a fired
        // cue, and the valid 101 entry must not merge alongside them.
        let trace = makeTrace(reviews: "[]")
        let incoming = sidecar("""
        [
          { "event_id": 101, "outcome": "useful" },
          { "event_id": 999, "outcome": "useful" },
          { "event_id": 103, "outcome": "useful" }
        ]
        """)
        assertMergeThrows(trace: trace, sidecar: incoming,
                          .unknownEventIDs([103, 999]))
    }

    func testInvalidOutcomeFails() throws {
        let trace = makeTrace(reviews: "[]")
        assertMergeThrows(
            trace: trace,
            sidecar: sidecar(#"[{ "event_id": 101, "outcome": "great" }]"#),
            .invalidOutcome(eventID: 101, outcome: "great"))
    }

    func testMalformedSidecarFails() throws {
        let trace = makeTrace(reviews: "[]")
        // Not JSON at all.
        XCTAssertThrowsError(try CueReviewMerge.merge(
            trace: trace, sidecar: Data("not json".utf8))) { error in
            guard case .malformedSidecar = error as? CueReviewMergeError else {
                return XCTFail("expected malformedSidecar, got \(error)")
            }
        }
        // Wrong shape: a latency sidecar handed to the wrong tool.
        XCTAssertThrowsError(try CueReviewMerge.merge(
            trace: trace, sidecar: Data(#"{"cues": []}"#.utf8))) { error in
            guard case .malformedSidecar = error as? CueReviewMergeError else {
                return XCTFail("expected malformedSidecar, got \(error)")
            }
        }
    }

    func testMalformedTraceFails() throws {
        let incoming = sidecar(#"[{ "event_id": 101, "outcome": "useful" }]"#)
        XCTAssertThrowsError(try CueReviewMerge.merge(
            trace: Data("[]".utf8), sidecar: incoming)) { error in
            guard case .malformedTrace = error as? CueReviewMergeError else {
                return XCTFail("expected malformedTrace, got \(error)")
            }
        }
    }

    func testUnsupportedSchemaVersionFails() throws {
        let trace = Data("""
        { "schema_version": 2, "cue_decisions": [], "reviews": [] }
        """.utf8)
        assertMergeThrows(
            trace: trace,
            sidecar: sidecar(#"[{ "event_id": 101, "outcome": "useful" }]"#),
            .unsupportedSchemaVersion(2))
    }

    func testUnrecognizedAcceptedFromSidecar() throws {
        // unrecognized grades a fired cue the rider never noticed — a
        // normal, map-gradable outcome like useful/false_alarm/too_late.
        let trace = makeTrace(reviews: "[]")
        let incoming = sidecar(#"[{ "event_id": 101, "outcome": "unrecognized" }]"#)
        let (merged, summary) = try CueReviewMerge.merge(trace: trace, sidecar: incoming)
        XCTAssertEqual(summary, .init(merged: 1, added: 1, overwrote: 0))
        let reviews = try reviewsArray(of: merged)
        XCTAssertEqual(reviews[0]["outcome"] as? String, "unrecognized")
    }

    func testMissingReviewsKeyIsRepairedNotRejected() throws {
        // A trace from a producer that omits reviews[] entirely (older
        // exports) is repaired — treated as [] — not rejected.
        let trace = Data("""
        {
          "schema_version": 1,
          "cue_decisions": [
            { "t_ms": 0, "type": "HEAD_UP", "event_id": 101,
              "reason_code": 0, "lead_time_s": 12 }
          ]
        }
        """.utf8)
        let incoming = sidecar(#"[{ "event_id": 101, "outcome": "useful" }]"#)
        let (merged, summary) = try CueReviewMerge.merge(trace: trace, sidecar: incoming)
        XCTAssertEqual(summary, .init(merged: 1, added: 1, overwrote: 0))
        let reviews = try reviewsArray(of: merged)
        XCTAssertEqual(reviews.count, 1)
        XCTAssertEqual(reviews[0]["event_id"] as? Int, 101)
        XCTAssertEqual(reviews[0]["outcome"] as? String, "useful")
    }
}
