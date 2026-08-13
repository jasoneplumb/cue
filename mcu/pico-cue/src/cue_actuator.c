/*
 * Intent: Implementation of the buzzer/LED actuator (see header).
 * Pattern: One `apply()` funnel writes hardware; everything else only
 *          moves state and timestamps. Rendering decisions come from
 *          cue_pattern.c, which is pure and host-tested — this file must
 *          not acquire timing rules of its own, or the §12 non-escalation
 *          guarantee would live in two places and only one of them would
 *          be tested.
 */
#ifdef PICO_BUILD

#include "cue_actuator.h"

#include "hardware/clocks.h"
#include "hardware/pio.h"
#include "hardware/pwm.h"
#include "pico/stdlib.h"

#include "ws2812.pio.h" /* generated from ws2812.pio by pico_generate_pio_header */

/* WuKong 2040 pinout (RFC 0006 D1). */
#define CUE_PIN_BUZZER 9u
#define CUE_PIN_LEDS 22u
#define CUE_LED_COUNT 2u

/* A fixed 12-bit wrap keeps the PWM divider inside its 1..255 range across
 * the whole usable piezo band (500 Hz..5 kHz) with no per-frequency
 * special cases, and puts 50% duty — the loudest square wave a piezo will
 * take — at exactly half of it. */
#define CUE_PWM_WRAP 4095u
#define CUE_PWM_HALF 2048u

/* Status/indication brightness. The cue itself is deliberately NOT dimmed:
 * it has to be seen in daylight, which is the entire point of the LED. */
#define CUE_STATUS_DIM_PCT 25u

#define CUE_BREATHE_PERIOD_MS 3000u
#define CUE_ADV_BLINK_ON_MS 200u
#define CUE_ADV_BLINK_PERIOD_MS 1500u
#define CUE_INDICATE_ON_MS 120u
#define CUE_INDICATE_PERIOD_MS 300u

#define CUE_RGB_GREEN 0x0000FF00u
#define CUE_RGB_YELLOW 0x00FFA000u
#define CUE_RGB_RED 0x00FF0000u

static uint buzzer_slice;
static uint buzzer_channel;

static PIO led_pio;
static int led_sm = -1;
static uint32_t led_last_rgb;
static bool led_ready;

static uint8_t selected_pattern = (uint8_t)CUE_PATTERN_DEFAULT;

/* Cue in flight. CUE_PATTERN_SELECTED doubles as "nothing playing" — it is
 * never a valid table index. */
static uint8_t active_pattern = (uint8_t)CUE_PATTERN_SELECTED;
static uint32_t active_start_ms;

/* Indication (pattern identity, battery level) — LED only, never audible. */
static uint32_t indicate_rgb;
static uint8_t indicate_blinks;
static uint32_t indicate_start_ms;

static uint8_t status_state = (uint8_t)CUE_ACT_STATUS_ADVERTISING;

/* Bench probes (wired port only). Highest priority, and deliberately
 * unreachable from BLE — see the header. */
static uint16_t probe_tone_hz;
static uint32_t probe_tone_end_ms;
static uint32_t probe_led_rgb;
static uint32_t probe_led_end_ms;

/* --- hardware ------------------------------------------------------------- */

static uint32_t now_ms(void) { return to_ms_since_boot(get_absolute_time()); }

static void buzzer_set(uint16_t hz) {
  static uint16_t current_hz = 0xFFFFu;
  if (hz == current_hz) {
    return;
  }
  current_hz = hz;
  if (hz == 0u) {
    pwm_set_chan_level(buzzer_slice, buzzer_channel, 0u);
    return;
  }
  /* divider = clk_sys / (hz * (wrap + 1)), in 8.4 fixed point. */
  float div = (float)clock_get_hz(clk_sys) / ((float)hz * (float)(CUE_PWM_WRAP + 1u));
  if (div < 1.0f) {
    div = 1.0f;
  } else if (div > 255.0f) {
    div = 255.0f;
  }
  pwm_set_clkdiv(buzzer_slice, div);
  pwm_set_chan_level(buzzer_slice, buzzer_channel, CUE_PWM_HALF);
}

