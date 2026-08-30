// Intent: Phone-side personal-route-memory store (RFC 0002 D1/D2/D7): the
//         per-segment record of review/marker history, its derivation into
//         the kernel's UNSAFE/SUPPRESS/NEUTRAL decision, and the fixed-size
//         eviction bound. The canonical store lives here, phone-side — the
//         kernel receives only the single resolved PersonalMemory record
//         RideEngine builds per step (RFC 0002 D5).
// Privacy: Counts and a bonus byte per segment, nothing else (NFR-005) —
//          no timestamps, no coordinates. Persisted to a caller-supplied
//          directory (the app passes Application Support), same convention
//          as SegmentStore.
// Pattern: markUnsafe/derivation logic is a pure, independently-testable
//          function of a record (D2); the store itself is the thin
//          saturating-counter + LRU-eviction wrapper around it (D1/D7).
import CueMapImport
import Foundation

/// Mirrors kernel PersonalMemoryState (CUE_MEMORY_*, kernel/cue_policy.h) —
/// a Swift-side convenience for building the resolved input, not a decision
/// type in its own right (RFC 0003 D3's "no Swift mirror" concern is about
/// kernel DECISIONS; this is caller-side input construction, the same as
/// building a RideSample from GPS fields).
public enum PersonalMemoryState: UInt8, Sendable {
    case neutral = 0
    case unsafe = 1
    case suppress = 2

    /// Precedence when more than one remembered segment is in play for the
    /// same step (RFC 0002 D5 "multi-segment resolution"): unsafe > suppress > neutral.
    var precedence: Int {
        switch self {
        case .unsafe: return 2
        case .suppress: return 1
        case .neutral: return 0
        }
    }
}

/// The step's resolved personal-route-memory input, ready to cross into the
/// kernel call (RideEngine converts this to the C PersonalMemory struct).
public struct ResolvedPersonalMemory: Equatable, Sendable {
    public let segmentID: UInt32
    public let state: PersonalMemoryState
    public let noticeBonusS: UInt8
}

/// One segment's aggregated history (RFC 0002 D1). Counters saturate at
/// their max rather than wrapping, matching the kernel's own saturate-
/// don't-wrap discipline for cooldowns.
public struct PersonalMemoryRecord: Codable, Equatable, Sendable {
    public var segmentID: UInt32
    public var useful: UInt16
    public var falseAlarm: UInt16
    public var tooLate: UInt16
    public var markerCount: UInt16
    public var noticeBonusS: UInt8
    /// Directions an IMPORTED custom zone asserts this segment is unsafe in
    /// (cue#30), as `ZoneDirectionMask`'s raw byte; empty means no zone
    /// asserts it. Held raw so the persisted record stays the flat table of
    /// integers RFC 0002 D1 describes — read it through `unsafeDirections`.
    /// One byte takes the packed record from 17 to 18 B, still rounding to
    /// D7's 20 B, so the 5 KiB budget stands.
    ///
    /// Deliberately describes ZONE evidence only, never the union of zones
    /// and in-ride taps. A tap is counted in `markerCount` and applies
    /// omnidirectionally on its own, so the two sources stay separable — and
    /// `undoUnsafeMarker` can reverse a tap without having to un-widen a mask
    /// it cannot attribute (see that method).
    public var unsafeDirMask: UInt8
    /// Monotonic global write counter (not wall-clock — RTC-free, portable
    /// to a future sensor-pod store) for least-recently-touched eviction.
    public var lruTouch: UInt32

    /// Typed view of `unsafeDirMask`.
    public var unsafeDirections: ZoneDirectionMask {
        get { ZoneDirectionMask(rawValue: unsafeDirMask) }
        set { unsafeDirMask = newValue.rawValue }
    }

    /// `unsafeDirMask` defaults to empty — "no imported zone asserts this
    /// segment", which is what every pre-cue#30 record means and what every
    /// existing construction site intends.
    public init(segmentID: UInt32, useful: UInt16, falseAlarm: UInt16, tooLate: UInt16,
                markerCount: UInt16, noticeBonusS: UInt8,
                unsafeDirMask: UInt8 = 0, lruTouch: UInt32) {
        self.segmentID = segmentID
        self.useful = useful
        self.falseAlarm = falseAlarm
        self.tooLate = tooLate
        self.markerCount = markerCount
        self.noticeBonusS = noticeBonusS
        self.unsafeDirMask = unsafeDirMask
        self.lruTouch = lruTouch
    }

