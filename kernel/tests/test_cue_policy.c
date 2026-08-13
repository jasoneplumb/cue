/*
 * Intent: Dependency-free unit tests for the cue-policy kernel — every gate
 *         in spec §8, plus the determinism contract (NFR-003).
 * Context: Run via `make -C kernel test`; wired into CI.
 * Pattern: CHECK macro accumulates failures; process exit code is the result.
 * Future: Replace hand-built scenarios with recorded replay traces once the
 *         replay harness lands (FR-010).
 */
#include <stdio.h>

#include "cue_policy.h"

static int failures = 0;

#define CHECK(cond)                                                  \
  do {                                                               \
    if (!(cond)) {                                                   \
      printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);         \
      failures++;                                                    \
    }                                                                \
  } while (0)

/* 5 m/s (18 km/h) — comfortably above the 4 km/h floor. */
#define CRUISE_CMPS 500

static RideSample sample_at(uint32_t t_ms, uint16_t speed_cmps) {
  RideSample s;
  s.t_ms = t_ms;
  s.lat_e7 = 477000000;
  s.lon_e7 = -1223000000;
  s.speed_cmps = speed_cmps;
  s.heading_deg_x10 = 900;
  s.segment_id = 42;
  return s;
}

static RouteEvent squeeze_event(uint32_t event_id, int16_t distance_to_start_m) {
  RouteEvent e;
  e.event_id = event_id;
  e.family = CUE_EVENT_FAMILY_COMPOSITE_SQUEEZE_ZONE;
  e.segment_id = 42;
  e.severity = 200;
  e.confidence = 200;
  e.reasons_bitmask = CUE_REASON_NARROW_LANE | CUE_REASON_NO_SHOULDER_OR_BIKE_LANE;
  e.distance_to_start_m = distance_to_start_m;
  e.distance_to_end_m = (int16_t)(distance_to_start_m + 120);
  return e;
}

static void test_default_config(void) {
  CuePolicyConfig cfg;
  cue_policy_default_config(&cfg);
  CHECK(cfg.min_notice_s == 5);
  CHECK(cfg.max_notice_s == 20);
  CHECK(cfg.min_cooldown_s == 15);
  CHECK(cfg.min_cooldown_m == 75);
  CHECK(cfg.min_speed_kmh == 1);
}

static void test_cues_inside_notice_window(void) {
  CuePolicyState st;
  cue_policy_init(&st, 0);
  RideSample s = sample_at(1000, CRUISE_CMPS);
  RouteEvent e = squeeze_event(7, 50); /* 50 m at 5 m/s = 10 s out */
  CueDecision d = cue_policy_step(&st, &s, &e, 1, 0);
  CHECK(d.type == CUE_HEAD_UP);
  CHECK(d.event_id == 7);
  CHECK(d.reason_code == CUE_REASON_CODE_CUED);
  CHECK(d.lead_time_s == 10);
}

static void test_no_events(void) {
  CuePolicyState st;
  cue_policy_init(&st, 0);
  RideSample s = sample_at(1000, CRUISE_CMPS);
  CueDecision d = cue_policy_step(&st, &s, 0, 0, 0);
  CHECK(d.type == CUE_NONE);
  CHECK(d.reason_code == CUE_REASON_CODE_NO_EVENT);
}

static void test_too_early_and_too_late(void) {
  CuePolicyState st;
  cue_policy_init(&st, 0);
  RideSample s = sample_at(1000, CRUISE_CMPS);

  RouteEvent far = squeeze_event(1, 200); /* 40 s out */
  CueDecision d = cue_policy_step(&st, &s, &far, 1, 0);
  CHECK(d.type == CUE_NONE);
  CHECK(d.reason_code == CUE_REASON_CODE_TOO_EARLY);
  CHECK(d.lead_time_s == 40);

  RouteEvent near = squeeze_event(2, 10); /* 2 s out */
  d = cue_policy_step(&st, &s, &near, 1, 0);
  CHECK(d.type == CUE_NONE);
  CHECK(d.reason_code == CUE_REASON_CODE_TOO_LATE);
}

static void test_inside_event_suppressed(void) {
  CuePolicyState st;
  cue_policy_init(&st, 0);
  RideSample s = sample_at(1000, CRUISE_CMPS);
  RouteEvent e = squeeze_event(3, -5);
  CueDecision d = cue_policy_step(&st, &s, &e, 1, 0);
  CHECK(d.type == CUE_NONE);
  CHECK(d.reason_code == CUE_REASON_CODE_INSIDE_EVENT);
}

