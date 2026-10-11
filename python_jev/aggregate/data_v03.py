"""Torch data layer for jev-fullinfo-dataset-v0.3.0 shards."""

from __future__ import annotations

from python_jev.aggregate.dataset_v03 import load_shard_v03
from python_jev.aggregate.dataset_v04 import load_shard_v04
from python_jev.training.data import JevFullInfoDataset, collate_jev
from python_jev.training.dataset_gen import TENSOR_KEYS


class JevFullInfoDatasetV3(JevFullInfoDataset):
    """Row access over one v0.3 shard (same tensors/collate as v0.1/v0.2).

    Falls back to the v0.2 loader for the byte-copied validation/test
    shards, which are v0.2 files by design (A1-9). Tensor layout is
    identical across versions; only the envelope version differs.
    """

    def __init__(self, shard_path: str, cap: int = 0) -> None:
        try:
            payload = load_shard_v03(shard_path, verify=True)
        except ValueError:
            from python_jev.retrain.dataset_v2 import load_shard_v2

            payload = load_shard_v2(shard_path, verify=True)
        self.tensors = payload["tensors"]
        self.provenance = payload["provenance"]
        self.split = payload["split"]
        self.n = int(self.tensors["actor"].shape[0])
        if cap and cap < self.n:
            self.n = cap
        for k in TENSOR_KEYS:
            assert self.tensors[k].shape[0] >= self.n, k


class JevFullInfoDatasetV4(JevFullInfoDataset):
    """Row access over one v0.4 shard (v0.2 byte-copies for val/test)."""

    def __init__(self, shard_path: str, cap: int = 0) -> None:
        try:
            payload = load_shard_v04(shard_path, verify=True)
        except ValueError:
            from python_jev.retrain.dataset_v2 import load_shard_v2

            payload = load_shard_v2(shard_path, verify=True)
        self.tensors = payload["tensors"]
        self.provenance = payload["provenance"]
        self.split = payload["split"]
        self.n = int(self.tensors["actor"].shape[0])
        if cap and cap < self.n:
            self.n = cap
        for k in TENSOR_KEYS:
            assert self.tensors[k].shape[0] >= self.n, k


class JevFullInfoDatasetV5(JevFullInfoDatasetV4):
    """Row access over one v0.5 shard (v0.2 byte-copies for val/test)."""

    def __init__(self, shard_path: str, cap: int = 0) -> None:
        from python_jev.aggregate.dataset_v05 import load_shard_v05

        try:
            payload = load_shard_v05(shard_path, verify=True)
        except ValueError:
            from python_jev.retrain.dataset_v2 import load_shard_v2

            payload = load_shard_v2(shard_path, verify=True)
        self.tensors = payload["tensors"]
        self.provenance = payload["provenance"]
        self.split = payload["split"]
        self.n = int(self.tensors["actor"].shape[0])
        if cap and cap < self.n:
            self.n = cap
        for k in TENSOR_KEYS:
            assert self.tensors[k].shape[0] >= self.n, k


__all__ = ["JevFullInfoDatasetV3", "JevFullInfoDatasetV4",
           "JevFullInfoDatasetV5", "collate_jev"]
