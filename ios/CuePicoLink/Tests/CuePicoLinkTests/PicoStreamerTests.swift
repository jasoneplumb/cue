// Intent: Tests for the phone-side step stream — sequence assignment,
//         shadow-divergence detection (RFC 0006 D2), and the reconnect
//         rules (D4). These are the paths where a mistake produces a
//         silent NFR-003 divergence rather than a visible failure, so
//         they are asserted directly instead of left to a ride.
import CueKernel
import Testing
import Foundation
@testable import CuePicoLink

private func makeSample(tMs: UInt32, speed: UInt16 = 500,
                        segment: UInt32 = 42) -> RideSample {
    var s = RideSample()
    s.t_ms = tMs
    s.speed_cmps = speed
    s.segment_id = segment
    return s
}

private func makeDecision(type: UInt8, eventID: UInt32 = 7,
                          reason: UInt8 = 0, lead: Int16 = 10) -> CueDecision {
    var d = CueDecision()
    d.type = type
    d.event_id = eventID
    d.reason_code = reason
    d.lead_time_s = lead
    return d
}

/// The report the Pico would send for a given decision.
private func report(seq: UInt16, tMs: UInt32, decision: CueDecision,
                    actuated: Bool = true, delayUs: UInt16 = 0) -> Data {
    var data = Data()
    data.append(UInt8(seq & 0xFF)); data.append(UInt8(seq >> 8))
    data.append(UInt8(tMs & 0xFF)); data.append(UInt8((tMs >> 8) & 0xFF))
    data.append(UInt8((tMs >> 16) & 0xFF)); data.append(UInt8(tMs >> 24))
    data.append(decision.type)
    let e = decision.event_id
    data.append(UInt8(e & 0xFF)); data.append(UInt8((e >> 8) & 0xFF))
    data.append(UInt8((e >> 16) & 0xFF)); data.append(UInt8(e >> 24))
    data.append(decision.reason_code)
    let lead = UInt16(bitPattern: decision.lead_time_s)
    data.append(UInt8(lead & 0xFF)); data.append(UInt8(lead >> 8))
    data.append(actuated ? 1 : 0)
    data.append(UInt8(delayUs & 0xFF)); data.append(UInt8(delayUs >> 8))
    return data
}

private func makeStreamer() -> PicoStreamer {
    PicoStreamer(rideIDHash: 0xABCD, config: CuePolicy.defaultConfig())
}

@Suite("PicoStreamer")
struct PicoStreamerTests {

    @Test("sequence numbers start at 1 and increment per step")
    func sequencing() {
        let s = makeStreamer()
        let first = s.makeStep(sample: makeSample(tMs: 1000), events: [],
                               memory: nil,
                               shadowDecision: makeDecision(type: 0))
        let second = s.makeStep(sample: makeSample(tMs: 2000), events: [],
                                memory: nil,
                                shadowDecision: makeDecision(type: 0))
        #expect(first?[first!.startIndex] == 1)
        #expect(second?[second!.startIndex] == 2)
    }

    @Test("matching decisions record no divergence")
    func agreementRecordsNoDivergence() {
        let s = makeStreamer()
        let decision = makeDecision(type: 1)
        _ = s.makeStep(sample: makeSample(tMs: 1000), events: [], memory: nil,
                       shadowDecision: decision)
        let agreed = s.handle(decisionReport: report(seq: 1, tMs: 1000,
                                                     decision: decision))
        #expect(agreed)
        #expect(s.divergenceCount == 0)
        #expect(s.stepRecords.first?.diverged == false)
        #expect(s.stepRecords.first?.actuated == true)
    }

    @Test("a differing decision field is a divergence (NFR-003)")
    func fieldMismatchIsDivergence() {
        let s = makeStreamer()
        _ = s.makeStep(sample: makeSample(tMs: 1000), events: [], memory: nil,
                       shadowDecision: makeDecision(type: 1, lead: 10))
        // Pico agrees on everything but the computed lead time.
        let agreed = s.handle(decisionReport: report(
            seq: 1, tMs: 1000, decision: makeDecision(type: 1, lead: 9)))
        #expect(!agreed)
        #expect(s.divergenceCount == 1)
        #expect(s.stepRecords.first?.diverged == true)
    }

