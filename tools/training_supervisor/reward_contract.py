"""Versioned GRPO reward contracts for TRAINING_MARATHON_V1 rollouts.

REWARD_CONTRACT_V1 (iterations 1..REWARD_CONTRACT_V2_FIRST_ITERATION-1):
    GRPO scalar = terminal reward from Godot (WIN +5 / LOSS -3 / DRAW -2;
    strict-invalid Brain output = immediate LOSS -3).

REWARD_CONTRACT_V2 (training signal only; eval/promotion unchanged):
    GRPO scalar = TERMINAL + CONTRACT_BONUS + PLAN_COHERENCE_BONUS
      TERMINAL             unchanged Godot value (+5 / -3 / -2)
      CONTRACT_BONUS       +0.25 iff the Brain output satisfied the strict
                           executable contract with no repair of any kind
      PLAN_COHERENCE_BONUS +0.25 iff contract-valid AND the authored
                           VictoryPlan passes every internal-consistency
                           predicate below (binary; any violation -> 0)
    Strict-invalid output: -3.0 exactly, no auxiliary bonus.

    Ordering invariant (max aux = +0.50 < class gap 1.0):
      best LOSS -2.50 < worst DRAW -2.00 < worst WIN +5.00

Coherence predicates are PURELY plan-consistency / contract semantics over
the compact authoring the Brain produced (victory_author_v1) and the
VictoryPlan lifecycle rules in scripts/cloud2/cloud2_victory_plan.gd. None
reward attacking, kills, damage, movement, survival, territory, formations
or any other tactic. Rollouts are INITIAL-only (one General call), so the
review-decision semantics (KEEP/ADVANCE/AMEND/EMERGENCY) are exercised only
through the transitions the INITIAL plan declares for its own phases.

Pure module: no torch, no Godot, no I/O. Deterministic.
"""
from __future__ import annotations

import json
from typing import Any, Dict, List, Optional, Tuple

REWARD_CONTRACT_V1 = "REWARD_CONTRACT_V1"
REWARD_CONTRACT_V2 = "REWARD_CONTRACT_V2"
REWARD_CONTRACTS = (REWARD_CONTRACT_V1, REWARD_CONTRACT_V2)

TERMINAL_REWARDS = {"WIN": 5, "LOSS": -3, "DRAW": -2}
CONTRACT_BONUS = 0.25
PLAN_COHERENCE_BONUS = 0.25
MAX_AUX = CONTRACT_BONUS + PLAN_COHERENCE_BONUS

# Compact-authoring transition vocabulary (cloud2_victory_authoring.gd).
NEXT_HOLD = ("-", "HOLD")
NEXT_END = ("END",)
THEN_RELEASE_RESERVE = "RELEASE_RESERVE"

# Strict-failure classes (persisted as strict_failure_type).
SF_BRAIN_CONTRACT = "BRAIN_CONTRACT_FAILURE"
SF_PIPELINE = "PIPELINE_INVARIANT"


# ----------------------------------------------------------------------
# contract validity
# ----------------------------------------------------------------------
class _DupKeys:
    def __init__(self) -> None:
        self.paths: List[str] = []


def _parse_direct(text: str) -> Tuple[Optional[Any], _DupKeys, str]:
    """json.loads of the whole stripped completion with duplicate-key
    capture. Last key wins (same as Godot's JSON.parse_string)."""
    dups = _DupKeys()

    def hook(pairs):
        seen = set()
        out = {}
        for k, v in pairs:
            if k in seen:
                dups.paths.append(str(k))
            seen.add(k)
            out[k] = v
        return out

    try:
        return json.loads(text.strip(), object_pairs_hook=hook), dups, ""
    except (ValueError, RecursionError) as e:
        return None, dups, str(e)[:160]


