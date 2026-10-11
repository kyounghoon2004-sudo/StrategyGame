"""D0 Part A — matched state-distribution collection (read-only).

Five source policies drive the SAME 60 matched scenarios (24 test + 24
train + 12 OOD, 12-turn / 64-state caps, mask v0.2.0 skip rule):

  simple  — SimpleAttackElseAdvancePolicy (dataset canonical continuation)
  random  — RandomLegalPolicy(seed=123 per scenario, benchmark convention)
  hold    — HoldPolicy
  jev_old — JevPolicyV0 v0.1.0-fi seed43, both seats, mask v0.2.0
  jev_new — JevPolicyV0 v0.2.0-fi seed43, both seats, mask v0.2.0

plus iid_test — the test-scenario rows of the simple collection, stored as
their own immutable set and verified against jev-fullinfo-dataset-v0.2.0
test shard state hashes.

Per decision state each worker records: full observation, v0.2 legal mask,
Q under all three continuations (Simple/Random/Hold, horizon 8,
ValueTargetV0), old+new JEV selections, a trial execution of the NEW
selection (INVALID must be zero), interpretable features, and full
provenance. Sets are written as hashed .pt files; rows never move sets
without an explicit relabel.
"""

from __future__ import annotations

import hashlib
import json
import os
from concurrent.futures import ProcessPoolExecutor

import torch

DIAG_VERSION = "jev-target-diagnostic-v0.1.0"
SETS = ("simple", "random", "hold", "jev_old", "jev_new", "iid_test")
SOURCE_POLICY = {
    "simple": "SimpleAttackElseAdvancePolicy",
    "random": "RandomLegalPolicy",
    "hold": "HoldPolicy",
    "jev_old": "JevPolicyV0/jev-policy-v0.1.0-fi/seed43",
    "jev_new": "JevPolicyV0/jev-policy-v0.2.0-fi/seed43",
    "iid_test": "SimpleAttackElseAdvancePolicy/test-scenarios-only",
    # A1 aggregation sets (analyzed by python_jev.aggregate, not D0 loops).
    "dagger1": "JevPolicyV0/jev-policy-v0.2.0-fi/seed43/dagger1-train",
    "visited_validation": "JevPolicyV0/jev-policy-v0.2.0-fi/seed43/visited-validation",
    "visited_test": "JevPolicyV0/selected-v0.3/visited-test",
    "drift_old": "JevPolicyV0/jev-policy-v0.2.0-fi/seed43/drift",
    "drift_new": "JevPolicyV0/selected-v0.3/drift",
    # A2 round-2 sets (analyzed by python_jev.aggregate, not D0 loops).
    "dagger2": "JevPolicyV0/jev-policy-v0.3.0-fi-dagger1/seed43/dagger2-train",
    "drift_v04": "JevPolicyV0/selected-v0.4/drift",
    # A3 round-3 sets (analyzed by python_jev.aggregate, not D0 loops).
    "dagger3": "JevPolicyV0/jev-policy-v0.4.0-fi-dagger2/seed44/dagger3-train",
    "visited_v04": "JevPolicyV0/jev-policy-v0.4.0-fi-dagger2/seed44/visited-validation",
    "visited_test_v05": "JevPolicyV0/selected-v0.5/visited-test",
    "drift_v05": "JevPolicyV0/selected-v0.5/drift",
}
TEACHERS = ("SimpleAttackElseAdvancePolicy", "RandomLegalPolicy", "HoldPolicy")

MAX_TURNS = 12
MAX_STATES = 64
N_WORKERS = 12

FEATURE_NAMES = (
    "turn", "trajectory_step", "side_blue", "legal_count",
    "blue_live", "red_live", "strength_ratio", "actor_soldiers",
    "visible_enemies", "stale_contacts", "has_contact",
    "min_enemy_dist", "mean_enemy_dist",
    "min_friendly_dist", "mean_friendly_dist",
    "frac_plains", "frac_forest", "frac_mountain", "frac_swamp",
    "frac_other_terrain", "patch_friendly", "patch_enemy",
    "remaining_mp", "has_attacked",
    "dist_advance_anchor", "dist_withdraw_anchor",
    "policy_entropy_new",
)


