"""Versioned constants for the Jev policy v0 skeleton.

Only frozen contract constants live here. The frozen sources are:
  - the five class-specific six-skill tables (MVP Architecture Freeze),
  - the Production Observation Schema Freeze (radius-5 / 91-cell local patch,
    variable-N entity sets, mask taxonomy, anti-leakage invariants),
from the canonical Notion research-branch page.
"""

from __future__ import annotations

from enum import IntEnum

# --- schema / model versioning -------------------------------------------
# Frozen production observation schema freeze (Notion). Bump on any contract
# change (field additions, radius change, mask-semantics change, ...).
OBSERVATION_SCHEMA_VERSION = "obs-v0"
SCHEMA_REVISION = 0

# Model/package identity surfaced in the inference telemetry envelope.
MODEL_VERSION = "jev-policy-v0.0.0-untrained"

# --- action space ---------------------------------------------------------
NUM_SKILL_SLOTS = 6

# Exactly five learned unit classes. HQ is NOT part of the first learned
# tactical policy and must never be accepted as an acting class here.
LEARNED_CLASSES: tuple[str, ...] = (
    "INFANTRY",
    "SPEARMAN",
    "CAVALRY",
    "ARCHER",
    "SCOUT",
)

# Frozen six-slot tables. Slot indices are structurally fixed; semantics are
# class-specific (five class-specific heads, one shared trunk).
ACTION_SPACE: dict[str, tuple[str, ...]] = {
    "INFANTRY": ("ATTACK", "ADVANCE", "HOLD", "REPOSITION", "SUPPORT", "WITHDRAW"),
    "SPEARMAN": ("ATTACK", "ADVANCE", "HOLD", "REPOSITION", "SCREEN", "WITHDRAW"),
    "CAVALRY": ("ATTACK", "FLANK", "ADVANCE", "PURSUE", "RESERVE", "WITHDRAW"),
    "ARCHER": ("FIRE", "FOCUS_FIRE", "REPOSITION_RANGE", "KITE", "HOLD_POSITION", "WITHDRAW"),
    "SCOUT": ("RECON_ADVANCE", "SHADOW", "HARASS", "SCREEN", "EVADE", "REGROUP"),
}


class UnitClass(IntEnum):
    """Stable integer encoding of the five learned classes."""

    INFANTRY = 0
    SPEARMAN = 1
    CAVALRY = 2
    ARCHER = 3
    SCOUT = 4


# Sentinel selected-slot value for rows whose legality mask is all-zero.
# An all-illegal mask NEVER silently picks a skill; the caller receives this
# explicit safe-failure sentinel instead.
ALL_ILLEGAL_SLOT = -1

# --- token / relation semantics ------------------------------------------
class TokenKind(IntEnum):
    """Actor-relative token relation kinds (shared token schema, one geometry
    convention across all three relation kinds)."""

    FRIENDLY = 0
    ENEMY_VISIBLE = 1
    STALE_CONTACT = 2
    # Extra slots used only to fill representation capacity.
    PAD = 3


# --- local hex patch ------------------------------------------------------
# Frozen: actor-centered radius-5 hex patch covering exactly 91 cells,
# actor's own cell included. Never silently expanded per profile/batch.
PATCH_RADIUS = 5
PATCH_NUM_CELLS = 91

# Six axial hex directions, fixed orientation shared by every profile.
AXIAL_DIRECTIONS: tuple[tuple[int, int], ...] = (
    (1, 0),
    (1, -1),
    (0, -1),
    (-1, 0),
    (-1, 1),
    (0, 1),
)


def assert_valid_class(class_name: str) -> str:
    """Loudly reject any class outside the frozen learned-class table."""
    if class_name not in ACTION_SPACE:
        raise ValueError(
            f"Unknown acting class {class_name!r}. The learned policy supports "
            f"only {sorted(ACTION_SPACE)}; HQ is not a learned actor in v0."
        )
    if len(ACTION_SPACE[class_name]) != NUM_SKILL_SLOTS:
        raise RuntimeError(
            f"Corrupt action table for {class_name!r}: expected "
            f"{NUM_SKILL_SLOTS} slots."
        )
    return class_name
