"""A2 dataset: jev-fullinfo-dataset-v0.4.0.

v0.3 TRAIN + dagger2 states. Same envelope/record layout as v0.3; only
the version stamp, aggregation round, and collection-checkpoint pins
advance. Validation/test stay byte-identical to the frozen set.
"""

from __future__ import annotations

from python_jev.aggregate.dataset_v03 import (
    V02_SOURCE,
    V03_SPLITS,
    load_shard_v03,
    pins_v03,
    save_shard_v03,
    v02_combined_hash,
    validate_record_v03,
)

DATASET_V04_VERSION = "jev-fullinfo-dataset-v0.4.0"
DATASET_V03_VERSION = "jev-fullinfo-dataset-v0.3.0"
MODEL_V04_VERSION = "jev-policy-v0.4.0-fi-dagger2"
AGGREGATION_V2_VERSION = "state-aggregation-v0.2.0"
DAGGER2_SOURCE = "JEV_VISITED_DAGGER2"
V04_SPLITS = V03_SPLITS
V04_SOURCES = (V02_SOURCE, "JEV_VISITED_DAGGER1", DAGGER2_SOURCE)


def pins_v04(v02_hash: str, dagger1_ckpt_hash: str, dagger2_ckpt_hash: str) -> dict:
    pins = pins_v03(v02_hash, dagger1_ckpt_hash)
    pins.update({
        "dataset_version": DATASET_V04_VERSION,
        "source_dataset_version": DATASET_V03_VERSION,
        "aggregation_version": AGGREGATION_V2_VERSION,
        "collection_checkpoint_dagger2": "jev-policy-v0.3.0-fi-dagger1/seed43",
        "collection_checkpoint_hash_dagger2": dagger2_ckpt_hash,
    })
    return pins


def save_shard_v04(path: str, split: str, records: list[dict], pins: dict) -> dict:
    return save_shard_v03(path, split, records, pins,
                          dataset_version=DATASET_V04_VERSION)


def load_shard_v04(path: str, verify: bool = True) -> dict:
    return load_shard_v03(path, verify=verify,
                          dataset_version=DATASET_V04_VERSION)


def validate_record_v04(record: dict, expected_pins: dict | None = None) -> list[str]:
    return validate_record_v03(record, expected_pins,
                               dataset_version=DATASET_V04_VERSION,
                               allowed_sources=V04_SOURCES)


__all__ = [
    "AGGREGATION_V2_VERSION",
    "DAGGER2_SOURCE",
    "DATASET_V03_VERSION",
    "DATASET_V04_VERSION",
    "MODEL_V04_VERSION",
    "V04_SOURCES",
    "V04_SPLITS",
    "load_shard_v04",
    "pins_v04",
    "save_shard_v04",
    "v02_combined_hash",
    "validate_record_v04",
]
