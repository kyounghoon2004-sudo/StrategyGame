"""Torch data layer for jev-fullinfo-dataset-v0.2.0 shards."""

from __future__ import annotations

from python_jev.retrain.dataset_v2 import load_shard_v2
from python_jev.training.data import JevFullInfoDataset, collate_jev
from python_jev.training.dataset_gen import TENSOR_KEYS


class JevFullInfoDatasetV2(JevFullInfoDataset):
    """Row access over one v0.2 shard (same tensors/collate as v0.1)."""

    def __init__(self, shard_path: str, cap: int = 0) -> None:
        payload = load_shard_v2(shard_path, verify=True)
        self.tensors = payload["tensors"]
        self.provenance = payload["provenance"]
        self.split = payload["split"]
        self.n = int(self.tensors["actor"].shape[0])
        if cap and cap < self.n:
            self.n = cap
        for k in TENSOR_KEYS:
            assert self.tensors[k].shape[0] >= self.n, k


__all__ = ["JevFullInfoDatasetV2", "collate_jev"]
