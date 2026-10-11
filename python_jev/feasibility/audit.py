"""Part A — mask-legal executor-failure audit (jev-failure-audit-v0.1.0).

Reproduces EVERY mask-legal -> executor-non-success event on pristine code
(no mask change, no executor change) across four state sources:

  1. collection replay over IID scenarios (same generator + collection
     policy as jev-fullinfo-dataset-v0.1.0, verified by state_hash),
  2. collection replay over OOD scenarios,
  3. the 60-case tactical exam,
  4. closed-loop benchmark trajectories (JevDriver, all 3 baselines,
     side-swapped — the exact run_benchmarks.py job set).

Per decision state the audit executes ALL SIX class slots on independent
clones (no intervening mutation, no continuation rollouts) and records the
canonical envelope (status / failure_code / state versions) plus the
JEV-selected slot under the frozen seed43 checkpoint.

Classification (exactly one of A/B/C/D/E per failure) is pinned in
CLASSIFICATION_NOTES below; the mechanical resolver recheck for B runs in
`classify_with_resolvers` once python_sim.skills.candidates exists.
"""

from __future__ import annotations

import copy
import hashlib
import json
import os

AUDIT_VERSION = "jev-failure-audit-v0.1.0"

# ---------------------------------------------------------------------------
# Classification contract (Part A).
#
# A. MASK_UNDERSPECIFIED — the mask bit is 1 while faction-authorized facts
#    already prove no mechanical realization exists (the mask omits the
#    executor's precondition check, e.g. ADVANCE/REPOSITION/WITHDRAW mask =
#    can_move with no destination/anchor check).
# B. EXECUTOR_BUG — the shared mechanical resolver confirms a realization
#    existed under the frozen contract but the executor returned INVALID.
#    (Checked mechanically post-refactor; pre-refactor sweep = source review.)
# C. CONTRACT_MISMATCH — mask and executor check a related condition with
#    different frozen definitions (declared pairs in MISMATCH_PAIRS).
# D. EXPECTED_WORLDTRUTH_DISCOVERY — PARTIAL/INTERRUPTED from authoritative
#    contact discovery (hidden_enemy stop). Never fixed by masking.
# E. STALE_STATE_RACE — mask/exec state versions differ (no such event is
#    expected: single-threaded, clone-per-branch; the audit records the
#    versions as evidence either way).
# ---------------------------------------------------------------------------
FAILURE_CLASSES = (
    "MASK_UNDERSPECIFIED",
    "EXECUTOR_BUG",
    "CONTRACT_MISMATCH",
    "EXPECTED_WORLDTRUTH_DISCOVERY",
    "STALE_STATE_RACE",
)

# (skill-name-set, failing codes, rationale). Only failures matching a pair
# classify as C; every other INVALID with mask bit 1 classifies as A.
MISMATCH_PAIRS = (
    (("ATTACK", "FIRE", "HARASS"), ("NO_TARGET", "OUT_OF_RANGE", "TARGET_NOT_ELIGIBLE"),
     "mask uses in_range_known range geometry; executor uses engine attackable-target legality"),
    (("PURSUE",), ("NO_PURSUIT_TARGET",),
     "mask requires an adjacent visible enemy; executor accepts fresh-stale/designated eligibility"),
    (("EVADE",), ("NO_EVADE_THREAT",),
     "mask requires a visible enemy; executor accepts stale-known threats"),
)

CLASSIFICATION_NOTES = {
    "MASK_UNDERSPECIFIED": "mask omits the executor's mechanical precondition check",
    "EXECUTOR_BUG": "resolver confirms a realization existed but executor returned INVALID",
    "CONTRACT_MISMATCH": "mask and executor check related but definitionally different conditions",
    "EXPECTED_WORLDTRUTH_DISCOVERY": "PARTIAL/INTERRUPTED from authoritative contact discovery",
    "STALE_STATE_RACE": "state changed between mask computation and execution",
}

