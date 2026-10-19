"""Authoritative executor — semantic port of Step3UnitManager action surface.

Every mutation the simulator performs flows through here, mirroring the
canonical call shapes documented in sim_controller.gd:

  BLUE move   : execute_player_stepwise_move (stepwise contact resolution)
  RED move    : find_route (GREEN_ONLY) -> execute_move
  attack      : execute_attack (preconditions -> calculate_combat -> commit)
  turn cycle  : end_turn (reset) with fog recompute orchestrated by Battle

Parity-critical order preserved in each function (see inline citations).
Observation-safe vs authoritative legality are SEPARATE: this executor is the
authoritative recheck layer (Notion I3/I5); the projector builds the
observation-safe mask independently from FactionKnowledge.
"""

from __future__ import annotations

from python_sim.rules import combat as combat_rules
from python_sim.rules import geometry, march, movement, terrain
from python_sim.rules.geometry import Hex
from python_sim.rules.rounding import maxf_gd, maxi_gd, minf_gd  # noqa: F401
from python_sim.state.world_state import WorldState

FIELD_FORTIFICATION_DISMANTLE_MP_COST: float = 1.0
REST_MORALE_RESTORE: float = 12.0


class Executor:
    """Authoritative mutation layer over one WorldState."""

    def __init__(self, world: WorldState, morale_rout_enabled: bool = False) -> None:
        self.world = world
        self.morale_rout_enabled = morale_rout_enabled

    # ------------------------------------------------------------------ helpers
    def _u(self, unit_id: str) -> dict:
        u = self.world.units.get(unit_id)
        if u is None:
            return {}
        return u.to_dict()

    def _commit(self, unit_id: str, u: dict) -> None:
        """Write dict fields back onto the typed unit (same keys)."""
        target = self.world.units.get(unit_id)
        if target is None:
            return
        for key, value in u.items():
            if key in ("class",):
                continue
            setattr(target, key, value)
        target.unit_class = u.get("class", target.unit_class)

    def visible_enemy_ids(self, knowledge) -> dict[str, bool]:
        """Fog-visible enemy id set for the blue-side stepwise authority."""
        out: dict[str, bool] = {}
        enemy_faction = "red" if knowledge.side == "blue" else "blue"
        for uid, unit in self.world.units.items():
            if unit.faction != enemy_faction or unit.garrisoned:
                continue
            if knowledge.is_enemy_visible(unit.to_dict()):
                out[uid] = True
        return out

    # ------------------------------------------------------------------ movement
    def execute_move(
        self,
        unit_id: str,
        path: list[Hex],
        cost: float,
        march_class: int,
        crosses_river: bool,
    ) -> dict:
        """Literal port of UM.execute_move (RED path / non-stepwise authority)."""
        w = self.world
        u = self._u(unit_id)
        if not u:
            return {"success": False, "error": "Unit not found"}
        if u.get("garrisoned", False):
            return {"success": False, "error": "Garrisoned unit cannot move on field"}
        if bool(u.get("routed", False)):
            return {"success": False, "error": "Routed — control lost (궤주 중)"}
        if u["action_ended"]:
            return {"success": False, "error": "Unit action already ended this turn"}

        old_q, old_r = int(u["q"]), int(u["r"])
        old_key = geometry.key_of((old_q, old_r))
        dest = path[-1]
        new_key = geometry.key_of(dest)

        # STEP-05R2: occupancy invariant against player-known state. This
        # executor is the authoritative layer; the red-side path already
        # validated with get_occupied_dict (full truth), blue uses stepwise.
        mover_is_blue = str(u.get("faction", "")) == "blue"
        if mover_is_blue:
            stopped_by_hidden = False
            contact_eid = ""
            truncated: list[Hex] = [path[0]]
            for h in path[1:]:
                k = geometry.key_of(h)
                if k in w.occupied_map and w.occupied_map[k] != unit_id:
                    occ_id = w.occupied_map[k]
                    occ_u = self._u(occ_id)
                    if occ_u.get("faction", "") == "red":
                        stopped_by_hidden = True
                        contact_eid = occ_id
                        break
                    return {
                        "success": False,
                        "error": "Route blocked by friendly unit",
                        "blocked_hex": h,
                        "stale_plan": True,
                    }
                truncated.append(h)
            if stopped_by_hidden:
                if len(truncated) < 2:
                    return {
                        "success": True, "moved": False, "stopped_by_contact": True,
                        "contact_kind": "hidden_enemy", "contact_id": contact_eid,
                        "unit_id": unit_id, "from": (old_q, old_r), "to": (old_q, old_r),
                        "remaining_mp": float(u.get("remaining_mp", 2.0)),
                        "traversed_path": truncated, "traversed_cost": 0.0,
                    }
                path = truncated
                dest = path[-1]
                new_key = geometry.key_of(dest)
        else:
            # RED AI validated its route against full truth upstream
            # (find_route with get_occupied_dict); keep the same guarantee.
            for h in path[1:]:
                k = geometry.key_of(h)
                if k in w.occupied_map and w.occupied_map[k] != unit_id:
                    return {
                        "success": False,
                        "error": "Route blocked by unit",
                        "blocked_hex": h,
                        "stale_plan": True,
                    }

        # §8 Stronghold occupancy.
        if w.is_stronghold_hex(dest[0], dest[1]):
            return {"success": False, "error": "Destination is inside stronghold footprint — use garrison entry"}

        # Fortified movement lock.
        if (
            bool(u.get("field_fortified", False))
            or int(u.get("field_fortification_hp", 0)) > 0
            or bool(u.get("fortified", False))
        ) and dest != (old_q, old_r):
            return {"success": False, "error": "Fortified — must explicitly dismantle field fortification before moving (uses [ 요새화 해제 ])"}

        # Resource consequences (morale only; supply retired SUP-FINAL).
        morale_penalty = march.get_morale_penalty(march_class, self.morale_rout_enabled)
        u["morale"] = maxf_gd(0.0, float(u["morale"]) - morale_penalty)
        u["fatigue"] = minf_gd(100.0, float(u.get("fatigue", 0.0)) + march.fatigue_for_march(march_class))
        u["has_moved"] = True

        base_mp = float(u.get("base_mp", 2.0))
        blue_lim = float(u.get("blue_limit", march.get_blue_limit(base_mp)))
        red_lim = float(u.get("red_limit", march.get_red_limit(base_mp)))
        black_lim = float(u.get("black_limit", march.get_black_limit(base_mp)))

        cur_spent = float(u.get("turn_move_cost_spent", 0.0))
        new_spent = cur_spent + cost
        u["turn_move_cost_spent"] = new_spent
        u["remaining_mp"] = maxf_gd(0.0, blue_lim - new_spent)

        # STEP-04R10 §1,§17: GREEN -> GUARD, ORANGE/RED or river -> UNGUARDED.
        if march_class == march.MarchClass.GREEN:
            u["defense_ready"] = True
            u["unguarded"] = False
        elif march_class in (march.MarchClass.ORANGE, march.MarchClass.RED) or crosses_river:
            u["unguarded"] = True
            u["defense_ready"] = False

        # §9/§10 revised R10: river or black-limit ends the action.
        end_action = False
        if crosses_river or new_spent >= black_lim - 0.001:
            u["action_ended"] = True
            end_action = True
        else:
            u["action_ended"] = False
            end_action = False

        # Occupancy mutation: ERASE OLD KEY THEN SET NEW KEY (order matters).
        w.occupied_map.pop(old_key, None)
        u["q"] = dest[0]
        u["r"] = dest[1]
        w.occupied_map[new_key] = unit_id
        w.notify_mutation()
        self._commit(unit_id, u)

        return {
            "success": True,
            "unit_id": unit_id,
            "from": (old_q, old_r),
            "to": dest,
            "remaining_mp": u["remaining_mp"],
            "turn_move_cost_spent": u["turn_move_cost_spent"],
            "blue_limit": blue_lim,
            "red_limit": red_lim,
            "black_limit": black_lim,
            "morale": u["morale"],
            "action_ended": u["action_ended"],
            "defense_ready": bool(u.get("defense_ready", False)),
            "unguarded": bool(u.get("unguarded", False)),
            "march_class": march_class,
            "end_action": end_action,
        }

    def execute_player_stepwise_move(
        self,
        unit_id: str,
        path: list[Hex],
        visible_enemy_ids: dict[str, bool],
        cell_data: dict[str, dict],
        river_cells: dict[str, bool],
    ) -> dict:
        """Literal port of UM.execute_player_stepwise_move (§4-§8).

        Walk one hex at a time; STOP before stacking on the first occupied
        hex; charge MP ONLY for traversed hexes; partial-move success with
        contact info. March class classifies the ACTUAL traversed cost.
        """
        w = self.world
        u = self._u(unit_id)
        if not u:
            return {"success": False, "error": "Unit not found"}
        if u.get("garrisoned", False):
            return {"success": False, "error": "Garrisoned unit cannot move on field"}
        if bool(u.get("routed", False)):
            return {"success": False, "error": "Routed — control lost (궤주 중)"}
        if bool(u.get("action_ended", False)):
            return {"success": False, "error": "Unit action already ended this turn"}
        if len(path) < 2:
            return {"success": False, "error": "Empty path"}

        old_q, old_r = int(u.get("q", 0)), int(u.get("r", 0))
        dest_probe = path[-1]
        if (
            bool(u.get("field_fortified", False))
            or int(u.get("field_fortification_hp", 0)) > 0
            or bool(u.get("fortified", False))
        ) and dest_probe != (old_q, old_r):
            return {"success": False, "error": "Fortified — must explicitly dismantle field fortification before moving (uses [ 요새화 해제 ])"}

        uclass = str(u.get("class", "infantry"))
        traversed: list[Hex] = [path[0]]
        traversed_cost = 0.0
        crossed = False
        contact_kind = ""
        contact_id = ""
        contact_hex: Hex = (-999, -999)

        for i in range(1, len(path)):
            h = path[i]
            prev = path[i - 1]
            if w.is_stronghold_hex(h[0], h[1]):
                contact_kind = "stronghold"
                contact_hex = h
                break
            key = geometry.key_of(h)
            if key in w.occupied_map and w.occupied_map[key] != unit_id:
                occ_id = w.occupied_map[key]
                occ_u = self._u(occ_id)
                occ_fac = str(occ_u.get("faction", ""))
                if occ_fac == "blue":
                    contact_kind = "friendly"
                elif occ_fac == "red":
                    contact_kind = "visible_enemy" if occ_id in visible_enemy_ids else "hidden_enemy"
                else:
                    contact_kind = "unknown"
                contact_id = occ_id
                contact_hex = h
                break
            cell = cell_data.get(key)
            terr = int(cell["terrain"]) if cell is not None else 0
            step_cost = terrain.get_terrain_cost(terr, uclass)
            prev_key = geometry.key_of(prev)
            if river_cells.get(prev_key, False) or river_cells.get(key, False) or terr == 7:
                crossed = True
            traversed_cost += step_cost
            traversed.append(h)

        stopped = contact_kind != ""
        moved = len(traversed) >= 2
        if not moved:
            # Contact on the very next hex: no MP charged, no teleport.
            return {
                "success": True, "moved": False, "stopped_by_contact": stopped,
                "contact_kind": contact_kind, "contact_id": contact_id, "contact_hex": contact_hex,
                "traversed_path": traversed, "traversed_cost": 0.0,
                "march_class": march.MarchClass.GREEN, "crosses_river": False,
                "from": (old_q, old_r), "to": (old_q, old_r),
            }

        # Resource consequences for ACTUAL traversed cost only (§7).
        base_mp = float(u.get("base_mp", 2.0))
        blue_lim = float(u.get("blue_limit", march.get_blue_limit(base_mp)))
        red_lim = float(u.get("red_limit", march.get_red_limit(base_mp)))
        black_lim = float(u.get("black_limit", march.get_black_limit(base_mp)))
        cur_spent = float(u.get("turn_move_cost_spent", 0.0))
        march_class = march.classify_march_by_cumulative_cost(cur_spent + traversed_cost, blue_lim, red_lim, crossed)
        morale_penalty = march.get_morale_penalty(march_class, self.morale_rout_enabled)
        u["morale"] = maxf_gd(0.0, float(u.get("morale", 100.0)) - morale_penalty)
        u["fatigue"] = minf_gd(100.0, float(u.get("fatigue", 0.0)) + march.fatigue_for_march(march_class))
        u["has_moved"] = True
        if march_class == march.MarchClass.GREEN and not crossed:
            u["defense_ready"] = True
            u["unguarded"] = False
        else:
            u["unguarded"] = True
            u["defense_ready"] = False
        new_spent = cur_spent + traversed_cost
        u["turn_move_cost_spent"] = new_spent
        u["remaining_mp"] = maxf_gd(0.0, blue_lim - new_spent)
        end_action = False
        if crossed or new_spent >= black_lim - 0.001:
            u["action_ended"] = True
            end_action = True
        else:
            u["action_ended"] = False
            end_action = False

        old_key = geometry.key_of((old_q, old_r))
        final_hex = traversed[-1]
        new_key = geometry.key_of(final_hex)
        w.occupied_map.pop(old_key, None)
        u["q"] = final_hex[0]
        u["r"] = final_hex[1]
        w.occupied_map[new_key] = unit_id
        w.notify_mutation()
        self._commit(unit_id, u)

        return {
            "success": True, "moved": True, "stopped_by_contact": stopped,
            "contact_kind": contact_kind, "contact_id": contact_id, "contact_hex": contact_hex,
            "traversed_path": traversed, "traversed_cost": traversed_cost,
            "march_class": march_class, "crosses_river": crossed,
            "from": (old_q, old_r), "to": final_hex,
            "remaining_mp": u["remaining_mp"],
            "turn_move_cost_spent": u["turn_move_cost_spent"],
            "blue_limit": blue_lim, "red_limit": red_lim, "black_limit": black_lim,
            "morale": u["morale"], "action_ended": u["action_ended"],
            "defense_ready": bool(u.get("defense_ready", False)),
            "unguarded": bool(u.get("unguarded", False)),
            "end_action": end_action,
        }

    # ------------------------------------------------------------------ combat
    def get_attackable_targets(self, attacker_id: str) -> list[dict]:
        """Literal port of UM.get_attackable_targets."""
        w = self.world
        result: list[dict] = []
        atk_u = self._u(attacker_id)
        if not atk_u:
            return result
        if atk_u.get("garrisoned", False):
            return result
        if bool(atk_u.get("action_ended", False)):
            return result
        if bool(atk_u.get("has_attacked", False)):
            return result
        if str(atk_u.get("class", "")) == "supply":
            return result

        atk_coord = (int(atk_u["q"]), int(atk_u["r"]))
        atk_faction = str(atk_u["faction"])
        atk_class = str(atk_u["class"])
        max_range = combat_rules.get_attack_range(atk_class)

        for uid in sorted(w.units.keys()):
            target = w.units[uid]
            if target.garrisoned:
                continue
            if target.faction == atk_faction:
                continue
            if target.soldier_count <= 0:
                continue
            def_coord = (target.q, target.r)
            dist = geometry.hex_distance_axial(atk_coord, def_coord)
            if dist <= max_range and dist > 0:
                info = target.to_dict()
                info["distance"] = dist
                info["is_adjacent"] = dist == 1
                info["fortification_hp"] = w.get_fortress_hp(def_coord[0], def_coord[1])
                result.append(info)
        return result

    def execute_attack(
        self,
        attacker_id: str,
        defender_id: str,
        strategic_modifiers: dict | None = None,
        variance: float = 1.0,
    ) -> dict:
        """Literal port of UM.execute_attack (variance defaults 1.0)."""
        w = self.world
        if strategic_modifiers is None:
            strategic_modifiers = {}
        atk_u = self._u(attacker_id)
        def_u = self._u(defender_id)
        if not atk_u or not def_u:
            return {"success": False, "error": "Unit not found"}

        if atk_u.get("garrisoned", False):
            return {"success": False, "error": "Garrisoned attacker cannot attack from inside"}
        if def_u.get("garrisoned", False):
            return {"success": False, "error": "Cannot directly attack garrisoned defender — attack stronghold instead"}
        if bool(atk_u.get("routed", False)):
            return {"success": False, "error": "Routed — control lost (궤주 중)"}
        if str(atk_u.get("class", "")) == "supply":
            return {"success": False, "error": "Supply train cannot attack (보급대)"}
        if bool(atk_u.get("has_attacked", False)):
            return {"success": False, "error": "Already attacked this turn (공격 완료)"}
        if bool(atk_u.get("action_ended", False)):
            return {"success": False, "error": "Attacker action already ended"}

        atk_coord = (int(atk_u["q"]), int(atk_u["r"]))
        def_coord = (int(def_u["q"]), int(def_u["r"]))
        dist = geometry.hex_distance_axial(atk_coord, def_coord)
        max_range = combat_rules.get_attack_range(str(atk_u["class"]))
        if dist > max_range or dist <= 0:
            return {"success": False, "error": "Target out of attack range"}

        fort_hp = w.get_fortress_hp(def_coord[0], def_coord[1])
        res = combat_rules.calculate_combat(
            atk_u, def_u, dist, fort_hp, strategic_modifiers, variance,
            morale_rout_enabled=self.morale_rout_enabled,
        )

        if fort_hp > 0:
            new_fort_hp = int(res["remaining_fortification_hp"])
            w.set_fortress_hp(def_coord[0], def_coord[1], new_fort_hp)
            sh = w.get_stronghold_at(def_coord[0], def_coord[1])
            if sh is not None and new_fort_hp <= 0:
                sh.breached = True

        # Defender field fortification update (STEP-04R7.1 §8-§10).
        if bool(def_u.get("field_fortified", False)) or int(def_u.get("field_fortification_hp", 0)) > 0:
            new_field_hp = int(res.get("remaining_field_fortification_hp", 0))
            def_u["field_fortification_hp"] = new_field_hp
            if new_field_hp <= 0:
                def_u["field_fortified"] = False
                def_u["fortified"] = False
                def_u["field_fortification_hp_max"] = 0

        def_cas = int(res["defender_casualties"])
        def_u["soldier_count"] = int(res["defender_remaining_troops"])
        def_u["morale"] = float(res["defender_final_morale"])

        defender_destroyed = int(def_u["soldier_count"]) <= 0
        if defender_destroyed:
            self._commit(defender_id, def_u)
            w.destroy_unit(defender_id)

        atk_cas = int(res["attacker_casualties"])
        atk_u["soldier_count"] = int(res["attacker_remaining_troops"])
        atk_u["morale"] = float(res["attacker_final_morale"])

        attacker_destroyed = int(atk_u["soldier_count"]) <= 0
        if attacker_destroyed:
            w.destroy_unit(attacker_id)

        atk_class = combat_rules.normalize_class_name(str(atk_u.get("class", "infantry")))
        atk_u["has_attacked"] = True

        if atk_class == "cavalry" and not attacker_destroyed:
            # Cavalry continuation: keeps the action.
            atk_u["action_ended"] = False
        else:
            atk_u["action_ended"] = True
            atk_u["remaining_mp"] = 0.0

        if not defender_destroyed:
            self._commit(defender_id, def_u)
        if not attacker_destroyed:
            self._commit(attacker_id, atk_u)
        w.notify_mutation()

        res["success"] = True
        res["attacker_id"] = attacker_id
        res["defender_id"] = defender_id
        res["defender_destroyed"] = defender_destroyed
        res["attacker_destroyed"] = attacker_destroyed
        res["attacker_action_ended"] = bool(atk_u.get("action_ended", True))
        res["attacker_remaining_mp"] = float(atk_u.get("remaining_mp", 0.0))
        return res

    def execute_ambush_strike(self, ambusher_id: str, victim_id: str) -> dict:
        """Literal port of UM.execute_ambush_strike (melee opening strike)."""
        w = self.world
        atk_u = self._u(ambusher_id)
        vic_u = self._u(victim_id)
        if not atk_u or not vic_u:
            return {"success": False, "error": "Unit not found"}
        if bool(atk_u.get("garrisoned", False)) or bool(vic_u.get("garrisoned", False)):
            return {"success": False, "error": "Garrisoned units cannot ambush"}
        if int(atk_u.get("soldier_count", 0)) <= 0 or int(vic_u.get("soldier_count", 0)) <= 0:
            return {"success": False, "error": "Destroyed unit cannot ambush"}
        atk_coord = (int(atk_u["q"]), int(atk_u["r"]))
        vic_coord = (int(vic_u["q"]), int(vic_u["r"]))
        dist = geometry.hex_distance_axial(atk_coord, vic_coord)
        if dist != 1:
            return {"success": False, "error": "Ambush requires adjacency"}
        if combat_rules.get_attack_range(str(atk_u["class"])) != 1:
            return {"success": False, "error": "Only melee ambush in Step 5"}
        fort_hp = w.get_fortress_hp(vic_coord[0], vic_coord[1])
        res = combat_rules.calculate_combat(
            atk_u, vic_u, 1, fort_hp, {}, 1.0, morale_rout_enabled=self.morale_rout_enabled,
        )
        # Surprise asymmetry: no reciprocal for the ambusher.
        res["attacker_casualties"] = 0
        res["attacker_remaining_troops"] = int(atk_u["soldier_count"])
        res["attacker_final_morale"] = float(atk_u["morale"])
        res["attacker_morale_delta"] = 0.0
        res["retaliation_occurred"] = False
        res["is_ambush_opening_strike"] = True

        if bool(vic_u.get("field_fortified", False)) or int(vic_u.get("field_fortification_hp", 0)) > 0:
            new_field_hp = int(res.get("remaining_field_fortification_hp", 0))
            vic_u["field_fortification_hp"] = new_field_hp
            if new_field_hp <= 0:
                vic_u["field_fortified"] = False
                vic_u["fortified"] = False
                vic_u["field_fortification_hp_max"] = 0

        vic_cas = int(res["defender_casualties"])
        vic_u["soldier_count"] = int(res["defender_remaining_troops"])
        vic_u["morale"] = float(res["defender_final_morale"])
        victim_destroyed = int(vic_u["soldier_count"]) <= 0
        if victim_destroyed:
            self._commit(victim_id, vic_u)
            w.destroy_unit(victim_id)
        else:
            # Movement stops: surprised victim ends its action.
            vic_u["action_ended"] = True
            vic_u["remaining_mp"] = 0.0
            self._commit(victim_id, vic_u)
        w.notify_mutation()

        res["success"] = True
        res["ambusher_id"] = ambusher_id
        res["victim_id"] = victim_id
        res["victim_destroyed"] = victim_destroyed
        res["victim_action_ended"] = True
        return res

    # ------------------------------------------------------------------ rest/fortify/wait
    def can_unit_rest(self, unit_id: str) -> bool:
        u = self._u(unit_id)
        if not u or bool(u.get("garrisoned", False)):
            return False
        if bool(u.get("routed", False)):
            return False
        if str(u.get("faction", "")) != "blue":
            return False
        if bool(u.get("action_ended", False)):
            return False
        if bool(u.get("has_attacked", False)):
            return False
        if bool(u.get("has_moved", False)):
            return False
        if float(u.get("turn_move_cost_spent", 0.0)) > 0.001:
            return False
        return True

    def rest_unit(self, unit_id: str) -> dict:
        u = self._u(unit_id)
        if not u:
            return {"success": False, "error": "Unit not found"}
        if u.get("garrisoned", False):
            return {"success": False, "error": "Garrison units cannot use field rest"}
        if not self.can_unit_rest(unit_id):
            return {"success": False, "error": "Unit not eligible to rest (must be untouched, no MP spent, no attack, not garrisoned)"}
        u["action_ended"] = True
        u["turn_resolved"] = True
        u["rested_this_turn"] = True
        u["resting_unguarded"] = False
        u["defense_ready"] = False
        u["unguarded"] = False
        u["reviewed_this_turn"] = True
        u["remaining_mp"] = 0.0
        if self.morale_rout_enabled:
            u["morale"] = minf_gd(100.0, float(u.get("morale", 100.0)) + REST_MORALE_RESTORE)
        u["fatigue"] = 0.0
        self.world.notify_mutation()
        self._commit(unit_id, u)
        return {"success": True, "unit_id": unit_id, "action_ended": True, "turn_resolved": True}

    def can_unit_fortify(self, unit_id: str) -> bool:
        u = self._u(unit_id)
        if not u or bool(u.get("garrisoned", False)):
            return False
        if bool(u.get("routed", False)):
            return False
        if str(u.get("faction", "")) != "blue":
            return False
        spent = float(u.get("turn_move_cost_spent", 0.0))
        if bool(u.get("field_fortified", False)) or int(u.get("field_fortification_hp", 0)) > 0:
            return False
        # 2026-10-18 (user, balance): a unit can field-fortify only once per game (mirrors step3_unit_manager.gd).
        if bool(u.get("field_fortify_used", False)):
            return False
        return spent <= 0.001 and not bool(u.get("has_moved", False)) and not bool(u.get("has_attacked", False)) and not bool(u.get("action_ended", False))

    def fortify_unit(self, unit_id: str) -> dict:
        u = self._u(unit_id)
        if not u:
            return {"success": False, "error": "Unit not found"}
        if u.get("garrisoned", False):
            return {"success": False, "error": "Garrison units cannot use field fortify"}
        if not self.can_unit_fortify(unit_id):
            return {"success": False, "error": "Unit not eligible to fortify (turn_move_cost_spent > 0, has_moved, attacked, or action_ended)"}
        fort_hp = combat_rules.FIELD_FORTIFICATION_DEFAULT_HP
        u["field_fortified"] = True
        u["fortified"] = True
        u["field_fortify_used"] = True
        u["field_fortification_hp"] = fort_hp
        u["field_fortification_hp_max"] = fort_hp
        u["resting_unguarded"] = False
        u["defense_ready"] = True
        u["unguarded"] = False
        u["action_ended"] = True
        u["turn_resolved"] = True
        u["reviewed_this_turn"] = True
        u["remaining_mp"] = 0.0
        self.world.notify_mutation()
        self._commit(unit_id, u)
        return {"success": True, "unit_id": unit_id, "fortified": True, "field_fortification_hp": fort_hp}

    def dismantle_fortification(self, unit_id: str) -> dict:
        u = self._u(unit_id)
        if not u:
            return {"success": False, "error": "Unit not found"}
        base = float(u.get("base_mp", 2.0))
        blue_lim = float(u.get("blue_limit", march.get_blue_limit(base)))
        spent = float(u.get("turn_move_cost_spent", 0.0))
        has_fort = bool(u.get("field_fortified", False)) or int(u.get("field_fortification_hp", 0)) > 0 or bool(u.get("fortified", False))
        eligible = (
            has_fort
            and not bool(u.get("garrisoned", False))
            and not bool(u.get("action_ended", False))
            and spent + FIELD_FORTIFICATION_DISMANTLE_MP_COST <= blue_lim + 0.001
        )
        if not eligible:
            return {"success": False, "error": f"Cannot dismantle: need field fortification, not action_ended, and at least {FIELD_FORTIFICATION_DISMANTLE_MP_COST:.1f} MP remaining"}
        u["turn_move_cost_spent"] = spent + FIELD_FORTIFICATION_DISMANTLE_MP_COST
        u["remaining_mp"] = maxf_gd(0.0, blue_lim - float(u["turn_move_cost_spent"]))
        u["field_fortified"] = False
        u["fortified"] = False
        u["field_fortification_hp"] = 0
        u["field_fortification_hp_max"] = 0
        u["defense_ready"] = False
        u["unguarded"] = False
        u["action_ended"] = False
        self.world.notify_mutation()
        self._commit(unit_id, u)
        return {"success": True, "unit_id": unit_id, "spent": float(u["turn_move_cost_spent"]), "remaining_mp": float(u["remaining_mp"])}

    def wait_unit(self, unit_id: str) -> dict:
        """UM.wait_unit: action end with GUARD."""
        u = self._u(unit_id)
        if not u:
            return {"success": False, "error": "Unit not found"}
        if bool(u.get("garrisoned", False)):
            return {"success": False, "error": "Garrison units cannot wait"}
        u["action_ended"] = True
        u["turn_resolved"] = True
        u["defense_ready"] = True
        u["unguarded"] = False
        u["remaining_mp"] = 0.0
        u["reviewed_this_turn"] = True
        self.world.notify_mutation()
        self._commit(unit_id, u)
        return {"success": True, "unit_id": unit_id}

    def resolve_unit_via_next(self, unit_id: str) -> dict:
        """UM.resolve_unit_via_next (NEXT-flow resolution policy)."""
        u = self._u(unit_id)
        if not u:
            return {"success": False, "error": "Unit not found"}
        if bool(u.get("garrisoned", False)):
            return {"success": False, "error": "Garrisoned"}
        if bool(u.get("action_ended", False)):
            return {"success": False, "error": "Already action_ended"}
        base = float(u.get("base_mp", 2.0))
        blue_lim = float(u.get("blue_limit", march.get_blue_limit(base)))
        spent = float(u.get("turn_move_cost_spent", 0.0))
        has_moved = bool(u.get("has_moved", False))
        unguarded_flag = bool(u.get("unguarded", False))

        if unguarded_flag:
            u["action_ended"] = True
            u["turn_resolved"] = True
            u["reviewed_this_turn"] = True
            u["remaining_mp"] = 0.0
            self._commit(unit_id, u)
            return {"success": True, "resolved": True, "stance": "unguarded", "unguarded": True, "defense_ready": False}

        if spent + 0.001 >= blue_lim and (has_moved or spent > 0.001):
            u["defense_ready"] = True
            u["unguarded"] = False
            u["action_ended"] = True
            u["turn_resolved"] = True
            u["reviewed_this_turn"] = True
            u["remaining_mp"] = 0.0
            self._commit(unit_id, u)
            return {"success": True, "resolved": True, "stance": "guard", "defense_ready": True, "unguarded": False}

        return {"success": False, "resolved": False, "reason": "blue MP remains — unit can move again", "stance": "active"}

    # ------------------------------------------------------------------ turn resolution queries
    def is_unit_data_turn_resolved(self, u: dict) -> bool:
        """Literal port of UM.is_unit_data_turn_resolved (ORDER preserved)."""
        if int(u.get("soldier_count", 0)) <= 0:
            return True
        if bool(u.get("garrisoned", False)):
            return True
        if bool(u.get("action_ended", False)):
            return True
        if bool(u.get("field_fortified", False)) or int(u.get("field_fortification_hp", 0)) > 0 or bool(u.get("fortified", False)):
            return True
        if bool(u.get("rested_this_turn", False)):
            return True
        if bool(u.get("routed", False)):
            return True
        if bool(u.get("is_convoy", False)) or str(u.get("class", "")) == "supply":
            return True
        base = float(u.get("base_mp", 2.0))
        blue_lim = float(u.get("blue_limit", march.get_blue_limit(base)))
        spent = float(u.get("turn_move_cost_spent", 0.0))
        if spent + 0.001 >= blue_lim:
            return True
        return False

    def unresolved_friendly_field_units_stable_order(self) -> list[dict]:
        """get_unresolved_friendly_field_units_in_stable_order (id ascending)."""
        candidates: list[dict] = []
        for uid in sorted(self.world.units.keys()):
            u = self.world.units[uid]
            if u.garrisoned:
                continue
            if u.faction != "blue":
                continue
            if u.soldier_count <= 0:
                continue
            if self.is_unit_data_turn_resolved(u.to_dict()):
                continue
            candidates.append(u.to_dict())
        return candidates

    def end_turn(self) -> int:
        """Literal port of UM.end_turn — resets and returns the new turn."""
        w = self.world
        w.current_turn += 1
        for u in w.units.values():
            base = u.base_mp
            u.blue_limit = march.get_blue_limit(base)
            u.red_limit = march.get_red_limit(base)
            u.black_limit = march.get_black_limit(base)
            u.turn_move_cost_spent = 0.0
            u.remaining_mp = base
            u.action_ended = False
            u.turn_resolved = False
            u.has_moved = False
            u.has_attacked = False
            u.rested_this_turn = False
            u.resting_unguarded = False
            u.reviewed_this_turn = False
            # Field fortification persists (STEP-04R10 §10); guard reset only
            # for non-fortified units (fortified keep GUARD).
            if u.field_fortified or u.field_fortification_hp > 0 or u.fortified:
                u.defense_ready = True
                u.unguarded = False
            else:
                u.defense_ready = False
                u.unguarded = False
        w.notify_mutation()
        return w.current_turn

    # ------------------------------------------------------------------ RED AI primitives
    def red_move(self, unit_id: str, dest: Hex) -> dict:
        """SIM._red_move: GREEN_ONLY route from current truth + execute_move."""
        u = self._u(unit_id)
        if not u:
            return {"success": False, "error": "Unit not found"}
        route = movement.find_route(
            (int(u.get("q", 0)), int(u.get("r", 0))), dest,
            str(u.get("class", "infantry")), float(u.get("base_mp", 2.0)),
            float(u.get("remaining_mp", 2.0)), march.MarchPolicy.GREEN_ONLY,
            self.world.cell_data, self.world.get_occupied_dict(),
            self.world.river_cells, "red", self.world.stronghold_cells,
            float(u.get("turn_move_cost_spent", 0.0)),
            float(u.get("blue_limit", 2.0)), float(u.get("red_limit", 4.0)),
            float(u.get("black_limit", 4.4)),
            morale_rout_enabled=self.morale_rout_enabled,
        )
        if not route.found or not route.is_valid_destination:
            return {"success": False, "error": route.rejection_reason}
        return self.execute_move(unit_id, route.path, route.cost, route.march_class, route.crosses_river)

    def red_attack(self, attacker_id: str, defender_id: str, mods: dict | None = None) -> dict:
        """SIM._red_attack: legality recheck + execute_attack."""
        legal = any(c.get("id") == defender_id for c in self.get_attackable_targets(attacker_id))
        if not legal:
            return {"success": False, "error": "Target is not a legal attack option."}
        return self.execute_attack(attacker_id, defender_id, mods or {})


__all__ = ["FIELD_FORTIFICATION_DISMANTLE_MP_COST", "REST_MORALE_RESTORE", "Executor"]
