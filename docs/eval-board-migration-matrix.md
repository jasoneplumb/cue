# Evaluation-Board Migration Matrix

> Board-neutral comparison for the Phase 4 MCU migration (design spec §13
> migration strategy). This is an engineering comparison of evaluation boards
> and ML toolchains — it makes no safety, crash-prevention, medical, or
> fitness claims (spec §3 non-goals).

The migration path stays vendor-neutral as long as possible:

```
phone/watch prototype → vendor-neutral replay dataset → MCU cue-policy kernel
                                                      → board-specific demo (later)
```

The phone prototype produces replay traces (`replay/replay_trace.schema.json`);
the deterministic C kernel (`kernel/cue_policy.c`) consumes them identically
live and offline (NFR-003). Choosing a board is therefore a late, low-risk
decision — this matrix exists so that decision can be made on evidence, not
vendor commitment.

## Candidate boards

One representative current-generation candidate per vendor, chosen because
each is the board its vendor's edge-ML toolchain documents as a supported
target. Rows are candidates, not commitments.

| Vendor    | Board (part)                                  | MCU / core                                   | Clock   | Flash                       | SRAM   | ML toolchain                        |
| --------- | --------------------------------------------- | -------------------------------------------- | ------- | --------------------------- | ------ | ----------------------------------- |
| TI        | LP-MSPM0G5187 LaunchPad                        | MSPM0G5187 — Arm Cortex-M0+ w/ TinyEngine NPU | 80 MHz  | 128 KB dual-bank (+8 KB data flash) | 32 KB  | CCStudio Edge AI Studio             |
| Microchip | SAM E54 Curiosity Ultra v2 (EV66Z56A)          | ATSAME54P20A — Arm Cortex-M4F                 | 120 MHz | 1 MB dual-panel             | 256 KB | MPLAB Machine Learning Dev Suite    |
| Renesas   | EK-RA8M1                                       | RA8M1 — Arm Cortex-M85 w/ Helium              | 480 MHz | 2 MB                        | 1 MB   | Reality AI Tools + e² studio        |
| NXP       | FRDM-MCXN947                                   | MCXN947 — dual Arm Cortex-M33 w/ eIQ Neutron NPU | 150 MHz | 2 MB dual-bank           | 512 KB | eIQ Toolkit + eIQ Time Series Studio |

Vendor facts verified against the sources listed at the end (accessed
2026-07-08; NXP row accessed 2026-07-13 — see the NXP source notes for
what could and could not be fetched directly).

## Axis 1 — Compute and memory fit

### Measured kernel footprint

Two independent builds of the same `kernel/cue_policy.c`: the host toolchain
the tests run under, and the actual Cortex-M0+ Thumb build shipped in the
Pico W firmware (`mcu/pico-cue`, Release `-O3`). Neither column is an
approximation of the other — both are measured.

