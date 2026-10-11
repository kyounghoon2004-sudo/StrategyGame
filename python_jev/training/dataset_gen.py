"""T0 full-information dataset generator (jev-fullinfo-dataset-v0.1.0).

Supervised corpus: decision states sampled along scripted battles, each
labeled with six-way counterfactual Q (ValueTargetV0, horizon 8,
SimpleAttackElseAdvancePolicy continuation) converted to soft PolicyTargetV0
preferences.

Full information ONLY: DEV_FLAT_ALL_INFO / TERRAIN_FULL_INFO. Any other
profile is rejected at build time and at load time.

Split discipline: SCENARIOS are split first (75 / 12.5 / 12.5); all states
of one battle stay in exactly one split. Deterministic for a fixed
(DATASET_SEED, N_SCENARIOS, collection config) triple.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import time

import torch

from python_jev.dataset.schema import FULL_INFO_PROFILES
from python_jev.training.policy_target import (
    POLICY_TARGET_VERSION,
    content_hash as policy_target_hash,
    soft_targets_from_q,
    validate_targets,
)
from python_jev.training.scenarios import (
    LEARNED_SPAWN_CLASSES,
    SCENARIO_GENERATOR_VERSION,
    generate_scenario,
    mission_context_for_side,
)

DATASET_VERSION = "jev-fullinfo-dataset-v0.1.0"
DATASET_SEED = 20260919
SPLIT_SEED = 0x70A1
TRAIN_FRACTION = 0.75
VAL_FRACTION = 0.125

# canonical v0 training continuation (frozen for the primary target)
TRAIN_CONTINUATION_POLICY = "SimpleAttackElseAdvancePolicy"
TRAIN_HORIZON_DECISIONS = 8
COLLECTION_POLICY = "SimpleAttackElseAdvancePolicy"
MAX_COLLECT_TURNS = 12
MAX_STATES_PER_SCENARIO = 64

PARTIAL_INFO_PROFILES = ("FLAT_FOG", "TERRAIN_FOG", "MORALE_COMBAT", "FULL_PRODUCTION")


# ------------------------------------------------------------ configuration
def dataset_config(class_counts_hint: str = "") -> dict:
    return {
        "dataset_version": DATASET_VERSION,
        "dataset_seed": DATASET_SEED,
        "split_seed": SPLIT_SEED,
        "train_fraction": TRAIN_FRACTION,
        "val_fraction": VAL_FRACTION,
        "continuation_policy": TRAIN_CONTINUATION_POLICY,
        "horizon_decisions": TRAIN_HORIZON_DECISIONS,
        "collection_policy": COLLECTION_POLICY,
        "max_collect_turns": MAX_COLLECT_TURNS,
        "max_states_per_scenario": MAX_STATES_PER_SCENARIO,
        "allowed_profiles": list(FULL_INFO_PROFILES),
        "full_information_only": True,
        "scenario_generator": SCENARIO_GENERATOR_VERSION,
    }


def contract_pins() -> dict:
    """Live contract pins — every record and shard carries these verbatim."""
    from python_jev.contracts import hex_patch as hex_patch_c
    from python_jev.contracts import observation_layout as ol
    from python_jev.contracts import ruleset as rs
    from python_sim import SIM_VERSION
    from python_sim.rollout import branch_snapshot, mission_progress, objective_progress
    from python_sim.rollout import terminal as terminal_c
    from python_sim.rollout.config import (
        CONTINUATION_POLICY_VERSION,
        ROLLOUT_CONFIG_VERSION,
    )
    from python_sim.rollout.engine import ROLLOUT_ENGINE_VERSION
    from python_sim.rollout.outcome import OUTCOME_VECTOR_VERSION_V2
    from python_sim.rollout.value_target import VALUE_TARGET_VERSION
    from python_sim.skills.contracts import (
        FAILURE_CODE_VERSION,
        MODES_VERSION,
        SKILL_CONTRACT_VERSION,
    )
    from python_sim.skills.contracts import content_hash as skill_modes_hash
    from python_sim.trajectory.recorder import TRAJECTORY_FORMAT_VERSION

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
        "rollout_engine_version": ROLLOUT_ENGINE_VERSION,
        "continuation_policy_version": CONTINUATION_POLICY_VERSION,
        "outcome_vector_version": OUTCOME_VECTOR_VERSION_V2,
        "terminal_version": terminal_c.TERMINAL_OUTCOME_VERSION,
        "terminal_hash": terminal_c.content_hash(),
        "mission_progress_version": mission_progress.MISSION_PROGRESS_VERSION,
        "mission_progress_hash": mission_progress.content_hash(),
        "objective_progress_version": objective_progress.OBJECTIVE_PROGRESS_VERSION,
        "objective_progress_hash": objective_progress.content_hash(),
        "branch_snapshot_version": branch_snapshot.BRANCH_SNAPSHOT_VERSION,
        "branch_snapshot_hash": branch_snapshot.content_hash(),
        "value_target_version": VALUE_TARGET_VERSION,
        "policy_target_version": POLICY_TARGET_VERSION,
        "policy_target_hash": policy_target_hash(),
        "trajectory_format_version": TRAJECTORY_FORMAT_VERSION,
        "dataset_version": DATASET_VERSION,
        "scenario_generator_version": SCENARIO_GENERATOR_VERSION,
    }


# ------------------------------------------------------------ split plan
def split_plan(n_scenarios: int) -> dict[int, dict]:
    """Scenario index -> {"split": train|validation|test, "profile": ...}.

    Shuffle is seeded and fixed; capital_push forces TERRAIN_FULL_INFO;
    every other scenario alternates profiles along shuffled order inside
    its split (balanced per split).
    """
    import random

    order = list(range(n_scenarios))
    random.Random(SPLIT_SEED).shuffle(order)
    n_train = int(n_scenarios * TRAIN_FRACTION)
    n_val = int(n_scenarios * VAL_FRACTION)
    plan: dict[int, dict] = {}
    counters = {"train": 0, "validation": 0, "test": 0}
    for rank, idx in enumerate(order):
        if rank < n_train:
            split = "train"
        elif rank < n_train + n_val:
            split = "validation"
        else:
            split = "test"
        fam_id = generate_scenario(idx)["meta"]["family"]
        if fam_id == "capital_push":
            profile = "TERRAIN_FULL_INFO"
        else:
            profile = "DEV_FLAT_ALL_INFO" if counters[split] % 2 == 0 else "TERRAIN_FULL_INFO"
        counters[split] += 1
        plan[idx] = {"split": split, "profile": profile}
    return plan


def ood_plan(n_scenarios: int) -> dict[int, dict]:
    import random

    plan: dict[int, dict] = {}
    for idx in range(n_scenarios):
        profile = "DEV_FLAT_ALL_INFO" if idx % 2 == 0 else "TERRAIN_FULL_INFO"
        plan[idx] = {"split": "generalization_test", "profile": profile}
    return plan


# ------------------------------------------------------------ collection
def _eligible_actor_ids(battle) -> tuple[list[str], list[str]]:
    blue, red = [], []
    for uid in sorted(battle.world.units.keys()):
        u = battle.world.units[uid]
        if u.unit_class not in LEARNED_SPAWN_CLASSES:
            continue
        if u.soldier_count <= 0 or u.action_ended or u.garrisoned:
            continue
        (blue if u.faction == "blue" else red).append(uid)
    return blue, red


def collect_scenario_records(
    index: int,
    profile: str,
    split: str,
    ood: bool = False,
) -> list[dict]:
    """Play one scenario forward; sample decision states with six-way Q."""
    import json as _json

    from python_jev.training.projection import project_for_training
    from python_sim.observation.projector import ObservationProjector
    from python_sim.policies import SimpleAttackElseAdvancePolicy
    from python_sim.rollout.engine import CounterfactualEngine, state_hash
    from python_sim.rollout.value_target import q_export_status
    from python_sim.sim.battle import Battle
    from python_sim.skills.context import MissionContext

    if profile not in FULL_INFO_PROFILES:
        raise ValueError(f"forbidden non-full-info profile in dataset: {profile!r}")
    gen = generate_scenario(index, ood=ood)
    scenario = gen["scenario"]
    meta = gen["meta"]
    pins = contract_pins()
    battle = Battle(_json.loads(_json.dumps(scenario)), profile, seed=scenario["seed"])
    blue_ctx = MissionContext(**mission_context_for_side(scenario, "blue"))
    red_ctx = MissionContext(**mission_context_for_side(scenario, "red"))
    engine = CounterfactualEngine.from_name(
        TRAIN_CONTINUATION_POLICY, TRAIN_HORIZON_DECISIONS, scenario["seed"])
    driver = SimpleAttackElseAdvancePolicy()
    projector = ObservationProjector(battle)
    cls_map = {"infantry": "INFANTRY", "spearman": "SPEARMAN", "cavalry": "CAVALRY",
               "archer": "ARCHER", "scout": "SCOUT"}

    records: list[dict] = []
    decision_index = 0
    for _turn in range(MAX_COLLECT_TURNS):
        if battle.evaluate_mission()["mission_status"] != "ongoing":
            break
        blue_ids, red_ids = _eligible_actor_ids(battle)
        for side, ids, ctx in (("blue", blue_ids, blue_ctx), ("red", red_ids, red_ctx)):
            for actor_id in ids:
                if len(records) >= MAX_STATES_PER_SCENARIO:
                    break
                u = battle.world.units.get(actor_id)
                if u is None or u.soldier_count <= 0 or u.action_ended:
                    continue
                if battle.evaluate_mission()["mission_status"] != "ongoing":
                    break
                ev = engine.evaluate(battle, actor_id, ctx)
                if not any(ev.legal_mask):
                    action = (driver.blue_action if side == "blue" else driver.red_action)(
                        battle, actor_id)
                    continue  # all-illegal: no target distribution exists
                proj = project_for_training(projector, side, actor_id, ctx)
                q_values = [ev.branches[s].outcome_scalar for s in range(6)]
                assert q_export_status(profile) == "OK"
                targets = soft_targets_from_q(q_values, list(ev.q_valid_mask))
                record = {
                    "dataset_version": DATASET_VERSION,
                    "full_information_only": True,
                    "profile": profile,
                    "split": split,
                    "scenario_id": scenario["scenario_id"],
                    "scenario_seed": scenario["seed"],
                    "scenario_family": meta["family"],
                    "scenario_ood": bool(ood),
                    "mission_type": scenario["mission_contract"]["primary_objective"],
                    "ratio_group": meta["ratio_group"],
                    "formation": meta["formation"],
                    "spacing": meta["spacing"],
                    "actor_id": actor_id,
                    "actor_class": cls_map[u.unit_class],
                    "acting_side": side,
                    "turn": int(battle.world.current_turn),
                    "decision_index": decision_index,
                    "state_hash": ev.decision_state_hash,
                    "observation": {
                        "actor_features": [float(x) for x in proj.actor_features],
                        "tokens": [[float(x) for x in t] for t in proj.tokens],
                        "token_padding_mask": [bool(x) for x in proj.token_padding_mask],
                        "hex_patch": [[float(x) for x in h] for h in proj.hex_patch],
                        "mission_features": [float(x) for x in proj.mission_features],
                        "global_features": [float(x) for x in proj.global_features],
                        "acting_class_idx": int(proj.acting_class_idx),
                    },
                    "legal_mask": [bool(x) for x in ev.legal_mask],
                    "q_valid_mask": [bool(x) for x in ev.q_valid_mask],
                    "q_values": q_values,
                    "p_target": targets,
                    "continuation_policy": TRAIN_CONTINUATION_POLICY,
                    "horizon_decisions": TRAIN_HORIZON_DECISIONS,
                    "contract_versions": dict(pins),
                }
                problems = validate_record(record, pins)
                if problems:
                    raise ValueError(f"invalid record {scenario['scenario_id']}:{decision_index}: {problems}")
                records.append(record)
                decision_index += 1
                (driver.blue_action if side == "blue" else driver.red_action)(battle, actor_id)
            if len(records) >= MAX_STATES_PER_SCENARIO:
                break
        battle.sim_end_turn()
    return records


def validate_record(record: dict, expected_pins: dict | None = None) -> list[str]:
    """Full DATA VALIDATION gate. Empty list == valid."""
    problems: list[str] = []
    if record.get("dataset_version") != DATASET_VERSION:
        problems.append(f"dataset_version must be {DATASET_VERSION}")
    if record.get("full_information_only") is not True:
        problems.append("full_information_only must be true")
    profile = record.get("profile")
    if profile not in FULL_INFO_PROFILES:
        problems.append(f"partial-information profile forbidden: {profile!r}")
    if record.get("split") not in ("train", "validation", "test", "generalization_test"):
        problems.append(f"bad split: {record.get('split')!r}")
    for key in ("scenario_id", "scenario_seed", "scenario_family", "mission_type",
                "actor_id", "actor_class", "acting_side"):
        if record.get(key) in (None, ""):
            problems.append(f"missing provenance: {key}")

    obs = record.get("observation", {})
    dims = {"actor_features": 67, "tokens": (24, 37), "hex_patch": (91, 33),
            "mission_features": 46, "global_features": 31}
    for key, dim in dims.items():
        v = obs.get(key)
        flat = [x for row in (v if isinstance(dim, tuple) else [v]) for x in (row or [])] \
            if v is not None else None
        n = len(flat) if flat is not None else -1
        want = (dim[0] * dim[1]) if isinstance(dim, tuple) else dim
        if n != want:
            problems.append(f"observation.{key} has {n} values, want {want}")
        elif any(not isinstance(x, (int, float)) or not math.isfinite(x) for x in flat):
            problems.append(f"observation.{key} has NaN/Inf/non-numeric")
    if len(obs.get("token_padding_mask", [])) != 24:
        problems.append("token_padding_mask must have 24 bits")
    if record.get("acting_class_idx", obs.get("acting_class_idx")) not in (0, 1, 2, 3, 4):
        problems.append("acting_class_idx must be in [0,5)")

    legal = record.get("legal_mask", [])
    q_valid = record.get("q_valid_mask", [])
    q_values = record.get("q_values", [])
    if len(legal) != 6 or len(q_valid) != 6 or len(q_values) != 6:
        problems.append("legal/q_valid/q_values must all have 6 entries")
        return problems
    if [bool(x) for x in q_valid] != [bool(x) for x in legal]:
        problems.append("full-info q_valid_mask must equal legal_mask")
    for s in range(6):
        qv = q_values[s]
        if q_valid[s]:
            if not isinstance(qv, (int, float)) or not math.isfinite(qv):
                problems.append(f"q_values[{s}] must be finite for a valid branch")
        elif qv is not None:
            problems.append(f"q_values[{s}] must be None for an invalid branch")
    problems.extend(
        f"p_target: {p}" for p in validate_targets(record.get("p_target", []), [bool(x) for x in q_valid])
    )
    cv = record.get("contract_versions", {})
    if expected_pins is not None:
        for k, want in expected_pins.items():
            if cv.get(k) != want:
                problems.append(f"contract pin mismatch: {k}")
    else:
        for k in ("sim_version", "ruleset_version", "observation_layout_version",
                  "skill_contract_version", "rollout_engine_version", "value_target_version",
                  "policy_target_version", "terminal_version", "mission_progress_version",
                  "objective_progress_version", "branch_snapshot_version"):
            if k not in cv:
                problems.append(f"contract_versions missing: {k}")
    return problems


# ------------------------------------------------------------ sharding
TENSOR_KEYS = ("actor", "tokens", "token_pad", "hex", "mission", "global",
               "class_idx", "legal", "q", "q_valid", "p_target")


def records_to_tensors(records: list[dict]) -> dict[str, torch.Tensor]:
    n = len(records)
    actor = torch.zeros(n, 67, dtype=torch.float32)
    tokens = torch.zeros(n, 24, 37, dtype=torch.float32)
    token_pad = torch.zeros(n, 24, dtype=torch.bool)
    hexp = torch.zeros(n, 91, 33, dtype=torch.float32)
    mission = torch.zeros(n, 46, dtype=torch.float32)
    glob = torch.zeros(n, 31, dtype=torch.float32)
    class_idx = torch.zeros(n, dtype=torch.long)
    legal = torch.zeros(n, 6, dtype=torch.bool)
    q = torch.zeros(n, 6, dtype=torch.float32)
    q_valid = torch.zeros(n, 6, dtype=torch.bool)
    p_target = torch.zeros(n, 6, dtype=torch.float32)
    for i, r in enumerate(records):
        o = r["observation"]
        actor[i] = torch.tensor(o["actor_features"], dtype=torch.float32)
        tokens[i] = torch.tensor(o["tokens"], dtype=torch.float32)
        token_pad[i] = torch.tensor(o["token_padding_mask"], dtype=torch.bool)
        hexp[i] = torch.tensor(o["hex_patch"], dtype=torch.float32)
        mission[i] = torch.tensor(o["mission_features"], dtype=torch.float32)
        glob[i] = torch.tensor(o["global_features"], dtype=torch.float32)
        class_idx[i] = int(o["acting_class_idx"])
        legal[i] = torch.tensor(r["legal_mask"], dtype=torch.bool)
        q_valid[i] = torch.tensor(r["q_valid_mask"], dtype=torch.bool)
        q[i] = torch.tensor([v if v is not None else 0.0 for v in r["q_values"]],
                            dtype=torch.float32)
        p_target[i] = torch.tensor(r["p_target"], dtype=torch.float32)
    return {"actor": actor, "tokens": tokens, "token_pad": token_pad, "hex": hexp,
            "mission": mission, "global": glob, "class_idx": class_idx,
            "legal": legal, "q": q, "q_valid": q_valid, "p_target": p_target}


def provenance_of(records: list[dict]) -> list[dict]:
    keys = ("scenario_id", "scenario_seed", "scenario_family", "scenario_ood",
            "mission_type", "ratio_group", "formation", "spacing", "profile", "split",
            "actor_id", "actor_class", "acting_side", "turn", "decision_index",
            "state_hash", "continuation_policy", "horizon_decisions")
    return [{k: r[k] for k in keys} for r in records]


def shard_hash(tensors: dict[str, torch.Tensor], provenance: list[dict]) -> str:
    h = hashlib.sha256()
    for k in sorted(tensors):
        t = tensors[k].contiguous().cpu()
        h.update(k.encode("utf-8"))
        # NOTE: bytes(UntypedStorage) iterates element-wise (minutes); the
        # numpy bulk path below hashes identical tensor bytes in ms.
        h.update(t.numpy().tobytes())
    h.update(json.dumps(provenance, sort_keys=True, separators=(",", ":")).encode("utf-8"))
    return h.hexdigest()


def save_shard(path: str, split: str, records: list[dict], pins: dict) -> dict:
    tensors = records_to_tensors(records)
    prov = provenance_of(records)
    digest = shard_hash(tensors, prov)
    payload = {
        "dataset_version": DATASET_VERSION,
        "split": split,
        "n_records": len(records),
        "config": dataset_config(),
        "contract_versions": dict(pins),
        "tensors": tensors,
        "provenance": prov,
        "shard_hash": digest,
    }
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    torch.save(payload, path)
    return {"path": path, "split": split, "records": len(records), "shard_hash": digest}


def load_shard(path: str, verify: bool = True) -> dict:
    payload = torch.load(path, map_location="cpu", weights_only=False)
    if payload.get("dataset_version") != DATASET_VERSION:
        raise ValueError(f"{path}: dataset_version {payload.get('dataset_version')!r}")
    if verify:
        digest = shard_hash(payload["tensors"], payload["provenance"])
        if digest != payload.get("shard_hash"):
            raise ValueError(f"{path}: shard hash mismatch (corrupt or tampered)")
    return payload


# ------------------------------------------------------------ orchestration
def _collect_job(job: tuple[int, str, str, bool]) -> list[dict]:
    index, profile, split, ood = job
    return collect_scenario_records(index, profile, split, ood=ood)


def generate_dataset(
    n_scenarios: int,
    out_dir: str,
    n_workers: int = 0,
    ood_scenarios: int = 0,
    audit_records: int = 40,
) -> dict:
    """Generate the full corpus: scenario split -> collect -> validate -> shard.

    n_workers=0/1: single process. >1: process pool over scenarios (results
    re-sorted by (split, scenario_id, decision_index) — deterministic).
    """
    from concurrent.futures import ProcessPoolExecutor

    t_start = time.perf_counter()
    pins = contract_pins()
    plan = split_plan(n_scenarios)
    jobs = [(i, plan[i]["profile"], plan[i]["split"], False) for i in range(n_scenarios)]
    if ood_scenarios:
        ood = ood_plan(ood_scenarios)
        jobs += [(i, ood[i]["profile"], ood[i]["split"], True) for i in range(ood_scenarios)]

    if n_workers and n_workers > 1:
        with ProcessPoolExecutor(max_workers=n_workers) as pool:
            batches = list(pool.map(_collect_job, jobs))
    else:
        batches = [_collect_job(j) for j in jobs]

    by_split: dict[str, list[dict]] = {}
    for recs in batches:
        for r in recs:
            by_split.setdefault(r["split"], []).append(r)
    for split in by_split:
        by_split[split].sort(key=lambda r: (r["scenario_id"], r["decision_index"]))

    os.makedirs(out_dir, exist_ok=True)
    shards = {}
    for split in sorted(by_split):
        path = os.path.join(out_dir, f"{split}.pt")
        shards[split] = save_shard(path, split, by_split[split], pins)

    # human-readable audit sample (train head, rounded)
    audit_path = os.path.join(out_dir, "audit_sample.jsonl")
    audit = []
    for r in by_split.get("train", [])[:audit_records]:
        audit.append(_rounded_record(r))
    from python_jev.dataset.schema import write_jsonl
    write_jsonl(audit_path, audit)

    wall = time.perf_counter() - t_start
    total = sum(len(v) for v in by_split.values())
    manifest = {
        "dataset_version": DATASET_VERSION,
        "config": dataset_config(),
        "contract_versions": pins,
        "n_scenarios": n_scenarios,
        "n_ood_scenarios": ood_scenarios,
        "n_workers": n_workers,
        "splits": {s: {"records": len(v), "scenarios": len({r["scenario_id"] for r in v})}
                   for s, v in sorted(by_split.items())},
        "total_records": total,
        "wall_seconds": wall,
        "states_per_second": (total / wall) if wall > 0 else 0.0,
        "shards": shards,
        "audit_sample": {"path": audit_path, "records": len(audit)},
    }
    with open(os.path.join(out_dir, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
    return manifest


def _rounded_record(record: dict, ndigits: int = 4) -> dict:
    out = {k: v for k, v in record.items() if k != "observation"}
    obs = record["observation"]

    def rnd(x):
        return round(float(x), ndigits)

    def rnd_list(v):
        return [rnd(x) if not isinstance(x, list) else [rnd(y) for y in x] for x in v]

    out["observation"] = {
        "actor_features": rnd_list(obs["actor_features"]),
        "tokens": rnd_list(obs["tokens"]),
        "token_padding_mask": list(obs["token_padding_mask"]),
        "hex_patch": rnd_list(obs["hex_patch"]),
        "mission_features": rnd_list(obs["mission_features"]),
        "global_features": rnd_list(obs["global_features"]),
        "acting_class_idx": int(obs["acting_class_idx"]),
    }
    out["q_values"] = [None if v is None else rnd(v) for v in record["q_values"]]
    out["p_target"] = [rnd(v) for v in record["p_target"]]
    return out


__all__ = [
    "COLLECTION_POLICY",
    "DATASET_SEED",
    "DATASET_VERSION",
    "MAX_COLLECT_TURNS",
    "MAX_STATES_PER_SCENARIO",
    "PARTIAL_INFO_PROFILES",
    "SPLIT_SEED",
    "TENSOR_KEYS",
    "TRAIN_CONTINUATION_POLICY",
    "TRAIN_FRACTION",
    "TRAIN_HORIZON_DECISIONS",
    "VAL_FRACTION",
    "collect_scenario_records",
    "contract_pins",
    "dataset_config",
    "generate_dataset",
    "load_shard",
    "ood_plan",
    "provenance_of",
    "records_to_tensors",
    "save_shard",
    "shard_hash",
    "split_plan",
    "validate_record",
]
