# Porting the Cue-Policy Kernel

How to carry the kernel to a new MCU or toolchain, and what it takes for a
port to count as certified. The worked examples are
[`mcu/pico-cue`](mcu/pico-cue/) (Raspberry Pi Pico W, RP2040 Cortex-M0+)
and [`mcu/esp32s2-cue`](mcu/esp32s2-cue/) (Adafruit ESP32-S2 Feather TFT,
Xtensa LX7) — both compile the kernel unmodified by path reference — one
source for host, iOS, and every MCU.

> This is an attention-aid prototype. No crash-prevention, safety, medical,
> or fitness claims are made (spec §3 non-goals).

## What porting means here

The kernel is exactly two files:

- [`kernel/cue_policy.h`](kernel/cue_policy.h)
- [`kernel/cue_policy.c`](kernel/cue_policy.c)

They compile standalone with `-std=c99 -Wall -Wextra -Werror -pedantic`,
include only `<stdint.h>`/`<stdbool.h>`, use integer-only arithmetic, and
perform no dynamic allocation and no OS calls (NFR-004). State is
caller-owned (`CuePolicyState` lives wherever you put it), and the API is a
pure step function: `cue_policy_init`, `cue_policy_default_config`,
`cue_policy_step`.

**Compile those two files with your toolchain. That is the whole port.**
Everything else — timebase glue that produces `t_ms`, the transport that
delivers samples and route events, whatever renders a cue — is
board-specific adapter code that lives outside the kernel and changes
nothing inside it. Map matching and route-event generation stay phone-side;
only normalized samples, compact route events, and the kernel migrate to
the MCU.

## Footprint budget

Two independent measured builds of the same `kernel/cue_policy.c`
(reproduce commands in
[`docs/eval-board-migration-matrix.md`](docs/eval-board-migration-matrix.md),
"Measured kernel footprint"):

| Metric | Host x86_64 (Apple clang, `-O2`) | Cortex-M0+ (arm-none-eabi-gcc 14.2, `-O3`) |
| --- | --- | --- |
| Code | 1,249 B | **1,016 B** (linked `.text`) |
| Initialized data / BSS | 0 B | 0 B |
| `CuePolicyState` (RAM) | 420 B | **420 B** |
| Worst-case stack per call | 48 B | **72 B** (`cue_policy_step`; `init` 8 B, `default_config` 0 B) |
| `RideSample` / `RouteEvent` / `CueDecision` | 20 B / 20 B / 12 B | 20 B / 20 B / 12 B |

Stack figures are `-fstack-usage` output; all entry points report `static`
usage (no alloca, no VLAs). A port that lands far from these numbers is
worth investigating before shipping — the kernel gives a toolchain nothing
to allocate and nothing to drag in.

## The certification contract

A port is not "it compiles"; it is "it makes byte-identical decisions."
Divergence between live and replay decisions is a bug (NFR-003), and the
contract has three layers:

1. **Compile-time state-size tripwire.**
   Assert the struct layout at build time, as
   `mcu/pico-cue/src/main.c` does:

   ```c
   static_assert(sizeof(CuePolicyState) == 420, "kernel state layout drift");
   ```

   This catches compiler-width drift before anything runs. Watch `_Bool`:
   arm-none-eabi-gcc and Clang treat it as 1 byte with 1-byte alignment,
   but `bool` is not a fixed-width type in C — IAR and ARMCC treat `_Bool`
   size as a configurable option. If the assert trips, re-measure
   `sizeof(CuePolicyState)` under both compilers before touching the
   constant.

2. **Runtime state-size echo.**
   The session handshake echoes `sizeof(CuePolicyState)` back to the host
   in the SESSION_ACK `state_size` field (RFC 0006), so the host tooling
   verifies at runtime that the firmware it is talking to was built with
   the expected layout — a second, independent reading of the same
   tripwire.

3. **On-target trace certification.**
   Stream every trace in `replay/traces/` to the running target and diff
   the returned decisions against each trace's recorded `cue_decisions` —
   the same goldens `make -C replay test` verifies on the host. Then
   stream `replay/tests/config_drift_divergence.json` and assert a
   divergence **is** detected, proving the comparator itself works. All
   traces must pass divergence-free and the drift fixture must diverge.

   [`tools/cue-hiltest`](tools/cue-hiltest/) is the reference
   implementation of this gate (`make -C mcu hiltest PORT=...` runs it for
   pico-cue). To leave a committed record of a pass,
   `make -C mcu hiltest-archive PORT=...` captures the whole run with a
   provenance header and PASS/FAIL trailer — the pattern a new port should
   reproduce. This is also the standing regression gate: re-run it after
   any kernel or port change.

Because the kernel is integer-only and deterministic, any divergence found
this way is a compiler or width bug, not noise. No hardware yet? Layer 3
has a host-side variant: cross-compile the kernel with the vendor
toolchain and run the replay comparison on the host — but a port claimed
as certified needs the on-target run.

## Determinism rules a port must not break

- **Deterministic event order.** `cue_policy_step` cues the first passing
  event in array order; callers must pass events in a deterministic order
  or replay cannot reproduce live decisions.
- **Monotonic `t_ms`.** Sample timestamps must be monotonically
  non-decreasing (the replay harness is stricter: strictly increasing).
  The kernel clamps a single integration step at 60 s to bound damage from
  a corrupt trace, but your timebase glue must not go backwards.
- **Integer math only.** Do not "improve" anything with floating point,
  and do not enable fast-math-style flags that change integer semantics.
  Same inputs, same decisions, on every target.

## Where to start

Read `mcu/pico-cue/README.md` end to end — toolchain pinning, the
state-size tripwire, the hiltest gate, and the committed-certificate
pattern are all demonstrated there. Then open a
[port request](.github/ISSUE_TEMPLATE/port-request.yml) issue describing
your target, toolchain, and whether you can run the on-target
certification.
