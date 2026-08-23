# RFC 0007: Miniaturized Cue Device — ESP32-H2, LiPo, and the Loudness Question

- **Status:** Draft
- **Date:** 2026-08-22
- **Tracking:** #27

## Context

RFC 0006 put a cue device on the handlebar: a Pico W in an Elecfreaks
WuKong 2040, with a passive piezo on GP9, two WS2812B LEDs on GP22, and
an 18650. It works — 15/15 trace cues actuated on Pico rides, decision→GPIO
in 138–173 µs (median 147 µs, n=13). The operator now wants the same device
substantially smaller: an ESP32-H2 module, a 250 mAh LiPo, and a smaller
buzzer.

The MCU and the battery are straightforward. The buzzer is not, and this
RFC exists mostly to say why.

**The thing RFC 0006 was built to fix is not yet confirmed fixed.** Two
delivery channels already failed on perceptibility — the 0004 triple-tap
haptic (masked by handlebar and road vibration) and the 0005 chime. D1
chose the WuKong because it is "loud and bright by construction." Three
facts from the current tree say that claim is still open:

- `cue_pattern.h` records candidate 4 (`sweep`) as **"Provisional until a
  validation ride judges it against real road and wind noise."** It was
  selected on a bench comparison, 2026-08-01.
- `docs/results.md` reports **7 of 33 graded cues as `unrecognized`** —
  explicitly "a delivery/perceptibility outcome, not a policy one."
- The D5 field acceptance gate is unmet. It requires ≥3 rides, zero shadow
  divergences, every shadow `HEAD_UP` actuated, **the rider reporting
  perception of every cue**, and each ride on battery with USB absent.

So the device's loudness margin is an unmeasured quantity. Shrinking the
actuator spends margin nobody has counted.

## Decisions

### D1 — Sequencing: the D5 gate passes on the WuKong before anything shrinks

| Option | Verdict | Why |
| --- | --- | --- |
| **Pass D5 on the Pico/WuKong first, then miniaturize against that baseline** | **Chosen** | D5 turns "loud enough" from a judgement into a recorded result. Miniaturization then has a reference to regress against, and a failure afterwards is attributable. |
| Build the H2 device now and validate once, on the small hardware | Rejected | Changes MCU, BLE stack, supply rail, buzzer size, and enclosure simultaneously. If the rider stops hearing cues, the evidence cannot say which change did it — and one of the candidates is "the whole approach", which would be a false negative on RFC 0006 itself. |
| Skip the gate; treat 15/15 actuations as sufficient | Rejected | `actuated` is a firmware-side flag: it records that the GPIO was driven, not that a human heard anything. The 7 `unrecognized` grades are the counter-evidence, from the only instrument that matters. |

This is D7's own method applied one level up. D7 varies **one** axis per
candidate "so a preference is attributable to something specific rather
than to 'it felt different'." A miniaturization that moves five axes at
once abandons that discipline at exactly the moment it is most needed.

### D2 — Loudness is recovered by drive voltage, not by diaphragm area

The premise worth contesting is that *smaller buzzer* implies *quieter
device*. A piezo is a voltage-driven, high-impedance load; its SPL tracks
the voltage swing across the element at least as strongly as it tracks
diaphragm size. Two levers, neither of which costs meaningful current:

| Lever | Cost | Gain |
| --- | --- | --- |
| **Differential drive** — element between two antiphase PWM pins instead of one pin and ground | one extra GPIO, one extra half-bridge | Doubles the swing across the element: roughly **+6 dB** |
| **Boosted rail** — 12–24 V into the element via a boost or a piezo driver IC (PAM8904 class) | one part | Large, and current draw stays small because the load is capacitive |

A 12 mm element driven differentially at 12 V will beat a 30 mm element
driven single-ended at 3.3 V. The pinned Zephyr already has what the first
lever needs: `mcpwm0` (`espressif,esp32-mcpwm`, complementary outputs with
dead-time) and `ledc0`, with drivers `pwm_mc_esp32.c` and
`pwm_led_esp32.c`.

