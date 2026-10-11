"""Frozen deterministic index map for the radius-5 local hex patch (91 cells).

Freeze rationale
----------------
The Notion freeze fixes the patch radius (5) and cell count (91) and demands a
fixed axial orientation, but not the slot order. A deterministic, drift-proof
mapping is required so that Godot, the Python simulator, and this package
always place the same physical relative hex into the same slot.

Rule frozen here (ring-major, canonical axial ray order):

  1. Ring-major: index 0 is the center (0,0); then ring k = 1..5 enumerates
     all cells at hex distance k before ring k+1 starts.
  2. Ring k starts at (-k, +k), the far end of the SW ray (direction 4 of
     HexUtils.DIRECTIONS scaled by k) — Red Blob's canonical ring start.
  3. The 6k ring cells then walk the six sides in Godot HexUtils.DIRECTIONS
     order: E, NE, NW, W, SW, SE = (1,0), (1,-1), (0,-1), (-1,0), (-1,1),
     (0,1) — k steps per side, appending each cell before stepping.
  4. Within a ray, cells run from the ray's far end toward its start corner,
     which reproduces the standard Red Blob ring-walk exactly.

Properties:
  - index 0 is always the actor's own cell (projector contract);
  - the same relative (dq, dr) always maps to the same index;
  - the map is a pure function of (dq, dr) — no set/dict iteration order,
    no floating point, no map bounds involved (relative geometry only);
  - every index in [0, 90] appears exactly once (tested by R0-4).

Reference implementations exist in two places that must stay in agreement:
this module and python_jev/synthetic.py (_PATCH_OFFSETS, produced by a
row-scan generator). The R0-4 tests assert they are the same set→index
mapping through the patch geometry helpers.
"""

from __future__ import annotations

import hashlib
import json

from python_jev.constants import AXIAL_DIRECTIONS, PATCH_NUM_CELLS, PATCH_RADIUS

PATCH_CONTRACT_VERSION = "hex-patch-v0.1.0"


def hex_index_manifest() -> list[list[int]]:
    """Return the frozen 91-entry manifest as [[index, dq, dr], ...]."""
    offsets = generate_ring_major(PATCH_RADIUS)
    return [[i, dq, dr] for i, (dq, dr) in enumerate(offsets)]


def generate_ring_major(radius: int) -> list[tuple[int, int]]:
    """Ring-major axial offsets for a hex patch of the given radius.

    Center first; ring k starts at (-k, +k) and walks the ring sides in
    Godot HexUtils.DIRECTIONS order (E, NE, NW, W, SW, SE), k steps per side.
    This is the Red Blob ring algorithm verbatim (start = direction-4 far end).
    """
    if radius < 0:
        raise ValueError("radius must be >= 0")
    dirs = [tuple(d) for d in AXIAL_DIRECTIONS]
    cells: list[tuple[int, int]] = [(0, 0)]
    for k in range(1, radius + 1):
        x, z = -k, k  # start: SW ray far end = direction 4 scaled by k
        for side in range(6):
            for _step in range(k):
                cells.append((x, z))
                x += dirs[side][0]
                z += dirs[side][1]
    return cells


def offset_to_index(dq: int, dr: int, radius: int = PATCH_RADIUS) -> int:
    """Frozen (dq, dr) -> slot index. Pure function, no iteration order."""
    ds = -dq - dr
    dist = max(abs(dq), abs(dr), abs(ds))
    if dist > radius:
        raise ValueError(f"offset ({dq},{dr}) outside radius-{radius} patch")
    return RING_MAJOR_INDEX[(dq, dr)]


RING_MAJOR_OFFSETS = generate_ring_major(PATCH_RADIUS)
RING_MAJOR_INDEX: dict[tuple[int, int], int] = {
    off: i for i, off in enumerate(RING_MAJOR_OFFSETS)
}

MANIFEST: dict = {
    "contract": "HexPatchIndexMap",
    "version": PATCH_CONTRACT_VERSION,
    "radius": PATCH_RADIUS,
    "num_cells": PATCH_NUM_CELLS,
    "orientation": "flat-top axial (q,r), s=-q-r",
    "direction_order": [list(d) for d in AXIAL_DIRECTIONS],
    "rule": (
        "index 0 = (0,0); ring-major k=1..5; ring k starts at (k,-1) "
        "(east anchor (k-1,0) + direction 5); remaining cells walk the six "
        "axial rays in HexUtils.DIRECTIONS order (E,NE,NW,W,SW,SE), "
        "k-1 steps on SE then k steps on each of E,NE,NW,W,SW"
    ),
    "index_map": hex_index_manifest(),
}


def content_hash() -> str:
    payload = json.dumps(MANIFEST, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


__all__ = [
    "PATCH_CONTRACT_VERSION",
    "RING_MAJOR_INDEX",
    "RING_MAJOR_OFFSETS",
    "content_hash",
    "generate_ring_major",
    "hex_index_manifest",
    "offset_to_index",
]
