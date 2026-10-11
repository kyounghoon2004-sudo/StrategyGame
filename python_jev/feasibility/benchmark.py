"""Benchmark V1 — corrected closed-loop benchmark (closed-loop-benchmark-v0.1.0).

Corrects the two T0 confounders without inventing game semantics:

1. Side-swapped TERMINAL win rates are INVALID under the current
   blue-centric mission contract (Part E finding): RED has no authoritative
   victory condition of its own, so "JEV-red victory rate" cannot measure
   policy quality. V1 reports terminal outcomes ONLY for same-seat BLUE
   comparisons (every policy as blue vs the same fixed red baseline on
   matched scenarios).

2. RED-seat / side-swapped battles are reported with actor-relative,
   non-terminal metrics only: mission-progress delta, casualty exchange,
   objective progress, invalid/partial rates, skill distribution,
   survival / HQ state, turn-normalized progress. Never combined into one
   scalar, never presented as win rates.

Comparability is a property of the COMPARISON (seat assignment + mission
semantics), pinned in MISSION_SEAT_SEMANTICS. If a future symmetric mission
contract freezes, its scenarios flip to terminal-comparable under side-swap
by changing that table — no invented semantics in this task.
"""

from __future__ import annotations

import copy
import os
import time

BENCHMARK_V1_VERSION = "closed-loop-benchmark-v0.1.0"
MAX_BENCH_TURNS = 30

# Pinned mission-seat semantics. All four VALID_OBJECTIVES are BLUE_CENTRIC:
# the authoritative evaluator scores the blue mission contract only
# (turn.py evaluate_mission). RED has no authoritative victory equivalent.
MISSION_SEAT_SEMANTICS = {
    "destroy_all_red": "BLUE_CENTRIC",
    "capture_capital": "BLUE_CENTRIC",
    "survive_turns": "BLUE_CENTRIC",
    "hold_hq": "BLUE_CENTRIC",
}


def scenario_comparability(scenario: dict) -> dict:
    """Terminal-comparability contract for one scenario.

    same_seat_blue: VALID — every policy can obtain victory/defeat/expired
        as blue under the authoritative evaluator.
    side_swapped_terminal: INVALID under BLUE_CENTRIC missions — the red
        seat has no authoritative victory condition (see Part E audit).
    """
    mission = str(scenario.get("mission_contract", {}).get("primary_objective", ""))
    semantics = MISSION_SEAT_SEMANTICS.get(mission, "UNKNOWN")
    swapped_valid = semantics == "SYMMETRIC"
    return {
        "benchmark_version": BENCHMARK_V1_VERSION,
        "mission": mission,
        "seat_semantics": semantics,
        "same_seat_blue_terminal": semantics in ("BLUE_CENTRIC", "SYMMETRIC"),
        "side_swapped_terminal": swapped_valid,
        "side_swapped_terminal_benchmark": "VALID" if swapped_valid else "INVALID",
    }


def run_v1_battle(scenario: dict, profile: str, blue_driver, red_driver,
                  max_turns: int = MAX_BENCH_TURNS, seed: int = 0,
                  blue_label: str = "blue", red_label: str = "red") -> dict:
    """One battle with full V1 metrics (mirrors closedloop.run_battle flow).

    Driver labels identify the POLICY in each seat (e.g. "JEV",
    "SimpleAttackElseAdvancePolicy"). Progress deltas use the frozen
    mission/objective progress contracts (blue perspective + red complement).
    """
    from python_sim.rollout.mission_progress import (
        mission_delta,
        mission_progress,
        mission_view_from_battle,
    )
    from python_sim.rollout.objective_progress import (
        objective_delta,
        objective_progress,
        objective_view_from_battle,
    )
    from python_sim.sim.battle import Battle

    battle = Battle(copy.deepcopy(scenario), profile, seed=seed)
    start_blue = sum(f.get("soldiers", 0) for f in scenario["forces"] if f["faction"] == "blue")
    start_red = sum(f.get("soldiers", 0) for f in scenario["forces"] if f["faction"] == "red")
    p0 = mission_progress(mission_view_from_battle(battle), "blue")
    o0 = objective_progress(objective_view_from_battle(battle), "blue")
    decisions = 0
    t0 = time.perf_counter()
    while battle.world.current_turn <= max_turns:
        if battle.evaluate_mission()["mission_status"] != "ongoing":
            break
        for side, driver, method in (
                ("blue", blue_driver, "blue_action"), ("red", red_driver, "red_action")):
            for uid in sorted(u.id for u in battle.world.units.values() if u.faction == side):
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
    blue_hq = any(u.unit_class == "hq" and u.faction == "blue" and u.soldier_count > 0
                  for u in battle.world.units.values())
    red_hq = any(u.unit_class == "hq" and u.faction == "red" and u.soldier_count > 0
                 for u in battle.world.units.values())
    p1 = mission_progress(mission_view_from_battle(battle), "blue")
    o1 = objective_progress(objective_view_from_battle(battle), "blue")
    turns = int(battle.world.current_turn)
    return {
        "benchmark_version": BENCHMARK_V1_VERSION,
        "scenario_id": scenario["scenario_id"],
        "profile": profile,
        "mission_type": str(scenario["mission_contract"]["primary_objective"]),
        "blue_policy": blue_label,
        "red_policy": red_label,
        "mission_status": mission["mission_status"],
        "termination_reason": mission.get("termination_reason"),
        "expired": mission["mission_status"] == "expired",
        "blue_victory": mission["mission_status"] == "victory",
        "blue_defeat": mission["mission_status"] == "defeat",
        "turns": turns,
        "decisions": decisions,
        "blue_start": start_blue,
        "red_start": start_red,
        "blue_alive": blue_alive,
        "red_alive": red_alive,
        "blue_lost": start_blue - blue_alive,
        "red_lost": start_red - red_alive,
        "exchange_blue_view": (start_red - red_alive) - (start_blue - blue_alive),
        "blue_hq_alive": blue_hq,
        "red_hq_alive": red_hq,
        "mission_progress_delta_blue": mission_delta(p1, p0),
        "mission_progress_delta_red": mission_delta(1.0 - p1, 1.0 - p0),
        "mission_progress_turn_normalized_blue": mission_delta(p1, p0) / max(1, turns),
        "objective_progress_delta_blue": objective_delta(o1, o0),
        "objective_progress_delta_red": objective_delta(1.0 - o1, 1.0 - o0),
        "blue_formations_alive": mission["blue_formations_alive"],
        "red_formations_alive": mission["red_formations_alive"],
        "wall_seconds": time.perf_counter() - t0,
    }


