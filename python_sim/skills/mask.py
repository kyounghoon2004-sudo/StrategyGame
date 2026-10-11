"""Observation-safe six-bit skill availability mask (skill layer).

Rule (Notion "Observation-safe six-skill legality mask"):
- 1 = eligible under KNOWN actor state + knowledge-safe preconditions, or the
  executor is allowed to attempt and resolve uncertainty authoritatively.
- 0 = proven impossible using only authorized facts and frozen preconditions.
- A hidden enemy, hidden obstacle, hidden path result, or hidden future state
  may never turn a bit off.

This is the authoritative skill-layer mask used by rollout/dataset code. The
projector's independent copy stays untouched (S0 gates depend on it).
"""

from __future__ import annotations

from python_sim.rules import geometry
from python_sim.skills.common import (
    _CLASS_TO_LEARNED,
    friendly_units,
    in_range_known,
    knowledge_of,
    max_vision_radius,
    visible_enemies,
)
from python_sim.sim.battle import Battle

CLS_TO_SLOT = {c: i for i, c in enumerate(
    ("INFANTRY", "SPEARMAN", "CAVALRY", "ARCHER", "SCOUT"))}


def observation_safe_skill_mask(battle: Battle, actor_id: str) -> list[bool]:
    """Six-bit class-specific mask; class not learned -> all False."""
    u = battle.world.unit_dict(actor_id)
    if not u or u.get("soldier_count", 0) <= 0:
        return [False] * 6
    cls = _CLASS_TO_LEARNED.get(str(u.get("class", "")).lower())
    if cls is None:
        return [False] * 6

    side = str(u["faction"])
    can_attack = (not u.get("has_attacked", False)) and (not u.get("action_ended", False))
    can_move = not u.get("action_ended", False)
    ranged = in_range_known(battle, u)
    attack_legal = can_attack and bool(ranged)

    if cls == "INFANTRY":
        return [attack_legal, can_move, True, can_move, _support_positional_available(battle, u), can_move]
    if cls == "SPEARMAN":
        return [attack_legal, can_move, True, can_move, can_move, can_move]
    if cls == "CAVALRY":
        return [attack_legal, can_move, can_move, _pursue_available(battle, u), can_move, can_move]
    if cls == "ARCHER":
        return [attack_legal, can_move, can_move, can_move, True, can_move]
    # SCOUT
    return [can_move, _shadow_available(battle, u), attack_legal, can_move, bool(visible_enemies(battle, side)), can_move]


def _support_positional_available(battle: Battle, u: dict) -> bool:
    """Positional SUPPORT (pinned mode): a friendly recipient exists —
    movement into adjacency is mechanically realizable from known facts."""
    side = str(u["faction"])
    others = [f for f in friendly_units(battle, side) if f["id"] != u["id"]]
    return can_move_check(u) and bool(others)


def _pursue_available(battle: Battle, u: dict) -> bool:
    """Pursue eligibility (pinned mode): an adjacent visible enemy (fleeing
    engagement) is knowledge-safe; just-withdrew contacts are unknown-ahead
    attempts the mask keeps 1 only when a candidate exists."""
    if not can_move_check(u):
        return False
    side = str(u["faction"])
    aq, ar = int(u["q"]), int(u["r"])
    for e in visible_enemies(battle, side):
        if geometry.hex_distance_axial((aq, ar), (int(e["q"]), int(e["r"]))) == 1:
            return True
    return False


def _shadow_available(battle: Battle, u: dict) -> bool:
    """SHADOW: a visible enemy exists within the shadow band envelope
    (vision radius..vision+2); otherwise the band position cannot be kept."""
    if not can_move_check(u):
        return False
    side = str(u["faction"])
    vision = max_vision_radius(str(u.get("class", "")))
    aq, ar = int(u["q"]), int(u["r"])
    for e in visible_enemies(battle, side):
        d = geometry.hex_distance_axial((aq, ar), (int(e["q"]), int(e["r"])))
        if vision <= d <= vision + 2:
            return True
    return False


def can_move_check(u: dict) -> bool:
    return not u.get("action_ended", False)


__all__ = ["CLS_TO_SLOT", "observation_safe_skill_mask"]
