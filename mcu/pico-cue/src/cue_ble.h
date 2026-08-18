/*
 * Intent: BTstack transport for the Cue Ride Service (RFC 0006 D3) —
 *         advertising, ATT read/write dispatch into cue_session, and
 *         DECISION/CONTROL notifications back to the phone.
 * Context: RFC 0006 D2/D3. This layer owns the radio and the clock; all
 *          protocol decisions live in cue_session.c, which is deliberately
 *          BTstack-free and host-tested.
 * Pattern: Target-only (PICO_BUILD) — the host test builds cue_session
 *          without ever linking BTstack.
 */
#ifndef CUE_BLE_H
#define CUE_BLE_H

#ifdef PICO_BUILD

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Bring up the controller, register the ATT handlers, and start
 * advertising. Returns false if the CYW43 driver or BTstack failed to
 * initialize (the caller keeps the USB replay port running regardless,
 * so a radio failure never costs us the Phase A certification path). */
bool cue_ble_init(void);

/* Non-blocking pump for the main loop. BTstack runs on the pico-sdk's
 * async_context, so this only services deferred work owned by this
 * module (currently the STATUS refresh). */
void cue_ble_poll(void);

/* True while a central is connected and subscribed to DECISION. */
bool cue_ble_is_connected(void);

/* True once the controller came up. Distinguishes the two states that
 * look identical from off the board — "the radio failed" and "someone
 * else already holds the link" — both of which present as a Pico that is
 * not advertising. Reported by the wired DIAG command; guessing between
 * them has cost real debugging time more than once. */
bool cue_ble_is_up(void);

/* True while a central holds the connection (subscribed or not). */
bool cue_ble_has_central(void);

/* Whether a DECISION report is queued but not yet delivered, and for which
 * seq. Exposed for the wired DIAG line only.
 *
 * "The report never arrived" has two causes that are indistinguishable
 * from off the board — it was sent and the central missed it, or it is
 * still sitting here — and that ambiguity is exactly what made #168 hard
 * to pin down. Same reasoning as radio=/link=.
 *
 * seq_out must be non-NULL: it is written only when the function returns
 * true, and left untouched otherwise, so a caller must supply storage to
 * read it from.
 *
 * Callable only from the main loop. decision_pending and the report body
 * are written from ATT callbacks, which — despite the driver being named
 * pico_cyw43_arch_none — run on the pico-sdk async_context's low-priority
 * IRQ and preempt main() (#18, #23), not cooperatively. The implementation
 * takes the cyw43 lock (cyw43_thread_enter/exit) around the read for
 * exactly that reason, and returns false before the driver has come up
 * rather than take an uninitialised lock. */
bool cue_ble_decision_pending(uint16_t *seq_out);

#ifdef __cplusplus
}
#endif

#endif /* PICO_BUILD */

#endif /* CUE_BLE_H */
