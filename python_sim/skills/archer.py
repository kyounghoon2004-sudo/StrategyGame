"""Archer executors — Notion slots 0-5 (FIRE/FOCUS_FIRE/REPOSITION_RANGE/
KITE/HOLD_POSITION/WITHDRAW).

F0 refactor: all candidate enumeration and precondition checks come from the
shared resolvers in python_sim.skills.candidates (the same functions
SkillPreflightV0 calls). Envelope literals, tie-break traces, effects, and
failure wordings are frozen J1-era behavior, preserved bit-identically
(verified by the Part A envelope-parity corpus).
"""

from __future__ import annotations

from python_sim.rules import combat, geometry
from python_sim.skills.candidates import (
    resolve_attack_target,
    resolve_focus_target,
    resolve_hold,
    resolve_kite,
    resolve_reposition_range,
    resolve_withdraw,
)
from python_sim.skills.common import actor_side
from python_sim.skills.contracts import FailureCode, failure, success
from python_sim.skills.context import MissionContext
from python_sim.skills.movement import commit_attack, commit_destination

CLS = "ARCHER"


def _detail(res, overrides: dict) -> str:
    """Frozen J1-era detail wording for this skill (many are empty strings)."""
    return overrides.get((res.reason, res.sub), res.detail)


def _fire(battle, actor, ctx, state_version_before):
    res = resolve_attack_target(battle, actor, ctx, out_of_range_style=True)
    if not res.ok:
        return failure(
            skill_class=CLS, skill_slot=0, skill_name="FIRE", actor_id=actor["id"],
            state_version_before=state_version_before,
            code=FailureCode(res.reason),
            detail=_detail(res, {("NO_TARGET", "no_target"):
                                 "no faction-authorized enemy in the fire predicate"}))
    t = res.choice["target"]
    return commit_attack(
        battle=battle, actor_id=actor["id"], defender_id=str(t["id"]),
        skill_class=CLS, skill_slot=0, skill_name="FIRE",
        state_version_before=state_version_before, side=actor_side(battle, actor),
        tie_break_trace=["mission_designation"] if t.get("designation")
        else ["mission_designation", "weakest", "nearest", "stable_id"],
    )


def _focus_fire(battle, actor, ctx, state_version_before):
    res = resolve_focus_target(battle, actor, ctx)
    if not res.ok:
        return failure(
            skill_class=CLS, skill_slot=1, skill_name="FOCUS_FIRE", actor_id=actor["id"],
            state_version_before=state_version_before,
            code=FailureCode(res.reason), detail=res.detail)
    t = res.choice["target"]
    return commit_attack(
        battle=battle, actor_id=actor["id"], defender_id=str(t["id"]),
        skill_class=CLS, skill_slot=1, skill_name="FOCUS_FIRE",
        state_version_before=state_version_before, side=actor_side(battle, actor),
        tie_break_trace=["focus_marker_priority", "stable_id"],
    )


def _reposition_range(battle, actor, ctx, state_version_before):
    res = resolve_reposition_range(battle, actor, ctx)
    if not res.ok:
        return failure(
            skill_class=CLS, skill_slot=2, skill_name="REPOSITION_RANGE",
            actor_id=actor["id"], state_version_before=state_version_before,
            code=FailureCode(res.reason),
            detail=_detail(res, {("NO_DESTINATION", "empty"): ""}))
    ch = res.choice
    trace = ["designated_target/anchor", "range_band_error", "los_predicate",
             "shortest_path", "axial_order"]
    return commit_destination(
        battle=battle, actor=actor, actor_id=actor["id"], skill_class=CLS, skill_slot=2,
        skill_name="REPOSITION_RANGE", dest=ch["coord"], path=list(ch["path"]),
        state_version_before=state_version_before, tie_break_trace=trace,
        effects_extra={"range_anchor": [ch["anchor"][0], ch["anchor"][1]],
                       "range_state": "IN_ENVELOPE", "no_shot_fired": True},
    )


def _kite(battle, actor, ctx, state_version_before):
    res = resolve_kite(battle, actor, ctx)
    if not res.ok:
        return failure(
            skill_class=CLS, skill_slot=3, skill_name="KITE", actor_id=actor["id"],
            state_version_before=state_version_before,
            code=FailureCode(res.reason),
            detail=_detail(res, {("NO_DESTINATION", "empty"): ""}))
    ch = res.choice
    trace = ["designated_threat_and_target", "threat_distance_increase",
             "range/los_validity", "shortest_path", "axial_order"]
    return commit_destination(
        battle=battle, actor=actor, actor_id=actor["id"], skill_class=CLS, skill_slot=3,
        skill_name="KITE", dest=ch["coord"], path=list(ch["path"]),
        state_version_before=state_version_before, tie_break_trace=trace,
        effects_extra={"threat": ch["threat"]["id"],
                       "ranged_target": [ch["anchor"][0], ch["anchor"][1]],
                       "movement_only": True,
                       "range_preserved": geometry.hex_distance_axial(ch["coord"], ch["anchor"]) <= combat.get_attack_range(str(actor.get("class", "archer")))},  # noqa: E501
    )


def _hold_position(battle, actor, ctx, state_version_before):
    res = resolve_hold(battle, actor, ctx)
    raw = battle.do_hold(actor["id"], actor_side(battle, actor))
    if not res.ok or not raw.get("success", False):
        return failure(
            skill_class=CLS, skill_slot=4, skill_name="HOLD_POSITION",
            actor_id=actor["id"], state_version_before=state_version_before,
            code=FailureCode.PRECONDITION_FAILED,
            detail=str(raw.get("error", res.detail)))
    return success(
        skill_class=CLS, skill_slot=4, skill_name="HOLD_POSITION", actor_id=actor["id"],
        state_version_before=state_version_before,
        state_version_after=battle.world.state_version,
        effects={"action_ended": True, "defense_ready": True,
                 "position": [int(actor["q"]), int(actor["r"])]},
        tie_break_trace=["no_choice"],
    )


def _withdraw(battle, actor, ctx, state_version_before):
    res = resolve_withdraw(battle, actor, ctx)
    if not res.ok:
        return failure(
            skill_class=CLS, skill_slot=5, skill_name="WITHDRAW", actor_id=actor["id"],
            state_version_before=state_version_before,
            code=FailureCode(res.reason),
            detail=_detail(res, {("NO_WITHDRAW_ROUTE", "anchor"): "",
                                 ("NO_DESTINATION", "empty"): ""}))
    ch = res.choice
    return commit_destination(
        battle=battle, actor=actor, actor_id=actor["id"], skill_class=CLS, skill_slot=5,
        skill_name="WITHDRAW", dest=ch["coord"], path=list(ch["path"]),
        state_version_before=state_version_before, tie_break_trace=ch["trace"],
        effects_extra={"withdraw_anchor": [ch["anchor"][0], ch["anchor"][1]]},
    )


EXECUTORS = {
    "FIRE": _fire,
    "FOCUS_FIRE": _focus_fire,
    "REPOSITION_RANGE": _reposition_range,
    "KITE": _kite,
    "HOLD_POSITION": _hold_position,
    "WITHDRAW": _withdraw,
}

__all__ = ["CLS", "EXECUTORS"]
