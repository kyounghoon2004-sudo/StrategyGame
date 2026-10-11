"""A3 dataset: jev-fullinfo-dataset-v0.5.0.

v0.4 TRAIN + novel dagger3 states (driver: jev-policy-v0.4.0-fi-dagger2
seed44). Same envelope/record layout as v0.3/v0.4; only the version
stamp, aggregation round, and collection-checkpoint pins advance.
Validation/test stay byte-identical to the frozen set. Only
cross-deduped NEW_UNIQUE dagger3 rows enter TRAIN.
"""

from __future__ import annotations

from python_jev.aggregate.dataset_v03 import (
    V02_SOURCE,
    V03_SPLITS,
    load_shard_v03,
    save_shard_v03,
    v02_combined_hash,
    validate_record_v03,
)
from python_jev.aggregate.dataset_v04 import (
    AGGREGATION_V2_VERSION,
    DAGGER2_SOURCE,
    DATASET_V04_VERSION,
    MODEL_V04_VERSION,
    pins_v04,
)
from python_jev.aggregate.gather import DAGGER_CAP

DAGGER_V2 = "artifacts/jev_dagger_v2"

# ---------------------------------------------------------------- versions
DATASET_V05_VERSION = "jev-fullinfo-dataset-v0.5.0"
MODEL_V05_VERSION = "jev-policy-v0.5.0-fi-dagger3"
DAGGER3_VERSION = "state-aggregation-v0.3.0"
DAGGER3_SOURCE = "JEV_VISITED_DAGGER3"
V04_CKPT_LABEL = "jev-policy-v0.4.0-fi-dagger2/seed44"

V04_TRAIN_SHA256 = (
    "4a17aa3a5ad1cf9944cd12ec56bad4976b7f297482cb80434695880e1aa30d21"
)
V04_CKPT_SHA256 = (
    "18ec11625d5de86e07e5caf84e3769fb73e4f585645c34129fe6f748cf42c0cc"
)

# carried corpus for round 3 = every v0.4 TRAIN row (original + r1 + r2)
V05_TRAIN_SOURCES = (V02_SOURCE, "JEV_VISITED_DAGGER1", DAGGER2_SOURCE)
V05_SOURCES = V05_TRAIN_SOURCES + (DAGGER3_SOURCE,)
V05_SPLITS = V03_SPLITS


def pins_v05(v02_hash: str, dagger1_ckpt_hash: str, dagger2_ckpt_hash: str,
             dagger3_ckpt_hash: str) -> dict:
    pins = pins_v04(v02_hash, dagger1_ckpt_hash, dagger2_ckpt_hash)
    pins.update({
        "dataset_version": DATASET_V05_VERSION,
        "source_dataset_version": DATASET_V04_VERSION,
        "aggregation_version": DAGGER3_VERSION,
        "collection_checkpoint_dagger3": V04_CKPT_LABEL,
        "collection_checkpoint_hash_dagger3": dagger3_ckpt_hash,
    })
    return pins


def save_shard_v05(path: str, split: str, records: list[dict], pins: dict) -> dict:
    return save_shard_v03(path, split, records, pins,
                          dataset_version=DATASET_V05_VERSION)


def load_shard_v05(path: str, verify: bool = True) -> dict:
    return load_shard_v03(path, verify=verify,
                          dataset_version=DATASET_V05_VERSION)


def validate_record_v05(record: dict, expected_pins: dict | None = None) -> list[str]:
    return validate_record_v03(record, expected_pins,
                               dataset_version=DATASET_V05_VERSION,
                               allowed_sources=V05_SOURCES)


__all__ = [
    "AGGREGATION_V2_VERSION",
    "DAGGER3_SOURCE",
    "DAGGER3_VERSION",
    "DAGGER_CAP",
    "DAGGER_V2",
    "DATASET_V04_VERSION",
    "DATASET_V05_VERSION",
    "MODEL_V04_VERSION",
    "MODEL_V05_VERSION",
    "V04_CKPT_LABEL",
    "V04_CKPT_SHA256",
    "V04_TRAIN_SHA256",
    "V05_SOURCES",
    "V05_SPLITS",
    "V05_TRAIN_SOURCES",
    "load_shard_v05",
    "pins_v05",
    "save_shard_v05",
    "v02_combined_hash",
    "validate_record_v05",
]
