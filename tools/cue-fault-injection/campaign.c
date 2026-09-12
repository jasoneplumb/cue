/* Intent: Measure session fault behavior using production C, without hardware.
 * Context: RFC 0006 sequencing and the phone/MCU decision-equivalence boundary.
 * Pattern: Fixed synthetic inputs, independent shadow state, asserted outcomes.
 * Future: Repeat on hardware and exercise the Swift receiver separately.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "cue_session.h"

static CueSession device;
static CueDecision expected[5];
static unsigned reports, mismatches, requests, rejected;
static uint16_t ack_size;

static void require(int ok, const char *message) {
  if (!ok) { fprintf(stderr, "FAILED: %s\n", message); exit(1); }
}

static RideSample sample(unsigned i) {
  RideSample s = {(i + 1u) * 1000u, 0, 0, 500, 0, 42};
  return s;
}

static RouteEvent event(unsigned i) {
  const int16_t distances[] = {150, 100, 95, 90, 85};
  RouteEvent e = {7, CUE_EVENT_FAMILY_COMPOSITE_SQUEEZE_ZONE, 42,
                  200, 200, 1, distances[i], (int16_t)(distances[i] + 70)};
  return e;
}

static void start(void) {
  uint8_t in[CUE_CTRL_SESSION_START_SIZE], out[CUE_CTRL_MAX_RESPONSE_SIZE];
  size_t len;
  CueTestCueRequest cue;
  CuePolicyConfig cfg;
  cue_policy_default_config(&cfg);
  cfg.max_notice_s = 20;
  in[0] = CUE_CTRL_SESSION_START;
  in[1] = CUE_WIRE_PROTO_VERSION;
  cue_wire_put_u32(in + 2, 0x1234);
  cue_wire_pack_config(in + 6, &cfg);
  require(cue_session_handle_control(&device, in, sizeof(in), out, sizeof(out),
                                     &len, &cue) == CUE_SESSION_OK, "start");
  require(len == CUE_CTRL_SESSION_ACK_SIZE && out[1] == CUE_CTRL_STATUS_OK,
          "start ack");
  ack_size = cue_wire_get_u16(out + 4);
}

static void begin(void) {
  memset(&device, 0, sizeof(device));
  cue_session_init(&device);
  start();
  reports = mismatches = requests = rejected = 0;
  CuePolicyConfig cfg;
  cue_policy_default_config(&cfg);
  cfg.max_notice_s = 20;
  CuePolicyState shadow;
  cue_policy_init(&shadow, &cfg);
  for (unsigned i = 0; i < 5; i++) {
    RideSample s = sample(i);
    RouteEvent e = event(i);
    expected[i] = cue_policy_step(&shadow, &s, &e, 1, NULL);
  }
  require(expected[1].type == CUE_HEAD_UP && expected[2].type == CUE_NONE,
          "fixture has one cue at step two");
}

static size_t pack(uint8_t *in, unsigned i, uint8_t flags) {
  cue_wire_put_u16(in, (uint16_t)(i + 1));
  in[2] = flags;
  in[3] = 1;
  RideSample s = sample(i);
  RouteEvent e = event(i);
  cue_wire_pack_sample(in + CUE_WIRE_STEP_HEADER_SIZE, &s);
  cue_wire_pack_event(in + CUE_WIRE_STEP_HEADER_SIZE + CUE_WIRE_SAMPLE_SIZE, &e);
  return CUE_WIRE_STEP_HEADER_SIZE + CUE_WIRE_SAMPLE_SIZE + CUE_WIRE_EVENT_SIZE;
}

/* This is an experiment comparator, not the production Swift receiver.
 * Compare logical fields, not C padding. Identity is checked separately. */
static int equal(const CueDecision *a, const CueDecision *b) {
  return a->type == b->type && a->event_id == b->event_id &&
         a->reason_code == b->reason_code && a->lead_time_s == b->lead_time_s;
}

static CueSessionStatus send_step(unsigned i, uint8_t flags, int truncate,
                                  int lose_report) {
  uint8_t in[CUE_WIRE_STEP_MAX_SIZE], out[CUE_WIRE_DECISION_REPORT_SIZE];
  size_t len = pack(in, i, flags), out_len;
  bool actuate;
  CueSession before;
  memcpy(&before, &device, sizeof(before));
  CueSessionStatus status = cue_session_handle_step(
      &device, in, len - (truncate ? 1u : 0u), out, sizeof(out), &out_len, &actuate);
  requests += actuate ? 1u : 0u;
  if (status != CUE_SESSION_OK) {
    rejected++;
    require(!actuate && out_len == 0, "rejected frame emits nothing");
    require(memcmp(&before, &device, sizeof(device)) == 0,
            "rejected frame preserves session state");
  } else {
    require(out_len == sizeof(out), "accepted step has report");
    if (!lose_report) {
      require(cue_wire_get_u16(out) == i + 1 &&
              cue_wire_get_u32(out + 2) == sample(i).t_ms, "report identity");
      CueDecision d;
      cue_wire_unpack_decision(out + 6, &d);
      reports++;
      mismatches += equal(&d, &expected[i]) ? 0u : 1u;
    }
  }
  return status;
}

static void ok(unsigned i, uint8_t flags) {
  require(send_step(i, flags, 0, 0) == CUE_SESSION_OK, "accepted step");
}

static void row(const char *name, unsigned r, unsigned m, unsigned a, unsigned n,
                const char *outcome) {
  require(rejected == r && mismatches == m && requests == a && reports == n,
          name);
  printf("{\"scenario\":\"%s\",\"rejected_frames\":%u,"
         "\"decision_mismatches\":%u,\"actuation_requests\":%u,"
         "\"compared_reports\":%u,\"state_size\":%u,"
         "\"outcome\":\"%s\",\"expectations_met\":true}\n",
         name, rejected, mismatches, requests, reports, ack_size, outcome);
}

