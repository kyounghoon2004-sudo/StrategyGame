"""A1 gates — first supervised state-aggregation round (dagger1, NOT RL).

Artifact-backed: heavy protocols write artifacts/jev_dagger_v0/*; these
tests verify leakage-freedom, counts, pins, and scope.
"""

from __future__ import annotations

import hashlib
import json
import pathlib

import torch

ROOT = pathlib.Path(__file__).resolve().parents[2]
A1 = ROOT / "artifacts" / "jev_dagger_v0"
V02 = ROOT / "artifacts" / "jev_training_v1" / "dataset"

V02_FILE_SHA256 = {
    "generalization_test": "e39ab61913a9df1f77794db8b8e515fe9a7a01e8e733c8030b42e990ff12fa2e",
    "test": "638687fc43a3a821bc90b48d4c0e716474d862d0ce4977b06c6bb7f87e352855",
    "train": "0cd7dd91c870e9b0051b7d3bccbc73fb1795fb3201ea3022305d867f25428543",
    "validation": "56c28b160cd772096b3b98fdfb84b3e886cd68b89a687691e469b74e33199e0d",
}


def _load_json(path: pathlib.Path) -> dict:
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def _file_sha(p: pathlib.Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


# ------------------------------------------------------------- A1-1 / A1-2
def test_a1_1_only_train_scenarios_aggregated() -> None:
    from python_jev.aggregate.gather import split_scenario_ids
    from python_jev.diagnose.collect import load_set

    train_ids = split_scenario_ids()["train"]
    assert len(train_ids) == 144
    prov = load_set(str(A1 / "collected_train_states" / "dagger1_unique.pt"),
                    verify=True)["provenance"]
    dag_ids = {p["scenario_id"] for p in prov}
    assert dag_ids <= train_ids
    assert len(dag_ids) == 144
    assert {p["split"] for p in prov} == {"train"}


def test_a1_2_val_test_never_enter_training() -> None:
    from python_jev.aggregate.dataset_v03 import load_shard_v03
    from python_jev.aggregate.gather import split_scenario_ids

    ref = split_scenario_ids()
    forbidden = ref["validation"] | ref["test"] | ref["generalization_test"]
    prov = load_shard_v03(str(A1 / "dataset_v03" / "train.pt"),
                          verify=True)["provenance"]
    train_ids = {p["scenario_id"] for p in prov}
    assert train_ids & forbidden == set()
    assert train_ids <= ref["train"]


# ------------------------------------------------------------------ A1-3
def test_a1_3_unique_count_in_range() -> None:
    manifest = _load_json(A1 / "collected_train_states" / "manifest.json")
    assert 4000 <= manifest["dedup"]["unique"] <= 8000
    assert manifest["dedup"]["unique"] + manifest["dedup"]["duplicates_removed"] == \
        manifest["dedup"]["raw"]


# ------------------------------------------------------------------ A1-4
def test_a1_4_deduplication_works() -> None:
    from python_jev.aggregate.gather import dedup_key
    from python_jev.diagnose.collect import load_set

    payload = load_set(str(A1 / "collected_train_states" / "dagger1_unique.pt"),
                       verify=True)
    manifest = _load_json(A1 / "collected_train_states" / "manifest.json")
    dedup_map = _load_json(A1 / "collected_train_states" / "dedup_map.json")
    assert len(dedup_map) == len(payload["provenance"]) == manifest["dedup"]["unique"]
    total = 0
    for i, p in enumerate(payload["provenance"]):
        row = {"obs_hash": p["obs_hash"], "actor_class": p["actor_class"],
               "mission": p["mission"],
               "legal": [bool(x) for x in
                         payload["tensors"]["legal"][i].tolist()]}
        key = "|".join(str(x) for x in dedup_key(row))
        assert dedup_map[key] == p["visit_count"]
        total += p["visit_count"]
    assert total == manifest["dedup"]["raw"]


# ------------------------------------------------------------------ A1-5
def test_a1_5_frozen_teacher_pipeline() -> None:
    from python_jev.aggregate.dataset_v03 import load_shard_v03
    from python_jev.training.policy_target import validate_targets

    payload = load_shard_v03(str(A1 / "dataset_v03" / "train.pt"), verify=True)
    cv = payload["contract_versions"]
    assert cv["legal_mask_version"] == "observation-safe-skill-mask-v0.2.0"
    assert cv["skill_preflight_version"] == "skill-preflight-v0.1.0"
    assert cv["value_target_version"] == "value-target-v0.1.0"
    assert cv["policy_target_version"] == "policy-target-v0.1.0"
    t, prov = payload["tensors"], payload["provenance"]
    n_dag = 0
    for i, p in enumerate(prov):
        if p["source"] != "JEV_VISITED_DAGGER1":
            continue
        n_dag += 1
        assert p["continuation_policy"] == "SimpleAttackElseAdvancePolicy"
        assert p["horizon_decisions"] == 8
        legal = [bool(x) for x in t["legal"][i].tolist()]
        qv = [bool(x) for x in t["q_valid"][i].tolist()]
        assert qv == legal and any(legal)
        q = [(float(v) if m else None)
             for v, m in zip(t["q"][i].tolist(), qv)]
        assert validate_targets([float(x) for x in t["p_target"][i].tolist()], qv) == []
        assert all((v is None) == (not ok) for v, ok in zip(q, qv))
    assert n_dag == _load_json(A1 / "dataset_v03" / "manifest.json")["dagger_train"]


# ------------------------------------------------------------------ A1-6
def test_a1_6_corrective_signal_verified() -> None:
    rep = _load_json(A1 / "metrics" / "recovery_signal.json")
    assert rep["passed"] is True
    assert rep["top_agreement"] < 0.90
    spot = rep["spotlight"]
    assert spot["SCOUT_RECON_ADVANCE"]["teacher"] - spot["SCOUT_RECON_ADVANCE"]["policy"] > 0.30
    assert spot["SCOUT_EVADE"]["policy"] - spot["SCOUT_EVADE"]["teacher"] > 0.30


# ------------------------------------------------------------------ A1-7
def test_a1_7_dataset_v02_immutable() -> None:
    from python_jev.retrain.dataset_v2 import load_shard_v2

    for split, pinned in V02_FILE_SHA256.items():
        p = V02 / f"{split}.pt"
        assert _file_sha(p) == pinned, split
        load_shard_v2(str(p), verify=True)


# ------------------------------------------------------------------ A1-8
def test_a1_8_v03_train_is_original_plus_dagger() -> None:
    from python_jev.aggregate.dataset_v03 import load_shard_v03
    from python_jev.retrain.dataset_v2 import load_shard_v2

    manifest = _load_json(A1 / "dataset_v03" / "manifest.json")
    new = load_shard_v03(str(A1 / "dataset_v03" / "train.pt"), verify=True)
    old = load_shard_v2(str(V02 / "train.pt"), verify=True)
    n0 = manifest["original_train"]
    assert n0 == 9194 == old["n_records"]
    assert new["n_records"] == n0 + manifest["dagger_train"]
    for k in ("actor", "tokens", "hex", "mission", "global", "q", "p_target",
              "token_pad", "legal", "q_valid", "class_idx"):
        assert torch.equal(new["tensors"][k][:n0], old["tensors"][k]), k
    for i, p in enumerate(new["provenance"][:n0]):
        assert p["scenario_id"] == old["provenance"][i]["scenario_id"]
        assert p["source"] == "JEV_FULLINFO_V02"
    for p in new["provenance"][n0:]:
        assert p["source"] == "JEV_VISITED_DAGGER1"


# ------------------------------------------------------------------ A1-9
def test_a1_9_val_test_byte_equivalent() -> None:
    for split in ("validation", "test", "generalization_test"):
        assert _file_sha(A1 / "dataset_v03" / f"{split}.pt") == _file_sha(V02 / f"{split}.pt")


# ----------------------------------------------------------------- A1-10
def test_a1_10_visited_validation_excluded_from_training() -> None:
    from python_jev.aggregate.dataset_v03 import load_shard_v03
    from python_jev.aggregate.gather import split_scenario_ids
    from python_jev.diagnose.collect import load_set

    vv = load_set(str(A1 / "visited_validation" / "visited_validation.pt"),
                  verify=True)
    assert 1000 <= vv["n_records"] <= 2000
    vv_ids = {p["scenario_id"] for p in vv["provenance"]}
    assert vv_ids <= split_scenario_ids()["validation"]
    train_ids = {p["scenario_id"] for p in
                 load_shard_v03(str(A1 / "dataset_v03" / "train.pt"),
                                verify=True)["provenance"]}
    assert vv_ids & train_ids == set()


# ----------------------------------------------------------------- A1-11
def test_a1_11_mixed_overfit_passes() -> None:
    rep = _load_json(A1 / "metrics" / "tiny_overfit.json")
    assert rep["passed"] is True
    assert rep["mix"] == "64 v0.2-train + 64 dagger1"
    assert rep["final_metrics"]["kl"] < 0.02


# ----------------------------------------------------------------- A1-12
def test_a1_12_three_seeds_from_scratch() -> None:
    history = _load_json(A1 / "metrics" / "training_history.json")
    assert history["model_version"] == "jev-policy-v0.3.0-fi-dagger1"
    assert history["init"] == "from_scratch"
    assert set(history["seeds"]) == {"42", "43", "44"}
    for seed in ("42", "43", "44"):
        ckpt = torch.load(A1 / "checkpoints" / f"seed{seed}.pt",
                          map_location="cpu", weights_only=False)
        assert ckpt["model_version"] == "jev-policy-v0.3.0-fi-dagger1"
        assert ckpt["init"] == "from_scratch"
        assert ckpt["full_information_only"] is True


# ----------------------------------------------------------------- A1-13
def test_a1_13_parameter_count_unchanged() -> None:
    new = torch.load(A1 / "checkpoints" / "seed43.pt",
                     map_location="cpu", weights_only=False)
    old = torch.load(ROOT / "artifacts" / "jev_training_v1" / "checkpoints" / "seed43.pt",
                     map_location="cpu", weights_only=False)
    assert set(new["state_dict"]) == set(old["state_dict"])
    assert sum(p.numel() for p in new["state_dict"].values()) == 1014430


# ----------------------------------------------------------------- A1-14
def test_a1_14_selected_by_validation_only() -> None:
    history = _load_json(A1 / "metrics" / "training_history.json")
    best = min(history["seeds"], key=lambda s: history["seeds"][s]["best_val_loss"])
    assert history["selected_seed"] == int(best)
    assert history["selection_rule"] == "lowest validation soft-target cross entropy"


# ----------------------------------------------------------------- A1-15
def test_a1_15_original_test_metrics() -> None:
    from python_jev.retrain.dataset_v2 import load_shard_v2

    report = _load_json(A1 / "metrics" / "offline.json")
    assert set(report["models"]) >= {"old_v02", "new_seed42", "new_seed43",
                                     "new_seed44", "untrained"}
    actual = load_shard_v2(str(V02 / "test.pt"), verify=True)["shard_hash"]
    assert report["shard_hash"] == actual
    for name, m in report["models"].items():
        assert m["aggregate"]["samples"] == 1531, name


# ----------------------------------------------------------------- A1-16
def test_a1_16_visited_validation_metrics() -> None:
    rep = _load_json(A1 / "metrics" / "visited.json")
    vv = rep["visited_validation"]
    assert vv["n"] >= 1000
    for tag in ("old_v02", "new_v03"):
        for k in ("mean_regret", "p95_regret", "top1", "epsilon_at_0.01"):
            assert k in vv["models"][tag]


# ----------------------------------------------------------------- A1-17
def test_a1_17_trajectory_depth_comparison() -> None:
    rep = _load_json(A1 / "metrics" / "depth_compare.json")
    for name in ("frozen_jev_new_set", "visited_validation"):
        for tag in ("old_v02", "new_v03"):
            for b in ("0-4", "5-9", "10-19", "20-+"):
                assert rep[name][tag][b]["n"] > 0, (name, tag, b)
            assert rep[name][tag]["trend_late_minus_early"] is not None


# ----------------------------------------------------------------- A1-18
def test_a1_18_same_seat_benchmark() -> None:
    comp = _load_json(A1 / "closedloop" / "same_seat_comparison.json")
    assert comp["benchmark_version"] == "closed-loop-benchmark-v0.1.0"
    assert comp["jobs"] == 24
    assert comp["matched_proof"]["baseline_conditions_identical"] is True
    assert set(comp["blue_vs_simple_red"]) == {
        "NEW_JEV", "OLD_JEV", "SimpleAttackElseAdvancePolicy",
        "RandomLegalPolicy", "HoldPolicy"}
    text = (A1 / "closedloop" / "same_seat_comparison.json").read_text(encoding="utf-8")
    assert "jev_victory_rate" not in text
    assert "side_swapped_terminal=INVALID" in text


# ----------------------------------------------------------------- A1-19
def test_a1_19_contact_drift_metrics() -> None:
    drift = _load_json(A1 / "drift" / "drift.json")
    for tag in ("old_v02", "new_v03"):
        c = drift["contact"][tag]
        for k in ("mean_nearest_enemy", "local_enemy_count",
                  "attack_legal_rate", "attack_opportunity_rate",
                  "friendly_dispersion", "legal_count",
                  "scout_evade_freq", "scout_recon_freq"):
            assert k in c, (tag, k)


# ----------------------------------------------------------------- A1-20
def test_a1_20_distribution_shift_compared() -> None:
    drift = _load_json(A1 / "drift" / "drift.json")
    assert set(drift["shift"]) >= {"iid_test_vs_new_visited", "new_visited_vs_old_visited"}
    assert set(drift["latent"]["sets"]) >= {"iid_test", "old_visited", "new_visited"}


# ----------------------------------------------------------------- A1-21
def test_a1_21_tactical_exam_rerun() -> None:
    exam = _load_json(A1 / "exam" / "exam.json")
    assert set(exam["models"]) == {"untrained", "old_v02", "new_v03"}
    for name, m in exam["models"].items():
        assert m["summary"]["overall"]["cases"] == 60, name


# ----------------------------------------------------------------- A1-22
def test_a1_22_oracle_gap_comparison() -> None:
    gap = _load_json(A1 / "metrics" / "oracle_gap.json")
    for k in ("oracle_exchange", "old_v02_exchange", "new_v03_exchange"):
        assert isinstance(gap[k], float), k
    assert gap["gap_closed_fraction"] is None or isinstance(gap["gap_closed_fraction"], float)


# ----------------------------------------------------------------- A1-23
def test_a1_23_invalid_is_zero() -> None:
    inv = _load_json(A1 / "metrics" / "offline_invalid.json")
    assert inv["new_selected"]["invalid_rate"] == 0.0
    comp = _load_json(A1 / "closedloop" / "same_seat_comparison.json")
    assert comp["blue_vs_simple_red"]["NEW_JEV"]["blue_invalid_rate"] == 0.0
    from python_jev.diagnose.collect import load_set

    prov = load_set(str(A1 / "collected_train_states" / "dagger1_unique.pt"),
                    verify=True)["provenance"]
    assert all(p["trial_exec_status"] != "INVALID" for p in prov)


# ----------------------------------------------------------------- A1-24
def test_a1_24_prior_chain_intact() -> None:
    assert (ROOT / "artifacts" / "jev_training_v1" / "dataset" / "manifest.json").exists()
    assert (ROOT / "artifacts" / "jev_target_diagnostic_v0" / "metrics"
            / "classification.json").exists()
    assert (ROOT / "docs" / "JEV" / "TARGET_DIAGNOSTIC_V0_HANDOFF.md").exists()


# ----------------------------------------------------------------- A1-25
def test_a1_25_no_fog_training() -> None:
    from python_jev.aggregate.dataset_v03 import load_shard_v03
    from python_jev.dataset.schema import FULL_INFO_PROFILES
    from python_jev.diagnose.collect import load_set

    prov = load_shard_v03(str(A1 / "dataset_v03" / "train.pt"),
                          verify=True)["provenance"]
    assert {p["profile"] for p in prov} <= set(FULL_INFO_PROFILES)
    dprov = load_set(str(A1 / "collected_train_states" / "dagger1_unique.pt"),
                     verify=True)["provenance"]
    assert {p["profile"] for p in dprov} <= set(FULL_INFO_PROFILES)


# ----------------------------------------------------------------- A1-26
def test_a1_26_no_rl_or_selfplay() -> None:
    for p in (ROOT / "python_jev" / "aggregate").rglob("*.py"):
        src = p.read_text(encoding="utf-8")
        for banned in ("selfplay", "self_play", "policy_gradient", "PPO(",
                       "DQN(", "REINFORCE", "backward(", "torch.optim",
                       "Optimizer", ".step()", "zero_grad"):
            assert banned not in src, f"{p.name} mentions {banned}"


# ----------------------------------------------------------------- A1-27
def test_a1_27_no_godot_gameplay_rewrite() -> None:
    hits = []
    for pat in ("scripts/**/*.gd", "scenes/**/*.tscn"):
        for p in ROOT.glob(pat):
            try:
                src = p.read_text(encoding="utf-8")
            except (UnicodeDecodeError, OSError):
                continue
            for token in ("jev_dagger_v0", "dataset-v0.3", "dagger",
                          "state-aggregation"):
                if token in src:
                    hits.append((str(p), token))
    assert hits == []
