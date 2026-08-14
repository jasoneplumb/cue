/*
 * Intent: ESP32-S2 port of the on-target replay certificate — the same
 *         kernel and the same USB line protocol as mcu/pico-cue, pumped
 *         through the S2's USB-CDC console, so tools/cue-hiltest certifies
 *         this board with zero host-side changes.
 * Context: RFC 0006 D6 portability certificate; cue_usb_replay.h documents
 *          the protocol. Board: Adafruit ESP32-S2 Feather TFT (the TFT is a
 *          cosmetic status surface — see cue_tft.h; replay works without it).
 * Pattern: Blocking line pump in the main task. The protocol handler is
 *          I/O-free (string in, string out); this file only moves bytes.
 */
#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "cue_policy.h"
#include "cue_tft.h"
#include "cue_usb_replay.h"

/* RFC 0006 D6 compiler-width tripwire, same value the Pico build asserts
 * and SESSION_ACK echoes: if the Xtensa struct layout drifts from the host
 * build, fail the compile, not the certificate. */
static_assert(sizeof(CuePolicyState) == 420,
              "CuePolicyState layout drifted from the certified 420 bytes");

void app_main(void) {
  static char line[CUE_USB_REPLAY_LINE_MAX];
  size_t len = 0;
  bool overflow = false;

  cue_usb_replay_init();
  cue_tft_init(); /* best-effort; failures are logged, never fatal */
  cue_tft_status(CUE_TFT_IDLE);

  for (;;) {
    int c = fgetc(stdin);
    if (c < 0) {
      /* Console not connected yet / EOF: yield instead of busy-spinning a
       * core (the Pico pump's getchar_timeout_us provides this implicitly). */
      vTaskDelay(pdMS_TO_TICKS(10));
      continue;
    }
    if (c == '\r') {
      continue;
    }
    if (c != '\n') {
      if (len + 1 < sizeof(line)) {
        line[len++] = (char)c;
      } else {
        overflow = true; /* discard until newline, then report — same
                          * semantics as the Pico pump (NFR-003 parity):
                          * a truncated line must never reach the kernel. */
      }
      continue;
    }
    line[len] = '\0';
    len = 0;
    if (overflow) {
      overflow = false;
      printf("ERR line too long\n");
      fflush(stdout);
      cue_tft_status(CUE_TFT_ERROR);
      continue;
    }
    /* Stack-local like the Pico pump: a handler that fails to write must
     * not silently echo the previous response (portability blindness). */
    char out[CUE_USB_REPLAY_RESPONSE_MAX];
    cue_usb_replay_handle_line(line, out, sizeof(out));
    /* One request line -> one response line, LF-terminated. */
    printf("%s\n", out);
    fflush(stdout);
    /* The literal "DEC 1," encodes CUE_HEAD_UP's wire value; pin it so a
     * renumbered enum fails the build instead of silently dimming the TFT. */
    _Static_assert(CUE_HEAD_UP == 1, "DEC prefix below assumes CUE_HEAD_UP == 1");
    if (strncmp(out, "DEC 1,", 6) == 0) {
      cue_tft_status(CUE_TFT_CUE); /* HEAD_UP decided this step */
    } else if (strncmp(out, "ERR", 3) == 0) {
      cue_tft_status(CUE_TFT_ERROR);
    } else {
      cue_tft_status(CUE_TFT_ACTIVE);
    }
  }
}
