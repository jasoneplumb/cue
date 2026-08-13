// Intent: Watch app — the ride screen (RFC 0003 D4/D5): one large
//         "unsafe here" button (FR-006's second input, covering voice's
//         wind/traffic-noise failure mode) and a keep-alive toggle for
//         the ride. Cue haptics arrive through WatchCueReceiver; this
//         file is UI only.
import CueKernel
import CueWatchLink
import HealthKit
import SwiftUI
import WatchKit

@main
struct CueWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchContentView()
        }
    }
}

struct WatchContentView: View {
    @StateObject private var ride = WatchRideModel()

    var body: some View {
        VStack(spacing: 10) {
            // The big tappable control (§5.8): most of the screen.
            Button {
                ride.markUnsafeHere()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                    Text("Unsafe here")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, minHeight: 90)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)

            Toggle("Ride mode", isOn: $ride.rideMode)
                .font(.footnote)
            if let note = ride.sessionNote {
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }

            // Cue-rendering comparison (RFC 0006 D8). Tap to hear the
            // selected candidate on the wrist, long-press to move to the
            // next — the whole point is judging them back-to-back against
            // real road vibration, which cannot be done from a desk.
            // This plays the actuator only: it never involves the kernel,
            // so a comparison can never enter the decision stream.
            // Not a Button with a simultaneous long-press gesture: that
            // fires the gesture at the hold threshold AND the button
            // action on release, so one long press plays twice and the
            // second play cancels the first mid-rhythm. On the control
            // being used to judge perceptibility, that glitch is exactly
            // the thing under measurement.
            Text("Cue: \(ride.hapticPatternName)")
                .font(.footnote)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .onTapGesture { WatchCueReceiver.shared.playCuePattern() }
                .onLongPressGesture { ride.cycleHapticPattern() }
            // Which build is actually running (#107) — same line as the
            // phone app, so a half-updated pair is visible at a glance.
            Text(AppVersion.line)
                .font(.footnote).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 6)
        .onAppear { _ = WatchCueReceiver.shared }  // activate the session
    }
}

/// Watch-side ride state: sends markers (live with queued fallback) and
/// holds a cycling WORKOUT session while ride mode is on so cue taps
/// land with the wrist down (RFC 0003 D4 names the workout session; the
/// extended-runtime types all cap at minutes-to-an-hour and none
/// describe a ride — the first provisioning attempt proved the
/// undeclared-type path invalidates instantly, #87).
///
/// Requires the HealthKit capability + workout-processing background
/// mode (ios/CueWatchSupport/). First toggle prompts for Health access;
/// cue reads and saves nothing — the session exists purely to keep the
/// app responsive.
@MainActor
final class WatchRideModel: NSObject, ObservableObject {
    /// Name of the selected cue rendering, for the comparison control.
    @Published private(set) var hapticPatternName =
        WatchCueReceiver.selectedPattern.name

    /// Advance to the next candidate and play it immediately — hearing
    /// the new selection is the point of changing it.
    func cycleHapticPattern() {
        let next = WatchHapticPatterns.nextIndex(
            after: WatchCueReceiver.selectedPatternIndex)
        WatchCueReceiver.selectedPatternIndex = next
        hapticPatternName = WatchCueReceiver.selectedPattern.name
        WatchCueReceiver.shared.playCuePattern()
    }

    @Published var rideMode = false {
        didSet {
            guard oldValue != rideMode else { return }
            rideMode ? startSession() : endSession()
        }
    }
    @Published private(set) var sessionNote: String?

    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?

    override init() {
        super.init()
        // The phone reports its own ride end (RideSessionController
        // .stopRide) so the toggle doesn't sit ON over a dead ride until
        // the rider notices and flips it manually.
        WatchCueReceiver.shared.onRideEnded = { [weak self] in
            Task { @MainActor in self?.endRideFromPhone() }
        }
    }

    /// Mirrors the system-ended path (workoutSession delegate, .stopped) so
    /// the note explains why the toggle flipped without a tap here.
    private func endRideFromPhone() {
        guard rideMode else { return }
        rideMode = false
        sessionNote = "ride mode ended by the phone"
    }

