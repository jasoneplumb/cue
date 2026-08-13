#!/usr/bin/env python3
# Intent: Desk-runnable D6 falsifier (RFC 0003) for the lead-time-accuracy
#         assumption — simulate a 1 Hz GPX ride with phone-grade GPS noise
#         over REAL imported OSM geometry, run a D2-style matcher (nearest
#         segment + heading gate + hysteresis), emit a schema-v1 trace, and
#         let replay_cli (the real kernel) produce the cue decisions. The
#         decisive metric is cue time vs GROUND-TRUTH zone entry: do lead
#         times land in the [min_notice_s, max_notice_s] window (spec §14)?
# Context: asmp0004 in the qsitu model — "1 Hz phone GPS plus nearest-segment
#          matching yields distance_to_start accurate enough that computed
#          lead times genuinely land in the 5–15 s window." The full D6 is an
#          iOS-simulator E2E gate; this tool runs its physics/matching core
#          before any ios/ toolchain exists. The kernel is NEVER reimplemented
#          here: decisions come from `replay_cli --print` (NFR-003).
# Pattern: One python3 pass, stdlib only. Squeeze scoring uses the obs00004
#          proxy rule (arterial class + explicit lanes<=2 + maxspeed>=40 mph +
#          meaningful cycleway-tag absence); contiguous qualifying ways merge
#          into zones. Deterministic for a given (input JSON, seed, args).
#          Not wired into CI — network-fetched input and region-specific
#          route names; a manual analyst tool like osm_tag_audit.sh.
# Privacy: Input geometry comes from an Overpass fetch the analyst runs
#          (bbox disclosure governed by the same note as osm_tag_audit.sh).
#          The scrubbed trace and the report contain no coordinates — only
#          way ids, road names, chainages, and timings (NFR-005 spirit).
#          The debug trace (--debug-trace) carries lat/lon for matcher
#          inspection: keep it local, never commit it.
#
# Usage: tools/d6_gpx_sim.py <overpass_out_geom.json>
#          --anchor-name "<residential road at ride origin>"
#          --loop-names "<road>,<road>,..."   (ride returns via these, in order)
#          [--crop-km 3.0] [--seed 42] [--base-speed 6.0]
#          [--lead-in-m 400] [--tail-m 200] [--horizon-m 600]
#          [--replay-cli replay/build/replay_cli] [--out-dir /tmp]
#          [--debug-trace]
#   The input must be an Overpass `out geom;` response for rideable highway
#   classes (see osm_tag_audit.sh for the class regex).
import argparse
import collections
import heapq
import json
import math
import random
import subprocess
import sys

INT16_MIN, INT16_MAX = -32768, 32767
RIDEABLE = {
    "primary", "secondary", "tertiary", "residential", "unclassified",
    "trunk", "primary_link", "secondary_link", "tertiary_link",
    "living_street",
}
ARTERIAL = {"primary", "secondary", "trunk", "primary_link", "secondary_link"}

# Matcher tuning (D2 shape: nearest segment + heading gate + hysteresis).
MATCH_RADIUS_M = 50.0     # candidate search radius
HEADING_GATE_DEG = 50.0   # undirected bearing agreement
HYSTERESIS_MARGIN_M = 3.0 # challenger must beat holder by this ...
HYSTERESIS_SAMPLES = 2    # ... for this many consecutive fixes
GPS_SIGMA_M = 4.0         # per-axis position noise (phone-grade, 1 Hz)
SPEED_SIGMA_MPS = 0.3     # GPS speed noise
HEADING_SIGMA_DEG = 5.0   # GPS course noise
SPEED_SWING_MPS = 1.0     # deterministic speed variation amplitude
SPEED_PERIOD_S = 90.0     # ... and period

# Squeeze scoring (obs00004 proxy rule): severity/confidence are constants —
# every zone this rule admits carries the same three explicit evidence bits.
# Calibration is D1b implementation scope; these sit safely above the spec §8
# placeholder thresholds (128) so the policy gates, not the scorer, decide.
SQUEEZE_SEVERITY = 200
SQUEEZE_CONFIDENCE = 190
SQUEEZE_REASONS = 0b111  # narrow_lane | no_shoulder_or_bike_lane | high_speed