def contract_check(rec: Dict[str, Any], completion_text: str) -> Tuple[bool, List[str]]:
    """Strict executable contract, one dimension. True only when the Godot
    production path adopted the Brain's plan with zero repair/retry/fallback
    AND the raw completion is itself exactly one JSON object (Godot's
    extract_json fence/span salvage counts as repair)."""
    why: List[str] = []
    side = str(rec.get("side", "RED")).upper()
    fault = str(rec.get("fault_red" if side == "RED" else "fault_blue", "") or "")
    consume = rec.get("consume_red" if side == "RED" else "consume_blue") or {}
    status = str(rec.get("status_red" if side == "RED" else "status_blue", ""))
    if rec.get("path") != "GODOT_RESOLUTION":
        why.append(f"path={rec.get('path')}")
    if fault:
        why.append(f"fault={fault}")
    if str(rec.get("validator_code", "") or ""):
        why.append(f"validator_code={rec.get('validator_code')}")
    if rec.get("plan_adopted") is not True:
        why.append("plan_not_adopted")
    if status != "READY":
        why.append(f"status={status}")
    if not (isinstance(consume, dict) and consume.get("ok") is True):
        why.append("consume_not_ok")
    if rec.get("general_calls") != 1:
        why.append(f"general_calls={rec.get('general_calls')}")
    if rec.get("retries") != 0:
        why.append(f"retries={rec.get('retries')}")
    if rec.get("fallback_calls") != 0 or rec.get("fallback_plan_adopted") is not False:
        why.append("fallback")
    doc, _, err = _parse_direct(completion_text or "")
    if not isinstance(doc, dict):
        why.append("not_direct_json_object" + (f" ({err})" if err else ""))
    return (not why), why


# ----------------------------------------------------------------------
# plan coherence (compact INITIAL authoring)
# ----------------------------------------------------------------------
def _u(v: Any) -> str:
    return str(v if v is not None else "").strip().upper()


def _conds(v: Any) -> List[Dict[str, Any]]:
    """Normalize a compact condition list to [{trigger, params}] exactly as
    expand_conds does (bare trigger string or {when|trigger, params...})."""
    if v is None:
        return []
    if isinstance(v, str):
        return [{"trigger": _u(v), "params": {}}]
    if not isinstance(v, list):
        return []
    out = []
    for e in v:
        if isinstance(e, str):
            out.append({"trigger": _u(e), "params": {}})
        elif isinstance(e, dict):
            params = {k: e[k] for k in e if k not in ("when", "trigger")}
            out.append({"trigger": _u(e.get("when", e.get("trigger", ""))),
                        "params": params})
    return out[:4]  # MAX_CONDS in authoring


def _cond_key(c: Dict[str, Any]) -> str:
    return json.dumps(c, sort_keys=True, default=str)


def _units(v: Any) -> List[str]:
    if not isinstance(v, list):
        return []
    out = []
    for u in v:
        uid = _u(u)
        if uid and uid not in out:
            out.append(uid)
    return out


