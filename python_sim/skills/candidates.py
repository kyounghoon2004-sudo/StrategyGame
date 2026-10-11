"""Shared mechanical candidate resolvers (skill-preflight-v0.1.0 companion).

Single authority for "does a mechanical realization exist" per skill, using
ONLY faction-authorized information (FactionKnowledge, declared mission
anchors, authorized occupancy — never hidden WorldTruth).

Architecture (frozen by the F0 task)::

    authorized state
          |
    shared mechanical candidate resolver (this module)
          |-- SkillPreflightV0 -> bool
          `-- SkillExecutor    -> deterministic chosen realization

Both the preflight predicate and the 30 skill executors call the SAME
resolve_* functions below, so the mask can never drift from the executor
again. Every resolver is pure (no battle mutation) and deterministic.

Mechanical only: resolvers enumerate candidates and apply the frozen
tie-break chains. They never rank tactical desirability (no foe-menace
weighting, no pairing quality, no strength preference beyond the frozen
weakest-first attack chain, which is a determinism rule, not a
recommendation).
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

from python_sim.rules import combat, geometry
from python_sim.rules.geometry import Hex
from python_sim.sim.battle import Battle
from python_sim.skills.common import (
    actor_side,
    designated_or_default_target,
    destination_by_anchor,
    enumerate_destinations,
    enumerate_targets,
    focus_target,
    friendly_units,
    in_range_known,  # noqa: F401 (re-exported for preflight parity checks)
    knowledge_of,
    known_enemies,  # noqa: F401 (re-exported for preflight parity checks)
    max_vision_radius,
    nearest_known_enemy,
    visible_enemies,
)
from python_sim.skills.context import (
    MissionContext,
    resolve_advance_anchor,
    resolve_recon_waypoint,
    resolve_regroup_anchor,
    resolve_reserve_anchor,
    resolve_reposition_anchor,
    resolve_withdraw_anchor,
)
from python_sim.skills.contracts import CanonicalModes, FailureCode

CANDIDATES_VERSION = "skill-candidates-v0.1.0"


@dataclass(frozen=True)
class Resolution:
    """Mechanical resolution of one skill invocation (pure, no mutation)."""

    ok: bool
    reason: str  # FailureCode value when not ok, else FailureCode.NONE
    count: int   # number of mechanical candidates (0 when not ok)
    detail: str = ""
    choice: dict = field(default_factory=dict)
    sub: str = ""  # machine-readable fail point ("" when ok)


# Frozen detail prose -> stable fail-point tag. Every resolver fail site uses
# prose from this table (identical prose always means the identical mechanical
# predicate); executors map (reason, sub) back to their frozen envelope
# wording, preserving J1-era literals bit-identically.
_DETAIL_SUB = {
    "no faction-authorized enemy in the attack predicate": "no_target",
    "no legal fire target under range/LOS": "no_target",
    "no authorized focus target/marker": "no_focus",
    "focus target outside current range": "range",
    "focus target not currently attackable (locks/phase)": "eligibility",
    "no declared objective/vector/advance anchor": "anchor",
    "no reachable legal destination in the movement budget": "empty",
    "no reachable destination reduces anchor distance": "no_reduce",
    "no declared reposition/formation anchor": "anchor",
    "no declared pike-line/formation anchor": "anchor",
    "no reachable legal destination": "empty",
    "no withdrawal anchor/safe zone resolvable": "anchor",
    "no reachable destination reduces withdrawal-anchor distance": "no_reduce",
    "no regroup anchor and no friendly regroup group": "anchor",
    "no reachable destination reduces regroup-envelope distance": "no_reduce",
    "no eligible friendly support recipient": "no_recipient",
    "no reachable hex at the canonical support distance": "no_dest",
    "no declared protected anchor/screen corridor": "no_anchor",
    "no authorized threat approach to screen against": "no_threat",
    "no authorized threat approach for the corridor": "no_threat",
    "degenerate threat vector": "degenerate",
    "no reachable hex closer to the corridor intercept point": "no_closer",
    "no authorized flank target": "no_target",
    "no reachable side/rear flank destination in the canonical bands": "no_dest",
    "no qualifying pursuit target (pinned eligibility)": "no_target",
    "no reachable destination closes on the pursuit target": "no_close",
    "no reserve anchor resolvable": "no_anchor",
    "reserve confirm requires a holdable actor": "unholdable",
    "actor cannot hold now (resolved or missing)": "guard",
    "no designated target/anchor and no authorized visible enemy": "no_anchor",
    "no reachable destination satisfies the range/LOS envelope": "no_valid",
    "no authorized threat to kite from": "no_threat",
    "no destination increases threat separation while preserving range/LOS": "no_valid",
    "no recon waypoint and no unexplored candidates in authorized knowledge": "no_anchor",
    "no reachable destination progresses recon": "no_progress",
    "designated shadow target not currently authorized/visible": "no_target_designated",
    "no authorized visible enemy": "no_target_none",
    "no reachable position inside the shadow band with visibility preserved": "no_band",
    "no authorized threat in the declared threat set": "no_threat",
    "no reachable evade destination": "empty",
    "no reachable destination increases threat separation": "no_separation",
}


def _fail(code: FailureCode, detail: str = "") -> Resolution:
    return Resolution(ok=False, reason=code.value, count=0, detail=detail,
                      sub=_DETAIL_SUB.get(detail, ""))


def _ok(reason_detail: str = "", count: int = 1, choice: dict | None = None,
        detail: str = "") -> Resolution:
    return Resolution(ok=True, reason=FailureCode.NONE.value,
                      count=count, detail=detail,
                      choice=dict(choice or {}))


# ---------------------------------------------------------------------------
# Attack family: INF/SPR/CAV ATTACK, ARCHER FIRE, SCOUT HARASS
# ---------------------------------------------------------------------------

def resolve_attack_target(battle: Battle, actor: dict, ctx: MissionContext,
                          out_of_range_style: bool = False) -> Resolution:
    """Frozen attack chain: mission designation -> weakest -> nearest -> id.

    out_of_range_style (FIRE/HARASS): distinguish "visible but unattackable"
    (OUT_OF_RANGE) from "nothing authorized" (NO_TARGET). Melee ATTACK
    reports NO_TARGET for both (frozen envelope wording).
    """
    targets = enumerate_targets(battle, actor)
    t = designated_or_default_target(battle, actor, ctx, targets)
    if t is None:
        if out_of_range_style and visible_enemies(battle, actor_side(battle, actor)):
            return _fail(FailureCode.OUT_OF_RANGE,
                         "no legal fire target under range/LOS")
        return _fail(FailureCode.NO_TARGET,
                     "no faction-authorized enemy in the attack predicate")
    return _ok(count=len(targets),
               choice={"target": t, "designated": bool(t.get("designation"))})


def resolve_focus_target(battle: Battle, actor: dict, ctx: MissionContext) -> Resolution:
    """ARCHER FOCUS_FIRE: locked focus target only (no retarget fallback)."""
    t = focus_target(battle, actor, ctx)
    if t is None:
        return _fail(FailureCode.NO_FOCUS_TARGET,
                     "no authorized focus target/marker")
    rng = combat.get_attack_range(str(actor.get("class", "archer")))
    dist = geometry.hex_distance_axial(
        (int(actor["q"]), int(actor["r"])), (int(t["q"]), int(t["r"])))
    if dist > rng:
        return _fail(FailureCode.OUT_OF_RANGE,
                     "focus target outside current range")
    legal_ids = {str(x["id"]) for x in enumerate_targets(battle, actor)}
    if str(t["id"]) not in legal_ids:
        return _fail(FailureCode.TARGET_NOT_ELIGIBLE,
                     "focus target not currently attackable (locks/phase)")
    return _ok(count=1, choice={"target": t})


# ---------------------------------------------------------------------------
# Anchor-directed movement: ADVANCE / REPOSITION / WITHDRAW / REGROUP
# ---------------------------------------------------------------------------

def _anchor_destination(battle: Battle, actor: dict, anchor: Hex,
                        empty_code: FailureCode,
                        notreduce_code: FailureCode,
                        empty_detail: str,
                        notreduce_detail: str,
                        accept_inside_radius: int | None = None) -> Resolution:
    side = actor_side(battle, actor)
    reachable = enumerate_destinations(battle, actor, side)
    if not reachable:
        return _fail(empty_code, empty_detail)
    origin = (int(actor["q"]), int(actor["r"]))
    coord, d, trace = destination_by_anchor(reachable, origin, anchor)
    reduces = geometry.hex_distance_axial(coord, anchor) < \
        geometry.hex_distance_axial(origin, anchor)
    inside = accept_inside_radius is not None and \
        geometry.hex_distance_axial(coord, anchor) <= accept_inside_radius
    if not reduces and not inside:
        return _fail(notreduce_code, notreduce_detail)
    reducing = sum(
        1 for v in reachable.values()
        if geometry.hex_distance_axial(v["coord"], anchor)
        < geometry.hex_distance_axial(origin, anchor))
    return _ok(count=reducing or len(reachable),
               choice={"coord": coord, "path": list(d["path"]),
                       "cost": d["cost"], "trace": trace,
                       "reachable_count": len(reachable)})


def resolve_advance(battle: Battle, actor: dict, ctx: MissionContext) -> Resolution:
    anchor = resolve_advance_anchor(ctx, actor["id"], battle)
    if anchor.anchor is None:
        return _fail(FailureCode.NO_ANCHOR,
                     "no declared objective/vector/advance anchor")
    res = _anchor_destination(
        battle, actor, anchor.anchor, FailureCode.NO_DESTINATION,
        FailureCode.NO_DESTINATION,
        "no reachable legal destination in the movement budget",
        "no reachable destination reduces anchor distance")
    if not res.ok:
        return res
    return _ok(count=res.count, choice={**res.choice,
               "anchor": anchor.anchor, "anchor_source": anchor.source})


def resolve_reposition(battle: Battle, actor: dict, ctx: MissionContext) -> Resolution:
    anchor = resolve_reposition_anchor(ctx, actor["id"], battle)
    if anchor.anchor is None:
        return _fail(FailureCode.NO_ANCHOR,
                     "no declared reposition/formation anchor")
    res = _anchor_destination(
        battle, actor, anchor.anchor, FailureCode.NO_DESTINATION,
        FailureCode.NO_DESTINATION,
        "no reachable legal destination",
        "no reachable destination reduces anchor distance")
    if not res.ok:
        return res
    return _ok(count=res.count, choice={**res.choice,
               "anchor": anchor.anchor, "anchor_source": anchor.source})


def resolve_withdraw(battle: Battle, actor: dict, ctx: MissionContext) -> Resolution:
    anchor = resolve_withdraw_anchor(ctx, actor["id"], battle)
    if anchor.anchor is None:
        return _fail(FailureCode.NO_WITHDRAW_ROUTE,
                     "no withdrawal anchor/safe zone resolvable")
    res = _anchor_destination(
        battle, actor, anchor.anchor, FailureCode.NO_DESTINATION,
        FailureCode.NO_WITHDRAW_ROUTE,
        "no reachable legal destination",
        "no reachable destination reduces withdrawal-anchor distance")
    if not res.ok:
        return res
    return _ok(count=res.count, choice={**res.choice,
               "anchor": anchor.anchor, "anchor_source": anchor.source})


def resolve_regroup(battle: Battle, actor: dict, ctx: MissionContext) -> Resolution:
    anchor = resolve_regroup_anchor(ctx, actor["id"], battle)
    if anchor.anchor is None:
        return _fail(FailureCode.NO_REGROUP_ANCHOR,
                     "no regroup anchor and no friendly regroup group")
    res = _anchor_destination(
        battle, actor, anchor.anchor, FailureCode.NO_DESTINATION,
        FailureCode.NO_DESTINATION,
        "no reachable legal destination",
        "no reachable destination reduces regroup-envelope distance",
        accept_inside_radius=2)
    if not res.ok:
        return res
    return _ok(count=res.count, choice={**res.choice,
               "anchor": anchor.anchor, "anchor_source": anchor.source})


# ---------------------------------------------------------------------------
# Infantry SUPPORT (positional)
# ---------------------------------------------------------------------------

def resolve_support_recipient(battle: Battle, actor: dict,
                              ctx: MissionContext) -> dict | None:
    """Declared recipient when eligible, else nearest friendly (stable id)."""
    side = actor_side(battle, actor)
    if ctx.support_recipient:
        u = battle.world.unit_dict(ctx.support_recipient)
        if u and u.get("faction") == side and u.get("soldier_count", 0) > 0 \
                and not u.get("garrisoned", False):
            return u
    cand = [f for f in friendly_units(battle, side) if f["id"] != actor["id"]]
    if not cand:
        return None
    origin = (int(actor["q"]), int(actor["r"]))
    return min(cand, key=lambda f: (
        geometry.hex_distance_axial(origin, (int(f["q"]), int(f["r"]))),
        str(f["id"])))


def resolve_support(battle: Battle, actor: dict, ctx: MissionContext) -> Resolution:
    side = actor_side(battle, actor)
    recipient = resolve_support_recipient(battle, actor, ctx)
    if recipient is None:
        return _fail(FailureCode.NO_SUPPORT_TARGET,
                     "no eligible friendly support recipient")
    rec_coord = (int(recipient["q"]), int(recipient["r"]))
    origin = (int(actor["q"]), int(actor["r"]))
    reachable = enumerate_destinations(battle, actor, side)
    want = CanonicalModes.SUPPORT_DESIRED_DISTANCE
    fallback = CanonicalModes.SUPPORT_FALLBACK_DISTANCE
    cands = [(k, d) for k, d in reachable.items()
             if geometry.hex_distance_axial(d["coord"], rec_coord) == want]
    if not cands:
        cands = [(k, d) for k, d in reachable.items()
                 if geometry.hex_distance_axial(d["coord"], rec_coord) <= fallback]
    if not cands:
        return _fail(FailureCode.NO_SUPPORT_DESTINATION,
                     "no reachable hex at the canonical support distance")
    # Frozen order (infantry.py): the already-in-position shortcut applies
    # only AFTER a reachable support hex exists.
    if geometry.hex_distance_axial(origin, rec_coord) <= want:
        return _ok(count=1, choice={"recipient": recipient,
                                    "already_in_position": True,
                                    "coord": origin, "path": [origin]})
    best = min(cands, key=lambda kd: (kd[1]["cost"], kd[1]["coord"]))
    coord, d = best[1]["coord"], best[1]
    return _ok(count=len(cands),
               choice={"recipient": recipient, "already_in_position": False,
                       "coord": coord, "path": list(d["path"]), "cost": d["cost"]})


# ---------------------------------------------------------------------------
# SCREEN (spearman / scout): corridor intercept between anchor and threat
# ---------------------------------------------------------------------------

def screen_midpoint(anchor: Hex, threat_coord: Hex, standoff: int) -> Hex | None:
    """Corridor midpoint = anchor + threat-vector * standoff (None if degenerate)."""
    ax, ay = anchor
    dx, dy = threat_coord[0] - ax, threat_coord[1] - ay
    length = math.hypot(dx, dy)
    if length == 0:
        return None
    return (int(round(ax + dx / length * standoff)),
            int(round(ay + dy / length * standoff)))


def resolve_screen(battle: Battle, actor: dict, ctx: MissionContext) -> Resolution:
    side = actor_side(battle, actor)
    if ctx.screen_anchor is None:
        return _fail(FailureCode.NO_SCREEN_ANCHOR,
                     "no declared protected anchor/screen corridor")
    anchor = (int(ctx.screen_anchor[0]), int(ctx.screen_anchor[1]))
    known = nearest_known_enemy(battle, actor, side)
    if known is None:
        return _fail(FailureCode.NO_SCREEN_ANCHOR,
                     "no authorized threat approach to screen against")
    _, threat_coord, _ = known
    mid = screen_midpoint(anchor, threat_coord,
                          CanonicalModes.SCREEN_CORRIDOR_STANDOFF)
    if mid is None:
        return _fail(FailureCode.NO_SCREEN_DESTINATION,
                     "degenerate threat vector")
    reachable = enumerate_destinations(battle, actor, side)
    if not reachable:
        return _fail(FailureCode.NO_SCREEN_DESTINATION,
                     "no reachable legal destination")
    best_key = min(
        reachable,
        key=lambda k: (geometry.hex_distance_axial(reachable[k]["coord"], mid),
                       reachable[k]["cost"], reachable[k]["coord"]),
    )
    d = reachable[best_key]
    origin = (int(actor["q"]), int(actor["r"]))
    if geometry.hex_distance_axial(d["coord"], mid) >= \
            geometry.hex_distance_axial(origin, mid):
        return _fail(FailureCode.NO_SCREEN_DESTINATION,
                     "no reachable hex closer to the corridor intercept point")
    closer = sum(
        1 for v in reachable.values()
        if geometry.hex_distance_axial(v["coord"], mid)
        < geometry.hex_distance_axial(origin, mid))
    return _ok(count=closer,
               choice={"coord": d["coord"], "path": list(d["path"]),
                       "cost": d["cost"], "anchor": anchor, "mid": mid,
                       "threat_coord": threat_coord})


# ---------------------------------------------------------------------------
# Cavalry FLANK / PURSUE / RESERVE
# ---------------------------------------------------------------------------

def resolve_flank_target(battle: Battle, actor: dict,
                         ctx: MissionContext) -> dict | None:
    """Declared designation when visible; else nearest authorized visible."""
    side = actor_side(battle, actor)
    if ctx.flank_target_id or ctx.designated_target_id:
        want = ctx.flank_target_id or ctx.designated_target_id
        for e in visible_enemies(battle, side):
            if e["id"] == want:
                return e
        return None
    vis = visible_enemies(battle, side)
    if not vis:
        return None
    origin = (int(actor["q"]), int(actor["r"]))
    return min(vis, key=lambda e: (
        geometry.hex_distance_axial(origin, (int(e["q"]), int(e["r"]))),
        str(e["id"])))


def flank_band_cells(target_coord: Hex, actor_coord: Hex) -> dict[str, list[Hex]]:
    """Canonical REAR/SIDE band cells around the target (movement-only)."""
    tq, tr = target_coord
    aq, ar = actor_coord
    dirs = [(1, 0), (1, -1), (0, -1), (-1, 0), (-1, 1), (0, 1)]
    dq, dr = tq - aq, tr - ar
    norm = math.hypot(dq, dr) or 1.0
    bearing = max(dirs, key=lambda d: (d[0] * dq + d[1] * dr) / norm)
    rear = (tq + bearing[0] * CanonicalModes.FLANK_REAR_BAND,
            tr + bearing[1] * CanonicalModes.FLANK_REAR_BAND)
    rot1 = (-bearing[1], bearing[0] + bearing[1])
    rot2 = (bearing[1] - bearing[0], -bearing[0])
    side_cells = [
        (tq + rot1[0] * CanonicalModes.FLANK_SIDE_BAND,
         tr + rot1[1] * CanonicalModes.FLANK_SIDE_BAND),
        (tq + rot2[0] * CanonicalModes.FLANK_SIDE_BAND,
         tr + rot2[1] * CanonicalModes.FLANK_SIDE_BAND),
    ]
    return {"REAR": [rear], "SIDE": side_cells}


def resolve_flank(battle: Battle, actor: dict, ctx: MissionContext) -> Resolution:
    t = resolve_flank_target(battle, actor, ctx)
    if t is None:
        return _fail(FailureCode.NO_FLANK_TARGET, "no authorized flank target")
    side = actor_side(battle, actor)
    bands = flank_band_cells((int(t["q"]), int(t["r"])),
                             (int(actor["q"]), int(actor["r"])))
    reachable = enumerate_destinations(battle, actor, side)
    total = 0
    for band_name in CanonicalModes.FLANK_BAND_ORDER:
        cands = []
        for cell in bands[band_name]:
            key = geometry.key_of(cell)
            if key in reachable:
                cands.append((key, reachable[key]))
        total += len(cands)
        if cands:
            k, d = min(cands, key=lambda kd: (kd[1]["cost"], kd[1]["coord"]))
            return _ok(count=total,
                       choice={"target": t, "band": band_name,
                               "coord": d["coord"], "path": list(d["path"]),
                               "cost": d["cost"]})
    void = _fail(FailureCode.NO_FLANK_DESTINATION,
                 "no reachable side/rear flank destination in the canonical bands")
    return void


def resolve_pursue_target(battle: Battle, actor: dict,
                          ctx: MissionContext) -> tuple[dict | None, str]:
    """Pinned PURSUE eligibility: designated > fresh-stale > adjacent."""
    side = actor_side(battle, actor)
    kn = knowledge_of(battle, side)
    if ctx.designated_target_id:
        for e in visible_enemies(battle, side):
            if e["id"] == ctx.designated_target_id:
                return e, "DESIGNATED"
        snap = kn.stale_contacts.get(ctx.designated_target_id)
        if snap is not None:
            return dict(snap, _stale=True), "STALE_JUST_LOST"
        return None, ""
    fresh = [(eid, snap) for eid, snap in sorted(kn.stale_contacts.items())
             if int(snap.get("turn", -99)) >= battle.world.current_turn - 1]
    if fresh:
        _eid, snap = fresh[0]
        return dict(snap, _stale=True), "JUST_WITHDREW"
    aq, ar = int(actor["q"]), int(actor["r"])
    adj = [e for e in visible_enemies(battle, side)
           if geometry.hex_distance_axial((aq, ar), (int(e["q"]), int(e["r"]))) == 1]
    if adj:
        return min(adj, key=lambda e: str(e["id"])), "ADJACENT"
    return None, ""


def resolve_pursue(battle: Battle, actor: dict, ctx: MissionContext) -> Resolution:
    side = actor_side(battle, actor)
    target, source = resolve_pursue_target(battle, actor, ctx)
    if target is None:
        return _fail(FailureCode.NO_PURSUIT_TARGET,
                     "no qualifying pursuit target (pinned eligibility)")
    tq = (int(target["q"]), int(target["r"]))
    reachable = enumerate_destinations(battle, actor, side)
    if not reachable:
        return _fail(FailureCode.NO_PURSUIT_ROUTE,
                     "no reachable legal destination")
    origin = (int(actor["q"]), int(actor["r"]))
    best_key = min(
        reachable,
        key=lambda k: (geometry.hex_distance_axial(reachable[k]["coord"], tq),
                       reachable[k]["cost"], reachable[k]["coord"]),
    )
    d = reachable[best_key]
    if geometry.hex_distance_axial(d["coord"], tq) > \
            geometry.hex_distance_axial(origin, tq):
        return _fail(FailureCode.NO_PURSUIT_ROUTE,
                     "no reachable destination closes on the pursuit target")
    closing = sum(
        1 for v in reachable.values()
        if geometry.hex_distance_axial(v["coord"], tq)
        <= geometry.hex_distance_axial(origin, tq))
    return _ok(count=closing,
               choice={"target": target, "target_source": source,
                       "coord": d["coord"], "path": list(d["path"]),
                       "cost": d["cost"]})


def resolve_reserve(battle: Battle, actor: dict, ctx: MissionContext) -> Resolution:
    side = actor_side(battle, actor)
    anchor = resolve_reserve_anchor(ctx, actor["id"], battle)
    if anchor.anchor is None:
        return _fail(FailureCode.NO_RESERVE_ANCHOR,
                     "no reserve anchor resolvable")
    radius = CanonicalModes.RESERVE_ENVELOPE_RADIUS
    origin = (int(actor["q"]), int(actor["r"]))
    if geometry.hex_distance_axial(origin, anchor.anchor) <= radius:
        if not can_hold_now(battle, actor, side):
            return _fail(FailureCode.PRECONDITION_FAILED,
                         "reserve confirm requires a holdable actor")
        return _ok(count=1, choice={"anchor": anchor.anchor,
                                    "envelope_radius": radius,
                                    "already_inside": True,
                                    "coord": origin, "path": [origin]})
    reachable = enumerate_destinations(battle, actor, side)
    if not reachable:
        return _fail(FailureCode.NO_DESTINATION,
                     "no reachable legal destination")
    inside = {k: d for k, d in reachable.items()
              if geometry.hex_distance_axial(d["coord"], anchor.anchor) <= radius}
    cands = inside if inside else reachable
    _k, d = min(cands.items(), key=lambda kd: (
        geometry.hex_distance_axial(kd[1]["coord"], anchor.anchor),
        kd[1]["cost"], kd[1]["coord"]))
    return _ok(count=len(cands),
               choice={"anchor": anchor.anchor, "envelope_radius": radius,
                       "already_inside": False,
                       "entered_envelope": bool(inside),
                       "coord": d["coord"], "path": list(d["path"]),
                       "cost": d["cost"]})


# ---------------------------------------------------------------------------
# HOLD family (+ shared hold guard)
# ---------------------------------------------------------------------------

def can_hold_now(battle: Battle, actor: dict, side: str) -> bool:
    """Pure mirror of the Battle.do_hold + wait_unit acceptance path.

    do_hold succeeds exactly when the actor exists, belongs to the acting
    side, and has not ended its action; wait_unit then succeeds exactly
    when the actor is additionally not garrisoned
    ("Garrison units cannot wait"). No mutation. Any drift here trips the
    full-info invariant test.
    """
    u = battle.world.unit_dict(actor["id"])
    return bool(u) and str(u.get("faction", "")) == side \
        and not bool(u.get("action_ended", False)) \
        and not bool(u.get("garrisoned", False))


def resolve_hold(battle: Battle, actor: dict, _ctx: MissionContext) -> Resolution:
    side = actor_side(battle, actor)
    if not can_hold_now(battle, actor, side):
        return _fail(FailureCode.PRECONDITION_FAILED,
                     "actor cannot hold now (resolved or missing)")
    return _ok(count=1, choice={"coord": (int(actor["q"]), int(actor["r"]))})


# ---------------------------------------------------------------------------
# Archer range skills
# ---------------------------------------------------------------------------

def los_predicate_ok(battle: Battle, side: str, target: Hex) -> bool:
    """Authorized LOS predicate: the TARGET cell must be currently visible
    to the acting side (the post-arrival firing relationship)."""
    kn = battle.blue_knowledge if side == "blue" else battle.red_knowledge
    return kn.is_hex_visible(target[0], target[1])


def resolve_range_anchor(battle: Battle, actor: dict,
                         ctx: MissionContext) -> Hex | None:
    """Designated/flank target coord, else nearest authorized visible enemy."""
    side = actor_side(battle, actor)
    if ctx.designated_target_id or ctx.flank_target_id:
        want = ctx.designated_target_id or ctx.flank_target_id
        for e in visible_enemies(battle, side):
            if e["id"] == want:
                return (int(e["q"]), int(e["r"]))
        # Frozen quirk (archer.py): a stale designation falls through to the
        # nearest-visible default instead of failing. Preserved verbatim.
    vis = visible_enemies(battle, side)
    if not vis:
        return None
    origin = (int(actor["q"]), int(actor["r"]))
    anchor_t = min(vis, key=lambda e: (
        geometry.hex_distance_axial(origin, (int(e["q"]), int(e["r"]))),
        str(e["id"])))
    return (int(anchor_t["q"]), int(anchor_t["r"]))


def resolve_reposition_range(battle: Battle, actor: dict,
                             ctx: MissionContext) -> Resolution:
    side = actor_side(battle, actor)
    anchor = resolve_range_anchor(battle, actor, ctx)
    if anchor is None:
        return _fail(FailureCode.NO_RANGE_ANCHOR,
                     "no designated target/anchor and no authorized visible enemy")
    rng = combat.get_attack_range(str(actor.get("class", "archer")))
    ideal = max(1, rng - CanonicalModes.REPOSITION_RANGE_IDEAL_OFFSET)
    reachable = enumerate_destinations(battle, actor, side)
    if not reachable:
        return _fail(FailureCode.NO_DESTINATION,
                     "no reachable legal destination")
    valid = {k: d for k, d in reachable.items()
             if 0 < geometry.hex_distance_axial(d["coord"], anchor) <= rng
             and los_predicate_ok(battle, side, anchor)}
    if not valid:
        return _fail(FailureCode.NO_DESTINATION,
                     "no reachable destination satisfies the range/LOS envelope")
    best_k = min(
        valid,
        key=lambda k: (abs(geometry.hex_distance_axial(valid[k]["coord"], anchor) - ideal),
                       valid[k]["cost"], valid[k]["coord"]),
    )
    d = valid[best_k]
    return _ok(count=len(valid),
               choice={"anchor": anchor, "coord": d["coord"],
                       "path": list(d["path"]), "cost": d["cost"]})


def resolve_kite_threat(battle: Battle, actor: dict) -> dict | None:
    """Nearest authorized visible threat (stable id tie-break)."""
    side = actor_side(battle, actor)
    vis = visible_enemies(battle, side)
    if not vis:
        return None
    origin = (int(actor["q"]), int(actor["r"]))
    return min(vis, key=lambda e: (
        geometry.hex_distance_axial(origin, (int(e["q"]), int(e["r"]))),
        str(e["id"])))


def resolve_kite(battle: Battle, actor: dict, ctx: MissionContext) -> Resolution:
    side = actor_side(battle, actor)
    threat = resolve_kite_threat(battle, actor)
    if threat is None:
        return _fail(FailureCode.NO_KITE_THREAT,
                     "no authorized threat to kite from")
    origin = (int(actor["q"]), int(actor["r"]))
    threat_coord = (int(threat["q"]), int(threat["r"]))
    anchor = None
    if ctx.designated_target_id:
        for e in visible_enemies(battle, side):
            if e["id"] == ctx.designated_target_id:
                anchor = (int(e["q"]), int(e["r"]))
                break
    if anchor is None:
        anchor = threat_coord
    rng = combat.get_attack_range(str(actor.get("class", "archer")))
    reachable = enumerate_destinations(battle, actor, side)
    if not reachable:
        return _fail(FailureCode.NO_DESTINATION,
                     "no reachable legal destination")
    origin_threat_d = geometry.hex_distance_axial(origin, threat_coord)
    cands = {k: d for k, d in reachable.items()
             if geometry.hex_distance_axial(d["coord"], threat_coord) > origin_threat_d
             and geometry.hex_distance_axial(d["coord"], anchor) <= rng
             and los_predicate_ok(battle, side, anchor)}
    if not cands:
        return _fail(FailureCode.NO_DESTINATION,
                     "no destination increases threat separation while preserving range/LOS")
    best_k = min(
        cands,
        key=lambda k: (-geometry.hex_distance_axial(cands[k]["coord"], threat_coord),
                       cands[k]["cost"], cands[k]["coord"]),
    )
    d = cands[best_k]
    return _ok(count=len(cands),
               choice={"threat": threat, "anchor": anchor,
                       "coord": d["coord"], "path": list(d["path"]),
                       "cost": d["cost"]})


# ---------------------------------------------------------------------------
# Scout RECON_ADVANCE / SHADOW / EVADE
# ---------------------------------------------------------------------------

def recon_coverage_gain(battle: Battle, actor: dict, coord: Hex) -> int:
    """Canonical coverage gain: hexes in the actor vision disc around coord
    that are not currently visible to the acting side (authorized only)."""
    side = actor_side(battle, actor)
    kn = knowledge_of(battle, side)
    radius = max_vision_radius(str(actor.get("class", "scout")))
    n = 0
    for dq in range(-radius, radius + 1):
        for dr in range(-radius, radius + 1):
            if geometry.hex_distance_axial((0, 0), (dq, dr)) > radius:
                continue
            if not kn.is_hex_visible(coord[0] + dq, coord[1] + dr):
                n += 1
    return n


def resolve_recon_advance(battle: Battle, actor: dict,
                          ctx: MissionContext) -> Resolution:
    side = actor_side(battle, actor)
    anchor = resolve_recon_waypoint(ctx, actor["id"], battle)
    if anchor.anchor is None:
        return _fail(FailureCode.NO_RECON_ANCHOR,
                     "no recon waypoint and no unexplored candidates in authorized knowledge")
    reachable = enumerate_destinations(battle, actor, side)
    if not reachable:
        return _fail(FailureCode.NO_RECON_DESTINATION,
                     "no reachable legal destination")
    origin = (int(actor["q"]), int(actor["r"]))
    best_key = min(
        reachable,
        key=lambda k: (-recon_coverage_gain(battle, actor, reachable[k]["coord"]),
                       geometry.hex_distance_axial(reachable[k]["coord"], anchor.anchor),
                       reachable[k]["cost"], reachable[k]["coord"]),
    )
    d = reachable[best_key]
    if geometry.hex_distance_axial(d["coord"], anchor.anchor) >= \
            geometry.hex_distance_axial(origin, anchor.anchor) \
            and recon_coverage_gain(battle, actor, d["coord"]) == 0:
        return _fail(FailureCode.NO_RECON_DESTINATION,
                     "no reachable destination progresses recon")
    return _ok(count=1, choice={"anchor": anchor.anchor,
                                "anchor_source": anchor.source,
                                "coord": d["coord"], "path": list(d["path"]),
                                "cost": d["cost"]})


def resolve_shadow_target(battle: Battle, actor: dict,
                          ctx: MissionContext) -> tuple[dict | None, str]:
    """Designated target (must be authorized/visible), else nearest visible."""
    side = actor_side(battle, actor)
    vis = visible_enemies(battle, side)
    if ctx.designated_target_id:
        for e in vis:
            if e["id"] == ctx.designated_target_id:
                return e, ""
        return None, "designated shadow target not currently authorized/visible"
    if not vis:
        return None, "no authorized visible enemy"
    origin = (int(actor["q"]), int(actor["r"]))
    return min(vis, key=lambda e: (
        geometry.hex_distance_axial(origin, (int(e["q"]), int(e["r"]))),
        str(e["id"]))), ""


def resolve_shadow(battle: Battle, actor: dict, ctx: MissionContext) -> Resolution:
    side = actor_side(battle, actor)
    target, why = resolve_shadow_target(battle, actor, ctx)
    if target is None:
        return _fail(FailureCode.NO_SHADOW_TARGET, why)
    t_coord = (int(target["q"]), int(target["r"]))
    vision = max_vision_radius(str(actor.get("class", "scout")))
    band = (vision, vision + CanonicalModes.SHADOW_BAND_WIDTH)
    reachable = enumerate_destinations(battle, actor, side)
    if not reachable:
        return _fail(FailureCode.NO_SHADOW_DESTINATION,
                     "no reachable legal destination")
    kn = knowledge_of(battle, side)

    def in_band(coord: Hex) -> bool:
        d = geometry.hex_distance_axial(coord, t_coord)
        return band[0] <= d <= band[1] and kn.is_hex_visible(t_coord[0], t_coord[1])

    cands = {k: d for k, d in reachable.items() if in_band(d["coord"])}
    if not cands:
        return _fail(FailureCode.NO_SHADOW_DESTINATION,
                     "no reachable position inside the shadow band with visibility preserved")
    best_k = min(cands, key=lambda k: (cands[k]["cost"], cands[k]["coord"]))
    d = cands[best_k]
    return _ok(count=len(cands),
               choice={"target": target, "band": band,
                       "coord": d["coord"], "path": list(d["path"]),
                       "cost": d["cost"]})


def resolve_evade(battle: Battle, actor: dict, ctx: MissionContext) -> Resolution:
    side = actor_side(battle, actor)
    known = nearest_known_enemy(battle, actor, side)
    if known is None:
        return _fail(FailureCode.NO_EVADE_THREAT,
                     "no authorized threat in the declared threat set")
    _, threat_coord, _ = known
    reachable = enumerate_destinations(battle, actor, side)
    if not reachable:
        return _fail(FailureCode.NO_SAFE_ROUTE,
                     "no reachable evade destination")
    origin = (int(actor["q"]), int(actor["r"]))
    origin_d = geometry.hex_distance_axial(origin, threat_coord)
    best_key = min(
        reachable,
        key=lambda k: (-geometry.hex_distance_axial(reachable[k]["coord"], threat_coord),
                       reachable[k]["cost"], reachable[k]["coord"]),
    )
    d = reachable[best_key]
    if geometry.hex_distance_axial(d["coord"], threat_coord) <= origin_d:
        return _fail(FailureCode.NO_SAFE_ROUTE,
                     "no reachable destination increases threat separation")
    safer = sum(
        1 for v in reachable.values()
        if geometry.hex_distance_axial(v["coord"], threat_coord) > origin_d)
    return _ok(count=safer,
               choice={"threat_coord": threat_coord,
                       "coord": d["coord"], "path": list(d["path"]),
                       "cost": d["cost"]})


__all__ = [
    "CANDIDATES_VERSION",
    "Resolution",
    "can_hold_now",
    "flank_band_cells",
    "los_predicate_ok",
    "recon_coverage_gain",
    "resolve_advance",
    "resolve_attack_target",
    "resolve_evade",
    "resolve_flank",
    "resolve_flank_target",
    "resolve_focus_target",
    "resolve_hold",
    "resolve_kite",
    "resolve_kite_threat",
    "resolve_pursue",
    "resolve_pursue_target",
    "resolve_range_anchor",
    "resolve_recon_advance",
    "resolve_regroup",
    "resolve_reposition",
    "resolve_reposition_range",
    "resolve_reserve",
    "resolve_screen",
    "resolve_shadow",
    "resolve_shadow_target",
    "resolve_support",
    "resolve_support_recipient",
    "resolve_withdraw",
    "screen_midpoint",
]
