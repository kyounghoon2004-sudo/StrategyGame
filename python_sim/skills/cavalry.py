"""Cavalry executors — Notion slots 0-5 (ATTACK/FLANK/ADVANCE/PURSUE/
RESERVE/WITHDRAW). FLANK and PURSUE are movement-only in this MVP contract.

F0 refactor: all candidate enumeration and precondition checks come from the
shared resolvers in python_sim.skills.candidates (the same functions
SkillPreflightV0 calls). Envelope literals, tie-break traces, effects, and
failure wordings are frozen J1-era behavior, preserved bit-identically
(verified by the Part A envelope-parity corpus).
"""

from __future__ import annotations

from python_sim.skills.candidates import (
    resolve_advance,
    resolve_attack_target,
    resolve_flank,
    resolve_pursue,
    resolve_reserve,
    resolve_withdraw,
)
from python_sim.skills.common import actor_side
from python_sim.skills.contracts import FailureCode, failure, success
from python_sim.skills.context import MissionContext
from python_sim.skills.movement import commit_attack, commit_destination

CLS = "CAVALRY"


def _detail(res, overrides: dict) -> str:
    """Frozen J1-era detail wording for this skill (many are empty strings)."""
    return overrides.get((res.reason, res.sub), res.detail)


def _atk(battle, actor, ctx, state_version_before):
    res = resolve_attack_target(battle, actor, ctx)
    if not res.ok:
        return failure(
            skill_class=CLS, skill_slot=0, skill_name="ATTACK", actor_id=actor["id"],
            state_version_before=state_version_before,
            code=FailureCode(res.reason),
            detail="no faction-authorized enemy in the Cavalry attack predicate")
    t = res.choice["target"]
    return commit_attack(
        battle=battle, actor_id=actor["id"], defender_id=str(t["id"]),
        skill_class=CLS, skill_slot=0, skill_name="ATTACK",
        state_version_before=state_version_before, side=actor_side(battle, actor),
        tie_break_trace=["mission_designation"] if t.get("designation")
        else ["mission_designation", "weakest", "nearest", "stable_id"],
    )


def _flank(battle, actor, ctx, state_version_before):
    res = resolve_flank(battle, actor, ctx)
    if not res.ok:
        return failure(
            skill_class=CLS, skill_slot=1, skill_name="FLANK", actor_id=actor["id"],
            state_version_before=state_version_before,
            code=FailureCode(res.reason), detail=res.detail)
    ch = res.choice
    trace = ["designated_target", "flank_band_rank(REAR>SIDE)", "distance_to_flank_point",
             "shortest_path", "axial_order"]
    return commit_destination(
        battle=battle, actor=actor, actor_id=actor["id"], skill_class=CLS, skill_slot=1,
        skill_name="FLANK", dest=ch["coord"], path=list(ch["path"]),
        state_version_before=state_version_before, tie_break_trace=trace,
        effects_extra={"flank_target": ch["target"]["id"], "flank_band": ch["band"],
                       "movement_only": True},
    )


def _adv(battle, actor, ctx, state_version_before):
    res = resolve_advance(battle, actor, ctx)
    if not res.ok:
        return failure(
            skill_class=CLS, skill_slot=2, skill_name="ADVANCE", actor_id=actor["id"],
            state_version_before=state_version_before,
            code=FailureCode(res.reason),
            detail=_detail(res, {("NO_ANCHOR", "anchor"): "",
                                 ("NO_DESTINATION", "empty"): ""}))
    ch = res.choice
    return commit_destination(
        battle=battle, actor=actor, actor_id=actor["id"], skill_class=CLS, skill_slot=2,
        skill_name="ADVANCE", dest=ch["coord"], path=list(ch["path"]),
        state_version_before=state_version_before, tie_break_trace=ch["trace"],
        effects_extra={"anchor": [ch["anchor"][0], ch["anchor"][1]]},
    )


