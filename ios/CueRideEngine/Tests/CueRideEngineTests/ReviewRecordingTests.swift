// Intent: After-ride review recording tests (RFC 0003 D7, FR-008). The
//         load-bearing properties: reviews[] exports with the schema's
//         exact field names and outcome strings, reviewed_at is an ABSENT
//         key when the caller supplied none, re-grading REPLACES (one
//         review per reviewed cue), exports stay byte-stable with reviews
//         present (event_id sort order), and a graded synthetic ride
//         round-trips exactly one review through the trace.
// Layout: Fixture geometry mirrors RideEngineTests (fake ids, equator
//         coordinates — NFR-005): approach way 100 → squeeze way 200
//         (secondary, lanes=2, 45 mph, cycleway=no → one zone) → exit
//         way 300. Duplicated, not shared: test files stay independent.
import CueKernel
import XCTest
@testable import CueMapImport
@testable import CueRideEngine

final class ReviewRecordingTests: XCTestCase {
    // MARK: - Recorder-level fixtures

    private func makeRecorder() -> RideTraceRecorder {
        RideTraceRecorder(rideID: "review-test-ride",
                          startedAt: "2026-07-11T00:00:00Z",
                          config: CuePolicy.defaultConfig())
    }

    private func exportedReviews(
        _ recorder: RideTraceRecorder) throws -> [[String: Any]] {
        let trace = try JSONSerialization.jsonObject(
            with: recorder.exportPolicyTrace()) as! [String: Any]
        return trace["reviews"] as! [[String: Any]]
    }

    // MARK: - Schema-exact fields and outcome strings

    func testReviewsExportExactSchemaFieldsAndOutcomeStrings() throws {
        let recorder = makeRecorder()
        recorder.addReview(eventID: 1, outcome: .useful)
        recorder.addReview(eventID: 2, outcome: .falseAlarm)
        recorder.addReview(eventID: 3, outcome: .tooLate)
        recorder.addReview(eventID: 4, outcome: .tooEarly)
        recorder.addReview(eventID: 5, outcome: .unrecognized)
        let reviews = try exportedReviews(recorder)
        XCTAssertEqual(reviews.count, 5)
        // The schema's enum, verbatim — these strings are the FR-008
        // interchange contract and must never drift.
        XCTAssertEqual(reviews.map { $0["outcome"] as? String },
                       ["useful", "false_alarm", "too_late", "too_early",
                        "unrecognized"])
        XCTAssertEqual(reviews.map { $0["event_id"] as? Int }, [1, 2, 3, 4, 5])
        for review in reviews {
            // Only schema keys, and only the required ones when
            // reviewed_at was not supplied.
            XCTAssertEqual(Set(review.keys), ["event_id", "outcome"])
        }
    }

    func testReviewedAtOmittedWhenNilPresentWhenSet() throws {
        let recorder = makeRecorder()
        recorder.addReview(eventID: 1, outcome: .useful)
        recorder.addReview(eventID: 2, outcome: .falseAlarm,
                           reviewedAt: "2026-07-11T01:23:45Z")
        let reviews = try exportedReviews(recorder)
        // Absent KEY, not a null — the schema rejects null.
        XCTAssertNil(reviews[0]["reviewed_at"])
        XCTAssertEqual(reviews[1]["reviewed_at"] as? String,
                       "2026-07-11T01:23:45Z")
    }

    // MARK: - Replace semantics (one review per reviewed cue)

    func testRegradingSameEventReplacesPriorReview() throws {
        let recorder = makeRecorder()
        recorder.addReview(eventID: 7, outcome: .falseAlarm,
                           reviewedAt: "2026-07-11T01:00:00Z")
        recorder.addReview(eventID: 7, outcome: .useful,
                           reviewedAt: "2026-07-11T01:05:00Z")
        let reviews = try exportedReviews(recorder)
        XCTAssertEqual(reviews.count, 1, "one review per cue — replace, not append")
        XCTAssertEqual(reviews[0]["outcome"] as? String, "useful")
        XCTAssertEqual(reviews[0]["reviewed_at"] as? String,
                       "2026-07-11T01:05:00Z")
    }

