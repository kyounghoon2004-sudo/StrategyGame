"""R1 same-seat closed-loop comparison (Part E).

Benchmark V1 protocol, one correction: the F0 runner scores a single JEV
model. Here BOTH the new selected checkpoint and the old seed43 checkpoint
run the full V1 suite (same 24 matched scenarios, same fixed red baselines,
mask v0.2.0), so NEW-vs-OLD-vs-baseline deltas are matched apples-to-apples.

Headline metrics are actor-relative (mission progress, casualty exchange):
terminal victory is scenario-determined and reported only for same-seat
BLUE conditions. No side-swapped win-rate claim appears anywhere —
SIDE_SWAPPED_TERMINAL_BENCHMARK = INVALID.
"""

from __future__ import annotations

import copy
import json
import os


def bench_jobs_24() -> list[tuple[str, int, str, bool]]:
    """The F0 stage-I matched job set: 12 IID test + 12 OOD scenarios."""
    from python_jev.training.dataset_gen import ood_plan, split_plan

    plan = split_plan(192)
    ood = ood_plan(48)
    test_idx = sorted(i for i in range(192) if plan[i]["split"] == "test")[:12]
    ood_idx = list(range(0, 48, 4))[:12]
    return ([("test", i, plan[i]["profile"], False) for i in test_idx]
            + [("generalization_test", i, ood[i]["profile"], True) for i in ood_idx])


def _strip_wall(cond: dict) -> dict:
    c = copy.deepcopy(cond)
    for b in c.get("battles", []):
        b.pop("wall_seconds", None)
    return c


def _blue_summary(report: dict, blue_policy: str) -> dict:
    return report["conditions"][f"blue={blue_policy}_vs_red=Simple"]["summary"]


