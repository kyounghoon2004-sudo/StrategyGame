"""R1 gates — corrected-target retraining (dataset v0.2 + jev-policy-v0.2.0-fi).

Artifact-backed gates plus small live re-simulation spot checks. Heavy
protocols (reconstruction, training, benchmarks) write
artifacts/jev_training_v1/*; these tests verify the pinned numbers.
"""

from __future__ import annotations

import hashlib
import json
import pathlib

import torch

ROOT = pathlib.Path(__file__).resolve().parents[2]
V0 = ROOT / "artifacts" / "jev_training_v0"
V1 = ROOT / "artifacts" / "jev_training_v1"

# R1-1: v0.1.0 shard file bytes, pinned before reconstruction began.
V01_FILE_SHA256 = {
    "generalization_test": "ad68ddbcd1461bd16c9894e8c8acf96149ac15716ec6dcc782b265823302b097",
    "test": "83a955d02679e0e179284b3f47d8ec6e00082d1147cb90f0d05c917b373c133e",
    "train": "533f1d305d5e61474b0bb0a6a430d452cb07736493f07ef4923af233ece18899",
    "validation": "a7343a9c074d486a03f1142ec1f6098fb484c3c9d29a595e116ce869ae40ea38",
}
POLICY_TARGET_HASH_V01 = "e509c79bc21bf4ecc80168025abac4458678498ba75125ebf07aa4a50b41d7d3"


def _load_json(path: pathlib.Path) -> dict:
    with open(path, encoding="utf-8") as f:
        return json.load(f)


# ------------------------------------------------------------- R1-1 / R1-2
def test_r1_1_v01_shards_byte_unchanged() -> None:
    from python_jev.training.dataset_gen import load_shard

    manifest = _load_json(V0 / "dataset" / "manifest.json")
    for split, pinned in V01_FILE_SHA256.items():
        p = V0 / "dataset" / f"{split}.pt"
        assert p.exists()
        assert hashlib.sha256(p.read_bytes()).hexdigest() == pinned
        payload = load_shard(str(p), verify=True)
        assert payload["shard_hash"] == manifest["shards"][split]["shard_hash"]
    assert manifest["dataset_version"] == "jev-fullinfo-dataset-v0.1.0"


def test_r1_2_v02_shards_versioned_and_verified() -> None:
    from python_jev.retrain.dataset_v2 import V2_SPLITS, load_shard_v2

    manifest = _load_json(V1 / "dataset" / "manifest.json")
    assert manifest["dataset_version"] == "jev-fullinfo-dataset-v0.2.0"
    assert manifest["source_dataset_version"] == "jev-fullinfo-dataset-v0.1.0"
    for split in V2_SPLITS:
        payload = load_shard_v2(str(V1 / "dataset" / f"{split}.pt"), verify=True)
        assert payload["split"] == split
        assert payload["config"]["full_information_only"] is True
        assert payload["contract_versions"]["legal_mask_version"] == \
            "observation-safe-skill-mask-v0.2.0"
        assert payload["contract_versions"]["skill_preflight_version"] == \
            "skill-preflight-v0.1.0"
        assert payload["source_dataset"]["shard_hash"] == \
            manifest["source_shard_hashes"][split]


def _aligned_masks():
    """Yield (split, key, old_legal, new_legal, class_idx, old_q, new_q) rows."""
    from python_jev.retrain.dataset_v2 import V2_SPLITS, load_shard_v2
    from python_jev.training.dataset_gen import load_shard

    for split in V2_SPLITS:
        old = load_shard(str(V0 / "dataset" / f"{split}.pt"), verify=True)
        new = load_shard_v2(str(V1 / "dataset" / f"{split}.pt"), verify=True)
        new_by_key = {(str(p["scenario_id"]), int(p["decision_index"])): i
                      for i, p in enumerate(new["provenance"])}
        for i, prov in enumerate(old["provenance"]):
            key = (str(prov["scenario_id"]), int(prov["decision_index"]))
            j = new_by_key.get(key)
            yield (split, key,
                   [bool(x) for x in old["tensors"]["legal"][i].tolist()],
                   ([bool(x) for x in new["tensors"]["legal"][j].tolist()]
                    if j is not None else None),
                   int(old["tensors"]["class_idx"][i].item()),
                   old["tensors"]["q"][i].tolist(),
                   (new["tensors"]["q"][j].tolist() if j is not None else None))


