// Intent: Facade-level checks that the SPM-packaged kernel behaves exactly
//         like the standalone build (RFC 0003 D3). Kernel LOGIC coverage
//         lives in kernel/tests/test_cue_policy.c — these tests only pin
//         the packaging seams: spec §8 defaults survive the C interop,
//         gates fire through the facade, and decisions stay deterministic.
import XCTest
import CCuePolicy  // C constants (CUE_REASON_CODE_*, event family macros)
import CueKernel

final class CuePolicyFacadeTests: XCTestCase {
    /// Distances are read at 5 m/s, so metres/5 is the lead time in seconds:
    /// 100 m -> 20 s, the max_notice ceiling (spec §8 set 15; widened to 20
    /// by the §13 tuning loop, see CUE_POLICY_DEFAULT_MAX_NOTICE_S) and so
    /// the earliest sample that cues under the default config.
    private func squeezeEvent(distanceM: Int16, eventID: UInt32 = 101) -> RouteEvent {
        RouteEvent(
            event_id: eventID,
            family: UInt8(CUE_EVENT_FAMILY_COMPOSITE_SQUEEZE_ZONE),
            segment_id: 7,
            severity: 200,
            confidence: 190,
            reasons_bitmask: 0b111,
            distance_to_start_m: distanceM,
            distance_to_end_m: distanceM + 200
        )
    }

    private func sample(tMs: UInt32, speedCmps: UInt16 = 500) -> RideSample {
        RideSample(t_ms: tMs, lat_e7: 0, lon_e7: 0, speed_cmps: speedCmps,
                   heading_deg_x10: 0, segment_id: 7)
    }

    func testDefaultConfigMatchesSpecSection8() {
        let config = CuePolicy.defaultConfig()
        XCTAssertEqual(config.severity_threshold, 128)
        XCTAssertEqual(config.confidence_threshold, 128)
        XCTAssertEqual(config.min_notice_s, 5)
        XCTAssertEqual(config.max_notice_s, 20)
        XCTAssertEqual(config.min_cooldown_s, 15)
        XCTAssertEqual(config.min_cooldown_m, 75)
        XCTAssertEqual(config.min_speed_kmh, 1)
    }

    func testCuesAtMaxNoticeBoundaryWithDefaults() {
        let policy = CuePolicy()
        let decision = policy.step(sample(tMs: 0), events: [squeezeEvent(distanceM: 100)])
        XCTAssertTrue(decision.isHeadUp)
        XCTAssertEqual(decision.event_id, 101)
        XCTAssertEqual(decision.lead_time_s, 20)
        XCTAssertEqual(decision.reason_code, UInt8(CUE_REASON_CODE_CUED))
    }

    func testOneCuePerEvent() {
        let policy = CuePolicy()
        XCTAssertTrue(policy.step(sample(tMs: 0),
                                  events: [squeezeEvent(distanceM: 75)]).isHeadUp)
        let second = policy.step(sample(tMs: 1000),
                                 events: [squeezeEvent(distanceM: 70)])
        XCTAssertFalse(second.isHeadUp)
        XCTAssertEqual(second.reason_code, UInt8(CUE_REASON_CODE_ALREADY_CUED))
    }

    func testTooEarlySuppression() {
        let policy = CuePolicy()
        // 125 m at 5 m/s -> 25 s > max_notice 20 s.
        let decision = policy.step(sample(tMs: 0), events: [squeezeEvent(distanceM: 125)])
        XCTAssertFalse(decision.isHeadUp)
        XCTAssertEqual(decision.reason_code, UInt8(CUE_REASON_CODE_TOO_EARLY))
    }

    func testNoEventsIdles() {
        let decision = CuePolicy().step(sample(tMs: 0))
        XCTAssertFalse(decision.isHeadUp)
        XCTAssertEqual(decision.reason_code, UInt8(CUE_REASON_CODE_NO_EVENT))
    }

    func testDeterministicAcrossInstances() {
        // Same sample/event sequence through two fresh instances must yield
        // byte-identical decisions (NFR-003 — the property D6 gates E2E).
        let sequence: [(UInt32, Int16)] = [
            (0, 120), (1000, 115), (2000, 90), (3000, 75), (4000, 70),
            (5000, 40), (6000, 10), (7000, -5), (8000, -50),
        ]
        func run() -> [(UInt8, UInt32, UInt8, Int16)] {
            let policy = CuePolicy()
            return sequence.map { tMs, distance in
                let d = policy.step(sample(tMs: tMs),
                                    events: [squeezeEvent(distanceM: distance)])
                return (d.type, d.event_id, d.reason_code, d.lead_time_s)
            }
        }
        XCTAssertTrue(run().elementsEqual(run(), by: ==))
    }

    func testSyntheticHeadUpIsAFullyFormedHeadUpDecision() {
        // The debug test-cue path (#131) treats this value exactly like a
        // kernel decision — isHeadUp gates both the chime and the watch
        // dispatch, and lead_time_s becomes the payload's expiry window.
        let decision = CueDecision.syntheticHeadUp(eventID: 0xFFFF_0001,
                                                   leadTimeS: 15)
        XCTAssertTrue(decision.isHeadUp)
        XCTAssertEqual(decision.event_id, 0xFFFF_0001)
        XCTAssertEqual(decision.reason_code, UInt8(CUE_REASON_CODE_CUED))
        XCTAssertEqual(decision.lead_time_s, 15)
    }
}
