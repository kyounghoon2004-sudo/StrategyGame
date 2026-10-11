"""D0 stage orchestrator: collect -> teachers -> shift -> oracles -> criteria.

Usage (from the project root):
    python -m python_jev.diagnose.run_diagnostic
    python -m python_jev.diagnose.run_diagnostic --stages collect teachers

Read-only: no weight updates, no corpus generation for training, no Fog,
no RL. The final root-cause label is written by the engineer from the
computed criteria (see metrics/criteria.json), not fitted here.
"""

from __future__ import annotations

import json
import os
import sys

OUT_ROOT = os.path.join("artifacts", "jev_target_diagnostic_v0")
NEW_CHECKPOINT = os.path.join("artifacts", "jev_training_v1", "checkpoints", "seed43.pt")
OLD_CHECKPOINT = os.path.join("artifacts", "jev_training_v0", "checkpoints", "seed43.pt")
V1_CLOSEDLOOP = os.path.join("artifacts", "jev_training_v1", "closedloop")
V2_TRAIN_SHARD = os.path.join("artifacts", "jev_training_v1", "dataset", "train.pt")


def _write(path: str, obj: dict) -> None:
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=1, sort_keys=True)


def stage_collect(out_root: str = OUT_ROOT) -> dict:
    from python_jev.diagnose.collect import (
        N_WORKERS,
        collect_job,
        matched_jobs,
        save_distribution_set,
        verify_iid_test_against_shard,
    )
    from python_jev.diagnose.collect import SETS as _SETS

    print("STAGE collect: 5 policies x 60 matched scenarios", flush=True)
    from concurrent.futures import ProcessPoolExecutor

    jobs = matched_jobs()
    print(f"  {len(jobs)} scenarios, sets={['simple', 'random', 'hold', 'jev_old', 'jev_new']}",
          flush=True)
    work = [(s, i, p, o, sp, OLD_CHECKPOINT, NEW_CHECKPOINT)
            for s in ("simple", "random", "hold", "jev_old", "jev_new")
            for (i, p, o, sp) in jobs]
    by_set: dict[str, list[dict]] = {s: [] for s in
                                     ("simple", "random", "hold", "jev_old", "jev_new")}
    skipped: dict[str, int] = {}
    with ProcessPoolExecutor(max_workers=N_WORKERS) as pool:
        for n, res in enumerate(pool.map(collect_job, work)):
            by_set[res["set"]].extend(res["rows"])
            skipped[res["scenario_id"]] = res["skipped_all_illegal"]
            if (n + 1) % 60 == 0:
                print(f"  jobs {n + 1}/{len(work)}", flush=True)
    for s in by_set:
        by_set[s].sort(key=lambda r: (r["scenario_id"], r["trajectory_step"]))
        print(f"  {s}: {len(by_set[s])} states", flush=True)
    dist_dir = os.path.join(out_root, "distributions")
    manifest_sets = {}
    for s, rows in by_set.items():
        manifest_sets[s] = save_distribution_set(
            os.path.join(dist_dir, f"{s}.pt"), s, rows)
    test_rows = [dict(r, set="iid_test") for r in by_set["simple"] if r["split"] == "test"]
    test_rows.sort(key=lambda r: (r["scenario_id"], r["trajectory_step"]))
    manifest_sets["iid_test"] = save_distribution_set(
        os.path.join(dist_dir, "iid_test.pt"), "iid_test", test_rows)
    print(f"  iid_test: {len(test_rows)} states (derived, test-only simple rows)",
          flush=True)
    check = verify_iid_test_against_shard(
        os.path.join(dist_dir, "iid_test.pt"),
        os.path.join("artifacts", "jev_training_v1", "dataset", "test.pt"))
    print(f"  iid_test shard verification: {check}", flush=True)
    manifest = {"sets": manifest_sets, "skipped_all_illegal_per_scenario": skipped,
                "iid_test_verification": check}
    _write(os.path.join(dist_dir, "manifest.json"), manifest)
    return manifest


def stage_teachers(out_root: str = OUT_ROOT) -> dict:
    from python_jev.diagnose import teachers as T

    print("STAGE teachers: cross-dist, matrix, regret, robustness, candidates",
          flush=True)
    dist_dir = os.path.join(out_root, "distributions")
    out = {}
    out["cross_dist"] = T.cross_distribution(dist_dir)
    _write(os.path.join(out_root, "metrics", "cross_dist.json"), out["cross_dist"])
    for s, m in out["cross_dist"]["sets"].items():
        print(f"  {s}: new_reg={m['new']['regret']['mean']:.5f} "
              f"old_reg={m['old']['regret']['mean']:.5f}", flush=True)
    out["matrix"] = T.teacher_matrix(dist_dir)
    _write(os.path.join(out_root, "teacher_matrix", "matrix.json"), out["matrix"])
    out["cross_regret"] = T.cross_teacher_regret(dist_dir)
    _write(os.path.join(out_root, "teacher_matrix", "cross_regret.json"),
           out["cross_regret"])
    out["robustness"] = T.jev_robustness(dist_dir)
    _write(os.path.join(out_root, "teacher_matrix", "robustness.json"),
           out["robustness"])
    out["candidates"] = T.candidate_targets(dist_dir)
    _write(os.path.join(out_root, "candidate_targets", "candidates.json"),
           out["candidates"])
    return out


