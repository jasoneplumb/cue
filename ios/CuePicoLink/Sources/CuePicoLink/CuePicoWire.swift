// Intent: Swift half of the RFC 0006 D3 wire protocol — the exact packed
//         little-endian encoding of `mcu/shared/cue_wire.h`, so the phone
//         and the Pico agree byte for byte.
// Context: The C header is the source of truth. This file is the one place
//          the encoding is restated, and the golden byte vectors in
//          CuePicoWireTests are asserted against the identical vectors in
//          mcu/pico-cue/tests/test_cue_wire.c — a change to either side
//          that is not made to both fails a test rather than surfacing as
//          a rejected write on a ride.
// Pattern: Kernel structs come from CueKernel (RFC 0003 D3 — no Swift
//          mirror of kernel types); this adds only serialization. Decoding
//          is total: nil on anything malformed, never a partially trusted
//          payload.
import CueKernel
import Foundation

public enum CuePicoWire {
    // MARK: - Constants (mirrors cue_wire.h)

    /// v2: the actuation delay is microseconds, and STATUS carries the
    /// supply. The delay kept its offset and its width, so a v1 peer would
    /// decode it happily and be wrong by 1000× — this number is the only
    /// thing standing between that and the D5 evidence, which is why the
    /// firmware refuses the session outright on a mismatch.
    public static let protocolVersion: UInt8 = 2

    public static let sampleSize = 20
    public static let eventSize = 17   // natural struct is 20 B with padding
    public static let memorySize = 6   // natural struct is 8 B with padding
    public static let decisionSize = 8 // natural struct is 12 B with padding
    public static let configSize = 12

    public static let stepHeaderSize = 4
    /// Matches CUE_WIRE_STEP_MAX_EVENTS and REPLAY_MAX_EVENTS_PER_SAMPLE.
    public static let stepMaxEvents = 16
    public static let stepMaxSize =
        stepHeaderSize + sampleSize + stepMaxEvents * eventSize + memorySize

    public static let decisionReportSize = 17
    public static let statusSize = 6

    /// Un-acked step ring capacity (RFC 0006 D4): ≥ 10 minutes at 1 Hz.
    public static let ringCapacity = 600

    public enum StepFlag {
        public static let memory: UInt8 = 1 << 0
        /// Step the kernel but do not actuate — a catch-up replay after a
        /// link gap must not fire a burst of stale cues (NFR-001).
        public static let catchup: UInt8 = 1 << 1
    }

    public enum Opcode {
        public static let sessionStart: UInt8 = 0x01
        public static let sessionResume: UInt8 = 0x02
        public static let sessionStop: UInt8 = 0x03
        public static let testCue: UInt8 = 0x04

        public static let sessionAck: UInt8 = 0x81
        public static let resumeAck: UInt8 = 0x82
        public static let genericAck: UInt8 = 0x83
    }

    public enum Status: UInt8, Sendable {
        case ok = 0
        case badProtocol = 1
        case badLength = 2
        /// Resume for a ride this Pico never had — it rebooted, so the
        /// phone must SESSION_START and re-stream from seq 0 (D4).
        case wrongRide = 3
        case notRiding = 4
        case badOpcode = 5
    }

    /// GATT identifiers, mirrored from cue_wire.h.
    public enum UUIDString {
        public static let service = "85BF0001-C87E-4346-8A6C-440B3E57F451"
        public static let control = "85BF0002-C87E-4346-8A6C-440B3E57F451"
        public static let step = "85BF0003-C87E-4346-8A6C-440B3E57F451"
        public static let decision = "85BF0004-C87E-4346-8A6C-440B3E57F451"
        public static let status = "85BF0005-C87E-4346-8A6C-440B3E57F451"
    }

    /// The name the firmware advertises.
    public static let advertisedName = "pico-cue"

    // MARK: - Primitive little-endian writers

