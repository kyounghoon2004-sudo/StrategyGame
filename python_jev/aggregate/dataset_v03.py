"""A1 dataset: jev-fullinfo-dataset-v0.3.0 = v0.2 TRAIN + dagger1 states.

Original samples are reused bit-identically (tensor equality asserted);
validation/test/generalization shards are byte-copied from v0.2. Only the
TRAIN state distribution changes. No reweighting in round 1.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import shutil

import torch

from python_jev.training.dataset_gen import records_to_tensors
from python_jev.training.policy_target import soft_targets_from_q, validate_targets

DATASET_V03_VERSION = "jev-fullinfo-dataset-v0.3.0"
DATASET_V02_VERSION = "jev-fullinfo-dataset-v0.2.0"
MODEL_V03_VERSION = "jev-policy-v0.3.0-fi-dagger1"
AGGREGATION_VERSION = "state-aggregation-v0.1.0"
V03_SPLITS = ("train", "validation", "test", "generalization_test")
DAGGER_SOURCE = "JEV_VISITED_DAGGER1"
V02_SOURCE = "JEV_FULLINFO_V02"


def labels_for_state(q_simple: list[float | None],
                     legal: list[bool]) -> tuple[list, list[bool], list[float]]:
    """Frozen v0.2 target pipeline: Q -> q_valid -> P_target. No changes."""
    q_values = [(float(v) if ok else None)
                for v, ok in zip(q_simple, legal)]
    q_valid = [bool(x) for x in legal]
    return q_values, q_valid, soft_targets_from_q(q_values, q_valid)


def pins_v03(v02_combined_hash: str, collection_ckpt_hash: str) -> dict:
    from python_jev.retrain.dataset_v2 import contract_pins_v2

    pins = contract_pins_v2(v02_combined_hash)
    pins.update({
        "dataset_version": DATASET_V03_VERSION,
        "source_dataset_version": DATASET_V02_VERSION,
        "aggregation_version": AGGREGATION_VERSION,
        "collection_checkpoint": "jev-policy-v0.2.0-fi/seed43",
        "collection_checkpoint_hash": collection_ckpt_hash,
    })
    return pins


def v02_combined_hash(v02_dir: str) -> str:
    from python_jev.retrain.dataset_v2 import V2_SPLITS, load_shard_v2

    h = hashlib.sha256()
    for s in V2_SPLITS:
        h.update(load_shard_v2(os.path.join(v02_dir, f"{s}.pt"),
                               verify=True)["shard_hash"].encode("utf-8"))
    return h.hexdigest()


# ------------------------------------------------------------ recovery gate
def recovery_signal(unique_rows: list[dict]) -> dict:
    """Part G: does the teacher demonstrably correct the policy's drift?"""
    from python_jev.constants import ACTION_SPACE

    agree = 0
    regrets: list[float] = []
    per_class: dict[str, dict] = {}
    for r in unique_rows:
        legal = [bool(x) for x in r["legal"]]
        q = r["teacher_q"]["SimpleAttackElseAdvancePolicy"]
        _qv, _qv_mask, p = labels_for_state(q, legal)
        top = max([a for a in range(6) if legal[a]], key=lambda a: q[a])
        sel = int(r["sel_new"])
        agree += (sel == top)
        best = max(q[a] for a in range(6) if legal[a])
        regrets.append(max(0.0, best - q[sel]))
        cell = per_class.setdefault(r["actor_class"], {
            "n": 0, "policy_skill": {}, "teacher_skill": {}, "p_sum": {},
            "p_n": {}, "regret_sum": 0.0})
        cell["n"] += 1
        ps, ts = ACTION_SPACE[r["actor_class"]][sel], ACTION_SPACE[r["actor_class"]][top]
        cell["policy_skill"][ps] = cell["policy_skill"].get(ps, 0) + 1
        cell["teacher_skill"][ts] = cell["teacher_skill"].get(ts, 0) + 1
        for a in range(6):
            sk = ACTION_SPACE[r["actor_class"]][a]
            if legal[a]:
                cell["p_sum"][sk] = cell["p_sum"].get(sk, 0.0) + p[a]
                cell["p_n"][sk] = cell["p_n"].get(sk, 0) + 1
        cell["regret_sum"] += regrets[-1]
    n = len(unique_rows)
    for cell in per_class.values():
        cell["mean_p_target"] = {k: cell["p_sum"][k] / cell["p_n"][k]
                                 for k in cell["p_sum"]}
        cell["mean_regret_current"] = cell["regret_sum"] / cell["n"]
        del cell["p_sum"], cell["p_n"], cell["regret_sum"]

    def freq(cell_name: str, skill: str, which: str) -> float:
        cell = per_class.get(cell_name, {"n": 0, which: {}})
        return cell[which].get(skill, 0) / max(1, cell["n"])

    scout = per_class.get("SCOUT", {"n": 0})
    spot = {
        "SCOUT_EVADE": {"policy": freq("SCOUT", "EVADE", "policy_skill"),
                        "teacher": freq("SCOUT", "EVADE", "teacher_skill")},
        "SCOUT_RECON_ADVANCE": {"policy": freq("SCOUT", "RECON_ADVANCE", "policy_skill"),
                                "teacher": freq("SCOUT", "RECON_ADVANCE", "teacher_skill")},
        "ARCHER_KITE": {"policy": freq("ARCHER", "KITE", "policy_skill"),
                        "teacher": freq("ARCHER", "KITE", "teacher_skill")},
        "ARCHER_FIRE": {"policy": freq("ARCHER", "FIRE", "policy_skill"),
                        "teacher": freq("ARCHER", "FIRE", "teacher_skill")},
        "ARCHER_REPOSITION_RANGE": {"policy": freq("ARCHER", "REPOSITION_RANGE", "policy_skill"),
                                    "teacher": freq("ARCHER", "REPOSITION_RANGE", "teacher_skill")},
        "CAVALRY_FLANK": {"policy": freq("CAVALRY", "FLANK", "policy_skill"),
                          "teacher": freq("CAVALRY", "FLANK", "teacher_skill")},
        "CAVALRY_ATTACK": {"policy": freq("CAVALRY", "ATTACK", "policy_skill"),
                           "teacher": freq("CAVALRY", "ATTACK", "teacher_skill")},
        "CAVALRY_ADVANCE": {"policy": freq("CAVALRY", "ADVANCE", "policy_skill"),
                            "teacher": freq("CAVALRY", "ADVANCE", "teacher_skill")},
    }
    agreement = agree / max(1, n)
    recon_gap = (spot["SCOUT_RECON_ADVANCE"]["teacher"]
                 - spot["SCOUT_RECON_ADVANCE"]["policy"])
    passed = bool(agreement < 0.90 and scout.get("n", 0) > 100 and recon_gap > 0.30)
    return {"n": n, "top_agreement": agreement,
            "mean_regret_current": sum(regrets) / max(1, n),
            "per_class": per_class, "spotlight": spot,
            "scout_states": scout.get("n", 0), "passed": passed}


