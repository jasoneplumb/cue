/*
 * Intent: Implementation of the USB-CDC replay line protocol (see header).
 * Pattern: Static caller-owned kernel state, no allocation; hand-rolled
 *          unsigned/signed field parsers with explicit range checks so a
 *          malformed line yields ERR, never a silently-truncated step —
 *          the same fail-loudly stance as the RFC 0006 D3 flags rule.
 */
#include "cue_usb_replay.h"

#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "cue_policy.h"
#include "cue_wire.h"

#ifndef CUE_FW_VERSION
#define CUE_FW_VERSION "0.1.0"
#endif

static CuePolicyState replay_state;
static CuePolicyConfig replay_config;
static bool replay_config_set;

void cue_usb_replay_init(void) {
  replay_config_set = false;
  cue_policy_default_config(&replay_config);
  cue_policy_init(&replay_state, NULL);
}

/* --- Field parsing --------------------------------------------------------- */

/* Parse an unsigned decimal field bounded by max, advancing *cursor past it
 * and the single following separator when sep != '\0'. Returns false on
 * empty field, non-digit, or overflow. */
static bool parse_u32_field(const char **cursor, char sep, uint32_t max,
                            uint32_t *out) {
  const char *p = *cursor;
  uint32_t value = 0;
  bool any = false;
  while (*p >= '0' && *p <= '9') {
    uint32_t digit = (uint32_t)(*p - '0');
    /* digit > max would underflow the subtraction below; unreachable at
     * current call sites (every max >= 16) but guarded, not latent. */
    if (digit > max || value > (max - digit) / 10u) {
      return false;
    }
    value = value * 10u + digit;
    any = true;
    p++;
  }
  if (!any) {
    return false;
  }
  if (sep != '\0') {
    if (*p != sep) {
      return false;
    }
    p++;
  }
  *cursor = p;
  *out = value;
  return true;
}

/* Signed variant for the distance fields (int16_t range). */
static bool parse_i16_field(const char **cursor, char sep, int16_t *out) {
  const char *p = *cursor;
  bool negative = false;
  if (*p == '-') {
    negative = true;
    p++;
  }
  uint32_t magnitude;
  if (!parse_u32_field(&p, sep, negative ? 32768u : 32767u, &magnitude)) {
    return false;
  }
  *cursor = p;
  *out = negative ? (int16_t)-(int32_t)magnitude : (int16_t)magnitude;
  return true;
}

/* --- Request handlers ------------------------------------------------------ */

static void respond(char *out, size_t out_cap, const char *text) {
  snprintf(out, out_cap, "%s", text);
}

static void handle_ping(char *out, size_t out_cap) {
  snprintf(out, out_cap, "PONG proto=%u fw=%s state_size=%u",
           (unsigned)CUE_WIRE_PROTO_VERSION, CUE_FW_VERSION,
           (unsigned)sizeof(CuePolicyState));
}

static void handle_cfg(const char *args, char *out, size_t out_cap) {
  const char *p = args;
  uint32_t severity, confidence, min_notice, max_notice;
  uint32_t cooldown_s, cooldown_m, min_speed;
  if (!parse_u32_field(&p, ',', UINT8_MAX, &severity) ||
      !parse_u32_field(&p, ',', UINT8_MAX, &confidence) ||
      !parse_u32_field(&p, ',', UINT16_MAX, &min_notice) ||
      !parse_u32_field(&p, ',', UINT16_MAX, &max_notice) ||
      !parse_u32_field(&p, ',', UINT16_MAX, &cooldown_s) ||
      !parse_u32_field(&p, ',', UINT16_MAX, &cooldown_m) ||
      !parse_u32_field(&p, '\0', UINT16_MAX, &min_speed) || *p != '\0') {
    respond(out, out_cap, "ERR malformed CFG");
    return;
  }
  replay_config.severity_threshold = (uint8_t)severity;
  replay_config.confidence_threshold = (uint8_t)confidence;
  replay_config.min_notice_s = (uint16_t)min_notice;
  replay_config.max_notice_s = (uint16_t)max_notice;
  replay_config.min_cooldown_s = (uint16_t)cooldown_s;
  replay_config.min_cooldown_m = (uint16_t)cooldown_m;
  replay_config.min_speed_kmh = (uint16_t)min_speed;
  replay_config_set = true;
  cue_policy_init(&replay_state, &replay_config);
  respond(out, out_cap, "OK");
}

static void handle_reset(char *out, size_t out_cap) {
  cue_policy_init(&replay_state, replay_config_set ? &replay_config : NULL);
  respond(out, out_cap, "OK");
}

