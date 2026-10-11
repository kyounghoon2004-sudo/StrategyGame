"""Offline benchmark for JevPolicyV0 (T0, Part E).

Metrics over held-out decision states with frozen six-way Q:
  soft-target CE, KL(P_target || P_model), strict top-1 agreement, top-2
  inclusion, epsilon-optimal accuracy, mean/median/p95 regret, illegal
  selection rate, policy entropy, Expected Calibration Error.

Epsilon-optimal (frozen): Q_selected >= Q_best - q_epsilon, q_epsilon = 0.25.
Calibration correctness = epsilon-optimal indicator; confidence = selected
probability. ECE bins = 15.
"""

from __future__ import annotations

import math

import torch
from torch.utils.data import DataLoader

from python_jev.constants import ALL_ILLEGAL_SLOT
from python_jev.training.data import JevFullInfoDataset, collate_jev

EPSILON_OPTIMAL_VERSION = "epsilon-optimal-v0.1.0"
Q_EPSILON = 0.25
ECE_BINS = 15


def _gather_rows(model, loader, device):
    """Per-row model outputs + labels for the whole loader (CPU tensors)."""
    model.eval()
    rows = {"raw": [], "prob": [], "sel": [], "sel_prob": [],
            "p_target": [], "q": [], "q_valid": [], "legal": [], "class_idx": []}
    with torch.no_grad():
        for obs, targets in loader:
            dev_obs = obs.to(device, torch.float32)
            out = model(dev_obs)
            rows["raw"].append(out.raw_logits.cpu())
            rows["prob"].append(out.probabilities.cpu())
            rows["sel"].append(out.selected_slot.cpu())
            rows["sel_prob"].append(out.selected_prob.cpu())
            for k in ("p_target", "q", "q_valid", "legal", "class_idx"):
                rows[k].append(targets[k].cpu() if torch.is_tensor(targets[k]) else targets[k])
    for k in rows:
        rows[k] = torch.cat(rows[k], dim=0) if rows[k] else torch.zeros(0)
    return rows


def metrics_from_rows(rows: dict) -> dict:
    n = int(rows["raw"].shape[0])
    if n == 0:
        return {"samples": 0}
    legal = rows["legal"].bool()
    q_valid = rows["q_valid"].bool()
    q = rows["q"].float()
    p_t = rows["p_target"].float()
    prob = rows["prob"].float()
    raw = rows["raw"].float()
    sel = rows["sel"].long()

    # masked log-probs of the model (legal-only support)
    masked = raw.masked_fill(~legal, float("-inf"))
    log_probs = torch.log_softmax(masked, dim=-1)
    safe_lp = torch.where(legal, log_probs, torch.zeros_like(log_probs))
    ce = -(p_t * safe_lp).sum(dim=-1)
    # KL(P_t || P_m) over legal support (p_t illegal mass is exactly 0)
    log_pt = torch.where(p_t > 0, p_t.log(), torch.zeros_like(p_t))
    kl = (p_t * (log_pt - safe_lp)).sum(dim=-1)

    # target/model top actions over legal slots
    pt_masked = torch.where(legal, p_t, torch.full_like(p_t, float("-inf")))
    top1_t = pt_masked.argmax(dim=-1)
    top1_m = sel.clamp_min(0)
    top1 = (top1_t == top1_m).float()
    # top-2 inclusion: model top-1 inside target top-2 (legal only)
    order = pt_masked.argsort(dim=-1, descending=True)
    top2 = ((order[:, 0] == top1_m) | (order[:, 1] == top1_m)).float()

    # regret + epsilon-optimality from Q
    q_masked = torch.where(q_valid, q, torch.full_like(q, float("-inf")))
    q_best = q_masked.amax(dim=-1)
    q_sel = q.gather(1, top1_m.unsqueeze(-1)).squeeze(-1)
    regret = (q_best - q_sel).clamp_min(0.0)
    eps_opt = (q_sel >= q_best - Q_EPSILON).float()

    # illegal selection: argmax of RAW logits lands on an illegal slot.
    # (diagnostic only — the deployed path selects from MASKED logits, which
    # cannot select an illegal slot; see masked_illegal_rate below.)
    raw_sel = raw.argmax(dim=-1)
    illegal = (~legal.gather(1, raw_sel.unsqueeze(-1)).squeeze(-1)).float()
    # deployed-path safety: masked selections are legal-or-sentinel by construction
    sel_is_sentinel = (sel == ALL_ILLEGAL_SLOT)
    sel_legal = legal.gather(1, top1_m.unsqueeze(-1)).squeeze(-1)
    masked_illegal = ((~sel_legal) & (~sel_is_sentinel)).float()

    # policy entropy in nats (masked support)
    ent = -(prob * torch.where(prob > 0, prob.log(), torch.zeros_like(prob))).sum(dim=-1)

    # ECE: confidence = selected prob, correctness = epsilon-optimal
    conf = rows["sel_prob"].float()
    ece = _ece(conf, eps_opt, ECE_BINS)
    ece_top1 = _ece(conf, top1, ECE_BINS)  # secondary: top-1-agreement correctness

    def pct(x, p):
        return float(torch.quantile(x, torch.tensor(p)).item())

    return {
        "samples": n,
        "loss": float(ce.mean()),
        "kl": float(kl.mean()),
        "top1": float(top1.mean()),
        "top2": float(top2.mean()),
        "epsilon_optimal": float(eps_opt.mean()),
        "mean_regret": float(regret.mean()),
        "median_regret": float(regret.median()),
        "p95_regret": pct(regret, 0.95),
        "max_regret": float(regret.max()),
        "illegal_selection_rate": float(illegal.mean()),
        "masked_illegal_rate": float(masked_illegal.mean()),
        "all_illegal_rate": float(sel_is_sentinel.float().mean()),
        "entropy": float(ent.mean()),
        "ece": ece,
        "ece_top1": ece_top1,
        "mean_confidence": float(conf.mean()),
    }