int main(int argc, char **argv) {
  if (argc == 2 && strcmp(argv[1], "mutant") == 0) {
    begin();
    /* Candidate binary changes only the maximum-notice comparison by 1 s.
     * At 21 s, the baseline says TOO_EARLY while the mutant requests a cue. */
    RideSample s = sample(0);
    RouteEvent e = event(0);
    e.distance_to_start_m = 105;
    CuePolicyState shadow;
    cue_policy_init(&shadow, NULL);
    CueDecision d = cue_policy_step(&shadow, &s, &e, 1, NULL);
    uint8_t in[CUE_WIRE_STEP_MAX_SIZE], out[CUE_WIRE_DECISION_REPORT_SIZE];
    size_t len = pack(in, 0, 0), out_len;
    cue_wire_pack_event(in + CUE_WIRE_STEP_HEADER_SIZE + CUE_WIRE_SAMPLE_SIZE, &e);
    bool actuate;
    require(ack_size == sizeof(CuePolicyState), "same-size drift passes size check");
    require(cue_session_handle_step(&device, in, len, out, sizeof(out), &out_len,
                                   &actuate) == CUE_SESSION_OK, "mutant step");
    require(out_len == sizeof(out), "mutant report size");
    CueDecision actual;
    cue_wire_unpack_decision(out + 6, &actual);
    require(d.type == CUE_NONE && actual.type == CUE_HEAD_UP, "mutant behavior");
    reports = 1; mismatches = !equal(&d, &actual); requests = actuate;
    row("same_size_kernel_drift", 0, 1, 1, 1, "mismatch_after_actuation_request");
    return 0;
  }
  require(argc == 1, "usage: campaign [mutant]");
  begin();
  for (unsigned i = 0; i < 5; i++) ok(i, 0);
  row("clean_control", 0, 0, 1, 5, "agreement");

  begin(); ok(0, 0);
  /* Step 2 never arrives; step 3 reveals the hole one subsequent write later. */
  require(send_step(2, 0, 0, 0) == CUE_SESSION_ERR_SEQ_GAP, "dropped step gap");
  ok(1, CUE_WIRE_STEP_FLAG_CATCHUP);
  for (unsigned i = 2; i < 5; i++) ok(i, 0);
  row("dropped_middle_step", 1, 0, 0, 5, "recovered_without_stale_actuation");

  begin(); ok(0, 0); ok(1, 0);
  uint8_t cached[CUE_WIRE_DECISION_REPORT_SIZE];
  memcpy(cached, device.last_report, sizeof(cached));
  ok(1, 0);
  require(memcmp(cached, device.last_report, sizeof(cached)) == 0,
          "duplicate step returns identical cached report");
  for (unsigned i = 2; i < 5; i++) ok(i, 0);
  row("duplicate_step", 0, 0, 1, 6, "cached_report_no_repeat_actuation");

  begin(); ok(0, 0);
  require(send_step(2, 0, 0, 0) == CUE_SESSION_ERR_SEQ_GAP, "reordering");
  for (unsigned i = 1; i < 5; i++) ok(i, 0);
  row("reordered_steps", 1, 0, 1, 5, "recovered_in_order");

  begin(); ok(0, 0); ok(1, 0);
  cue_session_init(&device);
  require(send_step(2, 0, 0, 0) == CUE_SESSION_ERR_STATE, "reset detected");
  uint8_t resume[CUE_CTRL_SESSION_RESUME_SIZE], ack[CUE_CTRL_MAX_RESPONSE_SIZE];
  size_t ack_len;
  CueTestCueRequest cue;
  resume[0] = CUE_CTRL_SESSION_RESUME;
  cue_wire_put_u32(resume + 1, 0x1234); cue_wire_put_u16(resume + 5, 2);
  require(cue_session_handle_control(&device, resume, sizeof(resume), ack,
                                     sizeof(ack), &ack_len, &cue) == CUE_SESSION_OK,
          "resume response");
  require(ack_len == CUE_CTRL_RESUME_ACK_SIZE && ack[1] == CUE_CTRL_STATUS_NOT_RIDING,
          "reset requires full restream");
  start();
  ok(0, CUE_WIRE_STEP_FLAG_CATCHUP); ok(1, CUE_WIRE_STEP_FLAG_CATCHUP);
  for (unsigned i = 2; i < 5; i++) ok(i, 0);
  row("reset_full_restream", 1, 0, 1, 7, "recovered_without_repeat_actuation");

  begin(); ok(0, 0);
  require(send_step(1, 0, 1, 0) == CUE_SESSION_ERR_LENGTH, "truncation");
  for (unsigned i = 1; i < 5; i++) ok(i, 0);
  row("truncated_frame", 1, 0, 1, 5, "rejected_then_recovered");

  begin(); ok(0, 0);
  require(send_step(1, 0x80, 0, 0) == CUE_SESSION_ERR_FLAGS, "unknown flags");
  for (unsigned i = 1; i < 5; i++) ok(i, 0);
  row("unknown_flags", 1, 0, 1, 5, "rejected_then_recovered");

  begin();
  for (unsigned i = 1; i < 5; i++) ok(i, 0);
  row("dropped_first_noncue_step", 0, 0, 1, 4, "not_detected_by_session_or_decision_comparison");

  begin();
  for (unsigned i = 0; i < 4; i++) ok(i, 0);
  require(send_step(4, 0, 0, 1) == CUE_SESSION_OK, "lost final report");
  row("lost_final_report", 0, 0, 1, 4, "comparison_coverage_incomplete");
  return 0;
}
