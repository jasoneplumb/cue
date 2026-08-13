// Intent: Ride-engine tests on SYNTHETIC geometry (fake ids, equator
//         coordinates — NFR-005). The load-bearing properties: a full
//         approach ride emits exactly one HEAD_UP with a lead time inside
//         the spec notice window (FR-004), inside-zone samples gate as
//         INSIDE_EVENT, departed zones are dropped by the directed gate,
//         unmatched fixes record segment 0, the policy export carries no
//         GPS keys (NFR-005), and — the NFR-003 leg — the exported trace
//         re-fed through a fresh kernel reproduces every decision.
// Layout: way 100 "approach" (residential, lon -0.004→0) shares node 10
//         with way 200 "squeeze" (secondary, lanes=2, 45 mph, cycleway=no,
//         lon 0→0.007 → one merged zone, endpoints 10/17), which shares
//         node 17 with way 300 "exit" (residential, lon 0.007→0.009).
import CCuePolicy
import CueKernel
import XCTest
@testable import CueMapImport
@testable import CueRideEngine

final class RideEngineTests: XCTestCase {
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

    private func makeEngine(rideID: String = "test-ride",
                            debugGPS: Bool = false) throws -> (RideEngine, SqueezeZone) {
        let segments = try SegmentImporter.deriveSegments(
            from: OverpassExtract(ways: [Self.approachWay, Self.squeezeWay, Self.exitWay]))
        let zones = SqueezeScorer.scoreZones(from: segments)
        XCTAssertEqual(zones.count, 1, "fixture must score exactly one zone")
        let engine = RideEngine(segments: segments, zones: zones,
                                rideID: rideID, startedAt: "2026-07-11T00:00:00Z",
                                debugGPS: debugGPS)
        return (engine, zones[0])
    }

    /// Eastbound fixes at 6 m/s, 1 Hz, ~2.2 m north of the centerline.
    private func eastboundFix(second: Int, startLon: Double) -> RideFix {
        RideFix(tMs: UInt32(second * 1000),
                lat: 0.00002,
                lon: startLon + 6.0 * Double(second) / 111_320.0,
                speedMps: 6.0,
                headingDeg: 90)
    }

    // MARK: - The headline ride: approach → one cue in window → inside

    func testApproachRideCuesExactlyOnceInsideNoticeWindow() throws {
        let (engine, zone) = try makeEngine()
        var headUps: [CueDecision] = []
        var sawInside = false
        for second in 0..<120 {
            guard let decision = engine.process(
                eastboundFix(second: second, startLon: -0.004)) else {
                XCTFail("no fix should be dropped")
                continue
            }
            if decision.isHeadUp { headUps.append(decision) }
            if decision.reason_code == UInt8(CUE_REASON_CODE_INSIDE_EVENT) {
                sawInside = true
            }
        }
        XCTAssertEqual(headUps.count, 1, "one HEAD_UP per event (FR-004)")
        let cue = try XCTUnwrap(headUps.first)
        XCTAssertEqual(cue.event_id, zone.eventID)
        // The engine was built without a config, so it runs the shipped
        // defaults — read the window off those rather than restating it, or
        // a §13 retune of min/max_notice_s silently falsifies this test.
        let defaults = CuePolicy.defaultConfig()
        let window = Int(defaults.min_notice_s)...Int(defaults.max_notice_s)
        XCTAssertTrue(window.contains(Int(cue.lead_time_s)),
                      "lead time \(cue.lead_time_s)s outside notice window \(window)")
        XCTAssertTrue(sawInside, "riding through the zone must gate INSIDE_EVENT")
    }

    // MARK: - Directed gate: departed zones drop; returning approach emits