static void handle_step(const char *args, char *out, size_t out_cap) {
  const char *p = args;
  uint32_t t_ms, speed, heading, segment, count;
  if (!parse_u32_field(&p, ',', UINT32_MAX, &t_ms) ||
      !parse_u32_field(&p, ',', UINT16_MAX, &speed) ||
      !parse_u32_field(&p, ',', 3599u, &heading) || /* 359.9 deg * 10 */
      !parse_u32_field(&p, ',', UINT32_MAX, &segment) ||
      !parse_u32_field(&p, '\0', CUE_WIRE_STEP_MAX_EVENTS, &count)) {
    respond(out, out_cap, "ERR malformed STEP header");
    return;
  }

  RideSample sample;
  sample.t_ms = t_ms;
  sample.lat_e7 = 0; /* coordinates and heading never reach the kernel   */
  sample.lon_e7 = 0; /* through this port (RFC 0006 D3) — heading is     */
  sample.heading_deg_x10 = 0; /* parsed for validation, then discarded.  */
  (void)heading;
  sample.speed_cmps = (uint16_t)speed;
  sample.segment_id = segment;

  RouteEvent events[CUE_WIRE_STEP_MAX_EVENTS];
  for (uint32_t i = 0; i < count; i++) {
    if (p[0] != ';' || p[1] != 'E' || p[2] != ' ') {
      respond(out, out_cap, "ERR expected event section");
      return;
    }
    p += 3;
    uint32_t event_id, family, ev_segment, sev, conf, reasons;
    if (!parse_u32_field(&p, ',', UINT32_MAX, &event_id) ||
        !parse_u32_field(&p, ',', UINT8_MAX, &family) ||
        !parse_u32_field(&p, ',', UINT32_MAX, &ev_segment) ||
        !parse_u32_field(&p, ',', UINT8_MAX, &sev) ||
        !parse_u32_field(&p, ',', UINT8_MAX, &conf) ||
        !parse_u32_field(&p, ',', UINT16_MAX, &reasons) ||
        !parse_i16_field(&p, ',', &events[i].distance_to_start_m) ||
        !parse_i16_field(&p, '\0', &events[i].distance_to_end_m)) {
      respond(out, out_cap, "ERR malformed event");
      return;
    }
    events[i].event_id = event_id;
    events[i].family = (uint8_t)family;
    events[i].segment_id = ev_segment;
    events[i].severity = (uint8_t)sev;
    events[i].confidence = (uint8_t)conf;
    events[i].reasons_bitmask = (uint16_t)reasons;
  }

  PersonalMemory memory;
  const PersonalMemory *memory_ptr = NULL;
  if (p[0] == ';' && p[1] == 'M' && p[2] == ' ') {
    p += 3;
    uint32_t mem_segment, mem_state, mem_bonus;
    if (!parse_u32_field(&p, ',', UINT32_MAX, &mem_segment) ||
        !parse_u32_field(&p, ',', UINT8_MAX, &mem_state) ||
        !parse_u32_field(&p, '\0', UINT8_MAX, &mem_bonus)) {
      respond(out, out_cap, "ERR malformed memory");
      return;
    }
    memory.segment_id = mem_segment;
    memory.state = (uint8_t)mem_state;
    memory.notice_bonus_s = (uint8_t)mem_bonus;
    memory_ptr = &memory;
  }
  if (*p != '\0') {
    respond(out, out_cap, "ERR trailing input");
    return;
  }

  CueDecision decision = cue_policy_step(&replay_state, &sample, events,
                                         (uint8_t)count, memory_ptr);
  snprintf(out, out_cap, "DEC %u,%" PRIu32 ",%u,%d", (unsigned)decision.type,
           decision.event_id, (unsigned)decision.reason_code,
           (int)decision.lead_time_s);
}

void cue_usb_replay_handle_line(const char *line, char *out, size_t out_cap) {
  if (strcmp(line, "PING") == 0) {
    handle_ping(out, out_cap);
  } else if (strncmp(line, "CFG ", 4) == 0) {
    handle_cfg(line + 4, out, out_cap);
  } else if (strcmp(line, "RESET") == 0) {
    handle_reset(out, out_cap);
  } else if (strncmp(line, "STEP ", 5) == 0) {
    handle_step(line + 5, out, out_cap);
  } else if (line[0] == '\0') {
    respond(out, out_cap, "ERR empty line");
  } else {
    respond(out, out_cap, "ERR unknown command");
  }
}

/* --- stdio pump (target-only) ---------------------------------------------- */

#ifdef PICO_BUILD
#include <stdlib.h>

#include "pico/stdlib.h"

#include "cue_actuator.h"
#include "cue_ble.h"
#include "cue_power.h"