static void test_severity_confidence_gates(void) {
  CuePolicyState st;
  cue_policy_init(&st, 0);
  RideSample s = sample_at(1000, CRUISE_CMPS);

  RouteEvent weak = squeeze_event(4, 50);
  weak.severity = 10;
  CueDecision d = cue_policy_step(&st, &s, &weak, 1, 0);
  CHECK(d.reason_code == CUE_REASON_CODE_SEVERITY);

  RouteEvent unsure = squeeze_event(5, 50);
  unsure.confidence = 10;
  d = cue_policy_step(&st, &s, &unsure, 1, 0);
  CHECK(d.reason_code == CUE_REASON_CODE_CONFIDENCE);
}

static void test_speed_floor(void) {
  /* Pinned to an explicit 4 km/h threshold, not the shipped default
   * (CUE_POLICY_DEFAULT_MIN_SPEED_KMH) — this test is about the gate's
   * boundary arithmetic, so it must not need touching every time the
   * default is retuned via the spec §13 loop. */
  CuePolicyConfig cfg;
  cue_policy_default_config(&cfg);
  cfg.min_speed_kmh = 4;
  CuePolicyState st;
  cue_policy_init(&st, &cfg);
  RideSample crawling = sample_at(1000, 50); /* 1.8 km/h */
  RouteEvent e = squeeze_event(6, 50);
  CueDecision d = cue_policy_step(&st, &crawling, &e, 1, 0);
  CHECK(d.type == CUE_NONE);
  CHECK(d.reason_code == CUE_REASON_CODE_TOO_SLOW);

  /* Boundary: 4 km/h = 111.1 cm/s; 111 must fail, 112 must pass the gate. */
  RideSample at_111 = sample_at(2000, 111);
  RouteEvent far = squeeze_event(6, 50); /* at 1.11 m/s, 50 m = 45 s: TOO_EARLY */
  d = cue_policy_step(&st, &at_111, &far, 1, 0);
  CHECK(d.reason_code == CUE_REASON_CODE_TOO_SLOW);
  RideSample at_112 = sample_at(3000, 112);
  d = cue_policy_step(&st, &at_112, &far, 1, 0);
  CHECK(d.reason_code == CUE_REASON_CODE_TOO_EARLY);
}

static void test_one_cue_per_event(void) {
  /* FR-004: at most one HEAD_UP per route event. */
  CuePolicyState st;
  cue_policy_init(&st, 0);
  RideSample s1 = sample_at(1000, CRUISE_CMPS);
  RouteEvent e = squeeze_event(8, 50);
  CueDecision d = cue_policy_step(&st, &s1, &e, 1, 0);
  CHECK(d.type == CUE_HEAD_UP);

  /* Still approaching the same event well past every cooldown. */
  RideSample s2 = sample_at(1000 + 20000, CRUISE_CMPS); /* +20 s, +100 m */
  e.distance_to_start_m = 40;
  d = cue_policy_step(&st, &s2, &e, 1, 0);
  CHECK(d.type == CUE_NONE);
  CHECK(d.reason_code == CUE_REASON_CODE_ALREADY_CUED);
}

static void test_cooldowns(void) {
  CuePolicyState st;
  cue_policy_init(&st, 0);
  RideSample s1 = sample_at(1000, CRUISE_CMPS);
  RouteEvent first = squeeze_event(9, 50);
  CueDecision d = cue_policy_step(&st, &s1, &first, 1, 0);
  CHECK(d.type == CUE_HEAD_UP);

  /* A different qualifying event 5 s later: time cooldown suppresses. */
  RideSample s2 = sample_at(1000 + 5000, CRUISE_CMPS);
  RouteEvent second = squeeze_event(10, 50);
  d = cue_policy_step(&st, &s2, &second, 1, 0);
  CHECK(d.type == CUE_NONE);
  CHECK(d.reason_code == CUE_REASON_CODE_COOLDOWN_TIME);

  /* 16 s later but only ~18 m travelled: distance cooldown suppresses. */
  CuePolicyState st2;
  cue_policy_init(&st2, 0);
  RideSample a = sample_at(1000, CRUISE_CMPS);
  d = cue_policy_step(&st2, &a, &first, 1, 0);
  CHECK(d.type == CUE_HEAD_UP);
  RideSample slow = sample_at(1000 + 16000, 112); /* 1.12 m/s * 16 s = 17.9 m < 75 m */
  RouteEvent third = squeeze_event(11, 8); /* 8 m at 1.12 m/s ≈ 7 s: in window */
  d = cue_policy_step(&st2, &slow, &third, 1, 0);
  CHECK(d.type == CUE_NONE);
  CHECK(d.reason_code == CUE_REASON_CODE_COOLDOWN_DISTANCE);

  /* Both cooldowns satisfied: 20 s and 100 m later, a new event cues. */
  RideSample s3 = sample_at(1000 + 21000, CRUISE_CMPS);
  RouteEvent fourth = squeeze_event(12, 50);
  d = cue_policy_step(&st, &s3, &fourth, 1, 0);
  CHECK(d.type == CUE_HEAD_UP);
  CHECK(d.event_id == 12);
}

