/*
 * Intent: Golden byte vectors for the RFC 0006 D3 wire format, asserted
 *         from the C side. The IDENTICAL vectors are asserted in Swift by
 *         ios/CuePicoLink/Tests/CuePicoLinkTests/CuePicoWireTests.swift.
 *         Two independent implementations pinned to one set of bytes: a
 *         change to either encoder that is not made to both fails here or
 *         there, instead of surfacing as a rejected write mid-ride.
 * Context: cue_wire.h is the source of truth; this file is the contract
 *          test that keeps the Swift restatement honest.
 * Pattern: Field values are deliberately asymmetric (distinct, non-zero,
 *          and including negatives) so a byte-order or offset error cannot
 *          coincidentally still match.
 */
#include <stdio.h>
#include <string.h>

#include "cue_wire.h"

static int failures;

static void expect_bytes(const char *what, const uint8_t *got, size_t got_len,
                         const uint8_t *want, size_t want_len) {
  if (got_len != want_len || memcmp(got, want, want_len) != 0) {
    printf("FAIL %s\n  want:", what);
    for (size_t i = 0; i < want_len; i++) printf(" %02x", want[i]);
    printf("\n  got: ");
    for (size_t i = 0; i < got_len; i++) printf(" %02x", got[i]);
    printf("\n");
    failures++;
  }
}

