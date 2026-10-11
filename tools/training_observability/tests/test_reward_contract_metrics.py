"""Reward-contract (V1/V2) fields in the metrics aggregator: additive and
backward compatible with V1 rows (never invented)."""
from __future__ import annotations

import json
import shutil
import unittest

from tools.training_observability.metrics import CSV_FIELDS, run_metrics
from tools.training_observability.tests._fixtures import fresh_workspace, rmtree


def _v2_group(gi, comps):
    return {"group_index": gi, "seeds": [gi * 2, gi * 2 + 1],
            "rewards": [c["total_reward"] for c in comps],
            "terminal_rewards": [c["terminal_reward"] for c in comps],
            "reward_contract_version": "REWARD_CONTRACT_V2", "grpo_reward_field": "rewards",
            "reward_components": comps, "informative": True, "wall_s": 1.0}


def _c(term, cv, coh, strict=None):
    return {"terminal_reward": term, "contract_valid": cv, "plan_coherent": coh,
            "contract_bonus": 0.25 if cv else 0.0, "plan_coherence_bonus": 0.25 if coh else 0.0,
            "total_reward": term + (0.25 if cv else 0.0) + (0.25 if coh else 0.0),
            "strict_failure_type": strict}


class RewardContractMetricsTest(unittest.TestCase):
    def setUp(self):
        self.base, self.paths = fresh_workspace()
        its = self.paths.marathon_root / "iterations"
        src, dst = its / "iteration_000018", its / "iteration_000019"
        shutil.copytree(src, dst)
        res = json.loads((dst / "ITERATION_RESULT.json").read_text(encoding="utf-8"))
        res["iteration"] = 19
        res["candidate_id"] = "T0019"
        groups = [_v2_group(1, [_c(-3, False, False, "BRAIN_CONTRACT_FAILURE:VP_INVALID_JSON"),
                                _c(-2, True, False)]),
                  _v2_group(2, [_c(-2, True, True), _c(-2, False, False)])]
        man = {"status": "ROLLOUT_DONE", "groups_attempted": groups, "n_attempted": 2,
               "n_informative": 2, "reward_contract_version": "REWARD_CONTRACT_V2"}
        res["summaries"]["rollout_manifest.json"] = man
        (dst / "ITERATION_RESULT.json").write_text(json.dumps(res), encoding="utf-8")

    def tearDown(self):
        rmtree(self.base)

    def test_v1_and_v2_side_by_side(self):
        doc = run_metrics(self.paths, now="2026-09-25T00:00:00Z")
        rows = {r["iteration"]: r for r in doc["iterations"]}
        v1, v2 = rows[18], rows[19]
        self.assertEqual(v1["reward_contract_version"], "REWARD_CONTRACT_V1")
        self.assertIsNone(v1["rollout_contract_valid_n"])
        self.assertEqual(v1["missing"]["rollout_contract_valid_n"], "NOT_RECORDED_UNDER_V1")
        self.assertEqual(v1["rollout_terminal_reward_mean"], v1["rollout_reward_mean"])
        self.assertEqual(v2["reward_contract_version"], "REWARD_CONTRACT_V2")
        self.assertEqual((v2["rollout_n_win"], v2["rollout_n_loss"], v2["rollout_n_draw"]), (0, 1, 3))
        self.assertEqual(v2["rollout_terminal_reward_mean"], -2.25)
        self.assertEqual(v2["rollout_total_reward_mean"], -2.0625)
        self.assertEqual((v2["rollout_contract_valid_n"], v2["rollout_plan_coherent_n"],
                          v2["rollout_strict_failure_n"]), (2, 1, 1))
        by = doc["aggregates"]["by_reward_contract"]
        self.assertEqual(set(by), {"REWARD_CONTRACT_V1", "REWARD_CONTRACT_V2"})
        self.assertEqual(by["REWARD_CONTRACT_V2"]["iterations"], 1)
        self.assertEqual(by["REWARD_CONTRACT_V2"]["contract_valid"], {"n": 2, "of": 4, "rate": 0.5})
        self.assertEqual(by["REWARD_CONTRACT_V2"]["strict_failure"]["rate"], 0.25)
        self.assertIsNone(by["REWARD_CONTRACT_V1"]["contract_valid"])
        self.assertEqual(by["REWARD_CONTRACT_V2"]["informative_ratio"], 1.0)
        summary = (self.paths.output_root / "metrics" / "SUMMARY.md").read_text(encoding="utf-8")
        self.assertIn("REWARD_CONTRACT_V2", summary)
        header = (self.paths.output_root / "metrics" / "iterations.csv").read_text(
            encoding="utf-8").splitlines()[0].split(",")
        self.assertEqual(header, CSV_FIELDS)
        self.assertEqual(header[:35][-1], "resumed")  # original columns unchanged, new ones appended


if __name__ == "__main__":
    unittest.main()