static void test_deterministic_replay(void) {
  /* NFR-003: identical trace + config => identical decisions. */
  CueDecision run[2][6];
  for (int r = 0; r < 2; r++) {
    CuePolicyState st;
    cue_policy_init(&st, 0);
    for (int i = 0; i < 6; i++) {
      RideSample s = sample_at(1000u + (uint32_t)i * 4000u, CRUISE_CMPS);
      RouteEvent e = squeeze_event((uint32_t)(100 + i / 3),
                                   (int16_t)(90 - i * 20));
      run[r][i] = cue_policy_step(&st, &s, &e, 1, 0);
    }
  }
  for (int i = 0; i < 6; i++) {
    CHECK(run[0][i].type == run[1][i].type);
    CHECK(run[0][i].event_id == run[1][i].event_id);
    CHECK(run[0][i].reason_code == run[1][i].reason_code);
    CHECK(run[0][i].lead_time_s == run[1][i].lead_time_s);
  }
}

static void test_zero_min_speed_clamped(void) {
  /* A zero-valued min_speed_kmh must not open a divide-by-zero path in the
   * time-to-event computation; init clamps it to 1. */
  CuePolicyConfig cfg;
  cue_policy_default_config(&cfg);
  cfg.min_speed_kmh = 0;
  CuePolicyState st;
  cue_policy_init(&st, &cfg);
  RideSample stopped = sample_at(1000, 0);
  RouteEvent e = squeeze_event(20, 50);
  CueDecision d = cue_policy_step(&st, &stopped, &e, 1, 0);
  CHECK(d.type == CUE_NONE);
  CHECK(d.reason_code == CUE_REASON_CODE_TOO_SLOW);
}

static void test_inverted_notice_window_clamped(void) {
  /* min_notice_s > max_notice_s would make TOO_LATE fire for every event,
   * silently suppressing all cues; init clamps min down to max (#8). */
  CuePolicyConfig cfg;
  cue_policy_default_config(&cfg);
  cfg.min_notice_s = 20;
  cfg.max_notice_s = 10;
  CuePolicyState st;
  cue_policy_init(&st, &cfg);
  CHECK(st.config.min_notice_s == 10);
  CHECK(st.config.max_notice_s == 10);
  /* The resolved [10, 10] window still admits a cue exactly 10 s out. */
  RideSample s = sample_at(1000, CRUISE_CMPS);
  RouteEvent e = squeeze_event(40, 50); /* 50 m at 5 m/s = 10 s out */
  CueDecision d = cue_policy_step(&st, &s, &e, 1, 0);
  CHECK(d.type == CUE_HEAD_UP);
  CHECK(d.reason_code == CUE_REASON_CODE_CUED);
  CHECK(d.lead_time_s == 10);

  /* An inverted window whose min also exceeds INT16_MAX resolves against the
   * already-clamped max, keeping the window self-consistent. */
  cue_policy_default_config(&cfg);
  cfg.min_notice_s = UINT16_MAX;
  cfg.max_notice_s = UINT16_MAX;
  cue_policy_init(&st, &cfg);
  CHECK(st.config.max_notice_s == (uint16_t)INT16_MAX);
  CHECK(st.config.min_notice_s == (uint16_t)INT16_MAX);
}

