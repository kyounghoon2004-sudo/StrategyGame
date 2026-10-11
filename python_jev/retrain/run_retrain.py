"""R1 stage orchestrator: corrected-target retraining end to end.

Usage (from the project root):
    python -m python_jev.retrain.run_retrain                  # all stages
    python -m python_jev.retrain.run_retrain --stages dataset coverage
    python -m python_jev.retrain.run_retrain --stages train offline

Stages: dataset -> coverage -> overfit -> train -> offline -> closedloop
        -> exam -> sensitivity. Each stage writes its artifacts as it
        completes (incremental, rerunnable); later stages read earlier
        artifacts from disk.

Device: CPU by default (this workstation's GPU is shared with Godot
editors, under which CUDA transfers have been observed to wedge; see
feasibility run_audit._device). Override with R1_DEVICE=cuda.
"""

from __future__ import annotations

import json
import os
import sys

import torch

OUT_ROOT = os.path.join("artifacts", "jev_training_v1")
V01_ROOT = os.path.join("artifacts", "jev_training_v0")
OLD_CHECKPOINT = os.path.join(V01_ROOT, "checkpoints", "seed43.pt")
SEEDS = (42, 43, 44)


def _device() -> str:
    want = os.environ.get("R1_DEVICE", "cpu")
    if want == "cuda" and torch.cuda.is_available():
        return "cuda"
    return "cpu"


def _load_model(checkpoint: str, device: str):
    from python_jev.model import JevPolicyV0
    from python_jev.training.checkpoint import load_checkpoint

    model = JevPolicyV0().to(device)
    load_checkpoint(checkpoint, model)
    model.eval()
    return model


# ------------------------------------------------------------ stages
def stage_dataset(out_root: str = OUT_ROOT) -> dict:
    from python_jev.retrain.rebuild_v2 import reconstruct_dataset

    print("STAGE dataset: v0.1 -> v0.2 reconstruction", flush=True)
    manifest = reconstruct_dataset(
        os.path.join(V01_ROOT, "dataset"), out_root,
        log_fn=lambda m: print(f"  {m}", flush=True))
    print(f"  wrote {manifest['total_records']} records, "
          f"delta changed={manifest['delta']['records_mask_changed']}", flush=True)
    return manifest


def stage_coverage(out_root: str = OUT_ROOT) -> dict:
    from python_jev.retrain.dataset_v2 import (
        V2_SPLITS,
        coverage_flags,
        extended_action_stats,
        load_shard_v2,
    )
    from python_jev.training.coverage import (
        analyze_shard,
        check_full_info_only,
        check_no_leakage,
    )

    print("STAGE coverage: v0.2 coverage audit", flush=True)
    ds_dir = os.path.join(out_root, "dataset")
    shards = {s: os.path.join(ds_dir, f"{s}.pt") for s in V2_SPLITS}
    per_split = {}
    for split, path in shards.items():
        base = analyze_shard(path, loader=load_shard_v2)
        ext = extended_action_stats(path, loader=load_shard_v2)
        for key, entry in ext["per_action"].items():
            base["per_action"][key].update({
                "median_q": entry["median_q"], "q_std": entry["q_std"],
                "best_count": entry["best_count"]})
        per_split[split] = base
    flags = coverage_flags(per_split["train"]["per_action"])
    leakage = check_no_leakage(
        {s: shards[s] for s in ("train", "validation", "test")},
        loader=load_shard_v2)
    full_info = check_full_info_only(shards, loader=load_shard_v2)
    decision = ("REBALANCE_REQUIRED" if flags["dead_actions"]
                else "KEEP_DISTRIBUTION")
    report = {"per_split": per_split, "train_flags": flags,
              "leakage": leakage, "full_info": full_info,
              "rebalance_decision": decision,
              "rebalance_reason": (
                  "no dead actions; scenario distribution unchanged "
                  "(controlled experiment: mask is the only factor)"
                  if decision == "KEEP_DISTRIBUTION"
                  else f"dead actions: {flags['dead_actions']}")}
    out_path = os.path.join(out_root, "metrics", "coverage_report.json")
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w") as f:
        json.dump(report, f, indent=1, sort_keys=True)
    print(f"  train flags: dead={flags['dead_actions']} "
          f"rare={len(flags['rare_actions'])} decision={decision}", flush=True)
    return report


