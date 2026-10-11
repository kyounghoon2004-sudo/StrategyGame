"""WorldTruth — the single authoritative battle state.

Owns: cell_data (terrain), occupancy map, unit registry, fortress wall HP
pool, strongholds, turn counter, player march policy. Mirrors the canonical
Godot authorities (HexGrid.cell_data + Step3UnitManager registries) as ONE
immutable-friendly state object the simulator mutates through its rules
layer. It is NEVER handed to the observation projector except through
FactionKnowledge recompute and the explicit projector contract.

Cheap cloning: cell_data (4,921 small dicts) is shared copy-on-write between
clones; units/occupancy are copied shallowly per clone. Correctness first:
clone() is value-semantic for everything the rules mutate.
"""

from __future__ import annotations

import copy
from dataclasses import dataclass, field

from python_sim.rules import geometry, march
from python_sim.rules.geometry import Hex
from python_sim.state.unit_state import UnitState, new_unit_from_scenario

# UM constants (authoritative defaults)
DEFAULT_FORTRESS_FOOTPRINT: list[Hex] = [(-4, 2), (-3, 2), (-4, 3)]
DEFAULT_CAPITAL_FOOTPRINT: list[Hex] = [(14, -5), (15, -5), (14, -4)]
DEFAULT_FORTRESS_ID: str = "Fortress_Hulao"
DEFAULT_CAPITAL_ID: str = "Capital_Luoyang"
DEFAULT_FORTRESS_HP: int = 1000
DEFAULT_CAPITAL_HP: int = 1500
DEFAULT_FORTRESS_SLOTS: int = 4
DEFAULT_CAPITAL_SLOTS: int = 6

VALID_CLASSES = ("infantry", "spearman", "archer", "cavalry", "scout", "siege", "conscript", "hq")


@dataclass
class Stronghold:
    """Minimal StrongholdCls facts the simulator consumes."""

    structure_id: str
    structure_type: str  # "FORTRESS" | "CAPITAL"
    owner: str
    footprint: list[Hex]
    fortification_hp: int
    fortification_hp_max: int
    garrison_slots: int
    garrison_roster: list[str] = field(default_factory=list)
    breached: bool = False

    def get_anchor(self) -> Hex:
        return self.footprint[0]

    def to_facts(self) -> dict:
        return {
            "structure_id": self.structure_id,
            "owner": self.owner,
            "fortification_hp": self.fortification_hp,
            "fortification_hp_max": self.fortification_hp_max,
            "breached": self.breached,
            "garrison_count": len(self.garrison_roster),
            "garrison_roster": list(self.garrison_roster),
            "anchor": [self.footprint[0][0], self.footprint[0][1]],
            "structure_type": self.structure_type,
        }


