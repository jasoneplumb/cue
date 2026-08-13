/*
 * Intent: Implementation of the VSYS read (see header).
 *
 * Why this is not just adc_read(). On a Pico W, GPIO29 is shared: it is
 * both the VSYS/3 divider tap on ADC3 and the CYW43's SPI clock line.
 * Pointing it at the ADC therefore takes the pin away from the radio for
 * the duration of the sample, so this:
 *   - holds the cyw43 lock, so no SPI transaction is in flight while the
 *     pin is borrowed,
 *   - wakes the CYW43 first, because the lock serialises transactions but
 *     does not wake a sleeping chip, and a parked SPI clock line is what
 *     the ADC samples instead of the divider,
 *   - discards the first conversions after the mux switch, and
 *   - restores GPIO29's previous function afterwards.
 * Skipping the restore leaves the radio with a dead clock line, which
 * presents as BLE dying moments after the first battery read — a
 * "firmware bug" whose cause is three files away.
 *
 * The sequence mirrors the pico-sdk reference (pico-examples
 * adc/read_vsys/power_status.c), deliberately and in full. This file
 * originally kept the shape but not the substance — one discarded
 * one-shot conversion where the reference drains a FIFO of three, and no
 * wake at all — and read ~5x low off USB as a result: 836 mV on a board
 * that cannot run below ~1.8 V (#165). A number that low is not a supply
 * voltage, it is a measurement artifact, and it was about to be believed
 * as validation evidence.
 */
#include "cue_power.h"

#ifdef PICO_BUILD

#include "hardware/adc.h"
#include "hardware/gpio.h"
#include "pico/cyw43_arch.h"
#include "pico/stdlib.h"

#include <stddef.h>

#ifndef PICO_VSYS_PIN
#define PICO_VSYS_PIN 29
#endif
#ifndef PICO_FIRST_ADC_PIN
#define PICO_FIRST_ADC_PIN 26
#endif

/* VSYS is divided by 3 on the board; the ADC is 12-bit against 3.3 V. */
#define CUE_ADC_REF_MV 3300u
#define CUE_ADC_RANGE 4096u
#define CUE_VSYS_DIVIDER 3u

/* Samples averaged, and samples discarded before them. Both from the
 * reference, whose comment on the discard is "We seem to read low values
 * initially - this seems to fix it". */
#define CUE_VSYS_SAMPLES 3u

/* Total budget for one VSYS read. Conversions land every ~2 us and the
 * read needs about seven of them, so this is two orders of magnitude of
 * headroom — it is a stall detector, not a rate limit. */
#define CUE_VSYS_READ_TIMEOUT_US 2000u

/* Bounded replacement for adc_fifo_get_blocking().
 *
 * The pico-sdk reference blocks forever, and is right to: it runs from a
 * demo's main(). This runs in the loop that has to fire a cue on time, and
 * an ADC that stopped converting would stop that loop — the rider's
 * symptom would be cues silently ceasing while the radio stayed connected
 * and nothing was logged. Defensive: no such stall has been observed, and
 * the ADC has no other user in this firmware to be disturbed by. */
static bool fifo_get(absolute_time_t deadline, uint16_t *out) {
  while (adc_fifo_is_empty()) {
    if (time_reached(deadline)) {
      return false;
    }
  }
  *out = (uint16_t)adc_fifo_get();
  return true;
}

static bool initialised;
/* Defaults to false so a caller that runs before main() has resolved the
 * radio gets "unknown" rather than a hang. */
static bool radio_available;

void cue_power_init(void) {
  if (!initialised) {
    adc_init();
    initialised = true;
  }
}

void cue_power_set_radio_available(bool available) {
  radio_available = available;
}

