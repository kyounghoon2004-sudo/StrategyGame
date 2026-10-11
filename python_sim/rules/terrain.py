"""Terrain rules — literal port of Step3Config terrain costs + HexCell flags.

DATA-CONFIGURABLE (RulesetV0 `terrain_costs_standard` / `terrain_costs_scout`):
standard: plains 1.0, mountains 3.0, forest 2.0, swamp 2.0, fortress 1.0,
village 1.0, road 0.5, river 1.0, wall/stronghold interior 99 (impassable).
Scout specials: forest 1.0, mountains 1.0, swamp 1.5.

Impassability: terrain 8/9/10 or >= 99 (Step3Config.is_impassable).
Ambush-capable terrain: FOREST, SWAMP (HexCell.can_ambush).

NOT wired (contract gaps — never invent):
- TerrainMods.DEFENSE_BONUS (terrain defense in combat) — gap terrain_defense_wiring.
- TerrainMods.ARCHER_RANGE_BONUS — gap archer_range_bonus_wiring.
"""

from __future__ import annotations

from python_sim.rules import geometry

# Step3Config.TERRAIN_COSTS_STANDARD — keyed by authoritative terrain int
TERRAIN_COSTS_STANDARD: dict[int, float] = {
    0: 1.0,   # PLAINS
    1: 3.0,   # MOUNTAINS
    2: 2.0,   # FOREST
    3: 2.0,   # SWAMP / MARSH
    4: 1.0,   # FORTRESS
    5: 1.0,   # VILLAGE
    6: 0.5,   # ROAD
    7: 1.0,   # RIVER (traversable, crossing triggers RED)
    8: 99.0,  # WALL (impassable)
    9: 99.0,  # STRONGHOLD_FOOTPRINT
    10: 99.0, # STRONGHOLD_WALL
}

# Step3Config.TERRAIN_COSTS_SCOUT
TERRAIN_COSTS_SCOUT: dict[int, float] = {
    0: 1.0,   # PLAINS
    1: 1.0,   # MOUNTAINS (scout special)
    2: 1.0,   # FOREST (scout special)
    3: 1.5,   # SWAMP
    4: 1.0,   # FORTRESS
    5: 1.0,   # VILLAGE
    6: 0.5,   # ROAD
    7: 1.0,   # RIVER
    8: 99.0,  # WALL
    9: 99.0,
    10: 99.0,
}


def get_terrain_cost(terrain_type: int, unit_class: str) -> float:
    """Step3Config.get_terrain_cost — scout uses the special table."""
    if unit_class.lower() in ("scout", "scouts"):
        return TERRAIN_COSTS_SCOUT.get(terrain_type, 1.0)
    return TERRAIN_COSTS_STANDARD.get(terrain_type, 1.0)


def is_impassable(terrain_type: int) -> bool:
    """Step3Config.is_impassable."""
    return terrain_type == 8 or terrain_type == 9 or terrain_type == 10 or terrain_type >= 99


def can_ambush(terrain_type: int) -> bool:
    """HexCell.can_ambush — forest and swamp permit ambush triggers."""
    return terrain_type in (geometry.TERRAIN_FOREST, geometry.TERRAIN_SWAMP)


__all__ = [
    "TERRAIN_COSTS_SCOUT",
    "TERRAIN_COSTS_STANDARD",
    "can_ambush",
    "get_terrain_cost",
    "is_impassable",
]
