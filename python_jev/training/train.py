"""Supervised reference training for JevPolicyV0 (T0, Part D).

Loss: masked soft-target cross entropy over legal slots only:
    L = - sum_i P_target(i) * log P_model(i)
No scheduler, no RL, no self-play. Early stopping on validation policy
loss (patience 5). Best-validation checkpoint wins; test is never used
for selection.
"""

from __future__ import annotations

import math
import time

import torch
import torch.nn.functional as F
from torch.utils.data import DataLoader

from python_jev.model import JevPolicyV0
from python_jev.training.data import JevFullInfoDataset, collate_jev

TRAIN_DEFAULTS = {
    "learning_rate": 3e-4,
    "weight_decay": 1e-4,
    "gradient_clip_global_norm": 1.0,
    "batch_size": 256,
    "max_epochs": 30,
    "patience": 5,
    "dtype": "float32",
    "optimizer": "AdamW",
    "scheduler": None,
}


def soft_target_policy_loss(
    raw_logits: torch.Tensor,  # [B, 6]
    legal_mask: torch.Tensor,  # [B, 6] bool
    p_target: torch.Tensor,    # [B, 6]
) -> torch.Tensor:
    """Masked soft-target cross entropy (scalar mean over the batch)."""
    if legal_mask.dtype != torch.bool:
        raise ValueError("legal_mask must be bool")
    masked = raw_logits.masked_fill(~legal_mask, float("-inf"))
    log_probs = torch.log_softmax(masked, dim=-1)
    # illegal log(-inf) * 0.0 target would NaN — zero those terms exactly.
    safe = torch.where(legal_mask, log_probs, torch.zeros_like(log_probs))
    per_row = -(p_target * safe).sum(dim=-1)
    return per_row.mean()


@torch.no_grad()
def evaluate_loss(model, loader, device) -> float:
    model.eval()
    total, count = 0.0, 0
    for obs, targets in loader:
        obs = obs.to(device, torch.float32)
        out = model(obs)
        loss = soft_target_policy_loss(
            out.raw_logits, obs.legal_mask,
            targets["p_target"].to(device, torch.float32))
        n = obs.batch_size
        total += float(loss) * n
        count += n
    return total / max(1, count)


def train_one_seed(
    train_shard: str,
    val_shard: str,
    seed: int,
    device: str | torch.device,
    config: dict | None = None,
    log_fn=None,
    dataset_cls=None,
) -> dict:
    """Train JevPolicyV0 from one initialization seed. Returns run record."""
    cfg = dict(TRAIN_DEFAULTS)
    if config:
        cfg.update(config)
    dev = torch.device(device)
    torch.manual_seed(seed)

    # R1 hook (additive): dataset_cls overrides the shard reader so the
    # identical loop trains on v0.2 shards; None keeps the T0 path.
    ds_cls = dataset_cls or JevFullInfoDataset
    train_ds = ds_cls(train_shard)
    val_ds = ds_cls(val_shard)
    gen = torch.Generator().manual_seed(seed)
    train_loader = DataLoader(train_ds, batch_size=cfg["batch_size"], shuffle=True,
                              collate_fn=collate_jev, generator=gen)
    val_loader = DataLoader(val_ds, batch_size=cfg["batch_size"], shuffle=False,
                            collate_fn=collate_jev)

    model = JevPolicyV0().to(dev, torch.float32)
    opt = torch.optim.AdamW(model.parameters(), lr=cfg["learning_rate"],
                            weight_decay=cfg["weight_decay"])

    history: dict[str, list[float]] = {"train_loss": [], "val_loss": [], "epoch_seconds": []}
    best_val = math.inf
    best_epoch = -1
    best_state = None
    bad_epochs = 0
    samples_seen = 0
    t_run = time.perf_counter()
    for epoch in range(cfg["max_epochs"]):
        model.train()
        t_ep = time.perf_counter()
        total, count = 0.0, 0
        for obs, targets in train_loader:
            obs = obs.to(dev, torch.float32)
            p_t = targets["p_target"].to(dev, torch.float32)
            opt.zero_grad(set_to_none=True)
            out = model(obs)
            loss = soft_target_policy_loss(out.raw_logits, obs.legal_mask, p_t)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(
                model.parameters(), cfg["gradient_clip_global_norm"])
            opt.step()
            n = obs.batch_size
            total += float(loss.detach()) * n
            count += n
            samples_seen += n
        train_loss = total / max(1, count)
        val_loss = evaluate_loss(model, val_loader, dev)
        history["train_loss"].append(train_loss)
        history["val_loss"].append(val_loss)
        history["epoch_seconds"].append(time.perf_counter() - t_ep)
        improved = val_loss < best_val - 1e-12
        if improved:
            best_val = val_loss
            best_epoch = epoch
            best_state = {k: v.detach().cpu().clone() for k, v in model.state_dict().items()}
            bad_epochs = 0
        else:
            bad_epochs += 1
        if log_fn:
            log_fn(f"seed {seed} epoch {epoch}: train={train_loss:.4f} "
                   f"val={val_loss:.4f} best={best_val:.4f}@{best_epoch}")
        if bad_epochs >= cfg["patience"]:
            break
    wall = time.perf_counter() - t_run
    model.load_state_dict(best_state)
    return {
        "seed": seed,
        "config": cfg,
        "history": history,
        "best_epoch": best_epoch,
        "best_val_loss": best_val,
        "epochs_run": len(history["train_loss"]),
        "wall_seconds": wall,
        "samples_per_second": samples_seen / wall if wall > 0 else 0.0,
        "best_state_dict": best_state,
    }


__all__ = [
    "TRAIN_DEFAULTS",
    "evaluate_loss",
    "soft_target_policy_loss",
    "train_one_seed",
]
