"""D0 gates — target-quality / distribution diagnostic (read-only).

Artifact-backed: the heavy protocols write artifacts/jev_target_diagnostic_v0/*;
these tests verify completeness, pins, and scope (no training, no Fog, no RL).
"""

from __future__ import annotations

import hashlib
import json
import pathlib

import torch

ROOT = pathlib.Path(__file__).resolve().parents[2]
D0 = ROOT / "artifacts" / "jev_target_diagnostic_v0"
SETS = ("simple", "random", "hold", "jev_old", "jev_new", "iid_test")

NEW_SEED43_SHA256 = "df97ca8e41e58cdf467420e5cbf23da7bb6fa139cb9763e28b42e1f7e80b0584"
OLD_SEED43_SHA256 = "02d46c8a3ad56e893b5fd88d1ed5509d3f95b0e70f5d715c86ecae595d9ca2b2"


def _load_json(path: pathlib.Path) -> dict:
    with open(path, encoding="utf-8") as f:
        return json.load(f)


# ------------------------------------------------------------------ D0-1
def test_d0_1_six_distributions_collected_and_pinned() -> None:
    from python_jev.diagnose.collect import load_set

    manifest = _load_json(D0 / "distributions" / "manifest.json")
    for s in SETS:
        payload = load_set(str(D0 / "distributions" / f"{s}.pt"), verify=True)
        assert payload["set"] == s
        assert payload["n_records"] >= 1000, s
        assert payload["source_policy"]
        assert payload["teachers"] == ["SimpleAttackElseAdvancePolicy",
                                       "RandomLegalPolicy", "HoldPolicy"]
        assert manifest["sets"][s]["set_hash"] == payload["set_hash"]
        for p in payload["provenance"][:25]:
            for k in ("scenario_seed", "turn", "actor_id", "actor_class",
                      "state_hash", "obs_hash", "set", "trajectory_step"):
                assert p[k] not in (None, ""), (s, k)
            assert p["set"] == s
            assert len(p["state_hash"]) == 64 and len(p["obs_hash"]) == 64
    assert manifest["iid_test_verification"]["exact_order_match"] is True


# ------------------------------------------------------------------ D0-2
def test_d0_2_no_training_performed() -> None:
    new = ROOT / "artifacts" / "jev_training_v1" / "checkpoints" / "seed43.pt"
    old = ROOT / "artifacts" / "jev_training_v0" / "checkpoints" / "seed43.pt"
    assert hashlib.sha256(new.read_bytes()).hexdigest() == NEW_SEED43_SHA256
    assert hashlib.sha256(old.read_bytes()).hexdigest() == OLD_SEED43_SHA256
    banned = ("backward(", "torch.optim", "Optimizer", ".step()", "zero_grad",
              "CrossEntropyLoss", "MSELoss", "lr_scheduler", "save_checkpoint",
              "load_state_dict")
    files = list((ROOT / "python_jev" / "diagnose").rglob("*.py"))
    assert len(files) >= 5
    for p in files:
        src = p.read_text(encoding="utf-8")
        for b in banned:
            assert b not in src, f"{p.name} mentions {b!r}"


# -------------------------------------------------------------- D0-3/D0-4
def test_d0_3_new_jev_evaluated_on_all_distributions() -> None:
    cross = _load_json(D0 / "metrics" / "cross_dist.json")
    assert cross["q_teacher"] == "SimpleAttackElseAdvancePolicy"
    assert set(cross["sets"]) == set(SETS)
    for s in SETS:
        for tag in ("old", "new"):
            m = cross["sets"][s][tag]
            for k in ("regret", "top1", "epsilon_at_0.01", "entropy"):
                assert k in m, (s, tag, k)


def test_d0_4_old_vs_new_comparison_produced() -> None:
    cross = _load_json(D0 / "metrics" / "cross_dist.json")
    for s in ("iid_test", "jev_old", "jev_new", "simple"):
        assert cross["sets"][s]["old"]["regret"]["n"] > 1000
        assert cross["sets"][s]["new"]["regret"]["n"] > 1000


