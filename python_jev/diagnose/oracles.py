"""D0 Parts K–L — counterfactual greedy oracle closed-loop diagnostics.

Two expensive diagnostic-only policies on a SMALL matched 6-scenario
subset (4 test + 2 OOD, the head of the R1 bench set), each as BLUE vs
fixed Simple red under mask v0.2.0:

  CounterfactualGreedySimple    — argmax Q_simple over executable actions
  CounterfactualGreedy2Teacher  — argmax of (P_simple + P_random) / 2

Compared against the already-recorded NEW JEV / OLD JEV / Simple BLUE
battles on the SAME scenario ids (no rerun, no side-swap claims).
"""

from __future__ import annotations

import copy
import json
import os

ORACLE_VERSION = "counterfactual-greedy-oracle-v0.1.0"


def oracle_subset_jobs() -> list[tuple[str, int, str, bool]]:
    """First 4 test + first 2 OOD jobs of the frozen R1 bench set."""
    from python_jev.retrain.closedloop_v1 import bench_jobs_24

    jobs = bench_jobs_24()
    test = [j for j in jobs if j[0] == "test"][:4]
    ood = [j for j in jobs if j[0] == "generalization_test"][:2]
    return test + ood


class _GreedyBase:
    def __init__(self, blue_ctx, red_ctx, scenario_seed: int) -> None:
        from python_sim.rollout.engine import CounterfactualEngine

        self.ctx = {"blue": blue_ctx, "red": red_ctx}
        self.engines = {
            "SimpleAttackElseAdvancePolicy": CounterfactualEngine.from_name(
                "SimpleAttackElseAdvancePolicy", 8, scenario_seed),
        }
        self.exec_status: dict[str, int] = {}
        self.decisions = 0

    def _select(self, battle, actor_id: str, side: str, legal: list[bool]) -> int:
        raise NotImplementedError

    def _act(self, battle, unit_id: str, side: str) -> dict:
        from python_jev.training.inference import CLASS_TO_UPPER
        from python_sim.skills.registry import execute_skill

        from python_jev.retrain.rebuild_v2 import new_mask_fn

        u = battle.world.units.get(unit_id)
        if u is None or u.action_ended:
            return {"success": False, "error": "no unit or ended"}
        cls_upper = CLASS_TO_UPPER.get(u.unit_class)
        if cls_upper is None:
            return battle.do_hold(unit_id, side)
        legal = [bool(x) for x in new_mask_fn(battle, unit_id, self.ctx[side])]
        if not any(legal):
            self.exec_status["ALL_ILLEGAL"] = self.exec_status.get("ALL_ILLEGAL", 0) + 1
            return battle.do_hold(unit_id, side)
        slot = self._select(battle, unit_id, side, legal)
        env = execute_skill(battle, unit_id, cls_upper, slot, self.ctx[side])
        st = str(env.get("status", "UNKNOWN"))
        self.exec_status[st] = self.exec_status.get(st, 0) + 1
        self.decisions += 1
        return {"success": st in ("SUCCESS", "PARTIAL"), "skill_slot": slot,
                "status": st, "envelope": env}

    def blue_action(self, battle, unit_id: str) -> dict:
        return self._act(battle, unit_id, "blue")

    def red_action(self, battle, unit_id: str) -> dict:
        return self._act(battle, unit_id, "red")


class CounterfactualGreedySimple(_GreedyBase):
    """Argmax Q_simple over mechanically executable actions."""

    def _select(self, battle, actor_id: str, side: str, legal: list[bool]) -> int:
        from python_jev.retrain.rebuild_v2 import new_mask_fn

        ev = self.engines["SimpleAttackElseAdvancePolicy"].evaluate(
            battle, actor_id, self.ctx[side], mask_fn=new_mask_fn)
        q = [float(ev.branches[s].outcome_scalar) if legal[s] else float("-inf")
             for s in range(6)]
        return max(range(6), key=lambda s: q[s])