def stage_overfit(out_root: str = OUT_ROOT, device: str | None = None) -> dict:
    from python_jev.retrain.data_v2 import JevFullInfoDatasetV2
    from python_jev.training.overfit_gate import run_overfit_gate

    device = device or _device()
    print(f"STAGE overfit: tiny gate on corrected targets (device={device})",
          flush=True)
    rep = run_overfit_gate(
        os.path.join(out_root, "dataset", "train.pt"), device,
        dataset_cls=JevFullInfoDatasetV2,
        log_fn=lambda m: print(f"  {m}", flush=True))
    out_path = os.path.join(out_root, "metrics", "tiny_overfit.json")
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    slim = {k: v for k, v in rep.items() if k != "loss_curve"}
    slim["loss_curve_head"] = rep["loss_curve"][:5]
    slim["loss_curve_tail"] = rep["loss_curve"][-5:]
    with open(out_path, "w") as f:
        json.dump(slim, f, indent=1, sort_keys=True, default=float)
    print(f"  passed={rep['passed']} final_loss={rep['final_loss']:.4f} "
          f"floor={rep['entropy_floor']:.4f} kl={rep['final_metrics']['kl']:.4f} "
          f"regret={rep['final_metrics']['mean_regret']:.5f}", flush=True)
    if not rep["passed"]:
        raise RuntimeError("tiny overfit gate FAILED — STOP before full training")
    return rep


def stage_train(out_root: str = OUT_ROOT, device: str | None = None,
                seeds=SEEDS) -> dict:
    from python_jev.model import JevPolicyV0
    from python_jev.retrain.data_v2 import JevFullInfoDatasetV2
    from python_jev.retrain.dataset_v2 import (
        MODEL_V2_VERSION,
        V2_SPLITS,
        contract_pins_v2,
        load_shard_v2,
        source_dataset_hash,
    )
    from python_jev.training.checkpoint import (
        CHECKPOINT_MODEL_VERSION_V2,
        build_checkpoint,
        save_checkpoint,
    )
    from python_jev.training.run_training import MODEL_CONFIG
    from python_jev.training.train import TRAIN_DEFAULTS, train_one_seed

    device = device or _device()
    assert MODEL_V2_VERSION == CHECKPOINT_MODEL_VERSION_V2
    print(f"STAGE train: from-scratch seeds {tuple(seeds)} (device={device})",
          flush=True)
    ds_dir = os.path.join(out_root, "dataset")
    ckpt_dir = os.path.join(out_root, "checkpoints")
    os.makedirs(ckpt_dir, exist_ok=True)
    v01_paths = {s: os.path.join(V01_ROOT, "dataset", f"{s}.pt") for s in V2_SPLITS}
    pins = contract_pins_v2(source_dataset_hash(v01_paths))
    ds_hash = _v2_dataset_hash(ds_dir)
    try:
        n_params = sum(p.numel() for p in JevPolicyV0().parameters())
    except Exception:
        n_params = None
    summary: dict = {"device": device, "model_version": MODEL_V2_VERSION,
                     "model_config": MODEL_CONFIG, "train_defaults": TRAIN_DEFAULTS,
                     "n_parameters": n_params, "dataset_hash": ds_hash,
                     "init": "from_scratch", "seeds": {}}
    for seed in seeds:
        run = train_one_seed(
            os.path.join(ds_dir, "train.pt"),
            os.path.join(ds_dir, "validation.pt"),
            seed, device,
            log_fn=lambda m: print(f"  {m}", flush=True),
            dataset_cls=JevFullInfoDatasetV2)
        model = JevPolicyV0()
        model.load_state_dict(run["best_state_dict"])
        ckpt = build_checkpoint(
            model, MODEL_CONFIG, run["config"], seed, run["best_epoch"],
            run["history"], {"best_val_loss": run["best_val_loss"]}, pins, ds_hash,
            model_version=CHECKPOINT_MODEL_VERSION_V2,
            extra_metadata={"init": "from_scratch",
                            "dataset_version": "jev-fullinfo-dataset-v0.2.0"})
        path = os.path.join(ckpt_dir, f"seed{seed}.pt")
        save_checkpoint(ckpt, path)
        summary["seeds"][str(seed)] = {
            "best_epoch": run["best_epoch"],
            "best_val_loss": run["best_val_loss"],
            "epochs_run": run["epochs_run"],
            "wall_seconds": run["wall_seconds"],
            "samples_per_second": run["samples_per_second"],
            "checkpoint": path,
        }
        print(f"  seed {seed}: best_epoch={run['best_epoch']} "
              f"val={run['best_val_loss']:.4f} epochs={run['epochs_run']}",
              flush=True)
    best = min(seeds, key=lambda s: summary["seeds"][str(s)]["best_val_loss"])
    summary["selected_seed"] = best
    summary["selection_rule"] = "lowest validation soft-target cross entropy"
    out_path = os.path.join(out_root, "metrics", "training_history.json")
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w") as f:
        json.dump(summary, f, indent=2, sort_keys=True)
    print(f"  selected seed {best}", flush=True)
    return summary