# ------------------------------------------------------------------ D0-5
def test_d0_5_three_teacher_q_on_identical_states() -> None:
    from python_jev.diagnose.collect import load_set

    for s in SETS:
        t = load_set(str(D0 / "distributions" / f"{s}.pt"), verify=True)["tensors"]
        n = t["actor"].shape[0]
        assert t["teacher_q"].shape == (n, 3, 6), s
        legal = t["legal"].bool()
        for teacher in range(3):
            q = t["teacher_q"][:, teacher, :]
            assert bool(torch.isfinite(q[legal]).all()), (s, teacher)
            assert bool(torch.isnan(q[~legal]).all()), (s, teacher)


# ------------------------------------------------------------------ D0-6
def test_d0_6_cross_teacher_regret_calculated() -> None:
    xr = _load_json(D0 / "teacher_matrix" / "cross_regret.json")
    assert len(xr["pooled"]) == 6
    for s in SETS:
        assert len(xr["per_set"][s]) == 6
    assert "ARCHER" in xr["per_class"]


# ------------------------------------------------------------------ D0-7
def test_d0_7_jev_regret_under_all_teachers() -> None:
    rb = _load_json(D0 / "teacher_matrix" / "robustness.json")
    assert set(rb) == set(SETS)
    for s in SETS:
        assert set(rb[s]["per_teacher"]) == {"SimpleAttackElseAdvancePolicy",
                                             "RandomLegalPolicy", "HoldPolicy"}
        assert "worst_teacher" in rb[s] and "mean_of_teachers" in rb[s]


# -------------------------------------------------------------- D0-8/D0-9
def test_d0_8_candidate_targets_constructed() -> None:
    cd = _load_json(D0 / "candidate_targets" / "candidates.json")
    assert set(cd) == set(SETS)
    for s in SETS:
        assert set(cd[s]["entropy"]) == {"A", "B", "C"}
        assert 0.0 <= cd[s]["top_change_A_to_B"] <= 1.0
        assert 0.0 <= cd[s]["top_change_A_to_C"] <= 1.0


def test_d0_9_teacher_disagreement_measured() -> None:
    cd = _load_json(D0 / "candidate_targets" / "candidates.json")
    mx = _load_json(D0 / "teacher_matrix" / "matrix.json")
    for s in SETS:
        assert cd[s]["jsd"]["n"] > 1000
        assert sum(cd[s]["teacher_agreement"].values()) == cd[s]["n"]
        assert set(cd[s]["teacher_agreement"]) == {"3/3", "2/3", "1/3"}
    assert len(mx["pooled"]) == 3
    assert set(mx["by_class"]) >= {"ARCHER", "CAVALRY", "SCOUT"}


# ----------------------------------------------------------------- D0-10
def test_d0_10_interpretable_shift_statistics() -> None:
    ft = _load_json(D0 / "covariate_shift" / "features.json")
    assert set(ft["per_set"]) == set(SETS)
    for s in SETS:
        assert len(ft["per_set"][s]["numeric"]) == 27
        assert set(ft["per_set"][s]["categorical"]) >= {"actor_class", "mission"}
    for pair in ("iid_test_vs_jev_new", "simple_vs_jev_new"):
        rows = ft["comparisons"][pair]
        assert len(rows) == 27
        assert all("cohens_d" in r for r in rows)


# ----------------------------------------------------------------- D0-11
def test_d0_11_latent_diagnostic_produced() -> None:
    lt = _load_json(D0 / "covariate_shift" / "latent.json")
    assert "forward hook" in lt["method"]
    assert lt["train_reference"]["n"] == 1000
    assert set(lt["sets"]) == set(SETS)
    for s in SETS:
        assert lt["sets"][s]["mean"] > 0


# ----------------------------------------------------------------- D0-12
def test_d0_12_trajectory_depth_regret() -> None:
    dep = _load_json(D0 / "trajectory_depth" / "depth.json")
    assert set(dep) == set(SETS)
    for s in SETS:
        for b in ("0-4", "5-9", "10-19", "20-+"):
            assert dep[s][b]["n"] > 0, (s, b)
        assert dep[s]["trend_late_minus_early"] is not None


