// Intent: Discard-ride rollback tests (#135): a discarded ride must
//         contribute NOTHING to personal route memory — mark()-ed "unsafe
//         here" segments and forwarded review grades are all reversed by
//         engine.undoPersonalMemoryContributions(), while evidence from
//         PAST rides on the same segments survives untouched (NFR-005 /
//         RFC 0002). Session/file-level behavior (no export, UI reset)
//         lives in RideSessionController and is verified manually — this
//         suite covers the package-level engine/store contract.
// Layout: Fixture geometry duplicated from ReviewRecordingTests (approach
//         way 100 -> squeeze way 200 -> exit way 300), the known-good ride
//         that cues exactly once. Duplicated, not shared: test files stay
//         independent.
import CueKernel
import XCTest
@testable import CueMapImport
@testable import CueRideEngine

final class DiscardRideTests: XCTestCase {
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
        id: 300, tags: ["highway": "residential"], nodes: [17, 30, 31],
        geometry: [OverpassCoordinate(lat: 0, lon: 0.007),
                   OverpassCoordinate(lat: 0, lon: 0.008),
                   OverpassCoordinate(lat: 0, lon: 0.009)])

    private func fixtureSegmentsAndZones() throws -> (segments: [RoadSegment], zones: [SqueezeZone]) {
        let segments = try SegmentImporter.deriveSegments(
            from: OverpassExtract(ways: [Self.approachWay, Self.squeezeWay, Self.exitWay]))
        let zones = SqueezeScorer.scoreZones(from: segments)
        XCTAssertEqual(zones.count, 1, "fixture must score exactly one zone")
        return (segments, zones)
    }

    /// Eastbound at 6 m/s, 1 Hz, ~2.2 m north of the centerline — cues
    /// exactly once with no memory in play (ReviewRecordingTests baseline).
    private func ride(_ engine: RideEngine) {
        for second in 0..<120 {
            engine.process(RideFix(
                tMs: UInt32(second * 1000),
                lat: 0.00002,
                lon: -0.004 + 6.0 * Double(second) / 111_320.0,
                speedMps: 6.0,
                headingDeg: 90))
        }
    }

    func testDiscardRollsBackMarkersAndGradesToAnEmptyStore() throws {
        let (segments, zones) = try fixtureSegmentsAndZones()
        let store = PersonalMemoryStore()
        let engine = RideEngine(segments: segments, zones: zones, personalMemoryStore: store,
                                rideID: "discard-rollback",
                                startedAt: "2026-07-27T00:00:00Z")
        ride(engine)
        let cues = engine.recorder.cueSummaries
        XCTAssertEqual(cues.count, 1)

        // The ride contributes both kinds of evidence: two marker taps
        // (voice/phone path and the queued-watch path) plus a grade.
        XCTAssertTrue(engine.mark())
        XCTAssertTrue(engine.mark(atTMs: 30_000))
        engine.recordReview(eventID: cues[0].eventID, outcome: .falseAlarm)
        XCTAssertGreaterThan(store.recordCount, 0, "ride must have fed the store before discard")

        engine.undoPersonalMemoryContributions()
        XCTAssertEqual(store.recordCount, 0,
                       "a discarded ride contributes nothing — the store must be exactly as before")
    }

    func testDiscardAfterRegradeUndoesOnlyTheLatestGrade() throws {
        // recordReview already undoes the PRIOR forwarded outcome on each
        // re-grade; the discard rollback must undo the LATEST exactly once
        // — never double-undo into a past ride's counters.
        let (segments, zones) = try fixtureSegmentsAndZones()
        let store = PersonalMemoryStore()
        let engine = RideEngine(segments: segments, zones: zones, personalMemoryStore: store,
                                rideID: "discard-regrade",
                                startedAt: "2026-07-27T00:00:00Z")
        ride(engine)
        let cues = engine.recorder.cueSummaries
        XCTAssertEqual(cues.count, 1)

        engine.recordReview(eventID: cues[0].eventID, outcome: .falseAlarm)
        engine.recordReview(eventID: cues[0].eventID, outcome: .useful)
        engine.recordReview(eventID: cues[0].eventID, outcome: .falseAlarm)

        engine.undoPersonalMemoryContributions()
        XCTAssertEqual(store.recordCount, 0)
    }

    func testDiscardPreservesEvidenceFromPastRides() throws {
        let (segments, zones) = try fixtureSegmentsAndZones()
        let store = PersonalMemoryStore()
        let squeezeSegment = zones[0].segmentIDs[0]
        // A PAST ride (or custom-zone import) already marked the squeeze
        // segment unsafe — history the discard must not erase.
        store.recordUnsafeMarker(segmentID: squeezeSegment)

        let engine = RideEngine(segments: segments, zones: zones, personalMemoryStore: store,
                                rideID: "discard-preserve-history",
                                startedAt: "2026-07-27T01:00:00Z")
        ride(engine)
        if let cue = engine.recorder.cueSummaries.first {
            engine.recordReview(eventID: cue.eventID, outcome: .falseAlarm)
        }
        XCTAssertTrue(engine.mark())

        engine.undoPersonalMemoryContributions()
        XCTAssertEqual(store.recordCount, 1, "the past ride's record must survive the discard")
        XCTAssertEqual(store.resolved(for: squeezeSegment)?.state, .unsafe,
                       "the past ride's marker still dominates after this ride's rollback")
    }

    func testDiscardRollbackIsIdempotent() throws {
        let (segments, zones) = try fixtureSegmentsAndZones()
        let store = PersonalMemoryStore()
        let squeezeSegment = zones[0].segmentIDs[0]
        store.recordUnsafeMarker(segmentID: squeezeSegment)

        let engine = RideEngine(segments: segments, zones: zones, personalMemoryStore: store,
                                rideID: "discard-idempotent",
                                startedAt: "2026-07-27T02:00:00Z")
        ride(engine)
        XCTAssertTrue(engine.mark())

        engine.undoPersonalMemoryContributions()
        engine.undoPersonalMemoryContributions()
        // A second call must not eat the past ride's marker.
        XCTAssertEqual(store.resolved(for: squeezeSegment)?.state, .unsafe)
    }
}
