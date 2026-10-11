"""Axial hex geometry — literal port of the authoritative tactical path.

Coordinate system (verified against the live sources, RulesetV0 §1):

- The tactical authorities (boundary gate, movement envelope, fog, combat
  ranges) operate on PURE AXIAL coordinates:
    scripts/step2r/step2r_world_boundary.gd :: is_playable_hex (axial distance)
    scripts/step3/step3_pathfinding.gd :: calculate_envelope adds HexUtils
      .DIRECTIONS (axial) directly to Vector2i cell keys.
    scripts/step5/fog_of_war.gd :: _axial_distance / _hex_line.
- The odd-q offset tables in HexUtils exist for presentation/pixel input only
  (DEAD for the headless tactical path, RulesetV0 rule `pixel_rounding`).

Direction order is frozen: HexUtils.DIRECTIONS (E, NE, NW, W, SW, SE).
Board: radius-40 hexagon = 4,921 playable cells centered at (0,0).
"""

from __future__ import annotations

from python_jev.constants import AXIAL_DIRECTIONS

# Authoritative constants (step2r_world_boundary.gd)
HEX_RADIUS: int = 40
PLAYABLE_HEX_COUNT: int = 4921
OUTER_HEX_RADIUS: int = 85

# Terrain codes shared with fog/terrain rules (hex_cell.gd :: TerrainType)
TERRAIN_PLAINS: int = 0
TERRAIN_MOUNTAIN: int = 1
TERRAIN_FOREST: int = 2
TERRAIN_SWAMP: int = 3
TERRAIN_FORTRESS: int = 4
TERRAIN_VILLAGE: int = 5
TERRAIN_ROAD: int = 6
TERRAIN_RIVER: int = 7
TERRAIN_WALL: int = 8

# Frozen direction order (flat-top axial, clockwise from east)
DIRECTIONS: tuple[tuple[int, int], ...] = tuple((dq, dr) for dq, dr in AXIAL_DIRECTIONS)

Hex = tuple[int, int]


def axial_distance_from_origin(coord: Hex) -> int:
    s = -coord[0] - coord[1]
    return max(abs(coord[0]), abs(coord[1]), abs(s))


def hex_distance_axial(a: Hex, b: Hex) -> int:
    ds = -(a[0] + a[1]) + (b[0] + b[1])
    return max(abs(a[0] - b[0]), abs(a[1] - b[1]), abs(ds))


def is_playable_hex(coord: Hex) -> bool:
    return axial_distance_from_origin(coord) <= HEX_RADIUS


def is_impassable_mountain_hex(coord: Hex) -> bool:
    d = axial_distance_from_origin(coord)
    return HEX_RADIUS < d <= OUTER_HEX_RADIUS


def is_outside_world(coord: Hex) -> bool:
    return axial_distance_from_origin(coord) > OUTER_HEX_RADIUS


def all_playable_cells() -> list[Hex]:
    """All 4,921 playable cells in deterministic scan order (q then r)."""
    out: list[Hex] = []
    for q in range(-HEX_RADIUS, HEX_RADIUS + 1):
        for r in range(-HEX_RADIUS, HEX_RADIUS + 1):
            c = (q, r)
            if is_playable_hex(c):
                out.append(c)
    return out


def neighbors(coord: Hex) -> list[Hex]:
    """Six neighbors in frozen DIRECTIONS order."""
    q, r = coord
    return [(q + dq, r + dr) for dq, dr in DIRECTIONS]


def hex_line(a: Hex, b: Hex) -> list[Hex]:
    """Axial cube-lerp line inclusive of both endpoints (fog _hex_line)."""
    n = hex_distance_axial(a, b)
    if n == 0:
        return [a]
    ax, az = float(a[0]), float(a[1])
    ay = -ax - az
    bx, bz = float(b[0]), float(b[1])
    by = -bx - bz
    out: list[Hex] = []
    for i in range(n + 1):
        t = float(i) / float(n)
        out.append(cube_round(ax + (bx - ax) * t, ay + (by - ay) * t, az + (bz - az) * t))
    return out


def cube_round(fx: float, fy: float, fz: float) -> Hex:
    """Godot _cube_round: roundi each axis, adjust the largest-diff axis.

    Godot roundi is half-away-from-zero — cube rounding may hit .5 on tie
    lines, so the parity rounding helper is load-bearing here.
    """
    from python_sim.rules.rounding import roundi_gd

    rx = roundi_gd(fx)
    ry = roundi_gd(fy)
    rz = roundi_gd(fz)
    dx = abs(float(rx) - fx)
    dy = abs(float(ry) - fy)
    dz = abs(float(rz) - fz)
    if dx > dy and dx > dz:
        rx = -ry - rz
    elif dy > dz:
        ry = -rx - rz
    else:
        rz = -rx - ry
    return (rx, rz)


def key_of(coord: Hex) -> str:
    """Godot \"%d,%d\" string key format."""
    return f"{coord[0]},{coord[1]}"


__all__ = [
    "DIRECTIONS",
    "HEX_RADIUS",
    "Hex",
    "OUTER_HEX_RADIUS",
    "PLAYABLE_HEX_COUNT",
    "TERRAIN_FOREST",
    "TERRAIN_FORTRESS",
    "TERRAIN_MOUNTAIN",
    "TERRAIN_PLAINS",
    "TERRAIN_RIVER",
    "TERRAIN_ROAD",
    "TERRAIN_SWAMP",
    "TERRAIN_VILLAGE",
    "TERRAIN_WALL",
    "all_playable_cells",
    "axial_distance_from_origin",
    "cube_round",
    "hex_distance_axial",
    "hex_line",
    "is_impassable_mountain_hex",
    "is_outside_world",
    "is_playable_hex",
    "key_of",
    "neighbors",
]