static void test_timestamp_regression_stays_conservative(void) {
  /* NFR-001: a sample timestamped before the last cue must not expire the
   * time cooldown via unsigned wrap. */
  CuePolicyState st;
  cue_policy_init(&st, 0);
  RideSample s1 = sample_at(100000, CRUISE_CMPS);
  RouteEvent e1 = squeeze_event(30, 50);
  CueDecision d = cue_policy_step(&st, &s1, &e1, 1, 0);
  CHECK(d.type == CUE_HEAD_UP);
  RideSample back = sample_at(50000, CRUISE_CMPS); /* corrupt: 50 s earlier */
  RouteEvent e2 = squeeze_event(31, 50);
  d = cue_policy_step(&st, &back, &e2, 1, 0);
  CHECK(d.type == CUE_NONE);
  CHECK(d.reason_code == CUE_REASON_CODE_COOLDOWN_TIME);
  /* The regressed sample must not credit phantom travel toward the
   * distance cooldown either (white-box check on the accumulator). */
  CHECK(st.distance_since_last_cue_cm == 0);
}

static void test_ring_eviction_known_limitation(void) {
  /* Documents the FR-004 bound: the cued-event ring holds the most recent
   * CUE_POLICY_CUED_EVENTS_CAP ids; an evicted event may cue a second time.
   * Cooldowns zeroed so every event cues immediately. */
  CuePolicyConfig cfg;
  cue_policy_default_config(&cfg);
  cfg.min_cooldown_s = 0;
  cfg.min_cooldown_m = 0;
  CuePolicyState st;
  cue_policy_init(&st, &cfg);
  uint32_t t = 1000;
  for (uint32_t id = 1; id <= CUE_POLICY_CUED_EVENTS_CAP + 1u; id++) {
    RideSample s = sample_at(t, CRUISE_CMPS);
    RouteEvent e = squeeze_event(id, 50);
    CueDecision d = cue_policy_step(&st, &s, &e, 1, 0);
    CHECK(d.type == CUE_HEAD_UP);
    t += 1000;
  }
  /* Event 1 was evicted by event CAP+1 and is allowed to cue again. */
  RideSample s = sample_at(t, CRUISE_CMPS);
  RouteEvent e = squeeze_event(1, 50);
  CueDecision d = cue_policy_step(&st, &s, &e, 1, 0);
  CHECK(d.type == CUE_HEAD_UP);
}

static void test_near_pass_refunds_budget(void) {
  /* Issue #28: a near-pass that cues but never enters must not burn the
   * FR-004 budget owed to the genuine approach minutes later. */
  CuePolicyState st;
  cue_policy_init(&st, 0);

  /* Near-pass cue: 50 m out (10 s at 5 m/s), everything gates through. */
  RideSample s1 = sample_at(1000, CRUISE_CMPS);
  RouteEvent e = squeeze_event(50, 50);
  CueDecision d = cue_policy_step(&st, &s1, &e, 1, 0);
  CHECK(d.type == CUE_HEAD_UP);
  CHECK(d.event_id == 50);

  /* Rider retreats without entering: distance climbs the refund threshold
   * above the closest approach, freeing the budget slot. */
  RideSample s2 = sample_at(2000, CRUISE_CMPS);
  e.distance_to_start_m = (int16_t)(50 + CUE_POLICY_RETREAT_REFUND_M);
  d = cue_policy_step(&st, &s2, &e, 1, 0);
  /* The refund frees the slot on THIS step, so the gate reported is a
   * cooldown, not ALREADY_CUED (budget). ALREADY_CUED is evaluated BEFORE
   * both cooldown gates, so reaching a cooldown code at all proves the slot
   * was freed — the same proof the pre-2026-08-06 TOO_EARLY assertion gave.
   * It reports COOLDOWN_TIME rather than TOO_EARLY only because the
   * retreat distance here (100 m = 20 s at 5 m/s) now sits exactly ON the
   * widened max_notice_s ceiling instead of past it; the distance is left
   * at exactly the refund threshold deliberately, since that boundary
   * (>= threshold refunds, threshold - 1 does not) is what this test and
   * test_shallow_retreat_keeps_budget pin between them. */
  CHECK(d.type == CUE_NONE);
  CHECK(d.reason_code == CUE_REASON_CODE_COOLDOWN_TIME);

  /* Genuine approach past every cooldown (+60 s, +300 m): the informative
   * cue must fire — NOT be suppressed as ALREADY_CUED (the bug). */
  RideSample s3 = sample_at(2000 + 60000, CRUISE_CMPS);
  e.distance_to_start_m = 50;
  d = cue_policy_step(&st, &s3, &e, 1, 0);
  CHECK(d.type == CUE_HEAD_UP);
  CHECK(d.reason_code == CUE_REASON_CODE_CUED);
  CHECK(d.lead_time_s == 10);
}

