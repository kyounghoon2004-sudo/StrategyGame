"""T0 gates ??first supervised training run (PolicyTargetV0 + dataset + training).

T0-1  PolicyTargetV0 frozen and versioned.
T0-2  Soft target conversion tests.
T0-3  Illegal actions receive exactly zero target probability.
(T0-4 ??T0-10 dataset gates live further below; T0-26 reload gate at the end.)
"""

from __future__ import annotations

import math

import pytest

from python_jev.training.policy_target import (
    POLICY_TARGET_STD_EPSILON,
    POLICY_TARGET_TEMPERATURE,
    POLICY_TARGET_VERSION,
    POLICY_TARGET_Z_CLIP,
    content_hash,
    soft_targets_from_q,
    validate_targets,
)


# ------------------------------------------------------------------ T0-1
def test_t0_1_policy_target_frozen_version() -> None:
    assert POLICY_TARGET_VERSION == "policy-target-v0.1.0"
    assert POLICY_TARGET_TEMPERATURE == 1.0
    assert POLICY_TARGET_STD_EPSILON == 1e-6
    assert POLICY_TARGET_Z_CLIP == 3.0
    h = content_hash()
    assert isinstance(h, str) and len(h) == 64
    assert content_hash() == h  # stable pin


# ------------------------------------------------------------------ T0-2
def test_t0_2_soft_targets_follow_q_ordering_without_one_hot_collapse() -> None:
    # Near-tied Q must NOT collapse: FLANK 0.53 vs ATTACK 0.51 stay soft.
    q = [0.51, 0.53, 0.10, None, None, None]
    valid = [True, True, True, False, False, False]
    p = soft_targets_from_q(q, valid)
    assert validate_targets(p, valid) == []
    assert p[1] > p[0] > p[2] > 0.0
    assert p[0] > 0.2 and p[1] > 0.2  # both leaders keep real mass
    assert p[3] == 0.0 and p[4] == 0.0 and p[5] == 0.0
    assert math.isclose(sum(p), 1.0, rel_tol=1e-9, abs_tol=1e-9)


def test_t0_2_equal_legal_q_gives_uniform_over_legal() -> None:
    q = [0.4, 0.4, None, 0.4, None, 0.4]
    valid = [True, True, False, True, False, True]
    p = soft_targets_from_q(q, valid)
    assert validate_targets(p, valid) == []
    for s in (0, 1, 3, 5):
        assert p[s] == pytest.approx(0.25)
    assert p[2] == 0.0 and p[4] == 0.0


def test_t0_2_single_legal_action_gets_full_mass() -> None:
    q = [None, None, 1.7, None, None, None]
    valid = [False, False, True, False, False, False]
    p = soft_targets_from_q(q, valid)
    assert p == [0.0, 0.0, 1.0, 0.0, 0.0, 0.0]


def test_t0_2_z_clip_bounds_extreme_gaps() -> None:
    # Huge Q gap: clipped z keeps the loser at a bounded (nonzero) mass.
    q = [100.0, 0.0, None, None, None, None]
    valid = [True, True, False, False, False, False]
    p = soft_targets_from_q(q, valid)
    assert validate_targets(p, valid) == []
    # z = ±1 -> softmax mass ratio e^2; clip only binds beyond ±3.
    assert p[0] == pytest.approx(math.exp(2) / (math.exp(2) + 1.0), rel=1e-9)
    # Five-vs-one gap large enough to hit the ±3 clip.
    q2 = [10.0, 0.0, 0.0, 0.0, 0.0, 0.0]
    p2 = soft_targets_from_q(q2, [True] * 6)
    assert validate_targets(p2, [True] * 6) == []
    assert p2[0] < 1.0 and all(v > 0.0 for v in p2)  # clipped, never one-hot


def test_t0_2_known_reference_values() -> None:
    # Hand-computed: Q=[1,0] legal -> z=[+1,-1] -> softmax.
    p = soft_targets_from_q([1.0, 0.0, None, None, None, None],
                            [True, True, False, False, False, False])
    e = math.exp(2.0)
    assert p[0] == pytest.approx(e / (e + 1.0), rel=1e-12)
    assert p[1] == pytest.approx(1.0 / (e + 1.0), rel=1e-12)


