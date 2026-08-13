/*
 * Intent: Portable cue-policy kernel API — the decision layer shared by the
 *         live iOS prototype and the offline replay harness. Divergence
 *         between live and replay decisions is a bug.
 * Context: Design spec §6 (data model), §8 (cue policy), §14 (MCU migration).
 * Pattern: Pure step function over caller-owned state. No dynamic allocation,
 *          no OS dependencies, integer-only arithmetic (NFR-003, NFR-004).
 * Future: Additional event families will extend RouteEvent and
 *         CuePolicyConfig. Personal-route-memory (spec §9) is implemented
 *         as the separate PersonalMemory input below (RFC 0002 D5).
 */
#ifndef CUE_POLICY_H
#define CUE_POLICY_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* --- Route events (spec §6, §7) ------------------------------------------ */

/* Event families. Only one exists in the MVP. */
#define CUE_EVENT_FAMILY_COMPOSITE_SQUEEZE_ZONE 1u

/* reasons_bitmask bits (spec §7). */
#define CUE_REASON_NARROW_LANE (1u << 0)
#define CUE_REASON_NO_SHOULDER_OR_BIKE_LANE (1u << 1)
#define CUE_REASON_HIGH_SPEED_CONTEXT (1u << 2)
/* Reserved ranges: bits 3–7 infrastructure, 8–11 traffic context,
 * 12–15 personal history (spec §7 "reserved future ranges"). These bits
 * describe event-level personal-history EVIDENCE; the memory DECISION
 * (RFC 0002 D5) is carried by PersonalMemory below, deliberately not here. */

typedef struct {
  uint32_t t_ms;            /* milliseconds since ride start; monotonic */
  int32_t lat_e7;           /* latitude  * 1e7 */
  int32_t lon_e7;           /* longitude * 1e7 */
  uint16_t speed_cmps;      /* ground speed, cm/s */
  uint16_t heading_deg_x10; /* heading, degrees * 10 */
  uint32_t segment_id;      /* matched map segment */
} RideSample;

typedef struct {
  uint32_t event_id;
  uint8_t family; /* CUE_EVENT_FAMILY_* */
  uint32_t segment_id;
  uint8_t severity;   /* 0–255 */
  uint8_t confidence; /* 0–255 */
  uint16_t reasons_bitmask;
  int16_t distance_to_start_m; /* <= 0 means the rider is at/inside the event */
  int16_t distance_to_end_m;
} RouteEvent;

/* --- Personal route memory (spec §9, RFC 0002) ---------------------------- */

typedef enum {
  CUE_MEMORY_NEUTRAL = 0,
  CUE_MEMORY_UNSAFE = 1,
  CUE_MEMORY_SUPPRESS = 2,
} PersonalMemoryState;

/* Resolved personal-route-memory input for the current step (RFC 0002 D5).
 * Phone-resolved: the phone joins the rider's per-segment store to the
 * current position/approach window and passes the single applicable record.
 * All fields fixed-size; NULL (as a whole pointer, passed to cue_policy_step)
 * means "no memory this step", so a memory-free ride is byte-for-byte
 * identical to today (NFR-003/004). segment_id 0 is reserved ("no record");
 * a record with state == CUE_MEMORY_NEUTRAL and notice_bonus_s == 0 is
 * byte-for-byte equivalent to passing memory == NULL. */
typedef struct {
  uint32_t segment_id;     /* segment this record applies to; 0 = no record */
  uint8_t state;           /* PersonalMemoryState */
  uint8_t notice_bonus_s;  /* additive notice-window bonus (RFC 0002 D4) */
} PersonalMemory;

/* --- Cue decisions (spec §6) ---------------------------------------------- */

typedef enum {
  CUE_NONE = 0,
  CUE_HEAD_UP = 1,
} CueType;

/* reason_code values: for CUE_HEAD_UP the code is CUE_REASON_CODE_CUED; for
 * CUE_NONE it names the first gate that failed, in evaluation order below.
 * Evaluation order differs from the spec §8 expression only to avoid
 * computing time_to_event before the speed gate guarantees speed > 0; the
 * expression is a pure conjunction, so ordering does not change the result. */