void cue_power_sample(uint16_t *mv_out, uint8_t *supply_out) {
  if (!initialised || !radio_available) {
    if (mv_out != NULL) {
      *mv_out = 0u;
    }
    if (supply_out != NULL) {
      *supply_out = (uint8_t)CUE_POWER_SUPPLY_UNKNOWN;
    }
    return;
  }

  cyw43_thread_enter();

  /* Wake the radio before borrowing its pin: a sleeping CYW43 parks the
   * shared line, and the ADC then measures that instead of the divider.
   * The lock does not do this — it serialises transactions, it does not
   * wake the chip.
   *
   * The wake call IS the VBUS read, so the supply costs nothing extra and
   * — the reason this function returns both — is sampled inside the same
   * locked region as the voltage. Two separate calls could straddle a
   * cable being pulled and pair a battery voltage with a USB label, which
   * is the exact mislabelling the supply field exists to prevent. Here
   * that pairing is structural rather than something each caller has to
   * remember. */
  bool vbus = cyw43_arch_gpio_get(CYW43_WL_GPIO_VBUS_PIN);

  gpio_function_t saved = gpio_get_function(PICO_VSYS_PIN);

  adc_gpio_init(PICO_VSYS_PIN);
  adc_select_input(PICO_VSYS_PIN - PICO_FIRST_ADC_PIN);

  /* Free-running into the FIFO rather than one-shot conversions: the
   * settling samples after a mux switch have to be drained, not merely
   * counted, and the FIFO is what the reference drains. At ~2 us per
   * conversion the whole read is tens of microseconds, which is why it
   * is safe to call from the same loop that services cues. */
  adc_fifo_setup(true, false, 0, false, false);
  adc_run(true);

  /* The || short-circuits on purpose, and this is the reference's idiom
   * verbatim: while the FIFO has entries the counter is NOT decremented,
   * so the loop first empties whatever the mux switch queued and only
   * then discards CUE_VSYS_SAMPLES further conversions. A plain for-loop
   * of three would skip the drain, which is the half that fixes the low
   * reading. Termination is not in question: a free-running ADC produces
   * a sample every ~2 us while the CPU empties the 4-entry FIFO orders of
   * magnitude faster, so it always goes empty. */
  absolute_time_t deadline = make_timeout_time_us(CUE_VSYS_READ_TIMEOUT_US);
  bool complete = true;

  int ignore = (int)CUE_VSYS_SAMPLES;
  while (complete && (!adc_fifo_is_empty() || ignore-- > 0)) {
    uint16_t discard;
    complete = fifo_get(deadline, &discard);
  }

  uint32_t sum = 0u;
  for (uint32_t i = 0; complete && i < CUE_VSYS_SAMPLES; i++) {
    uint16_t value = 0u;
    complete = fifo_get(deadline, &value);
    if (complete) {
      sum += value;
    }
  }

  adc_run(false);
  adc_fifo_drain();

  gpio_set_function(PICO_VSYS_PIN, saved);

  cyw43_thread_exit();

  if (mv_out != NULL) {
    /* A timed-out read reports 0 — "not sampled" — rather than an average
     * over however many samples did arrive. Every consumer already treats
     * 0 honestly: the phone maps it to nil, cue_power_level buckets it as
     * unknown, and the sidecar drops it. The supply below is unaffected;
     * it was read before the ADC and is still true. */
    if (!complete) {
      *mv_out = 0u;
    } else {
      uint32_t raw = sum / CUE_VSYS_SAMPLES;
      uint32_t mv = raw * CUE_VSYS_DIVIDER * CUE_ADC_REF_MV / CUE_ADC_RANGE;
      *mv_out = (uint16_t)(mv > 0xFFFFu ? 0xFFFFu : mv);
    }
  }
  if (supply_out != NULL) {
    *supply_out =
        (uint8_t)(vbus ? CUE_POWER_SUPPLY_USB : CUE_POWER_SUPPLY_BATTERY);
  }
}

const char *cue_power_supply_name(uint8_t supply) {
  switch (supply) {
    case CUE_POWER_SUPPLY_USB:
      return "usb";
    case CUE_POWER_SUPPLY_BATTERY:
      return "battery";
    default:
      return "unknown";
  }
}

#endif /* PICO_BUILD */

/* --- Level bucketing (host-testable; no pico-sdk below this line) -------
 *
 * Outside the PICO_BUILD guard deliberately. This is the part that
 * decides what the rider is told, it is the part that was wrong, and it
 * needs no hardware to be wrong in — so `make -C mcu test` pins it.
 */

/* MEASURED 2026-08-01 (#165), which settles the bench note this block
 * used to carry: VSYS does NOT track the 18650 on a WuKong 2040.
 *
 *   supply=usb      5037 mV
 *   supply=battery   103 mV   (with the corrected read above; the older
 *                              read said 836 mV, equally meaningless)
 *
 * The board runs BLE happily at both, and a Pico W cannot run below
 * ~1.8 V on VSYS, so 103 mV is not the voltage powering it. The WuKong
 * feeds the Pico's 3V3 pin and leaves VSYS unpowered — floating at
 * leakage potential — whenever USB is out. There is no firmware change
 * that makes this pin see the cell; a real charge gauge needs the cell
 * brought to a free ADC pin (GP26–28) through a divider.
 *
 * So the thresholds below are retained only for the USB case, and the
 * plausibility floor is what does the real work: it is the difference
 * between "low battery" and "this sensor is not measuring the supply".
 */
#define CUE_VSYS_HEALTHY_MV 4200u
#define CUE_VSYS_USABLE_MV 3700u

/* A Pico W's regulator gives out around 1.8 V, so firmware that is
 * running and reporting a value below that is reporting a node it is not
 * powered by. Bucketing that as "low" is a lie the rider acts on — before
 * this floor, button B flashed RED on every battery-powered ride while
 * the board was perfectly healthy. Unknown (magenta) is the honest
 * answer, and it is the answer the LED table already had a colour for. */
#define CUE_VSYS_IMPLAUSIBLE_MV 1800u

uint8_t cue_power_level(uint16_t mv) {
  if (mv == 0u || mv < CUE_VSYS_IMPLAUSIBLE_MV) {
    return 0u;
  }
  if (mv >= CUE_VSYS_HEALTHY_MV) {
    return 3u;
  }
  if (mv >= CUE_VSYS_USABLE_MV) {
    return 2u;
  }
  return 1u;
}