# ------------------------------------------------------------- R1-3..R1-5
def test_r1_3_affected_record_counts() -> None:
    delta = _load_json(V1 / "dataset_delta" / "delta_report.json")["summary"]
    changed = dropped = total = 0
    for _split, _key, old_legal, new_legal, _c, _qo, _qn in _aligned_masks():
        total += 1
        if new_legal is None:
            dropped += 1
        elif old_legal != new_legal:
            changed += 1
    assert total == 15343
    assert dropped == 18 == delta["records_dropped"]
    assert changed == 5625 == delta["records_mask_changed"]
    assert changed + dropped == 5643  # F0 audit expectation


def test_r1_4_removed_branch_count() -> None:
    from python_jev.training.dataset_gen import load_shard

    kept_lost = 0
    for _split, _key, old_legal, new_legal, _c, _qo, _qn in _aligned_masks():
        if new_legal is not None:
            kept_lost += sum(1 for a, b in zip(old_legal, new_legal) if a and not b)
    assert kept_lost == 6875
    # dropped records lost every old-legal branch (72); F0 total = 6947.
    delta = _load_json(V1 / "dataset_delta" / "delta_report.json")
    assert delta["summary"]["branches_removed"] == 6875
    dropped_old = 0
    for split in ("train", "validation", "test", "generalization_test"):
        old = load_shard(str(V0 / "dataset" / f"{split}.pt"), verify=True)
        by_key = {(str(p["scenario_id"]), int(p["decision_index"])): i
                  for i, p in enumerate(old["provenance"])}
        for d in delta["dropped"]:
            if d["split"] != split:
                continue
            i = by_key[(d["scenario_id"], d["decision_index"])]
            dropped_old += int(old["tensors"]["legal"][i].sum())
    assert dropped_old == 72
    assert kept_lost + dropped_old == 6947


def test_r1_5_gained_shadow_branches() -> None:
    gained = []
    for _split, key, old_legal, new_legal, cls, _qo, _qn in _aligned_masks():
        if new_legal is None:
            continue
        for s in range(6):
            if new_legal[s] and not old_legal[s]:
                gained.append((key, cls, s))
    assert len(gained) == 1139
    assert all(cls == 4 and s == 1 for _k, cls, s in gained)  # SCOUT/SHADOW
    rollouts = _load_json(V1 / "dataset_delta" / "new_branch_rollouts.json")
    assert rollouts["count"] == 1139
    assert all(r["actor_class"] == "SCOUT" and r["slot"] == 1 and r["skill"] == "SHADOW"
               for r in rollouts["rollouts"])
    import math

    assert all(isinstance(r["q"], float) and math.isfinite(r["q"])
               for r in rollouts["rollouts"])


# ------------------------------------------------------------------ R1-6
def _replay_to_key(scenario_id: str, profile: str, want: int):
    """Replay collection to one decision state; return (battle, actor, ctx)."""
    import json as _json

    from python_jev.training.dataset_gen import _eligible_actor_ids, ood_plan, split_plan
    from python_jev.training.scenarios import generate_scenario, mission_context_for_side
    from python_sim.policies import SimpleAttackElseAdvancePolicy
    from python_sim.sim.battle import Battle
    from python_sim.skills import observation_safe_skill_mask
    from python_sim.skills.context import MissionContext

    ood = scenario_id.startswith("ood_")
    index = int(scenario_id.rsplit("_", 1)[1])
    gen = generate_scenario(index, ood=ood)
    scenario = gen["scenario"]
    assert scenario["scenario_id"] == scenario_id
    battle = Battle(_json.loads(_json.dumps(scenario)), profile, seed=scenario["seed"])
    ctxs = {"blue": MissionContext(**mission_context_for_side(scenario, "blue")),
            "red": MissionContext(**mission_context_for_side(scenario, "red"))}
    driver = SimpleAttackElseAdvancePolicy()
    decision_index = 0
    for _turn in range(12):
        if battle.evaluate_mission()["mission_status"] != "ongoing":
            break
        blue_ids, red_ids = _eligible_actor_ids(battle)
        for side, ids in (("blue", blue_ids), ("red", red_ids)):
            for actor_id in ids:
                u = battle.world.units.get(actor_id)
                if u is None or u.soldier_count <= 0 or u.action_ended:
                    continue
                if battle.evaluate_mission()["mission_status"] != "ongoing":
                    break
                legal_old = [bool(x) for x in
                             observation_safe_skill_mask(battle, actor_id)]
                step = (driver.blue_action if side == "blue" else driver.red_action)
                if not any(legal_old):
                    step(battle, actor_id)
                    continue
                if decision_index == want:
                    return battle, actor_id, ctxs[side], scenario["seed"]
                decision_index += 1
                step(battle, actor_id)
        battle.sim_end_turn()
    raise AssertionError(f"decision {want} not reached in {scenario_id}")