def matched_jobs() -> list[tuple[int, str, bool, str]]:
    """60 matched (index, profile, ood, split) jobs. Deterministic."""
    from python_jev.training.dataset_gen import ood_plan, split_plan

    plan = split_plan(192)
    ood = ood_plan(48)
    test_idx = sorted(i for i in range(192) if plan[i]["split"] == "test")
    train_idx = sorted(i for i in range(192) if plan[i]["split"] == "train")[:24]
    ood_idx = list(range(0, 48, 4))[:12]
    jobs = [(i, plan[i]["profile"], False, plan[i]["split"])
            for i in (test_idx + train_idx)]
    jobs += [(i, ood[i]["profile"], True, "generalization_test") for i in ood_idx]
    return jobs


def collect_job(job: tuple) -> dict:
    """Replay one scenario under one source policy; return its rows.

    A1 hook (additive): an optional 8th element ``extra`` dict supports
    ``driver_ckpt`` (drive with that checkpoint instead of the set default),
    ``driver_label`` (provenance note), and ``max_states`` (per-scenario cap
    override). Absent, behavior is D0-identical.
    """
    import json as _json
    import math

    import torch as _torch

    _torch.set_num_threads(1)
    set_name, index, profile, ood, split, ckpt_old, ckpt_new = job[:7]
    extra = job[7] if len(job) > 7 else None

    from python_jev.model import JevPolicyV0
    from python_jev.training.checkpoint import load_checkpoint
    from python_jev.training.closedloop import JevDriver
    from python_jev.training.dataset_gen import _eligible_actor_ids
    from python_jev.training.inference import batch_from_projection, select_slot
    from python_jev.training.projection import project_for_training
    from python_jev.training.scenarios import generate_scenario, mission_context_for_side
    from python_sim.observation.projector import ObservationProjector
    from python_sim.policies import (
        HoldPolicy,
        RandomLegalPolicy,
        SimpleAttackElseAdvancePolicy,
    )
    from python_sim.rollout.config import RolloutConfig
    from python_sim.rollout.engine import CounterfactualEngine, state_hash
    from python_sim.sim.battle import Battle
    from python_sim.skills.context import MissionContext
    from python_sim.skills.registry import execute_skill

    from python_jev.retrain.rebuild_v2 import new_mask_fn

    old_model = JevPolicyV0().eval()
    load_checkpoint(ckpt_old, old_model)
    new_model = JevPolicyV0().eval()
    load_checkpoint(ckpt_new, new_model)
    engines = {p: CounterfactualEngine(RolloutConfig(
        continuation_policy=p, red_policy=p, horizon_decisions=8, seed=7))
        for p in TEACHERS}

    gen = generate_scenario(index, ood=ood)
    scenario = gen["scenario"]
    battle = Battle(_json.loads(_json.dumps(scenario)), profile,
                    seed=scenario["seed"])
    ctxs = {"blue": MissionContext(**mission_context_for_side(scenario, "blue")),
            "red": MissionContext(**mission_context_for_side(scenario, "red"))}
    if extra is not None and extra.get("driver_ckpt"):
        drv_model = JevPolicyV0().eval()
        load_checkpoint(extra["driver_ckpt"], drv_model)
        driver = JevDriver(drv_model, "cpu", ctxs["blue"], ctxs["red"],
                           mask_fn=new_mask_fn)
    elif set_name == "simple":
        driver = SimpleAttackElseAdvancePolicy()
    elif set_name == "random":
        driver = RandomLegalPolicy(seed=123)
    elif set_name == "hold":
        driver = HoldPolicy()
    elif set_name == "jev_old":
        driver = JevDriver(old_model, "cpu", ctxs["blue"], ctxs["red"],
                           mask_fn=new_mask_fn)
    elif set_name == "jev_new":
        driver = JevDriver(new_model, "cpu", ctxs["blue"], ctxs["red"],
                           mask_fn=new_mask_fn)
    else:
        raise ValueError(f"unknown set {set_name}")
    projector = ObservationProjector(battle)

    cls_map = {"infantry": "INFANTRY", "spearman": "SPEARMAN", "cavalry": "CAVALRY",
               "archer": "ARCHER", "scout": "SCOUT"}
    rows: list[dict] = []
    skipped = 0
    n_states = 0
    cap = int((extra or {}).get("max_states", MAX_STATES))
    for _turn in range(MAX_TURNS):
        if battle.evaluate_mission()["mission_status"] != "ongoing":
            break
        blue_ids, red_ids = _eligible_actor_ids(battle)
        for side, ids in (("blue", blue_ids), ("red", red_ids)):
            for actor_id in ids:
                if n_states >= cap:
                    break
                u = battle.world.units.get(actor_id)
                if u is None or u.soldier_count <= 0 or u.action_ended:
                    continue
                if battle.evaluate_mission()["mission_status"] != "ongoing":
                    break
                step = (driver.blue_action if side == "blue" else driver.red_action)
                legal = [bool(x) for x in new_mask_fn(battle, actor_id, ctxs[side])]
                if not any(legal):
                    skipped += 1
                    step(battle, actor_id)
                    continue
                proj = project_for_training(projector, side, actor_id, ctxs[side])
                batch = batch_from_projection(proj, legal)
                sel_old = select_slot(old_model, batch, "cpu")
                sel_new = select_slot(new_model, batch, "cpu")
                evs = {p: engines[p].evaluate(battle, actor_id, ctxs[side],
                                              mask_fn=new_mask_fn) for p in TEACHERS}
                q = {p: [(float(evs[p].branches[s].outcome_scalar)
                          if legal[s] else None) for s in range(6)] for p in TEACHERS}
                new_slot = int(sel_new["selected_slot"][0])
                env = execute_skill(battle.clone(), actor_id,
                                    cls_map[u.unit_class], new_slot, ctxs[side])
                probs_new = [float(x) for x in sel_new["probabilities"][0]]
                ent_new = -sum(p * math.log(p) for p in probs_new if p > 0)
                feats = extract_features(battle, actor_id, side, ctxs[side],
                                         legal, ent_new)
                obs = {
                    "actor_features": [float(x) for x in proj.actor_features],
                    "tokens": [[float(x) for x in t] for t in proj.tokens],
                    "token_padding_mask": [bool(x) for x in proj.token_padding_mask],
                    "hex_patch": [[float(x) for x in h] for h in proj.hex_patch],
                    "mission_features": [float(x) for x in proj.mission_features],
                    "global_features": [float(x) for x in proj.global_features],
                    "acting_class_idx": int(proj.acting_class_idx),
                }
                rows.append({
                    "set": set_name,
                    "scenario_id": scenario["scenario_id"],
                    "scenario_seed": scenario["seed"],
                    "scenario_index": index,
                    "scenario_ood": bool(ood),
                    "split": split,
                    "profile": profile,
                    "mission": str(scenario["mission_contract"]["primary_objective"]),
                    "turn": int(battle.world.current_turn),
                    "trajectory_step": n_states,
                    "actor_id": actor_id,
                    "actor_class": cls_map[u.unit_class],
                    "side": side,
                    "state_hash": state_hash(battle),
                    "obs_hash": _obs_hash(obs),
                    "observation": obs,
                    "legal": legal,
                    "teacher_q": q,
                    "sel_old": int(sel_old["selected_slot"][0]),
                    "prob_old": [float(x) for x in sel_old["probabilities"][0]],
                    "sel_new": new_slot,
                    "prob_new": probs_new,
                    "trial_exec_status": str(env.get("status", "UNKNOWN")),
                    "trial_failure_code": str(env.get("failure_code", "NONE")),
                    "features": feats,
                })
                n_states += 1
                step(battle, actor_id)
            if n_states >= cap:
                break
        battle.sim_end_turn()
    return {"set": set_name, "scenario_id": scenario["scenario_id"],
            "rows": rows, "skipped_all_illegal": skipped}


