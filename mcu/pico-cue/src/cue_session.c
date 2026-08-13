/*
 * Intent: Implementation of the ride-session state machine (see header).
 * Pattern: Stack-only decode into kernel structs via cue_wire.h, exact
 *          length validation before any field is trusted, and a single
 *          cue_policy_step call site.
 */
#include "cue_session.h"

#include <string.h>

#ifndef CUE_FW_VERSION_U16
/* Packed major.minor for the wire: 0x0001 == 0.1. */
#define CUE_FW_VERSION_U16 0x0001u
#endif

void cue_session_init(CueSession *s) {
  cue_policy_init(&s->policy, NULL);
  s->ride_id_hash = 0;
  s->last_seq = 0;
  s->have_seq = false;
  s->state = (uint8_t)CUE_SESSION_IDLE;
  memset(s->last_report, 0, sizeof(s->last_report));
  s->have_last_report = false;
}

/* --- CONTROL ------------------------------------------------------------- */

static size_t put_generic_ack(uint8_t *out, size_t out_cap, uint8_t status) {
  if (out_cap < CUE_CTRL_GENERIC_ACK_SIZE) {
    return 0;
  }
  out[0] = (uint8_t)CUE_CTRL_GENERIC_ACK;
  out[1] = status;
  return CUE_CTRL_GENERIC_ACK_SIZE;
}

static size_t put_session_ack(uint8_t *out, size_t out_cap, uint8_t status) {
  if (out_cap < CUE_CTRL_SESSION_ACK_SIZE) {
    return 0;
  }
  out[0] = (uint8_t)CUE_CTRL_SESSION_ACK;
  out[1] = status;
  cue_wire_put_u16(out + 2, (uint16_t)CUE_FW_VERSION_U16);
  /* The runtime half of the D6 width tripwire. Reported even on a failed
   * start so the phone can tell a width mismatch from a protocol one. */
  cue_wire_put_u16(out + 4, (uint16_t)sizeof(CuePolicyState));
  return CUE_CTRL_SESSION_ACK_SIZE;
}

static size_t put_resume_ack(uint8_t *out, size_t out_cap, uint8_t status,
                             uint16_t last_seq) {
  if (out_cap < CUE_CTRL_RESUME_ACK_SIZE) {
    return 0;
  }
  out[0] = (uint8_t)CUE_CTRL_RESUME_ACK;
  out[1] = status;
  cue_wire_put_u16(out + 2, last_seq);
  return CUE_CTRL_RESUME_ACK_SIZE;
}

static CueSessionStatus handle_session_start(CueSession *s,
                                             const uint8_t *data, size_t len,
                                             uint8_t *out, size_t out_cap,
                                             size_t *out_len) {
  if (len != CUE_CTRL_SESSION_START_SIZE) {
    *out_len = put_session_ack(out, out_cap, (uint8_t)CUE_CTRL_STATUS_BAD_LENGTH);
    return CUE_SESSION_ERR_LENGTH;
  }
  if (data[1] != (uint8_t)CUE_WIRE_PROTO_VERSION) {
    *out_len = put_session_ack(out, out_cap, (uint8_t)CUE_CTRL_STATUS_BAD_PROTO);
    return CUE_SESSION_OK; /* a clean refusal, not a malformed write */
  }

  CuePolicyConfig config;
  cue_wire_unpack_config(data + 6, &config);
  /* cue_policy_init clamps a nonsensical config rather than rejecting it
   * (it has no error channel); the phone sends the same config to its own
   * shadow, which clamps identically, so both sides stay in step. */
  cue_policy_init(&s->policy, &config);
  s->ride_id_hash = cue_wire_get_u32(data + 2);
  s->last_seq = 0;
  s->have_seq = false;
  s->have_last_report = false;
  s->state = (uint8_t)CUE_SESSION_RIDING;

  *out_len = put_session_ack(out, out_cap, (uint8_t)CUE_CTRL_STATUS_OK);
  return CUE_SESSION_OK;
}

static CueSessionStatus handle_session_resume(CueSession *s,
                                              const uint8_t *data, size_t len,
                                              uint8_t *out, size_t out_cap,
                                              size_t *out_len) {
  if (len != CUE_CTRL_SESSION_RESUME_SIZE) {
    *out_len = put_resume_ack(out, out_cap, (uint8_t)CUE_CTRL_STATUS_BAD_LENGTH, 0);
    return CUE_SESSION_ERR_LENGTH;
  }
  if (s->state != (uint8_t)CUE_SESSION_RIDING) {
    /* Rebooted or never started: the phone must SESSION_START and
     * re-stream from seq 0 (D4) rather than resume into empty state. */
    *out_len = put_resume_ack(out, out_cap, (uint8_t)CUE_CTRL_STATUS_NOT_RIDING, 0);
    return CUE_SESSION_OK;
  }
  if (cue_wire_get_u32(data + 1) != s->ride_id_hash) {
    *out_len = put_resume_ack(out, out_cap, (uint8_t)CUE_CTRL_STATUS_WRONG_RIDE, 0);
    return CUE_SESSION_OK;
  }

  /* The phone's last_acked_seq is advisory — our own last_seq is the
   * authority on what the kernel has actually consumed, and it is what
   * the phone must resume from. */
  *out_len = put_resume_ack(out, out_cap, (uint8_t)CUE_CTRL_STATUS_OK,
                            s->have_seq ? s->last_seq : 0);
  return CUE_SESSION_OK;
}

