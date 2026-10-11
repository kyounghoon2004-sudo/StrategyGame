"""M0 gates — jev_mission_data_v1 regression (same-state multi-mission corpus).

M0-1  mission_context is required on every row (fail-fast, no silent default).
M0-2  Same-state variants differ ONLY in the mission block.
M0-3  Six-slot legality mask is identical across variants of a state.
M0-4  Teacher targets are recomputed per mission (never copied across variants).
M0-5  Mission features are non-constant (within-state and corpus-wide).
M0-6  Grouped split: no physical state leaks across train/val.
M0-7  Legacy T0 checkpoint loads into the unchanged architecture.
M0-8  Six-slot semantics intact end to end (masks, targets, forward).

Read-only: these tests never train, never write checkpoints, never touch Godot.
"""

from __future__ import annotations

import json
import math
import os

import pytest
import torch

from python_jev.model import JevPolicyV0
from python_jev.training.checkpoint import load_checkpoint
from python_jev.training.data import collate_jev
from python_jev.training.policy_target import soft_targets_from_q, validate_targets
from python_jev.training.projection import require_training_context

PROJ = os.path.abspath(os.path.join(os.path.dirname(__file__), os.pardir, os.pardir))
ART = os.path.join(PROJ, "artifacts", "jev_mission_data_v1")
INTENTS = ["ATTACK", "FIX", "FLANK", "HOLD", "RESERVE", "RECON", "WITHDRAW"]
LEGACY_CKPT = os.path.join(PROJ, "artifacts", "jev_training_v0", "checkpoints", "seed44.pt")

pytestmark = pytest.mark.skipif(
    not os.path.isdir(ART), reason="jev_mission_data_v1 artifacts not present")


def _read_jsonl(path: str) -> list[dict]:
    with open(path, encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]


@pytest.fixture(scope="module")
def train_pt() -> dict:
    return torch.load(os.path.join(ART, "states_train.pt"), map_location="cpu",
                      weights_only=False)


@pytest.fixture(scope="module")
def val_pt() -> dict:
    return torch.load(os.path.join(ART, "states_val.pt"), map_location="cpu",
                      weights_only=False)


@pytest.fixture(scope="module")
def rows_train() -> list[dict]:
    return _read_jsonl(os.path.join(ART, "train.jsonl"))


@pytest.fixture(scope="module")
def rows_val() -> list[dict]:
    return _read_jsonl(os.path.join(ART, "val.jsonl"))


@pytest.fixture(scope="module")
def split_of() -> dict:
    with open(os.path.join(ART, "SPLIT_INDEX.json"), encoding="utf-8") as f:
        return json.load(f)["split_of_state"]


# ------------------------------------------------------------------ M0-1
def test_m0_1_every_row_carries_identified_mission_context(rows_train, rows_val) -> None:
    for r in rows_train + rows_val:
        mc = r.get("mission_context")
        assert isinstance(mc, dict), f"{r.get('row_id')}: mission_context missing"
        assert mc.get("scenario_id"), f"{r['row_id']}: context lacks scenario_id"
        assert mc.get("mission_type"), f"{r['row_id']}: context lacks mission_type"
        assert isinstance(mc.get("doctrine"), dict), f"{r['row_id']}: no doctrine"
        assert len(r["mission_block"]) == 46


def test_m0_1_training_projection_rejects_missing_or_default_context() -> None:
    from python_sim.skills.context import MissionContext

    with pytest.raises(ValueError):
        require_training_context(None)
    with pytest.raises(ValueError):
        require_training_context(MissionContext())  # default: no scenario identity
    with pytest.raises(TypeError):
        require_training_context({"scenario_id": "x"})  # type: ignore[arg-type]


