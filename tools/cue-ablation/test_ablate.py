#!/usr/bin/env python3
"""Intent: Prevent count-preserving trace corruption from passing ablations.
Context: The old baseline sanity check accepted a changed cue event ID.
Pattern: Run the real CLI on small committed fixtures with targeted mutations.
Future: Extend the cases when the recorded-decision contract gains fields.
"""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(__file__).with_name("ablate.py")
spec = importlib.util.spec_from_file_location("ablate", SCRIPT)
ablate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ablate)


class VerificationTests(unittest.TestCase):
    def run_trace(self, trace):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "case-trace.json"
            path.write_text(json.dumps(trace))
            return subprocess.run([sys.executable, str(SCRIPT), directory],
                                  cwd=ROOT, capture_output=True, text=True)

    def fixture(self, name="squeeze_loop_baseline"):
        return json.loads((ROOT / "replay" / "traces" / f"{name}.json").read_text())

    def assert_rejected(self, trace):
        result = self.run_trace(trace)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("BASELINE VERIFICATION FAILED", result.stderr)
        self.assertNotIn("| Variant |", result.stdout)

    def test_valid_trace_and_optional_none_omissions(self):
        trace = self.fixture()
        trace["cue_decisions"] = [d for d in trace["cue_decisions"]
                                  if d["type"] == "HEAD_UP"]
        result = self.run_trace(trace)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("baseline verified against all recorded decisions", result.stdout)

    def test_same_count_corruption_is_rejected(self):
        for field, value in (("event_id", 999999), ("reason_code", 7),
                             ("lead_time_s", 99), ("t_ms", 3000)):
            with self.subTest(field=field):
                trace = self.fixture()
                cue = next(d for d in trace["cue_decisions"] if d["type"] == "HEAD_UP")
                cue[field] = value
                trace["cue_decisions"].sort(key=lambda d: d["t_ms"])
                self.assert_rejected(trace)

    def test_recorded_none_and_type_corruption_are_rejected(self):
        trace = self.fixture()
        trace["cue_decisions"][0]["reason_code"] = 99
        self.assert_rejected(trace)
        trace = self.fixture()
        next(d for d in trace["cue_decisions"] if d["type"] == "HEAD_UP")["type"] = "NONE"
        self.assert_rejected(trace)

    def test_unrecorded_head_up_is_rejected(self):
        trace = self.fixture()
        trace["cue_decisions"] = [d for d in trace["cue_decisions"]
                                  if d["type"] != "HEAD_UP"]
        self.assert_rejected(trace)

    def test_equal_counts_with_shifted_cue_have_two_changed_timestamps(self):
        before = [{"t_ms": 1, "type": "HEAD_UP", "event_id": 7,
                   "reason_code": 0, "lead_time_s": 10},
                  {"t_ms": 2, "type": "NONE", "event_id": 7,
                   "reason_code": 8, "lead_time_s": 9}]
        after = copy.deepcopy(before)
        after[0]["type"], after[1]["type"] = "NONE", "HEAD_UP"
        wrap = lambda ds: {"decision_streams": {"ride": ds}}
        self.assertEqual(ablate.decision_deltas(wrap(before), wrap(after)), (2, 2))


if __name__ == "__main__":
    unittest.main()