int main(void) {
  /* --- RideSample: lat/lon/heading MUST serialize as zero (NFR-005) ---- */
  {
    RideSample s = {0x12345678u, 455201234, -1226751234, 0x01F4u, 1234u,
                    0xABCDEF01u};
    uint8_t got[CUE_WIRE_SAMPLE_SIZE];
    cue_wire_pack_sample(got, &s);
    const uint8_t want[CUE_WIRE_SAMPLE_SIZE] = {
        0x78, 0x56, 0x34, 0x12, /* t_ms */
        0x00, 0x00, 0x00, 0x00, /* lat_e7 zeroed on the wire */
        0x00, 0x00, 0x00, 0x00, /* lon_e7 zeroed on the wire */
        0xF4, 0x01,             /* speed_cmps */
        0x00, 0x00,             /* heading_deg_x10 zeroed on the wire */
        0x01, 0xEF, 0xCD, 0xAB, /* segment_id */
    };
    expect_bytes("sample", got, sizeof(got), want, sizeof(want));
  }

  /* --- RouteEvent: 17 B packed, negative distances two's complement ---- */
  {
    RouteEvent e = {0x0A0B0C0Du, 1u, 0x11223344u, 0xC8u, 0x64u, 0x0007u,
                    -50, 300};
    uint8_t got[CUE_WIRE_EVENT_SIZE];
    cue_wire_pack_event(got, &e);
    const uint8_t want[CUE_WIRE_EVENT_SIZE] = {
        0x0D, 0x0C, 0x0B, 0x0A, /* event_id */
        0x01,                   /* family */
        0x44, 0x33, 0x22, 0x11, /* segment_id */
        0xC8,                   /* severity */
        0x64,                   /* confidence */
        0x07, 0x00,             /* reasons_bitmask */
        0xCE, 0xFF,             /* distance_to_start_m = -50 */
        0x2C, 0x01,             /* distance_to_end_m = 300 */
    };
    expect_bytes("event", got, sizeof(got), want, sizeof(want));
  }

  /* --- PersonalMemory: 6 B packed (natural struct is 8 B) -------------- */
  {
    PersonalMemory m = {0x00C0FFEEu, 2u, 7u};
    uint8_t got[CUE_WIRE_MEMORY_SIZE];
    cue_wire_pack_memory(got, &m);
    const uint8_t want[CUE_WIRE_MEMORY_SIZE] = {0xEE, 0xFF, 0xC0, 0x00, 0x02,
                                                0x07};
    expect_bytes("memory", got, sizeof(got), want, sizeof(want));
  }

  /* --- CuePolicyConfig: 12 B packed ------------------------------------ */
  {
    CuePolicyConfig c = {128u, 200u, 5u, 15u, 15u, 75u, 4u};
    uint8_t got[CUE_WIRE_CONFIG_SIZE];
    cue_wire_pack_config(got, &c);
    const uint8_t want[CUE_WIRE_CONFIG_SIZE] = {
        0x80, 0xC8, 0x05, 0x00, 0x0F, 0x00, 0x0F, 0x00, 0x4B, 0x00, 0x04, 0x00,
    };
    expect_bytes("config", got, sizeof(got), want, sizeof(want));
  }

  /* --- CueDecision: 8 B packed, negative lead time ---------------------- */
  {
    CueDecision d = {1u, 0x00000007u, 0u, -1};
    uint8_t got[CUE_WIRE_DECISION_SIZE];
    cue_wire_pack_decision(got, &d);
    const uint8_t want[CUE_WIRE_DECISION_SIZE] = {
        0x01,                   /* type */
        0x07, 0x00, 0x00, 0x00, /* event_id */
        0x00,                   /* reason_code */
        0xFF, 0xFF,             /* lead_time_s = -1 */
    };
    expect_bytes("decision", got, sizeof(got), want, sizeof(want));
  }

  /* --- Round-trips: unpack(pack(x)) == x for every codec --------------- */
  {
    RideSample s = {99u, 1, 2, 500u, 900u, 42u};
    uint8_t buf[CUE_WIRE_SAMPLE_SIZE];
    RideSample back;
    cue_wire_pack_sample(buf, &s);
    cue_wire_unpack_sample(buf, &back);
    if (back.t_ms != s.t_ms || back.speed_cmps != s.speed_cmps ||
        back.segment_id != s.segment_id) {
      printf("FAIL sample round-trip: kernel-observable fields changed\n");
      failures++;
    }
    if (back.lat_e7 != 0 || back.lon_e7 != 0 || back.heading_deg_x10 != 0) {
      printf("FAIL sample round-trip: location fields survived the wire\n");
      failures++;
    }

    RouteEvent e = {7u, 1u, 42u, 200u, 200u, 1u, -32768, 32767};
    uint8_t ebuf[CUE_WIRE_EVENT_SIZE];
    RouteEvent eback;
    cue_wire_pack_event(ebuf, &e);
    cue_wire_unpack_event(ebuf, &eback);
    if (eback.event_id != e.event_id || eback.family != e.family ||
        eback.segment_id != e.segment_id || eback.severity != e.severity ||
        eback.confidence != e.confidence ||
        eback.reasons_bitmask != e.reasons_bitmask ||
        eback.distance_to_start_m != e.distance_to_start_m ||
        eback.distance_to_end_m != e.distance_to_end_m) {
      printf("FAIL event round-trip (int16 extremes)\n");
      failures++;
    }

    CueDecision d = {0u, 0xFFFFFFFFu, 11u, 32767};
    uint8_t dbuf[CUE_WIRE_DECISION_SIZE];
    CueDecision dback;
    cue_wire_pack_decision(dbuf, &d);
    cue_wire_unpack_decision(dbuf, &dback);
    if (dback.type != d.type || dback.event_id != d.event_id ||
        dback.reason_code != d.reason_code ||
        dback.lead_time_s != d.lead_time_s) {
      printf("FAIL decision round-trip\n");
      failures++;
    }
  }

  /* --- Sizes the Swift side hardcodes ---------------------------------- */
  {
    struct { const char *name; unsigned got; unsigned want; } sizes[] = {
        {"SAMPLE", CUE_WIRE_SAMPLE_SIZE, 20u},
        {"EVENT", CUE_WIRE_EVENT_SIZE, 17u},
        {"MEMORY", CUE_WIRE_MEMORY_SIZE, 6u},
        {"DECISION", CUE_WIRE_DECISION_SIZE, 8u},
        {"CONFIG", CUE_WIRE_CONFIG_SIZE, 12u},
        {"STEP_MAX", CUE_WIRE_STEP_MAX_SIZE, 302u},
        {"DECISION_REPORT", CUE_WIRE_DECISION_REPORT_SIZE, 17u},
        {"STATUS", CUE_WIRE_STATUS_SIZE, 6u},
        {"RING_CAPACITY", CUE_WIRE_RING_CAPACITY, 600u},
        {"STEP_MAX_EVENTS", CUE_WIRE_STEP_MAX_EVENTS, 16u},
        /* The delay field kept its offset and its width across v2 while
         * changing units, so nothing about the layout can catch a
         * mismatch — only the version can. Pinned here so a bump made
         * without the corresponding Swift change fails on this side. */
        {"PROTO_VERSION", CUE_WIRE_PROTO_VERSION, 2u},
        {"DELAY_US_OFFSET", CUE_WIRE_DECISION_REPORT_DELAY_US_OFFSET, 15u},
        {"STATUS_SUPPLY_OFFSET", CUE_WIRE_STATUS_SUPPLY_OFFSET, 5u},
    };
    for (size_t i = 0; i < sizeof(sizes) / sizeof(sizes[0]); i++) {
      if (sizes[i].got != sizes[i].want) {
        printf("FAIL size %s: %u, want %u\n", sizes[i].name, sizes[i].got,
               sizes[i].want);
        failures++;
      }
    }
  }

  printf(failures ? "FAILURES: %d\n" : "cue_wire: all tests passed\n",
         failures);
  return failures ? 1 : 0;
}