    func markUnsafeHere() {
        WatchCueReceiver.shared.sendMarker()
        // §5.8: exactly one capture confirmation, distinct from the cue
        // tap (.notification): capture uses .click.
        WKInterfaceDevice.current().play(.click)
    }

    private func startSession() {
        sessionNote = nil
        // Starting a workout session requires share authorization for the
        // workout type even though cue never saves one.
        healthStore.requestAuthorization(
            toShare: [HKObjectType.workoutType()], read: []) { [weak self] granted, error in
            Task { @MainActor in
                guard let self else { return }
                // The user may have toggled ride mode back off while the
                // authorization prompt was up — starting a session now
                // would orphan it live behind an off toggle.
                guard self.rideMode else { return }
                guard granted, error == nil else {
                    self.rideMode = false
                    self.sessionNote = "ride mode needs Health access (Settings › Health)"
                    return
                }
                self.beginWorkout()
            }
        }
    }

    private func beginWorkout() {
        // Idempotent against overlapping auth callbacks (rapid on/off/on
        // queues one callback per toggle-on): a session already running
        // means this begin is a duplicate — ending it first guarantees at
        // most one live session ever exists.
        workoutSession?.end()
        workoutSession = nil
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .cycling
        configuration.locationType = .outdoor
        do {
            let session = try HKWorkoutSession(healthStore: healthStore,
                                               configuration: configuration)
            session.delegate = self
            session.startActivity(with: Date())
            workoutSession = session
            // The receiver mirrors this flag into every cue ack
            // (RFC 0004 D1) — it must track the session, not the toggle:
            // the toggle can be ON over a dead session for the instant
            // before the delegate callback lands.
            WatchCueReceiver.shared.setWorkoutActive(true)
        } catch {
            rideMode = false
            sessionNote = "ride mode failed: \(error.localizedDescription)"
        }
    }

    private func endSession() {
        // No setWorkoutActive(false) here: end() is asynchronous and the
        // session keeps the app haptic-eligible until the .ended delegate
        // callback (which clears the flag). Clearing early would stamp a
        // cue acked in that window with the false "silent no-op"
        // signature RFC 0004 exists to isolate.
        workoutSession?.end()
        workoutSession = nil
    }
}

// The system can end a workout session (user action in the workout UI,
// resource pressure). The delegate is the only signal; without it, ride
// mode would silently lie.
extension WatchRideModel: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState,
                                    date: Date) {
        // Both terminal states: .ended (normal) and .stopped (the system
        // halted the session before end() was called) — missing either
        // would leave the toggle ON over a dead session.
        guard toState == .ended || toState == .stopped else { return }
        // ObjectIdentifier, not the session itself, crosses into the main-
        // actor task: HKWorkoutSession is not Sendable, and identity is
        // all the guard needs.
        let endedID = ObjectIdentifier(workoutSession)
        Task { @MainActor in
            // Identity guard: only the CURRENT session's terminal state
            // clears the flag — a stale callback from a session that
            // beginWorkout already replaced must not mark the live one
            // haptic-ineligible. (nil matches too: the endSession path
            // has already released the session but not the flag.)
            guard self.currentSessionID == endedID
                    || self.workoutSession == nil else { return }
            WatchCueReceiver.shared.setWorkoutActive(false)
            self.workoutSession = nil
            if self.rideMode {
                self.rideMode = false
                self.sessionNote = "ride mode ended by the system"
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didFailWithError error: Error) {
        let failedID = ObjectIdentifier(workoutSession)
        Task { @MainActor in
            guard self.currentSessionID == failedID
                    || self.workoutSession == nil else { return }
            WatchCueReceiver.shared.setWorkoutActive(false)
            self.workoutSession = nil
            self.rideMode = false
            self.sessionNote = "ride mode failed: \(error.localizedDescription)"
        }
    }

    private var currentSessionID: ObjectIdentifier? {
        workoutSession.map(ObjectIdentifier.init)
    }
}
