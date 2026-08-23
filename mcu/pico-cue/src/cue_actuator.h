/*
 * Intent: The thing that finally makes a cue perceptible — buzzer (GP9,
 *         PWM) and the two WS2812B LEDs (GP22, PIO) on the WuKong 2040.
 *         Plays the candidate renderings in cue_pattern.h, and shows the
 *         link/session state on the LEDs when no cue is playing.
 * Context: RFC 0006 D7, issue #154. Both prior delivery channels (the
 *          RFC 0004 watch haptic, the RFC 0005 chime) failed on
 *          perceptibility; this is the channel that replaces them, so
 *          "which rendering does the rider actually notice" is decided by
 *          comparison on the bike, not by a constant in a header.
 * Pattern: Target-only (PICO_BUILD), non-blocking. Every entry point
 *          returns immediately and `cue_actuator_poll()` advances the
 *          rendering from the main loop — a busy-wait would stall
 *          BTstack's radio work for the pattern's whole duration, which
 *          at 1.6 s is sixteen missed step writes.
 *
 *          The timing and §12 non-escalation rules live in cue_pattern.c,
 *          which is pure and host-tested. This file owns only hardware
 *          and priority: cue > indication > status.
 */
#ifndef CUE_ACTUATOR_H
#define CUE_ACTUATOR_H

#ifdef PICO_BUILD

#include <stdbool.h>
#include <stdint.h>

#include "cue_pattern.h"