def _obs_hash(obs: dict) -> str:
    h = hashlib.sha256()
    for k in ("actor_features", "tokens", "token_padding_mask", "hex_patch",
              "mission_features", "global_features", "acting_class_idx"):
        h.update(json.dumps(obs[k], sort_keys=True).encode("utf-8"))
    return h.hexdigest()


def extract_features(battle, actor_id: str, side: str, ctx, legal: list[bool],
                     entropy_new: float) -> list[float]:
    """Interpretable numeric features (FEATURE_NAMES order). Pure readout."""
    from python_sim.rules import geometry
    from python_sim.skills.common import (
        friendly_units,
        knowledge_of,
        visible_enemies,
    )

    u = battle.world.units[actor_id]
    ud = u.to_dict()
    aq, ar = int(u.q), int(u.r)
    vis = visible_enemies(battle, side)
    friends = [f for f in friendly_units(battle, side) if f["id"] != actor_id]
    de = [geometry.hex_distance_axial((aq, ar), (int(e["q"]), int(e["r"])))
          for e in vis]
    df = [geometry.hex_distance_axial((aq, ar), (int(f["q"]), int(f["r"])))
          for f in friends]
    blue_live = sum(x.soldier_count for x in battle.world.units.values()
                    if x.faction == "blue")
    red_live = sum(x.soldier_count for x in battle.world.units.values()
                   if x.faction == "red")
    terr = {"plains": 0, "forest": 0, "mountain": 0, "swamp": 0, "other": 0}
    total = 0
    for dq in range(-5, 6):
        for dr in range(-5, 6):
            if abs(dq) + abs(dr) + abs(dq + dr) > 10:
                continue
            cell = battle.world.cell_data.get(f"{aq + dq},{ar + dr}")
            if cell is None:
                continue
            total += 1
            t = int(cell["terrain"])
            if t == 0:
                terr["plains"] += 1
            elif t == 2:
                terr["forest"] += 1
            elif t == 1:
                terr["mountain"] += 1
            elif t == 3:
                terr["swamp"] += 1
            else:
                terr["other"] += 1
    total = max(1, total)
    pf = pe = 0
    for x in battle.world.units.values():
        if x.soldier_count <= 0 or x.garrisoned or x.id == actor_id:
            continue
        if geometry.hex_distance_axial((aq, ar), (int(x.q), int(x.r))) <= 5:
            if x.faction == side:
                pf += 1
            else:
                pe += 1
    kn = knowledge_of(battle, side)
    adv = getattr(ctx, "advance_anchor", None)
    wdn = getattr(ctx, "withdraw_anchor", None)
    return [
        float(battle.world.current_turn),
        0.0,  # trajectory_step filled by the caller-facing assembler
        1.0 if side == "blue" else 0.0,
        float(sum(legal)),
        float(blue_live),
        float(red_live),
        float(blue_live) / max(1.0, float(red_live)),
        float(u.soldier_count),
        float(len(vis)),
        float(len(kn.stale_contacts)),
        1.0 if de else 0.0,
        float(min(de)) if de else 99.0,
        float(sum(de) / len(de)) if de else 99.0,
        float(min(df)) if df else 99.0,
        float(sum(df) / len(df)) if df else 99.0,
        terr["plains"] / total,
        terr["forest"] / total,
        terr["mountain"] / total,
        terr["swamp"] / total,
        terr["other"] / total,
        float(pf),
        float(pe),
        float(getattr(u, "remaining_mp", ud.get("remaining_mp", 0))),
        1.0 if ud.get("has_attacked", False) else 0.0,
        float(geometry.hex_distance_axial((aq, ar), (int(adv[0]), int(adv[1]))))
        if adv else -1.0,
        float(geometry.hex_distance_axial((aq, ar), (int(wdn[0]), int(wdn[1]))))
        if wdn else -1.0,
        float(entropy_new),
    ]


