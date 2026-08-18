/*
 * Intent: Implementation of the buzzer/LED actuator (see header).
 * Pattern: One `apply()` funnel writes hardware; everything else only
 *          moves state and timestamps. Rendering decisions come from
 *          cue_pattern.c, which is pure and host-tested — this file must
 *          not acquire timing rules of its own, or the §12 non-escalation
 *          guarantee would live in two places and only one of them would
 *          be tested.
 *
 * Why the cyw43 lock is here, and why removing it is a regression (#18).
 *
 *   This state machine LOOKS single-threaded. It is not. CMakeLists.txt
 *   links `pico_cyw43_arch_none`, which in pico-sdk 2.3.0 does not mean
 *   "no async context" — it links `pico_async_context_threadsafe_background`
 *   (pico_cyw43_arch/CMakeLists.txt:76-83, which also defines
 *   PICO_CYW43_ARCH_THREADSAFE_BACKGROUND=1). BTstack registers its run
 *   loop as a when-pending worker on that context
 *   (pico_btstack/btstack_run_loop_async_context.c:21), and that context
 *   dispatches its workers from `low_priority_irq_handler` — a claimed
 *   user IRQ, `irq_set_exclusive_handler` + `irq_set_enabled`
 *   (async_context_threadsafe_background.c:165-177, :290).
 *
 *   So every ATT callback runs in interrupt context and preempts main().
 *   Two of this module's entry points are reached from there —
 *   `cue_actuator_fire()` for a TEST_CUE write and for a kernel HEAD_UP
 *   (cue_ble.c:337, :360) — while `_poll` and the button handlers reach
 *   the same state from the main loop. Unsynchronized, three states tear,
 *   and every one of them is silent:
 *
 *     - `buzzer_set()` commits its `current_hz` cache before it touches a
 *       PWM register. A preemption in that gap leaves the cache claiming
 *       a tone that the PWM is not producing, and the dedupe check then
 *       suppresses every future attempt to start it. The LED strobes the
 *       whole pattern in silence.
 *     - `apply()` samples `now_ms()` at the top and reads
 *       `active_start_ms` much further down. A fire landing between them
 *       makes `t - active_start_ms` underflow to ~4.29e9 ms, so
 *       cue_pattern_render reports past-the-end and the cue is cancelled
 *       after an instant.
 *     - `leds_set()` commits `led_last_rgb` before pushing
 *       CUE_LED_COUNT words to the PIO. A preemption between pushes
 *       latches two colours on one strip, and the dedupe suppresses the
 *       corrective rewrite until the value next changes — indefinitely,
 *       for a steady colour.
 *
 *   None of these is reproducible on a bench and all three present as
 *   "the cue didn't fire" or "the cue was silent", which this system
 *   would otherwise attribute to the policy.
 *
 *   `cyw43_thread_enter()` / `cyw43_thread_exit()` are
 *   `async_context_acquire_lock_blocking` / `_release_lock` on exactly
 *   that context (cyw43_driver.c:247), so they are precisely the lock the
 *   preempting side holds: `low_priority_irq_handler` only dispatches
 *   when its recursive-mutex enter count comes back 1, and backs off
 *   without running any worker when it has preempted a holder. They are
 *   recursion-safe by design, so the IRQ-side calls (which already run
 *   under the lock) pay only a mutex increment — `actuation_delay_us`
 *   (RFC 0006 D3) is unaffected. cue_power.c:106 established the idiom.
 *
 *   The rule is uniform on purpose: EVERY public entry point brackets its
 *   body, so no reader has to work out which ones are "the safe ones".
 */
#ifdef PICO_BUILD

#include "cue_actuator.h"

#include "hardware/clocks.h"
#include "hardware/pio.h"
#include "hardware/pwm.h"
#include "pico/cyw43_arch.h"
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

static bool is_active(void) {
  return active_pattern != (uint8_t)CUE_PATTERN_SELECTED;
}

/* The single point where anything reaches hardware. Callers must hold the
 * lock — every public entry point does. Priority is
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

  if (is_active()) {
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

/* --- mutual exclusion ----------------------------------------------------- */

/* False until cyw43_arch_init() has succeeded. Two facts at once, and they
 * become true at the same instant: the async_context (and therefore the
 * lock) exists, and the IRQ that can preempt us exists. Before that point
 * the lock must NOT be taken — `cyw43_async_context` is still NULL, so
 * cyw43_thread_enter() would fault. That matters because main() keeps
 * running deliberately when cue_ble_init() fails (the replay port is the
 * Phase A certification path): an unconditional lock would wedge exactly
 * the loop that tolerance exists to protect, which is the same trap
 * cue_power.c's `radio_available` flag avoids.
 *
 * Set from main-loop context by cue_ble_init(), before hci_power_control()
 * and therefore before any connection exists to generate an ATT write, so
 * no entry point can straddle the transition and take the lock without
 * releasing it.
 *
 * Monotonic, and its setter takes no argument so that it cannot be
 * otherwise. actuator_lock() and actuator_unlock() read this flag
 * independently, so a value that could go back to false would have
 * acquire take the mutex and release skip it — a permanent deadlock from
 * one plausible teardown call. A one-way latch removes that failure mode
 * at the type level rather than by convention. */
static bool lock_available;

static void actuator_lock(void) {
  if (lock_available) {
    cyw43_thread_enter();
  }
}

static void actuator_unlock(void) {
  if (lock_available) {
    cyw43_thread_exit();
  }
}

/* --- API ------------------------------------------------------------------ */

