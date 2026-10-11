"""R1 dataset correction II: replay v0.1 states, correct masks, fill SHADOW Q.

Read-only w.r.t. v0.1.0: the source shards are verified and never written.
Collection is replayed EXACTLY (same generator, policy, turn caps, skip
rule); every shard record is matched by (scenario_id, decision_index) with
a state_hash proof and an old-mask drift check (F0 Part D protocol).

Per matched record:
- kept branches (old legal AND new legal): reuse STORED Q bit-identically;
- removed branches: Q=None, excluded from q_valid_mask + P_target;
- gained branches: deterministic single-branch rollout (rollout_branch_q);
- P_target recomputed with frozen policy-target-v0.1.0.

STOP conditions: any state_hash mismatch, any old-mask drift, any reused-Q
audit deviation beyond tolerance, or unexpected delta counts vs the F0
audit (5,643 / 6,947 / 1,139).
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import random
import time

import torch

from python_jev.retrain.dataset_v2 import (
    DATASET_V1_VERSION,
    DATASET_V2_VERSION,
    Q_AUDIT_ABS_TOL,
    RECONSTRUCTION_VERSION,
    REUSED_Q_AUDIT_MIN_KEPT,
    REUSED_Q_AUDIT_SAMPLE,
    REUSED_Q_AUDIT_SEED,
    V2_SPLITS,
    contract_pins_v2,
    load_shard_v2,
    save_shard_v2,
    source_dataset_hash,
    validate_record_v2,
)
from python_jev.training.policy_target import soft_targets_from_q

# F0 Part D pinned expectations (exact replay must reproduce them).
EXPECT_CHANGED_RECORDS = 5643
EXPECT_LOST_BRANCHES = 6947
EXPECT_GAINED_BRANCHES = 1139
MAX_DROPPED_RECORDS = 20
CROSS_CHECK_RECORDS = 10


def new_mask_fn(battle, actor_id, ctx=None):
    from python_sim.skills import observation_safe_skill_mask_v2

    return [bool(x) for x in observation_safe_skill_mask_v2(battle, actor_id, ctx)]


def _argmax(p):
    return max(range(6), key=lambda s: p[s])


def _entropy(p):
    return -sum(v * math.log(v) for v in p if v > 0)


def reconstruct_dataset(v01_dir: str, out_root: str,
                        audit_sample_records: int = 40,
                        log_fn=None) -> dict:
    """Full v0.1 -> v0.2 reconstruction. Returns the v0.2 manifest."""
    import json as _json

    from python_jev.constants import ACTION_SPACE
    from python_jev.training.dataset_gen import (
        _eligible_actor_ids,
        load_shard,
        ood_plan,
        split_plan,
    )
    from python_jev.training.scenarios import (
        generate_scenario,
        mission_context_for_side,
    )
    from python_sim.policies import SimpleAttackElseAdvancePolicy
    from python_sim.rollout.engine import CounterfactualEngine, state_hash
    from python_sim.sim.battle import Battle
    from python_sim.skills import observation_safe_skill_mask
    from python_sim.skills.context import MissionContext

    from python_jev.retrain.dataset_v2 import rollout_branch_q

    log = log_fn or (lambda m: print(m, flush=True))
    t_start = time.perf_counter()

    v01_paths = {s: os.path.join(v01_dir, f"{s}.pt") for s in V2_SPLITS}
    source_hashes = {}
    for s in V2_SPLITS:
        payload = load_shard(v01_paths[s], verify=True)
        source_hashes[s] = payload["shard_hash"]
    combined = source_dataset_hash(v01_paths)
    pins = contract_pins_v2(combined)
    log(f"source {DATASET_V1_VERSION} verified, combined={combined[:16]}...")

    # index v0.1 records by (scenario_id, decision_index)
    payloads = {s: load_shard(v01_paths[s], verify=True) for s in V2_SPLITS}
    wanted: dict[tuple[str, int], dict] = {}
    for split in V2_SPLITS:
        payload = payloads[split]
        tensors = payload["tensors"]
        for i, prov in enumerate(payload["provenance"]):
            key = (str(prov["scenario_id"]), int(prov["decision_index"]))
            wanted[key] = {
                "split": split,
                "row": i,
                "legal": [bool(x) for x in tensors["legal"][i].tolist()],
                "q": [(float(v) if m else None)
                      for v, m in zip(tensors["q"][i].tolist(),
                                      tensors["q_valid"][i].tolist())],
                "p": [float(x) for x in tensors["p_target"][i].tolist()],
                "class": str(prov["actor_class"]),
                "prov": prov,
            }
    log(f"indexed {len(wanted)} v0.1 records")

    # presample reused-Q audit pairs from old-legal branches
    all_pairs = [(k, s) for k, r in wanted.items()
                 for s in range(6) if r["legal"][s]]
    rng = random.Random(REUSED_Q_AUDIT_SEED)
    sampled = rng.sample(all_pairs, min(REUSED_Q_AUDIT_SAMPLE, len(all_pairs)))
    audit_want: dict[tuple[str, int], list[int]] = {}
    for k, s in sampled:
        audit_want.setdefault(k, []).append(s)

    plan = split_plan(192)
    ood = ood_plan(48)
    jobs = [(i, plan[i]["profile"], False) for i in range(192)] + \
           [(i, ood[i]["profile"], True) for i in range(48)]

    driver = SimpleAttackElseAdvancePolicy()
    corrected: dict[tuple[str, int], dict] = {}
    new_branch_rollouts: list[dict] = []
    dropped: list[dict] = []
    audit_diffs: list[float] = []
    audit_exact = 0
    audit_kept = 0
    audit_skipped_new_illegal = 0
    cross_checks: list[dict] = []
    matched = 0
    hash_mismatch = 0
    changed_records = 0
    lost_branches = 0
    gained_branches = 0
    old_q_valid_total = 0

    for ji, (index, profile, is_ood) in enumerate(jobs):
        if ji % 40 == 0:
            log(f"replay {ji}/{len(jobs)} matched={matched} "
                f"gained={gained_branches} audit_kept={audit_kept}")
        gen = generate_scenario(index, ood=is_ood)
        scenario = gen["scenario"]
        battle = Battle(_json.loads(_json.dumps(scenario)), profile,
                        seed=scenario["seed"])
        ctxs = {"blue": MissionContext(**mission_context_for_side(scenario, "blue")),
                "red": MissionContext(**mission_context_for_side(scenario, "red"))}
        engine = CounterfactualEngine.from_name(
            "SimpleAttackElseAdvancePolicy", 8, scenario["seed"])
        decision_index = 0
        n_states = 0
        for _turn in range(12):
            if battle.evaluate_mission()["mission_status"] != "ongoing":
                break
            blue_ids, red_ids = _eligible_actor_ids(battle)
            for side, ids in (("blue", blue_ids), ("red", red_ids)):
                for actor_id in ids:
                    if n_states >= 64:
                        break
                    u = battle.world.units.get(actor_id)
                    if u is None or u.soldier_count <= 0 or u.action_ended:
                        continue
                    if battle.evaluate_mission()["mission_status"] != "ongoing":
                        break
                    legal_old = [bool(x) for x in
                                 observation_safe_skill_mask(battle, actor_id)]
                    step = (driver.blue_action if side == "blue"
                            else driver.red_action)
                    if not any(legal_old):
                        step(battle, actor_id)
                        continue
                    key = (str(scenario["scenario_id"]), decision_index)
                    rec = wanted.get(key)
                    if rec is None:
                        raise RuntimeError(f"replay produced unmatched state {key}")
                    if state_hash(battle) != rec["prov"]["state_hash"]:
                        hash_mismatch += 1
                    if rec["legal"] != legal_old:
                        raise RuntimeError(f"mask drift at {key}")
                    legal_new = new_mask_fn(battle, actor_id, ctxs[side])
                    matched += 1
                    n_states += 1
                    old_q_valid_total += sum(legal_old)

                    kept = [s for s in range(6) if legal_old[s] and legal_new[s]]
                    removed = [s for s in range(6) if legal_old[s] and not legal_new[s]]
                    gained = [s for s in range(6) if legal_new[s] and not legal_old[s]]
                    lost_branches += len(removed)
                    gained_branches += len(gained)
                    if removed or gained:
                        changed_records += 1

                    q_new: list[float | None] = [None] * 6
                    for s in kept:
                        q_new[s] = rec["q"][s]  # reuse STORED Q bit-identically
                    for s in gained:
                        qv = rollout_branch_q(battle, actor_id, ctxs[side], s,
                                              scenario["seed"])
                        q_new[s] = qv
                        new_branch_rollouts.append({
                            "scenario_id": key[0], "decision_index": key[1],
                            "split": rec["split"], "actor_class": rec["class"],
                            "slot": s, "skill": ACTION_SPACE[rec["class"]][s],
                            "q": qv,
                        })

                    # reused-Q audit on presampled kept slots (live battle state)
                    for s in audit_want.get(key, []):
                        if not legal_new[s]:
                            audit_skipped_new_illegal += 1
                            continue
                        re_q = rollout_branch_q(battle, actor_id, ctxs[side], s,
                                                scenario["seed"])
                        stored = rec["q"][s]
                        assert stored is not None
                        diff = abs(float(torch.tensor(re_q, dtype=torch.float32))
                                   - float(torch.tensor(stored, dtype=torch.float32)))
                        audit_diffs.append(diff)
                        audit_kept += 1
                        if diff == 0.0:
                            audit_exact += 1

                    # full-engine cross-check on the first corrected records
                    if len(cross_checks) < CROSS_CHECK_RECORDS and kept:
                        ev = engine.evaluate(battle, actor_id, ctxs[side],
                                             mask_fn=new_mask_fn)
                        assert [bool(x) for x in ev.legal_mask] == legal_new
                        worst_stored = 0.0
                        worst_single = 0.0
                        for s in kept:
                            full_q = float(ev.branches[s].outcome_scalar)
                            stored = rec["q"][s]
                            worst_stored = max(
                                worst_stored,
                                abs(float(torch.tensor(full_q, dtype=torch.float32))
                                    - float(torch.tensor(stored, dtype=torch.float32))))
                            single_q = rollout_branch_q(battle, actor_id, ctxs[side],
                                                        s, scenario["seed"])
                            worst_single = max(worst_single, abs(full_q - single_q))
                        cross_checks.append({
                            "scenario_id": key[0], "decision_index": key[1],
                            "kept": kept,
                            "max_abs_stored_vs_full": worst_stored,
                            "max_abs_single_vs_full": worst_single,
                        })

                    if not any(legal_new):
                        dropped.append({"scenario_id": key[0],
                                        "decision_index": key[1],
                                        "split": rec["split"],
                                        "actor_class": rec["class"]})
                        decision_index += 1
                        step(battle, actor_id)
                        continue
                    p_new = soft_targets_from_q(q_new, [bool(x) for x in legal_new])
                    corrected[key] = {
                        "split": rec["split"], "row": rec["row"],
                        "class": rec["class"],
                        "legal_old": legal_old, "legal_new": legal_new,
                        "q_old": rec["q"], "q_new": q_new,
                        "p_old": rec["p"], "p_new": p_new,
                        "kept": kept, "removed": removed, "gained": gained,
                    }
                    decision_index += 1
                    step(battle, actor_id)
                if n_states >= 64:
                    break
            battle.sim_end_turn()

    # ---- STOP gates ----
    if matched != len(wanted):
        raise RuntimeError(f"matched {matched} != wanted {len(wanted)}")
    if hash_mismatch:
        raise RuntimeError(f"{hash_mismatch} state_hash mismatches — STOP")
    if changed_records != EXPECT_CHANGED_RECORDS:
        raise RuntimeError(
            f"changed {changed_records} != F0 audit {EXPECT_CHANGED_RECORDS} — STOP")
    if lost_branches != EXPECT_LOST_BRANCHES:
        raise RuntimeError(
            f"lost {lost_branches} != F0 audit {EXPECT_LOST_BRANCHES} — STOP")
    if gained_branches != EXPECT_GAINED_BRANCHES:
        raise RuntimeError(
            f"gained {gained_branches} != F0 audit {EXPECT_GAINED_BRANCHES} — STOP")
    if any(s != 1 for s in (r["slot"] for r in new_branch_rollouts)) or \
            any(r["actor_class"] != "SCOUT" for r in new_branch_rollouts):
        raise RuntimeError("gained branches are not all SCOUT/SHADOW — STOP")
    if audit_kept < REUSED_Q_AUDIT_MIN_KEPT:
        raise RuntimeError(f"audit kept {audit_kept} < {REUSED_Q_AUDIT_MIN_KEPT} — STOP")
    max_diff = max(audit_diffs) if audit_diffs else 0.0
    if max_diff > Q_AUDIT_ABS_TOL:
        bad = sum(1 for d in audit_diffs if d > Q_AUDIT_ABS_TOL)
        raise RuntimeError(
            f"reused-Q audit FAILED: {bad}/{audit_kept} beyond tol, "
            f"max_diff={max_diff} — STOP, do not trust the old dataset")
    for cc in cross_checks:
        if cc["max_abs_stored_vs_full"] > Q_AUDIT_ABS_TOL or \
                cc["max_abs_single_vs_full"] > Q_AUDIT_ABS_TOL:
            raise RuntimeError(f"cross-check failed: {cc} — STOP")
    if len(dropped) > MAX_DROPPED_RECORDS:
        raise RuntimeError(f"dropped {len(dropped)} records — STOP")
    log(f"replay OK: matched={matched} changed={changed_records} "
        f"lost={lost_branches} gained={gained_branches} dropped={len(dropped)}")
    log(f"reused-Q audit PASS: {audit_kept} kept branches, "
        f"exact={audit_exact}, max_diff={max_diff:.3e}")

    # ---- assemble v0.2 records (v0.1 order, drops excluded) ----
    from python_jev.training.dataset_gen import TENSOR_KEYS

    v2_records: dict[str, list[dict]] = {s: [] for s in V2_SPLITS}
    for split in V2_SPLITS:
        payload = payloads[split]
        tensors = payload["tensors"]
        for i, prov in enumerate(payload["provenance"]):
            key = (str(prov["scenario_id"]), int(prov["decision_index"]))
            c = corrected.get(key)
            if c is None:
                continue  # dropped (no legal branch under the truth)
            obs = {
                "actor_features": [float(x) for x in tensors["actor"][i].tolist()],
                "tokens": [[float(x) for x in t] for t in tensors["tokens"][i].tolist()],
                "token_padding_mask": [bool(x) for x in tensors["token_pad"][i].tolist()],
                "hex_patch": [[float(x) for x in h] for h in tensors["hex"][i].tolist()],
                "mission_features": [float(x) for x in tensors["mission"][i].tolist()],
                "global_features": [float(x) for x in tensors["global"][i].tolist()],
                "acting_class_idx": int(tensors["class_idx"][i].item()),
            }
            v2_records[split].append({
                "dataset_version": DATASET_V2_VERSION,
                "full_information_only": True,
                "profile": prov["profile"],
                "split": split,
                "scenario_id": prov["scenario_id"],
                "scenario_seed": prov["scenario_seed"],
                "scenario_family": prov["scenario_family"],
                "scenario_ood": prov["scenario_ood"],
                "mission_type": prov["mission_type"],
                "ratio_group": prov["ratio_group"],
                "formation": prov["formation"],
                "spacing": prov["spacing"],
                "actor_id": prov["actor_id"],
                "actor_class": prov["actor_class"],
                "acting_side": prov["acting_side"],
                "turn": prov["turn"],
                "decision_index": prov["decision_index"],
                "state_hash": prov["state_hash"],
                "observation": obs,
                "legal_mask": [bool(x) for x in c["legal_new"]],
                "q_valid_mask": [bool(x) for x in c["legal_new"]],
                "q_values": list(c["q_new"]),
                "p_target": list(c["p_new"]),
                "continuation_policy": "SimpleAttackElseAdvancePolicy",
                "horizon_decisions": 8,
                "contract_versions": dict(pins),
            })
    for split in V2_SPLITS:
        for r in v2_records[split]:
            problems = validate_record_v2(r, pins)
            if problems:
                raise ValueError(
                    f"invalid v0.2 record {r['scenario_id']}:{r['decision_index']}: {problems}")
    log(f"validated {sum(len(v) for v in v2_records.values())} v0.2 records")

    # ---- write shards ----
    ds_dir = os.path.join(out_root, "dataset")
    shards = {}
    for split in V2_SPLITS:
        source = {"dataset_version": DATASET_V1_VERSION, "split": split,
                  "shard_hash": source_hashes[split],
                  "source_dataset_hash": combined}
        shards[split] = save_shard_v2(os.path.join(ds_dir, f"{split}.pt"),
                                      split, v2_records[split], pins, source)
        load_shard_v2(os.path.join(ds_dir, f"{split}.pt"), verify=True)
    log("wrote + re-verified 4 v0.2 shards")

    # ---- delta report ----
    from python_jev.constants import ACTION_SPACE as _AS

    delta = _delta_report(corrected, dropped, ACTION_SPACE=_AS)
    delta["summary"]["records_matched_v01"] = matched
    delta["summary"]["records_kept_v02"] = len(corrected)

    # ---- manifest ----
    target_hash = _target_hash(ds_dir)
    wall = time.perf_counter() - t_start
    total = sum(len(v) for v in v2_records.values())
    manifest = {
        "dataset_version": DATASET_V2_VERSION,
        "source_dataset_version": DATASET_V1_VERSION,
        "source_dataset_hash": combined,
        "source_shard_hashes": source_hashes,
        "target_hash": target_hash,
        "contract_versions": pins,
        "reconstruction": {
            "reconstruction_version": RECONSTRUCTION_VERSION,
            "records_matched": matched,
            "state_hash_mismatches": hash_mismatch,
            "records_dropped": len(dropped),
            "new_branch_rollouts": len(new_branch_rollouts),
            "reused_q_audit": {
                "seed": REUSED_Q_AUDIT_SEED,
                "sampled_old_legal": len(sampled),
                "audited_kept": audit_kept,
                "skipped_new_illegal": audit_skipped_new_illegal,
                "exact_matches": audit_exact,
                "max_abs_diff": max_diff,
                "tolerance": Q_AUDIT_ABS_TOL,
                "passed": True,
            },
            "cross_checks": cross_checks,
        },
        "delta": delta["summary"],
        "splits": {s: {"records": len(v2_records[s]),
                       "scenarios": len({r["scenario_id"] for r in v2_records[s]})}
                   for s in V2_SPLITS},
        "total_records": total,
        "wall_seconds": wall,
        "shards": shards,
    }
    with open(os.path.join(ds_dir, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)

    delta_dir = os.path.join(out_root, "dataset_delta")
    os.makedirs(delta_dir, exist_ok=True)
    with open(os.path.join(delta_dir, "delta_report.json"), "w", encoding="utf-8") as f:
        json.dump(delta, f, indent=1, sort_keys=True)
    with open(os.path.join(delta_dir, "new_branch_rollouts.json"), "w",
              encoding="utf-8") as f:
        json.dump({"count": len(new_branch_rollouts),
                   "rollouts": new_branch_rollouts}, f, indent=1, sort_keys=True)

    audit_dir = os.path.join(out_root, "audit")
    os.makedirs(audit_dir, exist_ok=True)
    with open(os.path.join(audit_dir, "reused_q_audit.json"), "w", encoding="utf-8") as f:
        json.dump(manifest["reconstruction"], f, indent=1, sort_keys=True)
    with open(os.path.join(audit_dir, "audit_sample.jsonl"), "w", encoding="utf-8") as f:
        for r in v2_records["train"][:audit_sample_records]:
            f.write(json.dumps(_rounded_record(r), sort_keys=True) + "\n")
    manifest["audit_sample"] = {"path": os.path.join(audit_dir, "audit_sample.jsonl"),
                                "records": min(audit_sample_records,
                                               len(v2_records["train"]))}
    with open(os.path.join(ds_dir, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
    log(f"v0.2 manifest: {total} records in {wall:.1f}s, target={target_hash[:16]}...")
    return manifest


def _target_hash(ds_dir: str) -> str:
    h = hashlib.sha256()
    for split in V2_SPLITS:
        payload = load_shard_v2(os.path.join(ds_dir, f"{split}.pt"), verify=True)
        h.update(split.encode("utf-8"))
        h.update(payload["tensors"]["p_target"].contiguous().numpy().tobytes())
    return h.hexdigest()


def _delta_report(corrected: dict, dropped: list, ACTION_SPACE: dict) -> dict:
    rows = list(corrected.values())
    changed = [c for c in rows if c["removed"] or c["gained"]]
    l1 = [sum(abs(a - b) for a, b in zip(c["p_new"], c["p_old"])) for c in rows]
    flips = sum(1 for c in rows if _argmax(c["p_new"]) != _argmax(c["p_old"]))
    ent_old = [_entropy(c["p_old"]) for c in rows]
    ent_new = [_entropy(c["p_new"]) for c in rows]
    removed_total = sum(len(c["removed"]) for c in rows)
    gained_total = sum(len(c["gained"]) for c in rows)

    per_split: dict[str, dict] = {}
    for c in rows:
        cell = per_split.setdefault(c["split"], {"total": 0, "changed": 0,
                                                 "removed": 0, "added": 0,
                                                 "l1": 0.0, "flips": 0})
        cell["total"] += 1
        if c["removed"] or c["gained"]:
            cell["changed"] += 1
        cell["removed"] += len(c["removed"])
        cell["added"] += len(c["gained"])
        cell["l1"] += sum(abs(a - b) for a, b in zip(c["p_new"], c["p_old"]))
        cell["flips"] += 1 if _argmax(c["p_new"]) != _argmax(c["p_old"]) else 0
    for cell in per_split.values():
        cell["mean_l1"] = cell["l1"] / max(1, cell["total"])
        cell["flip_rate"] = cell["flips"] / max(1, cell["total"])
        del cell["l1"]

    per_class: dict[str, dict] = {}
    for c in rows:
        cell = per_class.setdefault(c["class"], {"total": 0, "changed": 0,
                                                 "removed": 0, "added": 0,
                                                 "l1": 0.0, "flips": 0})
        cell["total"] += 1
        if c["removed"] or c["gained"]:
            cell["changed"] += 1
        cell["removed"] += len(c["removed"])
        cell["added"] += len(c["gained"])
        cell["l1"] += sum(abs(a - b) for a, b in zip(c["p_new"], c["p_old"]))
        cell["flips"] += 1 if _argmax(c["p_new"]) != _argmax(c["p_old"]) else 0
    for cell in per_class.values():
        cell["mean_l1"] = cell["l1"] / max(1, cell["total"])
        cell["flip_rate"] = cell["flips"] / max(1, cell["total"])
        del cell["l1"]

    lost_detail: dict[str, int] = {}
    gained_detail: dict[str, int] = {}
    for c in rows:
        for s in c["removed"]:
            k = f"{c['class']}:{s}:{ACTION_SPACE[c['class']][s]}"
            lost_detail[k] = lost_detail.get(k, 0) + 1
        for s in c["gained"]:
            k = f"{c['class']}:{s}:{ACTION_SPACE[c['class']][s]}"
            gained_detail[k] = gained_detail.get(k, 0) + 1

    def spot(cls, slot):
        k = f"{cls}:{slot}:{ACTION_SPACE[cls][slot]}"
        return {"key": k, "lost": lost_detail.get(k, 0),
                "gained": gained_detail.get(k, 0)}

    return {
        "summary": {
            "records_total": len(rows),
            "records_unchanged": len(rows) - len(changed),
            "records_mask_changed": len(changed),
            "records_mask_changed_rate": len(changed) / max(1, len(rows)),
            "branches_removed": removed_total,
            "branches_added": gained_total,
            "mean_p_target_l1": sum(l1) / max(1, len(l1)),
            "max_p_target_l1": max(l1) if l1 else 0.0,
            "top_action_flips": flips,
            "top_action_flip_rate": flips / max(1, len(rows)),
            "mean_target_entropy_old": sum(ent_old) / max(1, len(ent_old)),
            "mean_target_entropy_new": sum(ent_new) / max(1, len(ent_new)),
            "mean_target_entropy_delta":
                (sum(ent_new) - sum(ent_old)) / max(1, len(rows)),
            "records_dropped": len(dropped),
        },
        "per_split": per_split,
        "per_class": per_class,
        "branches_lost_by_action": dict(sorted(lost_detail.items(),
                                               key=lambda kv: -kv[1])),
        "branches_added_by_action": dict(sorted(gained_detail.items(),
                                                key=lambda kv: -kv[1])),
        "spotlight": {
            "ARCHER_KITE": spot("ARCHER", 3),
            "CAVALRY_FLANK": spot("CAVALRY", 1),
            "SCOUT_EVADE": spot("SCOUT", 4),
            "SCOUT_SHADOW": spot("SCOUT", 1),
        },
        "dropped": dropped,
    }


def _rounded_record(record: dict, ndigits: int = 4) -> dict:
    out = {k: v for k, v in record.items()
           if k not in ("observation", "contract_versions")}
    out["contract_versions"] = record.get("contract_versions", {})

    def rnd(x):
        return round(float(x), ndigits)

    def rnd_list(v):
        return [rnd(x) if not isinstance(x, list) else [rnd(y) for y in x] for x in v]

    obs = record["observation"]
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
    "CROSS_CHECK_RECORDS",
    "EXPECT_CHANGED_RECORDS",
    "EXPECT_GAINED_BRANCHES",
    "EXPECT_LOST_BRANCHES",
    "MAX_DROPPED_RECORDS",
    "new_mask_fn",
    "reconstruct_dataset",
]