/*
 * Intent: Implementation of the A/B button reader (see header).
 * Pattern: Sampled debounce with a stability timer, one small state
 *          machine per button. No GPIO interrupts: a bouncing contact
 *          would fire dozens of them, and an ISR that can fire a cue is
 *          exactly the sort of thing that makes a cue appear when the
 *          rider did not ask for one (NFR-001).
 *
 * A long press emits at the threshold rather than on release, so the
 * rider gets the test cue while still holding the button; the release
 * that follows is deliberately swallowed instead of also reading as a
 * short press.
 */
#ifdef PICO_BUILD

#include "cue_buttons.h"

#include "pico/stdlib.h"

/* WuKong 2040 (RFC 0006 D1). Both buttons pull to ground and are held
 * high by the internal pull-up, so LOW means pressed. */
#define CUE_PIN_BUTTON_A 18u
#define CUE_PIN_BUTTON_B 19u

#define CUE_DEBOUNCE_MS 25u
#define CUE_LONG_PRESS_MS 700u

typedef struct {
  uint8_t pin;
  bool stable_down;    /* debounced state                                  */
  bool raw_down;       /* last raw sample                                  */
  uint32_t raw_since;  /* when raw_down last changed                       */
  uint32_t down_since; /* when stable_down became true                     */
  bool long_emitted;   /* the press already produced a long-press event    */
} CueButton;

static CueButton button_a = {CUE_PIN_BUTTON_A, false, false, 0u, 0u, false};
static CueButton button_b = {CUE_PIN_BUTTON_B, false, false, 0u, 0u, false};

static void button_init(CueButton *b) {
  gpio_init(b->pin);
  gpio_set_dir(b->pin, GPIO_IN);
  gpio_pull_up(b->pin);
}

void cue_buttons_init(void) {
  button_init(&button_a);
  button_init(&button_b);
}

/* Advance one button. Returns the event it produced, if any. `long_ms` of
 * 0 disables long-press detection for that button. */
static CueButtonEvent button_step(CueButton *b, uint32_t now, uint32_t long_ms,
                                  CueButtonEvent short_event,
                                  CueButtonEvent long_event) {
  bool raw = !gpio_get(b->pin); /* active low */
  if (raw != b->raw_down) {
    b->raw_down = raw;
    b->raw_since = now;
    return CUE_BUTTON_EVENT_NONE;
  }
  if (now - b->raw_since < CUE_DEBOUNCE_MS) {
    return CUE_BUTTON_EVENT_NONE; /* still settling */
  }

  if (raw && !b->stable_down) {
    b->stable_down = true;
    b->down_since = now;
    b->long_emitted = false;
    return CUE_BUTTON_EVENT_NONE; /* nothing is decided on press */
  }

  if (raw && b->stable_down && long_ms > 0u && !b->long_emitted &&
      now - b->down_since >= long_ms) {
    b->long_emitted = true;
    return long_event;
  }

  if (!raw && b->stable_down) {
    b->stable_down = false;
    /* A release that already produced a long press is consumed, not
     * replayed as a short one. */
    return b->long_emitted ? CUE_BUTTON_EVENT_NONE : short_event;
  }

  return CUE_BUTTON_EVENT_NONE;
}

uint8_t cue_buttons_poll(CueButtonEvent *out, uint8_t cap) {
  uint32_t now = to_ms_since_boot(get_absolute_time());
  uint8_t count = 0u;

  CueButtonEvent a = button_step(&button_a, now, CUE_LONG_PRESS_MS,
                                 CUE_BUTTON_A_SHORT, CUE_BUTTON_A_LONG);
  if (a != CUE_BUTTON_EVENT_NONE && count < cap) {
    out[count++] = a;
  }

  CueButtonEvent b = button_step(&button_b, now, 0u, CUE_BUTTON_B_SHORT,
                                 CUE_BUTTON_EVENT_NONE);
  if (b != CUE_BUTTON_EVENT_NONE && count < cap) {
    out[count++] = b;
  }

  return count;
}

#endif /* PICO_BUILD */
