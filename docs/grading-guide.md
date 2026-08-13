# Grading rides — the one-minute habit that tunes your cues

## Why grading matters

The cue policy decides everything from **map evidence alone**: OSM road
attributes scored into squeeze zones, thresholded on severity and
confidence, delivered inside a 5–15 s lead window. It has never seen your
roads. Every `HEAD_UP` that fires is therefore a **hypothesis** — "this
map data, at this speed, warranted a heads-up here" — and the only ground
truth the tuning loop (spec §13) ever gets is your grade. Ungraded rides
teach the policy nothing: the false alarm that annoyed you at km 12 will
fire again on every future ride, identically, until a grade says otherwise.

A typical ride fires a handful of cues. Grading them takes under a minute.

## What each grade actually does

| Grade           | What it tells the loop                          | The lever it moves |
| --------------- | ----------------------------------------------- | ------------------ |
| **Useful**      | Evidence and timing were right — protect this   | Anchors current thresholds; guards against overcorrecting on the grades below |
| **False alarm** | The zone's evidence overstates this road        | Raise severity/confidence thresholds or fix the scorer for that reason combination (check the popup's decoded reasons — *which* evidence lied?) |
| **Too late**    | Right call, wrong moment                        | Compare the popup's `lead` against the 5 s floor and its `delivered` latency — slow watch delivery eats lead time the kernel thinks it gave; this separates a policy problem from a delivery problem |
| **Too early**   | Right call, far too soon — the warning felt disconnected from the hazard | Compare the popup's `lead` against the notice ceiling (`max_notice_s`) — the inverse of **Too late**; suggests tightening the ceiling, the same lever the kernel's `TOO_EARLY` gate already enforces |
| **Unrecognized** | The cue fired correctly but you never noticed it | Check the popup's `delivered`/`latency_ms` (did it actually arrive?) and `workout_active` (was the watch haptic-eligible?) — a delivery/perceptibility problem, not a threshold problem; doesn't move a policy lever by itself |

**Places the policy *should* have cued are markers, not a grade** — tap
"unsafe here" on the watch during the ride, or (planned) author a marker
directly on the map afterward. There is no after-the-fact review outcome
for "you should have cued here": a cue that fired was by definition not
missed (that's what **Unrecognized**, above, grades instead — a cue that
fired but wasn't perceived, a different problem). Markers with no zone
under them are the case for personal route memory (RFC 0002).

## How to grade on the map

Ride events on webmap.dev show each cue where it happened, on the base map,
with the zone that fired it underneath — the context the phone's list
review never had.

1. Export and load the ride (see [webmap-overlays.md](webmap-overlays.md)).
2. Tap a gray (ungraded) point → tap **Useful**, **False alarm**,
   **Too late**, **Too early**, or **Unrecognized** in the popup. The point recolors instantly; the overlay
   shows graded/total so you know when you're done. Re-grading overwrites —
   latest wins. Grades wait in the browser (localStorage), kept in a
   separate slot per loaded file — grading one ride never clobbers
   another ride's unexported grades.
3. **Export reviews** (next to "change file…" in the layers control) →
   the browser downloads **`cue-reviews.json`**. Nothing else ever leaves
   the browser — same privacy stance as loading.

Then bring the grades home — see the next section.

## Integrating a graded ride

The download is a small **per-ride sidecar** in the trace schema's
`reviews[]` shape — only graded cues, Clear'd ones omitted:

```json
[{ "event_id": 57053650, "outcome": "useful", "reviewed_at": "2026-07-16T20:03:00Z" }]
```

### 1. Merge it into the ride's trace

The trace stays the single source of truth — the sidecar is applied to it,
never consumed directly by any other tool:

```bash
swift run cue-review-merge rides/<ride>-trace.json ~/Downloads/cue-reviews.json
merged 3 review(s) (2 new, 1 overwrote) -> rides/<ride>-trace.json
```

The merge is **in place** (pass `-o` to write elsewhere) and
**all-or-nothing** — on any error, nothing is written:

- An `event_id` with no `HEAD_UP` cue in this trace fails the whole merge —
  the likeliest cause is handing it the **wrong ride's** sidecar.
- Incoming grades **overwrite** an existing review for the same event
  (latest wins); all other reviews and every non-review field round-trip
  untouched, and re-merging the same sidecar is byte-idempotent.

### 2. GPS rides: merge into the debug trace too

Reviews belong in the canonical `<ride>-trace.json` — that's what replay
and tuning read. But if the viewable export came from a GPS **debug**
trace (`<ride>-trace-debug.json`), re-exporting the map file from it won't
show the new colors unless it also carries the reviews. The event ids are
identical, so apply the same sidecar to both:

```bash
swift run cue-review-merge rides/<ride>-trace.json ~/Downloads/cue-reviews.json
swift run cue-review-merge rides/<ride>-trace-debug.json ~/Downloads/cue-reviews.json
```

### 3. Re-export and reload

```bash
swift run cue-events-export rides/<ride>-trace-debug.json region.json \
  --latency rides/<ride>-latency.json -o rides/<ride>-events.geojson
```

The summary now reports the graded count (e.g. `graded: 3/4 cues`). On
webmap.dev, use the overlay's **change file…** action to load the
re-exported file. Two things are expected here:

- The points arrive **already colored** — the grades are baked into the
  file now, not layered by the browser.
- The re-exported file reads as a *new* file to the browser (its content
  changed), so its pending-grade layer starts empty. Your judgment is
  still fully revisable: re-grading on the map overwrites a baked outcome
  the same way it overwrites anything else, and the next sidecar → merge
  round carries the correction.

Once merged, the grades are simply part of the trace: `replay_cli`, the
tuning loop, and any future analysis see them with no extra steps.

## Housekeeping later

Judgments age: a marker placed mid-ride can turn out to be noise, roadwork
ends, a repave removes a squeeze. The planned v2 lets you **remove markers
you've since judged unnecessary** from the map review flow, with removals
flowing back through the same sidecar → trace round trip as grades. Until
then, grades themselves are always correctable — overwrite on the map and
re-merge.

## The payoff

Grades close the loop the whole system is built around: **map evidence →
cue → your judgment → better thresholds → fewer false alarms, earlier real
warnings.** The policy can only ever be as honest as its last graded ride.