def mph(tags):
    parts = str(tags.get("maxspeed", "")).split()
    try:
        val = int(parts[0])
    except (ValueError, IndexError):
        return 0
    # OSM bare numbers default to km/h per spec; "mph" is explicit (US/UK).
    if len(parts) < 2 or parts[1].lower() != "mph":
        val = round(val / 1.60934)
    return val


def has_cycleway_tag(tags):
    return any(k == "cycleway" or k.startswith("cycleway:") for k in tags)


def is_squeeze(tags):
    if tags.get("highway") not in ARTERIAL:
        return False
    if mph(tags) < 40:
        return False
    try:
        lanes = int(tags.get("lanes", ""))
    except ValueError:
        return False  # unknown lane count -> no event (NFR-001 direction)
    return lanes <= 2 and not has_cycleway_tag(tags)


class Geo:
    """Equirectangular meters around an anchor — fine at neighborhood scale."""

    def __init__(self, lat0, lon0):
        self.lat0, self.lon0 = lat0, lon0
        self.kx = 111320.0 * math.cos(math.radians(lat0))
        self.ky = 110540.0

    def xy(self, lat, lon):
        return ((lon - self.lon0) * self.kx, (lat - self.lat0) * self.ky)

    def latlon(self, x, y):
        return (self.lat0 + y / self.ky, self.lon0 + x / self.kx)


def dist(a, b):
    return math.hypot(a[0] - b[0], a[1] - b[1])


def bearing(a, b):
    return math.degrees(math.atan2(b[0] - a[0], b[1] - a[1])) % 360.0


def undirected_diff(h1, h2):
    d = abs(h1 - h2) % 360.0
    d = min(d, 360.0 - d)
    return min(d, 180.0 - d)


def point_seg(p, a, b):
    """(distance, t, projection) from point p to segment a-b."""
    ax, ay = a
    vx, vy = b[0] - ax, b[1] - ay
    L2 = vx * vx + vy * vy
    t = 0.0 if L2 == 0 else max(0.0, min(1.0, ((p[0] - ax) * vx + (p[1] - ay) * vy) / L2))
    proj = (ax + t * vx, ay + t * vy)
    return dist(p, proj), t, proj


def load_ways(path):
    data = json.load(open(path))
    if data.get("remark"):
        sys.exit(f"Overpass remark in input (partial data?): {data['remark']}")
    ways = [e for e in data.get("elements", []) if e["type"] == "way"
            and e.get("tags", {}).get("highway") in RIDEABLE]
    if not ways:
        sys.exit("no rideable ways in input — did you fetch with `out geom;`?")
    for w in ways:
        if not (0 < w["id"] <= 0xFFFFFFFF):
            sys.exit(f"way id {w['id']} does not fit uint32 segment_id")
        if len(w.get("nodes", [])) != len(w.get("geometry", [])):
            sys.exit(f"way {w['id']}: nodes/geometry length mismatch — need `out geom;`")
    return ways


def midpoint(ways_subset):
    pts = [g for w in ways_subset for g in w["geometry"]]
    return (sum(p["lat"] for p in pts) / len(pts),
            sum(p["lon"] for p in pts) / len(pts))


class Graph:
    def __init__(self, ways, geo):
        self.node_xy = {}
        self.adj = collections.defaultdict(list)  # node -> [(nbr, len, way_id)]
        self.way_by_id = {w["id"]: w for w in ways}
        for w in ways:
            ids, geom = w["nodes"], w["geometry"]
            for nid, g in zip(ids, geom):
                self.node_xy[nid] = geo.xy(g["lat"], g["lon"])
            for a, b in zip(ids, ids[1:]):
                L = dist(self.node_xy[a], self.node_xy[b])
                self.adj[a].append((b, L, w["id"]))
                self.adj[b].append((a, L, w["id"]))

    def dijkstra(self, src, allowed_ways=None, banned_ways=None, penalty_ways=None):
        INF = float("inf")
        d = {src: 0.0}
        prev = {}
        pq = [(0.0, src)]
        while pq:
            du, u = heapq.heappop(pq)
            if du > d.get(u, INF):
                continue
            for v, L, wid in self.adj[u]:
                if allowed_ways is not None and wid not in allowed_ways:
                    continue
                if banned_ways is not None and wid in banned_ways:
                    continue
                if penalty_ways is not None and wid in penalty_ways:
                    L = L * 500.0
                nd = du + L
                if nd < d.get(v, INF):
                    d[v] = nd
                    prev[v] = (u, wid)
                    heapq.heappush(pq, (nd, v))
        return d, prev

    def path(self, src, dst, penalty_ways=None):
        d, prev = self.dijkstra(src, penalty_ways=penalty_ways)
        if dst not in d:
            sys.exit(f"no path between waypoints {src} and {dst}")
        nodes, edge_ways = [dst], []
        while nodes[-1] != src:
            u, wid = prev[nodes[-1]]
            nodes.append(u)
            edge_ways.append(wid)
        nodes.reverse()
        edge_ways.reverse()
        return nodes, edge_ways

    def nearest_node(self, xy, among=None):
        pool = among if among is not None else self.node_xy.keys()
        return min(pool, key=lambda n: dist(self.node_xy[n], xy))


