// Intent: End-to-end proof of the CUE path (RFC 0006 D2) — a simulated
//         ride that actually produces a HEAD_UP, streamed through the real
//         wire format into a second kernel standing in for the Pico, with
//         its decisions compared back through PicoStreamer.
// Context: The bench ride that validated B3 on hardware was stationary, so
//          every decision was TOO_SLOW and the cue path was never
//          exercised — `unactuatedHeadUps` was trivially empty rather than
//          meaningfully so. This closes that gap without needing to ride
//          past a real squeeze zone.
// Pattern: The stand-in Pico decodes from the PACKED BYTES rather than
//          reusing the Swift structs, so this covers pack -> decode ->
//          kernel -> report -> compare. The decoder is test-local on
//          purpose: the shipping decoder is the C one in cue_session.c,
//          and the golden vectors are what pin the two together.
import CueKernel
@testable import CueMapImport
import CueRideEngine
import Testing
import Foundation
@testable import CuePicoLink

/// A stand-in for the firmware: runs the same kernel over the same wire
/// bytes and answers with a DECISION report, exactly as cue_session.c does.
private struct SimulatedPico {
    let policy = CuePolicy()

    /// Mirrors cue_session_handle_step's decode. Kept deliberately literal
    /// against cue_wire.h's layout — if this and the C decoder ever drift,
    /// the golden vectors in CuePicoWireTests/test_cue_wire.c fail first.
    func step(_ payload: Data) -> Data {
        let b = [UInt8](payload)
        func u16(_ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
        func u32(_ i: Int) -> UInt32 {
            UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16
                | UInt32(b[i + 3]) << 24
        }
        let seq = u16(0)
        let flags = b[2]
        let eventCount = Int(b[3])

        var sample = RideSample()
        sample.t_ms = u32(4)
        sample.lat_e7 = Int32(bitPattern: u32(8))
        sample.lon_e7 = Int32(bitPattern: u32(12))
        sample.speed_cmps = u16(16)
        sample.heading_deg_x10 = u16(18)
        sample.segment_id = u32(20)

        var cursor = 24
        var events: [RouteEvent] = []
        for _ in 0..<eventCount {
            var e = RouteEvent()
            e.event_id = u32(cursor)
            e.family = b[cursor + 4]
            e.segment_id = u32(cursor + 5)
            e.severity = b[cursor + 9]
            e.confidence = b[cursor + 10]
            e.reasons_bitmask = u16(cursor + 11)
            e.distance_to_start_m = Int16(bitPattern: u16(cursor + 13))
            e.distance_to_end_m = Int16(bitPattern: u16(cursor + 15))
            events.append(e)
            cursor += CuePicoWire.eventSize
        }

        var memory: PersonalMemory?
        if flags & CuePicoWire.StepFlag.memory != 0 {
            var m = PersonalMemory()
            m.segment_id = u32(cursor)
            m.state = b[cursor + 4]
            m.notice_bonus_s = b[cursor + 5]
            memory = m
        }

        let decision = policy.step(sample, events: events, memory: memory)
        let catchup = flags & CuePicoWire.StepFlag.catchup != 0
        let actuated = decision.type == 1 && !catchup

        var out = Data()
        out.append(UInt8(seq & 0xFF)); out.append(UInt8(seq >> 8))
        let t = sample.t_ms
        out.append(UInt8(t & 0xFF)); out.append(UInt8((t >> 8) & 0xFF))
        out.append(UInt8((t >> 16) & 0xFF)); out.append(UInt8(t >> 24))
        out.append(decision.type)
        let e = decision.event_id
        out.append(UInt8(e & 0xFF)); out.append(UInt8((e >> 8) & 0xFF))
        out.append(UInt8((e >> 16) & 0xFF)); out.append(UInt8(e >> 24))
        out.append(decision.reason_code)
        let lead = UInt16(bitPattern: decision.lead_time_s)
        out.append(UInt8(lead & 0xFF)); out.append(UInt8(lead >> 8))
        out.append(actuated ? 1 : 0)
        // The firmware measures this locally; a fixed value here keeps the
        // scenario deterministic (NFR-003).
        out.append(42); out.append(0)
        return out
    }
}

@Suite("Pico cue path (simulated ride)")
struct PicoCuePathTests {

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

