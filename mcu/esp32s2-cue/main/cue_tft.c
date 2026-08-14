/*
 * Intent: cue_tft.h implementation — ST7789 over SPI via esp_lcd, solid
 *         fills only. See the header for why this is deliberately dumb.
 * Context: Pin assignments are the Adafruit ESP32-S2 Feather TFT's
 *          (constraint: verify against Adafruit's pinout page before
 *          trusting a dark display — a wrong pin here looks exactly like a
 *          broken build and is not one; the replay port runs regardless).
 * Pattern: We fill the panel's full native 240x320 window with row strips,
 *          which covers the visible 240x135 region on every module offset
 *          variant without any offset math.
 */
#include "cue_tft.h"

#include "driver/gpio.h"
#include "driver/spi_master.h"
#include "esp_lcd_panel_io.h"
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_panel_vendor.h"
#include "esp_log.h"

/* Adafruit ESP32-S2 Feather TFT (verify against the Adafruit pinout). */
#define TFT_PIN_SCK 36
#define TFT_PIN_MOSI 35
#define TFT_PIN_CS 7
#define TFT_PIN_DC 39
#define TFT_PIN_RST 40
#define TFT_PIN_BACKLIGHT 45
#define TFT_PIN_I2C_POWER 21 /* also gates the TFT rail on this board */

#define TFT_NATIVE_W 240
#define TFT_NATIVE_H 320
#define TFT_STRIP_ROWS 8

static const char *TAG = "cue_tft";
static esp_lcd_panel_handle_t s_panel; /* NULL = display latched off */
static esp_lcd_panel_io_handle_t s_io;

static void fill(uint16_t rgb565) {
  static uint16_t strip[TFT_NATIVE_W * TFT_STRIP_ROWS];
  if (s_panel == NULL) {
    return;
  }
  for (int i = 0; i < TFT_NATIVE_W * TFT_STRIP_ROWS; i++) {
    strip[i] = rgb565;
  }
  for (int y = 0; y < TFT_NATIVE_H; y += TFT_STRIP_ROWS) {
    if (esp_lcd_panel_draw_bitmap(s_panel, 0, y, TFT_NATIVE_W,
                                  y + TFT_STRIP_ROWS, strip) != ESP_OK) {
      /* Latch off SILENTLY: the IDF log sink shares the USB-CDC channel
       * with the protocol stream (CONFIG_ESP_CONSOLE_USB_CDC), so a log
       * line mid-session would be read as the next request's response and
       * desync the host. Init-time logging (before any session) is fine;
       * in-session logging is not. Release everything so a future re-init
       * (e.g. after a task restart) is not poisoned by a held SPI bus. */
      esp_lcd_panel_del(s_panel);
      s_panel = NULL;
      if (s_io != NULL) {
        esp_lcd_panel_io_del(s_io);
        s_io = NULL;
      }
      spi_bus_free(SPI2_HOST);
      return;
    }
  }
}

void cue_tft_init(void) {
  gpio_config_t power = {
      .pin_bit_mask = (1ULL << TFT_PIN_BACKLIGHT) | (1ULL << TFT_PIN_I2C_POWER),
      .mode = GPIO_MODE_OUTPUT,
  };
  if (gpio_config(&power) != ESP_OK) {
    ESP_LOGW(TAG, "gpio config failed — display off");
    return;
  }
  gpio_set_level(TFT_PIN_I2C_POWER, 1);
  gpio_set_level(TFT_PIN_BACKLIGHT, 1);

  spi_bus_config_t bus = {
      .sclk_io_num = TFT_PIN_SCK,
      .mosi_io_num = TFT_PIN_MOSI,
      .miso_io_num = -1,
      .quadwp_io_num = -1,
      .quadhd_io_num = -1,
      .max_transfer_sz = TFT_NATIVE_W * TFT_STRIP_ROWS * 2,
  };
  if (spi_bus_initialize(SPI2_HOST, &bus, SPI_DMA_CH_AUTO) != ESP_OK) {
    ESP_LOGW(TAG, "spi bus init failed — display off");
    return;
  }

  esp_lcd_panel_io_spi_config_t io_cfg = {
      .dc_gpio_num = TFT_PIN_DC,
      .cs_gpio_num = TFT_PIN_CS,
      .pclk_hz = 20 * 1000 * 1000,
      .spi_mode = 0,
      .trans_queue_depth = 4,
      .lcd_cmd_bits = 8,
      .lcd_param_bits = 8,
  };
  esp_lcd_panel_io_handle_t io;
  if (esp_lcd_new_panel_io_spi((esp_lcd_spi_bus_handle_t)SPI2_HOST, &io_cfg,
                               &io) != ESP_OK) {
    ESP_LOGW(TAG, "panel io failed — display off");
    spi_bus_free(SPI2_HOST);
    return;
  }

  esp_lcd_panel_dev_config_t panel_cfg = {
      .reset_gpio_num = TFT_PIN_RST,
      .rgb_ele_order = LCD_RGB_ELEMENT_ORDER_RGB,
      .bits_per_pixel = 16,
  };
  esp_lcd_panel_handle_t panel = NULL;
  if (esp_lcd_new_panel_st7789(io, &panel_cfg, &panel) != ESP_OK) {
    ESP_LOGW(TAG, "panel create failed — display off");
    esp_lcd_panel_io_del(io);
    spi_bus_free(SPI2_HOST);
    return;
  }
  /* invert_color(true): the Feather's ST7789 module is an inverted panel —
   * without this every status color renders as its RGB complement. */
  if (esp_lcd_panel_reset(panel) != ESP_OK ||
      esp_lcd_panel_init(panel) != ESP_OK ||
      esp_lcd_panel_invert_color(panel, true) != ESP_OK ||
      esp_lcd_panel_disp_on_off(panel, true) != ESP_OK) {
    ESP_LOGW(TAG, "panel init failed — display off");
    esp_lcd_panel_del(panel);
    esp_lcd_panel_io_del(io);
    spi_bus_free(SPI2_HOST);
    return;
  }
  s_io = io;
  s_panel = panel;
  ESP_LOGI(TAG, "ST7789 up");
}

void cue_tft_status(CueTftStatus status) {
  /* RGB565: dim blue / green / amber / red — indexed by CueTftStatus. */
  static const uint16_t colors[] = {0x000A, 0x0400, 0xFD20, 0xF800};
  _Static_assert(sizeof(colors) / sizeof(colors[0]) == CUE_TFT_ERROR + 1,
                 "colors[] must cover every CueTftStatus enumerator");
  static int last = -1; /* int, not the enum: -1 sentinel is well-defined */
  if ((int)status == last ||
      status > CUE_TFT_ERROR) { /* defensive: unknown status = no repaint */
    return; /* full fills are slow; only repaint on change */
  }
  last = (int)status;
  fill(colors[status]);
}
