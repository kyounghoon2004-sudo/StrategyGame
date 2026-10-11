"""A3 stage orchestrator: dagger3 collect -> v0.5 -> retrain -> evaluate.

Mirrors run_dagger2; behavior policy is the v0.4 selected checkpoint
(seed44). Round-3 novelties: cross-dataset dedup against v0.4 TRAIN
(novel rows only enter v0.5), a fresh v0.4-driven visited-validation
set, teacher/policy disagreement audit, and 4-way comparisons.
Frozen inputs (v0.2 bytes, v0.3/v0.4 shards, A1/A2 sets, D0 sets/oracle)
are read-only. No RL, no Fog, no contract changes.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import sys

import torch

OUT_ROOT = os.path.join("artifacts", "jev_dagger_v2")
V02_CKPT = os.path.join("artifacts", "jev_training_v1", "checkpoints", "seed43.pt")
V03_CKPT = os.path.join("artifacts", "jev_dagger_v0", "checkpoints", "seed43.pt")
V04_CKPT = os.path.join("artifacts", "jev_dagger_v1", "checkpoints", "seed44.pt")
V02_DIR = os.path.join("artifacts", "jev_training_v1", "dataset")
V03_DIR = os.path.join("artifacts", "jev_dagger_v0", "dataset_v03")
V04_DIR = os.path.join("artifacts", "jev_dagger_v1", "dataset_v04")
A1_ROOT = os.path.join("artifacts", "jev_dagger_v0")
A2_ROOT = os.path.join("artifacts", "jev_dagger_v1")
D0_DIR = os.path.join("artifacts", "jev_target_diagnostic_v0")
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


def _verify_driver_ckpt() -> str:
    """A3-1: v0.4 seed44 bytes must match the pinned hash pre-collection."""
    from python_jev.aggregate.dataset_v05 import V04_CKPT_SHA256
    from python_jev.aggregate.gather import collection_ckpt_hash

    got = collection_ckpt_hash(V04_CKPT)
    assert got == V04_CKPT_SHA256, f"driver ckpt drift: {got}"
    return got


def _split_jobs(split: str) -> list[tuple[int, str, bool, str]]:
    from python_jev.training.dataset_gen import split_plan

    plan = split_plan(192)
    return [(i, plan[i]["profile"], False, split)
            for i in sorted(j for j in range(192) if plan[j]["split"] == split)]


def stage_pilot(out_root: str = OUT_ROOT) -> dict:
    from python_jev.aggregate.dataset_v05 import DAGGER3_SOURCE
    from python_jev.aggregate.gather import (
        DAGGER_CAP,
        collect_dagger1,
        deduplicate,
        train_jobs,
    )

    _verify_driver_ckpt()
    print("STAGE pilot3: 24 train scenarios, v0.4 driver", flush=True)
    jobs = train_jobs()[:24]
    rows = collect_dagger1(V03_CKPT, V04_CKPT, scenarios=jobs,
                           log_fn=lambda m: print(f"  {m}", flush=True),
                           max_states=DAGGER_CAP, set_name="dagger3",
                           driver_label="dagger3-v04-seed44")
    _unique, info = deduplicate(rows, source=DAGGER3_SOURCE, traj_prefix="dagger3")
    rate = info["unique"] / max(1, info["raw"])
    print(f"  raw={info['raw']} unique={info['unique']} rate={rate:.3f} "
          f"projected={rate * 144 * DAGGER_CAP:.0f}", flush=True)
    return {"jobs": len(jobs), **info, "unique_rate": rate}


def stage_collect(out_root: str = OUT_ROOT) -> dict:
    from collections import Counter

    from python_jev.aggregate.dataset_v05 import DAGGER3_SOURCE, V04_CKPT_LABEL
    from python_jev.aggregate.gather import (
        MAX_UNIQUE,
        MIN_UNIQUE,
        collect_dagger1,
        dedup_key,
        deduplicate,
    )
    from python_jev.diagnose.collect import save_distribution_set

    ckpt_hash = _verify_driver_ckpt()
    print("STAGE collect3: dagger3 on 144 TRAIN scenarios", flush=True)
    rows = collect_dagger1(V03_CKPT, V04_CKPT,
                           log_fn=lambda m: print(f"  {m}", flush=True),
                           set_name="dagger3", driver_label="dagger3-v04-seed44")
    unique, info = deduplicate(rows, source=DAGGER3_SOURCE, traj_prefix="dagger3")
    print(f"  {info}", flush=True)
    if not (MIN_UNIQUE <= info["unique"] <= MAX_UNIQUE):
        raise RuntimeError(f"unique {info['unique']} outside [{MIN_UNIQUE},{MAX_UNIQUE}]")
    cdir = os.path.join(out_root, "round3_collection")
    os.makedirs(cdir, exist_ok=True)
    set_info = save_distribution_set(os.path.join(cdir, "dagger3_unique.pt"),
                                     "dagger3", unique)
    dedup_map = {}
    for r in unique:
        dedup_map["|".join(str(x) for x in dedup_key(r))] = r["visit_count"]
    _write(os.path.join(cdir, "dedup_map.json"), dedup_map)
    manifest = {"collection": set_info, "dedup": info, "scenarios": 144,
                "split": "train",
                "driver": V04_CKPT_LABEL, "driver_ckpt_hash": ckpt_hash,
                "reference_ckpt": "jev-policy-v0.3.0-fi-dagger1/seed43",
                "class_distribution": dict(Counter(r["actor_class"] for r in unique)),
                "profile_distribution": dict(Counter(r["profile"] for r in unique)),
                "mission_distribution": dict(Counter(r["mission"] for r in unique)),
                "depth_histogram": {
                    "0-4": sum(1 for r in unique if r["trajectory_step"] <= 4),
                    "5-9": sum(1 for r in unique if 5 <= r["trajectory_step"] <= 9),
                    "10-19": sum(1 for r in unique if 10 <= r["trajectory_step"] <= 19),
                    "20+": sum(1 for r in unique if r["trajectory_step"] >= 20)}}
    _write(os.path.join(cdir, "manifest.json"), manifest)
    return manifest


def stage_crossdedup(out_root: str = OUT_ROOT) -> dict:
    from collections import Counter

    from python_jev.aggregate.dataset_v05 import V04_TRAIN_SHA256
    from python_jev.aggregate.gather import cross_dedup_report
    from python_jev.diagnose.collect import load_set

    print("STAGE crossdedup3: round-3 uniques vs v0.4 TRAIN corpus", flush=True)
    with open(os.path.join(V04_DIR, "train.pt"), "rb") as f:
        got = hashlib.sha256(f.read()).hexdigest()
    assert got == V04_TRAIN_SHA256, "v0.4 train bytes drifted — STOP"
    cdir = os.path.join(out_root, "round3_collection")
    payload = load_set(os.path.join(cdir, "dagger3_unique.pt"), verify=True)
    novel_idx, report = cross_dedup_report(
        payload, os.path.join(V04_DIR, "train.pt"),
        os.path.join(A1_ROOT, "collected_train_states", "dagger1_unique.pt"),
        os.path.join(A2_ROOT, "collected_train_states", "dagger2_unique.pt"))
    report["novel_indices"] = novel_idx
    report["novel_class_distribution"] = dict(Counter(
        payload["provenance"][i]["actor_class"] for i in novel_idx))
    _write(os.path.join(cdir, "crossdedup.json"), report)
    print(f"  unique={report['round3_unique']} novel={report['new_unique']} "
          f"already={report['already_in_v04']} "
          f"join={report['tensor_join_matched']}/"
          f"{report['tensor_join_checked']}", flush=True)
    return report


def _unique_rows_as_recovery(out_root: str) -> list[dict]:
    import math

    from python_jev.diagnose.collect import load_set

    payload = load_set(os.path.join(out_root, "round3_collection",
                                    "dagger3_unique.pt"), verify=True)
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
    return rows


def stage_recover(out_root: str = OUT_ROOT) -> dict:
    from python_jev.aggregate.dataset_v03 import recovery_signal
    from python_jev.aggregate.drift import scout_boundary

    print("STAGE recover3: corrective signal + SCOUT boundary", flush=True)
    rep = recovery_signal(_unique_rows_as_recovery(out_root))
    rep["scout_boundary"] = scout_boundary(
        os.path.join(out_root, "round3_collection", "dagger3_unique.pt"))
    _write(os.path.join(out_root, "metrics", "recovery_signal.json"), rep)
    b = rep["scout_boundary"]
    print(f"  agreement={rep['top_agreement']:.3f} scout={b['scout_states']} "
          f"teacher_evade={b['teacher_evade']} teacher_recon={b['teacher_recon']} "
          f"both_sides={b['both_sides_covered']}", flush=True)
    for row in b["feature_differences"][:5]:
        print(f"    {row['feature']}: evade={row['mean_teacher_evade']:.3f} "
              f"recon={row['mean_teacher_recon']:.3f} d={row['cohens_d']:+.3f}",
              flush=True)
    if not rep["passed"]:
        raise RuntimeError("no corrective signal in dagger3 states — STOP")
    return rep


def stage_visited_v04(out_root: str = OUT_ROOT) -> dict:
    from python_jev.aggregate.drift import collect_policy_set

    print("STAGE visited_v04: v0.4 driver on VALIDATION scenarios (pre-train)",
          flush=True)
    _verify_driver_ckpt()
    path = collect_policy_set(
        V04_CKPT, "visited_v04", _split_jobs("validation"),
        os.path.join(out_root, "visited_validation", "visited_v04.pt"),
        V04_CKPT, log_fn=lambda m: print(f"  {m}", flush=True))
    return {"visited_v04": path}


def stage_dataset(out_root: str = OUT_ROOT) -> dict:
    import time

    from python_jev.aggregate.dataset_v03 import labels_for_state, v02_combined_hash
    from python_jev.aggregate.dataset_v04 import load_shard_v04
    from python_jev.aggregate.dataset_v05 import (
        DAGGER3_SOURCE,
        DATASET_V05_VERSION,
        V04_CKPT_LABEL,
        V04_TRAIN_SHA256,
        V05_SPLITS,
        load_shard_v05,
        pins_v05,
        save_shard_v05,
        validate_record_v05,
    )
    from python_jev.aggregate.gather import collection_ckpt_hash, split_scenario_ids
    from python_jev.diagnose.collect import load_set
    from python_jev.training.scenarios import generate_scenario

    print("STAGE dataset3: assemble jev-fullinfo-dataset-v0.5.0", flush=True)
    t_start = time.perf_counter()
    ckpt3 = collection_ckpt_hash(V04_CKPT)
    ckpt2 = collection_ckpt_hash(V03_CKPT)
    ckpt1 = collection_ckpt_hash(V02_CKPT)
    pins = pins_v05(v02_combined_hash(V02_DIR), ckpt1, ckpt2, ckpt3)
    with open(os.path.join(V04_DIR, "train.pt"), "rb") as f:
        assert hashlib.sha256(f.read()).hexdigest() == V04_TRAIN_SHA256
    train_ids = split_scenario_ids()["train"]
    forbidden = (split_scenario_ids()["validation"]
                 | split_scenario_ids()["test"]
                 | split_scenario_ids()["generalization_test"])

    # carried records, rebuilt bit-identically from v0.4 train tensors
    v04 = load_shard_v04(os.path.join(V04_DIR, "train.pt"), verify=True)
    vt, vp = v04["tensors"], v04["provenance"]
    carried: list[dict] = []
    for i, prov in enumerate(vp):
        qv = [(float(v) if m else None) for v, m in
              zip(vt["q"][i].tolist(), vt["q_valid"][i].tolist())]
        carried.append({
            "dataset_version": DATASET_V05_VERSION, "full_information_only": True,
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
            "source": prov["source"], "visit_count": prov["visit_count"],
            "trajectory_id": prov["trajectory_id"],
            "trajectory_index": prov["trajectory_index"],
            "collection_ckpt": prov["collection_ckpt"],
        })
    dag = load_set(os.path.join(out_root, "round3_collection",
                                "dagger3_unique.pt"), verify=True)
    with open(os.path.join(out_root, "round3_collection", "crossdedup.json"),
              encoding="utf-8") as f:
        novel_idx = set(json.load(f)["novel_indices"])
    dagger: list[dict] = []
    for i, prov in enumerate(dag["provenance"]):
        if i not in novel_idx:
            continue
        meta = generate_scenario(prov["scenario_index"])["meta"]
        t = dag["tensors"]
        legal = [bool(x) for x in t["legal"][i].tolist()]
        q_raw = t["teacher_q"][i, 0].tolist()
        q_in = [(None if q != q else float(q)) for q in q_raw]
        q_values, q_valid, p_target = labels_for_state(q_in, legal)
        dagger.append({
            "dataset_version": DATASET_V05_VERSION, "full_information_only": True,
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
            "source": DAGGER3_SOURCE, "visit_count": prov["visit_count"],
            "trajectory_id": f"dagger3:{prov['scenario_id']}",
            "trajectory_index": prov["trajectory_step"],
            "collection_ckpt": ckpt3,
        })
    dag_ids = {r["scenario_id"] for r in dagger}
    if not dag_ids <= train_ids or dag_ids & forbidden:
        raise RuntimeError("dagger3 leakage outside TRAIN")
    print(f"  carried={len(carried)} dagger3_novel={len(dagger)} leakage=0",
          flush=True)
    for r in dagger:
        problems = validate_record_v05(r, pins)
        if problems:
            raise ValueError(f"invalid dagger3 record: {problems}")
    for r in carried[::11]:
        problems = validate_record_v05(r, pins)
        if problems:
            raise ValueError(f"invalid v0.5 carried record: {problems}")
    ds_dir = os.path.join(out_root, "dataset_v05")
    shards = {"train": save_shard_v05(os.path.join(ds_dir, "train.pt"), "train",
                                      carried + dagger, pins)}
    back = load_shard_v05(os.path.join(ds_dir, "train.pt"), verify=True)
    n0 = len(carried)
    for k in ("actor", "tokens", "hex", "mission", "global", "q", "p_target",
              "token_pad", "legal", "q_valid", "class_idx"):
        assert torch.equal(back["tensors"][k][:n0], vt[k]), k
    for s in ("validation", "test", "generalization_test"):
        src = os.path.join(V02_DIR, f"{s}.pt")
        dst = os.path.join(ds_dir, f"{s}.pt")
        shutil.copyfile(src, dst)
        assert hashlib.sha256(open(src, "rb").read()).hexdigest() == \
            hashlib.sha256(open(dst, "rb").read()).hexdigest(), s
        shards[s] = {"path": dst, "split": s, "copied_from": src}
    manifest = {"dataset_version": DATASET_V05_VERSION,
                "source_dataset_version": "jev-fullinfo-dataset-v0.4.0",
                "contract_versions": pins,
                "carried_train": len(carried), "dagger3_train": len(dagger),
                "total_train": len(carried) + len(dagger),
                "dagger3_scenarios": sorted(dag_ids),
                "leakage_val_test_ood": 0,
                "driver": V04_CKPT_LABEL,
                "wall_seconds": time.perf_counter() - t_start,
                "shards": shards}
    with open(os.path.join(ds_dir, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
    return manifest


def stage_overfit(out_root: str = OUT_ROOT, device: str | None = None) -> dict:
    from python_jev.aggregate.data_v03 import JevFullInfoDatasetV5
    from python_jev.aggregate.dataset_v03 import v02_combined_hash
    from python_jev.aggregate.dataset_v05 import (
        DATASET_V05_VERSION,
        load_shard_v05,
        pins_v05,
        save_shard_v05,
    )
    from python_jev.aggregate.gather import collection_ckpt_hash
    from python_jev.training.overfit_gate import run_overfit_gate

    device = device or _device()
    print(f"STAGE overfit3: mixed 4x32 gate (device={device})", flush=True)
    ds_dir = os.path.join(out_root, "dataset_v05")
    back = load_shard_v05(os.path.join(ds_dir, "train.pt"), verify=True)
    manifest = json.load(open(os.path.join(ds_dir, "manifest.json"), encoding="utf-8"))
    n0, n3 = manifest["carried_train"], manifest["dagger3_train"]
    # carried slice holds v0.2-originals, dagger1, dagger2 in order.
    a2_manifest = json.load(open(os.path.join(V04_DIR, "manifest.json"),
                                 encoding="utf-8"))
    n_v03 = a2_manifest["carried_train"]
    a1_manifest = json.load(open(os.path.join(V03_DIR, "manifest.json"),
                                 encoding="utf-8"))
    n_orig = a1_manifest["original_train"]
    bounds = [(0, n_orig), (n_orig, n_v03), (n_v03, n0), (n0, n0 + n3)]
    idx = []
    for lo, hi in bounds:
        idx += list(range(lo, hi, max(1, (hi - lo) // 32)))[:32]
    t, prov = back["tensors"], back["provenance"]
    pins = pins_v05(v02_combined_hash(V02_DIR),
                    collection_ckpt_hash(V02_CKPT), collection_ckpt_hash(V03_CKPT),
                    collection_ckpt_hash(V04_CKPT))

    def rec(i: int) -> dict:
        p = prov[i]
        return {
            "dataset_version": DATASET_V05_VERSION, "full_information_only": True,
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
    save_shard_v05(os.path.join(audit_dir, "tiny_mixed.pt"), "train", mixed, pins)
    rep = run_overfit_gate(os.path.join(audit_dir, "tiny_mixed.pt"), device,
                           dataset_cls=JevFullInfoDatasetV5,
                           log_fn=lambda m: print(f"  {m}", flush=True))
    slim = {k: v for k, v in rep.items() if k != "loss_curve"}
    slim["mix"] = "32 v0.2 + 32 dagger1 + 32 dagger2 + 32 dagger3"
    _write(os.path.join(out_root, "metrics", "tiny_overfit.json"), slim)
    print(f"  passed={rep['passed']} final={rep['final_loss']:.4f} "
          f"floor={rep['entropy_floor']:.4f}", flush=True)
    if not rep["passed"]:
        raise RuntimeError("mixed tiny-overfit gate FAILED — STOP")
    return rep


def stage_train(out_root: str = OUT_ROOT, device: str | None = None,
                seeds=SEEDS) -> dict:
    from python_jev.aggregate.data_v03 import JevFullInfoDatasetV5
    from python_jev.aggregate.dataset_v03 import v02_combined_hash
    from python_jev.aggregate.dataset_v05 import (
        MODEL_V05_VERSION,
        V05_SPLITS,
        pins_v05,
    )
    from python_jev.aggregate.gather import collection_ckpt_hash
    from python_jev.model import JevPolicyV0
    from python_jev.training.checkpoint import build_checkpoint, save_checkpoint
    from python_jev.training.run_training import MODEL_CONFIG
    from python_jev.training.train import TRAIN_DEFAULTS, train_one_seed

    device = device or _device()
    print(f"STAGE train3: from-scratch seeds {tuple(seeds)} (device={device})",
          flush=True)
    ds_dir = os.path.join(out_root, "dataset_v05")
    ckpt_dir = os.path.join(out_root, "checkpoints")
    os.makedirs(ckpt_dir, exist_ok=True)
    pins = pins_v05(v02_combined_hash(V02_DIR),
                    collection_ckpt_hash(V02_CKPT), collection_ckpt_hash(V03_CKPT),
                    collection_ckpt_hash(V04_CKPT))
    h = hashlib.sha256()
    for s in V05_SPLITS:
        with open(os.path.join(ds_dir, f"{s}.pt"), "rb") as f:
            h.update(hashlib.sha256(f.read()).digest())
    ds_hash, summary = h.hexdigest(), None
    try:
        n_params = sum(p.numel() for p in JevPolicyV0().parameters())
    except Exception:
        n_params = None
    summary = {"device": device, "model_version": MODEL_V05_VERSION,
               "model_config": MODEL_CONFIG, "train_defaults": TRAIN_DEFAULTS,
               "n_parameters": n_params, "dataset_hash": ds_hash,
               "init": "from_scratch", "seeds": {}}
    for seed in seeds:
        run = train_one_seed(
            os.path.join(ds_dir, "train.pt"),
            os.path.join(ds_dir, "validation.pt"), seed, device,
            log_fn=lambda m: print(f"  {m}", flush=True),
            dataset_cls=JevFullInfoDatasetV5)
        model = JevPolicyV0()
        model.load_state_dict(run["best_state_dict"])
        ckpt = build_checkpoint(
            model, MODEL_CONFIG, run["config"], seed, run["best_epoch"],
            run["history"], {"best_val_loss": run["best_val_loss"]}, pins, ds_hash,
            model_version=MODEL_V05_VERSION,
            extra_metadata={"init": "from_scratch",
                            "dataset_version": "jev-fullinfo-dataset-v0.5.0"})
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
    print("STAGE offline3: v0.2 test, untrained/v0.2/v0.3/v0.4/v0.5", flush=True)
    seed, new_ckpt = _selected_checkpoint(out_root)
    models = {"v02": _load_model(V02_CKPT, device),
              "v03": _load_model(V03_CKPT, device),
              "v04": _load_model(V04_CKPT, device)}
    for s in SEEDS:
        models[f"v05_seed{s}"] = _load_model(
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
        "new_selected": audit_selected_invalid(models[f"v05_seed{seed}"],
                                               device, jobs, new_mask_fn)}
    _write(os.path.join(out_root, "metrics", "offline_invalid.json"), invalid_report)
    if invalid_report["new_selected"]["invalid_rate"] != 0.0:
        raise RuntimeError("new-model selected INVALID != 0 — BLOCKER")
    return {"offline": report, "invalid": invalid_report}


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


def stage_visited_test_v05(out_root: str = OUT_ROOT) -> dict:
    from python_jev.aggregate.drift import collect_policy_set

    print("STAGE visited_test_v05: NEW v0.5 driver on TEST (post-selection)",
          flush=True)
    _seed, new_ckpt = _selected_checkpoint(out_root)
    path = collect_policy_set(
        new_ckpt, "visited_test_v05", _split_jobs("test"),
        os.path.join(out_root, "visited_validation", "visited_test_v05.pt"),
        new_ckpt, log_fn=lambda m: print(f"  {m}", flush=True))
    return {"visited_test_v05": path}


def stage_visited_eval(out_root: str = OUT_ROOT, device: str | None = None) -> dict:
    device = device or _device()
    print("STAGE visited_eval3: v0.4/v0.5 on D_VISITED_VALIDATION_V04", flush=True)
    _seed, new_ckpt = _selected_checkpoint(out_root)
    out = {
        "visited_v04": _eval_visited_set(
            os.path.join(out_root, "visited_validation", "visited_v04.pt"),
            {"v04": V04_CKPT, "v05": new_ckpt}, device),
        "visited_test_v05": _eval_visited_set(
            os.path.join(out_root, "visited_validation", "visited_test_v05.pt"),
            {"v04": V04_CKPT, "v05": new_ckpt}, device),
        "visited_validation_frozen": _eval_visited_set(
            os.path.join(A1_ROOT, "visited_validation", "visited_validation.pt"),
            {"v02": V02_CKPT, "v03": V03_CKPT, "v04": V04_CKPT,
             "v05": new_ckpt}, device),
    }
    _write(os.path.join(out_root, "metrics", "visited.json"), out)
    for name, rep in out.items():
        for tag, m in rep["models"].items():
            print(f"  {name} {tag}: reg={m['mean_regret']:.5f} "
                  f"top1={m['top1']:.3f}", flush=True)
    return out


def stage_depth(out_root: str = OUT_ROOT) -> dict:
    from python_jev.aggregate.drift import depth_for_ckpt

    print("STAGE depth3: v0.2/v0.3/v0.4/v0.5 regret-by-depth", flush=True)
    _seed, new_ckpt = _selected_checkpoint(out_root)
    frozen = os.path.join(D0_DIR, "distributions", "jev_new.pt")
    vv = os.path.join(A1_ROOT, "visited_validation", "visited_validation.pt")
    out = {}
    for name, path in (("frozen_jev_new_set", frozen),
                       ("visited_validation_frozen", vv)):
        out[name] = {"v02": depth_for_ckpt(path, V02_CKPT),
                     "v03": depth_for_ckpt(path, V03_CKPT),
                     "v04": depth_for_ckpt(path, V04_CKPT),
                     "v05": depth_for_ckpt(path, new_ckpt)}
    _write(os.path.join(out_root, "depth", "depth_compare.json"), out)
    return out


def stage_closedloop(out_root: str = OUT_ROOT, device: str | None = None) -> dict:
    from python_jev.retrain.closedloop_v1 import run_two_model_v1
    from python_jev.retrain.rebuild_v2 import new_mask_fn

    device = device or _device()
    print("STAGE closedloop3: V1 v0.5 vs v0.4 + frozen v0.2/v0.3 merge",
          flush=True)
    _seed, new_ckpt = _selected_checkpoint(out_root)
    res = run_two_model_v1(_load_model(new_ckpt, device),
                           _load_model(V04_CKPT, device), device,
                           os.path.join(out_root, "closedloop"), new_mask_fn,
                           log_fn=lambda m: print(f"  {m}", flush=True))
    comp = json.load(open(os.path.join(out_root, "closedloop",
                                       "same_seat_comparison.json"),
                          encoding="utf-8"))
    a1 = json.load(open(os.path.join(A1_ROOT, "closedloop",
                                     "same_seat_comparison.json"),
                        encoding="utf-8"))
    # cross-round determinism: shared baselines must reproduce A1 exactly.
    for k in ("SimpleAttackElseAdvancePolicy", "RandomLegalPolicy", "HoldPolicy"):
        a = json.dumps(comp["blue_vs_simple_red"][k], sort_keys=True)
        b = json.dumps(a1["blue_vs_simple_red"][k], sort_keys=True)
        assert a == b, f"baseline drift across rounds: {k}"
    four = {"benchmark_version": comp["benchmark_version"], "mask": comp["mask"],
            "comparability": comp["comparability"], "jobs": comp["jobs"],
            "blue_vs_simple_red": {
                "v05": comp["blue_vs_simple_red"]["NEW_JEV"],
                "v04": comp["blue_vs_simple_red"]["OLD_JEV"],
                "v03": a1["blue_vs_simple_red"]["NEW_JEV"],
                "v02": a1["blue_vs_simple_red"]["OLD_JEV"],
                "Simple": comp["blue_vs_simple_red"]["SimpleAttackElseAdvancePolicy"],
                "Random": comp["blue_vs_simple_red"]["RandomLegalPolicy"],
                "Hold": comp["blue_vs_simple_red"]["HoldPolicy"]}}
    _write(os.path.join(out_root, "closedloop", "comparison_4way.json"), four)
    for k, v in four["blue_vs_simple_red"].items():
        print(f"  {k}: dM={v['mean_mission_progress_delta_blue']:+.4f} "
              f"ex={v['mean_exchange_blue_view']:+.1f}", flush=True)
    res["comparison_4way"] = four
    return res


def stage_drift(out_root: str = OUT_ROOT) -> dict:
    from python_jev.aggregate.drift import (
        collect_policy_set,
        contact_metrics,
        latent_compare,
        shift_compare,
    )
    from python_jev.diagnose.collect import matched_jobs

    print("STAGE drift3: v0.5 trajectories + 4-way contact/shift/latent",
          flush=True)
    _seed, new_ckpt = _selected_checkpoint(out_root)
    new_path = collect_policy_set(
        new_ckpt, "drift_v05", matched_jobs(),
        os.path.join(out_root, "drift", "drift_v05.pt"), new_ckpt,
        log_fn=lambda m: print(f"  {m}", flush=True))
    paths = {"iid_test": os.path.join(D0_DIR, "distributions", "iid_test.pt"),
             "v02_visited": os.path.join(D0_DIR, "distributions", "jev_new.pt"),
             "v03_visited": os.path.join(A1_ROOT, "drift", "drift_new.pt"),
             "v04_visited": os.path.join(A2_ROOT, "drift", "drift_v04.pt"),
             "v05_visited": new_path}
    frozen = json.load(open(os.path.join(A2_ROOT, "drift", "drift.json"),
                            encoding="utf-8"))["contact"]
    contact = {"v02": frozen["v02"], "v03": frozen["v03"], "v04": frozen["v04"],
               "v05": contact_metrics(new_path, new_ckpt)}
    out = {"contact": contact,
           "shift": shift_compare({k: v for k, v in paths.items()
                                   if k != "iid_test"} | {"iid_test": paths["iid_test"]}),
           "latent": latent_compare(V02_CKPT, os.path.join(V02_DIR, "train.pt"),
                                    paths),
           "drift_v05_set": new_path}
    _write(os.path.join(out_root, "drift", "drift.json"), out)
    print(f"  scout EVADE v04={contact['v04']['scout_evade_freq']:.3f} "
          f"v05={contact['v05']['scout_evade_freq']:.3f} "
          f"recon_v05={contact['v05']['scout_recon_freq']:.3f}", flush=True)
    return out


def stage_scout(out_root: str = OUT_ROOT) -> dict:
    import math
    from collections import Counter

    from python_jev.constants import ACTION_SPACE
    from python_jev.diagnose.collect import load_set

    print("STAGE scout3: SCOUT behavior v02..v05 + teacher", flush=True)
    drift = json.load(open(os.path.join(out_root, "drift", "drift.json"),
                           encoding="utf-8"))["contact"]
    payload = load_set(os.path.join(out_root, "drift", "drift_v05.pt"),
                       verify=True)
    teacher = Counter()
    teacher_n = 0
    for i, prov in enumerate(payload["provenance"]):
        if prov["actor_class"] != "SCOUT":
            continue
        teacher_n += 1
        legal = [bool(x) for x in payload["tensors"]["legal"][i].tolist()]
        q = payload["tensors"]["teacher_q"][i, 0].tolist()
        qf = [(None if math.isnan(v) else v) for v in q]
        teacher[ACTION_SPACE["SCOUT"][max(
            [a for a in range(6) if legal[a]], key=lambda a: qf[a])]] += 1
    out = {
        "policy_scout_dist": {k: {"n": drift[k]["scout_n"],
                                  "dist": drift[k]["scout_skill_dist"],
                                  "evade": drift[k]["scout_evade_freq"],
                                  "recon": drift[k]["scout_recon_freq"]}
                              for k in ("v02", "v03", "v04", "v05")},
        "teacher_on_drift_v05": {"n": teacher_n, "dist": dict(teacher),
                                 "evade": teacher.get("EVADE", 0) / max(1, teacher_n),
                                 "recon": teacher.get("RECON_ADVANCE", 0) / max(1, teacher_n)},
    }
    _write(os.path.join(out_root, "scout", "scout.json"), out)
    for k, v in out["policy_scout_dist"].items():
        print(f"  {k}: evade={v['evade']:.3f} recon={v['recon']:.3f}", flush=True)
    t = out["teacher_on_drift_v05"]
    print(f"  teacher: evade={t['evade']:.3f} recon={t['recon']:.3f}", flush=True)
    return out


def stage_disagree(out_root: str = OUT_ROOT, device: str | None = None) -> dict:
    import math

    from python_jev.aggregate.dataset_v03 import labels_for_state
    from python_jev.aggregate.drift import driver_sels
    from python_jev.diagnose.collect import load_set

    device = device or _device()
    print("STAGE disagree3: v0.4/v0.5 vs teacher on Round-3 states", flush=True)
    _seed, new_ckpt = _selected_checkpoint(out_root)
    payload = load_set(os.path.join(out_root, "round3_collection",
                                    "dagger3_unique.pt"), verify=True)
    n = payload["n_records"]
    fw5 = driver_sels(_load_model(new_ckpt, device), payload)
    sel4 = payload["tensors"]["sel_new"].tolist()
    prob4 = payload["tensors"]["prob_new"].tolist()
    stats = {}
    for tag, sels, probs in (("v04", sel4, prob4), ("v05", fw5["sel"], fw5["prob"])):
        agree = reg_sum = psel_sum = js_sum = 0.0
        for i in range(n):
            legal = [bool(x) for x in payload["tensors"]["legal"][i].tolist()]
            q = payload["tensors"]["teacher_q"][i, 0].tolist()
            qf = [(None if math.isnan(v) else v) for v in q]
            _qv, _qm, p_target = labels_for_state(qf, legal)
            top = max([a for a in range(6) if legal[a]], key=lambda a: qf[a])
            best = max(v for v, ok in zip(qf, legal) if ok)
            s = int(sels[i])
            agree += (s == top)
            reg_sum += max(0.0, best - qf[s])
            psel_sum += p_target[s]
            m = [(a + b) / 2 for a, b in zip(probs[i], p_target)]
            kl_pm = sum(a * math.log(a / c) for a, c in zip(probs[i], m) if a > 0)
            kl_tm = sum(b * math.log(b / c) for b, c in zip(p_target, m) if b > 0)
            js_sum += 0.5 * (kl_pm + kl_tm)
        stats[tag] = {"agreement": agree / n,
                      "mean_current_action_regret": reg_sum / n,
                      "mean_selected_p_target": psel_sum / n,
                      "mean_js_to_teacher": js_sum / n}
    out = {"n": n, "models": stats,
           "agreement_gain_v05_minus_v04":
               stats["v05"]["agreement"] - stats["v04"]["agreement"]}
    _write(os.path.join(out_root, "metrics", "disagreement.json"), out)
    for tag, s in stats.items():
        print(f"  {tag}: agree={s['agreement']:.3f} "
              f"reg={s['mean_current_action_regret']:.5f} "
              f"js={s['mean_js_to_teacher']:.4f}", flush=True)
    return out


def stage_exam(out_root: str = OUT_ROOT, device: str | None = None) -> dict:
    import copy

    from python_jev.model import JevPolicyV0
    from python_jev.retrain.rebuild_v2 import new_mask_fn
    from python_jev.training.exam import build_exam_cases, run_exam

    device = device or _device()
    print("STAGE exam3: 60 cases x5", flush=True)
    _seed, new_ckpt = _selected_checkpoint(out_root)
    torch.manual_seed(0)
    models = {"untrained": JevPolicyV0().to(device).eval(),
              "v02": _load_model(V02_CKPT, device),
              "v03": _load_model(V03_CKPT, device),
              "v04": _load_model(V04_CKPT, device),
              "v05": _load_model(new_ckpt, device)}
    out: dict = {"mask": "observation-safe-skill-mask-v0.2.0", "models": {}}
    for name, model in models.items():
        rep = run_exam(model, device, copy.deepcopy(build_exam_cases()),
                       mask_fn=new_mask_fn)
        out["models"][name] = {"summary": rep["summary"]}
        print(f"  {name}: reg={rep['summary']['overall']['mean_regret']:.4f}",
              flush=True)
    _write(os.path.join(out_root, "exam", "exam.json"), out)
    return out


def stage_oracle(out_root: str = OUT_ROOT) -> dict:
    print("STAGE oracle3: frozen oracle gap vs v0.2..v0.5", flush=True)
    d0 = json.load(open(os.path.join(D0_DIR, "oracle_closedloop", "report.json"),
                        encoding="utf-8"))
    a2_gap = json.load(open(os.path.join(A2_ROOT, "metrics", "oracle_gap.json"),
                            encoding="utf-8"))
    v1_new = json.load(open(os.path.join(out_root, "closedloop", "v1_new_model.json"),
                            encoding="utf-8"))
    sub = [b for b in v1_new["conditions"]["blue=JEV_vs_red=Simple"]["battles"]
           if b["scenario_id"] in d0["subset_scenario_ids"]]
    assert len(sub) == 6
    new_ex = sum(b["exchange_blue_view"] for b in sub) / 6.0
    new_dm = sum(b["mission_progress_delta_blue"] for b in sub) / 6.0
    o_ex = d0["oracles"]["CounterfactualGreedySimple"]["summary"]["mean_exchange_blue_view"]
    old_ex = a2_gap["v02_exchange"]
    gap = {"oracle_exchange": o_ex, "v02_exchange": old_ex,
           "v03_exchange": a2_gap["v03_exchange"],
           "v04_exchange": a2_gap["v04_exchange"], "v05_exchange": new_ex,
           "v05_dM": new_dm,
           "gap_closed_fraction_v05": ((new_ex - old_ex) / (o_ex - old_ex)
                                       if o_ex != old_ex else None),
           "gap_closed_fraction_v04": a2_gap["gap_closed_fraction_v04"],
           "gap_closed_fraction_v03": a2_gap["gap_closed_fraction_v03"]}
    _write(os.path.join(out_root, "oracle", "oracle_gap.json"), gap)
    print(f"  oracle={o_ex:+.1f} v02={old_ex:+.1f} "
          f"v03={a2_gap['v03_exchange']:+.1f} v04={a2_gap['v04_exchange']:+.1f} "
          f"v05={new_ex:+.1f} closed_v05={gap['gap_closed_fraction_v05']}",
          flush=True)
    return gap


def stage_success_metrics(out_root: str = OUT_ROOT) -> dict:
    def load(rel: str) -> dict:
        with open(os.path.join(out_root, rel), encoding="utf-8") as f:
            return json.load(f)

    offline = load("metrics/offline.json")["models"]
    visited = load("metrics/visited.json")
    depth = load("depth/depth_compare.json")
    four = load("closedloop/comparison_4way.json")["blue_vs_simple_red"]
    drift = load("drift/drift.json")
    gap = load("oracle/oracle_gap.json")
    new_key = f"v05_seed{load('metrics/training_history.json')['selected_seed']}"
    metrics = {
        "iid": {k: {"regret": offline[m]["aggregate"]["mean_regret"],
                    "top1": offline[m]["aggregate"]["top1"]}
                for k, m in (("v02", "v02"), ("v03", "v03"), ("v04", "v04"),
                             ("v05", new_key))},
        "visited_v04": {k: {"regret": visited["visited_v04"]["models"][k]["mean_regret"],
                            "top1": visited["visited_v04"]["models"][k]["top1"]}
                        for k in ("v04", "v05")},
        "visited_frozen": {k: {"regret": visited["visited_validation_frozen"]["models"][k]["mean_regret"],
                               "top1": visited["visited_validation_frozen"]["models"][k]["top1"]}
                           for k in ("v02", "v03", "v04", "v05")},
        "depth_trend": {k: depth["frozen_jev_new_set"][k]["trend_late_minus_early"]
                        for k in ("v02", "v03", "v04", "v05")},
        "closedloop": {k: {"dM": four[k]["mean_mission_progress_delta_blue"],
                           "ex": four[k]["mean_exchange_blue_view"]}
                       for k in ("v02", "v03", "v04", "v05", "Simple")},
        "scout": {k: {"evade": drift["contact"][k]["scout_evade_freq"],
                      "recon": drift["contact"][k]["scout_recon_freq"]}
                  for k in ("v02", "v03", "v04", "v05")},
        "latent": {k: drift["latent"]["sets"][s]["mean"] for k, s in
                   (("v02", "v02_visited"), ("v03", "v03_visited"),
                    ("v04", "v04_visited"), ("v05", "v05_visited"))},
        "disagreement": load("metrics/disagreement.json"),
        "novelty": load("round3_collection/crossdedup.json"),
        "oracle_gap_closed_v05": gap["gap_closed_fraction_v05"],
        "oracle_gap_closed_v04": gap["gap_closed_fraction_v04"],
        "invalid_new": load("metrics/offline_invalid.json")["new_selected"]["invalid_rate"],
    }
    _write(os.path.join(out_root, "metrics", "success_metrics.json"), metrics)
    print(json.dumps(metrics, indent=1), flush=True)
    return metrics


STAGES = {
    "pilot": stage_pilot,
    "collect": stage_collect,
    "crossdedup": stage_crossdedup,
    "recover": stage_recover,
    "visited_v04": stage_visited_v04,
    "dataset": stage_dataset,
    "overfit": stage_overfit,
    "train": stage_train,
    "offline": stage_offline,
    "visited_test_v05": stage_visited_test_v05,
    "visited_eval": stage_visited_eval,
    "depth": stage_depth,
    "closedloop": stage_closedloop,
    "drift": stage_drift,
    "scout": stage_scout,
    "disagree": stage_disagree,
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
