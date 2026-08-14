/*
 * Intent: Reference implementation of the cue-policy gate (spec §8) — the
 *         same binary logic runs live on the phone and offline in replay.
 * Context: See cue_policy.h for the API contract and gate-ordering note.
 * Pattern: Integer-only arithmetic; 64-bit intermediates where products can
 *          overflow 32 bits. No allocation, no libc beyond stdint/stdbool.
 * Future: Personal route memory (spec §9, RFC 0002) hooks in before the
 *         severity gate — see the `memory` handling in evaluate_event.
 */
#include "cue_policy.h"

/* Bound a single integration step so one corrupt timestamp cannot inflate
 * the distance-cooldown accumulator (constraint documented in the header). */
#define CUE_POLICY_MAX_STEP_MS 60000u

/* Ablation builds ONLY (tools/cue-ablation — never firmware, never the app):
 * -DCUE_ABLATION_DISTANCE_GATE swaps the time-to-event notice window for a
 * raw distance window, so the replay corpus can quantify what the
 * speed-normalized window buys (docs/ablations.md). Default thresholds are
 * the [min_notice_s, max_notice_s] = [5, 20] s window at the corpus's median
 * cue-moment speed (5.8 m/s): 30–115 m. constraint: this flag must never be
 * set in a shipping build — the SESSION_ACK state-size tripwire cannot catch
 * it (state layout is unchanged), only the replay contract can. */
#ifdef CUE_ABLATION_DISTANCE_GATE
/* IDF_VER covers every ESP-IDF target; PICO_BUILD covers the pico-sdk.
 * Extend this list with each new firmware toolchain's sentinel macro. */
#if defined(PICO_BUILD) || defined(IDF_VER)
#error "CUE_ABLATION_DISTANCE_GATE is a replay-ablation research variant and must never reach firmware"
#endif
#ifndef CUE_ABLATION_MIN_NOTICE_M
#define CUE_ABLATION_MIN_NOTICE_M 30
#endif
#ifndef CUE_ABLATION_MAX_NOTICE_M
#define CUE_ABLATION_MAX_NOTICE_M 115
#endif
#endif

void cue_policy_default_config(CuePolicyConfig *config) {
  config->severity_threshold = CUE_POLICY_DEFAULT_SEVERITY_THRESHOLD;
  config->confidence_threshold = CUE_POLICY_DEFAULT_CONFIDENCE_THRESHOLD;
  config->min_notice_s = CUE_POLICY_DEFAULT_MIN_NOTICE_S;
  config->max_notice_s = CUE_POLICY_DEFAULT_MAX_NOTICE_S;
  config->min_cooldown_s = CUE_POLICY_DEFAULT_MIN_COOLDOWN_S;
  config->min_cooldown_m = CUE_POLICY_DEFAULT_MIN_COOLDOWN_M;
  config->min_speed_kmh = CUE_POLICY_DEFAULT_MIN_SPEED_KMH;
}

void cue_policy_init(CuePolicyState *state, const CuePolicyConfig *config) {
  if (config != 0) {
    state->config = *config;
  } else {
    cue_policy_default_config(&state->config);
  }
  /* constraint: min_speed_kmh >= 1 keeps the speed gate a divide-by-zero
   * guard for the time-to-event computation (review finding, PR #4). */
  if (state->config.min_speed_kmh < 1) {
    state->config.min_speed_kmh = 1;
  }
  /* constraint: max_notice_s <= INT16_MAX so a cue that passes the notice
   * window always reports an untruncated lead_time_s (int16_t). Unreachable
   * with spec §8 values; guards future config extension (review, PR #4). */
  if (state->config.max_notice_s > (uint16_t)INT16_MAX) {
    state->config.max_notice_s = (uint16_t)INT16_MAX;
  }
  /* constraint: min_notice_s <= max_notice_s — an inverted window would fail
   * every notice gate (TOO_LATE always fires first), silently suppressing all
   * cues: a misconfiguration masked as conservative behavior (NFR-001). The
   * kernel has no error channel, so clamp min down to max; applied after the
   * max_notice_s clamp so the resolved window is self-consistent
   * (review, PR #7) (#8). */
  if (state->config.min_notice_s > state->config.max_notice_s) {
    state->config.min_notice_s = state->config.max_notice_s;
  }
  state->have_prev_sample = false;
  state->prev_t_ms = 0;
  state->has_cued = false;
  state->last_cue_t_ms = 0;
  state->distance_since_last_cue_cm = 0;
  state->cued_event_count = 0;
  state->cued_event_next = 0;
  for (uint8_t i = 0; i < CUE_POLICY_CUED_EVENTS_CAP; i++) {
    state->cued_event_ids[i] = 0;
    state->cued_event_min_dist[i] = 0;
  }
}