    @Test("actuated is excluded from the comparison")
    func actuatedIsNotADivergence() {
        let s = makeStreamer()
        let decision = makeDecision(type: 1)
        _ = s.makeStep(sample: makeSample(tMs: 1000), events: [], memory: nil,
                       shadowDecision: decision)
        // Same decision, but the Pico suppressed actuation (catch-up).
        // That is a delivery property, not a kernel disagreement.
        let agreed = s.handle(decisionReport: report(seq: 1, tMs: 1000,
                                                     decision: decision,
                                                     actuated: false))
        #expect(agreed)
        #expect(s.divergenceCount == 0)
        #expect(s.unactuatedHeadUps.count == 1)
    }

    @Test("a report for a step we never sent counts as divergence")
    func unknownSeqIsDivergence() {
        let s = makeStreamer()
        let agreed = s.handle(decisionReport: report(
            seq: 99, tMs: 1000, decision: makeDecision(type: 1)))
        #expect(!agreed)
        #expect(s.divergenceCount == 1)
    }

    @Test("a malformed report is rejected without counting a divergence")
    func malformedReportRejected() {
        let s = makeStreamer()
        #expect(!s.handle(decisionReport: Data([0x01, 0x02])))
        #expect(s.divergenceCount == 0)
        #expect(s.reportedCount == 0)
    }

    @Test("resume replays only un-acked steps, flagged non-actuating")
    func resumeReplaysBacklogAsCatchup() {
        let s = makeStreamer()
        for i in 1...5 {
            _ = s.makeStep(sample: makeSample(tMs: UInt32(i) * 1000),
                           events: [], memory: nil,
                           shadowDecision: makeDecision(type: 0))
        }
        // The Pico consumed through seq 3.
        guard case let .replay(payloads) =
                s.resumePlan(picoLastProcessedSeq: 3, resumeStatus: .ok) else {
            Issue.record("expected a replay plan")
            return
        }
        #expect(payloads.count == 2)
        for payload in payloads {
            let flags = payload[payload.startIndex + 2]
            #expect(flags & CuePicoWire.StepFlag.catchup != 0)
        }
        // Seq 4 first, in order.
        #expect(payloads.first?[payloads.first!.startIndex] == 4)
    }

    @Test("acknowledged steps drop out of the replay set")
    func acknowledgeTrimsBacklog() {
        let s = makeStreamer()
        for i in 1...3 {
            _ = s.makeStep(sample: makeSample(tMs: UInt32(i) * 1000),
                           events: [], memory: nil,
                           shadowDecision: makeDecision(type: 0))
        }
        s.acknowledge(seq: 3)
        guard case let .replay(payloads) =
                s.resumePlan(picoLastProcessedSeq: 3, resumeStatus: .ok) else {
            Issue.record("expected a replay plan")
            return
        }
        #expect(payloads.isEmpty)
    }