    enum CodingKeys: String, CodingKey {
        case segmentID, useful, falseAlarm, tooLate, markerCount, noticeBonusS
        case unsafeDirMask, lruTouch
    }

    /// Hand-written for ONE reason: `unsafeDirMask` must decode as empty when
    /// the key is absent. A synthesized decoder requires every non-optional
    /// property to be present, so adding this field would make every
    /// personal-memory.json written before cue#30 fail to decode — and
    /// `PersonalMemoryStore.load` answers a decode failure with an EMPTY
    /// store, silently discarding a rider's entire accumulated history on
    /// first launch after the upgrade. The memberwise default above is
    /// invisible here; this is what actually protects the file.
    ///
    /// Empty is also the RIGHT default, not just a safe one: a pre-cue#30
    /// record's `markerCount` already covers whatever zone import or tap
    /// raised it, and that resolves omnidirectionally exactly as it did.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        segmentID = try container.decode(UInt32.self, forKey: .segmentID)
        useful = try container.decode(UInt16.self, forKey: .useful)
        falseAlarm = try container.decode(UInt16.self, forKey: .falseAlarm)
        tooLate = try container.decode(UInt16.self, forKey: .tooLate)
        markerCount = try container.decode(UInt16.self, forKey: .markerCount)
        noticeBonusS = try container.decode(UInt8.self, forKey: .noticeBonusS)
        unsafeDirMask = try container.decodeIfPresent(UInt8.self, forKey: .unsafeDirMask) ?? 0
        lruTouch = try container.decode(UInt32.self, forKey: .lruTouch)
    }
}

/// Phone-side per-segment memory store (RFC 0002 D1, D7). Reference type:
/// one instance is shared by RideSessionController across rides and
/// injected into each ride's RideEngine, so live cueing benefits from
/// history recorded on PAST rides, not just the current one.
public final class PersonalMemoryStore {
    /// 256 remembered segments, matching RFC 0002 D7's 5 KiB sizing note.
    public static let segmentsCap = 256
    /// A single stray false_alarm never suppresses (NFR-001 — conservative).
    static let falseAlarmMin: UInt16 = 2
    /// Beyond this, a segment is systematically mis-timed and should be
    /// escalated to a global CuePolicyConfig change, not widened forever.
    static let maxTooLateBonusS: UInt8 = 8

    private var recordsBySegment: [UInt32: PersonalMemoryRecord] = [:]
    private var writeCounter: UInt32 = 0
    private var _lastEvictedSegmentID: UInt32?
    /// Total evictions over the store's lifetime — a single before/after
    /// comparison of `lastEvictedSegmentID` around a BULK insert (e.g.
    /// importing many custom zones at once) only ever sees the LAST of
    /// possibly several evictions that batch triggered; comparing this
    /// count instead lets a caller detect "N evictions happened," not just
    /// "at least one did" (RFC 0002 D7 — a bound is not a silent truncation).
    private var _evictionCount: Int = 0
    /// Guards every property above. Today's real callers (RideSessionController
    /// is @MainActor) never actually race, but RideEngine/PersonalMemoryStore
    /// are plain, non-isolated types with no enforced calling convention —
    /// a lock makes the class correct regardless of caller context, cheaper
    /// than propagating @MainActor through RideEngine's whole public API
    /// (and the existing test suite, which calls it synchronously off-actor).
    private let lock = NSLock()

    /// Segment id evicted by the most recent write that overflowed the cap,
    /// or nil if none has happened yet — a bound is not a silent
    /// truncation (RFC 0002 D7); callers may surface this for visibility.
    /// For a BATCH of writes, prefer diffing `evictionCount` before/after —
    /// this only ever reflects the single most recent eviction.
    public var lastEvictedSegmentID: UInt32? {
        lock.lock(); defer { lock.unlock() }
        return _lastEvictedSegmentID
    }

