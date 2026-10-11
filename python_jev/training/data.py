"""Torch data layer for jev-fullinfo-dataset-v0.1.0 shards."""

from __future__ import annotations

import torch
from torch.utils.data import Dataset

from python_jev.constants import PATCH_NUM_CELLS
from python_jev.observation import ObservationBatchV0
from python_jev.training.dataset_gen import TENSOR_KEYS, load_shard


class JevFullInfoDataset(Dataset):
    """Row access over one dataset shard (optionally capped, deterministic)."""

    def __init__(self, shard_path: str, cap: int = 0) -> None:
        payload = load_shard(shard_path, verify=True)
        self.tensors = payload["tensors"]
        self.provenance = payload["provenance"]
        self.split = payload["split"]
        self.n = int(self.tensors["actor"].shape[0])
        if cap and cap < self.n:
            self.n = cap
        for k in TENSOR_KEYS:
            assert self.tensors[k].shape[0] >= self.n, k

    def __len__(self) -> int:
        return self.n

    def __getitem__(self, idx: int) -> dict:
        return {k: self.tensors[k][idx] for k in TENSOR_KEYS}


def collate_jev(batch: list[dict]) -> tuple[ObservationBatchV0, dict[str, torch.Tensor]]:
    b = len(batch)
    obs = ObservationBatchV0(
        actor_features=torch.stack([r["actor"] for r in batch]),
        tokens=torch.stack([r["tokens"] for r in batch]),
        token_padding_mask=torch.stack([r["token_pad"] for r in batch]),
        hex_patch=torch.stack([r["hex"] for r in batch]),
        hex_padding_mask=torch.zeros(b, PATCH_NUM_CELLS, dtype=torch.bool),
        mission_features=torch.stack([r["mission"] for r in batch]),
        global_features=torch.stack([r["global"] for r in batch]),
        legal_mask=torch.stack([r["legal"] for r in batch]),
        acting_class_idx=torch.stack([r["class_idx"] for r in batch]),
        metadata={},
    )
    targets = {
        "p_target": torch.stack([r["p_target"] for r in batch]),
        "q": torch.stack([r["q"] for r in batch]),
        "q_valid": torch.stack([r["q_valid"] for r in batch]),
        "legal": torch.stack([r["legal"] for r in batch]),
        "class_idx": torch.stack([r["class_idx"] for r in batch]),
    }
    return obs, targets


__all__ = ["JevFullInfoDataset", "collate_jev"]
