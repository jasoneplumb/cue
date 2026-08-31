# Viewing rides on webmap.dev — Squeeze zones + Cue events

The repo ships two export tools whose GeoJSON output loads directly into
[webmap.dev](https://webmap.dev)'s overlay set:

| Overlay (webmap.dev)      | Exporter                             | Shows                                                    |
| -------------------------- | ------------------------------------ | -------------------------------------------------------- |
| **Squeeze zones**          | `cue-zone-export` (webmap.dev#227)   | Where the imported region *would* cue — the static, OSM-scored zones |
| **Custom squeeze zones**   | *(none — drawn in webmap.dev itself)* | Zones you draw by hand on the map — rendered dashed blue so they're never mistaken for the scorer's output, optionally **directional** (RFC 0008) so a zone only applies riding the way you drew it |
| **Cue events**             | `cue-events-export` (webmap.dev#231) | What one ride actually *did* — fired cues, their grades, delivery, and rider markers |

Loaded together they close the §13 tuning loop visually: the derived zones
say where the policy watches, custom zones say where a rider's own
judgment disagrees, and the events say what happened there.

> **Privacy first (NFR-005).** Every file below — the Overpass extract, the
> ride trace, the latency sidecar, and both GeoJSON exports — reveals where
> you ride. They all stay on your machine: `*.geojson`, `/region.json`, and
> `/rides/` are gitignored, and webmap.dev bundles no data for the same
> reason — you hand it a local file per session, nothing more. Never commit
> any of these; tests use hand-built synthetic fixtures only.

## 1. Get an Overpass extract for your ride region

Both exporters take the same input the app's "Import region…" picker does:
an Overpass `out geom;` JSON response for your riding area's bounding box
(south, west, north, east):

```bash
QUERY='[out:json][timeout:60];
way["highway"~"^(primary|secondary|tertiary|residential|unclassified|trunk|primary_link|secondary_link|tertiary_link|living_street)$"](SOUTH,WEST,NORTH,EAST);
out geom;'
curl -sS --fail --max-time 90 -X POST --data-urlencode "data=$QUERY" \
  https://overpass-api.de/api/interpreter > region.json
```

The highway-class filter matches `rideableHighwayClasses` in the importer
(and `tools/osm_tag_audit.sh`). The query must end in `out geom;` — a
tags-only fetch has no geometry to export. If Overpass returns a `remark`
field, the data is truncated and both tools refuse it; retry or shrink the
bbox. Note the bbox itself is disclosed to the public Overpass endpoint —
use a box comfortably larger than your actual loop.

## 2. Squeeze zones — export and view

Export the scored zones through the same importer/scorer the app runs:

```bash
swift run cue-zone-export region.json -o squeeze-zones.geojson
```

The summary line reports ways → segments → zones. Then, on webmap.dev:

1. Open the **layers control** and toggle **Squeeze zones** on.
2. The overlay prompts with a **file picker** — choose
   `squeeze-zones.geojson`.
3. The choice persists in the browser's **localStorage** for the session
   pattern webmap.dev uses; re-toggling the overlay re-reads your file
   without re-picking. Clearing site data forgets it.

A malformed or wrong-shape file is rejected at load with an error and the
overlay stays empty — nothing partial is drawn or persisted.

Each zone renders as its member segment polylines; features sharing an
`event_id` are one logical zone. Popups show severity, confidence, and the
decoded `reasons_bitmask` (narrow lane / no shoulder or bike lane /
high-speed context).

## 3. Custom squeeze zones — draw your own

Unlike the overlay above, this one has no exporter — it's authored
entirely in webmap.dev, for stretches you know are a squeeze but the OSM
importer/scorer didn't flag (no tags to key off, or the road hasn't been
mapped in enough detail).

1. Click the **Draw zone** map control (topleft, pencil icon).
2. Click points on the map to trace the zone; **Finish** (button or
   Enter) commits it, **Cancel** (button or Esc) discards it.
3. The zone renders **dashed blue** — deliberately outside the derived
   overlay's severity palette (yellow/orange/red) and the Cue events
   overlay's outcome palette, so "mine" and "the scorer's" are never
   ambiguous at a glance.
4. Tap a drawn zone to edit its label, mark it **directional**, reverse
   it, or delete it.

### Directional zones (RFC 0008)

A zone applies in both directions by default. Tick **Directional** in its
popup and it applies only while you are riding the way you drew it —
first vertex to last — so a squeeze that only bites descending stops
biasing the climb, and two zones on the same road can say different
things. Directional zones draw an arrowhead per segment showing which
way they run; **Reverse** flips one drawn the wrong way round (the only
geometry edit this overlay has — everything else is still delete and
redraw).

Alignment is generous on purpose: anything within 90° of the road's
direction counts as "with it". That is enough to tell coming from going,
and loose enough not to drop cues where a road bends or where your
course and the road legitimately differ on approach.

A zone with no `directional` property — every file exported before this
existed — is bidirectional, unchanged.

**In the app**, a directional zone is only applied on the passes it
matches. Note the app decides direction from your GPS course, so at a
standstill (no course) it applies the zone rather than guessing.

**In `cue-custom-zone-merge`**, gating needs the trace's own
`heading_deg_x10`, which is optional — a policy-tuning trace has none.
Directional zones then apply **both ways** (the pre-RFC-0008 answer, so
an old trace's result does not silently change), the affected sample
count is reported, and `--strict` refuses the merge instead:

```
2 zone(s) matched -> 3 segment(s) (0 zone(s) unmatched), 4 personal_memory change point(s), 812 ungated sample(s)
```

A non-zero ungated count means that what-if overstates its directional
zones by whatever the reverse passes contribute. Re-record the ride with
the debug-GPS toggle on for a gated answer.

Custom zones persist in the browser's localStorage, same as the other
overlays. The layers-control row also has **Export** (downloads the set
as a GeoJSON file) and **Change…** (imports a previously-exported file —
this **replaces** the current set, the same contract the other overlays
use for "load a different file").

This file now has two cue-side consumers (RFC 0002 Personal Route
Memory). Both treat a custom zone as the same kind of rider judgment as
an in-ride "unsafe here" marker tap, but no longer as the same record:
RFC 0008 gave a zone its own direction-carrying field, since a tap is
about the place and a zone is about a direction through it. A tap you
make during a ride you then discard can no longer disturb an imported
zone, and re-importing a file is idempotent.

- **Live:** the app's "Import custom zones…" action (Personal memory
  section, below Region) snaps the file to imported segments and folds
  matches straight into the phone's `PersonalMemoryStore`, biasing
  cueing on the current and future rides.
- **Desk tool:** `cue-custom-zone-merge <trace.json> <custom-zones.geojson> <region.json>`
  replays a recorded ride as a what-if — "what would this
  ride's cueing have looked like with these zones flagged unsafe?" —
  by writing the matched segments' `personal_memory[]` into the trace
  (replacing, not appending, any prior personal-memory state).

## 4. Cue events — export and view

After a ride, export the trace from the app (and the latency sidecar, if
you want delivery facts), then join them with the region extract:

```bash
swift run cue-events-export ride-trace.json region.json \
  --latency ride-latency.json -o cue-events.geojson
```

- `ride-trace.json` — the schema-v1 policy trace
  (`replay/replay_trace.schema.json`).
- `--latency` — optional sidecar from the dispatcher's latency log; without
  it the `delivered` / `latency_ms` fields are simply omitted.
- The policy trace carries **no GPS** by default, so each event renders at
  its matched segment's midpoint, flagged `approx: true` — "somewhere on
  this segment", not a fix.
- If the ride was recorded with the **debug-GPS toggle** on, the trace
  carries per-sample fixes and the export upgrades automatically — no
  extra flag (webmap.dev#236):
  - One `kind: "track"` **LineString** traces the actual ride path
    (present when at least two samples carry a fix).
  - Events with a usable fix render **exactly there** and omit `approx`:
    markers use their own recorded coordinates; cues use the fix of the
    sample nearest their timestamp (within 2 s — at the ~1 Hz sample
    cadence that is normally the same instant). Events without a usable
    fix keep the midpoint + `approx: true` form, so one file may mix both.
  - The summary line reports coverage, e.g.
    `gps: 812/834 samples, track emitted, 1/1 cues exact, 0/1 markers exact`
    — a partial-GPS ride is visible at export time. A trace without GPS
    produces byte-identical output to before.
- An event whose `segment_id` has no match in the extract (wrong region, or
  OSM edits changed the ids since the ride) is **skipped with a stderr
  warning and counted in the summary**; pass `--strict` to fail instead of
  skipping. The summary also reports graded and latency-join counts, so a
  silent mismatch can't masquerade as a clean export.

Load it the same way: layers control → **Cue events** → file picker.

**Legend** (webmap.dev#231):

| Marker                | Meaning                          |
| --------------------- | -------------------------------- |
| Green point           | `outcome: useful`                |
| Red point             | `outcome: false_alarm`           |
| Orange point          | `outcome: too_late`              |
| Purple point          | `outcome: unrecognized`          |
| Gray point            | ungraded (no review yet)         |
| **Dashed ring**       | `delivered: false` — the cue never reached the wrist |
| **Triangle**          | rider marker ("unsafe here", FR-006) |

Gray points are gradable right on the map: tap one, pick an outcome, then
**Export reviews** and merge the sidecar back into the ride's trace with
`cue-review-merge` — the full loop, and why it matters, is in
[grading-guide.md](grading-guide.md).

## 5. Reading the overlays together

Cue-event points sit on the zone that fired them — popups on both the
Squeeze zones and Cue events overlays share `event_id` and `segment_id`,
so a point and its zone cross-reference directly. Custom zones carry
neither id — they're a rider's own annotation, cross-referenced by eye
(and by dashed-blue-vs-solid-color) rather than a shared key. Patterns
worth acting on in the §13 loop:

- **Red point on a zone** — a false alarm: the zone's evidence
  (severity/confidence in the zone popup) overstates that road; candidate
  for threshold or scorer tuning.
- **Orange point** — cued too late: compare the event's `lead_time_s`
  against `min_notice_s`, and check `latency_ms` — a slow watch delivery
  eats lead time the kernel thinks it gave.
- **Purple point** — a cue that fired but you never noticed
  (`unrecognized`): check `delivered`/`latency_ms` alongside it — a
  delivery/perceptibility problem, not a policy one.
- **Triangle with no zone under it** — a marker where the policy never
  cued at all: the case for personal route memory (RFC 0002).
- **Dashed ring** — the policy fired but the rider felt nothing; a
  delivery problem, not a policy one.

## 6. Keeping it private

One stance, end to end: map data and ride data stay on the operator's
machines. The repo's `.gitignore` guards `*.geojson`, `/region.json`, and
`/rides/`; webmap.dev holds nothing server-side and bundles no data —
custom zones you draw stay in that browser's localStorage (or an exported
file on your own device) the same way. If you share a screenshot, remember
the base map itself shows where you ride.
