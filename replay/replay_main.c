/*
 * Intent: Replay harness (FR-010) — load a replay trace JSON (per
 *         replay_trace.schema.json), feed its samples and route-event
 *         observations through the cue-policy kernel in deterministic
 *         order, and compare kernel output against the trace's recorded
 *         cue_decisions. Exit 0 on an exact match, 1 on divergence,
 *         2 on a malformed trace or usage error.
 * Context: NFR-003 (deterministic replay); CLAUDE.md module boundaries —
 *          replay depends only on kernel/ and the schema, and owns all
 *          JSON parsing so the kernel stays import-free.
 * Pattern: Two-pass tokenize (json_mini.h), decode into kernel structs,
 *          then a single pointer-walk over samples / observations /
 *          recorded decisions. Host-side tool: allocation and libc are
 *          fine here, unlike in kernel/. --stats verifies exactly like the
 *          default mode, then prints cue-timing and suppression metrics
 *          (spec §13 measurement hook, §14 lead-time milestone).
 * Future: --print exists to author new traces; --print does not (yet) emit
 *         personal_memory[] — it authors cue_decisions only.
 */
#include <inttypes.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

#include "cue_policy.h"
#include "json_mini.h"

/* Bound on simultaneous observations at one sample timestamp. The MVP has a
 * single event family and sparse events; 16 is generous headroom well under
 * the kernel's uint8_t event_count. */
#define REPLAY_MAX_EVENTS_PER_SAMPLE 16

/* RouteEvent observation stamped with the sample timestamp it belongs to. */
typedef struct {
  uint32_t t_ms;
  RouteEvent event;
} TimedRouteEvent;

/* One personal_memory[] record stamped with the sample timestamp it takes
 * effect at (RFC 0002 D6) — carry-forward, not exact-match like
 * TimedRouteEvent above: it applies from t_ms until the next record's t_ms. */
typedef struct {
  uint32_t t_ms;
  PersonalMemory memory;
} TimedPersonalMemory;

/* One recorded CueDecisionRecord from the trace. */
typedef struct {
  uint32_t t_ms;
  uint8_t type;
  uint32_t event_id;
  uint8_t reason_code;
  int16_t lead_time_s;
} RecordedDecision;

/* One HEAD_UP the kernel emitted during a --stats replay, in emission
 * order (which is chronological — one decision per sample). */
typedef struct {
  uint32_t t_ms;
  uint32_t event_id;
  int16_t lead_time_s;
} CueStat;

/* Review outcome vocabulary (schema Review.outcome). --stats prints counts
 * in this fixed order so output is stable regardless of the trace's array
 * order (NFR-003 spirit). */
static const char *const k_review_outcomes[] = {"useful", "false_alarm",
                                                "too_late", "too_early",
                                                "unrecognized"};
#define REPLAY_N_REVIEW_OUTCOMES \
  ((long)(sizeof(k_review_outcomes) / sizeof(k_review_outcomes[0])))

static const char *g_path;
static const char *g_js;
static const JmTok *g_toks;

static void die(const char *fmt, ...) {
  va_list ap;
  fprintf(stderr, "%s: ", g_path != NULL ? g_path : "replay_cli");
  va_start(ap, fmt);
  vfprintf(stderr, fmt, ap);
  va_end(ap);
  fputc('\n', stderr);
  exit(2);
}

/* --- Field decoding -------------------------------------------------------- */

static long need(long obj, const char *key) {
  long v = jm_obj_get(g_js, g_toks, obj, key);
  if (v < 0) {
    die("missing required key \"%s\"", key);
  }
  return v;
}

static long long get_int(long tok, const char *what, long long lo,
                         long long hi) {
  long long v;
  if (!jm_get_ll(g_js, &g_toks[tok], &v) || v < lo || v > hi) {
    die("field %s: expected integer in [%lld, %lld]", what, lo, hi);
  }
  return v;
}

static uint32_t need_u32(long obj, const char *key) {
  return (uint32_t)get_int(need(obj, key), key, 0, 4294967295LL);
}

static uint16_t need_u16(long obj, const char *key) {
  return (uint16_t)get_int(need(obj, key), key, 0, 65535);
}

static uint8_t need_u8(long obj, const char *key) {
  return (uint8_t)get_int(need(obj, key), key, 0, 255);
}

static int16_t need_i16(long obj, const char *key) {
  return (int16_t)get_int(need(obj, key), key, INT16_MIN, INT16_MAX);
}

/* Optional int32 field (lat_e7 / lon_e7 may be omitted per NFR-005). */
static int32_t opt_i32(long obj, const char *key) {
  long tok = jm_obj_get(g_js, g_toks, obj, key);
  if (tok < 0) {
    return 0;
  }
  return (int32_t)get_int(tok, key, INT32_MIN, INT32_MAX);
}

