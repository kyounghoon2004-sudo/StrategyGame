"""Infantry executors — Notion slots 0-5 (ATTACK/ADVANCE/HOLD/REPOSITION/
SUPPORT/WITHDRAW), realized on python_sim primitives.

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
    resolve_hold,
    resolve_reposition,
    resolve_support,
    resolve_withdraw,
)
from python_sim.skills.common import actor_side
from python_sim.skills.contracts import CanonicalModes, FailureCode, failure, success
from python_sim.skills.context import MissionContext
from python_sim.skills.movement import commit_attack, commit_destination

CLS = "INFANTRY"


def _atk(battle, actor, ctx, state_version_before):
    res = resolve_attack_target(battle, actor, ctx)
    if not res.ok:
        return failure(
            skill_class=CLS, skill_slot=0, skill_name="ATTACK", actor_id=actor["id"],
            state_version_before=state_version_before,
            code=FailureCode(res.reason),
            detail="no faction-authorized enemy in the Infantry attack predicate",
        )
    t = res.choice["target"]
    return commit_attack(
        battle=battle, actor_id=actor["id"], defender_id=str(t["id"]),
        skill_class=CLS, skill_slot=0, skill_name="ATTACK",
        state_version_before=state_version_before, side=actor_side(battle, actor),
        tie_break_trace=["mission_designation", "weakest", "nearest", "stable_id"]
        if not t.get("designation") else ["mission_designation"],
    )


def _adv(battle, actor, ctx, state_version_before):
    res = resolve_advance(battle, actor, ctx)
    if not res.ok:
        return failure(
            skill_class=CLS, skill_slot=1, skill_name="ADVANCE", actor_id=actor["id"],
            state_version_before=state_version_before,
            code=FailureCode(res.reason), detail=res.detail)
    ch = res.choice
    return commit_destination(
        battle=battle, actor=actor, actor_id=actor["id"], skill_class=CLS, skill_slot=1,
        skill_name="ADVANCE", dest=ch["coord"], path=list(ch["path"]),
        state_version_before=state_version_before, tie_break_trace=ch["trace"],
        effects_extra={"anchor": [ch["anchor"][0], ch["anchor"][1]],
                       "anchor_source": ch["anchor_source"]},
    )


def _hold(battle, actor, ctx, state_version_before):
    res = resolve_hold(battle, actor, ctx)
    raw = battle.do_hold(actor["id"], actor_side(battle, actor))
    if not res.ok or not raw.get("success", False):
        return failure(
            skill_class=CLS, skill_slot=2, skill_name="HOLD", actor_id=actor["id"],
            state_version_before=state_version_before,
            code=FailureCode.PRECONDITION_FAILED,
            detail=str(raw.get("error", res.detail)))
    return success(
        skill_class=CLS, skill_slot=2, skill_name="HOLD", actor_id=actor["id"],
        state_version_before=state_version_before,
        state_version_after=battle.world.state_version,
        effects={"action_ended": True, "defense_ready": True, "position": [int(actor["q"]), int(actor["r"])]},
        tie_break_trace=["no_choice"],
    )


def _repo(battle, actor, ctx, state_version_before):
    res = resolve_reposition(battle, actor, ctx)
    if not res.ok:
        return failure(
            skill_class=CLS, skill_slot=3, skill_name="REPOSITION", actor_id=actor["id"],
            state_version_before=state_version_before,
            code=FailureCode(res.reason), detail=res.detail)
    ch = res.choice
    return commit_destination(
        battle=battle, actor=actor, actor_id=actor["id"], skill_class=CLS, skill_slot=3,
        skill_name="REPOSITION", dest=ch["coord"], path=list(ch["path"]),
        state_version_before=state_version_before, tie_break_trace=ch["trace"],
        effects_extra={"anchor": [ch["anchor"][0], ch["anchor"][1]]},
    )


def _support(battle, actor, ctx, state_version_before):
    res = resolve_support(battle, actor, ctx)
    if not res.ok:
        return failure(
            skill_class=CLS, skill_slot=4, skill_name="SUPPORT", actor_id=actor["id"],
            state_version_before=state_version_before,
            code=FailureCode(res.reason), detail=res.detail)
    ch = res.choice
    recipient = ch["recipient"]
    if ch["already_in_position"]:
        dest = ch["coord"]
        return success(
            skill_class=CLS, skill_slot=4, skill_name="SUPPORT", actor_id=actor["id"],
            state_version_before=state_version_before,
            state_version_after=battle.world.state_version,
            effects={"support_mode": CanonicalModes.SUPPORT_MODE, "recipient": recipient["id"],
                     "already_in_position": True},
            target_id=recipient["id"], destination=[dest[0], dest[1]],
            tie_break_trace=["recipient", "support_distance", "already_in_position"],
        )
    trace = ["recipient", "support_distance", "shortest_path", "axial_order"]
    return commit_destination(
        battle=battle, actor=actor, actor_id=actor["id"], skill_class=CLS, skill_slot=4,
        skill_name="SUPPORT", dest=ch["coord"], path=list(ch["path"]),
        state_version_before=state_version_before, tie_break_trace=trace,
        effects_extra={"support_mode": CanonicalModes.SUPPORT_MODE,
                       "recipient": recipient["id"]},
    )


def _withdraw(battle, actor, ctx, state_version_before):
    res = resolve_withdraw(battle, actor, ctx)
    if not res.ok:
        return failure(
            skill_class=CLS, skill_slot=5, skill_name="WITHDRAW", actor_id=actor["id"],
            state_version_before=state_version_before,
            code=FailureCode(res.reason), detail=res.detail)
    ch = res.choice
    return commit_destination(
        battle=battle, actor=actor, actor_id=actor["id"], skill_class=CLS, skill_slot=5,
        skill_name="WITHDRAW", dest=ch["coord"], path=list(ch["path"]),
        state_version_before=state_version_before, tie_break_trace=ch["trace"],
        effects_extra={"withdraw_anchor": [ch["anchor"][0], ch["anchor"][1]],
                       "anchor_source": ch["anchor_source"]},
    )


EXECUTORS = {
    "ATTACK": _atk,
    "ADVANCE": _adv,
    "HOLD": _hold,
    "REPOSITION": _repo,
    "SUPPORT": _support,
    "WITHDRAW": _withdraw,
}

__all__ = ["CLS", "EXECUTORS"]
