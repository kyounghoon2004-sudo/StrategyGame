"""M1 gates — jev_mission_train_v1 regression (mission-conditioned training).

M1-1  All five seed checkpoints exist and load into the unchanged arch.
M1-2  Six-slot semantics intact: 6 logits, illegal prob exactly 0 masked.
M1-3  Training shards carry non-default, non-constant mission blocks.
M1-4  Gate decision artifacts present; recorded checkpoint hashes match.
M1-5  v0.4/v0.5 reference checkpoints untouched (spot sizes).

Read-only: never trains, never writes checkpoints, never touches Godot.
"""

from __future__ import annotations

import hashlib
import json
import os
import sys

import pytest
import torch

from python_jev.constants import PATCH_NUM_CELLS
from python_jev.model import JevPolicyV0
from python_jev.observation import ObservationBatchV0
from python_jev.training.checkpoint import load_checkpoint

PROJ = os.path.abspath(os.path.join(os.path.dirname(__file__), os.pardir, os.pardir))
ART = os.path.join(PROJ, "artifacts", "jev_mission_train_v1")
SEEDS = (201, 202, 203, 204, 205)

pytestmark = pytest.mark.skipif(
    not os.path.isdir(ART), reason="jev_mission_train_v1 artifacts not present")


def _sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _load_json(name: str):
    with open(os.path.join(ART, name), encoding="utf-8") as f:
        return json.load(f)


# ------------------------------------------------------------------ M1-1
def test_m1_1_checkpoints_load_into_unchanged_arch() -> None:
    ref = JevPolicyV0()
    n_ref = sum(p.numel() for p in ref.parameters())
    for seed in SEEDS:
        path = os.path.join(ART, "checkpoints", f"seed{seed}.pt")
        assert os.path.exists(path), path
        model = JevPolicyV0()
        meta = load_checkpoint(path, model)
        assert sum(p.numel() for p in model.parameters()) == n_ref
        assert meta["seed"] == seed
        assert meta["dataset_version"] == "jev-mission-data-v1.0.0"


# ------------------------------------------------------------------ M1-2
def test_m1_2_six_slots_masked_forward() -> None:
    sys.path.insert(0, ART)
    try:
        from mission_data import load_shard_mission  # noqa: E402
    finally:
        sys.path.remove(ART)
    payload = load_shard_mission(os.path.join(ART, "dataset", "validation.pt"),
                                 verify=True)
    t = payload["tensors"]
    model = JevPolicyV0().eval()
    load_checkpoint(os.path.join(ART, "checkpoints", "seed205.pt"), model)
    with torch.no_grad():
        for start in (0, 512, 1024, 1500):
            sl = slice(start, start + 64)
            obs = ObservationBatchV0(
                actor_features=t["actor"][sl], tokens=t["tokens"][sl],
                token_padding_mask=t["token_pad"][sl], hex_patch=t["hex"][sl],
                hex_padding_mask=torch.zeros(64, PATCH_NUM_CELLS, dtype=torch.bool),
                mission_features=t["mission"][sl], global_features=t["global"][sl],
                legal_mask=t["legal"][sl], acting_class_idx=t["class_idx"][sl],
                metadata={})
            out = model(obs)
            assert list(out.raw_logits.shape) == [64, 6]
            assert list(out.probabilities.shape) == [64, 6]
            masked_illegal = out.probabilities[~obs.legal_mask]
            assert float(masked_illegal.sum()) == 0.0
            assert bool((((out.probabilities.sum(-1) - 1.0).abs() < 1e-5)).all())


# ------------------------------------------------------------------ M1-3
def test_m1_3_mission_blocks_non_default() -> None:
    sys.path.insert(0, ART)
    try:
        from mission_data import load_shard_mission  # noqa: E402
    finally:
        sys.path.remove(ART)
    for name in ("train.pt", "validation.pt"):
        payload = load_shard_mission(os.path.join(ART, "dataset", name),
                                     verify=True)
        assert payload["dataset_version"] == "jev-mission-data-v1.0.0"
        m = payload["tensors"]["mission"].float()
        assert float(m.std()) > 1e-3
        # rows are not all copies of one default block
        assert int((m != m[0]).any(dim=-1).sum()) > len(m) // 2


# ------------------------------------------------------------------ M1-4
def test_m1_4_decision_artifacts_consistent() -> None:
    for name in ("TRAINING_MANIFEST.json", "PER_SEED_TRAINING.json",
                 "OFFLINE_EVALUATION.json", "MISSION_CONDITION_RESULTS.json",
                 "MISSION_ABLATION_RESULTS.json", "STRICT_SIGNAL_RESULTS.json",
                 "CLOSED_LOOP_RESULTS.json", "SEED_ROBUSTNESS.json",
                 "CHECKPOINT_SELECTION.json", "PRODUCTION_DECISION.json"):
        assert os.path.exists(os.path.join(ART, name)), name
    per_seed = _load_json("PER_SEED_TRAINING.json")
    for seed in SEEDS:
        entry = per_seed[str(seed)]
        assert _sha256(entry["checkpoint"]) == entry["checkpoint_sha256"]
    decision = _load_json("PRODUCTION_DECISION.json")
    assert decision["status"] in ("PASS", "PASS_WITH_WARNINGS", "FAIL", "BLOCKED")
    if decision["checkpoint"]:
        assert _sha256(decision["checkpoint"]) == decision["sha256"]
    selection = _load_json("CHECKPOINT_SELECTION.json")
    assert selection["rule_file"].endswith("SELECTION_RULE.md")
    assert os.path.exists(selection["rule_file"])


# ------------------------------------------------------------------ M1-5
def test_m1_5_reference_checkpoints_intact() -> None:
    refs = [
        ("artifacts/jev_dagger_v1/checkpoints/seed44.pt", 4078741),
        ("artifacts/jev_dagger_v2/checkpoints/seed44.pt", 4078997),
        ("artifacts/jev_training_v1/checkpoints/seed43.pt", 4078293),
    ]
    for rel, size in refs:
        path = os.path.join(PROJ, rel)
        assert os.path.exists(path), path
        assert os.path.getsize(path) == size, (rel, os.path.getsize(path))