static uint16_t opt_u16(long obj, const char *key) {
  long tok = jm_obj_get(g_js, g_toks, obj, key);
  if (tok < 0) {
    return 0;
  }
  return (uint16_t)get_int(tok, key, 0, 65535);
}

/* Family string -> numeric mapping documented in the schema (FR-010). */
static uint8_t decode_family(long tok) {
  if (jm_streq(g_js, &g_toks[tok], "COMPOSITE_SQUEEZE_ZONE")) {
    return CUE_EVENT_FAMILY_COMPOSITE_SQUEEZE_ZONE;
  }
  die("unknown event family \"%.*s\" (this harness knows "
      "COMPOSITE_SQUEEZE_ZONE = %u)",
      (int)(g_toks[tok].end - g_toks[tok].start), g_js + g_toks[tok].start,
      (unsigned)CUE_EVENT_FAMILY_COMPOSITE_SQUEEZE_ZONE);
  return 0; /* unreachable */
}

/* personal_memory[].state string -> kernel PersonalMemoryState (RFC 0002 D2). */
static uint8_t decode_memory_state(long tok) {
  if (jm_streq(g_js, &g_toks[tok], "NEUTRAL")) {
    return (uint8_t)CUE_MEMORY_NEUTRAL;
  }
  if (jm_streq(g_js, &g_toks[tok], "UNSAFE")) {
    return (uint8_t)CUE_MEMORY_UNSAFE;
  }
  if (jm_streq(g_js, &g_toks[tok], "SUPPRESS")) {
    return (uint8_t)CUE_MEMORY_SUPPRESS;
  }
  die("unknown personal_memory state \"%.*s\"",
      (int)(g_toks[tok].end - g_toks[tok].start), g_js + g_toks[tok].start);
  return 0; /* unreachable */
}

/* For the end-of-trace carry-forward-active warning (RFC 0002 D6).
 * Hard error on unknown states, mirroring cue_type_name/reason_code_name
 * above — decode_memory_state already rejects any unrecognized state
 * string today, but a silent "?" fallback here would mislabel the warning
 * (rather than fail loudly) the day a new PersonalMemoryState is added and
 * this switch isn't updated to match, exactly the failure mode the die()
 * pattern in the peer functions exists to catch. */
static const char *memory_state_name(uint8_t state) {
  switch (state) {
  case CUE_MEMORY_NEUTRAL:
    return "NEUTRAL";
  case CUE_MEMORY_UNSAFE:
    return "UNSAFE";
  case CUE_MEMORY_SUPPRESS:
    return "SUPPRESS";
  default:
    die("unknown personal memory state %u", (unsigned)state);
  }
  return ""; /* unreachable */
}

static uint8_t decode_cue_type(long tok) {
  if (jm_streq(g_js, &g_toks[tok], "NONE")) {
    return CUE_NONE;
  }
  if (jm_streq(g_js, &g_toks[tok], "HEAD_UP")) {
    return CUE_HEAD_UP;
  }
  die("unknown cue decision type \"%.*s\"",
      (int)(g_toks[tok].end - g_toks[tok].start), g_js + g_toks[tok].start);
  return 0; /* unreachable */
}

/* Hard error on unknown types: a silent fallback would mislabel --print
 * output and divergence diagnostics when CueType grows (review, PR #7). */
static const char *cue_type_name(uint8_t type) {
  if (type == CUE_HEAD_UP) {
    return "HEAD_UP";
  }
  if (type == CUE_NONE) {
    return "NONE";
  }
  die("unknown CueType %u in kernel output", (unsigned)type);
  return ""; /* unreachable */
}

/* Symbolic CUE_REASON_CODE_* names for the --stats suppression histogram.
 * Hard error on unknown codes, mirroring cue_type_name above. */
static const char *reason_code_name(uint8_t code) {
  switch (code) {
  case CUE_REASON_CODE_CUED:
    return "CUED";
  case CUE_REASON_CODE_NO_EVENT:
    return "NO_EVENT";
  case CUE_REASON_CODE_SEVERITY:
    return "SEVERITY";
  case CUE_REASON_CODE_CONFIDENCE:
    return "CONFIDENCE";
  case CUE_REASON_CODE_INSIDE_EVENT:
    return "INSIDE_EVENT";
  case CUE_REASON_CODE_TOO_SLOW:
    return "TOO_SLOW";
  case CUE_REASON_CODE_TOO_LATE:
    return "TOO_LATE";
  case CUE_REASON_CODE_TOO_EARLY:
    return "TOO_EARLY";
  case CUE_REASON_CODE_ALREADY_CUED:
    return "ALREADY_CUED";
  case CUE_REASON_CODE_COOLDOWN_TIME:
    return "COOLDOWN_TIME";
  case CUE_REASON_CODE_COOLDOWN_DISTANCE:
    return "COOLDOWN_DISTANCE";
  case CUE_REASON_CODE_MEMORY_SUPPRESSED:
    return "MEMORY_SUPPRESSED";
  default:
    die("unknown reason_code %u in kernel output", (unsigned)code);
  }
  return ""; /* unreachable */
}

