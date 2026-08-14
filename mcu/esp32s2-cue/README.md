# esp32s2-cue — cue-policy kernel on Adafruit ESP32-S2 Feather TFT

Second MCU port of the RFC 0006 D6 portability certificate:
`kernel/cue_policy.c` and the pico port's I/O-free line-protocol module
(`mcu/pico-cue/src/cue_usb_replay.c`) compiled unmodified for the ESP32-S2
(Xtensa LX7), speaking the same protocol over the S2's native USB-CDC
console — so [`tools/cue-hiltest`](../../tools/cue-hiltest/hiltest.py)
certifies this board with **zero host-side changes**.

The Feather's ST7789 TFT is a cosmetic status surface (solid color fills:
dim blue idle, green traffic, amber HEAD_UP, red malformed line). The
replay port never depends on it; a dark display is not a broken port —
check the pin table in `main/cue_tft.c` against Adafruit's pinout page
first.

## Build

Requires ESP-IDF v5.x:

```sh
. $IDF_PATH/export.sh                 # or ~/esp/esp-idf/export.sh
idf.py -C mcu/esp32s2-cue set-target esp32s2
idf.py -C mcu/esp32s2-cue build
```

## Flash

Hold BOOT, tap RESET, release BOOT (S2 ROM bootloader), then:

```sh
idf.py -C mcu/esp32s2-cue -p /dev/tty.usbmodem* flash
```

Tap RESET after flashing; the board re-enumerates as a USB-CDC device.

## Verify — on-target portability certificate

Same command, same goldens, same comparator proof as the Pico port:

```sh
make -C mcu hiltest PORT=/dev/tty.usbmodemXXXX
make -C mcu hiltest-archive PORT=/dev/tty.usbmodemXXXX   # committed certificate
```

**One certificate run per boot.** The S2's USB-CDC console can wedge when
the host closes the port at the end of a session — a second hiltest run
then times out on PING. That is the console, not the port logic: tap RESET
between runs (the Pico's equivalent ritual is the BOOTSEL dance). Looks
exactly like a broken build; it is not.

The compile-time `static_assert(sizeof(CuePolicyState) == 420)` in
`main/main.c` is the same tripwire the Pico build carries, and the
SESSION-level `state_size` echo in the PING response lets the host verify
it at runtime (see `PORTING.md` for the full three-layer contract).

Status: certified — see the committed pass certificate in
`mcu/hiltest-runs/`. Re-run `hiltest-archive` (with `BOARD=` and
`TOOLCHAIN=xtensa-esp32s2-elf-gcc`) after any kernel or firmware change.
