"""Shared deterministic resolution machinery for the 30 skill executors.

Everything here is faction-knowledge-bound (Notion I4): target/destination
enumeration uses the acting side's authorized occupancy and visibility only.
All tie-break chains follow the per-skill Notion contracts with the stable
axial ordering (q, then r) and stable unit ids as final criteria.
"""

from __future__ import annotations

from python_sim.rules import combat, geometry, march, movement, terrain
from python_sim.rules.geometry import Hex
from python_sim.skills.contracts import CanonicalModes
from python_sim.skills.context import MissionContext
from python_sim.sim.battle import Battle

MARCH_TIER_RANK = {"GREEN": 0, "ORANGE": 1, "RED": 2, "BLACK": 3}
_CLASS_TO_LEARNED = {
    "infantry": "INFANTRY", "spearman": "SPEARMAN", "spear": "SPEARMAN",
    "cavalry": "CAVALRY", "archer": "ARCHER", "archers": "ARCHER",
    "scout": "SCOUT", "scouts": "SCOUT",
}


def actor_guard(battle: Battle, actor_id: str) -> dict | None:
    """Fresh authoritative actor state; None -> STALE_STATE/NO_ACTOR (I3)."""
    u = battle.world.unit_dict(actor_id)
    if not u:
        return None
    return u


def skill_class_of(u: dict) -> str:
    return _CLASS_TO_LEARNED.get(str(u.get("class", "")).lower(), "")


def actor_side(battle: Battle, u: dict) -> str:
    return str(u.get("faction", "blue"))


def knowledge_of(battle: Battle, side: str):
    return battle.blue_knowledge if side == "blue" else battle.red_knowledge


def authorized_occupancy(battle: Battle, side: str) -> dict[str, dict]:
    """Player-known occupancy for blue (own + visible enemies); RED AI keeps
    full truth per the verified policy asymmetry (RulesetV0 parity rules)."""
    if side == "blue":
        vis = battle.executor.visible_enemy_ids(battle.blue_knowledge)
        return battle.world.get_player_known_occupied(vis)
    return battle.world.get_occupied_dict()


def friendly_units(battle: Battle, side: str) -> list[dict]:
    out = []
    for u in sorted(battle.world.units.values(), key=lambda x: x.id):
        if u.faction == side and u.soldier_count > 0 and not u.garrisoned:
            out.append(u.to_dict())
    return out


def visible_enemies(battle: Battle, side: str) -> list[dict]:
    """Authorized visible enemy list (stable id order)."""
    kn = knowledge_of(battle, side)
    enemy = "red" if side == "blue" else "blue"
    out = []
    for u in sorted(battle.world.units.values(), key=lambda x: x.id):
        if u.faction == enemy and u.soldier_count > 0 and not u.garrisoned:
            if kn.is_enemy_visible(u.to_dict()):
                out.append(u.to_dict())
    return out


def known_enemies(battle: Battle, side: str) -> list[dict]:
    """Currently visible enemies + stale-contact snapshots (authorized)."""
    kn = knowledge_of(battle, side)
    out = list(visible_enemies(battle, side))
    for eid in sorted(kn.stale_contacts.keys()):
        snap = dict(kn.stale_contacts[eid])
        snap["_stale"] = True
        out.append(snap)
    return out


def _stale_key(e: dict) -> tuple:
    return (-1, -1) if e.get("_stale") else (int(e.get("q", 0)), int(e.get("r", 0)))


def enumerate_targets(battle: Battle, actor: dict) -> list[dict]:
    """Attackable targets the acting side can AUTHORIZED-see, in range.

    Executor-side legality is knowledge-bound: an attack candidate must be
    currently visible to the acting side (Notion I4). The authoritative
    engine recheck happens inside Battle.do_attack anyway (I5).
    """
    side = actor_side(battle, actor)
    vis = {u["id"] for u in visible_enemies(battle, side)}
    legal = battle.executor.get_attackable_targets(actor["id"])
    return [t for t in legal if t.get("id") in vis]