# ------------------------------------------------------------ validation
PROV_BASE_KEYS = ("scenario_id", "scenario_seed", "scenario_family", "scenario_ood",
                  "mission_type", "ratio_group", "formation", "spacing", "profile",
                  "split", "actor_id", "actor_class", "acting_side", "turn",
                  "decision_index", "state_hash", "continuation_policy",
                  "horizon_decisions")
PROV_EXTRA_KEYS = ("source", "visit_count", "trajectory_id", "trajectory_index",
                   "collection_ckpt")


def validate_record_v03(record: dict, expected_pins: dict | None = None,
                        dataset_version: str = DATASET_V03_VERSION,
                        allowed_sources: tuple[str, ...] | None = None) -> list[str]:
    problems: list[str] = []
    if record.get("dataset_version") != dataset_version:
        problems.append(f"dataset_version must be {dataset_version}")
    if record.get("full_information_only") is not True:
        problems.append("full_information_only must be true")
    from python_jev.dataset.schema import FULL_INFO_PROFILES

    if record.get("profile") not in FULL_INFO_PROFILES:
        problems.append(f"forbidden profile: {record.get('profile')!r}")
    if record.get("split") not in V03_SPLITS:
        problems.append(f"bad split: {record.get('split')!r}")
    obs = record.get("observation", {})
    dims = {"actor_features": 67, "tokens": (24, 37), "hex_patch": (91, 33),
            "mission_features": 46, "global_features": 31}
    for key, dim in dims.items():
        v = obs.get(key)
        flat = [x for row in (v if isinstance(dim, tuple) else [v]) for x in (row or [])] \
            if v is not None else None
        want = (dim[0] * dim[1]) if isinstance(dim, tuple) else dim
        if (len(flat) if flat is not None else -1) != want:
            problems.append(f"observation.{key} wrong size")
        elif any(not isinstance(x, (int, float)) or not math.isfinite(x) for x in flat):
            problems.append(f"observation.{key} non-finite")
    if len(obs.get("token_padding_mask", [])) != 24:
        problems.append("token_padding_mask must have 24 bits")
    if obs.get("acting_class_idx") not in (0, 1, 2, 3, 4):
        problems.append("acting_class_idx must be in [0,5)")
    legal = record.get("legal_mask", [])
    q_valid = record.get("q_valid_mask", [])
    q_values = record.get("q_values", [])
    if len(legal) != 6 or len(q_valid) != 6 or len(q_values) != 6:
        problems.append("legal/q_valid/q_values must all have 6 entries")
        return problems
    if [bool(x) for x in q_valid] != [bool(x) for x in legal]:
        problems.append("q_valid_mask must equal legal_mask")
    if not any(bool(x) for x in legal):
        problems.append("record must keep >= 1 legal branch")
    for s in range(6):
        qv = q_values[s]
        if q_valid[s]:
            if not isinstance(qv, (int, float)) or not math.isfinite(qv):
                problems.append(f"q_values[{s}] must be finite")
        elif qv is not None:
            problems.append(f"q_values[{s}] must be None")
    problems.extend(
        f"p_target: {p}" for p in validate_targets(record.get("p_target", []),
                                                   [bool(x) for x in q_valid]))
    for k in ("source", "visit_count", "trajectory_id", "trajectory_index",
              "collection_ckpt"):
        if record.get(k) in (None, ""):
            problems.append(f"missing aggregation provenance: {k}")
    if record.get("source") not in (allowed_sources or (V02_SOURCE, DAGGER_SOURCE)):
        problems.append(f"bad source: {record.get('source')!r}")
    cv = record.get("contract_versions", {})
    if expected_pins is not None:
        for k, want in expected_pins.items():
            if cv.get(k) != want:
                problems.append(f"contract pin mismatch: {k}")
    else:
        for k in ("legal_mask_version", "skill_preflight_version",
                  "value_target_version", "policy_target_version",
                  "aggregation_version", "collection_checkpoint_hash"):
            if k not in cv:
                problems.append(f"contract_versions missing: {k}")
    return problems


