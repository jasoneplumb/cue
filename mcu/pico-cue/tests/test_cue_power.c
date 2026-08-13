/*
 * Intent: Pin cue_power_level's buckets, especially the plausibility
 *         floor that decides whether the rider is told "low battery" or
 *         "unknown".
 * Context: #165. On this carrier VSYS is unpowered whenever USB is out,
 *          so the reading on every battery-powered ride is ~100 mV. Before
 *          the floor, that bucketed as 1 (low) and button B flashed RED
 *          all ride on a perfectly healthy board — a lie the rider acts
 *          on. The reading itself needs hardware; this judgement does not,
 *          so it is asserted here rather than on a bike.
 */
#include <stdio.h>

#include "cue_power.h"

static int failures;

static void check_level(uint16_t mv, uint8_t want, const char *what) {
  uint8_t got = cue_power_level(mv);
  if (got != want) {
    printf("FAIL %s: cue_power_level(%u) = %u, want %u\n", what,
           (unsigned)mv, (unsigned)got, (unsigned)want);
    failures++;
  }
}

int main(void) {
  /* 0 is the firmware's "not sampled", and must not read as a flat cell. */
  check_level(0u, 0u, "not sampled");

  /* Below what the board can run on: the sensor is not seeing the supply,
   * which is a different claim from "the battery is low". These are the
   * values actually measured on battery (#165). */
  check_level(103u, 0u, "measured on battery, corrected read");
  check_level(836u, 0u, "measured on battery, original read");
  check_level(1799u, 0u, "just below the plausibility floor");

  /* At and above the floor the buckets mean what they say. */
  check_level(1800u, 1u, "floor itself is a real, low reading");
  check_level(3699u, 1u, "just below usable");
  check_level(3700u, 2u, "usable boundary");
  check_level(4199u, 2u, "just below healthy");
  check_level(4200u, 3u, "healthy boundary");
  check_level(5037u, 3u, "measured on USB");

  /* The LED table is indexed by this value, so a bucket outside 0..3
   * would read past its end. */
  for (uint32_t mv = 0u; mv <= 0xFFFFu; mv += 7u) {
    if (cue_power_level((uint16_t)mv) > 3u) {
      printf("FAIL: cue_power_level(%u) is outside 0..3\n", (unsigned)mv);
      failures++;
      break;
    }
  }

  printf(failures ? "FAILURES: %d\n" : "cue_power: all tests passed\n",
         failures);
  return failures ? 1 : 0;
}
