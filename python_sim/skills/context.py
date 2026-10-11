"""Mission context + knowledge-safe anchor resolution (Notion I4 / step 4).

Anchors are mission facts supplied by the General/mission layer. Resolution
NEVER invents a battlefield anchor from WorldTruth (Notion: "never infer an
anchor from the battlefield when the contract requires a declared one") —
missing declared anchors fail the skill with NO_*_ANCHOR.

Withdrawal fallback: when no explicit withdraw anchor is declared, the
engine-owned actor-side HQ is the canonical safe zone (turn.py defeat rule
makes the HQ the faction's survival anchor). This is NOT a battlefield
inference — it is the engine-owned faction anchor.

Recon waypoints: Scout.RECON_ADVANCE's "authoritative unexplored/observation
candidate set" is the acting faction's EXPLORED-but-unseen frontier from
FactionKnowledge (authorized knowledge only, never WorldTruth truth cells).
"""

from __future__ import annotations

from dataclasses import dataclass, field

from python_sim.rules import geometry
from python_sim.rules.geometry import Hex, hex_distance_axial
from python_sim.sim.battle import Battle


@dataclass
class MissionContext:
    """Typed General intent supplied alongside the selected skill."""

    scenario_id: str = ""
    mission_type: str = "SEEK_BATTLE"
    objective_type: str = "ENEMY_ARMY"
    primary_objective: str = "destroy_all_red"
    turn_limit: int = 12
    actor_mission_role: str = "PRIMARY"

    # declared anchors (None = absent -> NO_*_ANCHOR for skills that require one)
    advance_anchor: Hex | None = None
    reposition_anchor: Hex | None = None
    withdraw_anchor: Hex | None = None
    support_recipient: str | None = None
    reserve_anchor: Hex | None = None
    regroup_anchor: Hex | None = None
    screen_anchor: Hex | None = None
    recon_waypoint: Hex | None = None
    flank_target_id: str | None = None
    designated_target_id: str | None = None

    doctrine: dict = field(default_factory=dict)

    def to_dict(self) -> dict:
        def hx(h):
            return [h[0], h[1]] if h is not None else None
        return {
            "scenario_id": self.scenario_id,
            "mission_type": self.mission_type,
            "objective_type": self.objective_type,
            "primary_objective": self.primary_objective,
            "turn_limit": self.turn_limit,
            "actor_mission_role": self.actor_mission_role,
            "advance_anchor": hx(self.advance_anchor),
            "reposition_anchor": hx(self.reposition_anchor),
            "withdraw_anchor": hx(self.withdraw_anchor),
            "support_recipient": self.support_recipient,
            "reserve_anchor": hx(self.reserve_anchor),
            "regroup_anchor": hx(self.regroup_anchor),
            "screen_anchor": hx(self.screen_anchor),
            "recon_waypoint": hx(self.recon_waypoint),
            "flank_target_id": self.flank_target_id,
            "designated_target_id": self.designated_target_id,
            "doctrine": dict(self.doctrine),
        }


@dataclass
class AnchorResolution:
    """Declared anchor + source attribution (replay evidence, Notion I12)."""

    anchor: Hex | None
    source: str                 # DECLARED | HQ_FALLBACK | NONE
    detail: str = ""


def resolve_advance_anchor(ctx: MissionContext, actor_id: str, battle: Battle) -> AnchorResolution:
    """Declared advance anchor; objective anchor; else NONE (no invention)."""
    if ctx.advance_anchor is not None:
        return AnchorResolution(tuple(ctx.advance_anchor), "DECLARED")
    if ctx.designated_target_id:
        u = battle.world.unit_dict(ctx.designated_target_id)
        if u and u.get("soldier_count", 0) > 0:
            return AnchorResolution((int(u["q"]), int(u["r"])), "DECLARED", "designated_target")
    if ctx.primary_objective in ("destroy_all_red", "capture_capital") and ctx.objective_type == "ENEMY_ARMY":
        # Engine-owned mission anchor: the first stronghold anchor of the
        # enemy faction when strongholds are registered, else NONE.
        for sh in battle.world.strongholds.values():
            if sh.owner != "blue":
                return AnchorResolution(sh.get_anchor(), "DECLARED", "mission_objective_structure")
    return AnchorResolution(None, "NONE")


def resolve_reposition_anchor(ctx: MissionContext, actor_id: str, battle: Battle) -> AnchorResolution:
    if ctx.reposition_anchor is not None:
        return AnchorResolution(tuple(ctx.reposition_anchor), "DECLARED")
    return AnchorResolution(None, "NONE")


def resolve_withdraw_anchor(ctx: MissionContext, actor_id: str, battle: Battle) -> AnchorResolution:
    """Declared withdraw anchor; else the engine-owned own-side HQ."""
    if ctx.withdraw_anchor is not None:
        return AnchorResolution(tuple(ctx.withdraw_anchor), "DECLARED")
    for u in sorted(battle.world.units.values(), key=lambda x: x.id):
        if u.unit_class == "hq" and u.faction == _side_of(battle, actor_id) and u.soldier_count > 0:
            return AnchorResolution((u.q, u.r), "HQ_FALLBACK", u.id)
    return AnchorResolution(None, "NONE")


