// Intent: End-to-end proof that RFC 0002 personal route memory actually
//         changes live cueing through the full pipeline (PersonalMemoryStore
//         -> RideEngine.resolveMemory -> CuePolicy.step -> kernel), not just
//         at the unit level (kernel: PersonalMemoryStoreTests covers D2/D4/
//         D7 in isolation; test_cue_policy.c covers the gate itself).
// Layout: Fixture geometry duplicated from ReviewRecordingTests (approach
//         way 100 -> squeeze way 200 -> exit way 300), a known-good ride
//         that cues exactly once without memory — the baseline this suite
//         changes the outcome of.
import CueKernel
import XCTest
@testable import CueMapImport
@testable import CueRideEngine

final class PersonalMemoryIntegrationTests: XCTestCase {
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

    /// Eastbound at 6 m/s, 1 Hz, ~2.2 m north of the centerline — the same
    /// approach -> squeeze ride ReviewRecordingTests proves cues exactly
    /// once with no memory in play.
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

    func testStorePrePopulatedWithFalseAlarmsSuppressesTheRide() throws {
        let (segments, zones) = try fixtureSegmentsAndZones()
        let store = PersonalMemoryStore()
        // D2: false_alarm >= 2 and > useful suppresses.
        store.recordReview(segmentID: zones[0].segmentIDs[0], outcome: .falseAlarm)
        store.recordReview(segmentID: zones[0].segmentIDs[0], outcome: .falseAlarm)

        let engine = RideEngine(segments: segments, zones: zones, personalMemoryStore: store,
                                rideID: "memory-integration-suppress",
                                startedAt: "2026-07-22T00:00:00Z")
        ride(engine)

        XCTAssertTrue(engine.recorder.cueSummaries.isEmpty,
                      "SUPPRESS should have blocked the cue this fixture otherwise fires")
    }

    func testReviewFromOneRideSuppressesCueOnALaterRide() throws {
        let (segments, zones) = try fixtureSegmentsAndZones()
        let sharedStore = PersonalMemoryStore()

        // Ride A: no memory yet — cues normally, then gets graded via the
        // engine (not direct store manipulation) so this test also proves
        // recordReview's segment_id attribution, not just the store API.
        // Two SEPARATE rides each grade the recurring event false_alarm
        // ONCE — independent evidence across rides, not one rider re-
        // tapping the same cue (RideEngine.recordReview undoes a re-grade
        // of the SAME event on the SAME ride instance before re-applying,
        // so repeated taps on one cue cannot inflate the store — see
        // testRegradingTheSameEventDoesNotInflateTheStore below).
        for rideIndex in 0..<2 {
            let ride_ = RideEngine(segments: segments, zones: zones, personalMemoryStore: sharedStore,
                                   rideID: "memory-integration-ride-a\(rideIndex)",
                                   startedAt: "2026-07-22T0\(rideIndex):00:00Z")
            ride(ride_)
            let cues = ride_.recorder.cueSummaries
            XCTAssertEqual(cues.count, 1, "each ride must cue once, matching ReviewRecordingTests' baseline")
            ride_.recordReview(eventID: cues[0].eventID, outcome: .falseAlarm)
        }

        // Ride B: same route, same shared store — must NOT cue this time.
        let rideB = RideEngine(segments: segments, zones: zones, personalMemoryStore: sharedStore,
                               rideID: "memory-integration-ride-b",
                               startedAt: "2026-07-22T02:00:00Z")
        ride(rideB)
        XCTAssertTrue(rideB.recorder.cueSummaries.isEmpty,
                      "ride B should be suppressed by two prior rides' stored reviews")
    }

