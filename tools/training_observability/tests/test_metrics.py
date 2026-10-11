import json
import shutil
import unittest
from pathlib import Path

from tools.training_observability.marathon_scan import discover_iterations
from tools.training_observability.metrics import reconstruct_lineage, run_metrics
from tools.training_observability.safe_io import ReadOnlySource
from tools.training_observability.tests._fixtures import fresh_workspace

NOW = "2026-01-01T00:00:00Z"


def _read_outputs(paths):
    d = paths.metrics_dir
    return {n: (d / n).read_bytes() for n in ("TRAINING_METRICS.json", "iterations.csv", "SUMMARY.md")}


class MetricsTests(unittest.TestCase):
    def setUp(self):
        self.base, self.paths = fresh_workspace()

    # (1) rerun produces the same result: cached rerun + from-scratch rerun
    def test_rerun_identical(self):
        run_metrics(self.paths, now=NOW)
        first = _read_outputs(self.paths)
        doc2 = run_metrics(self.paths, now=NOW)
        self.assertEqual(doc2["scan"]["rows_built"], 0, "second run must reuse cache")
        self.assertEqual(first, _read_outputs(self.paths))
        shutil.rmtree(self.paths.metrics_dir)
        run_metrics(self.paths, now=NOW)
        self.assertEqual(first, _read_outputs(self.paths))

    # (6) informative/attempted ratio
    def test_informative_ratio(self):
        doc = run_metrics(self.paths, now=NOW)
        rows = {r["iteration"]: r for r in doc["iterations"]}
        for n, r in rows.items():
            man = json.loads((self.paths.marathon_root / "iterations" / f"iteration_{n:06d}" /
                              "rollout" / "rollout_manifest.json").read_text(encoding="utf-8"))
            inf = sum(1 for g in man["groups_attempted"] if g["informative"])
            self.assertEqual(r["groups_attempted"], len(man["groups_attempted"]))
            self.assertEqual(r["groups_informative"], inf)
            self.assertAlmostEqual(r["informative_ratio"], inf / len(man["groups_attempted"]), places=6)
        self.assertEqual(rows[1]["informative_ratio"], 0.5)          # 2 of 4 (iteration 1)
        self.assertEqual(rows[8]["decision"], "SKIPPED_NO_SIGNAL")
        self.assertEqual((rows[8]["groups_attempted"], rows[8]["groups_informative"]), (8, 1))
        a = doc["aggregates"]
        att = sum(r["groups_attempted"] for r in rows.values())
        inf = sum(r["groups_informative"] for r in rows.values())
        self.assertAlmostEqual(a["informative_ratio_cumulative"], inf / att, places=6)

    def test_missing_values_not_invented(self):
        doc = run_metrics(self.paths, now=NOW)
        r8 = next(r for r in doc["iterations"] if r["iteration"] == 8)
        self.assertIsNone(r8["optimizer_steps"])
        self.assertEqual(r8["missing"]["optimizer_steps"], "NOT_RUN")
        self.assertIsNone(r8["eval_wins"])
        self.assertIsNone(r8["iteration_duration_s"])
        csv = (self.paths.metrics_dir / "iterations.csv").read_text(encoding="utf-8").splitlines()
        row8 = next(l for l in csv if l.startswith("8,"))
        self.assertIn("NOT_RUN", row8)

    # (5) lineage reconstruction
    def test_lineage_reconstruction(self):
        doc = run_metrics(self.paths, now=NOW)
        lin = doc["lineage"]
        self.assertEqual(lin["chain"], ["B0", "T0004", "T0018"])
        self.assertEqual([p["iteration"] for p in lin["promotions"]], [4, 18])
        self.assertEqual(lin["promotions"][1]["replaced"], "T0004")
        r8 = next(r for r in doc["iterations"] if r["iteration"] == 8)
        self.assertEqual(r8["champion_before"], "T0004")
        self.assertEqual(r8["champion_before_source"], "DERIVED_PREVIOUS_ITERATION_CHAMPION_AFTER")
        # the copied REAL lineage file is ahead of this 6-iteration subset -> reported, never repaired
        self.assertTrue(any("CHAMPION_LINEAGE.json champion" in d for d in lin["discrepancies"]))

    def test_lineage_consistent_file_has_no_discrepancy(self):
        rows = [{"iteration": 1, "decision": "PROMOTE", "candidate": "T0001",
                 "champion_before": "B0", "champion_after": "T0001"},
                {"iteration": 2, "decision": "REJECT", "candidate": "T0002",
                 "champion_before": "T0001", "champion_after": "T0001"},
                {"iteration": 3, "decision": "SKIPPED_NO_SIGNAL", "candidate": "T0003",
                 "champion_before": None, "champion_after": "T0001"},
                {"iteration": 4, "decision": "PROMOTE", "candidate": "T0004",
                 "champion_before": "T0001", "champion_after": "T0004"}]
        lf = {"records": [{"checkpoint_id": "B0", "status": "HISTORICAL", "parent_champion_id": None},
                          {"checkpoint_id": "T0001", "status": "HISTORICAL", "parent_champion_id": "B0"},
                          {"checkpoint_id": "T0002", "status": "REJECTED", "parent_champion_id": "T0001"},
                          {"checkpoint_id": "T0004", "status": "CHAMPION", "parent_champion_id": "T0001"}]}
        out = reconstruct_lineage(rows, lf, {"champion_id": "T0004"})
        self.assertEqual(out["chain"], ["B0", "T0001", "T0004"])
        self.assertEqual(out["discrepancies"], [])
        lf["records"][3]["parent_champion_id"] = "B0"
        out = reconstruct_lineage([dict(r) for r in rows], lf, {"champion_id": "T0004"})
        self.assertTrue(any("parent of T0004" in d for d in out["discrepancies"]))

    # (3) incomplete / live iteration does not crash the scanner
    def test_incomplete_iterations_skipped(self):
        it = self.paths.marathon_root / "iterations"
        live = it / "iteration_000019"
        (live / "rollout").mkdir(parents=True)
        (live / "train").mkdir()
        (live / "rollout" / "group1.json").write_text('{"group_index": 1, "seeds": [49', encoding="utf-8")
        trunc = it / "iteration_000020"
        (trunc / "rollout").mkdir(parents=True)
        (trunc / "ITERATION_RESULT.json").write_text('{"iteration": 20, "decis', encoding="utf-8")
        wrong = it / "iteration_000021"
        wrong.mkdir()
        (wrong / "ITERATION_RESULT.json").write_text('{"iteration": 99, "decision": "REJECT"}', encoding="utf-8")
        (it / "iteration_tmp_garbage").mkdir()
        src = ReadOnlySource(retry_delay_s=0.01)
        refs = {r.number: r for r in discover_iterations(src, self.paths.marathon_root)}
        self.assertFalse(refs[19].complete)
        self.assertIn("NO_ITERATION_RESULT", refs[19].reason)
        self.assertIn("UNREADABLE", refs[20].reason)
        self.assertIn("STRUCTURALLY_INVALID", refs[21].reason)
        # nothing inside the in-progress iteration was opened
        self.assertFalse(any("iteration_000019" in p for p in src.read_paths))
        doc = run_metrics(self.paths, src=src, now=NOW)
        self.assertEqual([x["iteration"] for x in doc["aggregates"]["iterations_incomplete"]], [19, 20, 21])
        self.assertEqual(doc["aggregates"]["iterations_complete"], 6)


if __name__ == "__main__":
    unittest.main()
