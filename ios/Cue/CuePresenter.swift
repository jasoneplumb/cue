// Intent: The cue-delivery fan-out (RFC 0006 D5). `deliver` used to call
//         the watch dispatch and the phone chime directly; this makes each
//         a presenter so they can be retired independently once the Pico
//         channel is validated, without disturbing the single call site
//         every HEAD_UP leaves through.
// Context: The Pico is deliberately NOT a presenter. It self-actuates from
//          its own kernel on the 1 Hz step stream (RFC 0006 D2), so
//          delivering to it here would cue the rider twice for one
//          decision. CuePicoLink's only tie to this boundary is the debug
//          test cue.
// Pattern: One protocol, one array, no behaviour change on introduction —
//          the refactor is deliberately inert so the retirement in Phase E
//          is a deletion rather than a rewrite.
import CueKernel
import CueWatchLink
import Foundation

@MainActor
protocol CuePresenter {
    /// Render one HEAD_UP to the rider. `sampleTMs` is the ride-relative
    /// time of the kernel step that produced it — the anchor the watch
    /// expiry gate needs (RFC 0003 D4).
    func present(_ decision: CueDecision, sampleTMs: UInt32)
}

/// The RFC 0004 channel: a fixed triple-tap on the watch.
@MainActor
struct WatchCuePresenter: CuePresenter {
    let dispatcher: CueDispatcher

    func present(_ decision: CueDecision, sampleTMs: UInt32) {
        dispatcher.dispatch(decision, sampleTMs: sampleTMs)
    }
}

/// The RFC 0005 channel: a phone-local chime, independent of the watch.
@MainActor
struct ChimeCuePresenter: CuePresenter {
    func present(_ decision: CueDecision, sampleTMs: UInt32) {
        CueChimePlayer.shared.play()
    }
}