def test_t0_2_rejects_nonfinite_q_on_valid_slots() -> None:
    with pytest.raises(ValueError):
        soft_targets_from_q([float("nan"), 0.0, None, None, None, None],
                            [True, True, False, False, False, False])
    with pytest.raises(ValueError):
        soft_targets_from_q([float("inf"), 0.0, None, None, None, None],
                            [True, True, False, False, False, False])
    with pytest.raises(ValueError):
        soft_targets_from_q([None, 0.0, None, None, None, None],
                            [True, True, False, False, False, False])
    with pytest.raises(ValueError):
        soft_targets_from_q([None] * 6, [False] * 6)


def test_t0_2_temperature_guarded() -> None:
    with pytest.raises(ValueError):
        soft_targets_from_q([1.0, 0.0, None, None, None, None],
                            [True, True, False, False, False, False],
                            temperature=0.0)


# ------------------------------------------------------------------ T0-3
def test_t0_3_illegal_slots_exactly_zero_and_renormalized() -> None:
    q = [0.2, None, -0.7, None, 1.1, None]
    valid = [True, False, True, False, True, False]
    p = soft_targets_from_q(q, valid)
    assert p[1] == 0.0 and p[3] == 0.0 and p[5] == 0.0
    assert type(p[1]) is float
    assert math.isclose(p[0] + p[2] + p[4], 1.0, rel_tol=1e-9, abs_tol=1e-9)
    assert validate_targets(p, valid) == []
    bad = list(p)
    bad[1] = 1e-12
    assert validate_targets(bad, valid) != []


# ------------------------------------------------------------------ T0-4
def _dataset_shard_paths() -> dict[str, str]:
    import pathlib

    root = pathlib.Path(__file__).resolve().parents[2]
    d = root / "artifacts" / "jev_training_v0" / "dataset"
    return {s: str(d / f"{s}.pt") for s in ("train", "validation", "test")}


def test_t0_4_scenario_split_has_zero_leakage() -> None:
    from python_jev.training.coverage import check_no_leakage

    report = check_no_leakage(_dataset_shard_paths())
    assert report["leak_count"] == 0, report["leaked"]
    assert report["total_unique"] == sum(report["splits"].values())
    # frozen fractions: 75 / 12.5 / 12.5 of 192 scenarios
    assert report["splits"] == {"train": 144, "validation": 24, "test": 24}


# ------------------------------------------------------------------ T0-5
def test_t0_5_dataset_size_in_range() -> None:
    from python_jev.training.dataset_gen import DATASET_VERSION, load_shard

    total = 0
    for split, path in _dataset_shard_paths().items():
        payload = load_shard(path, verify=True)
        assert payload["dataset_version"] == DATASET_VERSION == "jev-fullinfo-dataset-v0.1.0"
        assert payload["split"] == split
        total += payload["n_records"]
    assert 10_000 <= total <= 15_000, total


# ------------------------------------------------------------------ T0-6
def test_t0_6_all_five_classes_represented() -> None:
    from python_jev.training.dataset_gen import load_shard

    payload = load_shard(_dataset_shard_paths()["train"], verify=True)
    cls = payload["tensors"]["class_idx"]
    counts = [(cls == i).sum().item() for i in range(5)]
    assert all(c > 0 for c in counts), counts
    # no severe imbalance: smallest class keeps >= 1/3 of the largest
    assert min(counts) >= max(counts) / 3, counts


# ------------------------------------------------------------------ T0-7
def test_t0_7_all_thirty_identities_have_legal_coverage() -> None:
    from python_jev.constants import ACTION_SPACE, LEARNED_CLASSES
    from python_jev.training.dataset_gen import load_shard

    payload = load_shard(_dataset_shard_paths()["train"], verify=True)
    t = payload["tensors"]
    legal = t["legal"].bool()
    cls = t["class_idx"]
    for ci, cname in enumerate(LEARNED_CLASSES):
        rows = (cls == ci).nonzero(as_tuple=True)[0]
        assert len(rows) > 0
        for s in range(6):
            n_legal = int(legal[rows, s].sum())
            assert n_legal >= 50, f"{cname}:{ACTION_SPACE[cname][s]} legal={n_legal}"
            mean_p = float(t["p_target"][rows[legal[rows, s]], s].mean())
            assert mean_p > 0.05, f"{cname}:{s} mean_p={mean_p}"


