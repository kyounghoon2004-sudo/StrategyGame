import json
import shutil
import unittest

from tools.training_observability.dataset_builder import iter_dataset, run_dataset
from tools.training_observability.tests._fixtures import fresh_workspace

NOW = "2026-01-01T00:00:00Z"


def _shards(paths):
    return {p.name: p.read_bytes() for p in paths.dataset_dir.glob("trajectories-*.jsonl.gz")}


class DatasetTests(unittest.TestCase):
    def setUp(self):
        self.base, self.paths = fresh_workspace()

    def _expected_rollout_samples(self):
        n = 0
        for d in (self.paths.marathon_root / "iterations").iterdir():
            man = json.loads((d / "rollout" / "rollout_manifest.json").read_text(encoding="utf-8"))
            n += sum(len(g["seeds"]) for g in man["groups_attempted"])
        return n

    # (2) rerun creates no duplicates; append-only; deterministic
    def test_rerun_no_duplicates(self):
        m1 = run_dataset(self.paths, now=NOW)
        s1 = _shards(self.paths)
        self.assertGreater(m1["stats"]["n_records"], 0)
        self.assertEqual(m1["stats"]["n_duplicate_ids"], 0)
        m2 = run_dataset(self.paths, now=NOW)
        self.assertEqual(m2["last_build"]["records_added"], 0)
        self.assertEqual(m2["stats"]["n_records"], m1["stats"]["n_records"])
        self.assertEqual(_shards(self.paths), s1, "shards must not change on rerun")
        # force re-derivation of every unit (cache dropped): still no duplicates
        man = json.loads((self.paths.dataset_dir / "manifest.json").read_text(encoding="utf-8"))
        man["units"] = {}
        (self.paths.dataset_dir / "manifest.json").write_text(json.dumps(man), encoding="utf-8")
        m3 = run_dataset(self.paths, now=NOW)
        self.assertEqual(m3["last_build"]["records_added"], 0)
        self.assertEqual(m3["last_build"]["conflicts"], 0)
        ids = [r["record_id"] for r in iter_dataset(self.paths.dataset_dir)]
        self.assertEqual(len(ids), len(set(ids)))
        # full rebuild is byte-identical (deterministic ids/order/gzip)
        run_dataset(self.paths, rebuild=True, now=NOW)
        self.assertEqual(_shards(self.paths), s1)

    def test_incremental_append(self):
        it = self.paths.marathon_root / "iterations"
        held = self.base / "held_back"
        shutil.move(str(it / "iteration_000018"), str(held))
        m1 = run_dataset(self.paths, now=NOW)
        n1 = m1["stats"]["n_records"]
        shutil.move(str(held), str(it / "iteration_000018"))  # iteration completes later
        m2 = run_dataset(self.paths, now=NOW)
        self.assertGreater(m2["last_build"]["records_added"], 0)
        self.assertEqual(len(m2["shards"]), len(m1["shards"]) + 1)
        self.assertIn(18, m2["stats"]["marathon_iterations_indexed"])
        self.assertEqual(m2["stats"]["n_records"], n1 + m2["last_build"]["records_added"])

    def test_content_self_contained_and_complete(self):
        man = run_dataset(self.paths, now=NOW)
        recs = list(iter_dataset(self.paths.dataset_dir))
        ro = [r for r in recs if r["record_type"] == "rollout_sample" and r["source_run"] == "training_marathon_v1"]
        self.assertEqual(len(ro), self._expected_rollout_samples())
        prompts = [r for r in recs if r["record_type"] == "prompt"]
        self.assertEqual(len(prompts), 1)
        for r in ro:
            self.assertEqual(r["schema_version"], "trajectory_record_v1")
            self.assertEqual(r["record_status"], "COMPLETE", r["record_id"])
            self.assertTrue(r["output"]["completion_text"])
            self.assertTrue(r["output"]["text_sha16_verified"])
            self.assertEqual(r["episode_seed"], r["generation_seed"] + 1000)
            self.assertIn(r["reward"]["reward"], (5, -3, -2))
            self.assertEqual(r["prompt"]["prompt_record_id"], prompts[0]["record_id"])
            self.assertEqual(r["validity"]["strict_failure"], r["terminal"]["outcome"] == "LOSS")
        ev = [r for r in recs if r["record_type"] == "eval_match" and r["source_run"] == "training_marathon_v1"]
        self.assertEqual(len(ev), 4 * 5)  # 5 of 6 copied iterations ran eval (it 8 skipped)
        self.assertTrue(all(r["output"]["red_text"] and r["output"]["blue_text"] for r in ev))
        self.assertIn("manual_rl_loop_v1", man["stats"]["by_source_run"])
        self.assertIn("rl_pipeline_proof_v0", man["stats"]["by_source_run"])
        cov = {c["field"]: c["status"] for c in man["field_coverage"]["rollout_sample"]}
        self.assertEqual(cov["generated token ids"], "NOT_PERSISTED_BY_PRODUCER")
        self.assertEqual(cov["prompt text"], "PARTIAL")
        self.assertEqual(cov["reward"], "RECORDED")
        # records stay valid when the sources are deleted
        shutil.rmtree(self.base / "src")
        again = list(iter_dataset(self.paths.dataset_dir))
        self.assertEqual(len(again), len(recs))
        self.assertTrue(all(r["output"]["completion_text"] for r in again if r["record_type"] == "rollout_sample"
                            and r["record_status"] == "COMPLETE"))

    # (4) malformed input recorded safely, never silently dropped
    def test_malformed_sources_logged(self):
        rd = self.paths.marathon_root / "iterations" / "iteration_000001" / "rollout"
        (rd / "rollout_T0001g1s3101.json").write_text('{"battle_turns": 6, "candid', encoding="utf-8")
        (rd / "rollout_T0001g2s3103_in.json").unlink()
        (rd / "group3_s3105.txt").write_text("tampered", encoding="utf-8")
        (rd / "rollout_T0001g9s9999.json").write_text("{}", encoding="utf-8")
        ed = self.paths.marathon_root / "iterations" / "iteration_000001" / "eval"
        (ed / "eval_s9101_m1_in.json").write_text("not json", encoding="utf-8")
        man = run_dataset(self.paths, now=NOW)
        recs = {r["rollout_id"]: r for r in iter_dataset(self.paths.dataset_dir)
                if r["record_type"] == "rollout_sample" and r["iteration"] == 1}
        self.assertEqual(len(recs), 8, "every recorded sample must be present")
        bad = recs["T0001g1s3101"]
        self.assertEqual(bad["record_status"], "INCOMPLETE")
        self.assertIsNone(bad["episode_record"])
        self.assertEqual(bad["reward"]["reward"], -2)  # still known from the group summary
        self.assertEqual(recs["T0001g2s3103"]["record_status"], "INCOMPLETE")
        self.assertFalse(recs["T0001g3s3105"]["output"]["text_sha16_verified"])
        kinds = man["stats"]["issues_by_kind"]
        for k in ("MALFORMED_JSON", "MISSING_FILE", "TEXT_SHA_MISMATCH", "ORPHAN_SOURCE_FILE"):
            self.assertIn(k, kinds)
        ev1 = [r for r in iter_dataset(self.paths.dataset_dir)
               if r["record_type"] == "eval_match" and r["iteration"] == 1]
        self.assertEqual(len(ev1), 4)
        m1 = next(r for r in ev1 if r["match_id"] == "eval_s9101_m1")
        self.assertEqual(m1["record_status"], "INCOMPLETE")
        self.assertTrue(m1["output"]["red_text"], "falls back to the persisted .txt generation")
        report = (self.paths.dataset_dir / "DATASET_REPORT.md").read_text(encoding="utf-8")
        self.assertIn("MALFORMED_JSON", report)


if __name__ == "__main__":
    unittest.main()
