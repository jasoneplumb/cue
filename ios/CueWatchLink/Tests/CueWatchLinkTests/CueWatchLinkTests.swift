// Intent: D4 link-logic tests, all on injected clocks and a fake
//         transport (no WCSession — that glue is app-target code). The
//         load-bearing properties: payloads survive the dictionary round
//         trip and reject anything malformed; the expiry gate discards
//         stale and duplicate cues (never a double tap, never a tap after
//         the rider reached the event); the dispatcher picks live vs
//         queued correctly, falls back on live failure, anchors
//         dispatch_ts to the kernel decision instant, and produces the
//         p95 latency figure asmp0002 needs.
import CCuePolicy
import CueKernel
import XCTest
@testable import CueWatchLink

private final class FakeTransport: CueTransport {
    var isReachable = true
    var liveMessages: [[String: Any]] = []
    var queuedMessages: [[String: Any]] = []
    var pendingAcks: [(CueDeliveryAck) -> Void] = []
    var pendingFailures: [() -> Void] = []

    func sendLive(_ message: [String: Any],
                  onDeliveryAck: @escaping (CueDeliveryAck) -> Void,
                  onFailure: @escaping () -> Void) {
        liveMessages.append(message)
        pendingAcks.append(onDeliveryAck)
        pendingFailures.append(onFailure)
    }

    func sendQueued(_ message: [String: Any]) {
        queuedMessages.append(message)
    }
}

private func headUp(eventID: UInt32, leadTimeS: Int16) -> CueDecision {
    CueDecision(type: UInt8(CUE_HEAD_UP.rawValue), event_id: eventID,
                reason_code: 0, lead_time_s: leadTimeS)
}

final class CueWatchLinkTests: XCTestCase {
    // MARK: - Payload

    func testPayloadRoundTrip() {
        let payload = CuePayload(eventID: 42, dispatchTsMs: 1_700_000_000_000,
                                 expiresAfterS: 12)
        XCTAssertEqual(CuePayload(from: payload.encoded()), payload)
        XCTAssertEqual(payload.expiryTsMs, 1_700_000_012_000)
    }

    func testPayloadDecodeRejectsMalformedMessages() {
        let good = CuePayload(eventID: 1, dispatchTsMs: 1000, expiresAfterS: 5)
        var missing = good.encoded()
        missing.removeValue(forKey: "event_id")
        XCTAssertNil(CuePayload(from: missing))

        var mistyped = good.encoded()
        mistyped["dispatch_ts_ms"] = "soon"
        XCTAssertNil(CuePayload(from: mistyped))

        var outOfRange = good.encoded()
        outOfRange["expires_after_s"] = 70_000
        XCTAssertNil(CuePayload(from: outOfRange))

        var negative = good.encoded()
        negative["event_id"] = -1
        XCTAssertNil(CuePayload(from: negative))
    }

    // MARK: - Marker payload (D5, watch → phone)

    func testMarkerPayloadRoundTrip() {
        let payload = MarkerPayload(markedTsMs: 1_700_000_042_000)
        XCTAssertEqual(MarkerPayload(from: payload.encoded()), payload)
        XCTAssertEqual(payload.type, "unsafe_here")
    }

    func testMarkerPayloadRejectsMalformedAndUnknownTypes() {
        let good = MarkerPayload(markedTsMs: 1000).encoded()
        var unknownType = good
        unknownType["marker_type"] = "pothole"  // future type: reject, don't guess
        XCTAssertNil(MarkerPayload(from: unknownType))

        var missing = good
        missing.removeValue(forKey: "marked_ts_ms")
        XCTAssertNil(MarkerPayload(from: missing))

        var negative = good
        negative["marked_ts_ms"] = -5
        XCTAssertNil(MarkerPayload(from: negative))
    }

    // MARK: - Ride-ended payload (phone → watch, control)

    func testRideEndedPayloadRoundTrip() {
        let payload = RideEndedPayload()
        XCTAssertEqual(RideEndedPayload(from: payload.encoded()), payload)
    }

    func testRideEndedPayloadRejectsMalformedAndUnrelatedMessages() {
        var wrongControl = RideEndedPayload().encoded()
        wrongControl["control_type"] = "something_else"
        XCTAssertNil(RideEndedPayload(from: wrongControl))

        XCTAssertNil(RideEndedPayload(from: [:]))
        // A CuePayload must never be mistaken for a ride-ended control
        // message — the two share the WCSession channel.
        let cue = CuePayload(eventID: 1, dispatchTsMs: 1000, expiresAfterS: 5)
        XCTAssertNil(RideEndedPayload(from: cue.encoded()))
    }

