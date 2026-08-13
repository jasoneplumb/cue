#!/usr/bin/env python3
"""
Intent: On-target portability certificate (RFC 0006 D6) — streams every
        checked-in replay trace to a Pico W running mcu/pico-cue's
        USB-CDC replay port and diffs decisions against the trace's
        recorded cue_decisions, the same golden `replay_cli` verifies on
        the host. Then streams a must-diverge fixture and asserts
        divergence IS detected, proving the comparator itself works
        (mirrors replay/Makefile's own exit-1 assertion).
Context: mcu/pico-cue/src/cue_usb_replay.h documents the line protocol;
         feed/compare semantics mirror replay/replay_main.c's sample loop
         exactly (route_events exact-match per sample, personal_memory
         carry-forward, decisions compared only against the trace's own
         golden — this tool trusts replay_cli already validated the
         trace's shape via `make -C replay test`).
Pattern: Host-side tool (pyserial); no allocation/determinism concerns
         apply here the way they do in kernel/ or replay/ — this is a
         test harness, not part of the module boundary CLAUDE.md defines
         for kernel/replay/ios.
Usage:
  hiltest.py --port /dev/tty.usbmodemXXXX
  hiltest.py --port /dev/tty.usbmodemXXXX --traces-dir ../../replay/traces \
             --must-diverge ../../replay/tests/config_drift_divergence.json
"""
import argparse
import glob
import json
import os
import sys
import time

try:
    import serial
except ImportError:
    # `make -C mcu hiltest` provisions a venv automatically; this message
    # is for a direct invocation. Plain `pip install` is refused on
    # PEP 668-managed interpreters (stock macOS/Homebrew python), so
    # point at the venv route rather than a command that will fail.
    print(
        "ERROR: pyserial is required.\n"
        "  Easiest: make -C mcu hiltest PORT=/dev/tty.usbmodemXXXX "
        "(provisions a venv for you)\n"
        "  Manual:  python3 -m venv .venv && .venv/bin/pip install pyserial "
        "&& .venv/bin/python tools/cue-hiltest/hiltest.py ...",
        file=sys.stderr,
    )
    sys.exit(2)

FAMILY_TO_NUM = {"COMPOSITE_SQUEEZE_ZONE": 1}
TYPE_TO_NUM = {"NONE": 0, "HEAD_UP": 1}
TYPE_FROM_NUM = {0: "NONE", 1: "HEAD_UP"}
MEMORY_STATE_TO_NUM = {"NEUTRAL": 0, "UNSAFE": 1, "SUPPRESS": 2}

DEFAULT_TIMEOUT_S = 3.0


class HiltestError(Exception):
    pass


def check_event_cap_agreement(here):
    """Deferred finding from PR #150 (issue #151): CUE_WIRE_STEP_MAX_EVENTS
    (mcu/shared/cue_wire.h) and REPLAY_MAX_EVENTS_PER_SAMPLE
    (replay/replay_main.c) must agree, or the wire protocol and the trace
    corpus's own per-sample cap could silently drift apart. This is
    tools-side introspection, not a code dependency — it does not widen
    replay/'s documented boundary (CLAUDE.md: replay depends only on
    kernel and the trace schema), it just reads both source files as text
    to catch drift before it reaches hardware."""
    import re

    wire_path = os.path.normpath(os.path.join(here, "..", "..", "mcu", "shared", "cue_wire.h"))
    replay_path = os.path.normpath(os.path.join(here, "..", "..", "replay", "replay_main.c"))
    try:
        with open(wire_path) as f:
            wire_src = f.read()
        with open(replay_path) as f:
            replay_src = f.read()
    except OSError as e:
        raise HiltestError(
            f"could not read {e.filename} for the event-cap check — run this "
            "tool from a full checkout (or via `make -C mcu hiltest`)"
        ) from e

    wire_match = re.search(r"CUE_WIRE_STEP_MAX_EVENTS\s+(\d+)u", wire_src)
    replay_match = re.search(r"REPLAY_MAX_EVENTS_PER_SAMPLE\s+(\d+)", replay_src)
    if not wire_match or not replay_match:
        raise HiltestError(
            "could not find CUE_WIRE_STEP_MAX_EVENTS or "
            "REPLAY_MAX_EVENTS_PER_SAMPLE — the constants may have been "
            "renamed; update check_event_cap_agreement()"
        )
    wire_cap, replay_cap = int(wire_match.group(1)), int(replay_match.group(1))
    if wire_cap != replay_cap:
        raise HiltestError(
            f"event-cap drift: CUE_WIRE_STEP_MAX_EVENTS={wire_cap} != "
            f"REPLAY_MAX_EVENTS_PER_SAMPLE={replay_cap} — the wire protocol "
            "and the trace corpus's per-sample cap must agree (issue #151)"
        )


