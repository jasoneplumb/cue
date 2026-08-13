#!/usr/bin/env python3
"""
Intent: Replay-based ablation sweep — re-run the local ride corpus through
        kernel policy variants and print the comparison table, so policy
        questions are answered from recorded rides instead of new riding
        (docs/ablations.md).
Context: Uses replay_cli --print (which evaluates but never verifies, exit 0)
         over per-variant rewrites of each trace's policy_config /
         personal_memory; the distance-gate variant is a replay_cli built
         with -DCUE_ABLATION_DISTANCE_GATE (kernel/cue_policy.c — replay
         ablation builds only, #error-guarded out of firmware).
Pattern: stdlib-only; deterministic iteration order; binaries come from
         replay/Makefile's own recipe (BUILD=/CFLAGS= overrides) so this
         tool cannot silently build a different replay_cli than CI tests;
         all paths resolve against the repo root, so it runs from any CWD.
Future: promote a variant to a CuePolicyConfig field if an ablation ever
        graduates into the §13 tuning loop.

Usage: python3 tools/cue-ablation/ablate.py [rides-dir]
"""
from __future__ import annotations

import glob
import json
import os
import statistics
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Must match replay/Makefile's CFLAGS default — passed explicitly because a
# command-line CFLAGS= replaces the ?= default entirely.
REPLAY_CFLAGS = "-std=c99 -Wall -Wextra -Werror -pedantic -O2"

REASON_NAMES = {
    0: "CUED", 1: "NO_EVENT", 2: "SEVERITY", 3: "CONFIDENCE",
    4: "INSIDE_EVENT", 5: "TOO_SLOW", 6: "TOO_LATE", 7: "TOO_EARLY",
    8: "ALREADY_CUED", 9: "COOLDOWN_TIME", 10: "COOLDOWN_DISTANCE",
    11: "MEMORY_SUPPRESSED",
}


def build_baseline_cli() -> str:
    subprocess.run(["make", "-C", "replay", "build/replay_cli"],
                   cwd=ROOT, check=True, capture_output=True)
    return os.path.join(ROOT, "replay", "build", "replay_cli")


def build_distance_cli(workdir: str) -> str:
    # Same Makefile recipe as the baseline binary — only the output dir and
    # the ablation define differ, so source lists and include paths cannot
    # drift from what CI builds.
    out = os.path.join(workdir, "replay_cli")
    subprocess.run(
        ["make", "-C", "replay", f"BUILD={workdir}",
         f"CFLAGS={REPLAY_CFLAGS} -DCUE_ABLATION_DISTANCE_GATE", out],
        cwd=ROOT, check=True, capture_output=True)
    return out


def variant_trace(trace: dict, variant: str) -> dict:
    t = json.loads(json.dumps(trace))  # deep copy
    if variant in ("baseline", "distance_gate"):
        pass  # inputs unchanged (distance_gate differs in the binary)
    elif variant == "no_memory":
        t["personal_memory"] = []
    elif variant == "no_thresholds":
        cfg = t["policy_config"]
        cfg["severity_threshold"] = 0
        cfg["confidence_threshold"] = 0
        cfg["min_cooldown_s"] = 0
        cfg["min_cooldown_m"] = 0
    elif variant == "every_zone":
        # no_thresholds plus the notice window blown open: the true
        # "cue once per approached zone" upper bound. Only the speed gate
        # (min_speed_kmh stays 1 as the division guard), INSIDE_EVENT,
        # and the FR-004 one-cue-per-event budget remain.
        cfg = t["policy_config"]
        cfg["severity_threshold"] = 0
        cfg["confidence_threshold"] = 0
        cfg["min_cooldown_s"] = 0
        cfg["min_cooldown_m"] = 0
        cfg["min_notice_s"] = 0
        cfg["max_notice_s"] = 32767
    else:
        raise ValueError(f"unknown variant {variant!r}")
    return t


