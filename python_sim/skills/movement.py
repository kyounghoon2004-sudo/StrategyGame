"""Shared movement machinery for destination skills (Notion I5/I6).

commit_destination wraps the authoritative stepwise executor, translating the
raw partial-success contract into the canonical envelope fields (PARTIAL /
INTERRUPTED on hidden-contact stops, with newly revealed contact recorded —
never pre-leaked).
"""

from __future__ import annotations

from python_sim.rules.geometry import Hex
from python_sim.skills.common import classify_contact, execute_stepwise
from python_sim.skills.contracts import FailureCode, failure, success


def commit_destination(
    *,
    battle,
    actor: dict,
    actor_id: str,
    skill_class: str,
    skill_slot: int,
    skill_name: str,
    dest: Hex,
    path: list[Hex],
    state_version_before: int,
    effects_extra: dict | None = None,
    tie_break_trace: list[str] | None = None,
) -> dict:
    """Execute the resolved path authoritatively and shape the envelope.

    - SUCCESS: reached the resolved destination.
    - PARTIAL: hidden-contact / stronghold / friendly stop truncated the
      march (INTERRUPTED semantics; contact recorded from the executor).
    - INVALID: engine rejected (no mutation — executor guarantees it).
    """
    res = execute_stepwise(battle, actor_id, path)
    if not res.get("success", False):
        return failure(
            skill_class=skill_class, skill_slot=skill_slot, skill_name=skill_name,
            actor_id=actor_id, state_version_before=state_version_before,
            code=FailureCode.ENGINE_REJECTED, detail=str(res.get("error", "")),
            tie_break_trace=tie_break_trace,
        )

    moved = bool(res.get("moved", False))
    contact = classify_contact(res)
    reached = (int(res.get("to", (actor["q"], actor["r"]))[0]),
               int(res.get("to", (actor["q"], actor["r"]))[1]))
    effects = {
        "movement_spent": float(res.get("traversed_cost", 0.0)),
        "march_class": int(res.get("march_class", 0)),
        "crosses_river": bool(res.get("crosses_river", False)),
        "from": [int(res["from"][0]), int(res["from"][1])] if "from" in res else None,
        "to": [reached[0], reached[1]],
        "action_ended": bool(res.get("action_ended", False)),
        "unguarded": bool(res.get("unguarded", False)),
        "defense_ready": bool(res.get("defense_ready", False)),
    }
    if effects_extra:
        effects.update(effects_extra)

    if not moved:
        # Contact on the very first step: no movement committed.
        if contact == "hidden_enemy":
            return success(
                skill_class=skill_class, skill_slot=skill_slot, skill_name=skill_name,
                actor_id=actor_id,
                state_version_before=state_version_before,
                state_version_after=battle.world.state_version,
                effects={**effects, "movement_spent": 0.0, "stopped_by_contact": True},
                destination=None, path=[list(reached)],
                tie_break_trace=tie_break_trace,
                partial={
                    "interrupted": True,
                    "reason": "HIDDEN_CONTACT",
                    "contact_kind": contact,
                    "contact_id": res.get("contact_id", ""),
                    "contact_hex": list(res.get("contact_hex", reached)),
                    "newly_revealed_contact": res.get("contact_id", ""),
                },
            )
        return failure(
            skill_class=skill_class, skill_slot=skill_slot, skill_name=skill_name,
            actor_id=actor_id, state_version_before=state_version_before,
            code=FailureCode.BLOCKED,
            detail=f"no movement committed; contact_kind={contact or 'none'}",
            tie_break_trace=tie_break_trace,
        )

    if res.get("stopped_by_contact", False):
        partial = {
            "interrupted": True,
            "reason": "HIDDEN_CONTACT" if contact == "hidden_enemy" else (
                "STRONGHOLD" if contact == "stronghold" else contact.upper() or "CONTACT"),
            "contact_kind": contact,
            "contact_id": res.get("contact_id", ""),
            "contact_hex": list(res.get("contact_hex", reached)),
            "newly_revealed_contact": res.get("contact_id", "") if contact == "hidden_enemy" else "",
        }
        return success(
            skill_class=skill_class, skill_slot=skill_slot, skill_name=skill_name,
            actor_id=actor_id,
            state_version_before=state_version_before,
            state_version_after=battle.world.state_version,
            effects=effects,
            destination=[reached[0], reached[1]],
            path=[list(h) for h in res.get("traversed_path", [])],
            tie_break_trace=tie_break_trace,
            partial=partial,
        )

    return success(
        skill_class=skill_class, skill_slot=skill_slot, skill_name=skill_name,
        actor_id=actor_id,
        state_version_before=state_version_before,
        state_version_after=battle.world.state_version,
        effects=effects,
        destination=[reached[0], reached[1]],
        path=[list(h) for h in res.get("traversed_path", [])],
        tie_break_trace=tie_break_trace,
    )


def commit_attack(
    *,
    battle,
    actor_id: str,
    defender_id: str,
    skill_class: str,
    skill_slot: int,
    skill_name: str,
    state_version_before: int,
    side: str,
    tie_break_trace: list[str] | None = None,
) -> dict:
    """Authoritative attack through the canonical command seam (do_attack
    performs the engine recheck I5 and combat-assessment bookkeeping)."""
    res = battle.do_attack(actor_id, defender_id, side)
    if not res.get("success", False):
        err = str(res.get("error", ""))
        code = FailureCode.ENGINE_REJECTED
        if "range" in err.lower():
            code = FailureCode.OUT_OF_RANGE
        elif "observed" in err.lower():
            code = FailureCode.NO_LINE_OF_SIGHT
        return failure(
            skill_class=skill_class, skill_slot=skill_slot, skill_name=skill_name,
            actor_id=actor_id, state_version_before=state_version_before,
            code=code, detail=err, tie_break_trace=tie_break_trace,
        )
    effects = {
        "defender_casualties": int(res.get("defender_casualties", 0)),
        "attacker_casualties": int(res.get("attacker_casualties", 0)),
        "defender_destroyed": bool(res.get("defender_destroyed", False)),
        "attacker_destroyed": bool(res.get("attacker_destroyed", False)),
        "wall_damage": int(res.get("wall_damage", 0)),
        "retaliation_occurred": bool(res.get("retaliation_occurred", False)),
        "attacker_action_ended": bool(res.get("attacker_action_ended", True)),
        "is_ranged": bool(res.get("is_ranged", False)),
    }
    return success(
        skill_class=skill_class, skill_slot=skill_slot, skill_name=skill_name,
        actor_id=actor_id,
        state_version_before=state_version_before,
        state_version_after=battle.world.state_version,
        effects=effects,
        target_id=defender_id,
        tie_break_trace=tie_break_trace,
    )


__all__ = ["commit_attack", "commit_destination"]
