"""Movement — Dijkstra envelope and route search, ported semantically literally.

Source of authority: scripts/step3/step3_pathfinding.gd (calculate_envelope,
find_route, _reconstruct_path). Parity-critical details preserved exactly:

- array-scan priority queue (lowest g_score; FIRST index wins ties, matching
  Godot's `if c < best_cost` strict comparison over insertion order);
- relax ONLY when `tent_g < existing_g - 0.0001` (strict epsilon);
- neighbor order = frozen HexUtils.DIRECTIONS;
- origin exempt from occupancy blocking; player-known occupancy blocks
  traversal (route AROUND, hard planning obstacle);
- `tent_g > max_budget` prunes expansion; reached nodes classify
  (spent+cost, river) THEN the policy filter is applied;
- destination occupied => dropped from reachable_data;
- stronghold footprint hexes never route through; impassable terrain skipped.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from python_sim.rules import geometry, march, terrain
from python_sim.rules.geometry import Hex

# Godot literal
RELAX_EPSILON: float = 0.0001


@dataclass
class RouteInfo:
    """Mirror of Step3Pathfinding.RouteInfo."""

    found: bool = False
    origin: Hex = (0, 0)
    destination: Hex = (0, 0)
    path: list[Hex] = field(default_factory=list)
    cost: float = 0.0
    march_class: int = march.MarchClass.GREEN
    crosses_river: bool = False
    morale_penalty: float = 0.0
    is_valid_destination: bool = False
    rejection_reason: str = ""


@dataclass
class EnvelopeResult:
    """Mirror of Step3Pathfinding.EnvelopeResult."""

    origin: Hex = (0, 0)
    green_hexes: list[Hex] = field(default_factory=list)
    orange_hexes: list[Hex] = field(default_factory=list)
    red_hexes: list[Hex] = field(default_factory=list)
    # "q,r" -> {"coord", "cost", "march_class", "crosses_river", "path",
    #           "morale_penalty"} — the food_cost field is retired (SUP-FINAL).
    reachable_data: dict[str, dict] = field(default_factory=dict)


def calculate_envelope(
    origin: Hex,
    unit_class: str,
    base_mp: float,
    remaining_mp: float,
    policy: int,
    cell_data: dict[str, dict],
    occupied_units: dict[str, dict],
    river_cells: dict[str, bool],
    friendly_faction: str = "blue",
    stronghold_cells: dict[str, bool] | None = None,
    turn_move_cost_spent: float = -1.0,
    p_blue_limit: float = -1.0,
    p_red_limit: float = -1.0,
    p_black_limit: float = -1.0,
    morale_rout_enabled: bool = False,
) -> EnvelopeResult:
    """Literal port of Step3Pathfinding.calculate_envelope."""
    if stronghold_cells is None:
        stronghold_cells = {}
    result = EnvelopeResult(origin=origin)

    if not geometry.is_playable_hex(origin):
        return result

    blue_lim = p_blue_limit if p_blue_limit > 0.0 else march.get_blue_limit(base_mp)
    red_lim = p_red_limit if p_red_limit > 0.0 else march.get_red_limit(base_mp)
    black_lim = p_black_limit if p_black_limit > 0.0 else march.get_black_limit(base_mp)
    spent = turn_move_cost_spent if turn_move_cost_spent >= 0.0 else max(0.0, blue_lim - remaining_mp)

    max_budget = march.get_max_additional_budget(spent, blue_lim, red_lim, black_lim, policy)
    if max_budget <= 0.001:
        # No movement budget available under current policy.
        return result

    origin_key = geometry.key_of(origin)
    g_score: dict[str, float] = {origin_key: 0.0}
    river_flag: dict[str, bool] = {origin_key: False}
    came_from: dict[str, Hex] = {}

    # Open set as insertion-ordered array; array-scan PQ (Godot parity: the
    # FIRST lowest-cost node is taken, and removal preserves order).
    open_set: list[Hex] = [origin]

    while open_set:
        best_idx = 0
        best_cost = g_score.get(geometry.key_of(open_set[0]), 1e9)
        for i in range(1, len(open_set)):
            c = g_score.get(geometry.key_of(open_set[i]), 1e9)
            if c < best_cost:
                best_cost = c
                best_idx = i

        current = open_set.pop(best_idx)
        current_key = geometry.key_of(current)
        current_g = g_score[current_key]
        current_river = river_flag.get(current_key, False)

        if current_g > max_budget:
            continue

        for n in geometry.neighbors(current):
            if not geometry.is_playable_hex(n):
                continue
            n_key = geometry.key_of(n)
            # §25: never route through intact fortress/city interiors.
            if n_key in stronghold_cells:
                continue
            cell = cell_data.get(n_key)
            terrain_type = int(cell["terrain"]) if cell is not None else 0

            if terrain.is_impassable(terrain_type):
                continue

            # STEP-05R3 §6: player-known occupancy blocks traversal; origin exempt.
            if n_key in occupied_units and n_key != origin_key:
                continue

            step_cost = terrain.get_terrain_cost(terrain_type, unit_class)
            tent_g = current_g + step_cost

            if tent_g > max_budget:
                continue

            # River crossing: current or neighbor touches river.
            step_crosses_river = bool(
                current_river
                or river_cells.get(n_key, False)
                or river_cells.get(current_key, False)
                or terrain_type == 7
            )

            existing_g = g_score.get(n_key, 1e9)
            if tent_g < existing_g - RELAX_EPSILON:
                g_score[n_key] = tent_g
                river_flag[n_key] = step_crosses_river
                came_from[n_key] = current
                if n not in open_set:
                    open_set.append(n)

    # Classify reached nodes, then policy-filter (ORDER IS LOAD-BEARING).
    for k in g_score:
        parts = k.split(",")
        coord = (int(parts[0]), int(parts[1]))
        if coord == origin:
            continue
        if k in occupied_units:
            continue

        cost = g_score[k]
        has_river = river_flag.get(k, False)
        march_class = march.classify_march_by_cumulative_cost(spent + cost, blue_lim, red_lim, has_river)

        if not march.is_policy_allowed(policy, march_class):
            continue

        path = _reconstruct_path(origin, coord, came_from)
        result.reachable_data[k] = {
            "coord": coord,
            "cost": cost,
            "march_class": march_class,
            "crosses_river": has_river,
            "path": path,
            "morale_penalty": march.get_morale_penalty(march_class, morale_rout_enabled),
        }
        if march_class == march.MarchClass.GREEN:
            result.green_hexes.append(coord)
        elif march_class == march.MarchClass.ORANGE:
            result.orange_hexes.append(coord)
        else:
            result.red_hexes.append(coord)

    return result


def _reconstruct_path(origin: Hex, target: Hex, came_from: dict[str, Hex]) -> list[Hex]:
    """Godot _reconstruct_path: target back to origin, push_front each step."""
    path: list[Hex] = [target]
    cur = target
    cur_key = geometry.key_of(cur)
    while cur_key in came_from:
        prev = came_from[cur_key]
        path.insert(0, prev)
        if prev == origin:
            break
        cur = prev
        cur_key = geometry.key_of(cur)
    return path


def find_route(
    origin: Hex,
    destination: Hex,
    unit_class: str,
    base_mp: float,
    remaining_mp: float,
    policy: int,
    cell_data: dict[str, dict],
    occupied_units: dict[str, dict],
    river_cells: dict[str, bool],
    friendly_faction: str = "blue",
    stronghold_cells: dict[str, bool] | None = None,
    turn_move_cost_spent: float = -1.0,
    p_blue_limit: float = -1.0,
    p_red_limit: float = -1.0,
    p_black_limit: float = -1.0,
    morale_rout_enabled: bool = False,
) -> RouteInfo:
    """Literal port of Step3Pathfinding.find_route (rejection reasons included)."""
    if stronghold_cells is None:
        stronghold_cells = {}
    info = RouteInfo(origin=origin, destination=destination)

    if origin == destination:
        info.found = True
        info.path = [origin]
        info.cost = 0.0
        info.march_class = march.MarchClass.GREEN
        info.is_valid_destination = False
        info.rejection_reason = "Origin is destination"
        return info

    if not geometry.is_playable_hex(destination):
        info.rejection_reason = "Destination outside playable map"
        return info

    dest_key = geometry.key_of(destination)
    if dest_key in occupied_units:
        info.rejection_reason = "Destination is occupied"
        return info
    if dest_key in stronghold_cells:
        info.rejection_reason = "Destination inside stronghold footprint — use garrison entry"
        return info

    dest_cell = cell_data.get(dest_key)
    if dest_cell is not None and terrain.is_impassable(int(dest_cell["terrain"])):
        info.rejection_reason = "Destination is impassable"
        return info

    env = calculate_envelope(
        origin, unit_class, base_mp, remaining_mp, policy,
        cell_data, occupied_units, river_cells, friendly_faction, stronghold_cells,
        turn_move_cost_spent, p_blue_limit, p_red_limit, p_black_limit,
        morale_rout_enabled,
    )

    if dest_key in env.reachable_data:
        d = env.reachable_data[dest_key]
        info.found = True
        info.path = list(d["path"])
        info.cost = float(d["cost"])
        info.march_class = int(d["march_class"])
        info.crosses_river = bool(d["crosses_river"])
        info.morale_penalty = float(d["morale_penalty"])
        info.is_valid_destination = True
        return info

    if policy != march.MarchPolicy.RED_ALLOWED:
        env_all = calculate_envelope(
            origin, unit_class, base_mp, remaining_mp, march.MarchPolicy.RED_ALLOWED,
            cell_data, occupied_units, river_cells, friendly_faction, stronghold_cells,
            turn_move_cost_spent, p_blue_limit, p_red_limit, p_black_limit,
            morale_rout_enabled,
        )
        if dest_key in env_all.reachable_data:
            d_all = env_all.reachable_data[dest_key]
            mc = int(d_all["march_class"])
            label = {march.MarchClass.GREEN: "BLUE (일반 행군)", march.MarchClass.ORANGE: "RED (강행군)", march.MarchClass.RED: "BLACK (급행군/도하)"}.get(mc, "UNKNOWN")
            info.rejection_reason = f"Requires {label} march (forbidden by current policy)"
            return info

    info.rejection_reason = "Destination not reachable within current policy budget"
    return info


__all__ = ["EnvelopeResult", "RELAX_EPSILON", "RouteInfo", "calculate_envelope", "find_route"]
