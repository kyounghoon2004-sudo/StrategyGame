"""Part G — epsilon-metric saturation audit (epsilon-audit-v0.1.0).

q_epsilon=0.25 (epsilon-optimal-v0.1.0, frozen) dwarfs realized Q gaps and
saturates at ~0.997 for trained AND untrained models. This audit keeps the
frozen metric untouched and measures candidate tighter thresholds for
trained-vs-untrained discrimination, grounded in the observed Q-gap
distribution. No new canonical epsilon is chosen here on looks alone.
"""

from __future__ import annotations

import json
import os

import torch
from torch.utils.data import DataLoader

EPSILON_AUDIT_VERSION = "epsilon-audit-v0.1.0"
CANDIDATE_EPSILONS = (0.005, 0.01, 0.02, 0.05)


def gather_eval_rows(model, shard_path: str, device, batch_size: int = 512,
                     dataset_cls=None) -> dict:
    from python_jev.training.data import JevFullInfoDataset, collate_jev
    from python_jev.training.evaluate import _gather_rows

    # R1 hook (additive): dataset_cls overrides the shard reader (v0.2 eval).
    ds = (dataset_cls or JevFullInfoDataset)(shard_path)
    loader = DataLoader(ds, batch_size=batch_size, shuffle=False, collate_fn=collate_jev)
    return _gather_rows(model, loader, device)


def epsilon_rates(rows: dict, epsilons=tuple([0.25, *CANDIDATE_EPSILONS])) -> dict:
    q_valid = rows["q_valid"].bool()
    q = rows["q"].float()
    sel = rows["sel"].long().clamp_min(0)
    q_masked = torch.where(q_valid, q, torch.full_like(q, float("-inf")))
    q_best = q_masked.amax(dim=-1)
    q_sel = q.gather(1, sel.unsqueeze(-1)).squeeze(-1)
    gap_closed = (q_best - q_sel).clamp_min(0.0)
    out = {}
    for eps in epsilons:
        out[str(eps)] = float(((q_sel >= q_best - eps).float()).mean())
    # Q-gap distribution grounding: best-vs-second-best among valid slots.
    gaps = []
    qv = q.clone()
    qv[~q_valid] = float("-inf")
    top2 = qv.topk(min(2, qv.shape[1]), dim=-1).values
    if top2.shape[1] == 2:
        gaps = (top2[:, 0] - top2[:, 1]).clamp_min(0.0)
    import statistics

    gl = sorted(float(x) for x in gaps) if len(gaps) else [0.0]
    out["q_gap_distribution"] = {
        "mean": sum(gl) / len(gl),
        "median": statistics.median(gl),
        "p90": gl[min(len(gl) - 1, int(0.90 * len(gl)))],
        "p99": gl[min(len(gl) - 1, int(0.99 * len(gl)))],
        "frac_gap_below_0.005": sum(1 for x in gl if x < 0.005) / len(gl),
        "frac_gap_below_0.05": sum(1 for x in gl if x < 0.05) / len(gl),
    }
    out["mean_regret"] = float(gap_closed.mean())
    out["samples"] = int(rows["raw"].shape[0])
    return out


def run_epsilon_audit(trained_model, untrained_model, shard_path: str,
                      device, out_path: str) -> dict:
    rows_t = gather_eval_rows(trained_model, shard_path, device)
    rows_u = gather_eval_rows(untrained_model, shard_path, device)
    report = {
        "audit_version": EPSILON_AUDIT_VERSION,
        "frozen_metric": {"version": "epsilon-optimal-v0.1.0", "q_epsilon": 0.25},
        "shard": os.path.abspath(shard_path),
        "trained": epsilon_rates(rows_t),
        "untrained": epsilon_rates(rows_u),
    }
    report["discrimination"] = {
        eps: report["trained"][eps] - report["untrained"][eps]
        for eps in ("0.25", "0.005", "0.01", "0.02", "0.05")
    }
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, "w") as f:
        json.dump(report, f, indent=1, sort_keys=True)
    return report


__all__ = ["CANDIDATE_EPSILONS", "EPSILON_AUDIT_VERSION", "epsilon_rates",
           "gather_eval_rows", "run_epsilon_audit"]