    // MARK: - Expiry gate

    func testGatePlaysFreshDiscardsStaleAndDuplicates() {
        var gate = CueExpiryGate()
        let payload = CuePayload(eventID: 7, dispatchTsMs: 10_000, expiresAfterS: 10)
        // Fresh: rider has not reached the event start.
        XCTAssertEqual(gate.verdict(for: payload, receivedTsMs: 15_000), .play)
        // Same event again (queued duplicate after a live delivery).
        XCTAssertEqual(gate.verdict(for: payload, receivedTsMs: 15_500), .duplicate)

        var boundary = CueExpiryGate()
        // Exactly at expiry the rider is AT the event start — stale (>=).
        XCTAssertEqual(boundary.verdict(for: payload, receivedTsMs: 20_000), .expired)
        // And an expired event is also remembered: no later replay.
        XCTAssertEqual(boundary.verdict(for: payload, receivedTsMs: 20_001), .duplicate)

        var late = CueExpiryGate()
        // The reconnect-burst case: minutes late.
        XCTAssertEqual(late.verdict(for: payload, receivedTsMs: 80_000), .expired)
    }

    func testSyntheticTestCuesDispatchAndPlayLikeRealOnes() throws {
        // The debug test-cue path (#131): each tap gets a DISTINCT id in
        // the reserved test range, so the second tap must dispatch and
        // play — not die as a gate duplicate — while a queued re-delivery
        // of the same tap still dedups.
        let transport = FakeTransport()
        let dispatcher = CueDispatcher(transport: transport,
                                       rideStartEpochMs: 1_000_000)
        dispatcher.dispatch(CueDecision.syntheticHeadUp(eventID: 0xFFFF_0001,
                                                        leadTimeS: 15),
                            sampleTMs: 30_000)
        dispatcher.dispatch(CueDecision.syntheticHeadUp(eventID: 0xFFFF_0002,
                                                        leadTimeS: 15),
                            sampleTMs: 45_000)
        XCTAssertEqual(transport.liveMessages.count, 2)

        var gate = CueExpiryGate()
        let first = try XCTUnwrap(CuePayload(from: transport.liveMessages[0]))
        let second = try XCTUnwrap(CuePayload(from: transport.liveMessages[1]))
        XCTAssertEqual(gate.verdict(for: first, receivedTsMs: 1_031_000), .play)
        XCTAssertEqual(gate.verdict(for: second, receivedTsMs: 1_046_000), .play)
        XCTAssertEqual(gate.verdict(for: second, receivedTsMs: 1_047_000), .duplicate)
    }

    // MARK: - Dispatcher paths

    func testReachableDispatchUsesLivePathAndAckCompletesLatency() {
        let transport = FakeTransport()
        let dispatcher = CueDispatcher(transport: transport,
                                       rideStartEpochMs: 1_000_000)
        dispatcher.dispatch(headUp(eventID: 42, leadTimeS: 12), sampleTMs: 30_000)

        XCTAssertEqual(transport.liveMessages.count, 1)
        XCTAssertTrue(transport.queuedMessages.isEmpty)
        let sent = try! XCTUnwrap(CuePayload(from: transport.liveMessages[0]))
        // dispatch_ts anchors to the kernel decision instant: start + t_ms.
        XCTAssertEqual(sent.dispatchTsMs, 1_030_000)
        XCTAssertEqual(sent.expiresAfterS, 12)

        XCTAssertNil(dispatcher.records[0].latencyMs)
        // Watch received 800 ms later, played it, workout live (RFC 0004).
        transport.pendingAcks[0](CueDeliveryAck(
            deliveryTsMs: 1_030_800, verdict: "play", workoutActive: true))
        XCTAssertEqual(dispatcher.records[0].latencyMs, 800)
        XCTAssertEqual(dispatcher.p95LatencyMs, 800)
        XCTAssertEqual(dispatcher.records[0].watchVerdict, "play")
        XCTAssertEqual(dispatcher.records[0].workoutActive, true)
    }

    func testUnreachableDispatchQueuesAndStaysUndelivered() throws {
        let transport = FakeTransport()
        transport.isReachable = false
        let dispatcher = CueDispatcher(transport: transport, rideStartEpochMs: 0)
        dispatcher.dispatch(headUp(eventID: 9, leadTimeS: 8), sampleTMs: 5000)

        XCTAssertTrue(transport.liveMessages.isEmpty)
        XCTAssertEqual(transport.queuedMessages.count, 1)
        XCTAssertEqual(dispatcher.records[0].path, .queued)
        XCTAssertNil(dispatcher.records[0].deliveryTsMs)

        let log = try JSONSerialization.jsonObject(
            with: dispatcher.exportLatencyLog(rideID: "r")) as! [String: Any]
        XCTAssertEqual(log["undelivered_count"] as? Int, 1)
        XCTAssertNil(log["p95_latency_ms"] as? UInt64)
    }

