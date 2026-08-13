// Intent: The cross-device cue message (RFC 0003 D4): what the phone
//         dispatches and the watch decodes. Every payload carries its own
//         expiry — the fallback path queues, and on reconnect
//         transferUserInfo delivers everything at once; a burst of taps a
//         minute after the squeeze zone is worse than no tap (NFR-001).
// Context: dispatch_ts_ms is anchored to the KERNEL STEP'S DECISION
//          INSTANT on the phone (the wall-clock time of the sample that
//          produced the cue), not the WCSession send time — phone and
//          watch must share this anchor, or queueing delay before send
//          would silently extend the expiry window (D4).
// Pattern: [String: Any] is WCSession's message currency; encode/decode
//          are total functions over it — decode returns nil on anything
//          malformed rather than trusting the transport.
import Foundation

/// One HEAD_UP cue in flight from phone to watch.
public struct CuePayload: Equatable, Sendable {
    public let eventID: UInt32
    /// Unix epoch milliseconds of the kernel decision instant (see header).
    public let dispatchTsMs: UInt64
    /// The decision's own computed lead time: the cue expires exactly when
    /// the rider reaches the event start (D4 stale-cue expiry).
    public let expiresAfterS: UInt16

    public init(eventID: UInt32, dispatchTsMs: UInt64, expiresAfterS: UInt16) {
        self.eventID = eventID
        self.dispatchTsMs = dispatchTsMs
        self.expiresAfterS = expiresAfterS
    }

    /// The instant this cue becomes stale noise instead of help.
    public var expiryTsMs: UInt64 {
        dispatchTsMs + UInt64(expiresAfterS) * 1000
    }

    // Keys are versioned as a family: unknown future keys are ignored on
    // decode, missing required keys reject the payload.
    enum Key {
        static let eventID = "event_id"
        static let dispatchTsMs = "dispatch_ts_ms"
        static let expiresAfterS = "expires_after_s"
    }

    /// WCSession message dictionary. `Int(clamping:)` on the UInt64 —
    /// Swift's plain initializer traps on overflow, and plist Int is the
    /// wire type WCSession dictates.
    public func encoded() -> [String: Any] {
        [Key.eventID: Int(eventID),
         Key.dispatchTsMs: Int(clamping: dispatchTsMs),
         Key.expiresAfterS: Int(expiresAfterS)]
    }

    /// nil on any missing, mistyped, or out-of-range field — the watch
    /// never plays a cue it cannot fully validate (NFR-001 direction).
    public init?(from message: [String: Any]) {
        guard let eventID = message[Key.eventID] as? Int,
              let dispatchTsMs = message[Key.dispatchTsMs] as? Int,
              let expiresAfterS = message[Key.expiresAfterS] as? Int,
              let eventID32 = UInt32(exactly: eventID),
              let dispatch64 = UInt64(exactly: dispatchTsMs),
              let expires16 = UInt16(exactly: expiresAfterS) else { return nil }
        self.init(eventID: eventID32, dispatchTsMs: dispatch64,
                  expiresAfterS: expires16)
    }
}
