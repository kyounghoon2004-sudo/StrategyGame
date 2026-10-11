"""Checkpoint format for jev-policy-v0.1.0-fi (full-information reference run).

A checkpoint is a plain dict saved with torch.save: state_dict (tensors
only — no pickled Python objects beyond config/metadata dicts), model
configuration, training configuration + hash, seed, best epoch, validation
metrics, and every contract version/hash pin.
"""

from __future__ import annotations

import hashlib
import json

import torch

CHECKPOINT_MODEL_VERSION = "jev-policy-v0.1.0-fi"
CHECKPOINT_MODEL_VERSION_V2 = "jev-policy-v0.2.0-fi"
CHECKPOINT_FORMAT_VERSION = "jev-checkpoint-v0.1.0"


def training_config_hash(config: dict) -> str:
    return hashlib.sha256(
        json.dumps(config, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()


def build_checkpoint(
    model,
    model_config: dict,
    training_config: dict,
    seed: int,
    best_epoch: int,
    history: dict,
    validation_metrics: dict,
    contract_versions: dict,
    dataset_hash: str,
    model_version: str | None = None,
    extra_metadata: dict | None = None,
) -> dict:
    # R1 hook (additive): model_version selects the checkpoint family
    # (v0.2.0-fi for the corrected-target retrain); default keeps T0.
    meta = dict(extra_metadata) if extra_metadata else {}
    ckpt = {
        "checkpoint_format": CHECKPOINT_FORMAT_VERSION,
        "model_version": model_version or CHECKPOINT_MODEL_VERSION,
        "full_information_only": True,
        "model_config": dict(model_config),
        "training_config": dict(training_config),
        "training_config_hash": training_config_hash(training_config),
        "seed": int(seed),
        "best_epoch": int(best_epoch),
        "history": {k: list(v) for k, v in history.items()},
        "validation_metrics": dict(validation_metrics),
        "contract_versions": dict(contract_versions),
        "dataset_hash": str(dataset_hash),
        "state_dict": {k: v.detach().cpu().clone() for k, v in model.state_dict().items()},
    }
    ckpt.update(meta)
    return ckpt


def save_checkpoint(checkpoint: dict, path: str) -> str:
    torch.save(checkpoint, path)
    return path


def load_checkpoint(path: str, model) -> dict:
    """Load weights into a JevPolicyV0 instance; returns the metadata dict."""
    payload = torch.load(path, map_location="cpu", weights_only=False)
    missing, unexpected = model.load_state_dict(payload["state_dict"], strict=True)
    assert not missing and not unexpected, (missing, unexpected)
    meta = {k: v for k, v in payload.items() if k != "state_dict"}
    return meta


def checkpoint_metadata_hash(checkpoint: dict) -> str:
    meta = {k: v for k, v in checkpoint.items() if k != "state_dict"}
    return hashlib.sha256(
        json.dumps(meta, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()


__all__ = [
    "CHECKPOINT_FORMAT_VERSION",
    "CHECKPOINT_MODEL_VERSION",
    "CHECKPOINT_MODEL_VERSION_V2",
    "build_checkpoint",
    "checkpoint_metadata_hash",
    "load_checkpoint",
    "save_checkpoint",
    "training_config_hash",
]