    private static func put16(_ value: UInt16, into data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8(value >> 8))
    }

    private static func put32(_ value: UInt32, into data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8(value >> 24))
    }

    private static func get16(_ data: Data, _ offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private static func get32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }

    // MARK: - Struct encoding

    /// RFC 0006 D3: lat, lon, and heading are ZEROED on the wire. Enforced
    /// here exactly as the C codec enforces it, so no caller can transmit
    /// live GPS by handing over an unscrubbed sample (NFR-005). The kernel
    /// provably reads none of the three, so this cannot affect determinism.
    public static func packSample(_ sample: RideSample, into data: inout Data) {
        put32(sample.t_ms, into: &data)
        put32(0, into: &data) // lat_e7
        put32(0, into: &data) // lon_e7
        put16(sample.speed_cmps, into: &data)
        put16(0, into: &data) // heading_deg_x10
        put32(sample.segment_id, into: &data)
    }

    public static func packEvent(_ event: RouteEvent, into data: inout Data) {
        put32(event.event_id, into: &data)
        data.append(event.family)
        put32(event.segment_id, into: &data)
        data.append(event.severity)
        data.append(event.confidence)
        put16(event.reasons_bitmask, into: &data)
        put16(UInt16(bitPattern: event.distance_to_start_m), into: &data)
        put16(UInt16(bitPattern: event.distance_to_end_m), into: &data)
    }

    public static func packMemory(_ memory: PersonalMemory, into data: inout Data) {
        put32(memory.segment_id, into: &data)
        data.append(memory.state)
        data.append(memory.notice_bonus_s)
    }

    public static func packConfig(_ config: CuePolicyConfig, into data: inout Data) {
        data.append(config.severity_threshold)
        data.append(config.confidence_threshold)
        put16(config.min_notice_s, into: &data)
        put16(config.max_notice_s, into: &data)
        put16(config.min_cooldown_s, into: &data)
        put16(config.min_cooldown_m, into: &data)
        put16(config.min_speed_kmh, into: &data)
    }

    // MARK: - STEP

    /// One kernel step: `seq | flags | event_count | sample | events×n | [memory]`.
    ///
    /// Events beyond `stepMaxEvents` are NOT truncated here — the caller
    /// must truncate upstream of both the shadow step and the wire so both
    /// kernels see an identical set (RFC 0006 D3). Truncating at this layer
    /// would manufacture exactly the divergence the shadow exists to catch,
    /// so this returns nil instead.
    public static func packStep(seq: UInt16,
                                flags: UInt8 = 0,
                                sample: RideSample,
                                events: [RouteEvent],
                                memory: PersonalMemory? = nil) -> Data? {
        guard events.count <= stepMaxEvents else { return nil }
        var data = Data()
        data.reserveCapacity(stepHeaderSize + sampleSize
                             + events.count * eventSize + memorySize)
        put16(seq, into: &data)
        var effectiveFlags = flags & ~StepFlag.memory
        if memory != nil { effectiveFlags |= StepFlag.memory }
        data.append(effectiveFlags)
        data.append(UInt8(events.count))
        packSample(sample, into: &data)
        for event in events { packEvent(event, into: &data) }
        if let memory { packMemory(memory, into: &data) }
        return data
    }

    /// The sequence number a packed step carries. The transport needs it
    /// to match ATT write responses back to steps, and reading it from the
    /// payload keeps that mapping honest — a separately-tracked seq could
    /// drift from what was actually sent.
    public static func seq(ofStep payload: Data) -> UInt16 {
        guard payload.count >= 2 else { return 0 }
        return get16(payload, 0)
    }

    // MARK: - CONTROL

    public static func packSessionStart(rideIDHash: UInt32,
                                        config: CuePolicyConfig) -> Data {
        var data = Data()
        data.append(Opcode.sessionStart)
        data.append(protocolVersion)
        put32(rideIDHash, into: &data)
        packConfig(config, into: &data)
        return data
    }

    public static func packSessionResume(rideIDHash: UInt32,
                                         lastAckedSeq: UInt16) -> Data {
        var data = Data()
        data.append(Opcode.sessionResume)
        put32(rideIDHash, into: &data)
        put16(lastAckedSeq, into: &data)
        return data
    }

    public static func packSessionStop() -> Data { Data([Opcode.sessionStop]) }
    public static func packTestCue() -> Data { Data([Opcode.testCue]) }

    // MARK: - Decoding

    /// SESSION_ACK: `opcode | status | fw_version | state_size`.
    public struct SessionAck: Equatable, Sendable {
        public let status: Status
        public let firmwareVersion: UInt16
        /// The Pico's `sizeof(CuePolicyState)` — the runtime half of the
        /// D6 compiler-width tripwire. A mismatch against the phone's own
        /// kernel means the two would diverge from the first step, so the
        /// caller must abort rather than stream into it.
        public let stateSize: UInt16
    }

    public static func unpackSessionAck(_ data: Data) -> SessionAck? {
        guard data.count == 6, data[data.startIndex] == Opcode.sessionAck,
              let status = Status(rawValue: data[data.startIndex + 1])
        else { return nil }
        return SessionAck(status: status,
                          firmwareVersion: get16(data, 2),
                          stateSize: get16(data, 4))
    }

    /// RESUME_ACK: `opcode | status | last_processed_seq`. The seq is the
    /// Pico's own, which is authoritative over the phone's advisory value.
    public struct ResumeAck: Equatable, Sendable {
        public let status: Status
        public let lastProcessedSeq: UInt16
    }

    public static func unpackResumeAck(_ data: Data) -> ResumeAck? {
        guard data.count == 4, data[data.startIndex] == Opcode.resumeAck,
              let status = Status(rawValue: data[data.startIndex + 1])
        else { return nil }
        return ResumeAck(status: status, lastProcessedSeq: get16(data, 2))
    }

    /// DECISION notify: `seq | t_ms | CueDecision | actuated | actuation_delay_us`.
    public struct DecisionReport: Equatable, Sendable {
        public let seq: UInt16
        public let tMs: UInt32
        public let type: UInt8
        public let eventID: UInt32
        public let reasonCode: UInt8
        public let leadTimeS: Int16
        /// Whether the Pico actually drove the actuator — false for a
        /// catch-up step or a non-HEAD_UP decision.
        public let actuated: Bool
        /// Step arrival → actuator fired, in microseconds (v2).
        ///
        /// Milliseconds reported 0 for every genuine cue of the first
        /// validation ride: the real interval is under 500 µs, so it
        /// rounded away. The result was D2's claim confirmed, expressed
        /// as a number that reads identically to "never measured"
        /// (#164). `actuationDelayUsMax` means "≥ 65.535 ms" — broken,
        /// not slow.
        public let actuationDelayUs: UInt16

        public var isHeadUp: Bool { type == 1 }
    }

    public static func unpackDecisionReport(_ data: Data) -> DecisionReport? {
        guard data.count == decisionReportSize else { return nil }
        let base = data.startIndex
        return DecisionReport(
            seq: get16(data, 0),
            tMs: get32(data, 2),
            type: data[base + 6],
            eventID: get32(data, 7),
            reasonCode: data[base + 11],
            leadTimeS: Int16(bitPattern: get16(data, 12)),
            actuated: data[base + 14] != 0,
            actuationDelayUs: get16(data, 15))
    }

    /// Saturation value of `actuationDelayUs`: "≥ 65.535 ms", i.e. a fault.
    public static let actuationDelayUsMax: UInt16 = 0xFFFF

    /// Which supply the device is running on (v2).
    ///
    /// Codes as a string on the wire-adjacent side of the app (sidecar,
    /// diagnostics) and as a byte on the wire, matching `DIAG`'s
    /// vocabulary so one word means one thing in both places.
    public enum Supply: UInt8, Codable, Sendable {
        /// No radio, so no way to ask. A real answer, not a placeholder —
        /// guessing "usb" would put a guess into ride evidence.
        case unknown = 0
        case usb = 1
        case battery = 2

        public var name: String {
            switch self {
            case .unknown: return "unknown"
            case .usb: return "usb"
            case .battery: return "battery"
            }
        }

        public init(from decoder: Decoder) throws {
            let name = try decoder.singleValueContainer().decode(String.self)
            switch name {
            case "usb": self = .usb
            case "battery": self = .battery
            default: self = .unknown
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(name)
        }
    }

    /// STATUS: `fw_version | state | battery_mv | supply`.
    public struct DeviceStatus: Equatable, Sendable {
        public let firmwareVersion: UInt16
        public let sessionState: UInt8
        /// VSYS millivolts. **Not a charge gauge** on a WuKong 2040: the
        /// carrier powers the Pico through 3V3 and leaves VSYS unpowered
        /// whenever USB is out, so this reads ~5040 mV on USB and ~100 mV
        /// on battery (#165). Read it with `supply`, never alone.
        public let batteryMillivolts: UInt16
        public let supply: Supply
    }

    public static func unpackStatus(_ data: Data) -> DeviceStatus? {
        guard data.count == statusSize else { return nil }
        return DeviceStatus(firmwareVersion: get16(data, 0),
                            sessionState: data[data.startIndex + 2],
                            batteryMillivolts: get16(data, 3),
                            // An unrecognised value decodes as unknown
                            // rather than failing the whole packet: a
                            // future supply state should cost the supply
                            // field, not the session state beside it.
                            supply: Supply(rawValue: data[data.startIndex + 5])
                                ?? .unknown)
    }
}