Supporting evidence already in the tree, from `mcu/pico-cue/README.md`:
powered over USB with the WuKong switched off, "the LEDs stay dark and the
**buzzer is weak**." Drive rail visibly dominates on the current hardware.

**The differential-drive experiment needs an external element, and this
document originally said otherwise.** The first draft claimed it was testable
on the WuKong "with no new hardware — a firmware change plus a second pin."
That is wrong, and the error is worth leaving visible because it is the same
class this RFC is about.

Differential drive requires access to **both** terminals of the piezo. The
WuKong's onboard buzzer is reached from GP9 and its return is, on every
ordinary carrier layout, the board's ground plane. Elecfreaks publishes no
schematic and their wiki does not state the second terminal, so this is not
even confirmable from documentation — it was assumed from a pin number.

What the experiment actually costs: a bare piezo element and two jumpers to
two GPIOs. Cheap, and still no H2 and no enclosure — but it is new hardware,
and the **onboard buzzer cannot be the device under test**. Nothing done in
firmware alone raises the voltage swing across a part with one terminal
soldered to ground; duty and frequency are already spanned by D7's
candidates.

**Settle the premise first, with a multimeter**: continuity between the
buzzer's second terminal and GND. Thirty seconds, and it either confirms the
assumption above or reopens the cheaper path. Recorded as a prerequisite
rather than a footnote, because the whole D1/D2 sequence rests on the
differential experiment being cheap enough to run before miniaturization.

### D3 — Every acoustic claim is measured on the board, never taken from a part

`cue_actuator.h` already states the rule, in the comment on
`cue_actuator_tone()`:

> "the piezo resonates at ~2.3 kHz" is a datasheet claim about a part, not
> a measurement of THIS board — and the entire project turns on whether the
> rider can hear the thing.

Any candidate element is swept with `cue_actuator_tone()` and measured at a
fixed distance against the WuKong baseline before it enters a pattern
table. A part swap that changes the resonant peak silently re-tunes every
candidate in `cue_pattern.c`, since five of the six name a carrier
frequency.

#### Measured 2026-08-23: the WuKong's own element does not peak at 2.3 kHz

The rule was applied to the board already on the bench, before any part
swap, and the datasheet number does not survive it.

A coarse sweep (1200–4000 Hz) and two fine sweeps (100 Hz steps) put the
loudest response at **2800 Hz**. Ordered sweeps judged by ear are exactly
the kind of evidence this repo distrusts — a rising-pitch expectation
produces the same shape as a real peak — so the result was confirmed
double-blind:

| Trial type | n | Result |
| --- | --- | --- |
| 2800 Hz vs 2300 Hz, order randomised per trial | 4 | **4/4 chose 2800** |
| Catch trials (identical pair, listener not told) | 2 | **2/2 called "same"** |

The listener did not know which trials were which, and neither did the
author until the answers were in — the key was written to a file and read
back only for scoring. One real trial had the presentation order reversed
and the answer followed the frequency rather than the position. The catch
trials are what make the rest worth anything: a listener who called a
winner on an identical pair would have shown the four real trials to be
response bias, which is D5's must-diverge principle pointed at a human
instead of a comparator.

**This result is independent of the bench's unresolved supply question.**
Both tones in every trial played under identical power, so a starved buzzer
scales both equally; the comparison is relative and survives whatever the
WuKong's power switch was doing.

What it does **not** establish: that 2800 Hz is the exact peak. Only
2800-vs-2300 was blind-tested; the sweeps that suggested 2800 were ordered
and are weaker evidence. The peak is somewhere near 2800, not at 2300, and
a 50 Hz claim would be false precision. Nor is any of it an SPL figure —
this is one listener, one room, one session, comparing rather than
measuring.