/* Ring slot currently holding event_id, or -1. event_id 0 is reserved
 * (RFC 0002 D5) and tombstones a refunded slot, so a real event never
 * matches a freed slot. */
static int find_cued_slot(const CuePolicyState *state, uint32_t event_id) {
  if (event_id == 0u) {
    return -1;
  }
  for (uint8_t i = 0; i < state->cued_event_count; i++) {
    if (state->cued_event_ids[i] == event_id) {
      return (int)i;
    }
  }
  return -1;
}

static bool already_cued(const CuePolicyState *state, uint32_t event_id) {
  return find_cued_slot(state, event_id) >= 0;
}

static void record_cued(CuePolicyState *state, uint32_t event_id,
                        int16_t distance_to_start_m) {
  state->cued_event_ids[state->cued_event_next] = event_id;
  state->cued_event_min_dist[state->cued_event_next] = distance_to_start_m;
  state->cued_event_next =
      (uint8_t)((state->cued_event_next + 1u) % CUE_POLICY_CUED_EVENTS_CAP);
  if (state->cued_event_count < CUE_POLICY_CUED_EVENTS_CAP) {
    state->cued_event_count++;
  }
}

/* FR-004 budget refresh (issue #28): free the one-cue slot of any already-
 * cued event the rider has retreated from without entering, so a later
 * genuine approach can still cue. Deterministic from the observed
 * distance_to_start_m sequence alone (NFR-003); fixed-size state (NFR-004).
 * Runs before the decision pass so a refund takes effect the same step. */
static void refresh_on_retreat(CuePolicyState *state, const RouteEvent *events,
                               uint8_t event_count) {
  for (uint8_t i = 0; i < event_count; i++) {
    const RouteEvent *e = &events[i];
    int slot = find_cued_slot(state, e->event_id);
    if (slot < 0) {
      continue;
    }
    /* Reaching the zone (distance_to_start <= 0) means the cue was
     * genuine: latch the slot with a -1 sentinel so the budget stays
     * spent FOREVER — including after a U-turn exit, when
     * distance_to_start turns positive again and would otherwise resume
     * retreat tracking. The sentinel is unambiguous: min tracking only
     * ever holds positive pre-entry distances (a cue requires
     * distance_to_start > 0 at cue time). */
    if (e->distance_to_start_m <= 0) {
      state->cued_event_min_dist[slot] = -1;
      continue;
    }
    if (state->cued_event_min_dist[slot] < 0) {
      continue; /* entered earlier — never refund */
    }
    if (e->distance_to_start_m < state->cued_event_min_dist[slot]) {
      state->cued_event_min_dist[slot] = e->distance_to_start_m;
    }
    if ((int32_t)e->distance_to_start_m -
            (int32_t)state->cued_event_min_dist[slot] >=
        (int32_t)CUE_POLICY_RETREAT_REFUND_M) {
      state->cued_event_ids[slot] = 0;      /* reserved-id tombstone */
      state->cued_event_min_dist[slot] = 0;
    }
  }
}

/* Evaluate one event against every gate. Returns CUE_REASON_CODE_CUED when
 * the event should cue; otherwise the first failed gate. Writes the computed
 * lead time (or -1) to *lead_time_s.
 *
 * memory: NULL, or the step's resolved PersonalMemory (RFC 0002 D5). Only
 * applies when memory->segment_id == event->segment_id — a record for a
 * different segment must not leak its bias onto this event. */
