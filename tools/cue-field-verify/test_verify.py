"""Intent: Keep missing/inconsistent field evidence from passing verification.
Context: Sidecar counters are claims; decision fields and coverage are evidence.
Pattern: Targeted counter corruption and an empty-directory end-to-end check.
Future: Add compatibility fixtures when the sidecar schema changes.
"""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("verify.py")
spec = importlib.util.spec_from_file_location("field_verify", SCRIPT)
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


class EvidenceTests(unittest.TestCase):
    def sidecar(self):
        step = {"seq": 1, "diverged": False}
        for key, value in {"type": 1, "event_id": 7, "reason_code": 0, "lead_time_s": 10}.items():
            step["shadow_" + key] = step["pico_" + key] = value
        return {"steps": [step, {"seq": 2}], "reported_count": 1,
                "divergence_count": 0, "orphan_report_count": 0}

    def test_pending_tail_is_explicitly_uncompared(self):
        result = verify.check_sidecar(self.sidecar())
        self.assertEqual((result["logged"], result["compared"], result["uncompared"]), (2, 1, 1))

    def test_corrupted_counters_and_hidden_divergence_rejected(self):
        original = self.sidecar()
        for mutation in ("reported_count", "divergence_count", "pico_event_id", "partial", "duplicate"):
            with self.subTest(mutation=mutation):
                data = copy.deepcopy(original)
                if mutation in ("reported_count", "divergence_count"):
                    data[mutation] += 1
                elif mutation == "partial":
                    del data["steps"][0]["pico_type"]
                elif mutation == "duplicate":
                    data["steps"][1]["seq"] = 1
                else:
                    data["steps"][0][mutation] = 8
                with self.assertRaises(ValueError):
                    verify.check_sidecar(data)

    def test_missing_corpus_never_produces_passing_status(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "evidence"
            proc = subprocess.run([sys.executable, str(SCRIPT), directory,
                                   "--corpus-kind", "field", "--output", str(output)],
                                  capture_output=True, text=True)
            self.assertEqual(proc.returncode, 1)
            result = json.loads((output / "verification.json").read_text())
            self.assertEqual(result["status"], "blocked_missing_corpus")
            self.assertNotIn("verified_traces", result)


if __name__ == "__main__":
    unittest.main()
