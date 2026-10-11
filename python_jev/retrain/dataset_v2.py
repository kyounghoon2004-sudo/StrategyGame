"""R1 dataset correction I/O: jev-fullinfo-dataset-v0.2.0.

Rebuilds the T0 corpus under SkillPreflightV0 /
observation-safe-skill-mask-v0.2.0 WITHOUT mutating v0.1.0:

- branches that stay legal: reuse the STORED Q bit-identically;
- branches that turn illegal: removed from q_valid_mask + PolicyTarget
  normalization (Q=None, never a fake low value);
- newly legal branches (F0 audit: 1,139 SCOUT/SHADOW): deterministic
  single-branch counterfactual rollout with the SAME frozen ValueTargetV0,
  SimpleAttackElseAdvance continuation, horizon 8, ruleset, skill contract;
- P_target recomputed with the UNCHANGED policy-target-v0.1.0 transform.

The replay/correction driver lives in rebuild_v2.py; this module holds
versions, pins, shard I/O, record validation, the single-branch rollout,
and extended coverage statistics.
"""

from __future__ import annotations

import hashlib
import json
import math
import os

import torch

from python_jev.constants import ACTION_SPACE, LEARNED_CLASSES
from python_jev.training.dataset_gen import (
    TENSOR_KEYS,
    records_to_tensors,
)
from python_jev.training.policy_target import validate_targets

DATASET_V2_VERSION = "jev-fullinfo-dataset-v0.2.0"
DATASET_V1_VERSION = "jev-fullinfo-dataset-v0.1.0"
MODEL_V2_VERSION = "jev-policy-v0.2.0-fi"
RECONSTRUCTION_VERSION = "jev-dataset-correction-v0.1.0"
V2_SPLITS = ("train", "validation", "test", "generalization_test")

# Reused-Q audit: randomized subset of kept branches, re-simulated and
# compared against the stored Q. Deterministic seed; absolute tolerance.
REUSED_Q_AUDIT_SEED = 20260920
REUSED_Q_AUDIT_SAMPLE = 800
REUSED_Q_AUDIT_MIN_KEPT = 500
Q_AUDIT_ABS_TOL = 1e-6