static uint8_t evaluate_event(const CuePolicyState *state,
                              const RideSample *sample, const RouteEvent *event,
                              const PersonalMemory *memory,
                              int16_t *lead_time_s) {
  const CuePolicyConfig *cfg = &state->config;
  *lead_time_s = -1;

  /* segment_id 0 is reserved ("no record", RFC 0002 D5) — mirrors the
   * event_id 0 tombstone guard in find_cued_slot. Enforcement belongs
   * upstream (the phone-side store must never persist segment 0), but a
   * defense-in-depth check here means a double phone/schema failure can
   * only ever drop an UNSAFE record's effect, never apply one to the
   * wrong (zero) segment. */
  const PersonalMemory *applicable =
      (memory != 0 && memory->segment_id != 0u &&
       memory->segment_id == event->segment_id)
          ? memory
          : 0;
  uint8_t memory_state =
      applicable != 0 ? applicable->state : (uint8_t)CUE_MEMORY_NEUTRAL;

  /* RFC 0002 D5, hook point: before the severity gate.
   * UNSAFE bypasses the severity check only — confidence, inside-event,
   * speed, notice, already-cued, and cooldown gates all still run, so
   * memory can only promote an event the model already produced, never
   * fabricate one or exceed FR-004. SUPPRESS raises the effective severity
   * threshold to UINT8_MAX (only cue if the model is nearly certain) and
   * reports a distinct reason code for replay debugging. */
  if (memory_state == (uint8_t)CUE_MEMORY_SUPPRESS) {
    if (event->severity < UINT8_MAX) {
      return CUE_REASON_CODE_MEMORY_SUPPRESSED;
    }
  } else if (memory_state != (uint8_t)CUE_MEMORY_UNSAFE) {
    if (event->severity < cfg->severity_threshold) {
      return CUE_REASON_CODE_SEVERITY;
    }
  }
  if (event->confidence < cfg->confidence_threshold) {
    return CUE_REASON_CODE_CONFIDENCE;
  }
  if (event->distance_to_start_m <= 0) {
    return CUE_REASON_CODE_INSIDE_EVENT;
  }
  /* speed_cmps * 36 vs min_speed_kmh * 1000 compares cm/s to km/h without
   * division: v[km/h] = v[cm/s] * 36 / 1000. */
  if ((uint32_t)sample->speed_cmps * 36u < (uint32_t)cfg->min_speed_kmh * 1000u) {
    return CUE_REASON_CODE_TOO_SLOW;
  }
  /* cue_policy_init clamps min_speed_kmh >= 1, so the speed gate above
   * guarantees speed_cmps > 0 here.
   * time[s] = distance[m] / (speed[cm/s] / 100). */
  {
#ifdef CUE_ABLATION_DISTANCE_GATE
    /* Distance-window ablation: gate on distance_to_start_m directly.
     * lead_time_s is still computed and reported so variants compare on the
     * same axis. The personal-memory notice bonus is a time-domain lever and
     * deliberately does not apply here. */
    int32_t tte_s = ((int32_t)event->distance_to_start_m * 100) /
                    (int32_t)sample->speed_cmps;
    *lead_time_s = (tte_s > INT16_MAX) ? INT16_MAX : (int16_t)tte_s;
    if ((int32_t)event->distance_to_start_m < CUE_ABLATION_MIN_NOTICE_M) {
      return CUE_REASON_CODE_TOO_LATE;
    }
    if ((int32_t)event->distance_to_start_m > CUE_ABLATION_MAX_NOTICE_M) {
      return CUE_REASON_CODE_TOO_EARLY;
    }
#else
    /* RFC 0002 D4: notice_bonus_s (any memory state) widens the minimum
     * notice window, applied in a 32-bit intermediate — min_notice_s
     * (uint16, up to 65535) + notice_bonus_s (uint8) can reach 65,790,
     * which would wrap a uint16 local into a tiny value and fire the cue
     * far too early, the opposite of the too_late correction the bonus
     * exists to make. The max(...) re-clamp preserves cue_policy_init's
     * min_notice_s <= max_notice_s invariant even when a large bonus would
     * otherwise invert the window (accepted window-collapse edge case). */
    int32_t effective_min_notice_s = (int32_t)cfg->min_notice_s;
    if (applicable != 0) {
      effective_min_notice_s += applicable->notice_bonus_s;
    }
    /* cue_policy_init clamps both config fields <= INT16_MAX specifically
     * so a cue that passes the window always reports an untruncated
     * lead_time_s (int16_t) below. min_notice_s + notice_bonus_s can push
     * effective_min_notice_s to 32,768 (e.g. min == max == INT16_MAX with
     * any nonzero bonus) — clamped here, BEFORE the re-clamp below, so the
     * window degrades to a single point [INT16_MAX, INT16_MAX] instead of
     * silently inverting (effective_min > effective_max), which — like an
     * inverted CuePolicyConfig — would suppress every cue for the
     * segment. */
    if (effective_min_notice_s > (int32_t)INT16_MAX) {
      effective_min_notice_s = (int32_t)INT16_MAX;
    }
    int32_t effective_max_notice_s = (int32_t)cfg->max_notice_s;
    if (effective_min_notice_s > effective_max_notice_s) {
      effective_max_notice_s = effective_min_notice_s;
    }
    int32_t tte_s = ((int32_t)event->distance_to_start_m * 100) /
                    (int32_t)sample->speed_cmps;
    *lead_time_s = (tte_s > INT16_MAX) ? INT16_MAX : (int16_t)tte_s;
    if (tte_s < effective_min_notice_s) {
      return CUE_REASON_CODE_TOO_LATE;
    }
    if (tte_s > effective_max_notice_s) {
      return CUE_REASON_CODE_TOO_EARLY;
    }
#endif /* CUE_ABLATION_DISTANCE_GATE */
  }
  if (already_cued(state, event->event_id)) {
    return CUE_REASON_CODE_ALREADY_CUED;
  }
  if (state->has_cued) {
    /* Saturate on timestamp regression: unsigned wrap would make the
     * cooldown appear expired and fire a spurious cue — the opposite of
     * conservative cueing (NFR-001). Zero elapsed keeps the cooldown live. */
    uint32_t since_ms = (sample->t_ms >= state->last_cue_t_ms)
                            ? (sample->t_ms - state->last_cue_t_ms)
                            : 0u;
    if (since_ms < (uint32_t)cfg->min_cooldown_s * 1000u) {
      return CUE_REASON_CODE_COOLDOWN_TIME;
    }
    if (state->distance_since_last_cue_cm < (uint32_t)cfg->min_cooldown_m * 100u) {
      return CUE_REASON_CODE_COOLDOWN_DISTANCE;
    }
  }
  return CUE_REASON_CODE_CUED;
}

