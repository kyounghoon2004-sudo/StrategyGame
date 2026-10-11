"""A2 gates — second supervised state-aggregation round (dagger2, NOT RL).

Mirrors the A1 gate structure for v0.4 / jev-policy-v0.4.0-fi-dagger2.
Frozen inputs (v0.2 bytes, v0.3 shards, A1 visited set, D0 sets) are
asserted intact, never rewritten.
"""

from __future__ import annotations

import hashlib
import json
import pathlib

import torch

ROOT = pathlib.Path(__file__).resolve().parents[2]
A2 = ROOT / "artifacts" / "jev_dagger_v1"
A1 = ROOT / "artifacts" / "jev_dagger_v0"
V02 = ROOT / "artifacts" / "jev_training_v1" / "dataset"
V03 = A1 / "dataset_v03"

V03_TRAIN_SHA256 = "50dbc7c02b1c22e95f4cbe2ae0f8299b6d030d7013c7a0a840189363e3bcea12"
V1_SEED43_SHA256 = "df97ca8e41e58cdf467420e5cbf23da7bb6fa139cb9763e28b42e1f7e80b0584"


def _load_json(path: pathlib.Path) -> dict:
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def _file_sha(p: pathlib.Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def test_a2_1_only_train_scenarios_aggregated() -> None:
    from python_jev.aggregate.gather import split_scenario_ids
    from python_jev.diagnose.collect import load_set

    train_ids = split_scenario_ids()["train"]
    prov = load_set(str(A2 / "collected_train_states" / "dagger2_unique.pt"),
                    verify=True)["provenance"]
    dag_ids = {p["scenario_id"] for p in prov}
    assert dag_ids <= train_ids and len(dag_ids) == 144
    assert {p["split"] for p in prov} == {"train"}


def test_a2_2_no_val_test_in_v04_train() -> None:
    from python_jev.aggregate.dataset_v04 import load_shard_v04
    from python_jev.aggregate.gather import split_scenario_ids

    ref = split_scenario_ids()
    forbidden = ref["validation"] | ref["test"] | ref["generalization_test"]
    prov = load_shard_v04(str(A2 / "dataset_v04" / "train.pt"),
                          verify=True)["provenance"]
    train_ids = {p["scenario_id"] for p in prov}
    assert train_ids & forbidden == set()
    assert train_ids <= ref["train"]


def test_a2_3_unique_count_in_range() -> None:
    manifest = _load_json(A2 / "collected_train_states" / "manifest.json")
    assert 4000 <= manifest["dedup"]["unique"] <= 8000
    assert manifest["dedup"]["unique"] + manifest["dedup"]["duplicates_removed"] == \
        manifest["dedup"]["raw"]
    assert manifest["class_distribution"]["SCOUT"] > 500


def test_a2_4_dedup_unchanged_key() -> None:
    from python_jev.aggregate.gather import dedup_key
    from python_jev.diagnose.collect import load_set

    payload = load_set(str(A2 / "collected_train_states" / "dagger2_unique.pt"),
                       verify=True)
    manifest = _load_json(A2 / "collected_train_states" / "manifest.json")
    dedup_map = _load_json(A2 / "collected_train_states" / "dedup_map.json")
    assert len(dedup_map) == len(payload["provenance"]) == manifest["dedup"]["unique"]
    total = 0
    for i, p in enumerate(payload["provenance"]):
        row = {"obs_hash": p["obs_hash"], "actor_class": p["actor_class"],
               "mission": p["mission"],
               "legal": [bool(x) for x in
                         payload["tensors"]["legal"][i].tolist()]}
        assert len(dedup_key(row)) == 4  # obs x class x mission x legal
        key = "|".join(str(x) for x in dedup_key(row))
        assert dedup_map[key] == p["visit_count"]
        total += p["visit_count"]
    assert total == manifest["dedup"]["raw"]


def test_a2_5_frozen_teacher_pipeline() -> None:
    from python_jev.aggregate.dataset_v04 import load_shard_v04
    from python_jev.training.policy_target import validate_targets

    payload = load_shard_v04(str(A2 / "dataset_v04" / "train.pt"), verify=True)
    cv = payload["contract_versions"]
    assert cv["legal_mask_version"] == "observation-safe-skill-mask-v0.2.0"
    assert cv["skill_preflight_version"] == "skill-preflight-v0.1.0"
    assert cv["value_target_version"] == "value-target-v0.1.0"
    assert cv["policy_target_version"] == "policy-target-v0.1.0"
    t, prov = payload["tensors"], payload["provenance"]
    n_dag2 = 0
    for i, p in enumerate(prov):
        if p["source"] != "JEV_VISITED_DAGGER2":
            continue
        n_dag2 += 1
        assert p["continuation_policy"] == "SimpleAttackElseAdvancePolicy"
        assert p["horizon_decisions"] == 8
        qv = [bool(x) for x in t["q_valid"][i].tolist()]
        assert qv == [bool(x) for x in t["legal"][i].tolist()]
        assert validate_targets([float(x) for x in t["p_target"][i].tolist()], qv) == []
    assert n_dag2 == _load_json(A2 / "dataset_v04" / "manifest.json")["dagger2_train"]


def test_a2_6_boundary_and_corrective_signal() -> None:
    rep = _load_json(A2 / "metrics" / "recovery_signal.json")
    assert rep["passed"] is True
    assert rep["top_agreement"] < 0.90
    b = rep["scout_boundary"]
    assert b["both_sides_covered"] is True
    assert b["teacher_evade"] >= 1 and b["teacher_recon"] >= 100
    assert b["policy_skill_counts"]["EVADE"] > b["teacher_skill_counts"]["EVADE"]
    assert len(b["feature_differences"]) == 27


def test_a2_7_v03_immutable() -> None:
    from python_jev.aggregate.dataset_v03 import load_shard_v03

    assert _file_sha(V03 / "train.pt") == V03_TRAIN_SHA256
    load_shard_v03(str(V03 / "train.pt"), verify=True)
    a1_success = _load_json(A1 / "metrics" / "success.json")
    assert a1_success["TRAINING_SUCCESS"] == "PASS"
    assert a1_success["POLICY_QUALITY_SUCCESS"] == "PASS"


def test_a2_8_v04_is_v03_plus_dagger2() -> None:
    from python_jev.aggregate.dataset_v03 import load_shard_v03
    from python_jev.aggregate.dataset_v04 import load_shard_v04

    manifest = _load_json(A2 / "dataset_v04" / "manifest.json")
    new = load_shard_v04(str(A2 / "dataset_v04" / "train.pt"), verify=True)
    old = load_shard_v03(str(V03 / "train.pt"), verify=True)
    n0 = manifest["carried_train"]
    assert n0 == 15242 == old["n_records"]
    assert new["n_records"] == n0 + manifest["dagger2_train"]
    for k in ("actor", "tokens", "hex", "mission", "global", "q", "p_target",
              "token_pad", "legal", "q_valid", "class_idx"):
        assert torch.equal(new["tensors"][k][:n0], old["tensors"][k]), k
    assert {p["source"] for p in new["provenance"][n0:]} == {"JEV_VISITED_DAGGER2"}


def test_a2_9_val_test_byte_identical() -> None:
    for split in ("validation", "test", "generalization_test"):
        assert _file_sha(A2 / "dataset_v04" / f"{split}.pt") == _file_sha(V02 / f"{split}.pt")


def test_a2_10_frozen_visited_set_reused() -> None:
    vv = _load_json(A2 / "metrics" / "visited.json")["visited_validation_frozen"]
    assert vv["n"] == 1536
    assert set(vv["models"]) == {"v02", "v03", "v04"}


def test_a2_11_mixed_overfit_passes() -> None:
    rep = _load_json(A2 / "metrics" / "tiny_overfit.json")
    assert rep["passed"] is True
    assert rep["mix"] == "43 v0.2 + 43 dagger1 + 42 dagger2"


def test_a2_12_three_seeds_from_scratch() -> None:
    history = _load_json(A2 / "metrics" / "training_history.json")
    assert history["model_version"] == "jev-policy-v0.4.0-fi-dagger2"
    assert history["init"] == "from_scratch"
    assert set(history["seeds"]) == {"42", "43", "44"}
    for seed in ("42", "43", "44"):
        ckpt = torch.load(A2 / "checkpoints" / f"seed{seed}.pt",
                          map_location="cpu", weights_only=False)
        assert ckpt["model_version"] == "jev-policy-v0.4.0-fi-dagger2"
        assert ckpt["init"] == "from_scratch"


def test_a2_13_parameter_count_unchanged() -> None:
    new = torch.load(A2 / "checkpoints" / "seed44.pt",
                     map_location="cpu", weights_only=False)
    old = torch.load(ROOT / "artifacts" / "jev_training_v1" / "checkpoints" / "seed43.pt",
                     map_location="cpu", weights_only=False)
    assert set(new["state_dict"]) == set(old["state_dict"])
    assert sum(p.numel() for p in new["state_dict"].values()) == 1014430


def test_a2_14_selected_by_validation_only() -> None:
    history = _load_json(A2 / "metrics" / "training_history.json")
    best = min(history["seeds"], key=lambda s: history["seeds"][s]["best_val_loss"])
    assert history["selected_seed"] == int(best)


def test_a2_15_original_test_metrics() -> None:
    from python_jev.retrain.dataset_v2 import load_shard_v2

    report = _load_json(A2 / "metrics" / "offline.json")
    assert set(report["models"]) >= {"v02", "v03", "v04_seed42", "v04_seed43",
                                     "v04_seed44", "untrained"}
    actual = load_shard_v2(str(V02 / "test.pt"), verify=True)["shard_hash"]
    assert report["shard_hash"] == actual


def test_a2_16_visited_metrics_three_models() -> None:
    rep = _load_json(A2 / "metrics" / "visited.json")["visited_validation_frozen"]
    for tag in ("v02", "v03", "v04"):
        for k in ("mean_regret", "p95_regret", "top1", "epsilon_at_0.01"):
            assert k in rep["models"][tag]


def test_a2_17_trajectory_depth_three_models() -> None:
    rep = _load_json(A2 / "metrics" / "depth_compare.json")
    for name in ("frozen_jev_new_set", "visited_validation_frozen"):
        for tag in ("v02", "v03", "v04"):
            for b in ("0-4", "5-9", "10-19", "20-+"):
                assert rep[name][tag][b]["n"] > 0


def test_a2_18_three_way_closedloop() -> None:
    three = _load_json(A2 / "closedloop" / "comparison_3way.json")
    assert set(three["blue_vs_simple_red"]) == {"v04", "v03", "v02", "Simple",
                                                "Random", "Hold"}
    assert three["jobs"] == 24
    text = (A2 / "closedloop" / "comparison_3way.json").read_text(encoding="utf-8")
    assert "jev_victory_rate" not in text
    assert "side_swapped_terminal=INVALID" in text


def test_a2_19_contact_drift_three_models() -> None:
    drift = _load_json(A2 / "drift" / "drift.json")
    for tag in ("v02", "v03", "v04"):
        c = drift["contact"][tag]
        for k in ("attack_opportunity_rate", "mean_nearest_enemy",
                  "local_enemy_count", "friendly_dispersion",
                  "scout_evade_freq", "scout_recon_freq"):
            assert k in c, (tag, k)


def test_a2_20_shift_three_models() -> None:
    drift = _load_json(A2 / "drift" / "drift.json")
    assert set(drift["latent"]["sets"]) >= {"v02_visited", "v03_visited",
                                            "v04_visited", "iid_test"}


def test_a2_21_tactical_exam_four_models() -> None:
    exam = _load_json(A2 / "exam" / "exam.json")
    assert set(exam["models"]) == {"untrained", "v02", "v03", "v04"}
    for name, m in exam["models"].items():
        assert m["summary"]["overall"]["cases"] == 60, name


def test_a2_22_oracle_gap_four_series() -> None:
    gap = _load_json(A2 / "metrics" / "oracle_gap.json")
    for k in ("oracle_exchange", "v02_exchange", "v03_exchange", "v04_exchange"):
        assert isinstance(gap[k], float), k
    assert isinstance(gap["gap_closed_fraction_v04"], float)


def test_a2_23_invalid_is_zero() -> None:
    inv = _load_json(A2 / "metrics" / "offline_invalid.json")
    assert inv["new_selected"]["invalid_rate"] == 0.0
    three = _load_json(A2 / "closedloop" / "comparison_3way.json")
    assert three["blue_vs_simple_red"]["v04"]["blue_invalid_rate"] == 0.0


def test_a2_24_prior_chain_intact() -> None:
    assert (A1 / "dataset_v03" / "manifest.json").exists()
    assert (A1 / "metrics" / "success.json").exists()
    assert (ROOT / "docs" / "JEV" / "DAGGER_V0_HANDOFF.md").exists()


def test_a2_25_no_fog_training() -> None:
    from python_jev.aggregate.dataset_v04 import load_shard_v04
    from python_jev.dataset.schema import FULL_INFO_PROFILES
    from python_jev.diagnose.collect import load_set

    prov = load_shard_v04(str(A2 / "dataset_v04" / "train.pt"),
                          verify=True)["provenance"]
    assert {p["profile"] for p in prov} <= set(FULL_INFO_PROFILES)
    dprov = load_set(str(A2 / "collected_train_states" / "dagger2_unique.pt"),
                     verify=True)["provenance"]
    assert {p["profile"] for p in dprov} <= set(FULL_INFO_PROFILES)


def test_a2_26_no_rl_or_selfplay() -> None:
    for p in (ROOT / "python_jev" / "aggregate").rglob("*.py"):
        src = p.read_text(encoding="utf-8")
        for banned in ("selfplay", "self_play", "policy_gradient", "PPO(",
                       "DQN(", "REINFORCE", "backward(", "torch.optim",
                       "Optimizer", ".step()", "zero_grad"):
            assert banned not in src, f"{p.name} mentions {banned}"


def test_a2_27_no_godot_gameplay_rewrite() -> None:
    hits = []
    for pat in ("scripts/**/*.gd", "scenes/**/*.tscn"):
        for p in ROOT.glob(pat):
            try:
                src = p.read_text(encoding="utf-8")
            except (UnicodeDecodeError, OSError):
                continue
            for token in ("jev_dagger_v1", "dataset-v0.4", "dagger2"):
                if token in src:
                    hits.append((str(p), token))
    assert hits == []
