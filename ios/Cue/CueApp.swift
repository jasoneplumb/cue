// Intent: iOS app entry point — the ride-screen shell (RFC 0003,
//         FR-001…009): region import, start/stop ride, live counters,
//         a phone-side marker button, the after-ride grading list (D7,
//         FR-008), and the exported artifact list. The engine room is
//         RideSessionController; this file is UI only.
import CueKernel
import CueRideEngine
import SwiftUI
import UniformTypeIdentifiers

@main
struct CueApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @StateObject private var session = RideSessionController.shared
    @State private var showingImporter = false
    @State private var showingCustomZoneImporter = false
    @State private var showingDiscardConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                // Ride first (#132): Start/Stop is the primary action at the
                // trailhead; setup sections below are typically touched once.
                // During a review the same top slot shows Review instead —
                // the two states are mutually exclusive.
                if session.state == .reviewing {
                    reviewSection
                } else {
                    rideSection
                }
                picoSection
                regionSection
                personalMemorySection
                if !session.exportedFiles.isEmpty { exportSection }
                if let error = session.lastError {
                    Section("Last error") {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
                // Debug knobs last (#140): next-ride configuration, not a
                // trailhead action — hidden mid-ride and mid-review, same
                // visibility the toggle had inside the pre-ride Ride section.
                if session.state != .riding && session.state != .reviewing {
                    debugSection
                }
            }
            // Which build is actually running (#107, #140): field installs
            // are verified by eye, and a failed install is invisible without
            // the version on screen — the title keeps it visible without
            // spending a list row on it.
            .navigationTitle(AppVersion.line)
            .fileImporter(isPresented: $showingImporter,
                          allowedContentTypes: [.json]) { result in
                if case .success(let url) = result {
                    session.importRegion(from: url)
                }
            }
            .fileImporter(isPresented: $showingCustomZoneImporter,
                          // webmap.dev exports .geojson; UTType(filenameExtension:)
                          // builds an ad-hoc type for it since the system has no
                          // registered public.geojson UTI — .json as a fallback for
                          // files saved with a plain .json extension.
                          allowedContentTypes: [UTType(filenameExtension: "geojson") ?? .json, .json]) { result in
                if case .success(let url) = result {
                    session.importCustomZones(from: url)
                }
            }
        }
    }

    private var regionSection: some View {
        Section("Region") {
            if session.state == .noRegion {
                Text("No region imported — pick an Overpass `out geom;` JSON export.")
                    .font(.footnote)
            } else {
                LabeledContent("Segments", value: "\(session.segmentCount)")
                LabeledContent("Squeeze zones", value: "\(session.zoneCount)")
            }
            Button("Import region…") { showingImporter = true }
                .disabled(session.state == .riding || session.state == .reviewing)
        }
    }

    /// RFC 0002: rider-authored signal (in-ride markers, after-ride
    /// reviews, and imported webmap.dev custom zones) that biases cueing
    /// independently of the OSM-derived squeeze zones above.
    private var personalMemorySection: some View {
        Section("Personal memory") {
            LabeledContent("Remembered segments", value: "\(session.rememberedSegmentCount)")
            Button("Import custom zones…") { showingCustomZoneImporter = true }
                .disabled(session.state == .noRegion || session.state == .riding
                    || session.state == .reviewing)
            Text("Zones drawn in webmap.dev — snapped to the imported region and "
                 + "treated like an \u{201c}unsafe here\u{201d} marker.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var rideSection: some View {
        Section("Ride") {
            if session.state == .riding {
                LabeledContent("Samples", value: "\(session.sampleCount)")
                LabeledContent("Cues", value: "\(session.cueCount)")
                LabeledContent("Markers", value: "\(session.markerCount)")
                if let reason = session.lastReasonCode {
                    LabeledContent("Last gate", value: Self.reasonLabel(reason))
                }
                Button("Unsafe here") { session.mark() }
                #if DEBUG
                // Debug builds only (#131): lands a synthetic HEAD_UP on
                // demand — phone chime + watch tap — without touching the
                // trace, so cue delivery is testable without riding past a
                // real squeeze zone.
                Button("Test cue") { session.fireTestCue() }
                // Drives the Pico's actuator only — neither kernel is
                // involved, so it never enters the decision stream
                // (RFC 0006 D3). The way to bench-test the buzzer.
                Button("Test cue (pico)") { session.picoLink.fireTestCue() }
                #endif
                Button("Stop ride", role: .destructive) { session.stopRide() }
                Text(RideSessionController.ridesInBackground
                     ? "Sampling continues with the screen locked — pocket the phone."
                     : "Keep the screen on: this build lacks the location background mode.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Button("Start ride") { session.startRide() }
                    .disabled(session.state != .ready)
            }
        }
    }

    /// Moved out of the pre-ride Ride section (#140): the toggle configures
    /// the NEXT ride, so it lives at the bottom with one-time setup rather
    /// than beside Start ride. No section header — the toggle's own
    /// "(debug)" label already carries it.
    private var debugSection: some View {
        Section {
            Toggle("Keep GPS (debug)", isOn: $session.debugGPS)
            if session.debugGPS {
                // The privacy contract in one breath (#109, NFR-005):
                // what extra file appears, what's in it, where it may
                // go. Shown only while ON — the default path needs no
                // caveat.
                Text("This ride will also export …-trace-debug.json "
                     + "with your actual route, for checking map "
                     + "matching on your own computer. Keep it private. "
                     + "The standard trace never contains GPS.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - After-ride review (D7, FR-008)

    private var reviewSection: some View {
        Section("Review") {
            if session.reviewCues.isEmpty {
                Text("No cues this ride.").font(.footnote).foregroundStyle(.secondary)
            }
            // Kernel guarantees at most one HEAD_UP per event (NFR-001),
            // so eventID is a valid row identity.
            ForEach(session.reviewCues, id: \.eventID) { cue in
                HStack {
                    Text(Self.rideClock(tMs: cue.tMs)).font(.body.monospacedDigit())
                    Text("event \(cue.eventID)")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    // Menu picker: four outcomes is too wide for segmented
                    // control; the menu label shows the current selection.
                    Picker("", selection: gradeBinding(eventID: cue.eventID)) {
                        Text("ungraded").tag(ReviewOutcome?.none)
                        ForEach(ReviewOutcome.allCases, id: \.self) { outcome in
                            Text(Self.outcomeLabel(outcome))
                                .tag(ReviewOutcome?.some(outcome))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            }
            // Markers ride alongside cues in the review (D7: "list of
            // cues (and markers)") — the rider's own ground truth for
            // the missed-risk judgment.
            ForEach(Array(session.reviewMarkers.enumerated()), id: \.offset) { _, marker in
                HStack {
                    Text(Self.rideClock(tMs: marker.tMs)).font(.body.monospacedDigit())
                    Text("marker · segment \(marker.segmentID)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Button("Finish & export") { session.finishReview() }
            Text("Grades write into the trace before export — "
                 + "finishing without grading is fine.")
                .font(.footnote).foregroundStyle(.secondary)
            // Discard is irreversible (#135) — a stray tap must not lose a
            // ride silently, so the destructive action routes through a
            // confirmation dialog.
            Button("Discard ride", role: .destructive) {
                showingDiscardConfirmation = true
            }
            .confirmationDialog(
                "Discard this ride? Its recording and any grades will be lost.",
                isPresented: $showingDiscardConfirmation,
                titleVisibility: .visible
            ) {
                Button("Discard ride", role: .destructive) {
                    session.discardReview()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    /// Selection binding per cue; ungraded (nil) is display-only — grades
    /// replace, they are never cleared (one review per cue).
    private func gradeBinding(eventID: UInt32) -> Binding<ReviewOutcome?> {
        Binding(
            get: { session.grades[eventID] },
            set: { outcome in
                if let outcome { session.grade(eventID: eventID, outcome: outcome) }
            })
    }

    private static func rideClock(tMs: UInt32) -> String {
        let seconds = tMs / 1000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Short rider-facing description of the kernel's last gate decision
    /// (`kernel/cue_policy.h` `CUE_REASON_CODE_*`; mirrors the symbolic
    /// names `replay/replay_main.c`'s `reason_code_name` uses for --stats).
    private static func reasonLabel(_ code: UInt8) -> String {
        switch code {
        case 0: return "cued"
        case 1: return "no event"
        case 2: return "below severity threshold"
        case 3: return "below confidence threshold"
        case 4: return "inside event"
        case 5: return "too slow"
        case 6: return "too late to notice"
        case 7: return "too early to notice"
        case 8: return "already cued"
        case 9: return "cooldown (time)"
        case 10: return "cooldown (distance)"
        case 11: return "memory suppressed"
        default: return "reason \(code)"
        }
    }

    private static func outcomeLabel(_ outcome: ReviewOutcome) -> String {
        switch outcome {
        case .useful: return "Useful"
        case .falseAlarm: return "False alarm"
        case .tooLate: return "Too late"
        case .tooEarly: return "Too early"
        case .unrecognized: return "Unrecognized"
        }
    }

    /// RFC 0006: the MCU cue channel's live state. Visible outside a ride
    /// too — knowing whether the board was found is exactly what you want
    /// before setting off, and divergence is the D5 gate's headline
    /// metric, so it should not wait for the post-ride sidecar.
    ///
    /// A SEPARATE VIEW on purpose: PicoBLELink is its own ObservableObject
    /// hanging off the controller, and a nested one's @Published changes
    /// fire its own objectWillChange, not the parent's. Read through
    /// `session.picoLink` this would render once and then sit frozen at
    /// "starting" while the link connected behind it.
    private var picoSection: some View {
        PicoStatusSection(link: session.picoLink, riding: session.state == .riding)
    }

    private var exportSection: some View {
        Section("Exported (Documents)") {
            ForEach(session.exportedFiles, id: \.self) { url in
                Text(url.lastPathComponent).font(.footnote.monospaced())
            }
        }
    }
}

#Preview {
    ContentView()
}

/// Live status for the MCU cue channel (RFC 0006). Observes the link
/// directly — see the note on `picoSection` for why it cannot be inlined.
private struct PicoStatusSection: View {
    @ObservedObject var link: PicoBLELink
    let riding: Bool

    var body: some View {
        Section("Cue device") {
            LabeledContent("Link", value: Self.label(link.state))
            if riding {
                LabeledContent("Divergences", value: "\(link.divergenceCount)")
            }
            if let mv = link.batteryMillivolts {
                LabeledContent("Battery", value: "\(mv) mV")
            }
            if case .incompatible(let size) = link.state {
                Text("Firmware kernel state is \(size) B but this build expects "
                     + "\(CuePolicy.stateSize) B — reflash the Pico from this "
                     + "commit before riding.")
                    .font(.footnote).foregroundStyle(.red)
            }
            if let error = link.lastError {
                Text(error).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private static func label(_ state: PicoBLELink.LinkState) -> String {
        switch state {
        case .idle: return "starting"
        case .unsupported: return "no Bluetooth"
        case .unauthorized: return "Bluetooth denied"
        case .poweredOff: return "Bluetooth off"
        case .scanning: return "looking for pico-cue"
        case .connecting: return "connecting"
        case .ready: return "connected"
        case .riding: return "streaming"
        case .incompatible: return "incompatible firmware"
        }
    }
}
