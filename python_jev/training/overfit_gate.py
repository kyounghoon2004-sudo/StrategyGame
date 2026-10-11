"""Tiny-overfit gate (T0, Part C): prove the model/targets/masking/batching/
gradient path can learn before full training. Trains JevPolicyV0 on ~128
training examples only; training loss must fall dramatically. Failure here
STOPS the run (investigate targets/masks/batching/gradients/routing first).
"""

from __future__ import annotations

import time

import torch
from torch.utils.data import DataLoader, Subset

from python_jev.model import JevPolicyV0
from python_jev.training.data import JevFullInfoDataset, collate_jev
from python_jev.training.evaluate import metrics_from_rows
from python_jev.training.train import evaluate_loss, soft_target_policy_loss

OVERFIT_CONFIG = {
    "n_examples": 128,
    "batch_size": 32,
    "max_epochs": 150,
    "learning_rate": 3e-4,
    "weight_decay": 1e-4,
    "gradient_clip_global_norm": 1.0,
    "seed": 0,
}


def run_overfit_gate(train_shard: str, device, config: dict | None = None,
                     log_fn=None, dataset_cls=None) -> dict:
    cfg = dict(OVERFIT_CONFIG)
    if config:
        cfg.update(config)
    dev = torch.device(device)
    torch.manual_seed(cfg["seed"])
    # R1 hook (additive): dataset_cls overrides the shard reader (v0.2 gate).
    full = (dataset_cls or JevFullInfoDataset)(train_shard)
    gen = torch.Generator().manual_seed(cfg["seed"])
    perm = torch.randperm(len(full), generator=gen)[: cfg["n_examples"]].tolist()
    tiny = Subset(full, perm)
    loader = DataLoader(tiny, batch_size=cfg["batch_size"], shuffle=True,
                        collate_fn=collate_jev,
                        generator=torch.Generator().manual_seed(cfg["seed"]))
    eval_loader = DataLoader(tiny, batch_size=cfg["batch_size"], shuffle=False,
                             collate_fn=collate_jev)

    model = JevPolicyV0().to(dev, torch.float32)
    opt = torch.optim.AdamW(model.parameters(), lr=cfg["learning_rate"],
                            weight_decay=cfg["weight_decay"])
    init_loss = evaluate_loss(model, eval_loader, dev)
    init_metrics = metrics_from_rows(_gather(model, eval_loader, dev))
    t0 = time.perf_counter()
    losses = []
    for epoch in range(cfg["max_epochs"]):
        model.train()
        total, count = 0.0, 0
        for obs, targets in loader:
            obs = obs.to(dev, torch.float32)
            p_t = targets["p_target"].to(dev, torch.float32)
            opt.zero_grad(set_to_none=True)
            out = model(obs)
            loss = soft_target_policy_loss(out.raw_logits, obs.legal_mask, p_t)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(),
                                           cfg["gradient_clip_global_norm"])
            opt.step()
            n = obs.batch_size
            total += float(loss.detach()) * n
            count += n
        losses.append(total / max(1, count))
        if log_fn and (epoch % 25 == 0 or epoch == cfg["max_epochs"] - 1):
            log_fn(f"overfit epoch {epoch}: loss={losses[-1]:.4f}")
    wall = time.perf_counter() - t0

    # before/after metrics on the tiny set (KL + regret)
    rows = _gather(model, eval_loader, dev)
    final = metrics_from_rows(rows)
    # Soft-target gate: CE floor is the TARGET ENTROPY (mean ~1.39), not 0.
    # Overfit = model reproduces the tiny-set distributions: KL -> ~0 and
    # regret -> ~0, with loss settling at the entropy floor.
    entropy_floor = init_metrics["loss"] - init_metrics["kl"]
    passed = (final["kl"] < 0.02
              and final["mean_regret"] < 0.005
              and losses[-1] < entropy_floor + 0.05)
    return {
        "config": cfg,
        "initial_loss": init_loss,
        "initial_metrics": init_metrics,
        "entropy_floor": entropy_floor,
        "final_loss": losses[-1],
        "loss_curve": losses,
        "final_metrics": final,
        "wall_seconds": wall,
        "passed": bool(passed),
    }


def _gather(model, loader, device):
    from python_jev.training.evaluate import _gather_rows

    return _gather_rows(model, loader, device)


__all__ = ["OVERFIT_CONFIG", "run_overfit_gate"]
