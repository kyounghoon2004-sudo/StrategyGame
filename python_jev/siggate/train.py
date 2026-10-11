"""Arm training: JevPolicyV0 from scratch on BASE + gated D3 rows (Part F).

Identical protocol to train_one_seed (AdamW 3e-4 / wd 1e-4 / clip 1.0 /
batch 256 / 30 epochs / patience 5 / float32 / no scheduler); only the row
set differs (Subset over the frozen v0.5 train shard). Checkpoints are
EXPERIMENTAL (siggate model versions), never v0.6.
"""

from __future__ import annotations

import math
import os
import time

import torch
from torch.utils.data import DataLoader, Subset

from python_jev.aggregate.data_v03 import JevFullInfoDatasetV5
from python_jev.model import JevPolicyV0
from python_jev.siggate import SEEDS
from python_jev.siggate.gates import V05_TRAIN
from python_jev.training.checkpoint import build_checkpoint, save_checkpoint
from python_jev.training.data import collate_jev
from python_jev.training.train import (
    TRAIN_DEFAULTS,
    evaluate_loss,
    soft_target_policy_loss,
)

VAL_SHARD = os.path.join("artifacts", "jev_dagger_v2", "dataset_v05", "validation.pt")


def experiment_model_version(arm: str) -> str:
    return f"jev-policy-v0.5.0-fi-siggate-{arm}-exp"


def train_arm_seed(arm: str, train_idx: list[int], seed: int,
                   device: str | torch.device, log_fn=None) -> dict:
    """Mirror of train_one_seed over an explicit row subset."""
    cfg = dict(TRAIN_DEFAULTS)
    dev = torch.device(device)
    torch.manual_seed(seed)
    full = JevFullInfoDatasetV5(V05_TRAIN)
    train_ds = Subset(full, train_idx)
    val_ds = JevFullInfoDatasetV5(VAL_SHARD)
    gen = torch.Generator().manual_seed(seed)
    train_loader = DataLoader(train_ds, batch_size=cfg["batch_size"], shuffle=True,
                              collate_fn=collate_jev, generator=gen)
    val_loader = DataLoader(val_ds, batch_size=cfg["batch_size"], shuffle=False,
                            collate_fn=collate_jev)
    model = JevPolicyV0().to(dev, torch.float32)
    opt = torch.optim.AdamW(model.parameters(), lr=cfg["learning_rate"],
                            weight_decay=cfg["weight_decay"])
    history: dict[str, list[float]] = {"train_loss": [], "val_loss": [],
                                       "epoch_seconds": []}
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
            best_state = {k: v.detach().cpu().clone()
                          for k, v in model.state_dict().items()}
            bad_epochs = 0
        else:
            bad_epochs += 1
        if log_fn:
            log_fn(f"arm {arm} seed {seed} epoch {epoch}: train={train_loss:.4f} "
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


def arm_contract_pins(manifest_hash: str) -> dict:
    from python_jev.aggregate.dataset_v03 import v02_combined_hash
    from python_jev.aggregate.dataset_v05 import pins_v05
    from python_jev.aggregate.gather import collection_ckpt_hash

    pins = pins_v05(
        v02_combined_hash(os.path.join("artifacts", "jev_training_v1", "dataset")),
        collection_ckpt_hash(os.path.join("artifacts", "jev_training_v1",
                                          "checkpoints", "seed43.pt")),
        collection_ckpt_hash(os.path.join("artifacts", "jev_dagger_v0",
                                          "checkpoints", "seed43.pt")),
        collection_ckpt_hash(os.path.join("artifacts", "jev_dagger_v1",
                                          "checkpoints", "seed44.pt")))
    pins["siggate_manifest_hash"] = manifest_hash
    return pins


def save_arm_checkpoint(arm: str, run: dict, manifest_hash: str,
                        ckpt_dir: str, n_parameters: int) -> str:
    model = JevPolicyV0()
    model.load_state_dict(run["best_state_dict"])
    ckpt = build_checkpoint(
        model,
        model_config={"token_embed_dim": 128, "context_embed_dim": 128,
                      "hidden_dim": 256, "fusion_latent_dim": 512,
                      "dtype": "float32",
                      "architecture": "JevPolicyV0-shared-trunk-five-class-heads"},
        training_config=run["config"],
        seed=run["seed"],
        best_epoch=run["best_epoch"],
        history=run["history"],
        validation_metrics={"val_loss": run["best_val_loss"]},
        contract_versions=arm_contract_pins(manifest_hash),
        dataset_hash=f"siggate-{arm}:{manifest_hash}",
        model_version=experiment_model_version(arm),
        extra_metadata={"n_parameters": n_parameters,
                        "experimental": True,
                        "production": False},
    )
    os.makedirs(ckpt_dir, exist_ok=True)
    path = os.path.join(ckpt_dir, f"seed{run['seed']}.pt")
    save_checkpoint(ckpt, path)
    return path


__all__ = [
    "SEEDS",
    "VAL_SHARD",
    "arm_contract_pins",
    "experiment_model_version",
    "save_arm_checkpoint",
    "train_arm_seed",
]