CueSessionStatus cue_session_handle_control(CueSession *s, const uint8_t *data,
                                            size_t len, uint8_t *out,
                                            size_t out_cap, size_t *out_len,
                                            CueTestCueRequest *test_cue) {
  *out_len = 0;
  test_cue->fire = false;
  test_cue->pattern = (uint8_t)CUE_PATTERN_SELECTED;
  if (len < 1) {
    return CUE_SESSION_ERR_LENGTH;
  }

  switch (data[0]) {
    case CUE_CTRL_SESSION_START:
      return handle_session_start(s, data, len, out, out_cap, out_len);
    case CUE_CTRL_SESSION_RESUME:
      return handle_session_resume(s, data, len, out, out_cap, out_len);
    case CUE_CTRL_SESSION_STOP:
      if (len != 1) {
        *out_len = put_generic_ack(out, out_cap, (uint8_t)CUE_CTRL_STATUS_BAD_LENGTH);
        return CUE_SESSION_ERR_LENGTH;
      }
      cue_session_init(s);
      *out_len = put_generic_ack(out, out_cap, (uint8_t)CUE_CTRL_STATUS_OK);
      return CUE_SESSION_OK;
    case CUE_CTRL_TEST_CUE:
      if (len < CUE_CTRL_TEST_CUE_MIN_SIZE || len > CUE_CTRL_TEST_CUE_MAX_SIZE) {
        *out_len = put_generic_ack(out, out_cap, (uint8_t)CUE_CTRL_STATUS_BAD_LENGTH);
        return CUE_SESSION_ERR_LENGTH;
      }
      if (len == CUE_CTRL_TEST_CUE_MAX_SIZE) {
        /* An explicit candidate (RFC 0006 D7). Refused rather than
         * clamped: silently substituting a different pattern would make a
         * back-to-back comparison lie about which one the rider heard. */
        if (!cue_pattern_valid(data[1])) {
          *out_len =
              put_generic_ack(out, out_cap, (uint8_t)CUE_CTRL_STATUS_BAD_PATTERN);
          return CUE_SESSION_ERR_PATTERN;
        }
        test_cue->pattern = data[1];
      }
      /* Actuator only, never the kernel: a test cue must not appear in
       * the decision stream or perturb FR-004 budgets (RFC 0006 D3). */
      test_cue->fire = true;
      *out_len = put_generic_ack(out, out_cap, (uint8_t)CUE_CTRL_STATUS_OK);
      return CUE_SESSION_OK;
    default:
      *out_len = put_generic_ack(out, out_cap, (uint8_t)CUE_CTRL_STATUS_BAD_OPCODE);
      return CUE_SESSION_ERR_OPCODE;
  }
}

/* --- STEP ---------------------------------------------------------------- */

static void build_report(uint8_t *out, uint16_t seq, uint32_t t_ms,
                         const CueDecision *d, bool actuated,
                         uint16_t actuation_delay_us) {
  cue_wire_put_u16(out + 0, seq);
  cue_wire_put_u32(out + 2, t_ms);
  cue_wire_pack_decision(out + 6, d);
  out[CUE_WIRE_DECISION_REPORT_ACTUATED_OFFSET] = actuated ? 1u : 0u;
  cue_wire_put_u16(out + CUE_WIRE_DECISION_REPORT_DELAY_US_OFFSET,
                   actuation_delay_us);
}

void cue_session_record_actuation_delay_us(CueSession *s, uint8_t *report,
                                           uint16_t delay_us) {
  cue_wire_put_u16(report + CUE_WIRE_DECISION_REPORT_DELAY_US_OFFSET, delay_us);
  /* The cache too, not just the outgoing copy. An idempotent STEP retry
   * re-emits last_report verbatim, so leaving the cache at the
   * placeholder 0 would feed a fabricated "actuated instantly" into the
   * D5 gate's evidence precisely when a DECISION notify went missing —
   * the case where the phone most needs the real number. */
  if (s->have_last_report) {
    cue_wire_put_u16(s->last_report + CUE_WIRE_DECISION_REPORT_DELAY_US_OFFSET,
                     delay_us);
  }
}

