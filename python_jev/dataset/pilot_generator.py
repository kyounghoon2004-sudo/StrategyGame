"""Pilot dataset generator (engineering validation ONLY — not production scale).

Purpose: prove state -> ObservationLayoutV0 -> six skill branches -> rollout
-> outcome vector -> (blocked) Q export end-to-end, with enough coverage to
exercise all five learned classes, all 30 skills, force ratios, missions,
positions, and both full-information profiles — plus Fog-profile records
that carry NO Q labels (guard-enforced).

Dataset size is justified by verification needs only (~30 records):
- 5 classes x 2 full-info profiles x 3 scenarios ≈ 30 decision states.
- every one of the 30 skills appears in at least one record's per_skill set.
- Fog profiles appear only in the anti-leakage test fixture set.
"""

from __future__ import annotations

import json

from python_jev import constants as jev_c
from python_jev.contracts import hex_patch as hex_patch_c
from python_jev.contracts import observation_layout as ol
from python_jev.contracts import ruleset as rs
from python_jev.dataset.schema import (
    DATASET_SCHEMA_VERSION,
    assert_no_fog_oracle_labels,
    observation_payload_hash,
    validate_record,
    write_jsonl,
)
from python_sim import SIM_VERSION
from python_sim.observation.projector import ObservationProjector
from python_sim.rollout.config import ROLLOUT_CONFIG_VERSION
from python_sim.rollout.engine import CounterfactualEngine, state_hash
from python_sim.rollout.outcome import OUTCOME_VECTOR_VERSION_V2
from python_sim.rollout.value_target import VALUE_TARGET_VERSION, q_export_status
from python_sim.skills import observation_safe_skill_mask
from python_sim.skills.contracts import (
    FAILURE_CODE_VERSION,
    MODES_VERSION,
    SKILL_CONTRACT_VERSION,
    content_hash as skill_modes_hash,
)
from python_sim.skills.context import MissionContext
from python_sim.sim.battle import Battle, SCENARIO_PROFILES
from python_jev.training.projection import project_for_training
from python_sim.trajectory.recorder import TRAJECTORY_FORMAT_VERSION
from python_sim.rollout.config import CONTINUATION_POLICY_VERSION

DEFAULT_CONTINUATION = "SimpleAttackElseAdvancePolicy"


def _scenario(name: str, seed: int) -> dict:
    """Small deterministic pilot scenarios (varied force ratios/missions)."""
    base_map = {"bounds": {"q_min": -30, "q_max": -20, "r_min": -5, "r_max": 5},
                "default_terrain": 0, "terrain_overrides": {}, "river_cells": []}
    if name == "pilot_even_seek":
        return {
            "scenario_id": name, "scenario_version": "0.1.0", "seed": seed,
            "mission_contract": {"primary_objective": "destroy_all_red", "turn_limit": 12},
            "map": base_map,
            "forces": [
                {"id": "B_HQ_1", "class": "hq", "faction": "blue", "q": -28, "r": 0, "soldiers": 300},
                {"id": "B_INF_1", "class": "infantry", "faction": "blue", "q": -25, "r": 0, "soldiers": 400},
                {"id": "B_SPR_1", "class": "spearman", "faction": "blue", "q": -26, "r": -1, "soldiers": 380},
                {"id": "B_CAV_1", "class": "cavalry", "faction": "blue", "q": -27, "r": 1, "soldiers": 300},
                {"id": "B_ARC_1", "class": "archer", "faction": "blue", "q": -27, "r": -2, "soldiers": 250},
                {"id": "B_SCT_1", "class": "scout", "faction": "blue", "q": -24, "r": 1, "soldiers": 80},
                {"id": "R_INF_1", "class": "infantry", "faction": "red", "q": -22, "r": 0, "soldiers": 420},
                {"id": "R_ARC_1", "class": "archer", "faction": "red", "q": -21, "r": -1, "soldiers": 240},
                {"id": "R_HQ_1", "class": "hq", "faction": "red", "q": -20, "r": 2, "soldiers": 300},
            ],
        }
    if name == "pilot_hold_defend":
        return {
            "scenario_id": name, "scenario_version": "0.1.0", "seed": seed,
            "mission_contract": {"primary_objective": "hold_hq", "turn_limit": 8},
            "map": base_map,
            "forces": [
                {"id": "B_HQ_1", "class": "hq", "faction": "blue", "q": -28, "r": 0, "soldiers": 300},
                {"id": "B_INF_1", "class": "infantry", "faction": "blue", "q": -26, "r": 0, "soldiers": 500},
                {"id": "B_SPR_1", "class": "spearman", "faction": "blue", "q": -27, "r": 1, "soldiers": 450},
                {"id": "B_ARC_1", "class": "archer", "faction": "blue", "q": -27, "r": -1, "soldiers": 300},
                {"id": "R_CAV_1", "class": "cavalry", "faction": "red", "q": -21, "r": 0, "soldiers": 350},
                {"id": "R_INF_1", "class": "infantry", "faction": "red", "q": -22, "r": 1, "soldiers": 450},
                {"id": "R_HQ_1", "class": "hq", "faction": "red", "q": -19, "r": 0, "soldiers": 300},
            ],
        }
    # pilot_mismatch_recon: outnumbered blue + recon mission (force-ratio/
    # mission coverage)
    return {
        "scenario_id": name, "scenario_version": "0.1.0", "seed": seed,
        "mission_contract": {"primary_objective": "survive_turns", "turn_limit": 10},
        "map": base_map,
        "forces": [
            {"id": "B_HQ_1", "class": "hq", "faction": "blue", "q": -29, "r": 0, "soldiers": 250},
            {"id": "B_SCT_1", "class": "scout", "faction": "blue", "q": -25, "r": 1, "soldiers": 80},
            {"id": "B_ARC_1", "class": "archer", "faction": "blue", "q": -26, "r": 0, "soldiers": 220},
            {"id": "R_INF_1", "class": "infantry", "faction": "red", "q": -22, "r": 0, "soldiers": 500},
            {"id": "R_SPR_1", "class": "spearman", "faction": "red", "q": -21, "r": 1, "soldiers": 460},
            {"id": "R_CAV_1", "class": "cavalry", "faction": "red", "q": -20, "r": -1, "soldiers": 330},
            {"id": "R_HQ_1", "class": "hq", "faction": "red", "q": -19, "r": 2, "soldiers": 300},
        ],
    }


