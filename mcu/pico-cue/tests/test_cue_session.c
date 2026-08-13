/*
 * Intent: Host test for the ride-session state machine — especially the
 *         sequencing contract (RFC 0006 D4) that keeps on-target kernel
 *         state bit-identical to the phone's shadow. A duplicate or
 *         out-of-order step that reached cue_policy_step would diverge
 *         silently, so those paths are asserted directly rather than
 *         left to hardware testing.
 * Build: see mcu/Makefile's `test` target.
 */
#include <stdio.h>
#include <string.h>

#include "cue_session.h"
#include "cue_wire.h"

static int failures;

static void check(int cond, const char *what) {
  if (!cond) {
    printf("FAIL: %s\n", what);
    failures++;
  }
}

/* --- payload builders ----------------------------------------------------- */

static size_t build_start(uint8_t *buf, uint32_t ride_hash, uint8_t proto) {
  CuePolicyConfig cfg;
  cue_policy_default_config(&cfg);
  cfg.min_speed_kmh = 4;
  buf[0] = (uint8_t)CUE_CTRL_SESSION_START;
  buf[1] = proto;
  cue_wire_put_u32(buf + 2, ride_hash);
  cue_wire_pack_config(buf + 6, &cfg);
  return CUE_CTRL_SESSION_START_SIZE;
}

static size_t build_step(uint8_t *buf, uint16_t seq, uint8_t flags,
                         uint32_t t_ms, uint16_t speed_cmps,
                         uint32_t segment_id, int has_event,
                         int16_t dist_start) {
  cue_wire_put_u16(buf + 0, seq);
  buf[2] = flags;
  buf[3] = has_event ? 1u : 0u;
  RideSample s = {t_ms, 0, 0, speed_cmps, 0, segment_id};
  cue_wire_pack_sample(buf + 4, &s);
  size_t len = CUE_WIRE_STEP_HEADER_SIZE + CUE_WIRE_SAMPLE_SIZE;
  if (has_event) {
    RouteEvent e = {7u, (uint8_t)CUE_EVENT_FAMILY_COMPOSITE_SQUEEZE_ZONE,
                    segment_id, 200u, 200u, 1u, dist_start, (int16_t)(dist_start + 70)};
    cue_wire_pack_event(buf + len, &e);
    len += CUE_WIRE_EVENT_SIZE;
  }
  return len;
}

static uint8_t report_type(const uint8_t *report) {
  CueDecision d;
  cue_wire_unpack_decision(report + 6, &d);
  return d.type;
}

/* --- tests ---------------------------------------------------------------- */