def coherence_check(doc: Dict[str, Any], dup_keys: List[str]) -> List[str]:
    """Return the list of violated plan-consistency predicates ([] = coherent).

    P1 NO_DUPLICATE_KEYS    one declaration per key (a repeated key such as
                            two 'phases' silently discards a declared part)
    P2 NEXT_RESOLVES        a phase's 'next' is ''/'-'/'HOLD'/'END' or names a
                            declared phase
    P3 NEXT_FORWARD         an explicit ADVANCE target is a LATER phase (the
                            lifecycle only advances into PLANNED phases:
                            self/backward targets are VP_TARGET_STATE)
    P4 LAST_PHASE_CLOSES    the last phase does not ADVANCE to 'next in order'
                            (there is none: VP_NO_NEXT)
    P5 MISSION_REFS_RESOLVE condition mission_id params name a mission the
                            plan declares (Godot ids M01.. per phase; phase
                            conditions resolve within their phase, plan
                            abort/branch conditions within any phase)
    P6 ONE_MISSION_PER_UNIT within a phase a unit is assigned to at most one
                            mission (packet: every-ready-formation-exactly-
                            one-mission)
    P7 RESERVE_DISJOINT     within a phase a reserved unit is not also
                            assigned to a mission of that phase
    P8 RELEASE_HAS_RESERVE  release conditions only where a reserve is held
    P9 BRANCH_RESERVE       a RELEASE_RESERVE branch needs a declared reserve
    P10 NO_SELF_CONTRADICTION the identical condition is not both a success
                            and a failure/abort condition of the same scope
    P11 GROUPS_DISJOINT     within a phase a unit belongs to at most one group
    """
    v: List[str] = []
    if dup_keys:
        v.append("P1_DUPLICATE_KEYS:" + ",".join(sorted(set(dup_keys)))[:120])
    phases = doc.get("phases")
    if not isinstance(phases, list) or not phases:
        v.append("P0_NO_PHASES")
        return v
    pids: List[str] = []
    for i, p in enumerate(phases):
        pid = _u((p or {}).get("id", (p or {}).get("phase_id", ""))) if isinstance(p, dict) else ""
        pids.append(pid or f"P{i + 1}")
    mission_ids_by_phase: Dict[str, List[str]] = {}
    for i, p in enumerate(phases):
        ms = p.get("missions") if isinstance(p, dict) else None
        n = len(ms) if isinstance(ms, list) else 0
        mission_ids_by_phase[pids[i]] = [f"M{k + 1:02d}" for k in range(n)]
    all_mids = {m for ids in mission_ids_by_phase.values() for m in ids}
    any_reserve = False

    for i, p in enumerate(phases):
        if not isinstance(p, dict):
            continue
        pid = pids[i]
        local_mids = set(mission_ids_by_phase[pid])
        # P2/P3/P4 transitions
        nxt = _u(p.get("next", ""))
        if nxt in NEXT_HOLD or nxt in NEXT_END:
            pass
        elif nxt == "":
            if i == len(phases) - 1:
                v.append(f"P4_LAST_PHASE_ADVANCES:{pid}")
        elif nxt not in pids:
            v.append(f"P2_NEXT_UNKNOWN:{pid}->{nxt}")
        elif pids.index(nxt) <= i:
            v.append(f"P3_NEXT_NOT_FORWARD:{pid}->{nxt}")
        # missions: P5 refs, P6 single assignment, P10 mission scope
        assigned: Dict[str, int] = {}
        ms = p.get("missions") if isinstance(p.get("missions"), list) else []
        for k, m in enumerate(ms):
            if not isinstance(m, dict):
                continue
            for uid in _units(m.get("units")):
                assigned[uid] = assigned.get(uid, 0) + 1
            mwin, mstop = _conds(m.get("win")), _conds(m.get("stop"))
            for c in mwin + mstop:
                ref = _u(c["params"].get("mission_id", ""))
                if ref and ref not in local_mids:
                    v.append(f"P5_MISSION_REF:{pid}/M{k + 1:02d}->{ref}")
            if {_cond_key(c) for c in mwin} & {_cond_key(c) for c in mstop}:
                v.append(f"P10_SELF_CONTRADICTION:{pid}/M{k + 1:02d}")
        for uid, n in sorted(assigned.items()):
            if n > 1:
                v.append(f"P6_UNIT_IN_{n}_MISSIONS:{pid}/{uid}")
        # phase-level conditions
        win, lose = _conds(p.get("win")), _conds(p.get("lose"))
        abort, entry = _conds(p.get("abort")), _conds(p.get("entry"))
        release = _conds(p.get("release"))
        for c in win + lose + abort + entry + release:
            ref = _u(c["params"].get("mission_id", ""))
            if ref and ref not in local_mids:
                v.append(f"P5_MISSION_REF:{pid}->{ref}")
        wk = {_cond_key(c) for c in win}
        if wk & ({_cond_key(c) for c in lose} | {_cond_key(c) for c in abort}):
            v.append(f"P10_SELF_CONTRADICTION:{pid}")
        # reserve: P7 / P8
        reserve = _units(p.get("reserve"))
        if reserve:
            any_reserve = True
        for uid in reserve:
            if uid in assigned:
                v.append(f"P7_RESERVE_ASSIGNED:{pid}/{uid}")
        if release and not reserve:
            v.append(f"P8_RELEASE_WITHOUT_RESERVE:{pid}")
        # P11 groups
        groups = p.get("groups")
        if isinstance(groups, dict):
            owner: Dict[str, int] = {}
            for g in groups.values():
                for uid in _units(g):
                    owner[uid] = owner.get(uid, 0) + 1
            for uid, n in sorted(owner.items()):
                if n > 1:
                    v.append(f"P11_UNIT_IN_{n}_GROUPS:{pid}/{uid}")

    for c in _conds(doc.get("abort")):
        ref = _u(c["params"].get("mission_id", ""))
        if ref and ref not in all_mids:
            v.append(f"P5_MISSION_REF:plan_abort->{ref}")
    branches = doc.get("branches") if isinstance(doc.get("branches"), list) else []
    for j, b in enumerate(branches):
        if not isinstance(b, dict):
            continue
        when = b.get("when")
        for c in _conds([when] if isinstance(when, (dict, str)) else []):
            ref = _u(c["params"].get("mission_id", ""))
            if ref and ref not in all_mids:
                v.append(f"P5_MISSION_REF:branch{j + 1}->{ref}")
        if _u(b.get("then", "REQUEST_REVIEW")) == THEN_RELEASE_RESERVE and not any_reserve:
            v.append(f"P9_BRANCH_RELEASE_NO_RESERVE:branch{j + 1}")
    return v