    @Test("a rejected resume forces a full re-stream (Pico rebooted)")
    func wrongRideForcesFullRestream() {
        let s = makeStreamer()
        _ = s.makeStep(sample: makeSample(tMs: 1000), events: [], memory: nil,
                       shadowDecision: makeDecision(type: 0))
        #expect(s.resumePlan(picoLastProcessedSeq: 0,
                             resumeStatus: .wrongRide) == .fullRestream)
        #expect(s.resumePlan(picoLastProcessedSeq: 0,
                             resumeStatus: .notRiding) == .fullRestream)
    }

    @Test("a hole between the Pico's seq and our backlog forces a re-stream")
    func gapForcesFullRestream() {
        let s = makeStreamer()
        for i in 1...3 {
            _ = s.makeStep(sample: makeSample(tMs: UInt32(i) * 1000),
                           events: [], memory: nil,
                           shadowDecision: makeDecision(type: 0))
        }
        s.acknowledge(seq: 1)
        // Pico claims it only consumed seq 0; we no longer hold seq 1, so
        // an in-order replay is impossible — do not paper over it.
        #expect(s.resumePlan(picoLastProcessedSeq: 0,
                             resumeStatus: .ok) == .fullRestream)
    }

    @Test("ring overflow degrades to a full re-stream, never a silent gap")
    func ringOverflowForcesFullRestream() {
        let s = makeStreamer()
        for i in 0...CuePicoWire.ringCapacity {
            _ = s.makeStep(sample: makeSample(tMs: UInt32(i) * 1000),
                           events: [], memory: nil,
                           shadowDecision: makeDecision(type: 0))
        }
        #expect(s.resumePlan(picoLastProcessedSeq: 1,
                             resumeStatus: .ok) == .fullRestream)
    }

    /// A disagreement seen before a disconnect must not survive the replay
    /// of that same step. divergenceCount is what the D5 gate reads as its
    /// NFR-003 metric, so an inflated one would fail a ride that was
    /// actually clean.
    @Test("a replayed step's earlier divergence is rolled back, not double-counted")
    func replayRollsBackEarlierDivergence() {
        let s = makeStreamer()
        _ = s.makeStep(sample: makeSample(tMs: 1000), events: [], memory: nil,
                       shadowDecision: makeDecision(type: 1, lead: 10))
        // Pico disagreed before the link dropped.
        s.handle(decisionReport: report(seq: 1, tMs: 1000,
                                        decision: makeDecision(type: 1, lead: 9)))
        #expect(s.divergenceCount == 1)

        guard case .replay = s.resumePlan(picoLastProcessedSeq: 0,
                                          resumeStatus: .ok) else {
            Issue.record("expected a replay plan")
            return
        }
        // The prior report is void: its divergence is rolled back and the
        // record no longer claims a Pico decision.
        #expect(s.divergenceCount == 0)
        #expect(s.reportedCount == 0)
        #expect(s.stepRecords.first?.diverged == nil)
        #expect(s.stepRecords.first?.picoType == nil)

        // The replay agrees, so the ride ends clean rather than carrying a
        // phantom divergence.
        s.handle(decisionReport: report(seq: 1, tMs: 1000,
                                        decision: makeDecision(type: 1, lead: 10)))
        #expect(s.divergenceCount == 0)
        #expect(s.reportedCount == 1)
        #expect(s.stepRecords.first?.diverged == false)
    }

    @Test("a replayed step that diverges again is counted exactly once")
    func replayedDivergenceCountedOnce() {
        let s = makeStreamer()
        _ = s.makeStep(sample: makeSample(tMs: 1000), events: [], memory: nil,
                       shadowDecision: makeDecision(type: 1, lead: 10))
        s.handle(decisionReport: report(seq: 1, tMs: 1000,
                                        decision: makeDecision(type: 1, lead: 9)))
        _ = s.resumePlan(picoLastProcessedSeq: 0, resumeStatus: .ok)
        s.handle(decisionReport: report(seq: 1, tMs: 1000,
                                        decision: makeDecision(type: 1, lead: 9)))
        #expect(s.divergenceCount == 1)
        #expect(s.stepRecords.first?.diverged == true)
    }

    /// A replayed step's non-actuation is the deliberate NFR-001 behaviour.
    /// Counting it as a delivery failure would inflate the number the D5
    /// gate uses to decide whether cues are reaching the rider — the same
    /// class of lying-metric bug as the divergence double-count.
    @Test("a replayed HEAD_UP is marked catch-up and not counted as undelivered")
    func replayedStepIsMarkedCatchup() {
        let s = makeStreamer()
        _ = s.makeStep(sample: makeSample(tMs: 1000), events: [], memory: nil,
                       shadowDecision: makeDecision(type: 1))
        #expect(s.stepRecords.first?.catchup == false)

        guard case .replay = s.resumePlan(picoLastProcessedSeq: 0,
                                          resumeStatus: .ok) else {
            Issue.record("expected a replay plan")
            return
        }
        #expect(s.stepRecords.first?.catchup == true)

        // The Pico steps the kernel but suppresses the actuator, exactly
        // as D4 requires — that must not read as a missed cue.
        s.handle(decisionReport: report(seq: 1, tMs: 1000,
                                        decision: makeDecision(type: 1),
                                        actuated: false))
        #expect(s.unactuatedHeadUps.isEmpty)
    }

    /// A genuinely undelivered cue must still be caught — the filter above
    /// must not swallow real failures along with the intentional ones.
    @Test("a non-replayed HEAD_UP that never actuated is still reported")
    func genuineUndeliveredStillCounted() {
        let s = makeStreamer()
        _ = s.makeStep(sample: makeSample(tMs: 1000), events: [], memory: nil,
                       shadowDecision: makeDecision(type: 1))
        s.handle(decisionReport: report(seq: 1, tMs: 1000,
                                        decision: makeDecision(type: 1),
                                        actuated: false))
        #expect(s.unactuatedHeadUps.count == 1)
    }

    /// BLE notifications are unacknowledged, so the OS can replay one.
    /// Folding it in twice would double both aggregates.
    @Test("a duplicate decision notification is folded in once")
    func duplicateNotificationIgnored() {
        let s = makeStreamer()
        _ = s.makeStep(sample: makeSample(tMs: 1000), events: [], memory: nil,
                       shadowDecision: makeDecision(type: 1, lead: 10))
        let mismatched = report(seq: 1, tMs: 1000,
                                decision: makeDecision(type: 1, lead: 9))
        s.handle(decisionReport: mismatched)
        s.handle(decisionReport: mismatched)
        #expect(s.divergenceCount == 1)
        #expect(s.reportedCount == 1)

        // An agreeing step is likewise counted once.
        let s2 = makeStreamer()
        let decision = makeDecision(type: 1)
        _ = s2.makeStep(sample: makeSample(tMs: 1000), events: [], memory: nil,
                        shadowDecision: decision)
        let dup = report(seq: 1, tMs: 1000, decision: decision)
        #expect(s2.handle(decisionReport: dup))
        #expect(s2.handle(decisionReport: dup)) // still reports agreement
        #expect(s2.reportedCount == 1)
        #expect(s2.divergenceCount == 0)
    }

    @Test("the state-size tripwire rejects a mismatched Pico (D6)")
    func stateSizeTripwire() {
        let s = makeStreamer()
        let good = CuePicoWire.SessionAck(status: .ok, firmwareVersion: 1,
                                          stateSize: 420)
        let wrongSize = CuePicoWire.SessionAck(status: .ok, firmwareVersion: 1,
                                               stateSize: 292)
        let refused = CuePicoWire.SessionAck(status: .badProtocol,
                                             firmwareVersion: 1, stateSize: 420)
        #expect(s.validate(sessionAck: good, expectedStateSize: 420))
        #expect(!s.validate(sessionAck: wrongSize, expectedStateSize: 420))
        #expect(!s.validate(sessionAck: refused, expectedStateSize: 420))
    }

    @Test("sidecar export carries per-step evidence for the D5 gate")
    func sidecarExport() throws {
        let s = makeStreamer()
        let decision = makeDecision(type: 1)
        _ = s.makeStep(sample: makeSample(tMs: 1000), events: [], memory: nil,
                       shadowDecision: decision)
        s.handle(decisionReport: report(seq: 1, tMs: 1000, decision: decision,
                                        actuated: true, delayUs: 120))
        let data = try s.exportSidecar()
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"divergence_count\" : 0"))
        #expect(json.contains("\"actuation_delay_us\" : 120"))
        #expect(json.contains("\"pico_type\" : 1"))
        #expect(json.contains("\"shadow_type\" : 1"))
    }

    // MARK: - Battery series (D5 evidence path, #165)

    @Test("battery samples are stamped with the ride clock, not a wall clock")
    func batterySamplesUseRideClock() {
        let s = makeStreamer()
        // Before any step there is no ride clock to stamp against.
        s.record(batteryMillivolts: 4180, supply: .battery)
        _ = s.makeStep(sample: makeSample(tMs: 1000), events: [], memory: nil,
                       shadowDecision: makeDecision(type: 0))
        _ = s.makeStep(sample: makeSample(tMs: 61_000), events: [], memory: nil,
                       shadowDecision: makeDecision(type: 0))
        s.record(batteryMillivolts: 4090, supply: .battery)

        #expect(s.batterySamples.map(\.tMs) == [0, 61_000])
        #expect(s.batterySamples.map(\.batteryMv) == [4180, 4090])
    }

    /// The firmware reports 0 mV for "could not measure". That must not
    /// become a flat cell in the evidence — but it must not take the
    /// supply label down with it either, because the supply is the half
    /// the D5 gate actually reads.
    @Test("an unmeasurable voltage keeps its supply instead of dropping the sample")
    func zeroBatteryReadingKeepsSupply() {
        let s = makeStreamer()
        s.record(batteryMillivolts: 0, supply: .usb)
        #expect(s.batterySamples.count == 1)
        #expect(s.batterySamples[0].batteryMv == nil)
        #expect(s.batterySamples[0].supply == .usb)

        // Nothing measurable AND nothing knowable: no sample at all.
        s.record(batteryMillivolts: 0, supply: .unknown)
        #expect(s.batterySamples.count == 1)
    }

    /// The regression this optionality exists to prevent: a ride that
    /// touched USB while its ADC was failing must not read as
    /// battery-powered throughout.
    @Test("a USB sample with an unmeasurable voltage still refutes the claim")
    func usbWithNoVoltageStillRefutesClaim() throws {
        let s = makeStreamer()
        _ = s.makeStep(sample: makeSample(tMs: 1000), events: [], memory: nil,
                       shadowDecision: makeDecision(type: 0))
        s.record(batteryMillivolts: 4180, supply: .battery)
        s.record(batteryMillivolts: 0, supply: .usb)
        s.record(batteryMillivolts: 4090, supply: .battery)

        #expect(s.batteryPoweredThroughout == false)
        let json = String(decoding: try s.exportSidecar(), as: UTF8.self)
        #expect(json.contains("\"battery_powered_throughout\" : false"))
        // The header brackets the readings that exist, skipping the gap.
        #expect(json.contains("\"battery_start_mv\" : 4180"))
        #expect(json.contains("\"battery_end_mv\" : 4090"))
    }

    /// "The device could not tell" is not "the device was on USB".
    @Test("an unknown supply leaves the claim unmade rather than failed")
    func unknownSupplyLeavesClaimUnmade() {
        let s = makeStreamer()
        s.record(batteryMillivolts: 4180, supply: .battery)
        s.record(batteryMillivolts: 4090, supply: .unknown)
        #expect(s.batteryPoweredThroughout == nil)
    }

    @Test("sidecar carries the battery series and brackets it in the header")
    func sidecarCarriesBattery() throws {
        let s = makeStreamer()
        _ = s.makeStep(sample: makeSample(tMs: 1000), events: [], memory: nil,
                       shadowDecision: makeDecision(type: 0))
        s.record(batteryMillivolts: 4180, supply: .battery)
        s.record(batteryMillivolts: 3950, supply: .battery)
        s.record(batteryMillivolts: 3810, supply: .battery)

        let json = String(decoding: try s.exportSidecar(), as: UTF8.self)
        #expect(json.contains("\"battery_start_mv\" : 4180"))
        #expect(json.contains("\"battery_end_mv\" : 3810"))
        #expect(json.contains("\"battery_mv\" : 3950"))
        #expect(json.contains("\"supply\" : \"battery\""))
        #expect(json.contains("\"battery_powered_throughout\" : true"))
    }

    /// D5 requires the validation ride to run on the 18650. A ride with a
    /// cable in it for any part of the ride has not demonstrated
    /// endurance, so one non-battery sample is enough to fail the claim.
    @Test("one USB sample disqualifies the on-battery claim for the ride")
    func usbSampleDisqualifiesBatteryClaim() throws {
        let s = makeStreamer()
        _ = s.makeStep(sample: makeSample(tMs: 1000), events: [], memory: nil,
                       shadowDecision: makeDecision(type: 0))
        s.record(batteryMillivolts: 4180, supply: .battery)
        s.record(batteryMillivolts: 5037, supply: .usb)
        s.record(batteryMillivolts: 4090, supply: .battery)

        #expect(s.batteryPoweredThroughout == false)
        let json = String(decoding: try s.exportSidecar(), as: UTF8.self)
        #expect(json.contains("\"battery_powered_throughout\" : false"))
        #expect(json.contains("\"supply\" : \"usb\""))
    }

    /// A ride the phone never sampled must not read as a failed
    /// on-battery claim — it is an unmade claim, and the gate has to be
    /// able to tell those apart.
    @Test("no samples means no on-battery claim, not a false one")
    func noSamplesMeansNoClaim() throws {
        let s = makeStreamer()
        #expect(s.batteryPoweredThroughout == nil)
        let json = String(decoding: try s.exportSidecar(), as: UTF8.self)
        #expect(!json.contains("battery_powered_throughout"))
    }

    /// "Not measured" and "measured, and it was fine" must not encode the
    /// same way — that ambiguity is the whole defect behind #164 and #165.
    @Test("a ride with no reading omits the battery summary, keeping an empty series")
    func sidecarOmitsBatterySummaryWhenNeverRead() throws {
        let s = makeStreamer()
        _ = s.makeStep(sample: makeSample(tMs: 1000), events: [], memory: nil,
                       shadowDecision: makeDecision(type: 0))
        let json = String(decoding: try s.exportSidecar(), as: UTF8.self)
        // The summary fields are what carry a claim, so they are the
        // ones that must be absent. The series itself is non-optional and
        // serialises as [], which says "sampled nothing" rather than
        // asserting anything about the battery.
        #expect(!json.contains("battery_start_mv"))
        #expect(!json.contains("battery_end_mv"))
        #expect(json.contains("\"battery\" : ["))
    }
}