def _mission_context(scenario: dict) -> MissionContext:
    mc = scenario["mission_contract"]
    role = "RECON" if mc["primary_objective"] == "survive_turns" else "PRIMARY"
    return MissionContext(
        scenario_id=str(scenario["scenario_id"]),
        primary_objective=str(mc["primary_objective"]),
        turn_limit=int(mc["turn_limit"]),
        actor_mission_role=role,
    )


def _contract_versions() -> dict:
    return {
        "sim_version": SIM_VERSION,
        "ruleset_version": rs.RULESET_VERSION,
        "ruleset_hash": rs.content_hash(),
        "observation_layout_version": ol.LAYOUT_CONTRACT_VERSION,
        "observation_layout_hash": ol.content_hash(),
        "hex_patch_version": hex_patch_c.PATCH_CONTRACT_VERSION,
        "hex_patch_hash": hex_patch_c.content_hash(),
        "skill_contract_version": SKILL_CONTRACT_VERSION,
        "skill_modes_hash": skill_modes_hash(),
        "failure_code_version": FAILURE_CODE_VERSION,
        "modes_version": MODES_VERSION,
        "rollout_config_version": ROLLOUT_CONFIG_VERSION,
        "continuation_policy_version": CONTINUATION_POLICY_VERSION,
        "outcome_vector_version": OUTCOME_VECTOR_VERSION_V2,
        "value_target_version": VALUE_TARGET_VERSION,
        "trajectory_format_version": TRAJECTORY_FORMAT_VERSION,
        "dataset_schema_version": DATASET_SCHEMA_VERSION,
        "jev_action_space_version": "python_jev.constants.ACTION_SPACE (frozen tables)",
    }


def _observation_payload(battle: Battle, actor_id: str, ctx: MissionContext) -> dict:
    """ObservationLayoutV0 input as a JSON-safe payload (projector output).

    The payload is the AUTHORIZED projection only. WorldTruth is never
    serialized here (world_truth_in_payload stays False). The actual
    mission context is required (fail-fast training projection)."""
    side = str(battle.world.unit_dict(actor_id).get("faction", "blue"))
    proj = ObservationProjector(battle)
    o = project_for_training(proj, side, actor_id, ctx)
    return {
        "actor_features": [round(x, 6) for x in o.actor_features],
        "tokens": [[round(x, 6) for x in t] for t in o.tokens],
        "token_padding_mask": list(o.token_padding_mask),
        "hex_patch": [[round(x, 6) for x in h] for h in o.hex_patch],
        "mission_features": [round(x, 6) for x in o.mission_features],
        "global_features": [round(x, 6) for x in o.global_features],
        "acting_class_idx": int(o.acting_class_idx),
        "payload_hash": None,  # set by caller
    }


