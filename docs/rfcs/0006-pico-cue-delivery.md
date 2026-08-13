# RFC 0006: Kernel-on-MCU Cue Delivery — Pico W + WuKong 2040 Buzzer/LED

- **Status:** Accepted
- **Date:** 2026-07-31
- **Tracking:** #147

## Context

Both delivery channels have now failed perceptibility in the field. The
RFC 0004 triple-tap haptic is masked by handlebar and road vibration —
the exact failure mode 0004 D2 anticipated ("if the triple-tap is still
imperceptible, the next lever is a §13 calibration conversation, not a
longer pattern") — and the RFC 0005 chime, that calibration lever, is
unreliable in practice: `CueChimePlayer`'s failure paths are silent by
design (swallowed session/engine errors, the caught-exception skip from
#139), and 0005's Consequences already named the open gap that there is
no ack for whether a chime was actually *heard*. Spec §12 forbids
escalation, so neither channel can be made stronger; the remaining lever
is a different actuator entirely — one mounted on the handlebar, loud
and bright by construction, whose delivery is *locally observable*
rather than inferred through a radio link's ack.

Separately, the design record has always planned an MCU migration
(NFR-004): "map matching and route-event generation stay phone-side;
only normalized samples, compact route events, and the kernel migrate to
MCU." The perceptibility failure is the occasion to execute that
migration for real rather than adding a fourth phone-side channel.

## Decisions

### D1 — Hardware: Raspberry Pi Pico W in an Elecfreaks WuKong 2040

| Option | Verdict | Why |
| --- | --- | --- |
| **Pico W + WuKong 2040** | **Chosen** | One assembly holds everything the cue needs: BLE radio (CYW43439) for the phone link, onboard passive buzzer (GP9, PWM — frequency-drivable for loudness), two WS2812B LEDs (GP22), A/B buttons (GP18/GP19), and an 18650 battery with power management. No external wiring; handlebar-mountable as-is. pico-sdk is plain CMake + GCC, matching the kernel's existing `-std=c99 -Wall -Wextra -Werror -pedantic` discipline. |
| SAM E54 Curiosity Ultra v2 (the migration matrix's chosen candidate) | Rejected for this role | No radio, no actuators, no battery — a live cue device needs all three bolted on. The matrix ([eval-board-migration-matrix.md](../eval-board-migration-matrix.md)) was scoped to *replay demos and vendor evaluation*, where it remains valid; this RFC instantiates its per-vendor glue model (build integration, timebase, cue output, trace transport) for a fifth platform rather than replacing it. |
| Plain Pico (no radio) as a wired/standalone device | Rejected | No BLE means no live samples or route events — it can only replay embedded traces, which is a demo, not a cue device. |

The board is off the migration matrix, and deliberately so: the matrix
optimizes for vendor evaluation; this decision optimizes for a rider
perceiving a cue. `sizeof(CuePolicyState)` is re-verified under
arm-none-eabi-gcc per the matrix's compiler-width caveat (D6).

### D2 — The kernel runs on the Pico; the phone becomes sensor + shadow

| Option | Verdict | Why |
| --- | --- | --- |
| **Kernel on the Pico; phone streams samples/events and runs a shadow step** | **Chosen** | The spec's mandated migration shape. Cue timing becomes immune to link jitter at the critical moment: route events arrive seconds-to-minutes ahead of the zone, and decision→buzzer is a GPIO write, not a radio hop. The phone must keep stepping the kernel anyway — `RideTraceRecorder` is the trace producer (FR-009/FR-010) — so the shadow costs nothing and buys live divergence detection. |
| Pico as a dumb actuator (phone decides, sends HEAD_UP over BLE) | Rejected | Re-creates the watch link's structural weakness: the one message that matters must cross the radio exactly at cue time, resurrecting the expiry-gate/staleness machinery and never validating the kernel on target silicon. |
| Full standalone device (GPS + map matching on the MCU) | Rejected | Explicitly out of scope by design: the migration matrix warns that moving map matching on-MCU changes compute requirements by orders of magnitude. Phone-side generation stays. |

**Authority and divergence:** the Pico is authoritative for actuation;
the phone's step is the shadow. The Pico reports each `CueDecision` back
over BLE and the phone compares field-by-field against its shadow
decision for the same step. Any mismatch is recorded as a divergence and
surfaced — divergence between live and replay decisions is a bug
(NFR-003), and this makes it a *live-caught* bug rather than a post-ride
replay finding. The exported trace is unchanged: it records the shadow
decisions, exactly as today, so `replay_cli` verification and the §13
tuning loop are untouched.

### D3 — Wire protocol: the kernel's structs, packed little-endian

The BLE payloads are the kernel's own input/output types serialized
field-by-field, packed, little-endian (both iOS and RP2040 are LE):
`RideSample` 20 B, `RouteEvent` 17 B packed (the natural struct is 20 B
with padding — structs are never memcpy'd onto the wire),
`PersonalMemory` 6 B packed (natural struct is 8 B with trailing
padding), `CueDecision` 8 B packed, `CuePolicyConfig` 12 B packed.
One codec header (`mcu/shared/cue_wire.h`) is compiled into the
firmware, the host test tool, and asserted against Swift golden byte
vectors, so encode/decode cannot fork.

GATT layout (custom 128-bit service; Pico = peripheral, iPhone =
central):

| Characteristic | Properties | Direction | Payload |
| --- | --- | --- | --- |
| `CONTROL` | write, indicate | both | opcode-framed control messages |
| `STEP` | write with response | phone→pico | one kernel step |
| `DECISION` | notify | pico→phone | decision + actuation report |
| `STATUS` | read, notify | pico→phone | battery mV, fw version, state |

Control opcodes: `SESSION_START` (protocol version, ride-id hash,
packed config → `cue_policy_init`; the ack echoes
`sizeof(CuePolicyState)` as a compiler-width tripwire — on a mismatch
the phone aborts session setup and surfaces the error, with no
fallback, since a width mismatch guarantees divergence from the first
step),
`SESSION_RESUME`, `SESSION_STOP`, `TEST_CUE` (drives the actuator only —
never the kernel — the firmware analog of the #131 debug cue).

`STEP` carries `seq u16 | flags u8 | event_count u8 (≤16) | RideSample |
RouteEvent × n` (in exact tracker order) `| [PersonalMemory]` — max
302 B; MTU 512 requested, ATT long writes as fallback. `flags` bit 0 =
`PersonalMemory` present; bit 1 = catch-up/non-actuating (D4); bits
2–7 reserved and must be zero — the Pico rejects a step with unknown
flags set, so a protocol-version disagreement fails loudly instead of
actuating stale cues. The 16-event cap matches the replay harness's
per-sample limit; should the tracker ever produce more, the phone
truncates to the first 16 in tracker order *before* the shadow step —
upstream of both consumers — so the Pico, the shadow, and the exported
trace all see the identical set and truncation can never manufacture a
false divergence. Write-with-response gives per-step ordering and ack
at the 1 Hz sample cadence.
`DECISION` carries `seq | t_ms | CueDecision | actuated u8 |
actuation_delay_us u16` (microseconds since wire v2 — see #164; in
milliseconds the field read 0 for every genuine cue, because the
interval it measures is under 500 us). `STATUS` carries
`fw_version u16 | state u8 | battery_mv u16 | supply u8`.

**Time:** kernel time is exclusively the phone-stamped `t_ms` inside
`RideSample` — the Pico never re-stamps, so no clock synchronization
exists anywhere in the design (NFR-003). Pico-local time is used only
for actuator pattern scheduling and the `actuation_delay_us`
measurement.

**Privacy:** `lat_e7`, `lon_e7`, and `heading_deg_x10` are zeroed on
the wire. The kernel provably reads none of the three, so zeroing
cannot affect determinism — the same stance as the checked-in replay
traces, which carry no GPS (NFR-005). The radio link carries no data
the kernel does not consume. One residual vector is stated openly
rather than implied away: `segment_id`s are OSM-derived, so a passive
observer logging the stream could reconstruct the route without any
GPS on the wire. The link uses LE encryption via standard pairing
where the stack permits; for this single-rider prototype the remaining
exposure is an accepted risk.

### D4 — Reconnect: kernel state lives on the Pico; the phone re-streams

Kernel state is owned by the Pico for the ride's duration. The phone
keeps every un-acked step in a ring buffer; on reconnect it sends
`SESSION_RESUME` with the last acked `seq` and replays the backlog.
Catch-up steps are flagged **non-actuating** — the Pico steps the kernel
with them (state must stay bit-identical to the shadow) but suppresses
the buzzer/LED, because a burst of stale cues after a link gap is
exactly the noisy cueing NFR-001 forbids; a missed cue is preferred. If
the Pico rebooted mid-ride (ride-id hash mismatch), it rejects the
resume and the phone falls back to `SESSION_START` plus a full re-stream
from `seq` 0 — correct by construction, because kernel state is a pure
function of the step sequence.

The live ring is bounded (capacity recorded alongside the codec in
`cue_wire.h`; sized for ≥ 10 minutes of steps at 1 Hz). If a
disconnect outlives it, the phone never attempts a partial catch-up —
it takes the same full-re-stream path as the reboot case,
reconstructing the complete step sequence from the ride trace
recorder, which already holds every sample, event, and memory record
since ride start. Ring overflow therefore degrades to a slower resync,
never to silent state divergence.

### D5 — Retirement of the RFC 0004/0005 delivery channels, gated on validation

> **Amended 2026-08-01 (see D8): the watch haptic is no longer retired.**
> D5 below still governs the RFC 0005 **chime**, and its validation gate
> still governs when the Pico channel is considered proven. What changed
> is the conclusion drawn about the wrist: the operator elected to keep
> the tactile channel permanently, alongside the handlebar actuator,
> rather than replacing it. The reasoning is in D8.

The watch haptic dispatch and the phone chime are removed only after the
Pico channel passes a field acceptance gate, not on merge of this RFC:

- ≥ 3 real rides each producing ≥ 1 genuine `HEAD_UP`;
- **zero** shadow divergences across all validation rides;
- every shadow `HEAD_UP` actuated on the Pico (sidecar `actuated` flag);
- the rider reports perceiving every cue;
- each validation ride runs on the 18650, USB absent, and the sidecar
  says so — an endurance claim from a ride on external power is no claim
  at all;
- the Pico stays live for the whole ride: every streamed step answered by
  a `DECISION` report through to the final step, no truncated tail
  (sidecar `reported_count` and `seq` contiguity);
- at least one forced mid-ride BLE disconnect survived with no duplicate
  and no stale cue (NFR-001).

> **Amended 2026-08-01 (#165): the battery criterion is replaced.**
>
> It read "battery survives each ride (`STATUS` millivolts logged)". That
> cannot be met, and could not have been: on a WuKong 2040 the Pico's
> VSYS pin is not fed by the battery path. Measured on this board —
> **5037 mV on USB, 103 mV on battery** — while BLE ran normally in both
> cases. A Pico W's regulator gives out near 1.8 V, so the 103 mV is not
> the voltage powering the board: the WuKong feeds the Pico's 3V3 pin and
> leaves VSYS floating whenever USB is out. `STATUS` millivolts report
> whether USB is present. They say nothing about the cell, and no
> firmware change makes that pin see it — a real charge gauge would need
> the cell brought to a free ADC pin (GP26–28) through a divider.
>
> The first measurement of this (836 mV) was itself wrong, from an
> incomplete VSYS read; correcting it against the pico-sdk reference
> moved the number but not the conclusion. Both readings were, in the
> end, evidence that the *sensor* was being trusted without the
> measurement path having been checked.
>
> What the criterion was actually for is that the cue device does not die
> mid-ride. That is directly observable in evidence the sidecar already
> collects — a brownout truncates the `DECISION` stream — so it is
> re-grounded above on liveness plus an explicit on-battery requirement,
> both falsifiable. The millivolt series is still logged (it is what
> distinguishes a battery ride from a USB one), but it is telemetry, not
> a gate.
>
> Dependency, stated so it is not discovered later: the on-battery
> criterion needs the supply state in the sidecar, which is a `STATUS`
> payload change. It rides the same wire revision and
> `CUE_WIRE_PROTO_VERSION` bump as #164 rather than spending a second
> one. Until that lands, no validation ride can satisfy this criterion.
>
> This is the second time this gate has been weakened by a metric that
> reads the same whether the system works or is broken; see also the
> `actuation_delay` resolution fix (#164). A criterion that cannot fail
> is worse than no criterion, because the validation evidence still
> *looks* complete.

On retirement, RFC 0004 and RFC 0005 are marked **Superseded (delivery
channel only)**: the 0004 D1 ack instrumentation pattern lives on in the
`DECISION` report, and the watch's *marker* channel
(`markFromWatch`, FR-006…007) and ride-ended signal are explicitly kept —
retirement removes cue delivery, not the watch link.

Until then, the watch haptic and chime keep firing from the existing
delivery boundary (`RideSessionController.deliver`), restructured as a
presenter fan-out but preserving its invariant that every phone-side
`HEAD_UP` — kernel-decided or debug-synthetic — leaves through a
single call site. The Pico is deliberately **not** a presenter at that
boundary: per D2 it actuates from its own kernel's decision on the
1 Hz STEP stream, and wiring it into `deliver` would double-deliver
every cue. `CuePicoLink` is a step streamer and passive shadow
observer; its only tie to the delivery boundary is the debug-only test
cue, which maps to the `TEST_CUE` opcode (actuator only, never the
kernel).

### D6 — Toolchain and verification: unmodified kernel, on-target replay gate

| Option | Verdict | Why |
| --- | --- | --- |
| **pico-sdk C + BTstack; `kernel/cue_policy.c` compiled unmodified by path reference** | **Chosen** | RFC 0003 D3's no-mirror rule, extended to firmware: one kernel source for host, iOS, and MCU. `_Static_assert` on `sizeof(CuePolicyState)` at the include point catches compiler-width drift at build time. |
| MicroPython/CircuitPython (the WuKong vendor examples' stack) | Rejected | The kernel would need a native-module wrapper, and determinism verification through an interpreter adds a layer the replay corpus cannot certify. |

The port's acceptance gate is the trace corpus itself — the "portability
certificate" of [audit-tune.md](../audit-tune.md): a host tool streams
every checked-in `replay/traces/*.json` to the Pico over USB-CDC and
compares decisions against the recorded golden `cue_decisions`, then
streams the `config_drift_divergence` fixture and asserts divergence
**is** detected (proving the comparator). Run as `make -C mcu hiltest` —
manual, hardware-attached, re-run after any kernel or firmware change.
CI gains a build-only `mcu-build` job (arm-none-eabi-gcc, pinned
pico-sdk) so kernel changes cannot silently break the firmware build;
the existing quality gate is untouched, and hardware tests never run in
CI.

### D7 — Actuation: several candidate renderings, selectable at runtime

*Added 2026-08-01 with Phase C (#154). D7 amends D3's single-pattern
sketch; nothing in D1–D6 changes.*

D3 specified one buzzer rendering. That was a design-time answer to an
empirical question, and it is the wrong shape for the one thing this
hardware exists to settle: **which rendering a rider actually notices
over road and wind noise.** Both retired channels failed exactly there,
and neither failure was predictable from a datasheet.

So the firmware ships a **table of candidates, selectable at runtime**,
and the choice is made by comparison on a bike rather than by argument:

| # | Name | The axis it probes, relative to the baseline |
| --- | --- | --- |
| 0 | `triple-2k3` | baseline — 3+3 bursts of 150 ms at piezo resonance, LED strobed with the bursts |
| 1 | `duo-long` | burst count and duty: two 400 ms bursts instead of six short ones |
| 2 | `low-1k2` | carrier frequency (1200 Hz), rhythm held identical to the baseline |
| 3 | `syncopated` | rhythm: short-short-LONG, irregular by design |
| 4 | `sweep` | **default** — spectral motion: three 400 ms tones rising 1600 → 2300 → 3000 Hz |
| 5 | `steady-led` | LED coupling: audio identical to the baseline, LED steady instead of strobed |

Each candidate varies **one** axis against candidate 0, so a preference
is attributable to something specific rather than to "it felt different".

**Selection.** `TEST_CUE` grows an optional trailing `pattern_index u8`
(a length-1 frame still means "fire the selected pattern", so Phase B's
firmware and tooling keep working unchanged). An index outside the table
is refused rather than clamped — quietly substituting a different
candidate would make a comparison lie about what the rider heard. On the
bike, button A cycles the selection and blinks the index; from the Mac,
`make -C mcu blecheck BLECHECK_ARGS="--patterns"` fires all six in turn.
A kernel-decided `HEAD_UP` always plays the *selected* candidate.

**Non-escalation holds for every candidate (spec §12).** Each is a
fixed-length rendering of one cue: no repeat-on-non-response, no
escalation, and a pattern that has run to its end goes silent and stays
silent. That rule is enforced in one place — `cue_pattern_render()` — and
asserted by the host test rather than trusted to each caller's loop.
`CUE_PATTERN_MAX_DURATION_MS` (2.5 s) keeps every rendering finished
before the rider reaches the zone it is about, since `min_notice_s` is 5 s.

**Buttons.** A short-press acknowledges a playing cue (the rider plainly
received it, so the rest is noise) and, when idle, cycles the candidate.
A long-press fires a local test cue — the actuator only, never the
kernel, so a bench check can never appear in the decision stream or
perturb an FR-004 budget. Button B flashes the battery level.

**What Phase C's bench test established, and what it did not.** A real
`HEAD_UP` reaching a real actuator was verified on hardware for the first
time: audible and, in the operator's judgement, plausible for road use.

Comparing all six back-to-back on the bench (2026-08-01, via button A)
selected **candidate 4, `sweep`** — the rising contour — over the
baseline, with its tones lengthened from 200 ms to 400 ms because each
step needed longer to register. That is the reasoning worth keeping: a
*rising pitch* is unlike anything road noise produces, whereas both
retired channels asked the rider to notice a steady stimulus competing
with steady handlebar vibration. It is now the compiled-in default.

The choice is **provisional**, and deliberately so: a quiet bench says
nothing about 30 km/h of wind noise, which is the condition that killed
both previous channels. The other five stay selectable precisely so the
first validation ride can overturn this without a firmware change. Only a
D5 ride can confirm it.

One hardware fact cost real time and is recorded so it is not
rediscovered: **the WuKong 2040's buzzer and LEDs are powered from the
expansion board's own rail, behind its power switch and 18650 — not from
the Pico's USB supply.** With the Pico running happily on USB and the
board switched off, the LEDs stay dark and the buzzer is weak. Both
symptoms read as firmware bugs and neither is one.

### D8 — The watch keeps its tactile channel, with candidate envelopes

*Added 2026-08-01 with Phase C2. Amends D5: the watch haptic is retained
permanently rather than retired. RFC 0004's marker channel was never in
question; what changes is that its **cue** channel survives too.*

D5 assumed the wrist had been ruled out, because RFC 0004's triple-tap
was masked by handlebar and road vibration. That conclusion confused a
*channel* with a *rendering*. The buzzer work (D7) demonstrated the
distinction directly: the failure was never "audio does not work", it was
one particular rendering, and searching the space found a better one.
The wrist deserves the same search before being abandoned, and the two
channels are independent in the way that matters — a rider whose ears are
full of wind noise still has a wrist, and vice versa.

So the two delivery channels are **kept in parallel, permanently**:
handlebar buzzer + LED (authoritative, Pico-local, D2) and watch haptic
(phone-dispatched through the existing `deliver` fan-out). Both are fed
by the same single delivery boundary, so they cannot disagree about
whether a cue happened.

**What watchOS permits, which constrains the design.**
`WKInterfaceDevice.play(_:)` takes a fixed `WKHapticType` and exposes no
duration or intensity control. "Duty cycle" on this platform can
therefore only mean the *spacing between discrete taps* — a decelerating
envelope is taps that thin out, not taps that weaken. Every candidate is
a schedule of tap instants and nothing else, which is also what makes the
table honestly testable: the offsets are the whole behaviour.

| # | Name | Axis probed |
| --- | --- | --- |
| 0 | `triple-600` | baseline — RFC 0004 D2's three taps 600 ms apart, the rendering that failed |
| 1 | `descend-10s` | **default** — rapid onset decaying over 10 s (0.15 s → 1.85 s intervals) |
| 2 | `descend-5s` | vs 1: the same decay at half the length |
| 3 | `ascend-5s` | vs 2: direction of change (accelerating, "closing in") |
| 4 | `steady-10s` | vs 1: duration with no change in rhythm at all |

Selection cycles from the watch face itself (tap to play, long-press to
advance), because the comparison only means anything against real road
vibration and the phone is pocketed. As with D7, playing a candidate
drives the actuator only and never the kernel.

**Two consequences recorded rather than assumed away.**

1. **A 10 s rendering outlasts `min_notice_s` (5 s).** A cue delivered at
   minimum notice is still tapping when the rider reaches the zone. For
   the handlebar buzzer that would be noise and
   `CUE_PATTERN_MAX_DURATION_MS` forbids it; on the wrist it is a
   deliberate trade, since a sparse tap *during* the event is arguably
   still information where a sound is not. If validation rides find the
   tail distracting rather than informative, `descend-5s` is one
   long-press away and needs no firmware change.
2. **§12 non-escalation still binds, and is unchanged in kind.** Every
   candidate is a fixed schedule of one haptic type, fully determined
   before the first tap. Nothing lengthens on non-response, nothing
   varies the haptic type, and a second cue *replaces* the rendering in
   flight rather than interleaving with it. What made RFC 0004 D2
   compliant was that its pattern was fixed, not that it was short — a
   longer fixed pattern is the same category of thing. A candidate that
   reacted to whether the rider responded would not be.

## Consequences

- New top-level `mcu/` tree (`mcu/pico-cue/` firmware, `mcu/shared/`
  wire codec) and `tools/cue-hiltest/` — the first realization of the
  Phase 4 migration path; [mcu-replay-demo-readme.md](../mcu-replay-demo-readme.md)'s
  LED vocabulary (green = none, blue = HEAD_UP, red = divergence/error)
  carries over to the WuKong LEDs.
- iOS grows a `CuePresenter` fan-out at the delivery boundary
  (structuring the watch and chime channels for D5's retirement), a
  `CuePicoLink` package (wire codec, step streamer, shadow comparator
  — not a presenter; D5), a CoreBluetooth central, and the
  `bluetooth-central` background mode + usage-description Info.plist
  keys. The watch and chime presenters are unchanged until D5's gate.
- Trace schema v2 (introduced with RFC 0002's `personal_memory`
  records) and replay determinism are untouched; the new
  per-ride evidence (Pico decisions, actuation flags, divergences,
  `actuation_delay_us`) lands in a sidecar next to the existing latency
  sidecar, mirroring the RFC 0004 D1 pattern.
- No new privacy surface (NFR-005): the radio carries samples reduced
  to time, speed, and segment id (coordinates and heading zeroed),
  compact events, and memory records — nothing else; nothing is
  persisted on the Pico.
- Battery runtime (~60 min on the WuKong's 18650) is a validation-ride
  metric, not a project gate; a USB power bank is the fallback.
- This device is an attention aid. Nothing in this RFC states or
  implies crash prevention, and no safety, medical, or fitness claims
  are made (spec §3 non-goals).