static uint32_t scale_rgb(uint32_t rgb, uint32_t pct) {
  uint32_t r = ((rgb >> 16) & 0xFFu) * pct / 100u;
  uint32_t g = ((rgb >> 8) & 0xFFu) * pct / 100u;
  uint32_t b = (rgb & 0xFFu) * pct / 100u;
  return (r << 16) | (g << 8) | b;
}

static void leds_set(uint32_t rgb) {
  if (!led_ready || rgb == led_last_rgb) {
    return;
  }
  led_last_rgb = rgb;
  /* WS2812B wants GRB, MSB first, left-justified for the 24-bit autopull. */
  uint32_t grb = (((rgb >> 8) & 0xFFu) << 16) | (((rgb >> 16) & 0xFFu) << 8) |
                 (rgb & 0xFFu);
  for (uint i = 0; i < CUE_LED_COUNT; i++) {
    pio_sm_put_blocking(led_pio, (uint)led_sm, grb << 8u);
  }
}

/* --- rendering ------------------------------------------------------------ */

/* Triangle, not a sine: a lookup table or float sinf() would buy a
 * marginally smoother ramp on a status indicator nobody is grading. */
static uint32_t breathe_rgb(uint32_t t) {
  uint32_t phase = t % CUE_BREATHE_PERIOD_MS;
  uint32_t half = CUE_BREATHE_PERIOD_MS / 2u;
  uint32_t up = phase < half ? phase : (CUE_BREATHE_PERIOD_MS - phase);
  uint32_t pct = 4u + (up * (CUE_STATUS_DIM_PCT - 4u)) / half;
  return scale_rgb(CUE_RGB_GREEN, pct);
}

static uint32_t status_rgb(uint32_t t) {
  switch (status_state) {
    case (uint8_t)CUE_ACT_STATUS_CONNECTED:
      return breathe_rgb(t);
    case (uint8_t)CUE_ACT_STATUS_ERROR:
      return scale_rgb(CUE_RGB_RED, CUE_STATUS_DIM_PCT);
    case (uint8_t)CUE_ACT_STATUS_ADVERTISING:
    default:
      return (t % CUE_ADV_BLINK_PERIOD_MS) < CUE_ADV_BLINK_ON_MS
                 ? scale_rgb(CUE_RGB_YELLOW, CUE_STATUS_DIM_PCT)
                 : 0u;
  }
}

/* The single point where anything reaches hardware. Priority is
 * cue > indication > status: a cue must never be masked by a status
 * animation, and an indication must never be mistaken for a cue. */
static void apply(void) {
  uint32_t t = now_ms();

  /* Bench probes outrank everything: they answer a question the operator
   * asked one second ago, and nothing on a ride can reach them. */
  bool tone_probing = false;
  if (probe_tone_hz != 0u) {
    if ((int32_t)(t - probe_tone_end_ms) < 0) {
      tone_probing = true;
    } else {
      probe_tone_hz = 0u;
    }
  }
  bool led_probing = false;
  if (probe_led_end_ms != 0u) {
    if ((int32_t)(t - probe_led_end_ms) < 0) {
      led_probing = true;
    } else {
      probe_led_end_ms = 0u;
      led_last_rgb = 0xFFFFFFFFu; /* force the next real write through */
    }
  }
  /* Both outputs are driven from the probe state whenever EITHER probe is
   * live, so an expiring LED probe does not leave the last probe colour
   * latched on screen just because a TONE probe is still running. */
  if (tone_probing || led_probing) {
    buzzer_set(tone_probing ? probe_tone_hz : 0u);
    leds_set(led_probing ? probe_led_rgb : 0u);
    return;
  }

  if (active_pattern != (uint8_t)CUE_PATTERN_SELECTED) {
    CueActuation a;
    cue_pattern_render(active_pattern, t - active_start_ms, &a);
    if (a.active) {
      buzzer_set(a.buzzer_hz);
      leds_set(a.led_rgb);
      return;
    }
    /* Ended. cue_pattern_render is the authority on when that is, and it
     * never re-activates (spec §12). */
    active_pattern = (uint8_t)CUE_PATTERN_SELECTED;
  }

  buzzer_set(0u);

  if (indicate_blinks > 0u) {
    uint32_t elapsed = t - indicate_start_ms;
    uint32_t total = (uint32_t)indicate_blinks * CUE_INDICATE_PERIOD_MS;
    if (elapsed < total) {
      leds_set((elapsed % CUE_INDICATE_PERIOD_MS) < CUE_INDICATE_ON_MS
                   ? indicate_rgb
                   : 0u);
      return;
    }
    indicate_blinks = 0u;
  }

  leds_set(status_rgb(t));
}

