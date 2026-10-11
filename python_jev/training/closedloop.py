"""Closed-loop battle benchmark (T0, Part F).

The selected best-validation checkpoint plays full battles inside the
Python simulator (no training during battles) against fixed baselines:
RandomLegalPolicy, SimpleAttackElseAdvancePolicy, HoldPolicy. Every
benchmark scenario runs as a side-swapped pair (BLUE=JEV/RED=base and
the reverse) on the identical scenario/terrain/mission/forces.

Metrics per battle: terminal verdict, mission completion, objective
progress facts, friendly/enemy casualties, HQ survival, turns + tactical
decisions to terminal, expired flag, skill distribution, invalid/partial
execution rates. Distributions and averages — never one arbitrary score.
"""

from __future__ import annotations

import copy
import time

import torch

from python_jev.training.inference import CLASS_TO_UPPER, batch_from_projection, select_slot

CLOSEDLOOP_BENCHMARK_VERSION = "closedloop-benchmark-v0.1.0"
JEV_DRIVER_VERSION = "jev-closedloop-driver-v0.1.0"
MAX_BENCH_TURNS = 30


class JevDriver:
    """Greedy masked JevPolicyV0 driver with the blue/red action interface."""

    def __init__(self, model, device, blue_ctx, red_ctx, on_decision=None,
                 mask_fn=None) -> None:
        self.model = model
        self.device = device
        self.ctx = {"blue": blue_ctx, "red": red_ctx}
        self.skill_counts: dict[str, dict[int, int]] = {"blue": {}, "red": {}}
        self.exec_status: dict[str, dict[str, int]] = {"blue": {}, "red": {}}
        self.decisions = 0
        # F0 audit hooks (additive; both default to the frozen T0 behavior):
        # on_decision receives one dict per JEV decision (or None to disable);
        # mask_fn overrides the legality mask (or None for the frozen mask).
        self.on_decision = on_decision
        self.mask_fn = mask_fn

    def _act(self, battle, unit_id: str, side: str) -> dict:
        from python_jev.training.projection import project_for_training
        from python_sim.observation.projector import ObservationProjector
        from python_sim.skills import observation_safe_skill_mask
        from python_sim.skills.registry import execute_skill

        u = battle.world.units.get(unit_id)
        if u is None or u.action_ended:
            return {"success": False, "error": "no unit or ended"}
        cls_upper = CLASS_TO_UPPER.get(u.unit_class)
        if cls_upper is None:  # HQ / non-learned: hold through the seam
            return battle.do_hold(unit_id, side)
        if self.mask_fn is None:
            legal = [bool(x) for x in observation_safe_skill_mask(battle, unit_id)]
        else:
            legal = [bool(x) for x in self.mask_fn(battle, unit_id, self.ctx[side])]
        mask_state_version = battle.world.state_version
        proj = project_for_training(
            ObservationProjector(battle), side, unit_id, self.ctx[side])
        batch = batch_from_projection(proj, legal)
        sel = select_slot(self.model, batch, self.device)
        slot = sel["selected_slot"][0]
        self.decisions += 1
        if slot < 0:
            self.exec_status[side]["ALL_ILLEGAL"] = self.exec_status[side].get("ALL_ILLEGAL", 0) + 1
            res = battle.do_hold(unit_id, side)
            if self.on_decision is not None:
                self.on_decision({"side": side, "actor_id": unit_id,
                                  "skill_class": cls_upper, "slot": -1,
                                  "legal": legal, "envelope": None,
                                  "mask_state_version": mask_state_version,
                                  "decision_index": self.decisions})
            return res
        env = execute_skill(battle, unit_id, cls_upper, slot, self.ctx[side])
        self.skill_counts[side][slot] = self.skill_counts[side].get(slot, 0) + 1
        st = str(env.get("status", "UNKNOWN"))
        self.exec_status[side][st] = self.exec_status[side].get(st, 0) + 1
        if self.on_decision is not None:
            self.on_decision({"side": side, "actor_id": unit_id,
                              "skill_class": cls_upper, "slot": slot,
                              "legal": legal, "envelope": env,
                              "mask_state_version": mask_state_version,
                              "decision_index": self.decisions})
        return {"success": st in ("SUCCESS", "PARTIAL"), "skill_slot": slot,
                "status": st, "envelope": env}

    def blue_action(self, battle, unit_id: str) -> dict:
        return self._act(battle, unit_id, "blue")

    def red_action(self, battle, unit_id: str) -> dict:
        return self._act(battle, unit_id, "red")


def _start_totals(scenario: dict) -> dict:
    blue = sum(f.get("soldiers", 0) for f in scenario["forces"] if f["faction"] == "blue")
    red = sum(f.get("soldiers", 0) for f in scenario["forces"] if f["faction"] == "red")
    return {"blue": blue, "red": red}


def _side_order_ids(battle, side: str) -> list[str]:
    return sorted(u.id for u in battle.world.units.values() if u.faction == side)


