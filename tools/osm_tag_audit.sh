#!/bin/sh
# Intent: Desk-check falsifier for the map-data-sufficiency assumption —
#         given a bounding box, report per-road and aggregate coverage of
#         the attributes the on-device squeeze scorer needs (spec §7,
#         RFC 0003 D1): lanes, width, cycleway*, shoulder, maxspeed,
#         parking*. Run this against any new ride region BEFORE trusting
#         cold detection there.
# Context: 2026-07-09 audit of the Maring→Miller→Hawkins loop (and a
#          downtown-Portland control): width/shoulder tags are effectively
#          absent region-wide (≈0–2%), while lanes/maxspeed/cycleway are
#          systematically tagged on arterials. The D1b scorer therefore
#          derives its evidence from PROXIES — lanes + maxspeed +
#          meaningful absence of cycleway tags — not width/shoulder
#          fields. "Meaningful absence" requires systematic tagging on
#          the road class in question; this report is how you check that.
# Pattern: One Overpass POST (tags only, no geometry), one python3 pass.
#          Deps: sh, curl, python3. Not wired into CI — network-dependent
#          and region-specific; a manual analyst tool.
# Privacy: The bbox is disclosed to the public Overpass endpoint. NFR-005
#          governs the app, not this desk tool — but choose bbox
#          granularity accordingly (a city-scale box blurs a home loop).
#
# Usage: tools/osm_tag_audit.sh <south> <west> <north> <east> [out.json]
#   Coordinates are decimal degrees, bbox order south west north east.
#   The raw Overpass response is kept at [out.json] (default
#   /tmp/osm_audit.json) for follow-up queries (e.g. per-road tag dumps).
set -eu

if [ $# -lt 4 ]; then
  echo "usage: $0 <south> <west> <north> <east> [out.json]" >&2
  exit 2
fi
S=$1; W=$2; N=$3; E=$4
OUT=${5:-/tmp/osm_audit.json}

# Validate coordinates before splicing them into Overpass QL — a typo like
# "45.5]" would otherwise surface as a cryptic Overpass syntax error.
for coord in "$S" "$W" "$N" "$E"; do
  case "$coord" in
    ''|*[!0-9.-]*|*.*.*|-*-*|*-|*.|.*)
      echo "error: '$coord' is not a decimal coordinate" >&2
      echo "usage: $0 <south> <west> <north> <east> [out.json]" >&2
      exit 2
      ;;
  esac
done

QUERY="[out:json][timeout:60];
way[\"highway\"~\"^(primary|secondary|tertiary|residential|unclassified|trunk|primary_link|secondary_link|tertiary_link|living_street)$\"]($S,$W,$N,$E);
out tags;"

# --max-time bounds the whole transfer: Overpass's [timeout:60] limits
# server-side processing only, not a stalled connection.
curl -sS --fail --max-time 90 -X POST --data-urlencode "data=$QUERY" \
  https://overpass-api.de/api/interpreter > "$OUT"

python3 - "$OUT" <<'EOF'
import json, sys, collections
data = json.load(open(sys.argv[1]))

# Overpass reports timeouts/memory overflows as HTTP 200 with a "remark"
# field — without this check, a truncated result is indistinguishable
# from a genuinely sparse bbox (review, PR #19).
remark = data.get("remark")
if remark:
    print(f"Overpass error (partial or no data): {remark}", file=sys.stderr)
    sys.exit(1)

ways = [e for e in data.get("elements", []) if e["type"] == "way"]
if not ways:
    print("No matching ways in bbox — check coordinates "
          "(order: south west north east).")
    sys.exit(1)

ATTRS = {
    "lanes":     lambda t: "lanes" in t,
    "width":     lambda t: any(k in t for k in ("width", "est_width", "lanes:width")),
    "cycleway*": lambda t: any(k == "cycleway" or k.startswith("cycleway:") for k in t),
    "shoulder":  lambda t: "shoulder" in t,
    "maxspeed":  lambda t: "maxspeed" in t,
    "parking*":  lambda t: any(k.startswith(("parking:", "parking_lane")) for k in t),
}

counts = collections.Counter()
per_name = {}
for w in ways:
    t = w.get("tags", {})
    have = {a for a, f in ATTRS.items() if f(t)}
    for a in have:
        counts[a] += 1
    name = t.get("name", f'(unnamed {t.get("highway","?")} way/{w["id"]})')
    rec = per_name.setdefault(name, {"n": 0, "have": collections.Counter()})
    rec["n"] += 1
    for a in have:
        rec["have"][a] += 1

n = len(ways)
print(f"{n} rideable ways in bbox\n")
print("== Aggregate coverage (share of ways carrying each attribute) ==")
for a in ATTRS:
    c = counts[a]
    print(f"  {a:10s} {c:5d}/{n}  ({100*c/n:5.1f}%)")

TOP = 40
ranked = sorted(per_name.items(), key=lambda kv: -kv[1]["n"])
print(f"\n== Per-road coverage (top {min(TOP, len(ranked))} of "
      f"{len(ranked)} named roads, by segment count) ==")
print(f'  {"road":40.40s} {"segs":>4s} ' + " ".join(f"{a:>9.9s}" for a in ATTRS))
for name, rec in ranked[:TOP]:
    row = f'  {name:40.40s} {rec["n"]:4d} '
    row += " ".join(f'{rec["have"][a]:>4d}/{rec["n"]:<4d}' for a in ATTRS)
    print(row)
if len(ranked) > TOP:
    print(f"  … {len(ranked) - TOP} more roads omitted — raise TOP or "
          f"query the raw JSON kept at the output path")
EOF