    func testRegradingTheSameEventDoesNotInflateTheStore() throws {
        // The trace has ONE outcome per reviewed cue (addReview replaces);
        // the store must mirror that, not count every tap, or reconsidering
        // a grade a few times would wrongly cross the D2 suppress threshold
        // on repeated taps of ONE cue instead of independent evidence.
        let (segments, zones) = try fixtureSegmentsAndZones()
        let store = PersonalMemoryStore()
        let engine = RideEngine(segments: segments, zones: zones, personalMemoryStore: store,
                                rideID: "memory-integration-regrade",
                                startedAt: "2026-07-22T00:00:00Z")
        ride(engine)
        let cues = engine.recorder.cueSummaries
        XCTAssertEqual(cues.count, 1)

        engine.recordReview(eventID: cues[0].eventID, outcome: .falseAlarm)
        engine.recordReview(eventID: cues[0].eventID, outcome: .useful)
        engine.recordReview(eventID: cues[0].eventID, outcome: .falseAlarm)

        let resolved = store.resolved(for: zones[0].segmentIDs[0])
        // Net contribution of THIS event after three re-grades must be
        // exactly one false_alarm (the latest), not two.
        XCTAssertEqual(resolved?.state, .neutral,
                       "one false_alarm alone must not suppress (FALSE_ALARM_MIN = 2, NFR-001)")
    }

    func testExportedTraceCarriesPersonalMemoryChangePoints() throws {
        // Closes the NFR-003 loop: a live decision memory influenced must
        // be replayable, so the export must actually carry personal_memory[]
        // (RFC 0002 D6) — not just resolve memory in-process.
        let (segments, zones) = try fixtureSegmentsAndZones()
        let store = PersonalMemoryStore()
        store.recordReview(segmentID: zones[0].segmentIDs[0], outcome: .falseAlarm)
        store.recordReview(segmentID: zones[0].segmentIDs[0], outcome: .falseAlarm)

        let engine = RideEngine(segments: segments, zones: zones, personalMemoryStore: store,
                                rideID: "memory-integration-export",
                                startedAt: "2026-07-22T00:00:00Z")
        ride(engine)

        let trace = try JSONSerialization.jsonObject(
            with: engine.recorder.exportPolicyTrace()) as! [String: Any]
        XCTAssertEqual(trace["schema_version"] as? Int, 2)
        let personalMemory = trace["personal_memory"] as! [[String: Any]]

        // SUPPRESS is active on the squeeze segment from the very first
        // sample that observes it and stays active through the ride's own
        // LAST sample (the store never changes mid-ride) — carry-forward
        // compression must log exactly ONE change point (the activation),
        // not one per sample. This is intentionally NOT 2: the exporter
        // does not append a synthetic terminal clear record (see the
        // "Deliberately NOT appending" comment in RideTraceRecorder's
        // export) — doing so would make the ride's OWN last sample replay
        // under NEUTRAL even though it was decided live under SUPPRESS,
        // since carry-forward records take effect inclusive of their own
        // t_ms. A trace ending non-neutral is the expected, correct shape
        // here, not a gap; replay's own end-of-trace warning is the
        // deliberate (advisory, non-failing) signal for it.
        XCTAssertEqual(personalMemory.count, 1,
                      "carry-forward must log only the CHANGE, not every sample")
        let record = personalMemory[0]
        XCTAssertEqual(record["state"] as? String, "SUPPRESS")
        XCTAssertEqual(record["segment_id"] as? Int, Int(zones[0].segmentIDs[0]))
        XCTAssertEqual(record["notice_bonus_s"] as? Int, 0)
        // The logged t_ms must be an actual sample timestamp (replay's
        // trace-shape validation requires this — Phase 2, replay_main.c).
        let sampleTimes = Set((trace["samples"] as! [[String: Any]]).map { $0["t_ms"] as! Int })
        XCTAssertTrue(sampleTimes.contains(record["t_ms"] as! Int))
    }

    func testExportedTraceOmitsPersonalMemoryWhenNeverActive() throws {
        let (segments, zones) = try fixtureSegmentsAndZones()
        let engine = RideEngine(segments: segments, zones: zones,
                                rideID: "memory-integration-export-empty",
                                startedAt: "2026-07-22T00:00:00Z")
        ride(engine)
        let trace = try JSONSerialization.jsonObject(
            with: engine.recorder.exportPolicyTrace()) as! [String: Any]
        XCTAssertEqual(trace["schema_version"] as? Int, 2)
        XCTAssertEqual((trace["personal_memory"] as! [Any]).count, 0)
    }