CueDecision cue_policy_step(CuePolicyState *state, const RideSample *sample,
                            const RouteEvent *events, uint8_t event_count,
                            const PersonalMemory *memory) {
  CueDecision decision;
  decision.type = CUE_NONE;
  decision.event_id = 0;
  decision.reason_code = CUE_REASON_CODE_NO_EVENT;
  decision.lead_time_s = -1;

  /* Integrate distance travelled since the last cue (used by the
   * distance-cooldown gate). */
  if (state->have_prev_sample) {
    /* Saturate on timestamp regression (as in the time-cooldown gate):
     * unsigned wrap would credit up to MAX_STEP_MS of phantom travel and
     * could expire the distance cooldown prematurely (NFR-001). */
    uint32_t dt_ms = (sample->t_ms >= state->prev_t_ms)
                         ? (sample->t_ms - state->prev_t_ms)
                         : 0u;
    if (dt_ms > CUE_POLICY_MAX_STEP_MS) {
      dt_ms = CUE_POLICY_MAX_STEP_MS;
    }
    state->distance_since_last_cue_cm +=
        (uint32_t)(((uint64_t)sample->speed_cmps * dt_ms) / 1000u);
  }
  state->prev_t_ms = sample->t_ms;
  state->have_prev_sample = true;

  /* Free the FR-004 budget of any cued event the rider has retreated from
   * without entering, before the decision pass evaluates it (issue #28). */
  refresh_on_retreat(state, events, event_count);

  for (uint8_t i = 0; i < event_count; i++) {
    int16_t lead_time_s;
    uint8_t reason =
        evaluate_event(state, sample, &events[i], memory, &lead_time_s);
    if (reason == CUE_REASON_CODE_CUED) {
      decision.type = CUE_HEAD_UP;
      decision.event_id = events[i].event_id;
      decision.reason_code = CUE_REASON_CODE_CUED;
      decision.lead_time_s = lead_time_s;
      record_cued(state, events[i].event_id, events[i].distance_to_start_m);
      state->has_cued = true;
      state->last_cue_t_ms = sample->t_ms;
      state->distance_since_last_cue_cm = 0;
      return decision;
    }
    if (i == 0) {
      /* Surface the first event's first failed gate for replay debugging. */
      decision.event_id = events[i].event_id;
      decision.reason_code = reason;
      decision.lead_time_s = lead_time_s;
    }
  }
  return decision;
}