/* Returns the array token, checks its type, and reports its element count. */
static long need_array(long obj, const char *key, long *count) {
  long tok = need(obj, key);
  if (g_toks[tok].type != JM_ARRAY) {
    die("\"%s\" must be an array", key);
  }
  *count = g_toks[tok].size;
  return tok;
}

static long need_object(long tok, const char *what) {
  if (g_toks[tok].type != JM_OBJECT) {
    die("%s entries must be objects", what);
  }
  return tok;
}

/* Like need_array, but tolerates an absent key: *count = 0 and a -1 token.
 * personal_memory[] is optional (schema v2, RFC 0002 D6) — absent means
 * memory-free replay, identical to a trace with no memory feature at all. */
static long opt_array(long obj, const char *key, long *count) {
  long tok = jm_obj_get(g_js, g_toks, obj, key);
  if (tok < 0) {
    *count = 0;
    return -1;
  }
  if (g_toks[tok].type != JM_ARRAY) {
    die("\"%s\" must be an array", key);
  }
  *count = g_toks[tok].size;
  return tok;
}

/* --- Trace decoding -------------------------------------------------------- */

static void decode_policy_config(long root, CuePolicyConfig *cfg) {
  long pc = need(root, "policy_config");
  need_object(pc, "policy_config");
  cfg->severity_threshold = need_u8(pc, "severity_threshold");
  cfg->confidence_threshold = need_u8(pc, "confidence_threshold");
  cfg->min_notice_s = need_u16(pc, "min_notice_s");
  cfg->max_notice_s = need_u16(pc, "max_notice_s");
  cfg->min_cooldown_s = need_u16(pc, "min_cooldown_s");
  cfg->min_cooldown_m = need_u16(pc, "min_cooldown_m");
  cfg->min_speed_kmh = need_u16(pc, "min_speed_kmh");
}

/* The kernel accepts non-decreasing t_ms; the harness requires strictly
 * increasing sample timestamps so each observation and recorded decision
 * maps to exactly one sample. */
static RideSample *decode_samples(long root, long *n_out) {
  long arr, n, i, tok;
  RideSample *samples;
  arr = need_array(root, "samples", &n);
  samples = (RideSample *)malloc((size_t)(n > 0 ? n : 1) * sizeof(*samples));
  if (samples == NULL) {
    die("out of memory decoding %ld samples", n);
  }
  tok = arr + 1;
  for (i = 0; i < n; i++) {
    long o = need_object(tok, "samples");
    samples[i].t_ms = need_u32(o, "t_ms");
    samples[i].lat_e7 = opt_i32(o, "lat_e7");
    samples[i].lon_e7 = opt_i32(o, "lon_e7");
    samples[i].speed_cmps = need_u16(o, "speed_cmps");
    samples[i].heading_deg_x10 = opt_u16(o, "heading_deg_x10");
    samples[i].segment_id = need_u32(o, "segment_id");
    if (i > 0 && samples[i].t_ms <= samples[i - 1].t_ms) {
      die("samples[%ld].t_ms=%" PRIu32 " does not increase (previous %" PRIu32
          "); replay requires strictly increasing sample timestamps",
          i, samples[i].t_ms, samples[i - 1].t_ms);
    }
    tok = jm_skip(g_toks, tok);
  }
  *n_out = n;
  return samples;
}

static TimedRouteEvent *decode_route_events(long root, long *n_out) {
  long arr, n, i, tok;
  TimedRouteEvent *obs;
  arr = need_array(root, "route_events", &n);
  obs = (TimedRouteEvent *)malloc((size_t)(n > 0 ? n : 1) * sizeof(*obs));
  if (obs == NULL) {
    die("out of memory decoding %ld route events", n);
  }
  tok = arr + 1;
  for (i = 0; i < n; i++) {
    long o = need_object(tok, "route_events");
    obs[i].t_ms = need_u32(o, "t_ms");
    obs[i].event.event_id = need_u32(o, "event_id");
    obs[i].event.family = decode_family(need(o, "family"));
    obs[i].event.segment_id = need_u32(o, "segment_id");
    obs[i].event.severity = need_u8(o, "severity");
    obs[i].event.confidence = need_u8(o, "confidence");
    obs[i].event.reasons_bitmask = need_u16(o, "reasons_bitmask");
    obs[i].event.distance_to_start_m = need_i16(o, "distance_to_start_m");
    obs[i].event.distance_to_end_m = need_i16(o, "distance_to_end_m");
    if (i > 0 && obs[i].t_ms < obs[i - 1].t_ms) {
      die("route_events[%ld].t_ms=%" PRIu32 " decreases (previous %" PRIu32
          "); observations must be ordered by t_ms",
          i, obs[i].t_ms, obs[i - 1].t_ms);
    }
    tok = jm_skip(g_toks, tok);
  }
  *n_out = n;
  return obs;
}

