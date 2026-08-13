// Intent: Pin the invariants of the candidate wrist renderings
//         (RFC 0006 D8). The watch app plays these offsets without
//         further checking, and the §12 non-escalation rule is a property
//         of the table itself — so it is asserted here rather than
//         discovered on a wrist.
import Testing

@testable import CueWatchLink

@Suite("Watch haptic candidates")
struct WatchHapticPatternTests {

    @Test("every candidate is a well-formed, fixed-length schedule")
    func schedulesAreWellFormed() {
        for pattern in WatchHapticPatterns.all {
            #expect(!pattern.name.isEmpty)
            #expect(!pattern.probes.isEmpty, "\(pattern.name) documents its axis")
            #expect(pattern.tapCount >= 2, "\(pattern.name) has a rhythm at all")
            #expect(pattern.tapOffsetsS.first == 0,
                    "\(pattern.name) starts at the cue instant")
            #expect(pattern.durationS <= WatchHapticPatterns.maxDurationS,
                    "\(pattern.name) is within the duration ceiling")
        }
    }

    /// Strictly ascending, and never closer than the coalescing floor —
    /// below it watchOS merges taps and the schedule stops describing
    /// what the rider actually feels.
    @Test("taps are ordered and far enough apart to be felt separately")
    func tapsAreSeparable() {
        for pattern in WatchHapticPatterns.all {
            for (a, b) in zip(pattern.tapOffsetsS, pattern.tapOffsetsS.dropFirst()) {
                #expect(b > a, "\(pattern.name) offsets ascend")
                #expect(b - a >= WatchHapticPatterns.minSpacingS - 1e-9,
                        "\(pattern.name) gap \(b - a)s is above the floor")
            }
        }
    }

    /// Which candidate is the compiled-in default is a decision recorded
    /// in RFC 0006 D8, so changing it should be a deliberate act that
    /// updates the design record — not something a reordering of the
    /// table does silently.
    ///
    /// (This replaces an earlier "schedules are constant" test that could
    /// never fail: reading a `static let` twice trivially returns equal
    /// values. The §12 guarantee it claimed to check is provided by the
    /// type system, and a test that cannot fail advertises coverage that
    /// does not exist.)
    @Test("the default candidate is the one D8 records")
    func defaultIsRecorded() {
        let chosen = WatchHapticPatterns.all[WatchHapticPatterns.defaultIndex]
        #expect(chosen.name == "descend-10s")
        #expect(chosen.durationS <= WatchHapticPatterns.maxDurationS)
    }

    /// The named shapes must actually have the shape their names claim,
    /// or a comparison attributes a preference to the wrong axis.
    @Test("descending patterns decelerate and ascending ones accelerate")
    func envelopeDirections() {
        func intervals(_ p: WatchHapticPattern) -> [Double] {
            zip(p.tapOffsetsS, p.tapOffsetsS.dropFirst()).map { $1 - $0 }
        }

        for pattern in [WatchHapticPatterns.descending10s,
                        WatchHapticPatterns.descending5s] {
            let gaps = intervals(pattern)
            #expect(zip(gaps, gaps.dropFirst()).allSatisfy { $1 >= $0 },
                    "\(pattern.name) thins out monotonically")
        }

        let ascending = intervals(WatchHapticPatterns.ascending5s)
        #expect(zip(ascending, ascending.dropFirst()).allSatisfy { $1 <= $0 },
                "ascend-5s tightens monotonically")

        let steady = intervals(WatchHapticPatterns.steady10s)
        #expect(steady.allSatisfy { abs($0 - steady[0]) < 1e-9 },
                "steady-10s holds one interval, isolating duration")
    }

    /// `ascend-5s` must be the exact time-reversal of `descend-5s`, or the
    /// pair varies direction AND length together and a preference between
    /// them proves nothing about either. This is the assertion that keeps
    /// the "one axis per candidate" claim in RFC 0006 D8 honest.
    @Test("ascend-5s is the exact time-reversal of descend-5s")
    func ascendMirrorsDescend() {
        let down = WatchHapticPatterns.descending5s
        let up = WatchHapticPatterns.ascending5s

        #expect(up.tapCount == down.tapCount)
        #expect(abs(up.durationS - down.durationS) < 1e-9,
                "same length, so only direction differs")

        func intervals(_ p: WatchHapticPattern) -> [Double] {
            zip(p.tapOffsetsS, p.tapOffsetsS.dropFirst()).map { $1 - $0 }
        }
        let downGaps = intervals(down)
        let upGaps = intervals(up)
        #expect(upGaps.count == downGaps.count)
        for (u, d) in zip(upGaps, downGaps.reversed()) {
            #expect(abs(u - d) < 1e-9,
                    "interval sequence is reversed, not merely similar")
        }
    }

    /// The candidates must genuinely differ, or the comparison the whole
    /// table exists for has nothing to compare.
    @Test("no two candidates render identically")
    func candidatesAreDistinct() {
        let all = WatchHapticPatterns.all
        for i in all.indices {
            for j in all.indices where j > i {
                #expect(all[i].tapOffsetsS != all[j].tapOffsetsS,
                        "\(all[i].name) and \(all[j].name) differ")
            }
        }
    }

    @Test("selection is total: out-of-range falls back, cycling wraps")
    func selectionIsTotal() {
        let count = WatchHapticPatterns.all.count
        #expect(WatchHapticPatterns.pattern(at: -1).name
                == WatchHapticPatterns.all[WatchHapticPatterns.defaultIndex].name)
        #expect(WatchHapticPatterns.pattern(at: count).name
                == WatchHapticPatterns.all[WatchHapticPatterns.defaultIndex].name)
        #expect(WatchHapticPatterns.nextIndex(after: count - 1) == 0)
        #expect(WatchHapticPatterns.nextIndex(after: 0) == 1)
        #expect(WatchHapticPatterns.nextIndex(after: 99)
                == WatchHapticPatterns.defaultIndex)
    }

    /// The baseline stays candidate 0: every comparison should be against
    /// the rendering that actually failed in the field (RFC 0004 D2).
    @Test("candidate 0 is the RFC 0004 triple-tap")
    func baselineIsFirst() {
        #expect(WatchHapticPatterns.all[0].tapOffsetsS == [0, 0.6, 1.2])
    }
}