int main(void) {
  CueSession s;
  uint8_t buf[CUE_WIRE_STEP_MAX_SIZE];
  uint8_t out[CUE_WIRE_DECISION_REPORT_SIZE];
  uint8_t ctrl_out[CUE_CTRL_MAX_RESPONSE_SIZE];
  size_t out_len;
  bool actuate;
  CueTestCueRequest test_cue;
  CueSessionStatus st;

  /* A STEP before any session is refused, kernel untouched. */
  cue_session_init(&s);
  size_t len = build_step(buf, 0, 0, 1000, 500, 42, 1, 50);
  st = cue_session_handle_step(&s, buf, len, out, sizeof(out), &out_len, &actuate);
  check(st == CUE_SESSION_ERR_STATE, "step before session -> ERR_STATE");
  check(out_len == 0 && !actuate, "refused step emits nothing");

  /* SESSION_START acks OK and reports the real state size (D6 tripwire). */
  len = build_start(buf, 0xABCDEF01u, (uint8_t)CUE_WIRE_PROTO_VERSION);
  st = cue_session_handle_control(&s, buf, len, ctrl_out, sizeof(ctrl_out),
                                  &out_len, &test_cue);
  check(st == CUE_SESSION_OK, "session start OK");
  check(out_len == CUE_CTRL_SESSION_ACK_SIZE, "session ack size");
  check(ctrl_out[0] == CUE_CTRL_SESSION_ACK, "session ack opcode");
  check(ctrl_out[1] == CUE_CTRL_STATUS_OK, "session ack status OK");
  check(cue_wire_get_u16(ctrl_out + 4) == (uint16_t)sizeof(CuePolicyState),
        "session ack echoes sizeof(CuePolicyState)");

  /* A cueing step: 5 m/s at 50 m out -> 10 s lead, inside [5,15]. */
  len = build_step(buf, 1, 0, 1000, 500, 42, 1, 50);
  st = cue_session_handle_step(&s, buf, len, out, sizeof(out), &out_len, &actuate);
  check(st == CUE_SESSION_OK, "first step OK");
  check(out_len == CUE_WIRE_DECISION_REPORT_SIZE, "report size");
  check(report_type(out) == (uint8_t)CUE_HEAD_UP, "first step cues");
  check(actuate, "HEAD_UP actuates");
  check(cue_wire_get_u16(out) == 1, "report echoes seq");
  check(cue_wire_get_u32(out + 2) == 1000u, "report echoes t_ms");
  check(out[14] == 1u, "report actuated flag set");

  /* Duplicate seq: cached report replayed, kernel NOT re-stepped, and no
   * second actuation. Re-stepping would double-count the FR-004 budget. */
  uint8_t cached[CUE_WIRE_DECISION_REPORT_SIZE];
  memcpy(cached, out, sizeof(cached));
  len = build_step(buf, 1, 0, 1000, 500, 42, 1, 50);
  st = cue_session_handle_step(&s, buf, len, out, sizeof(out), &out_len, &actuate);
  check(st == CUE_SESSION_OK, "duplicate seq accepted");
  check(out_len == CUE_WIRE_DECISION_REPORT_SIZE, "duplicate re-emits report");
  check(memcmp(out, cached, sizeof(cached)) == 0, "duplicate report identical");
  check(!actuate, "duplicate does not re-actuate");

  /* Seq gap: rejected outright so the phone resyncs (D4) instead of
   * applying steps out of order. */
  len = build_step(buf, 5, 0, 3000, 500, 42, 0, 0);
  st = cue_session_handle_step(&s, buf, len, out, sizeof(out), &out_len, &actuate);
  check(st == CUE_SESSION_ERR_SEQ_GAP, "seq gap rejected");
  check(out_len == 0, "gap emits no report");

  /* Contiguous seq resumes normally; same event is now ALREADY_CUED,
   * proving the gap above left kernel state untouched. */
  len = build_step(buf, 2, 0, 3000, 500, 42, 1, 40);
  st = cue_session_handle_step(&s, buf, len, out, sizeof(out), &out_len, &actuate);
  check(st == CUE_SESSION_OK, "contiguous step OK");
  check(report_type(out) == (uint8_t)CUE_NONE, "second cue suppressed (FR-004)");
  check(!actuate, "no actuation on NONE");

  /* Catch-up flag: kernel still steps, actuator stays silent (NFR-001). */
  cue_session_init(&s);
  len = build_start(buf, 1u, (uint8_t)CUE_WIRE_PROTO_VERSION);
  cue_session_handle_control(&s, buf, len, ctrl_out, sizeof(ctrl_out), &out_len,
                             &test_cue);
  len = build_step(buf, 1, (uint8_t)CUE_WIRE_STEP_FLAG_CATCHUP, 1000, 500, 42, 1, 50);
  st = cue_session_handle_step(&s, buf, len, out, sizeof(out), &out_len, &actuate);
  check(st == CUE_SESSION_OK, "catch-up step OK");
  check(report_type(out) == (uint8_t)CUE_HEAD_UP, "catch-up still decides HEAD_UP");
  check(!actuate, "catch-up does not actuate");
  check(out[14] == 0u, "catch-up report marks not-actuated");

  /* Reserved flag bits are refused rather than partly understood. */
  len = build_step(buf, 2, 0x04u, 2000, 500, 42, 0, 0);
  st = cue_session_handle_step(&s, buf, len, out, sizeof(out), &out_len, &actuate);
  check(st == CUE_SESSION_ERR_FLAGS, "reserved flag bit rejected");

  /* event_count beyond the wire cap. */
  len = build_step(buf, 2, 0, 2000, 500, 42, 0, 0);
  buf[3] = (uint8_t)(CUE_WIRE_STEP_MAX_EVENTS + 1u);
  st = cue_session_handle_step(&s, buf, len, out, sizeof(out), &out_len, &actuate);
  check(st == CUE_SESSION_ERR_EVENTS, "event_count over cap rejected");

  /* Length disagreeing with the declared event_count. */
  len = build_step(buf, 2, 0, 2000, 500, 42, 1, 50);
  st = cue_session_handle_step(&s, buf, len - 3, out, sizeof(out), &out_len, &actuate);
  check(st == CUE_SESSION_ERR_LENGTH, "truncated step rejected");

  /* Resume with the right ride hash returns our own last_seq. */
  cue_session_init(&s);
  len = build_start(buf, 0x1234u, (uint8_t)CUE_WIRE_PROTO_VERSION);
  cue_session_handle_control(&s, buf, len, ctrl_out, sizeof(ctrl_out), &out_len,
                             &test_cue);
  len = build_step(buf, 9, 0, 1000, 500, 42, 0, 0);
  cue_session_handle_step(&s, buf, len, out, sizeof(out), &out_len, &actuate);
  buf[0] = (uint8_t)CUE_CTRL_SESSION_RESUME;
  cue_wire_put_u32(buf + 1, 0x1234u);
  cue_wire_put_u16(buf + 5, 3u); /* phone's advisory value, deliberately stale */
  st = cue_session_handle_control(&s, buf, CUE_CTRL_SESSION_RESUME_SIZE, ctrl_out,
                                  sizeof(ctrl_out), &out_len, &test_cue);
  check(st == CUE_SESSION_OK, "resume OK");
  check(ctrl_out[1] == CUE_CTRL_STATUS_OK, "resume status OK");
  check(cue_wire_get_u16(ctrl_out + 2) == 9u,
        "resume reports the kernel's own last_seq, not the phone's");

  /* Resume for a different ride is refused: this Pico rebooted, so the
   * phone must restart and re-stream from seq 0 (D4). */
  cue_wire_put_u32(buf + 1, 0x9999u);
  st = cue_session_handle_control(&s, buf, CUE_CTRL_SESSION_RESUME_SIZE, ctrl_out,
                                  sizeof(ctrl_out), &out_len, &test_cue);
  check(ctrl_out[1] == CUE_CTRL_STATUS_WRONG_RIDE, "wrong ride hash refused");

  /* Resume with no session open. */
  cue_session_init(&s);
  cue_wire_put_u32(buf + 1, 0x1234u);
  st = cue_session_handle_control(&s, buf, CUE_CTRL_SESSION_RESUME_SIZE, ctrl_out,
                                  sizeof(ctrl_out), &out_len, &test_cue);
  check(ctrl_out[1] == CUE_CTRL_STATUS_NOT_RIDING, "resume while idle refused");

  /* Wrong protocol version is refused cleanly, session stays closed. */
  len = build_start(buf, 1u, (uint8_t)(CUE_WIRE_PROTO_VERSION + 1u));
  st = cue_session_handle_control(&s, buf, len, ctrl_out, sizeof(ctrl_out),
                                  &out_len, &test_cue);
  check(ctrl_out[1] == CUE_CTRL_STATUS_BAD_PROTO, "bad proto refused");
  len = build_step(buf, 1, 0, 1000, 500, 42, 0, 0);
  st = cue_session_handle_step(&s, buf, len, out, sizeof(out), &out_len, &actuate);
  check(st == CUE_SESSION_ERR_STATE, "no session opened after bad proto");

  /* TEST_CUE drives the actuator only — never the kernel. */
  cue_session_init(&s);
  len = build_start(buf, 1u, (uint8_t)CUE_WIRE_PROTO_VERSION);
  cue_session_handle_control(&s, buf, len, ctrl_out, sizeof(ctrl_out), &out_len,
                             &test_cue);
  buf[0] = (uint8_t)CUE_CTRL_TEST_CUE;
  st = cue_session_handle_control(&s, buf, 1, ctrl_out, sizeof(ctrl_out), &out_len,
                                  &test_cue);
  check(st == CUE_SESSION_OK && test_cue.fire, "TEST_CUE requests actuation");
  check(test_cue.pattern == (uint8_t)CUE_PATTERN_SELECTED,
        "bare TEST_CUE fires the selected pattern");
  check(!s.have_seq, "TEST_CUE leaves the decision stream untouched");

  /* TEST_CUE with an explicit candidate index (RFC 0006 D7). */
  buf[1] = (uint8_t)(CUE_PATTERN_COUNT - 1u);
  st = cue_session_handle_control(&s, buf, 2, ctrl_out, sizeof(ctrl_out),
                                  &out_len, &test_cue);
  check(st == CUE_SESSION_OK && test_cue.fire, "TEST_CUE with index accepted");
  check(test_cue.pattern == (uint8_t)(CUE_PATTERN_COUNT - 1u),
        "TEST_CUE carries the requested pattern");
  check(ctrl_out[1] == CUE_CTRL_STATUS_OK, "TEST_CUE with index acks OK");

  /* An index past the table is refused, not clamped: quietly substituting
   * a different candidate would make a comparison lie about what played. */
  buf[1] = (uint8_t)CUE_PATTERN_COUNT;
  st = cue_session_handle_control(&s, buf, 2, ctrl_out, sizeof(ctrl_out),
                                  &out_len, &test_cue);
  check(st == CUE_SESSION_ERR_PATTERN, "out-of-range pattern refused");
  check(!test_cue.fire, "refused pattern does not actuate");
  check(ctrl_out[0] == CUE_CTRL_GENERIC_ACK &&
            ctrl_out[1] == CUE_CTRL_STATUS_BAD_PATTERN,
        "out-of-range pattern acks BAD_PATTERN");

  /* The sentinel is not a valid explicit index either. */
  buf[1] = (uint8_t)CUE_PATTERN_SELECTED;
  st = cue_session_handle_control(&s, buf, 2, ctrl_out, sizeof(ctrl_out),
                                  &out_len, &test_cue);
  check(st == CUE_SESSION_ERR_PATTERN, "CUE_PATTERN_SELECTED refused as an index");

  /* Over-long TEST_CUE is a length error, distinct from a bad index. */
  buf[1] = 0u;
  buf[2] = 0u;
  st = cue_session_handle_control(&s, buf, 3, ctrl_out, sizeof(ctrl_out),
                                  &out_len, &test_cue);
  check(st == CUE_SESSION_ERR_LENGTH, "over-long TEST_CUE refused");
  check(!test_cue.fire, "over-long TEST_CUE does not actuate");

  /* STOP closes the session; a later step is refused. */
  buf[0] = (uint8_t)CUE_CTRL_SESSION_STOP;
  st = cue_session_handle_control(&s, buf, 1, ctrl_out, sizeof(ctrl_out), &out_len,
                                  &test_cue);
  check(st == CUE_SESSION_OK && ctrl_out[1] == CUE_CTRL_STATUS_OK, "stop OK");
  len = build_step(buf, 1, 0, 1000, 500, 42, 0, 0);
  st = cue_session_handle_step(&s, buf, len, out, sizeof(out), &out_len, &actuate);
  check(st == CUE_SESSION_ERR_STATE, "step after stop refused");

  /* Unknown opcode is refused with a recognizable ack. */
  buf[0] = 0x7Fu;
  st = cue_session_handle_control(&s, buf, 1, ctrl_out, sizeof(ctrl_out), &out_len,
                                  &test_cue);
  check(st == CUE_SESSION_ERR_OPCODE, "unknown opcode refused");
  check(ctrl_out[0] == CUE_CTRL_GENERIC_ACK &&
            ctrl_out[1] == CUE_CTRL_STATUS_BAD_OPCODE,
        "unknown opcode still acks");

  /* seq wraps u16 without being mistaken for a gap. */
  cue_session_init(&s);
  len = build_start(buf, 1u, (uint8_t)CUE_WIRE_PROTO_VERSION);
  cue_session_handle_control(&s, buf, len, ctrl_out, sizeof(ctrl_out), &out_len,
                             &test_cue);
  len = build_step(buf, 0xFFFFu, 0, 1000, 500, 42, 0, 0);
  st = cue_session_handle_step(&s, buf, len, out, sizeof(out), &out_len, &actuate);
  check(st == CUE_SESSION_OK, "step at seq 0xFFFF OK");
  len = build_step(buf, 0x0000u, 0, 2000, 500, 42, 0, 0);
  st = cue_session_handle_step(&s, buf, len, out, sizeof(out), &out_len, &actuate);
  check(st == CUE_SESSION_OK, "seq wrap 0xFFFF -> 0 is contiguous, not a gap");

  /* A recorded actuation delay must reach BOTH the outgoing report and
   * the cached copy a retry re-emits. Otherwise a lost DECISION notify —
   * the exact case that provokes a retry — is answered with a fabricated
   * zero, and the D5 gate's evidence claims the cue actuated instantly. */
  cue_session_init(&s);
  len = build_start(buf, 0x5150u, (uint8_t)CUE_WIRE_PROTO_VERSION);
  cue_session_handle_control(&s, buf, len, ctrl_out, sizeof(ctrl_out), &out_len,
                             &test_cue);
  len = build_step(buf, 1, 0, 1000, 500, 42, 1, 50);
  st = cue_session_handle_step(&s, buf, len, out, sizeof(out), &out_len, &actuate);
  check(st == CUE_SESSION_OK && actuate, "delay fixture: step cues");
  check(cue_wire_get_u16(out + CUE_WIRE_DECISION_REPORT_DELAY_US_OFFSET) == 0u,
        "session builds the report with a placeholder delay");
  cue_session_record_actuation_delay_us(&s, out, 37u);
  check(cue_wire_get_u16(out + CUE_WIRE_DECISION_REPORT_DELAY_US_OFFSET) == 37u,
        "recorded delay lands in the outgoing report");
  len = build_step(buf, 1, 0, 1000, 500, 42, 1, 50);
  st = cue_session_handle_step(&s, buf, len, out, sizeof(out), &out_len, &actuate);
  check(st == CUE_SESSION_OK && out_len == CUE_WIRE_DECISION_REPORT_SIZE,
        "retry after a recorded delay still replays the cached report");
  check(cue_wire_get_u16(out + CUE_WIRE_DECISION_REPORT_DELAY_US_OFFSET) == 37u,
        "retry replays the recorded delay, not a fabricated zero");
  check(!actuate, "retry still does not re-actuate");

  printf(failures ? "FAILURES: %d\n" : "cue_session: all tests passed\n",
         failures);
  return failures ? 1 : 0;
}
