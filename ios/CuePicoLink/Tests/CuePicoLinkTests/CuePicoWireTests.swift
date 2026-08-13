// Intent: Contract tests for the Swift half of the RFC 0006 D3 wire
//         format. Every golden vector here is byte-identical to one
//         asserted from C in mcu/pico-cue/tests/test_cue_wire.c — two
//         independent encoders pinned to one set of bytes, so a change to
//         either that is not made to both fails a test rather than showing
//         up as a rejected write on a ride.
// Pattern: Field values are deliberately asymmetric (distinct, non-zero,
//          negative where the type allows) so a byte-order or offset bug
//          cannot coincidentally still match.
import CueKernel
import Testing
import Foundation
@testable import CuePicoLink

@Suite("CuePicoWire golden vectors")
struct CuePicoWireTests {

    @Test("sample: lat, lon and heading are zeroed on the wire (NFR-005)")
    func sampleZeroesLocation() {
        var sample = RideSample()
        sample.t_ms = 0x1234_5678
        sample.lat_e7 = 455_201_234
        sample.lon_e7 = -1_226_751_234
        sample.speed_cmps = 0x01F4
        sample.heading_deg_x10 = 1234
        sample.segment_id = 0xABCD_EF01

        var data = Data()
        CuePicoWire.packSample(sample, into: &data)

        #expect(data == Data([
            0x78, 0x56, 0x34, 0x12, // t_ms
            0x00, 0x00, 0x00, 0x00, // lat_e7 zeroed
            0x00, 0x00, 0x00, 0x00, // lon_e7 zeroed
            0xF4, 0x01,             // speed_cmps
            0x00, 0x00,             // heading_deg_x10 zeroed
            0x01, 0xEF, 0xCD, 0xAB, // segment_id
        ]))
        #expect(data.count == CuePicoWire.sampleSize)
    }

    @Test("event: 17 bytes packed, negative distance two's complement")
    func eventVector() {
        var event = RouteEvent()
        event.event_id = 0x0A0B_0C0D
        event.family = 1
        event.segment_id = 0x1122_3344
        event.severity = 0xC8
        event.confidence = 0x64
        event.reasons_bitmask = 0x0007
        event.distance_to_start_m = -50
        event.distance_to_end_m = 300

        var data = Data()
        CuePicoWire.packEvent(event, into: &data)

        #expect(data == Data([
            0x0D, 0x0C, 0x0B, 0x0A, // event_id
            0x01,                   // family
            0x44, 0x33, 0x22, 0x11, // segment_id
            0xC8,                   // severity
            0x64,                   // confidence
            0x07, 0x00,             // reasons_bitmask
            0xCE, 0xFF,             // distance_to_start_m = -50
            0x2C, 0x01,             // distance_to_end_m = 300
        ]))
        #expect(data.count == CuePicoWire.eventSize)
    }

    @Test("memory: 6 bytes packed, not the natural struct's 8")
    func memoryVector() {
        var memory = PersonalMemory()
        memory.segment_id = 0x00C0_FFEE
        memory.state = 2
        memory.notice_bonus_s = 7

        var data = Data()
        CuePicoWire.packMemory(memory, into: &data)

        #expect(data == Data([0xEE, 0xFF, 0xC0, 0x00, 0x02, 0x07]))
        #expect(data.count == CuePicoWire.memorySize)
    }

    @Test("config: 12 bytes packed")
    func configVector() {
        var config = CuePolicyConfig()
        config.severity_threshold = 128
        config.confidence_threshold = 200
        config.min_notice_s = 5
        config.max_notice_s = 15
        config.min_cooldown_s = 15
        config.min_cooldown_m = 75
        config.min_speed_kmh = 4

        var data = Data()
        CuePicoWire.packConfig(config, into: &data)

        #expect(data == Data([
            0x80, 0xC8, 0x05, 0x00, 0x0F, 0x00,
            0x0F, 0x00, 0x4B, 0x00, 0x04, 0x00,
        ]))
        #expect(data.count == CuePicoWire.configSize)
    }

    @Test("SESSION_START frames opcode, version, ride hash and config")
    func sessionStartVector() {
        var config = CuePolicyConfig()
        config.severity_threshold = 128
        config.confidence_threshold = 200
        config.min_notice_s = 5
        config.max_notice_s = 15
        config.min_cooldown_s = 15
        config.min_cooldown_m = 75
        config.min_speed_kmh = 4

        let data = CuePicoWire.packSessionStart(rideIDHash: 0xABCD_EF01,
                                                config: config)
        #expect(data == Data([
            0x01,                   // SESSION_START
            0x02,                   // proto version (v2: us delay, supply)
            0x01, 0xEF, 0xCD, 0xAB, // ride_id_hash
            0x80, 0xC8, 0x05, 0x00, 0x0F, 0x00,
            0x0F, 0x00, 0x4B, 0x00, 0x04, 0x00,
        ]))
        #expect(data.count == 18)
    }

    /// The D4 reconnect message. Pinned like every other outbound control
    /// frame so an edit cannot silently diverge from the C expectation and
    /// surface only as a rejected write on a reconnect — the one moment it
    /// is hardest to debug.
    @Test("SESSION_RESUME frames opcode, ride hash and last acked seq")
    func sessionResumeVector() {
        let data = CuePicoWire.packSessionResume(rideIDHash: 0xABCD_EF01,
                                                 lastAckedSeq: 9)
        #expect(data == Data([
            0x02,                   // SESSION_RESUME
            0x01, 0xEF, 0xCD, 0xAB, // ride_id_hash
            0x09, 0x00,             // last_acked_seq
        ]))
        // No protocol-version byte here, unlike SESSION_START.
        #expect(data.count == 7)
    }

    @Test("SESSION_STOP and TEST_CUE are bare opcodes")
    func bareOpcodeVectors() {
        #expect(CuePicoWire.packSessionStop() == Data([0x03]))
        #expect(CuePicoWire.packTestCue() == Data([0x04]))
    }

    @Test("STEP header, ordering, and the memory flag")
    func stepVector() {
        var sample = RideSample()
        sample.t_ms = 1000
        sample.speed_cmps = 500
        sample.segment_id = 42

        var event = RouteEvent()
        event.event_id = 7
        event.family = 1
        event.segment_id = 42
        event.severity = 200
        event.confidence = 200
        event.reasons_bitmask = 1
        event.distance_to_start_m = 50
        event.distance_to_end_m = 120

        // Bound outside the macro: the type-checker times out on inline
        // arithmetic inside #expect.
        let oneEventSize = CuePicoWire.stepHeaderSize + CuePicoWire.sampleSize
            + CuePicoWire.eventSize
        let step = CuePicoWire.packStep(seq: 1, sample: sample, events: [event])
        #expect(step?.count == oneEventSize)
        #expect(step?.prefix(4) == Data([0x01, 0x00, 0x00, 0x01]))

        // Supplying memory must set bit 0 and append 6 bytes.
        var memory = PersonalMemory()
        memory.segment_id = 42
        memory.state = 2
        memory.notice_bonus_s = 0
        let withMemorySize = oneEventSize + CuePicoWire.memorySize
        let withMemory = CuePicoWire.packStep(seq: 2, sample: sample,
                                              events: [event], memory: memory)
        #expect(withMemory?.count == withMemorySize)
        let flagByte = withMemory?[withMemory!.startIndex + 2]
        #expect(flagByte == CuePicoWire.StepFlag.memory)
    }

    @Test("catch-up flag survives alongside the memory flag")
    func catchupFlag() {
        var sample = RideSample()
        sample.t_ms = 1000
        sample.speed_cmps = 500

        var memory = PersonalMemory()
        memory.segment_id = 1

        let step = CuePicoWire.packStep(seq: 3,
                                        flags: CuePicoWire.StepFlag.catchup,
                                        sample: sample, events: [],
                                        memory: memory)
        let flags = step![step!.startIndex + 2]
        #expect(flags == (CuePicoWire.StepFlag.catchup | CuePicoWire.StepFlag.memory))
    }

    @Test("packStep refuses more events than the wire cap rather than truncating")
    func stepRefusesOverCap() {
        var sample = RideSample()
        sample.t_ms = 1
        var event = RouteEvent()
        event.family = 1
        // Truncating here would hide events from the Pico that the phone's
        // own shadow step still saw — manufacturing the very divergence the
        // shadow exists to detect (RFC 0006 D3).
        let tooMany = Array(repeating: event, count: CuePicoWire.stepMaxEvents + 1)
        #expect(CuePicoWire.packStep(seq: 1, sample: sample, events: tooMany) == nil)

        let atCap = Array(repeating: event, count: CuePicoWire.stepMaxEvents)
        let packed = CuePicoWire.packStep(seq: 1, sample: sample, events: atCap)
        let maxWithoutMemory = CuePicoWire.stepMaxSize - CuePicoWire.memorySize
        #expect(packed != nil)
        #expect(packed?.count == maxWithoutMemory)
    }

    @Test("DECISION report decodes every field at the right offset")
    func decisionReportDecode() {
        let report = Data([
            0x2A, 0x00,             // seq = 42
            0x28, 0x23, 0x00, 0x00, // t_ms = 9000
            0x01,                   // type = HEAD_UP
            0x07, 0x00, 0x00, 0x00, // event_id = 7
            0x00,                   // reason_code
            0x0C, 0x00,             // lead_time_s = 12
            0x01,                   // actuated
            0xFA, 0x00,             // actuation_delay_us = 250
        ])
        let decoded = CuePicoWire.unpackDecisionReport(report)
        #expect(decoded?.seq == 42)
        #expect(decoded?.tMs == 9000)
        #expect(decoded?.isHeadUp == true)
        #expect(decoded?.eventID == 7)
        #expect(decoded?.reasonCode == 0)
        #expect(decoded?.leadTimeS == 12)
        #expect(decoded?.actuated == true)
        #expect(decoded?.actuationDelayUs == 250)
    }

    @Test("DECISION report carries a negative lead time")
    func decisionReportNegativeLead() {
        let report = Data([
            0x01, 0x00, 0xE8, 0x03, 0x00, 0x00,
            0x00,                   // type = NONE
            0x07, 0x00, 0x00, 0x00,
            0x08,                   // reason_code = ALREADY_CUED
            0xFF, 0xFF,             // lead_time_s = -1
            0x00, 0x00, 0x00,
        ])
        let decoded = CuePicoWire.unpackDecisionReport(report)
        #expect(decoded?.leadTimeS == -1)
        #expect(decoded?.isHeadUp == false)
        #expect(decoded?.actuated == false)
    }

    @Test("decoding is total: wrong length or opcode yields nil")
    func decodingIsTotal() {
        #expect(CuePicoWire.unpackDecisionReport(Data()) == nil)
        #expect(CuePicoWire.unpackDecisionReport(Data(repeating: 0, count: 16)) == nil)
        #expect(CuePicoWire.unpackDecisionReport(Data(repeating: 0, count: 18)) == nil)
        // Right length, wrong opcode.
        #expect(CuePicoWire.unpackSessionAck(Data([0x99, 0, 1, 0, 0xA4, 0x01])) == nil)
        #expect(CuePicoWire.unpackResumeAck(Data([0x99, 0, 0, 0])) == nil)
        // Unknown status code is rejected rather than coerced.
        #expect(CuePicoWire.unpackSessionAck(Data([0x81, 0x7F, 1, 0, 0xA4, 0x01])) == nil)
    }

    @Test("SESSION_ACK exposes the state-size tripwire (RFC 0006 D6)")
    func sessionAckDecode() {
        // 420 == sizeof(CuePolicyState) on both host and arm-none-eabi.
        let ack = CuePicoWire.unpackSessionAck(
            Data([0x81, 0x00, 0x01, 0x00, 0xA4, 0x01]))
        #expect(ack?.status == .ok)
        #expect(ack?.firmwareVersion == 1)
        #expect(ack?.stateSize == 420)
    }

    @Test("RESUME_ACK reports the Pico's own last processed seq")
    func resumeAckDecode() {
        let ack = CuePicoWire.unpackResumeAck(Data([0x82, 0x00, 0x09, 0x00]))
        #expect(ack?.status == .ok)
        #expect(ack?.lastProcessedSeq == 9)

        let rejected = CuePicoWire.unpackResumeAck(Data([0x82, 0x03, 0x00, 0x00]))
        #expect(rejected?.status == .wrongRide)
    }

    @Test("constants match cue_wire.h")
    func constantsMatchHeader() {
        #expect(CuePicoWire.sampleSize == 20)
        #expect(CuePicoWire.eventSize == 17)
        #expect(CuePicoWire.memorySize == 6)
        #expect(CuePicoWire.decisionSize == 8)
        #expect(CuePicoWire.configSize == 12)
        #expect(CuePicoWire.stepMaxSize == 302)
        #expect(CuePicoWire.decisionReportSize == 17)
        #expect(CuePicoWire.statusSize == 6)
        #expect(CuePicoWire.stepMaxEvents == 16)
        #expect(CuePicoWire.ringCapacity == 600)
        // The v2 delay change kept the offset and the width, so no layout
        // assertion can catch a peer that still means milliseconds. This
        // literal is the only tripwire, and it is asserted identically in
        // test_cue_wire.c.
        #expect(CuePicoWire.protocolVersion == 2)
    }

    @Test("STATUS decodes the supply byte, unknown values included")
    func statusDecodesSupply() {
        let onBattery = CuePicoWire.unpackStatus(
            Data([0x01, 0x00, 0x02, 0xC5, 0x0F, 0x02]))
        #expect(onBattery?.firmwareVersion == 1)
        #expect(onBattery?.sessionState == 2)
        #expect(onBattery?.batteryMillivolts == 4037)
        #expect(onBattery?.supply == .battery)

        let onUSB = CuePicoWire.unpackStatus(
            Data([0x01, 0x00, 0x00, 0xB5, 0x13, 0x01]))
        #expect(onUSB?.supply == .usb)
        #expect(onUSB?.batteryMillivolts == 5045)

        // A supply value this build does not know costs the supply field,
        // not the packet: the session state beside it still decodes.
        let future = CuePicoWire.unpackStatus(
            Data([0x01, 0x00, 0x03, 0x00, 0x00, 0x7F]))
        #expect(future?.supply == .unknown)
        #expect(future?.sessionState == 3)

        // A v1 firmware's 5-byte STATUS must be refused outright rather
        // than decoded with a missing field defaulted into place.
        #expect(CuePicoWire.unpackStatus(
            Data([0x01, 0x00, 0x00, 0xB5, 0x13])) == nil)
    }
}