@Suite("PicoStreamer aggregate reconciliation")
struct PicoStreamerReconciliationTests {

    /// The aggregates are derived from the records rather than
    /// accumulated, so the identity below holds by construction. Asserted
    /// anyway because it is the property the D5 gate depends on when it
    /// reads the sidecar.
    @Test("divergence_count reconciles against the per-step records")
    func aggregatesReconcile() {
        let s = makeStreamer()
        _ = s.makeStep(sample: makeSample(tMs: 1000), events: [], memory: nil,
                       shadowDecision: makeDecision(type: 1, lead: 10))
        _ = s.makeStep(sample: makeSample(tMs: 2000), events: [], memory: nil,
                       shadowDecision: makeDecision(type: 0, reason: 1, lead: -1))
        // One disagreement...
        s.handle(decisionReport: report(seq: 1, tMs: 1000,
                                        decision: makeDecision(type: 1, lead: 9)))
        // ...one agreement...
        s.handle(decisionReport: report(seq: 2, tMs: 2000,
                                        decision: makeDecision(type: 0, reason: 1,
                                                               lead: -1)))
        // ...and one report for a step that was never sent, which has no
        // record to appear in.
        s.handle(decisionReport: report(seq: 77, tMs: 5000,
                                        decision: makeDecision(type: 1)))

        let fromRecords = s.stepRecords.filter { $0.diverged == true }.count
        #expect(s.orphanReportCount == 1)
        #expect(s.divergenceCount == fromRecords + s.orphanReportCount)
        #expect(s.divergenceCount == 2)
        #expect(s.reportedCount == 3)
    }

