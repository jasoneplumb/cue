// Intent: The watch-side decision: play this cue, or discard it as stale
//         (RFC 0003 D4). The two failure modes are asymmetric and the gate
//         picks the right side of each: a cue delivered before arrival
//         still helps (played), one delivered after arrival is stale noise
//         (discarded — NFR-001 prefers a missed cue over a misleading one).
// Pattern: Pure state machine over injected wall-clock values — no Date()
//          reads, so the whole gate is deterministic under test. Duplicate
//          suppression by event_id covers the queued path's burst-on-
//          reconnect behavior (the same cue can arrive via sendMessage AND
//          a queued transferUserInfo retry).

/// What the watch should do with one received payload.
public enum CueVerdict: Equatable, Sendable {
    /// Play the single subtle tap (§5.7).
    case play
    /// Arrived at/after the rider reached the event start — discard, and
    /// the phone's log will show it as expired for §13 tuning.
    case expired
    /// Already played (or already discarded) this event — a queued
    /// duplicate must never double-tap (FR-004's spirit on the watch side).
    case duplicate
}

/// One ride's gate. Create per ride; feed every received payload with the
/// watch's wall clock at receipt.
public struct CueExpiryGate {
    private var seenEventIDs: Set<UInt32> = []

    public init() {}

    /// Judge one payload received at `receivedTsMs` (Unix epoch ms).
    /// Expiry is `>=`: at the boundary the rider is AT the event start,
    /// and a tap now is exactly the misleading case (D4).
    public mutating func verdict(for payload: CuePayload,
                                 receivedTsMs: UInt64) -> CueVerdict {
        guard seenEventIDs.insert(payload.eventID).inserted else {
            return .duplicate
        }
        return receivedTsMs >= payload.expiryTsMs ? .expired : .play
    }
}