/* Bench diagnostics live HERE rather than in the pure line handler above,
 * and deliberately so: that handler is the RFC 0006 D6 portability
 * certificate's protocol, compiled and asserted host-side with no
 * hardware in the picture. Hardware probes cannot live in it without
 * making it un-host-testable. Everything below is wired-port only and
 * unreachable over BLE, so nothing here can put a sound on a ride.
 *
 *   TONE <hz>,<ms>   hold one tone — how this buzzer's real resonance
 *                    gets measured instead of assumed
 *   LEDS <rrggbb>,<ms>  force a colour — separates "LED code is wrong"
 *                    from "pin or pixels are wrong"
 *   DIAG             report actuator readiness and the selected pattern
 *
 * Returns true when the line was a diagnostic (response written). */
static bool handle_diagnostic(const char *line, char *out, size_t out_cap) {
  if (strcmp(line, "DIAG") == 0) {
    /* Battery is sampled here rather than only over BLE so the VSYS path
     * can be read without a radio link — D5 makes "battery survives the
     * ride" a gate metric, and a gate fed by an unverified number is
     * worth nothing. Main-loop context, so borrowing GPIO29 back from the
     * CYW43 is safe (see cue_power.c). */
    uint16_t mv;
    uint8_t supply;
    cue_power_sample(&mv, &supply);
    /* radio/link are reported because "not advertising" has two causes
     * that look identical from off the board — the controller failed, or
     * a central already holds the link — and guessing between them has
     * cost real debugging time. */
    snprintf(out, out_cap,
             "DIAG leds=%s selected=%u patterns=%u supply=%s battery_mv=%u "
             "level=%u radio=%s link=%s",
             cue_actuator_leds_ready() ? "ready" : "unavailable",
             (unsigned)cue_actuator_selected(), (unsigned)cue_pattern_count(),
             /* Which supply the millivolts were measured against. Without
              * it the number is unreadable off the board — see #165. */
             cue_power_supply_name(supply),
             (unsigned)mv, (unsigned)cue_power_level(mv),
             cue_ble_is_up() ? "up" : "down",
             cue_ble_has_central()
                 ? (cue_ble_is_connected() ? "subscribed" : "connected")
                 : "advertising");
    return true;
  }
  if (strncmp(line, "TONE ", 5) == 0) {
    const char *p = line + 5;
    char *end = NULL;
    unsigned long hz = strtoul(p, &end, 10);
    if (end == p || *end != ',' || hz > 20000ul) {
      snprintf(out, out_cap, "ERR malformed TONE");
      return true;
    }
    p = end + 1;
    unsigned long ms = strtoul(p, &end, 10);
    if (end == p || *end != '\0' || ms > 5000ul) {
      snprintf(out, out_cap, "ERR malformed TONE");
      return true;
    }
    cue_actuator_tone((uint16_t)hz, (uint16_t)ms);
    snprintf(out, out_cap, "OK tone %lu Hz %lu ms", hz, ms);
    return true;
  }
  if (strncmp(line, "LEDS ", 5) == 0) {
    const char *p = line + 5;
    char *end = NULL;
    unsigned long rgb = strtoul(p, &end, 16);
    if (end == p || *end != ',' || rgb > 0xFFFFFFul) {
      snprintf(out, out_cap, "ERR malformed LEDS");
      return true;
    }
    p = end + 1;
    unsigned long ms = strtoul(p, &end, 10);
    if (end == p || *end != '\0' || ms > 10000ul) {
      snprintf(out, out_cap, "ERR malformed LEDS");
      return true;
    }
    cue_actuator_led_probe((uint32_t)rgb, (uint16_t)ms);
    snprintf(out, out_cap, "OK leds %06lx %lu ms (pio %s)", rgb, ms,
             cue_actuator_leds_ready() ? "ready" : "unavailable");
    return true;
  }
  return false;
}

void cue_usb_replay_poll(void) {
  static char line[CUE_USB_REPLAY_LINE_MAX];
  static size_t length;
  static bool overflow;

  for (;;) {
    int c = getchar_timeout_us(0);
    if (c == PICO_ERROR_TIMEOUT) {
      return;
    }
    if (c == '\r') {
      continue;
    }
    if (c != '\n') {
      if (length + 1 < sizeof(line)) {
        line[length++] = (char)c;
      } else {
        overflow = true; /* discard until newline, then report */
      }
      continue;
    }
    line[length] = '\0';
    char response[CUE_USB_REPLAY_RESPONSE_MAX];
    if (overflow) {
      snprintf(response, sizeof(response), "ERR line too long");
    } else if (!handle_diagnostic(line, response, sizeof(response))) {
      cue_usb_replay_handle_line(line, response, sizeof(response));
    }
    printf("%s\n", response);
    length = 0;
    overflow = false;
  }
}
#endif /* PICO_BUILD */
