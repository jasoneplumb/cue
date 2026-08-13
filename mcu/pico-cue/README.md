# pico-cue — cue-policy kernel on Raspberry Pi Pico W

RFC 0006 Phase A firmware: `kernel/cue_policy.c` cross-built unmodified
for the Pico W (RP2040, Cortex-M0+), serving a USB-CDC line protocol so
[`tools/cue-hiltest`](../../tools/cue-hiltest/hiltest.py) can certify the
port against the same checked-in trace corpus `replay_cli` verifies on
the host — the "portability certificate"
([`docs/audit-tune.md`](../../docs/audit-tune.md)). Evolved from the
draft [`docs/mcu-replay-demo-readme.md`](../../docs/mcu-replay-demo-readme.md).

Phase B added the BLE Cue Ride Service; Phase C added the WuKong 2040
buzzer/LED actuator, the candidate patterns, and the A/B buttons.

## Hardware

- Raspberry Pi Pico W.
- WuKong 2040 carrier — required for anything that makes a sound or a
  light (buzzer GP9, two WS2812B LEDs GP22, buttons GP18/GP19).
- A USB cable with data lines (not charge-only).

> **The WuKong's peripherals run off the WuKong's own power, not the
> Pico's USB.** With a charged 18650 fitted, push the board's power
> switch *down* (its power indicator lights). Powered over USB alone
> with the board switched off, the Pico runs fine — replay, BLE,
> everything — while the LEDs stay dark and the buzzer is weak. Both
> symptoms look exactly like firmware bugs. They are not.

