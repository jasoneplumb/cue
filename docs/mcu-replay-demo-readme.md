# Cue Policy Kernel on SAM E54 — Replay Demo (Phase 4+)

> **Status: draft README for a demo that does not exist yet.** This is the
> proposed `README.md` for the Phase 4+ MCU replay demo, written ahead of
> implementation so the demo's scope, claims, and vendor story are agreed
> before any board work starts. When the demo is built, this file moves to
> `mcu/same54-replay-demo/README.md`. Board selection follows
> [eval-board-migration-matrix.md](eval-board-migration-matrix.md) — a
> late, low-risk decision; this instantiates the matrix's Microchip
> candidate.

## Example Summary

This example demonstrates time-series decision inference on ride data: the
cue project's portable C cue-policy kernel runs on a Microchip SAM E54
Curiosity Ultra v2 (ATSAME54P20A, Arm Cortex-M4F), streaming a
pre-recorded ride trace through `cue_policy_step` at the same 1 Hz cadence
the phone prototype uses. For each sample the kernel decides one of three
outcomes for an approaching road "squeeze zone" event: no action, emit a
single `HEAD_UP` attention cue, or suppress (cue budget already spent —
at most one cue per route event, NFR-001). The decision is indicated by
toggling onboard LEDs.

In this example the inference happens using the Cortex-M4F CPU itself and
no hardware accelerator is used — nor the FPU, an RTOS, or any heap
allocation: the kernel is integer-only C99 with a fixed-size state struct.

The decision to LED mapping is shown below:

- **Green**: sample processed, decision `NONE`
- **Blue**: decision `HEAD_UP` — cue emitted with its computed lead time
- **Red**: divergence self-check failed — the on-board decision differs
  from the host-replay decision recorded for the same trace. This LED
  should never light; it is the demo's point (NFR-003).

In the phone-side pipeline, map matching and squeeze-zone scoring run
against OpenStreetMap data and produce compact `RouteEvent`s; only
normalized ride samples, those events, and the kernel itself migrate to
the MCU. There is no on-device learning: policy tuning is an offline loop
(design spec §13) in which exported ride traces replay deterministically
on a host through the same kernel (`replay_cli`), and config changes are
recorded in the trace's `policy_config`. The build artifacts this example
consumes are: the kernel pair (`cue_policy.c` / `cue_policy.h`, compiled
unmodified from the repo root), and a generated header embedding one
checked-in replay trace — pre-parsed 20-byte binary sample records rather
than JSON, per the migration matrix's on-target replay mode — with its
expected decisions. This makes the kernel easy to integrate with an
MPLAB X project.

## Device Migration Recommendations

The kernel is 100% vendor-neutral C99 — fixed-width types, no dynamic
allocation, no OS calls (NFR-004) — so migration changes only the ~4 glue
adapters: build integration, clock/timebase → `t_ms`, cue output GPIO,
and trace transport. See
[eval-board-migration-matrix.md](eval-board-migration-matrix.md) for the
board-neutral comparison against the other candidate targets (TI
LP-MSPM0G5187, Renesas EK-RA8M1) and the per-vendor glue table; the same
sources build for all three. Note the matrix caveat: verify
`sizeof(CuePolicyState)` under the actual vendor compiler — `_Bool` width
is a configurable option under IAR/ARMCC.

## Low-Power Recommendations

Terminate unused pins by configuring them as GPIO output-low or input
with internal pull resistors; MPLAB Code Configurator / Harmony's pin
manager allows configuring unused pins directly. Because the decision
loop runs at 1 Hz, the application can spend the inter-sample interval in
STANDBY with an RTC wakeup; the kernel keeps all state in one
caller-owned 420-byte struct, so nothing is lost across sleep.

## Hardware Requirements

- SAM E54 Curiosity Ultra v2 (EV66Z56A) — onboard programmer/debugger;
  1 MB flash / 256 KB SRAM comfortably hold the kernel (~1 KB code),
  embedded traces, and multi-ride logging buffers per the migration
  matrix's fit assessment.

## Example Usage

1. **Hardware Setup**
   - No external hardware connections required for this example.
   - USB provides power, programming, and the UART decision log.

2. **Operation**
   - On startup, the application initializes clocks, LEDs, and UART.
   - The embedded replay trace is streamed sample-by-sample through
     `cue_policy_step`.
   - Each decision toggles the corresponding LED and prints one log line
     (timestamp, event id, decision, lead time) at 115200 baud.
   - After the final sample, the application prints a summary: samples
     processed, cues emitted, and divergence count (expected: 0).

3. **Running the Example**
   - Compile, load, and run the application on the SAM E54 board from
     MPLAB X (XC32).
   - Verify equivalence: run the same trace on the host with
     `replay/build/replay_cli --print` — the decision sequences must be
     identical. Because the kernel is integer-only and deterministic, any
     divergence is a compiler/width bug, not noise (migration matrix,
     Axis 3).
   - Modify the `#define CUE_TRACE` in `main.c` to select a different
     checked-in trace fixture.

## Software Details

- **Input**: normalized ride samples (20 B/record: `t_ms`, `speed_cmps`,
  heading, matched `segment_id`) and compact `RouteEvent`s (20 B) —
  trace schema v1, identical to the phone export and host replay formats
  (FR-010).
- **Decision step**: `cue_policy_step` — deterministic, integer-only, one
  call per sample; measured footprint 1016 B Cortex-M0+ text + 420 B
  state + 12 B/decision (arm-none-eabi-gcc `-O3`, from the Pico W
  firmware build — see the migration matrix for the measurement).
- **LED indication**: decision outcome per sample, plus the divergence
  self-check against recorded host decisions.
- **Policy details**: notice window, cue budget, and severity gates are
  documented in the design spec (§7, §8, §13) and RFC 0002/0003.

## Notes

- This is the "Hello World" of the cue MCU migration path: it proves the
  kernel needs nothing beyond a Cortex-M-class CPU, and that live and
  replayed decisions cannot diverge (divergence is defined as a bug).
- The example uses a built-in recorded trace rather than live sensor
  input; live sampling, map matching, and event generation remain
  phone-side by design — the migration matrix warns that moving any of
  it on-MCU changes compute requirements by orders of magnitude.
- Privacy: checked-in traces contain no GPS coordinates — the kernel
  replays from time, speed, and segment ids alone (NFR-005).
- This example is an attention-aid demonstration. It makes no crash
  prevention, safety, medical, or fitness claims (spec §3 non-goals).

## References

- [eval-board-migration-matrix.md](eval-board-migration-matrix.md) —
  board-neutral comparison, measured kernel footprint, replay/debug
  axes, and verified sources
- Cue design record (private working archive; spec §6–§8, §13–§14)
- RFC 0002 — Personal Route Memory; RFC 0003 — iOS Prototype Architecture
- Kernel sources and tests: `kernel/`; replay harness and trace schema:
  `replay/`
- Microchip — SAM E54 Curiosity Ultra v2 (EV66Z56A):
  <https://www.microchip.com/en-us/development-tool/ev66z56a>
- Microchip — MPLAB Machine Learning Development Suite:
  <https://www.microchip.com/en-us/tools-resources/develop/mplab-machine-learning-development-suite>