def in_range_known(battle: Battle, actor: dict) -> list[dict]:
    """Visible enemies within attack range regardless of has_attacked locks
    (range geometry only — used by mask + range-resolution skills)."""
    side = actor_side(battle, actor)
    rng = combat.get_attack_range(str(actor.get("class", "infantry")))
    out = []
    aq, ar = int(actor["q"]), int(actor["r"])
    for e in visible_enemies(battle, side):
        d = geometry.hex_distance_axial((aq, ar), (int(e["q"]), int(e["r"])))
        if 0 < d <= rng:
            out.append(dict(e, distance=d))
    return out


def weakest_then_nearest(targets: list[dict], origin: Hex) -> dict | None:
    """Notion attack chain: weakest legal target -> nearest -> stable id."""
    if not targets:
        return None

    def key(t: dict):
        dist = int(t.get("distance", geometry.hex_distance_axial(origin, (int(t["q"]), int(t["r"])))))
        return (int(t.get("soldier_count", 0)), dist, str(t.get("id", "")))

    return min(targets, key=key)


def designated_or_default_target(
    battle: Battle, actor: dict, ctx: MissionContext, targets: list[dict]
) -> dict | None:
    """Step 3/4: mission designation when legal; else weakest/nearest/id."""
    if ctx.designated_target_id:
        for t in targets:
            if t.get("id") == ctx.designated_target_id:
                return dict(t, designation="MISSION_DESIGNATED")
    return weakest_then_nearest(targets, (int(actor["q"]), int(actor["r"])))


def focus_target(battle: Battle, actor: dict, ctx: MissionContext) -> dict | None:
    """FOCUS_FIRE locked target: mission designation or the canonical
    stand-in (NEAREST_VISIBLE_STABLE_ID). Never builds a weakest-target
    fallback (Notion forbids retargeting in FOCUS_FIRE)."""
    if ctx.designated_target_id:
        for e in visible_enemies(battle, actor_side(battle, actor)):
            if e["id"] == ctx.designated_target_id:
                return e
        return None
    vis = visible_enemies(battle, actor_side(battle, actor))
    if not vis:
        return None
    origin = (int(actor["q"]), int(actor["r"]))
    return min(
        vis,
        key=lambda e: (geometry.hex_distance_axial(origin, (int(e["q"]), int(e["r"]))), str(e["id"])),
    )


def enumerate_destinations(
    battle: Battle, actor: dict, side: str, policy: int | None = None
) -> dict[str, dict]:
    """Knowledge-bound movement envelope for the actor (player-known
    occupancy for blue; full truth for RED AI — the verified policy shape)."""
    u = actor
    env = movement.calculate_envelope(
        (int(u["q"]), int(u["r"])), str(u.get("class", "infantry")),
        float(u.get("base_mp", 2.0)), float(u.get("remaining_mp", u.get("base_mp", 2.0))),
        battle._policy_for(side, "auto") if policy is None else policy,
        battle.world.cell_data, authorized_occupancy(battle, side),
        battle.world.river_cells, side, battle.world.stronghold_cells,
        float(u.get("turn_move_cost_spent", 0.0)),
        float(u.get("blue_limit", march.get_blue_limit(float(u.get("base_mp", 2.0))))),
        float(u.get("red_limit", march.get_red_limit(float(u.get("base_mp", 2.0))))),
        float(u.get("black_limit", march.get_black_limit(float(u.get("base_mp", 2.0))))),
        morale_rout_enabled=battle.morale_rout_enabled,
    )
    return env.reachable_data


def destination_by_anchor(
    reachable: dict[str, dict], origin: Hex, anchor: Hex, extra_rank: dict[str, tuple] | None = None
) -> tuple[Hex, dict, list[str]]:
    """Frozen Notion destination chain for anchor-directed movement skills
    (ADVANCE / REPOSITION / WITHDRAW / RESERVE / REGROUP family):

        greatest anchor-distance reduction (max progress, deeper tiers win
        ties within equal reduction per 'most forward projection')
        -> shortest path (cost)
        -> most forward projection on the declared vector (tie inside the
        same reduction band; implemented as the geometric tie-set breaker
        at equal reduction and equal cost)
        -> stable axial hex order.

    Falls back to the plain cost-ordered minimum when NO candidate reduces
    anchor distance (contract: 'keep destinations that reduce distance'
    first, canonical nearest otherwise). No march-tier, strength, or threat
    term enters this chain (I7: stable tie-breaks only).

    Returns (coord, data, tie_break_trace)."""
    trace = ["anchor_distance_reduction", "shortest_path",
             "forward_projection", "axial_order"]

    def rank(key: str, d: dict):
        coord = d["coord"]
        progress = geometry.hex_distance_axial(origin, anchor) - \
            geometry.hex_distance_axial(coord, anchor)
        return (
            -progress,          # greatest reduction first
            d["cost"],          # shortest path
            coord,              # forward projection, then stable axial order
        )

    reducing = {
        k: d for k, d in reachable.items()
        if geometry.hex_distance_axial(d["coord"], anchor)
        < geometry.hex_distance_axial(origin, anchor)
    }
    pool = reducing if reducing else reachable
    best_key = min(pool, key=lambda k: rank(k, pool[k]))
    d = pool[best_key]
    return d["coord"], d, trace