#ifdef __cplusplus
extern "C" {
#endif

/* What the LEDs show when no cue and no indication is playing. Extends
 * the LED vocabulary of docs/mcu-replay-demo-readme.md (green = none,
 * blue = HEAD_UP, red = divergence/error) to the link states this device
 * has and that one did not. */
typedef enum {
  CUE_ACT_STATUS_ADVERTISING = 0, /* yellow blink — waiting for the phone   */
  CUE_ACT_STATUS_CONNECTED = 1,   /* green breathing — linked and/or riding */
  CUE_ACT_STATUS_ERROR = 2,       /* red — firmware-local fault             */
} CueActuatorStatus;

/* Claim GP9's PWM slice and a PIO1 state machine for GP22, and start in
 * ADVERTISING. Returns false if no PIO resource was available, in which
 * case the buzzer still works and the LEDs stay dark — a cue you can hear
 * but not see beats no cue at all. */
bool cue_actuator_init(void);

/* Advance the rendering. Call every main-loop iteration; it does nothing
 * but read a clock when nothing is playing. */
void cue_actuator_poll(void);

/* Start `pattern`, or the selected candidate when `pattern` is
 * CUE_PATTERN_SELECTED. Returns the index actually started, or
 * CUE_PATTERN_SELECTED if the index was invalid and nothing was played.
 *
 * Restarting while a pattern is already playing is deliberate and
 * bounded: it replaces the rendering in flight rather than queueing or
 * extending one, so the actuator can never sound for longer than a single
 * pattern's declared duration (spec §12). */
uint8_t cue_actuator_fire(uint8_t pattern);

/* Stop whatever is playing right now — button A's acknowledge. The rider
 * has clearly received the cue, so continuing to buzz is noise. */
void cue_actuator_silence(void);

bool cue_actuator_is_active(void);

/* Runtime candidate selection (the operator requirement on issue #154):
 * several patterns, comparable back-to-back without reflashing. */
uint8_t cue_actuator_selected(void);
void cue_actuator_select(uint8_t pattern);
/* Advance to the next candidate, wrapping. Returns the new index. */
uint8_t cue_actuator_next_pattern(void);

/* Blink the LEDs `count` times in `rgb` — how the board answers a
 * question without a screen (which pattern is selected, how much battery
 * is left). Silent by construction: an indication must never be
 * mistakable for a cue. Ignored while a cue is playing. */
void cue_actuator_indicate(uint32_t rgb, uint8_t count);

void cue_actuator_set_status(CueActuatorStatus status);

/* --- bench bring-up (wired port only, never reachable over BLE) ----------- */

/* Hold one tone for `ms`, bypassing the pattern table entirely.
 *
 * This exists because "the piezo resonates at ~2.3 kHz" is a datasheet
 * claim about a part, not a measurement of THIS board — and the entire
 * project turns on whether the rider can hear the thing. Sweeping tones
 * and listening is how the carrier frequency in cue_pattern.c gets chosen
 * on evidence. Outranks a playing cue: a bench probe should answer
 * immediately, and nothing here can be triggered from a ride. */
void cue_actuator_tone(uint16_t hz, uint16_t ms);

/* --- drive topology (RFC 0007 D2) ---------------------------------------- */

/* How the piezo is driven. The axis RFC 0007 D2 exists to measure: a piezo is
 * voltage-driven, so doubling the swing across the element is a larger lever
 * on loudness than diaphragm area.
 *
 * SINGLE reproduces the WuKong's topology exactly — one pin swinging 0..3V3
 * against a grounded return. DIFFERENTIAL drives the second leg in antiphase
 * from the same PWM slice, so the element sees ±3V3: twice the swing, ~+6 dB,
 * for one GPIO and no boost converter.
 *
 * Runtime-switchable on purpose. #154's operator requirement was candidates
 * "comparable back-to-back without reflashing", and that applies harder here:
 * the element, its mounting, and the room are held constant while ONLY the
 * drive topology changes, which is the one-axis discipline of D7 applied to
 * the thing D7 could not vary.
 *
 * REQUIRES AN EXTERNAL ELEMENT across CUE_PIN_BUZZER and CUE_PIN_BUZZER_N.
 * The WuKong's onboard buzzer cannot be driven this way — its return is the
 * board's ground plane, so it has no second leg to drive. Selecting
 * DIFFERENTIAL with the onboard buzzer changes nothing audible, which is a
 * result that looks exactly like "differential drive does not help". Read
 * RFC 0007 D2 before running the comparison.
 */
typedef enum {
  CUE_DRIVE_SINGLE = 0,       /* one pin against ground — the WuKong topology */
  CUE_DRIVE_DIFFERENTIAL = 1, /* two pins in antiphase — needs an external element */
  /* BENCH PROBE, not a topology to ship. Drives the N leg alone with the P
   * leg parked low, to answer one question the multimeter cannot reach on
   * this board: is the onboard buzzer's second terminal connected to GP8, or
   * to the ground plane?
   *
   * Measured 2026-08-23: the buzzer is mounted with no accessible rear
   * terminal, so RFC 0007's continuity check is physically impossible here
   * and this is the substitute.
   *
   * Reading it — and the control is not optional:
   *   SINGLE audible, N_ONLY silent  -> GP8 does not reach the element.
   *                                     Consistent with a grounded return;
   *                                     differential needs an external part.
   *   SINGLE audible, N_ONLY audible -> GP8 reaches SOMETHING audible. It does
   *                                     NOT follow that it reaches the
   *                                     element — see below.
   *   SINGLE silent                  -> the rig is broken, not the theory.
   *                                     N_ONLY's result means nothing. Run
   *                                     the control FIRST, every time.
   *
   * RESULT on this bench, 2026-08-23: both audible — and yet a blind A/B put
   * differential at 3/3 "no difference" against single, with sensitivity
   * controls at 3/3 in the same session. The probe alone would have said GP8
   * drives the element. It does not. This mode answers "does driving GP8 make
   * noise", which is a WEAKER question than "does GP8 move the element", and
   * the two came apart on real hardware. Do not read a positive N_ONLY as
   * proof of connection to the buzzer.
   */
  CUE_DRIVE_N_ONLY = 2,
} CueDriveMode;

#define CUE_DRIVE_MODE_COUNT 3u

uint8_t cue_actuator_drive_mode(void);
/* Ignores an out-of-range value rather than clamping: silently substituting a
 * topology would make an A/B comparison lie about what was driven. */
void cue_actuator_set_drive_mode(uint8_t mode);
/* Advance to the next topology, wrapping. Returns the new mode. */
uint8_t cue_actuator_next_drive_mode(void);

/* Force the LEDs to `rgb` for `ms` — separates "the LED code is wrong"
 * from "the pixels or the pin are wrong" during bring-up. */
void cue_actuator_led_probe(uint32_t rgb, uint16_t ms);

/* False when no PIO state machine was available for the LEDs. */
bool cue_actuator_leds_ready(void);

#ifdef __cplusplus
}
#endif

#endif /* PICO_BUILD */

#endif /* CUE_ACTUATOR_H */
