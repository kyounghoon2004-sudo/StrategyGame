"""Benchmark entry (T0, Parts F+G): tactical exam + closed-loop battles.

- Exam: 60 simulator-grounded vignettes, trained vs untrained.
- Closed-loop: side-swapped pairs (JEV vs {Random, Simple, Hold}) on unseen
  IID test scenarios and OOD scenarios. No training during battles.
Each section writes its JSON as it completes (incremental, rerunnable).
"""

from __future__ import annotations

import copy
import json
import os

import torch

from python_jev.model import JevPolicyV0
from python_jev.training.checkpoint import load_checkpoint
from python_jev.training.closedloop import (
    CLOSEDLOOP_BENCHMARK_VERSION,
    JevDriver,
    run_pair,
    summarize_battles,
)
from python_jev.training.dataset_gen import ood_plan, split_plan
from python_jev.training.exam import EXAM_VERSION, build_exam_cases, run_exam
from python_jev.training.scenarios import generate_scenario, mission_context_for_side
from python_sim.policies import HoldPolicy, RandomLegalPolicy, SimpleAttackElseAdvancePolicy
from python_sim.skills.context import MissionContext

BASELINES = ("RandomLegalPolicy", "SimpleAttackElseAdvancePolicy", "HoldPolicy")


def _baseline_factory(name: str):
    def make():
        if name == "RandomLegalPolicy":
            return RandomLegalPolicy(seed=123), {}
        if name == "SimpleAttackElseAdvancePolicy":
            return SimpleAttackElseAdvancePolicy(), {}
        if name == "HoldPolicy":
            return HoldPolicy(), {}
        raise KeyError(name)
    return make


def benchmark_closed_loop(model, device, out_path: str,
                          n_test: int = 12, n_ood: int = 12) -> dict:
    plan = split_plan(192)
    test_idx = sorted(i for i in range(192) if plan[i]["split"] == "test")[:n_test]
    ood = ood_plan(48)
    ood_idx = list(range(0, 48, 48 // n_ood))[:n_ood]
    jobs = [("test", i, plan[i]["profile"], False) for i in test_idx]
    jobs += [("generalization_test", i, ood[i]["profile"], True) for i in ood_idx]

    report: dict = {"benchmark_version": CLOSEDLOOP_BENCHMARK_VERSION,
                    "exam_version": EXAM_VERSION,
                    "model": "jev-policy-v0.1.0-fi",
                    "jobs": len(jobs), "results": {}}
    for base in BASELINES:
        base_factory = _baseline_factory(base)
        battles_all: list[dict] = []
        by_pool: dict[str, list[dict]] = {"test": [], "generalization_test": []}
        for pool, index, profile, is_ood in jobs:
            scenario = generate_scenario(index, ood=is_ood)["scenario"]

            def jev_factory(scn=scenario):
                blue_ctx = MissionContext(**mission_context_for_side(scn, "blue"))
                red_ctx = MissionContext(**mission_context_for_side(scn, "red"))
                drv = JevDriver(model, device, blue_ctx, red_ctx)
                stats = {"skill_counts": drv.skill_counts, "exec_status": drv.exec_status}
                return drv, stats

            pair = run_pair(copy.deepcopy(scenario), profile, jev_factory, base_factory,
                            seed=scenario["seed"])
            for battle in (pair["battle_a"], pair["battle_b"]):
                battle["pool"] = pool
                battle["baseline"] = base
                battle["scenario_index"] = index
                battles_all.append(battle)
                by_pool[pool].append(battle)
        report["results"][base] = {
            "overall": summarize_battles(battles_all),
            "test": summarize_battles(by_pool["test"]),
            "generalization_test": summarize_battles(by_pool["generalization_test"]),
            "battles": battles_all,
        }
        s = report["results"][base]["overall"]
        print(f"{base}: jev_win={s['jev_victory_rate']:.2f} "
              f"completed={s['mission_completed_rate']:.2f} expired={s['expired_rate']:.2f} "
              f"turns={s['mean_turns']:.1f} blue_lost={s['mean_blue_lost']:.0f} "
              f"red_lost={s['mean_red_lost']:.0f} invalid={s['invalid_rate']:.3f} "
              f"partial={s['partial_rate']:.3f}", flush=True)
    with open(out_path, "w") as f:
        json.dump(report, f, indent=1, sort_keys=True)
    return report


def main(out_root: str = "artifacts/jev_training_v0",
         checkpoint: str = "artifacts/jev_training_v0/checkpoints/seed43.pt") -> dict:
    device = "cuda" if torch.cuda.is_available() else "cpu"
    bench_dir = os.path.join(out_root, "benchmark")
    os.makedirs(bench_dir, exist_ok=True)

    model = JevPolicyV0().to(device)
    load_checkpoint(checkpoint, model)
    model.eval()
    torch.manual_seed(0)
    untrained = JevPolicyV0().to(device).eval()

    cases = build_exam_cases()
    exam_trained = run_exam(model, device, copy.deepcopy(cases))
    exam_untrained = run_exam(untrained, device, copy.deepcopy(cases))
    exam_report = {"trained": exam_trained["summary"], "untrained": exam_untrained["summary"],
                   "trained_cases": exam_trained["cases"]}
    with open(os.path.join(bench_dir, "exam.json"), "w") as f:
        json.dump(exam_report, f, indent=1, sort_keys=True)
    print("exam trained:", json.dumps(exam_report["trained"]["overall"], indent=1), flush=True)
    print("exam untrained:", json.dumps(exam_report["untrained"]["overall"], indent=1), flush=True)

    closed = benchmark_closed_loop(model, device, os.path.join(bench_dir, "closedloop.json"))
    return {"exam": exam_report, "closedloop": {
        b: {k: v for k, v in closed["results"][b].items() if k != "battles"}
        for b in closed["results"]}}


if __name__ == "__main__":
    main()