bool cue_actuator_init(void) {
  /* Bracketed for the uniform rule, not because it can contend: this runs
   * from main() before cue_ble_init(), so `lock_available` is still false
   * and both calls are no-ops. Leaving it bracketed means the invariant
   * "every entry point takes the lock" has no exceptions to remember if
   * the init order ever changes. */
  actuator_lock();
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
  bool ready = led_ready;
  actuator_unlock();
  return ready;
}

void cue_actuator_set_lock_available(void) { lock_available = true; }

void cue_actuator_poll(void) {
  /* Rate-limited to once per millisecond, and this is about the lock, not
   * about apply(). Releasing the OUTERMOST cyw43 lock runs
   * `process_under_lock()`, which re-arms the async_context's alarm — the
   * SDK puts that at "10s of microseconds"
   * (async_context_threadsafe_background.c, the comment above the
   * alarm_pending optimization; the optimization does not fire when the
   * next timeout is unchanged, which is the steady state). Paying that on
   * every iteration of a loop that also has to service USB and buttons is
   * a cost this fix would otherwise have introduced by itself.
   *
   * Skipping is provably lossless: every rendering decision below is a
   * function of `now_ms()` in whole milliseconds and of state that only
   * the other entry points change — and each of those calls apply()
   * itself, under the lock. So a second poll inside the same millisecond
   * can only recompute the identical frame. */
  static uint32_t last_poll_ms;
  uint32_t t = now_ms();
  if (t == last_poll_ms) {
    return;
  }
  last_poll_ms = t;

  actuator_lock();
  apply();
  actuator_unlock();
}

uint8_t cue_actuator_fire(uint8_t pattern) {
  actuator_lock();
  uint8_t index = (pattern == (uint8_t)CUE_PATTERN_SELECTED) ? selected_pattern
                                                             : pattern;
  if (!cue_pattern_valid(index)) {
    actuator_unlock();
    return (uint8_t)CUE_PATTERN_SELECTED;
  }
  active_pattern = index;
  active_start_ms = now_ms();
  indicate_blinks = 0u; /* a cue outranks whatever question was being answered */
  /* Drive hardware now rather than on the next poll: the caller measures
   * actuation_delay_ms across this call (RFC 0006 D3), and a report that
   * excluded the main loop's own latency would flatter the number. The
   * lock does not change what that number measures — on this path it is
   * already held by the dispatching IRQ, so it costs a recursive-mutex
   * increment. */
  apply();
  actuator_unlock();
  return index;
}

void cue_actuator_silence(void) {
  actuator_lock();
  active_pattern = (uint8_t)CUE_PATTERN_SELECTED;
  indicate_blinks = 0u;
  apply();
  actuator_unlock();
}

bool cue_actuator_acknowledge(void) {
  actuator_lock();
  /* Check and stop in ONE locked region. Split across two — which is what
   * a public `is_active()` getter plus `_silence()` amounts to, however
   * atomic each half is on its own — a HEAD_UP arriving in the gap gets
   * silenced by a press that was answering the previous cue, and the
   * rider never perceives it. A cue this device decided to deliver and
   * then swallowed is worse than the noisy cueing NFR-001 forbids,
   * because nothing downstream can tell it happened. */
  bool acknowledged = is_active();
  if (acknowledged) {
    active_pattern = (uint8_t)CUE_PATTERN_SELECTED;
    indicate_blinks = 0u;
    apply();
  }
  actuator_unlock();
  return acknowledged;
}

uint8_t cue_actuator_selected(void) {
  actuator_lock();
  uint8_t pattern = selected_pattern;
  actuator_unlock();
  return pattern;
}

void cue_actuator_select(uint8_t pattern) {
  actuator_lock();
  if (cue_pattern_valid(pattern)) {
    selected_pattern = pattern;
  }
  actuator_unlock();
}

uint8_t cue_actuator_next_pattern(void) {
  actuator_lock();
  selected_pattern =
      (uint8_t)((selected_pattern + 1u) % (uint8_t)cue_pattern_count());
  uint8_t pattern = selected_pattern;
  actuator_unlock();
  return pattern;
}

void cue_actuator_indicate(uint32_t rgb, uint8_t count) {
  actuator_lock();
  /* The internal `is_active()`, not the public entry point: the check and
   * the write that depends on it have to sit inside ONE locked region, or
   * a cue landing between them would be overwritten by the indication it
   * is supposed to outrank. */
  if (count == 0u || is_active()) {
    actuator_unlock();
    return;
  }
  indicate_rgb = rgb;
  indicate_blinks = count;
  indicate_start_ms = now_ms();
  apply();
  actuator_unlock();
}

void cue_actuator_set_status(CueActuatorStatus status) {
  actuator_lock();
  status_state = (uint8_t)status;
  actuator_unlock();
}

void cue_actuator_tone(uint16_t hz, uint16_t ms) {
  actuator_lock();
  if (hz == 0u || ms == 0u) {
    probe_tone_hz = 0u;
    buzzer_set(0u);
    actuator_unlock();
    return;
  }
  probe_tone_hz = hz;
  probe_tone_end_ms = now_ms() + ms;
  apply();
  actuator_unlock();
}

void cue_actuator_led_probe(uint32_t rgb, uint16_t ms) {
  actuator_lock();
  if (ms == 0u) {
    if (probe_led_end_ms != 0u) {
      probe_led_end_ms = 0u;
      led_last_rgb = 0xFFFFFFFFu; /* force the next real write through */
      apply();
    }
    actuator_unlock();
    return;
  }
  probe_led_rgb = rgb;
  probe_led_end_ms = now_ms() + ms;
  apply();
  actuator_unlock();
}

bool cue_actuator_leds_ready(void) {
  actuator_lock();
  bool ready = led_ready;
  actuator_unlock();
  return ready;
}

#endif /* PICO_BUILD */