def _pursue(battle, actor, ctx, state_version_before):
    res = resolve_pursue(battle, actor, ctx)
    if not res.ok:
        return failure(
            skill_class=CLS, skill_slot=3, skill_name="PURSUE", actor_id=actor["id"],
            state_version_before=state_version_before,
            code=FailureCode(res.reason),
            detail=_detail(res, {("NO_PURSUIT_ROUTE", "empty"): ""}))
    ch = res.choice
    trace = ["designated_target", "greatest_distance_reduction", "shortest_path", "axial_order"]
    return commit_destination(
        battle=battle, actor=actor, actor_id=actor["id"], skill_class=CLS, skill_slot=3,
        skill_name="PURSUE", dest=ch["coord"], path=list(ch["path"]),
        state_version_before=state_version_before, tie_break_trace=trace,
        effects_extra={"pursuit_target": str(ch["target"].get("id", "")),
                       "target_source": ch["target_source"], "movement_only": True},
    )


def _reserve(battle, actor, ctx, state_version_before):
    res = resolve_reserve(battle, actor, ctx)
    if not res.ok:
        if res.sub == "unholdable":
            # Inside the envelope but unholdable: the J1 code calls do_hold
            # here (rejected, same _record side effect); keep that call for
            # the authoritative wording and identical bookkeeping.
            raw = battle.do_hold(actor["id"], actor_side(battle, actor))
            return failure(
                skill_class=CLS, skill_slot=4, skill_name="RESERVE", actor_id=actor["id"],
                state_version_before=state_version_before,
                code=FailureCode.PRECONDITION_FAILED,
                detail=str(raw.get("error", res.detail)))
        return failure(
            skill_class=CLS, skill_slot=4, skill_name="RESERVE", actor_id=actor["id"],
            state_version_before=state_version_before,
            code=FailureCode(res.reason),
            detail=_detail(res, {("NO_RESERVE_ANCHOR", "no_anchor"): "",
                                 ("NO_DESTINATION", "empty"): ""}))
    ch = res.choice
    origin = (int(actor["q"]), int(actor["r"]))
    if ch["already_inside"]:
        raw = battle.do_hold(actor["id"], actor_side(battle, actor))
        if not raw.get("success", False):
            return failure(
                skill_class=CLS, skill_slot=4, skill_name="RESERVE", actor_id=actor["id"],
                state_version_before=state_version_before,
                code=FailureCode.PRECONDITION_FAILED, detail=str(raw.get("error", "")))
        return success(
            skill_class=CLS, skill_slot=4, skill_name="RESERVE", actor_id=actor["id"],
            state_version_before=state_version_before,
            state_version_after=battle.world.state_version,
            effects={"reserve_state": "CONFIRMED_IN_ENVELOPE",
                     "reserve_anchor": [ch["anchor"][0], ch["anchor"][1]],
                     "envelope_radius": ch["envelope_radius"], "action_ended": True},
            destination=[origin[0], origin[1]],
            tie_break_trace=["reserve_anchor", "envelope_membership", "already_inside"],
        )
    trace = ["reserve_anchor", "envelope_membership", "anchor_distance", "shortest_path", "axial_order"]
    return commit_destination(
        battle=battle, actor=actor, actor_id=actor["id"], skill_class=CLS, skill_slot=4,
        skill_name="RESERVE", dest=ch["coord"], path=list(ch["path"]),
        state_version_before=state_version_before, tie_break_trace=trace,
        effects_extra={"reserve_state": "ENVELOPE_ENTERED" if ch["entered_envelope"] else "IN_TRANSIT",
                       "reserve_anchor": [ch["anchor"][0], ch["anchor"][1]],
                       "envelope_radius": ch["envelope_radius"]},
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
    "ATTACK": _atk,
    "FLANK": _flank,
    "ADVANCE": _adv,
    "PURSUE": _pursue,
    "RESERVE": _reserve,
    "WITHDRAW": _withdraw,
}

__all__ = ["CLS", "EXECUTORS"]