    func testMemoryClearingMidRideLogsClearRecordCarryingTheSameSegmentID() throws {
        // Regression: the clear-record fallback used to emit segment_id 0
        // (the RFC 0002 D5 "no record" sentinel) for a mid-ride deactivation,
        // which replay_main.c's decoder rejects outright — any real ride
        // that entered then cleared a remembered segment would fail to
        // replay (an NFR-003 violation). The clear record must instead
        // carry the segment it is clearing, with state NEUTRAL.
        let (segments, zones) = try fixtureSegmentsAndZones()
        let store = PersonalMemoryStore()
        let segmentID = zones[0].segmentIDs[0]
        store.recordReview(segmentID: segmentID, outcome: .falseAlarm)
        store.recordReview(segmentID: segmentID, outcome: .falseAlarm)

        let engine = RideEngine(segments: segments, zones: zones, personalMemoryStore: store,
                                rideID: "memory-integration-clear-mid-ride",
                                startedAt: "2026-07-22T00:00:00Z")
        func fix(_ second: Int) -> RideFix {
            RideFix(tMs: UInt32(second * 1000), lat: 0.00002,
                   lon: -0.004 + 6.0 * Double(second) / 111_320.0,
                   speedMps: 6.0, headingDeg: 90)
        }
        for second in 0..<80 { engine.process(fix(second)) }
        // One false_alarm alone no longer suppresses (FALSE_ALARM_MIN = 2, NFR-001).
        store.undoReview(segmentID: segmentID, outcome: .falseAlarm)
        for second in 80..<120 { engine.process(fix(second)) }

        let trace = try JSONSerialization.jsonObject(
            with: engine.recorder.exportPolicyTrace()) as! [String: Any]
        let personalMemory = trace["personal_memory"] as! [[String: Any]]
        XCTAssertEqual(personalMemory.count, 2, "activation then clear")
        XCTAssertEqual(personalMemory[0]["state"] as? String, "SUPPRESS")
        XCTAssertEqual(personalMemory[0]["segment_id"] as? Int, Int(segmentID))
        XCTAssertEqual(personalMemory[1]["state"] as? String, "NEUTRAL")
        XCTAssertEqual(personalMemory[1]["segment_id"] as? Int, Int(segmentID),
                      "the clear record must carry the segment it clears, never the reserved 0 sentinel")
    }

    // MARK: - Directional custom zones (cue#30)

    /// The mirror image of `ride`: same road, travelled the other way, so the
    /// only thing that differs between the two assertions below is direction.
    private func rideWestbound(_ engine: RideEngine) {
        for second in 0..<120 {
            engine.process(RideFix(
                tMs: UInt32(second * 1000),
                lat: 0.00002,
                lon: 0.009 - 6.0 * Double(second) / 111_320.0,
                speedMps: 6.0,
                headingDeg: 270))
        }
    }

    private func activeMemoryStates(in engine: RideEngine) throws -> [String] {
        let trace = try JSONSerialization.jsonObject(
            with: engine.recorder.exportPolicyTrace()) as! [String: Any]
        return (trace["personal_memory"] as! [[String: Any]]).compactMap { $0["state"] as? String }
    }

    func testDirectionalZoneAppliesRidingWithItAndNotAgainstIt() throws {
        let (segments, zones) = try fixtureSegmentsAndZones()
        let segmentID = zones[0].segmentIDs[0]
        // The fixture's ways run east, so the squeeze segment's node order
        // does too — .forward is the eastbound pass. Pinned rather than
        // assumed: the whole test turns on it.
        let bearing = segments.first { $0.id == segmentID }?.nodeOrderBearingDeg
        XCTAssertEqual(try XCTUnwrap(bearing), 90, accuracy: 1)

        let eastbound = PersonalMemoryStore()
        eastbound.recordUnsafeZone(segmentID: segmentID, directions: .forward)
        let withTheZone = RideEngine(segments: segments, zones: zones,
                                     personalMemoryStore: eastbound,
                                     rideID: "directional-with",
                                     startedAt: "2026-07-22T00:00:00Z")
        ride(withTheZone)
        XCTAssertEqual(try activeMemoryStates(in: withTheZone), ["UNSAFE"],
                       "riding the way the zone was drawn must apply it")

        let againstIt = RideEngine(segments: segments, zones: zones,
                                   personalMemoryStore: eastbound,
                                   rideID: "directional-against",
                                   startedAt: "2026-07-22T01:00:00Z")
        rideWestbound(againstIt)
        XCTAssertEqual(try activeMemoryStates(in: againstIt), [],
                       "riding the other way must leave the zone silent — this is the whole point")
    }

