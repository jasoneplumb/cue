#!/usr/bin/env python3
"""
Intent: Generate a synthetic, coordinate-free demo ride corpus so a fresh
        clone can run the results aggregator and the ablation sweep without
        the operator's private field data (NFR-005: real rides never ship).
Context: Emits schema-v2-shaped traces in the replay fixture style (samples
         carry no lat/lon — the harness zero-fills them); cue_decisions are
         authored by the real kernel via `replay_cli --print` (replay/README
         authoring flow), then every trace is verified round-trip with a
         plain replay_cli run (exit 0), so the corpus ships pre-certified.
Pattern: stdlib-only, fixed default seed — the corpus is byte-identical
         across runs and platforms for a given (seed, count). The kernel is
         never reimplemented here; python only shapes inputs.
Future: grow ride shapes (memory records, retreat/refund approaches) as the
        demo needs them; keep every shape coordinate-free.

Usage: python3 tools/cue-demo-corpus/generate.py [--out demo-rides] [--rides 6] [--seed 7]
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import random
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

DEFAULT_CONFIG = {
    "severity_threshold": 128,
    "confidence_threshold": 128,
    "min_notice_s": 5,
    "max_notice_s": 20,
    "min_cooldown_s": 15,
    "min_cooldown_m": 75,
    "min_speed_kmh": 1,
}


def build_ride(rng: random.Random, ride_idx: int) -> dict:
    """One synthetic ride: cruise segments with speed variation, several
    squeeze zones approached at different speeds, occasional stops."""
    samples = []
    events = []
    t_ms = 0
    zone_count = rng.randint(2, 5)
    # Zones staggered along the ride; each gets an approach profile.
    next_event_id = ride_idx * 1000 + 101
    segment_id = ride_idx * 100 + 1

    for zone in range(zone_count):
        speed = rng.choice([180, 250, 400, 550, 700, 900, 1200])  # cm/s
        # Cruise toward the zone from ~40 s out.
        dist_m = (speed * 40) // 100 + rng.randint(20, 80)
        severity = rng.randint(150, 240)
        confidence = rng.randint(150, 240)
        zone_len = rng.randint(80, 300)
        eid = next_event_id
        next_event_id += 1
        while dist_m > -zone_len:
            jitter = rng.randint(-15, 15)
            v = max(60, speed + jitter)
            samples.append({"t_ms": t_ms, "speed_cmps": v,
                            "segment_id": segment_id})
            events.append({
                "t_ms": t_ms, "event_id": eid,
                "family": "COMPOSITE_SQUEEZE_ZONE",
                "segment_id": segment_id,
                "severity": severity, "confidence": confidence,
                "reasons_bitmask": 7,
                "distance_to_start_m": dist_m,
                "distance_to_end_m": dist_m + zone_len,
            })
            t_ms += 1000
            # max(1, ...): v < 100 cm/s must still make progress, or the
            # approach loop never terminates.
            dist_m -= max(1, v // 100)
        # Post-zone gap with no observations (idle cruise + a brief stop).
        segment_id += 1
        for _ in range(rng.randint(20, 45)):
            samples.append({"t_ms": t_ms,
                            "speed_cmps": rng.choice([0, 0, 120, 300, 500]),
                            "segment_id": segment_id})
            t_ms += 1000
        segment_id += 1

    return {
        "schema_version": 2,
        "ride_id": f"demo-ride-{ride_idx:02d}",
        # Real date arithmetic, not string formatting, so any --rides count
        # yields valid ISO-8601 (review, PR #190 x2).
        "started_at": (datetime.datetime(2026, 1, 1, 12, 0)
                       + datetime.timedelta(minutes=ride_idx)
                       ).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "policy_config": dict(DEFAULT_CONFIG),
        "samples": samples,
        "route_events": events,
        "personal_memory": [],
        "cue_decisions": [],
        "markers": [],
        "reviews": [],
    }


def author_decisions(cli: str, trace: dict, tmp_path: str) -> list:
    with open(tmp_path, "w") as f:
        json.dump(trace, f)
    proc = subprocess.run([cli, "--print", tmp_path], capture_output=True,
                          text=True, check=True, timeout=60)
    return json.loads(proc.stdout)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="demo-rides")
    ap.add_argument("--rides", type=int, default=6)
    ap.add_argument("--seed", type=int, default=7)
    args = ap.parse_args()

    subprocess.run(["make", "-C", "replay", "build/replay_cli"],
                   cwd=ROOT, check=True, capture_output=True, timeout=300)
    cli = os.path.join(ROOT, "replay", "build", "replay_cli")

    out = args.out if os.path.isabs(args.out) else os.path.join(ROOT, args.out)
    os.makedirs(out, exist_ok=True)
    rng = random.Random(args.seed)
    total_cues = 0
    for i in range(args.rides):
        trace = build_ride(rng, i)
        path = os.path.join(out, f"demo-ride-{i:02d}-trace.json")
        decisions = author_decisions(cli, trace, path)
        # Producers must record every HEAD_UP (replay/README): keep exactly
        # those; recording suppressed decisions is optional and omitted.
        trace["cue_decisions"] = [d for d in decisions
                                  if d["type"] == "HEAD_UP"]
        total_cues += len(trace["cue_decisions"])
        with open(path, "w") as f:
            json.dump(trace, f, indent=1)
            f.write("\n")
        # Round-trip certification: the authored trace must replay exit-0.
        subprocess.run([cli, path], check=True, capture_output=True,
                       timeout=60)
        print(f"{os.path.relpath(path, ROOT)}: "
              f"{len(trace['samples'])} samples, "
              f"{len(trace['cue_decisions'])} cues (replay OK)")
    print(f"demo corpus: {args.rides} rides, {total_cues} cues — every trace "
          f"replays bit-exact against the kernel that authored it")
    return 0


if __name__ == "__main__":
    sys.exit(main())