enum {
  CUE_REASON_CODE_CUED = 0,
  CUE_REASON_CODE_NO_EVENT = 1,
  CUE_REASON_CODE_SEVERITY = 2,
  CUE_REASON_CODE_CONFIDENCE = 3,
  CUE_REASON_CODE_INSIDE_EVENT = 4,
  CUE_REASON_CODE_TOO_SLOW = 5,
  CUE_REASON_CODE_TOO_LATE = 6,     /* time_to_event < min_notice_s */
  CUE_REASON_CODE_TOO_EARLY = 7,    /* time_to_event > max_notice_s */
  CUE_REASON_CODE_ALREADY_CUED = 8, /* one HEAD_UP per event (FR-004) */
  CUE_REASON_CODE_COOLDOWN_TIME = 9,
  CUE_REASON_CODE_COOLDOWN_DISTANCE = 10,
  /* A CUE_MEMORY_SUPPRESS record applied to this event's segment (RFC 0002
   * D5) AND the event's severity fell below the SUPPRESS-raised threshold
   * (UINT8_MAX, not the ordinary severity_threshold) — distinguishes a
   * memory-biased-down event from an ordinary severity miss (code 2), for
   * replay debugging. */
  CUE_REASON_CODE_MEMORY_SUPPRESSED = 11,
};

typedef struct {
  uint8_t type; /* CueType */
  uint32_t event_id;
  uint8_t reason_code;
  int16_t lead_time_s; /* time to event start; -1 when not computed */
} CueDecision;

/* --- Policy configuration (spec §8 parameter table) ----------------------- */

/* All fields are logically non-negative; unsigned types make a negative
 * misconfiguration unrepresentable rather than latent (review, PR #4). */
typedef struct {
  uint8_t severity_threshold;
  uint8_t confidence_threshold;
  uint16_t min_notice_s;
  uint16_t max_notice_s;
  uint16_t min_cooldown_s;
  uint16_t min_cooldown_m;
  uint16_t min_speed_kmh;
} CuePolicyConfig;

/* Initial values from spec §8. severity/confidence thresholds are not given
 * initial values in the spec; 128 (midpoint) is a placeholder.
 * future: tune both from three-ride engineering-proof traces (spec §13).
 * min_speed_kmh: spec §8 lists 4; lowered to 1 (the floor cue_policy_init
 * already clamps to — see below) via the same §13 tuning loop, not a
 * mechanism change: the TOO_SLOW gate (kernel/cue_policy.c) still runs and
 * still guards the time-to-event division against speed_cmps == 0.
 * max_notice_s: spec §8 lists 15; widened to 20 via the same §13 tuning
 * loop (operator decision, 2026-08-06), again not a mechanism change — the
 * TOO_EARLY gate is untouched and only its ceiling moved. Provenance, since
 * this one is weaker than the min_speed_kmh precedent: across the nine
 * graded rides of 2026-07-21..08-06 EVERY cue fired at exactly the 15 s
 * ceiling behind 646-741 TOO_EARLY suppressions per ride, so the ceiling —
 * not the geometry — was setting every lead time, and three cues at that
 * ceiling were still graded too_late. The countervailing evidence is on the
 * record: 7 of 22 grades were `unrecognized` (a delivery/perceptibility
 * outcome that docs/grading-guide.md says moves no policy lever), and the
 * same event at the same lead drew opposite grades on 08-02 vs 08-06, so
 * the grade corpus does not by itself separate 15 s from 20 s. Widening
 * also admits one extra cue apiece on the 07-28 and 07-31 traces, which is
 * the NFR-001 cost paid for the earlier notice.
 * future: re-run the §13 sweep once cue delivery is perceptible on a
 * stable path, and revisit — the sweep script's candidates were
 * {15, 18, 20, 22, 25}. */
#define CUE_POLICY_DEFAULT_SEVERITY_THRESHOLD 128
#define CUE_POLICY_DEFAULT_CONFIDENCE_THRESHOLD 128
#define CUE_POLICY_DEFAULT_MIN_NOTICE_S 5
#define CUE_POLICY_DEFAULT_MAX_NOTICE_S 20
#define CUE_POLICY_DEFAULT_MIN_COOLDOWN_S 15
#define CUE_POLICY_DEFAULT_MIN_COOLDOWN_M 75
#define CUE_POLICY_DEFAULT_MIN_SPEED_KMH 1

/* --- Policy state ---------------------------------------------------------- */

