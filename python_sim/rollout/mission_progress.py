"""MissionProgressV0 — frozen normalized mission progress (mission-progress-v0.1.0).

Authoritative source: SimController.evaluate_mission (scripts/sim/sim_controller.gd),
VALID_OBJECTIVES = ("destroy_all_red", "capture_capital", "survive_turns", "hold_hq").

Frozen semantics:
- P_mission(state, faction, mission) in [0,1] measures progress toward the
  authoritative SUCCESS condition of the battle's mission contract, using only
  state already consumed by the authoritative evaluator (or the underlying
  authoritative HP state behind the evaluator's breach flag).
- M = clip(P(post) - P(branch_start), -1, +1) is the ONLY mission_delta allowed
  for ValueTargetV0. The legacy raw-outcome "mission_delta" (terminal/status
  indicator) is NOT reused; it is retained untouched under raw-outcome v0.1.0.
- "victory ? 1 : 0" is never used as progress: every mission has an
  intermediate measurable definition (see audit table). Degenerate configs fall
  back to an explicit binary 0/1 (BINARY_ONLY_PROGRESS=True) rather than an
  invented shaped reward.
- Failure does not force M=-1: P measures progress toward success only;
  terminal failure is represented by T=-1 (TerminalOutcomeV0). This avoids
  double-counting terminal failure.
- Faction relativity: the evaluator is blue-centric, so P_blue is the absolute
  blue-mission progress and P_red = 1 - P_blue (zero-sum complement; red has no
  separate mission contract — red success IS blue failure). M_red = -M_blue.

All terms are faction-relative, branch-start-relative, bounded, deterministic,
auditable, derived from authoritative state, and free of tactical heuristics.
"""

from __future__ import annotations

import hashlib
import json

MISSION_PROGRESS_VERSION = "mission-progress-v0.1.0"


def content_hash() -> str:
    """Stable content hash of the frozen mission-progress contract."""
    return hashlib.sha256(_MISSION_SPEC_CANONICAL.encode("utf-8")).hexdigest()


def _clip01(x: float) -> float:
    return max(0.0, min(1.0, float(x)))


def _clip11(x: float) -> float:
    return max(-1.0, min(1.0, float(x)))


# ---------------------------------------------------------------------------
# Mission audit table (machine-readable; prose mirror in VALUE_TARGET_V0_SPEC).
# ---------------------------------------------------------------------------
# Per mission type:
# - completion: authoritative success condition (evaluator verbatim logic)
# - measurable: authoritative state consumed
# - definition: P_blue formula
# - denominator: normalization denominator + authoritative origin
# - terminal: interaction with terminal evaluation
# - support: profile support statement
# - binary_only: True only when no measurable intermediate progress exists
# - overlap: double-count review outcome (which term carries shared signals)
MISSION_AUDIT: tuple[dict, ...] = (
    {
        "mission_type": "destroy_all_red",
        "authoritative_completion": "red_alive formations empty (evaluator: red_alive.is_empty())",
        "authoritative_measurable": "red formations alive (evaluator input) vs scenario red formation count",
        "p_definition": "destroyed_red_formations / total_red_formations",
        "normalization_denominator": "scenario red formation count (scenario forces, faction==red)",
        "terminal_interaction": "victory sets P=1 (red_alive==0); defeat takes evaluator precedence but does not force M=-1 (T carries it)",
        "support": "supported on all profiles",
        "binary_only": False,
        "overlap": "formation elimination is distinct from soldier attrition (E) and stronghold state (O=0 for this mission)",
    },
    {
        "mission_type": "capture_capital",
        "authoritative_completion": "capital breached OR capital owner==blue (evaluator: capital_taken)",
        "authoritative_measurable": "Capital stronghold breach flag + owner (evaluator inputs) backed by authoritative fortification_hp (combat wall-damage state)",
        "p_definition": "1 on breached/owner==blue else 1 - fortification_hp / fortification_hp_max",
        "normalization_denominator": "Capital fortification_hp_max (authoritative stronghold registration: 1500)",
        "terminal_interaction": "victory sets P=1; defeat precedence does not force M=-1 (T carries it)",
        "support": "supported iff strongholds registered (TERRAIN_FULL_INFO and above); unsupported (P=0) when strongholds disabled (DEV_FLAT_ALL_INFO has no Capital entity)",
        "binary_only": False,
        "overlap": "M carries the capital signal; O=0 for this mission (no double count)",
    },
    {
        "mission_type": "survive_turns",
        "authoritative_completion": "turn > turn_limit and hq_alive (evaluator: turn_limit_survived)",
        "authoritative_measurable": "current turn + turn_limit (mission contract) — same branch as the evaluator",
        "p_definition": "(turn - 1) / turn_limit clipped to [0,1]",
        "normalization_denominator": "mission contract turn_limit (positive int, battle-validated)",
        "terminal_interaction": "victory (turn>limit, HQ alive) sets P=1; HQ loss is defeat via T, P stays time-based (no forced M=-1)",
        "support": "supported on all profiles",
        "binary_only": False,
        "overlap": "time survival is distinct from force attrition (E) and stronghold state (O=0 for this mission)",
    },
    {
        "mission_type": "hold_hq",
        "authoritative_completion": "turn > turn_limit and hq_alive (evaluator: same branch as survive_turns)",
        "authoritative_measurable": "current turn + turn_limit (mission contract) — same branch as the evaluator",
        "p_definition": "(turn - 1) / turn_limit clipped to [0,1]",
        "normalization_denominator": "mission contract turn_limit (positive int, battle-validated)",
        "terminal_interaction": "victory (turn>limit, HQ alive) sets P=1; HQ loss is defeat via T, P stays time-based (no forced M=-1)",
        "support": "supported on all profiles",
        "binary_only": False,
        "overlap": "time survival is distinct from force attrition (E) and stronghold state (O=0 for this mission)",
    },
)