def build_record(
    scenario: dict,
    profile: str,
    actor_id: str,
    continuation: str = DEFAULT_CONTINUATION,
    horizon: int = 8,
    seed: int = 7,
) -> dict:
    battle = Battle(json.loads(json.dumps(scenario)), profile, seed=seed)
    ctx = _mission_context(scenario)
    actor = battle.world.unit_dict(actor_id)
    if actor is None:
        raise KeyError(f"actor {actor_id!r} not in scenario")
    cls_map = {"infantry": "INFANTRY", "spearman": "SPEARMAN", "cavalry": "CAVALRY",
               "archer": "ARCHER", "scout": "SCOUT"}
    actor_class = cls_map[str(actor.get("class", "")).lower()]

    eng = CounterfactualEngine.from_name(continuation, horizon, seed)
    ev = eng.evaluate(battle, actor_id, ctx)

    obs = _observation_payload(battle, actor_id, ctx)
    obs["payload_hash"] = observation_payload_hash(
        {k: v for k, v in obs.items() if k != "payload_hash"})
    legal = observation_safe_skill_mask(battle, actor_id)

    per_skill = []
    for slot in range(6):
        br = ev.branches[slot]
        per_skill.append({
            "skill_slot": slot,
            "skill_name": br.skill_name,
            "execution_status": br.execution_status,
            "execution_result": br.execution_result,
            "post_skill_state_hash": br.post_skill_state_hash,
            "raw_outcome": br.raw_outcome,
            "outcome_scalar": br.outcome_scalar,   # Q for legal full-info branches; None if masked
        })

    q_status = q_export_status(profile)
    # ValueTargetV0 scalar labels: per-slot Q for legal full-info branches,
    # None for masked slots (V0-17) and for Q-forbidden profiles (fog guard).
    q_values: list | None = None
    if q_status == "OK":
        q_values = [ev.branches[slot].outcome_scalar for slot in range(6)]
    record = {
        "dataset_schema_version": DATASET_SCHEMA_VERSION,
        "profile": profile,
        "full_information": profile not in ("FLAT_FOG", "TERRAIN_FOG",
                                            "MORALE_COMBAT", "FULL_PRODUCTION"),
        "profile_degraded": bool(SCENARIO_PROFILES[profile].get("degraded")),
        "scenario_id": str(scenario["scenario_id"]),
        "scenario_seed": int(scenario.get("seed", seed)),
        "state_hash": ev.decision_state_hash,
        "actor_id": actor_id,
        "actor_class": actor_class,
        "mission_context": ctx.to_dict(),
        "observation": obs,
        "observation_hash": obs["payload_hash"],
        "legal_mask": list(legal),
        "per_skill": per_skill,
        "q_values": q_values,                # ValueTargetV0 Q[6] (None where forbidden/masked)
        "q_export_status": q_status,
        "q_valid_mask": list(ev.q_valid_mask),
        "continuation_policy_id": continuation,
        "horizon_decisions": int(horizon),
        "world_truth_in_payload": False,
        "contract_versions": _contract_versions(),
    }
    # hard guard before the record ever leaves the builder
    assert_no_fog_oracle_labels(record)
    problems = validate_record(record)
    if problems:
        raise ValueError(f"invalid pilot record: {problems}")
    return record


def generate_pilot_dataset() -> list[dict]:
    """Small engineering-validation set: 2 full-info profiles x 3 scenarios
    x 5 classes (one actor per class per scenario)."""
    records = []
    seed = 7
    for profile in ("DEV_FLAT_ALL_INFO", "TERRAIN_FULL_INFO"):
        for sname in ("pilot_even_seek", "pilot_hold_defend", "pilot_mismatch_recon"):
            scn = _scenario(sname, seed)
            cls_actor = {
                "INFANTRY": "B_INF_1", "SPEARMAN": "B_SPR_1", "CAVALRY": "B_CAV_1",
                "ARCHER": "B_ARC_1", "SCOUT": "B_SCT_1",
            }
            for cls, actor_id in cls_actor.items():
                if cls == "CAVALRY" and sname != "pilot_even_seek":
                    continue  # scenario has no blue cavalry; keep coverage explicit
                try:
                    records.append(build_record(scn, profile, actor_id,
                                                horizon=8, seed=seed))
                except KeyError:
                    continue  # class not present in this scenario
    return records


def write_pilot_dataset(path: str) -> dict:
    records = generate_pilot_dataset()
    n = write_jsonl(path, records)
    classes = sorted({r["actor_class"] for r in records})
    skills = sorted({ps["skill_name"] for r in records for ps in r["per_skill"]})
    profiles = sorted({r["profile"] for r in records})
    return {
        "path": path,
        "records": n,
        "profiles": profiles,
        "classes": classes,
        "skills_covered": skills,
        "n_skills_covered": len(skills),
    }


__all__ = [
    "build_record",
    "generate_pilot_dataset",
    "write_pilot_dataset",
]