CueSessionStatus cue_session_handle_step(CueSession *s, const uint8_t *data,
                                         size_t len, uint8_t *out,
                                         size_t out_cap, size_t *out_len,
                                         bool *actuate) {
  *out_len = 0;
  *actuate = false;

  if (s->state != (uint8_t)CUE_SESSION_RIDING) {
    return CUE_SESSION_ERR_STATE;
  }
  if (len < CUE_WIRE_STEP_HEADER_SIZE + CUE_WIRE_SAMPLE_SIZE) {
    return CUE_SESSION_ERR_LENGTH;
  }

  uint16_t seq = cue_wire_get_u16(data + 0);
  uint8_t flags = data[2];
  uint8_t event_count = data[3];

  if ((flags & (uint8_t)~CUE_WIRE_STEP_FLAGS_KNOWN) != 0u) {
    /* A protocol-version disagreement must fail loudly, never actuate
     * on a payload we only partly understand (RFC 0006 D3). */
    return CUE_SESSION_ERR_FLAGS;
  }
  if (event_count > CUE_WIRE_STEP_MAX_EVENTS) {
    return CUE_SESSION_ERR_EVENTS;
  }

  bool has_memory = (flags & (uint8_t)CUE_WIRE_STEP_FLAG_MEMORY) != 0u;
  size_t expect = CUE_WIRE_STEP_HEADER_SIZE + CUE_WIRE_SAMPLE_SIZE +
                  (size_t)event_count * CUE_WIRE_EVENT_SIZE +
                  (has_memory ? CUE_WIRE_MEMORY_SIZE : 0u);
  if (len != expect) {
    return CUE_SESSION_ERR_LENGTH;
  }

  /* Sequencing (see the header's contract). Idempotent retry first: a
   * repeat of the last seq re-emits the cached report and leaves the
   * kernel untouched. */
  if (s->have_seq && seq == s->last_seq) {
    if (s->have_last_report && out_cap >= CUE_WIRE_DECISION_REPORT_SIZE) {
      memcpy(out, s->last_report, CUE_WIRE_DECISION_REPORT_SIZE);
      *out_len = CUE_WIRE_DECISION_REPORT_SIZE;
    }
    return CUE_SESSION_OK; /* deliberately no actuation on a replay */
  }
  if (s->have_seq && seq != (uint16_t)(s->last_seq + 1u)) {
    return CUE_SESSION_ERR_SEQ_GAP;
  }

  const uint8_t *cursor = data + CUE_WIRE_STEP_HEADER_SIZE;
  RideSample sample;
  cue_wire_unpack_sample(cursor, &sample);
  cursor += CUE_WIRE_SAMPLE_SIZE;

  RouteEvent events[CUE_WIRE_STEP_MAX_EVENTS];
  for (uint8_t i = 0; i < event_count; i++) {
    cue_wire_unpack_event(cursor, &events[i]);
    cursor += CUE_WIRE_EVENT_SIZE;
  }

  PersonalMemory memory;
  const PersonalMemory *memory_ptr = NULL;
  if (has_memory) {
    cue_wire_unpack_memory(cursor, &memory);
    memory_ptr = &memory;
  }

  /* Last guard before the kernel mutates. Checked HERE, not after the
   * step: advancing the kernel and then failing the write would leave
   * the Pico one step ahead of a phone that believes the step was
   * rejected — a silent NFR-003 divergence. Unreachable from today's
   * callers (both size `out` exactly), which is precisely why it must
   * not be left where a future caller could trip it. */
  if (out_cap < CUE_WIRE_DECISION_REPORT_SIZE) {
    return CUE_SESSION_ERR_LENGTH;
  }

  CueDecision decision =
      cue_policy_step(&s->policy, &sample, event_count > 0 ? events : NULL,
                      event_count, memory_ptr);

  s->last_seq = seq;
  s->have_seq = true;

  bool catchup = (flags & (uint8_t)CUE_WIRE_STEP_FLAG_CATCHUP) != 0u;
  bool fire = (decision.type == (uint8_t)CUE_HEAD_UP) && !catchup;

  /* actuation_delay_ms is measured by the caller (it owns the clock and
   * the actuator); the session reports 0 and lets the BLE layer overwrite
   * it, keeping this translation unit free of any time source. */
  build_report(s->last_report, seq, sample.t_ms, &decision, fire, 0u);
  s->have_last_report = true;

  memcpy(out, s->last_report, CUE_WIRE_DECISION_REPORT_SIZE);
  *out_len = CUE_WIRE_DECISION_REPORT_SIZE;
  *actuate = fire;
  return CUE_SESSION_OK;
}
