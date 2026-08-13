// Intent: Thin Swift facade over the C cue-policy kernel (RFC 0003 D3).
//         The app talks to this; the kernel stays the single source of
//         truth for every decision. No Swift mirror of kernel types — D3
//         rejected that as manufactured live/replay divergence.
// Pattern: C structs (RideSample, RouteEvent, CueDecision, CuePolicyConfig)
//          are re-exported as typealiases and used as-is; this file adds
//          only state ownership and Swift-shaped call ergonomics.
import CCuePolicy

public typealias RideSample = CCuePolicy.RideSample
public typealias RouteEvent = CCuePolicy.RouteEvent
public typealias CueDecision = CCuePolicy.CueDecision
public typealias CuePolicyConfig = CCuePolicy.CuePolicyConfig
public typealias PersonalMemory = CCuePolicy.PersonalMemory

/// One ride's cue-policy state machine. Create one per ride; feed it every
/// 1 Hz sample with that sample's route-event observations in a stable,
/// deterministic order (NFR-003 — replay must reproduce live decisions).
public final class CuePolicy {
    private var state = CuePolicyState()

    /// `config == nil` applies the spec §8 defaults (mirrors the C API).
    public init(config: CuePolicyConfig? = nil) {
        if var config {
            cue_policy_init(&state, &config)
        } else {
            cue_policy_init(&state, nil)
        }
    }

    /// `sizeof(CuePolicyState)` as this build lays it out — the phone
    /// half of the RFC 0006 D6 compiler-width tripwire. The Pico reports
    /// its own in SESSION_ACK; a mismatch means the two kernels would
    /// diverge from the first step, so the link must refuse to stream.
    public static var stateSize: Int { MemoryLayout<CuePolicyState>.size }

    /// The spec §8 default parameter table.
    public static func defaultConfig() -> CuePolicyConfig {
        var config = CuePolicyConfig()
        cue_policy_default_config(&config)
        return config
    }

    /// The replay harness refuses traces carrying more observations per
    /// sample than this (REPLAY_MAX_EVENTS_PER_SAMPLE in replay_main.c).
    /// A live step that exceeded it would cue the rider with a decision
    /// replay can never reproduce — an NFR-003 violation — so the facade
    /// enforces the trace contract, not just the kernel's uint8 bound.
    public static let maxEventsPerSample = 16

    /// Evaluate one sample. At most one HEAD_UP per call — the first event
    /// (in array order) that passes every gate. `sample.t_ms` must be
    /// monotonically non-decreasing across calls (kernel contract).
    ///
    /// `memory`: the resolved personal-route-memory input for this step
    /// (RFC 0002 D5), or nil for memory-free evaluation — byte-for-byte
    /// identical to a kernel build with no memory feature at all.
    public func step(_ sample: RideSample, events: [RouteEvent] = [],
                     memory: PersonalMemory? = nil) -> CueDecision {
        precondition(events.count <= Self.maxEventsPerSample,
                     "too many events for one sample — replay harness cap is \(Self.maxEventsPerSample)")
        var sample = sample
        return events.withUnsafeBufferPointer { buffer in
            if var memory {
                return cue_policy_step(&state, &sample, buffer.baseAddress,
                                       UInt8(events.count), &memory)
            }
            return cue_policy_step(&state, &sample, buffer.baseAddress,
                                   UInt8(events.count), nil)
        }
    }
}

extension CueDecision {
    /// True when the kernel decided to cue (CUE_HEAD_UP).
    public var isHeadUp: Bool { type == UInt8(CUE_HEAD_UP.rawValue) }

    #if DEBUG
    /// Debug-support synthetic HEAD_UP (#131): a value the app can inject
    /// at the cue-delivery boundary (phone chime + watch dispatch) to
    /// exercise delivery without a real route event. Pure value
    /// construction — no CuePolicyState exists or is touched, so the
    /// kernel's decision path and its determinism contract (NFR-003,
    /// live/replay parity) are unaffected by callers using this. DEBUG
    /// only: a Release CueKernel must not offer any way to mint a
    /// bypass-kernel decision.
    public static func syntheticHeadUp(eventID: UInt32,
                                       leadTimeS: Int16) -> CueDecision {
        CueDecision(type: UInt8(CUE_HEAD_UP.rawValue),
                    event_id: eventID,
                    reason_code: UInt8(CUE_REASON_CODE_CUED),
                    lead_time_s: leadTimeS)
    }
    #endif
}
