"""F0 stage orchestrator (CPU inference; see run_audit._device rationale).

Usage (from the project root):
    python -m python_jev.feasibility.run_feasibility            # all stages
    python -m python_jev.feasibility.run_feasibility --stages C D

Stages: C (mask comparison) · D (dataset audit) · G (epsilon) ·
        H (sensitivity) · X (tactical exam rerun) · I (V1 benchmark old+new).
"""

from __future__ import annotations

import json
import os
import sys

import torch

from python_jev.feasibility.run_audit import _device  # noqa: F401 (shared policy)

CHECKPOINT = os.path.join("artifacts", "jev_training_v0", "checkpoints", "seed43.pt")
OUT_ROOT = os.path.join("artifacts", "jev_feasibility_v0")


def _load_model(device: str):
    from python_jev.model import JevPolicyV0
    from python_jev.training.checkpoint import load_checkpoint

    model = JevPolicyV0().to(device)
    load_checkpoint(CHECKPOINT, model)
    model.eval()
    return model


def _bench_jobs():
    from python_jev.training.dataset_gen import ood_plan, split_plan

    plan = split_plan(192)
    ood = ood_plan(48)
    test_idx = sorted(i for i in range(192) if plan[i]["split"] == "test")[:12]
    ood_idx = list(range(0, 48, 4))[:12]
    return ([("test", i, plan[i]["profile"], False) for i in test_idx]
            + [("generalization_test", i, ood[i]["profile"], True) for i in ood_idx])


def stage_c(model, device):
    from python_jev.feasibility.reeval import run_mask_comparison
    from python_jev.training.dataset_gen import ood_plan, split_plan

    print("STAGE C: old-vs-new mask comparison", flush=True)
    plan = split_plan(192)
    ood = ood_plan(48)
    test_idx = sorted(i for i in range(192) if plan[i]["split"] == "test")
    ood_idx = list(range(0, 48, 4))[:12]
    jobs = ([("test", i, plan[i]["profile"], False) for i in test_idx]
            + [("generalization_test", i, ood[i]["profile"], True) for i in ood_idx])
    out = os.path.join(OUT_ROOT, "mask_comparison", "old_vs_new.json")
    rep = run_mask_comparison(model, device, jobs, out)
    print(json.dumps(rep["summary"], indent=1), flush=True)
    return rep["summary"]


def stage_d():
    from python_jev.feasibility.reeval import run_dataset_audit

    print("STAGE D: dataset audit (read-only)", flush=True)
    shards = [os.path.join("artifacts", "jev_training_v0", "dataset", f"{s}.pt")
              for s in ("train", "validation", "test", "generalization_test")]
    out = os.path.join(OUT_ROOT, "mask_comparison", "dataset_audit.json")
    summary = run_dataset_audit(shards, out)
    print(json.dumps(summary, indent=1), flush=True)
    return summary


def stage_g(model, device):
    from python_jev.feasibility.epsilon_audit import run_epsilon_audit
    from python_jev.model import JevPolicyV0

    print("STAGE G: epsilon audit", flush=True)
    torch.manual_seed(0)
    untrained = JevPolicyV0().to(device).eval()
    out = os.path.join(OUT_ROOT, "benchmark", "epsilon_audit.json")
    rep = run_epsilon_audit(
        model, untrained,
        os.path.join("artifacts", "jev_training_v0", "dataset", "test.pt"),
        device, out)
    print(json.dumps({k: rep[k] for k in ("trained", "untrained", "discrimination")},
                     indent=1), flush=True)
    return rep


def stage_h():
    from python_jev.feasibility.sensitivity import run_sensitivity
    from python_jev.training.dataset_gen import split_plan
    from python_jev.training.scenarios import generate_scenario

    print("STAGE H: continuation sensitivity", flush=True)
    plan = split_plan(192)
    test_idx = sorted(i for i in range(192) if plan[i]["split"] == "test")
    by_mission: dict[str, list[int]] = {}
    for i in test_idx:
        m = generate_scenario(i)["scenario"]["mission_contract"]["primary_objective"]
        by_mission.setdefault(m, []).append(i)
    idx = [i for m in sorted(by_mission) for i in by_mission[m][:4]]
    jobs = [(i, plan[i]["profile"], False) for i in idx]
    out = os.path.join(OUT_ROOT, "continuation_sensitivity", "sensitivity.json")
    rep = run_sensitivity(jobs, out)
    print(json.dumps({"states": rep["states"], "overall": rep["overall"]}, indent=1),
          flush=True)
    return rep


