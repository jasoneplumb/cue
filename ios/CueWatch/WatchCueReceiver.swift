// Intent: Watch-side receiver (RFC 0003 D4, RFC 0004): decode each
//         incoming cue, let the expiry gate judge it, play the fixed
//         triple-tap pattern (RFC 0004 D2) only on a .play verdict, and
//         reply with the watch's wall clock at receipt PLUS the verdict
//         and workout state so the phone's sidecar can tell "never
//         played" from "played but not felt" (RFC 0004 D1).
// Pattern: Both delivery paths land here — sendMessage (live, with reply)
//          and transferUserInfo (queued burst on reconnect, no reply).
//          The gate is what keeps the queued path harmless: expired cues
//          are discarded, duplicates never double-tap (NFR-001).
import CueWatchLink
import Foundation
import WatchConnectivity
import WatchKit

// @unchecked Sendable: WCSession delivers delegate callbacks on its own
// serial queue. Mutable state is protected two ways: the expiry gate and
// workout flag are stateLock-guarded (resetForNewRide()/setWorkoutActive()
// arrive from app code on other threads); pendingTaps is main-queue
// confined instead (only ever touched inside playCuePattern's main hop).
final class WatchCueReceiver: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchCueReceiver()

    /// Which candidate rendering a cue plays (RFC 0006 D8). Persisted so
    /// a comparison survives the app being suspended mid-ride, and read
    /// through `WatchHapticPatterns` so an out-of-range stored value falls
    /// back rather than crashing or silently playing nothing.
    ///
    /// Bounds are still load-bearing and unchanged in kind from RFC 0004
    /// D2: every candidate is a FIXED schedule of one haptic type, decided
    /// before the first tap. Nothing lengthens on non-response and nothing
    /// varies the haptic type — that is what keeps this inside §12's "do
    /// not escalate" line, not the old pattern's shortness.
    static let patternIndexKey = "watchHapticPatternIndex"

    static var selectedPatternIndex: Int {
        get {
            guard UserDefaults.standard.object(forKey: patternIndexKey) != nil
            else { return WatchHapticPatterns.defaultIndex }
            return UserDefaults.standard.integer(forKey: patternIndexKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: patternIndexKey) }
    }

    static var selectedPattern: WatchHapticPattern {
        WatchHapticPatterns.pattern(at: selectedPatternIndex)
    }

    private let stateLock = NSLock()
    private var gate = CueExpiryGate()
    /// Mirrors WatchRideModel's workout session state (set on the main
    /// actor, read on WCSession's queue) — the haptic-eligibility proxy
    /// reported in every ack (RFC 0004 D1).
    private var workoutActive = false

    private let callbackLock = NSLock()
    private var _onRideEnded: (@Sendable () -> Void)?

    /// Fired when the phone signals its ride has ended (RideSessionController
    /// .stopRide → PhoneWatchLink.sendRideEnded). Invoked on WCSession's
    /// delegate queue — hop to your actor inside.
    var onRideEnded: (@Sendable () -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return _onRideEnded }
        set { callbackLock.lock(); defer { callbackLock.unlock() }; _onRideEnded = newValue }
    }

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// New ride, fresh duplicate-suppression state.
    func resetForNewRide() {
        stateLock.lock()
        defer { stateLock.unlock() }
        gate = CueExpiryGate()
    }

    /// WatchRideModel reports workout-session transitions here so acks can
    /// carry the flag without a cross-actor hop on the reply path.
    func setWorkoutActive(_ active: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        workoutActive = active
    }

    /// Send one "unsafe here" marker to the phone (D5, FR-006): live when
    /// reachable, queued otherwise or on failure — the payload carries
    /// the press instant, so late queued delivery still marks the road
    /// position the rider was actually at.
    func sendMarker() {
        let payload = MarkerPayload(
            markedTsMs: UInt64(Date().timeIntervalSince1970 * 1000))
        let message = payload.encoded()
        let session = WCSession.default
        guard session.isReachable else {
            session.transferUserInfo(message)
            return
        }
        // A reply handler is REQUIRED for the message to reach the
        // phone's with-reply delegate method — the no-reply variant would
        // route to a delegate stub and silently drop the marker.
        session.sendMessage(message, replyHandler: { _ in },
                            errorHandler: { _ in
            session.transferUserInfo(message)
        })
    }

    /// `receivedTsMs` is captured ONCE per delivery by the caller — the
    /// same clock sample goes into the phone's latency reply and this
    /// expiry verdict, so the two can never disagree about when the cue
    /// arrived. Returns the verdict (nil for malformed payloads) plus the
    /// workout flag sampled atomically with it, for the ack.
    private func receive(_ message: [String: Any],
                         receivedTsMs: UInt64) -> (verdict: CueVerdict?,
                                                   workoutActive: Bool) {
        let (verdict, workout): (CueVerdict?, Bool) = {
            stateLock.lock()
            defer { stateLock.unlock() }
            // Malformed payloads are dropped silently: the watch never
            // plays a cue it cannot fully validate (NFR-001 direction).
            guard let payload = CuePayload(from: message) else {
                return (nil, workoutActive)
            }
            return (gate.verdict(for: payload, receivedTsMs: receivedTsMs),
                    workoutActive)
        }()
        if verdict == .play {
            playCuePattern()
        }
        // Expired/duplicate cues are discarded; the ack's verdict tells
        // the phone's sidecar, which §13 reads as coverage loss rather
        // than pretending they helped.
        return (verdict, workout)
    }

    /// Remaining taps of the pattern in flight — main-queue confined
    /// (touched only inside playCuePattern's main-queue hop).
    private var pendingTaps: [DispatchWorkItem] = []

    /// RFC 0004 D2: schedule the fixed pattern; each tap is the same §12
    /// subtle .notification haptic. WKInterfaceDevice.play must run on
    /// the main thread — and is still a silent no-op if the app is not
    /// frontmost, which is exactly what the ack's workout_active flag
    /// lets the sidecar detect after the ride. A new cue CANCELS the
    /// remainder of a still-playing pattern, so overlapping distinct
    /// route events never stack additively: at most hapticRepeats taps
    /// are ever PENDING. The perceived worst case is hapticRepeats + 1 —
    /// cancel() cannot recall a tap already dequeued (the i=0 tap fires
    /// at .now()), so a cue landing mid-pattern can add one stray tap
    /// from the old pattern. Bounded and constant-urgency either way
    /// (the D2 "never lengthens" line, architectural not probabilistic).
    /// Play the selected candidate. `pattern` overrides the selection —
    /// used by the wrist comparison control, never by a cue.
    func playCuePattern(_ pattern: WatchHapticPattern? = nil) {
        let schedule = (pattern ?? Self.selectedPattern).tapOffsetsS
        DispatchQueue.main.async { [self] in
            // Cancelling first means a second cue REPLACES the rendering in
            // flight rather than interleaving with it, so the wrist can
            // never feel more than one pattern's worth of taps at once —
            // the §12 bound, enforced here because the schedule is now
            // long enough for an overlap to be possible at all.
            pendingTaps.forEach { $0.cancel() }
            pendingTaps = schedule.map { offset in
                let tap = DispatchWorkItem {
                    WKInterfaceDevice.current().play(.notification)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + offset,
                                              execute: tap)
                return tap
            }
        }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {}

    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        let receivedTsMs = UInt64(Date().timeIntervalSince1970 * 1000)
        // Ride-end control messages never reach the cue gate — they carry
        // none of CuePayload's required keys and would just decode to nil.
        if RideEndedPayload(from: message) != nil {
            onRideEnded?()
            // An empty reply, not a CueDeliveryAck: RFC 0004's delivery_ts_ms
            // / verdict / workout_active fields describe a cue's fate, which
            // is meaningless for a control message — the phone discards this
            // reply today, but a future reader shouldn't find cue semantics
            // stamped on a ride-end acknowledgment.
            replyHandler([:])
            return
        }
        // Verdict first, then reply: the gate is a set-insert, so the ack
        // can carry what the watch DID without delaying it measurably —
        // the latency clock sample was already taken above.
        let (verdict, workout) = receive(message, receivedTsMs: receivedTsMs)
        replyHandler(CueDeliveryAck(deliveryTsMs: receivedTsMs,
                                    verdict: verdict?.wireName,
                                    workoutActive: workout).encoded())
    }

    func session(_ session: WCSession,
                 didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if RideEndedPayload(from: userInfo) != nil {
            onRideEnded?()
            return
        }
        // Queued path: no reply channel, so the verdict goes unreported —
        // the phone's log already shows queued sends as undelivered.
        _ = receive(userInfo,
                    receivedTsMs: UInt64(Date().timeIntervalSince1970 * 1000))
    }
}