    /// Total evictions over the store's lifetime (monotonically
    /// increasing). Diff two readings around a batch of writes to count
    /// how many evictions THAT batch caused.
    public var evictionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _evictionCount
    }

    public init() {}

    /// Restore a previously-saved store (see `save(to:)`).
    public init(records: [PersonalMemoryRecord]) {
        for record in records {
            recordsBySegment[record.segmentID] = record
            writeCounter = max(writeCounter, record.lruTouch)
        }
    }

    public var recordCount: Int {
        lock.lock(); defer { lock.unlock() }
        return recordsBySegment.count
    }

    /// D2 derivation: resolves a record to at most one of three states, in
    /// strict precedence — explicit markers dominate regardless of outcome
    /// history; else a segment with enough false_alarm evidence (and more
    /// false_alarm than useful) is suppressed; else neutral. A pure
    /// function of its input, independently testable without a store.
    ///
    /// The two unsafe sources are checked separately, because they assert
    /// different things (cue#30). An in-ride tap (`markerCount`) is about the
    /// PLACE and applies whichever way the rider is going. An imported zone
    /// (`unsafeDirections`) is about a direction THROUGH the place and
    /// applies only when the rider is travelling its way — a nil direction
    /// (unknown course at a standstill, or CoreLocation reporting none)
    /// cannot reject anything, matching SegmentMatcher's heading gate, which
    /// is why a caller with no direction to offer keeps its pre-cue#30
    /// behavior by omitting the argument.
    ///
    /// Note a zone that does NOT apply this direction falls THROUGH to the
    /// suppress rule rather than short-circuiting to neutral: with the zone
    /// silent, the segment's review history is the only evidence left, and it
    /// should govern. A rider who flags a road unsafe eastbound and
    /// separately grades westbound cues as false alarms gets both judgments
    /// honored, each in its own direction.
    public static func resolve(_ record: PersonalMemoryRecord,
                               travelling direction: TravelDirection? = nil)
        -> (state: PersonalMemoryState, noticeBonusS: UInt8) {
        if record.markerCount > 0 {
            return (.unsafe, record.noticeBonusS)
        }
        // No !isEmpty guard: applies(to:) already answers false for an empty
        // mask in both its branches, and a second guard saying the same thing
        // is one more place for the two to drift apart.
        if record.unsafeDirections.applies(to: direction) {
            return (.unsafe, record.noticeBonusS)
        }
        if record.falseAlarm >= falseAlarmMin && record.falseAlarm > record.useful {
            return (.suppress, record.noticeBonusS)
        }
        return (.neutral, record.noticeBonusS)
    }

    /// The resolved input for `segmentID`, or nil if nothing is remembered
    /// for it (equivalent to a NEUTRAL + 0 record — RideEngine treats both
    /// the same way). See `resolve` for what `travelling` gates.
    public func resolved(for segmentID: UInt32,
                         travelling direction: TravelDirection? = nil) -> ResolvedPersonalMemory? {
        lock.lock(); defer { lock.unlock() }
        guard segmentID != 0, let record = recordsBySegment[segmentID] else { return nil }
        let (state, bonus) = Self.resolve(record, travelling: direction)
        return ResolvedPersonalMemory(segmentID: segmentID, state: state, noticeBonusS: bonus)
    }

    /// Attribute one after-ride review outcome to a segment (RFC 0002 D1:
    /// the caller joins event_id -> the RouteEvent.segment_id observed for
    /// it in the ride). `.unrecognized` contributes no counter — it is a
    /// delivery/attention signal, not a policy-correctness one (D2 Context).
    /// `.tooEarly` also contributes none: its lever is the global
    /// max_notice_s ceiling (spec §13), and the record has no counter for
    /// it — extending D2's evidence model is an RFC decision, not implied
    /// by the vocabulary.
    public func recordReview(segmentID: UInt32, outcome: ReviewOutcome) {
        // Skip touch() entirely, not just the counter — a review that
        // contributes no evidence must not consume a slot in the
        // 256-segment cap for zero informational benefit.
        guard segmentID != 0, outcome != .unrecognized, outcome != .tooEarly
        else { return }
        lock.lock(); defer { lock.unlock() }
        var record = touch(segmentID)
        switch outcome {
        case .useful:
            record.useful = Self.saturatingIncrement(record.useful)
        case .falseAlarm:
            record.falseAlarm = Self.saturatingIncrement(record.falseAlarm)
        case .tooLate:
            record.tooLate = Self.saturatingIncrement(record.tooLate)
            // D4: +2 s per too_late review, capped — never silently widened
            // forever; beyond the cap the fix is a global config change.
            record.noticeBonusS = min(Self.maxTooLateBonusS, record.noticeBonusS + 2)
        case .tooEarly, .unrecognized:
            fatalError("unreachable — filtered by the guard above")
        }
        recordsBySegment[segmentID] = record
    }

    /// Reverse a previously-recorded review outcome's counter contribution
    /// — used when a rider re-grades the same event (and by the #135
    /// discard rollback), so the store reflects
    /// only the LATEST review per event (matching the trace's own one-
    /// review-per-cue contract) rather than one increment per tap. Does
    /// not touch lruTouch (undoing isn't fresh evidence) and, for
    /// too_late, reduces notice_bonus_s by the same +2 — imprecise if the
    /// bonus had already saturated at the cap from other too_late reviews
    /// on this segment, an accepted tradeoff since the bonus is a soft
    /// timing nudge (D4), not the keep/kill state undoReview exists to
    /// protect the precision of.
    public func undoReview(segmentID: UInt32, outcome: ReviewOutcome) {
        guard segmentID != 0, outcome != .unrecognized, outcome != .tooEarly
        else { return }
        lock.lock(); defer { lock.unlock() }
        guard var record = recordsBySegment[segmentID] else { return }
        switch outcome {
        case .useful:
            record.useful = Self.saturatingDecrement(record.useful)
        case .falseAlarm:
            record.falseAlarm = Self.saturatingDecrement(record.falseAlarm)
        case .tooLate:
            record.tooLate = Self.saturatingDecrement(record.tooLate)
            record.noticeBonusS = record.noticeBonusS >= 2 ? record.noticeBonusS - 2 : 0
        case .tooEarly, .unrecognized:
            fatalError("unreachable — filtered by the guard above")
        }
        storePruningIfEmpty(record, for: segmentID)
    }

    /// Record an in-ride "unsafe here" marker tap for a segment (FR-006).
    /// A tap carries no direction — the rider is asserting risk about the
    /// place, not about one way through it — so it applies whichever way the
    /// rider is travelling, and leaves `unsafeDirMask` alone. It does not
    /// need to widen the mask to do that: `resolve` checks `markerCount`
    /// first, before any direction is consulted.
    public func recordUnsafeMarker(segmentID: UInt32) {
        guard segmentID != 0 else { return }
        lock.lock(); defer { lock.unlock() }
        var record = touch(segmentID)
        record.markerCount = Self.saturatingIncrement(record.markerCount)
        recordsBySegment[segmentID] = record
    }

    /// Record an imported webmap.dev custom zone's "unsafe here" for a
    /// segment — the same epistemic category as a marker tap (the rider is
    /// asserting risk, just authored beforehand rather than mid-ride), which
    /// is why D2 still does not distinguish them, but with a direction the
    /// tap does not have.
    ///
    /// `directions` is ASSIGNED, not unioned. webmap.dev's own contract is
    /// that importing a file REPLACES the zone set, and the cue side must not
    /// drift from that: without assignment, flipping a zone's direction and
    /// re-importing would leave both directions flagged forever, since
    /// `markerCount` cannot be attributed back to the zone that raised it.
    /// The caller is expected to pass the union across every zone in the file
    /// that matched this segment (`CustomZoneMatchResult.directionsBySegment`),
    /// so two opposing zones in one file still assign `.both`.
    ///
    /// This does NOT touch `markerCount`: an imported zone is tracked wholly
    /// in the mask so that re-importing is idempotent, and so that undoing a
    /// tap can never disturb a zone's assertion (or vice versa).
    ///
    /// Prefer `replaceUnsafeZones` for an import — this writes ONE segment and
    /// cannot know about a zone the rider deleted.
    public func recordUnsafeZone(segmentID: UInt32, directions: ZoneDirectionMask) {
        guard segmentID != 0, !directions.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var record = touch(segmentID)
        record.unsafeDirections = directions
        recordsBySegment[segmentID] = record
    }

    /// Replace the whole imported-zone set with `directionsBySegment`, the
    /// union across every zone in one file.
    ///
    /// Import REPLACES in webmap.dev, and the cue side has to mean the same
    /// thing. Writing only the segments a new file covers would leave every
    /// segment the rider DELETED a zone from still flagged, with no way to
    /// take it back — the file is the whole statement, not a set of additions.
    /// Segments whose only evidence was the departed zone are pruned outright,
    /// exactly as an undo prunes; segments with taps or reviews keep those and
    /// lose only the zone.
    ///
    /// This is what the separate zone field (cue#30) buys that a shared
    /// `marker_count` could not: zone evidence can be cleared without
    /// touching anything the rider did during a ride.
    public func replaceUnsafeZones(directionsBySegment: [UInt32: ZoneDirectionMask]) {
        lock.lock(); defer { lock.unlock() }
        for (segmentID, record) in recordsBySegment where record.unsafeDirMask != 0 {
            guard directionsBySegment[segmentID] == nil else { continue }
            var cleared = record
            cleared.unsafeDirMask = 0
            storePruningIfEmpty(cleared, for: segmentID)
        }
        for (segmentID, directions) in directionsBySegment {
            guard segmentID != 0, !directions.isEmpty else { continue }
            var record = touch(segmentID)
            record.unsafeDirections = directions
            recordsBySegment[segmentID] = record
        }
    }

    /// Reverse one previously-recorded "unsafe here" contribution — the
    /// discard path (#135): a marker made during a ride the rider then
    /// throws away was part of the ride being discarded, so its evidence
    /// goes with it. Same undo discipline as undoReview: no lruTouch
    /// refresh (undoing isn't fresh evidence), saturating decrement.
    public func undoUnsafeMarker(segmentID: UInt32) {
        guard segmentID != 0 else { return }
        lock.lock(); defer { lock.unlock() }
        guard var record = recordsBySegment[segmentID] else { return }
        record.markerCount = Self.saturatingDecrement(record.markerCount)
        storePruningIfEmpty(record, for: segmentID)
    }

    /// Write back an undo result, removing the record entirely once every
    /// counter, the bonus, AND the zone mask are empty. The mask counts as
    /// evidence in its own right — a segment asserted only by an imported
    /// zone has `markerCount == 0`, and dropping it here would silently
    /// discard the import.
    ///
    /// Undo never rolls the mask back, and does not need to: taps and zones
    /// are tracked in separate fields, so undoing a tap cannot leave a zone's
    /// direction widened. That separation is what makes "a discarded ride
    /// leaves the store exactly as it found it" (#135) true even when the
    /// discarded ride tapped a segment an imported zone already covered.
    ///
    /// resolved(for:) documents a missing
    /// record as equivalent to NEUTRAL + 0, and a lingering zeroed record
    /// would still consume a slot in the 256-segment cap and inflate
    /// recordCount — a discarded ride must leave the store's counts
    /// exactly as it found them (#135). Internal helper: callers must
    /// already hold `lock`.
    private func storePruningIfEmpty(_ record: PersonalMemoryRecord, for segmentID: UInt32) {
        if record.useful == 0 && record.falseAlarm == 0 && record.tooLate == 0
            && record.markerCount == 0 && record.noticeBonusS == 0
            && record.unsafeDirMask == 0 {
            recordsBySegment.removeValue(forKey: segmentID)
        } else {
            recordsBySegment[segmentID] = record
        }
    }

    private static func saturatingIncrement(_ value: UInt16) -> UInt16 {
        let (result, overflow) = value.addingReportingOverflow(1)
        return overflow ? UInt16.max : result
    }

    private static func saturatingDecrement(_ value: UInt16) -> UInt16 {
        value > 0 ? value - 1 : 0
    }

    /// Existing record for `segmentID` with its LRU stamp refreshed, or a
    /// fresh zeroed one — evicting the least-recently-touched segment first
    /// if the store is at capacity. Internal helper: callers must already
    /// hold `lock` (NSLock is not reentrant — locking again here would
    /// deadlock).
    private func touch(_ segmentID: UInt32) -> PersonalMemoryRecord {
        writeCounter += 1
        if var existing = recordsBySegment[segmentID] {
            existing.lruTouch = writeCounter
            return existing
        }
        if recordsBySegment.count >= Self.segmentsCap {
            evictLeastRecentlyTouched()
        }
        return PersonalMemoryRecord(segmentID: segmentID, useful: 0, falseAlarm: 0,
                                    tooLate: 0, markerCount: 0, noticeBonusS: 0,
                                    lruTouch: writeCounter)
    }

    /// Internal helper: callers must already hold `lock`.
    private func evictLeastRecentlyTouched() {
        guard let oldest = recordsBySegment.values.min(by: { $0.lruTouch < $1.lruTouch }) else { return }
        recordsBySegment.removeValue(forKey: oldest.segmentID)
        _lastEvictedSegmentID = oldest.segmentID
        _evictionCount += 1
    }

    // MARK: - Persistence

    private static let fileName = "personal-memory.json"

    /// Load a previously-saved store, or an empty one if none exists yet or
    /// the file cannot be read (corrupt/unavailable storage starts the
    /// rider fresh rather than failing app launch).
    public static func load(from directory: URL) -> PersonalMemoryStore {
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([PersonalMemoryRecord].self, from: data)
        else { return PersonalMemoryStore() }
        return PersonalMemoryStore(records: records)
    }

    /// Persist every remembered segment, sorted by id for byte-stable
    /// output (same convention as SegmentStore).
    public func save(to directory: URL) throws {
        let sorted: [PersonalMemoryRecord]
        do {
            lock.lock(); defer { lock.unlock() }
            sorted = recordsBySegment.values.sorted { $0.segmentID < $1.segmentID }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(sorted)
            .write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }
}
