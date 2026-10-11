"""Pilot dataset record schema (PilotRecordV0) + anti-leakage guard.

Each record is fully reproducible: it pins every relevant contract
version/hash, the scenario seed/id, state hash, actor, observation payload,
legal mask, per-skill execution results, raw rollout outcomes, masks, and
the rollout configuration. Scalar Q[6] (ValueTargetV0) is present exactly
when q_export_status == OK — possible only for full-information profiles
under the frozen value-target contract, and permanently impossible for
partial-information profiles (hidden-truth oracle leak).
"""

from __future__ import annotations

import hashlib
import json

DATASET_SCHEMA_VERSION = "pilot-dataset-v0.1.0"

# Partial-information profiles: final Q export is FORBIDDEN (J1-16).
PARTIAL_INFO_PROFILES = ("FLAT_FOG", "TERRAIN_FOG", "MORALE_COMBAT", "FULL_PRODUCTION")
FULL_INFO_PROFILES = ("DEV_FLAT_ALL_INFO", "TERRAIN_FULL_INFO")


def assert_no_fog_oracle_labels(record: dict) -> None:
    """Hard guard: a partial-information record must never carry Q targets
    derived from (or at all alongside) hidden WorldTruth."""
    profile = record.get("profile")
    if profile in PARTIAL_INFO_PROFILES:
        if record.get("q_values") is not None:
            raise ValueError(
                f"LEAKAGE: fog profile {profile!r} record carries q_values "
                "(hidden-truth oracle labels are forbidden)")
        if record.get("q_export_status") not in (None, "FORBIDDEN_PARTIAL_INFORMATION"):
            raise ValueError(
                f"LEAKAGE: fog profile {profile!r} record has q_export_status="
                f"{record.get('q_export_status')!r}")
        for ps in record.get("per_skill", []):
            if ps.get("outcome_scalar") is not None:
                raise ValueError(
                    f"LEAKAGE: fog profile {profile!r} per_skill[{ps.get('skill_slot')}] "
                    "carries outcome_scalar")
    if record.get("world_truth_in_payload"):
        raise ValueError("LEAKAGE: world_truth_in_payload must never be true")


def validate_record(record: dict) -> list[str]:
    """Schema validation; returns a list of human-readable problems."""
    problems = []
    required = (
        "dataset_schema_version", "profile", "full_information", "scenario_id",
        "scenario_seed", "state_hash", "actor_id", "actor_class",
        "mission_context", "observation", "legal_mask", "per_skill",
        "q_valid_mask", "continuation_policy_id", "horizon_decisions",
        "contract_versions",
    )
    for k in required:
        if k not in record:
            problems.append(f"missing required field: {k}")
    if record.get("full_information") is None:
        problems.append("full_information boolean required")
    if len(record.get("legal_mask", [])) != 6:
        problems.append("legal_mask must have 6 bits")
    if len(record.get("q_valid_mask", [])) != 6:
        problems.append("q_valid_mask must have 6 bits")
    if len(record.get("per_skill", [])) != 6:
        problems.append("per_skill must cover all six slots")
    for ps in record.get("per_skill", []):
        if "raw_outcome" not in ps:
            problems.append(f"per_skill[{ps.get('skill_slot')}] missing raw_outcome")
    # ValueTargetV0 Q consistency (V0-17 mask rule included)
    q_status = record.get("q_export_status")
    q_values = record.get("q_values")
    q_valid = list(record.get("q_valid_mask", []))
    if q_status == "OK":
        if not isinstance(q_values, list) or len(q_values) != 6:
            problems.append("q_values must be a 6-list when q_export_status is OK")
        else:
            for slot, qv in enumerate(q_values):
                if q_valid and bool(q_valid[slot]):
                    if not isinstance(qv, (int, float)):
                        problems.append(f"q_values[{slot}] must be numeric for a Q-valid branch")
                else:
                    if qv is not None:
                        problems.append(f"q_values[{slot}] must be None for a masked branch (V0-17)")
        for ps in record.get("per_skill", []):
            slot = ps.get("skill_slot")
            expect = q_values[slot] if isinstance(q_values, list) and 0 <= slot < 6 else None
            if ps.get("outcome_scalar") != expect:
                problems.append(f"per_skill[{slot}] outcome_scalar must equal q_values[{slot}]")
    elif q_status in ("BLOCKED_NO_VALUE_TARGET_CONTRACT", "FORBIDDEN_PARTIAL_INFORMATION"):
        if q_values is not None:
            problems.append(f"q_values must be None when q_export_status is {q_status}")
        for ps in record.get("per_skill", []):
            if ps.get("outcome_scalar") is not None:
                problems.append(f"per_skill[{ps.get('skill_slot')}] outcome_scalar must be None when Q is {q_status}")
    cv = record.get("contract_versions", {})
    for k in ("sim_version", "ruleset_version", "ruleset_hash",
              "observation_layout_version", "observation_layout_hash",
              "skill_contract_version", "skill_modes_hash",
              "rollout_config_version", "continuation_policy_version",
              "outcome_vector_version", "value_target_version",
              "trajectory_format_version"):
        if k not in cv:
            problems.append(f"contract_versions missing: {k}")
    # anti-leakage
    try:
        assert_no_fog_oracle_labels(record)
    except ValueError as e:
        problems.append(str(e))
    return problems


def observation_payload_hash(observation: dict) -> str:
    """Deterministic hash of the serialized observation payload."""
    return hashlib.sha256(json.dumps(
        observation, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("utf-8")).hexdigest()


def write_jsonl(path: str, records: list[dict]) -> int:
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        for r in records:
            f.write(json.dumps(r, sort_keys=True, separators=(",", ":"),
                               ensure_ascii=True) + "\n")
    return len(records)


def read_jsonl(path: str) -> list[dict]:
    out = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                out.append(json.loads(line))
    return out


__all__ = [
    "DATASET_SCHEMA_VERSION",
    "FULL_INFO_PROFILES",
    "PARTIAL_INFO_PROFILES",
    "assert_no_fog_oracle_labels",
    "observation_payload_hash",
    "read_jsonl",
    "validate_record",
    "write_jsonl",
]