# ------------------------------------------------------------------ M0-2
def test_m0_2_variants_share_obs_hash_but_not_mission_block(rows_train) -> None:
    by_state: dict[str, list[dict]] = {}
    for r in rows_train:
        by_state.setdefault(r["state_key"], []).append(r)
    assert len(by_state) == 2523
    for skey, rows in by_state.items():
        assert [r["intent"] for r in rows] == INTENTS, skey
        assert len({r["obs_groups_hash"] for r in rows}) == 1, skey
        assert len({r["state_hash"] for r in rows}) == 1, skey
        assert len({r["profile"] for r in rows}) == 1, skey
        assert len({r["actor_id"] for r in rows}) == 1, skey
        blocks = {tuple(r["mission_block"]) for r in rows}
        assert len(blocks) == 7, f"{skey}: mission blocks not pairwise distinct"


def test_m0_2_pt_variant_blocks_pairwise_distinct(train_pt, val_pt) -> None:
    for p in (train_pt, val_pt):
        n = len(p["state_keys"])
        blocks = torch.stack([p["mission_variant"][i] for i in INTENTS], dim=1)
        assert blocks.shape == (n, 7, 46)
        for s in range(n):
            assert len({tuple(blocks[s, j].tolist()) for j in range(7)}) == 7


# ------------------------------------------------------------------ M0-3
def test_m0_3_legal_mask_identical_across_variants(rows_train, rows_val) -> None:
    for r in rows_train + rows_val:
        assert len(r["legal_mask"]) == 6 and len(r["q_valid_mask"]) == 6
        assert [bool(x) for x in r["q_valid_mask"]] == [bool(x) for x in r["legal_mask"]]
    by_state: dict[str, list[dict]] = {}
    for r in rows_train:
        by_state.setdefault(r["state_key"], []).append(r)
    for skey, rows in by_state.items():
        assert len({tuple(r["legal_mask"]) for r in rows}) == 1, skey


def test_m0_3_pt_q_valid_equals_legal_broadcast(train_pt, val_pt) -> None:
    for p in (train_pt, val_pt):
        want = p["legal"].repeat_interleave(7, dim=0)
        assert torch.equal(p["labels_row_major"]["q_valid"], want)


# ------------------------------------------------------------------ M0-4
def test_m0_4_p_target_matches_per_variant_q(rows_train) -> None:
    checked = 0
    for r in rows_train[::37]:  # deterministic ~477-row sample
        qv = [bool(x) for x in r["q_valid_mask"]]
        expect = soft_targets_from_q(r["q_values"], qv)
        assert validate_targets(r["p_target"], qv) == [], r["row_id"]
        for a, b in zip(r["p_target"], expect):
            assert a == pytest.approx(b, abs=1e-6), r["row_id"]
        checked += 1
    assert checked > 400


def test_m0_4_teacher_varies_with_mission(train_pt) -> None:
    p = train_pt
    n = len(p["state_keys"])
    q = torch.nan_to_num(p["labels_row_major"]["q_values"], nan=0.0).view(n, 7, 6)
    identical = (q - q[:, :1, :]).abs().sum(dim=-1) == 0
    n_identical = int(identical.all(dim=-1).sum())
    assert n_identical < n // 2, f"teacher Q identical on {n_identical}/{n} states"
    tops = p["labels_row_major"]["teacher_top_slot"].view(n, 7)
    flips = int(((tops != tops[:, :1]).any(dim=-1)).sum())
    assert flips >= 500, f"only {flips} states flip teacher top slot"
    with open(os.path.join(ART, "manifest.json"), encoding="utf-8") as f:
        manifest = json.load(f)
    assert manifest["counts"]["engine_evaluations"] == manifest["counts"]["rows"] == 19600


# ------------------------------------------------------------------ M0-5
def test_m0_5_mission_features_non_constant(train_pt, val_pt) -> None:
    for p in (train_pt, val_pt):
        n = len(p["state_keys"])
        blocks = torch.stack([p["mission_variant"][i] for i in INTENTS], dim=1)
        assert torch.isfinite(blocks).all()
        uniq_all = {tuple(blocks[s, j].tolist()) for s in range(n) for j in range(7)}
        assert len(uniq_all) > 1000, f"only {len(uniq_all)} unique mission blocks"
        for name in INTENTS:
            uniq_intent = {tuple(v.tolist()) for v in p["mission_variant"][name]}
            assert len(uniq_intent) > 100, f"{name}: only {len(uniq_intent)} variants"


