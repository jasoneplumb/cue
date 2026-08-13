/*
 * Intent: Host test for the candidate cue patterns (RFC 0006 D7). The
 *         table is data the firmware plays without further checking, so
 *         its invariants are asserted here rather than discovered on a
 *         bike: bursts ordered and non-overlapping, declared duration
 *         matching the actual one, every candidate finishing inside the
 *         policy's notice window, and — the §12 obligation — no pattern
 *         ever becoming active again after it has ended.
 * Build: see mcu/Makefile's `test` target.
 */
#include <stdio.h>
#include <string.h>

#include "cue_pattern.h"

static int failures;

static void check(int cond, const char *what) {
  if (!cond) {
    printf("FAIL: %s\n", what);
    failures++;
  }
}

static void checkf(int cond, const char *what, const char *who) {
  if (!cond) {
    printf("FAIL: %s [%s]\n", what, who);
    failures++;
  }
}

int main(void) {
  CueActuation a;

  check(cue_pattern_count() == (uint8_t)CUE_PATTERN_COUNT, "count matches macro");
  check(cue_pattern_valid((uint8_t)CUE_PATTERN_DEFAULT), "default index is valid");
  check(!cue_pattern_valid((uint8_t)CUE_PATTERN_COUNT), "count is out of range");
  check(!cue_pattern_valid((uint8_t)CUE_PATTERN_SELECTED),
        "the SELECTED sentinel is not a table index");
  check(cue_pattern_get((uint8_t)CUE_PATTERN_COUNT) == NULL,
        "out-of-range get returns NULL");

  for (uint8_t i = 0; i < cue_pattern_count(); i++) {
    const CuePattern *p = cue_pattern_get(i);
    checkf(p != NULL, "pattern present", "index");
    if (p == NULL) {
      continue;
    }
    const char *who = p->name;

    checkf(p->name != NULL && p->name[0] != '\0', "named", who);
    checkf(p->probes != NULL && p->probes[0] != '\0',
           "documents the axis it probes", who);
    checkf(p->burst_count > 0u, "has at least one burst", who);
    checkf(p->led_rgb != 0u, "lights the LED", who);
    checkf(p->total_ms <= (uint16_t)CUE_PATTERN_MAX_DURATION_MS,
           "completes inside the notice window", who);

    /* Ordered, non-overlapping, and audible. Overlap would make the
     * rendering ambiguous — two bursts claiming the same instant would
     * silently resolve to whichever comes first in the array. */
    uint32_t prev_end = 0u;
    for (uint8_t b = 0; b < p->burst_count; b++) {
      const CueBurst *burst = &p->bursts[b];
      checkf(burst->duration_ms > 0u, "burst has nonzero duration", who);
      checkf(burst->freq_hz >= 500u && burst->freq_hz <= 5000u,
             "burst frequency is in the piezo's usable band", who);
      checkf((uint32_t)burst->start_ms >= prev_end,
             "bursts are ordered and non-overlapping", who);
      prev_end = (uint32_t)burst->start_ms + (uint32_t)burst->duration_ms;
    }
    checkf(prev_end == (uint32_t)p->total_ms,
           "total_ms equals the end of the last burst", who);

    /* Render at every declared boundary. */
    cue_pattern_render(i, 0u, &a);
    checkf(a.active, "active at t=0", who);
    checkf(a.buzzer_hz == p->bursts[0].freq_hz, "sounds at t=0", who);

    cue_pattern_render(i, (uint32_t)p->total_ms - 1u, &a);
    checkf(a.active, "still active one ms before the end", who);

    cue_pattern_render(i, (uint32_t)p->total_ms, &a);
    checkf(!a.active && a.buzzer_hz == 0u && a.led_rgb == 0u,
           "silent and inactive at total_ms", who);

    /* §12: once finished, a pattern never restarts, at any later time.
     * Sampled well past the end, including a value that would wrap a
     * naive modulo-based scheduler back into the pattern. */
    for (uint32_t t = (uint32_t)p->total_ms; t < 60000u; t += 37u) {
      cue_pattern_render(i, t, &a);
      if (a.active || a.buzzer_hz != 0u || a.led_rgb != 0u) {
        checkf(0, "never re-activates after the end", who);
        break;
      }
    }

    /* Sweep the whole pattern: the LED contract must hold at every ms,
     * and every sounding instant must belong to a declared burst. */
    int saw_gap = 0;
    for (uint32_t t = 0u; t < (uint32_t)p->total_ms; t++) {
      cue_pattern_render(i, t, &a);
      if (!a.active) {
        checkf(0, "active for its whole declared duration", who);
        break;
      }
      if (a.buzzer_hz == 0u) {
        saw_gap = 1;
      }
      if (p->led_mode == (uint8_t)CUE_LED_STEADY) {
        if (a.led_rgb != p->led_rgb) {
          checkf(0, "steady LED stays lit across gaps", who);
          break;
        }
      } else if ((a.buzzer_hz != 0u) != (a.led_rgb != 0u)) {
        checkf(0, "strobed LED tracks the buzzer exactly", who);
        break;
      }
    }
    checkf(saw_gap || p->burst_count == 1u,
           "a multi-burst pattern has audible gaps", who);
  }

  /* An unknown index renders as silence rather than reaching into the
   * table — the actuator plays whatever this returns. */
  cue_pattern_render((uint8_t)CUE_PATTERN_COUNT, 0u, &a);
  check(!a.active && a.buzzer_hz == 0u && a.led_rgb == 0u,
        "invalid index renders silent");
  cue_pattern_render((uint8_t)CUE_PATTERN_SELECTED, 0u, &a);
  check(!a.active, "the SELECTED sentinel renders silent");

  /* The candidates must actually differ, or a back-to-back comparison
   * has nothing to compare. Distinctness is checked on the rendered
   * timeline, not on the struct, so two tables that merely spell the
   * same rendering differently still count as duplicates. */
  for (uint8_t i = 0; i < cue_pattern_count(); i++) {
    for (uint8_t j = (uint8_t)(i + 1u); j < cue_pattern_count(); j++) {
      int differs = 0;
      for (uint32_t t = 0u; t < (uint32_t)CUE_PATTERN_MAX_DURATION_MS; t++) {
        CueActuation x, y;
        cue_pattern_render(i, t, &x);
        cue_pattern_render(j, t, &y);
        if (x.buzzer_hz != y.buzzer_hz || x.led_rgb != y.led_rgb ||
            x.active != y.active) {
          differs = 1;
          break;
        }
      }
      if (!differs) {
        printf("FAIL: patterns %u and %u render identically\n", i, j);
        failures++;
      }
    }
  }

  printf(failures ? "FAILURES: %d\n" : "cue_pattern: all tests passed\n",
         failures);
  return failures ? 1 : 0;
}
