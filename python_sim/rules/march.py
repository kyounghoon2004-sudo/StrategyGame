"""March classes, march policies, and march classification — Step3Config port.

Parity-critical literals:
- march multipliers GREEN 1.0 / ORANGE 2.0 / RED 2.2 (Step3Config
  MARCH_MULTIPLIERS as consumed by get_blue/red/black_limit).
- classification tolerances: +0.001 on both tier boundaries.
- river crossing FORCES MarchClass.RED regardless of cost.
"""

from __future__ import annotations

from enum import IntEnum

# --- Step6 fatigue accumulation (applied by the unit manager on any march) ---
FATIGUE_GREEN: float = 4.0
FATIGUE_ORANGE: float = 18.0
FATIGUE_RED: float = 32.0
FATIGUE_EXHAUSTED: float = 60.0


class MarchClass(IntEnum):
    GREEN = 0
    ORANGE = 1
    RED = 2


class MarchPolicy(IntEnum):
    GREEN_ONLY = 0
    ORANGE_ALLOWED = 1
    RED_ALLOWED = 2


MARCH_MULTIPLIERS: dict[int, float] = {
    MarchClass.GREEN: 1.0,
    MarchClass.ORANGE: 2.0,
    MarchClass.RED: 2.2,
}

# Step3Config.CLASS_BASE_MOVEMENT (data-configurable; supply retired from
# spawn per SUP-1 but the movement entry stays authoritative).
CLASS_BASE_MOVEMENT: dict[str, float] = {
    "cavalry": 3.0,
    "infantry": 2.0,
    "archer": 2.0,
    "spear": 2.0,
    "spearman": 2.0,
    "scout": 4.0,
    "siege": 1.0,
    "conscript": 1.0,
    "hq": 1.0,
    "supply": 8.0,
}

# Step3Config.MORALE_PENALTY (applied only when morale_rout_enabled)
MORALE_PENALTY: dict[int, float] = {
    MarchClass.GREEN: 0.0,
    MarchClass.ORANGE: 5.0,
    MarchClass.RED: 15.0,
}


def get_base_movement(unit_class: str) -> float:
    key = unit_class.lower()
    if key == "spearmen":
        key = "spearman"
    elif key == "archers":
        key = "archer"
    elif key == "scouts":
        key = "scout"
    elif key == "conscripts":
        key = "conscript"
    return float(CLASS_BASE_MOVEMENT.get(key, 2.0))


def get_blue_limit(base_mp: float) -> float:
    return base_mp * 1.0


def get_red_limit(base_mp: float) -> float:
    return base_mp * 2.0


def get_black_limit(base_mp: float) -> float:
    return base_mp * 2.2


def get_max_additional_budget(
    spent: float, blue_limit: float, red_limit: float, black_limit: float, policy_tier: int
) -> float:
    """Step3Config.get_max_additional_budget — match semantics (policy OR class)."""
    if policy_tier == MarchPolicy.GREEN_ONLY or policy_tier == MarchClass.GREEN:
        return max(0.0, blue_limit - spent)
    if policy_tier == MarchPolicy.ORANGE_ALLOWED or policy_tier == MarchClass.ORANGE:
        return max(0.0, red_limit - spent)
    if policy_tier == MarchPolicy.RED_ALLOWED or policy_tier == MarchClass.RED:
        return max(0.0, black_limit - spent)
    return max(0.0, blue_limit - spent)


def classify_march_by_cumulative_cost(
    total_spent_including_step: float,
    blue_limit: float,
    red_limit: float,
    crosses_river: bool,
) -> int:
    """Step3Config.classify_march_by_cumulative_cost — literal, +0.001 tolerances."""
    if crosses_river:
        return MarchClass.RED
    if total_spent_including_step <= blue_limit + 0.001:
        return MarchClass.GREEN
    if total_spent_including_step <= red_limit + 0.001:
        return MarchClass.ORANGE
    return MarchClass.RED


def is_policy_allowed(policy: int, march_class: int) -> bool:
    """Step3Config.is_policy_allowed."""
    if policy == MarchPolicy.GREEN_ONLY:
        return march_class == MarchClass.GREEN
    if policy == MarchPolicy.ORANGE_ALLOWED:
        return march_class in (MarchClass.GREEN, MarchClass.ORANGE)
    if policy == MarchPolicy.RED_ALLOWED:
        return True
    return False


def get_morale_penalty(march_class: int, morale_rout_enabled: bool) -> float:
    """Step3Config.get_morale_penalty with the sandbox gate made explicit."""
    if not morale_rout_enabled:
        return 0.0
    return float(MORALE_PENALTY.get(march_class, 0.0))


def fatigue_for_march(march_class: int) -> float:
    """UM._s6_fatigue_for_march — Step6 fatigue accumulation per march class."""
    if march_class == MarchClass.ORANGE:
        return FATIGUE_ORANGE
    if march_class == MarchClass.RED:
        return FATIGUE_RED
    return FATIGUE_GREEN


__all__ = [
    "CLASS_BASE_MOVEMENT",
    "FATIGUE_EXHAUSTED",
    "FATIGUE_GREEN",
    "FATIGUE_ORANGE",
    "FATIGUE_RED",
    "MARCH_MULTIPLIERS",
    "MarchClass",
    "MarchPolicy",
    "MORALE_PENALTY",
    "classify_march_by_cumulative_cost",
    "fatigue_for_march",
    "get_base_movement",
    "get_black_limit",
    "get_blue_limit",
    "get_max_additional_budget",
    "get_morale_penalty",
    "get_red_limit",
    "is_policy_allowed",
]