# ------------------------------------------------------------ shard I/O
def provenance_of_v03(records: list[dict]) -> list[dict]:
    return [{k: r[k] for k in PROV_BASE_KEYS + PROV_EXTRA_KEYS} for r in records]


def shard_hash_v03(tensors: dict[str, torch.Tensor], provenance: list[dict]) -> str:
    from python_jev.training.dataset_gen import shard_hash

    return shard_hash(tensors, provenance)


def save_shard_v03(path: str, split: str, records: list[dict], pins: dict,
                   dataset_version: str = DATASET_V03_VERSION) -> dict:
    from python_jev.training.dataset_gen import dataset_config

    tensors = records_to_tensors(records)
    prov = provenance_of_v03(records)
    digest = shard_hash_v03(tensors, prov)
    config = dataset_config()
    config["dataset_version"] = dataset_version
    payload = {"dataset_version": dataset_version, "split": split,
               "n_records": len(records), "config": config,
               "contract_versions": dict(pins), "tensors": tensors,
               "provenance": prov, "shard_hash": digest}
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    torch.save(payload, path)
    return {"path": path, "split": split, "records": len(records),
            "shard_hash": digest}


def load_shard_v03(path: str, verify: bool = True,
                   dataset_version: str = DATASET_V03_VERSION) -> dict:
    payload = torch.load(path, map_location="cpu", weights_only=False)
    if payload.get("dataset_version") != dataset_version:
        raise ValueError(f"{path}: dataset_version {payload.get('dataset_version')!r}")
    if verify:
        digest = shard_hash_v03(payload["tensors"], payload["provenance"])
        if digest != payload.get("shard_hash"):
            raise ValueError(f"{path}: v0.3 shard hash mismatch")
    return payload


__all__ = [
    "AGGREGATION_VERSION",
    "DAGGER_SOURCE",
    "DATASET_V02_VERSION",
    "DATASET_V03_VERSION",
    "MODEL_V03_VERSION",
    "PROV_BASE_KEYS",
    "PROV_EXTRA_KEYS",
    "V02_SOURCE",
    "V03_SPLITS",
    "labels_for_state",
    "load_shard_v03",
    "pins_v03",
    "recovery_signal",
    "save_shard_v03",
    "shard_hash_v03",
    "v02_combined_hash",
    "validate_record_v03",
]