    func testDepartedZoneIsDroppedByDirectedGate() throws {
        let (engine, _) = try makeEngine()
        // On the exit way ~170 m past the zone's east endpoint, riding away:
        // the zone must produce no observation (reason 1 = NO_EVENT).
        let away = try XCTUnwrap(engine.process(
            RideFix(tMs: 1000, lat: 0.00002, lon: 0.0085, speedMps: 6, headingDeg: 90)))
        XCTAssertEqual(away.reason_code, UInt8(CUE_REASON_CODE_NO_EVENT))

        // Same spot facing the zone: the observation emits, and at ~28 s
        // out the kernel gates TOO_EARLY — proof the event was seen.
        let (returning, _) = try makeEngine()
        let toward = try XCTUnwrap(returning.process(
            RideFix(tMs: 1000, lat: 0.00002, lon: 0.0085, speedMps: 6, headingDeg: 270)))
        XCTAssertEqual(toward.reason_code, UInt8(CUE_REASON_CODE_TOO_EARLY))
    }

    // MARK: - Sampling contract

    func testUnmatchedFixRecordsSegmentZero() throws {
        let (engine, _) = try makeEngine()
        let decision = try XCTUnwrap(engine.process(
            RideFix(tMs: 1000, lat: 0.01, lon: 0.002, speedMps: 6, headingDeg: 90)))
        XCTAssertEqual(decision.reason_code, UInt8(CUE_REASON_CODE_NO_EVENT))
        let trace = try JSONSerialization.jsonObject(
            with: engine.recorder.exportPolicyTrace()) as! [String: Any]
        let samples = trace["samples"] as! [[String: Any]]
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0]["segment_id"] as? UInt32, 0)
    }

    func testNonFiniteValuesNeverTrap() throws {
        let (engine, _) = try makeEngine()
        // Non-finite coordinates: fix dropped (no honest sample exists).
        XCTAssertNil(engine.process(
            RideFix(tMs: 1000, lat: .nan, lon: -0.004, speedMps: 6, headingDeg: 90)))
        XCTAssertNil(engine.process(
            RideFix(tMs: 1000, lat: 0.00002, lon: .infinity, speedMps: 6, headingDeg: 90)))
        // Out-of-range finite coordinates are equally corrupt: dropped.
        XCTAssertNil(engine.process(
            RideFix(tMs: 1000, lat: 300, lon: -0.004, speedMps: 6, headingDeg: 90)))
        XCTAssertNil(engine.process(
            RideFix(tMs: 1000, lat: 0.00002, lon: -200, speedMps: 6, headingDeg: 90)))
        // Non-finite heading/speed degrade to unknown/0 — position still counts.
        let degraded = try XCTUnwrap(engine.process(
            RideFix(tMs: 1000, lat: 0.00002, lon: -0.004, speedMps: .nan,
                    headingDeg: .nan)))
        XCTAssertEqual(degraded.reason_code, UInt8(CUE_REASON_CODE_TOO_SLOW))
        let trace = try JSONSerialization.jsonObject(
            with: engine.recorder.exportPolicyTrace()) as! [String: Any]
        let samples = trace["samples"] as! [[String: Any]]
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0]["speed_cmps"] as? Int, 0)
        // Unknown course exports as an ABSENT key, never as "due north".
        XCTAssertNil(samples[0]["heading_deg_x10"])
    }

    func testNonIncreasingTimestampIsDropped() throws {
        let (engine, _) = try makeEngine()
        XCTAssertNotNil(engine.process(
            RideFix(tMs: 1000, lat: 0.00002, lon: -0.004, speedMps: 6, headingDeg: 90)))
        XCTAssertNil(engine.process(
            RideFix(tMs: 1000, lat: 0.00002, lon: -0.0039, speedMps: 6, headingDeg: 90)))
        XCTAssertNil(engine.process(
            RideFix(tMs: 500, lat: 0.00002, lon: -0.0039, speedMps: 6, headingDeg: 90)))
        let trace = try JSONSerialization.jsonObject(
            with: engine.recorder.exportPolicyTrace()) as! [String: Any]
        XCTAssertEqual((trace["samples"] as! [Any]).count, 1)
    }

    // MARK: - Export (FR-009, NFR-005)

    func testPolicyExportOmitsGPSAndMatchesSchemaShape() throws {
        let (engine, _) = try makeEngine()
        for second in 0..<80 {
            engine.process(eastboundFix(second: second, startLon: -0.004))
        }
        let trace = try JSONSerialization.jsonObject(
            with: engine.recorder.exportPolicyTrace()) as! [String: Any]

        for key in ["schema_version", "ride_id", "started_at", "policy_config",
                    "samples", "route_events", "cue_decisions", "markers", "reviews",
                    "personal_memory"] {
            XCTAssertNotNil(trace[key], "missing required key \(key)")
        }
        // RFC 0002 D6: schema_version 2 now that live cueing can be
        // memory-influenced; personal_memory[] is simply empty when (as
        // here) the engine's store never resolved anything this ride.
        XCTAssertEqual(trace["schema_version"] as? Int, 2)
        XCTAssertEqual((trace["personal_memory"] as! [Any]).count, 0)

        let samples = trace["samples"] as! [[String: Any]]
        XCTAssertEqual(samples.count, 80)
        for sample in samples {
            XCTAssertNil(sample["lat_e7"], "policy trace must carry no GPS (NFR-005)")
            XCTAssertNil(sample["lon_e7"])
            // These fixes all carried a course: heading must be present.
            XCTAssertNotNil(sample["heading_deg_x10"])
        }
        // Strictly increasing t_ms (replay harness requirement).
        let times = samples.map { $0["t_ms"] as! Int }
        XCTAssertEqual(times, times.sorted())
        XCTAssertEqual(Set(times).count, times.count)

        let observations = trace["route_events"] as! [[String: Any]]
        XCTAssertFalse(observations.isEmpty)
        XCTAssertEqual(observations[0]["family"] as? String, "COMPOSITE_SQUEEZE_ZONE")

        // Without the per-ride debugGPS opt-in, nothing was retained: even
        // the debug export carries no coordinates (NFR-005).
        let unretained = try JSONSerialization.jsonObject(
            with: engine.recorder.exportDebugTrace()) as! [String: Any]
        XCTAssertNil((unretained["samples"] as! [[String: Any]])[0]["lat_e7"])

        // Debug export on an opted-in ride is the only place GPS appears.
        let (debugEngine, _) = try makeEngine(debugGPS: true)
        debugEngine.process(eastboundFix(second: 0, startLon: -0.004))
        let debug = try JSONSerialization.jsonObject(
            with: debugEngine.recorder.exportDebugTrace()) as! [String: Any]
        let debugSamples = debug["samples"] as! [[String: Any]]
        XCTAssertNotNil(debugSamples[0]["lat_e7"])
        // ... and its POLICY export still strips them.
        let debugPolicy = try JSONSerialization.jsonObject(
            with: debugEngine.recorder.exportPolicyTrace()) as! [String: Any]
        XCTAssertNil((debugPolicy["samples"] as! [[String: Any]])[0]["lat_e7"])
    }

    func testExportIsDeterministic() throws {
        let (first, _) = try makeEngine()
        let (second, _) = try makeEngine()
        for second_ in 0..<60 {
            first.process(eastboundFix(second: second_, startLon: -0.004))
            second.process(eastboundFix(second: second_, startLon: -0.004))
        }
        XCTAssertEqual(try first.recorder.exportPolicyTrace(),
                       try second.recorder.exportPolicyTrace())
    }

    // MARK: - Markers (D5, FR-006…007)

    func testMarkAnchorsToNearestSampleAndExportsWithoutGPS() throws {
        let (engine, _) = try makeEngine()
        for second in 0..<10 {
            engine.process(eastboundFix(second: second, startLon: -0.004))
        }
        // Immediate mark: anchors to the latest sample (t_ms 9000).
        XCTAssertTrue(engine.mark())
        // Late-arriving queued watch marker pressed at t_ms ~3400:
        // nearest sample is 3000, NOT wherever the rider is now.
        XCTAssertTrue(engine.mark(atTMs: 3400))
        let trace = try JSONSerialization.jsonObject(
            with: engine.recorder.exportPolicyTrace()) as! [String: Any]
        let markers = trace["markers"] as! [[String: Any]]
        XCTAssertEqual(markers.count, 2)
        // Chronological export order, not delivery order: the late-
        // arriving queued marker (t_ms 3000) sorts before the earlier-
        // DELIVERED immediate marker (t_ms 9000).
        XCTAssertEqual(markers[0]["t_ms"] as? Int, 3000)
        XCTAssertEqual(markers[1]["t_ms"] as? Int, 9000)
        XCTAssertEqual(markers[0]["type"] as? String, "unsafe_here")
        let samples = trace["samples"] as! [[String: Any]]
        XCTAssertEqual(markers[0]["segment_id"] as? Int,
                       samples[3]["segment_id"] as? Int)
        for marker in markers {
            XCTAssertNil(marker["lat_e7"], "policy trace markers carry no GPS")
            XCTAssertNil(marker["lon_e7"])
        }
    }

    func testMarkBeforeFirstSampleIsRejected() throws {
        let (engine, _) = try makeEngine()
        XCTAssertFalse(engine.mark(), "no position to anchor to yet")
        let trace = try JSONSerialization.jsonObject(
            with: engine.recorder.exportPolicyTrace()) as! [String: Any]
        XCTAssertEqual((trace["markers"] as! [Any]).count, 0)
    }

    func testDebugRideMarkersCarryGPS() throws {
        let (engine, _) = try makeEngine(debugGPS: true)
        engine.process(eastboundFix(second: 0, startLon: -0.004))
        XCTAssertTrue(engine.mark())
        let debug = try JSONSerialization.jsonObject(
            with: engine.recorder.exportDebugTrace()) as! [String: Any]
        let markers = debug["markers"] as! [[String: Any]]
        XCTAssertNotNil(markers[0]["lat_e7"])
        // ... and even on a debug ride, the POLICY export strips them.
        let policy = try JSONSerialization.jsonObject(
            with: engine.recorder.exportPolicyTrace()) as! [String: Any]
        XCTAssertNil((policy["markers"] as! [[String: Any]])[0]["lat_e7"])
    }

    // MARK: - NFR-003: the exported trace reproduces every live decision

    func testExportedTraceReplaysDivergenceFree() throws {
        let (engine, _) = try makeEngine()
        for second in 0..<120 {
            engine.process(eastboundFix(second: second, startLon: -0.004))
        }
        let trace = try JSONSerialization.jsonObject(
            with: engine.recorder.exportPolicyTrace()) as! [String: Any]
        let samples = trace["samples"] as! [[String: Any]]
        let observations = trace["route_events"] as! [[String: Any]]
        let recorded = trace["cue_decisions"] as! [[String: Any]]
        XCTAssertEqual(samples.count, recorded.count,
                       "every sample logs its decision")

        // Replay the trace exactly as replay_cli does: per sample, feed the
        // observations stamped with its t_ms, in array order, to a FRESH
        // kernel with the trace's config. Live and replay must agree on
        // every decision — divergence is the bug class this repo names.
        let replay = CuePolicy()  // engine ran spec §8 defaults
        let observationsByTMs = Dictionary(grouping: observations) {
            UInt32($0["t_ms"] as! Int)
        }
        for (index, sample) in samples.enumerated() {
            let tMs = UInt32(sample["t_ms"] as! Int)
            let events = (observationsByTMs[tMs] ?? [])
                .map { observation in
                    RouteEvent(
                        event_id: UInt32(observation["event_id"] as! Int),
                        family: UInt8(CUE_EVENT_FAMILY_COMPOSITE_SQUEEZE_ZONE),
                        segment_id: UInt32(observation["segment_id"] as! Int),
                        severity: UInt8(observation["severity"] as! Int),
                        confidence: UInt8(observation["confidence"] as! Int),
                        reasons_bitmask: UInt16(observation["reasons_bitmask"] as! Int),
                        distance_to_start_m: Int16(observation["distance_to_start_m"] as! Int),
                        distance_to_end_m: Int16(observation["distance_to_end_m"] as! Int))
                }
            let decision = replay.step(
                RideSample(t_ms: tMs, lat_e7: 0, lon_e7: 0,
                           speed_cmps: UInt16(sample["speed_cmps"] as! Int),
                           // From the trace, exactly as replay_cli reads it
                           // (opt_u16 defaults an absent key to 0) — a future
                           // heading-sensitive kernel must not slip past
                           // this test unnoticed.
                           heading_deg_x10: UInt16(sample["heading_deg_x10"] as? Int ?? 0),
                           segment_id: UInt32(sample["segment_id"] as! Int)),
                events: events)
            let expected = recorded[index]
            XCTAssertEqual(decision.isHeadUp ? "HEAD_UP" : "NONE",
                           expected["type"] as? String, "t_ms \(tMs)")
            XCTAssertEqual(Int(decision.event_id), expected["event_id"] as? Int, "t_ms \(tMs)")
            XCTAssertEqual(Int(decision.reason_code), expected["reason_code"] as? Int, "t_ms \(tMs)")
            XCTAssertEqual(Int(decision.lead_time_s), expected["lead_time_s"] as? Int, "t_ms \(tMs)")
        }
    }

    // MARK: - RFC 0006 D2: the MCU step tap

    /// The tap must hand over the SAME sample/events/memory the kernel was
    /// stepped with. If the caller re-derived them, the Pico and the
    /// phone's shadow could disagree for reasons unrelated to the kernel,
    /// and every divergence the shadow reported would be suspect.
    func testStepTapCarriesTheStepsOwnInputs() throws {
        let (engine, _) = try makeEngine()
        var contexts: [RideStepContext] = []
        engine.onStep = { contexts.append($0) }

        let decision = engine.process(eastboundFix(second: 0, startLon: -0.004))
        XCTAssertEqual(contexts.count, 1)
        XCTAssertEqual(contexts.first?.sample.t_ms, 0)
        XCTAssertEqual(contexts.first?.sample.speed_cmps, 600)
        XCTAssertEqual(contexts.first?.decision.type, decision?.type)
        XCTAssertEqual(contexts.first?.decision.event_id, decision?.event_id)
        XCTAssertEqual(contexts.first?.decision.reason_code, decision?.reason_code)
        XCTAssertEqual(contexts.first?.decision.lead_time_s, decision?.lead_time_s)
    }

    /// A fix the engine drops was never stepped through the kernel, so the
    /// Pico must not be sent one either — otherwise its kernel would run
    /// ahead of the phone's shadow.
    func testStepTapSilentOnDroppedFixes() throws {
        let (engine, _) = try makeEngine()
        var count = 0
        engine.onStep = { _ in count += 1 }

        _ = engine.process(eastboundFix(second: 2, startLon: -0.004))
        XCTAssertEqual(count, 1)
        // Repeated and regressing timestamps both violate the strictly-
        // increasing contract and are dropped before the kernel step.
        _ = engine.process(eastboundFix(second: 2, startLon: -0.004))
        _ = engine.process(eastboundFix(second: 1, startLon: -0.004))
        XCTAssertEqual(count, 1)
        // A non-finite coordinate is dropped the same way.
        _ = engine.process(RideFix(tMs: 9000, lat: .nan, lon: 0,
                                   speedMps: 6, headingDeg: 90))
        XCTAssertEqual(count, 1)
    }

    /// Engines that never set the tap must behave exactly as before.
    func testStepTapIsOptional() throws {
        let (engine, _) = try makeEngine()
        XCTAssertNotNil(engine.process(eastboundFix(second: 0, startLon: -0.004)))
    }

    /// The events handed to the tap are the ones the kernel evaluated, in
    /// the same order — the property NFR-003 rests on.
    func testStepTapCarriesEventsInKernelOrder() throws {
        let (engine, zone) = try makeEngine()
        var seen: [[RouteEvent]] = []
        engine.onStep = { seen.append($0.events) }
        for second in 0..<12 {
            _ = engine.process(eastboundFix(second: second, startLon: -0.004))
        }
        let withEvents = seen.filter { !$0.isEmpty }
        XCTAssertFalse(withEvents.isEmpty, "approach must observe the zone")
        for events in withEvents {
            XCTAssertEqual(events.first?.event_id, zone.eventID)
        }
    }
}