static void test_shallow_retreat_keeps_budget(void) {
  /* NFR-001 conservatism: a sub-threshold wobble (GPS / graph-distance
   * jitter) must NOT refund the budget, or a single genuine approach could
   * double-cue. One HEAD_UP per event still holds across the wobble. */
  CuePolicyState st;
  cue_policy_init(&st, 0);
  RideSample s1 = sample_at(1000, CRUISE_CMPS);
  RouteEvent e = squeeze_event(60, 50); /* cue at 50 m, closest = 50 */
  CueDecision d = cue_policy_step(&st, &s1, &e, 1, 0);
  CHECK(d.type == CUE_HEAD_UP);

  /* Distance ticks up by less than the refund threshold: no refund. */
  RideSample s2 = sample_at(2000, CRUISE_CMPS);
  e.distance_to_start_m = (int16_t)(50 + (CUE_POLICY_RETREAT_REFUND_M - 1));
  cue_policy_step(&st, &s2, &e, 1, 0);

  /* Re-approach into the window, cooldowns long satisfied (+20 s, +100 m):
   * the retained budget still suppresses the second cue. */
  RideSample s3 = sample_at(2000 + 20000, CRUISE_CMPS);
  e.distance_to_start_m = 45; /* 9 s out, inside the notice window */
  d = cue_policy_step(&st, &s3, &e, 1, 0);
  CHECK(d.type == CUE_NONE);
  CHECK(d.reason_code == CUE_REASON_CODE_ALREADY_CUED);
}

static void test_entered_zone_is_never_refunded(void) {
  /* A cue the rider actually rode into is genuine: reaching the zone
   * (distance_to_start <= 0) latches the slot and must never free the
   * budget — not while inside, and not after a U-turn EXIT makes
   * distance_to_start positive again and retreat tracking would
   * otherwise resume. */
  CuePolicyState st;
  cue_policy_init(&st, 0);
  RideSample s1 = sample_at(1000, CRUISE_CMPS);
  RouteEvent e = squeeze_event(70, 50);
  CueDecision d = cue_policy_step(&st, &s1, &e, 1, 0);
  CHECK(d.type == CUE_HEAD_UP);

  /* Inside the zone; the refund pass must skip it. */
  RideSample s2 = sample_at(2000, CRUISE_CMPS);
  e.distance_to_start_m = -10;
  d = cue_policy_step(&st, &s2, &e, 1, 0);
  CHECK(d.reason_code == CUE_REASON_CODE_INSIDE_EVENT);

  /* Back in the window past cooldowns: still one-per-event (no double cue). */
  RideSample s3 = sample_at(2000 + 20000, CRUISE_CMPS);
  e.distance_to_start_m = 50;
  d = cue_policy_step(&st, &s3, &e, 1, 0);
  CHECK(d.type == CUE_NONE);
  CHECK(d.reason_code == CUE_REASON_CODE_ALREADY_CUED);

  /* U-turn exit, then a retreat FAR past the refund threshold: without
   * the entered latch this refunds (200 - 50 >= threshold) and the
   * re-approach below would double-cue. */
  RideSample s4 = sample_at(2000 + 40000, CRUISE_CMPS);
  e.distance_to_start_m = 200;
  cue_policy_step(&st, &s4, &e, 1, 0);

  RideSample s5 = sample_at(2000 + 60000, CRUISE_CMPS);
  e.distance_to_start_m = 45; /* in-window, cooldowns long satisfied */
  d = cue_policy_step(&st, &s5, &e, 1, 0);
  CHECK(d.type == CUE_NONE);
  CHECK(d.reason_code == CUE_REASON_CODE_ALREADY_CUED);
}

static PersonalMemory memory_for(uint32_t segment_id, uint8_t state,
                                  uint8_t notice_bonus_s) {
  PersonalMemory m;
  m.segment_id = segment_id;
  m.state = state;
  m.notice_bonus_s = notice_bonus_s;
  return m;
}

