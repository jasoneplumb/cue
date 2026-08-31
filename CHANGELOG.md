# Changelog

All notable changes to this project will be documented in this file.

## 0.14.0-alpha — 2026-08-31

A rider can now say "this squeeze only matters going this way." Custom
zones drawn in webmap.dev carry the direction they were drawn in, and a
directional zone biases cueing only on the pass that matches it — the case
hand-drawn zones exist for, and the only way two zones on the same road
can be told apart. The kernel is untouched: RFC 0002 D5 already put the
spatial join phone-side, so the gate sits upstream of what
`personal_memory[]` records and a recorded ride still replays bit-exactly
through an unmodified `cue_policy.c`. No schema bump either.

Alongside it, four fixes on the Pico BLE and actuator path, and a
review-workflow change prompted by measuring this release's own cost.

### Added

- **Directional custom zones** (#30, RFC 0008): the custom-zone GeoJSON
  contract gains one optional `directional` boolean — absent or false
  means bidirectional, so every file exported before it existed keeps its
  exact meaning. Direction lives in the LineString's vertex order alone; a
  second bearing field could disagree with the geometry it duplicates.
  Each `(zone, segment)` match resolves to two bits along that segment's
  own node order, so the ride-time comparison is exact rather than a fuzzy
  bearing match, and it fits on a personal-memory record without
  disturbing RFC 0002 D7's 5 KiB budget (17 B → 18 B packed, still
  rounding to 20 B).
  - Alignment is the same side of perpendicular (90°), reusing
    `RouteEventTracker.approachGateDeg`'s directed convention rather than
    inventing a third threshold. Deliberately wide: anything tighter drops
    legitimate cues where a road bends or on approach, and too wide a gate
    degrades only to the previous fire-both-ways behavior.
  - Direction latches per approach but only once **corroborated** —
    `directionLatchSamples` consecutive agreeing samples, the discipline
    `SegmentMatcher.hysteresisSamples` already applies. Latching on the
    first fix let one transient course reading gate a zone out for an
    entire approach, a suppressed cue and strictly worse than what it
    replaced.
  - Zone evidence and in-ride tap evidence are now **separate record
    fields**. A tap is about the place and applies whichever way the rider
    is going; a zone is about a direction through it. Keeping them apart
    is what lets an import be cleared without touching a rider's own
    markers — so importing a file now replaces the zone set, and deleting
    a zone from the file actually clears it.
  - `cue-custom-zone-merge` gates on the same bearing and the same latch,
    so a desk what-if predicts what the phone did. `heading_deg_x10` is
    optional (NFR-005), so a trace without it applies directional zones
    both ways and says so; `--strict` refuses instead, failing before it
    writes. A bearingless segment is reported separately from a missing
    course, because re-recording fixes one and cannot fix the other.