# ------------------------------------------------------------ version pins
def rollout_config_hash() -> str:
    """Stable hash of the frozen v0 rollout configuration (seed-independent).

    The per-scenario seed is provenance, not config: it varies by design.
    """
    from python_sim.rollout.config import (
        CONTINUATION_POLICY_VERSION,
        ROLLOUT_CONFIG_VERSION,
    )
    from python_sim.rollout.engine import ROLLOUT_ENGINE_VERSION

    payload = {
        "rollout_engine_version": ROLLOUT_ENGINE_VERSION,
        "rollout_config_version": ROLLOUT_CONFIG_VERSION,
        "continuation_policy_version": CONTINUATION_POLICY_VERSION,
        "continuation_policy": "SimpleAttackElseAdvancePolicy",
        "red_policy": "SimpleAttackElseAdvancePolicy",
        "horizon_decisions": 8,
        "max_turns": 24,
    }
    return hashlib.sha256(
        json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()


def contract_pins_v2(source_dataset_hash: str) -> dict:
    """Full v0.2 contract pins: every frozen T0 pin plus the new mask,
    preflight, value-target hash, rollout hash, and source-dataset link."""
    from python_jev.training.dataset_gen import contract_pins
    from python_sim.rollout.engine import ROLLOUT_ENGINE_VERSION
    from python_sim.rollout.value_target import (
        VALUE_TARGET_VERSION,
    )
    from python_sim.rollout.value_target import content_hash as vt_hash
    from python_sim.skills import candidates as cand
    from python_sim.skills.preflight import (
        LEGAL_MASK_V2_VERSION,
        SKILL_PREFLIGHT_VERSION,
        preflight_content_hash,
    )

    pins = contract_pins()
    pins.update({
        "dataset_version": DATASET_V2_VERSION,
        "source_dataset_version": DATASET_V1_VERSION,
        "source_dataset_hash": source_dataset_hash,
        "legal_mask_version": LEGAL_MASK_V2_VERSION,
        "legal_mask_hash": preflight_content_hash(),
        "skill_preflight_version": SKILL_PREFLIGHT_VERSION,
        "skill_preflight_hash": preflight_content_hash(),
        "skill_candidates_version": cand.CANDIDATES_VERSION,
        "value_target_version": VALUE_TARGET_VERSION,
        "value_target_hash": vt_hash(),
        "rollout_engine_version": ROLLOUT_ENGINE_VERSION,
        "rollout_config_hash": rollout_config_hash(),
        "reconstruction_version": RECONSTRUCTION_VERSION,
    })
    return pins


def source_dataset_hash(v01_shard_paths: dict[str, str]) -> str:
    """Combined hash of the v0.1 source shards (fixed split order)."""
    from python_jev.training.dataset_gen import load_shard

    h = hashlib.sha256()
    for split in V2_SPLITS:
        payload = load_shard(v01_shard_paths[split], verify=True)
        h.update(payload["shard_hash"].encode("utf-8"))
    return h.hexdigest()


# ------------------------------------------------------------ shard I/O
def shard_hash_v2(tensors: dict[str, torch.Tensor], provenance: list[dict]) -> str:
    from python_jev.training.dataset_gen import shard_hash

    return shard_hash(tensors, provenance)


def save_shard_v2(
    path: str,
    split: str,
    records: list[dict],
    pins: dict,
    source: dict,
) -> dict:
    """Save one v0.2 shard (tensor format identical to v0.1)."""
    from python_jev.training.dataset_gen import dataset_config, provenance_of

    tensors = records_to_tensors(records)
    prov = provenance_of(records)
    for p in prov:
        p["dataset_version"] = DATASET_V2_VERSION
    digest = shard_hash_v2(tensors, prov)
    config = dataset_config()
    config["dataset_version"] = DATASET_V2_VERSION
    payload = {
        "dataset_version": DATASET_V2_VERSION,
        "split": split,
        "n_records": len(records),
        "config": config,
        "contract_versions": dict(pins),
        "source_dataset": dict(source),
        "tensors": tensors,
        "provenance": prov,
        "shard_hash": digest,
    }
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    torch.save(payload, path)
    return {"path": path, "split": split, "records": len(records), "shard_hash": digest}


def load_shard_v2(path: str, verify: bool = True) -> dict:
    payload = torch.load(path, map_location="cpu", weights_only=False)
    if payload.get("dataset_version") != DATASET_V2_VERSION:
        raise ValueError(f"{path}: dataset_version {payload.get('dataset_version')!r}")
    if verify:
        digest = shard_hash_v2(payload["tensors"], payload["provenance"])
        if digest != payload.get("shard_hash"):
            raise ValueError(f"{path}: v0.2 shard hash mismatch (corrupt or tampered)")
    return payload


# ------------------------------------------------------------ validation
def validate_record_v2(record: dict, expected_pins: dict | None = None) -> list[str]:
    """Full v0.2 record validation gate. Empty list == valid."""
    problems: list[str] = []
    if record.get("dataset_version") != DATASET_V2_VERSION:
        problems.append(f"dataset_version must be {DATASET_V2_VERSION}")
    if record.get("full_information_only") is not True:
        problems.append("full_information_only must be true")
    from python_jev.dataset.schema import FULL_INFO_PROFILES

    profile = record.get("profile")
    if profile not in FULL_INFO_PROFILES:
        problems.append(f"partial-information profile forbidden: {profile!r}")
    if record.get("split") not in V2_SPLITS:
        problems.append(f"bad split: {record.get('split')!r}")
    for key in ("scenario_id", "scenario_seed", "scenario_family", "mission_type",
                "actor_id", "actor_class", "acting_side"):
        if record.get(key) in (None, ""):
            problems.append(f"missing provenance: {key}")

    obs = record.get("observation", {})
    dims = {"actor_features": 67, "tokens": (24, 37), "hex_patch": (91, 33),
            "mission_features": 46, "global_features": 31}
    for key, dim in dims.items():
        v = obs.get(key)
        flat = [x for row in (v if isinstance(dim, tuple) else [v]) for x in (row or [])] \
            if v is not None else None
        n = len(flat) if flat is not None else -1
        want = (dim[0] * dim[1]) if isinstance(dim, tuple) else dim
        if n != want:
            problems.append(f"observation.{key} has {n} values, want {want}")
        elif any(not isinstance(x, (int, float)) or not math.isfinite(x) for x in flat):
            problems.append(f"observation.{key} has NaN/Inf/non-numeric")
    if len(obs.get("token_padding_mask", [])) != 24:
        problems.append("token_padding_mask must have 24 bits")
    if record.get("acting_class_idx", obs.get("acting_class_idx")) not in (0, 1, 2, 3, 4):
        problems.append("acting_class_idx must be in [0,5)")

    legal = record.get("legal_mask", [])
    q_valid = record.get("q_valid_mask", [])
    q_values = record.get("q_values", [])
    if len(legal) != 6 or len(q_valid) != 6 or len(q_values) != 6:
        problems.append("legal/q_valid/q_values must all have 6 entries")
        return problems
    if [bool(x) for x in q_valid] != [bool(x) for x in legal]:
        problems.append("full-info q_valid_mask must equal legal_mask")
    if not any(bool(x) for x in legal):
        problems.append("v0.2 record must keep >= 1 legal branch (else no target exists)")
    for s in range(6):
        qv = q_values[s]
        if q_valid[s]:
            if not isinstance(qv, (int, float)) or not math.isfinite(qv):
                problems.append(f"q_values[{s}] must be finite for a valid branch")
        elif qv is not None:
            problems.append(f"q_values[{s}] must be None for an invalid branch")
    problems.extend(
        f"p_target: {p}" for p in validate_targets(record.get("p_target", []), [bool(x) for x in q_valid])
    )
    cv = record.get("contract_versions", {})
    if expected_pins is not None:
        for k, want in expected_pins.items():
            if cv.get(k) != want:
                problems.append(f"contract pin mismatch: {k}")
    else:
        for k in ("sim_version", "ruleset_version", "observation_layout_version",
                  "skill_contract_version", "rollout_engine_version", "value_target_version",
                  "value_target_hash", "policy_target_version", "legal_mask_version",
                  "skill_preflight_version", "terminal_version", "mission_progress_version",
                  "objective_progress_version", "branch_snapshot_version",
                  "source_dataset_version", "source_dataset_hash"):
            if k not in cv:
                problems.append(f"contract_versions missing: {k}")
    return problems


# ------------------------------------------------------------ single-branch rollout
def rollout_branch_q(battle, actor_id: str, ctx, skill_slot: int, scenario_seed: int) -> float:
    """Deterministic Q for ONE branch: clone -> skill -> Simple continuation.

    Semantically identical to one branch of CounterfactualEngine.evaluate
    with (SimpleAttackElseAdvancePolicy, horizon 8, seed=scenario_seed):
    same branch-start snapshot capture, same skill executor, same
    continuation driver, same ValueTargetV0 derivation. Only the missing
    branch is simulated — kept branches reuse stored Q.
    """
    from python_sim.rollout import engine as eng_mod
    from python_sim.rollout.branch_snapshot import capture_branch_start
    from python_sim.rollout.config import RolloutConfig
    from python_sim.rollout.outcome import raw_outcome_vector_v2
    from python_sim.skills.registry import execute_skill

    faction = eng_mod._faction_of(battle, actor_id)
    cls = eng_mod._class_name(battle, actor_id)
    snapshot = capture_branch_start(battle, faction)
    branch_battle = battle.clone()
    execute_skill(branch_battle, actor_id, cls, int(skill_slot), ctx)
    config = RolloutConfig(
        continuation_policy="SimpleAttackElseAdvancePolicy",
        horizon_decisions=8,
        seed=int(scenario_seed),
    )
    outcome = eng_mod._run_continuation(
        branch_battle, actor_id, config, snapshot, faction, True)
    return float(outcome["scalar_Q"])


# ------------------------------------------------------------ extended coverage
def extended_action_stats(shard_path: str, loader=None) -> dict:
    """Per-(class, slot) stats incl. median Q and Q std (v0.2 coverage)."""
    from python_jev.training.dataset_gen import load_shard

    load = loader or load_shard
    payload = load(shard_path, verify=True)
    t = payload["tensors"]
    legal = t["legal"].bool()
    q_valid = t["q_valid"].bool()
    q = t["q"].float()
    p = t["p_target"].float()
    cls = t["class_idx"].long()

    per_action: dict[str, dict] = {}
    for ci, cname in enumerate(LEARNED_CLASSES):
        rows = (cls == ci).nonzero(as_tuple=True)[0]
        slots = ACTION_SPACE[cname]
        for s in range(6):
            key = f"{cname}:{s}:{slots[s]}"
            is_legal = legal[rows, s] if len(rows) else torch.zeros(0, dtype=torch.bool)
            n_legal = int(is_legal.sum())
            entry: dict = {"skill": slots[s], "legal_count": n_legal,
                           "best_count": 0, "mean_p_target": None,
                           "mean_q": None, "median_q": None, "q_std": None}
            if n_legal:
                qv = q[rows[is_legal], s]
                entry["mean_p_target"] = float(p[rows[is_legal], s].mean())
                entry["mean_q"] = float(qv.mean())
                entry["median_q"] = float(qv.median())
                entry["q_std"] = float(qv.std()) if n_legal > 1 else 0.0
            per_action[key] = entry
        if len(rows):
            qm = torch.where(q_valid[rows], q[rows],
                             torch.full_like(q[rows], float("-inf")))
            best = qm.argmax(dim=-1)
            for s in range(6):
                key = f"{cname}:{s}:{ACTION_SPACE[cname][s]}"
                per_action[key]["best_count"] = int((best == s).sum())
    return {"split": payload["split"], "records": int(t["actor"].shape[0]),
            "per_action": per_action}


def coverage_flags(per_action: dict, min_legal: int = 50,
                   min_mean_p: float = 0.05) -> dict:
    """Dead / rare / dominant action detection (T0-7 thresholds)."""
    dead, rare = [], []
    for key, e in per_action.items():
        if e["legal_count"] == 0:
            dead.append(key)
        elif e["legal_count"] < min_legal or (e["mean_p_target"] or 0.0) < min_mean_p:
            rare.append(key)
    concentrated: dict[str, float] = {}
    for cname in LEARNED_CLASSES:
        keys = [k for k in per_action if k.startswith(cname + ":")]
        total_best = sum(per_action[k]["best_count"] for k in keys)
        if total_best:
            top = max(per_action[k]["best_count"] for k in keys)
            concentrated[cname] = top / total_best
    dominant = {c: v for c, v in concentrated.items() if v > 0.9}
    return {"dead_actions": dead, "rare_actions": rare,
            "best_concentration": concentrated, "dominant_actions": dominant}


__all__ = [
    "DATASET_V1_VERSION",
    "DATASET_V2_VERSION",
    "MODEL_V2_VERSION",
    "Q_AUDIT_ABS_TOL",
    "RECONSTRUCTION_VERSION",
    "REUSED_Q_AUDIT_MIN_KEPT",
    "REUSED_Q_AUDIT_SAMPLE",
    "REUSED_Q_AUDIT_SEED",
    "V2_SPLITS",
    "contract_pins_v2",
    "coverage_flags",
    "extended_action_stats",
    "load_shard_v2",
    "rollout_config_hash",
    "rollout_branch_q",
    "save_shard_v2",
    "shard_hash_v2",
    "source_dataset_hash",
    "validate_record_v2",
]