_MISSION_SPEC_CANONICAL = json.dumps(
    {
        "version": MISSION_PROGRESS_VERSION,
        "audit": [
            {k: m[k] for k in ("mission_type", "p_definition", "normalization_denominator", "binary_only", "overlap")}
            for m in MISSION_AUDIT
        ],
        "delta": "M=clip(P_post-P_pre,-1,+1); failure never forces M=-1",
        "faction": "P_red = 1 - P_blue",
    },
    sort_keys=True,
    separators=(",", ":"),
    ensure_ascii=True,
)


# ---------------------------------------------------------------------------
# Progress evaluation (blue-centric absolute progress; faction projection out).
# ---------------------------------------------------------------------------

def mission_progress_blue(view: dict) -> float:
    """Absolute BLUE-mission progress in [0,1] from an explicit state view.

    View keys (all authoritative, evaluator-consumed):
        primary_objective: str
        turn: int (current turn, 1-based)
        turn_limit: int (mission contract)
        red_formations_alive: int
        red_formations_initial: int (scenario red formation count)
        capital: dict | None with breached: bool, owner: str,
                 fortification_hp: int, fortification_hp_max: int
                 (None when strongholds are disabled)
    """
    objective = str(view.get("primary_objective", ""))
    if objective == "destroy_all_red":
        total = int(view.get("red_formations_initial", 0))
        alive = int(view.get("red_formations_alive", 0))
        if total <= 0:
            # Degenerate contract (no red formations): binary fallback.
            return 1.0 if alive <= 0 else 0.0
        return _clip01((total - alive) / float(total))
    if objective == "capture_capital":
        capital = view.get("capital")
        if not capital:
            # No Capital entity (strongholds disabled): unsupported config.
            return 0.0
        if bool(capital.get("breached", False)) or str(capital.get("owner", "")) == "blue":
            return 1.0
        hp_max = int(capital.get("fortification_hp_max", 0))
        if hp_max <= 0:
            return 0.0
        hp = int(capital.get("fortification_hp", hp_max))
        return _clip01(1.0 - float(hp) / float(hp_max))
    if objective in ("survive_turns", "hold_hq"):
        limit = int(view.get("turn_limit", 0))
        if limit <= 0:
            return 0.0
        turn = int(view.get("turn", 1))
        return _clip01((turn - 1) / float(limit))
    # Unknown objective: no authoritative progress exists; report 0 rather
    # than inventing a requirement the game does not define.
    return 0.0


def mission_progress(view: dict, faction: str) -> float:
    """Faction-relative absolute progress P_mission(state, faction, mission)."""
    faction = str(faction).lower()
    if faction not in ("blue", "red"):
        raise ValueError(f"faction must be blue|red, got {faction!r}")
    p_blue = mission_progress_blue(view)
    return p_blue if faction == "blue" else _clip01(1.0 - p_blue)


def mission_delta(p_post: float, p_pre: float) -> float:
    """Branch-relative mission term M in [-1,+1]."""
    return _clip11(float(p_post) - float(p_pre))


def mission_view_from_battle(battle) -> dict:
    """Extract the authoritative state view from a live Battle (duck-typed).

    Denominator origins (all pre-existing authoritative state):
    - red_formations_initial: scenario forces with faction==red (battle-validated).
    - capital: Capital_* stronghold facts from world state (None if absent).
    - turn / turn_limit: world turn counter + mission contract.
    """
    contract = battle.scenario.get("mission_contract", {})
    red_initial = sum(
        1 for f in battle.scenario.get("forces", []) if str(f.get("faction", "")) == "red"
    )
    red_alive = sum(
        1 for u in battle.world.units.values() if u.faction == "red" and u.soldier_count > 0
    )
    capital = None
    for sh in sorted(battle.world.strongholds.values(), key=lambda s: s.structure_id):
        if sh.structure_id.startswith("Capital"):
            capital = {
                "breached": bool(sh.breached),
                "owner": str(sh.owner),
                "fortification_hp": int(sh.fortification_hp),
                "fortification_hp_max": int(sh.fortification_hp_max),
            }
    return {
        "primary_objective": str(contract.get("primary_objective", "")),
        "turn": int(battle.world.current_turn),
        "turn_limit": int(contract.get("turn_limit", 0)),
        "red_formations_alive": int(red_alive),
        "red_formations_initial": int(red_initial),
        "capital": capital,
    }


def is_binary_only(objective: str) -> bool:
    """Whether a mission type has only binary progress (none currently do)."""
    return next((m["binary_only"] for m in MISSION_AUDIT if m["mission_type"] == objective), False)


__all__ = [
    "MISSION_AUDIT",
    "MISSION_PROGRESS_VERSION",
    "content_hash",
    "is_binary_only",
    "mission_delta",
    "mission_progress",
    "mission_progress_blue",
    "mission_view_from_battle",
]
