/*
 * Intent: The candidate cue renderings — a table of named buzzer/LED
 *         patterns plus a pure function that renders any of them at any
 *         instant. This is the *data* half of Phase C; cue_actuator.c is
 *         the hardware half that plays what this describes.
 * Context: RFC 0006 D7 (actuation patterns), issue #154. The operator
 *          requirement is explicit: several candidates, selectable at
 *          runtime, comparable back-to-back on the bike — the whole
 *          reason this hardware exists is perceptibility, and which
 *          rendering wins is an empirical question, not a design-time one.
 * Pattern: No hardware, no clock, no allocation — `elapsed_ms` comes from
 *          the caller, so the entire pattern engine is host-testable and
 *          the same table is asserted by `make -C mcu test` (NFR-004).
 *
 * Non-escalation (spec §12): every candidate is a FIXED-LENGTH rendering
 * of one cue. There is no repeat-on-non-response and no escalation path —
 * a pattern that has run to its end goes silent and stays silent until
 * the kernel decides another HEAD_UP. `CUE_PATTERN_MAX_DURATION_MS` is
 * the mechanical guard: a pattern must finish well inside the policy's
 * `min_notice_s` (5 s) so the rendering is complete before the rider
 * reaches the zone it is about.
 */
#ifndef CUE_PATTERN_H
#define CUE_PATTERN_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Number of selectable candidates. Kept as a macro so buffers and the
 * protocol's range check are both sized from one place. */
#define CUE_PATTERN_COUNT 6u

/* Compiled-in default. Changing this is how a bench/ride comparison gets
 * committed — see RFC 0006 D7.
 *
 * Candidate 4 (`sweep`, rising 1600 -> 2300 -> 3000 Hz) on the operator's
 * bench comparison of all six, 2026-08-01. A rising contour is unlike
 * anything road noise produces, which is the property the two retired
 * channels lacked. Provisional until a validation ride judges it against
 * real road and wind noise; the rest stay selectable for that comparison. */
#define CUE_PATTERN_DEFAULT 4u

/* Wire/API sentinel for "whichever pattern is currently selected" — what
 * a length-1 TEST_CUE frame means, and what a kernel HEAD_UP always uses.
 * Deliberately outside any valid index. */
#define CUE_PATTERN_SELECTED 0xFFu

/* No candidate may outlast this. min_notice_s is 5 s, so a 2.5 s ceiling
 * leaves the rendering finished with margin before the zone. */
#define CUE_PATTERN_MAX_DURATION_MS 2500u

/* One buzzer burst: `freq_hz` for `duration_ms`, starting `start_ms` after
 * the pattern begins. Bursts are ordered and non-overlapping (asserted by
 * the host test), so rendering is a linear scan with no state. */
typedef struct {
  uint16_t start_ms;
  uint16_t duration_ms;
  uint16_t freq_hz;
} CueBurst;

typedef enum {
  /* LED lit only while the buzzer sounds — the audio and visual channels
   * reinforce each other, and the strobe carries the rhythm. */
  CUE_LED_STROBE = 0,
  /* LED lit for the pattern's whole duration — isolates the coupling axis
   * so a comparison can tell "the strobe helped" from "the light helped". */
  CUE_LED_STEADY = 1,
} CueLedMode;

typedef struct {
  const char *name;
  /* Which perceptibility axis this candidate exists to probe, relative to
   * the others. Comparison notes belong next to the numbers they explain. */
  const char *probes;
  const CueBurst *bursts;
  uint8_t burst_count;
  uint8_t led_mode; /* CueLedMode */
  uint32_t led_rgb; /* 0x00RRGGBB */
  uint16_t total_ms;
} CuePattern;

/* What the actuator should be doing at the rendered instant. */
typedef struct {
  uint16_t buzzer_hz; /* 0 = silent */
  uint32_t led_rgb;   /* 0 = dark */
  bool active;        /* false once the pattern has run to its end */
} CueActuation;

/* NULL for an out-of-range index. */
const CuePattern *cue_pattern_get(uint8_t index);

uint8_t cue_pattern_count(void);

bool cue_pattern_valid(uint8_t index);

/* Render `index` at `elapsed_ms` after its start. An invalid index or an
 * elapsed time past the pattern's end yields a silent, dark, inactive
 * result — so a caller that keeps ticking past the end simply stops,
 * which is what §12 non-escalation requires of every code path. */
void cue_pattern_render(uint8_t index, uint32_t elapsed_ms, CueActuation *out);

#ifdef __cplusplus
}
#endif

#endif /* CUE_PATTERN_H */
