"""Parts C + D — existing-checkpoint reevaluation and dataset audit.

No training, no weight changes, no dataset mutation. The frozen seed43
checkpoint is re-run with the corrected SkillPreflight/legality path and
compared against the frozen v0.1.0 mask on the EXACT same decision states
(replay verified by state_hash against the v0.1.0 shard provenance).

Part C (run_mask_comparison): per-state old-vs-new selected skill, regret,
executor result of the selection, invalid rate, entropy after masking.
Part D (run_dataset_audit): per-record legal_mask change counts (class /
action), lost Q-valid branches, and P_target recomputation delta.
"""

from __future__ import annotations

import json
import math
import os

import torch

REEVAL_VERSION = "jev-reeval-v0.1.0"


def old_mask_fn(battle, actor_id, ctx=None):
    from python_sim.skills import observation_safe_skill_mask

    return [bool(x) for x in observation_safe_skill_mask(battle, actor_id)]


def new_mask_fn(battle, actor_id, ctx=None):
    from python_sim.skills import observation_safe_skill_mask_v2

    return [bool(x) for x in observation_safe_skill_mask_v2(battle, actor_id, ctx)]


def _entropy(probs: list[float]) -> float:
    return -sum(p * math.log(p) for p in probs if p > 0)


def run_mask_comparison(model, device, jobs: list[tuple[str, int, str, bool]],
                        out_path: str, max_turns: int = 12,
                        max_states_per_scenario: int = 64) -> dict:
    """Old-vs-new comparison on identical replayed states (Part C)."""
    import json as _json

    from python_jev.training.dataset_gen import _eligible_actor_ids
    from python_jev.training.inference import batch_from_projection, select_slot
    from python_jev.training.projection import project_for_training
    from python_jev.training.scenarios import generate_scenario, mission_context_for_side
    from python_sim.observation.projector import ObservationProjector
    from python_sim.policies import SimpleAttackElseAdvancePolicy
    from python_sim.rollout.engine import CounterfactualEngine
    from python_sim.sim.battle import Battle
    from python_sim.skills.context import MissionContext
    from python_sim.skills.registry import execute_skill

    engine = CounterfactualEngine.from_name("SimpleAttackElseAdvancePolicy", 8, 7)
    driver = SimpleAttackElseAdvancePolicy()
    rows: list[dict] = []
    for split, index, profile, ood in jobs:
        gen = generate_scenario(index, ood=ood)
        scenario = gen["scenario"]
        mission = str(scenario["mission_contract"]["primary_objective"])
        battle = Battle(_json.loads(_json.dumps(scenario)), profile, seed=scenario["seed"])
        ctxs = {"blue": MissionContext(**mission_context_for_side(scenario, "blue")),
                "red": MissionContext(**mission_context_for_side(scenario, "red"))}
        projector = ObservationProjector(battle)
        n_states = 0
        for _turn in range(max_turns):
            if battle.evaluate_mission()["mission_status"] != "ongoing":
                break
            blue_ids, red_ids = _eligible_actor_ids(battle)
            for side, ids in (("blue", blue_ids), ("red", red_ids)):
                for actor_id in ids:
                    if n_states >= max_states_per_scenario:
                        break
                    u = battle.world.units.get(actor_id)
                    if u is None or u.soldier_count <= 0 or u.action_ended:
                        continue
                    if battle.evaluate_mission()["mission_status"] != "ongoing":
                        break
                    ctx = ctxs[side]
                    ev_old = engine.evaluate(battle, actor_id, ctx, mask_fn=None)
                    ev_new = engine.evaluate(battle, actor_id, ctx, mask_fn=new_mask_fn)
                    legal_old = [bool(x) for x in ev_old.legal_mask]
                    legal_new = [bool(x) for x in ev_new.legal_mask]
                    if not any(legal_old) and not any(legal_new):
                        (driver.blue_action if side == "blue" else driver.red_action)(
                            battle, actor_id)
                        continue
                    proj = project_for_training(projector, side, actor_id, ctx)
                    q_old = [ev_old.branches[s].outcome_scalar for s in range(6)]
                    q_new = [ev_new.branches[s].outcome_scalar for s in range(6)]
                    out: dict = {
                        "scenario_id": scenario["scenario_id"], "split": split,
                        "profile": profile, "mission": mission,
                        "actor_class": str(u.unit_class).upper(), "side": side,
                        "turn": int(battle.world.current_turn),
                        "legal_old": legal_old, "legal_new": legal_new,
                    }
                    for tag, legal, q, ev in (("old", legal_old, q_old, ev_old),
                                              ("new", legal_new, q_new, ev_new)):
                        if not any(legal):
                            out[f"sel_{tag}"] = -1
                            out[f"regret_{tag}"] = None
                            out[f"exec_{tag}"] = "MASKED_ALL"
                            out[f"code_{tag}"] = "MASKED_ILLEGAL"
                            out[f"entropy_{tag}"] = 0.0
                            continue
                        sel = select_slot(model, batch_from_projection(proj, legal), device)
                        slot = int(sel["selected_slot"][0])
                        env = execute_skill(battle.clone(), actor_id,
                                            str(u.unit_class).upper(), slot, ctx)
                        q_best = max(q[s] for s in range(6) if legal[s])
                        out[f"sel_{tag}"] = slot
                        out[f"regret_{tag}"] = max(0.0, q_best - q[slot])
                        out[f"exec_{tag}"] = str(env.get("status", "UNKNOWN"))
                        out[f"code_{tag}"] = str(env.get("failure_code", "NONE"))
                        out[f"entropy_{tag}"] = _entropy(sel["probabilities"][0])
                    out["agree"] = out["sel_old"] == out["sel_new"]
                    rows.append(out)
                    n_states += 1
                    (driver.blue_action if side == "blue" else driver.red_action)(battle, actor_id)
                if n_states >= max_states_per_scenario:
                    break
            battle.sim_end_turn()

    def mean(key, tag_filter=None):
        vals = [r[key] for r in rows
                if r[key] is not None and (tag_filter is None or tag_filter(r))]
        return sum(vals) / max(1, len(vals))

    old_sel = [r for r in rows if r["sel_old"] >= 0]
    new_sel = [r for r in rows if r["sel_new"] >= 0]
    summary = {
        "reeval_version": REEVAL_VERSION,
        "states": len(rows),
        "old_mean_regret": mean("regret_old"),
        "new_mean_regret": mean("regret_new"),
        "old_invalid_selection_rate": sum(1 for r in old_sel if r["exec_old"] == "INVALID") / max(1, len(old_sel)),
        "new_invalid_selection_rate": sum(1 for r in new_sel if r["exec_new"] == "INVALID") / max(1, len(new_sel)),
        "old_partial_selection_rate": sum(1 for r in old_sel if r["exec_old"] == "PARTIAL") / max(1, len(old_sel)),
        "new_partial_selection_rate": sum(1 for r in new_sel if r["exec_new"] == "PARTIAL") / max(1, len(new_sel)),
        "selection_agreement": sum(1 for r in rows if r["agree"]) / max(1, len(rows)),
        "old_mean_entropy": mean("entropy_old"),
        "new_mean_entropy": mean("entropy_new"),
        "old_all_illegal_states": sum(1 for r in rows if r["sel_old"] < 0),
        "new_all_illegal_states": sum(1 for r in rows if r["sel_new"] < 0),
        "mask_shrink_states": sum(1 for r in rows
                                  if any(a and not b for a, b in zip(r["legal_old"], r["legal_new"]))),
        "mask_expand_states": sum(1 for r in rows
                                  if any(b and not a for a, b in zip(r["legal_old"], r["legal_new"]))),
    }
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, "w") as f:
        json.dump({"summary": summary, "rows": rows}, f, indent=1, sort_keys=True)
    return {"summary": summary, "rows": rows}


