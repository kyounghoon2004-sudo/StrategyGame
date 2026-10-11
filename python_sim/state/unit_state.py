"""Unit state — single typed representation of one field formation.

This is the SIMULATOR's internal typed view. The canonical semantic port is
a per-unit dict mirroring the authoritative Godot unit_data fields (UM
initialize_from_renderer_units); the dataclass below is the typed storage
backing those dicts, keeping field names identical to Godot for auditability.
Values and defaults are cited in RulesetV0 (unit_state family).

Morale/fatigue/rout fields exist on every unit (source behavior) but are
inert in the DEV sandbox (morale_rout_enabled=False gates all writes).
"""

from __future__ import annotations

from dataclasses import dataclass, field

from python_sim.rules import march


@dataclass
class UnitState:
    """One field formation. Field names mirror Godot unit_data exactly."""

    id: str
    unit_class: str  # authoritative raw class string (e.g. "spearman", "hq")
    faction: str  # "blue" | "red"
    q: int
    r: int
    soldier_count: int
    max_count: int
    form_factor: str = "form_a"
    base_mp: float = 2.0
    blue_limit: float = 2.0
    red_limit: float = 4.0
    black_limit: float = 4.4
    turn_move_cost_spent: float = 0.0
    remaining_mp: float = 2.0
    morale: float = 100.0
    fatigue: float = 0.0
    action_ended: bool = False
    has_moved: bool = False
    has_attacked: bool = False
    fortified: bool = False
    field_fortified: bool = False
    field_fortification_hp: int = 0
    field_fortification_hp_max: int = 0
    rested_this_turn: bool = False
    resting_unguarded: bool = False
    defense_ready: bool = False
    unguarded: bool = False
    turn_resolved: bool = False
    reviewed_this_turn: bool = False
    routed: bool = False
    rout_turns: int = 0
    is_hq: bool = False
    garrisoned: bool = False
    stronghold_id: str = ""

    def to_dict(self) -> dict:
        """Authoritative unit_data dict (class key is "class" per Godot)."""
        return {
            "id": self.id,
            "class": self.unit_class,
            "faction": self.faction,
            "q": self.q,
            "r": self.r,
            "soldier_count": self.soldier_count,
            "max_count": self.max_count,
            "form_factor": self.form_factor,
            "base_mp": self.base_mp,
            "blue_limit": self.blue_limit,
            "red_limit": self.red_limit,
            "black_limit": self.black_limit,
            "turn_move_cost_spent": self.turn_move_cost_spent,
            "remaining_mp": self.remaining_mp,
            "morale": self.morale,
            "fatigue": self.fatigue,
            "action_ended": self.action_ended,
            "has_moved": self.has_moved,
            "has_attacked": self.has_attacked,
            "fortified": self.fortified,
            "field_fortified": self.field_fortified,
            "field_fortification_hp": self.field_fortification_hp,
            "field_fortification_hp_max": self.field_fortification_hp_max,
            "rested_this_turn": self.rested_this_turn,
            "resting_unguarded": self.resting_unguarded,
            "defense_ready": self.defense_ready,
            "unguarded": self.unguarded,
            "turn_resolved": self.turn_resolved,
            "reviewed_this_turn": self.reviewed_this_turn,
            "routed": self.routed,
            "rout_turns": self.rout_turns,
            "is_hq": self.is_hq,
            "garrisoned": self.garrisoned,
            "stronghold_id": self.stronghold_id,
        }


def new_unit_from_scenario(f: dict) -> UnitState:
    """UM.initialize_from_renderer_units field derivation (supply skipped upstream)."""
    unit_class = str(f.get("class", "infantry"))
    soldiers = int(f.get("soldiers", f.get("soldier_count", 100)))
    max_count = int(f.get("max_count", soldiers))
    base_mp = march.get_base_movement(unit_class)
    return UnitState(
        id=str(f.get("id", "")),
        unit_class=unit_class,
        faction=str(f.get("faction", "blue")),
        q=int(f.get("q", 0)),
        r=int(f.get("r", 0)),
        soldier_count=soldiers,
        max_count=max_count,
        form_factor=str(f.get("form_factor", "form_a")),
        base_mp=base_mp,
        blue_limit=march.get_blue_limit(base_mp),
        red_limit=march.get_red_limit(base_mp),
        black_limit=march.get_black_limit(base_mp),
        remaining_mp=base_mp,
        is_hq=unit_class == "hq",
    )


__all__ = ["UnitState", "new_unit_from_scenario"]
