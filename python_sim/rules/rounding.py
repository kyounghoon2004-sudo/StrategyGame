"""Godot numeric parity helpers.

Godot `roundi()` rounds HALF AWAY FROM ZERO; Python's built-in `round()` uses
banker's rounding. Casualty products in `CombatCalculator.calculate_combat`
and the fog strength bands go through `roundi`, so every simulator rounding
site must use `roundi_gd` below — never Python `round()`.

    roundi_gd(2.5)  == 3    (Python round(2.5)  == 2  — WRONG for parity)
    roundi_gd(-2.5) == -3   (Python round(-2.5) == -2 — WRONG for parity)

Godot float literals: `clampf/clampi/maxf/minf/absf` are ported as their
obvious Python equivalents; NaN never occurs on the battle path.

`godot_hash()` is an ISOLATED ROLL INTERFACE: the canonical battle path is
fully deterministic (variance=1.0, no randf/randi), and hash-keyed rolls
(seedend_roll / estimate_band / combat bands) key on Godot's
implementation-defined 32-bit `hash()`. Godot hash parity is recorded as
UNRESOLVED_CONTRACT_GAP `godot_hash_parity` (RulesetV0); the simulator
exposes the seam so a pinned substitute can be dropped in without touching
rule code. It never silently substitutes Python's `hash()` (salted per
process — non-reproducible across runs, therefore forbidden).
"""

from __future__ import annotations

import math

# Deterministic FNV-1a 32-bit stand-in for Godot's implementation-defined
# 32-bit string hash. Documented contract-limited: same key -> same value
# across runs/platforms (replayable), but NOT bit-equal to Godot hash().
# Any comparison whose expected value depends on the Godot hash must be
# marked CONTRACT_LIMITED in the parity fixtures.
_FNV_OFFSET: int = 0x811C9DC5
_FNV_PRIME: int = 0x01000193
_MASK32: int = 0xFFFFFFFF


def godot_hash(key: str) -> int:
    """Deterministic 32-bit stand-in for Godot hash() (contract-limited)."""
    h = _FNV_OFFSET
    for byte in key.encode("utf-8"):
        h ^= byte
        h = (h * _FNV_PRIME) & _MASK32
    return h


def seeded_roll(key: str) -> float:
    """Godot Step6DecisionLayer.seeded_roll: abs(hash(key)) % 1000 / 1000.

    Uses the pinned godot_hash stand-in (see module docstring). On the
    canonical path this only matters for morale stochasticity, which the
    canonical headless authority (sim_controller with Step6 absent) never
    invokes.
    """
    return float(abs(godot_hash(key)) % 1000) / 1000.0


def roundi_gd(value: float) -> int:
    """Godot roundi(): round half away from zero."""
    return int(math.floor(value + 0.5)) if value >= 0.0 else int(math.ceil(value - 0.5))


def round_to_step_gd(value: float, step: int) -> int:
    """Godot `_round_to(v, step)` = int(round(v/step))*step (banker's!).

    Faithfully ported: fog strength bands deliberately use Python/Godot
    `round()` semantics here (half-to-even), NOT roundi. Keep exact.
    """
    return int(round(value / float(step))) * step


def clampf_gd(v: float, lo: float, hi: float) -> float:
    return lo if v < lo else (hi if v > hi else v)


def clampi_gd(v: int, lo: int, hi: int) -> int:
    return lo if v < lo else (hi if v > hi else v)


def maxi_gd(a: int, b: int) -> int:
    return a if a >= b else b


def mini_gd(a: int, b: int) -> int:
    return a if a <= b else b


def maxf_gd(a: float, b: float) -> float:
    return a if a >= b else b


def minf_gd(a: float, b: float) -> float:
    return a if a <= b else b


def lerp_gd(a: float, b: float, t: float) -> float:
    """Godot lerpf(a, b, t) = a + (b - a) * t."""
    return a + (b - a) * t


__all__ = [
    "clampf_gd",
    "clampi_gd",
    "godot_hash",
    "lerp_gd",
    "maxf_gd",
    "maxi_gd",
    "minf_gd",
    "mini_gd",
    "round_to_step_gd",
    "roundi_gd",
    "seeded_roll",
]
