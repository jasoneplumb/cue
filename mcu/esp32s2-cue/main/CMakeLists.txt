# The kernel and the line-protocol module are compiled from their canonical
# locations — nothing is copied, so this port can never drift from the
# sources the host tests and the Pico firmware build (module-boundary rule:
# divergence between live and replay decisions is a bug).
idf_component_register(
  SRCS
    "main.c"
    "cue_tft.c"
    "../../pico-cue/src/cue_usb_replay.c"
    "../../../kernel/cue_policy.c"
  INCLUDE_DIRS
    "."
    "../../pico-cue/src"
    "../../shared"
    "../../../kernel"
  REQUIRES
    esp_lcd
    driver
)