STATUS_BUCKETS = ("SUCCESS", "PARTIAL", "INTERRUPTED", "INVALID", "MASKED")


def status_bucket(envelope: dict) -> str:
    """SUCCESS / PARTIAL / INTERRUPTED / INVALID / MASKED.

    The envelope status vocabulary has no INTERRUPTED value: interruption is
    PARTIAL with partial.interrupted=True (movement.py commit_destination).
    The audit keeps that distinction explicit instead of merging it away.
    """
    status = str(envelope.get("status", "UNKNOWN"))
    if status == "PARTIAL" and isinstance(envelope.get("partial"), dict) \
            and envelope["partial"].get("interrupted") is True \
            and not envelope.get("mechanical_effects", {}).get("moved", True):
        return "INTERRUPTED"
    if status == "PARTIAL" and isinstance(envelope.get("partial"), dict) \
            and envelope["partial"].get("interrupted") is True:
        # Contact-truncated march: movement committed AND discovery stop.
        # Reported as PARTIAL (interrupted=True preserved on the row).
        return "PARTIAL"
    return status


def classify_failure(skill_name: str, envelope: dict, mask_bit: bool,
                     mask_state_version: int | None,
                     exec_state_version: int | None,
                     resolver_executable: bool | None = None) -> str:
    """Exactly one of A/B/C/D/E (short names). mask_bit=False rows are not
    failures of the mask and classify as 'MASKED' (not a failure class)."""
    status = str(envelope.get("status", "UNKNOWN"))
    if status in ("SUCCESS", "MASKED") or not mask_bit:
        return "MASKED" if not mask_bit else "SUCCESS"
    code = str(envelope.get("failure_code", "NONE"))
    # E: proven intervening mutation only.
    if code == "STALE_STATE" or (
            mask_state_version is not None and exec_state_version is not None
            and mask_state_version != exec_state_version):
        return "STALE_STATE_RACE"
    # D: authoritative discovery stops (hidden or visible contact).
    if status == "PARTIAL":
        return "EXPECTED_WORLDTRUTH_DISCOVERY"
    if status == "INTERRUPTED":
        return "EXPECTED_WORLDTRUTH_DISCOVERY"
    if status != "INVALID":
        return "EXPECTED_WORLDTRUTH_DISCOVERY"
    # B: mechanical resolver recheck (post-refactor oracle).
    if resolver_executable is True:
        return "EXECUTOR_BUG"
    # C: declared definition-divergence pairs.
    for names, codes, _ in MISMATCH_PAIRS:
        if skill_name in names and code in codes:
            return "CONTRACT_MISMATCH"
    # A: everything else mask-legal-but-INVALID.
    return "MASK_UNDERSPECIFIED"


def envelope_digest(envelope: dict) -> str:
    blob = json.dumps(envelope, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=True, default=str)
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


# ---------------------------------------------------------------------------
# State-source runners. Each yields row dicts; rows are JSON-serializable.
# ---------------------------------------------------------------------------

def _slot_rows(battle, actor_id: str, skill_class: str, ctx, legal: list[bool],
               source: str, profile: str, mission: str,
               selected_slot: int | None, decision_key: str) -> list[dict]:
    from python_sim.skills.registry import execute_skill

    mask_version = battle.world.state_version
    rows: list[dict] = []
    for slot in range(6):
        clone = battle.clone()
        env = execute_skill(clone, actor_id, skill_class, slot, ctx)
        bucket = status_bucket(env)
        rows.append({
            "audit_version": AUDIT_VERSION,
            "source": source,
            "profile": profile,
            "mission": mission,
            "decision_key": decision_key,
            "actor_id": actor_id,
            "skill_class": skill_class,
            "slot": slot,
            "skill_name": str(env.get("skill_name", f"slot{slot}")),
            "mask_bit": bool(legal[slot]),
            "selected": bool(selected_slot is not None and slot == selected_slot),
            "status": str(env.get("status", "UNKNOWN")),
            "bucket": bucket,
            "failure_code": str(env.get("failure_code", "NONE")),
            "interrupted": bool(isinstance(env.get("partial"), dict)
                                and env["partial"].get("interrupted") is True),
            "partial_reason": (env.get("partial") or {}).get("reason", "")
            if isinstance(env.get("partial"), dict) else "",
            "contact_kind": (env.get("partial") or {}).get("contact_kind", "")
            if isinstance(env.get("partial"), dict) else "",
            "mask_state_version": mask_version,
            "exec_state_version": mask_version,  # clone of the identical frozen state
            "envelope_digest": envelope_digest(env),
            "class": classify_failure(
                str(env.get("skill_name", f"slot{slot}")), env, bool(legal[slot]),
                mask_version, mask_version),
        })
    return rows