def merge_zones(squeeze_ways):
    """Union contiguous qualifying ways (shared endpoints) into zones."""
    node_owner = collections.defaultdict(set)
    for w in squeeze_ways:
        for n in w["nodes"]:
            node_owner[n].add(w["id"])
    seen, zones = set(), []
    by_id = {w["id"]: w for w in squeeze_ways}
    for w in squeeze_ways:
        if w["id"] in seen:
            continue
        comp, stack = set(), [w["id"]]
        while stack:
            wid = stack.pop()
            if wid in comp:
                continue
            comp.add(wid)
            for n in by_id[wid]["nodes"]:
                stack.extend(node_owner[n] - comp)
        seen |= comp
        zones.append(sorted(comp))
    return zones


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("osm_json")
    ap.add_argument("--anchor-name", required=True)
    ap.add_argument("--loop-names", default="",
                    help="comma-separated road names ridden before the arterial "
                         "run, in order; omit for the clean approach-physics "
                         "measurement (near-passes on connector legs can burn "
                         "an event's one-cue budget — a real failure mode, but "
                         "a separate experiment)")
    ap.add_argument("--max-notice-s", type=int, default=20,
                    help="policy max_notice_s — the spec §13 tuning lever "
                         "(default tracks CUE_POLICY_DEFAULT_MAX_NOTICE_S; "
                         "the D6 runs recorded in docs/ used 15 and 12)")
    ap.add_argument("--crop-km", type=float, default=3.0)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--base-speed", type=float, default=6.0)
    ap.add_argument("--lead-in-m", type=float, default=400.0)
    ap.add_argument("--tail-m", type=float, default=200.0)
    ap.add_argument("--horizon-m", type=float, default=600.0)
    ap.add_argument("--replay-cli", default="replay/build/replay_cli")
    ap.add_argument("--out-dir", default="/tmp")
    ap.add_argument("--debug-trace", action="store_true",
                    help="also write a lat/lon trace for matcher inspection (do not commit)")
    args = ap.parse_args()
    if args.base_speed <= SPEED_SWING_MPS:
        sys.exit(f"--base-speed must exceed {SPEED_SWING_MPS} (SPEED_SWING_MPS): "
                 "instantaneous speed would reach 0 and stall the simulated ride")

    all_ways = load_ways(args.osm_json)
    anchor_ways = [w for w in all_ways if w.get("tags", {}).get("name") == args.anchor_name]
    if not anchor_ways:
        sys.exit(f"anchor road {args.anchor_name!r} not in input")
    lat0, lon0 = midpoint(anchor_ways)
    geo = Geo(lat0, lon0)

    def near_anchor(w):
        return any(dist(geo.xy(g["lat"], g["lon"]), (0, 0)) <= args.crop_km * 1000.0
                   for g in w["geometry"])

    ways = [w for w in all_ways if near_anchor(w)]
    graph = Graph(ways, geo)
    print(f"{len(ways)} rideable ways within {args.crop_km} km of {args.anchor_name!r}")

    # --- Squeeze zones (obs00004 proxy rule) -------------------------------
    squeeze_ways = [w for w in ways if is_squeeze(w.get("tags", {}))]
    zone_way_ids = merge_zones(squeeze_ways)
    if not zone_way_ids:
        sys.exit("no squeeze-qualifying ways in crop — nothing to falsify against")
    by_id = graph.way_by_id

    def zone_lon(z):
        return midpoint([by_id[wid] for wid in z])[1]

    zone_way_ids.sort(key=zone_lon, reverse=True)  # ride east -> west
    zone_road = by_id[zone_way_ids[0][0]]["tags"].get("name", "?")
    print(f"{len(zone_way_ids)} squeeze zone(s) on {zone_road!r} "
          f"(way counts: {[len(z) for z in zone_way_ids]})")

    # Zone endpoint nodes: degree-1 nodes within the zone's own subgraph.
    def zone_endpoints(z):
        deg = collections.Counter()
        for wid in z:
            for a, b in zip(by_id[wid]["nodes"], by_id[wid]["nodes"][1:]):
                deg[a] += 1
                deg[b] += 1
        ends = [n for n, c in deg.items() if c == 1]
        if len(ends) < 2:
            # Loop-shaped zone — should not occur on arterials. z is sorted
            # by OSM way id (no geographic meaning), so fall back to the
            # extreme nodes of the geographically extreme ways instead.
            by_x = sorted(z, key=lambda wid: sum(
                graph.node_xy[n][0] for n in by_id[wid]["nodes"]
            ) / len(by_id[wid]["nodes"]))
            ends = [by_id[by_x[0]]["nodes"][0], by_id[by_x[-1]]["nodes"][-1]]
        ends.sort(key=lambda n: graph.node_xy[n][0])  # by x: west, east
        return ends[0], ends[-1]

    # --- Waypoints: lead-in east of the first zone, through all zones,
    #     a short tail past the last, then the loop roads home. ------------
    first_zone, last_zone = zone_way_ids[0], zone_way_ids[-1]
    first_east = zone_endpoints(first_zone)[1]
    last_west = zone_endpoints(last_zone)[0]
    zone_road_ways = {w["id"] for w in ways if w.get("tags", {}).get("name") == zone_road}

    def offset_node(from_node, banned, target_m, intersections_only=False):
        """Node ~target_m along the zone road, not crossing `banned` ways."""
        d, _ = graph.dijkstra(from_node, allowed_ways=zone_road_ways, banned_ways=set(banned))
        pool = {n: v for n, v in d.items() if v > 0}
        if intersections_only:
            # Reachable from side streets with the zone road banned — the
            # loop legs must be able to END here without riding the arterial.
            pool = {n: v for n, v in pool.items()
                    if any(wid not in zone_road_ways for _, _, wid in graph.adj[n])}
        if not pool:
            return from_node
        return min(pool, key=lambda n: abs(pool[n] - target_m))

    start = offset_node(first_east, first_zone, args.lead_in_m, intersections_only=True)
    tail = offset_node(last_west, last_zone, args.tail_m)

    # Ride shape: residential loop first (anchor -> loop roads -> lead-in
    # point; a negative test — these roads must produce zero events), then
    # one east->west arterial run through every zone, ending at the tail.
    # Loop legs heavily penalize the zone road (soft ban — some junctions
    # are only reachable through it): riding it eastbound past the zones
    # would smear zone chainage across two passes and fire legitimate-
    # looking approach cues that burn each event's one-cue budget (FR-004)
    # long before the real approach.
    anchor_node = graph.nearest_node(geo.xy(lat0, lon0),
                                     among={n for w in anchor_ways if w["id"] in by_id
                                            for n in w["nodes"]})
    waypoints = [anchor_node] if args.loop_names else []
    for name in [s.strip() for s in args.loop_names.split(",") if s.strip()]:
        named = [w for w in ways if w.get("tags", {}).get("name") == name]
        if not named:
            sys.exit(f"loop road {name!r} not in crop")
        nodes = {n for w in named for n in w["nodes"]}
        waypoints.append(graph.nearest_node(geo.xy(*midpoint(named)), among=nodes))
    waypoints.extend([start, first_east, last_west, tail])
    n_loop_legs = len(waypoints) - 4  # legs before the lead-in point

    route_nodes, route_edge_ways = [waypoints[0]], []
    for leg, (a, b) in enumerate(zip(waypoints, waypoints[1:])):
        penalized = zone_road_ways if leg < n_loop_legs else None
        nodes, edge_ways = graph.path(a, b, penalty_ways=penalized)
        route_nodes.extend(nodes[1:])
        route_edge_ways.extend(edge_ways)

    # Per-vertex chainage; per-edge way id.
    chain = [0.0]
    for a, b in zip(route_nodes, route_nodes[1:]):
        chain.append(chain[-1] + dist(graph.node_xy[a], graph.node_xy[b]))
    total_len = chain[-1]
    print(f"route: {len(route_nodes)} nodes, {total_len:.0f} m")

    # --- Events: zones traversed by the route, by chainage -----------------
    events = []
    for z in zone_way_ids:
        zset = set(z)
        idxs = [i for i, wid in enumerate(route_edge_ways) if wid in zset]
        if not idxs:
            print(f"  note: zone {z} not on route — skipped (no observations)")
            continue
        # First contiguous traversal only; a second pass would smear the
        # zone's extent across the whole ride (allow 2-edge interruptions
        # for nodes shared with cross streets).
        end_i = idxs[0]
        for i in idxs[1:]:
            if i - end_i > 3:
                print(f"  warning: zone {z} re-traversed at edge {i}; "
                      f"using first pass only")
                break
            end_i = i
        events.append({"ways": z, "start": chain[idxs[0]], "end": chain[end_i + 1]})
    events.sort(key=lambda e: e["start"])
    for i, e in enumerate(events):
        e["event_id"] = 101 + i
        e["segment_id"] = e["ways"][0]
        print(f"  event {e['event_id']}: ways {e['ways']} chainage "
              f"{e['start']:.0f}..{e['end']:.0f} m ({e['end'] - e['start']:.0f} m long)")
    if not events:
        sys.exit("route traverses no squeeze zone — adjust waypoints")

    # --- Ground-truth ride + noisy fixes -----------------------------------
    rng = random.Random(args.seed)
    edge_idx = 0

    def pos_at(c):
        nonlocal edge_idx
        while edge_idx + 1 < len(chain) - 1 and chain[edge_idx + 1] <= c:
            edge_idx += 1
        a, b = graph.node_xy[route_nodes[edge_idx]], graph.node_xy[route_nodes[edge_idx + 1]]
        span = chain[edge_idx + 1] - chain[edge_idx]
        t = 0.0 if span == 0 else (c - chain[edge_idx]) / span
        return ((a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1])),
                bearing(a, b), route_edge_ways[edge_idx])

    truth = []  # (t_s, chain, xy, bearing, way_id, speed)
    c, t = 0.0, 0
    while c < total_len and t < 3600:
        spd = args.base_speed + SPEED_SWING_MPS * math.sin(2 * math.pi * t / SPEED_PERIOD_S)
        xy, brg, wid = pos_at(c)
        truth.append((t, c, xy, brg, wid, spd))
        c += spd
        t += 1

    fixes = []
    for (t, c, xy, brg, wid, spd) in truth:
        fixes.append({
            "t": t,
            "xy": (xy[0] + rng.gauss(0, GPS_SIGMA_M), xy[1] + rng.gauss(0, GPS_SIGMA_M)),
            "speed": max(0.0, rng.gauss(spd, SPEED_SIGMA_MPS)),
            "heading": (brg + rng.gauss(0, HEADING_SIGMA_DEG)) % 360.0,
        })

    # --- Matcher: nearest segment + heading gate + hysteresis (D2) ---------
    cell = 100.0
    grid = collections.defaultdict(list)  # cell -> [(way_id, seg_index)]
    way_pts = {}
    for w in ways:
        pts = [geo.xy(g["lat"], g["lon"]) for g in w["geometry"]]
        way_pts[w["id"]] = pts
        for i, (a, b) in enumerate(zip(pts, pts[1:])):
            for cx in range(int(min(a[0], b[0]) // cell), int(max(a[0], b[0]) // cell) + 1):
                for cy in range(int(min(a[1], b[1]) // cell), int(max(a[1], b[1]) // cell) + 1):
                    grid[(cx, cy)].append((w["id"], i))

    def candidates(p):
        cx, cy = int(p[0] // cell), int(p[1] // cell)
        segs = set()
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                segs.update(grid.get((cx + dx, cy + dy), ()))
        best = {}
        for wid, i in segs:
            pts = way_pts[wid]
            d, tt, proj = point_seg(p, pts[i], pts[i + 1])
            if d <= MATCH_RADIUS_M and (wid not in best or d < best[wid][0]):
                best[wid] = (d, bearing(pts[i], pts[i + 1]), proj, i)
        return best

    matched = []  # per sample: (way_id, projection, seg_index) or (None,)*3
    current, challenger, challenge_count = None, None, 0
    for f in fixes:
        cand = {wid: v for wid, v in candidates(f["xy"]).items()
                if undirected_diff(f["heading"], v[1]) <= HEADING_GATE_DEG}
        if not cand:
            matched.append((current, None, None))
            continue
        best_wid = min(cand, key=lambda w: cand[w][0])
        if current in cand:
            if best_wid != current and \
               cand[best_wid][0] < cand[current][0] - HYSTERESIS_MARGIN_M:
                if challenger == best_wid:
                    challenge_count += 1
                else:
                    challenger, challenge_count = best_wid, 1
                if challenge_count >= HYSTERESIS_SAMPLES:
                    current, challenger, challenge_count = best_wid, None, 0
            else:
                challenger, challenge_count = None, 0
        else:
            current, challenger, challenge_count = best_wid, None, 0
        c = cand.get(current)
        matched.append((current, c[2], c[3]) if c else (current, None, None))

    # --- Phone-side distance model: graph distance to each zone boundary ---
    # The phone knows the road graph, its matched position, and its heading —
    # NOT the planned route (D2 rejected route-locked matching). Per event,
    # precompute shortest-path distances from the zone's entry and exit
    # nodes; per sample, distance_to_start is the graph distance from the
    # matched projection, and a DIRECTED heading gate (±90°) keeps events
    # that lie behind the rider from emitting observations.
    for e in events:
        i0 = next(i for i, wid in enumerate(route_edge_ways)
                  if wid in set(e["ways"]))
        e["start_node"] = route_nodes[i0]
        e["end_node"] = route_nodes[
            max(i for i, wid in enumerate(route_edge_ways)
                if wid in set(e["ways"]) and chain[i + 1] <= e["end"] + 1.0) + 1]
        e["d_start"], _ = graph.dijkstra(e["start_node"])
        e["d_end"], _ = graph.dijkstra(e["end_node"])
        e["way_set"] = set(e["ways"])

    def graph_dist(dmap, wid, seg_idx, proj):
        ids = by_id[wid]["nodes"]
        a, b = ids[seg_idx], ids[seg_idx + 1]
        opts = []
        for n in (a, b):
            if n in dmap:
                opts.append((dmap[n] + dist(proj, graph.node_xy[n]), n))
        return min(opts) if opts else (None, None)

    samples, observations = [], []
    ds_err = []  # emitted distance_to_start vs route ground truth (approach only)
    for f, (wid, proj, seg_idx), (tt, c_true, _, _, true_wid, _) in \
            zip(fixes, matched, truth):
        t_ms = f["t"] * 1000
        samples.append({
            "t_ms": t_ms,
            "lat_e7": None,  # filled for debug trace only
            "speed_cmps": min(65535, round(f["speed"] * 100)),
            "heading_deg_x10": round(f["heading"] * 10) % 3600,
            "segment_id": wid if wid is not None else 0,
        })
        if proj is None:
            continue
        for e in events:
            ds_mag, ds_node = graph_dist(e["d_start"], wid, seg_idx, proj)
            de_mag, _ = graph_dist(e["d_end"], wid, seg_idx, proj)
            if ds_mag is None or de_mag is None:
                continue
            if wid in e["way_set"]:
                ds, de = -round(ds_mag), round(de_mag)
            elif ds_mag <= de_mag:  # approach side
                ds, de = round(ds_mag), round(de_mag)
                # Directed gate: the way toward the zone entry must roughly
                # agree with travel direction, or the event is behind us.
                toward = graph.node_xy[ds_node]
                if dist(proj, toward) > 1.0:
                    diff = abs(f["heading"] - bearing(proj, toward)) % 360.0
                    if min(diff, 360.0 - diff) > 90.0:
                        continue
            else:  # past side: the phone drops events behind the rider
                continue
            if ds <= args.horizon_m and de >= -100:
                observations.append({
                    "t_ms": t_ms,
                    "event_id": e["event_id"],
                    "family": "COMPOSITE_SQUEEZE_ZONE",
                    "segment_id": e["segment_id"],
                    "severity": SQUEEZE_SEVERITY,
                    "confidence": SQUEEZE_CONFIDENCE,
                    "reasons_bitmask": SQUEEZE_REASONS,
                    "distance_to_start_m": max(INT16_MIN, min(INT16_MAX, ds)),
                    "distance_to_end_m": max(INT16_MIN, min(INT16_MAX, de)),
                })
                true_ds = e["start"] - c_true
                if ds > 0 and 0 < true_ds <= args.horizon_m:
                    ds_err.append(ds - true_ds)

    match_ok = sum(1 for (wid, _, _), tr in zip(matched, truth) if wid == tr[4])
    print(f"matcher: {match_ok}/{len(truth)} samples on the true way "
          f"({100 * match_ok / len(truth):.1f}%); "
          f"{sum(1 for w, _, _ in matched if w is None)} unmatched")
    if ds_err:
        ae = sorted(abs(e) for e in ds_err)
        p95 = ae[min(len(ae) - 1, max(0, math.ceil(len(ae) * 0.95) - 1))]
        print(f"distance_to_start |error| on approach: median "
              f"{ae[len(ae) // 2]:.1f} m, p95 {p95:.1f} m, "
              f"max {ae[-1]:.1f} m over {len(ae)} observations")

    # --- Trace + kernel oracle ---------------------------------------------
    trace = {
        "schema_version": 1,
        "ride_id": f"d6-sim-seed{args.seed}",
        "started_at": "2026-07-10T00:00:00Z",
        "policy_config": {
            "severity_threshold": 128, "confidence_threshold": 128,
            "min_notice_s": 5, "max_notice_s": args.max_notice_s,
            "min_cooldown_s": 15, "min_cooldown_m": 75, "min_speed_kmh": 4,
        },
        "samples": [{k: v for k, v in s.items() if k != "lat_e7"} for s in samples],
        "route_events": observations,
        "cue_decisions": [],
        "markers": [],
        "reviews": [],
    }
    out = f"{args.out_dir}/d6_trace.json"
    with open(out, "w") as fh:
        json.dump(trace, fh, indent=1)

    printed = subprocess.run([args.replay_cli, "--print", out],
                             capture_output=True, text=True)
    if printed.returncode != 0:
        sys.exit(f"replay_cli --print failed:\n{printed.stdout}{printed.stderr}")
    trace["cue_decisions"] = json.loads(printed.stdout)
    with open(out, "w") as fh:
        json.dump(trace, fh, indent=1)

    if args.debug_trace:
        for s, f in zip(samples, fixes):
            lat, lon = geo.latlon(*f["xy"])
            s["lat_e7"], s["lon_e7"] = round(lat * 1e7), round(lon * 1e7)
        dbg = dict(trace)
        dbg["samples"] = samples
        with open(f"{args.out_dir}/d6_trace_debug.json", "w") as fh:
            json.dump(dbg, fh, indent=1)
        print(f"debug trace (has GPS, do not commit): {args.out_dir}/d6_trace_debug.json")

    stats = subprocess.run([args.replay_cli, "--stats", out],
                           capture_output=True, text=True)
    print(f"\n--- replay_cli --stats ({'OK' if stats.returncode == 0 else 'DIVERGENCE'}) ---")
    print(stats.stdout.rstrip())
    if stats.returncode != 0:
        sys.exit("round-trip divergence — live/replay bug class, investigate")

    # --- Ground truth: cue time vs actual zone entry ------------------------
    print("\n--- ground truth (simulation-side, invisible to the kernel) ---")
    cfg = trace["policy_config"]
    cues = {d["event_id"]: d for d in trace["cue_decisions"] if d["type"] == "HEAD_UP"}
    in_window = 0
    for e in events:
        entry_t = None
        for (tt, c_true, *_), (tt2, c2, *_) in zip(truth, truth[1:]):
            if c_true < e["start"] <= c2:
                entry_t = tt + (e["start"] - c_true) / (c2 - c_true)
                break
        d = cues.get(e["event_id"])
        if d is None:
            print(f"event {e['event_id']}: NO CUE (entry at t={entry_t:.1f}s) — missed coverage")
            continue
        true_lead = entry_t - d["t_ms"] / 1000.0
        ok = cfg["min_notice_s"] <= true_lead <= cfg["max_notice_s"]
        in_window += ok
        print(f"event {e['event_id']}: cue at t={d['t_ms'] / 1000:.0f}s, kernel lead "
              f"{d['lead_time_s']}s, TRUE lead {true_lead:.1f}s "
              f"{'IN' if ok else 'OUTSIDE'} [{cfg['min_notice_s']}, {cfg['max_notice_s']}] s")
    print(f"\nverdict: {in_window}/{len(events)} zone entries cued inside the "
          f"true notice window (seed {args.seed})")


if __name__ == "__main__":
    main()