def _tier_of(d: dict) -> str:
    mc = int(d.get("march_class", 0))
    if mc == march.MarchClass.GREEN and not d.get("crosses_river"):
        return "GREEN"
    if mc == march.MarchClass.ORANGE:
        return "ORANGE"
    return "RED"  # RED-classified (incl. river-forced)


def execute_stepwise(battle: Battle, actor_id: str, path: list[Hex]) -> dict:
    """Authoritative execution (Notion step 6) via the canonical BLUE
    stepwise authority; returns the raw executor result."""
    vis = battle.executor.visible_enemy_ids(
        knowledge_of(battle, actor_side(battle, battle.world.unit_dict(actor_id)))
    )
    return battle.executor.execute_player_stepwise_move(
        actor_id, path, vis, battle.world.cell_data, battle.world.river_cells
    )


def classify_contact(executor_result: dict) -> str:
    """hidden_enemy | visible_enemy | friendly | stronghold | '' (no stop)."""
    return str(executor_result.get("contact_kind", ""))


def nearest_known_enemy(battle: Battle, actor: dict, side: str):
    """Nearest authorized enemy (visible first, then stale) with distance."""
    origin = (int(actor["q"]), int(actor["r"]))
    best = None
    best_key = None
    for e in known_enemies(battle, side):
        q, r = _stale_key(e)
        d = geometry.hex_distance_axial(origin, (q, r))
        key = (0 if not e.get("_stale") else 1, d, str(e.get("id", "")))
        if best_key is None or key < best_key:
            best_key = key
            best = (e, (q, r), d)
    return best


def visible_count_in_band(battle: Battle, side: str, cell: Hex) -> int:
    """Authorized visibility-predicate helper for screen lanes: number of
    own-side visible hexes in the radius-5 patch centered on cell."""
    kn = knowledge_of(battle, side)
    n = 0
    for dq in range(-2, 3):
        for dr in range(-2, 3):
            if abs(dq) + abs(dr) + abs(-dq - dr) > 2:
                continue
            if kn.is_hex_visible(cell[0] + dq, cell[1] + dr):
                n += 1
    return n


def max_vision_radius(uclass: str) -> int:
    from python_sim.state.faction_knowledge import NORMAL_VISION, SCOUT_VISION

    return SCOUT_VISION if uclass.lower().startswith("scout") else NORMAL_VISION


def formation_units_near(
    battle: Battle, side: str, anchor: Hex, radius: int, exclude: str
) -> list[dict]:
    """Spacing predicate: friendly non-HQ formations within radius of anchor."""
    out = []
    for u in friendly_units(battle, side):
        if u["id"] == exclude or u.get("class") == "hq":
            continue
        if geometry.hex_distance_axial(anchor, (int(u["q"]), int(u["r"]))) <= radius:
            out.append(u)
    return out


__all__ = [
    "MARCH_TIER_RANK",
    "actor_guard",
    "actor_side",
    "authorized_occupancy",
    "classify_contact",
    "designated_or_default_target",
    "destination_by_anchor",
    "enumerate_destinations",
    "enumerate_targets",
    "execute_stepwise",
    "focus_target",
    "formation_units_near",
    "friendly_units",
    "in_range_known",
    "knowledge_of",
    "known_enemies",
    "max_vision_radius",
    "nearest_known_enemy",
    "skill_class_of",
    "visible_count_in_band",
    "visible_enemies",
    "weakest_then_nearest",
]