class WorldState:
    """Authoritative world truth (units + terrain + occupancy + structures)."""

    __slots__ = (
        "cell_data", "occupied_map", "fortress_map", "units", "garrisoned",
        "current_turn", "current_policy", "strongholds", "river_cells",
        "stronghold_cells", "state_version",
    )

    def __init__(self) -> None:
        self.cell_data: dict[str, dict] = {}
        self.occupied_map: dict[str, str] = {}
        self.fortress_map: dict[str, int] = {}
        self.units: dict[str, UnitState] = {}
        self.garrisoned: dict[str, str] = {}
        self.current_turn: int = 1
        # UM._current_policy init: player-side default RED_ALLOWED (verified).
        self.current_policy: int = march.MarchPolicy.RED_ALLOWED
        self.strongholds: dict[str, Stronghold] = {}
        self.river_cells: dict[str, bool] = {}
        self.stronghold_cells: dict[str, bool] = {}
        self.state_version: int = 0

    # ------------------------------------------------------------------ build
    def build_map(self, bounds: dict, default_terrain: int, terrain_overrides: dict[str, int], river_cells: list[list[int]], enable_strongholds: bool = True) -> None:
        q_min = int(bounds.get("q_min", -30))
        q_max = int(bounds.get("q_max", -20))
        r_min = int(bounds.get("r_min", -5))
        r_max = int(bounds.get("r_max", 5))
        self.cell_data = {}
        for q in range(q_min, q_max + 1):
            for r in range(r_min, r_max + 1):
                key = f"{q},{r}"
                terrain = int(terrain_overrides.get(key, default_terrain))
                self.cell_data[key] = {"q": q, "r": r, "terrain": terrain}
        self.river_cells = {f"{int(a)},{int(b)}": True for a, b in river_cells}
        self.stronghold_cells = {}
        self.strongholds = {}
        self.fortress_map = {}
        if enable_strongholds:
            self._register_default_strongholds()

    def _register_default_strongholds(self) -> None:
        fortress = Stronghold(
            structure_id=DEFAULT_FORTRESS_ID,
            structure_type="FORTRESS",
            owner="red",
            footprint=list(DEFAULT_FORTRESS_FOOTPRINT),
            fortification_hp=DEFAULT_FORTRESS_HP,
            fortification_hp_max=DEFAULT_FORTRESS_HP,
            garrison_slots=DEFAULT_FORTRESS_SLOTS,
        )
        capital = Stronghold(
            structure_id=DEFAULT_CAPITAL_ID,
            structure_type="CAPITAL",
            owner="red",
            footprint=list(DEFAULT_CAPITAL_FOOTPRINT),
            fortification_hp=DEFAULT_CAPITAL_HP,
            fortification_hp_max=DEFAULT_CAPITAL_HP,
            garrison_slots=DEFAULT_CAPITAL_SLOTS,
        )
        self.strongholds[fortress.structure_id] = fortress
        self.strongholds[capital.structure_id] = capital
        for h in DEFAULT_FORTRESS_FOOTPRINT:
            self.stronghold_cells[geometry.key_of(h)] = True
            self.fortress_map[geometry.key_of(h)] = DEFAULT_FORTRESS_HP
        for h in DEFAULT_CAPITAL_FOOTPRINT:
            self.stronghold_cells[geometry.key_of(h)] = True
            self.fortress_map[geometry.key_of(h)] = DEFAULT_CAPITAL_HP

    def spawn_units(self, forces: list[dict]) -> None:
        self.units = {}
        self.occupied_map = {}
        self.garrisoned = {}
        for f in forces:
            unit_class = str(f.get("class", "infantry"))
            if unit_class.lower() == "supply":
                continue  # SUP-1: supply-class units are retired, cannot spawn
            unit = new_unit_from_scenario(f)
            # §8: units placed on footprint hexes belong in garrison.
            key = geometry.key_of((unit.q, unit.r))
            sh = self.get_stronghold_at(unit.q, unit.r)
            if sh is not None:
                if sh.owner == unit.faction and len(sh.garrison_roster) < sh.garrison_slots:
                    sh.garrison_roster.append(unit.id)
                    self.garrisoned[unit.id] = sh.structure_id
                    unit.garrisoned = True
                    unit.stronghold_id = sh.structure_id
                    self.units[unit.id] = unit
                    continue
            self.units[unit.id] = unit
            self.occupied_map[key] = unit.id

    # ------------------------------------------------------------------ queries
    def get_stronghold_at(self, q: int, r: int) -> Stronghold | None:
        key = geometry.key_of((q, r))
        for sh in self.strongholds.values():
            if key in {geometry.key_of(h) for h in sh.footprint}:
                return sh
        return None

    def is_stronghold_hex(self, q: int, r: int) -> bool:
        return geometry.key_of((q, r)) in self.stronghold_cells

    def get_fortress_hp(self, q: int, r: int) -> int:
        return int(self.fortress_map.get(geometry.key_of((q, r)), 0))

    def set_fortress_hp(self, q: int, r: int, hp: int) -> None:
        self.fortress_map[geometry.key_of((q, r))] = hp

    def get_unit_by_id(self, unit_id: str) -> UnitState | None:
        return self.units.get(unit_id)

    def unit_dict(self, unit_id: str) -> dict:
        u = self.units.get(unit_id)
        return u.to_dict() if u else {}

    def all_field_units(self) -> list[dict]:
        """get_all_units(): field units only, excludes garrisoned."""
        return [u.to_dict() for u in self.units.values() if not u.garrisoned]

    def all_units_including_garrisoned(self) -> list[dict]:
        return [u.to_dict() for u in self.units.values()]

    def get_occupied_dict(self) -> dict[str, dict]:
        """Full-truth occupancy: "q,r" -> unit dict."""
        res: dict[str, dict] = {}
        for k, uid in self.occupied_map.items():
            u = self.units.get(uid)
            if u is not None:
                res[k] = u.to_dict()
        return res

    def get_player_known_occupied(self, visible_enemy_ids: dict[str, bool]) -> dict[str, dict]:
        """UM.get_player_known_occupied — own + visible enemies only.

        Hidden enemy truth never enters planning; stale markers never block.
        """
        res: dict[str, dict] = {}
        for k, uid in self.occupied_map.items():
            u = self.units.get(uid)
            if u is None:
                continue
            if u.faction == "blue":
                res[k] = u.to_dict()
            elif u.faction == "red":
                if visible_enemy_ids.get(uid, False):
                    res[k] = u.to_dict()
                # else: hidden enemy => unknown space, omit from planning
            else:
                res[k] = u.to_dict()
        return res

    def known_occupancy_for(self, side: str, enemy_visible_fn) -> dict[str, str]:
        """Projector.known_occupancy: "q,r" -> unit id for a side's knowledge."""
        result: dict[str, str] = {}
        for u in self.units.values():
            if u.soldier_count <= 0 or u.garrisoned:
                continue
            if u.faction == side or enemy_visible_fn(u.to_dict()):
                result[geometry.key_of((u.q, u.r))] = u.id
        return result

    def get_all_strongholds(self) -> list[Stronghold]:
        return list(self.strongholds.values())

    # ------------------------------------------------------------------ mutation
    def notify_mutation(self) -> int:
        self.state_version += 1
        return self.state_version

    def destroy_unit(self, unit_id: str) -> None:
        """UM.destroy_unit: erase occupancy + registries immediately."""
        u = self.units.get(unit_id)
        if u is None:
            return
        self.occupied_map.pop(geometry.key_of((u.q, u.r)), None)
        del self.units[unit_id]
        self.garrisoned.pop(unit_id, None)
        for sh in self.strongholds.values():
            if unit_id in sh.garrison_roster:
                sh.garrison_roster.remove(unit_id)

    def clone(self) -> "WorldState":
        """Value-semantic clone with shared immutable-ish terrain payloads.

        cell_data cell dicts are copied lazily via a shared top-level dict of
        IDENTICAL dict objects: the rules layer never mutates cell dicts in
        place (terrain is static during battle), so sharing them is safe and
        avoids deep-copying 4,921 cells. Units/occupancy/strongholds are
        copied by value.
        """
        new = WorldState.__new__(WorldState)
        new.cell_data = self.cell_data  # shared: terrain is battle-static
        new.occupied_map = dict(self.occupied_map)
        new.fortress_map = dict(self.fortress_map)
        new.units = {uid: copy.copy(u) for uid, u in self.units.items()}
        new.garrisoned = dict(self.garrisoned)
        new.current_turn = self.current_turn
        new.current_policy = self.current_policy
        new.strongholds = {
            sid: Stronghold(
                structure_id=sh.structure_id,
                structure_type=sh.structure_type,
                owner=sh.owner,
                footprint=list(sh.footprint),
                fortification_hp=sh.fortification_hp,
                fortification_hp_max=sh.fortification_hp_max,
                garrison_slots=sh.garrison_slots,
                garrison_roster=list(sh.garrison_roster),
                breached=sh.breached,
            )
            for sid, sh in self.strongholds.items()
        }
        new.river_cells = self.river_cells  # shared: battle-static
        new.stronghold_cells = self.stronghold_cells  # shared: battle-static
        new.state_version = self.state_version
        return new

    # ------------------------------------------------------------------ fingerprint
    @staticmethod
    def _gd_bool(v: bool) -> str:
        """GDScript str(bool) emits lowercase — fingerprint byte parity."""
        return "true" if v else "false"

    def fingerprint(self) -> str:
        """SimController.fingerprint port (authoritative state digest).

        Byte-parity verified against the exported Godot headless probe
        (sim_entry verification.json gate1): bools lowercase, strongholds in
        REGISTRATION order (Godot Dictionary iteration), units id-sorted.
        """
        parts: list[str] = [f"t={self.current_turn}"]
        for u in sorted(self.units.values(), key=lambda x: x.id):
            parts.append(
                f"{u.id}:{u.q},{u.r}:mp{u.remaining_mp:.3f}:ae{self._gd_bool(u.action_ended)}:"
                f"sol{u.soldier_count}:mor{u.morale:.3f}:fat{u.fatigue:.3f}:"
                f"rt{self._gd_bool(u.routed)}:gar{self._gd_bool(u.garrisoned)}"
            )
        for sh in self.strongholds.values():  # registration order (Godot parity)
            parts.append(
                f"sh:{sh.structure_id}:{sh.owner}:hp{sh.fortification_hp}:"
                f"br{self._gd_bool(sh.breached)}:gar{len(sh.garrison_roster)}"
            )
        return "|".join(parts)


def scenario_bounds_fingerprint_key(coord: Hex) -> str:
    return geometry.key_of(coord)


__all__ = [
    "DEFAULT_CAPITAL_FOOTPRINT",
    "DEFAULT_CAPITAL_HP",
    "DEFAULT_FORTRESS_FOOTPRINT",
    "DEFAULT_FORTRESS_HP",
    "Stronghold",
    "VALID_CLASSES",
    "WorldState",
]