def audit_collection(model, device, jobs: list[tuple[str, int, str, bool]],
                     source: str, max_turns: int = 12,
                     max_states_per_scenario: int = 64,
                     log_every: int = 4000) -> list[dict]:
    """Replay dataset collection (deterministic Simple driver); no rollouts.

    jobs: (split, scenario_index, profile, ood). Returns row dicts.
    """
    import json as _json

    from python_jev.training.dataset_gen import _eligible_actor_ids
    from python_jev.training.inference import CLASS_TO_UPPER, batch_from_projection, select_slot
    from python_jev.training.projection import project_for_training
    from python_jev.training.scenarios import generate_scenario, mission_context_for_side
    from python_sim.observation.projector import ObservationProjector
    from python_sim.policies import SimpleAttackElseAdvancePolicy
    from python_sim.sim.battle import Battle
    from python_sim.skills import observation_safe_skill_mask
    from python_sim.skills.context import MissionContext

    cls_upper = {"infantry": "INFANTRY", "spearman": "SPEARMAN",
                 "cavalry": "CAVALRY", "archer": "ARCHER", "scout": "SCOUT"}
    driver = SimpleAttackElseAdvancePolicy()
    rows: list[dict] = []
    states = 0
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
                    legal = [bool(x) for x in observation_safe_skill_mask(battle, actor_id)]
                    proj = project_for_training(projector, side, actor_id, ctxs[side])
                    sel = select_slot(model, batch_from_projection(proj, legal), device)
                    slot = int(sel["selected_slot"][0])
                    key = f"{scenario['scenario_id']}:{battle.world.current_turn}:{actor_id}"
                    rows.extend(_slot_rows(
                        battle, actor_id, cls_upper[u.unit_class], ctxs[side],
                        legal, source, profile, mission, slot if slot >= 0 else None, key))
                    states += 1
                    n_states += 1
                    if states % log_every == 0:
                        print(f"  audit {source}: {states} states", flush=True)
                    (driver.blue_action if side == "blue" else driver.red_action)(battle, actor_id)
                if n_states >= max_states_per_scenario:
                    break
            battle.sim_end_turn()
    return rows


def audit_exam(model, device, source: str = "exam") -> list[dict]:
    """The 60 tactical-exam vignettes with the exam's own MissionContext."""
    import copy as _copy

    from python_jev.training.exam import build_exam_cases
    from python_jev.training.inference import batch_from_projection, select_slot
    from python_jev.training.projection import project_for_training
    from python_sim.observation.projector import ObservationProjector
    from python_sim.sim.battle import Battle
    from python_sim.skills import observation_safe_skill_mask
    from python_sim.skills.context import MissionContext

    rows: list[dict] = []
    for case in build_exam_cases():
        scenario = _copy.deepcopy(case["scenario"])
        battle = Battle(scenario, case["profile"], seed=scenario["seed"])
        mc = scenario["mission_contract"]
        ctx = MissionContext(
            scenario_id=scenario["scenario_id"],
            primary_objective=mc["primary_objective"],
            turn_limit=mc["turn_limit"],
            advance_anchor=(scenario["forces"][2]["q"], scenario["forces"][2]["r"]),
            withdraw_anchor=(scenario["forces"][0]["q"], scenario["forces"][0]["r"]),
        )
        mission = str(mc["primary_objective"])
        legal = [bool(x) for x in observation_safe_skill_mask(battle, case["actor_id"])]
        proj = project_for_training(
            ObservationProjector(battle), case["side"], case["actor_id"], ctx)
        sel = select_slot(model, batch_from_projection(proj, legal), device)
        slot = int(sel["selected_slot"][0])
        rows.extend(_slot_rows(
            battle, case["actor_id"], case["actor_class"], ctx, legal,
            source, case["profile"], mission, slot if slot >= 0 else None,
            case["case_id"]))
    return rows


