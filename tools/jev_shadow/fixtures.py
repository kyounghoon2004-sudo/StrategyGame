"""Synthetic schema-valid shadow requests for parity/fail-open batteries.

These fixtures exercise the worker-side contract (schema, projection,
mapping, forward, masking). Live Godot requests replayed from REQUESTS.jsonl
provide the end-to-end parity leg.
"""

from __future__ import annotations

import json
import os

from python_jev.contracts.hex_patch import RING_MAJOR_OFFSETS
from tools.jev_shadow import SHADOW_REQUEST_VERSION

HERE = os.path.dirname(os.path.abspath(__file__))
STRATEGY_ROOT = os.path.abspath(os.path.join(HERE, os.pardir, os.pardir))
_SLOT_MAP_PATH = os.path.join(
    STRATEGY_ROOT, "artifacts", "jev_godot_shadow_v0",
    "JEV_SHADOW_SLOT_MAP.json")
_GODOT_MATRIX: dict[str, list[str]] | None = None


def godot_matrix() -> dict[str, list[str]]:
    global _GODOT_MATRIX
    if _GODOT_MATRIX is None:
        with open(_SLOT_MAP_PATH, encoding="utf-8") as f:
            _GODOT_MATRIX = json.load(f)["godot_source"]["matrix"]
    return _GODOT_MATRIX


_KIND_OF = {
    "ATTACK_CONTACT": "ATTACK", "ADVANCE_LINE": "ADVANCE", "HOLD_LINE": "HOLD",
    "CLOSE_GAP_SUPPORT": "ADVANCE", "PRESS_OBJECTIVE": "ADVANCE",
    "WITHDRAW_LINE": "WITHDRAW",
    "FIRE_PRIORITY_TARGET": "ATTACK", "HOLD_FIRELINE": "HOLD",
    "REPOSITION_FOR_RANGE": "ADVANCE", "SUPPORT_ASSIGNED_GROUP": "ADVANCE",
    "KITE_FROM_THREAT": "WITHDRAW", "WITHDRAW_TO_SCREEN": "WITHDRAW",
    "ATTACK_CAVALRY": "ATTACK", "HOLD_ANTI_CAV_SCREEN": "HOLD",
    "ADVANCE_WITH_LINE": "ADVANCE", "PROTECT_ARCHER": "ADVANCE",
    "PROTECT_HQ": "ADVANCE", "FALLBACK_SCREEN": "WITHDRAW",
    "CHARGE_PRIORITY_TARGET": "ATTACK", "FLANK_LEFT": "ADVANCE",
    "FLANK_RIGHT": "ADVANCE", "EXPLOIT_REAR_OR_RANGED": "ATTACK",
    "SCREEN_COUNTERFLANK": "ADVANCE", "DISENGAGE_TO_RESERVE": "WITHDRAW",
    "RECON_FORWARD": "ADVANCE", "RECON_LEFT": "ADVANCE",
    "RECON_RIGHT": "ADVANCE", "SHADOW_PRIORITY_ENEMY": "ADVANCE",
    "SCREEN_EDGE": "HOLD", "EVADE_RETURN": "WITHDRAW",
    "HOLD_REAR": "HOLD", "FOLLOW_MAIN_EFFORT": "ADVANCE",
    "RELOCATE_LEFT_SAFE": "WITHDRAW", "RELOCATE_RIGHT_SAFE": "WITHDRAW",
    "RELOCATE_CENTER_SAFE": "WITHDRAW", "WITHDRAW_FROM_THREAT": "WITHDRAW",
}


def make_request(unit_class: str = "INFANTRY", task: str = "ATTACK",
                 masked: tuple[int, ...] = (), baseline_slot: int = 0,
                 terrain: int = 0, turn: int = 3, tag: str = "fx") -> dict:
    """Build one schema-valid request. masked = Godot option indices masked."""
    aq, ar = 0, 0
    matrix = godot_matrix()
    opts = []
    for i, oid in enumerate(matrix[unit_class]):
        m = i in masked
        opts.append({"slot": i, "option_id": oid,
                     "kind": _KIND_OF[oid], "masked": m,
                     "mask_reason": "NO_VALID_TARGET" if m else ""})
    cells = [{"q": aq + dq, "r": ar + dr, "terrain": terrain, "in_bounds": True}
             for dq, dr in RING_MAJOR_OFFSETS]
    return {
        "schema_version": SHADOW_REQUEST_VERSION,
        "request_id": f"{tag}-req-1",
        "battle_id": f"{tag}-battle",
        "decision_id": f"{tag}-d1",
        "turn": turn,
        "snapshot_id": f"{tag}-snap",
        "faction": "RED",
        "actor": {
            "unit_id": "R-INF-1", "unit_class": unit_class.lower(), "q": aq,
            "r": ar, "soldiers": 420, "max_count": 500,
            "remaining_mp": 3.0, "base_mp": 4.0, "turn_move_cost_spent": 1.0,
            "blue_limit": 4.0, "can_attack": True, "has_attacked": False,
            "action_ended": False, "status": "ready", "morale": 82.0,
            "routed": False, "garrisoned": False, "defense_ready": False,
            "formation": "FIELD",
        },
        "unit_class": unit_class,
        "mission": {
            "mission_id": "M1", "task": task, "area": "CENTER",
            "status": "ACTIVE", "objective": {"kind": "NONE"},
            "engagement": {"policy": "ATTACK_IF_ADVANTAGEOUS"},
            "constraints": {"preserve_force": False},
            "activated_turn": 1, "progress_turn": 0,
        },
        "doctrine": {"aggression": 0.5, "risk_tolerance": 0.5,
                      "tempo": 0.5, "pursuit": 0.5,
                      "reserve_discipline": 0.6, "deception": 0.2},
        "ctx": {"turns_active": 2, "urgency": 0.0,
                "mission_status": "ACTIVE", "main_effort": "",
                "bounds": {"q_min": -32, "q_max": -16, "r_min": -8,
                           "r_max": 8}},
        "godot_options": opts,
        "baseline": {"slot": baseline_slot,
                     "option_id": matrix[unit_class][baseline_slot]},
        "planned_command": {"action": "ATTACK", "scope": "unit"},
        "friendlies": [
            {"unit_id": "R-INF-1", "class": unit_class.lower(), "q": aq,
             "r": ar, "soldiers": 420, "max_count": 500,
             "has_acted": False, "status": "ready"},
            {"unit_id": "R-ARC-1", "class": "archer", "q": -1, "r": 1,
             "soldiers": 300, "max_count": 360, "has_acted": False,
             "status": "ready"},
        ],
        "enemies_visible": [
            {"unit_id": "B-INF-1", "class": "infantry", "q": 2, "r": 0,
             "last_seen_turn": turn},
        ],
        "stale": [
            {"unit_id": "B-CAV-9", "class": "cavalry", "q": -4, "r": 3,
             "last_seen_turn": turn - 2},
        ],
        "hex_cells": cells,
        "red_visible_cells": ["0,0", "1,0", "2,0", "0,1", "-1,1", "1,-1"],
        "objective_hex": [2, 0],
        "hq_pos": [-3, 1],
        "enemy_hq": {"known": False, "alive": False, "q": 0, "r": 0},
        "turn_limit": 40,
        "mission_evaluation": {"primary_objective": "destroy_all_red",
                               "mission_status": "ongoing"},
    }


__all__ = ["godot_matrix", "make_request"]
