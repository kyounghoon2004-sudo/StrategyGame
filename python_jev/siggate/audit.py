"""Gate audit: per-arm retention, correction mass, distributions (Parts C-D)."""

from __future__ import annotations

import json
import os
from collections import Counter

from python_jev.constants import ACTION_SPACE


def depth_bucket(decision_index: int) -> str:
    if decision_index <= 4:
        return "0-4"
    if decision_index <= 9:
        return "5-9"
    if decision_index <= 19:
        return "10-19"
    return "20+"


def gate_stats(manifests: dict, signals: list[dict], out_dir: str) -> dict:
    """Per-arm audit from v0.5-train provenance + frozen signals."""
    from python_jev.aggregate.dataset_v05 import load_shard_v05
    from python_jev.siggate.gates import V05_TRAIN

    os.makedirs(out_dir, exist_ok=True)
    shard = load_shard_v05(V05_TRAIN, verify=True)
    prov = shard["provenance"]
    pool_regret = sum(s["driver_regret"] for s in signals)
    pool_mean = [s for s in signals if 0.01 <= s["driver_regret"] < 0.025]
    pool_large = [s for s in signals if s["driver_regret"] >= 0.025]
    out: dict = {}
    for arm, spec in manifests.items():
        keep = spec["retained_positions"]
        kept = [signals[j] for j in keep]
        kset = set(keep)
        prows = [prov[signals[j]["train_idx"]] for j in keep]
        cls = Counter(p["actor_class"] for p in prows)
        mis = Counter(p["mission_type"] for p in prows)
        prf = Counter(p["profile"] for p in prows)
        dep = Counter(depth_bucket(p["decision_index"]) for p in prows)
        tskill = Counter(ACTION_SPACE[p["actor_class"]][signals[j]["teacher_top"]]
                         for j, p in zip(keep, prows))
        dskill = Counter(ACTION_SPACE[p["actor_class"]][signals[j]["driver_sel"]]
                         for j, p in zip(keep, prows))
        scout = [(j, p) for j, p in zip(keep, prows) if p["actor_class"] == "SCOUT"]
        kept_regret = sum(s["driver_regret"] for s in kept)
        # tie/value buckets on retained
        tie = sum(1 for s in kept if s["teacher_margin"] == 0.0)
        near = sum(1 for s in kept if s["driver_regret"] < 0.0025)
        mean = sum(1 for s in kept if 0.01 <= s["driver_regret"] < 0.025)
        large = sum(1 for s in kept if s["driver_regret"] >= 0.025)
        stat = {
            "arm": arm,
            "gate": spec["gate"],
            "d3_pool": len(signals),
            "retained": len(keep),
            "excluded": len(signals) - len(keep),
            "frac_retained": len(keep) / len(signals),
            "correction_retained": kept_regret,
            "correction_total": pool_regret,
            "correction_frac": kept_regret / pool_regret if pool_regret else 0.0,
            "correction_density": kept_regret / len(keep) if keep else 0.0,
            "meaningful_retained": mean,
            "meaningful_total": len(pool_mean),
            "large_retained": large,
            "large_total": len(pool_large),
            "tie_retained": tie,
            "near_tie_retained": near,
            "class_dist": dict(cls),
            "mission_dist": dict(mis),
            "profile_dist": dict(prf),
            "depth_dist": dict(dep),
            "teacher_skill_dist": dict(tskill),
            "driver_skill_dist": dict(dskill),
            "scout_retained": len(scout),
            "scout_teacher_evade": sum(
                1 for j, p in scout if ACTION_SPACE["SCOUT"][signals[j]["teacher_top"]] == "EVADE"),
            "scout_driver_evade": sum(
                1 for j, p in scout if ACTION_SPACE["SCOUT"][signals[j]["driver_sel"]] == "EVADE"),
            "scout_teacher_recon": sum(
                1 for j, p in scout if ACTION_SPACE["SCOUT"][signals[j]["teacher_top"]] == "RECON_ADVANCE"),
            "scout_driver_recon": sum(
                1 for j, p in scout if ACTION_SPACE["SCOUT"][signals[j]["driver_sel"]] == "RECON_ADVANCE"),
            "scout_shadow_either": sum(
                1 for j, p in scout
                if "SHADOW" in (ACTION_SPACE["SCOUT"][signals[j]["teacher_top"]],
                                ACTION_SPACE["SCOUT"][signals[j]["driver_sel"]])),
            "excluded_positions_sorted": sorted(set(range(len(signals))) - kset)[:8],
        }
        out[arm] = stat
        with open(os.path.join(out_dir, f"{arm}.json"), "w", encoding="utf-8") as f:
            json.dump(stat, f, indent=1, sort_keys=True)
    with open(os.path.join(out_dir, "all_arms.json"), "w", encoding="utf-8") as f:
        json.dump(out, f, indent=1, sort_keys=True)
    return out


__all__ = ["depth_bucket", "gate_stats"]