def audit_closed_loop(model, device, jobs: list[tuple[str, int, str, bool]],
                      source: str = "closedloop") -> list[dict]:
    """JevDriver trajectories on benchmark scenarios (all 3 baselines,
    side-swapped). Records the JEV-side decision envelopes only."""
    import copy as _copy

    from python_jev.training.closedloop import JevDriver, run_pair
    from python_jev.training.scenarios import generate_scenario, mission_context_for_side
    from python_sim.policies import HoldPolicy, RandomLegalPolicy, SimpleAttackElseAdvancePolicy
    from python_sim.skills.context import MissionContext

    baselines = {
        "RandomLegalPolicy": lambda: (RandomLegalPolicy(seed=123), {}),
        "SimpleAttackElseAdvancePolicy": lambda: (SimpleAttackElseAdvancePolicy(), {}),
        "HoldPolicy": lambda: (HoldPolicy(), {}),
    }
    rows: list[dict] = []
    for base_name, base_factory in baselines.items():
        done = 0
        for _pool, index, profile, ood in jobs:
            scenario = generate_scenario(index, ood=ood)["scenario"]
            done += 1
            if done % 6 == 0 or done == len(jobs):
                print(f"  audit {source}: {base_name} {done}/{len(jobs)} pairs",
                      flush=True)
            mission = str(scenario["mission_contract"]["primary_objective"])
            captured: list[dict] = []

            def jev_factory(scn=scenario, cap=captured):
                blue_ctx = MissionContext(**mission_context_for_side(scn, "blue"))
                red_ctx = MissionContext(**mission_context_for_side(scn, "red"))
                drv = JevDriver(model, device, blue_ctx, red_ctx,
                                on_decision=lambda r: cap.append(r))
                stats = {"skill_counts": drv.skill_counts, "exec_status": drv.exec_status}
                return drv, stats

            run_pair(_copy.deepcopy(scenario), profile, jev_factory, base_factory,
                     seed=scenario["seed"])
            for r in captured:
                if r.get("envelope") is None:  # all-illegal -> hold fallback
                    rows.append({
                        "audit_version": AUDIT_VERSION, "source": source,
                        "baseline": base_name, "profile": profile, "mission": mission,
                        "decision_key": f"{scenario['scenario_id']}:{r['side']}:{r['decision_index']}",
                        "actor_id": r["actor_id"], "skill_class": r["skill_class"],
                        "slot": -1, "skill_name": "ALL_ILLEGAL_HOLD",
                        "mask_bit": False, "selected": True, "status": "MASKED",
                        "bucket": "MASKED", "failure_code": "MASKED_ILLEGAL",
                        "interrupted": False, "partial_reason": "", "contact_kind": "",
                        "mask_state_version": int(r["mask_state_version"]),
                        "exec_state_version": int(r["mask_state_version"]),
                        "envelope_digest": "", "class": "MASKED", "jev_side": r["side"],
                    })
                    continue
                env = r["envelope"]
                bucket = status_bucket(env)
                rows.append({
                    "audit_version": AUDIT_VERSION,
                    "source": source,
                    "baseline": base_name,
                    "profile": profile,
                    "mission": mission,
                    "decision_key": f"{scenario['scenario_id']}:{r['side']}:{r['decision_index']}",
                    "actor_id": r["actor_id"],
                    "skill_class": r["skill_class"],
                    "slot": int(r["slot"]),
                    "skill_name": str(env.get("skill_name", "")),
                    "mask_bit": True,
                    "selected": True,
                    "status": str(env.get("status", "UNKNOWN")),
                    "bucket": bucket,
                    "failure_code": str(env.get("failure_code", "NONE")),
                    "interrupted": bool(isinstance(env.get("partial"), dict)
                                        and env["partial"].get("interrupted") is True),
                    "partial_reason": (env.get("partial") or {}).get("reason", "")
                    if isinstance(env.get("partial"), dict) else "",
                    "contact_kind": (env.get("partial") or {}).get("contact_kind", "")
                    if isinstance(env.get("partial"), dict) else "",
                    "mask_state_version": int(r["mask_state_version"]),
                    "exec_state_version": int(r["mask_state_version"]),
                    "envelope_digest": envelope_digest(env),
                    "class": classify_failure(
                        str(env.get("skill_name", "")), env, True,
                        int(r["mask_state_version"]), int(r["mask_state_version"])),
                    "jev_side": r["side"],
                })
    return rows


