// Intent: Phone-side WCSession adapter (RFC 0003 D4): the thin glue that
//         lets CueDispatcher's platform-neutral policy drive the real
//         watch link. sendMessage is the sub-second live path when the
//         watch is reachable; transferUserInfo is the queued fallback —
//         the dispatcher decides which, this file only carries bytes.
// Pattern: The watch's reply to a live message carries its wall clock at
//          receipt (delivery_ts_ms); the dispatcher pairs it with the
//          kernel-anchored dispatch_ts to measure delivery latency (the
//          asmp0002 / meas0002 instrument).
import CueWatchLink
import Foundation
import WatchConnectivity

// @unchecked Sendable: the only mutable state is the marker callback,
// lock-guarded because it is set from the main actor while WCSession
// invokes it from its delegate queue.
final class PhoneWatchLink: NSObject, WCSessionDelegate, CueTransport, @unchecked Sendable {
    static let shared = PhoneWatchLink()

    private let callbackLock = NSLock()
    private var _onMarker: (@Sendable (MarkerPayload) -> Void)?

    /// Fired for every valid watch marker message (D5). The callback is
    /// invoked on WCSession's delegate queue — hop to your actor inside.
    var onMarker: (@Sendable (MarkerPayload) -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return _onMarker }
        set { callbackLock.lock(); defer { callbackLock.unlock() }; _onMarker = newValue }
    }

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // MARK: - CueTransport

    var isReachable: Bool {
        WCSession.isSupported() && WCSession.default.isReachable
    }

    func sendLive(_ message: [String: Any],
                  onDeliveryAck: @escaping (CueDeliveryAck) -> Void,
                  onFailure: @escaping () -> Void) {
        WCSession.default.sendMessage(
            message,
            replyHandler: { reply in
                // Any reply means the watch got the cue — ack always; the
                // decode is total (every field nil on absence/mistype), so
                // the log records "delivered, details unmeasurable" rather
                // than falsely counting it as coverage loss.
                onDeliveryAck(CueDeliveryAck(from: reply))
            },
            errorHandler: { _ in onFailure() })
    }

    func sendQueued(_ message: [String: Any]) {
        WCSession.default.transferUserInfo(message)
    }

    /// Tell the watch the ride just ended (RideSessionController.stopRide),
    /// so "Ride mode" turns off — and its HKWorkoutSession ends — without
    /// the rider reaching for the watch. Fire-and-forget: same live/queued
    /// path policy as cues, but no ack/latency bookkeeping — there is no
    /// expiry to measure here.
    func sendRideEnded() {
        let message = RideEndedPayload().encoded()
        guard isReachable else {
            WCSession.default.transferUserInfo(message)
            return
        }
        WCSession.default.sendMessage(message, replyHandler: { _ in },
                                      errorHandler: { _ in
            WCSession.default.transferUserInfo(message)
        })
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {}

    // The phone receives exactly one kind of traffic: watch markers (D5).
    // Both sendMessage variants are handled — which delegate method fires
    // depends on whether the SENDER attached a reply handler, and a
    // marker must never be dropped over that detail.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        replyHandler(["ok": 1])
        guard let payload = MarkerPayload(from: message) else { return }
        onMarker?(payload)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let payload = MarkerPayload(from: message) else { return }
        onMarker?(payload)
    }

    func session(_ session: WCSession,
                 didReceiveUserInfo userInfo: [String: Any] = [:]) {
        // Queued fallback markers (watch was unreachable at press time).
        guard let payload = MarkerPayload(from: userInfo) else { return }
        onMarker?(payload)
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // Watch switched: reactivate for the new pairing.
        session.activate()
    }
}
