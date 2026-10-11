"""Godot six-option <-> JEV six-slot mapping (jev-shadow-slotmap-v1).

Single authority: JEV_SHADOW_SLOT_MAP.json next to the shadow contract. This
module loads it once, enforces its invariants loudly, and derives JEV legality
(OR over mapped Godot options) plus baseline translation for agreement.
"""

from __future__ import annotations

import json
import os

from tools.jev_shadow import SHADOW_SLOTMAP_VERSION

HERE = os.path.dirname(os.path.abspath(__file__))
STRATEGY_ROOT = os.path.abspath(os.path.join(HERE, os.pardir, os.pardir))
DEFAULT_MAP_PATH = os.path.join(
    STRATEGY_ROOT, "artifacts", "jev_godot_shadow_v0",
    "JEV_SHADOW_SLOT_MAP.json")


class SlotMapError(ValueError):
    """Raised when the slot map file violates its own invariants."""


class SlotMap:
    def __init__(self, path: str = DEFAULT_MAP_PATH) -> None:
        with open(path, encoding="utf-8") as f:
            doc = json.load(f)
        if doc.get("slot_map_version") != SHADOW_SLOTMAP_VERSION:
            raise SlotMapError(
                f"slot_map_version {doc.get('slot_map_version')!r} != {SHADOW_SLOTMAP_VERSION!r}")
        self.doc = doc
        self.mapping: dict[str, dict[str, dict]] = doc["mapping"]
        self.dead: dict[str, set[int]] = {
            cls: {d["jev_slot"] for d in rows}
            for cls, rows in doc["dead_jev_slots"].items()
        }
        self._check_invariants()

    def _check_invariants(self) -> None:
        godot_matrix = self.doc["godot_source"]["matrix"]
        jev_tables = self.doc["jev_source"]["tables"]
        for cls, godot_opts in godot_matrix.items():
            if cls == "HQ":
                continue
            if cls not in self.mapping:
                raise SlotMapError(f"class {cls}: missing mapping block")
            if cls not in jev_tables:
                raise SlotMapError(f"class {cls}: missing JEV table")
            block = self.mapping[cls]
            if set(block) != set(godot_opts):
                raise SlotMapError(
                    f"class {cls}: mapped options {sorted(block)} != MATRIX {godot_opts}")
            for opt, row in block.items():
                slot = row["jev_slot"]
                if not 0 <= slot < 6:
                    raise SlotMapError(f"class {cls} option {opt}: slot {slot} out of range")
                if jev_tables[cls][slot] != row["jev_skill"]:
                    raise SlotMapError(
                        f"class {cls} option {opt}: skill {row['jev_skill']} != "
                        f"table slot {slot} ({jev_tables[cls][slot]})")
            # every JEV slot is either mapped or declared dead (never both)
            mapped_slots = {row["jev_slot"] for row in block.values()}
            dead_slots = self.dead.get(cls, set())
            if mapped_slots & dead_slots:
                raise SlotMapError(f"class {cls}: slots both mapped and dead: "
                                   f"{sorted(mapped_slots & dead_slots)}")
            if mapped_slots | dead_slots != set(range(6)):
                raise SlotMapError(
                    f"class {cls}: slots not covered: mapped={sorted(mapped_slots)} "
                    f"dead={sorted(dead_slots)}")

    def jev_table(self, unit_class: str) -> tuple[str, ...]:
        return tuple(self.doc["jev_source"]["tables"][unit_class])

    def dead_slots(self, unit_class: str) -> set[int]:
        return set(self.dead.get(unit_class, set()))

    def jev_legal_from_godot(self, unit_class: str, godot_options: list[dict]) -> list[bool]:
        """OR-aggregation: JEV slot legal iff any mapped Godot option is unmasked."""
        block = self.mapping[unit_class]
        legal = [False] * 6
        for o in godot_options:
            row = block.get(o["option_id"])
            if row is None:
                raise SlotMapError(
                    f"class {unit_class}: Godot option {o['option_id']!r} not in slot map")
            if not o["masked"]:
                legal[row["jev_slot"]] = True
        return legal

    def baseline_to_jev(self, unit_class: str, baseline_option_id: str) -> int | None:
        row = self.mapping[unit_class].get(baseline_option_id)
        return None if row is None else int(row["jev_slot"])


__all__ = ["DEFAULT_MAP_PATH", "SlotMap", "SlotMapError"]