# ------------------------------------------------------------------ T0-8
def test_t0_8_single_scenario_collection_is_deterministic() -> None:
    import hashlib
    import json

    from python_jev.training.dataset_gen import collect_scenario_records, split_plan

    plan = split_plan(192)
    idx = 11  # fixed probe scenario (not asserted on content, only stability)
    a = collect_scenario_records(idx, plan[idx]["profile"], plan[idx]["split"])
    b = collect_scenario_records(idx, plan[idx]["profile"], plan[idx]["split"])
    ha = hashlib.sha256(json.dumps(a, sort_keys=True).encode()).hexdigest()
    hb = hashlib.sha256(json.dumps(b, sort_keys=True).encode()).hexdigest()
    assert ha == hb
    assert len(a) > 0


# ------------------------------------------------------------------ T0-9
def test_t0_9_no_nan_inf_or_invalid_masks() -> None:
    import torch

    from python_jev.training.dataset_gen import load_shard

    for split, path in _dataset_shard_paths().items():
        t = load_shard(path, verify=True)["tensors"]
        for k in ("actor", "tokens", "hex", "mission", "global", "q", "p_target"):
            assert bool(torch.isfinite(t[k]).all()), f"{split}:{k}"
        for k in ("token_pad", "legal", "q_valid"):
            assert t[k].dtype == torch.bool, f"{split}:{k}"
        assert t["class_idx"].min() >= 0 and t["class_idx"].max() < 5
        # full-info identity: q_valid == legal; every row has >= 1 legal
        assert bool((t["q_valid"] == t["legal"]).all()), split
        assert bool((t["legal"].sum(-1) >= 1).all()), split
        # targets: legal mass 1, illegal mass exactly 0
        mass = t["p_target"].masked_fill(~t["legal"].bool(), 0.0).sum(-1)
        assert bool(torch.allclose(mass, torch.ones_like(mass), atol=1e-5)), split
        assert float(t["p_target"].masked_fill(t["legal"].bool(), 0.0).abs().max()) == 0.0


# ------------------------------------------------------------------ T0-10
def test_t0_10_training_corpus_has_zero_fog_records() -> None:
    from python_jev.training.coverage import check_full_info_only

    report = check_full_info_only(_dataset_shard_paths())
    assert report["partial_info_records"] == 0, report["issues"]
    assert report["records"] >= 10_000


# ------------------------------------------------------------------ T0-26
def test_t0_26_checkpoint_reload_equivalence(tmp_path) -> None:
    import torch

    from python_jev.model import JevPolicyV0
    from python_jev.synthetic import make_observation_batch
    from python_jev.training.checkpoint import (
        CHECKPOINT_MODEL_VERSION,
        build_checkpoint,
        load_checkpoint,
        save_checkpoint,
    )
    from python_jev.training.dataset_gen import contract_pins

    torch.manual_seed(7)
    model = JevPolicyV0().eval()
    obs = make_observation_batch(4, seed=3)
    with torch.no_grad():
        pre = model(obs).raw_logits.clone()
    ckpt = build_checkpoint(
        model, {"architecture": "JevPolicyV0-test"}, {"lr": 3e-4}, 7, 0,
        {"train_loss": [1.0]}, {"best_val_loss": 1.0}, contract_pins(), "test-hash")
    assert ckpt["model_version"] == CHECKPOINT_MODEL_VERSION == "jev-policy-v0.1.0-fi"
    assert ckpt["full_information_only"] is True
    for pin in ("ruleset_version", "observation_layout_version", "skill_contract_version",
                "rollout_engine_version", "terminal_version", "mission_progress_version",
                "objective_progress_version", "branch_snapshot_version",
                "value_target_version", "policy_target_version"):
        assert pin in ckpt["contract_versions"], pin
    path = str(tmp_path / "roundtrip.pt")
    save_checkpoint(ckpt, path)
    fresh = JevPolicyV0().eval()
    meta = load_checkpoint(path, fresh)
    assert meta["model_version"] == CHECKPOINT_MODEL_VERSION
    with torch.no_grad():
        post = fresh(obs).raw_logits
    assert torch.equal(pre, post)  # bit-identical reload