class PicoLink:
    """Thin line-protocol client over the USB-CDC serial port."""

    def __init__(self, port, baud=115200, timeout=DEFAULT_TIMEOUT_S):
        self._ser = serial.Serial(port, baud, timeout=timeout)
        # The Pico's USB-CDC stack needs a moment after enumeration/reset
        # before it reliably echoes; a stale partial line from a previous
        # session (if any) is discarded rather than misread as a response.
        time.sleep(0.5)
        self._ser.reset_input_buffer()

    def close(self):
        self._ser.close()

    def request(self, line):
        self._ser.write((line + "\n").encode("ascii"))
        raw = self._ser.readline()
        if not raw:
            raise HiltestError(f"timed out waiting for a response to: {line}")
        return raw.decode("ascii", errors="replace").rstrip("\r\n")


def decode_config(cfg):
    return ",".join(
        str(cfg[k])
        for k in (
            "severity_threshold",
            "confidence_threshold",
            "min_notice_s",
            "max_notice_s",
            "min_cooldown_s",
            "min_cooldown_m",
            "min_speed_kmh",
        )
    )


def encode_step(sample, events, memory):
    parts = [
        str(sample["t_ms"]),
        str(sample["speed_cmps"]),
        str(sample.get("heading_deg_x10", 0)),  # opt_u16 default, per RFC 0006 D3
        str(sample["segment_id"]),
        str(len(events)),
    ]
    line = ",".join(parts)
    for e in events:
        family = FAMILY_TO_NUM.get(e["family"])
        if family is None:
            raise HiltestError(
                f"unknown route-event family {e['family']!r} at t_ms="
                f"{sample['t_ms']} — the kernel's family table grew; extend "
                "FAMILY_TO_NUM to match cue_policy.h"
            )
        line += ";E " + ",".join(
            str(v)
            for v in (
                e["event_id"],
                family,
                e["segment_id"],
                e["severity"],
                e["confidence"],
                e["reasons_bitmask"],
                e["distance_to_start_m"],
                e["distance_to_end_m"],
            )
        )
    if memory is not None:
        state = MEMORY_STATE_TO_NUM.get(memory["state"])
        if state is None:
            raise HiltestError(
                f"unknown personal-memory state {memory['state']!r} at t_ms="
                f"{sample['t_ms']} — extend MEMORY_STATE_TO_NUM to match "
                "PersonalMemoryState in cue_policy.h"
            )
        line += ";M " + ",".join(
            str(v)
            for v in (
                memory["segment_id"],
                state,
                memory["notice_bonus_s"],
            )
        )
    return "STEP " + line


def parse_decision(response):
    if not response.startswith("DEC "):
        raise HiltestError(f"expected a DEC response, got: {response}")
    fields = response[len("DEC ") :].split(",")
    if len(fields) != 4:
        raise HiltestError(f"malformed DEC response: {response}")
    try:
        dtype, event_id, reason_code, lead_time_s = (int(f) for f in fields)
    except ValueError as e:
        # Non-numeric field: a framing error (a response read out of step
        # with its request) or a firmware bug — either way not a divergence.
        raise HiltestError(f"non-numeric field in DEC response: {response}") from e
    return {
        "type": TYPE_FROM_NUM.get(dtype, dtype),
        "event_id": event_id,
        "reason_code": reason_code,
        "lead_time_s": lead_time_s,
    }


def replay_trace(link, trace):
    """Streams one trace's samples through the Pico; returns (matched,
    divergences, mismatches) mirroring replay_main.c's verify-mode
    semantics exactly (route_events exact-match, personal_memory
    carry-forward, decisions checked only at their recorded t_ms, an
    unrecorded HEAD_UP is always a divergence)."""
    ack = link.request("CFG " + decode_config(trace["policy_config"]))
    if ack != "OK":
        raise HiltestError(f"CFG rejected: {ack}")

    events_by_t = {}
    for obs in trace["route_events"]:
        events_by_t.setdefault(obs["t_ms"], []).append(obs)

    memory_by_t = {}
    for rec in trace.get("personal_memory", []):
        memory_by_t[rec["t_ms"]] = rec

    decisions_by_t = {rec["t_ms"]: rec for rec in trace["cue_decisions"]}

    matched = 0
    divergences = 0
    mismatches = []
    current_memory = None

    for sample in trace["samples"]:
        t_ms = sample["t_ms"]
        events = events_by_t.get(t_ms, [])
        if t_ms in memory_by_t:
            current_memory = memory_by_t[t_ms]

        response = link.request(encode_step(sample, events, current_memory))
        decision = parse_decision(response)

        recorded = decisions_by_t.get(t_ms)
        if recorded is not None:
            if (
                recorded["type"] != decision["type"]
                or recorded["event_id"] != decision["event_id"]
                or recorded["reason_code"] != decision["reason_code"]
                or recorded["lead_time_s"] != decision["lead_time_s"]
            ):
                mismatches.append((t_ms, recorded, decision))
                divergences += 1
            else:
                matched += 1
        elif decision["type"] != "NONE":
            mismatches.append((t_ms, None, decision))
            divergences += 1

    return matched, divergences, mismatches