    func testLiveFailureFallsBackToQueuedPath() {
        let transport = FakeTransport()
        let dispatcher = CueDispatcher(transport: transport, rideStartEpochMs: 0)
        dispatcher.dispatch(headUp(eventID: 3, leadTimeS: 10), sampleTMs: 1000)
        transport.pendingFailures[0]()  // send error mid-flight

        XCTAssertEqual(transport.queuedMessages.count, 1)
        XCTAssertEqual(dispatcher.records[0].path, .liveFellBackToQueued)
        // The queued copy carries the ORIGINAL dispatch_ts — late delivery
        // is the watch gate's problem, the expiry window must not stretch.
        let requeued = try! XCTUnwrap(CuePayload(from: transport.queuedMessages[0]))
        XCTAssertEqual(requeued.dispatchTsMs, 1000)
    }

    func testNonHeadUpDecisionsAreIgnored() {
        let transport = FakeTransport()
        let dispatcher = CueDispatcher(transport: transport, rideStartEpochMs: 0)
        dispatcher.dispatch(
            CueDecision(type: UInt8(CUE_NONE.rawValue), event_id: 1,
                        reason_code: 7, lead_time_s: -1),
            sampleTMs: 1000)
        XCTAssertTrue(transport.liveMessages.isEmpty)
        XCTAssertTrue(transport.queuedMessages.isEmpty)
        XCTAssertTrue(dispatcher.records.isEmpty)
    }

    func testAckWithoutTimestampCountsDeliveredButUnmeasured() throws {
        let transport = FakeTransport()
        let dispatcher = CueDispatcher(transport: transport, rideStartEpochMs: 0)
        dispatcher.dispatch(headUp(eventID: 4, leadTimeS: 10), sampleTMs: 1000)
        // Watch replied but nothing decoded (legacy build / mangled reply).
        transport.pendingAcks[0](CueDeliveryAck(deliveryTsMs: nil))

        XCTAssertTrue(dispatcher.records[0].delivered)
        XCTAssertNil(dispatcher.records[0].latencyMs)
        XCTAssertNil(dispatcher.records[0].watchVerdict)
        XCTAssertNil(dispatcher.records[0].workoutActive)
        XCTAssertNil(dispatcher.p95LatencyMs)
        let log = try JSONSerialization.jsonObject(
            with: dispatcher.exportLatencyLog(rideID: "r")) as! [String: Any]
        // Delivered-but-unmeasured must NOT inflate the coverage-loss metric.
        XCTAssertEqual(log["undelivered_count"] as? Int, 0)
    }

    func testBackwardClockSkewIsUnmeasuredNotZero() {
        let transport = FakeTransport()
        let dispatcher = CueDispatcher(transport: transport,
                                       rideStartEpochMs: 1_000_000)
        dispatcher.dispatch(headUp(eventID: 6, leadTimeS: 10), sampleTMs: 30_000)
        // Watch clock 500 ms BEHIND dispatch.
        transport.pendingAcks[0](CueDeliveryAck(deliveryTsMs: 1_029_500))
        // Skew corrupts the measurement; it must not enter p95 as 0 ms.
        XCTAssertTrue(dispatcher.records[0].delivered)
        XCTAssertNil(dispatcher.records[0].latencyMs)
        XCTAssertNil(dispatcher.p95LatencyMs)
    }

    func testFallbackSendSurvivesDispatcherRelease() {
        let transport = FakeTransport()
        var dispatcher: CueDispatcher? = CueDispatcher(transport: transport,
                                                       rideStartEpochMs: 0)
        dispatcher?.dispatch(headUp(eventID: 8, leadTimeS: 10), sampleTMs: 1000)
        dispatcher = nil  // ride ended mid-send
        transport.pendingFailures[0]()
        // The cue must still reach the queued path — a rider-facing tap
        // outranks the (already discarded) log entry.
        XCTAssertEqual(transport.queuedMessages.count, 1)
    }

    func testNegativeLeadTimeClampsToImmediateExpiry() {
        let transport = FakeTransport()
        let dispatcher = CueDispatcher(transport: transport, rideStartEpochMs: 0)
        dispatcher.dispatch(headUp(eventID: 5, leadTimeS: -1), sampleTMs: 1000)
        let sent = try! XCTUnwrap(CuePayload(from: transport.liveMessages[0]))
        XCTAssertEqual(sent.expiresAfterS, 0)
    }