def run_variant(cli: str, variant: str, trace_paths: list[str],
                workdir: str) -> dict:
    cues = 0
    leads: list[int] = []
    supp: dict[str, int] = {}
    per_ride = []
    for path in trace_paths:
        with open(path) as f:
            trace = json.load(f)
        rewritten = variant_trace(trace, variant)
        tmp = os.path.join(workdir, variant + "-" + os.path.basename(path))
        with open(tmp, "w") as f:
            json.dump(rewritten, f)
        proc = subprocess.run([cli, "--print", tmp], capture_output=True,
                              text=True, check=True, cwd=ROOT)
        decisions = json.loads(proc.stdout)
        ride_cues = 0
        for d in decisions:
            if d["type"] == "HEAD_UP":
                cues += 1
                ride_cues += 1
                leads.append(d["lead_time_s"])
            else:
                name = REASON_NAMES.get(d["reason_code"], str(d["reason_code"]))
                supp[name] = supp.get(name, 0) + 1
        per_ride.append((os.path.basename(path), ride_cues))
    return {"cues": cues, "leads": leads, "suppressed": supp,
            "per_ride": per_ride}


def main() -> int:
    rides = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "rides")
    trace_paths = sorted(glob.glob(os.path.join(rides, "*-trace.json")))
    if not trace_paths:
        print(f"no *-trace.json under {rides}/", file=sys.stderr)
        return 2

    with tempfile.TemporaryDirectory() as workdir:
        cli = build_baseline_cli()
        cli_distance = build_distance_cli(workdir)

        variants = [
            ("baseline", cli),
            ("no_memory", cli),
            ("no_thresholds", cli),
            ("every_zone", cli),
            ("distance_gate", cli_distance),
        ]
        results = {}
        for name, binary in variants:
            results[name] = run_variant(binary, name, trace_paths, workdir)

        # Sanity: baseline must reproduce every recorded HEAD_UP exactly —
        # same kernel, same config, so anything else means this harness
        # rewrote something it shouldn't have.
        recorded = 0
        for path in trace_paths:
            with open(path) as f:
                trace = json.load(f)
            recorded += sum(1 for d in (trace.get("cue_decisions") or [])
                            if d.get("type") == "HEAD_UP")
        if results["baseline"]["cues"] != recorded:
            print(f"SANITY FAILED: baseline replayed "
                  f"{results['baseline']['cues']} cues vs {recorded} recorded",
                  file=sys.stderr)
            return 1

        print(f"corpus: {len(trace_paths)} traces, "
              f"{recorded} recorded HEAD_UP cues (baseline reproduces them)")
        print()
        print("| Variant | Cues | Lead s min/med/max | In 5–20 s window | Top suppressions |")
        print("| --- | --- | --- | --- | --- |")
        for name, _ in variants:
            r = results[name]
            if r["leads"]:
                lead = (f"{min(r['leads'])} / "
                        f"{statistics.median(r['leads']):g} / "
                        f"{max(r['leads'])}")
                in_window = sum(1 for s in r["leads"] if 5 <= s <= 20)
                window = f"{in_window}/{len(r['leads'])}"
            else:
                lead = "—"
                window = "—"
            top = sorted(r["suppressed"].items(), key=lambda kv: -kv[1])[:3]
            tops = ", ".join(f"{k} {v:,}" for k, v in top)
            print(f"| {name} | {r['cues']} | {lead} | {window} | {tops} |")
        print()
        print("full suppression histograms:")
        for name, _ in variants:
            r = results[name]
            hist = ", ".join(f"{k}={v:,}" for k, v in
                             sorted(r["suppressed"].items(),
                                    key=lambda kv: -kv[1]))
            print(f"  {name}: {hist}")
        print()
        for name, _ in variants:
            r = results[name]
            base = dict(results["baseline"]["per_ride"])
            diffs = [f"{ride}: {base[ride]}→{n}" for ride, n in r["per_ride"]
                     if n != base[ride]]
            if name != "baseline" and diffs:
                print(f"{name} per-ride deltas: " + "; ".join(diffs))
    return 0


if __name__ == "__main__":
    sys.exit(main())
