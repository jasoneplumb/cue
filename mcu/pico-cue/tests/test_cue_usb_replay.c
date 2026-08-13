/*
 * Intent: Host-side test driver for the USB-CDC replay line protocol —
 *         the reproducible anchor behind the Phase A2 "protocol logic is
 *         host-testable" claim, and the host twin the Phase A3 hiltest
 *         builds on. Exercises cue_usb_replay_handle_line (pure, no I/O)
 *         plus the cue_wire codec's D3 zeroing invariant.
 * Build (from the repo root; wired into make -C mcu in Phase A3):
 *   cc -std=c11 -Wall -Wextra -Werror -I kernel -I mcu/shared \
 *      -I mcu/pico-cue/src mcu/pico-cue/src/cue_usb_replay.c \
 *      kernel/cue_policy.c mcu/pico-cue/tests/test_cue_usb_replay.c \
 *      -o build/test_cue_usb_replay && ./build/test_cue_usb_replay
 */
#include <stdio.h>
#include <string.h>

#include "cue_usb_replay.h"
#include "cue_wire.h"

static int failures;

static void expect(const char *line, const char *want) {
  char out[CUE_USB_REPLAY_RESPONSE_MAX];
  cue_usb_replay_handle_line(line, out, sizeof(out));
  if (strcmp(out, want) != 0) {
    printf("FAIL: %s\n  want: %s\n  got:  %s\n", line, want, out);
    failures++;
  }
}

/* RFC 0006 D3: the codec itself must zero lat/lon/heading on the wire,
 * regardless of what the caller passes (review, PR #150 finding 1). */
static void check_pack_sample_zeroes_location(void) {
  RideSample s = {1000u, 455201234, -1226751234, 500u, 1234u, 42u};
  uint8_t wire[CUE_WIRE_SAMPLE_SIZE];
  cue_wire_pack_sample(wire, &s);
  RideSample back;
  cue_wire_unpack_sample(wire, &back);
  if (back.lat_e7 != 0 || back.lon_e7 != 0 || back.heading_deg_x10 != 0) {
    printf("FAIL: pack_sample leaked location fields\n");
    failures++;
  }
  if (back.t_ms != s.t_ms || back.speed_cmps != s.speed_cmps ||
      back.segment_id != s.segment_id) {
    printf("FAIL: pack_sample corrupted kernel-observable fields\n");
    failures++;
  }
}

int main(void) {
  cue_usb_replay_init();
  /* Spelled out rather than built from CUE_WIRE_PROTO_VERSION: this is
   * the string a host tool parses, so pinning it as a literal is what
   * makes a version bump show up here as a decision to confirm instead of
   * silently following along. */
  expect("PING", "PONG proto=2 fw=0.1.0 state_size=420");
  expect("CFG 128,128,5,15,15,75,4", "OK");
  /* 5 m/s toward a zone 50 m out -> tte 10 s, inside [5,15]: cue. */
  expect("STEP 1000,500,0,42,1;E 7,1,42,200,200,1,50,120",
         "DEC 1,7,0,10");
  /* Same event two seconds later: FR-004 one-cue-per-event. lead_time_s
   * is still reported (8 s) — the gate order computes it before the
   * already-cued check. */
  expect("STEP 3000,500,0,42,1;E 7,1,42,200,200,1,40,110",
         "DEC 0,7,8,8");
  expect("RESET", "OK");
  /* After reset the ride state is fresh; the same approach cues again. */
  expect("STEP 1000,500,0,42,1;E 7,1,42,200,200,1,50,120",
         "DEC 1,7,0,10");
  /* Memory suppress on the event's segment raises the severity bar. */
  expect("RESET", "OK");
  expect("STEP 1000,500,0,42,1;E 7,1,42,200,200,1,50,120;M 42,2,0",
         "DEC 0,7,11,-1");
  /* No events. */
  expect("STEP 5000,500,0,0,0", "DEC 0,0,1,-1");
  /* Heading is accepted up to 359.9 deg x10 and discarded (D3); the same
   * step with in-range heading decides identically to heading 0. */
  expect("RESET", "OK");
  expect("STEP 1000,500,3599,42,1;E 7,1,42,200,200,1,50,120",
         "DEC 1,7,0,10");
  /* Malformed inputs fail loudly. */
  expect("STEP 1000,500,3600,42,0", "ERR malformed STEP header");
  expect("STEP 1000,500,0,42,1", "ERR expected event section");
  expect("STEP 1000,500,0,42,17;E 1,1,1,1,1,1,1,1",
         "ERR malformed STEP header");
  expect("CFG 256,128,5,15,15,75,4", "ERR malformed CFG");
  expect("BOGUS", "ERR unknown command");
  expect("", "ERR empty line");
  check_pack_sample_zeroes_location();
  printf(failures ? "FAILURES: %d\n" : "cue_usb_replay: all tests passed\n",
         failures);
  return failures ? 1 : 0;
}