- **DIAG reports an undelivered DECISION** (#7): the MCU surfaces a
  decision the link never delivered, so a dropped report is visible rather
  than silently absent.

### Fixed

- **Actuator state races the BTstack async_context IRQ** (#23): actuator
  state is now synchronized against the IRQ that can preempt it.
- **ATT long-write assembly state survived a disconnect** (#22): reset on
  disconnect, so a reconnecting client cannot inherit a half-assembled
  write.
- **SESSION_STOP status code and led_probe cancel asymmetry** (#24).
- **Desk tools refused schema_version 2** (#6): `cue-review-merge` and
  `cue-events-export` now accept v2 traces, which the personal-memory
  feature has been emitting since 0.12.0-alpha.

### Changed

- **RFC 0007 — miniaturized cue device** (#28): ESP32-H2, LiPo, and the
  loudness question, recorded as a decision record.
- **Review workflow reads only the delta on follow-up rounds** (#36):
  measured on #30's stack, the five test and build jobs finish in ~2
  minutes wall clock in parallel while the review job ran 11 minutes to
  76 minutes — review is effectively the entire PR wait, and every round
  re-read the whole PR even when the change since the last verdict was one
  comment. The verdict comment now carries a `reviewed-sha` marker and
  later rounds scope to the diff since it; `--max-turns` drops 25 → 10.
  The six review dimensions are unchanged — late rounds on #30 were still
  finding real defects, so this targets latency, not rigor.
- GitHub Actions pinned to full commit SHAs; CI, release, license and C99
  badges added to the README; `library.json` chip keywords and community
  scaffolding synced from the working archive.

## 0.13.0-alpha — 2026-08-13

The repositioning release: not one kernel decision changes, and that is
the point. The repo now leads with what it can prove — a deterministic
decision kernel with a field-enforced equivalence contract — and ships
the proof alongside the claim: aggregated field results reproducible by a
committed script, a replay-based ablation study of what each policy gate
actually does on real rides, and the first committed on-target pass
certificate. The "edge-AI sensor-fusion" framing is gone; there is no
learned model in the pipeline, and the docs now say so instead of
implying otherwise.

### Added

- `tools/cue-ablation` + `docs/ablations.md`: **replay-based ablation
  sweep** — the field corpus re-scored under policy variants with zero new
  riding (#179). Findings: the severity/confidence/cooldown gates have
  never bound in the field (the phone's squeeze scoring prefilters —
  all 37,349 observations arrive at or above both thresholds); personal
  route memory has not yet changed a single field decision (armed, never
  reached); and the notice window is the load-bearing noise gate — with
  it removed, cues double to 83 with **zero** inside the 5–20 s spec
  window (median lead 226 s), and a distance window calibrated to the
  median cue speed still leaves 17 of 41 cues out of spec. The
  `distance_gate` kernel variant lives behind
  `-DCUE_ABLATION_DISTANCE_GATE`, `#error`-guarded out of `PICO_BUILD`
  firmware; the default build is byte-identical with the flag unset.
- `docs/results.md` + `tools/cue-results/aggregate.py`: **field results
  as a first-class page** (#175) — equivalence-contract evidence (23/23
  traces replay exit-0; 11,300 phone↔Pico shadow-compared steps, zero
  divergences, zero orphans), corpus totals (88.1 km, 57,783 steps,
  42 cues, 33 grades), and delivery numbers with the honest negatives up
  front (22 undelivered watch dispatches, 7 `unrecognized` grades).
  Every figure is produced by the committed aggregator; the corpus
  itself stays out of the repo per NFR-005 and the page says so.
- `make -C mcu hiltest-archive`: the on-target portability certificate
  now leaves a committed, dated artifact — provenance header (UTC time,
  repo HEAD with porcelain dirty detection, board, port, toolchain) and
  PASS/FAIL trailer, SIGINT-safe via a gitignored `*.FAILED.log` working
  file renamed only on a verified pass (#181). First pass committed:
  `mcu/hiltest-runs/2026-08-13T04-18-46Z-4ce264a.log` — all six traces
  certified divergence-free on the Pico W, drift fixture diverged as
  required.

### Changed

- **Identity** (#173, #175): README, AGENTS.md, and the GitHub repo
  description now lead with the contract — the same C file runs as phone
  shadow, MCU actuator, and offline replay, and all three must agree bit
  for bit — with cycling introduced as the demonstrator. The
  "edge-AI sensor-fusion reference demo" framing is dropped everywhere it
  was a live claim (historical records and vendor-toolchain references
  stand). `docs/design-aspects.md` is promoted to the README lede, and
  the stale 5–15 s notice window in the lede now reads 5–20 s
  (`max_notice_s` moved in 0.12.0-alpha).
- **Kernel footprint numbers are measured, current, and two-column**
  (#173, #177): 420 B `CuePolicyState` (compile-time asserted) and
  1,016 B Cortex-M0+ linked `.text` replace the stale 292 B / ~1 KB
  host guesses, alongside host x86_64 figures (1,249 B `__TEXT`) and
  `-fstack-usage` worst-case stack (72 B M0+ / 48 B host, no
  alloca/VLAs), each cell with its reproduce command.

## 0.12.0-alpha — 2026-08-06

The first policy retune driven by real graded rides rather than desk
simulation. Seven rides came off the phone covering 2026-07-31 to
2026-08-06; all replayed bit-exact and the Pico reported zero divergences
across them, so the kernel was never in question — what the corpus showed
instead was that **every cue in nine graded rides fired at exactly the
`max_notice_s` ceiling**, meaning the config, not the road, was setting
every lead time. The ceiling moves 15 → 20 s.

The grade corpus behind that decision is weaker than the change deserves
and the entry below says so plainly: a third of the grades were
`unrecognized`, which is a delivery outcome rather than a policy one, and
the same event at the same lead was graded differently on two rides. The
sweep should be re-run once cue delivery is perceptible on a stable path.

### Changed

- `kernel`: **`max_notice_s` default widened 15 → 20 s** (spec §13 tuning
  loop; operator decision). Across the nine graded rides of 2026-07-21 to
  2026-08-06 every cue fired at exactly the 15 s ceiling behind 646–741
  `TOO_EARLY` suppressions per ride — the ceiling, not the road geometry,
  was setting every lead time — and three cues at that ceiling were still
  graded `too_late`. Only the ceiling moved; the `TOO_EARLY` gate is
  untouched, and traces carry their own `policy_config`, so every
  checked-in trace replays bit-identically as before. The shipped default
  now matches the `squeeze_loop_tuned.json` fixture that has demonstrated
  this value since the first tuning round.

  The counter-evidence is on the record rather than buried: 7 of the 22
  grades were `unrecognized`, which `docs/grading-guide.md` classes as a
  delivery/perceptibility outcome that moves no policy lever, and the same
  event at the same lead drew opposite grades on 08-02 and 08-06 — so this
  corpus does not by itself separate 15 s from 20 s. Widening also admits
  one extra cue apiece on the 07-28 and 07-31 traces, the NFR-001 cost of
  the earlier notice. Re-run the sweep once cue delivery is perceptible on
  a stable path.

### Fixed

- `ios`: the phone chime no longer ducks other audio for the whole ride.
  The audio session passed `.duckOthers` alongside `.mixWithOthers`, but
  ducking applies for as long as the session is active — the entire ride,
  not just the ~1.2 s the chime rings — so a podcast or cycling computer
  played attenuated throughout. The chime carries over unattenuated
  background audio on its own; RFC 0005 D3 is amended to record why.

- `ios`: two engine tests asserted the notice window as a hardcoded
  `(5...15)` literal beside a comment naming it "spec §8 defaults",
  duplicating the kernel's config. Both now read `min_notice_s` /
  `max_notice_s` off `CuePolicy.defaultConfig()`, so a retune can no
  longer leave a test silently asserting a window the kernel abandoned.

## 0.11.0-alpha — 2026-08-02

RFC 0006 Phases A3 through C, and the first validation rides on real
hardware. **The buzzer and LEDs actuate for real**: the phone streams
normalized samples over BLE, the Pico runs `cue_policy_step` locally and
drives the actuator from its own kernel's decision, and the phone's
shadow kernel compares every step live. Across 1948 streamed steps in
four rides there were **zero divergences** — the live and on-target
kernels have never disagreed (NFR-003).

### Added

- `mcu/`: the **on-target portability certificate** (RFC 0006 D6). A host
  tool streams every checked-in `replay/traces/*.json` to a flashed Pico
  over USB-CDC and diffs its decisions against the same goldens
  `replay_cli` verifies on the host, then streams a must-diverge fixture
  and asserts divergence *is* detected — so the comparator is proven
  rather than assumed. Run as `make -C mcu hiltest`; hardware tests never
  run in CI, but a build-only `mcu-build` job now cross-compiles the
  firmware so a kernel change cannot silently break it. (#157)
- `mcu/`: the **BLE Cue Ride Service** — GATT server and session state
  machine (RFC 0006 D3/D4). Kernel state belongs to the ride, not the
  connection, so a dropped link is recovered with `SESSION_RESUME` from
  the Pico's own last-processed sequence rather than by restarting the
  kernel; replayed steps are flagged non-actuating so a reconnect cannot
  fire a burst of stale cues (NFR-001). A duplicate step replays a cached
  report instead of re-stepping the kernel, and a `sizeof(CuePolicyState)`
  mismatch is refused at session start rather than diverging from the
  first step. (#158)
- `ios/CuePicoLink/`: the phone half of the wire — codec, step streamer,
  and **shadow-divergence detection** (RFC 0006 D2). The comparison uses
  the decision from the same kernel call that feeds the trace recorder,
  not a re-derivation, so it checks two implementations rather than two
  copies of one. Divergence and reported counts are *derived* from the
  per-step records rather than accumulated, because two separate bugs
  came from a state transition forgetting to adjust a counter — and those
  counters are what the acceptance gate reads. (#160)
- `ios/`: CoreBluetooth central and presenter fan-out (RFC 0006 D3). The
  Pico is deliberately **not** a presenter at the delivery boundary: it
  actuates from its own kernel on the 1 Hz step stream, so wiring it in
  would double-deliver every cue. Each ride exports a `-pico.json`
  sidecar carrying per-step shadow-vs-Pico evidence. (#161)
- `mcu/`: **perceptible actuation** — buzzer and WS2812B LED patterns,
  six candidates selectable at runtime so a validation ride can overturn
  a rendering with no reflash, plus handlebar buttons for acknowledge,
  pattern cycling, and a bench test cue that reaches the actuator without
  ever touching the kernel. Candidate 4 (`sweep`, rising 1600→3000 Hz) is
  provisionally chosen. (#162, #154)
- `mcu/`: `DIAG` reports `supply=`, and the ride sidecar records a battery
  series with `battery_powered_throughout`. D5 requires a validation ride
  to run on the 18650, and this is what lets a ride prove it. (#166, #167)

### Changed

- **Wire protocol v2** (`CUE_WIRE_PROTO_VERSION` 1 → 2), two coupled
  changes shipped under one bump. `actuation_delay` is now **microseconds**:
  in milliseconds it read `0` for every genuine cue of the first
  validation ride, because the real interval is under 500 µs — RFC 0006
  D2's architectural claim landing exactly as argued, reported as a number
  indistinguishable from "never measured". On-target it now reads
  **199–214 µs** across independent runs. `STATUS` gains a `supply` byte,
  because millivolts alone cannot establish that a ride ran on battery.
  The delay kept its offset and width, so a v1 peer would decode it
  happily and be wrong by 1000× — the version check is the only thing
  that catches that, so the literal `2` is pinned independently in the C,
  Swift, and Python suites. (#164, #167)
- RFC 0006 **D5's battery criterion is replaced**. It required "battery
  survives each ride (`STATUS` millivolts logged)", which could not be
  met: on a WuKong 2040 the Pico's VSYS pin is not fed by the battery
  path. Measured **5037 mV on USB, 103 mV on battery** on the bench and
  55–60 mV in the field, with BLE running normally throughout — a Pico W
  cannot run near 0.1 V, so VSYS is unpowered whenever USB is out and
  reports only whether USB is present. The criterion is now liveness plus
  an explicit on-battery requirement, both falsifiable. (#165, #166)
- RFC 0006 gains **D7** (buzzer candidates) and **D8** — the watch keeps
  its tactile channel permanently alongside the handlebar actuator, with
  candidate envelopes of its own. This reverses D5's retirement of the
  watch haptic; the chime retirement stands. (#162)

### Fixed

- The VSYS read kept the shape of the pico-sdk reference but not its
  substance — one discarded one-shot conversion where the reference
  drains a FIFO, and no CYW43 wake at all (the lock serialises
  transactions; it does not wake a sleeping chip, so the ADC sampled a
  parked SPI clock line). Corrected in full. The error was invisible
  against USB's 1.67 V at the pin and dominant against battery's 0.03 V,
  which is why only the battery reading was ever wrong. (#165, #166)
- Battery level buckets an implausible reading as *unknown* rather than
  *low*. Below ~1.8 V the board could not be running, so the sensor is
  not measuring the supply — and saying "low" is a lie the rider acts on.
  Handlebar button B had been flashing red on every battery-powered ride
  while the board was healthy. (#165, #166)
- Nothing logged battery millivolts because `STATUS` is a read
  characteristic the firmware never notifies on, so the phone's
  subscription was inert and the connect-time read was the only sample
  ever taken — the displayed value froze for the whole ride. (#165, #166)
- A latent hang: `cue_power`'s reads are radio transactions, but `main()`
  treats a radio failure as non-fatal so the USB replay port survives it.
  Taking an uninitialised CYW43 mutex would have wedged exactly that loop
  — `DIAG` on a board whose radio failed would hang the firmware. (#167)
- An unmeasurable voltage no longer discards its supply label. The ADC
  read reports 0 mV on timeout while the supply beside it stays valid, and
  dropping the whole sample would have let a ride that spent time on USB
  claim it never saw a cable — a false pass on the D5 gate. (#167)
- The VSYS read is bounded rather than blocking forever. The pico-sdk
  reference blocks and is right to; it runs from a demo's `main()`. This
  runs in the loop that has to fire a cue on time. (#167)

## 0.10.0-alpha — 2026-07-31

### Added

- `docs/rfcs/`: **RFC 0006** records the decision to move cue delivery
  off the phone and watch entirely. Both existing channels have failed
  perceptibility in the field — the RFC 0004 triple-tap haptic is masked
  by handlebar and road vibration, and the RFC 0005 chime is unreliable
  with failure paths that are silent by design — and spec §12 forbids
  escalating either one, so the remaining lever is a different actuator:
  a handlebar-mounted Raspberry Pi Pico W in an Elecfreaks WuKong 2040
  (onboard buzzer, WS2812B LEDs, 18650 battery). It executes the design
  record's long-planned MCU migration rather than adding a fourth
  phone-side channel: map matching and route-event generation stay on
  the phone, which streams normalized samples and compact events over
  BLE, while the MCU runs `cue_policy_step` locally and actuates — so
  cue timing no longer depends on a radio hop at the moment that
  matters. The phone keeps stepping the same kernel as a **shadow**
  (it is already the trace producer), and the MCU reports each decision
  back, making any live/on-target disagreement an NFR-003 divergence
  caught in-ride rather than in post-ride replay. Retirement of the
  0004/0005 delivery paths is gated on field-validation criteria, and
  the watch's *marker* channel survives it. (#147, #148)
- `mcu/`: first firmware on that path — `mcu/pico-cue/` is a pico-sdk
  project that cross-builds `kernel/cue_policy.c` **unmodified** by path
  reference for the Pico W (RFC 0003 D3's no-mirror rule extended to the
  MCU), with a compile-time assertion pinning `sizeof(CuePolicyState)`
  so an ARM/host struct-layout drift fails the build instead of quietly
  diverging. It serves a USB-CDC line protocol (`PING`/`CFG`/`RESET`/
  `STEP`→`DEC`) whose handler is pure and host-compilable, so the
  protocol logic is testable without hardware. `mcu/shared/cue_wire.h`
  is the single packed little-endian codec for the kernel's structs,
  shared by firmware, host tooling, and the future BLE path so encode
  and decode can never fork; it zeroes coordinates and heading inside
  the codec itself, so no caller can transmit GPS even by passing an
  unscrubbed sample (NFR-005). (#147, #150)

## 0.9.0-alpha — 2026-07-29

### Added

- `replay/`+`ios/`+`docs/`: **too_early** joins the FR-008 review-outcome
  vocabulary end to end — schema enum, replay `--stats` fixed print
  order, phone picker ("Too early"), export/merge validation, and a
  grading-guide row. It grades the timing failure opposite too_late (the
  cue fired so far ahead it felt disconnected from the hazard); its
  tuning lever is the global `max_notice_s` ceiling, so personal route
  memory deliberately records no per-segment evidence for it. (#143, #145)
- `ios/`: `cue-events-export` emits `heading_deg` (direction of travel,
  degrees clockwise from north) on cue features positioned at a GPS fix
  whose sample carried a course — joined from the trace's existing
  `heading_deg_x10`. Omitted for courseless fixes, midpoint (`approx`)
  cues, and out-of-range producer values, so "unknown" never reads as
  due north. Rendered on webmap.dev as a direction tick on each cue
  point (webmap.dev#245/#248), which also adds the **Too early** grade
  button. (#144, #146)

### Fixed

- `ios/`: closed the remaining TOCTOU window in cue chime playback —
  `AVAudioPlayerNode.play()` can raise an ObjC exception after the
  readiness check passes; an ObjC exception-catching shim converts it
  to a caught Swift error so a mid-ride cue can't abort the app.
  (#139, #142)

## 0.8.0-alpha — 2026-07-28

### Changed

- `ios/`: the running build's version now reads as bare semver — `cue
  #.#.#`, no `-alpha` postfix or build number — on both phone and
  watch; release tooling and bundle metadata keep the full version
  unchanged. (#137, #138)
- `ios/`: the phone's main screen shows the version in the navigation
  title (replacing the footer row, #107's field-install check intact),
  and the "Keep GPS (debug)" toggle moves to its own section at the
  bottom of the page — same pre-ride-only visibility, NFR-005 privacy
  footnote unchanged. (#140, #141)

## 0.7.0-alpha — 2026-07-28

### Added

- `ios/`: post-ride **Discard ride** action next to "Finish & export",
  behind a destructive-role confirmation dialog. Confirming leaves the
  review state without writing any artifacts — no trace/latency/debug
  files — and drops the ride's personal-memory contributions (grades
  and "Unsafe here" markers from the discarded ride are not persisted).
  Covered by package-level `DiscardRideTests`. (#135, #136)

## 0.6.0-alpha — 2026-07-27

### Added

- `ios/`: debug-only "Test cue" button (visible during an active ride,
  `#if DEBUG` builds only) that fires a synthetic HEAD_UP through the
  same `RideSessionController` delivery path as a real cue — phone
  chime plus watch haptic on demand, making audio-path testing a
  two-tap job. Synthetic cues are excluded from the exported trace and
  personal-memory evidence, so a test tap cannot pollute replay data or
  bias future cueing. (#131, #134)

### Changed

- `ios/`: the Ride section (Start/Stop ride, Unsafe here) now renders
  at the top of the main screen, ahead of Region and Personal memory —
  the primary trailhead action no longer requires scrolling past
  one-time setup sections. (#132, #133)

## 0.5.1-alpha — 2026-07-27

### Fixed

- `ios/`: CueChimePlayer no longer crashes the app when a cue fires
  while its audio engine is stopped — `AVAudioPlayerNode.play()` on a
  stopped engine raises an uncatchable NSException that aborted the
  ride (and lost its trace, five on-device crash logs Jul 21–27). The
  player now recovers the engine after session interruptions, route
  changes, and media-services resets, restarts it as a last resort in
  `play()`, and skips the chime rather than abort; stale interruption
  state is cleared at ride boundaries so a dropped `.ended`
  notification cannot mute a later ride. (#129, #130)

## 0.5.0-alpha — 2026-07-22

### Added

- `kernel/`, `replay/`, `ios/`: RFC 0002 Personal Route Memory —
  after-ride reviews and `unsafe_here` markers now bias live cueing
  through a phone-side per-segment store (explicit markers dominate;
  `false_alarm >= 2` and exceeding `useful` suppresses, per NFR-001's
  conservative default). The kernel gains a pre-severity-gate hook (bypass
  on `UNSAFE`, raise-to-`UINT8_MAX` on `SUPPRESS`, plus a per-segment
  notice-window bonus) that is byte-for-byte unchanged when no memory
  applies. The replay schema bumps to v2 with carry-forward
  `personal_memory[]` records so a memory-influenced decision stays
  deterministically replayable (NFR-003). The app's Personal memory
  section gains an "Import custom zones…" action that snaps a
  webmap.dev custom-zones export to imported segments and folds matches
  into the store as marker evidence. (#119, #120, #121, #126)
- `tools/cue-custom-zone-merge`: desk-tool counterpart to the app's
  custom-zone import — merges a webmap.dev custom-zones GeoJSON export
  into a recorded ride's `personal_memory[]`, so a rider-drawn zone can
  be tuned against a past ride as a what-if, without a live ride on the
  phone. Replaces (not appends) the trace's prior `personal_memory[]`.
  (#125)
- `ios/`: the phone now tells the watch when a ride ends
  (`RideSessionController.stopRide`), turning off "Ride mode" (and its
  `HKWorkoutSession`) without the rider having to reach for the watch.
  (#127)

## 0.4.0-alpha — 2026-07-20

### Added

- `tools/cue-events-export`: ride trace → cue-events GeoJSON exporter —
  cues, markers, and reviews as Points at the matched segment's midpoint
  (`approx: true` — the policy trace carries no GPS by default, NFR-005);
  byte-stable output; CLI mirrors `cue-zone-export`. Companion
  `docs/webmap-overlays.md` covers both overlays end to end. (#112)
- `tools/cue-events-export`: emits a GPS track LineString and exact
  (non-approximated) event positions when the trace carries debug-GPS
  fixes, instead of the segment-midpoint fallback. (#114)
- `tools/cue-review-merge`: merges a webmap.dev map-grading reviews
  sidecar into a ride trace's `reviews[]` — overwrite/latest-wins
  semantics, all-or-nothing on unknown event ids or invalid outcomes,
  byte-idempotent re-merge — plus a grading-guide walkthrough. (#116)
- `docs/grading-guide.md`: expanded into a dedicated section — the
  sidecar format, the merge command and its summary/error guards, the
  canonical-vs-debug-trace step for GPS rides, and what to expect on
  re-export/reload. (#118)
- `ios/`: `CueChimePlayer` — a phone-local, synthesized audible chime on
  every `HEAD_UP`, independent of watch reachability. Uses the
  `.playback` audio session category (audible even with the phone
  muted) and mixes/ducks rather than cutting off other audio. See
  RFC 0005 for the non-escalation and simultaneity tradeoffs.

### Changed

- `ios/`: the FR-008 review outcome `missed_risk` is replaced by
  `unrecognized` — a normal per-cue grade for a fired cue the rider
  never noticed (distinct from `too_late`, which is noticed-but-late).
  The redundant post-ride "Add missed risk" button is removed: the
  existing `unsafe_here` marker (watch button, phone button, Siri)
  already covers "the policy should have cued here" with real location
  data the old button never had. `CueMapImport`'s map-grading merge no
  longer special-cases the outcome as app-only.
- `kernel/`: default `min_speed_kmh` lowered from 4 to 1 km/h in
  response to rider reports of cues going unnoticed at low speed — a
  spec §13 tuning-loop parameter change, not a change to the
  `TOO_SLOW` gate's mechanism (still guards the time-to-event division
  against `speed_cmps == 0`).

### Fixed

- `tools/cue-events-export`: cue-event midpoint interpolation now
  correctly walks accumulated geometry length (was picking the wrong
  edge on any segment with 3+ nodes).
- `tools/cue-events-export`: skip counters split by cause (no
  route-event evidence vs. stale/missing segment), and out-of-schema
  review outcomes are dropped rather than exported ungraded.
- `tools/cue-review-merge`: sidecar outcome validation tightened to the
  map-gradable set, and trace JSON parse errors are surfaced instead of
  collapsing to a generic "not a JSON object".

## 0.3.0-alpha — 2026-07-14

### Added

- `ios/`: in-app version line — phone (bottom of the main list) and watch
  (under the ride-mode toggle) both show `cue <semver> (<build>)` from the
  bundle, so a stale or half-updated install is visible at a glance and
  release bumps propagate with no code change. (#108)
- `tools/cue-zone-export`: squeeze-zone GeoJSON exporter — Overpass extract
  through the same importer/scorer the app runs, emitting the webmap.dev
  overlay contract (one LineString per zone member; severity / confidence /
  reasons bitmask). Companion to the webmap.dev squeeze-zones overlay. (#102)
- `docs/`: NXP row (FRDM-MCXN947 + eIQ) added to the eval-board migration
  matrix, with the cross-vendor edge-AI catalog scan extended to n=4. (#99)

### Fixed

- `kernel/`: FR-004 one-cue budget now refunds when the rider clearly
  retreats from a zone without entering it (distance climbs ≥ 50 m above
  closest approach), with an entered-latch so a genuinely reached zone never
  refunds — a spurious near-pass cue no longer silences the genuine approach
  minutes later. Deterministic from the distance sequence alone (NFR-003),
  fixed-size state (NFR-004), pinned by a checked-in replay fixture. (#101)
- `ios/`: RFC 0004 — ride three delivered four cues in under a second each
  and the rider felt none. Cue acks now carry the expiry-gate verdict and
  `workout_active`, exported per cue in the latency sidecar (distinguishes
  gate-discard / silent no-op / played-but-not-felt), and a `play` verdict
  renders as a fixed triple `.notification` tap at 600 ms spacing — bounded,
  constant-urgency, never repeats on non-response (§12 non-escalation). (#106)
- `ios/`: debug-GPS toggle renamed to "Keep GPS (debug)" with an ON-state
  footnote naming the extra `…-trace-debug.json` file, its local-inspection
  purpose, and that the standard trace never contains GPS (NFR-005). (#110)

### Added

- `ios/`: background-location ride sampling (merged Info.plist, ride-duration
  scoped) and the watch ride-mode cycling workout session (HealthKit
  capability; extended-runtime types don't fit a ride) — the two gaps the
  first field ride exposed. First field trace replayed divergence-free
  through `replay_cli` (NFR-003 verified on real data). (#88)
- `ios/CueRideEngine`: GPX playback E2E harness (RFC 0003 D6) — GPX 1.1
  parser, scenario runner over the real pipeline, notice-window assertion,
  in-process replay-equivalence check, opt-in real-binary `replay_cli`
  round trip. (#82)
- `ios/`: after-ride review list (RFC 0003 D7, FR-008) — four-outcome
  grading per cue plus rider-added missed-risk; grades write `reviews[]`
  into the trace before export. (#81)
- `ios/`: markers (RFC 0003 D5, FR-006…007) + the ride-screen shell —
  voice App Intent and watch big-button (one record shape; queued presses
  anchor to the press instant's segment), region import, start/stop ride,
  CoreLocation feed, end-of-ride export of trace + latency sidecar. (#76)
- `ios/CueWatchLink`: watch link (RFC 0003 D4, FR-004…005) — cue payloads
  anchored to the kernel decision instant with lead-time expiry, a
  never-double-tap watch gate, live/queued dispatch with fallback, and the
  per-cue delivery-latency log with p95 (the asmp0002 instrument). (#72)
- `ios/CueRideEngine`: the ride engine (RFC 0003, FR-001…003, FR-009) —
  1 Hz pipeline from GPS fix through matcher, zone→RouteEvent conversion
  over graph distances, `cue_policy_step`, and schema-v1 trace export with
  GPS retention as a per-ride opt-in (NFR-005). (#68)
- `ios/CueMapImport`: map matcher (RFC 0003 D2) — grid spatial index,
  per-edge heading gate, way-level hysteresis with independent challenge
  kinds; calibration mirrors the desk sim's validated constants. (#41)
- `ios/CueMapImport`: composite squeeze-zone scoring (RFC 0003 D1b) —
  §7 conjunction over class/lanes/maxspeed/riding-space proxies with the
  meaningful-absence coverage gate; riding-space evidence model (schema v2
  cache). (#37)
- `ios/CueMapImport`: OSM region import + segment model (RFC 0003 D1a) —
  Overpass extract validation, node-aligned splitting with stable
  content-derived segment ids, tamper-evident local cache. (#35)
- `ios/`: Xcode project — app + watch targets linking the kernel package;
  local build gate. (#33)
- `Package.swift` + `ios/CueKernel`: SPM C target wrapping the kernel with
  a thin Swift facade (RFC 0003 D3) — one source of truth, no Swift
  mirror. (#32)
- `tools/d6_gpx_sim.py`: D6 desk simulator — 1 Hz simulated rides with
  phone-grade GPS noise over real OSM geometry, decisions from
  `replay_cli`; validated the lead-time assumption and found the
  `max_notice_s` tuning lever before any physical ride. (#27)
- `docs/`: Phase 4+ MCU replay-demo README draft (SAM E54, vendor-example
  format) (#65); provisioning runbook,
  decision-layer walkthrough, session docs (#86).

### Changed

- `.gitignore`: NFR-005 privacy block — region extracts, GPX rides, pulled
  field traces, and doc PDF exports never enter git. (#86, #88)

### Added (pre-implementation)

- `tools/osm_tag_audit.sh`: OSM squeeze-attribute coverage audit — given a
  bbox, reports per-road/aggregate presence of the scorer's spec §7 inputs
  (lanes, width, cycleway*, shoulder, maxspeed, parking*) from Overpass.
  Operationalizes the map-data-sufficiency falsifier for any ride region;
  the 2026-07-09 audit finding (width/shoulder absent region-wide — D1b
  scoring must use lanes+maxspeed+cycleway-absence proxies) is documented
  in the header. Manual tool; not in CI. (#18)
- RFC 0003: iOS prototype architecture (Phase 1 vertical slice) — on-device
  route events from an imported OSM snapshot, nearest-segment matching, SPM
  C-target kernel embedding, WCSession cue path with a measured latency
  budget, dual marker capture (voice + watch), GPX-playback E2E with
  `replay_cli` as oracle, minimal in-app review. (#16)
- RFC 0002: personal route memory (spec §9) — design-only decision record.
  Defines a phone-side per-segment store (cue-outcome counts + unsafe-marker
  history keyed by `segment_id`), the "explicit markers dominate" derivation
  rule, the speed×lead-time approach window (phone-resolved), the per-segment
  `+2 s after too_late` notice-bonus tuning rule, a new fixed-size
  `PersonalMemory` kernel input hooked before the severity gate (reserving
  `reasons_bitmask` bits 12–15 for their spec-§7 meaning), a `schema_version`
  1→2 bump with an optional `personal_memory[]` array for deterministic replay
  (NFR-003), and a fixed 5 KiB (256-segment, 20 B/record) memory budget (NFR-004/005).
  No kernel, replay, or schema code changes in this PR. (#11)

### Changed

- `kernel/cue_policy.c`: `cue_policy_init` now clamps an inverted notice
  window (`min_notice_s > max_notice_s`) by lowering `min_notice_s` to
  `max_notice_s` — previously such a config silently suppressed every cue
  (every event failed `TOO_LATE` first), masking misconfiguration as
  conservative behavior (NFR-001). The replay harness's stricter load-time
  rejection is unchanged. (#8)

### Added

- `replay/`: `--stats` mode for `replay_cli` — after a divergence-free
  replay (a diverging trace still exits 1 with no stats), prints cue-timing
  metrics: per-`HEAD_UP` `event_id` / `t_ms` / `lead_time_s`, lead-time
  min / median / max, count inside the configured notice window, a
  suppression histogram by `reason_code` (decisions at observation-carrying
  samples only), and review-outcome counts — the spec §13 "can cue timing
  and false alarms be measured?" hook. Mutually exclusive with `--print`;
  exit-code semantics unchanged; deterministic output ordering (NFR-003
  spirit). `make -C replay test` now exercises `--stats` on both example
  traces. (#12)
- `docs/eval-board-migration-matrix.md`: board-neutral evaluation-board
  migration matrix for Phase 4 (spec §13) — one current-generation candidate
  per vendor (TI LP-MSPM0G5187, Microchip SAM E54 Curiosity Ultra v2,
  Renesas EK-RA8M1) compared on compute/memory fit (with measured kernel
  footprint), ML toolchain fit, replay/debug support, and portability, plus
  explicit open unknowns. (#10)
- `replay/`: replay harness (FR-010) — `replay_cli` loads a trace JSON,
  feeds samples and route-event observations through the cue-policy kernel
  in deterministic order, and exits nonzero on any divergence from the
  recorded `cue_decisions` (NFR-003). Includes a vendored single-header
  JSON tokenizer (`json_mini.h`), a `--print` mode for authoring traces,
  synthetic example traces (baseline + `max_notice_s` tuning variant for
  the spec §13 before/after comparison; no real GPS per NFR-005), a
  config-drift fixture that must fail replay, and `make -C replay test`
  wired into CI. (#6)

## 0.2.0-alpha — 2026-07-08

### Changed

- Design record: replaced the bundle with the revised July 8, 2026 archive
  (kept in the private working archive). Explicit owner update per
  AGENT_POLICY (design-record changes require human direction) in the
  private working archive.

### Added

- `kernel/cue_policy.h` + `cue_policy.c`: portable cue-policy kernel — data
  model from spec §6, gate from §8, one `HEAD_UP` per event (FR-004),
  deterministic and allocation-free (NFR-003/NFR-004), with a
  dependency-free C test suite. (#3)
- `replay/replay_trace.schema.json`: phone/replay interchange schema —
  samples, route-event observations, cue decisions, markers, reviews
  (FR-009), plus the policy config for deterministic replay. (#3)
- CI: kernel build + test and schema JSON validation steps.

## 0.1.0-alpha — 2026-07-08

### Added

- Design record: archived the July 8, 2026 design bundle (kept in the
  private working archive) — design specification (FR-001…FR-010,
  NFR-001…NFR-005) and companion documents.
- Repo conventions adapted from infobento.com: `mainline` default branch,
  conventional commits, agent policy, docs layout with RFC directory,
  `review-requested` review flow.
- RFC 0001: project naming decision record.
- CI: Claude review workflow (`review-requested` label flow, adapted
  from infobento.com). (#1)