    // MARK: - p95 and export

    func testP95OverTwentyAckedCues() {
        let transport = FakeTransport()
        let dispatcher = CueDispatcher(transport: transport, rideStartEpochMs: 0)
        for i in 0..<20 {
            dispatcher.dispatch(headUp(eventID: UInt32(i), leadTimeS: 10),
                                sampleTMs: UInt32(i) * 1000)
        }
        // Latencies 100, 200, … 2000 ms: p95 rank over 20 = the 19th
        // sorted value = 1900.
        for (i, ack) in transport.pendingAcks.enumerated() {
            ack(CueDeliveryAck(deliveryTsMs: UInt64(i) * 1000 + UInt64((i + 1) * 100)))
        }
        XCTAssertEqual(dispatcher.p95LatencyMs, 1900)
    }

    func testLatencyLogExportIsDeterministicAndComplete() throws {
        func makeLog() throws -> Data {
            let transport = FakeTransport()
            let dispatcher = CueDispatcher(transport: transport, rideStartEpochMs: 500)
            dispatcher.dispatch(headUp(eventID: 1, leadTimeS: 9), sampleTMs: 1000)
            // The ride-2026-07-14 signature: acked fast, but no workout
            // session was live — the haptic call was a silent no-op.
            transport.pendingAcks[0](CueDeliveryAck(
                deliveryTsMs: 2400, verdict: "play", workoutActive: false))
            transport.isReachable = false
            dispatcher.dispatch(headUp(eventID: 2, leadTimeS: 7), sampleTMs: 9000)
            return try dispatcher.exportLatencyLog(rideID: "ride-1")
        }
        XCTAssertEqual(try makeLog(), try makeLog())
        let log = try JSONSerialization.jsonObject(with: makeLog()) as! [String: Any]
        XCTAssertEqual(log["ride_id"] as? String, "ride-1")
        let cues = log["cues"] as! [[String: Any]]
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0]["latency_ms"] as? Int, 900)  // 2400 - 1500
        // RFC 0004 fields ride along per cue: verdict "play" with
        // workout_active false is the delivered-but-never-played signature.
        XCTAssertEqual(cues[0]["watch_verdict"] as? String, "play")
        XCTAssertEqual(cues[0]["workout_active"] as? Bool, false)
        XCTAssertEqual(cues[1]["path"] as? String, "queued")
        XCTAssertNil(cues[1]["latency_ms"] as? Int)
        XCTAssertNil(cues[1]["watch_verdict"] as? String)
        XCTAssertEqual(log["undelivered_count"] as? Int, 1)
        // The summary must agree with the rows it summarizes: one measured
        // cue at 900 ms → p95 900.
        XCTAssertEqual(log["p95_latency_ms"] as? Int, 900)
    }

    // MARK: - Delivery ack (RFC 0004)

    func testDeliveryAckRoundTrip() {
        let ack = CueDeliveryAck(deliveryTsMs: 1_700_000_000_000,
                                 verdict: "play", workoutActive: true)
        XCTAssertEqual(CueDeliveryAck(from: ack.encoded()), ack)
    }

    func testDeliveryAckDecodeIsTotalOverLegacyAndMangledReplies() {
        // A pre-RFC-0004 watch replies with the timestamp alone: still a
        // full delivery, diagnostics simply absent.
        let legacy = CueDeliveryAck(from: ["delivery_ts_ms": 800])
        XCTAssertEqual(legacy.deliveryTsMs, 800)
        XCTAssertNil(legacy.verdict)
        XCTAssertNil(legacy.workoutActive)

        // Empty and mistyped replies decode to all-nil, never fail — the
        // reply's existence is the delivery.
        XCTAssertEqual(CueDeliveryAck(from: [:]),
                       CueDeliveryAck(deliveryTsMs: nil))
        let mangled = CueDeliveryAck(from: [
            "delivery_ts_ms": "soon", "verdict": 3, "workout_active": "yes"])
        XCTAssertEqual(mangled, CueDeliveryAck(deliveryTsMs: nil))

        // Absent fields are omitted from the wire dict, not encoded as null.
        XCTAssertTrue(CueDeliveryAck(deliveryTsMs: nil).encoded().isEmpty)
    }

    func testVerdictWireNamesAreStable() {
        // Sidecar vocabulary — analysis tooling greps these strings.
        XCTAssertEqual(CueVerdict.play.wireName, "play")
        XCTAssertEqual(CueVerdict.expired.wireName, "expired")
        XCTAssertEqual(CueVerdict.duplicate.wireName, "duplicate")
    }
}