/* personal_memory[] uses carry-forward semantics (RFC 0002 D6), not the
 * exact-match re-observation route_events[] uses — so, unlike
 * decode_route_events, consecutive records need only be non-decreasing
 * rather than strictly ordered per sample. Two records at the same t_ms
 * naming the SAME segment_id are redundant but harmless (last one wins,
 * matching how a later write always supersedes an earlier one in the
 * carry-forward model). Two records at the same t_ms naming DIFFERENT
 * segment_ids is a producer-contract violation, not a harmless redundancy:
 * RFC 0002 D5 requires the phone to resolve multi-segment candidates down
 * to the single applicable record (UNSAFE > SUPPRESS > NEUTRAL, nearest-
 * ahead tiebreak) BEFORE logging — a trace that skipped that resolution
 * and logged two different segments for one step cannot be replayed
 * correctly by "last one wins," so it is rejected rather than silently
 * guessing. */
static TimedPersonalMemory *decode_personal_memory(long root, long *n_out) {
  long arr, n, i, tok;
  TimedPersonalMemory *mem;
  arr = opt_array(root, "personal_memory", &n);
  mem = (TimedPersonalMemory *)malloc((size_t)(n > 0 ? n : 1) * sizeof(*mem));
  if (mem == NULL) {
    die("out of memory decoding %ld personal_memory records", n);
  }
  if (arr < 0) {
    *n_out = 0;
    return mem;
  }
  tok = arr + 1;
  for (i = 0; i < n; i++) {
    long o = need_object(tok, "personal_memory");
    mem[i].t_ms = need_u32(o, "t_ms");
    mem[i].memory.segment_id = need_u32(o, "segment_id");
    /* RFC 0002 D5/follow-up #3: 0 is reserved ("no record") and must never
     * be a producer's real segment id — a real segment mistakenly assigned
     * id 0 would have its memory silently discarded on every kernel step. */
    if (mem[i].memory.segment_id == 0u) {
      die("personal_memory[%ld].segment_id must not be 0 (reserved)", i);
    }
    mem[i].memory.state = decode_memory_state(need(o, "state"));
    mem[i].memory.notice_bonus_s = need_u8(o, "notice_bonus_s");
    if (i > 0 && mem[i].t_ms < mem[i - 1].t_ms) {
      die("personal_memory[%ld].t_ms=%" PRIu32 " decreases (previous %" PRIu32
          "); records must be ordered by t_ms",
          i, mem[i].t_ms, mem[i - 1].t_ms);
    }
    if (i > 0 && mem[i].t_ms == mem[i - 1].t_ms &&
        mem[i].memory.segment_id != mem[i - 1].memory.segment_id) {
      die("personal_memory[%ld] and [%ld] share t_ms=%" PRIu32
          " but name different segment_ids (%" PRIu32 " vs %" PRIu32
          "); the phone must resolve multi-segment candidates to one "
          "record before logging (RFC 0002 D5)",
          i - 1, i, mem[i].t_ms, mem[i - 1].memory.segment_id,
          mem[i].memory.segment_id);
    }
    tok = jm_skip(g_toks, tok);
  }
  *n_out = n;
  return mem;
}

static RecordedDecision *decode_cue_decisions(long root, long *n_out) {
  long arr, n, i, tok;
  RecordedDecision *rec;
  arr = need_array(root, "cue_decisions", &n);
  rec = (RecordedDecision *)malloc((size_t)(n > 0 ? n : 1) * sizeof(*rec));
  if (rec == NULL) {
    die("out of memory decoding %ld cue decisions", n);
  }
  tok = arr + 1;
  for (i = 0; i < n; i++) {
    long o = need_object(tok, "cue_decisions");
    rec[i].t_ms = need_u32(o, "t_ms");
    rec[i].type = decode_cue_type(need(o, "type"));
    rec[i].event_id = need_u32(o, "event_id");
    rec[i].reason_code = need_u8(o, "reason_code");
    rec[i].lead_time_s = need_i16(o, "lead_time_s");
    if (i > 0 && rec[i].t_ms <= rec[i - 1].t_ms) {
      die("cue_decisions[%ld].t_ms=%" PRIu32 " does not increase (previous "
          "%" PRIu32 "); the kernel emits one decision per sample",
          i, rec[i].t_ms, rec[i - 1].t_ms);
    }
    tok = jm_skip(g_toks, tok);
  }
  *n_out = n;
  return rec;
}

