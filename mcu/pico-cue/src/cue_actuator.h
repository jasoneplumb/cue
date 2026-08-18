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
 *          Entry points are reached from two execution contexts — the
 *          main loop, and the BTstack ATT callbacks, which pico-sdk
 *          dispatches from a low-priority IRQ that preempts main(). Every
 *          one of them therefore takes the cyw43 async_context lock; see
 *          the header block of cue_actuator.c for why, and issue #18 for
 *          what tears without it. Callers need do nothing, EXCEPT call
 *          cue_actuator_set_lock_available() once (below).
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
 * but not see beats no cue at all.
 *
 * Runs before cyw43_arch_init(), so it does not lock — see
 * cue_actuator_set_lock_available(). */
bool cue_actuator_init(void);

/* Tell the actuator that cyw43_arch_init() has succeeded, so its lock may
 * now be taken.
 *
 * Two things become true at that instant and this is both of them: the
 * async_context exists (before it, `cyw43_thread_enter()` dereferences a
 * NULL context and faults), and the BTstack IRQ that can preempt this
 * module's state exists. main() deliberately keeps running when
 * cue_ble_init() fails — the wired replay port is the Phase A
 * certification path — so locking unconditionally would wedge precisely
 * the loop that tolerance protects. The mirror of cue_power.c's
 * `radio_available`, and told from the same place for the same reason:
 * one fact, one owner.
 *
 * One-way and takes no argument deliberately: the lock helpers test the
 * flag independently on acquire and on release, so a flag that could go
 * back to false would acquire the mutex and then skip releasing it. There
 * is no legitimate caller for that, and no parameter to pass it. */
void cue_actuator_set_lock_available(void);

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

/* Stop whatever is playing right now. The rider has clearly received the
 * cue, so continuing to buzz is noise.
 *
 * To acknowledge a cue, use cue_actuator_acknowledge() instead — this
 * silences unconditionally, including a cue that arrived microseconds
 * ago. */
void cue_actuator_silence(void);

/* Stop a cue IF one is playing, and report whether there was one.
 *
 * Button A's acknowledge, and one call rather than a query followed by
 * cue_actuator_silence() because the two have to be indivisible: the ATT
 * callbacks that start cues preempt the main loop, so a HEAD_UP landing
 * between a check and a silence would be stopped by a press that was
 * answering the cue before it — a cue this device decided to deliver and
 * then swallowed, with nothing downstream able to tell (NFR-001).
 *
 * A false return means nothing was playing, which is the caller's cue to
 * treat the press as meaning something else. */
bool cue_actuator_acknowledge(void);

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
