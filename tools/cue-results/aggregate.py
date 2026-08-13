#!/usr/bin/env python3
"""
Intent: Aggregate the rides/ corpus sidecars into the docs/results.md field
        evidence table, so every published figure is reproducible with one
        command instead of hand-collated.
Context: docs/results.md cites this script; traces per
         replay/replay_trace.schema.json, latency + pico sidecars per the
         iOS exporters and RFC 0006.
Pattern: stdlib-only, read-only, deterministic output ordering (sorted file
         globs, fixed print order) — rerunning on an unchanged corpus is
         byte-identical.
Future: grow a --json mode if webmap.dev or CI ever consumes these figures.

Usage: python3 tools/cue-results/aggregate.py [rides-dir]
"""
import glob
import json
import os
import statistics
import sys


def main() -> int:
    rides = sys.argv[1] if len(sys.argv) > 1 else "rides"
    traces = sorted(glob.glob(os.path.join(rides, "*-trace.json")))
    if not traces:
        print(f"no *-trace.json under {rides}/", file=sys.stderr)
        return 2

    total_samples = 0
    total_dist_cm = 0
    total_cues = 0
    outcomes: dict[str, int] = {}
    graded_rides = 0
    moving_traces = 0
    for path in traces:
        trace = json.load(open(path))
        # `or []` (not a .get default) so a JSON null field cannot reach the
        # loops below.
        samples = trace.get("samples") or []
        # Distance: integrate speed over dt, clamped at the kernel's 60 s
        # corrupt-trace bound (cue_policy.h) and floored at 0 — a reversed
        # timestamp must not subtract distance (Python // floors negatives).
        dist_cm = 0
        for a, b in zip(samples, samples[1:]):
            dt_ms = max(0, min(b["t_ms"] - a["t_ms"], 60000))
            dist_cm += a["speed_cmps"] * dt_ms // 1000
        # Schema: `type` is the string enum "NONE"/"HEAD_UP"
        # (replay/replay_trace.schema.json).
        cues = [d for d in (trace.get("cue_decisions") or [])
                if d.get("type") == "HEAD_UP"]
        reviews = trace.get("reviews") or []
        total_samples += len(samples)
        total_dist_cm += dist_cm
        total_cues += len(cues)
        if dist_cm > 0:
            moving_traces += 1
        if reviews:
            graded_rides += 1
        for r in reviews:
            outcome = r.get("outcome")
            if outcome is not None:
                outcomes[outcome] = outcomes.get(outcome, 0) + 1

    print("== corpus ==")
    print(f"traces: {len(traces)} ({moving_traces} with motion)")
    print(f"kernel steps (samples): {total_samples}")
    print(f"distance_km: {total_dist_cm / 100000.0:.1f}")
    print(f"HEAD_UP cues: {total_cues}")
    grades = sum(outcomes.values())
    ordered = ["useful", "false_alarm", "too_late", "too_early", "unrecognized"]
    # Unknown outcome values still print, so the breakdown always sums to
    # the total instead of silently hiding a schema surprise.
    extras = sorted(k for k in outcomes if k not in ordered)
    print(f"grades: {grades} across {graded_rides} rides — "
          + ", ".join(f"{k}={outcomes.get(k, 0)}" for k in ordered + extras))

    print("== watch delivery (latency sidecars) ==")
    dispatches = delivered = queued = other = 0
    latencies = []
    verdicts: dict[str, int] = {}
    for path in sorted(glob.glob(os.path.join(rides, "*-latency.json"))):
        sidecar = json.load(open(path))
        for cue in sidecar.get("cues") or []:
            dispatches += 1
            if cue.get("delivered"):
                delivered += 1
                if isinstance(cue.get("latency_ms"), (int, float)):
                    latencies.append(cue["latency_ms"])
                verdict = cue.get("watch_verdict") or "pre-verdict schema"
                verdicts[verdict] = verdicts.get(verdict, 0) + 1
            elif cue.get("path") == "queued":
                queued += 1
            else:
                # Neither delivered nor queued — count explicitly so the
                # three printed buckets always sum to dispatches.
                other += 1
    print(f"dispatches: {dispatches}, delivered live: {delivered}, "
          f"queued (undelivered): {queued}, other undelivered: {other}")
    if verdicts:
        print("watch verdicts among delivered: "
              + ", ".join(f"{k}={v}" for k, v in sorted(verdicts.items())))
    if latencies:
        print(f"delivery latency ms: n={len(latencies)} min={min(latencies)} "
              f"median={statistics.median(latencies):g} max={max(latencies)}")

    print("== phone<->pico shadow contract (pico sidecars, RFC 0006) ==")
    files = sorted(glob.glob(os.path.join(rides, "*-pico.json")))
    logged = compared = divergences = orphans = actuated = 0
    delays_us = []
    for path in files:
        sidecar = json.load(open(path))
        steps = sidecar.get("steps") or []
        logged += len(steps)
        compared += sidecar.get("reported_count") or 0
        divergences += sidecar.get("divergence_count") or 0
        orphans += sidecar.get("orphan_report_count") or 0
        for step in steps:
            if step.get("actuated"):
                actuated += 1
                if isinstance(step.get("actuation_delay_us"), (int, float)):
                    delays_us.append(step["actuation_delay_us"])
    print(f"instrumented rides: {len(files)}")
    print(f"steps logged: {logged}, shadow-compared: {compared}, "
          f"divergences: {divergences}, orphan reports: {orphans}")
    print(f"buzzer actuations: {actuated}")
    if delays_us:
        print(f"actuation delay us: n={len(delays_us)} min={min(delays_us)} "
              f"median={statistics.median(delays_us):g} max={max(delays_us)} "
              f"({actuated - len(delays_us)} early records at ms resolution only)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