/* Count review outcomes (FR-008) into counts[REPLAY_N_REVIEW_OUTCOMES],
 * indexed to match k_review_outcomes. The kernel never consumes reviews;
 * only --stats decodes them. Returns the number of reviews. */
static long decode_reviews(long root, long *counts) {
  long arr, n, i, tok;
  arr = need_array(root, "reviews", &n);
  tok = arr + 1;
  for (i = 0; i < n; i++) {
    long o = need_object(tok, "reviews");
    long ot = need(o, "outcome");
    long k;
    int known = 0;
    (void)need_u32(o, "event_id");
    for (k = 0; k < REPLAY_N_REVIEW_OUTCOMES; k++) {
      if (jm_streq(g_js, &g_toks[ot], k_review_outcomes[k])) {
        counts[k]++;
        known = 1;
        break;
      }
    }
    if (!known) {
      die("unknown review outcome \"%.*s\"",
          (int)(g_toks[ot].end - g_toks[ot].start), g_js + g_toks[ot].start);
    }
    tok = jm_skip(g_toks, tok);
  }
  return n;
}

/* --- Replay ---------------------------------------------------------------- */

static void report_mismatch(uint32_t t_ms, const RecordedDecision *exp,
                            const CueDecision *got) {
  printf("DIVERGENCE t_ms=%" PRIu32 ": recorded {type=%s event_id=%" PRIu32
         " reason_code=%u lead_time_s=%d} vs kernel {type=%s event_id=%" PRIu32
         " reason_code=%u lead_time_s=%d}\n",
         t_ms, cue_type_name(exp->type), exp->event_id,
         (unsigned)exp->reason_code, (int)exp->lead_time_s,
         cue_type_name(got->type), got->event_id, (unsigned)got->reason_code,
         (int)got->lead_time_s);
}

static int cmp_lead_time(const void *a, const void *b) {
  int16_t x = *(const int16_t *)a;
  int16_t y = *(const int16_t *)b;
  return (x > y) - (x < y);
}

/* --stats output, after a divergence-free replay. Integer math only; the
 * median is the lower-middle element of the sorted lead times, and both
 * histograms print in fixed (numeric / k_review_outcomes) order, so the
 * output is byte-stable across runs (NFR-003 spirit). */
static void print_stats(const CuePolicyConfig *cfg, const CueStat *cues,
                        long n_cues, const long *supp,
                        const long *review_counts, long n_reviews) {
  long i;
  printf("stats: %ld HEAD_UP cue(s)\n", n_cues);
  for (i = 0; i < n_cues; i++) {
    printf("  HEAD_UP event_id=%" PRIu32 " t_ms=%" PRIu32 " lead_time_s=%d\n",
           cues[i].event_id, cues[i].t_ms, (int)cues[i].lead_time_s);
  }
  if (n_cues > 0) {
    long inside = 0;
    int16_t *leads = (int16_t *)malloc((size_t)n_cues * sizeof(*leads));
    if (leads == NULL) {
      die("out of memory sorting %ld lead times", n_cues);
    }
    for (i = 0; i < n_cues; i++) {
      leads[i] = cues[i].lead_time_s;
      if ((int32_t)cues[i].lead_time_s >= (int32_t)cfg->min_notice_s &&
          (int32_t)cues[i].lead_time_s <= (int32_t)cfg->max_notice_s) {
        inside++;
      }
    }
    qsort(leads, (size_t)n_cues, sizeof(*leads), cmp_lead_time);
    printf("stats: lead_time_s min=%d median=%d max=%d\n", (int)leads[0],
           (int)leads[(n_cues - 1) / 2], (int)leads[n_cues - 1]);
    printf("stats: %ld of %ld cue(s) inside notice window [%u, %u] s\n",
           inside, n_cues, (unsigned)cfg->min_notice_s,
           (unsigned)cfg->max_notice_s);
    free(leads);
  }
  {
    long total = 0;
    /* Start at 1: supp[CUE_REASON_CODE_CUED] is unreachable — the collection
     * branch dies on it (kernel invariant violation, review PR #15). */
    for (i = 1; i <= CUE_REASON_CODE_MEMORY_SUPPRESSED; i++) {
      total += supp[i];
    }
    printf("stats: %ld suppressed decision(s) at observation samples\n",
           total);
    for (i = 1; i <= CUE_REASON_CODE_MEMORY_SUPPRESSED; i++) {
      if (supp[i] > 0) {
        printf("  reason_code=%ld %s: %ld\n", i,
               reason_code_name((uint8_t)i), supp[i]);
      }
    }
  }
  printf("stats: %ld review(s)\n", n_reviews);
  for (i = 0; i < REPLAY_N_REVIEW_OUTCOMES; i++) {
    if (review_counts[i] > 0) {
      printf("  outcome %s: %ld\n", k_review_outcomes[i], review_counts[i]);
    }
  }
}

