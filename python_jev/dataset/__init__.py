"""python_jev.dataset — pilot dataset schema + guards (schema only).

NO training, NO optimizer, NO large-scale generation. This package defines:
- the versioned JSONL record schema (PilotRecordV0),
- the dataset-level anti-leakage / Q-export guard wrapper,
- JSONL reading/writing with schema validation.
"""

from python_jev.dataset.schema import (
    DATASET_SCHEMA_VERSION,
    PARTIAL_INFO_PROFILES,
    assert_no_fog_oracle_labels,
    validate_record,
)

__all__ = [
    "DATASET_SCHEMA_VERSION",
    "PARTIAL_INFO_PROFILES",
    "assert_no_fog_oracle_labels",
    "validate_record",
]
