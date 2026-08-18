/*
 * Intent: Single wire codec for the RFC 0006 BLE/host protocol — packed
 *         little-endian serialization of the kernel's structs, shared
 *         verbatim by the Pico firmware, the host hiltest tool, and the
 *         iOS golden-vector tests, so encode/decode can never fork.
 * Context: RFC 0006 D3 (wire protocol), kernel/cue_policy.h (source of
 *          truth for field order — wire order IS struct order).
 * Pattern: Field-wise pack/unpack, never struct memcpy: RouteEvent,
 *          CueDecision, and PersonalMemory carry padding their wire forms
 *          must not (RFC 0006 D3).
 */
#ifndef CUE_WIRE_H
#define CUE_WIRE_H

#include <stddef.h>
#include <stdint.h>

#include "cue_policy.h"

#ifdef __cplusplus
extern "C" {
#endif

/* v2 (#164, #165): actuation delay is microseconds, not milliseconds, and
 * STATUS carries the supply. The delay change keeps the same offset and
 * the same u16 width, so a v1 peer would decode it happily and be wrong
 * by 1000x — silently. That is exactly what this version check is for:
 * the mismatch has to fail at SESSION_START, loudly, rather than land a
 * plausible number in the D5 evidence. */
#define CUE_WIRE_PROTO_VERSION 2u

/* Packed wire sizes (RFC 0006 D3). Natural struct sizes differ where
 * noted; the codec below is the only mapping between the two. */
#define CUE_WIRE_SAMPLE_SIZE 20u   /* == sizeof(RideSample), no padding   */
#define CUE_WIRE_EVENT_SIZE 17u    /* natural struct is 20 B with padding */
#define CUE_WIRE_MEMORY_SIZE 6u    /* natural struct is 8 B with padding  */
#define CUE_WIRE_DECISION_SIZE 8u  /* natural struct is 12 B with padding */
#define CUE_WIRE_CONFIG_SIZE 12u   /* == sizeof(CuePolicyConfig)          */

/* STEP payload: seq u16 | flags u8 | event_count u8 | sample | events×n
 * | [memory]  (RFC 0006 D3). */
#define CUE_WIRE_STEP_HEADER_SIZE 4u
#define CUE_WIRE_STEP_MAX_EVENTS 16u /* matches REPLAY_MAX_EVENTS_PER_SAMPLE */
#define CUE_WIRE_STEP_MAX_SIZE                                       \
  (CUE_WIRE_STEP_HEADER_SIZE + CUE_WIRE_SAMPLE_SIZE +                \
   CUE_WIRE_STEP_MAX_EVENTS * CUE_WIRE_EVENT_SIZE +                  \
   CUE_WIRE_MEMORY_SIZE) /* 302 */

/* STEP flags (RFC 0006 D3): bits 2–7 are reserved and must be zero; the
 * Pico rejects a step with unknown flags set so a protocol-version
 * disagreement fails loudly instead of actuating stale cues. */
#define CUE_WIRE_STEP_FLAG_MEMORY (1u << 0)
#define CUE_WIRE_STEP_FLAG_CATCHUP (1u << 1) /* step kernel, do not actuate */
#define CUE_WIRE_STEP_FLAGS_KNOWN                                     \
  (CUE_WIRE_STEP_FLAG_MEMORY | CUE_WIRE_STEP_FLAG_CATCHUP)

/* DECISION notify: seq u16 | t_ms u32 | decision | actuated u8 |
 * actuation_delay_us u16  (RFC 0006 D3).
 *
 * Microseconds, since v2. In milliseconds the field read 0 on every
 * genuine cue of the first validation ride — the real interval is under
 * 500 us, so it rounded away (#164). That was D2's architectural claim
 * landing exactly as argued, reported as a number indistinguishable from
 * "never measured", which is the same defect #162 had to fix once
 * already. A u16 of microseconds spans 65 ms: ample for a path that
 * should never exceed single-digit milliseconds, and anything larger
 * saturates to 0xFFFF, which is an obvious fault rather than a plausible
 * one. */
#define CUE_WIRE_DECISION_REPORT_SIZE                                 \
  (2u + 4u + CUE_WIRE_DECISION_SIZE + 1u + 2u) /* 17 */

/* Saturation value for the delay: ">= 65.535 ms", i.e. broken, not slow. */
#define CUE_WIRE_ACTUATION_DELAY_US_MAX 0xFFFFu

/* Field offsets within that report. Named because two translation units
 * write them — cue_session builds the report, and the BLE layer patches
 * the measured delay in afterwards (it owns the clock, the session does
 * not). Spelled as literals in both places, inserting a field ahead of
 * them would silently corrupt whichever site was not updated. */
#define CUE_WIRE_DECISION_REPORT_SEQ_OFFSET 0u
_Static_assert(CUE_WIRE_DECISION_REPORT_SIZE >
                   CUE_WIRE_DECISION_REPORT_SEQ_OFFSET + 1u,
               "seq field overruns the DECISION report");
#define CUE_WIRE_DECISION_REPORT_ACTUATED_OFFSET                       \
  (2u + 4u + CUE_WIRE_DECISION_SIZE) /* 14 */
/* Renamed with the unit in v2 (was ..._DELAY_OFFSET) so that any site
 * still writing milliseconds fails to compile rather than compiling into
 * a 1000x error. */
#define CUE_WIRE_DECISION_REPORT_DELAY_US_OFFSET                        \
  (CUE_WIRE_DECISION_REPORT_ACTUATED_OFFSET + 1u) /* 15 */

/* STATUS read: fw_version u16 | state u8 | battery_mv u16 | supply u8.
 * Named here, and pinned by both test suites, so appending a field to
 * the firmware's STATUS payload fails a test rather than silently
 * tripping the reader's length guard and dropping every packet.
 *
 * `supply` arrived in v2 because `battery_mv` alone is not evidence: on a
 * WuKong 2040 the Pico's VSYS is unpowered whenever USB is out, so the
 * millivolts say whether USB is present and nothing about the cell
 * (#165). D5 requires validation rides to run on the 18650, and this
 * field is what lets the sidecar prove one did. Values are the
 * CUE_POWER_SUPPLY_* constants; UNKNOWN is a real answer, reported when
 * the radio is down and there is no way to ask. */
#define CUE_WIRE_STATUS_SIZE 6u
#define CUE_WIRE_STATUS_SUPPLY_OFFSET 5u

/* Phone-side un-acked step ring (RFC 0006 D4): >= 10 minutes at 1 Hz.
 * Overflow never partial-catches-up — it falls back to a full re-stream
 * from seq 0, reconstructed from the ride trace recorder. */
#define CUE_WIRE_RING_CAPACITY 600u

/* --- GATT identifiers (RFC 0006 D3) --------------------------------------
 * Custom 128-bit service, Nordic-style: one base UUID with a varying
 * 16-bit field. Recorded here rather than only in the .gatt file so the
 * iOS central (Phase B2) shares one source of truth. */
#define CUE_GATT_UUID_SERVICE "85BF0001-C87E-4346-8A6C-440B3E57F451"
#define CUE_GATT_UUID_CONTROL "85BF0002-C87E-4346-8A6C-440B3E57F451"
#define CUE_GATT_UUID_STEP "85BF0003-C87E-4346-8A6C-440B3E57F451"
#define CUE_GATT_UUID_DECISION "85BF0004-C87E-4346-8A6C-440B3E57F451"
#define CUE_GATT_UUID_STATUS "85BF0005-C87E-4346-8A6C-440B3E57F451"

/* --- CONTROL opcodes (RFC 0006 D3) ---------------------------------------
 * Requests are phone->pico writes; responses carry the high bit so a
 * capture is unambiguous about direction. */
#define CUE_CTRL_SESSION_START 0x01u
#define CUE_CTRL_SESSION_RESUME 0x02u
#define CUE_CTRL_SESSION_STOP 0x03u
#define CUE_CTRL_TEST_CUE 0x04u

#define CUE_CTRL_SESSION_ACK 0x81u
#define CUE_CTRL_RESUME_ACK 0x82u
#define CUE_CTRL_GENERIC_ACK 0x83u

/* SESSION_START: opcode | proto_ver u8 | ride_id_hash u32 | config 12 B */
#define CUE_CTRL_SESSION_START_SIZE (1u + 1u + 4u + CUE_WIRE_CONFIG_SIZE)
/* SESSION_ACK: opcode | status u8 | fw_version u16 | state_size u16.
 * state_size is the runtime half of the D6 compiler-width tripwire — the
 * phone aborts on a mismatch rather than streaming into a kernel whose
 * state is laid out differently than its own shadow. */
#define CUE_CTRL_SESSION_ACK_SIZE 6u
/* SESSION_RESUME: opcode | ride_id_hash u32 | last_acked_seq u16 */
#define CUE_CTRL_SESSION_RESUME_SIZE 7u
/* RESUME_ACK: opcode | status u8 | last_processed_seq u16 */
#define CUE_CTRL_RESUME_ACK_SIZE 4u
/* SESSION_STOP: opcode only. GENERIC_ACK: opcode | status u8 */
#define CUE_CTRL_GENERIC_ACK_SIZE 2u
/* TEST_CUE: opcode | [pattern_index u8]. The index is OPTIONAL — a
 * length-1 frame means "fire whichever pattern is selected", which is
 * what Phase B's firmware and tooling already send, so extending the
 * opcode does not break them (RFC 0006 D7). A length-2 frame fires a
 * specific candidate, which is how patterns get compared back-to-back
 * without reflashing. */
#define CUE_CTRL_TEST_CUE_MIN_SIZE 1u
#define CUE_CTRL_TEST_CUE_MAX_SIZE 2u
/* Largest response this protocol produces — sizes control-path buffers. */
#define CUE_CTRL_MAX_RESPONSE_SIZE CUE_CTRL_SESSION_ACK_SIZE

/* Control status codes, carried in every *_ACK. */
#define CUE_CTRL_STATUS_OK 0u
#define CUE_CTRL_STATUS_BAD_PROTO 1u   /* proto_ver the firmware won't speak */
#define CUE_CTRL_STATUS_BAD_LENGTH 2u  /* payload length != the opcode's size */
#define CUE_CTRL_STATUS_WRONG_RIDE 3u  /* resume for a ride this Pico never had
                                        * (it rebooted) — phone must restart  */
#define CUE_CTRL_STATUS_NOT_RIDING 4u  /* resume with no session open. STOP is
                                        * deliberately idempotent (a phone
                                        * that rebooted mid-ride must be able
                                        * to reset an already-idle Pico) and
                                        * always acks OK — see cue_session.c */
#define CUE_CTRL_STATUS_BAD_OPCODE 5u
#define CUE_CTRL_STATUS_BAD_PATTERN 6u /* TEST_CUE index outside the table */

/* --- Primitive little-endian accessors ------------------------------------ */

static inline void cue_wire_put_u16(uint8_t *p, uint16_t v) {
  p[0] = (uint8_t)(v & 0xFFu);
  p[1] = (uint8_t)(v >> 8);
}

static inline void cue_wire_put_u32(uint8_t *p, uint32_t v) {
  p[0] = (uint8_t)(v & 0xFFu);
  p[1] = (uint8_t)((v >> 8) & 0xFFu);
  p[2] = (uint8_t)((v >> 16) & 0xFFu);
  p[3] = (uint8_t)(v >> 24);
}

static inline uint16_t cue_wire_get_u16(const uint8_t *p) {
  return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}

static inline uint32_t cue_wire_get_u32(const uint8_t *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
         ((uint32_t)p[3] << 24);
}

/* Signed fields travel as their two's-complement bit pattern. The
 * unsigned->signed casts below are well-defined on every target this
 * codec compiles for (GCC/Clang on ARM, x86-64, arm64). */
static inline void cue_wire_put_i16(uint8_t *p, int16_t v) {
  cue_wire_put_u16(p, (uint16_t)v);
}

static inline void cue_wire_put_i32(uint8_t *p, int32_t v) {
  cue_wire_put_u32(p, (uint32_t)v);
}

static inline int16_t cue_wire_get_i16(const uint8_t *p) {
  return (int16_t)cue_wire_get_u16(p);
}

static inline int32_t cue_wire_get_i32(const uint8_t *p) {
  return (int32_t)cue_wire_get_u32(p);
}

/* --- Struct codecs (wire order == cue_policy.h declaration order) --------- */

/* RFC 0006 D3: lat, lon, and heading are ZEROED ON THE WIRE — enforced
 * here, inside the codec, so no caller (Phase B BLE included) can ever
 * transmit live GPS by passing an unscrubbed sample (NFR-005). The kernel
 * provably reads none of the three, so the round-trip asymmetry cannot
 * affect determinism. */
static inline void cue_wire_pack_sample(uint8_t *p, const RideSample *s) {
  cue_wire_put_u32(p + 0, s->t_ms);
  cue_wire_put_i32(p + 4, 0);
  cue_wire_put_i32(p + 8, 0);
  cue_wire_put_u16(p + 12, s->speed_cmps);
  cue_wire_put_u16(p + 14, 0);
  cue_wire_put_u32(p + 16, s->segment_id);
}

static inline void cue_wire_unpack_sample(const uint8_t *p, RideSample *s) {
  s->t_ms = cue_wire_get_u32(p + 0);
  s->lat_e7 = cue_wire_get_i32(p + 4);
  s->lon_e7 = cue_wire_get_i32(p + 8);
  s->speed_cmps = cue_wire_get_u16(p + 12);
  s->heading_deg_x10 = cue_wire_get_u16(p + 14);
  s->segment_id = cue_wire_get_u32(p + 16);
}

static inline void cue_wire_pack_event(uint8_t *p, const RouteEvent *e) {
  cue_wire_put_u32(p + 0, e->event_id);
  p[4] = e->family;
  cue_wire_put_u32(p + 5, e->segment_id);
  p[9] = e->severity;
  p[10] = e->confidence;
  cue_wire_put_u16(p + 11, e->reasons_bitmask);
  cue_wire_put_i16(p + 13, e->distance_to_start_m);
  cue_wire_put_i16(p + 15, e->distance_to_end_m);
}

static inline void cue_wire_unpack_event(const uint8_t *p, RouteEvent *e) {
  e->event_id = cue_wire_get_u32(p + 0);
  e->family = p[4];
  e->segment_id = cue_wire_get_u32(p + 5);
  e->severity = p[9];
  e->confidence = p[10];
  e->reasons_bitmask = cue_wire_get_u16(p + 11);
  e->distance_to_start_m = cue_wire_get_i16(p + 13);
  e->distance_to_end_m = cue_wire_get_i16(p + 15);
}

static inline void cue_wire_pack_memory(uint8_t *p, const PersonalMemory *m) {
  cue_wire_put_u32(p + 0, m->segment_id);
  p[4] = m->state;
  p[5] = m->notice_bonus_s;
}

static inline void cue_wire_unpack_memory(const uint8_t *p,
                                          PersonalMemory *m) {
  m->segment_id = cue_wire_get_u32(p + 0);
  m->state = p[4];
  m->notice_bonus_s = p[5];
}

static inline void cue_wire_pack_decision(uint8_t *p, const CueDecision *d) {
  p[0] = d->type;
  cue_wire_put_u32(p + 1, d->event_id);
  p[5] = d->reason_code;
  cue_wire_put_i16(p + 6, d->lead_time_s);
}

static inline void cue_wire_unpack_decision(const uint8_t *p,
                                            CueDecision *d) {
  d->type = p[0];
  d->event_id = cue_wire_get_u32(p + 1);
  d->reason_code = p[5];
  d->lead_time_s = cue_wire_get_i16(p + 6);
}

static inline void cue_wire_pack_config(uint8_t *p,
                                        const CuePolicyConfig *c) {
  p[0] = c->severity_threshold;
  p[1] = c->confidence_threshold;
  cue_wire_put_u16(p + 2, c->min_notice_s);
  cue_wire_put_u16(p + 4, c->max_notice_s);
  cue_wire_put_u16(p + 6, c->min_cooldown_s);
  cue_wire_put_u16(p + 8, c->min_cooldown_m);
  cue_wire_put_u16(p + 10, c->min_speed_kmh);
}

static inline void cue_wire_unpack_config(const uint8_t *p,
                                          CuePolicyConfig *c) {
  c->severity_threshold = p[0];
  c->confidence_threshold = p[1];
  c->min_notice_s = cue_wire_get_u16(p + 2);
  c->max_notice_s = cue_wire_get_u16(p + 4);
  c->min_cooldown_s = cue_wire_get_u16(p + 6);
  c->min_cooldown_m = cue_wire_get_u16(p + 8);
  c->min_speed_kmh = cue_wire_get_u16(p + 10);
}

#ifdef __cplusplus
}
#endif

#endif /* CUE_WIRE_H */