def test_r1_6_reused_q_audit_passes_with_live_spot_check() -> None:
    audit = _load_json(V1 / "audit" / "reused_q_audit.json")
    assert audit["reused_q_audit"]["passed"] is True
    assert audit["reused_q_audit"]["audited_kept"] >= 500
    assert audit["reused_q_audit"]["max_abs_diff"] == 0.0
    assert all(c["max_abs_stored_vs_full"] == 0.0 and c["max_abs_single_vs_full"] == 0.0
               for c in audit["cross_checks"])

    # live spot check: 4 deterministic kept branches, re-simulated now.
    from python_jev.retrain.dataset_v2 import load_shard_v2
    from python_jev.retrain.dataset_v2 import rollout_branch_q
    from python_sim.rollout.engine import state_hash

    payload = load_shard_v2(str(V1 / "dataset" / "train.pt"), verify=True)
    spots = []
    for i, prov in enumerate(payload["provenance"]):
        if len(spots) >= 4:
            break
        legal = [bool(x) for x in payload["tensors"]["legal"][i].tolist()]
        if sum(legal) >= 2:
            s = next(s for s in range(6) if legal[s])
            spots.append((prov, s, float(payload["tensors"]["q"][i][s].item())))
    assert len(spots) == 4
    for prov, slot, stored_q in spots:
        battle, actor_id, ctx, seed = _replay_to_key(
            prov["scenario_id"], prov["profile"], int(prov["decision_index"]))
        assert state_hash(battle) == prov["state_hash"]
        re_q = rollout_branch_q(battle, actor_id, ctx, slot, seed)
        assert float(torch.tensor(re_q, dtype=torch.float32)) == \
            float(torch.tensor(stored_q, dtype=torch.float32))


# ------------------------------------------------------------- R1-7 / R1-8
def test_r1_7_policy_targets_renormalize_and_transform_frozen() -> None:
    from python_jev.retrain.dataset_v2 import V2_SPLITS, load_shard_v2
    from python_jev.training.policy_target import (
        POLICY_TARGET_VERSION,
        content_hash,
        validate_targets,
    )

    assert POLICY_TARGET_VERSION == "policy-target-v0.1.0"
    assert content_hash() == POLICY_TARGET_HASH_V01  # transform unchanged
    for split in V2_SPLITS:
        t = load_shard_v2(str(V1 / "dataset" / f"{split}.pt"), verify=True)["tensors"]
        mass = t["p_target"].masked_fill(~t["legal"].bool(), 0.0).sum(-1)
        assert bool(torch.allclose(mass, torch.ones_like(mass), atol=1e-5)), split
        assert bool((t["q_valid"] == t["legal"]).all()), split
        assert bool((t["legal"].sum(-1) >= 1).all()), split
        n = t["actor"].shape[0]
        for i in range(0, n, 997):  # deterministic stride sample + edges
            p = [float(x) for x in t["p_target"][i].tolist()]
            v = [bool(x) for x in t["q_valid"][i].tolist()]
            assert validate_targets(p, v) == [], (split, i)


def test_r1_8_illegal_target_probability_exactly_zero() -> None:
    from python_jev.retrain.dataset_v2 import V2_SPLITS, load_shard_v2

    for split in V2_SPLITS:
        t = load_shard_v2(str(V1 / "dataset" / f"{split}.pt"), verify=True)["tensors"]
        bad = t["p_target"].masked_fill(t["legal"].bool(), 0.0).abs().max()
        assert float(bad) == 0.0, split