def run_battle(scenario: dict, profile: str, blue_driver, red_driver,
               max_turns: int = MAX_BENCH_TURNS, seed: int = 0) -> dict:
    """Play one battle to terminal (or turn cap). Drivers expose the
    blue_action/red_action interface used by the rollout engine."""
    from python_sim.sim.battle import Battle

    battle = Battle(copy.deepcopy(scenario), profile, seed=seed)
    start = _start_totals(scenario)
    decisions = 0
    t0 = time.perf_counter()
    while battle.world.current_turn <= max_turns:
        if battle.evaluate_mission()["mission_status"] != "ongoing":
            break
        for side, driver, method in (
                ("blue", blue_driver, "blue_action"), ("red", red_driver, "red_action")):
            for uid in _side_order_ids(battle, side):
                u = battle.world.units.get(uid)
                if u is None or u.garrisoned or u.soldier_count <= 0:
                    continue
                if battle.executor.is_unit_data_turn_resolved(u.to_dict()):
                    continue
                getattr(driver, method)(battle, uid)
                decisions += 1
            if battle.evaluate_mission()["mission_status"] != "ongoing":
                break
        battle.sim_end_turn()
    mission = battle.evaluate_mission()
    blue_alive = sum(u.soldier_count for u in battle.world.units.values() if u.faction == "blue")
    red_alive = sum(u.soldier_count for u in battle.world.units.values() if u.faction == "red")
    hq_alive = any(u.unit_class == "hq" and u.faction == "blue" and u.soldier_count > 0
                   for u in battle.world.units.values())
    return {
        "scenario_id": scenario["scenario_id"],
        "profile": profile,
        "mission_status": mission["mission_status"],
        "termination_reason": mission.get("termination_reason"),
        "expired": mission["mission_status"] == "expired",
        "mission_completed": mission["mission_status"] in ("victory", "defeat"),
        "blue_victory": mission["mission_status"] == "victory",
        "turns": int(battle.world.current_turn),
        "decisions": decisions,
        "blue_start": start["blue"],
        "red_start": start["red"],
        "blue_alive": blue_alive,
        "red_alive": red_alive,
        "blue_lost": start["blue"] - blue_alive,
        "red_lost": start["red"] - red_alive,
        "hq_alive": hq_alive,
        "blue_formations_alive": mission["blue_formations_alive"],
        "red_formations_alive": mission["red_formations_alive"],
        "capital": mission.get("capital", {}),
        "wall_seconds": time.perf_counter() - t0,
    }


def run_pair(scenario: dict, profile: str, jev_factory, baseline_factory,
             seed: int = 0) -> dict:
    """Side-swapped pair on one scenario. Factories take no args and return
    fresh (driver, stats_dict) tuples."""
    blue_jev, stats_a = jev_factory()
    red_base, _ = baseline_factory()
    battle_a = run_battle(scenario, profile, blue_jev, red_base, seed=seed)
    battle_a["jev_side"] = "blue"
    battle_a["jev_stats"] = stats_a
    battle_a["jev_victory"] = battle_a["blue_victory"]

    blue_base, _ = baseline_factory()
    red_jev, stats_b = jev_factory()
    battle_b = run_battle(scenario, profile, blue_base, red_jev, seed=seed)
    battle_b["jev_side"] = "red"
    battle_b["jev_stats"] = stats_b
    # mission verdicts are blue-centric: RED-side JEV wins on blue defeat
    battle_b["jev_victory"] = battle_b["mission_status"] == "defeat"
    return {"battle_a": battle_a, "battle_b": battle_b}


def summarize_battles(battles: list[dict]) -> dict:
    n = len(battles)
    if n == 0:
        return {"battles": 0}
    import statistics

    def mean(key):
        return sum(float(b.get(key, 0) or 0) for b in battles) / n

    def frac(key):
        return sum(1 for b in battles if b.get(key)) / n

    verdicts: dict[str, int] = {}
    for b in battles:
        verdicts[b["mission_status"]] = verdicts.get(b["mission_status"], 0) + 1
    skill: dict[int, int] = {}
    status: dict[str, int] = {}
    for b in battles:
        for side in ("blue", "red"):
            for slot, c in (b.get("jev_stats") or {}).get("skill_counts", {}).get(side, {}).items():
                skill[int(slot)] = skill.get(int(slot), 0) + int(c)
            for st, c in (b.get("jev_stats") or {}).get("exec_status", {}).get(side, {}).items():
                status[str(st)] = status.get(str(st), 0) + int(c)
    total_exec = sum(status.values()) or 1
    return {
        "battles": n,
        "verdicts": verdicts,
        "jev_victory_rate": frac("jev_victory"),
        "mission_completed_rate": frac("mission_completed"),
        "expired_rate": frac("expired"),
        "hq_survival_rate": frac("hq_alive"),
        "mean_turns": mean("turns"),
        "mean_decisions": mean("decisions"),
        "mean_blue_lost": mean("blue_lost"),
        "mean_red_lost": mean("red_lost"),
        "mean_blue_alive": mean("blue_alive"),
        "mean_red_alive": mean("red_alive"),
        "skill_distribution": {str(k): skill[k] for k in sorted(skill)},
        "exec_status": status,
        "invalid_rate": status.get("INVALID", 0) / total_exec,
        "partial_rate": status.get("PARTIAL", 0) / total_exec,
        "interrupted_rate": status.get("INTERRUPTED", 0) / total_exec,
    }


__all__ = [
    "CLOSEDLOOP_BENCHMARK_VERSION",
    "JEV_DRIVER_VERSION",
    "MAX_BENCH_TURNS",
    "JevDriver",
    "run_battle",
    "run_pair",
    "summarize_battles",
]