    private static func eastboundGPX(seconds: Int) -> Data {
        var body = ""
        for second in 0..<seconds {
            let lon = -0.004 + 6.0 * Double(second) / 111_320.0
            let time = "<time>2026-07-11T00:"
                + String(format: "%02d:%02d", second / 60, second % 60) + "Z</time>"
            body += "<trkpt lat=\"0.00002\" lon=\"\(lon)\">\(time)</trkpt>\n"
        }
        return Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="cue-tests" xmlns="http://www.topografix.com/GPX/1/1">
          <trk><name>synthetic eastbound</name><trkseg>
        \(body)  </trkseg></trk>
        </gpx>
        """.utf8)
    }

    /// Runs the approach, streaming every kernel step through the wire
    /// format into the stand-in Pico and folding its answers back.
    private func runScenario(seconds: Int = 120)
        throws -> (streamer: PicoStreamer, cues: Int) {
        let segments = try SegmentImporter.deriveSegments(
            from: OverpassExtract(ways: [Self.approachWay, Self.squeezeWay]))
        let zones = SqueezeScorer.scoreZones(from: segments)
        #expect(zones.count == 1, "fixture must score exactly one zone")

        let engine = RideEngine(segments: segments, zones: zones,
                                rideID: "pico-path", startedAt: "1970-01-01T00:00:00Z")
        let streamer = PicoStreamer(rideIDHash: 0xFEED,
                                    config: CuePolicy.defaultConfig())
        let pico = SimulatedPico()
        var cues = 0

        engine.onStep = { context in
            guard let payload = streamer.makeStep(sample: context.sample,
                                                  events: context.events,
                                                  memory: context.memory,
                                                  shadowDecision: context.decision)
            else { return }
            if context.decision.type == 1 { cues += 1 }
            streamer.acknowledge(seq: CuePicoWire.seq(ofStep: payload))
            streamer.handle(decisionReport: pico.step(payload))
        }

        for fix in try GPXPlayback.rideFixes(from: Self.eastboundGPX(seconds: seconds)) {
            _ = engine.process(fix)
        }
        return (streamer, cues)
    }

    /// The headline: an approach that actually cues, with both kernels
    /// agreeing on every step including the HEAD_UP itself.
    @Test("a simulated approach cues, and the two kernels agree throughout")
    func approachCuesWithoutDivergence() throws {
        let (streamer, cues) = try runScenario()
        #expect(cues >= 1, "the approach must produce a HEAD_UP")
        #expect(streamer.divergenceCount == 0)
        #expect(streamer.orphanReportCount == 0)

        let records = streamer.stepRecords
        #expect(records.count >= 100)
        #expect(records.allSatisfy { $0.diverged == false })

        // FR-004: at most one HEAD_UP for the event.
        let headUps = records.filter { $0.shadowType == 1 }
        #expect(headUps.count == 1)
    }

    /// The gap the stationary bench ride left open: a HEAD_UP that the
    /// Pico reports as actuated, so `unactuatedHeadUps` is empty because
    /// the cue landed — not because no cue existed.
    @Test("the HEAD_UP is reported actuated, with a measured delay")
    func headUpIsActuated() throws {
        let (streamer, _) = try runScenario()
        let headUps = streamer.stepRecords.filter { $0.shadowType == 1 }
        #expect(headUps.count == 1)
        let cue = try #require(headUps.first)
        #expect(cue.picoType == 1)
        #expect(cue.actuated == true)
        #expect(cue.actuationDelayUs == 42)
        #expect(cue.picoLeadTimeS == cue.shadowLeadTimeS)
        #expect(streamer.unactuatedHeadUps.isEmpty)
    }

    /// The wire's event cap and the cap the engine applies upstream of the
    /// kernel must be the same number. They live in different packages
    /// (the engine must not depend on the link), so nothing but this
    /// assertion stops them drifting — and if they drift, the engine hands
    /// the wire a step it cannot encode, which is the one case that leaves
    /// the two kernels looking at different events (RFC 0006 D3).
    @Test("the engine's event cap is the wire's event cap")
    func eventCapsAgree() {
        #expect(RideEngine.maxEventsPerStep == CuePicoWire.stepMaxEvents)
    }

    /// The sidecar a validation ride would produce, checked the way the D5
    /// gate reads it — aggregates reconciled against the per-step records
    /// rather than trusted.
    @Test("the exported sidecar reconciles and carries the cue")
    func sidecarReconciles() throws {
        let (streamer, _) = try runScenario()
        let data = try streamer.exportSidecar()
        let json = try #require(JSONSerialization.jsonObject(with: data)
                                as? [String: Any],
                                "sidecar must be a JSON object")
        let steps = try #require(json["steps"] as? [[String: Any]],
                                 "sidecar must carry a steps array")

        let diverged = steps.filter { $0["diverged"] as? Bool == true }.count
        let reported = steps.filter { $0["pico_type"] != nil }.count
        // Required, not defaulted: a `?? -1` would let a missing key make
        // both sides of the comparison wrong together and still pass, and
        // this reconciliation is exactly what the D5 gate reads.
        let orphans = try #require(json["orphan_report_count"] as? Int,
                                   "sidecar must carry orphan_report_count")
        #expect(json["divergence_count"] as? Int == orphans + diverged)
        #expect(json["reported_count"] as? Int == orphans + reported)
        #expect(json["ring_overflowed"] as? Bool == false)
        #expect(steps.contains { $0["actuated"] as? Bool == true })
    }

    /// A catch-up replay must still step both kernels but suppress the
    /// actuator — the NFR-001 rule, exercised on a step that really cues.
    @Test("replaying the cue step keeps the decision but drops the actuation")
    func replayedCueDoesNotActuate() throws {
        let segments = try SegmentImporter.deriveSegments(
            from: OverpassExtract(ways: [Self.approachWay, Self.squeezeWay]))
        let zones = SqueezeScorer.scoreZones(from: segments)
        let engine = RideEngine(segments: segments, zones: zones,
                                rideID: "pico-replay", startedAt: "1970-01-01T00:00:00Z")
        let streamer = PicoStreamer(rideIDHash: 0xFEED,
                                    config: CuePolicy.defaultConfig())
        let pico = SimulatedPico()
        var cuePayload: Data?

        engine.onStep = { context in
            guard let payload = streamer.makeStep(sample: context.sample,
                                                  events: context.events,
                                                  memory: context.memory,
                                                  shadowDecision: context.decision)
            else { return }
            if context.decision.type == 1 { cuePayload = payload }
        }
        for fix in try GPXPlayback.rideFixes(from: Self.eastboundGPX(seconds: 120)) {
            _ = engine.process(fix)
        }

        // Nothing was acknowledged, so the whole ride is the backlog.
        guard case let .replay(payloads) =
                streamer.resumePlan(picoLastProcessedSeq: 0, resumeStatus: .ok) else {
            Issue.record("expected a replay plan")
            return
        }
        #expect(cuePayload != nil)
        for payload in payloads {
            streamer.handle(decisionReport: pico.step(payload))
        }
        // The kernel still decided a HEAD_UP on the replayed step — but the
        // rider is long past that zone, so it must not fire.
        let cue = streamer.stepRecords.first { $0.shadowType == 1 }
        #expect(cue?.picoType == 1)
        #expect(cue?.actuated == false)
        #expect(cue?.catchup == true)
        #expect(streamer.unactuatedHeadUps.isEmpty,
                "a suppressed catch-up cue is not an undelivered cue")
    }
}
