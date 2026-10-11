"""A1 stage orchestrator: dagger1 collect -> v0.3 -> retrain -> evaluate.

Usage (from the project root):
    python -m python_jev.aggregate.run_aggregate
    python -m python_jev.aggregate.run_aggregate --stages pilot collect

Supervised state aggregation only. No RL, no Fog, no contract changes.
visited_test runs strictly after model selection (stage order enforced).
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import sys

import torch

OUT_ROOT = os.path.join("artifacts", "jev_dagger_v0")
V0_CKPT = os.path.join("artifacts", "jev_training_v0", "checkpoints", "seed43.pt")
OLD_CKPT = os.path.join("artifacts", "jev_training_v1", "checkpoints", "seed43.pt")
V02_DIR = os.path.join("artifacts", "jev_training_v1", "dataset")
D0_DIR = os.path.join("artifacts", "jev_target_diagnostic_v0")
V1_CLOSEDLOOP = os.path.join("artifacts", "jev_training_v1", "closedloop")
SEEDS = (42, 43, 44)


def _device() -> str:
    want = os.environ.get("A1_DEVICE", "cpu")
    if want == "cuda" and torch.cuda.is_available():
        return "cuda"
    return "cpu"


def _write(path: str, obj: dict) -> None:
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=1, sort_keys=True)


def _load_model(ckpt_path: str, device: str):
    from python_jev.model import JevPolicyV0
    from python_jev.training.checkpoint import load_checkpoint

    model = JevPolicyV0().to(device)
    load_checkpoint(ckpt_path, model)
    model.eval()
    return model


# ------------------------------------------------------------ collection
def stage_pilot(out_root: str = OUT_ROOT) -> dict:
    from python_jev.aggregate.gather import (
        collect_dagger1,
        deduplicate,
        train_jobs,
    )

    print("STAGE pilot: 24 train scenarios -> unique-rate estimate", flush=True)
    jobs = train_jobs()[:24]
    rows = collect_dagger1(OLD_CKPT, OLD_CKPT, scenarios=jobs,
                           log_fn=lambda m: print(f"  {m}", flush=True))
    _unique, info = deduplicate(rows)
    rate = info["unique"] / max(1, info["raw"])
    proj = rate * 144 * 64
    print(f"  raw={info['raw']} unique={info['unique']} rate={rate:.3f} "
          f"projected_144x64={proj:.0f}", flush=True)
    return {"jobs": len(jobs), **info, "unique_rate": rate,
            "projected_full": proj}


def stage_collect(out_root: str = OUT_ROOT) -> dict:
    from python_jev.aggregate.gather import (
        MAX_UNIQUE,
        MIN_UNIQUE,
        collect_dagger1,
        deduplicate,
    )
    from python_jev.diagnose.collect import save_distribution_set

    print("STAGE collect: dagger1 on 144 TRAIN scenarios", flush=True)
    rows = collect_dagger1(V0_CKPT, OLD_CKPT,
                           log_fn=lambda m: print(f"  {m}", flush=True))
    unique, info = deduplicate(rows)
    print(f"  {info}", flush=True)
    if not (MIN_UNIQUE <= info["unique"] <= MAX_UNIQUE):
        raise RuntimeError(f"unique {info['unique']} outside [{MIN_UNIQUE},{MAX_UNIQUE}]")
    cdir = os.path.join(out_root, "collected_train_states")
    os.makedirs(cdir, exist_ok=True)
    set_info = save_distribution_set(os.path.join(cdir, "dagger1_unique.pt"),
                                     "dagger1", unique)
    from python_jev.aggregate.gather import dedup_key

    dedup_map = {}
    for r in unique:
        dedup_map["|".join([str(x) for x in dedup_key(r)])] = r["visit_count"]
    _write(os.path.join(cdir, "dedup_map.json"), dedup_map)
    manifest = {"collection": set_info, "dedup": info,
                "scenarios": 144, "split": "train"}
    _write(os.path.join(cdir, "manifest.json"), manifest)
    return manifest


def stage_recover(out_root: str = OUT_ROOT) -> dict:
    import math

    from python_jev.aggregate.dataset_v03 import recovery_signal
    from python_jev.diagnose.collect import load_set

    print("STAGE recover: corrective-signal gate", flush=True)
    payload = load_set(os.path.join(out_root, "collected_train_states",
                                    "dagger1_unique.pt"), verify=True)
    rows = []
    sel = payload["tensors"]["sel_new"].tolist()
    for i, prov in enumerate(payload["provenance"]):
        q = payload["tensors"]["teacher_q"][i, 0].tolist()
        rows.append({
            "legal": [bool(x) for x in payload["tensors"]["legal"][i].tolist()],
            "teacher_q": {"SimpleAttackElseAdvancePolicy":
                          [(None if math.isnan(v) else v) for v in q]},
            "sel_new": int(sel[i]),
            "actor_class": prov["actor_class"],
        })
    rep = recovery_signal(rows)
    _write(os.path.join(out_root, "metrics", "recovery_signal.json"), rep)
    print(f"  agreement={rep['top_agreement']:.3f} "
          f"scout_recon policy={rep['spotlight']['SCOUT_RECON_ADVANCE']['policy']:.3f} "
          f"teacher={rep['spotlight']['SCOUT_RECON_ADVANCE']['teacher']:.3f} "
          f"passed={rep['passed']}", flush=True)
    if not rep["passed"]:
        raise RuntimeError("no corrective signal in dagger1 states — STOP")
    return rep


# ------------------------------------------------------------ dataset v0.3
def stage_dataset(out_root: str = OUT_ROOT) -> dict:
    import time

    from python_jev.aggregate.dataset_v03 import (
        DATASET_V03_VERSION,
        V03_SPLITS,
        pins_v03,
        save_shard_v03,
        v02_combined_hash,
        validate_record_v03,
    )
    from python_jev.aggregate.gather import collection_ckpt_hash, split_scenario_ids
    from python_jev.diagnose.collect import load_set
    from python_jev.retrain.dataset_v2 import V2_SPLITS, load_shard_v2
    from python_jev.training.scenarios import generate_scenario

    print("STAGE dataset: assemble jev-fullinfo-dataset-v0.3.0", flush=True)
    t_start = __import__("time").perf_counter()
    ckpt_hash = collection_ckpt_hash(OLD_CKPT)
    v02_hash = v02_combined_hash(V02_DIR)
    pins = pins_v03(v02_hash, ckpt_hash)
    train_ids = split_scenario_ids()["train"]
    forbidden = (split_scenario_ids()["validation"]
                 | split_scenario_ids()["test"]
                 | split_scenario_ids()["generalization_test"])

    # originals, rebuilt bit-identically from v0.2 train tensors
    v02 = load_shard_v2(os.path.join(V02_DIR, "train.pt"), verify=True)
    vt, vp = v02["tensors"], v02["provenance"]
    originals: list[dict] = []
    for i, prov in enumerate(vp):
        qv = [(float(v) if m else None) for v, m in
              zip(vt["q"][i].tolist(), vt["q_valid"][i].tolist())]
        originals.append({
            "dataset_version": DATASET_V03_VERSION, "full_information_only": True,
            "profile": prov["profile"], "split": "train",
            "scenario_id": prov["scenario_id"], "scenario_seed": prov["scenario_seed"],
            "scenario_family": prov["scenario_family"], "scenario_ood": prov["scenario_ood"],
            "mission_type": prov["mission_type"], "ratio_group": prov["ratio_group"],
            "formation": prov["formation"], "spacing": prov["spacing"],
            "actor_id": prov["actor_id"], "actor_class": prov["actor_class"],
            "acting_side": prov["acting_side"], "turn": prov["turn"],
            "decision_index": prov["decision_index"], "state_hash": prov["state_hash"],
            "observation": {
                "actor_features": [float(x) for x in vt["actor"][i].tolist()],
                "tokens": [[float(x) for x in t] for t in vt["tokens"][i].tolist()],
                "token_padding_mask": [bool(x) for x in vt["token_pad"][i].tolist()],
                "hex_patch": [[float(x) for x in h] for h in vt["hex"][i].tolist()],
                "mission_features": [float(x) for x in vt["mission"][i].tolist()],
                "global_features": [float(x) for x in vt["global"][i].tolist()],
                "acting_class_idx": int(vt["class_idx"][i].item())},
            "legal_mask": [bool(x) for x in vt["legal"][i].tolist()],
            "q_valid_mask": [bool(x) for x in vt["q_valid"][i].tolist()],
            "q_values": qv,
            "p_target": [float(x) for x in vt["p_target"][i].tolist()],
            "continuation_policy": prov["continuation_policy"],
            "horizon_decisions": prov["horizon_decisions"],
            "contract_versions": dict(pins),
            "source": "JEV_FULLINFO_V02", "visit_count": 1,
            "trajectory_id": f"v02:{prov['scenario_id']}",
            "trajectory_index": prov["decision_index"],
            "collection_ckpt": "n/a:v02-collection",
        })
    # dagger records from the deduped unique set
    from python_jev.aggregate.dataset_v03 import labels_for_state

    dag = load_set(os.path.join(out_root, "collected_train_states",
                                "dagger1_unique.pt"), verify=True)
    dagger: list[dict] = []
    for i, prov in enumerate(dag["provenance"]):
        meta = generate_scenario(prov["scenario_index"])["meta"]
        t = dag["tensors"]
        legal = [bool(x) for x in t["legal"][i].tolist()]
        q_raw = t["teacher_q"][i, 0].tolist()
        q_in = [(None if q != q else float(q)) for q in q_raw]  # NaN -> None
        q_values, q_valid, p_target = labels_for_state(q_in, legal)
        dagger.append({
            "dataset_version": DATASET_V03_VERSION, "full_information_only": True,
            "profile": prov["profile"], "split": "train",
            "scenario_id": prov["scenario_id"], "scenario_seed": prov["scenario_seed"],
            "scenario_family": meta["family"], "scenario_ood": False,
            "mission_type": prov["mission"], "ratio_group": meta["ratio_group"],
            "formation": meta["formation"], "spacing": meta["spacing"],
            "actor_id": prov["actor_id"], "actor_class": prov["actor_class"],
            "acting_side": prov["side"], "turn": prov["turn"],
            "decision_index": prov["trajectory_step"], "state_hash": prov["state_hash"],
            "observation": {
                "actor_features": [float(x) for x in t["actor"][i].tolist()],
                "tokens": [[float(x) for x in tt] for tt in t["tokens"][i].tolist()],
                "token_padding_mask": [bool(x) for x in t["token_pad"][i].tolist()],
                "hex_patch": [[float(x) for x in h] for h in t["hex"][i].tolist()],
                "mission_features": [float(x) for x in t["mission"][i].tolist()],
                "global_features": [float(x) for x in t["global"][i].tolist()],
                "acting_class_idx": int(t["class_idx"][i].item())},
            "legal_mask": legal, "q_valid_mask": q_valid,
            "q_values": q_values, "p_target": p_target,
            "continuation_policy": "SimpleAttackElseAdvancePolicy",
            "horizon_decisions": 8, "contract_versions": dict(pins),
            "source": "JEV_VISITED_DAGGER1", "visit_count": prov["visit_count"],
            "trajectory_id": f"dagger1:{prov['scenario_id']}",
            "trajectory_index": prov["trajectory_step"],
            "collection_ckpt": ckpt_hash,
        })
    # leakage gate: every dagger scenario must be a TRAIN scenario
    dag_ids = {r["scenario_id"] for r in dagger}
    if not dag_ids <= train_ids:
        raise RuntimeError(f"dagger1 leaked non-train scenarios: {dag_ids - train_ids}")
    if dag_ids & forbidden:
        raise RuntimeError("dagger1 leaked val/test/ood scenarios")
    print(f"  originals={len(originals)} dagger={len(dagger)} "
          f"leakage=0 ({len(dag_ids)} train scenarios)", flush=True)

    for r in dagger:
        problems = validate_record_v03(r, pins)
        if problems:
            raise ValueError(f"invalid dagger record: {problems}")
    for r in originals[::7]:
        problems = validate_record_v03(r, pins)
        if problems:
            raise ValueError(f"invalid v0.3 original: {problems}")
    train_records = originals + dagger
    ds_dir = os.path.join(out_root, "dataset_v03")
    shards = {"train": save_shard_v03(os.path.join(ds_dir, "train.pt"), "train",
                                      train_records, pins)}
    # tensor-equality proof: originals reused bit-identically
    from python_jev.aggregate.dataset_v03 import load_shard_v03

    back = load_shard_v03(os.path.join(ds_dir, "train.pt"), verify=True)
    n0 = len(originals)
    for k in ("actor", "tokens", "hex", "mission", "global", "q", "p_target"):
        assert torch.equal(back["tensors"][k][:n0], vt[k]), k
    for k in ("token_pad", "legal", "q_valid"):
        assert torch.equal(back["tensors"][k][:n0], vt[k]), k
    assert torch.equal(back["tensors"]["class_idx"][:n0], vt["class_idx"])
    # byte-copy the frozen splits
    for s in ("validation", "test", "generalization_test"):
        src = os.path.join(V02_DIR, f"{s}.pt")
        dst = os.path.join(ds_dir, f"{s}.pt")
        shutil.copyfile(src, dst)
        h1 = hashlib.sha256(open(src, "rb").read()).hexdigest()
        h2 = hashlib.sha256(open(dst, "rb").read()).hexdigest()
        assert h1 == h2, s
        shards[s] = {"path": dst, "split": s, "copied_from": src, "sha256": h2}
    manifest = {"dataset_version": DATASET_V03_VERSION,
                "source_dataset_version": "jev-fullinfo-dataset-v0.2.0",
                "source_dataset_hash": v02_hash,
                "contract_versions": pins,
                "original_train": len(originals), "dagger_train": len(dagger),
                "total_train": len(train_records),
                "dagger_scenarios": sorted(dag_ids),
                "leakage_val_test_ood": 0,
                "wall_seconds": time.perf_counter() - t_start,
                "shards": shards}
    with open(os.path.join(ds_dir, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
    print(f"  v0.3 train={len(train_records)} manifest written", flush=True)
    return manifest


# ------------------------------------------------------------ visited sets
def _split_jobs(split: str) -> list[tuple[int, str, bool, str]]:
    from python_jev.training.dataset_gen import split_plan

    plan = split_plan(192)
    return [(i, plan[i]["profile"], False, split)
            for i in sorted(j for j in range(192) if plan[j]["split"] == split)]


def stage_visited(out_root: str = OUT_ROOT) -> dict:
    from python_jev.aggregate.drift import collect_policy_set

    print("STAGE visited: D_VISITED_VALIDATION_V0 (eval-only)", flush=True)
    path = collect_policy_set(
        OLD_CKPT, "visited_validation", _split_jobs("validation"),
        os.path.join(out_root, "visited_validation", "visited_validation.pt"),
        OLD_CKPT, log_fn=lambda m: print(f"  {m}", flush=True))
    return {"visited_validation": path}


def stage_overfit(out_root: str = OUT_ROOT, device: str | None = None) -> dict:
    import random

    from python_jev.aggregate.data_v03 import JevFullInfoDatasetV3
    from python_jev.aggregate.dataset_v03 import (
        DATASET_V03_VERSION,
        load_shard_v03,
        pins_v03,
        save_shard_v03,
        v02_combined_hash,
    )
    from python_jev.aggregate.gather import collection_ckpt_hash
    from python_jev.training.overfit_gate import run_overfit_gate

    device = device or _device()
    print(f"STAGE overfit: mixed 64+64 gate (device={device})", flush=True)
    ds_dir = os.path.join(out_root, "dataset_v03")
    back = load_shard_v03(os.path.join(ds_dir, "train.pt"), verify=True)
    manifest = json.load(open(os.path.join(ds_dir, "manifest.json"), encoding="utf-8"))
    n0 = manifest["original_train"]
    # NOTE: mixed probe rebuilt from stored tensors (originals slice + dagger
    # stride) to avoid a second full assembly pass.
    t, prov = back["tensors"], back["provenance"]
    idx = list(range(0, n0, max(1, n0 // 64)))[:64]
    idx += list(range(n0, n0 + manifest["dagger_train"],
                      max(1, manifest["dagger_train"] // 64)))[:64]
    pins = pins_v03(v02_combined_hash(V02_DIR), collection_ckpt_hash(OLD_CKPT))

    def rec(i: int) -> dict:
        p = prov[i]
        return {
            "dataset_version": DATASET_V03_VERSION, "full_information_only": True,
            "profile": p["profile"], "split": "train",
            "scenario_id": p["scenario_id"], "scenario_seed": p["scenario_seed"],
            "scenario_family": p["scenario_family"], "scenario_ood": p["scenario_ood"],
            "mission_type": p["mission_type"], "ratio_group": p["ratio_group"],
            "formation": p["formation"], "spacing": p["spacing"],
            "actor_id": p["actor_id"], "actor_class": p["actor_class"],
            "acting_side": p["acting_side"], "turn": p["turn"],
            "decision_index": p["decision_index"], "state_hash": p["state_hash"],
            "observation": {
                "actor_features": [float(x) for x in t["actor"][i].tolist()],
                "tokens": [[float(x) for x in tt] for tt in t["tokens"][i].tolist()],
                "token_padding_mask": [bool(x) for x in t["token_pad"][i].tolist()],
                "hex_patch": [[float(x) for x in h] for h in t["hex"][i].tolist()],
                "mission_features": [float(x) for x in t["mission"][i].tolist()],
                "global_features": [float(x) for x in t["global"][i].tolist()],
                "acting_class_idx": int(t["class_idx"][i].item())},
            "legal_mask": [bool(x) for x in t["legal"][i].tolist()],
            "q_valid_mask": [bool(x) for x in t["q_valid"][i].tolist()],
            "q_values": [(float(v) if m else None) for v, m in
                         zip(t["q"][i].tolist(), t["q_valid"][i].tolist())],
            "p_target": [float(x) for x in t["p_target"][i].tolist()],
            "continuation_policy": p["continuation_policy"],
            "horizon_decisions": p["horizon_decisions"],
            "contract_versions": dict(pins),
            "source": p["source"], "visit_count": p["visit_count"],
            "trajectory_id": p["trajectory_id"],
            "trajectory_index": p["trajectory_index"],
            "collection_ckpt": p["collection_ckpt"],
        }

    mixed = [rec(i) for i in idx]
    assert len(mixed) == 128
    audit_dir = os.path.join(out_root, "audit")
    save_shard_v03(os.path.join(audit_dir, "tiny_mixed.pt"), "train", mixed, pins)
    rep = run_overfit_gate(os.path.join(audit_dir, "tiny_mixed.pt"), device,
                           dataset_cls=JevFullInfoDatasetV3,
                           log_fn=lambda m: print(f"  {m}", flush=True))
    slim = {k: v for k, v in rep.items() if k != "loss_curve"}
    slim["mix"] = "64 v0.2-train + 64 dagger1"
    _write(os.path.join(out_root, "metrics", "tiny_overfit.json"), slim)
    print(f"  passed={rep['passed']} final={rep['final_loss']:.4f} "
          f"floor={rep['entropy_floor']:.4f} kl={rep['final_metrics']['kl']:.4f}",
          flush=True)
    if not rep["passed"]:
        raise RuntimeError("mixed tiny-overfit gate FAILED — STOP")
    return rep


def stage_train(out_root: str = OUT_ROOT, device: str | None = None,
                seeds=SEEDS) -> dict:
    from python_jev.aggregate.data_v03 import JevFullInfoDatasetV3
    from python_jev.aggregate.dataset_v03 import (
        MODEL_V03_VERSION,
        V03_SPLITS,
        load_shard_v03,
        pins_v03,
        v02_combined_hash,
    )
    from python_jev.aggregate.gather import collection_ckpt_hash
    from python_jev.model import JevPolicyV0
    from python_jev.training.checkpoint import build_checkpoint, save_checkpoint
    from python_jev.training.run_training import MODEL_CONFIG
    from python_jev.training.train import TRAIN_DEFAULTS, train_one_seed

    device = device or _device()
    print(f"STAGE train: from-scratch seeds {tuple(seeds)} (device={device})",
          flush=True)
    ds_dir = os.path.join(out_root, "dataset_v03")
    ckpt_dir = os.path.join(out_root, "checkpoints")
    os.makedirs(ckpt_dir, exist_ok=True)
    pins = pins_v03(v02_combined_hash(V02_DIR), collection_ckpt_hash(OLD_CKPT))
    # file-byte hash: val/test/gen are v0.2 byte-copies by design (A1-9),
    # so a version-agnostic content hash covers all four shards uniformly.
    h = hashlib.sha256()
    for s in V03_SPLITS:
        with open(os.path.join(ds_dir, f"{s}.pt"), "rb") as f:
            h.update(hashlib.sha256(f.read()).digest())
    ds_hash = h.hexdigest()
    try:
        n_params = sum(p.numel() for p in JevPolicyV0().parameters())
    except Exception:
        n_params = None
    summary: dict = {"device": device, "model_version": MODEL_V03_VERSION,
                     "model_config": MODEL_CONFIG, "train_defaults": TRAIN_DEFAULTS,
                     "n_parameters": n_params, "dataset_hash": ds_hash,
                     "init": "from_scratch", "seeds": {}}
    for seed in seeds:
        run = train_one_seed(
            os.path.join(ds_dir, "train.pt"),
            os.path.join(ds_dir, "validation.pt"), seed, device,
            log_fn=lambda m: print(f"  {m}", flush=True),
            dataset_cls=JevFullInfoDatasetV3)
        model = JevPolicyV0()
        model.load_state_dict(run["best_state_dict"])
        ckpt = build_checkpoint(
            model, MODEL_CONFIG, run["config"], seed, run["best_epoch"],
            run["history"], {"best_val_loss": run["best_val_loss"]}, pins, ds_hash,
            model_version=MODEL_V03_VERSION,
            extra_metadata={"init": "from_scratch",
                            "dataset_version": "jev-fullinfo-dataset-v0.3.0"})
        path = os.path.join(ckpt_dir, f"seed{seed}.pt")
        save_checkpoint(ckpt, path)
        summary["seeds"][str(seed)] = {
            "best_epoch": run["best_epoch"], "best_val_loss": run["best_val_loss"],
            "epochs_run": run["epochs_run"], "wall_seconds": run["wall_seconds"],
            "samples_per_second": run["samples_per_second"], "checkpoint": path}
        print(f"  seed {seed}: best_epoch={run['best_epoch']} "
              f"val={run['best_val_loss']:.4f}", flush=True)
    best = min(seeds, key=lambda s: summary["seeds"][str(s)]["best_val_loss"])
    summary["selected_seed"] = best
    summary["selection_rule"] = "lowest validation soft-target cross entropy"
    _write(os.path.join(out_root, "metrics", "training_history.json"), summary)
    print(f"  selected seed {best}", flush=True)
    return summary


def _selected_checkpoint(out_root: str) -> tuple[int, str]:
    history = json.load(open(os.path.join(out_root, "metrics", "training_history.json"),
                             encoding="utf-8"))
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
    print("STAGE offline: original v0.2 test, all models", flush=True)
    seed, new_ckpt = _selected_checkpoint(out_root)
    models = {"old_v02": _load_model(OLD_CKPT, device)}
    for s in SEEDS:
        models[f"new_seed{s}"] = _load_model(
            os.path.join(out_root, "checkpoints", f"seed{s}.pt"), device)
    torch.manual_seed(0)
    models["untrained"] = JevPolicyV0().to(device).eval()
    report = evaluate_corrected_heldout(
        models, os.path.join(V02_DIR, "test.pt"), device)
    _write(os.path.join(out_root, "metrics", "offline.json"), report)
    for name, m in report["models"].items():
        a = m["aggregate"]
        print(f"  {name}: loss={a['loss']:.4f} reg={a['mean_regret']:.5f} "
              f"top1={a['top1']:.3f}", flush=True)
    plan = split_plan(192)
    ood = ood_plan(48)
    jobs = ([("test", i, plan[i]["profile"], False)
             for i in sorted(j for j in range(192) if plan[j]["split"] == "test")]
            + [("generalization_test", i, ood[i]["profile"], True)
               for i in list(range(0, 48, 4))[:12]])
    invalid_report = {
        "mask": "observation-safe-skill-mask-v0.2.0",
        "new_selected": audit_selected_invalid(models[f"new_seed{seed}"],
                                               device, jobs, new_mask_fn)}
    _write(os.path.join(out_root, "metrics", "offline_invalid.json"), invalid_report)
    print(f"  invalid new={invalid_report['new_selected']['invalid_rate']:.4f}",
          flush=True)
    if invalid_report["new_selected"]["invalid_rate"] != 0.0:
        raise RuntimeError("new-model selected INVALID != 0 — BLOCKER")
    return {"offline": report, "invalid": invalid_report}


def stage_visited_test(out_root: str = OUT_ROOT) -> dict:
    from python_jev.aggregate.drift import collect_policy_set

    print("STAGE visited_test: NEW driver on TEST scenarios (post-selection)",
          flush=True)
    _seed, new_ckpt = _selected_checkpoint(out_root)
    path = collect_policy_set(
        new_ckpt, "visited_test", _split_jobs("test"),
        os.path.join(out_root, "visited_validation", "visited_test.pt"),
        new_ckpt, log_fn=lambda m: print(f"  {m}", flush=True))
    return {"visited_test": path}


def _eval_visited_set(set_path: str, ckpts: dict[str, str], device: str) -> dict:
    import math

    from python_jev.aggregate.drift import driver_sels
    from python_jev.diagnose.collect import load_set

    payload = load_set(set_path, verify=True)
    n = payload["n_records"]
    out: dict = {"n": n, "models": {}}
    for tag, ckpt in ckpts.items():
        fw = driver_sels(_load_model(ckpt, device), payload)
        regrets, tops, eps = [], [], []
        for i in range(n):
            legal = [bool(x) for x in payload["tensors"]["legal"][i].tolist()]
            q = payload["tensors"]["teacher_q"][i, 0].tolist()
            qf = [(None if math.isnan(v) else v) for v in q]
            best = max(v for v, ok in zip(qf, legal) if ok)
            top = max([a for a in range(6) if legal[a]], key=lambda a: qf[a])
            regrets.append(max(0.0, best - qf[fw["sel"][i]]))
            tops.append(1.0 if fw["sel"][i] == top else 0.0)
            eps.append(1.0 if qf[fw["sel"][i]] >= best - 0.01 else 0.0)
        rs = sorted(regrets)
        out["models"][tag] = {
            "mean_regret": sum(rs) / n, "median_regret": rs[n // 2],
            "p95_regret": rs[min(n - 1, int(0.95 * n))],
            "top1": sum(tops) / n, "epsilon_at_0.01": sum(eps) / n}
    return out


def stage_visited_eval(out_root: str = OUT_ROOT, device: str | None = None) -> dict:
    device = device or _device()
    print("STAGE visited_eval: old+new on frozen visited sets", flush=True)
    _seed, new_ckpt = _selected_checkpoint(out_root)
    ckpts = {"old_v02": OLD_CKPT, "new_v03": new_ckpt}
    out = {
        "visited_validation": _eval_visited_set(
            os.path.join(out_root, "visited_validation", "visited_validation.pt"),
            ckpts, device),
        "visited_test": _eval_visited_set(
            os.path.join(out_root, "visited_validation", "visited_test.pt"),
            ckpts, device),
    }
    _write(os.path.join(out_root, "metrics", "visited.json"), out)
    for name, r in out.items():
        for tag, m in r["models"].items():
            print(f"  {name}/{tag}: reg={m['mean_regret']:.5f} "
                  f"top1={m['top1']:.3f}", flush=True)
    return out


def stage_depth(out_root: str = OUT_ROOT) -> dict:
    from python_jev.aggregate.drift import depth_for_ckpt

    print("STAGE depth: old vs new regret-by-depth", flush=True)
    _seed, new_ckpt = _selected_checkpoint(out_root)
    frozen = os.path.join(D0_DIR, "distributions", "jev_new.pt")
    vv = os.path.join(out_root, "visited_validation", "visited_validation.pt")
    out = {
        "frozen_jev_new_set": {
            "old_v02": depth_for_ckpt(frozen, OLD_CKPT),
            "new_v03": depth_for_ckpt(frozen, new_ckpt)},
        "visited_validation": {
            "old_v02": depth_for_ckpt(vv, OLD_CKPT),
            "new_v03": depth_for_ckpt(vv, new_ckpt)},
    }
    _write(os.path.join(out_root, "metrics", "depth_compare.json"), out)
    for name, r in out.items():
        print(f"  {name}: old trend={r['old_v02']['trend_late_minus_early']} "
              f"new trend={r['new_v03']['trend_late_minus_early']}", flush=True)
    return out


def stage_closedloop(out_root: str = OUT_ROOT, device: str | None = None) -> dict:
    from python_jev.retrain.closedloop_v1 import run_two_model_v1
    from python_jev.retrain.rebuild_v2 import new_mask_fn

    device = device or _device()
    print(f"STAGE closedloop: same-seat V1 v0.3 vs v0.2 (device={device})",
          flush=True)
    _seed, new_ckpt = _selected_checkpoint(out_root)
    return run_two_model_v1(_load_model(new_ckpt, device),
                            _load_model(OLD_CKPT, device), device,
                            os.path.join(out_root, "closedloop"), new_mask_fn,
                            log_fn=lambda m: print(f"  {m}", flush=True))


def stage_drift(out_root: str = OUT_ROOT) -> dict:
    from python_jev.aggregate.drift import (
        collect_policy_set,
        contact_metrics,
        latent_compare,
        shift_compare,
    )
    from python_jev.diagnose.collect import matched_jobs

    print("STAGE drift: NEW trajectories + contact/shift/latent", flush=True)
    _seed, new_ckpt = _selected_checkpoint(out_root)
    jobs = matched_jobs()
    new_path = collect_policy_set(
        new_ckpt, "drift_new", jobs,
        os.path.join(out_root, "drift", "drift_new.pt"), new_ckpt,
        log_fn=lambda m: print(f"  {m}", flush=True))
    old_path = os.path.join(D0_DIR, "distributions", "jev_new.pt")
    iid_path = os.path.join(D0_DIR, "distributions", "iid_test.pt")
    contact = {"old_v02": contact_metrics(old_path, OLD_CKPT),
               "new_v03": contact_metrics(new_path, new_ckpt)}
    shift = shift_compare({"iid_test": iid_path, "old_visited": old_path,
                           "new_visited": new_path})
    latent = latent_compare(
        OLD_CKPT, os.path.join(V02_DIR, "train.pt"),
        {"iid_test": iid_path, "old_visited": old_path, "new_visited": new_path})
    out = {"contact": contact, "shift": shift, "latent": latent,
           "drift_new_set": new_path}
    _write(os.path.join(out_root, "drift", "drift.json"), out)
    print(f"  contact old atk_opp={contact['old_v02']['attack_opportunity_rate']:.3f} "
          f"new={contact['new_v03']['attack_opportunity_rate']:.3f}", flush=True)
    print(f"  latent old={latent['sets']['old_visited']['mean']:.3f} "
          f"new={latent['sets']['new_visited']['mean']:.3f}", flush=True)
    return out


def stage_exam(out_root: str = OUT_ROOT, device: str | None = None) -> dict:
    import copy

    from python_jev.model import JevPolicyV0
    from python_jev.retrain.rebuild_v2 import new_mask_fn
    from python_jev.training.exam import build_exam_cases, run_exam

    device = device or _device()
    print("STAGE exam: 60 cases, untrained/old/new", flush=True)
    _seed, new_ckpt = _selected_checkpoint(out_root)
    torch.manual_seed(0)
    models = {"untrained": JevPolicyV0().to(device).eval(),
              "old_v02": _load_model(OLD_CKPT, device),
              "new_v03": _load_model(new_ckpt, device)}
    out: dict = {"mask": "observation-safe-skill-mask-v0.2.0", "models": {}}
    for name, model in models.items():
        rep = run_exam(model, device, copy.deepcopy(build_exam_cases()),
                       mask_fn=new_mask_fn)
        out["models"][name] = {"summary": rep["summary"]}
        print(f"  {name}: reg={rep['summary']['overall']['mean_regret']:.4f}",
              flush=True)
    _write(os.path.join(out_root, "exam", "exam.json"), out)
    return out


def _strip_wall_battles(battles: list[dict]) -> list[dict]:
    import copy as _copy

    out = []
    for b in battles:
        c = _copy.deepcopy(b)
        c.pop("wall_seconds", None)
        out.append(c)
    return out


def stage_oracle(out_root: str = OUT_ROOT) -> dict:
    from python_jev.diagnose.oracles import run_oracle_subset

    print("STAGE oracle: rerun greedy diagnostics + gap vs v0.3", flush=True)
    rep = run_oracle_subset(os.path.join(out_root, "oracle_closedloop"),
                            V1_CLOSEDLOOP,
                            log_fn=lambda m: print(f"  {m}", flush=True))
    d0 = json.load(open(os.path.join(D0_DIR, "oracle_closedloop", "report.json"),
                        encoding="utf-8"))
    assert d0["subset_scenario_ids"] == rep["subset_scenario_ids"]
    for name in ("CounterfactualGreedySimple", "CounterfactualGreedy2Teacher"):
        a = _strip_wall_battles(d0["oracles"][name]["battles"])
        b = _strip_wall_battles(rep["oracles"][name]["battles"])
        assert json.dumps(a, sort_keys=True) == json.dumps(b, sort_keys=True), name
    print("  oracle rerun bit-identical to D0 (minus wall clock)", flush=True)
    comp = json.load(open(os.path.join(out_root, "closedloop",
                                       "same_seat_comparison.json"),
                          encoding="utf-8"))
    v1_new = json.load(open(os.path.join(out_root, "closedloop", "v1_new_model.json"),
                            encoding="utf-8"))
    sub = [b for b in v1_new["conditions"]["blue=JEV_vs_red=Simple"]["battles"]
           if b["scenario_id"] in rep["subset_scenario_ids"]]
    assert len(sub) == 6
    new_ex = sum(b["exchange_blue_view"] for b in sub) / 6.0
    new_dm = sum(b["mission_progress_delta_blue"] for b in sub) / 6.0
    o = rep["oracles"]["CounterfactualGreedySimple"]["summary"]
    old_ex = rep["reference"]["NEW_JEV"]["summary"]["mean_exchange_blue_view"]
    gap = {"oracle_exchange": o["mean_exchange_blue_view"],
           "old_v02_exchange": old_ex, "new_v03_exchange": new_ex,
           "new_v03_dM": new_dm,
           "gap_closed_fraction": ((new_ex - old_ex)
                                   / (o["mean_exchange_blue_view"] - old_ex)
                                   if o["mean_exchange_blue_view"] != old_ex else None)}
    _write(os.path.join(out_root, "metrics", "oracle_gap.json"), gap)
    print(f"  gap: oracle={gap['oracle_exchange']:+.1f} "
          f"old={old_ex:+.1f} new={new_ex:+.1f} closed={gap['gap_closed_fraction']}",
          flush=True)
    return {"report": rep, "gap": gap}


def stage_success_metrics(out_root: str = OUT_ROOT) -> dict:
    def load(rel: str) -> dict:
        with open(os.path.join(out_root, rel), encoding="utf-8") as f:
            return json.load(f)

    offline = load("metrics/offline.json")["models"]
    visited = load("metrics/visited.json")
    depth = load("metrics/depth_compare.json")
    comp = load("closedloop/same_seat_comparison.json")
    drift = load("drift/drift.json")
    gap = load("metrics/oracle_gap.json")
    new_key = f"new_seed{load('metrics/training_history.json')['selected_seed']}"
    metrics = {
        "iid": {
            "old_regret": offline["old_v02"]["aggregate"]["mean_regret"],
            "new_regret": offline[new_key]["aggregate"]["mean_regret"],
            "old_top1": offline["old_v02"]["aggregate"]["top1"],
            "new_top1": offline[new_key]["aggregate"]["top1"]},
        "visited_validation": {
            "old_regret": visited["visited_validation"]["models"]["old_v02"]["mean_regret"],
            "new_regret": visited["visited_validation"]["models"]["new_v03"]["mean_regret"],
            "old_top1": visited["visited_validation"]["models"]["old_v02"]["top1"],
            "new_top1": visited["visited_validation"]["models"]["new_v03"]["top1"]},
        "depth_trend_frozen": {
            "old": depth["frozen_jev_new_set"]["old_v02"]["trend_late_minus_early"],
            "new": depth["frozen_jev_new_set"]["new_v03"]["trend_late_minus_early"]},
        "closedloop": {
            "dM_old": comp["blue_vs_simple_red"]["OLD_JEV"]["mean_mission_progress_delta_blue"],
            "dM_new": comp["blue_vs_simple_red"]["NEW_JEV"]["mean_mission_progress_delta_blue"],
            "ex_old": comp["blue_vs_simple_red"]["OLD_JEV"]["mean_exchange_blue_view"],
            "ex_new": comp["blue_vs_simple_red"]["NEW_JEV"]["mean_exchange_blue_view"]},
        "latent": {
            "old": drift["latent"]["sets"]["old_visited"]["mean"],
            "new": drift["latent"]["sets"]["new_visited"]["mean"]},
        "oracle_gap_closed": gap["gap_closed_fraction"],
        "invalid_new": load("metrics/offline_invalid.json")["new_selected"]["invalid_rate"],
    }
    _write(os.path.join(out_root, "metrics", "success_metrics.json"), metrics)
    print(json.dumps(metrics, indent=1), flush=True)
    return metrics


STAGES = {
    "pilot": stage_pilot,
    "collect": stage_collect,
    "recover": stage_recover,
    "dataset": stage_dataset,
    "visited": stage_visited,
    "overfit": stage_overfit,
    "train": stage_train,
    "offline": stage_offline,
    "visited_test": stage_visited_test,
    "visited_eval": stage_visited_eval,
    "depth": stage_depth,
    "closedloop": stage_closedloop,
    "drift": stage_drift,
    "exam": stage_exam,
    "oracle": stage_oracle,
    "success_metrics": stage_success_metrics,
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