def run_dataset_audit(shard_paths: list[str], out_path: str) -> dict:
    """Audit the frozen v0.1.0 corpus under SkillPreflightV0 (Part D).

    Replays collection EXACTLY (same generator, policy, turn caps, skip rule)
    and matches every shard record by (scenario_id, decision_index) with a
    state_hash proof. Never writes to the shards.
    """
    import json as _json

    from python_jev.training.dataset_gen import _eligible_actor_ids, load_shard
    from python_jev.training.policy_target import soft_targets_from_q
    from python_jev.training.scenarios import generate_scenario, mission_context_for_side
    from python_sim.policies import SimpleAttackElseAdvancePolicy
    from python_sim.sim.battle import Battle
    from python_sim.skills import observation_safe_skill_mask
    from python_sim.skills.context import MissionContext
    from python_sim.skills.registry import execute_skill

    CLS_UPPER = {"infantry": "INFANTRY", "spearman": "SPEARMAN", "cavalry": "CAVALRY",
                 "archer": "ARCHER", "scout": "SCOUT"}

    MAX_TURNS = 12
    MAX_STATES = 64
    torch.serialization  # keep torch import live for load_shard

    # index shard records by (scenario_id, decision_index)
    wanted: dict[tuple[str, int], dict] = {}
    meta: dict[tuple[str, int], dict] = {}
    for sp in shard_paths:
        payload = load_shard(sp, verify=True)
        tensors = payload["tensors"]
        for i, prov in enumerate(payload["provenance"]):
            key = (str(prov["scenario_id"]), int(prov["decision_index"]))
            wanted[key] = {
                "legal": [bool(x) for x in tensors["legal"][i].tolist()],
                "q": [(float(v) if m else None)
                      for v, m in zip(tensors["q"][i].tolist(),
                                      tensors["q_valid"][i].tolist())],
                "p_target": [float(x) for x in tensors["p_target"][i].tolist()],
                "class": str(prov["actor_class"]),
                "split": str(prov["split"]),
            }
            meta[key] = prov

    # replay every dataset scenario deterministically
    from python_jev.training.dataset_gen import ood_plan, split_plan

    plan = split_plan(192)
    ood = ood_plan(48)
    jobs = [(i, plan[i]["profile"], False) for i in range(192)] + \
           [(i, ood[i]["profile"], True) for i in range(48)]

    driver = SimpleAttackElseAdvancePolicy()
    matched = 0
    hash_mismatch = 0
    changed_records = 0
    changed_by_class: dict[str, int] = {}
    changed_by_action: dict[str, int] = {}
    lost_by_action: dict[str, int] = {}
    gained_by_action: dict[str, int] = {}
    lost_branches = 0
    gained_branches = 0
    total_old_branches = 0
    shared_kl_vals: list[float] = []
    removed_mass_vals: list[float] = []
    top_flip = 0
    kl_n = 0
    per_split_changed: dict[str, int] = {}
    per_split_total: dict[str, int] = {}
    # Full-info invariant sweep (F0-5) + EXECUTOR_BUG oracle (class B): every
    # dataset state, all six slots, preflight bit vs trial-execution status.
    preflight_legal_executions = 0
    preflight_legal_invalid = 0
    preflight_illegal_executions = 0
    preflight_illegal_noninvalid = 0
    for index, profile, is_ood in jobs:
        gen = generate_scenario(index, ood=is_ood)
        scenario = gen["scenario"]
        battle = Battle(_json.loads(_json.dumps(scenario)), profile, seed=scenario["seed"])
        ctxs = {"blue": MissionContext(**mission_context_for_side(scenario, "blue")),
                "red": MissionContext(**mission_context_for_side(scenario, "red"))}
        decision_index = 0
        n_states = 0
        for _turn in range(MAX_TURNS):
            if battle.evaluate_mission()["mission_status"] != "ongoing":
                break
            blue_ids, red_ids = _eligible_actor_ids(battle)
            for side, ids in (("blue", blue_ids), ("red", red_ids)):
                for actor_id in ids:
                    if n_states >= MAX_STATES:
                        break
                    u = battle.world.units.get(actor_id)
                    if u is None or u.soldier_count <= 0 or u.action_ended:
                        continue
                    if battle.evaluate_mission()["mission_status"] != "ongoing":
                        break
                    legal_old = [bool(x) for x in observation_safe_skill_mask(battle, actor_id)]
                    if not any(legal_old):
                        (driver.blue_action if side == "blue" else driver.red_action)(
                            battle, actor_id)
                        continue  # same skip rule as dataset_gen
                    key = (str(scenario["scenario_id"]), decision_index)
                    rec = wanted.get(key)
                    if rec is None:
                        raise RuntimeError(f"replay produced unmatched state {key}")
                    # state_hash proof of exact-state correspondence
                    from python_sim.rollout.engine import state_hash

                    if state_hash(battle) != meta[key]["state_hash"]:
                        hash_mismatch += 1
                    if rec["legal"] != legal_old:
                        raise RuntimeError(f"mask drift at {key}: shard vs replay differ")
                    legal_new = new_mask_fn(battle, actor_id, ctxs[side])
                    for s in range(6):
                        env = execute_skill(
                            battle.clone(), actor_id, CLS_UPPER[u.unit_class],
                            s, ctxs[side])
                        invalid = env.get("status") == "INVALID"
                        if legal_new[s]:
                            preflight_legal_executions += 1
                            preflight_legal_invalid += invalid
                        else:
                            preflight_illegal_executions += 1
                            preflight_illegal_noninvalid += (not invalid)
                    matched += 1
                    n_states += 1
                    per_split_total[rec["split"]] = per_split_total.get(rec["split"], 0) + 1
                    total_old_branches += sum(legal_old)
                    lost = sum(1 for a, b in zip(legal_old, legal_new) if a and not b)
                    gained = sum(1 for a, b in zip(legal_old, legal_new) if b and not a)
                    lost_branches += lost
                    gained_branches += gained
                    if lost or gained:
                        changed_records += 1
                        changed_by_class[rec["class"]] = changed_by_class.get(rec["class"], 0) + 1
                        per_split_changed[rec["split"]] = per_split_changed.get(rec["split"], 0) + 1
                        for s in range(6):
                            if legal_old[s] != legal_new[s]:
                                k = f"{rec['class']}/slot{s}"
                                changed_by_action[k] = changed_by_action.get(k, 0) + 1
                                if legal_old[s] and not legal_new[s]:
                                    lost_by_action[k] = lost_by_action.get(k, 0) + 1
                                else:
                                    gained_by_action[k] = gained_by_action.get(k, 0) + 1
                    # P_target recomputation delta. Gained slots have no stored
                    # Q and need branch re-simulation; the honest no-sim basis
                    # is: (a) old target mass sitting on removed (dud) slots,
                    # (b) shared-support KL with both distributions
                    # renormalized over kept slots (no clipped infinities).
                    p_old = rec["p_target"]
                    removed_mass_vals.append(
                        sum(p_old[s] for s in range(6)
                            if legal_old[s] and not legal_new[s]))
                    new_valid = [bool(b) and rec["q"][s] is not None
                                 for s, b in enumerate(legal_new)]
                    if any(new_valid):
                        p_new = soft_targets_from_q(rec["q"], new_valid)
                        kl_n += 1
                        kept = [s for s in range(6) if new_valid[s]]
                        ren_old = sum(p_old[s] for s in kept)
                        if ren_old > 0:
                            skl = sum(
                                (p_old[s] / ren_old)
                                * (math.log(p_old[s] / ren_old)
                                   - math.log(max(p_new[s], 1e-12)))
                                for s in kept if p_old[s] > 0)
                            shared_kl_vals.append(skl)
                        top_old = max(range(6), key=lambda s: p_old[s])
                        top_new = max(range(6), key=lambda s: p_new[s])
                        if top_old != top_new:
                            top_flip += 1
                    decision_index += 1
                    (driver.blue_action if side == "blue" else driver.red_action)(battle, actor_id)
                if n_states >= MAX_STATES:
                    break
            battle.sim_end_turn()

    summary = {
        "reeval_version": REEVAL_VERSION,
        "shards": [os.path.abspath(p) for p in shard_paths],
        "records_total": len(wanted),
        "records_matched": matched,
        "state_hash_mismatches": hash_mismatch,
        "records_with_mask_change": changed_records,
        "records_with_mask_change_rate": changed_records / max(1, matched),
        "changed_by_class": changed_by_class,
        "changed_by_action": dict(sorted(changed_by_action.items(), key=lambda kv: -kv[1])),
        "old_q_valid_branches": total_old_branches,
        "lost_q_valid_branches": lost_branches,
        "gained_unscored_slots": gained_branches,
        "lost_by_action": dict(sorted(lost_by_action.items(), key=lambda kv: -kv[1])),
        "gained_by_action": dict(sorted(gained_by_action.items(), key=lambda kv: -kv[1])),
        "mean_old_mass_on_removed_slots": sum(removed_mass_vals) / max(1, len(removed_mass_vals)),
        "mean_shared_support_kl": sum(shared_kl_vals) / max(1, len(shared_kl_vals)),
        "top_action_flip_rate": top_flip / max(1, kl_n),
        "per_split_changed": per_split_changed,
        "per_split_total": per_split_total,
        "preflight_legal_executions": preflight_legal_executions,
        "preflight_legal_invalid": preflight_legal_invalid,
        "full_info_invalid_rate_after_mask": (
            preflight_legal_invalid / max(1, preflight_legal_executions)),
        "preflight_illegal_executions": preflight_illegal_executions,
        "preflight_illegal_noninvalid": preflight_illegal_noninvalid,
        "executor_bug_events": preflight_legal_invalid,
    }
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, "w") as f:
        json.dump(summary, f, indent=1, sort_keys=True)
    return summary


__all__ = ["REEVAL_VERSION", "new_mask_fn", "old_mask_fn", "run_dataset_audit",
           "run_mask_comparison"]
