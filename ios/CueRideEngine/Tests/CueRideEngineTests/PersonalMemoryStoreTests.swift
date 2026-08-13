// Intent: RFC 0002 D1/D2/D7 tests for the phone-side personal-memory store —
//         the derivation precedence (markers dominate), saturating counters,
//         the too_late notice-bonus cap, LRU eviction at the 256-segment
//         cap, and a save/load round trip.
import XCTest
@testable import CueRideEngine

final class PersonalMemoryStoreTests: XCTestCase {
    // MARK: - D2 derivation (pure function, no store instance needed)

    func testNeutralWhenNoHistory() {
        let record = PersonalMemoryRecord(segmentID: 1, useful: 0, falseAlarm: 0,
                                          tooLate: 0, markerCount: 0, noticeBonusS: 0, lruTouch: 0)
        XCTAssertEqual(PersonalMemoryStore.resolve(record).state, .neutral)
    }

    func testMarkerDominatesRegardlessOfOutcomeHistory() {
        // Heavy false_alarm evidence would otherwise suppress — an explicit
        // marker overrides it entirely (D2 rule 1: markers dominate).
        let record = PersonalMemoryRecord(segmentID: 1, useful: 0, falseAlarm: 10,
                                          tooLate: 0, markerCount: 1, noticeBonusS: 0, lruTouch: 0)
        XCTAssertEqual(PersonalMemoryStore.resolve(record).state, .unsafe)
    }

    func testSingleStrayFalseAlarmNeverSuppresses() {
        // FALSE_ALARM_MIN = 2 — one false_alarm alone is conservative
        // (NFR-001): keep cueing rather than silence on thin evidence.
        let record = PersonalMemoryRecord(segmentID: 1, useful: 0, falseAlarm: 1,
                                          tooLate: 0, markerCount: 0, noticeBonusS: 0, lruTouch: 0)
        XCTAssertEqual(PersonalMemoryStore.resolve(record).state, .neutral)
    }

    func testSuppressesWhenFalseAlarmMeetsMinimumAndExceedsUseful() {
        let record = PersonalMemoryRecord(segmentID: 1, useful: 1, falseAlarm: 2,
                                          tooLate: 0, markerCount: 0, noticeBonusS: 0, lruTouch: 0)
        XCTAssertEqual(PersonalMemoryStore.resolve(record).state, .suppress)
    }

    func testDoesNotSuppressWhenUsefulMeetsOrExceedsFalseAlarm() {
        let record = PersonalMemoryRecord(segmentID: 1, useful: 2, falseAlarm: 2,
                                          tooLate: 0, markerCount: 0, noticeBonusS: 0, lruTouch: 0)
        XCTAssertEqual(PersonalMemoryStore.resolve(record).state, .neutral)
    }

    func testTooLateAloneNeitherSuppressesNorMarksUnsafe() {
        // too_late feeds the D4 tuning rule, not the D2 keep/kill state.
        let record = PersonalMemoryRecord(segmentID: 1, useful: 0, falseAlarm: 0,
                                          tooLate: 5, markerCount: 0, noticeBonusS: 8, lruTouch: 0)
        XCTAssertEqual(PersonalMemoryStore.resolve(record).state, .neutral)
        XCTAssertEqual(PersonalMemoryStore.resolve(record).noticeBonusS, 8)
    }

    // MARK: - Store mutation: saturating counters, D4 bonus cap

    func testRecordReviewIncrementsTheMatchingCounter() {
        let store = PersonalMemoryStore()
        store.recordReview(segmentID: 7, outcome: .useful)
        store.recordReview(segmentID: 7, outcome: .useful)
        store.recordReview(segmentID: 7, outcome: .falseAlarm)
        let resolved = store.resolved(for: 7)
        // useful (2) >= falseAlarm (1): does not suppress.
        XCTAssertEqual(resolved?.state, .neutral)
    }

    func testUnrecognizedContributesNoCounter() {
        let store = PersonalMemoryStore()
        store.recordReview(segmentID: 7, outcome: .unrecognized)
        // No record at all should have been created — nothing to resolve.
        XCTAssertNil(store.resolved(for: 7))
    }

    func testTooEarlyContributesNoCounter() {
        // Same no-evidence contract as unrecognized (#143): too_early's
        // lever is the global max_notice_s ceiling, not per-segment
        // memory. Guards the recordReview/undoReview filter that keeps
        // the fatalError arm unreachable.
        let store = PersonalMemoryStore()
        store.recordReview(segmentID: 7, outcome: .tooEarly)
        XCTAssertNil(store.resolved(for: 7))
        store.undoReview(segmentID: 7, outcome: .tooEarly)
        XCTAssertNil(store.resolved(for: 7))
    }

