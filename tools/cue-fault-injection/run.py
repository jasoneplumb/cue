#!/usr/bin/env python3
"""Intent: Build and record a reproducible host fault-injection campaign.
Context: Uses the real session/wire/kernel C; no radio, GPIO or Swift runtime.
Pattern: Fresh temporary builds, one isolated mutant, fail on unmet expectations.
Future: Add on-target execution without changing the host evidence label.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
INPUTS = ["tools/cue-fault-injection/run.py", "tools/cue-fault-injection/campaign.c",
          "kernel/cue_policy.c", "kernel/cue_policy.h", "mcu/shared/cue_wire.h",
          "mcu/pico-cue/src/cue_session.c", "mcu/pico-cue/src/cue_session.h",
          "mcu/pico-cue/src/cue_pattern.c", "mcu/pico-cue/src/cue_pattern.h"]


def run(args, **kwargs):
    proc = subprocess.run(args, cwd=ROOT, capture_output=True, text=True, **kwargs)
    if proc.returncode:
        print(proc.stdout + proc.stderr, end="", file=sys.stderr)
        proc.check_returncode()
    return proc.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="write JSON evidence on success")
    parser.add_argument("--sanitize", action="store_true")
    args = parser.parse_args()
    cc = shlex.split(os.environ.get("CC", "cc"))
    flags = ["-std=c11", "-Wall", "-Wextra", "-Werror", "-pedantic", "-O2"]
    if args.sanitize:
        flags += ["-O1", "-g", "-fsanitize=address,undefined",
                  "-fno-sanitize-recover=all"]
    includes = ["-Ikernel", "-Imcu/shared", "-Imcu/pico-cue/src"]
    source = (ROOT / "kernel/cue_policy.c").read_text()
    old = "if (tte_s > effective_max_notice_s)"
    new = "if (tte_s > effective_max_notice_s + 1)"
    if source.count(old) != 1:
        raise RuntimeError("mutation anchor changed; review experiment before running")
    mutant = source.replace(old, new)
    commands = []
    with tempfile.TemporaryDirectory(prefix="cue-fault-") as temporary:
        build = Path(temporary)

        def compile_object(src, name, defines=()):
            out = build / (name + ".o")
            cmd = cc + flags + includes + list(defines) + ["-c", str(src), "-o", str(out)]
            commands.append([part.replace(temporary, "<build>") for part in cmd])
            run(cmd)
            return out

        kernel = compile_object("kernel/cue_policy.c", "kernel")
        pattern = compile_object("mcu/pico-cue/src/cue_pattern.c", "pattern")
        harness = compile_object("tools/cue-fault-injection/campaign.c", "campaign")
        session = compile_object("mcu/pico-cue/src/cue_session.c", "session")
        mutant_path = build / "mutant.c"
        mutant_path.write_text(mutant)
        names = ["cue_policy_step", "cue_policy_init", "cue_policy_default_config"]
        mutated_kernel = compile_object(mutant_path, "mutant", [f"-D{n}=candidate_{n}" for n in names])
        mutated_session = compile_object("mcu/pico-cue/src/cue_session.c", "mutant_session",
                                         ["-Dcue_policy_step=candidate_cue_policy_step"])
        rows = []
        binary_hashes = {}
        for name, objects, argv in [
            ("baseline", [kernel, pattern, harness, session], []),
            ("mutant", [kernel, pattern, harness, mutated_kernel, mutated_session], ["mutant"]),
        ]:
            binary = build / name
            cmd = cc + flags + list(map(str, objects)) + ["-o", str(binary)]
            commands.append([part.replace(temporary, "<build>") for part in cmd])
            run(cmd)
            binary_hashes[name] = hashlib.sha256(binary.read_bytes()).hexdigest()
            rows.extend(json.loads(line) for line in run([str(binary)] + argv).splitlines())
    if len(rows) != 10 or len({r["scenario"] for r in rows}) != 10:
        raise RuntimeError("campaign did not execute all ten expected scenarios")
    if not all(row["expectations_met"] for row in rows):
        raise RuntimeError("campaign expectation failed")
    evidence = {
        "schema_version": 1, "evidence_kind": "host_synthetic_fault_injection",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "repo_head": run(["git", "rev-parse", "HEAD"]).strip(),
        "working_tree_dirty": bool(run(["git", "status", "--porcelain"])),
        "platform": platform.platform(), "compiler": run(cc + ["--version"]).splitlines()[0],
        "flags": flags, "build_commands": commands, "binary_sha256": binary_hashes,
        "sanitizer_environment": {k: os.environ.get(k) for k in
                                  ("ASAN_OPTIONS", "LSAN_OPTIONS", "UBSAN_OPTIONS")},
        "source_sha256": {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in INPUTS},
        "mutation": {"before": old, "after": new,
                     "mutated_source_sha256": hashlib.sha256(mutant.encode()).hexdigest()},
        "scenarios": rows, "expectations_met": True,
        "limitations": ["No physical BLE, GPIO, audible output, or Swift receiver exercised.",
                        "Actuation requests are not measured physical actuations.",
                        "Compared reports include duplicate/catch-up observations, not unique steps.",
                        "The comparator is a host experiment, not production PicoStreamer.",
                        "Expected blind spots are successful characterizations, not eliminated faults.",
                        "No wall-clock detection latency or statistical failure rate is estimated."],
    }
    rendered = json.dumps(evidence, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered)
    print("| Scenario | Rejected | Decision mismatches | Actuation requests | Compared reports | Outcome |")
    print("| --- | --- | --- | --- | --- | --- |")
    for row in rows:
        print(f"| {row['scenario']} | {row['rejected_frames']} | {row['decision_mismatches']} | "
              f"{row['actuation_requests']} | {row['compared_reports']} | {row['outcome']} |")


if __name__ == "__main__":
    main()
