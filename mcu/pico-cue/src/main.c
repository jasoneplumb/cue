/*
 * Intent: pico-cue firmware entry point (RFC 0006). Serves two
 *         independent front ends over one kernel build: the USB-CDC
 *         replay port (Phase A) that the host hiltest certifies against
 *         the trace corpus, and the BLE Cue Ride Service (Phase B) that
 *         the phone streams live rides to. Phase C adds the actuator the
 *         rider actually perceives, plus the two buttons that make the
 *         candidate patterns comparable without a phone.
 *
 *         The two front ends own separate sessions deliberately — the
 *         replay port must stay usable as the regression gate even while
 *         BLE work is in progress, and a hiltest run must never be able
 *         to perturb a live ride's kernel state.
 *
 *         This file is also the composition root for the buttons: what a
 *         press MEANS is decided here, in one readable place, rather than
 *         spread across the modules a press happens to touch.
 */
#include <assert.h>

#include "pico/stdlib.h"

#include "cue_actuator.h"
#include "cue_ble.h"
#include "cue_buttons.h"
#include "cue_pattern.h"
#include "cue_policy.h"
#include "cue_power.h"
#include "cue_usb_replay.h"

/* RFC 0006 D6 compiler-width tripwire: the kernel's state must be laid out
 * identically under arm-none-eabi-gcc and the host compilers (420 B, host
 * measurement 2026-07-31), or on-target decisions could diverge from the
 * shadow/replay without any wire-format error. SESSION_ACK echoes this same
 * value at runtime (Phase B). */
static_assert(sizeof(CuePolicyState) == 420,
              "CuePolicyState layout drifted from host build");

/* Pattern-identity indication: a dim white blink per candidate index + 1,
 * so "which one is armed" is answerable on a handlebar with no display. */
#define CUE_RGB_WHITE_DIM 0x00303030u

/* Battery indication, by cue_power_level() bucket. Deliberately distinct
 * from the cue's blue, and silent — an answer to a question must never be
 * mistakable for a cue (NFR-001). */
static const uint32_t k_battery_rgb[4] = {
    0x00FF00FFu, /* 0: unknown — magenta, one blink */
    0x00FF0000u, /* 1: low                          */
    0x00FFA000u, /* 2: usable                       */
    0x0000FF00u, /* 3: healthy                      */
};

static void handle_button(CueButtonEvent event) {
  switch (event) {
    case CUE_BUTTON_A_SHORT:
      /* Acknowledge: the rider has plainly received the cue, so the rest
       * of the pattern is noise. One call, not a query plus a silence —
       * the actuator has to decide and act indivisibly, or a cue arriving
       * between the two would be swallowed (#18).
       *
       * Nothing playing, so the same button walks the candidates (issue
       * #154's operator requirement) and reports where it landed. */
      if (!cue_actuator_acknowledge()) {
        uint8_t next = cue_actuator_next_pattern();
        cue_actuator_indicate(CUE_RGB_WHITE_DIM, (uint8_t)(next + 1u));
      }
      break;
    case CUE_BUTTON_A_LONG:
      /* Bench/bike test cue: the actuator only, never the kernel — the
       * on-target analog of the phone's debug test cue (RFC 0006 D3). */
      (void)cue_actuator_fire((uint8_t)CUE_PATTERN_SELECTED);
      break;
    case CUE_BUTTON_B_SHORT: {
      uint16_t mv;
      cue_power_sample(&mv, NULL);
      uint8_t level = cue_power_level(mv);
      cue_actuator_indicate(k_battery_rgb[level], level == 0u ? 1u : level);
      break;
    }
    case CUE_BUTTON_EVENT_NONE:
    default:
      break;
  }
}

int main(void) {
  stdio_init_all();
  cue_usb_replay_init();
  cue_power_init();
  cue_buttons_init();
  /* A missing PIO state machine costs the LEDs, not the buzzer — a cue
   * you can hear but not see still beats no cue. */
  (void)cue_actuator_init();
  /* A radio failure is not fatal either: the replay port is the Phase A
   * certification path and must keep working regardless. cue_ble_init
   * tells cue_power whether the driver came up — power sensing is radio
   * transactions all the way down, and taking an uninitialised cyw43
   * mutex would wedge precisely the loop this tolerance exists to
   * protect. */
  (void)cue_ble_init();

  for (;;) {
    cue_usb_replay_poll();
    cue_ble_poll();
    cue_actuator_poll();

    CueButtonEvent events[CUE_BUTTON_MAX_EVENTS];
    uint8_t count = cue_buttons_poll(events, (uint8_t)CUE_BUTTON_MAX_EVENTS);
    for (uint8_t i = 0; i < count; i++) {
      handle_button(events[i]);
    }

    tight_loop_contents();
  }
}