static void test_memory_null_is_unchanged(void) {
  /* memory == NULL must be byte-for-byte identical to a build with no
   * memory feature at all — same decision as the equivalent 4-arg call
   * every other test in this file already exercises. */
  CuePolicyState st;
  cue_policy_init(&st, 0);
  RideSample s = sample_at(1000, CRUISE_CMPS);
  RouteEvent e = squeeze_event(200, 50);
  CueDecision d = cue_policy_step(&st, &s, &e, 1, 0);
  CHECK(d.type == CUE_HEAD_UP);
  CHECK(d.reason_code == CUE_REASON_CODE_CUED);
  CHECK(d.lead_time_s == 10);

  /* The header's documented equivalence (cue_policy.h): a record with
   * state == NEUTRAL and notice_bonus_s == 0 is byte-for-byte the same as
   * memory == NULL, even when segment_id matches the event's segment. */
  CuePolicyState st2;
  cue_policy_init(&st2, 0);
  PersonalMemory neutral_zero = memory_for(e.segment_id, CUE_MEMORY_NEUTRAL, 0);
  d = cue_policy_step(&st2, &s, &e, 1, &neutral_zero);
  CHECK(d.type == CUE_HEAD_UP);
  CHECK(d.reason_code == CUE_REASON_CODE_CUED);
  CHECK(d.lead_time_s == 10);
}

static void test_memory_unsafe_bypasses_severity_not_confidence(void) {
  CuePolicyState st;
  cue_policy_init(&st, 0);
  RideSample s = sample_at(1000, CRUISE_CMPS);

  /* Severity alone would fail this gate; UNSAFE for the matching segment
   * bypasses only the severity check. */
  RouteEvent weak = squeeze_event(201, 50);
  weak.severity = 10;
  PersonalMemory unsafe = memory_for(weak.segment_id, CUE_MEMORY_UNSAFE, 0);
  CueDecision d = cue_policy_step(&st, &s, &weak, 1, &unsafe);
  CHECK(d.type == CUE_HEAD_UP);
  CHECK(d.reason_code == CUE_REASON_CODE_CUED);

  /* Confidence gate is NOT bypassed — a zero-confidence phantom event must
   * not be promoted into a cue by an unsafe marker (RFC 0002 D5). */
  CuePolicyState st2;
  cue_policy_init(&st2, 0);
  RouteEvent unsure = squeeze_event(202, 50);
  unsure.confidence = 10;
  PersonalMemory unsafe2 = memory_for(unsure.segment_id, CUE_MEMORY_UNSAFE, 0);
  d = cue_policy_step(&st2, &s, &unsure, 1, &unsafe2);
  CHECK(d.type == CUE_NONE);
  CHECK(d.reason_code == CUE_REASON_CODE_CONFIDENCE);
}

static void test_memory_unsafe_with_notice_bonus(void) {
  /* RFC 0002 D5/D4: notice_bonus_s applies for ANY memory state, including
   * UNSAFE — orthogonal to the severity bypass. A weak-severity event
   * escapes the severity gate via UNSAFE (as above) and would cue at 7 s
   * out under the default [5, 20] window; adding a 4 s bonus (effective
   * min 9 s) makes that same call fail TOO_LATE instead, proving the
   * bonus still applies on the UNSAFE path. */
  CuePolicyState st;
  cue_policy_init(&st, 0);
  RideSample s = sample_at(1000, CRUISE_CMPS);
  RouteEvent weak = squeeze_event(203, 35); /* 35 m at 5 m/s = 7 s out */
  weak.severity = 10;

  PersonalMemory unsafe_only = memory_for(weak.segment_id, CUE_MEMORY_UNSAFE, 0);
  CueDecision d = cue_policy_step(&st, &s, &weak, 1, &unsafe_only);
  CHECK(d.type == CUE_HEAD_UP);
  CHECK(d.lead_time_s == 7);

  CuePolicyState st2;
  cue_policy_init(&st2, 0);
  PersonalMemory unsafe_and_bonus = memory_for(weak.segment_id, CUE_MEMORY_UNSAFE, 4);
  d = cue_policy_step(&st2, &s, &weak, 1, &unsafe_and_bonus);
  CHECK(d.type == CUE_NONE);
  CHECK(d.reason_code == CUE_REASON_CODE_TOO_LATE);
}

