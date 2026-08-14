/*
 * Intent: The smallest possible embedding of the cue-policy kernel — one
 *         sample, one squeeze-zone event, one decision — so a newcomer sees
 *         the whole API surface without the replay harness.
 * Context: kernel/cue_policy.h is the entire contract; embedding the kernel
 *          is copying two files. PORTING.md covers taking this to an MCU.
 * Pattern: Also a runnable assertion (exit 0/1), so `make -C examples test`
 *          keeps the example honest in CI.
 */
#include <stdio.h>

#include "cue_policy.h"

int main(void) {
  CuePolicyState state;
  cue_policy_init(&state, 0); /* NULL config = spec §8 defaults */

  /* Riding 5 m/s on segment 7 ... */
  RideSample sample = {0};
  sample.t_ms = 1000;
  sample.speed_cmps = 500;
  sample.segment_id = 7;

  /* ... with a squeeze zone starting 60 m ahead: 12 s away, inside the
   * [5, 20] s notice window, above both thresholds. */
  RouteEvent zone = {0};
  zone.event_id = 101;
  zone.family = CUE_EVENT_FAMILY_COMPOSITE_SQUEEZE_ZONE;
  zone.segment_id = 7;
  zone.severity = 200;
  zone.confidence = 220;
  zone.reasons_bitmask =
      CUE_REASON_NARROW_LANE | CUE_REASON_NO_SHOULDER_OR_BIKE_LANE;
  zone.distance_to_start_m = 60;
  zone.distance_to_end_m = 260;

  CueDecision d = cue_policy_step(&state, &sample, &zone, 1, 0);
  if (d.type != CUE_HEAD_UP) {
    fprintf(stderr, "expected HEAD_UP, got type=%u reason_code=%u\n",
            (unsigned)d.type, (unsigned)d.reason_code);
    return 1;
  }
  printf("HEAD_UP for event %u at %d s lead (window [5, 20] s)\n",
         (unsigned)d.event_id, (int)d.lead_time_s);

  /* Same event again: FR-004 — at most one cue per route event. */
  sample.t_ms = 2000;
  zone.distance_to_start_m = 55;
  d = cue_policy_step(&state, &sample, &zone, 1, 0);
  if (d.type != CUE_NONE || d.reason_code != CUE_REASON_CODE_ALREADY_CUED) {
    fprintf(stderr, "expected ALREADY_CUED suppression, got type=%u "
                    "reason_code=%u\n",
            (unsigned)d.type, (unsigned)d.reason_code);
    return 1;
  }
  printf("second approach suppressed: ALREADY_CUED (FR-004)\n");
  return 0;
}
