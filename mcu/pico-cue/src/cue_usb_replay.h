/*
 * Intent: USB-CDC line protocol for host-driven on-target replay — the
 *         RFC 0006 D6 portability-certificate transport. The host
 *         (tools/cue-hiltest) streams checked-in traces line-by-line and
 *         compares the returned decisions against the recorded goldens.
 * Context: RFC 0006 D6; replay/replay_main.c is the host-side twin whose
 *          verification semantics this port must reproduce on target.
 * Pattern: Pure line handler (string in, string out) separated from the
 *          stdio poll loop, so the protocol logic itself is host-testable
 *          and I/O-free (mirrors the kernel's caller-owned-state style).
 *
 * Protocol (one request line -> one response line, ASCII, LF-terminated):
 *   PING                       -> PONG proto=<n> fw=<ver> state_size=<n>
 *   CFG s,c,minn,maxn,cds,cdm,minspd
 *                              -> OK        (stores config, re-inits state)
 *   RESET                      -> OK        (re-init; stored config or defaults)
 *   STEP t_ms,speed_cmps,heading_x10,segment_id,n[;E id,family,seg,sev,conf,
 *        reasons,dstart,dend]*n[;M seg,state,bonus]
 *                              -> DEC type,event_id,reason_code,lead_time_s
 *   anything else / malformed  -> ERR <reason>
 *
 * Samples carry no lat/lon by construction, and the heading field —
 * accepted syntactically because the checked-in traces record it — is
 * zeroed before the kernel step, so this port is bit-identical to the BLE
 * path for every kernel-observable field (RFC 0006 D3: coordinates and
 * heading are zeroed on the wire; the kernel provably reads none of them).
 */
#ifndef CUE_USB_REPLAY_H
#define CUE_USB_REPLAY_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Longest well-formed request: STEP header + 16 events + memory. */
#define CUE_USB_REPLAY_LINE_MAX 1024u
/* Sized by DIAG, which is far and away the longest response. At its
 * widest — every field at its longest rendering — it is about 135 bytes:
 *
 *   DIAG leds=unavailable selected=31 patterns=32 supply=unknown
 *   battery_mv=65535 level=3 radio=down link=advertising
 *   pending_decision=65535
 *
 * 128 truncated that, and -Wformat-truncation caught it at build time
 * rather than leaving a clipped diagnostic to be misread on a bench. */
#define CUE_USB_REPLAY_RESPONSE_MAX 192u

/* Reset protocol state: default config, fresh kernel state. */
void cue_usb_replay_init(void);

/* Handle one request line (no trailing newline); writes one response line
 * (no trailing newline) into out. Always writes something. */
void cue_usb_replay_handle_line(const char *line, char *out, size_t out_cap);

#ifdef PICO_BUILD
/* Pump stdio: assemble incoming characters into lines, dispatch each
 * through cue_usb_replay_handle_line, print the response. Non-blocking;
 * call from the main loop. Target-only, like its implementation — a host
 * build that called it would otherwise fail at link, not compile. */
void cue_usb_replay_poll(void);
#endif

#ifdef __cplusplus
}
#endif

#endif /* CUE_USB_REPLAY_H */