def _v2_dataset_hash(ds_dir: str) -> str:
    import hashlib

    from python_jev.retrain.dataset_v2 import V2_SPLITS, load_shard_v2

    h = hashlib.sha256()
    for s in V2_SPLITS:
        h.update(load_shard_v2(os.path.join(ds_dir, f"{s}.pt"),
                               verify=True)["shard_hash"].encode("utf-8"))
    return h.hexdigest()


def _selected_checkpoint(out_root: str) -> tuple[int, str]:
    with open(os.path.join(out_root, "metrics", "training_history.json")) as f:
        history = json.load(f)
    seed = history["selected_seed"]
    return seed, os.path.join(out_root, "checkpoints", f"seed{seed}.pt")


def stage_offline(out_root: str = OUT_ROOT, device: str | None = None) -> dict:
    from python_jev.model import JevPolicyV0
    from python_jev.retrain.eval_v1 import (
        audit_selected_invalid,
        evaluate_corrected_heldout,
    )
    from python_jev.retrain.rebuild_v2 import new_mask_fn
    from python_jev.training.dataset_gen import ood_plan, split_plan

    device = device or _device()
    print(f"STAGE offline: corrected held-out, all models (device={device})",
          flush=True)
    seed, new_ckpt = _selected_checkpoint(out_root)
    models = {"old_seed43": _load_model(OLD_CHECKPOINT, device)}
    for s in SEEDS:
        models[f"new_seed{s}"] = _load_model(
            os.path.join(out_root, "checkpoints", f"seed{s}.pt"), device)
    torch.manual_seed(0)
    models["untrained"] = JevPolicyV0().to(device).eval()
    report = evaluate_corrected_heldout(
        models, os.path.join(out_root, "dataset", "test.pt"), device)
    out_path = os.path.join(out_root, "metrics", "offline.json")
    with open(out_path, "w") as f:
        json.dump(report, f, indent=1, sort_keys=True)
    for name, m in report["models"].items():
        a = m["aggregate"]
        print(f"  {name}: loss={a['loss']:.4f} regret={a['mean_regret']:.5f} "
              f"p95={a['p95_regret']:.5f} top1={a['top1']:.3f} "
              f"eps@0.01={m['epsilon_rates']['0.01']:.4f}", flush=True)

    plan = split_plan(192)
    ood = ood_plan(48)
    jobs = ([("test", i, plan[i]["profile"], False)
             for i in sorted(j for j in range(192) if plan[j]["split"] == "test")]
            + [("generalization_test", i, ood[i]["profile"], True)
               for i in list(range(0, 48, 4))[:12]])
    invalid_report = {
        "mask": "observation-safe-skill-mask-v0.2.0",
        "jobs": len(jobs),
        "new_selected": audit_selected_invalid(models[f"new_seed{seed}"],
                                               device, jobs, new_mask_fn),
        "old_seed43": audit_selected_invalid(models["old_seed43"],
                                             device, jobs, new_mask_fn),
    }
    out_inv = os.path.join(out_root, "metrics", "offline_invalid.json")
    with open(out_inv, "w") as f:
        json.dump(invalid_report, f, indent=1, sort_keys=True)
    print(f"  invalid: new={invalid_report['new_selected']['invalid_rate']:.4f} "
          f"old={invalid_report['old_seed43']['invalid_rate']:.4f}", flush=True)
    if invalid_report["new_selected"]["invalid_rate"] != 0.0:
        raise RuntimeError("new-model selected INVALID != 0 — BLOCKER")
    return {"offline": report, "invalid": invalid_report}


def stage_closedloop(out_root: str = OUT_ROOT, device: str | None = None) -> dict:
    from python_jev.retrain.closedloop_v1 import run_two_model_v1
    from python_jev.retrain.rebuild_v2 import new_mask_fn

    device = device or _device()
    print(f"STAGE closedloop: same-seat V1, new + old (device={device})",
          flush=True)
    _seed, new_ckpt = _selected_checkpoint(out_root)
    new_model = _load_model(new_ckpt, device)
    old_model = _load_model(OLD_CHECKPOINT, device)
    return run_two_model_v1(new_model, old_model, device,
                            os.path.join(out_root, "closedloop"),
                            new_mask_fn,
                            log_fn=lambda m: print(f"  {m}", flush=True))


