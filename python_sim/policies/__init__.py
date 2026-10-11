"""Deterministic smoke policies (state-machine testing only, NOT tactical AI)."""

from __future__ import annotations

import random

from python_sim.rules import geometry
from python_sim.sim.battle import Battle


class RandomLegalPolicy:
    """Deterministic-seeded random policy over legal commands."""

    def __init__(self, seed: int = 0) -> None:
        self.rng = random.Random(seed)

    def blue_action(self, battle: Battle, unit_id: str) -> dict:
        units = battle.world.units
        u = units.get(unit_id)
        if u is None:
            return {"success": False, "error": "no unit"}
        choices: list[tuple[str, dict]] = []
        if not u.action_ended:
            targets = battle.executor.get_attackable_targets(unit_id)
            for t in targets:
                choices.append(("attack", {"defender_id": t["id"]}))
            env_units = battle._occupied_for("blue")
            # pick a random reachable destination
            from python_sim.rules import movement

            base_mp = u.base_mp
            vis = battle.executor.visible_enemy_ids(battle.blue_knowledge)
            env = movement.calculate_envelope(
                (u.q, u.r), u.unit_class, base_mp, u.remaining_mp,
                battle._policy_for("blue", "auto"), battle.world.cell_data,
                battle.world.get_player_known_occupied(vis), battle.world.river_cells,
                "blue", battle.world.stronghold_cells, u.turn_move_cost_spent,
                u.blue_limit, u.red_limit, u.black_limit,
                morale_rout_enabled=battle.morale_rout_enabled,
            )
            dests = sorted(env.reachable_data.keys())
            if dests:
                key = self.rng.choice(dests)
                d = env.reachable_data[key]
                choices.append(("move", {"path": d["path"]}))
            choices.append(("hold", {}))
        if not choices:
            return {"success": False, "error": "no legal action"}
        kind, payload = self.rng.choice(choices)
        if kind == "attack":
            return battle.do_attack(unit_id, payload["defender_id"], "blue")
        if kind == "move":
            path = payload["path"]
            final = path[-1]
            # stepwise execution along the planned path (blue authority)
            return battle.executor.execute_player_stepwise_move(
                unit_id, path, battle.executor.visible_enemy_ids(battle.blue_knowledge),
                battle.world.cell_data, battle.world.river_cells,
            ) if False else battle.do_move(unit_id, final[0], final[1], "blue")
        return battle.do_hold(unit_id, "blue")

    def red_action(self, battle: Battle, unit_id: str) -> dict:
        u = battle.world.units.get(unit_id)
        if u is None or u.action_ended:
            return {"success": False, "error": "no unit or action ended"}
        choices: list[tuple[str, dict]] = []
        targets = battle.executor.get_attackable_targets(unit_id)
        for t in targets:
            choices.append(("attack", {"defender_id": t["id"]}))
        # random green destination from full-truth envelope (RED AI shape)
        from python_sim.rules import movement

        env = movement.calculate_envelope(
            (u.q, u.r), u.unit_class, u.base_mp, u.remaining_mp,
            0, battle.world.cell_data, battle.world.get_occupied_dict(),
            battle.world.river_cells, "red", battle.world.stronghold_cells,
            u.turn_move_cost_spent, u.blue_limit, u.red_limit, u.black_limit,
            morale_rout_enabled=battle.morale_rout_enabled,
        )
        greens = sorted(env.green_hexes)
        if greens:
            dest = self.rng.choice(greens)
            choices.append(("move", {"dest": dest}))
        choices.append(("hold", {}))
        kind, payload = self.rng.choice(choices)
        if kind == "attack":
            return battle.do_attack(unit_id, payload["defender_id"], "red")
        if kind == "move":
            d = payload["dest"]
            return battle.do_move(unit_id, d[0], d[1], "red")
        return {"success": True, "held": True}