def print_mismatches(trace_name, mismatches):
    for t_ms, recorded, decision in mismatches:
        if recorded is None:
            print(
                f"  DIVERGENCE t_ms={t_ms}: pico emitted HEAD_UP (event "
                f"{decision['event_id']}, lead {decision['lead_time_s']} s) "
                f"absent from recorded cue_decisions ({trace_name})"
            )
        else:
            print(
                f"  DIVERGENCE t_ms={t_ms}: recorded {recorded} != "
                f"pico {decision} ({trace_name})"
            )


def run_trace_file(link, path, expect_divergence):
    try:
        with open(path) as f:
            trace = json.load(f)
    except OSError as e:
        raise HiltestError(f"could not read trace {path}: {e}") from e
    except json.JSONDecodeError as e:
        raise HiltestError(f"malformed trace JSON in {path}: {e}") from e
    name = os.path.basename(path)
    matched, divergences, mismatches = replay_trace(link, trace)
    if expect_divergence:
        if divergences == 0:
            print(f"FAIL {name}: expected a divergence, but none was detected")
            return False
        print(f"ok   {name}: divergence detected as expected "
              f"({divergences} divergence(s) across {matched + divergences} samples)")
        return True
    if divergences != 0:
        print(f"FAIL {name}: {divergences} divergence(s) across "
              f"{matched + divergences} samples")
        print_mismatches(name, mismatches)
        return False
    print(f"ok   {name}: {matched} sample(s) matched, 0 divergences")
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True, help="Serial port, e.g. /dev/tty.usbmodem14401")
    parser.add_argument("--baud", type=int, default=115200)
    here = os.path.dirname(os.path.abspath(__file__))
    default_traces = os.path.normpath(os.path.join(here, "..", "..", "replay", "traces"))
    default_must_diverge = os.path.normpath(
        os.path.join(here, "..", "..", "replay", "tests", "config_drift_divergence.json")
    )
    parser.add_argument("--traces-dir", default=default_traces)
    parser.add_argument(
        "--must-diverge",
        action="append",
        default=None,
        help="Trace(s) that must produce at least one divergence — proves "
        "the comparator itself works. Repeatable. Defaults to "
        "replay/tests/config_drift_divergence.json.",
    )
    args = parser.parse_args()
    must_diverge = args.must_diverge or [default_must_diverge]

    try:
        check_event_cap_agreement(here)
    except HiltestError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2

    # Opening the port is the likeliest failure in practice (wrong PORT=,
    # board unplugged, permissions), so it gets the same clean ERROR: path
    # as everything else rather than a traceback.
    try:
        link = PicoLink(args.port, args.baud)
    except (serial.SerialException, OSError) as e:
        print(
            f"ERROR: could not open {args.port}: {e}\n"
            "  Check the board is plugged in and running pico_cue "
            "(ls /dev/tty.usbmodem* on macOS, /dev/ttyACM* on Linux)",
            file=sys.stderr,
        )
        return 2

    try:
        pong = link.request("PING")
        print(f"connected: {pong}")

        traces = sorted(glob.glob(os.path.join(args.traces_dir, "*.json")))
        if not traces:
            print(f"ERROR: no traces found in {args.traces_dir}", file=sys.stderr)
            return 2

        ok = True
        for path in traces:
            ok = run_trace_file(link, path, expect_divergence=False) and ok
        for path in must_diverge:
            ok = run_trace_file(link, path, expect_divergence=True) and ok

        if ok:
            print("hiltest: all traces certified — pico decisions match the host replay")
            return 0
        print("hiltest: FAILED — see divergences above", file=sys.stderr)
        return 1
    except HiltestError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2
    finally:
        link.close()


if __name__ == "__main__":
    sys.exit(main())