def stage_exam(out_root: str = OUT_ROOT, device: str | None = None) -> dict:
    import copy

    from python_jev.model import JevPolicyV0
    from python_jev.retrain.rebuild_v2 import new_mask_fn
    from python_jev.training.exam import build_exam_cases, run_exam

    device = device or _device()
    print(f"STAGE exam: 60 tactical cases, mask v0.2.0 (device={device})",
          flush=True)
    _seed, new_ckpt = _selected_checkpoint(out_root)
    torch.manual_seed(0)
    models = {"untrained": JevPolicyV0().to(device).eval(),
              "old": _load_model(OLD_CHECKPOINT, device),
              "new": _load_model(new_ckpt, device)}
    out: dict = {"mask": "observation-safe-skill-mask-v0.2.0", "models": {}}
    cases_by_model: dict[str, list[dict]] = {}
    for name, model in models.items():
        rep = run_exam(model, device, copy.deepcopy(build_exam_cases()),
                       mask_fn=new_mask_fn)
        out["models"][name] = {"summary": rep["summary"], "cases": rep["cases"]}
        cases_by_model[name] = rep["cases"]
        print(f"  {name}: mean_regret={rep['summary']['overall']['mean_regret']:.4f} "
              f"p95={rep['summary']['overall']['p95_regret']:.4f}", flush=True)
    # skill-selection changes old -> new (same untouched cases)
    changes = []
    for co, cn in zip(cases_by_model["old"], cases_by_model["new"]):
        assert co["case_id"] == cn["case_id"]
        if co["selected_slot"] != cn["selected_slot"]:
            changes.append({"case_id": co["case_id"],
                            "actor_class": co["actor_class"],
                            "theme": co["theme"],
                            "old_slot": co["selected_slot"],
                            "new_slot": cn["selected_slot"],
                            "old_regret": co["regret"],
                            "new_regret": cn["regret"]})
    out["selection_changes_old_to_new"] = {
        "n_changed": len(changes), "n_cases": len(cases_by_model["new"]),
        "changes": changes}
    print(f"  selections changed old->new: {len(changes)}/60", flush=True)
    out_path = os.path.join(out_root, "exam", "exam.json")
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w") as f:
        json.dump(out, f, indent=1, sort_keys=True)
    return out


def stage_sensitivity(out_root: str = OUT_ROOT) -> dict:
    from python_jev.feasibility.sensitivity import run_sensitivity
    from python_jev.retrain.rebuild_v2 import new_mask_fn
    from python_jev.training.dataset_gen import split_plan
    from python_jev.training.scenarios import generate_scenario

    device = _device()
    print("STAGE sensitivity: continuation diagnostic, corrected mask",
          flush=True)
    _seed, new_ckpt = _selected_checkpoint(out_root)
    plan = split_plan(192)
    test_idx = sorted(i for i in range(192) if plan[i]["split"] == "test")
    by_mission: dict[str, list[int]] = {}
    for i in test_idx:
        m = generate_scenario(i)["scenario"]["mission_contract"]["primary_objective"]
        by_mission.setdefault(m, []).append(i)
    jobs = [(i, plan[i]["profile"], False)
            for m in sorted(by_mission) for i in by_mission[m][:4]]
    out_path = os.path.join(out_root, "sensitivity", "sensitivity.json")
    rep = run_sensitivity(jobs, out_path, mask_fn=new_mask_fn, mask_tag="new",
                          align_model=_load_model(new_ckpt, device),
                          align_device=device)
    print(f"  states={rep['states']} overall={json.dumps(rep['overall'])}",
          flush=True)
    if "model_alignment" in rep:
        for p, a in rep["model_alignment"].items():
            print(f"  align {p}: {a['agreement']:.3f}", flush=True)
    return rep


STAGES = {
    "dataset": stage_dataset,
    "coverage": stage_coverage,
    "overfit": stage_overfit,
    "train": stage_train,
    "offline": stage_offline,
    "closedloop": stage_closedloop,
    "exam": stage_exam,
    "sensitivity": stage_sensitivity,
}


def main(argv: list[str] | None = None) -> dict:
    argv = list(sys.argv[1:] if argv is None else argv)
    want: list[str] = list(STAGES)
    if "--stages" in argv:
        want = [w for w in argv[argv.index("--stages") + 1:] if w in STAGES]
    print(f"device={_device()} out={OUT_ROOT} stages={want}", flush=True)
    results: dict = {}
    for name in want:
        results[name] = STAGES[name]()
    return results


if __name__ == "__main__":
    main()