# ------------------------------------------------------------------ R1-9
def test_r1_9_coverage_adequate_no_rebalance() -> None:
    from python_jev.constants import ACTION_SPACE, LEARNED_CLASSES
    from python_jev.retrain.dataset_v2 import load_shard_v2

    report = _load_json(V1 / "metrics" / "coverage_report.json")
    assert report["rebalance_decision"] == "KEEP_DISTRIBUTION"
    assert report["train_flags"]["dead_actions"] == []
    assert report["leakage"]["leak_count"] == 0
    assert report["full_info"]["partial_info_records"] == 0
    t = load_shard_v2(str(V1 / "dataset" / "train.pt"), verify=True)["tensors"]
    legal = t["legal"].bool()
    cls = t["class_idx"]
    for ci, cname in enumerate(LEARNED_CLASSES):
        rows = (cls == ci).nonzero(as_tuple=True)[0]
        for s in range(6):
            n_legal = int(legal[rows, s].sum())
            assert n_legal >= 50, f"{cname}:{ACTION_SPACE[cname][s]}"
            mean_p = float(t["p_target"][rows[legal[rows, s]], s].mean())
            assert mean_p > 0.05, f"{cname}:{s}"


# ----------------------------------------------------------------- R1-10
def test_r1_10_tiny_overfit_passes() -> None:
    rep = _load_json(V1 / "metrics" / "tiny_overfit.json")
    assert rep["passed"] is True
    assert rep["final_metrics"]["kl"] < 0.02
    assert rep["final_metrics"]["mean_regret"] < 0.005
    assert rep["final_loss"] < rep["entropy_floor"] + 0.05


# ----------------------------------------------------------------- R1-11
def test_r1_11_three_seeds_trained_from_scratch() -> None:
    history = _load_json(V1 / "metrics" / "training_history.json")
    assert history["model_version"] == "jev-policy-v0.2.0-fi"
    assert history["init"] == "from_scratch"
    assert history["n_parameters"] == 1014430
    assert set(history["seeds"]) == {"42", "43", "44"}
    for seed, run in history["seeds"].items():
        ckpt = torch.load(V1 / "checkpoints" / f"seed{seed}.pt",
                          map_location="cpu", weights_only=False)
        assert ckpt["model_version"] == "jev-policy-v0.2.0-fi"
        assert ckpt["full_information_only"] is True
        assert ckpt["init"] == "from_scratch"
        assert ckpt["seed"] == int(seed)
        assert run["best_val_loss"] == ckpt["validation_metrics"]["best_val_loss"]
    best = min(history["seeds"],
               key=lambda s: history["seeds"][s]["best_val_loss"])
    assert history["selected_seed"] == int(best)
    assert history["selection_rule"] == \
        "lowest validation soft-target cross entropy"


# ------------------------------------------------------------- R1-12/13
def test_r1_12_all_models_share_one_corrected_heldout() -> None:
    from python_jev.retrain.dataset_v2 import load_shard_v2

    report = _load_json(V1 / "metrics" / "offline.json")
    assert report["mask"] == "observation-safe-skill-mask-v0.2.0"
    assert set(report["models"]) >= {"old_seed43", "new_seed42", "new_seed43",
                                     "new_seed44"}
    pinned = report["shard_hash"]
    actual = load_shard_v2(str(V1 / "dataset" / "test.pt"), verify=True)["shard_hash"]
    assert pinned == actual
    for name, m in report["models"].items():
        assert m["aggregate"]["samples"] == 1531, name


def test_r1_13_selected_invalid_is_zero() -> None:
    report = _load_json(V1 / "metrics" / "offline_invalid.json")
    assert report["mask"] == "observation-safe-skill-mask-v0.2.0"
    assert report["new_selected"]["invalid_rate"] == 0.0
    assert report["old_seed43"]["invalid_rate"] == 0.0
    assert report["new_selected"]["states"] > 1000


# ------------------------------------------------------------- R1-14..17
def test_r1_14_same_seat_benchmark_used() -> None:
    comp = _load_json(V1 / "closedloop" / "same_seat_comparison.json")
    assert comp["benchmark_version"] == "closed-loop-benchmark-v0.1.0"
    assert comp["mask"] == "new (observation-safe-skill-mask-v0.2.0)"
    assert comp["jobs"] == 24
    assert comp["matched_proof"]["baseline_conditions_identical"] is True
    assert set(comp["blue_vs_simple_red"]) == {
        "NEW_JEV", "OLD_JEV", "SimpleAttackElseAdvancePolicy",
        "RandomLegalPolicy", "HoldPolicy"}


def test_r1_15_no_side_swapped_win_claim() -> None:
    text = (V1 / "closedloop" / "same_seat_comparison.json").read_text(encoding="utf-8")
    assert "jev_victory_rate" not in text
    assert "red_victory_rate" not in text
    assert "side_swapped_terminal=INVALID" in text