def rows_to_tensors(rows: list[dict]) -> dict[str, torch.Tensor]:
    n = len(rows)
    actor = torch.zeros(n, 67, dtype=torch.float32)
    tokens = torch.zeros(n, 24, 37, dtype=torch.float32)
    token_pad = torch.zeros(n, 24, dtype=torch.bool)
    hexp = torch.zeros(n, 91, 33, dtype=torch.float32)
    mission = torch.zeros(n, 46, dtype=torch.float32)
    glob = torch.zeros(n, 31, dtype=torch.float32)
    class_idx = torch.zeros(n, dtype=torch.long)
    legal = torch.zeros(n, 6, dtype=torch.bool)
    teacher_q = torch.full((n, 3, 6), float("nan"), dtype=torch.float32)
    sel_old = torch.zeros(n, dtype=torch.long)
    sel_new = torch.zeros(n, dtype=torch.long)
    prob_old = torch.zeros(n, 6, dtype=torch.float32)
    prob_new = torch.zeros(n, 6, dtype=torch.float32)
    feats = torch.zeros(n, len(FEATURE_NAMES), dtype=torch.float32)
    for i, r in enumerate(rows):
        o = r["observation"]
        actor[i] = torch.tensor(o["actor_features"], dtype=torch.float32)
        tokens[i] = torch.tensor(o["tokens"], dtype=torch.float32)
        token_pad[i] = torch.tensor(o["token_padding_mask"], dtype=torch.bool)
        hexp[i] = torch.tensor(o["hex_patch"], dtype=torch.float32)
        mission[i] = torch.tensor(o["mission_features"], dtype=torch.float32)
        glob[i] = torch.tensor(o["global_features"], dtype=torch.float32)
        class_idx[i] = int(o["acting_class_idx"])
        legal[i] = torch.tensor(r["legal"], dtype=torch.bool)
        for t, p in enumerate(TEACHERS):
            for s in range(6):
                v = r["teacher_q"][p][s]
                if v is not None:
                    teacher_q[i, t, s] = float(v)
        sel_old[i] = int(r["sel_old"])
        sel_new[i] = int(r["sel_new"])
        prob_old[i] = torch.tensor(r["prob_old"], dtype=torch.float32)
        prob_new[i] = torch.tensor(r["prob_new"], dtype=torch.float32)
        f = list(r["features"])
        f[1] = float(r["trajectory_step"])
        feats[i] = torch.tensor(f, dtype=torch.float32)
    return {"actor": actor, "tokens": tokens, "token_pad": token_pad, "hex": hexp,
            "mission": mission, "global": glob, "class_idx": class_idx,
            "legal": legal, "teacher_q": teacher_q, "sel_old": sel_old,
            "sel_new": sel_new, "prob_old": prob_old, "prob_new": prob_new,
            "features": feats}


