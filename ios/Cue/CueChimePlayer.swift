// Intent: Phone-side audible cue delivery. Plays a short synthesized
//         chime on every HEAD_UP, independent of the watch link — so a
//         cue is still heard when the watch is not worn, or when its
//         haptic goes unnoticed. Dispatched from the same call site as
//         the watch send (RideSessionController.process) for best-effort
//         simultaneity: WatchConnectivity's measured delivery latency
//         (CueDispatcher's asmp0002 instrument, p95 target <= 2 s) means
//         exact sync between the chime and the watch haptic is not
//         guaranteed — this fires immediately, the watch tap follows
//         whenever the link delivers it.
// Pattern: The tone is synthesized at init, not a bundled asset — no
//          audio file ships in the repo, so there is nothing to license.
//          Delivery is best-effort all the way down: AVFAudio raises
//          ObjC NSExceptions (uncatchable from Swift) when a player node
//          is started on a stopped engine, so the engine is revived
//          after interruptions, route changes, and media-services
//          resets, and play() skips the chime rather than touch an
//          engine it could not restart — the watch haptic path is
//          unaffected either way.
import AVFoundation

@MainActor
final class CueChimePlayer {
    static let shared = CueChimePlayer()

    // Rebuilt wholesale after a media-services reset (which invalidates
    // every node the old engine owned), so `var`, not `let`.
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private let buffer: AVAudioPCMBuffer

    /// Chimes are only wanted between prepareForRide() and teardown();
    /// the recovery observers below use this to stay inert outside rides.
    private var rideActive = false
    /// Set while an AVAudioSession interruption (phone call, Siri) is in
    /// progress — the session is not ours to use until it ends.
    private var interrupted = false
    /// Tracks the engine-scoped configuration-change observer so it can
    /// follow the engine across a media-services rebuild.
    private var configChangeObserver: NSObjectProtocol?
    /// Session-scoped observers live as long as this singleton, but the
    /// tokens are retained anyway so a future teardown path can remove
    /// them instead of leaking closures into NotificationCenter.
    private var sessionObservers: [NSObjectProtocol] = []

    private init() {
        buffer = Self.makeChimeBuffer()
        wireEngine()

        let center = NotificationCenter.default
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in
                guard let raw,
                      let type = AVAudioSession.InterruptionType(rawValue: raw)
                else { return }
                self?.handleInterruption(type)
            }
        })
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.rebuildAfterMediaServicesReset()
            }
        })
    }

    /// Activates the session so the chime is audible even with the
    /// silent switch on — muted-but-still-missed is exactly the failure
    /// mode this exists to fix — while mixing with other audio (a
    /// podcast, a cycling computer) rather than cutting it off. Mixing
    /// only: `.duckOthers` would apply for the whole time the session is
    /// active, not just while the chime rings, so other apps stayed
    /// attenuated for the entire ride. Call once per ride, before the
    /// first cue can fire; a failure here is non-fatal (best-effort
    /// audio, never blocks the ride or the watch haptic path).
    func prepareForRide() {
        rideActive = true
        // Stale-interruption reset: the observers run between rides too,
        // and a dropped .ended (or one that never fires because session
        // activation failed) must not mute an entire later ride.
        interrupted = false
        activateSessionAndStartEngine()
    }

    /// Shared by ride start and post-reset recovery, so recovery never
    /// routes through the public entry point (whose side effects may
    /// grow beyond audio setup).
    private func activateSessionAndStartEngine() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            try engine.start()
        } catch {
            // Deliberately silent: see prepareForRide() doc comment.
        }
    }

    /// Drops the session at ride end, mirroring how stopRide() drops the
    /// background-location privilege the moment it is no longer needed.
    func teardown() {
        rideActive = false
        interrupted = false
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(
            false, options: [.notifyOthersOnDeactivation])
    }

    /// A cue landing while the previous chime is still ringing interrupts
    /// it rather than layering — same "a new cue cancels the remainder of
    /// the old pattern" rule WatchCueReceiver.playCuePattern() uses for
    /// the haptic, so both delivery paths degrade the same way under a
    /// tight run of events.
    func play() {
        guard rideActive, !interrupted else { return }
        // A route change (earbuds dropping mid-ride) can stop the engine
        // between cues; a recovery notification may not have landed yet
        // when the next cue does. Restart here as the last line of
        // defense — starting a player node on a stopped engine aborts
        // the whole process (see Pattern above), and losing the ride
        // trace to a chime is the wrong trade.
        if !engine.isRunning {
            restartEngineIfRiding()
        }
        guard engine.isRunning else { return }
        // TOCTOU: engine.isRunning can go stale between the guard above
        // and player.play() — AVAudioEngine tears down on framework-
        // internal threads. The resulting NSException is uncatchable from
        // Swift; the ObjC shim lets us skip the chime instead of aborting
        // the process (and losing the in-flight ride recording).
        let buf = buffer
        let p = player
        let caught = CueCatchObjCException {
            p.scheduleBuffer(buf, at: nil, options: .interrupts)
            p.play()
        }
        if let caught {
            assert(caught.name.rawValue.contains("coreaudio")
                || caught.name == .genericException
                || caught.name == NSExceptionName("NSInternalInconsistencyException"),
                "Unexpected ObjC exception in chime path: \(caught)")
            print("[CueChimePlayer] ObjC exception caught — chime skipped: "
                + "\(caught.name.rawValue): \(caught.reason ?? "<no reason>")")
            restartEngineIfRiding()
        }
    }

    /// Attaches the player and points the configuration-change observer
    /// at the current engine instance — stale notifications from a
    /// pre-reset engine must not trigger restarts of the new one.
    private func wireEngine() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.restartEngineIfRiding()
            }
        }
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType) {
        switch type {
        case .began:
            interrupted = true
        case .ended:
            interrupted = false
            restartEngineIfRiding()
        @unknown default:
            break
        }
    }

    private func restartEngineIfRiding() {
        guard rideActive, !interrupted, !engine.isRunning else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        try? engine.start()
    }

    /// A media-services reset orphans the old engine's node graph;
    /// per Apple's guidance the engine and nodes must be recreated,
    /// not restarted.
    private func rebuildAfterMediaServicesReset() {
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        wireEngine()
        if rideActive, !interrupted {
            activateSessionAndStartEngine()
        }
    }

    /// A soft two-partial bell tone (fundamental + a fifth above),
    /// exponential decay — deliberately generated, not sampled, so no
    /// audio asset needs bundling into the app.
    private static func makeChimeBuffer() -> AVAudioPCMBuffer {
        let sampleRate = 44_100.0
        let duration = 1.2
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                   channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let channel = buffer.floatChannelData![0]
        let fundamental = 660.0    // E5 — soft, unobtrusive
        let overtone = fundamental * 1.5  // a fifth above
        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            let envelope = exp(-3.0 * t)
            let sample = 0.6 * sin(2 * .pi * fundamental * t)
                       + 0.3 * sin(2 * .pi * overtone * t)
            channel[i] = Float(sample * envelope * 0.5)
        }
        return buffer
    }
}