    func testUndoReviewReversesTheMatchingCounter() {
        let store = PersonalMemoryStore()
        store.recordReview(segmentID: 7, outcome: .falseAlarm)
        store.recordReview(segmentID: 7, outcome: .falseAlarm)
        // 2 false_alarm, 0 useful: suppresses.
        XCTAssertEqual(store.resolved(for: 7)?.state, .suppress)
        store.undoReview(segmentID: 7, outcome: .falseAlarm)
        // Back to 1 false_alarm: no longer meets FALSE_ALARM_MIN.
        XCTAssertEqual(store.resolved(for: 7)?.state, .neutral)
    }

    func testUndoReviewReducesTooLateBonusBySameAmountItAdded() {
        let store = PersonalMemoryStore()
        store.recordReview(segmentID: 7, outcome: .tooLate)
        XCTAssertEqual(store.resolved(for: 7)?.noticeBonusS, 2)
        store.undoReview(segmentID: 7, outcome: .tooLate)
        // The undo zeroed every counter AND the bonus, so the record is
        // pruned outright (#135) — nil resolves as NEUTRAL + 0, and the
        // segment no longer consumes a cap slot.
        XCTAssertNil(store.resolved(for: 7))
        XCTAssertEqual(store.recordCount, 0)
    }

    func testUndoReviewPrunesARecordLeftWithNoEvidence() {
        // Discard rollback (#135): a review that was the record's ONLY
        // evidence must leave the store's counts exactly as it found them.
        let store = PersonalMemoryStore()
        store.recordReview(segmentID: 7, outcome: .useful)
        XCTAssertEqual(store.recordCount, 1)
        store.undoReview(segmentID: 7, outcome: .useful)
        XCTAssertEqual(store.recordCount, 0)
        XCTAssertNil(store.resolved(for: 7))
    }

    // MARK: - Marker undo (#135 discard rollback)

    func testUndoUnsafeMarkerReversesOneMarkerContribution() {
        let store = PersonalMemoryStore()
        store.recordUnsafeMarker(segmentID: 7)
        store.recordUnsafeMarker(segmentID: 7)
        store.undoUnsafeMarker(segmentID: 7)
        // One marker remains — still unsafe (markers dominate, D2).
        XCTAssertEqual(store.resolved(for: 7)?.state, .unsafe)
        store.undoUnsafeMarker(segmentID: 7)
        // Last marker undone and no other evidence: record pruned.
        XCTAssertNil(store.resolved(for: 7))
        XCTAssertEqual(store.recordCount, 0)
    }

    func testUndoUnsafeMarkerOnAnUnknownSegmentIsANoOp() {
        let store = PersonalMemoryStore()
        store.undoUnsafeMarker(segmentID: 7)
        XCTAssertNil(store.resolved(for: 7))
        XCTAssertEqual(store.recordCount, 0)
    }

    func testUndoUnsafeMarkerKeepsARecordWithOtherEvidence() {
        // Undo removes THIS ride's marker, never past history: a segment
        // with review evidence from earlier rides must survive the prune.
        let store = PersonalMemoryStore()
        store.recordReview(segmentID: 7, outcome: .useful)
        store.recordUnsafeMarker(segmentID: 7)
        store.undoUnsafeMarker(segmentID: 7)
        XCTAssertEqual(store.recordCount, 1)
        // Marker gone, useful review still counted: back to neutral.
        XCTAssertEqual(store.resolved(for: 7)?.state, .neutral)
    }

    func testUndoReviewOnAnUnknownSegmentIsANoOp() {
        let store = PersonalMemoryStore()
        store.undoReview(segmentID: 7, outcome: .falseAlarm)
        XCTAssertNil(store.resolved(for: 7))
    }

    func testTooLateBonusSaturatesAtCap() {
        let store = PersonalMemoryStore()
        for _ in 0..<10 { store.recordReview(segmentID: 7, outcome: .tooLate) }
        // +2 per review would reach 20 uncapped; D4 caps at 8.
        XCTAssertEqual(store.resolved(for: 7)?.noticeBonusS, 8)
    }

