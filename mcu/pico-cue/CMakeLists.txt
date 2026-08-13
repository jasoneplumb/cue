# pico-cue firmware (RFC 0006). Compiles kernel/cue_policy.c unmodified by
# path reference — one kernel source for host, iOS, and MCU (RFC 0003 D3
# extended by RFC 0006 D6). Requires PICO_SDK_PATH or fetch-from-git.
cmake_minimum_required(VERSION 3.13)

set(PICO_BOARD pico_w CACHE STRING "Board type")

include(pico_sdk_import.cmake)

project(pico_cue C CXX ASM)
set(CMAKE_C_STANDARD 11)

pico_sdk_init()

add_executable(pico_cue
  src/main.c
  src/cue_usb_replay.c
  src/cue_session.c
  src/cue_ble.c
  src/cue_pattern.c
  src/cue_actuator.c
  src/cue_buttons.c
  src/cue_power.c
  ${CMAKE_CURRENT_LIST_DIR}/../../kernel/cue_policy.c
)

# WS2812B timing is far too tight to bit-bang while BTstack owns the CPU;
# the LEDs run from a PIO program instead (see src/ws2812.pio). Generates
# ws2812.pio.h into the build dir and puts it on the include path.
pico_generate_pio_header(pico_cue ${CMAKE_CURRENT_LIST_DIR}/src/ws2812.pio)

target_include_directories(pico_cue PRIVATE
  ${CMAKE_CURRENT_LIST_DIR}/src
  ${CMAKE_CURRENT_LIST_DIR}/../shared
  ${CMAKE_CURRENT_LIST_DIR}/../../kernel
)

# Generates cue_gatt.h (attribute handles + profile_data) from
# cue_gatt.gatt and puts its output dir on the include path. The header
# takes its name from the .gatt file, hence the doubled name — "cue.h"
# would be too generic to sit on a global include path. The UUIDs there
# are mirrored in mcu/shared/cue_wire.h for the iOS central — change
# both together (RFC 0006 D3).
pico_btstack_make_gatt_header(pico_cue PRIVATE
  ${CMAKE_CURRENT_LIST_DIR}/cue_gatt.gatt)

# PICO_BUILD gates the stdio pump in cue_usb_replay.c so the protocol logic
# compiles host-side too (hiltest golden-vector reuse, Phase A3).
target_compile_definitions(pico_cue PRIVATE PICO_BUILD=1)
# Add CUE_BLE_TRACE=1 above to log every ATT write and security event to
# USB stdio. Invaluable when a central reports an error the firmware
# cannot see: it distinguishes "the write never arrived" from "the write
# arrived and we rejected it" in one run.

# Strict flags apply to OUR sources only. A target-wide
# target_compile_options would also hit the SDK's and BTstack's vendored
# .c files (they arrive as INTERFACE sources), where -Werror fails on
# warnings we neither caused nor can fix without patching upstream.
set_source_files_properties(
  src/main.c
  src/cue_usb_replay.c
  src/cue_session.c
  src/cue_ble.c
  src/cue_pattern.c
  src/cue_actuator.c
  src/cue_buttons.c
  src/cue_power.c
  ${CMAKE_CURRENT_LIST_DIR}/../../kernel/cue_policy.c
  PROPERTIES COMPILE_OPTIONS "-Wall;-Wextra;-Werror")

target_link_libraries(pico_cue
  pico_stdlib
  pico_btstack_ble
  pico_btstack_cyw43
  pico_btstack_flash_bank  # persistent bonding (see cue_ble_init)
  pico_cyw43_arch_none
  hardware_pwm             # buzzer, GP9
  hardware_pio             # WS2812B LEDs, GP22
  hardware_adc             # VSYS battery sense
  hardware_clocks
)

pico_enable_stdio_usb(pico_cue 1)
pico_enable_stdio_uart(pico_cue 0)

pico_add_extra_outputs(pico_cue)