def _driver_stats(driver) -> dict:
    skills = getattr(driver, "skill_counts", {"blue": {}, "red": {}})
    execs = getattr(driver, "exec_status", {"blue": {}, "red": {}})
    flat_skills: dict[str, int] = {}
    flat_exec: dict[str, int] = {}
    for side in ("blue", "red"):
        for k, v in (skills.get(side) or {}).items():
            flat_skills[f"{side}:slot{k}"] = int(v)
        for k, v in (execs.get(side) or {}).items():
            flat_exec[f"{side}:{k}"] = int(v)
    total = sum(flat_exec.values()) or 0
    return {
        "skill_distribution": flat_skills,
        "exec_status": flat_exec,
        "invalid_rate": sum(v for k, v in flat_exec.items() if k.endswith(":INVALID")) / max(1, total),
        "partial_rate": sum(v for k, v in flat_exec.items() if k.endswith(":PARTIAL")) / max(1, total),
        "n_executions": total,
    }


def summarize_v1(battles: list[dict]) -> dict:
    """Distributions and averages — never one arbitrary scalar."""
    n = len(battles)
    if n == 0:
        return {"battles": 0}
    verdicts: dict[str, int] = {}
    for b in battles:
        verdicts[b["mission_status"]] = verdicts.get(b["mission_status"], 0) + 1

    def mean(key):
        return sum(float(b.get(key, 0) or 0) for b in battles) / n

    def frac(key):
        return sum(1 for b in battles if b.get(key)) / n

    return {
        "benchmark_version": BENCHMARK_V1_VERSION,
        "battles": n,
        "verdicts": verdicts,
        "victory_rate_blue": frac("blue_victory"),
        "defeat_rate_blue": frac("blue_defeat"),
        "expired_rate": frac("expired"),
        "hq_survival_blue": frac("blue_hq_alive"),
        "hq_survival_red": frac("red_hq_alive"),
        "mean_turns": mean("turns"),
        "mean_decisions": mean("decisions"),
        "mean_blue_lost": mean("blue_lost"),
        "mean_red_lost": mean("red_lost"),
        "mean_exchange_blue_view": mean("exchange_blue_view"),
        "mean_mission_progress_delta_blue": mean("mission_progress_delta_blue"),
        "mean_mission_progress_delta_red": mean("mission_progress_delta_red"),
        "mean_mission_progress_turn_normalized_blue": mean("mission_progress_turn_normalized_blue"),
        "mean_objective_progress_delta_blue": mean("objective_progress_delta_blue"),
        "mean_objective_progress_delta_red": mean("objective_progress_delta_red"),
    }


