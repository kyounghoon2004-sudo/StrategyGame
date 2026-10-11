"""A3 gates — third supervised state-aggregation round (dagger3, NOT RL).

Mirrors the A2 gate structure for v0.5 / jev-policy-v0.5.0-fi-dagger3.
Frozen inputs (v0.2 bytes, v0.3/v0.4 shards, A1/A2 sets, D0 sets) are
asserted intact, never rewritten.
"""

from __future__ import annotations

import hashlib
import json
import pathlib

import torch

ROOT = pathlib.Path(__file__).resolve().parents[2]
A3 = ROOT / "artifacts" / "jev_dagger_v2"
A2 = ROOT / "artifacts" / "jev_dagger_v1"
A1 = ROOT / "artifacts" / "jev_dagger_v0"
V02 = ROOT / "artifacts" / "jev_training_v1" / "dataset"
V04 = A2 / "dataset_v04"

V04_TRAIN_SHA256 = "4a17aa3a5ad1cf9944cd12ec56bad4976b7f297482cb80434695880e1aa30d21"
V04_SEED44_SHA256 = "18ec11625d5de86e07e5caf84e3769fb73e4f585645c34129fe6f748cf42c0cc"


def _load_json(path: pathlib.Path) -> dict:
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def _file_sha(p: pathlib.Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def test_a3_1_driver_ckpt_verified() -> None:
    manifest = _load_json(A3 / "round3_collection" / "manifest.json")
    assert manifest["driver"] == "jev-policy-v0.4.0-fi-dagger2/seed44"
    assert manifest["driver_ckpt_hash"] == V04_SEED44_SHA256
    assert _file_sha(A2 / "checkpoints" / "seed44.pt") == V04_SEED44_SHA256


def test_a3_2_only_train_scenarios_aggregated() -> None:
    from python_jev.aggregate.gather import split_scenario_ids
    from python_jev.diagnose.collect import load_set

    train_ids = split_scenario_ids()["train"]
    prov = load_set(str(A3 / "round3_collection" / "dagger3_unique.pt"),
                    verify=True)["provenance"]
    dag_ids = {p["scenario_id"] for p in prov}
    assert dag_ids <= train_ids and len(dag_ids) == 144
    assert {p["split"] for p in prov} == {"train"}


def test_a3_3_raw_collection_cap_unchanged() -> None:
    from collections import Counter

    from python_jev.diagnose.collect import load_set

    manifest = _load_json(A3 / "round3_collection" / "manifest.json")
    assert manifest["dedup"]["raw"] == 6048
    assert manifest["dedup"]["unique"] == 6048
    prov = load_set(str(A3 / "round3_collection" / "dagger3_unique.pt"),
                    verify=True)["provenance"]
    per = Counter(p["scenario_id"] for p in prov)
    assert len(per) == 144 and max(per.values()) <= 42


def test_a3_4_cross_dedup_against_v04() -> None:
    rep = _load_json(A3 / "round3_collection" / "crossdedup.json")
    assert rep["method"] == "float32-tensor-bytes+class+mission+legal"
    assert rep["tensor_join_checked"] == rep["tensor_join_matched"] == 12096
    assert rep["new_unique"] + rep["already_in_v04"] == rep["round3_unique"]


def test_a3_5_novel_count_recorded() -> None:
    rep = _load_json(A3 / "round3_collection" / "crossdedup.json")
    manifest = _load_json(A3 / "dataset_v05" / "manifest.json")
    assert rep["new_unique"] == 5408 == manifest["dagger3_train"]
    assert rep["already_in_v04"] == 640
    idx = rep["novel_indices"]
    assert len(idx) == 5408 and len(set(idx)) == 5408
    assert min(idx) >= 0 and max(idx) < 6048
    assert sum(rep["novel_class_distribution"].values()) == 5408


def test_a3_6_no_val_test_in_v05_train() -> None:
    from python_jev.aggregate.dataset_v05 import load_shard_v05
    from python_jev.aggregate.gather import split_scenario_ids

    ref = split_scenario_ids()
    forbidden = ref["validation"] | ref["test"] | ref["generalization_test"]
    prov = load_shard_v05(str(A3 / "dataset_v05" / "train.pt"),
                          verify=True)["provenance"]
    train_ids = {p["scenario_id"] for p in prov}
    assert train_ids & forbidden == set()
    assert train_ids <= ref["train"]


def test_a3_7_frozen_teacher_pipeline() -> None:
    from python_jev.aggregate.dataset_v05 import load_shard_v05
    from python_jev.training.policy_target import validate_targets

    payload = load_shard_v05(str(A3 / "dataset_v05" / "train.pt"), verify=True)
    cv = payload["contract_versions"]
    assert cv["legal_mask_version"] == "observation-safe-skill-mask-v0.2.0"
    assert cv["skill_preflight_version"] == "skill-preflight-v0.1.0"
    assert cv["value_target_version"] == "value-target-v0.1.0"
    assert cv["policy_target_version"] == "policy-target-v0.1.0"
    assert cv["dataset_version"] == "jev-fullinfo-dataset-v0.5.0"
    assert cv["aggregation_version"] == "state-aggregation-v0.3.0"
    t, prov = payload["tensors"], payload["provenance"]
    n_dag3 = 0
    for i, p in enumerate(prov):
        if p["source"] != "JEV_VISITED_DAGGER3":
            continue
        n_dag3 += 1
        assert p["continuation_policy"] == "SimpleAttackElseAdvancePolicy"
        assert p["horizon_decisions"] == 8
        qv = [bool(x) for x in t["q_valid"][i].tolist()]
        assert qv == [bool(x) for x in t["legal"][i].tolist()]
        assert validate_targets([float(x) for x in t["p_target"][i].tolist()], qv) == []
    assert n_dag3 == _load_json(A3 / "dataset_v05" / "manifest.json")["dagger3_train"]


def test_a3_8_corrective_signal_audit() -> None:
    rep = _load_json(A3 / "metrics" / "recovery_signal.json")
    assert rep["passed"] is True
    assert rep["top_agreement"] < 0.90
    assert rep["n"] == 6048
    assert "ARCHER_FIRE" in rep["spotlight"]


def test_a3_9_scout_boundary_reproduced() -> None:
    rep = _load_json(A3 / "metrics" / "recovery_signal.json")
    b = rep["scout_boundary"]
    assert b["both_sides_covered"] is True
    assert b["teacher_evade"] >= 1 and b["teacher_recon"] >= 100
    assert b["policy_skill_counts"]["EVADE"] > b["teacher_skill_counts"]["EVADE"]
    assert len(b["feature_differences"]) == 27


def test_a3_10_v04_immutable() -> None:
    from python_jev.aggregate.dataset_v04 import load_shard_v04

    assert _file_sha(V04 / "train.pt") == V04_TRAIN_SHA256
    load_shard_v04(str(V04 / "train.pt"), verify=True)
    a2_success = _load_json(A2 / "metrics" / "success.json")
    assert a2_success["TRAINING_SUCCESS"] == "PASS"
    assert a2_success["POLICY_QUALITY_SUCCESS"] == "PASS"


def test_a3_11_v05_is_v04_plus_dagger3() -> None:
    from python_jev.aggregate.dataset_v04 import load_shard_v04
    from python_jev.aggregate.dataset_v05 import load_shard_v05

    manifest = _load_json(A3 / "dataset_v05" / "manifest.json")
    new = load_shard_v05(str(A3 / "dataset_v05" / "train.pt"), verify=True)
    old = load_shard_v04(str(V04 / "train.pt"), verify=True)
    n0 = manifest["carried_train"]
    assert n0 == 21290 == old["n_records"]
    assert new["n_records"] == n0 + manifest["dagger3_train"] == 26698
    for k in ("actor", "tokens", "hex", "mission", "global", "q", "p_target",
              "token_pad", "legal", "q_valid", "class_idx"):
        assert torch.equal(new["tensors"][k][:n0], old["tensors"][k]), k
    assert {p["source"] for p in new["provenance"][n0:]} == {"JEV_VISITED_DAGGER3"}


def test_a3_12_val_test_byte_identical() -> None:
    for split in ("validation", "test", "generalization_test"):
        assert _file_sha(A3 / "dataset_v05" / f"{split}.pt") == _file_sha(V02 / f"{split}.pt")


def test_a3_13_mixed_overfit_passes() -> None:
    rep = _load_json(A3 / "metrics" / "tiny_overfit.json")
    assert rep["passed"] is True
    assert rep["mix"] == "32 v0.2 + 32 dagger1 + 32 dagger2 + 32 dagger3"


def test_a3_14_three_seeds_from_scratch() -> None:
    history = _load_json(A3 / "metrics" / "training_history.json")
    assert history["model_version"] == "jev-policy-v0.5.0-fi-dagger3"
    assert history["init"] == "from_scratch"
    assert set(history["seeds"]) == {"42", "43", "44"}
    for seed in ("42", "43", "44"):
        ckpt = torch.load(A3 / "checkpoints" / f"seed{seed}.pt",
                          map_location="cpu", weights_only=False)
        assert ckpt["model_version"] == "jev-policy-v0.5.0-fi-dagger3"
        assert ckpt["init"] == "from_scratch"


def test_a3_15_parameter_count_unchanged() -> None:
    new = torch.load(A3 / "checkpoints" / "seed44.pt",
                     map_location="cpu", weights_only=False)
    old = torch.load(ROOT / "artifacts" / "jev_training_v1" / "checkpoints" / "seed43.pt",
                     map_location="cpu", weights_only=False)
    assert set(new["state_dict"]) == set(old["state_dict"])
    assert sum(p.numel() for p in new["state_dict"].values()) == 1014430


def test_a3_16_selected_by_validation_only() -> None:
    history = _load_json(A3 / "metrics" / "training_history.json")
    best = min(history["seeds"], key=lambda s: history["seeds"][s]["best_val_loss"])
    assert history["selected_seed"] == int(best)


def test_a3_17_original_test_metrics() -> None:
    from python_jev.retrain.dataset_v2 import load_shard_v2

    report = _load_json(A3 / "metrics" / "offline.json")
    assert set(report["models"]) >= {"v02", "v03", "v04", "v05_seed42",
                                     "v05_seed43", "v05_seed44", "untrained"}
    actual = load_shard_v2(str(V02 / "test.pt"), verify=True)["shard_hash"]
    assert report["shard_hash"] == actual


def test_a3_18_visited_validation_v04() -> None:
    from python_jev.diagnose.collect import load_set

    rep = _load_json(A3 / "metrics" / "visited.json")
    vv = rep["visited_v04"]
    assert vv["n"] == 1536
    assert set(vv["models"]) == {"v04", "v05"}
    for tag in ("v04", "v05"):
        for k in ("mean_regret", "p95_regret", "top1", "epsilon_at_0.01"):
            assert k in vv["models"][tag]
    assert set(rep["visited_test_v05"]["models"]) == {"v04", "v05"}
    assert set(rep["visited_validation_frozen"]["models"]) == {"v02", "v03", "v04", "v05"}
    prov = load_set(str(A3 / "visited_validation" / "visited_v04.pt"),
                    verify=True)["provenance"]
    assert {p["split"] for p in prov} == {"validation"}


def test_a3_19_trajectory_depth_four_models() -> None:
    rep = _load_json(A3 / "depth" / "depth_compare.json")
    for name in ("frozen_jev_new_set", "visited_validation_frozen"):
        for tag in ("v02", "v03", "v04", "v05"):
            for b in ("0-4", "5-9", "10-19", "20-+"):
                assert rep[name][tag][b]["n"] > 0


def test_a3_20_four_way_closedloop() -> None:
    four = _load_json(A3 / "closedloop" / "comparison_4way.json")
    assert set(four["blue_vs_simple_red"]) == {"v05", "v04", "v03", "v02",
                                               "Simple", "Random", "Hold"}
    assert four["jobs"] == 24
    text = (A3 / "closedloop" / "comparison_4way.json").read_text(encoding="utf-8")
    assert "jev_victory_rate" not in text
    assert "side_swapped_terminal=INVALID" in text


def test_a3_21_scout_behavior_comparison() -> None:
    scout = _load_json(A3 / "scout" / "scout.json")
    assert set(scout["policy_scout_dist"]) == {"v02", "v03", "v04", "v05"}
    assert scout["teacher_on_drift_v05"]["recon"] > 0.90
    for k, v in scout["policy_scout_dist"].items():
        assert sum(v["dist"].values()) == v["n"], k


def test_a3_22_teacher_policy_disagreement() -> None:
    rep = _load_json(A3 / "metrics" / "disagreement.json")
    assert rep["n"] == 6048
    for tag in ("v04", "v05"):
        for k in ("agreement", "mean_current_action_regret",
                  "mean_selected_p_target", "mean_js_to_teacher"):
            assert k in rep["models"][tag]


def test_a3_23_oracle_gap_five_series() -> None:
    gap = _load_json(A3 / "oracle" / "oracle_gap.json")
    for k in ("oracle_exchange", "v02_exchange", "v03_exchange",
              "v04_exchange", "v05_exchange"):
        assert isinstance(gap[k], float), k
    assert isinstance(gap["gap_closed_fraction_v05"], float)


def test_a3_24_tactical_exam_five_models() -> None:
    exam = _load_json(A3 / "exam" / "exam.json")
    assert set(exam["models"]) == {"untrained", "v02", "v03", "v04", "v05"}
    for name, m in exam["models"].items():
        assert m["summary"]["overall"]["cases"] == 60, name


def test_a3_25_distribution_shift_four_models() -> None:
    drift = _load_json(A3 / "drift" / "drift.json")
    for tag in ("v02", "v03", "v04", "v05"):
        c = drift["contact"][tag]
        for k in ("attack_opportunity_rate", "mean_nearest_enemy",
                  "local_enemy_count", "friendly_dispersion",
                  "scout_evade_freq", "scout_recon_freq"):
            assert k in c, (tag, k)
    assert set(drift["latent"]["sets"]) >= {"v02_visited", "v03_visited",
                                            "v04_visited", "v05_visited",
                                            "iid_test"}
    assert "v04_visited_vs_v05_visited" in drift["shift"]


def test_a3_26_invalid_is_zero() -> None:
    inv = _load_json(A3 / "metrics" / "offline_invalid.json")
    assert inv["new_selected"]["invalid_rate"] == 0.0
    four = _load_json(A3 / "closedloop" / "comparison_4way.json")
    assert four["blue_vs_simple_red"]["v05"]["blue_invalid_rate"] == 0.0


def test_a3_27_prior_chain_intact() -> None:
    assert (A2 / "dataset_v04" / "manifest.json").exists()
    assert (A2 / "metrics" / "success.json").exists()
    assert (A1 / "dataset_v03" / "manifest.json").exists()
    assert (ROOT / "docs" / "JEV" / "DAGGER_V1_HANDOFF.md").exists()


def test_a3_28_no_fog_training() -> None:
    from python_jev.aggregate.dataset_v05 import load_shard_v05
    from python_jev.dataset.schema import FULL_INFO_PROFILES
    from python_jev.diagnose.collect import load_set

    prov = load_shard_v05(str(A3 / "dataset_v05" / "train.pt"),
                          verify=True)["provenance"]
    assert {p["profile"] for p in prov} <= set(FULL_INFO_PROFILES)
    dprov = load_set(str(A3 / "round3_collection" / "dagger3_unique.pt"),
                     verify=True)["provenance"]
    assert {p["profile"] for p in dprov} <= set(FULL_INFO_PROFILES)


def test_a3_29_no_rl_or_selfplay() -> None:
    for p in (ROOT / "python_jev" / "aggregate").rglob("*.py"):
        src = p.read_text(encoding="utf-8")
        for banned in ("selfplay", "self_play", "policy_gradient", "PPO(",
                       "DQN(", "REINFORCE", "backward(", "torch.optim",
                       "Optimizer", ".step()", "zero_grad"):
            assert banned not in src, f"{p.name} mentions {banned}"


def test_a3_30_no_arch_teacher_reward_change() -> None:
    from python_jev.aggregate.dataset_v05 import load_shard_v05

    cv = load_shard_v05(str(A3 / "dataset_v05" / "train.pt"),
                        verify=True)["contract_versions"]
    assert cv["aggregation_version"] == "state-aggregation-v0.3.0"
    assert cv["source_dataset_version"] == "jev-fullinfo-dataset-v0.4.0"
    assert cv["collection_checkpoint_dagger3"] == "jev-policy-v0.4.0-fi-dagger2/seed44"
    new = torch.load(A3 / "checkpoints" / "seed44.pt",
                     map_location="cpu", weights_only=False)
    old = torch.load(ROOT / "artifacts" / "jev_training_v1" / "checkpoints" / "seed43.pt",
                     map_location="cpu", weights_only=False)
    assert set(new["state_dict"]) == set(old["state_dict"])


def test_a3_31_no_godot_gameplay_rewrite() -> None:
    hits = []
    for pat in ("scripts/**/*.gd", "scenes/**/*.tscn"):
        for p in ROOT.glob(pat):
            try:
                src = p.read_text(encoding="utf-8")
            except (UnicodeDecodeError, OSError):
                continue
            for token in ("jev_dagger_v2", "dataset-v0.5", "dagger3"):
                if token in src:
                    hits.append((str(p), token))
    assert hits == []


def test_a3_32_success_verdicts_consistent() -> None:
    four = _load_json(A3 / "closedloop" / "comparison_4way.json")["blue_vs_simple_red"]
    success = _load_json(A3 / "metrics" / "success.json")
    for k in ("TRAINING_SUCCESS", "DISTRIBUTION_SUCCESS",
              "POLICY_QUALITY_SUCCESS", "COVERAGE_CONVERGENCE"):
        assert k in success
    improved = four["v05"]["mean_exchange_blue_view"] > four["v04"]["mean_exchange_blue_view"]
    assert (success["POLICY_QUALITY_SUCCESS"] == "PASS") == improved
    assert success["COVERAGE_CONVERGENCE"] in ("NOT_CONVERGED",
                                               "APPROACHING_CONVERGENCE",
                                               "CONVERGED")
