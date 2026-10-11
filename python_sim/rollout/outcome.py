"""Raw outcome vector — component-wise, inspectable, versionless weights.

Every legal branch produces one of these regardless of whether a scalar
return can be defined (task rule: "always retain raw rollout outcome
components"). Components are frozen measurable game outcomes ONLY; no
subjective tactical scoring exists here.

Units:
- casualties are soldier counts (int)
- objective_delta / mission_delta: stronghold + mission-status progression
  counts, deterministic from the authoritative mission evaluator
- terminal_result: the mission evaluator's own verdict string
- hq flags / strength ratios: raw measurable state facts
"""

from __future__ import annotations

from python_sim.sim.battle import Battle

OUTCOME_VECTOR_VERSION = "raw-outcome-vector-v0.1.0"

OUTCOME_VECTOR_VERSION_V2 = "raw-outcome-vector-v0.2.0"

COMPONENT_NAMES = (
    "enemy_casualties",
    "friendly_casualties",
    "objective_delta",
    "mission_delta",
    "own_hq_alive",
    "enemy_hq_alive",
    "own_strength_ratio",
    "enemy_visible_strength_ratio",
    "terminal_result",
    "horizon_steps",
)


def outcome_snapshot(battle: Battle) -> dict:
    """Raw measurable facts at an instant (no weights, no scoring)."""
    w = battle.world
    blue = [u for u in w.units.values() if u.faction == "blue" and u.soldier_count > 0]
    red = [u for u in w.units.values() if u.faction == "red" and u.soldier_count > 0]
    own_hq = next((u for u in blue if u.unit_class == "hq"), None)
    enemy_hq = next((u for u in red if u.unit_class == "hq"), None)
    blue_sol = sum(u.soldier_count for u in blue)
    red_sol = sum(u.soldier_count for u in red)
    blue_start = sum(
        int(f.get("soldiers", f.get("soldier_count", 0)))
        for f in battle.scenario.get("forces", []) if str(f.get("faction", "")) == "blue"
    )
    red_start = sum(
        int(f.get("soldiers", f.get("soldier_count", 0)))
        for f in battle.scenario.get("forces", []) if str(f.get("faction", "")) == "red"
    )
    breached = sum(1 for sh in w.strongholds.values() if sh.breached)
    return {
        "friendly_casualties": max(0, blue_start - blue_sol),
        "enemy_casualties": max(0, red_start - red_sol),
        "own_hq_alive": 1 if own_hq is not None else 0,
        "enemy_hq_alive": 1 if enemy_hq is not None else 0,
        "own_strength_ratio": (blue_sol / blue_start) if blue_start > 0 else 0.0,
        "enemy_visible_strength_ratio": (red_sol / red_start) if red_start > 0 else 0.0,
        "objective_delta": breached,
        "mission_status_now": battle.evaluate_mission()["mission_status"],
    }


def raw_outcome_vector(battle: Battle, horizon_steps: int) -> dict:
    """Final raw outcome vector after a rollout (component names frozen)."""
    snap = outcome_snapshot(battle)
    mission = battle.evaluate_mission()
    return {
        "enemy_casualties": snap["enemy_casualties"],
        "friendly_casualties": snap["friendly_casualties"],
        "objective_delta": snap["objective_delta"],
        "mission_delta": 1 if mission["mission_status"] in ("victory", "defeat", "expired") else 0,
        "own_hq_alive": snap["own_hq_alive"],
        "enemy_hq_alive": snap["enemy_hq_alive"],
        "own_strength_ratio": round(snap["own_strength_ratio"], 6),
        "enemy_visible_strength_ratio": round(snap["enemy_visible_strength_ratio"], 6),
        "terminal_result": mission["mission_status"],
        "horizon_steps": int(horizon_steps),
    }


__all__ = ["COMPONENT_NAMES", "OUTCOME_VECTOR_VERSION", "OUTCOME_VECTOR_VERSION_V2",
           "outcome_snapshot", "raw_outcome_vector", "raw_outcome_vector_v2"]


def raw_outcome_vector_v2(battle: Battle, horizon_steps: int, snapshot: dict,
                          acting_faction: str) -> dict:
    """Raw-outcome-vector-v0.2.0: v0.1.0 raw fields (names/semantics UNCHANGED)
    plus explicitly-named derived ValueTargetV0 fields.

    Raw section (v0.1.0 preserved verbatim for traceability; blue-centric facts
    as frozen — perspective lives ONLY in the derived T/M/O/E/Q terms):
        enemy_casualties, friendly_casualties (scenario-start based),
        objective_delta (absolute breached-stronghold count),
        mission_delta (legacy terminal/status indicator),
        own_hq_alive, enemy_hq_alive, own_strength_ratio,
        enemy_visible_strength_ratio, terminal_result, horizon_steps,
    plus raw terminal metadata: terminal_reason, expired.

    Derived section (ValueTargetV0, acting-faction-relative):
        branch-start casualty baselines + fractions, mission_progress_before/
        after + M, objective_progress_before/after + O, T, E, scalar_Q.
    """
    from python_sim.rollout.value_target import VALUE_TARGET_VERSION, derive_branch_terms

    base = raw_outcome_vector(battle, horizon_steps)
    mission = battle.evaluate_mission()
    faction = str(acting_faction).lower()
    derived = derive_branch_terms(snapshot, battle, faction)
    out = dict(base)
    out.update({
        "outcome_vector_version": OUTCOME_VECTOR_VERSION_V2,
        "value_target_version": VALUE_TARGET_VERSION,
        "acting_faction": faction,
        "terminal_reason": mission["termination_reason"],
        "expired": bool(mission["mission_status"] == "expired"),
        "enemy_live_at_branch_start": derived["enemy_live_at_branch_start"],
        "friendly_live_at_branch_start": derived["friendly_live_at_branch_start"],
        "enemy_casualties_since_branch_start": derived["enemy_casualties_since_branch_start"],
        "friendly_casualties_since_branch_start": derived["friendly_casualties_since_branch_start"],
        "enemy_fraction": derived["enemy_fraction"],
        "friendly_fraction": derived["friendly_fraction"],
        "mission_progress_before": derived["mission_progress_before"],
        "mission_progress_after": derived["mission_progress_after"],
        "M": derived["M"],
        "objective_progress_before": derived["objective_progress_before"],
        "objective_progress_after": derived["objective_progress_after"],
        "O": derived["O"],
        "T": derived["T"],
        "E": derived["E"],
        "scalar_Q": derived["scalar_Q"],
    })
    return out