    func testSegmentZeroIsNeverRecorded() {
        // 0 is reserved ("no record", RFC 0002 D5) — must never be a real
        // segment's key, matching the kernel-side guard.
        let store = PersonalMemoryStore()
        store.recordReview(segmentID: 0, outcome: .falseAlarm)
        store.recordReview(segmentID: 0, outcome: .falseAlarm)
        store.recordUnsafeMarker(segmentID: 0)
        XCTAssertEqual(store.recordCount, 0)
        XCTAssertNil(store.resolved(for: 0))
    }

    func testMarkerAndCustomZoneImportShareOneCounter() {
        // A custom zone import and an in-ride marker tap both land on
        // markerCount — same epistemic category (RFC 0002, custom-zone
        // mapping decision).
        let store = PersonalMemoryStore()
        store.recordUnsafeMarker(segmentID: 7)
        XCTAssertEqual(store.resolved(for: 7)?.state, .unsafe)
    }

    // MARK: - LRU eviction at the 256-segment cap (RFC 0002 D7)

    func testEvictsLeastRecentlyTouchedSegmentWhenFull() {
        let store = PersonalMemoryStore()
        for segmentID in 1...UInt32(PersonalMemoryStore.segmentsCap) {
            store.recordUnsafeMarker(segmentID: segmentID)
        }
        XCTAssertEqual(store.recordCount, PersonalMemoryStore.segmentsCap)
        XCTAssertNotNil(store.resolved(for: 1))

        // One more segment forces an eviction — segment 1 (never touched
        // again) is the least-recently-touched.
        store.recordUnsafeMarker(segmentID: UInt32(PersonalMemoryStore.segmentsCap) + 1)
        XCTAssertEqual(store.recordCount, PersonalMemoryStore.segmentsCap)
        XCTAssertNil(store.resolved(for: 1), "segment 1 should have been evicted")
        XCTAssertEqual(store.lastEvictedSegmentID, 1)
        // A full store dropping a segment reverts it to neutral, never a
        // spurious cue (NFR-001) — resolved(for:) returning nil IS neutral
        // from RideEngine's perspective.
    }

    func testEvictionCountAccumulatesAcrossABatchOfWrites() {
        // lastEvictedSegmentID only ever shows the LAST eviction; a caller
        // diffing evictionCount before/after a batch can tell how MANY
        // evictions that batch caused (RFC 0002 D7 — no silent truncation).
        let store = PersonalMemoryStore()
        for segmentID in 1...UInt32(PersonalMemoryStore.segmentsCap) {
            store.recordUnsafeMarker(segmentID: segmentID)
        }
        XCTAssertEqual(store.evictionCount, 0)

        let before = store.evictionCount
        for segmentID in UInt32(PersonalMemoryStore.segmentsCap + 1)...UInt32(PersonalMemoryStore.segmentsCap + 3) {
            store.recordUnsafeMarker(segmentID: segmentID)
        }
        XCTAssertEqual(store.evictionCount - before, 3, "three new segments into a full store must evict three")
    }

    func testTouchingAnExistingSegmentProtectsItFromEviction() {
        let store = PersonalMemoryStore()
        for segmentID in 1...UInt32(PersonalMemoryStore.segmentsCap) {
            store.recordUnsafeMarker(segmentID: segmentID)
        }
        // Re-touch segment 1 so it's no longer the least-recently-touched.
        store.recordUnsafeMarker(segmentID: 1)
        store.recordUnsafeMarker(segmentID: UInt32(PersonalMemoryStore.segmentsCap) + 1)
        XCTAssertNotNil(store.resolved(for: 1), "recently-touched segment 1 must survive eviction")
        XCTAssertEqual(store.lastEvictedSegmentID, 2, "segment 2 is now the least-recently-touched")
    }

    // MARK: - Persistence round trip

    func testSaveAndLoadRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("personal-memory-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = PersonalMemoryStore()
        store.recordUnsafeMarker(segmentID: 7)
        store.recordReview(segmentID: 8, outcome: .tooLate)
        try store.save(to: directory)

        let loaded = PersonalMemoryStore.load(from: directory)
        XCTAssertEqual(loaded.recordCount, 2)
        XCTAssertEqual(loaded.resolved(for: 7)?.state, .unsafe)
        XCTAssertEqual(loaded.resolved(for: 8)?.noticeBonusS, 2)
    }

    func testLoadFromEmptyDirectoryStartsFresh() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("personal-memory-test-missing-\(UUID().uuidString)")
        let loaded = PersonalMemoryStore.load(from: directory)
        XCTAssertEqual(loaded.recordCount, 0)
    }
}
