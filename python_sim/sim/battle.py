"""Battle — headless episode controller (port of SimController authority).

Wires WorldState + Executor + per-faction FactionKnowledge exactly like the
canonical headless path: Step6 charges/begin-player-turn are ABSENT on the
canonical authority (sim_controller._step6 == null), so the cycle is:

    end_turn (unit reset)  ->  fog recompute (both factions)

Combat modifiers are {} on the canonical path (Step6.attacker_bonus_vs absent
=> strategic_modifiers empty). Rout/rally/fatigue accumulation exist as rule
constants but are gated by the profile flag, mirroring SandboxRules.

Profiles are configuration overlays on ONE simulator (RulesetV0 §3.5):
DEV_FLAT_ALL_INFO disables terrain effects (all cells forced PLAINS cost),
obstacles (strongholds unregistered), fog (full information), morale, ambush.
"""

from __future__ import annotations

import hashlib
import json
from typing import Callable

from python_sim import SIM_VERSION
from python_sim.rules import combat as combat_rules
from python_sim.rules import geometry, march, movement, turn as turn_rules
from python_sim.rules.geometry import Hex
from python_sim.sim.executor import Executor
from python_sim.state.faction_knowledge import FactionKnowledge
from python_sim.state.world_state import WorldState

SCENARIO_PROFILES = {
    "DEV_FLAT_ALL_INFO": {
        "notion_name": "DEV_FLAT_FULL_INFO",
        "terrain_effects": False,
        "obstacles_strongholds": False,
        "fog_stale_contacts": False,
        "morale_rout_fatigue": False,
        "ambush": False,
    },
    "TERRAIN_FULL_INFO": {
        "notion_name": "TERRAIN_ONLY",
        "terrain_effects": True,
        "obstacles_strongholds": True,
        "fog_stale_contacts": False,
        "morale_rout_fatigue": False,
        "ambush": False,
    },
    "FLAT_FOG": {
        "notion_name": "FOG_ONLY",
        "terrain_effects": False,
        "obstacles_strongholds": False,
        "fog_stale_contacts": True,
        "morale_rout_fatigue": False,
        "ambush": True,
    },
    "TERRAIN_FOG": {
        "notion_name": "TERRAIN_FOG",
        "terrain_effects": True,
        "obstacles_strongholds": True,
        "fog_stale_contacts": True,
        "morale_rout_fatigue": False,
        "ambush": True,
    },
    "MORALE_COMBAT": {
        "notion_name": "MORALE_COMBAT",
        "terrain_effects": True,
        "obstacles_strongholds": True,
        "fog_stale_contacts": True,
        "morale_rout_fatigue": True,
        "ambush": True,
        "degraded": "terrain defense wiring + archer range bonus are contract gaps (RulesetV0); combat/terrain values otherwise faithful",
    },
    "FULL_PRODUCTION": {
        "notion_name": "FULL_PRODUCTION",
        "terrain_effects": True,
        "obstacles_strongholds": True,
        "fog_stale_contacts": True,
        "morale_rout_fatigue": True,
        "ambush": True,
        "degraded": "same unresolved wiring gaps as MORALE_COMBAT",
    },
}

DEFAULT_TEST_BOUNDS = {"q_min": -30, "q_max": -20, "r_min": -5, "r_max": 5}