static void test_memory_suppress_raises_threshold(void) {
  CuePolicyState st;
  cue_policy_init(&st, 0);
  RideSample s = sample_at(1000, CRUISE_CMPS);

  /* Ordinary severity (200) would otherwise cue; SUPPRESS raises the
   * effective threshold to UINT8_MAX, so it now fails — with a distinct
   * reason code from an ordinary severity miss. */
  RouteEvent e = squeeze_event(210, 50);
  PersonalMemory suppress = memory_for(e.segment_id, CUE_MEMORY_SUPPRESS, 0);
  CueDecision d = cue_policy_step(&st, &s, &e, 1, &suppress);
  CHECK(d.type == CUE_NONE);
  CHECK(d.reason_code == CUE_REASON_CODE_MEMORY_SUPPRESSED);

  /* A genuinely maximal-severity event still cues even when suppressed. */
  RouteEvent certain = squeeze_event(211, 50);
  certain.severity = UINT8_MAX;
  d = cue_policy_step(&st, &s, &certain, 1, &suppress);
  CHECK(d.type == CUE_HEAD_UP);
  CHECK(d.reason_code == CUE_REASON_CODE_CUED);
}

static void test_memory_suppress_with_notice_bonus(void) {
  /* RFC 0002 D5: notice_bonus_s applies for ANY memory state, including
   * SUPPRESS — orthogonal to the severity bias. A maximal-severity event
   * escapes suppression (as above) and would cue at 7 s out under the
   * default [5, 20] window; adding a 4 s bonus (effective min 9 s) makes
   * that same call fail TOO_LATE instead, proving the bonus is still
   * applied on the SUPPRESS path, not just NEUTRAL/UNSAFE. */
  CuePolicyState st;
  cue_policy_init(&st, 0);
  RideSample s = sample_at(1000, CRUISE_CMPS);
  RouteEvent certain = squeeze_event(212, 35); /* 35 m at 5 m/s = 7 s out */
  certain.severity = UINT8_MAX;

  PersonalMemory suppress_only = memory_for(certain.segment_id, CUE_MEMORY_SUPPRESS, 0);
  CueDecision d = cue_policy_step(&st, &s, &certain, 1, &suppress_only);
  CHECK(d.type == CUE_HEAD_UP);
  CHECK(d.lead_time_s == 7);

  CuePolicyState st2;
  cue_policy_init(&st2, 0);
  PersonalMemory suppress_and_bonus =
      memory_for(certain.segment_id, CUE_MEMORY_SUPPRESS, 4);
  d = cue_policy_step(&st2, &s, &certain, 1, &suppress_and_bonus);
  CHECK(d.type == CUE_NONE);
  CHECK(d.reason_code == CUE_REASON_CODE_TOO_LATE);
}

static void test_memory_notice_bonus_raises_floor(void) {
  /* D4's additive effect in isolation (no re-clamp): the bonus raises
   * effective_min_notice_s, so a marginal low-lead cue that would fire
   * under the default [5, 20] s window (7 s out) instead fails TOO_LATE
   * once a 4 s bonus is applied (effective min 9 s) — the segment stops
   * accepting the low-lead-time cues a too_late reviewer complained about.
   * (The complementary "admits more lead time instead" half of D4 needs
   * the re-clamp — see test_memory_notice_bonus_saturating_reclamp.) */
  CuePolicyState st;
  cue_policy_init(&st, 0);
  RideSample s = sample_at(1000, CRUISE_CMPS);
  RouteEvent e = squeeze_event(220, 35); /* 35 m at 5 m/s = 7 s out */

  CueDecision d = cue_policy_step(&st, &s, &e, 1, 0);
  CHECK(d.type == CUE_HEAD_UP);
  CHECK(d.lead_time_s == 7);

  CuePolicyState st2;
  cue_policy_init(&st2, 0);
  PersonalMemory bonus = memory_for(e.segment_id, CUE_MEMORY_NEUTRAL, 4);
  d = cue_policy_step(&st2, &s, &e, 1, &bonus);
  CHECK(d.type == CUE_NONE);
  CHECK(d.reason_code == CUE_REASON_CODE_TOO_LATE);
}

static void test_memory_notice_bonus_saturating_reclamp(void) {
  /* RFC 0002 D4's documented window-collapse case: a custom [5, 7] s
   * window plus a 4 s bonus re-clamps to [9, 9] rather than inverting. */
  CuePolicyConfig cfg;
  cue_policy_default_config(&cfg);
  cfg.min_notice_s = 5;
  cfg.max_notice_s = 7;
  CuePolicyState st;
  cue_policy_init(&st, &cfg);
  RideSample s = sample_at(1000, CRUISE_CMPS);
  RouteEvent e = squeeze_event(230, 45); /* 45 m at 5 m/s = 9 s out */
  PersonalMemory bonus = memory_for(e.segment_id, CUE_MEMORY_NEUTRAL, 4);
  CueDecision d = cue_policy_step(&st, &s, &e, 1, &bonus);
  CHECK(d.type == CUE_HEAD_UP);
  CHECK(d.lead_time_s == 9);

  /* 10 s out now falls outside the collapsed [9, 9] window: TOO_EARLY. */
  CuePolicyState st2;
  cue_policy_init(&st2, &cfg);
  RouteEvent far = squeeze_event(231, 50); /* 50 m at 5 m/s = 10 s out */
  d = cue_policy_step(&st2, &s, &far, 1, &bonus);
  CHECK(d.type == CUE_NONE);
  CHECK(d.reason_code == CUE_REASON_CODE_TOO_EARLY);
}

