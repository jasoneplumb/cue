/*
 * Intent: Ride-session state machine — owns CuePolicyState and is the
 *         ONLY caller of cue_policy_step in the firmware. Decodes
 *         CONTROL and STEP payloads (RFC 0006 D3), enforces the
 *         sequencing rules that keep on-target kernel state bit-identical
 *         to the phone's shadow (D4), and emits DECISION reports.
 * Context: RFC 0006 D2 (Pico authoritative for actuation, phone shadows),
 *          D3 (wire protocol), D4 (reconnect/resume semantics).
 * Pattern: Pure logic over caller-owned state — byte buffers in, byte
 *          buffers out, no BTstack and no I/O, so the whole state machine
 *          is host-testable (same split as cue_usb_replay's line handler).
 *          No dynamic allocation (NFR-004).
 *
 * Sequencing contract (the NFR-003-critical part). The kernel is a pure
 * function of the step sequence, so a step applied twice, or applied out
 * of order, silently diverges on-target state from the shadow's. Hence:
 *   - the first step of a session is accepted at any seq;
 *   - thereafter only seq == last_seq + 1 (u16, wrapping) is stepped;
 *   - a repeat of last_seq re-emits the CACHED report without touching
 *     the kernel, so a phone retrying an un-acked step is idempotent;
 *   - anything else is a gap: rejected, kernel untouched, and the phone
 *     must resync (D4's full re-stream) rather than paper over the hole.
 */
#ifndef CUE_SESSION_H
#define CUE_SESSION_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "cue_pattern.h"
#include "cue_policy.h"
#include "cue_wire.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
  CUE_SESSION_IDLE = 0,
  CUE_SESSION_RIDING = 1,
} CueSessionState;

/* Outcome of handling a write. Maps to an ATT error at the BLE layer;
 * OK means the write is accepted (a response may still have been
 * produced). */
typedef enum {
  CUE_SESSION_OK = 0,
  CUE_SESSION_ERR_LENGTH = 1,   /* payload length disagrees with the opcode */
  CUE_SESSION_ERR_STATE = 2,    /* STEP with no session open */
  CUE_SESSION_ERR_FLAGS = 3,    /* reserved flag bits set (D3) */
  CUE_SESSION_ERR_SEQ_GAP = 4,  /* non-contiguous seq — resync required */
  CUE_SESSION_ERR_EVENTS = 5,   /* event_count above the wire cap */
  CUE_SESSION_ERR_OPCODE = 6,   /* unknown control opcode */
  CUE_SESSION_ERR_PATTERN = 7,  /* TEST_CUE index outside the table (D7) */
} CueSessionStatus;

/* A decoded TEST_CUE request. `pattern` is CUE_PATTERN_SELECTED when the
 * frame carried no index, meaning "fire whatever is selected" — the
 * actuator, not the protocol, owns that choice. */
typedef struct {
  bool fire;
  uint8_t pattern;
} CueTestCueRequest;

typedef struct {
  CuePolicyState policy;
  uint32_t ride_id_hash;
  uint16_t last_seq;
  bool have_seq;
  uint8_t state; /* CueSessionState */
  /* Cached DECISION report for last_seq, so a retried step is idempotent
   * (see the sequencing contract above) rather than re-stepping. */
  uint8_t last_report[CUE_WIRE_DECISION_REPORT_SIZE];
  bool have_last_report;
} CueSession;

/* Reset to IDLE with no ride. Safe to call at any time. */
void cue_session_init(CueSession *s);

/* Handle a CONTROL characteristic write.
 *
 * out receives the response to indicate back (SESSION_ACK / RESUME_ACK /
 * GENERIC_ACK); *out_len is set to its length, 0 when there is none.
 * *test_cue is filled in for TEST_CUE, which drives the actuator only and
 * never the kernel (RFC 0006 D3) — the firmware analog of the phone's
 * debug test cue. The pattern index is range-checked HERE, in the
 * host-tested layer, so an out-of-range index can never reach the
 * actuator through any transport.
 *
 * A malformed request still produces an ack carrying a non-OK status
 * where the opcode is recognizable: the phone needs to distinguish "the
 * Pico refused" from "the Pico is not listening". */
CueSessionStatus cue_session_handle_control(CueSession *s, const uint8_t *data,
                                            size_t len, uint8_t *out,
                                            size_t out_cap, size_t *out_len,
                                            CueTestCueRequest *test_cue);

/* Handle a STEP characteristic write: decode, step the kernel, and build
 * the DECISION report.
 *
 * out receives the report (CUE_WIRE_DECISION_REPORT_SIZE bytes) to notify;
 * *out_len is 0 when the step was rejected. *actuate is true only when the
 * decision is a HEAD_UP that should reach the rider — a catch-up step
 * (CUE_WIRE_STEP_FLAG_CATCHUP) still advances the kernel but never
 * actuates, because a burst of stale cues after a link gap is the noisy
 * cueing NFR-001 forbids. */
CueSessionStatus cue_session_handle_step(CueSession *s, const uint8_t *data,
                                         size_t len, uint8_t *out,
                                         size_t out_cap, size_t *out_len,
                                         bool *actuate);

/* Write the measured actuation delay into `report` AND into the cached
 * copy the next idempotent retry would re-emit.
 *
 * The session builds every report with a placeholder 0 because it owns no
 * clock by design (RFC 0006 D3); only the caller that drove the actuator
 * knows the real figure. Both copies are updated here, in one place, so a
 * retried step cannot answer with a fabricated zero. Call only after a
 * step that set *actuate.
 *
 * Microseconds, saturating at CUE_WIRE_ACTUATION_DELAY_US_MAX. The
 * millisecond version of this reported 0 for every real cue, because the
 * interval it measures is under 500 us — a true result that was
 * indistinguishable from an unmeasured one (#164). */
void cue_session_record_actuation_delay_us(CueSession *s, uint8_t *report,
                                           uint16_t delay_us);

#ifdef __cplusplus
}
#endif

#endif /* CUE_SESSION_H */
