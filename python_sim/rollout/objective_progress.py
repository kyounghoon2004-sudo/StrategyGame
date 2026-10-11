"""ObjectiveProgressV0 — frozen normalized objective progress (objective-progress-v0.1.0).

Authoritative sources: world stronghold registry (WorldState.strongholds,
fortress_map HP pool, breach flags) + mission contract primary_objective.

Frozen semantics:
- P_objective(state, faction, mission) in [0,1] measures progress on the
  MISSION-RELEVANT objective-entity set only. Arbitrary map-objective
  interaction unrelated to the current mission is never rewarded.
- O = clip(P(post) - P(branch_start), -1, +1).
- Denominator class (frozen): the branch-start mission-relevant stronghold set;
  continuous form = mission-relevant durability fraction
  (1 - relevant_hp / relevant_hp_max); binary fallback = breached_relevant /
  total_relevant when HP is unavailable. No invented HP weighting: wall HP,
  maxima, and breach flags are pre-existing authoritative game semantics
  (combat wall damage x12 / siege x2.5, Fortress 1000 / Capital 1500).
- If the mission has no objective-system component, P_objective = 0 and O = 0.
- Double-count review (frozen per-mission selection): capture_capital's capital
  signal is carried by M (MissionProgressV0) and O = 0 for that mission; all
  other current missions have no relevant objective set, so O = 0 there too.
  The denominator machinery below is nevertheless frozen, implemented, and
  tested on synthetic views, so a future objective-bearing mission with a
  signal genuinely distinct from mission progress can adopt it without
  redefining normalization.

Faction relativity mirrors MissionProgressV0: O_red = -O_blue movement, i.e.
P_objective_red = 1 - P_objective_blue over the same relevant set.
"""

from __future__ import annotations

import hashlib
import json

OBJECTIVE_PROGRESS_VERSION = "objective-progress-v0.1.0"


def _clip01(x: float) -> float:
    return max(0.0, min(1.0, float(x)))


def _clip11(x: float) -> float:
    return max(-1.0, min(1.0, float(x)))


# ---------------------------------------------------------------------------
# Objective audit table (machine-readable).
# ---------------------------------------------------------------------------
# - has_component: whether the mission declares an objective-system component
# - denominator: frozen denominator class for that mission
# - live_selection: which term carries a shared signal (double-count review)
OBJECTIVE_AUDIT: tuple[dict, ...] = (
    {
        "mission_type": "destroy_all_red",
        "has_objective_component": False,
        "reason": "completion is red-force annihilation; strongholds are not mission-relevant",
        "denominator": "none (P_objective=0, O=0)",
        "live_selection": "O=0 (no relevant objective set)",
    },
    {
        "mission_type": "capture_capital",
        "has_objective_component": True,
        "reason": "Capital_* stronghold set is the declared objective",
        "denominator": "branch-start relevant Capital durability total (hp_max sum); binary fallback breached_relevant/total_relevant",
        "live_selection": "O=0 (M carries the capital signal; no double count)",
    },
    {
        "mission_type": "survive_turns",
        "has_objective_component": False,
        "reason": "completion is time survival; strongholds are not mission-relevant",
        "denominator": "none (P_objective=0, O=0)",
        "live_selection": "O=0 (no relevant objective set)",
    },
    {
        "mission_type": "hold_hq",
        "has_objective_component": False,
        "reason": "completion is HQ survival over time; strongholds are not mission-relevant",
        "denominator": "none (P_objective=0, O=0)",
        "live_selection": "O=0 (no relevant objective set)",
    },
)

_OBJECTIVE_SPEC_CANONICAL = json.dumps(
    {
        "version": OBJECTIVE_PROGRESS_VERSION,
        "denominator_class": "branch-start relevant-set durability fraction; binary fallback breached/total",
        "audit": [
            {k: m[k] for k in ("mission_type", "has_objective_component", "denominator", "live_selection")}
            for m in OBJECTIVE_AUDIT
        ],
        "delta": "O=clip(P_post-P_pre,-1,+1); live O=0 for all current missions per overlap review",
        "faction": "P_red = 1 - P_blue",
    },
    sort_keys=True,
    separators=(",", ":"),
    ensure_ascii=True,
)


def content_hash() -> str:
    """Stable content hash of the frozen objective-progress contract."""
    return hashlib.sha256(_OBJECTIVE_SPEC_CANONICAL.encode("utf-8")).hexdigest()