def _ece(conf: torch.Tensor, correct: torch.Tensor, n_bins: int) -> float:
    ece = 0.0
    n = conf.numel()
    for b in range(n_bins):
        lo, hi = b / n_bins, (b + 1) / n_bins
        in_bin = (conf > lo) & (conf <= hi) if b else (conf <= hi)
        cnt = int(in_bin.sum())
        if cnt == 0:
            continue
        acc = float(correct[in_bin].mean())
        avg_conf = float(conf[in_bin].mean())
        ece += abs(acc - avg_conf) * cnt / n
    return ece


def evaluate_offline(model, shard_path: str, device, batch_size: int = 512,
                     cap: int = 0, dataset_cls=None) -> dict:
    """Aggregate + per-class + per-profile offline metrics for one shard."""
    # R1 hook (additive): dataset_cls overrides the shard reader (v0.2 eval).
    ds = (dataset_cls or JevFullInfoDataset)(shard_path, cap=cap)
    loader = DataLoader(ds, batch_size=batch_size, shuffle=False, collate_fn=collate_jev)
    rows = _gather_rows(model, loader, device)
    out = {"aggregate": metrics_from_rows(rows),
           "epsilon_optimal_version": EPSILON_OPTIMAL_VERSION,
           "q_epsilon": Q_EPSILON, "ece_bins": ECE_BINS}
    if rows["raw"].shape[0]:
        per_class = {}
        for c in range(5):
            mask = rows["class_idx"] == c
            if int(mask.sum()) == 0:
                continue
            per_class[str(c)] = metrics_from_rows({k: v[mask] for k, v in rows.items()})
        out["per_class"] = per_class
        per_profile: dict[str, dict] = {}
        for i, prov in enumerate(ds.provenance[:ds.n]):
            per_profile.setdefault(prov["profile"], []).append(i)
        out["per_profile"] = {
            p: metrics_from_rows({k: v[torch.tensor(idxs)] for k, v in rows.items()})
            for p, idxs in per_profile.items()
        }
    return out


__all__ = [
    "ECE_BINS",
    "EPSILON_OPTIMAL_VERSION",
    "Q_EPSILON",
    "evaluate_offline",
    "metrics_from_rows",
]
