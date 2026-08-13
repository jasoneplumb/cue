# RFC 0004: Perceptible Cue Haptic + Delivery-vs-Perception Instrumentation

- **Status:** Accepted
- **Date:** 2026-07-14
- **Closes:** #105

## Context

Ride `2026-07-14T16-01-32Z` (the third field ride) produced four HEAD_UP
cues on NW Cornell Road, all logged `delivered: true` over the live path
with 709–929 ms latency (p95 929 ms) — and the rider felt none of them.
The kernel, the squeeze scoring, and the phone→watch link all did their
jobs; the failure is in the last inch, phone-ack → wrist, and the current
instrumentation cannot even localize it:

1. **`delivered` is a transport fact, not a perception fact.** The watch
   replies (which sets `delivered`/`delivery_ts_ms`) *before* the expiry
   gate runs and before the haptic call. A cue the gate discarded — or one
   whose `WKInterfaceDevice.play(_:)` call silently no-opped because the
   app was not frontmost — is indistinguishable in the sidecar from a cue
   that tapped the rider's wrist. Frontmost-during-ride is exactly what
   ride mode's `HKWorkoutSession` exists to guarantee (#87), but whether
   that session was actually live at cue time is recorded nowhere.
2. **One subtle `.notification` tap is marginal on a moving bike.** Road
   vibration, gloves, and wrist position all mask it. Spec §12's "one
   subtle haptic cue" was chosen for low distraction; this ride is the
   first field evidence the floor may sit below perceptibility.

Spec §12 also rules: "Do not escalate cues in the MVP." Any perceptibility
change must stay on the right side of that line, and the design record is
frozen — hence this RFC.

## Decisions

### D1 — Instrument the ack: verdict + workout state ride along the reply

| Option | Verdict | Why |
| --- | --- | --- |
| **Verdict + `workout_active` in the live-path reply** | **Chosen** | Zero new messages; the reply already exists and the gate verdict is a set-insert computed in microseconds. Sidecar-only change — trace schema v1 untouched (the schema-v2 stance in `CueDispatcher` holds). |
| Watch-side log file, merged after ride | Rejected | A second export/merge pipeline and a second clock domain for one bit of truth the reply can carry for free. |
| Report actual haptic playback | Rejected (impossible) | `WKInterfaceDevice.play(_:)` returns `Void` and reports nothing; watchOS offers no played-haptic callback. `workout_active` is the closest observable proxy for haptic eligibility. |

The watch computes the gate verdict **before** replying (the delivery
timestamp is captured first, so latency measurement is unchanged) and the
reply becomes a `CueDeliveryAck`: `delivery_ts_ms` + `verdict`
(`play`/`expired`/`duplicate`) + `workout_active`. `CueLinkRecord` and the
latency sidecar gain `watch_verdict` and `workout_active` per cue. Decode
is total — every field independently optional — so a reply from a build
predating this RFC still counts as a delivery.

After the next ride the sidecar distinguishes four cases: `verdict` of
`expired`/`duplicate` (gate discard — timing/duplicate problem),
`verdict == "play" && workout_active == false` (haptic call was a silent
no-op — ride-mode/UX problem), `verdict == "play" && workout_active ==
true` (played but not felt — perceptibility problem), and `verdict`
null/absent (no verdict reported: a legacy watch build or a payload the
watch rejected as malformed — draw no per-cue conclusion; `workout_active`
may still be present and is honest either way).

### D2 — Cue haptic: fixed triple-tap of the same subtle haptic

| Option | Verdict | Why |
| --- | --- | --- |
| **Same `.notification` haptic, fixed 3× at 600 ms spacing** | **Chosen** | Raises perceived duration ~sixfold with zero urgency change. Fixed length, constant type, still at most one cue per route event (FR-004) — a longer *rendering* of one cue, not an escalation chain. |
| Keep the single tap, rely on the watch's Prominent Haptics setting | Rejected as sole fix | User-level setting the app cannot read or set; failure mode is invisible and per-device. Worth enabling, but not a design answer. |
| Stronger system haptic type (`.failure`, `.directionUp`) | Rejected | Semantically wrong haptics repurposed for their intensity; watchOS gives no intensity API, and type-shopping trades meaning for volume. |
| `WKExtendedRuntimeSession.notifyUser(hapticType:repeatHandler:)` | Rejected | The repeat-until-dismissed alert is exactly the escalation §12 forbids, and the extended-runtime session types don't cover a ride (#87). |
| Escalate on non-response (repeat until acknowledged) | Rejected | Explicitly forbidden: §12 "Do not escalate cues in the MVP"; NFR-001 prefers a missed cue over a noisy one. |

**The non-escalation boundary, stated precisely:** the pattern is a fixed
compile-time constant (3 taps, 600 ms apart, ~1.2 s total — inside the 5 s
minimum notice window, so the full pattern completes before the zone);
every tap is the same §12 subtle `.notification` haptic; the pattern never
lengthens, strengthens, or repeats on non-response; duplicates and expired
cues still play nothing. Marker confirmation stays a single `.click`
(§5.8 — capture feedback must stay distinct from the cue).

If the next instrumented ride shows `play` + `workout_active: true` and
the triple-tap is still imperceptible, the next lever is a §13 calibration
conversation (haptic-and-audio pairing, Prominent Haptics guidance), not a
longer pattern.

## Consequences

- `CueTransport.sendLive`'s ack callback carries `CueDeliveryAck` instead
  of a bare timestamp — a source-breaking change inside the package;
  `PhoneWatchLink` and tests updated in the same commit.
- The latency sidecar gains two per-cue fields. It remains a sidecar:
  trace schema v1 is untouched, replay determinism (NFR-003) unaffected —
  the kernel and its inputs are not involved anywhere in this change.
  Encoding note for analysis tooling: in the sidecar JSON an unreported
  field appears as `null` (JSONEncoder), while on the WCSession wire it
  is omitted — treat `null` and absent as the same "unreported" state.
- The watch reply dictionary grows two keys. Old phone builds ignore
  them; old watch builds omit them — both directions degrade to today's
  behavior.
- Ride-mode discipline becomes measurable: rides with the toggle off now
  leave a `workout_active: false` trail instead of a mystery.
