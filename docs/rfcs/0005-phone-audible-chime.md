# RFC 0005: Phone-Side Audible Chime — Paired Delivery Channel

- **Status:** Accepted
- **Date:** 2026-07-20

## Context

Rider feedback: cues have gone unnoticed on recent rides, a problem that
predates RFC 0004's triple-tap haptic change — so the fixed-triple-tap
pattern is not, by itself, sufficient in every riding condition (gloves,
road vibration, wrist position). RFC 0004 D2 already named the next lever
if this happened: "the next lever is a §13 calibration conversation
(haptic-and-audio pairing, Prominent Haptics guidance), not a longer
pattern." This RFC is that lever.

The watch haptic also has a structural gap RFC 0004 D1 could only measure,
not close: it requires the watch to be worn, reachable, and haptic-eligible
(`workout_active`). A cue can be a correct, well-timed `HEAD_UP` and still
never reach the rider at all if the watch link is degraded or the watch is
simply not on the wrist that ride.

## Decisions

### D1 — A phone-local chime, independent of the watch link entirely

| Option | Verdict | Why |
| --- | --- | --- |
| **Phone plays its own chime at dispatch time, unconditionally** | **Chosen** | `RideSessionController.process()` already knows about every `HEAD_UP` before it ever reaches `CueDispatcher`/WCSession — playing locally needs no new coordination, and is not gated on watch reachability, `workout_active`, or delivery ack. A cue is audible even on a ride with no watch at all. |
| Only chime when the watch ack reports low/no perceptibility | Rejected | Reactive, not preventive — the whole point is to not depend on a round trip through the watch link (and its own asmp0002 latency) before the rider hears anything. |
| Route the chime through the watch (`WKAudioFilePlayer`) | Rejected | Reintroduces the exact dependency (link + reachability + worn) this decision exists to route around. |

### D2 — Synthesized tone, not a bundled sound asset

The chime is generated at runtime (`CueChimePlayer.makeChimeBuffer` — a
two-partial decaying sine, fundamental + a fifth, ~1.2 s) into an
`AVAudioPCMBuffer`, rather than shipping an audio file in the repo. No
asset means nothing to license or attribute, and keeps the app's asset
footprint at zero (consistent with the rest of the repo — no binaries
checked in anywhere else). If a specific sound is wanted later, swapping
`makeChimeBuffer()` for a bundled asset is a self-contained change.

### D3 — Audio session: `.playback` + mix, not the default `.ambient`

The session activates with category `.playback` and option
`[.mixWithOthers]`. `.playback` ignores the ring/silent
switch — deliberately, since a rider who muted the phone is exactly the
case "cues go unnoticed" describes, and a chime that respects silent mode
would be silent exactly when it's needed. `.mixWithOthers` keeps it from
cutting off other audio (music, a cycling computer) outright; the chime
layers over whatever is already playing.

**Amended:** this originally also passed `.duckOthers`. Ducking applies
for as long as the session is active — i.e. the whole ride, not just the
~1.2 s the chime rings — so other apps played attenuated the entire time
the app held the session. The option is dropped; the chime is loud enough
to carry over unattenuated background audio, and a ride-long volume cut on
someone else's music is the worse trade.

### D4 — Non-escalation boundary (mirrors RFC 0004 D2)

Spec §12's "do not escalate cues in the MVP" still holds. The chime is a
**paired channel, not an escalation of the haptic**: one fixed-length
rendering per `HEAD_UP` (same "at most one cue per route event" the
kernel already guarantees, FR-004/NFR-001), no repeat on non-response, no
volume or duration change ride-over-ride. A cue landing while the previous
chime is still ringing **interrupts** it rather than layering — the same
rule `WatchCueReceiver.playCuePattern()` uses for the haptic pattern, so
both delivery paths degrade identically under a tight run of events.

### D5 — Simultaneity is best-effort, not guaranteed

The chime fires at the same call site as `CueDispatcher.dispatch()` —
same instant, phone-local, no network hop. The watch haptic still crosses
WatchConnectivity, whose delivery latency `CueDispatcher` already measures
(asmp0002, p95 target <= 2 s) and whose remedy is explicitly "a manual,
between-rides `min_notice_s` bias through the normal §13 loop — never a
runtime auto-adjustment" (`CueDispatcher.swift` header). This RFC does not
change that: the chime and the watch tap will usually feel simultaneous,
but the architecture does not promise it, for the same reason it never
promised sub-latency watch delivery.

## Consequences

- New file `ios/Cue/CueChimePlayer.swift`; hooked into
  `RideSessionController` at `beginRide()` (`prepareForRide()`),
  `process()` (`play()`, alongside `dispatcher.dispatch(...)`), and
  `stopRide()` (`teardown()`).
- No schema or kernel change — like RFC 0004, this is entirely phone-side
  UX; trace schema v1 and replay determinism (NFR-003) are untouched.
- No new privacy surface (NFR-005): the chime carries no data, ride-scoped
  only, nothing exported or logged.
- **Open gap, same shape as RFC 0004 D1's before-state:** there is currently
  no ack for whether the chime was actually *heard* (route audio to
  Bluetooth/CarPlay, phone in a bag muffling it, etc.) — only whether it
  was scheduled to play. If audible-but-unnoticed turns out to be a real
  failure mode, the next step is the same kind of instrumentation D1 added
  for the haptic, not a louder or longer chime.