    /// A rollback that forgot a field used to leave a counter permanently
    /// wrong. With the aggregates derived, clearing the fields IS the
    /// rollback — this pins that they return to zero exactly.
    @Test("a full replay returns the aggregates to their pre-report state")
    func rollbackIsExact() {
        let s = makeStreamer()
        _ = s.makeStep(sample: makeSample(tMs: 1000), events: [], memory: nil,
                       shadowDecision: makeDecision(type: 1, lead: 10))
        s.handle(decisionReport: report(seq: 1, tMs: 1000,
                                        decision: makeDecision(type: 1, lead: 9)))
        #expect(s.divergenceCount == 1)
        #expect(s.reportedCount == 1)

        _ = s.resumePlan(picoLastProcessedSeq: 0, resumeStatus: .ok)
        #expect(s.divergenceCount == 0)
        #expect(s.reportedCount == 0)
        #expect(s.stepRecords.filter { $0.diverged != nil }.isEmpty)
    }

    @Test("a safe ride id is not derived from anything locational")
    func rideIDHashIsRandom() {
        // Only a smoke test that the helper exists and varies; its value
        // is the documented constraint, which a caller cannot violate by
        // accident if it uses this.
        let a = PicoStreamer.makeRideIDHash()
        let b = PicoStreamer.makeRideIDHash()
        let c = PicoStreamer.makeRideIDHash()
        #expect(!(a == b && b == c))
    }
}

