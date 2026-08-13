/*
 * Intent: Read VSYS so the STATUS characteristic can report supply
 *         millivolts and button B can flash a battery level.
 * Context: RFC 0006 D5 makes "battery survives each ride" a validation
 *          gate metric, and issue #154 puts the reading behind button B.
 * Pattern: The hardware reads are target-only (PICO_BUILD). On a Pico W
 *          they are not plain ADC reads — see the implementation for why
 *          they borrow a pin from the radio and give it back.
 *          `cue_power_level` is deliberately OUTSIDE that guard: it is
 *          pure arithmetic, it is the part that decides what the rider is
 *          told, and it is the part that was wrong (#165), so it belongs
 *          where `make -C mcu test` can pin it without hardware.
 */
#ifndef CUE_POWER_H
#define CUE_POWER_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Coarse level buckets, for a channel with no display: 3 = healthy,
 * 2 = usable, 1 = low, 0 = unknown. Readings the board could not be
 * running on bucket as unknown, not low — see the implementation. */
uint8_t cue_power_level(uint16_t mv);

#ifdef PICO_BUILD

void cue_power_init(void);

/* Tell this module whether the CYW43 came up.
 *
 * Both reads below are radio transactions — VSYS's divider tap is the
 * CYW43's SPI clock, and VBUS presence is one of its GPIOs — so both take
 * the cyw43 lock. main() treats a radio failure as non-fatal on purpose
 * (the USB replay port is the D6 certification path and must keep
 * working), and taking an uninitialised cyw43 mutex would hang exactly
 * the loop that is supposed to survive. Without this flag, `DIAG` on a
 * board whose radio failed would wedge the firmware. */
void cue_power_set_radio_available(bool available);

/* Which supply the board is on. Reported alongside every millivolt
 * reading because a supply voltage is uninterpretable without it: "5041"
 * and "836" tell you nothing until you know which was connected, and
 * mistaking one for the other is how #165 nearly amended an RFC on the
 * strength of a measurement artifact.
 *
 * UNKNOWN is a real answer, not a placeholder — with no radio there is no
 * way to ask, and saying "USB" would be a guess landing in ride evidence. */
#define CUE_POWER_SUPPLY_UNKNOWN 0u
#define CUE_POWER_SUPPLY_USB 1u
#define CUE_POWER_SUPPLY_BATTERY 2u

/* "usb" | "battery" | "unknown", for the wired diagnostic line. Never
 * NULL, including for a value outside the set. */
const char *cue_power_supply_name(uint8_t supply);

/* Read VSYS millivolts and the supply as ONE snapshot. Either pointer
 * may be NULL. Yields 0 / UNKNOWN when the radio is unavailable.
 *
 * Both come back from a single call because a voltage without the supply
 * it was measured against is not evidence, and two calls could straddle a
 * cable being pulled and pair a battery voltage with a USB label. The
 * VBUS read is also free here: waking the CYW43 to borrow its pin is
 * already a VBUS read.
 *
 * The millivolts are NOT a charge gauge. On a WuKong 2040 this reads
 * ~5040 mV on USB and ~100 mV on battery, because the board powers the
 * Pico through 3V3 and leaves VSYS unpowered — it says whether USB is
 * present, nothing about the 18650 (#165; the measurement is in the .c).
 * 0 mV is reported rather than a fabricated voltage: an invented number
 * would land in a validation ride's evidence and be believed. */
void cue_power_sample(uint16_t *mv_out, uint8_t *supply_out);

#endif /* PICO_BUILD */

#ifdef __cplusplus
}
#endif

#endif /* CUE_POWER_H */