def run_benchmark_v1(model, device, jobs: list[tuple[str, int, str, bool]],
                     out_path: str, mask_fn=None, mask_tag: str = "old") -> dict:
    """V1 protocol (Part F/I): same-seat BLUE terminal comparisons plus
    RED-seat descriptive (non-terminal) metrics. mask_fn=None runs the
    frozen v0.1.0 mask (OLD benchmark); mask_fn=new runs mask v0.2.0.
    """
    import json as _json

    from python_jev.training.closedloop import JevDriver
    from python_jev.training.scenarios import generate_scenario, mission_context_for_side
    from python_sim.policies import HoldPolicy, RandomLegalPolicy, SimpleAttackElseAdvancePolicy
    from python_sim.skills.context import MissionContext

    base_ctor = {
        "RandomLegalPolicy": lambda: RandomLegalPolicy(seed=123),
        "SimpleAttackElseAdvancePolicy": lambda: SimpleAttackElseAdvancePolicy(),
        "HoldPolicy": lambda: HoldPolicy(),
    }

    def jev_driver(scenario):
        blue_ctx = MissionContext(**mission_context_for_side(scenario, "blue"))
        red_ctx = MissionContext(**mission_context_for_side(scenario, "red"))
        return JevDriver(model, device, blue_ctx, red_ctx, mask_fn=mask_fn)

    report: dict = {"benchmark_version": BENCHMARK_V1_VERSION, "mask": mask_tag,
                    "comparability": "same_seat_blue_terminal=VALID; "
                                     "side_swapped_terminal=INVALID (blue-centric missions)",
                    "conditions": {}}

    # A. PRIMARY — same-seat BLUE terminal: each policy as blue vs Simple red.
    for policy in ("JEV", "SimpleAttackElseAdvancePolicy", "RandomLegalPolicy", "HoldPolicy"):
        battles: list[dict] = []
        jev_stats_agg = {"skill_distribution": {}, "exec_status": {},
                         "invalid": 0, "partial": 0, "n": 0}
        for _pool, index, profile, ood in jobs:
            scenario = generate_scenario(index, ood=ood)["scenario"]
            if policy == "JEV":
                blue = jev_driver(scenario)
            else:
                blue = base_ctor[policy]()
            red = base_ctor["SimpleAttackElseAdvancePolicy"]()
            b = run_v1_battle(scenario, profile, blue, red, seed=scenario["seed"],
                              blue_label=policy, red_label="SimpleAttackElseAdvancePolicy")
            if policy == "JEV":
                st = _driver_stats(blue)
                b["blue_driver_stats"] = st
                for k, v in st["skill_distribution"].items():
                    jev_stats_agg["skill_distribution"][k] = \
                        jev_stats_agg["skill_distribution"].get(k, 0) + v
                for k, v in st["exec_status"].items():
                    jev_stats_agg["exec_status"][k] = jev_stats_agg["exec_status"].get(k, 0) + v
            battles.append(b)
        summary = summarize_v1(battles)
        if policy == "JEV":
            n = sum(jev_stats_agg["exec_status"].values()) or 1
            summary["blue_driver_exec_status"] = jev_stats_agg["exec_status"]
            summary["blue_driver_skill_distribution"] = jev_stats_agg["skill_distribution"]
            summary["blue_invalid_rate"] = sum(
                v for k, v in jev_stats_agg["exec_status"].items()
                if k.endswith(":INVALID")) / n
            summary["blue_partial_rate"] = sum(
                v for k, v in jev_stats_agg["exec_status"].items()
                if k.endswith(":PARTIAL")) / n
        report["conditions"][f"blue={policy}_vs_red=Simple"] = {
            "terminal_comparable": True, "summary": summary, "battles": battles}

    # B. SECONDARY — JEV blue vs other fixed red baselines (valid blue-seat,
    # compare within condition only).
    for red in ("RandomLegalPolicy", "HoldPolicy"):
        battles = []
        for _pool, index, profile, ood in jobs:
            scenario = generate_scenario(index, ood=ood)["scenario"]
            blue = jev_driver(scenario)
            b = run_v1_battle(scenario, profile, blue, base_ctor[red](),
                              seed=scenario["seed"], blue_label="JEV", red_label=red)
            b["blue_driver_stats"] = _driver_stats(blue)
            battles.append(b)
        report["conditions"][f"blue=JEV_vs_red={red}"] = {
            "terminal_comparable": True, "summary": summarize_v1(battles),
            "battles": battles}

    # C. DESCRIPTIVE — JEV red vs Simple blue: actor-relative metrics only.
    battles = []
    for _pool, index, profile, ood in jobs:
        scenario = generate_scenario(index, ood=ood)["scenario"]
        red = jev_driver(scenario)
        b = run_v1_battle(scenario, profile, base_ctor["SimpleAttackElseAdvancePolicy"](),
                          red, seed=scenario["seed"],
                          blue_label="SimpleAttackElseAdvancePolicy", red_label="JEV")
        b["red_driver_stats"] = _driver_stats(red)
        # Strip terminal claims from the red-seat view: the blue-centric
        # verdict must never be read as a red policy outcome.
        b["red_terminal_claim"] = "NOT_COMPARABLE"
        battles.append(b)
    red_summary = summarize_v1(battles)
    red_summary.pop("victory_rate_blue", None)
    red_summary.pop("defeat_rate_blue", None)
    red_summary["note"] = ("red-seat actor-relative metrics only; no terminal "
                           "win/loss claim (SIDE_SWAPPED_TERMINAL_BENCHMARK=INVALID)")
    report["conditions"]["red=JEV_vs_blue=Simple_descriptive"] = {
        "terminal_comparable": False, "summary": red_summary, "battles": battles}

    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, "w") as f:
        _json.dump(report, f, indent=1, sort_keys=True)
    return report


__all__ = [
    "BENCHMARK_V1_VERSION",
    "MAX_BENCH_TURNS",
    "MISSION_SEAT_SEMANTICS",
    "run_benchmark_v1",
    "run_v1_battle",
    "scenario_comparability",
    "summarize_v1",
]