**The consequence lands outside this RFC.** Candidates 0, 2 and 4 in
`cue_pattern.c` name carriers chosen around the assumed ~2.3 kHz:
`triple-2k3`, `low-1k2`, and `sweep`'s 1600 → 2300 → 3000 ramp — `sweep`
being the current provisional default. D7's bench comparison on 2026-08-01
therefore judged *rhythm* while *pitch* was an uncontrolled variable
underneath it, and the winner was picked at a frequency the element does
not favour.

Re-tuning the table is **not** proposed here. D7 says the default is chosen
by comparison on a bike, and changing the carriers changes what every
candidate means; that is a decision for RFC 0006's owner, on a re-run
comparison, not a side effect of this RFC's bring-up work.

### D4 — The battery gauge is wired before the first ride, not after

RFC 0006's D5 battery criterion had to be **replaced** (#165) because the
Pico's VSYS pin cannot see the WuKong's cell: measured 5037 mV on USB and
103 mV on battery, with BLE running normally in both. The first
measurement of that (836 mV) was itself wrong. The amendment's conclusion
is the reusable part:

> a criterion that cannot fail is worse than no criterion, because the
> validation evidence still *looks* complete.

The H2 build has no excuse to repeat it. `adc0` (`espressif,esp32-adc`)
exists on this part; the cell goes to a free ADC pin through a divider **in
the first revision of the carrier**, so `STATUS.battery_mv` reports the
cell rather than reporting whether USB is plugged in. This is a schematic
requirement, not a firmware one — which is why it belongs in this RFC and
not in a later issue.

### D5 — Power: 250 mAh LiPo is sufficient; the regulator and charger are not free

| Constraint | Resolution |
| --- | --- |
| LiPo at full charge is 4.2 V; the ESP32-H2's VDD range is **3.0–3.6 V** | Must regulate. The Waveshare Zero's ME6217C33M5G (3.3 V, 800 mA) does it — cell into the 5 V pin. Dropout ~120 mV puts the usable window at roughly 3.45–4.2 V, so the bottom of the cell is unreachable |
| Runtime | BLE connected at the design's 1 Hz `STEP` cadence runs on the order of 10–20 mA; buzzer bursts are ≤2.5 s (`CUE_PATTERN_MAX_DURATION_MS`) and rare. ~250 mAh / ~15 mA ≈ **16 h** against a 1–4 h ride — comfortable |
| Charge management | **The Zero has none**; the WuKong did. A TP4056/MCP73831 and a protection circuit are additions to the carrier, not assumed |
| Cell protection | Verify whether the specific 250 mAh cell ships with a protection PCB. Do not assume it |

Runtime is not the binding constraint here, and the RFC should not pretend
otherwise — the interesting risks are acoustic and mechanical.

### D6 — Port surface: the kernel and the wire survive; the radio layer does not

| Piece | Disposition |
| --- | --- |
| `kernel/cue_policy.c` | Compiles unmodified (C99), per RFC 0003 D3's no-mirror rule. The `_Static_assert(sizeof(CuePolicyState) == 420)` tripwire **must be re-measured** under `riscv64-zephyr-elf` — D6's compiler-width caveat, now exercised against a third ABI |
| `mcu/shared/cue_wire.h` | Unchanged. Both RV32 and Cortex-M0+ are little-endian, which is exactly what D3's packed, field-by-field encoding was chosen to buy |
| `cue_ble.c` | **Rewritten.** BTstack → Zephyr `bt_gatt`. The GATT layout (CONTROL/STEP/DECISION/STATUS) and every opcode carry over unchanged; only the binding to the stack is new |
| Buzzer PWM | `ledc0` + `CONFIG_PWM=y`. Direct replacement for `hardware/pwm.h` |
| **WS2812B LEDs** | **The one real gap.** The H2 has no PIO, and the pinned Zephyr ships no RMT-based WS2812 driver. Available: `ws2812_spi.c`, `ws2812_i2s.c`, `ws2812_gpio.c`, `ws2812_uart.c`. **SPI is the correct choice** — GPIO bit-banging WS2812 timing while a BLE controller takes interrupts is a race, and `SPIM2_MOSI_GPIO8` exists in the H2 pinctrl header |
| `tools/cue-hiltest` USB-CDC | The H2's on-die USB-Serial-JTAG is bench-proven (benchseed `esp32h2_devkitm`, `proven`). The line protocol should port |
| `tools/cue-blecheck` | Works unchanged — it is a `bleak` client against the GATT layout, which D6 preserves |