class SimpleAttackElseAdvancePolicy:
    """Attack if a legal target exists; else advance toward nearest known enemy."""

    def blue_action(self, battle: Battle, unit_id: str) -> dict:
        u = battle.world.units.get(unit_id)
        if u is None or u.action_ended:
            return {"success": False, "error": "no unit or ended"}
        targets = battle.executor.get_attackable_targets(unit_id)
        if targets:
            best = min(targets, key=lambda t: (t["distance"], t["id"]))
            return battle.do_attack(unit_id, best["id"], "blue")
        vis = battle.executor.visible_enemy_ids(battle.blue_knowledge)
        dest = self._step_toward(battle, u, vis)
        if dest is None:
            return battle.do_hold(unit_id, "blue")
        return battle.do_move(unit_id, dest[0], dest[1], "blue")

    def red_action(self, battle: Battle, unit_id: str) -> dict:
        u = battle.world.units.get(unit_id)
        if u is None or u.action_ended:
            return {"success": False, "error": "no unit or ended"}
        targets = battle.executor.get_attackable_targets(unit_id)
        if targets:
            best = min(targets, key=lambda t: (t["distance"], t["id"]))
            return battle.do_attack(unit_id, best["id"], "red")
        dest = self._step_toward_red(battle, u)
        if dest is None:
            return {"success": True, "held": True}
        return battle.do_move(unit_id, dest[0], dest[1], "red")

    def _step_toward(self, battle: Battle, u, visible_enemy_ids: dict[str, bool]):
        from python_sim.rules import movement

        env = movement.calculate_envelope(
            (u.q, u.r), u.unit_class, u.base_mp, u.remaining_mp,
            battle._policy_for("blue", "auto"), battle.world.cell_data,
            battle.world.get_player_known_occupied(visible_enemy_ids),
            battle.world.river_cells, "blue", battle.world.stronghold_cells,
            u.turn_move_cost_spent, u.blue_limit, u.red_limit, u.black_limit,
            morale_rout_enabled=battle.morale_rout_enabled,
        )
        return self._best_step(battle, u, env.reachable_data, visible_enemy_ids)

    def _step_toward_red(self, battle: Battle, u):
        from python_sim.rules import movement

        env = movement.calculate_envelope(
            (u.q, u.r), u.unit_class, u.base_mp, u.remaining_mp,
            0, battle.world.cell_data, battle.world.get_occupied_dict(),
            battle.world.river_cells, "red", battle.world.stronghold_cells,
            u.turn_move_cost_spent, u.blue_limit, u.red_limit, u.black_limit,
            morale_rout_enabled=battle.morale_rout_enabled,
        )
        greens = {geometry.key_of(h): d for h, d in env.reachable_data.items()}
        return self._best_step(battle, u, greens, None)

    def _best_step(self, battle: Battle, u, reachable: dict, vis):
        enemies = [
            unit for unit in battle.world.units.values()
            if unit.faction != u.faction and unit.soldier_count > 0 and not unit.garrisoned
            and (vis is None or unit.id in vis)
        ]
        if not enemies or not reachable:
            return None
        best_key = None
        best_score = None
        for key, d in reachable.items():
            c = d["coord"]
            dist = min(geometry.hex_distance_axial(c, (e.q, e.r)) for e in enemies)
            # T0 bugfix (continuation-policies-v0.1.1): the score used to be
            # (-dist, cost, key) MINIMIZED, which maximized the distance to
            # the nearest enemy — every unit fled to the world edge, no
            # battle ever made contact, and all counterfactual Q tied. The
            # documented behavior ("advance toward nearest known enemy") is
            # the minimized (dist, cost, key) chain below.
            score = (dist, d["cost"], key)
            if best_score is None or score < best_score:
                best_score = score
                best_key = key
        if best_key is None:
            return None
        d = reachable[best_key]
        path = d["path"]
        return path[-1]


class HoldPolicy:
    """Every unit holds (pure reset/cycle coverage)."""

    def blue_action(self, battle: Battle, unit_id: str) -> dict:
        return battle.do_hold(unit_id, "blue")

    def red_action(self, battle: Battle, unit_id: str) -> dict:
        return {"success": True, "held": True}


__all__ = ["HoldPolicy", "RandomLegalPolicy", "SimpleAttackElseAdvancePolicy"]