# ----------------------------------------------------------------------
# reward
# ----------------------------------------------------------------------
def strict_failure_type(rec: Dict[str, Any]) -> Optional[str]:
    side = str(rec.get("side", "RED")).upper()
    off = str(rec.get("offender_side", "") or "").upper()
    if rec.get("path") == "STRICT_TERMINAL" and off in ("", side):
        code = str(rec.get("validator_code", "") or rec.get("terminal_reason", "") or "UNKNOWN")
        return f"{SF_BRAIN_CONTRACT}:{code}"
    return None


def compute_reward(rec: Dict[str, Any], completion_text: str,
                   version: str) -> Dict[str, Any]:
    """Reward record for one rollout episode. 'total_reward' is the GRPO
    scalar. 'terminal_reward' is always Godot's untouched candidate_reward."""
    if version not in REWARD_CONTRACTS:
        raise ValueError(f"unknown reward contract {version!r}")
    terminal = rec.get("candidate_reward")
    if terminal not in (5, -3, -2) or not isinstance(terminal, int) or isinstance(terminal, bool):
        raise ValueError(f"terminal reward outside contract: {terminal!r}")
    sft = strict_failure_type(rec)
    out: Dict[str, Any] = {"reward_contract_version": version,
                           "terminal_outcome": rec.get("candidate_outcome"),
                           "terminal_reward": terminal,
                           "strict_failure_type": sft}
    if version == REWARD_CONTRACT_V1:
        out.update({"contract_bonus": 0.0, "plan_coherence_bonus": 0.0,
                    "total_reward": terminal, "contract_valid": None,
                    "plan_coherent": None, "contract_violations": None,
                    "coherence_violations": None})
        return out
    valid, why = contract_check(rec, completion_text)
    if sft is not None:
        # Strict-invalid Brain output: immediate LOSS, no auxiliary bonus.
        assert terminal == -3 and not valid, (terminal, why)
        out.update({"contract_bonus": 0.0, "plan_coherence_bonus": 0.0,
                    "total_reward": -3.0, "contract_valid": False,
                    "plan_coherent": False, "contract_violations": why,
                    "coherence_violations": ["NOT_EVALUATED_CONTRACT_INVALID"]})
        return out
    coh: List[str]
    if valid:
        doc, dups, _ = _parse_direct(completion_text)
        coh = coherence_check(doc, dups.paths)
    else:
        coh = ["NOT_EVALUATED_CONTRACT_INVALID"]
    cb = CONTRACT_BONUS if valid else 0.0
    pb = PLAN_COHERENCE_BONUS if (valid and not coh) else 0.0
    total = float(terminal) + cb + pb
    out.update({"contract_bonus": cb, "plan_coherence_bonus": pb,
                "total_reward": total, "contract_valid": bool(valid),
                "plan_coherent": bool(valid and not coh),
                "contract_violations": why, "coherence_violations": coh})
    return out


def group_reward_fields(reward_records: List[Dict[str, Any]],
                        version: str) -> Dict[str, Any]:
    """Fields persisted on a rollout group entry. 'rewards' stays the GRPO
    scalar list (the field TRAIN consumes); the terminal values and every
    component ride alongside so each scalar is reconstructible."""
    return {"reward_contract_version": version,
            "grpo_reward_field": "rewards",
            "rewards": [r["total_reward"] for r in reward_records],
            "terminal_rewards": [r["terminal_reward"] for r in reward_records],
            "reward_components": [
                {k: r[k] for k in ("terminal_outcome", "terminal_reward",
                                   "contract_bonus", "plan_coherence_bonus",
                                   "total_reward", "contract_valid",
                                   "plan_coherent", "strict_failure_type",
                                   "contract_violations",
                                   "coherence_violations")}
                for r in reward_records]}


def check_ordering_invariant() -> Dict[str, float]:
    """best LOSS < worst DRAW < worst WIN under V2 (raises if violated)."""
    best_loss = TERMINAL_REWARDS["LOSS"] + MAX_AUX
    worst_draw = float(TERMINAL_REWARDS["DRAW"])
    worst_win = float(TERMINAL_REWARDS["WIN"])
    best_draw = TERMINAL_REWARDS["DRAW"] + MAX_AUX
    assert best_loss < worst_draw < best_draw < worst_win, \
        (best_loss, worst_draw, best_draw, worst_win)
    return {"best_loss": best_loss, "worst_draw": worst_draw,
            "best_draw": best_draw, "worst_win": worst_win}


check_ordering_invariant()