> **The battery millivolts are not a charge gauge.** The WuKong powers
> the Pico through its 3V3 pin, so VSYS — the only supply rail the Pico
> can measure — is unpowered whenever USB is out. Measured on this board:
> **5037 mV on USB, 103 mV on battery**, with BLE running normally in
> both cases (#165). A reading near zero on a board that is plainly alive
> is the expected result, not a fault: `DIAG`'s `supply=` field says
> which case you are in. Reading the 18650's actual charge would need the
> cell wired to a free ADC pin (GP26–28) through a divider.

## Toolchain

- [pico-sdk](https://github.com/raspberrypi/pico-sdk) pinned to `2.3.0`
  with the `lib/tinyusb` submodule checked out. The BLE build links
  BTstack from the pico-sdk — free for open source, but commercial
  products need a [BlueKitchen commercial
  license](https://bluekitchen-gmbh.com/); this repo vendors only its own
  `btstack_config.h` (see README §License).
- ARM GNU Toolchain `14.2.rel1` (`arm-none-eabi-gcc`) — the Homebrew
  `arm-none-eabi-gcc` formula on macOS is missing `newlib` pieces
  (`cannot find -lg`/`-lc` at link time); use the
  [official ARM release](https://developer.arm.com/downloads/-/arm-gnu-toolchain-downloads)
  instead, or `brew install --cask gcc-arm-embedded`.
- `cmake` (3.13+) and `picotool` (for `flash`).

```sh
export PICO_SDK_PATH=~/pico-sdk           # or wherever you cloned it
export PICO_TOOLCHAIN_PATH=~/toolchains/arm-gnu-toolchain-14.2.rel1-*  # if not on PATH
```

## Build

```sh
make -C mcu build          # -> mcu/pico-cue/build/pico_cue.uf2
```

`main.c` asserts `sizeof(CuePolicyState) == 420` at compile time — the
RFC 0006 D6 compiler-width tripwire. If this trips, the ARM struct
layout has drifted from the host build; re-measure both before changing
the constant (see `docs/eval-board-migration-matrix.md`'s caveat on
`_Bool` width under different compilers).

## Flash

1. Unplug the Pico, hold **BOOTSEL**, plug it back in, release. It
   mounts as a `RPI-RP2` USB drive.
2. `make -C mcu flash` (copies the UF2 via `picotool`, then reboots the
   board into the new firmware).

`picotool` cannot force a device running arbitrary firmware into BOOTSEL
without a picoboot interface — step 1's physical button press is
required every time, including for the very first flash.

## Verify — host-side protocol logic (no hardware)

```sh
make -C mcu test           # compiles cue_usb_replay.c against the host
                            # compiler; runs mcu/pico-cue/tests/test_cue_usb_replay.c
```

## Verify — on-target portability certificate (hardware required)

Once flashed and rebooted, find the board's serial device:

```sh
ls /dev/tty.usbmodem*       # macOS
ls /dev/ttyACM*             # Linux
```

```sh
make -C mcu hiltest PORT=/dev/tty.usbmodemXXXX
```

The tool needs `pyserial`. Stock macOS and Homebrew pythons are PEP
668-managed, so a plain `pip install pyserial` is refused system-wide —
the `hiltest` target therefore provisions a throwaway venv under
`mcu/build/hiltest-venv` on first use and reuses it afterwards. If your
interpreter already has pyserial (including via `PYTHON=` pointing at
your own venv), it is used as-is and nothing is created.

This streams every trace in `replay/traces/` to the board and diffs the
returned decisions against each trace's recorded `cue_decisions` — the
same goldens `make -C replay test` verifies on the host — then streams
`replay/tests/config_drift_divergence.json` and asserts a divergence
**is** detected, proving the comparator itself works. All traces must
pass divergence-free and the drift fixture must diverge; this is the
Phase A3 acceptance gate, and the standing regression gate to re-run
after any kernel or firmware change.

To leave a committed record of a pass, run
`make -C mcu hiltest-archive PORT=...` instead: same gate, but the whole
run is captured to `mcu/hiltest-runs/<utc-timestamp>-<short-sha>.log`
with a provenance header and PASS/FAIL trailer, meant to be committed
(see `mcu/hiltest-runs/README.md`).

## GATT caching — read this before debugging a "broken" service

Centrals cache a peripheral's attribute table, and both CoreBluetooth
and iOS cache it aggressively. If you change `cue_gatt.gatt` — add a
characteristic, change a property — a central that has connected before
may keep enforcing the **old** table. The failure does not look like a
cache problem: you get errors describing the previous configuration,
and they persist across reflashes, so the firmware appears to ignore
your change.

Observed instance: a build that briefly required encryption left macOS
returning `CBATTErrorDomain Code=15 "Encryption is insufficient."` on
subscribe, and it kept doing so after the encryption requirement was
removed and verified absent from the generated attribute table.

The service declares `GATT_DATABASE_HASH`, which is the BT 5.1
mechanism for a central to notice the table changed; it does not
declare the legacy Service Changed indication, which would only help
bonded clients whose prior view we tracked.

To clear a stale cache:

- **macOS**: for an unpaired peripheral the entry is a row in the
  `OtherDevices` table of
  `/Library/Bluetooth/com.apple.MobileBluetooth.ledevices.other.db`
  (a bonded one would be in `PairedDevices` in `...ledevices.paired.db`
  instead — check both, the symptom is identical):

  ```sh
  sudo sqlite3 /Library/Bluetooth/com.apple.MobileBluetooth.ledevices.other.db \
    ".dump" | grep -i pico          # find the row and its Uuid
  sudo sqlite3 /Library/Bluetooth/com.apple.MobileBluetooth.ledevices.other.db \
    "DELETE FROM OtherDevices WHERE Uuid='<uuid>';"
  sudo killall -9 bluetoothd
  ```

  Delete by `Uuid`, not by name, and never delete the whole file —
  that unpairs every BLE device including AirPods and Watch unlock.
  **Give `bluetoothd` a few seconds to come back before reconnecting**;
  a run started immediately after the kill can still fail and look like
  the clear did not work.
- **iOS**: Settings > Bluetooth > forget the device if it is bonded;
  otherwise toggle Bluetooth off/on, which clears the unpaired cache.

When a central reports an error the firmware cannot account for, build
with `CUE_BLE_TRACE=1` (see `CMakeLists.txt`) and watch USB stdio while
reproducing. It logs every ATT write with its handle and length, so it
separates "the write never arrived" from "the write arrived and we
rejected it" in a single run — which is what finally settled the case
above.

## Actuation — the candidate patterns (RFC 0006 D7)

Six renderings of a cue ship in `src/cue_pattern.c`, selectable at
runtime, because which one a rider actually notices over road and wind
noise is an empirical question and both retired channels got it wrong:

| # | Name | Probes, relative to candidate 0 |
| --- | --- | --- |
| 0 | `triple-2k3` | baseline: 3+3 bursts of 150 ms at 2300 Hz |
| 1 | `duo-long` | burst count and duty |
| 2 | `low-1k2` | carrier frequency |
| 3 | `syncopated` | rhythm (short-short-LONG) |
| 4 | `sweep` | **default** — rising 1600 → 2300 → 3000 Hz, 400 ms tones |
| 5 | `steady-led` | LED coupling |

Compare them without reflashing:

```sh
make -C mcu blecheck BLECHECK_ARGS="--patterns"     # fire all six in turn
make -C mcu blecheck BLECHECK_ARGS="--pattern 4"    # fire just one
```

On the bike, with the phone pocketed: **button A** short-press cycles the
selection (the LEDs blink index + 1 in white) and long-press fires the
selected pattern; while a cue is playing, short-press acknowledges and
silences it. **Button B** flashes the supply level — magenta ("unknown")
whenever the reading is one the board could not be running on, which on
battery is always, per the note above. A test cue drives
the actuator only — never the kernel — so it can never enter the decision
stream or perturb an FR-004 budget.

### Bench bring-up over USB

Wired-port diagnostics, unreachable over BLE, for separating firmware
faults from hardware ones:

```
DIAG                 -> DIAG leds=ready selected=4 patterns=6
                        supply=usb battery_mv=5037 level=3
                        radio=up link=subscribed
TONE 2300,500        -> hold one tone; how the buzzer's real resonance
                        gets measured rather than assumed
LEDS ff0000,2000     -> force a colour; separates "LED code is wrong"
                        from "pin or power is wrong"
```

## Protocol

See [`src/cue_usb_replay.h`](src/cue_usb_replay.h) for the line
protocol (`PING` / `CFG` / `RESET` / `STEP` → `DEC`) and
[`../shared/cue_wire.h`](../shared/cue_wire.h) for the packed
little-endian wire codec the BLE path (RFC 0006 Phase B) reuses.

## Notes

- Kernel source is compiled unmodified by path reference — one source
  for host, iOS, and MCU (RFC 0003 D3, extended by RFC 0006 D6).
- No dynamic allocation, no OS dependencies, integer-only arithmetic —
  inherited from the kernel itself (NFR-004).
- This is an attention-aid prototype. No crash-prevention, safety,
  medical, or fitness claims are made (spec §3 non-goals).
