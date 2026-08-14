/*
 * Intent: Minimal status surface on the Feather's ST7789 TFT — full-screen
 *         color fills only (no fonts, no framebuffer), enough to see the
 *         replay session breathing from across a desk.
 * Context: Adafruit ESP32-S2 Feather TFT, 240x135 ST7789 on SPI. The TFT is
 *          strictly cosmetic: every function is best-effort and the replay
 *          port never depends on it.
 * Pattern: Failures log and latch the module off; callers never check.
 */
#ifndef CUE_TFT_H
#define CUE_TFT_H

typedef enum {
  CUE_TFT_IDLE = 0,   /* dim blue — booted, no session */
  CUE_TFT_ACTIVE = 1, /* green — protocol traffic flowing */
  CUE_TFT_CUE = 2,    /* amber — a HEAD_UP was decided this step */
  CUE_TFT_ERROR = 3,  /* red — malformed request line */
} CueTftStatus;

void cue_tft_init(void);
void cue_tft_status(CueTftStatus status);

#endif /* CUE_TFT_H */
