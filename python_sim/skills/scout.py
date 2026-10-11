"""Scout executors — Notion slots 0-5 (RECON_ADVANCE/SHADOW/HARASS/SCREEN/
EVADE/REGROUP).

F0 refactor: all candidate enumeration and precondition checks come from the
shared resolvers in python_sim.skills.candidates (the same functions
SkillPreflightV0 calls). Envelope literals, tie-break traces, effects, and
failure wordings are frozen J1-era behavior, preserved bit-identically
(verified by the Part A envelope-parity corpus).
"""

from __future__ import annotations

from python_sim.skills.candidates import (
    resolve_attack_target,
    resolve_evade,
    resolve_recon_advance,
    resolve_regroup,
    resolve_screen,
    resolve_shadow,
)
from python_sim.skills.common import actor_side
from python_sim.skills.contracts import FailureCode, failure, success
from python_sim.skills.context import MissionContext
from python_sim.skills.movement import commit_attack, commit_destination

CLS = "SCOUT"


def _detail(res, overrides: dict) -> str:
    """Frozen J1-era detail wording for this skill (many are empty strings)."""
    return overrides.get((res.reason, res.sub), res.detail)


def _recon_advance(battle, actor, ctx, state_version_before):
    res = resolve_recon_advance(battle, actor, ctx)
    if not res.ok:
        return failure(
            skill_class=CLS, skill_slot=0, skill_name="RECON_ADVANCE",
            actor_id=actor["id"], state_version_before=state_version_before,
            code=FailureCode(res.reason),
            detail=_detail(res, {("NO_RECON_DESTINATION", "empty"): ""}))
    ch = res.choice
    trace = ["recon_waypoint_progress", "canonical_coverage_gain", "shortest_path", "axial_order"]
    return commit_destination(
        battle=battle, actor=actor, actor_id=actor["id"], skill_class=CLS, skill_slot=0,
        skill_name="RECON_ADVANCE", dest=ch["coord"], path=list(ch["path"]),
        state_version_before=state_version_before, tie_break_trace=trace,
        effects_extra={"recon_waypoint": [ch["anchor"][0], ch["anchor"][1]],
                       "visibility_update": "AUTHORITATIVE_POST_REFRESH"},
    )


def _shadow(battle, actor, ctx, state_version_before):
    res = resolve_shadow(battle, actor, ctx)
    if not res.ok:
        return failure(
            skill_class=CLS, skill_slot=1, skill_name="SHADOW", actor_id=actor["id"],
            state_version_before=state_version_before,
            code=FailureCode(res.reason),
            detail=_detail(res, {("NO_SHADOW_TARGET", "no_target_none"): "",
                                 ("NO_SHADOW_DESTINATION", "empty"): ""}))
    ch = res.choice
    trace = ["designated_target", "shadow_band_error", "visibility_predicate",
             "shortest_path", "axial_order"]
    return commit_destination(
        battle=battle, actor=actor, actor_id=actor["id"], skill_class=CLS, skill_slot=1,
        skill_name="SHADOW", dest=ch["coord"], path=list(ch["path"]),
        state_version_before=state_version_before, tie_break_trace=trace,
        effects_extra={"shadow_target": ch["target"]["id"],
                       "shadow_band": [ch["band"][0], ch["band"][1]],
                       "engagement": "NONE"},
    )


def _harass(battle, actor, ctx, state_version_before):
    res = resolve_attack_target(battle, actor, ctx, out_of_range_style=True)
    if not res.ok:
        return failure(
            skill_class=CLS, skill_slot=2, skill_name="HARASS", actor_id=actor["id"],
            state_version_before=state_version_before,
            code=FailureCode(res.reason),
            detail="no legal bounded-harassment target")
    t = res.choice["target"]
    return commit_attack(
        battle=battle, actor_id=actor["id"], defender_id=str(t["id"]),
        skill_class=CLS, skill_slot=2, skill_name="HARASS",
        state_version_before=state_version_before, side=actor_side(battle, actor),
        tie_break_trace=["mission_designation"] if t.get("designation")
        else ["harass_eligibility", "weakest", "nearest", "stable_id"],
    )


def _screen(battle, actor, ctx, state_version_before):
    res = resolve_screen(battle, actor, ctx)
    if not res.ok:
        return failure(
            skill_class=CLS, skill_slot=3, skill_name="SCREEN", actor_id=actor["id"],
            state_version_before=state_version_before,
            code=FailureCode(res.reason),
            detail=_detail(res, {
                ("NO_SCREEN_ANCHOR", "no_anchor"): "",
                ("NO_SCREEN_ANCHOR", "no_threat"): "no authorized threat approach for the corridor",
                ("NO_SCREEN_DESTINATION", "degenerate"): "",
                ("NO_SCREEN_DESTINATION", "empty"): "",
            }))
    ch = res.choice
    trace = ["protected_anchor", "corridor/intercept_distance", "visibility_predicate",
             "shortest_path", "axial_order"]
    return commit_destination(
        battle=battle, actor=actor, actor_id=actor["id"], skill_class=CLS, skill_slot=3,
        skill_name="SCREEN", dest=ch["coord"], path=list(ch["path"]),
        state_version_before=state_version_before, tie_break_trace=trace,
        effects_extra={"protected_anchor": [ch["anchor"][0], ch["anchor"][1]],
                       "screen_destination": [ch["coord"][0], ch["coord"][1]]},
    )


def _evade(battle, actor, ctx, state_version_before):
    res = resolve_evade(battle, actor, ctx)
    if not res.ok:
        return failure(
            skill_class=CLS, skill_slot=4, skill_name="EVADE", actor_id=actor["id"],
            state_version_before=state_version_before,
            code=FailureCode(res.reason), detail=res.detail)
    ch = res.choice
    trace = ["threat_priority(mission_else_nearest)", "separation_increase",
             "shortest_path", "axial_order"]
    return commit_destination(
        battle=battle, actor=actor, actor_id=actor["id"], skill_class=CLS, skill_slot=4,
        skill_name="EVADE", dest=ch["coord"], path=list(ch["path"]),
        state_version_before=state_version_before, tie_break_trace=trace,
        effects_extra={"declared_threat": [ch["threat_coord"][0], ch["threat_coord"][1]]},
    )


def _regroup(battle, actor, ctx, state_version_before):
    res = resolve_regroup(battle, actor, ctx)
    if not res.ok:
        return failure(
            skill_class=CLS, skill_slot=5, skill_name="REGROUP", actor_id=actor["id"],
            state_version_before=state_version_before,
            code=FailureCode(res.reason),
            detail=_detail(res, {("NO_DESTINATION", "empty"): ""}))
    ch = res.choice
    return commit_destination(
        battle=battle, actor=actor, actor_id=actor["id"], skill_class=CLS, skill_slot=5,
        skill_name="REGROUP", dest=ch["coord"], path=list(ch["path"]),
        state_version_before=state_version_before, tie_break_trace=ch["trace"],
        effects_extra={"regroup_anchor": [ch["anchor"][0], ch["anchor"][1]]},
    )


EXECUTORS = {
    "RECON_ADVANCE": _recon_advance,
    "SHADOW": _shadow,
    "HARASS": _harass,
    "SCREEN": _screen,
    "EVADE": _evade,
    "REGROUP": _regroup,
}

__all__ = ["CLS", "EXECUTORS"]