class CounterfactualGreedy2Teacher(_GreedyBase):
    """Argmax of (P_simple + P_random) / 2 over executable actions."""

    def __init__(self, blue_ctx, red_ctx, scenario_seed: int) -> None:
        from python_sim.rollout.engine import CounterfactualEngine

        super().__init__(blue_ctx, red_ctx, scenario_seed)
        self.engines["RandomLegalPolicy"] = CounterfactualEngine.from_name(
            "RandomLegalPolicy", 8, scenario_seed)

    def _select(self, battle, actor_id: str, side: str, legal: list[bool]) -> int:
        from python_jev.retrain.rebuild_v2 import new_mask_fn
        from python_jev.training.policy_target import soft_targets_from_q

        qs = []
        for name in ("SimpleAttackElseAdvancePolicy", "RandomLegalPolicy"):
            ev = self.engines[name].evaluate(battle, actor_id, self.ctx[side],
                                             mask_fn=new_mask_fn)
            qs.append([(float(ev.branches[s].outcome_scalar) if legal[s] else None)
                       for s in range(6)])
        ps = [soft_targets_from_q(q, legal) for q in qs]
        mix = [(a + b) / 2.0 for a, b in zip(ps[0], ps[1])]
        return max([s for s in range(6) if legal[s]], key=lambda s: mix[s])


def run_oracle_subset(out_dir: str, v1_closedloop_dir: str,
                      log_fn=None) -> dict:
    """Run both oracles on the subset; compare vs recorded V1 battles."""
    from python_jev.feasibility.benchmark import run_v1_battle, summarize_v1
    from python_jev.training.scenarios import generate_scenario, mission_context_for_side
    from python_sim.policies import SimpleAttackElseAdvancePolicy
    from python_sim.skills.context import MissionContext

    log = log_fn or (lambda m: print(m, flush=True))
    jobs = oracle_subset_jobs()
    scenario_ids = [generate_scenario(i, ood=o)["scenario"]["scenario_id"]
                    for _p, i, _pr, o in jobs]
    log(f"oracle subset: {scenario_ids}")

    report: dict = {"oracle_version": ORACLE_VERSION,
                    "mask": "observation-safe-skill-mask-v0.2.0",
                    "subset_scenario_ids": scenario_ids,
                    "oracles": {}, "reference": {}}
    for name, cls in (("CounterfactualGreedySimple", CounterfactualGreedySimple),
                      ("CounterfactualGreedy2Teacher", CounterfactualGreedy2Teacher)):
        battles = []
        exec_total: dict[str, int] = {}
        for _pool, index, profile, ood in jobs:
            scenario = generate_scenario(index, ood=ood)["scenario"]
            blue = cls(MissionContext(**mission_context_for_side(scenario, "blue")),
                       MissionContext(**mission_context_for_side(scenario, "red")),
                       scenario["seed"])
            b = run_v1_battle(copy.deepcopy(scenario), profile, blue,
                              SimpleAttackElseAdvancePolicy(),
                              seed=scenario["seed"], blue_label=name,
                              red_label="SimpleAttackElseAdvancePolicy")
            b["blue_driver_exec_status"] = dict(blue.exec_status)
            for k, v in blue.exec_status.items():
                exec_total[k] = exec_total.get(k, 0) + v
            battles.append(b)
            log(f"  {name}: {scenario['scenario_id']} {b['mission_status']} "
                f"dM={b['mission_progress_delta_blue']:+.3f} "
                f"exch={b['exchange_blue_view']:+.0f}")
        summary = summarize_v1(battles)
        summary["blue_driver_exec_status"] = exec_total
        summary["blue_invalid_count"] = exec_total.get("INVALID", 0)
        report["oracles"][name] = {"summary": summary, "battles": battles}

    with open(os.path.join(v1_closedloop_dir, "v1_new_model.json"), encoding="utf-8") as f:
        v1_new = json.load(f)
    with open(os.path.join(v1_closedloop_dir, "v1_old_model.json"), encoding="utf-8") as f:
        v1_old = json.load(f)
    refs = {
        "NEW_JEV": v1_new["conditions"]["blue=JEV_vs_red=Simple"]["battles"],
        "OLD_JEV": v1_old["conditions"]["blue=JEV_vs_red=Simple"]["battles"],
        "Simple": v1_new["conditions"][
            "blue=SimpleAttackElseAdvancePolicy_vs_red=Simple"]["battles"],
    }
    for name, battles in refs.items():
        sub = [b for b in battles if b["scenario_id"] in scenario_ids]
        assert len(sub) == len(scenario_ids), (name, len(sub))
        report["reference"][name] = {"summary": summarize_v1(sub),
                                     "scenario_ids": [b["scenario_id"] for b in sub]}
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "report.json"), "w", encoding="utf-8") as f:
        json.dump(report, f, indent=1, sort_keys=True)
    return report


__all__ = ["ORACLE_VERSION", "CounterfactualGreedy2Teacher",
           "CounterfactualGreedySimple", "oracle_subset_jobs",
           "run_oracle_subset"]
