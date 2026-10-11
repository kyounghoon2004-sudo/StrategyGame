"""Turn / phase model and mission evaluation — RulesetV0 turn_phase family.

Sources:
- TurnManager.BattlePhase: RECON(0) -> DEPLOY(1) -> ENGAGE(2) -> RESOLVE(3).
- Faction cycle: BLUE (player) then RED per cycle; turn increments per FULL
  cycle (UnitManager.end_turn is the turn counter authority).
- Canonical headless cycle order (sim_controller.sim_end_turn):
  Step6.end_turn_charges -> UnitManager.end_turn -> Step6.begin_player_turn
  -> Fog.recompute. On the canonical authority the Step6 layer is ABSENT
  (_step6 == null), so charges/begin-player-turn degrade to no-ops.
- Mission evaluation (sim_controller.evaluate_mission): BATTLE_TERMINAL_CONTRACT_V0.
  defeat = battle_lost / BLUE HQ dead (when fielded at start) / BLUE annihilated;
  victory = RED HQ dead (when fielded at start, all objectives) else per objective;
  expired past turn_limit. Evaluation ORDER preserved (defeat-first).
"""

from __future__ import annotations

from enum import IntEnum


class BattlePhase(IntEnum):
    RECON = 0
    DEPLOY = 1
    ENGAGE = 2
    RESOLVE = 3


def next_phase(phase: int) -> int:
    """TurnManager.next_phase — wraps after RESOLVE."""
    return (phase + 1) % 4


VALID_OBJECTIVES = ("destroy_all_red", "capture_capital", "survive_turns", "hold_hq")


def evaluate_mission(
    objective: str,
    turn_limit: int,
    turn: int,
    hq_alive: bool,
    blue_alive_count: int,
    red_alive_count: int,
    battle_lost: bool,
    capital: dict | None = None,
    red_hq_alive: bool = True,
    blue_hq_at_start: bool = True,
    red_hq_at_start: bool = False,
) -> dict:
    """Literal port of SimController.evaluate_mission decision core.

    BATTLE_TERMINAL_CONTRACT_V0: symmetric start-aware HQ-terminal. Defaults
    preserve the legacy decision core for callers that do not pass HQ facts
    (blue missing => defeat; red never wins by HQ).
    """
    capital = capital or {}
    status = "ongoing"
    reason = "objective_incomplete"
    blue_hq_dead = bool(blue_hq_at_start) and not hq_alive
    red_hq_dead = bool(red_hq_at_start) and not red_hq_alive
    if battle_lost or blue_hq_dead or blue_alive_count == 0:
        status = "defeat"
        reason = "hq_destroyed" if (battle_lost or blue_hq_dead) else "blue_annihilated"
    elif red_hq_dead:
        status = "victory"
        reason = "red_hq_destroyed"
    else:
        if objective == "destroy_all_red":
            if red_alive_count == 0:
                status = "victory"
                reason = "all_red_destroyed"
        elif objective == "capture_capital":
            if capital and (bool(capital.get("breached", False)) or str(capital.get("owner", "")) == "blue"):
                status = "victory"
                reason = "capital_taken"
        elif objective in ("survive_turns", "hold_hq"):
            if turn > turn_limit and hq_alive:
                status = "victory"
                reason = "turn_limit_survived"
    if status == "ongoing" and turn > turn_limit:
        status = "expired"
        reason = "turn_limit_reached_without_decision"
    return {"mission_status": status, "termination_reason": reason}


__all__ = ["BattlePhase", "VALID_OBJECTIVES", "evaluate_mission", "next_phase"]
