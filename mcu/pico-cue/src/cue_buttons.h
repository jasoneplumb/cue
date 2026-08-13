/*
 * Intent: The WuKong 2040's A/B buttons (GP18/GP19) as debounced events —
 *         the only input the device has when the phone is in a pocket.
 * Context: RFC 0006 D7, issue #154. Button A is what makes the candidate
 *          patterns comparable on the bike without reflashing or pulling
 *          the phone out; button B answers "how much battery is left".
 * Pattern: Target-only (PICO_BUILD), non-blocking, no interrupts. Emits
 *          events and takes no action itself — what a press MEANS is
 *          composed in main.c, where it can be read in one place rather
 *          than inferred from three modules calling each other.
 */
#ifndef CUE_BUTTONS_H
#define CUE_BUTTONS_H

#ifdef PICO_BUILD

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
  CUE_BUTTON_EVENT_NONE = 0,
  CUE_BUTTON_A_SHORT = 1, /* acknowledge a playing cue, else cycle patterns */
  CUE_BUTTON_A_LONG = 2,  /* fire a local test cue — bench check, no phone  */
  CUE_BUTTON_B_SHORT = 3, /* battery level                                  */
} CueButtonEvent;

/* At most one event per button per poll. */
#define CUE_BUTTON_MAX_EVENTS 2u

void cue_buttons_init(void);

/* Drain pending events into `out`; returns how many were written. Call
 * every main-loop iteration — debouncing is done by sampling, so a slow
 * caller degrades to missed presses rather than to spurious ones. */
uint8_t cue_buttons_poll(CueButtonEvent *out, uint8_t cap);

#ifdef __cplusplus
}
#endif

#endif /* PICO_BUILD */

#endif /* CUE_BUTTONS_H */