# ------------------------------------------------------------- D0-13/14
def test_d0_13_counterfactual_greedy_simple_run() -> None:
    from python_jev.diagnose.oracles import oracle_subset_jobs
    from python_jev.training.scenarios import generate_scenario

    rep = _load_json(D0 / "oracle_closedloop" / "report.json")
    want = [generate_scenario(i, ood=o)["scenario"]["scenario_id"]
            for _p, i, _pr, o in oracle_subset_jobs()]
    assert rep["subset_scenario_ids"] == want
    assert len(want) == 6
    o = rep["oracles"]["CounterfactualGreedySimple"]
    assert len(o["battles"]) == 6
    assert o["summary"]["blue_invalid_count"] == 0


def test_d0_14_robust_two_teacher_run() -> None:
    rep = _load_json(D0 / "oracle_closedloop" / "report.json")
    o = rep["oracles"]["CounterfactualGreedy2Teacher"]
    assert len(o["battles"]) == 6
    assert o["summary"]["blue_invalid_count"] == 0
    assert set(rep["reference"]) >= {"NEW_JEV", "Simple"}
    for name in ("NEW_JEV", "Simple"):
        assert rep["reference"][name]["scenario_ids"] == rep["subset_scenario_ids"]


# ----------------------------------------------------------------- D0-15
def test_d0_15_no_mechanical_invalid() -> None:
    from python_jev.diagnose.collect import load_set

    for s in SETS:
        prov = load_set(str(D0 / "distributions" / f"{s}.pt"),
                        verify=True)["provenance"]
        bad = [p for p in prov if p["trial_exec_status"] == "INVALID"]
        assert bad == [], s


# ----------------------------------------------------------------- D0-16
def test_d0_16_prior_artifacts_intact() -> None:
    from python_jev.retrain.dataset_v2 import load_shard_v2
    from python_jev.training.dataset_gen import load_shard

    for s in ("train", "validation", "test", "generalization_test"):
        load_shard(str(ROOT / "artifacts" / "jev_training_v0" / "dataset" / f"{s}.pt"),
                   verify=True)
        load_shard_v2(str(ROOT / "artifacts" / "jev_training_v1" / "dataset" / f"{s}.pt"),
                      verify=True)
    seed43 = ROOT / "artifacts" / "jev_training_v0" / "checkpoints" / "seed43.pt"
    assert hashlib.sha256(seed43.read_bytes()).hexdigest() == OLD_SEED43_SHA256


# ------------------------------------------------------------- D0-17/18
def test_d0_17_no_fog_labels() -> None:
    from python_jev.dataset.schema import FULL_INFO_PROFILES
    from python_jev.diagnose.collect import load_set

    for s in SETS:
        payload = load_set(str(D0 / "distributions" / f"{s}.pt"), verify=True)
        assert payload["config"]["full_information_only"] is True
        profiles = {p["profile"] for p in payload["provenance"]}
        assert profiles <= set(FULL_INFO_PROFILES), (s, profiles)


def test_d0_18_no_rl_or_selfplay() -> None:
    for p in (ROOT / "python_jev" / "diagnose").rglob("*.py"):
        src = p.read_text(encoding="utf-8")
        for banned in ("selfplay", "self_play", "policy_gradient", "PPO(",
                       "DQN(", "REINFORCE"):
            assert banned not in src, f"{p.name} mentions {banned}"


# ------------------------------------------------------------- D0-19/20
def test_d0_19_cause_classification_emitted() -> None:
    cls = _load_json(D0 / "metrics" / "classification.json")
    assert cls["root_cause"] in ("TARGET_BIAS", "COVARIATE_SHIFT", "BOTH", "OTHER")
    criteria = _load_json(D0 / "metrics" / "criteria.json")
    assert cls["evidence"]["criteria"] == criteria


def test_d0_20_exactly_one_next_strategy() -> None:
    cls = _load_json(D0 / "metrics" / "classification.json")
    assert isinstance(cls["next"], str) and len(cls["next"]) > 20
    assert "next_steps" not in cls and "recommendations" not in cls