/* Ring capacity for "already cued this event" tracking (FR-004). constraint:
 * fixed size — no allocation on the MCU path. The ring holds the most recent
 * CAP cued event ids for the WHOLE ride, not just the approach window, so it
 * bounds FR-004 enforcement: an event evicted after CAP newer cues can cue a
 * second time (documented by test_ring_eviction_known_limitation). 64 ids
 * (256 bytes) covers ~4.8 km of worst-case 75 m-spaced squeeze zones —
 * an upper bound: refunded near-pass slots are tombstoned (id 0), not
 * compacted, so they still occupy ring entries until FIFO overwrite and
 * heavy near-pass traffic shrinks effective coverage below the figure.
 * future: promote to per-segment personal route memory (spec §9). */
#define CUE_POLICY_CUED_EVENTS_CAP 64

/* Retreat refund threshold (issue #28, FR-004 / NFR-001). After a HEAD_UP,
 * if a cued event's distance_to_start_m climbs this many metres above its
 * closest observed approach WITHOUT the rider entering the zone, the cue is
 * treated as a near-pass that never paid off and its FR-004 budget slot is
 * freed, so a later genuine approach can still cue. A near-pass that burns
 * the one-cue budget and silences the real approach is the wrong side of
 * NFR-001 — noise delivered, information dropped. The bound is deterministic
 * from the recorded distance_to_start_m sequence (NFR-003) and needs no
 * per-ride config. Compile-time for now — like the severity/confidence
 * placeholders, a §13-tunable candidate for promotion to CuePolicyConfig.
 * 50 m is roughly half the ~100 m cueing range: far enough past the
 * graph-distance estimate's jitter to mean a real retreat, near enough that
 * an abandoned approach frees the budget promptly. */
#define CUE_POLICY_RETREAT_REFUND_M 50

typedef struct {
  CuePolicyConfig config;
  bool have_prev_sample;
  uint32_t prev_t_ms;
  bool has_cued; /* cooldown gates apply only after the first cue */
  uint32_t last_cue_t_ms;
  uint32_t distance_since_last_cue_cm;
  uint32_t cued_event_ids[CUE_POLICY_CUED_EVENTS_CAP];
  /* Closest distance_to_start_m seen since each slot's event was cued,
   * paired with cued_event_ids by index — the state the retreat refund
   * (CUE_POLICY_RETREAT_REFUND_M) needs, with no extra allocation. A
   * refunded slot is tombstoned with the reserved event id 0 (RFC 0002 D5),
   * which no real event carries, so it simply stops matching until a future
   * cue overwrites it; the ring's FIFO eviction and count are untouched. */
  int16_t cued_event_min_dist[CUE_POLICY_CUED_EVENTS_CAP];
  uint8_t cued_event_count;
  uint8_t cued_event_next;
} CuePolicyState;

/* Initialize state. config == NULL applies the spec §8 defaults.
 * min_speed_kmh is clamped to >= 1 so the time-to-event division inside
 * cue_policy_step is always guarded by the speed gate.
 * min_notice_s is clamped down to max_notice_s (after max_notice_s's own
 * INT16_MAX clamp): an inverted notice window would silently suppress every
 * cue, and the kernel has no error channel to report the misconfiguration
 * (review, PR #7) (#8). */
void cue_policy_init(CuePolicyState *state, const CuePolicyConfig *config);

/* Fill config with the spec §8 defaults. */
void cue_policy_default_config(CuePolicyConfig *config);

/* Evaluate one ride sample against the active route events.
 *
 * Returns at most one HEAD_UP decision per call — the first event (in array
 * order) that passes every gate. Callers must pass events in a deterministic
 * order for replay to reproduce live decisions (NFR-003). When no event cues,
 * the decision carries the first failed gate of the *first* event as its
 * reason_code (or CUE_REASON_CODE_NO_EVENT when event_count == 0).
 *
 * memory: the resolved personal-route-memory record for the current step
 * (RFC 0002 D5), or NULL for memory-free evaluation — byte-for-byte
 * identical to a kernel build with no memory feature at all. When non-NULL,
 * memory->state/notice_bonus_s apply only to events whose segment_id matches
 * memory->segment_id (events on other segments are unaffected this step).
 *
 * constraint: sample->t_ms must be monotonically non-decreasing; the distance
 * integrator clamps dt at 60 s to bound damage from a corrupt trace. */
CueDecision cue_policy_step(CuePolicyState *state, const RideSample *sample,
                            const RouteEvent *events, uint8_t event_count,
                            const PersonalMemory *memory);

#ifdef __cplusplus
}
#endif

#endif /* CUE_POLICY_H */
