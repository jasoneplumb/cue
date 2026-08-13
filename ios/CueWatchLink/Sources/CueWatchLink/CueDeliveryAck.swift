// Intent: The watch's reply to a live cue message (RFC 0004): delivery
//         receipt PLUS what the watch actually did with the cue. Ride
//         2026-07-14 showed `delivered` alone conflates transport with
//         perception — four cues acked in under a second, none felt.
//         The verdict and workout flag let the sidecar distinguish
//         "never played" (gate discard, or no workout session keeping
//         the app haptic-eligible) from "played but not felt".
// Pattern: Same total encode/decode over [String: Any] as CuePayload —
//          but PERMISSIVE where CuePayload is strict: each field decodes
//          independently to nil on absence or mistype, because a reply
//          from an older watch build (delivery_ts_ms only) is still a
//          delivery and must keep counting as one.
import Foundation

/// What one live-path reply carried. All fields optional: the reply is
/// best-effort diagnostics on top of the load-bearing "any reply = delivered".
public struct CueDeliveryAck: Equatable, Sendable {
    /// Watch wall clock at receipt (Unix epoch ms); nil when unreadable.
    public let deliveryTsMs: UInt64?
    /// The expiry gate's verdict, wire-named (see CueVerdict.wireName);
    /// nil from builds that predate RFC 0004.
    public let verdict: String?
    /// Whether the watch held a live HKWorkoutSession at receipt — the
    /// proxy for haptic eligibility (WKInterfaceDevice.play is a silent
    /// no-op when the app is not frontmost; the workout session is what
    /// keeps it frontmost with the wrist down).
    public let workoutActive: Bool?

    public init(deliveryTsMs: UInt64?, verdict: String? = nil,
                workoutActive: Bool? = nil) {
        self.deliveryTsMs = deliveryTsMs
        self.verdict = verdict
        self.workoutActive = workoutActive
    }

    enum Key {
        static let deliveryTsMs = "delivery_ts_ms"
        static let verdict = "verdict"
        static let workoutActive = "workout_active"
    }

    /// WCSession reply dictionary. Absent fields are omitted, not null —
    /// plist dictionaries carry no NSNull.
    public func encoded() -> [String: Any] {
        var reply: [String: Any] = [:]
        if let deliveryTsMs { reply[Key.deliveryTsMs] = Int(clamping: deliveryTsMs) }
        if let verdict { reply[Key.verdict] = verdict }
        if let workoutActive { reply[Key.workoutActive] = workoutActive }
        return reply
    }

    /// Every field independently optional: a malformed or legacy reply
    /// still decodes (to nils) — the reply's existence is the delivery.
    public init(from reply: [String: Any]) {
        self.init(
            deliveryTsMs: (reply[Key.deliveryTsMs] as? Int)
                .flatMap { UInt64(exactly: $0) },
            verdict: reply[Key.verdict] as? String,
            workoutActive: reply[Key.workoutActive] as? Bool)
    }
}

extension CueVerdict {
    /// Stable wire name for the ack's `verdict` field (sidecar vocabulary —
    /// keep in lockstep with the field-analysis tooling).
    public var wireName: String {
        switch self {
        case .play: return "play"
        case .expired: return "expired"
        case .duplicate: return "duplicate"
        }
    }
}