# ---------------------------------------------------------------------------
# Summaries
# ---------------------------------------------------------------------------

def summarize(rows: list[dict]) -> dict:
    """Matrix by (class, slot, skill, bucket, failure_code, profile, mission)."""
    mask_legal = [r for r in rows if r["mask_bit"]]
    selected = [r for r in rows if r.get("selected")]
    by_bucket: dict[str, int] = {}
    for r in mask_legal:
        by_bucket[r["bucket"]] = by_bucket.get(r["bucket"], 0) + 1
    by_class: dict[str, dict] = {}
    for r in mask_legal:
        cell = by_class.setdefault(r["skill_class"], {}).setdefault(
            f"slot{r['slot']}:{r['skill_name']}", {})
        cell[r["bucket"]] = cell.get(r["bucket"], 0) + 1
    by_code: dict[str, int] = {}
    for r in mask_legal:
        if r["bucket"] == "INVALID":
            key = f"{r['skill_class']}/{r['skill_name']}/{r['failure_code']}"
            by_code[key] = by_code.get(key, 0) + 1
    by_failure_class: dict[str, int] = {}
    for r in mask_legal:
        if r["bucket"] in ("INVALID", "PARTIAL", "INTERRUPTED"):
            by_failure_class[r["class"]] = by_failure_class.get(r["class"], 0) + 1
    by_source: dict[str, dict] = {}
    for r in mask_legal:
        cell = by_source.setdefault(r["source"], {})
        cell[r["bucket"]] = cell.get(r["bucket"], 0) + 1
    sel_invalid = sum(1 for r in selected if r["bucket"] == "INVALID")
    return {
        "audit_version": AUDIT_VERSION,
        "rows": len(rows),
        "mask_legal_rows": len(mask_legal),
        "selected_rows": len(selected),
        "mask_legal_by_bucket": by_bucket,
        "mask_legal_invalid_rate": by_bucket.get("INVALID", 0) / max(1, len(mask_legal)),
        "selected_invalid_rate": sel_invalid / max(1, len(selected)),
        "by_class_slot": by_class,
        "invalid_by_skill_code": dict(sorted(by_code.items(), key=lambda kv: -kv[1])),
        "nonsuccess_by_failure_class": by_failure_class,
        "by_source": by_source,
    }


def write_jsonl(path: str, rows: list[dict]) -> None:
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w") as f:
        for r in rows:
            f.write(json.dumps(r, sort_keys=True) + "\n")


__all__ = [
    "AUDIT_VERSION",
    "CLASSIFICATION_NOTES",
    "FAILURE_CLASSES",
    "MISMATCH_PAIRS",
    "STATUS_BUCKETS",
    "audit_closed_loop",
    "audit_collection",
    "audit_exam",
    "classify_failure",
    "envelope_digest",
    "status_bucket",
    "summarize",
    "write_jsonl",
]