def run_two_model_v1(new_model, old_model, device, out_dir: str,
                     mask_fn, log_fn=None) -> dict:
    """Run V1 for both models; write raw reports + the same-seat comparison."""
    from python_jev.feasibility.benchmark import BENCHMARK_V1_VERSION

    log = log_fn or (lambda m: print(m, flush=True))
    from python_jev.feasibility.benchmark import run_benchmark_v1

    jobs = bench_jobs_24()
    os.makedirs(out_dir, exist_ok=True)
    new_path = os.path.join(out_dir, "v1_new_model.json")
    old_path = os.path.join(out_dir, "v1_old_model.json")

    log("V1: NEW model, mask v0.2.0 (168 battles)")
    new_report = run_benchmark_v1(new_model, device, jobs, new_path,
                                  mask_fn=mask_fn, mask_tag="new")
    log("V1: OLD model, mask v0.2.0 (168 battles)")
    old_report = run_benchmark_v1(old_model, device, jobs, old_path,
                                  mask_fn=mask_fn, mask_tag="new")

    # matched-comparison proof: baseline-vs-baseline battles never touch the
    # JEV weights, so they must be bit-identical across the two runs.
    base_conds = [f"blue={p}_vs_red=Simple" for p in
                  ("SimpleAttackElseAdvancePolicy", "RandomLegalPolicy", "HoldPolicy")]
    identical = all(
        json.dumps(_strip_wall(new_report["conditions"][c]), sort_keys=True)
        == json.dumps(_strip_wall(old_report["conditions"][c]), sort_keys=True)
        for c in base_conds)

    blues: dict[str, dict] = {}
    blues["NEW_JEV"] = _blue_summary(new_report, "JEV")
    blues["OLD_JEV"] = _blue_summary(old_report, "JEV")
    for p in ("SimpleAttackElseAdvancePolicy", "RandomLegalPolicy", "HoldPolicy"):
        blues[p] = _blue_summary(new_report, p)

    def pick(s: dict) -> dict:
        return {
            "battles": s["battles"],
            "victory_rate_blue": s.get("victory_rate_blue"),
            "defeat_rate_blue": s.get("defeat_rate_blue"),
            "expired_rate": s["expired_rate"],
            "mean_turns": s["mean_turns"],
            "mean_decisions": s["mean_decisions"],
            "mean_mission_progress_delta_blue": s["mean_mission_progress_delta_blue"],
            "mean_mission_progress_turn_normalized_blue":
                s["mean_mission_progress_turn_normalized_blue"],
            "mean_exchange_blue_view": s["mean_exchange_blue_view"],
            "mean_blue_lost": s["mean_blue_lost"],
            "mean_red_lost": s["mean_red_lost"],
            "mean_objective_progress_delta_blue":
                s["mean_objective_progress_delta_blue"],
            "hq_survival_blue": s["hq_survival_blue"],
            "hq_survival_red": s["hq_survival_red"],
            "blue_invalid_rate": s.get("blue_invalid_rate"),
            "blue_partial_rate": s.get("blue_partial_rate"),
        }

    comparison = {
        "benchmark_version": BENCHMARK_V1_VERSION,
        "mask": "new (observation-safe-skill-mask-v0.2.0)",
        "comparability": ("same_seat_blue_terminal=VALID; "
                          "side_swapped_terminal=INVALID (blue-centric missions)"),
        "jobs": len(jobs),
        "matched_proof": {"baseline_conditions_identical": bool(identical)},
        "blue_vs_simple_red": {k: pick(v) for k, v in blues.items()},
        "deltas": {
            "NEW_minus_OLD": {
                k: blues["NEW_JEV"][k] - blues["OLD_JEV"][k]
                for k in ("mean_mission_progress_delta_blue",
                          "mean_exchange_blue_view",
                          "mean_objective_progress_delta_blue",
                          "mean_turns")
            },
            "NEW_minus_Simple": {
                k: blues["NEW_JEV"][k] - blues["SimpleAttackElseAdvancePolicy"][k]
                for k in ("mean_mission_progress_delta_blue",
                          "mean_exchange_blue_view",
                          "mean_objective_progress_delta_blue",
                          "mean_turns")
            },
            "OLD_minus_Simple": {
                k: blues["OLD_JEV"][k] - blues["SimpleAttackElseAdvancePolicy"][k]
                for k in ("mean_mission_progress_delta_blue",
                          "mean_exchange_blue_view",
                          "mean_objective_progress_delta_blue",
                          "mean_turns")
            },
        },
        "jev_blue_driver": {
            "new": {
                "exec_status": blues["NEW_JEV"].get("blue_driver_exec_status"),
                "skill_distribution":
                    blues["NEW_JEV"].get("blue_driver_skill_distribution"),
                "invalid_rate": blues["NEW_JEV"].get("blue_invalid_rate"),
                "partial_rate": blues["NEW_JEV"].get("blue_partial_rate"),
            },
            "old": {
                "exec_status": blues["OLD_JEV"].get("blue_driver_exec_status"),
                "skill_distribution":
                    blues["OLD_JEV"].get("blue_driver_skill_distribution"),
                "invalid_rate": blues["OLD_JEV"].get("blue_invalid_rate"),
                "partial_rate": blues["OLD_JEV"].get("blue_partial_rate"),
            },
        },
        "secondary_conditions": {
            tag: {
                "new": {k: v for k, v in new_report["conditions"][c]["summary"].items()
                        if k != "victory_rate_blue" or not c.startswith("red=")},
                "old": {k: v for k, v in old_report["conditions"][c]["summary"].items()
                        if k != "victory_rate_blue" or not c.startswith("red=")},
            }
            for tag, c in (("jev_vs_random_red", "blue=JEV_vs_red=RandomLegalPolicy"),
                           ("jev_vs_hold_red", "blue=JEV_vs_red=HoldPolicy"),
                           ("jev_red_descriptive",
                            "red=JEV_vs_blue=Simple_descriptive"))
        },
    }
    out_path = os.path.join(out_dir, "same_seat_comparison.json")
    with open(out_path, "w") as f:
        json.dump(comparison, f, indent=1, sort_keys=True)
    return {"new_report": new_path, "old_report": old_path,
            "comparison": out_path,
            "baselines_identical": bool(identical)}


__all__ = ["bench_jobs_24", "run_two_model_v1"]