static char *read_file(const char *path, long *len_out) {
  FILE *f = fopen(path, "rb");
  long len = 0; /* die() exits, but the compiler cannot see that in C99 */
  char *buf;
  if (f == NULL) {
    die("cannot open file");
  }
  if (fseek(f, 0, SEEK_END) != 0 || (len = ftell(f)) < 0 ||
      fseek(f, 0, SEEK_SET) != 0) {
    die("cannot determine file size");
  }
  buf = (char *)malloc((size_t)len + 1);
  if (buf == NULL) {
    die("out of memory reading %ld bytes", len);
  }
  if (len > 0 && fread(buf, 1, (size_t)len, f) != (size_t)len) {
    die("short read");
  }
  buf[len] = '\0';
  fclose(f);
  *len_out = len;
  return buf;
}

int main(int argc, char **argv) {
  int print_mode = 0;
  int stats_mode = 0;
  int argi = 1;
  char *js;
  long js_len, ntok, root, n_samples, n_obs, n_rec, n_mem, i, oi = 0, ri = 0,
                                                          mi = 0;
  long long schema_version;
  long matched = 0;
  long divergences = 0; /* bounded by n_samples + n_rec, both long */
  int cues = 0, first_printed = 0;
  long n_cue_stats = 0;
  long n_reviews = 0;
  long supp[CUE_REASON_CODE_MEMORY_SUPPRESSED + 1] = {0};
  long review_counts[REPLAY_N_REVIEW_OUTCOMES] = {0};
  JmTok *toks;
  CuePolicyConfig cfg;
  CuePolicyState state;
  RideSample *samples;
  TimedRouteEvent *obs;
  TimedPersonalMemory *mem;
  RecordedDecision *rec;
  CueStat *cue_stats = NULL;
  /* RFC 0002 D5: NEUTRAL + notice_bonus_s == 0 (regardless of segment_id)
   * is byte-for-byte equivalent to memory == NULL, so this can always be
   * passed by address to cue_policy_step — no separate "have memory yet"
   * flag needed. A memory-free trace (n_mem == 0) never mutates it. */
  PersonalMemory current_memory = {0, (uint8_t)CUE_MEMORY_NEUTRAL, 0};

  while (argi < argc) {
    if (strcmp(argv[argi], "--print") == 0) {
      print_mode = 1;
    } else if (strcmp(argv[argi], "--stats") == 0) {
      stats_mode = 1;
    } else {
      break; /* trace path (or junk the argc check rejects) */
    }
    argi++;
  }
  if ((print_mode && stats_mode) || argi + 1 != argc) {
    fprintf(stderr,
            "usage: replay_cli [--print | --stats] <trace.json>\n"
            "  default: replay the trace through the cue-policy kernel and\n"
            "           compare against its recorded cue_decisions\n"
            "  --print: emit the kernel's decisions for every sample that\n"
            "           carries observations, as a cue_decisions JSON array\n"
            "  --stats: verify as in the default mode, then print cue-timing\n"
            "           and suppression metrics (spec §13); mutually\n"
            "           exclusive with --print\n"
            "exit codes: 0 match, 1 divergence, 2 malformed trace / usage\n");
    return 2;
  }
  g_path = argv[argi];

  js = read_file(g_path, &js_len);
  ntok = jm_parse(js, js_len, NULL, 0);
  if (ntok < 0) {
    die("invalid JSON (error %ld)", ntok);
  }
  toks = (JmTok *)malloc((size_t)ntok * sizeof(*toks));
  if (toks == NULL) {
    die("out of memory for %ld tokens", ntok);
  }
  if (jm_parse(js, js_len, toks, ntok) != ntok) {
    die("tokenizer disagreement between passes");
  }
  g_js = js;
  g_toks = toks;

  root = 0;
  if (toks[root].type != JM_OBJECT) {
    die("trace root must be an object");
  }
  schema_version = get_int(need(root, "schema_version"), "schema_version", 0,
                           4294967295LL);
  if (schema_version != 1 && schema_version != 2) {
    die("unsupported schema_version %lld; this harness replays versions 1-2",
        schema_version);
  }

  decode_policy_config(root, &cfg);
  /* An inverted notice window makes the kernel emit all-NONE decisions; a
   * trace authored with --print under the same broken config would then
   * replay falsely clean, masking the misconfiguration (review, PR #7). */
  if (cfg.min_notice_s > cfg.max_notice_s) {
    die("policy_config: min_notice_s (%u) > max_notice_s (%u)",
        (unsigned)cfg.min_notice_s, (unsigned)cfg.max_notice_s);
  }
  samples = decode_samples(root, &n_samples);
  obs = decode_route_events(root, &n_obs);
  mem = decode_personal_memory(root, &n_mem);
  /* RFC 0002 D6: a schema_version 1 trace must never carry personal_memory
   * records — a v1 producer bug that emits them would otherwise replay
   * memory-influenced under this harness and memory-free under any older
   * (or schema-honest) tool, exactly the silent divergence the version
   * bump exists to make loud instead. An explicitly empty array is
   * harmless (n_mem == 0) and not rejected. */
  if (n_mem > 0 && schema_version < 2) {
    die("schema_version 1 trace carries %ld personal_memory record(s); "
        "bump schema_version to 2",
        n_mem);
  }
  rec = decode_cue_decisions(root, &n_rec);
  /* markers and reviews are rider feedback for tuning (FR-006/FR-008); the
   * kernel does not consume them, so replay ignores them — except that
   * --stats summarizes review outcomes. */
  if (stats_mode) {
    n_reviews = decode_reviews(root, review_counts);
    cue_stats = (CueStat *)malloc((size_t)(n_samples > 0 ? n_samples : 1) *
                                  sizeof(*cue_stats));
    if (cue_stats == NULL) {
      die("out of memory for %ld cue stats", n_samples);
    }
  }

  /* Trace-shape validation, before any stdout: every observation and
   * recorded decision must land exactly on a sample timestamp — the kernel
   * never saw a between-sample observation live, and it cannot be replayed
   * to a timestamp it was never stepped to. Both are trace errors (exit 2),
   * not divergence, and both must fire before --print opens its JSON array
   * so error paths cannot truncate the output (review, PR #7). */
  {
    long si = 0;
    long run = 1;
    for (i = 0; i < n_obs; i++) {
      while (si < n_samples && samples[si].t_ms < obs[i].t_ms) {
        si++;
      }
      if (si >= n_samples || samples[si].t_ms != obs[i].t_ms) {
        die("route_events[%ld] at t_ms=%" PRIu32
            " matches no sample timestamp — the kernel never saw it live",
            i, obs[i].t_ms);
      }
      if (i > 0 && obs[i].t_ms == obs[i - 1].t_ms) {
        run++;
        if (run > REPLAY_MAX_EVENTS_PER_SAMPLE) {
          die("more than %d observations at t_ms=%" PRIu32,
              REPLAY_MAX_EVENTS_PER_SAMPLE, obs[i].t_ms);
        }
      } else {
        run = 1;
      }
    }
    si = 0;
    for (i = 0; i < n_rec; i++) {
      while (si < n_samples && samples[si].t_ms < rec[i].t_ms) {
        si++;
      }
      if (si >= n_samples || samples[si].t_ms != rec[i].t_ms) {
        die("cue_decisions[%ld] at t_ms=%" PRIu32
            " matches no sample timestamp — the kernel emits decisions only "
            "at sample timestamps",
            i, rec[i].t_ms);
      }
    }
    /* personal_memory[] uses carry-forward semantics (RFC 0002 D6), but a
     * producer only ever resolves/logs a record at a moment the kernel was
     * actually stepped — so, like route_events/cue_decisions above, every
     * record's t_ms must land exactly on a sample timestamp. */
    si = 0;
    for (i = 0; i < n_mem; i++) {
      while (si < n_samples && samples[si].t_ms < mem[i].t_ms) {
        si++;
      }
      if (si >= n_samples || samples[si].t_ms != mem[i].t_ms) {
        die("personal_memory[%ld] at t_ms=%" PRIu32
            " matches no sample timestamp — the kernel is only ever "
            "stepped at sample timestamps",
            i, mem[i].t_ms);
      }
    }
  }

  cue_policy_init(&state, &cfg);
  if (print_mode) {
    printf("[");
  }

  for (i = 0; i < n_samples; i++) {
    const RideSample *s = &samples[i];
    RouteEvent evbuf[REPLAY_MAX_EVENTS_PER_SAMPLE];
    uint8_t ec = 0;
    CueDecision d;

    /* Alignment and the per-sample cap were validated above, so every
     * observation lands on exactly one sample and fits evbuf. */
    while (oi < n_obs && obs[oi].t_ms == s->t_ms) {
      evbuf[ec] = obs[oi].event; /* array order preserved (NFR-003) */
      ec++;
      oi++;
    }

    /* Carry-forward (RFC 0002 D6): a record applies from its t_ms until the
     * next one, so — unlike route_events above — this advances but never
     * "consumes back to empty"; current_memory simply holds whatever the
     * most recent record set, for every sample from here on. */
    while (mi < n_mem && mem[mi].t_ms == s->t_ms) {
      current_memory = mem[mi].memory;
      mi++;
    }

    d = cue_policy_step(&state, s, ec > 0 ? evbuf : NULL, ec, &current_memory);
    if (d.type == CUE_HEAD_UP) {
      cues++;
      if (stats_mode) {
        cue_stats[n_cue_stats].t_ms = s->t_ms;
        cue_stats[n_cue_stats].event_id = d.event_id;
        cue_stats[n_cue_stats].lead_time_s = d.lead_time_s;
        n_cue_stats++;
      }
    } else if (stats_mode && ec > 0) {
      /* Only decisions at samples carrying observations count as
       * suppressions — a NO_EVENT decision on an observation-free sample
       * is the kernel idling, not a suppressed cue. */
      /* CUED (0) on a CUE_NONE decision is a kernel invariant violation —
       * surface it instead of tallying it as a "suppression" (review,
       * PR #15). */
      if (d.reason_code == CUE_REASON_CODE_CUED ||
          d.reason_code > CUE_REASON_CODE_MEMORY_SUPPRESSED) {
        die("unexpected reason_code %u for CUE_NONE decision at t_ms=%" PRIu32,
            (unsigned)d.reason_code, s->t_ms);
      }
      supp[d.reason_code]++;
    }

    if (print_mode) {
      if (ec > 0) {
        printf("%s\n  {\"t_ms\": %" PRIu32 ", \"type\": \"%s\", \"event_id\": "
               "%" PRIu32 ", \"reason_code\": %u, \"lead_time_s\": %d}",
               first_printed ? "," : "", s->t_ms, cue_type_name(d.type),
               d.event_id, (unsigned)d.reason_code, (int)d.lead_time_s);
        first_printed = 1;
      }
      continue;
    }

    if (ri < n_rec && rec[ri].t_ms == s->t_ms) {
      const RecordedDecision *e = &rec[ri];
      if (e->type != d.type || e->event_id != d.event_id ||
          e->reason_code != d.reason_code || e->lead_time_s != d.lead_time_s) {
        report_mismatch(s->t_ms, e, &d);
        divergences++;
      } else {
        matched++;
      }
      ri++;
    } else if (d.type != CUE_NONE) {
      /* Producers must log every HEAD_UP (schema), so an unrecorded cue is
       * live/replay divergence, not an optional omission. */
      printf("DIVERGENCE t_ms=%" PRIu32 ": kernel emitted HEAD_UP (event "
             "%" PRIu32 ", lead %d s) absent from recorded cue_decisions\n",
             s->t_ms, d.event_id, (int)d.lead_time_s);
      divergences++;
    }
  }

  /* RFC 0002 D6 producer-contract check: a trace whose last personal_memory
   * record isn't an explicit clear ({state: NEUTRAL, notice_bonus_s: 0})
   * ends "carry-forward-active" — a dropped clear record (mid-ride crash,
   * lost write) would otherwise silently replay as if this bias were still
   * in effect. Warn, don't fail: the trace may be intentionally partial
   * (e.g. a synthetic fixture), and this is advisory, not a shape error. */
  if (n_mem > 0) {
    const PersonalMemory *last = &mem[n_mem - 1].memory;
    if (last->state != (uint8_t)CUE_MEMORY_NEUTRAL || last->notice_bonus_s != 0) {
      fprintf(stderr,
              "%s: warning: trace ends carry-forward-active — last "
              "personal_memory record (t_ms=%" PRIu32 ") is state=%s "
              "notice_bonus_s=%u, not a clear record; a truncated ride would "
              "silently replay remaining samples with this memory still "
              "applied (RFC 0002 D6)\n",
              g_path, mem[n_mem - 1].t_ms, memory_state_name(last->state),
              (unsigned)last->notice_bonus_s);
    }
  }

  if (print_mode) {
    printf("%s]\n", first_printed ? "\n" : "");
    return 0;
  }

  if (divergences > 0) {
    printf("replay FAILED: %s — %ld divergence(s) across %ld samples\n",
           g_path, divergences, n_samples);
    return 1;
  }
  printf("replay OK: %s — %ld samples, %ld recorded decisions matched, "
         "%d HEAD_UP cue(s)\n",
         g_path, n_samples, matched, cues);
  if (stats_mode) {
    print_stats(&cfg, cue_stats, n_cue_stats, supp, review_counts, n_reviews);
  }
  return 0;
}
