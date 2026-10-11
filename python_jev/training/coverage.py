"""Dataset coverage + target diagnostics for jev-fullinfo-dataset-v0.1.0."""

from __future__ import annotations

import math
from collections import Counter

import torch

from python_jev.constants import ACTION_SPACE, LEARNED_CLASSES
from python_jev.dataset.schema import FULL_INFO_PROFILES
from python_jev.training.dataset_gen import load_shard

CLASS_NAMES = list(LEARNED_CLASSES)


def analyze_shard(shard_path: str, loader=None) -> dict:
    # R1 hook (additive): loader overrides the shard reader (v0.2 coverage).
    payload = (loader or load_shard)(shard_path, verify=True)
    t = payload["tensors"]
    prov = payload["provenance"]
    n = t["actor"].shape[0]
    legal = t["legal"].bool()
    q_valid = t["q_valid"].bool()
    q = t["q"].float()
    p = t["p_target"].float()
    cls = t["class_idx"].long()

    qv = q[q_valid]
    report: dict = {
        "split": payload["split"],
        "records": n,
        "shard_hash": payload["shard_hash"],
        "scenarios": len({r["scenario_id"] for r in prov}),
        "class_counts": {c: int((cls == i).sum()) for i, c in enumerate(CLASS_NAMES)},
        "profile_counts": dict(Counter(r["profile"] for r in prov)),
        "mission_counts": dict(Counter(r["mission_type"] for r in prov)),
        "family_counts": dict(Counter(r["scenario_family"] for r in prov)),
        "ratio_counts": dict(Counter(r["ratio_group"] for r in prov)),
        "turn_histogram": dict(sorted(Counter(r["turn"] for r in prov).items())),
        "q_valid_total": int(q_valid.sum()),
        "q_min": float(qv.min()),
        "q_max": float(qv.max()),
        "q_mean": float(qv.mean()),
        "q_std": float(qv.std()),
        "target_entropy_mean": float(-(p * torch.where(
            p > 0, p.log(), torch.zeros_like(p))).sum(-1).mean()),
        "legal_per_state_mean": float(legal.sum(-1).float().mean()),
    }

    # per-(class, slot) coverage over the 30 identities
    per_action = {}
    for ci, cname in enumerate(CLASS_NAMES):
        rows = (cls == ci).nonzero(as_tuple=True)[0]
        slots = ACTION_SPACE[cname]
        for s in range(6):
            is_legal = legal[rows, s] if len(rows) else torch.zeros(0, dtype=torch.bool)
            n_legal = int(is_legal.sum())
            entry = {"skill": slots[s], "legal_count": n_legal, "best_count": 0,
                     "mean_p_target": None, "mean_q": None}
            if n_legal:
                entry["mean_p_target"] = float(p[rows[is_legal], s].mean())
                entry["mean_q"] = float(q[rows[is_legal], s].mean())
            per_action[f"{cname}:{s}:{slots[s]}"] = entry
        if len(rows):
            qm = torch.where(q_valid[rows], q[rows],
                             torch.full_like(q[rows], float("-inf")))
            best = qm.argmax(dim=-1)
            for s in range(6):
                key = f"{cname}:{s}:{slots[s]}"
                per_action[key]["best_count"] = int((best == s).sum())
    report["per_action"] = per_action

    # collapse detection: best-slot concentration per class
    for ci, cname in enumerate(CLASS_NAMES):
        rows = int((cls == ci).sum())
        if rows == 0:
            continue
        top = max(per_action[f"{cname}:{s}:{ACTION_SPACE[cname][s]}"]["best_count"]
                  for s in range(6))
        report.setdefault("best_concentration", {})[cname] = top / rows
    return report


def check_no_leakage(shard_paths: dict[str, str], loader=None) -> dict:
    """Scenario/family IDs must belong to exactly one split."""
    seen: dict[str, str] = {}
    dupes: list[dict] = []
    per_split: dict[str, list[str]] = {}
    for split, path in shard_paths.items():
        payload = (loader or load_shard)(path, verify=True)
        ids = sorted({r["scenario_id"] for r in payload["provenance"]})
        per_split[split] = ids
        for sid in ids:
            if sid in seen:
                dupes.append({"scenario_id": sid, "splits": sorted({seen[sid], split})})
            else:
                seen[sid] = split
    return {"splits": {s: len(v) for s, v in per_split.items()},
            "total_unique": len(seen), "leaked": dupes,
            "leak_count": len(dupes)}


def check_full_info_only(shard_paths: dict[str, str], loader=None) -> dict:
    bad: list[dict] = []
    total = 0
    for split, path in shard_paths.items():
        payload = (loader or load_shard)(path, verify=True)
        if payload["config"].get("full_information_only") is not True:
            bad.append({"split": split, "issue": "shard config flag not true"})
        for r in payload["provenance"]:
            total += 1
            if r["profile"] not in FULL_INFO_PROFILES:
                bad.append({"split": split, "profile": r["profile"]})
    return {"records": total, "partial_info_records": len(bad), "issues": bad[:10]}


__all__ = ["CLASS_NAMES", "analyze_shard", "check_full_info_only", "check_no_leakage"]