# ---------------------------------------------------------------------------
# Denominator machinery (frozen; exercised by tests on synthetic views).
# ---------------------------------------------------------------------------

def relevant_objective_ids(view: dict, branch_start_ids: list[str] | None = None) -> list[str]:
    """Mission-relevant objective entity IDs.

    The branch-start set is the denominator anchor: callers pass the IDs
    captured in the BranchStartOutcomeSnapshot so the post-state uses the
    identical set (stable denominator across the branch). When branch_start_ids
    is None, the set is resolved from the given view (snapshot capture path).
    """
    objective = str(view.get("primary_objective", ""))
    if objective != "capture_capital":
        return []
    if branch_start_ids is not None:
        return [str(s) for s in branch_start_ids]
    return [str(s.get("structure_id", "")) for s in view.get("strongholds", []) if str(s.get("structure_id", "")).startswith("Capital")]


def durability_progress_blue(view: dict, relevant_ids: list[str]) -> float:
    """Continuous blue objective progress over the relevant set in [0,1].

    1 when any relevant structure is breached or blue-owned, else the
    durability fraction 1 - hp_sum/hp_max_sum. Binary fallback
    (breached/total) when HP maxima are unavailable.
    """
    if not relevant_ids:
        return 0.0
    wanted = set(relevant_ids)
    structs = [s for s in view.get("strongholds", []) if str(s.get("structure_id", "")) in wanted]
    if not structs:
        return 0.0
    for s in structs:
        if bool(s.get("breached", False)) or str(s.get("owner", "")) == "blue":
            return 1.0
    hp_sum = sum(int(s.get("fortification_hp", 0)) for s in structs)
    hp_max = sum(int(s.get("fortification_hp_max", 0)) for s in structs)
    if hp_max <= 0:
        breached = sum(1 for s in structs if bool(s.get("breached", False)))
        return _clip01(breached / float(len(structs)))
    return _clip01(1.0 - float(hp_sum) / float(hp_max))


def objective_progress_blue(view: dict, branch_start_ids: list[str] | None = None) -> float:
    """Live blue P_objective: applies the frozen overlap selection.

    For all currently active mission types the overlap review forces O=0
    (capture_capital's signal is carried by M; other missions have no relevant
    set). The denominator machinery above remains the frozen normalization for
    any future objective-bearing mission with a distinct signal.
    """
    objective = str(view.get("primary_objective", ""))
    entry = next((m for m in OBJECTIVE_AUDIT if m["mission_type"] == objective), None)
    if entry is None or not entry["has_objective_component"]:
        return 0.0
    # Overlap review: M carries the capital signal for capture_capital.
    if objective == "capture_capital":
        return 0.0
    ids = relevant_objective_ids(view, branch_start_ids)
    return durability_progress_blue(view, ids)


def objective_progress(view: dict, faction: str, branch_start_ids: list[str] | None = None) -> float:
    """Faction-relative absolute progress P_objective(state, faction, mission)."""
    faction = str(faction).lower()
    if faction not in ("blue", "red"):
        raise ValueError(f"faction must be blue|red, got {faction!r}")
    p_blue = objective_progress_blue(view, branch_start_ids)
    return p_blue if faction == "blue" else _clip01(1.0 - p_blue)


def objective_delta(o_post: float, o_pre: float) -> float:
    """Branch-relative objective term O in [-1,+1]."""
    return _clip11(float(o_post) - float(o_pre))


def objective_view_from_battle(battle) -> dict:
    """Extract the objective state view from a live Battle (duck-typed)."""
    contract = battle.scenario.get("mission_contract", {})
    return {
        "primary_objective": str(contract.get("primary_objective", "")),
        "strongholds": [
            {
                "structure_id": sh.structure_id,
                "owner": str(sh.owner),
                "breached": bool(sh.breached),
                "fortification_hp": int(sh.fortification_hp),
                "fortification_hp_max": int(sh.fortification_hp_max),
            }
            for sh in sorted(battle.world.strongholds.values(), key=lambda s: s.structure_id)
        ],
    }


__all__ = [
    "OBJECTIVE_AUDIT",
    "OBJECTIVE_PROGRESS_VERSION",
    "content_hash",
    "durability_progress_blue",
    "objective_delta",
    "objective_progress",
    "objective_progress_blue",
    "objective_view_from_battle",
    "relevant_objective_ids",
]