    func testABidirectionalZoneStillAppliesBothWays() throws {
        // Regression guard: a zone drawn without `directional`, and every
        // in-ride marker tap, must behave exactly as before cue#30.
        let (segments, zones) = try fixtureSegmentsAndZones()
        let store = PersonalMemoryStore()
        store.recordUnsafeMarker(segmentID: zones[0].segmentIDs[0])

        let eastbound = RideEngine(segments: segments, zones: zones, personalMemoryStore: store,
                                   rideID: "bidirectional-east",
                                   startedAt: "2026-07-22T00:00:00Z")
        ride(eastbound)
        let westbound = RideEngine(segments: segments, zones: zones, personalMemoryStore: store,
                                   rideID: "bidirectional-west",
                                   startedAt: "2026-07-22T01:00:00Z")
        rideWestbound(westbound)

        XCTAssertEqual(try activeMemoryStates(in: eastbound), ["UNSAFE"])
        XCTAssertEqual(try activeMemoryStates(in: westbound), ["UNSAFE"])
    }

    /// A one-sample course reversal costs one sample of memory, and cue#30
    /// neither improved nor worsened that: `RouteEventTracker.approachGateDeg`
    /// is a DIRECTED 90° gate, so a reversed course drops the zone's route
    /// event outright for that sample, and no event means no memory to
    /// resolve — the same clear-and-reactivate this ride logged before the
    /// direction gate existed. The `latchedDirection` cache cannot prevent
    /// it (it holds a direction for a segment IN play, and this segment
    /// leaves play for that sample); pinning the shape here so a future
    /// change to either gate has to notice it.
    func testAReversedCourseSampleCostsOneSampleOfMemoryAsItAlwaysHas() throws {
        let (segments, zones) = try fixtureSegmentsAndZones()
        let store = PersonalMemoryStore()
        store.recordUnsafeZone(segmentID: zones[0].segmentIDs[0], directions: .forward)
        let engine = RideEngine(segments: segments, zones: zones, personalMemoryStore: store,
                                rideID: "directional-heading-spike",
                                startedAt: "2026-07-22T00:00:00Z")
        for second in 0..<120 {
            engine.process(RideFix(
                tMs: UInt32(second * 1000),
                lat: 0.00002,
                lon: -0.004 + 6.0 * Double(second) / 111_320.0,
                speedMps: 6.0,
                headingDeg: second == 60 ? 270 : 90))
        }
        XCTAssertEqual(try activeMemoryStates(in: engine), ["UNSAFE", "NEUTRAL", "UNSAFE"])
    }

    /// The reviewer's case on #32: one bad course on the first fix used to
    /// latch the wrong direction and gate a directional zone out for the
    /// WHOLE approach — a suppressed cue, strictly worse than the pre-cue#30
    /// behavior of applying the record both ways. Corroboration bounds it to
    /// the single spiked sample.
    func testAFirstFixCourseSpikeDoesNotSuppressTheApproach() throws {
        let (segments, zones) = try fixtureSegmentsAndZones()
        let store = PersonalMemoryStore()
        store.recordUnsafeZone(segmentID: zones[0].segmentIDs[0], directions: .forward)
        let engine = RideEngine(segments: segments, zones: zones, personalMemoryStore: store,
                                rideID: "directional-first-fix-spike",
                                startedAt: "2026-07-22T00:00:00Z")
        for second in 0..<120 {
            engine.process(RideFix(
                tMs: UInt32(second * 1000),
                lat: 0.00002,
                lon: -0.004 + 6.0 * Double(second) / 111_320.0,
                speedMps: 6.0,
                // 269 is 91 degrees off the eastbound segment — just past the
                // gate, so it resolves backward.
                headingDeg: second == 0 ? 269 : 90))
        }
        XCTAssertEqual(try activeMemoryStates(in: engine), ["UNSAFE"],
                       "one bad fix must cost one sample, not the whole approach")
    }