class Battle:
    """One deterministic headless battle episode."""

    def __init__(
        self,
        scenario: dict,
        profile: str = "DEV_FLAT_ALL_INFO",
        seed: int = 0,
    ) -> None:
        if profile not in SCENARIO_PROFILES:
            raise ValueError(f"unknown profile {profile!r}; known: {sorted(SCENARIO_PROFILES)}")
        self.scenario = json.loads(json.dumps(scenario))  # deep copy
        self.profile_name = profile
        self.profile = SCENARIO_PROFILES[profile]
        self.seed = seed  # provenance only: canonical path is deterministic

        err = self._validate_scenario(self.scenario)
        if err:
            raise ValueError(f"invalid scenario: {err}")

        flags = self.profile
        self.morale_rout_enabled = bool(flags["morale_rout_fatigue"])

        self.world = WorldState()
        self.world.current_policy = march.MarchPolicy.RED_ALLOWED
        # Terrain effects OFF => flat neutral plains (DEV contract). River
        # cells also vanish with terrain effects (flat map).
        terrain_effects = bool(flags["terrain_effects"])
        obstacles = bool(flags["obstacles_strongholds"])
        if terrain_effects:
            map_def = self.scenario.get("map", {})
            self.world.build_map(
                map_def.get("bounds", DEFAULT_TEST_BOUNDS),
                int(map_def.get("default_terrain", 0)),
                map_def.get("terrain_overrides", {}),
                map_def.get("river_cells", []),
                enable_strongholds=obstacles,
            )
        else:
            self.world.build_map(
                self.scenario.get("map", {}).get("bounds", DEFAULT_TEST_BOUNDS),
                0, {}, [], enable_strongholds=obstacles,
            )
        self.world.spawn_units(self.scenario.get("forces", []))
        self.executor = Executor(self.world, morale_rout_enabled=self.morale_rout_enabled)
        self.blue_knowledge = FactionKnowledge("blue")
        self.red_knowledge = FactionKnowledge("red")
        self._full_information = not bool(flags["fog_stale_contacts"])

        # Objective markers: stronghold footprints (auto-explored terrain).
        fps: list[Hex] = []
        for sh in self.world.strongholds.values():
            fps.extend(sh.footprint)
        self.blue_knowledge.set_objective_hexes(fps)
        self.red_knowledge.set_objective_hexes(fps)

        self._action_history: list[dict] = []
        self._action_seq = 0
        self._battle_lost = False

        self.refresh_observation("init")

    # ------------------------------------------------------------------ validation
    @staticmethod
    def _validate_scenario(scn: dict) -> str:
        if not scn:
            return "Scenario is empty."
        if not str(scn.get("scenario_id", "")):
            return "scenario_id is required."
        contract = scn.get("mission_contract", {})
        objective = str(contract.get("primary_objective", ""))
        if objective not in turn_rules.VALID_OBJECTIVES:
            return f"mission_contract.primary_objective must be one of {turn_rules.VALID_OBJECTIVES}."
        if int(contract.get("turn_limit", 0)) <= 0:
            return "mission_contract.turn_limit must be a positive int."
        forces = scn.get("forces", [])
        if not forces:
            return "forces must list at least one unit."
        seen: set[str] = set()
        for f in forces:
            uid = str(f.get("id", ""))
            if uid == "" or uid in seen:
                return "Force ids must be unique and non-empty."
            seen.add(uid)
            if str(f.get("class", "")) not in WorldState_valid_classes():
                return f"Force {uid} has unknown class."
            if str(f.get("faction", "")) not in ("blue", "red"):
                return f"Force {uid} faction must be blue or red."
            if int(f.get("soldiers", f.get("soldier_count", 0))) <= 0:
                return f"Force {uid} needs soldiers > 0."
        return ""

    # ------------------------------------------------------------------ observation
    def refresh_observation(self, reason: str = "external") -> None:
        """Recompute fog for both factions (discrete-change authority).

        With full information (DEV), knowledge mirrors truth: every playable
        cell is visible; no stale contacts exist (chess-like visibility).
        """
        all_units = self.world.all_field_units()
        blue_units = [u for u in all_units if u.get("faction") == "blue"]
        red_units = [u for u in all_units if u.get("faction") == "red"]
        turn = self.world.current_turn
        if self._full_information:
            for kn in (self.blue_knowledge, self.red_knowledge):
                kn.visible = {k: True for k in self.world.cell_data}
                kn.explored = dict(kn.visible)
                kn.visible_by_scout = {}
                kn.recompute([], all_units, self.world.cell_data, turn)  # contact bookkeeping only
                kn.visible = {k: True for k in self.world.cell_data}
                kn.explored = dict(kn.visible)
        else:
            self.blue_knowledge.recompute(blue_units, all_units, self.world.cell_data, turn)
            self.red_knowledge.recompute(red_units, all_units, self.world.cell_data, turn)

    def mark_combat_engaged(self, defender_id: str) -> None:
        """Shell _fog_mark_engaged mirror: red defender becomes combat-assessed."""
        pu = self.world.unit_dict(defender_id)
        if not pu or str(pu.get("faction", "")) != "red":
            return
        mx = max(1, int(pu.get("max_count", pu.get("soldier_count", 1))))
        ratio = float(pu.get("soldier_count", 0)) / float(mx)
        self.blue_knowledge.mark_combat_engaged(defender_id, ratio)

    # ------------------------------------------------------------------ command seam
    def _policy_for(self, side: str, march_mode: str) -> int:
        """CommandService._policy_for."""
        if side == "blue" and march_mode == "auto":
            return int(self.world.current_policy)
        mode = march_mode.lower()
        if mode in ("red", "red_allowed", "black", "black_allowed"):
            return march.MarchPolicy.RED_ALLOWED
        return march.MarchPolicy.GREEN_ONLY

    def _occupied_for(self, side: str) -> dict[str, dict]:
        """CommandService._occupied_for: player-known vs full truth."""
        if side == "blue":
            vis = self.executor.visible_enemy_ids(self.blue_knowledge)
            return self.world.get_player_known_occupied(vis)
        if side == "red":
            # RED AI keeps full truth (SIM._red_move uses get_occupied_dict).
            return self.world.get_occupied_dict()
        return {}

    def preview_move_route(self, unit_id: str, destination: Hex, side: str = "blue", march_mode: str = "auto"):
        """CommandService.preview_move_route."""
        u = self.world.unit_dict(unit_id)
        if not u or bool(u.get("action_ended", False)) or bool(u.get("garrisoned", False)):
            return None
        if str(u.get("faction", "")) != side:
            return None
        base_mp = float(u.get("base_mp", 2.0))
        return movement.find_route(
            (int(u.get("q", 0)), int(u.get("r", 0))),
            destination,
            str(u.get("class", "infantry")),
            base_mp,
            float(u.get("remaining_mp", base_mp)),
            self._policy_for(side, march_mode),
            self.world.cell_data,
            self._occupied_for(side),
            self.world.river_cells,
            side,
            self.world.stronghold_cells,
            float(u.get("turn_move_cost_spent", 0.0)),
            float(u.get("blue_limit", march.get_blue_limit(base_mp))),
            float(u.get("red_limit", march.get_red_limit(base_mp))),
            float(u.get("black_limit", march.get_black_limit(base_mp))),
            morale_rout_enabled=self.morale_rout_enabled,
        )

    def do_move(self, unit_id: str, q: int, r: int, side: str = "blue", march_mode: str = "auto") -> dict:
        """SIM.do_move: route + authoritative execution."""
        dest = (q, r)
        if side == "blue":
            route = self.preview_move_route(unit_id, dest, side, march_mode)
            if route is None or not route.found or not route.is_valid_destination:
                reason = route.rejection_reason if route is not None else "No legal route."
                res = {"success": False, "error": reason}
            else:
                res = self.executor.execute_player_stepwise_move(
                    unit_id, route.path, self.executor.visible_enemy_ids(self.blue_knowledge),
                    self.world.cell_data, self.world.river_cells,
                )
        else:
            res = self.executor.red_move(unit_id, dest)
        self._record("move", {"unit_id": unit_id, "to": [q, r], "side": side, "march_mode": march_mode}, res)
        if bool(res.get("success", False)):
            self.refresh_observation("sim_move")
        return res

    def attack_modifiers(self, attacker_id: str, defender_id: str) -> dict:
        """Canonical path: Step6 absent => {} (morale/supply modifiers inactive)."""
        return {}

    def do_attack(self, attacker_id: str, defender_id: str, side: str = "blue") -> dict:
        mods = self.attack_modifiers(attacker_id, defender_id)
        if side == "blue":
            # CommandService.execute_attack_intent: observation-safe visibility
            # gate on the TARGET (blue must currently observe it).
            if not self._full_information:
                pu = self.world.unit_dict(defender_id)
                if not pu or not self.blue_knowledge.is_enemy_visible(pu):
                    res = {"success": False, "error": "Target is not currently observed."}
                    self._record("attack", {"attacker_id": attacker_id, "defender_id": defender_id, "side": side}, res)
                    return res
            legal = any(c.get("id") == defender_id for c in self.executor.get_attackable_targets(attacker_id))
            if not legal:
                res = {"success": False, "error": "Target is not a legal attack option."}
            else:
                res = self.executor.execute_attack(attacker_id, defender_id, mods)
        else:
            res = self.executor.red_attack(attacker_id, defender_id, mods)
        self._record("attack", {"attacker_id": attacker_id, "defender_id": defender_id, "side": side}, res)
        if bool(res.get("success", False)):
            self.mark_combat_engaged(defender_id)
            self.refresh_observation("sim_attack")
        return res

    def do_hold(self, unit_id: str, side: str = "blue") -> dict:
        """CommandService.execute_hold_intent -> wait_unit."""
        u = self.world.unit_dict(unit_id)
        if not u or str(u.get("faction", "")) != side or bool(u.get("action_ended", False)):
            res = {"success": False, "error": "Formation cannot hold now."}
        else:
            res = self.executor.wait_unit(unit_id)
        self._record("hold", {"unit_id": unit_id, "side": side}, res)
        return res

    def do_rest(self, unit_id: str) -> dict:
        res = self.executor.rest_unit(unit_id)
        self._record("rest", {"unit_id": unit_id}, res)
        return res

    def do_fortify(self, unit_id: str) -> dict:
        res = self.executor.fortify_unit(unit_id)
        self._record("fortify", {"unit_id": unit_id}, res)
        return res

    def sim_end_turn(self) -> dict:
        """SIM.sim_end_turn: canonical cycle without Step6 (charges = {})."""
        prev_turn = self.world.current_turn
        next_turn = self.executor.end_turn()
        self.refresh_observation("turn_begin")
        res = {
            "ok": True,
            "previous_turn": prev_turn,
            "current_turn": next_turn,
            "charges": {},
            "begin_turn_report": {},
            "battle_lost": self._battle_lost,
        }
        self._record("end_turn", {}, res)
        return res

    # ------------------------------------------------------------------ episode flow
    def unresolved_blue_units(self) -> list[dict]:
        return self.executor.unresolved_friendly_field_units_stable_order()

    def blue_phase_complete(self) -> bool:
        return not self.unresolved_blue_units()

    def run_red_phase(self, red_policy: Callable[["Battle", str], dict]) -> list[dict]:
        """Run the RED phase with the injected deterministic policy.

        RED AI shape: units iterate in stable id order; each acts once
        (move/attack/hold); action_end checks mirror is_unit_data_turn_resolved.
        """
        actions: list[dict] = []
        for uid in sorted(u.id for u in self.world.units.values() if u.faction == "red"):
            u = self.world.units.get(uid)
            if u is None or u.garrisoned or u.soldier_count <= 0:
                continue
            if self.executor.is_unit_data_turn_resolved(u.to_dict()):
                continue
            result = red_policy(self, uid)
            actions.append({"unit_id": uid, "result": result})
        return actions

    def evaluate_mission(self) -> dict:
        """Literal port of SIM.evaluate_mission decision core."""
        contract = self.scenario.get("mission_contract", {})
        objective = str(contract.get("primary_objective", ""))
        turn_limit = int(contract.get("turn_limit", 0))
        turn = self.world.current_turn

        blue_alive = [u for u in self.world.units.values() if u.faction == "blue" and u.soldier_count > 0]
        red_alive = [u for u in self.world.units.values() if u.faction == "red" and u.soldier_count > 0]
        hq_alive = any(u.unit_class == "hq" and u.faction == "blue" for u in blue_alive)
        red_hq_alive = any(u.unit_class == "hq" and u.faction == "red" for u in red_alive)
        blue_sol = sum(u.soldier_count for u in blue_alive)
        red_sol = sum(u.soldier_count for u in red_alive)
        blue_morale = sum(u.morale for u in blue_alive)
        blue_start_sol = sum(
            int(f.get("soldiers", f.get("soldier_count", 0)))
            for f in self.scenario.get("forces", [])
            if str(f.get("faction", "")) == "blue"
        )
        forces = self.scenario.get("forces", [])
        blue_hq_at_start = any(
            str(f.get("class", "")) == "hq" and str(f.get("faction", "")) == "blue" for f in forces
        )
        red_hq_at_start = any(
            str(f.get("class", "")) == "hq" and str(f.get("faction", "")) == "red" for f in forces
        )
        capital = {}
        for sh in sorted(self.world.strongholds.values(), key=lambda s: s.structure_id):
            if sh.structure_id.startswith("Capital"):
                capital = sh.to_facts()
        verdict = turn_rules.evaluate_mission(
            objective, turn_limit, turn, hq_alive, len(blue_alive), len(red_alive),
            self._battle_lost, capital,
            red_hq_alive=red_hq_alive,
            blue_hq_at_start=blue_hq_at_start,
            red_hq_at_start=red_hq_at_start,
        )
        return {
            "mission_status": verdict["mission_status"],
            "termination_reason": verdict["termination_reason"],
            "primary_objective": objective,
            "turn_limit": turn_limit,
            "turns_elapsed": turn,
            "blue_formations_alive": len(blue_alive),
            "blue_soldiers_alive": blue_sol,
            "blue_soldiers_start": blue_start_sol,
            "blue_soldiers_lost": max(0, blue_start_sol - blue_sol),
            "red_formations_alive": len(red_alive),
            "red_soldiers_alive": red_sol,
            "blue_average_morale": blue_morale / float(max(1, len(blue_alive))),
            "hq_state": ("missing" if not hq_alive else "active"),
            "red_hq_state": ("missing" if not red_hq_alive else "active"),
            "blue_hq_at_start": blue_hq_at_start,
            "red_hq_at_start": red_hq_at_start,
            "capital": capital,
            "objectives": [sh.to_facts() for sh in sorted(self.world.strongholds.values(), key=lambda s: s.structure_id)],
        }

    # ------------------------------------------------------------------ records / fingerprints
    def _record(self, kind: str, request: dict, result: dict) -> None:
        self._action_seq += 1
        self._action_history.append({
            "seq": self._action_seq,
            "action": kind,
            "request": request,
            "turn": self.world.current_turn,
            "success": bool(result.get("success", result.get("ok", False))),
            "state_version": self.world.state_version,
        })

    def fingerprint(self) -> str:
        return self.world.fingerprint()

    def trajectory_hash(self) -> str:
        """Deterministic digest of the full action history + final state."""
        payload = json.dumps(
            {"actions": self._action_history, "final": self.fingerprint()},
            sort_keys=True, separators=(",", ":"), ensure_ascii=True,
        )
        return hashlib.sha256(payload.encode("utf-8")).hexdigest()

    def action_history(self) -> list[dict]:
        return [dict(a) for a in self._action_history]

    def clone(self) -> "Battle":
        """Counterfactual-ready clone (shared static terrain)."""
        new = Battle.__new__(Battle)
        new.scenario = json.loads(json.dumps(self.scenario))
        new.profile_name = self.profile_name
        new.profile = self.profile
        new.seed = self.seed
        new.morale_rout_enabled = self.morale_rout_enabled
        new.world = self.world.clone()
        new.executor = Executor(new.world, morale_rout_enabled=self.morale_rout_enabled)
        new._full_information = self._full_information
        # Knowledge clones: shallow-copies of the ledger dicts.
        new.blue_knowledge = _clone_knowledge(self.blue_knowledge)
        new.red_knowledge = _clone_knowledge(self.red_knowledge)
        new._action_history = [dict(a) for a in self._action_history]
        new._action_seq = self._action_seq
        new._battle_lost = self._battle_lost
        return new

    def episode_result(self, knowledge_side: str = "blue") -> dict:
        mission = self.evaluate_mission()
        return {
            "sim_version": SIM_VERSION,
            "profile": self.profile_name,
            "ruleset_version": _ruleset_version(),
            "observation_schema": _observation_schema(),
            "scenario_id": str(self.scenario.get("scenario_id", "")),
            "seed": self.seed,
            "mission": mission,
            "final_fingerprint": self.fingerprint(),
            "trajectory_hash": self.trajectory_hash(),
            "actions_executed": len(self._action_history),
            "action_history": self.action_history(),
        }