@Suite("PicoStreamer transport helpers")
struct PicoStreamerTransportTests {

    /// The transport matches ATT write responses to steps by reading the
    /// seq back out of the payload it sent, so this must agree with what
    /// packStep wrote.
    @Test("seq is recoverable from a packed step")
    func seqRoundTrip() {
        let s = makeStreamer()
        for expected in UInt16(1)...UInt16(3) {
            let payload = s.makeStep(sample: makeSample(tMs: UInt32(expected) * 1000),
                                     events: [], memory: nil,
                                     shadowDecision: makeDecision(type: 0))!
            #expect(CuePicoWire.seq(ofStep: payload) == expected)
        }
        // Total on a truncated payload rather than reading out of bounds.
        #expect(CuePicoWire.seq(ofStep: Data([0x01])) == 0)
    }

    @Test("hasStarted distinguishes resume from restart")
    func hasStartedGatesResume() {
        let s = makeStreamer()
        #expect(!s.hasStarted)
        _ = s.makeStep(sample: makeSample(tMs: 1000), events: [], memory: nil,
                       shadowDecision: makeDecision(type: 0))
        #expect(s.hasStarted)
    }

    @Test("resume payload carries the ride hash and last acked seq")
    func resumePayloadShape() {
        let s = PicoStreamer(rideIDHash: 0xABCD_EF01,
                             config: CuePolicy.defaultConfig())
        for i in 1...4 {
            _ = s.makeStep(sample: makeSample(tMs: UInt32(i) * 1000), events: [],
                           memory: nil, shadowDecision: makeDecision(type: 0))
        }
        s.acknowledge(seq: 3)
        #expect(s.resumePayload() == Data([
            0x02, 0x01, 0xEF, 0xCD, 0xAB, 0x03, 0x00,
        ]))
        // Acknowledging out of order must not walk the value backwards.
        s.acknowledge(seq: 2)
        #expect(s.resumePayload() == Data([
            0x02, 0x01, 0xEF, 0xCD, 0xAB, 0x03, 0x00,
        ]))
    }

    /// The D6 tripwire compares against this, so a drift between the
    /// Swift facade and the C struct would silently disable the check.
    @Test("the facade reports the kernel's real state size")
    func stateSizeMatchesKernel() {
        #expect(CuePolicy.stateSize == 420)
    }
}