    /// Two events in one step can name the same segment, and resolving
    /// direction per EVENT advanced the corroboration counter twice on a
    /// single fix — latching in one step and defeating the guard, so a
    /// first-fix spike would suppress the approach after all.
    ///
    /// SqueezeScorer partitions segments, so its zones never share one; the
    /// zones are therefore built BY HAND here and handed straight to
    /// RideEngine, which takes them as a parameter. Driving this through the
    /// scorer's own output would not exercise the dedup at all — the version
    /// of this test that did was passing whether the dedup existed or not.
    func testTwoEventsOnOneSegmentDoNotLatchInASingleStep() throws {
        let (segments, scored) = try fixtureSegmentsAndZones()
        let shared = scored[0]
        let overlapping = [
            shared,
            SqueezeZone(eventID: shared.eventID &+ 1, segmentIDs: shared.segmentIDs,
                        severity: shared.severity, confidence: shared.confidence,
                        reasonsBitmask: shared.reasonsBitmask, lengthM: shared.lengthM),
        ]
        let store = PersonalMemoryStore()
        store.recordUnsafeZone(segmentID: shared.segmentIDs[0], directions: .forward)
        let engine = RideEngine(segments: segments, zones: overlapping,
                                personalMemoryStore: store,
                                rideID: "directional-overlapping-events",
                                startedAt: "2026-07-22T00:00:00Z")
        for second in 0..<120 {
            engine.process(RideFix(
                tMs: UInt32(second * 1000),
                lat: 0.00002,
                lon: -0.004 + 6.0 * Double(second) / 111_320.0,
                speedMps: 6.0,
                // Two events name this segment every step, so without the
                // per-segment dedup this one spiked fix corroborates itself
                // and latches .backward for the whole approach.
                headingDeg: second == 0 ? 269 : 90))
        }
        XCTAssertEqual(try activeMemoryStates(in: engine), ["UNSAFE"],
                       "one bad fix must still cost one sample, not the approach")
    }

    /// A too_late notice bonus is orthogonal to unsafe/suppress and applies
    /// for ANY state (RFC 0002 D4), so a NEUTRAL record carrying one is a
    /// real kernel input, not a leak — and the recorder logs it, so replay
    /// exercises exactly what the live path sent. Pins both halves: the
    /// change point exists, and it carries the bonus.
    func testANeutralRecordWithANoticeBonusIsRecordedForReplay() throws {
        let (segments, zones) = try fixtureSegmentsAndZones()
        let segmentID = zones[0].segmentIDs[0]
        let store = PersonalMemoryStore()
        // too_late review (bonus, no keep/kill state) + a zone pointing the
        // other way, so this ride resolves NEUTRAL while the bonus stands.
        store.recordReview(segmentID: segmentID, outcome: .tooLate)
        store.replaceUnsafeZones(directionsBySegment: [segmentID: .backward])

        let engine = RideEngine(segments: segments, zones: zones, personalMemoryStore: store,
                                rideID: "neutral-with-bonus",
                                startedAt: "2026-07-22T00:00:00Z")
        ride(engine)  // eastbound: the .backward zone does not apply

        let trace = try JSONSerialization.jsonObject(
            with: engine.recorder.exportPolicyTrace()) as! [String: Any]
        let memory = trace["personal_memory"] as! [[String: Any]]
        XCTAssertEqual(memory.count, 1, "a bonus-carrying NEUTRAL must reach the trace")
        XCTAssertEqual(memory[0]["state"] as? String, "NEUTRAL")
        XCTAssertEqual(memory[0]["notice_bonus_s"] as? Int, 2)
    }

    /// The offline resolver and the live engine each declare a latch
    /// threshold, and their agreeing is the entire basis for a desk what-if
    /// predicting what the phone did. Nothing else fails if one is bumped.
    func testLiveAndOfflineLatchThresholdsAgree() {
        XCTAssertEqual(RideEngine.directionLatchSamples,
                       CustomZoneImport.directionLatchSamples)
    }

    func testUnaffectedRideStillCuesNormally() throws {
        // Regression guard: an engine with a fresh, empty store (the
        // default) behaves exactly as the pre-Phase-3 baseline.
        let (segments, zones) = try fixtureSegmentsAndZones()
        let engine = RideEngine(segments: segments, zones: zones,
                                rideID: "memory-integration-baseline",
                                startedAt: "2026-07-22T00:00:00Z")
        ride(engine)
        XCTAssertEqual(engine.recorder.cueSummaries.count, 1)
    }
}
