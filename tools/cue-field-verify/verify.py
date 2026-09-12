#!/usr/bin/env python3
"""Intent: Re-verify a supplied corpus and retain a private evidence directory.
Context: Field data is not committed; caller explicitly declares corpus kind.
Pattern: Snapshot bytes, hash inputs, fail closed, retain logs and coverage counts.
Future: Verify hardware provenance when trace schemas carry firmware hashes.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
FIELDS = ("type", "event_id", "reason_code", "lead_time_s")


def check_sidecar(data):
    steps = data["steps"]
    compared = divergent = 0
    seqs = set()
    for step in steps:
        if step["seq"] in seqs:
            raise ValueError("duplicate sequence in sidecar")
        seqs.add(step["seq"])
        present = [step.get("pico_" + field) is not None for field in FIELDS]
        if any(present) and not all(present):
            raise ValueError("partial decision report")
        if not any(present):
            if step.get("diverged") is not None:
                raise ValueError("uncompared step has divergence verdict")
            continue
        compared += 1
        mismatch = any(step["shadow_" + f] != step["pico_" + f] for f in FIELDS)
        divergent += mismatch
        # != not `is not`: a non-Python producer may write 0/1, and
        # 0 is not False under CPython identity even though 0 == False.
        if step.get("diverged") != mismatch:
            raise ValueError("stored divergence flag disagrees with decision fields")
    orphans = data.get("orphan_report_count", 0)
    if type(orphans) is not int or orphans < 0:
        raise ValueError("invalid orphan count")
    if data["reported_count"] != compared or data["divergence_count"] != divergent + orphans:
        raise ValueError("sidecar aggregate counters disagree with step evidence")
    return {"logged": len(steps), "compared": compared,
            "uncompared": len(steps) - compared, "decision_mismatches": divergent,
            "reported_orphans": orphans,
            "note": "Orphans have no step records; their count is reported, not independently proved."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("rides", type=Path)
    parser.add_argument("--corpus-kind", choices=["field", "synthetic"], required=True)
    parser.add_argument("--expected-traces", type=int)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = {"status": "running", "declared_corpus_kind": args.corpus_kind,
              "generated_at": datetime.now(timezone.utc).isoformat(),
              "note": "Corpus kind is caller-declared. No physical hardware is re-tested."}
    report_path = args.output / "verification.json"

    def save():
        report_path.write_text(json.dumps(report, indent=2) + "\n")

    def command(name, argv):
        proc = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True)
        (args.output / name).write_text(proc.stdout + proc.stderr)
        if proc.returncode:
            raise RuntimeError(f"{name}: command failed with exit {proc.returncode}")
        return proc.stdout

    try:
        # Inside the try so FileExistsError (an OSError) reaches the
        # handler, which overwrites the older report with a FAILED one —
        # never mix a failed new run with an older passing report.
        args.output.mkdir(parents=True, exist_ok=False)
        save()
        traces = sorted(args.rides.glob("*-trace.json"))
        if not traces:
            report["status"] = "blocked_missing_corpus"
            raise ValueError("No *-trace.json files found; no field result was verified.")
        if args.expected_traces is not None and len(traces) != args.expected_traces:
            raise ValueError(f"Expected {args.expected_traces} traces, found {len(traces)}")
        paths = sorted(set(traces + list(args.rides.glob("*-pico.json")) +
                           list(args.rides.glob("*-latency.json"))))
        report["repo_head"] = command("revision.txt", ["git", "rev-parse", "HEAD"]).strip()
        report["working_tree_dirty"] = bool(command("working-tree.txt", ["git", "status", "--porcelain"]))
        report["source_sha256"] = {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest()
                                   for p in ("tools/cue-field-verify/verify.py",
                                             "tools/cue-ablation/ablate.py",
                                             "tools/cue-results/aggregate.py",
                                             "replay/replay_main.c", "replay/json_mini.h",
                                             "kernel/cue_policy.c", "kernel/cue_policy.h")}
        report["input_sha256"] = {}
        with tempfile.TemporaryDirectory(prefix="cue-corpus-") as temporary:
            snapshot = Path(temporary)
            for p in paths:
                content = p.read_bytes()
                (snapshot / p.name).write_bytes(content)
                report["input_sha256"][p.name] = hashlib.sha256(content).hexdigest()
            # Explicit flags and forced build avoid reusing an ablation binary.
            command("build.txt", ["make", "-B", "-C", "replay", "CC=cc",
                    "CFLAGS=-std=c99 -Wall -Wextra -Werror -pedantic -O2", "build/replay_cli"])
            report["replay_sha256"] = hashlib.sha256((ROOT / "replay/build/replay_cli").read_bytes()).hexdigest()
            report["compiler"] = command("compiler.txt", ["cc", "--version"]).splitlines()[0]
            for i, trace in enumerate(traces):
                command(f"replay-{i:03d}.txt", [str(ROOT / "replay/build/replay_cli"), str(snapshot / trace.name)])
            report["verified_traces"] = len(traces)
            report["shadow_sidecars"] = {p.name: check_sidecar(json.loads((snapshot / p.name).read_text()))
                                         for p in paths if p.name.endswith("-pico.json")}
            if any(s["decision_mismatches"] or s["reported_orphans"]
                   for s in report["shadow_sidecars"].values()):
                raise ValueError("shadow disagreement or orphan report present")
            command("ablations.md", [sys.executable, "tools/cue-ablation/ablate.py", str(snapshot)])
            command("aggregates.txt", [sys.executable, "tools/cue-results/aggregate.py", str(snapshot)])
        report["status"] = "replay_verified"
        report["scope"] = "Recorded kernel decisions; sidecar comparisons where present. Missing reports remain explicitly uncompared."
    except (OSError, ValueError, KeyError, TypeError, RuntimeError) as error:
        if report["status"] == "running":
            report["status"] = "failed"
        report["error"] = str(error)
        try:
            save()
        except OSError:
            pass  # no writable evidence dir; stderr and the exit code still say failed
        print(str(error), file=sys.stderr)
        return 1
    save()
    print(f"{report['status']}: {report['verified_traces']} traces; evidence: {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
