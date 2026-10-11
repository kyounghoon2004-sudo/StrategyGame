"""Reference training entry (T0, Part D): three independent seeds (42/43/44),
identical dataset split, best-validation selection. Saves jev-policy-v0.1.0-fi
checkpoints + training histories. Test shard is never touched here."""

from __future__ import annotations

import hashlib
import json
import os

import torch

from python_jev.model import JevPolicyV0
from python_jev.training.checkpoint import build_checkpoint, save_checkpoint
from python_jev.training.dataset_gen import contract_pins, load_shard
from python_jev.training.train import TRAIN_DEFAULTS, train_one_seed

SEEDS = (42, 43, 44)
MODEL_CONFIG = {
    "architecture": "JevPolicyV0-shared-trunk-five-class-heads",
    "token_embed_dim": 128,
    "context_embed_dim": 128,
    "hidden_dim": 256,
    "fusion_latent_dim": 512,
    "dtype": "float32",
}


def dataset_hash_for(*shard_paths: str) -> str:
    h = hashlib.sha256()
    for p in shard_paths:
        h.update(load_shard(p, verify=True)["shard_hash"].encode("utf-8"))
    return h.hexdigest()


def main(out_root: str = "artifacts/jev_training_v0", seeds=SEEDS) -> dict:
    device = "cuda" if torch.cuda.is_available() else "cpu"
    ds_dir = os.path.join(out_root, "dataset")
    ckpt_dir = os.path.join(out_root, "checkpoints")
    os.makedirs(ckpt_dir, exist_ok=True)
    train_shard = os.path.join(ds_dir, "train.pt")
    val_shard = os.path.join(ds_dir, "validation.pt")
    pins = contract_pins()
    ds_hash = dataset_hash_for(train_shard, val_shard,
                               os.path.join(ds_dir, "test.pt"))
    try:
        n_params = sum(p.numel() for p in JevPolicyV0().parameters())
    except Exception:
        n_params = None

    summary = {"device": device, "model_config": MODEL_CONFIG,
               "train_defaults": TRAIN_DEFAULTS, "n_parameters": n_params,
               "dataset_hash": ds_hash, "seeds": {}}
    for seed in seeds:
        if torch.cuda.is_available():
            torch.cuda.reset_peak_memory_stats()
        run = train_one_seed(train_shard, val_shard, seed, device,
                             log_fn=lambda m: print(m, flush=True))
        peak_vram = (torch.cuda.max_memory_allocated() / 1e9
                     if torch.cuda.is_available() else None)
        model = JevPolicyV0()
        model.load_state_dict(run["best_state_dict"])
        ckpt = build_checkpoint(
            model, MODEL_CONFIG, run["config"], seed, run["best_epoch"],
            run["history"], {"best_val_loss": run["best_val_loss"]}, pins, ds_hash)
        path = os.path.join(ckpt_dir, f"seed{seed}.pt")
        save_checkpoint(ckpt, path)
        summary["seeds"][str(seed)] = {
            "best_epoch": run["best_epoch"],
            "best_val_loss": run["best_val_loss"],
            "epochs_run": run["epochs_run"],
            "wall_seconds": run["wall_seconds"],
            "samples_per_second": run["samples_per_second"],
            "peak_vram_gb": peak_vram,
            "checkpoint": path,
        }
        print(f"seed {seed}: best_epoch={run['best_epoch']} "
              f"val={run['best_val_loss']:.4f} epochs={run['epochs_run']} "
              f"peak_vram={peak_vram}", flush=True)
    with open(os.path.join(out_root, "metrics", "training_history.json"), "w") as f:
        json.dump(summary, f, indent=2, sort_keys=True)
    return summary


if __name__ == "__main__":
    main()