    // MARK: - Byte-stable export (sortedKeys convention)

    func testReviewsExportSortedByEventID() throws {
        let recorder = makeRecorder()
        // Grading order is rider whim; export order must not be.
        recorder.addReview(eventID: 9, outcome: .useful)
        recorder.addReview(eventID: 0, outcome: .unrecognized)
        recorder.addReview(eventID: 4, outcome: .tooLate)
        let reviews = try exportedReviews(recorder)
        XCTAssertEqual(reviews.map { $0["event_id"] as? Int }, [0, 4, 9])
    }

    func testExportIsDeterministicWithReviewsPresent() throws {
        let (first, second) = (makeRecorder(), makeRecorder())
        for recorder in [first, second] {
            recorder.addReview(eventID: 3, outcome: .tooLate,
                               reviewedAt: "2026-07-11T01:00:00Z")
            recorder.addReview(eventID: 1, outcome: .useful)
            recorder.addReview(eventID: 0, outcome: .unrecognized)
        }
        XCTAssertEqual(try first.exportPolicyTrace(),
                       try second.exportPolicyTrace())
    }

    // MARK: - Integration: graded synthetic ride round-trips its review

    private static let approachWay = OverpassWay(
        id: 100, tags: ["highway": "residential"],
        nodes: [20, 21, 22, 23, 10],
        geometry: (0...4).map { OverpassCoordinate(lat: 0, lon: -0.004 + Double($0) * 0.001) })

    private static let squeezeWay = OverpassWay(
        id: 200,
        tags: ["highway": "secondary", "lanes": "2", "maxspeed": "45 mph",
               "cycleway": "no"],
        nodes: [10, 11, 12, 13, 14, 15, 16, 17],
        geometry: (0...7).map { OverpassCoordinate(lat: 0, lon: Double($0) * 0.001) })

    private static let exitWay = OverpassWay(
        id: 300, tags: ["highway": "residential"],
        nodes: [17, 30, 31],
        geometry: [OverpassCoordinate(lat: 0, lon: 0.007),
                   OverpassCoordinate(lat: 0, lon: 0.008),
                   OverpassCoordinate(lat: 0, lon: 0.009)])

    func testGradedRideExportsExactlyThatReview() throws {
        let segments = try SegmentImporter.deriveSegments(
            from: OverpassExtract(ways: [Self.approachWay, Self.squeezeWay,
                                         Self.exitWay]))
        let zones = SqueezeScorer.scoreZones(from: segments)
        XCTAssertEqual(zones.count, 1, "fixture must score exactly one zone")
        let engine = RideEngine(segments: segments, zones: zones,
                                rideID: "review-ride",
                                startedAt: "2026-07-11T00:00:00Z")
        // Eastbound at 6 m/s, 1 Hz, ~2.2 m north of the centerline: the
        // full approach → squeeze ride that emits exactly one HEAD_UP.
        for second in 0..<120 {
            engine.process(RideFix(
                tMs: UInt32(second * 1000),
                lat: 0.00002,
                lon: -0.004 + 6.0 * Double(second) / 111_320.0,
                speedMps: 6.0,
                headingDeg: 90))
        }

        // The accessor the review UI lists: exactly the ride's one cue.
        let cues = engine.recorder.cueSummaries
        XCTAssertEqual(cues.count, 1, "one HEAD_UP per event (FR-004)")
        XCTAssertEqual(cues[0].eventID, zones[0].eventID)

        engine.recorder.addReview(eventID: cues[0].eventID, outcome: .useful,
                                  reviewedAt: "2026-07-11T00:02:30Z")
        let trace = try JSONSerialization.jsonObject(
            with: engine.recorder.exportPolicyTrace()) as! [String: Any]
        let reviews = trace["reviews"] as! [[String: Any]]
        XCTAssertEqual(reviews.count, 1)
        XCTAssertEqual(reviews[0]["event_id"] as? Int, Int(cues[0].eventID))
        XCTAssertEqual(reviews[0]["outcome"] as? String, "useful")
        XCTAssertEqual(reviews[0]["reviewed_at"] as? String,
                       "2026-07-11T00:02:30Z")
    }
}