| Metric | Host x86_64 (Apple clang, `-O2`) | Cortex-M0+ (arm-none-eabi-gcc 14.2, `-O3`) |
| --- | --- | --- |
| Code                       | 1,249 B (object `__TEXT`)   | **1,016 B** (linked `.text`, from `pico_cue.elf.map`) |
| Initialized data / BSS     | 0 B                         | 0 B     |
| `CuePolicyState` (RAM)     | 420 B                       | **420 B** (incl. 64-entry cue ring + retreat-refund min-distance array, #28) |
| Worst-case stack per call  | 48 B (`cue_policy_step`)    | **72 B** (`cue_policy_step`; `init` 8 B, `default_config` 0 B) |
| `RideSample` record        | 20 B                        | 20 B    |
| `RouteEvent` record        | 20 B                        | 20 B    |
| `CueDecision` record       | 12 B                        | 12 B    |

Stack figures are `-fstack-usage` output, and all three entry points report
`static` usage (no alloca, no VLAs); every helper is inlined at these
optimization levels, so the per-call figure is the whole call chain below
the entry point.

Reproduce:

- **M0+ code**: build `mcu/pico-cue`, then sum the kernel's `.text` sections
  from the linker map —
  `grep -A1 '^ \.text\.cue_policy' build/pico_cue.elf.map`
  (`cue_policy_default_config` 0x1c + `cue_policy_init` 0x70 +
  `cue_policy_step` 0x36c = 1,016 B; the unlinked object reports 1,020 B —
  4 B of section-alignment padding the link discards).
- **M0+ stack**:
  `arm-none-eabi-gcc -mcpu=cortex-m0plus -mthumb -O3 -std=c11 -fstack-usage -c kernel/cue_policy.c`
  and read the emitted `.su` file.
- **Host**: `cc -std=c99 -O2 -c kernel/cue_policy.c && size cue_policy.o`;
  stack via the same `-fstack-usage` flag.
- **State**: compile-time enforced — `mcu/pico-cue/src/main.c` has
  `static_assert(sizeof(CuePolicyState) == 420)`, and the SESSION_ACK
  `state_size` field echoes it at runtime (RFC 0006).

**Caveat:** struct sizes are correct for arm-none-eabi-gcc and Clang, which
both treat `_Bool`/`bool` as 1 byte with 1-byte alignment — but `bool` is not
a fixed-width type in C, so verify with `sizeof(CuePolicyState)` under the
actual vendor compiler too: IAR and ARMCC treat `_Bool` size as a
configurable option.

### Fit assessment

| Concern                          | TI MSPM0G5187 (128 KB / 32 KB) | Microchip SAME54 (1 MB / 256 KB) | Renesas RA8M1 (2 MB / 1 MB) | NXP MCXN947 (2 MB / 512 KB) |
| -------------------------------- | ------------------------------ | -------------------------------- | ---------------------------- | ---------------------------- |
| Kernel code (~1 KB) + state (420 B) | Trivial fit                 | Trivial fit                      | Trivial fit                  | Trivial fit                  |
| Future on-device model headroom  | Tight — NPU offsets compute, but flash/SRAM bound model size | Comfortable for small quantized models | Largest headroom; Helium accelerates DSP/ML | Comfortable; Neutron NPU accelerates quantized-model inference |
| Logging buffer (see below)       | Constrained — needs microSD (on LaunchPad) or streaming | Fits multi-ride buffering in SRAM/flash | Fits comfortably             | Fits multi-ride buffering in SRAM/flash |

Logging-buffer math, assuming 1 Hz sample logging (assumption — the phone
prototype's export rate is not yet fixed): a 2-hour ride is 7,200
`RideSample` records ≈ 141 KB, plus sparse `RouteEvent` observations and a
handful of 12-byte `CueDecision` records. That exceeds the MSPM0G5187's
32 KB SRAM, so on that class of part ride logging means streaming (UART/USB)
or external storage; the SAME54, RA8M1, and MCXN947 classes can buffer
rides internally. Note the kernel itself needs none of this — logging is a demo/
debug concern, and NFR-005 caps what we store to cue-tuning and replay needs.

## Axis 2 — ML toolchain fit

The cue policy today is a hand-written deterministic gate, not a trained
model. This axis matters for the *next* step the spec anticipates —
tuning/learning from ride data — and for the vendor-demo story.

| Stage              | TI — CCStudio Edge AI Studio                                | Microchip — MPLAB ML Dev Suite                          | Renesas — Reality AI Tools                                  | NXP — eIQ Toolkit + Time Series Studio                        |
| ------------------ | ----------------------------------------------------------- | -------------------------------------------------------- | ------------------------------------------------------------ | -------------------------------------------------------------- |
| Data collection    | Studio-integrated capture from supported boards              | Board capture via MPLAB X plug-in flow                    | Data collection integrated with e² studio round-trip workflow | FreeMASTER-based datalogging (ML Universal Datalogger) + dataset import into Time Series Studio |
| Feature extraction | 60+ models/app examples; PyTorch/TensorFlow/ONNX supported   | AutoML pipeline generates sensor-recognition features     | Reality AI automated feature discovery on raw sensor data     | Time Series Studio autoML for time-series; eIQ Toolkit imports TensorFlow/ONNX/PyTorch models |
| Training           | In-studio training/optimization on open frameworks           | AutoML model builder (cloud-assisted)                     | Reality AI Tools training                                     | Time Series Studio autoML; eIQ Toolkit train/bring-your-own-model |
| Deployment         | Compiles for TinyEngine NPU on-device inference              | Generates C inference code for 8/16/32-bit MCUs and MPUs  | Deploys directly into e² studio embedded projects             | TFLite-Micro engine; eIQ-Neutron-converted models for the NPU; TSS emits a compact C library (`tss_*` API) |
| Debugging          | CCStudio IDE (with integrated generative AI assistance)      | MPLAB X IDE + onboard debugger                            | e² studio + FSP; performance validation in the same round-trip | MCUXpresso IDE/VS Code + FreeMASTER real-time monitoring        |

All four toolchains assume vendor-board data capture; our dataset instead
arrives as phone-recorded replay traces. Whichever vendor is chosen, the
traces must be converted into that toolchain's import format — a one-way
export script, not a kernel change.

## Axis 3 — Replay/debug support

The question per board: can recorded ride traces (our `replay/` format) be
replayed on/against the target, and can cue timing and false alarms be
measured?

Two replay modes apply to any candidate:

1. **Host-side replay against target-compiled kernel** (works everywhere):
   cross-compile `kernel/` with the vendor toolchain, run `replay_cli`'s
   comparison logic on host against the same trace, and diff decisions.
   Because the kernel is integer-only and deterministic (NFR-003), any
   divergence is a compiler/width bug, not noise. No board required.
2. **On-target replay** (per-board work): feed trace samples over a debug
   transport and read back `CueDecision` records. The trace JSON parser
   (`replay/json_mini.h`) is also allocation-free C, but on-target it is
   simpler to stream pre-parsed binary records (20 B/sample) than JSON.

| Capability                          | TI LP-MSPM0G5187                          | Microchip SAME54 Curiosity Ultra          | Renesas EK-RA8M1                        | NXP FRDM-MCXN947                        |
| ----------------------------------- | ------------------------------------------ | ------------------------------------------ | ---------------------------------------- | ---------------------------------------- |
| Debug probe on board                | XDS110 onboard                             | Onboard programmer/debugger                | Onboard debugger (J-Link OB)             | MCU-Link onboard (CMSIS-DAP)             |
| Trace transport for replay feed     | USB-C, UART, microSD slot on LaunchPad     | USB, UART                                  | USB, UART, abundant external interfaces  | USB-C (high-speed), UART (MCU-Link VCOM) |
| Cue-timing measurement              | GPIO toggle + logic analyzer / cycle counters — same technique on all four boards; all have timestamped decision output via `CueDecision.lead_time_s` ||||
| False-alarm measurement             | Identical on all: replay a trace, count `HEAD_UP` decisions vs. reviewed ground truth — this is board-independent by design ||||

Replay/debug support is deliberately *not* a differentiator: the replay
harness was built so cue quality is measured in vendor-neutral trace space,
not on a board.

## Axis 4 — Portability

**Today, 100% of the kernel is vendor-neutral C.** `kernel/cue_policy.c` +
`cue_policy.h` compile standalone with `-std=c99 -Wall -Wextra -Werror
-pedantic`, use only `<stdint.h>`/`<stdbool.h>`, no allocation, no OS calls,
integer-only arithmetic (NFR-004). Nothing in the kernel changes for any
vendor.

What *would* change per vendor (all outside the kernel):

| Layer                         | TI                                   | Microchip                          | Renesas                              | NXP                                    |
| ----------------------------- | ------------------------------------- | ----------------------------------- | ------------------------------------- | --------------------------------------- |
| Build integration             | CCStudio project / TI Clang           | MPLAB X project / XC32              | e² studio project / FSP build         | MCUXpresso IDE or VS Code / SDK (armgcc) |
| Clock + timebase glue         | MSPM0 driverlib timer → `t_ms`        | Harmony/ASF timer → `t_ms`          | FSP timer → `t_ms`                    | MCUXpresso SDK timer → `t_ms`            |
| Cue output (haptic/LED stub)  | LaunchPad GPIO/PWM                    | Curiosity GPIO/PWM                  | EK GPIO/PWM                           | FRDM GPIO/PWM                            |
| Trace transport               | UART/USB/microSD driver               | UART/USB driver                     | UART/USB driver                       | UART/USB driver                          |
| Optional learned-model hookup | TinyEngine NPU runtime                | MPLAB ML generated C inference      | Reality AI runtime                    | eIQ TFLite-Micro / Neutron NPU runtime, or TSS-generated C library |

The glue layer is the same ~4 small adapters on every board; the vendor
choice changes *which* HAL those adapters call, not the kernel or the trace
format.

## NXP eIQ example-catalog scan

Same method as the earlier TI / Microchip / Renesas catalog scans: survey the
vendor's shipped ML example applications and ask whether any go *past* the
perception layer (sensor window → classifier → label) into a decision layer —
alert budgets, hysteresis, cue expiry, timing as a quality metric, or
deterministic replay of field recordings.

What ships (verified 2026-07-13 against the GitHub repositories in Sources):

- **MCUXpresso SDK `eiq_examples` for FRDM-MCXN947** (repo
  `nxp-mcuxpresso/mcux-sdk-examples`, directory
  `frdmmcxn947/eiq_examples/`): `tflm_label_image` and `tflm_cifar10` (image
  classification), `tflm_kws` (keyword spotting — DS-CNN over MFCC
  spectrograms from a microphone), `mpp_camera_mobilenet_view_tflm` (camera
  image classification), `mpp_camera_persondetect_view_tflm` and
  `mpp_camera_ultraface_view_tflm` (camera detection), `mpp_camera_view`
  (camera preview), `tflm_modelrunner` (model benchmarking/server),
  `tflm_lib` (TFLite-Micro library build). Several ship
  eIQ-Neutron-converted model artifacts
  (`mobilenetv1_model_data_tflite_npu16.h`, `ds_cnn_s_npu.tflite`) —
  primary-source evidence the examples target the on-chip NPU.
- **Application Code Hub AI/ML demos on MCX** (GitHub org `nxp-appcodehub`):
  fan anomaly detection with on-device learning (FRDM-MCXA156, accelerometer,
  Time-Series-Studio-generated incremental-KMeans model, 7 KB model / 4 KB
  RAM); on-device-trainable fan anomaly detection (MCXN947 and MCXA153
  variants); portable anomaly detection (on-device SVM training,
  FXLS8974CF accelerometer); sensorless motor anomaly detection
  (FRDM-MCXN947 — TSS model over calculated speed + measured Iq current);
  toy-doll/fashion-MNIST camera recognition (MCXN947).
- **eIQ Time Series Studio**: autoML for time-series anomaly detection /
  classification / regression targeting MCX and i.MX RT boards including
  FRDM-MCXN947; its canonical training example is fan-state classification
  (On/Off/Clog/Friction from a vibration sensor).

Findings:

- **The catalog stops at the perception layer, same as the other three
  vendors.** Every surveyed example terminates at a label, a score, or a
  GUI/LED status display.
- **Code-verified in the closest candidate:** in the sensorless motor
  anomaly demo, the entire post-classification layer is a single threshold
  compare (`ml_normal_score < TSS_RECOMMEND_THRESHOLD` in
  `source/gui_events.c`) that recolors a GUI bar and label. No alert
  budget, no hysteresis, no expiry, no decision record.
- **Timing appears only as inference latency** (e.g. "model inference is
  6 ms" in the fan-anomaly demo) — a compute cost, never a decision-quality
  metric like lead time.
- **Recording exists, replay does not.** The FreeMASTER-based ML Universal
  Datalogger captures training datasets, but no example replays field
  recordings deterministically for audit, tuning, or regression.
- **Distinctive vs. TI/Microchip/Renesas:** several NXP anomaly demos do
  *on-device learning* (incremental KMeans, on-device SVM training). That
  strengthens the adaptivity story but does not close the decision-layer
  gap — outputs still stop at anomaly/normal.
- **Caveat:** the scan covers the public SDK examples for one board plus
  Application Code Hub and Time Series Studio materials. nxp.com pages
  blocked automated fetching, so examples listed only on the vendor site
  may be missed.

## What we don't know yet

Unknowns the three-ride engineering-proof traces (spec §13) or an actual
board bring-up must answer before committing:

- **Real kernel code size on Cortex-M.** Only a host approximation exists;
  needs `arm-none-eabi-gcc` (or vendor compiler) measurement per target core.
- **Sample export rate and trace volume.** The 1 Hz logging assumption above
  is unvalidated — real rides will fix records/hour and thus buffer/transport
  requirements.
- **Whether a learned model is needed at all.** If tuning the hand-written
  gate on ride traces achieves acceptable cue quality (per after-ride
  reviews), the ML-toolchain axis collapses to a demo-story consideration.
- **Feature-extraction cost on target.** Map matching and route-event
  generation stay phone-side in this architecture; if any of it ever moves
  on-MCU, compute requirements change by orders of magnitude and this matrix
  must be redone.
- **Toolchain import friction.** No vendor toolchain has actually ingested a
  converted replay trace yet; the export-script effort per vendor is
  unmeasured.
- **Preproduction availability.** TI's edge-AI parts are new (March 2026);
  LaunchPad/silicon availability at purchase time needs a fresh check.

## Sources

Accessed 2026-07-08:

- TI — MSPM0G5187 product page: <https://www.ti.com/product/MSPM0G5187>
- TI — LP-MSPM0G5187 LaunchPad: <https://www.ti.com/tool/LP-MSPM0G5187>
- TI — Edge AI portfolio announcement (2026-03-10):
  <https://www.ti.com/about-ti/newsroom/news-releases/2026/2026-03-10-ti-expands-microcontroller-portfolio-and-software-ecosystem-to-enable-edge-ai-in-every-device.html>
- TI — Edge AI Studio: <https://dev.ti.com/edgeaistudio/>
- CNX Software — MSPM0G5187/AM13Ex TinyEngine NPU coverage:
  <https://www.cnx-software.com/2026/03/11/texas-instruments-mspm0g5187-and-am13ex-mcus-integrate-tinyengine-npu-for-edge-ai-applications/>
- Microchip — MPLAB Machine Learning Development Suite:
  <https://www.microchip.com/en-us/tools-resources/develop/mplab-machine-learning-development-suite>
- Microchip — SAM E54 Curiosity Ultra v2 (EV66Z56A):
  <https://www.microchip.com/en-us/development-tool/ev66z56a>
- Microchip — ATSAME54P20A: <https://www.microchip.com/en-us/product/atsame54p20a>
- Renesas — EK-RA8M1 evaluation kit:
  <https://www.renesas.com/en/design-resources/boards-kits/ek-ra8m1>
- Renesas — Reality AI Tools:
  <https://www.renesas.com/en/software-tool/reality-ai-tools>

NXP row and catalog scan, accessed 2026-07-13. nxp.com and mouser.com
blocked automated fetching (403/404/timeout), so the NXP product-page URLs
below are cited as canonical references but were verified only via search
excerpts; every load-bearing fact was instead confirmed against the
directly-fetched sources marked "(fetched)":

- Zephyr Project — FRDM-MCXN947 board documentation (fetched; confirms
  dual Cortex-M33 @ 150 MHz, 2 MB dual-bank flash, 512 KB RAM, on-board
  MCU-Link CMSIS-DAP debugger, HS USB Type-C):
  <https://docs.zephyrproject.org/latest/boards/nxp/frdm_mcxn947/doc/index.html>
- GitHub — MCUXpresso SDK examples, `frdmmcxn947/eiq_examples/` (fetched;
  full example list and NPU-converted model artifacts):
  <https://github.com/nxp-mcuxpresso/mcux-sdk-examples/tree/main/frdmmcxn947/eiq_examples>
- GitHub — ML Sensorless Anomaly Detection on FRDM-MCXN947 (fetched;
  README and `source/gui_events.c` threshold logic):
  <https://github.com/nxp-appcodehub/dm-ml-sensorless-anomaly-detection>
- GitHub — TSS-powered on-device-learning fan anomaly detection,
  FRDM-MCXA156 (fetched; README incl. model/RAM/latency figures):
  <https://github.com/nxp-appcodehub/dm-tss-powered-on-device-learning-fan-anomaly-based-on-mcxa156>
- NXP — FRDM-MCXN947 board page (not fetchable by automated tooling):
  <https://www.nxp.com/design/design-center/development-boards-and-designs/FRDM-MCXN947>
- NXP — MCX N94x/N54x product page (not fetchable; "integrated eIQ Neutron
  NPU" claim cross-verified by the NPU model artifacts in the SDK examples
  above): <https://www.nxp.com/products/MCX-N94-N54-N53-N52-N24>
- NXP — eIQ Toolkit (not fetchable):
  <https://www.nxp.com/design/design-center/software/eiq-ai-development-environment/eiq-toolkit-for-end-to-end-model-development-and-deployment:EIQ-TOOLKIT>
- NXP — eIQ Time Series Studio (not fetchable; TSS board support and
  fan-state example verified via the ACH repositories above):
  <https://www.nxp.com/design/design-center/software/eiq-ai-development-environment/eiq-time-series-studio-for-edge-ai-development:eIQ-TSS>