# ------------------------------------------------------------------ M0-6
def test_m0_6_grouped_split_has_no_state_leakage(rows_train, rows_val, split_of) -> None:
    train_states = {r["physical_state_id"] for r in rows_train}
    val_states = {r["physical_state_id"] for r in rows_val}
    assert len(train_states) == 2523 and len(val_states) == 277
    assert train_states.isdisjoint(val_states), "physical state in both splits"
    assert len(split_of) == 2800
    for r in rows_train:
        assert r["split"] == "train" and split_of[r["physical_state_id"]] == "train"
    for r in rows_val:
        assert r["split"] == "val" and split_of[r["physical_state_id"]] == "val"
    assert len(rows_train) == 7 * len(train_states) == 17661
    assert len(rows_val) == 7 * len(val_states) == 1939


# ------------------------------------------------------------------ M0-7
def test_m0_7_legacy_checkpoint_loads_and_runs_on_new_corpus(train_pt) -> None:
    assert os.path.isfile(LEGACY_CKPT), "legacy v0 checkpoint missing"
    torch.manual_seed(0)
    model = JevPolicyV0()
    meta = load_checkpoint(LEGACY_CKPT, model)
    assert meta.get("model_version") == "jev-policy-v0.1.0-fi"
    lab = train_pt["labels_row_major"]
    rows = [{
        "actor": train_pt["actor"][0], "tokens": train_pt["tokens"][0],
        "token_pad": train_pt["token_pad"][0], "hex": train_pt["hex"][0],
        "mission": train_pt["mission_variant"][name][0],
        "global": train_pt["global"][0], "class_idx": train_pt["class_idx"][0],
        "legal": train_pt["legal"][0],
        "q": torch.nan_to_num(lab["q_values"][j], nan=0.0),
        "q_valid": lab["q_valid"][j], "p_target": lab["p_target"][j],
    } for j, name in enumerate(INTENTS)]
    obs, _ = collate_jev(rows)
    model.eval()
    with torch.no_grad():
        out = model(obs)
    assert tuple(out.raw_logits.shape) == (7, 6)
    assert bool(torch.isfinite(out.raw_logits).all())


# ------------------------------------------------------------------ M0-8
def test_m0_8_six_slot_semantics_end_to_end(train_pt) -> None:
    from python_jev.training.train import soft_target_policy_loss

    p, lab = train_pt, train_pt["labels_row_major"]
    for key in ("p_target", "q_valid", "q_values"):
        assert lab[key].shape[1] == 6, key
    assert p["legal"].shape[1] == 6
    sums = lab["p_target"].sum(dim=-1)
    assert torch.allclose(sums, torch.ones_like(sums), atol=1e-5)
    assert bool((lab["p_target"][~lab["q_valid"]] == 0.0).all())
    rows = [{
        "actor": p["actor"][s], "tokens": p["tokens"][s],
        "token_pad": p["token_pad"][s], "hex": p["hex"][s],
        "mission": p["mission_variant"]["ATTACK"][s], "global": p["global"][s],
        "class_idx": p["class_idx"][s], "legal": p["legal"][s],
        "q": torch.nan_to_num(lab["q_values"][s * 7], nan=0.0),
        "q_valid": lab["q_valid"][s * 7], "p_target": lab["p_target"][s * 7],
    } for s in range(16)]
    obs, targets = collate_jev(rows)
    torch.manual_seed(1)
    model = JevPolicyV0().eval()
    with torch.no_grad():
        out = model(obs)
        loss = soft_target_policy_loss(out.raw_logits, obs.legal_mask,
                                       targets["p_target"])
    assert tuple(out.probabilities.shape) == (16, 6)
    assert bool((out.probabilities[~obs.legal_mask] == 0.0).all())
    assert math.isfinite(float(loss))