**A licensing consequence, in the project's favour.** `mcu/pico-cue/README.md`
records that the BLE build links BTstack, "free for open source, but
commercial products need a BlueKitchen commercial license." Zephyr's
Bluetooth stack is Apache-2.0. The port removes that constraint rather
than carrying it.

### D7 — Board substitution is sound for the radio and the console, and for nothing else

The bench H2 is a **Waveshare ESP32-H2-Zero** built against Zephyr's
`esp32h2_devkitm` (benchseed D21) — Zephyr v4.3.1 ships no Waveshare H2
board and the SoC is the same part. That substitution holds for the SoC's
own paths: USB-Serial-JTAG console, radio, and the peripherals addressed
through the GPIO matrix.

It does **not** hold for pin assignments. benchseed's
`boards/esp32h2_devkitm/FACTS.md` lists the Waveshare Zero's pin map,
its RGB LED, and its partition layout under *"Not established — needs
measurement."* The onboard WS2812 is a **candidate at GPIO8** — the pin
the ESP32-H2-DevKitM-1 uses, and Waveshare states the Zero is pin-compatible
with that board — and is recorded as a candidate until this bench rules on
it.

## Consequences

- **Nothing ships to the handlebar in a smaller box until D5's gate passes
  on the current one.** That is a schedule cost, accepted deliberately.
- The differential-drive experiment (D2) becomes the next actionable piece of
  work. It needs a bare piezo element and two jumpers — not the H2, not an
  enclosure, but not nothing either, and not the onboard buzzer.
- A second `mcu/` target appears (`mcu/h2-cue/`), and with it the first
  case of two firmware stacks compiling one kernel. D6's `_Static_assert`
  is what keeps that honest.
- The LED channel gets weaker in the port, not stronger: SPI-driven WS2812
  costs a peripheral and a pin that the RP2040's PIO gave away for free.
- **An LED cannot be part of any acceptance evidence.** benchseed's D16/D17
  settled this on adjacent hardware: a write-only indicator cannot fail, so
  it cannot be evidence, and "an assertion earns its place by being able to
  go red for a reason someone would act on." The LEDs stay an operator
  affordance — link state, pattern indication — exactly as `cue_actuator.h`
  already scopes them.

## Open questions

- **Where exactly does the element peak, and does re-tuning the carriers
  change which candidate wins?** 2800 Hz beat 2300 Hz double-blind (D3), but
  the peak is bracketed, not located, and D7's comparison has never been run
  with pitch controlled. This is the open question with the largest claim
  attached to it, and it belongs to RFC 0006 rather than here.
- **Is the WuKong buzzer's second terminal actually on the ground plane?**
  Assumed above from a pin number, because Elecfreaks publishes no schematic.
  A continuity check settles it, and a negative answer makes the D2
  experiment cheaper than this RFC now claims.
- Does the Waveshare Zero's PCB antenna hold a usable link from a handlebar,
  with a rider's body adjacent and a metal stem nearby? Unmeasured, and it
  gates the whole enclosure decision.
- Which element, at which drive topology, matches or beats the WuKong's SPL
  at the rider's ear? D2 and D3 describe how to answer it; nothing here
  claims an answer.
- Does `sizeof(CuePolicyState)` still equal 420 under `riscv64-zephyr-elf`?
  Cheap to check, and the build fails loudly if not.