def WorldState_valid_classes() -> tuple[str, ...]:
    from python_sim.state.world_state import VALID_CLASSES

    return VALID_CLASSES


def _clone_knowledge(kn: FactionKnowledge) -> FactionKnowledge:
    new = FactionKnowledge.__new__(FactionKnowledge)
    new.side = kn.side
    new.explored = dict(kn.explored)
    new.visible = dict(kn.visible)
    new.visible_by_scout = dict(kn.visible_by_scout)
    new.objective_hexes = dict(kn.objective_hexes)
    new.last_seen = {k: dict(v) for k, v in kn.last_seen.items()}
    new._prev_visible_enemies = dict(kn._prev_visible_enemies)
    new.combat_assessed = dict(kn.combat_assessed)
    new.assessed_health = dict(kn.assessed_health)
    new.stale_contacts = {k: dict(v) for k, v in kn.stale_contacts.items()}
    new.ever_seen = dict(kn.ever_seen)
    new.friendly_stale = {k: dict(v) for k, v in kn.friendly_stale.items()}
    return new


def _ruleset_version() -> str:
    from python_jev.contracts import ruleset

    return ruleset.RULESET_VERSION


def _observation_schema() -> str:
    from python_jev.contracts import observation_layout as ol

    return f"{ol.OBSERVATION_SCHEMA_VERSION} rev{ol.OBSERVATION_SCHEMA_REVISION}"


# Silence unused-import linters for intentionally re-exported parity symbols.
_ = combat_rules
_ = geometry


__all__ = ["Battle", "SCENARIO_PROFILES", "DEFAULT_TEST_BOUNDS"]