static void test_memory_scoped_to_matching_segment_only(void) {
  /* A memory record for segment X must not bias an event on segment Y in
   * the same step (RFC 0002 D5). */
  CuePolicyState st;
  cue_policy_init(&st, 0);
  RideSample s = sample_at(1000, CRUISE_CMPS);
  RouteEvent weak = squeeze_event(240, 50);
  weak.segment_id = 99;
  weak.severity = 10;
  PersonalMemory unsafe_elsewhere = memory_for(100, CUE_MEMORY_UNSAFE, 0);
  CueDecision d = cue_policy_step(&st, &s, &weak, 1, &unsafe_elsewhere);
  CHECK(d.type == CUE_NONE);
  CHECK(d.reason_code == CUE_REASON_CODE_SEVERITY);
}

static void test_memory_segment_id_zero_is_never_applicable(void) {
  /* segment_id 0 is reserved ("no record", RFC 0002 D5) — a memory record
   * claiming segment 0 must be discarded even if an event's segment_id
   * also happens to be 0 (upstream is supposed to prevent that, but the
   * kernel does not trust it: this is the defense-in-depth guard). */
  CuePolicyState st;
  cue_policy_init(&st, 0);
  RideSample s = sample_at(1000, CRUISE_CMPS);
  RouteEvent weak = squeeze_event(241, 50);
  weak.segment_id = 0;
  weak.severity = 10;
  PersonalMemory zero_segment = memory_for(0, CUE_MEMORY_UNSAFE, 0);
  CueDecision d = cue_policy_step(&st, &s, &weak, 1, &zero_segment);
  CHECK(d.type == CUE_NONE);
  CHECK(d.reason_code == CUE_REASON_CODE_SEVERITY);
}

static void test_memory_inside_event_still_gated(void) {
  /* RFC 0002 D5: unsafe is not an "always cue here" flag — a rider already
   * inside a marked-unsafe segment still gets no cue (cues on approach,
   * never mid-zone). */
  CuePolicyState st;
  cue_policy_init(&st, 0);
  RideSample s = sample_at(1000, CRUISE_CMPS);
  RouteEvent e = squeeze_event(250, -5);
  PersonalMemory unsafe = memory_for(e.segment_id, CUE_MEMORY_UNSAFE, 0);
  CueDecision d = cue_policy_step(&st, &s, &e, 1, &unsafe);
  CHECK(d.type == CUE_NONE);
  CHECK(d.reason_code == CUE_REASON_CODE_INSIDE_EVENT);
}

int main(void) {
  test_default_config();
  test_cues_inside_notice_window();
  test_no_events();
  test_too_early_and_too_late();
  test_inside_event_suppressed();
  test_severity_confidence_gates();
  test_speed_floor();
  test_one_cue_per_event();
  test_cooldowns();
  test_deterministic_replay();
  test_zero_min_speed_clamped();
  test_inverted_notice_window_clamped();
  test_timestamp_regression_stays_conservative();
  test_ring_eviction_known_limitation();
  test_near_pass_refunds_budget();
  test_shallow_retreat_keeps_budget();
  test_entered_zone_is_never_refunded();
  test_memory_null_is_unchanged();
  test_memory_unsafe_bypasses_severity_not_confidence();
  test_memory_unsafe_with_notice_bonus();
  test_memory_suppress_raises_threshold();
  test_memory_suppress_with_notice_bonus();
  test_memory_notice_bonus_raises_floor();
  test_memory_notice_bonus_saturating_reclamp();
  test_memory_scoped_to_matching_segment_only();
  test_memory_segment_id_zero_is_never_applicable();
  test_memory_inside_event_still_gated();
  if (failures == 0) {
    printf("cue_policy: all tests passed\n");
    return 0;
  }
  printf("cue_policy: %d check(s) FAILED\n", failures);
  return 1;
}
