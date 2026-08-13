/*
 * Intent: The candidate table itself (see cue_pattern.h for the contract).
 * Pattern: Static const data plus a stateless linear scan — no clock, no
 *          hardware, no allocation, so `make -C mcu test` exercises the
 *          exact bytes the firmware plays.
 *
 * How to read the candidates. Each exists to probe ONE axis against the
 * baseline, so a back-to-back comparison on the bike attributes a
 * difference to something specific rather than to "it felt different":
 *
 *   0 triple-2k3   baseline — the RFC 0006 D3 / issue #154 rendering
 *   1 duo-long     vs 0: burst count and duty (fewer, longer)
 *   2 low-1k2      vs 0: carrier frequency, rhythm held identical
 *   3 syncopated   vs 0: rhythm (irregular, short-short-LONG)
 *   4 sweep        vs 0: spectral motion (rising pitch) — CURRENT DEFAULT
 *   5 steady-led   vs 0: LED coupling, audio held identical
 *
 * 2300 Hz is the piezo's resonance — loudest per watt, and the reason it
 * is the baseline. Loudest is not automatically most NOTICEABLE against
 * road and wind noise, which is exactly what candidates 2 and 4 test.
 */
#include "cue_pattern.h"

#include <stddef.h>

#define CUE_HZ_RESONANT 2300u
#define CUE_HZ_LOW 1200u
#define CUE_RGB_BLUE 0x000000FFu /* HEAD_UP, per mcu-replay-demo-readme.md */

/* Baseline rhythm: three 150 ms bursts on a 250 ms period, a 300 ms gap,
 * then the same triplet again. Shared by candidates 0 and 5 so their
 * audio is bit-identical and only the LED coupling differs. */
static const CueBurst bursts_triple[] = {
    {0u, 150u, CUE_HZ_RESONANT},   {250u, 150u, CUE_HZ_RESONANT},
    {500u, 150u, CUE_HZ_RESONANT}, {950u, 150u, CUE_HZ_RESONANT},
    {1200u, 150u, CUE_HZ_RESONANT}, {1450u, 150u, CUE_HZ_RESONANT},
};

/* Same rhythm, lower carrier — the one axis under test. */
static const CueBurst bursts_triple_low[] = {
    {0u, 150u, CUE_HZ_LOW},   {250u, 150u, CUE_HZ_LOW},
    {500u, 150u, CUE_HZ_LOW}, {950u, 150u, CUE_HZ_LOW},
    {1200u, 150u, CUE_HZ_LOW}, {1450u, 150u, CUE_HZ_LOW},
};

/* Two long bursts: more energy per burst, fewer onsets. */
static const CueBurst bursts_duo[] = {
    {0u, 400u, CUE_HZ_RESONANT},
    {600u, 400u, CUE_HZ_RESONANT},
};

/* Short-short-LONG. An irregular rhythm is easier to separate from the
 * continuous buzz of road surface than a metronomic one — the specific
 * failure the RFC 0004 triple-tap haptic had. */
static const CueBurst bursts_syncopated[] = {
    {0u, 90u, CUE_HZ_RESONANT},
    {150u, 90u, CUE_HZ_RESONANT},
    {500u, 350u, CUE_HZ_RESONANT},
};

/* Rising pitch. Note the piezo is a resonator: the 1600 Hz and 3000 Hz
 * bursts are genuinely quieter than the 2300 Hz one, so this candidate
 * trades peak loudness for a contour nothing on the road produces. That
 * asymmetry is the point, not a defect.
 *
 * Tones are 400 ms, doubled from the 200 ms first cut on the operator's
 * bench comparison (2026-08-01) — the rising contour read clearly, but
 * each step needed longer to register. The 120 ms gaps are unchanged, so
 * the rhythm is the same and only the tone length differs. */
static const CueBurst bursts_sweep[] = {
    {0u, 400u, 1600u},
    {520u, 400u, CUE_HZ_RESONANT},
    {1040u, 400u, 3000u},
};

/* Index order is the wire order (TEST_CUE's pattern byte) and the order
 * button A cycles through. Append only — an insert would silently
 * renumber every candidate a validation note refers to. */
static const CuePattern k_patterns[CUE_PATTERN_COUNT] = {
    {"triple-2k3", "baseline: 3+3 bursts at piezo resonance, strobed",
     bursts_triple, 6u, (uint8_t)CUE_LED_STROBE, CUE_RGB_BLUE, 1600u},
    {"duo-long", "vs baseline: burst count and duty (2 long bursts)",
     bursts_duo, 2u, (uint8_t)CUE_LED_STROBE, CUE_RGB_BLUE, 1000u},
    {"low-1k2", "vs baseline: carrier frequency, rhythm held identical",
     bursts_triple_low, 6u, (uint8_t)CUE_LED_STROBE, CUE_RGB_BLUE, 1600u},
    {"syncopated", "vs baseline: irregular rhythm (short-short-long)",
     bursts_syncopated, 3u, (uint8_t)CUE_LED_STROBE, CUE_RGB_BLUE, 850u},
    {"sweep", "vs baseline: rising pitch, 1600 -> 2300 -> 3000 Hz",
     bursts_sweep, 3u, (uint8_t)CUE_LED_STROBE, CUE_RGB_BLUE, 1440u},
    {"steady-led", "vs baseline: LED coupling, audio held identical",
     bursts_triple, 6u, (uint8_t)CUE_LED_STEADY, CUE_RGB_BLUE, 1600u},
};

const CuePattern *cue_pattern_get(uint8_t index) {
  if (index >= (uint8_t)CUE_PATTERN_COUNT) {
    return NULL;
  }
  return &k_patterns[index];
}

uint8_t cue_pattern_count(void) { return (uint8_t)CUE_PATTERN_COUNT; }

bool cue_pattern_valid(uint8_t index) {
  return index < (uint8_t)CUE_PATTERN_COUNT;
}

void cue_pattern_render(uint8_t index, uint32_t elapsed_ms,
                        CueActuation *out) {
  out->buzzer_hz = 0u;
  out->led_rgb = 0u;
  out->active = false;

  const CuePattern *p = cue_pattern_get(index);
  if (p == NULL || elapsed_ms >= (uint32_t)p->total_ms) {
    /* Past the end (or nonsense index) is silence, permanently. §12
     * non-escalation is enforced here, at the one place every caller
     * funnels through, rather than trusted to each caller's loop. */
    return;
  }

  out->active = true;
  for (uint8_t i = 0; i < p->burst_count; i++) {
    const CueBurst *b = &p->bursts[i];
    if (elapsed_ms >= (uint32_t)b->start_ms &&
        elapsed_ms < (uint32_t)b->start_ms + (uint32_t)b->duration_ms) {
      out->buzzer_hz = b->freq_hz;
      break;
    }
  }

  if (p->led_mode == (uint8_t)CUE_LED_STEADY) {
    out->led_rgb = p->led_rgb;
  } else if (out->buzzer_hz != 0u) {
    out->led_rgb = p->led_rgb;
  }
}