def stage_shift(out_root: str = OUT_ROOT) -> dict:
    from python_jev.diagnose import shift as S

    print("STAGE shift: features, latent NN, trajectory depth", flush=True)
    dist_dir = os.path.join(out_root, "distributions")
    out = {}
    out["features"] = S.feature_stats(dist_dir)
    _write(os.path.join(out_root, "covariate_shift", "features.json"), out["features"])
    for row in out["features"]["comparisons"]["iid_test_vs_jev_new"][:6]:
        print(f"  shift {row['feature']}: d={row['cohens_d']:+.3f}", flush=True)
    out["latent"] = S.latent_diagnostic(dist_dir, NEW_CHECKPOINT, V2_TRAIN_SHARD)
    _write(os.path.join(out_root, "covariate_shift", "latent.json"), out["latent"])
    for s, v in out["latent"]["sets"].items():
        print(f"  latent NN {s}: mean={v['mean']:.3f}", flush=True)
    out["depth"] = S.trajectory_depth(dist_dir)
    _write(os.path.join(out_root, "trajectory_depth", "depth.json"), out["depth"])
    for s in ("jev_new", "jev_old", "simple"):
        d = out["depth"][s]
        print(f"  depth {s}: 0-4={d['0-4']['mean']} 20+={d['20-+']['mean']} "
              f"trend={d['trend_late_minus_early']}", flush=True)
    return out


def stage_oracles(out_root: str = OUT_ROOT) -> dict:
    from python_jev.diagnose.oracles import run_oracle_subset

    print("STAGE oracles: greedy-Simple + greedy-2-teacher subset", flush=True)
    return run_oracle_subset(os.path.join(out_root, "oracle_closedloop"),
                             V1_CLOSEDLOOP,
                             log_fn=lambda m: print(f"  {m}", flush=True))


def stage_criteria(out_root: str = OUT_ROOT) -> dict:
    """Decision quantities for the root-cause call (no label fitted)."""

    def load(rel: str) -> dict:
        with open(os.path.join(out_root, rel), encoding="utf-8") as f:
            return json.load(f)

    cross = load("metrics/cross_dist.json")["sets"]
    depth = load("trajectory_depth/depth.json")
    xreg = load("teacher_matrix/cross_regret.json")["pooled"]
    cand = load("candidate_targets/candidates.json")
    oracle = load("oracle_closedloop/report.json")
    latent = load("covariate_shift/latent.json")["sets"]

    def subset_means(entry: dict) -> dict:
        s = entry["summary"]
        return {"dM": s["mean_mission_progress_delta_blue"],
                "exch": s["mean_exchange_blue_view"],
                "vict": s.get("victory_rate_blue")}

    criteria = {
        "iid_new_regret": cross["iid_test"]["new"]["regret"]["mean"],
        "jev_new_visited_regret": cross["jev_new"]["new"]["regret"]["mean"],
        "jev_old_visited_regret_new_model": cross["jev_old"]["new"]["regret"]["mean"],
        "visited_over_iid_ratio": (
            cross["jev_new"]["new"]["regret"]["mean"]
            / max(1e-12, cross["iid_test"]["new"]["regret"]["mean"])),
        "depth_trend_jev_new": depth["jev_new"]["trend_late_minus_early"],
        "depth_trend_jev_old": depth["jev_old"]["trend_late_minus_early"],
        "depth_trend_simple": depth["simple"]["trend_late_minus_early"],
        "cross_teacher_regret_means": {k: v["mean"] for k, v in xreg.items()},
        "jsd_mean_jev_new": cand["jev_new"]["jsd"]["mean"],
        "jsd_mean_iid": cand["iid_test"]["jsd"]["mean"],
        "top_change_A_to_B_jev_new": cand["jev_new"]["top_change_A_to_B"],
        "latent_nn_mean": {s: v["mean"] for s, v in latent.items()},
        "oracle_subset": {
            "greedy_simple": subset_means(oracle["oracles"]["CounterfactualGreedySimple"]),
            "greedy_2teacher": subset_means(
                oracle["oracles"]["CounterfactualGreedy2Teacher"]),
            "ref_new_jev": subset_means(oracle["reference"]["NEW_JEV"]),
            "ref_simple": subset_means(oracle["reference"]["Simple"]),
        },
        "oracle_invalid_total": sum(
            o["summary"]["blue_driver_exec_status"].get("INVALID", 0)
            for o in oracle["oracles"].values()),
    }
    _write(os.path.join(out_root, "metrics", "criteria.json"), criteria)
    print(json.dumps(criteria, indent=1), flush=True)
    return criteria


STAGES = {
    "collect": stage_collect,
    "teachers": stage_teachers,
    "shift": stage_shift,
    "oracles": stage_oracles,
    "criteria": stage_criteria,
}


def main(argv: list[str] | None = None) -> dict:
    argv = list(sys.argv[1:] if argv is None else argv)
    want: list[str] = list(STAGES)
    if "--stages" in argv:
        want = [w for w in argv[argv.index("--stages") + 1:] if w in STAGES]
    print(f"out={OUT_ROOT} stages={want}", flush=True)
    results: dict = {}
    for name in want:
        results[name] = STAGES[name]()
    return results


if __name__ == "__main__":
    main()