def provenance_of(rows: list[dict]) -> list[dict]:
    # A1 hook (additive): visit_count defaults to 1 for D0 rows, which never
    # deduplicate. Stored provenance (and D0 set hashes) are unaffected.
    keys = ("set", "scenario_id", "scenario_seed", "scenario_index",
            "scenario_ood", "split", "profile", "mission", "turn",
            "trajectory_step", "actor_id", "actor_class", "side",
            "state_hash", "obs_hash", "trial_exec_status", "trial_failure_code")
    out = []
    for r in rows:
        d = {k: r[k] for k in keys}
        d["visit_count"] = int(r.get("visit_count", 1))
        out.append(d)
    return out


def set_hash(tensors: dict[str, torch.Tensor], provenance: list[dict]) -> str:
    h = hashlib.sha256()
    for k in sorted(tensors):
        t = tensors[k].contiguous().cpu()
        h.update(k.encode("utf-8"))
        h.update(t.numpy().tobytes())
    h.update(json.dumps(provenance, sort_keys=True, separators=(",", ":")).encode("utf-8"))
    return h.hexdigest()


def save_distribution_set(path: str, set_name: str, rows: list[dict]) -> dict:
    from python_sim.rollout.value_target import VALUE_TARGET_VERSION
    from python_sim.rollout.value_target import content_hash as vt_hash
    from python_sim.skills.preflight import (
        LEGAL_MASK_V2_VERSION,
        SKILL_PREFLIGHT_VERSION,
        preflight_content_hash,
    )

    tensors = rows_to_tensors(rows)
    prov = provenance_of(rows)
    digest = set_hash(tensors, prov)
    invalid = [p for p in prov if p["trial_exec_status"] == "INVALID"]
    if invalid:
        raise RuntimeError(f"{set_name}: {len(invalid)} trial INVALID "
                           f"(first: {invalid[0]}) — full-info mask violated")
    payload = {
        "diag_version": DIAG_VERSION,
        "set": set_name,
        "source_policy": SOURCE_POLICY[set_name],
        "n_records": len(rows),
        "teachers": list(TEACHERS),
        "feature_names": list(FEATURE_NAMES),
        "config": {"horizon_decisions": 8, "max_turns": MAX_TURNS,
                   "max_states_per_scenario": MAX_STATES,
                   "full_information_only": True},
        "contract_versions": {
            "legal_mask_version": LEGAL_MASK_V2_VERSION,
            "legal_mask_hash": preflight_content_hash(),
            "skill_preflight_version": SKILL_PREFLIGHT_VERSION,
            "value_target_version": VALUE_TARGET_VERSION,
            "value_target_hash": vt_hash(),
        },
        "tensors": tensors,
        "provenance": prov,
        "set_hash": digest,
    }
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    torch.save(payload, path)
    info = {"path": path, "set": set_name, "records": len(rows),
            "set_hash": digest,
            "trial_partial": sum(1 for p in prov if p["trial_exec_status"] == "PARTIAL")}
    load_set(path, verify=True)
    return info