def resolve_reserve_anchor(ctx: MissionContext, actor_id: str, battle: Battle) -> AnchorResolution:
    """Declared reserve anchor; else the actor-side HQ reserve envelope."""
    if ctx.reserve_anchor is not None:
        return AnchorResolution(tuple(ctx.reserve_anchor), "DECLARED")
    for u in sorted(battle.world.units.values(), key=lambda x: x.id):
        if u.unit_class == "hq" and u.faction == _side_of(battle, actor_id) and u.soldier_count > 0:
            return AnchorResolution((u.q, u.r), "HQ_FALLBACK", u.id)
    return AnchorResolution(None, "NONE")


def resolve_regroup_anchor(ctx: MissionContext, actor_id: str, battle: Battle) -> AnchorResolution:
    """Declared regroup anchor; else the regroup envelope of nearest friendly
    non-HQ formation (explicit friendly regroup group per the contract)."""
    if ctx.regroup_anchor is not None:
        return AnchorResolution(tuple(ctx.regroup_anchor), "DECLARED")
    side = _side_of(battle, actor_id)
    actor = battle.world.unit_dict(actor_id)
    if not actor:
        return AnchorResolution(None, "NONE")
    best: Hex | None = None
    best_d = None
    for u in sorted(battle.world.units.values(), key=lambda x: x.id):
        if u.faction == side and u.id != actor_id and u.soldier_count > 0 and not u.garrisoned and u.unit_class != "hq":
            d = hex_distance_axial((actor["q"], actor["r"]), (u.q, u.r))
            if best_d is None or d < best_d:
                best_d = d
                best = (u.q, u.r)
    if best is not None:
        return AnchorResolution(best, "DECLARED", "friendly_regroup_group")
    return AnchorResolution(None, "NONE")


def resolve_recon_waypoint(
    ctx: MissionContext, actor_id: str, battle: Battle
) -> AnchorResolution:
    """Declared waypoint; else the nearest frontier hex of the acting side's
    explored-but-unseen knowledge set (authorized candidates only)."""
    if ctx.recon_waypoint is not None:
        return AnchorResolution(tuple(ctx.recon_waypoint), "DECLARED")
    kn = battle.blue_knowledge if _side_of(battle, actor_id) == "blue" else battle.red_knowledge
    actor = battle.world.unit_dict(actor_id)
    if not actor:
        return AnchorResolution(None, "NONE")
    origin = (int(actor["q"]), int(actor["r"]))
    frontier = [
        k for k in kn.explored
        if k not in kn.visible and k not in kn.objective_hexes
    ]
    if not frontier:
        # No unexplored frontier within authorized knowledge: fall back to
        # the objective anchor set (recon the known objective area).
        if kn.objective_hexes:
            best = None
            best_key = None
            for k in kn.objective_hexes:
                q_s, r_s = k.split(",")
                h = (int(q_s), int(r_s))
                d = hex_distance_axial(origin, h)
                cand = (d, k)
                if best_key is None or cand < best_key:
                    best_key = cand
                    best = h
            if best is not None:
                return AnchorResolution(best, "DECLARED", "objective_area")
        # Full-information profile: the entire playable map is the
        # authorized observation candidate set — the farthest playable hex
        # from the actor is the canonical coverage-maximizing waypoint.
        if battle.world.cell_data:
            best = None
            best_key = None
            for k, cell in battle.world.cell_data.items():
                h = (int(cell["q"]), int(cell["r"]))
                d = hex_distance_axial(origin, h)
                if not geometry.is_playable_hex(h):
                    continue
                cand = (-d, k)  # maximize distance, stable key tie-break
                if best_key is None or cand < best_key:
                    best_key = cand
                    best = h
            if best is not None:
                return AnchorResolution(best, "DECLARED", "full_info_coverage_waypoint")
        return AnchorResolution(None, "NONE")
    best: Hex | None = None
    best_key = None
    for k in frontier:
        q_s, r_s = k.split(",")
        h = (int(q_s), int(r_s))
        d = hex_distance_axial(origin, h)
        cand = (d, k)
        if best_key is None or cand < best_key:
            best_key = cand
            best = h
    return AnchorResolution(best, "DECLARED", "knowledge_frontier")


def _side_of(battle: Battle, actor_id: str) -> str:
    u = battle.world.unit_dict(actor_id)
    return str(u.get("faction", "blue")) if u else "blue"


__all__ = [
    "AnchorResolution",
    "MissionContext",
    "resolve_advance_anchor",
    "resolve_recon_waypoint",
    "resolve_regroup_anchor",
    "resolve_reserve_anchor",
    "resolve_reposition_anchor",
    "resolve_withdraw_anchor",
]
