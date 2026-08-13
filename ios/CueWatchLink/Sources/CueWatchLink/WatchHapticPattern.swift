// Intent: The candidate wrist renderings of one cue — a table of tap
//         schedules plus the rules that keep every one of them inside
//         spec §12. The watch app plays what this describes; it decides
//         nothing itself.
// Context: RFC 0006 D8 (watch envelopes), amending D5's retirement of the
//          watch haptic. RFC 0004 D2 established the original fixed
//          triple-tap; it was masked by handlebar and road vibration,
//          which is the failure this table exists to search past.
// Pattern: Platform-neutral and data-only, like CuePayload and
//          CueExpiryGate — so `swift test` covers it on macOS while the
//          WKInterfaceDevice glue stays in the watch target
//          (Package.swift's stated split).
//
// What watchOS actually allows. `WKInterfaceDevice.play(_:)` takes a
// fixed `WKHapticType` and exposes NO duration or intensity control. So
// "duty cycle" on this platform can only mean the SPACING between
// discrete taps — a decelerating envelope is taps that thin out, not taps
// that weaken. Every candidate below is therefore a schedule of tap
// instants and nothing more, which is also why the table is honest to
// test: the offsets are the whole behaviour.

import Foundation

/// One fixed-length rendering of a single cue.
public struct WatchHapticPattern: Sendable, Equatable {
    public let name: String
    /// Which axis this candidate probes relative to the baseline.
    /// Comparison notes belong next to the numbers they explain.
    public let probes: String
    /// Tap instants in seconds from cue start, strictly ascending.
    public let tapOffsetsS: [Double]

    public var durationS: Double { tapOffsetsS.last ?? 0 }
    public var tapCount: Int { tapOffsetsS.count }

    public init(name: String, probes: String, tapOffsetsS: [Double]) {
        self.name = name
        self.probes = probes
        self.tapOffsetsS = tapOffsetsS
    }
}

public enum WatchHapticPatterns {
    /// No candidate may outlast this.
    ///
    /// Note what a rendering longer than `min_notice_s` (5 s) means: a cue
    /// delivered at minimum notice is still tapping when the rider reaches
    /// the zone. For the handlebar buzzer that would be noise, and
    /// `CUE_PATTERN_MAX_DURATION_MS` forbids it. For a wrist tap it is a
    /// deliberate, recorded trade — a sparse tap *during* the event is
    /// arguably still information, where a sound is not. It is recorded
    /// rather than assumed away: see RFC 0006 D8.
    public static let maxDurationS = 10.0

    /// Spacing floor. Below roughly this, watchOS coalesces taps and the
    /// rider feels one long mush instead of a rhythm — and the schedule
    /// stops describing what actually happens.
    public static let minSpacingS = 0.10

    /// The baseline: RFC 0004 D2's fixed triple-tap, the rendering that
    /// failed in the field. Kept as candidate 0 precisely so every
    /// comparison is against the thing that did not work.
    public static let baseline = WatchHapticPattern(
        name: "triple-600",
        probes: "baseline: RFC 0004's three taps, 600 ms apart",
        tapOffsetsS: [0, 0.6, 1.2])

    /// Rapid onset decaying over ~10 s: intervals grow monotonically from
    /// 150 ms to 1.85 s. The hypothesis is that a *changing* rhythm is
    /// separable from the constant buzz of road surface in a way the
    /// metronomic triple-tap was not, and that a long tail keeps the cue
    /// present while the rider is still closing on the zone.
    public static let descending10s = WatchHapticPattern(
        name: "descend-10s",
        probes: "rapid onset decaying over 10 s (intervals 0.15 s -> 1.85 s)",
        tapOffsetsS: [0, 0.15, 0.32, 0.52, 0.76, 1.05, 1.40, 1.85, 2.40,
                      3.10, 4.00, 5.10, 6.45, 8.05, 9.90])

    /// The same decaying shape compressed into 5 s, so a preference for
    /// `descend-10s` can be attributed to the decay or to the length —
    /// not left ambiguous between them.
    public static let descending5s = WatchHapticPattern(
        name: "descend-5s",
        probes: "vs descend-10s: the same decay, half the length",
        tapOffsetsS: [0, 0.12, 0.26, 0.42, 0.61, 0.84, 1.12, 1.48, 1.94,
                      2.52, 3.25, 4.10, 5.00])

    /// The mirror: sparse onset accelerating to a rapid finish. An
    /// accelerating rhythm reads as something closing in, which is
    /// arguably the more apt metaphor for a zone the rider is riding
    /// toward — and it is the only way to tell whether the decay in the
    /// candidates above is doing the work or merely the change.
    ///
    /// Exactly the time-reversal of `descend-5s`: same duration, same tap
    /// count, same multiset of intervals, opposite order. That equality is
    /// asserted by the tests, and it is what lets a preference between the
    /// two be attributed to DIRECTION alone. A merely similar pattern
    /// would confound direction with length and the comparison would prove
    /// nothing.
    public static let ascending5s = WatchHapticPattern(
        name: "ascend-5s",
        probes: "vs descend-5s: direction of change, length held identical",
        tapOffsetsS: [0, 0.90, 1.75, 2.48, 3.06, 3.52, 3.88, 4.16, 4.39,
                      4.58, 4.74, 4.88, 5.00])

    /// Constant 800 ms spacing for 10 s. Isolates duration from rhythm:
    /// if this reads as well as `descend-10s`, the decay is decoration
    /// and length was the whole story.
    public static let steady10s = WatchHapticPattern(
        name: "steady-10s",
        probes: "vs descend-10s: duration without any change in rhythm",
        tapOffsetsS: [0, 0.8, 1.6, 2.4, 3.2, 4.0, 4.8, 5.6, 6.4, 7.2, 8.0,
                      8.8, 9.6])

    /// Index order is the selector's order and the order the watch UI
    /// cycles. Append only — inserting would renumber every candidate a
    /// ride note refers to.
    public static let all: [WatchHapticPattern] = [
        baseline, descending10s, descending5s, ascending5s, steady10s,
    ]

    /// Compiled-in default. `descend-10s` is the operator's requested
    /// shape; it is provisional until wrist comparison on a real ride,
    /// which is why the others stay selectable.
    public static let defaultIndex = 1

    public static func pattern(at index: Int) -> WatchHapticPattern {
        guard all.indices.contains(index) else { return all[defaultIndex] }
        return all[index]
    }

    /// Wrap-around cycle, for a UI with one control and no room for a list.
    public static func nextIndex(after index: Int) -> Int {
        all.indices.contains(index) ? (index + 1) % all.count : defaultIndex
    }
}