/* --- API ------------------------------------------------------------------ */

bool cue_actuator_init(void) {
  gpio_set_function(CUE_PIN_BUZZER, GPIO_FUNC_PWM);
  buzzer_slice = pwm_gpio_to_slice_num(CUE_PIN_BUZZER);
  buzzer_channel = pwm_gpio_to_channel(CUE_PIN_BUZZER);
  pwm_set_wrap(buzzer_slice, CUE_PWM_WRAP);
  pwm_set_chan_level(buzzer_slice, buzzer_channel, 0u);
  pwm_set_enabled(buzzer_slice, true);

  /* PIO1: PIO0 belongs to the CYW43 driver on a Pico W. */
  led_pio = pio1;
  led_sm = pio_claim_unused_sm(led_pio, false);
  if (led_sm >= 0) {
    uint offset = pio_add_program(led_pio, &ws2812_program);
    ws2812_program_init(led_pio, (uint)led_sm, offset, CUE_PIN_LEDS, 800000.0f);
    led_ready = true;
    /* Force the first write through: the strip's power-on state is
     * undefined, so "no change" is not a safe assumption. */
    led_last_rgb = 0xFFFFFFFFu;
    leds_set(0u);
  }

  status_state = (uint8_t)CUE_ACT_STATUS_ADVERTISING;
  apply();
  return led_ready;
}

void cue_actuator_poll(void) { apply(); }

uint8_t cue_actuator_fire(uint8_t pattern) {
  uint8_t index = (pattern == (uint8_t)CUE_PATTERN_SELECTED) ? selected_pattern
                                                             : pattern;
  if (!cue_pattern_valid(index)) {
    return (uint8_t)CUE_PATTERN_SELECTED;
  }
  active_pattern = index;
  active_start_ms = now_ms();
  indicate_blinks = 0u; /* a cue outranks whatever question was being answered */
  /* Drive hardware now rather than on the next poll: the caller measures
   * actuation_delay_ms across this call (RFC 0006 D3), and a report that
   * excluded the main loop's own latency would flatter the number. */
  apply();
  return index;
}

void cue_actuator_silence(void) {
  active_pattern = (uint8_t)CUE_PATTERN_SELECTED;
  indicate_blinks = 0u;
  apply();
}

bool cue_actuator_is_active(void) {
  return active_pattern != (uint8_t)CUE_PATTERN_SELECTED;
}

uint8_t cue_actuator_selected(void) { return selected_pattern; }

void cue_actuator_select(uint8_t pattern) {
  if (cue_pattern_valid(pattern)) {
    selected_pattern = pattern;
  }
}

uint8_t cue_actuator_next_pattern(void) {
  selected_pattern =
      (uint8_t)((selected_pattern + 1u) % (uint8_t)cue_pattern_count());
  return selected_pattern;
}

void cue_actuator_indicate(uint32_t rgb, uint8_t count) {
  if (count == 0u || cue_actuator_is_active()) {
    return;
  }
  indicate_rgb = rgb;
  indicate_blinks = count;
  indicate_start_ms = now_ms();
  apply();
}

void cue_actuator_set_status(CueActuatorStatus status) {
  status_state = (uint8_t)status;
}

void cue_actuator_tone(uint16_t hz, uint16_t ms) {
  if (hz == 0u || ms == 0u) {
    probe_tone_hz = 0u;
    buzzer_set(0u);
    return;
  }
  probe_tone_hz = hz;
  probe_tone_end_ms = now_ms() + ms;
  apply();
}

void cue_actuator_led_probe(uint32_t rgb, uint16_t ms) {
  if (ms == 0u) {
    probe_led_end_ms = 0u;
    return;
  }
  probe_led_rgb = rgb;
  probe_led_end_ms = now_ms() + ms;
  apply();
}

bool cue_actuator_leds_ready(void) { return led_ready; }

#endif /* PICO_BUILD */