def load_set(path: str, verify: bool = True) -> dict:
    payload = torch.load(path, map_location="cpu", weights_only=False)
    if payload.get("diag_version") != DIAG_VERSION:
        raise ValueError(f"{path}: diag_version {payload.get('diag_version')!r}")
    if verify:
        digest = set_hash(payload["tensors"], payload["provenance"])
        if digest != payload.get("set_hash"):
            raise ValueError(f"{path}: distribution set hash mismatch")
    return payload


def verify_iid_test_against_shard(set_path: str, shard_path: str) -> dict:
    """Every iid_test state hash must match the v0.2 test shard in order."""
    from python_jev.retrain.dataset_v2 import load_shard_v2

    payload = load_set(set_path, verify=True)
    shard = load_shard_v2(shard_path, verify=True)
    got = [p["state_hash"] for p in payload["provenance"]]
    want = [p["state_hash"] for p in shard["provenance"]]
    return {"set_rows": len(got), "shard_rows": len(want),
            "exact_order_match": got == want,
            "set_minus_shard": len(set(got) - set(want)),
            "shard_minus_set": len(set(want) - set(got))}


__all__ = [
    "DIAG_VERSION",
    "FEATURE_NAMES",
    "MAX_STATES",
    "MAX_TURNS",
    "N_WORKERS",
    "SETS",
    "SOURCE_POLICY",
    "TEACHERS",
    "collect_job",
    "extract_features",
    "load_set",
    "matched_jobs",
    "provenance_of",
    "rows_to_tensors",
    "save_distribution_set",
    "set_hash",
    "verify_iid_test_against_shard",
]