def stage_x(model, device):
    import copy

    from python_jev.training.exam import build_exam_cases, run_exam
    from python_jev.training.inference import batch_from_projection, select_slot
    from python_jev.feasibility.reeval import new_mask_fn
    from python_sim.observation.projector import ObservationProjector
    from python_sim.sim.battle import Battle
    from python_sim.skills.context import MissionContext
    from python_sim.skills.registry import execute_skill

    print("STAGE X: tactical exam rerun (old + new masks)", flush=True)
    out: dict = {}
    for tag, mask in (("old", None), ("new", new_mask_fn)):
        cases = build_exam_cases()
        rep = run_exam(model, device, copy.deepcopy(cases), mask_fn=mask)
        # executor-invalid rate of the JEV selections (exam ctx, same cases)
        invalid = total = 0
        per_class: dict[str, dict[str, int]] = {}
        for case, scored in zip(cases, rep["cases"]):
            scenario = copy.deepcopy(case["scenario"])
            battle = Battle(scenario, case["profile"], seed=scenario["seed"])
            mc = scenario["mission_contract"]
            ctx = MissionContext(
                scenario_id=scenario["scenario_id"],
                primary_objective=mc["primary_objective"],
                turn_limit=mc["turn_limit"],
                advance_anchor=(scenario["forces"][2]["q"], scenario["forces"][2]["r"]),
                withdraw_anchor=(scenario["forces"][0]["q"], scenario["forces"][0]["r"]))
            slot = scored["selected_slot"]
            env = execute_skill(battle, case["actor_id"], case["actor_class"], slot, ctx)
            total += 1
            cell = per_class.setdefault(case["actor_class"], {"invalid": 0, "total": 0})
            cell["total"] += 1
            if env.get("status") == "INVALID":
                invalid += 1
                cell["invalid"] += 1
        out[tag] = {"summary": rep["summary"], "invalid_rate": invalid / max(1, total),
                    "invalid_by_class": per_class, "cases": rep["cases"]}
        print(f"  exam/{tag}: mean_regret={rep['summary']['overall']['mean_regret']:.4f} "
              f"invalid={invalid}/{total}", flush=True)
    path = os.path.join(OUT_ROOT, "benchmark", "exam_rerun.json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(out, f, indent=1, sort_keys=True)
    return {k: {"overall": v["summary"]["overall"], "invalid_rate": v["invalid_rate"],
               "invalid_by_class": v["invalid_by_class"]} for k, v in out.items()}


def stage_i(model, device):
    from python_jev.feasibility.benchmark import run_benchmark_v1
    from python_jev.feasibility.reeval import new_mask_fn

    print("STAGE I: V1 benchmark OLD mask", flush=True)
    jobs = _bench_jobs()
    old_path = os.path.join(OUT_ROOT, "benchmark", "v1_old_mask.json")
    run_benchmark_v1(model, device, jobs, old_path, mask_fn=None, mask_tag="old")
    print("STAGE I: V1 benchmark NEW mask", flush=True)
    new_path = os.path.join(OUT_ROOT, "benchmark", "v1_new_mask.json")
    rep = run_benchmark_v1(model, device, jobs, new_path, mask_fn=new_mask_fn,
                           mask_tag="new")
    for cond, data in rep["conditions"].items():
        s = data["summary"]
        print(f"  {cond}: battles={s['battles']} "
              f"victB={s.get('victory_rate_blue', float('nan')):.3f} "
              f"dM={s['mean_mission_progress_delta_blue']:+.3f} "
              f"exch={s['mean_exchange_blue_view']:+.0f}", flush=True)
    return {"old": old_path, "new": new_path}


STAGES = {"C": stage_c, "D": stage_d, "G": stage_g, "H": stage_h,
          "X": stage_x, "I": stage_i}


def main(argv: list[str] | None = None) -> dict:
    argv = list(sys.argv[1:] if argv is None else argv)
    want: list[str] = ["C", "D", "G", "H", "X", "I"]
    if "--stages" in argv:
        want = argv[argv.index("--stages") + 1:]
        want = [w for w in want if w in STAGES]
    device = _device()
    print(f"device={device} checkpoint={CHECKPOINT} stages={want}", flush=True)
    model = _load_model(device) if any(s in want for s in ("C", "G", "X", "I")) else None
    results: dict = {}
    if "C" in want:
        results["C"] = stage_c(model, device)
    if "D" in want:
        results["D"] = stage_d()
    if "G" in want:
        results["G"] = stage_g(model, device)
    if "H" in want:
        results["H"] = stage_h()
    if "X" in want:
        results["X"] = stage_x(model, device)
    if "I" in want:
        results["I"] = stage_i(model, device)
    return results


if __name__ == "__main__":
    main()