def test_r1_16_17_progress_and_exchange_reported() -> None:
    comp = _load_json(V1 / "closedloop" / "same_seat_comparison.json")
    for policy, s in comp["blue_vs_simple_red"].items():
        for k in ("mean_mission_progress_delta_blue", "mean_exchange_blue_view",
                  "mean_objective_progress_delta_blue", "mean_turns",
                  "victory_rate_blue", "expired_rate"):
            assert k in s, (policy, k)
    for d in ("NEW_minus_OLD", "NEW_minus_Simple"):
        for k in ("mean_mission_progress_delta_blue", "mean_exchange_blue_view"):
            assert k in comp["deltas"][d]


# ----------------------------------------------------------------- R1-18
def test_r1_18_tactical_exam_comparison() -> None:
    exam = _load_json(V1 / "exam" / "exam.json")
    assert exam["mask"] == "observation-safe-skill-mask-v0.2.0"
    assert set(exam["models"]) == {"untrained", "old", "new"}
    for name, m in exam["models"].items():
        assert m["summary"]["overall"]["cases"] == 60, name
        assert len(m["cases"]) == 60, name
    assert exam["selection_changes_old_to_new"]["n_cases"] == 60


# ----------------------------------------------------------------- R1-19
def test_r1_19_continuation_sensitivity_rerun() -> None:
    sens = _load_json(V1 / "sensitivity" / "sensitivity.json")
    assert sens["mask"] == "new"
    assert sens["states"] == 320
    assert len(sens["overall"]) == 3
    for c in ("ARCHER", "CAVALRY"):
        assert c in sens["by_class"]
        assert len(sens["by_class"][c]) == 3
    assert set(sens["model_alignment"]) == {
        "SimpleAttackElseAdvancePolicy", "RandomLegalPolicy", "HoldPolicy"}


# ------------------------------------------------------------- R1-20..23
def test_r1_20_architecture_unchanged() -> None:
    old = torch.load(V0 / "checkpoints" / "seed43.pt",
                     map_location="cpu", weights_only=False)
    new = torch.load(V1 / "checkpoints" / "seed43.pt",
                     map_location="cpu", weights_only=False)
    assert set(new["state_dict"]) == set(old["state_dict"])
    for k in old["state_dict"]:
        assert tuple(new["state_dict"][k].shape) == tuple(old["state_dict"][k].shape)
    assert sum(p.numel() for p in new["state_dict"].values()) == 1014430


def test_r1_21_22_no_fog_training_no_rl_or_selfplay() -> None:
    from python_jev.dataset.schema import FULL_INFO_PROFILES
    from python_jev.retrain.dataset_v2 import V2_SPLITS, load_shard_v2
    from python_sim.rollout.value_target import (
        VALUE_TARGET_VERSION,
    )
    from python_sim.rollout.value_target import content_hash as vt_hash

    assert VALUE_TARGET_VERSION == "value-target-v0.1.0"  # value target frozen
    for split in V2_SPLITS:
        payload = load_shard_v2(str(V1 / "dataset" / f"{split}.pt"), verify=True)
        cv = payload["contract_versions"]
        assert cv["value_target_version"] == "value-target-v0.1.0"
        assert cv["value_target_hash"] == vt_hash()
        assert payload["config"]["full_information_only"] is True
        profiles = {p["profile"] for p in payload["provenance"]}
        assert profiles <= set(FULL_INFO_PROFILES), profiles
    # source-level: no RL / self-play / fog-oracle machinery in retrain code
    # (test files may name the guarded concepts; non-test sources may not).
    for p in (ROOT / "python_jev" / "retrain").rglob("*.py"):
        src = p.read_text(encoding="utf-8")
        for banned in ("selfplay", "self_play", "policy_gradient", "PPO(",
                       "DQN(", "REINFORCE", "MSELoss", "lr_scheduler",
                       "FogOracle", "fog_oracle"):
            assert banned not in src, f"{p.name} mentions {banned}"


def test_r1_23_no_godot_gameplay_rewrite() -> None:
    hits = []
    for pat in ("scripts/**/*.gd", "scenes/**/*.tscn"):
        for p in ROOT.glob(pat):
            try:
                src = p.read_text(encoding="utf-8")
            except (UnicodeDecodeError, OSError):
                continue
            for token in ("jev-training-v1", "dataset-v0.2", "retrain",
                          "SkillPreflight", "skill_preflight"):
                if token in src:
                    hits.append((str(p), token))
    assert hits == []
