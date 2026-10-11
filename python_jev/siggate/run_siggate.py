"""Siggate stage orchestrator: verify -> gates -> overfit -> train -> eval.

Experimental ablation only. No new collection, no production freeze.
"""

from __future__ import annotations

import hashlib
import json
import os
import sys

import torch

from python_jev.siggate import ARM_NAMES, OUT_ROOT, SEEDS, SIGGATE_VERSION

V04_CKPT = os.path.join("artifacts", "jev_dagger_v1", "checkpoints", "seed44.pt")
V05_CKPT = os.path.join("artifacts", "jev_dagger_v2", "checkpoints", "seed44.pt")
V05_DIR = os.path.join("artifacts", "jev_dagger_v2", "dataset_v05")
V04_DIR = os.path.join("artifacts", "jev_dagger_v1", "dataset_v04")


def _device() -> str:
    want = os.environ.get("A1_DEVICE", "cpu")
    if want == "cuda" and torch.cuda.is_available():
        return "cuda"
    return "cpu"


def _write(path: str, obj: dict) -> None:
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=1, sort_keys=True)


def stage_verify(out_root: str = OUT_ROOT) -> dict:
    """SG0-1: source hashes + integrity of every frozen input."""
    from python_jev.aggregate.dataset_v04 import load_shard_v04
    from python_jev.aggregate.dataset_v05 import V04_CKPT_SHA256, V04_TRAIN_SHA256
    from python_jev.aggregate.dataset_v05 import load_shard_v05
    from python_jev.aggregate.gather import collection_ckpt_hash
    from python_jev.diagnose.collect import load_set
    from python_jev.siggate.gates import D3_SET, D3_XD, V05_TRAIN

    print("STAGE verify: frozen source integrity", flush=True)
    v04_ckpt = collection_ckpt_hash(V04_CKPT)
    assert v04_ckpt == V04_CKPT_SHA256, "v0.4 driver bytes drifted"
    with open(os.path.join(V04_DIR, "train.pt"), "rb") as f:
        v04_train = hashlib.sha256(f.read()).hexdigest()
    assert v04_train == V04_TRAIN_SHA256, "v0.4 train bytes drifted"
    with open(os.path.join(V05_DIR, "train.pt"), "rb") as f:
        v05_train_file = hashlib.sha256(f.read()).hexdigest()
    v05 = load_shard_v05(V05_TRAIN, verify=True)
    v04 = load_shard_v04(os.path.join(V04_DIR, "train.pt"), verify=True)
    d3 = load_set(D3_SET, verify=True)
    with open(D3_XD, encoding="utf-8") as f:
        xd = json.load(f)
    v05_ckpt = collection_ckpt_hash(V05_CKPT)
    # v0.5 carried prefix must equal v0.4 train exactly
    n0 = v04["n_records"]
    for k in ("actor", "tokens", "hex", "mission", "global", "q", "p_target",
              "token_pad", "legal", "q_valid", "class_idx"):
        assert torch.equal(v05["tensors"][k][:n0], v04["tensors"][k]), k
    rep = {"v04_ckpt_sha256": v04_ckpt, "v04_train_sha256": v04_train,
           "v04_train_shard_hash": v04["shard_hash"],
           "v05_train_file_sha256": v05_train_file,
           "v05_train_shard_hash": v05["shard_hash"],
           "v05_train_rows": v05["n_records"],
           "v05_ckpt_sha256": v05_ckpt,
           "d3_set_hash": d3["set_hash"], "d3_rows": d3["n_records"],
           "d3_novel": xd["new_unique"],
           "new_states_collected": 0}
    _write(os.path.join(out_root, "summary", "sources.json"), rep)
    print(f"  v0.4 ckpt+train pinned; v0.5 train {v05['n_records']} rows; "
          f"d3 novel {xd['new_unique']}", flush=True)
    return rep


def stage_gates(out_root: str = OUT_ROOT) -> dict:
    from python_jev.siggate.audit import gate_stats
    from python_jev.siggate.gates import build_manifests, dagger3_signals

    print("STAGE gates: deterministic arm manifests + audit", flush=True)
    manifests = build_manifests(os.path.join(out_root, "manifests"))
    signals = dagger3_signals()
    stats = gate_stats(manifests, signals, os.path.join(out_root, "gate_stats"))
    for arm in ARM_NAMES:
        s = stats[arm]
        print(f"  {arm}: kept={s['retained']} frac={s['frac_retained']:.3f} "
              f"corr={s['correction_frac']:.3f} tie_kept={s['tie_retained']} "
              f"large={s['large_retained']}/{s['large_total']}", flush=True)
    return stats


def stage_overfit(out_root: str = OUT_ROOT, device: str | None = None) -> dict:
    """Part G: one mixed tiny-overfit per arm (base + retained D3)."""
    import time

    from python_jev.aggregate.dataset_v05 import (
        DATASET_V05_VERSION,
        load_shard_v05,
        pins_v05,
        save_shard_v05,
    )
    from python_jev.aggregate.data_v03 import JevFullInfoDatasetV5
    from python_jev.aggregate.dataset_v03 import v02_combined_hash
    from python_jev.aggregate.gather import collection_ckpt_hash
    from python_jev.siggate.gates import V05_TRAIN, load_manifest
    from python_jev.training.overfit_gate import run_overfit_gate

    device = device or _device()
    print(f"STAGE overfit: mixed tiny gates per arm (device={device})", flush=True)
    shard = load_shard_v05(V05_TRAIN, verify=True)
    t, prov = shard["tensors"], shard["provenance"]
    pins = pins_v05(
        v02_combined_hash(os.path.join("artifacts", "jev_training_v1", "dataset")),
        collection_ckpt_hash(os.path.join("artifacts", "jev_training_v1",
                                          "checkpoints", "seed43.pt")),
        collection_ckpt_hash(os.path.join("artifacts", "jev_dagger_v0",
                                          "checkpoints", "seed43.pt")),
        collection_ckpt_hash(V04_CKPT))
    audit_dir = os.path.join(out_root, "audit")
    os.makedirs(audit_dir, exist_ok=True)
    out: dict = {}
    for arm in ARM_NAMES:
        man = load_manifest(os.path.join(out_root, "manifests", f"{arm}.json"))
        kept = man["retained_train_idx"]
        gen = torch.Generator().manual_seed(11)
        base = torch.randperm(21290, generator=gen)[:96].tolist()
        dk = kept if len(kept) <= 32 else [
            kept[i] for i in torch.randperm(len(kept), generator=gen)[:32].tolist()]

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

        tiny = [rec(i) for i in base + dk]
        t0 = time.perf_counter()
        save_shard_v05(os.path.join(audit_dir, f"tiny_{arm}.pt"), "train", tiny, pins)
        rep = run_overfit_gate(os.path.join(audit_dir, f"tiny_{arm}.pt"), device,
                               dataset_cls=JevFullInfoDatasetV5,
                               log_fn=lambda m: None)
        slim = {k: v for k, v in rep.items() if k != "loss_curve"}
        slim["mix"] = f"96 base + {len(dk)} gated-D3({arm})"
        slim["wall_seconds"] = time.perf_counter() - t0
        out[arm] = slim
        print(f"  {arm}: passed={rep['passed']} final={rep['final_loss']:.4f} "
              f"floor={rep['entropy_floor']:.4f}", flush=True)
        if not rep["passed"]:
            raise RuntimeError(f"tiny-overfit FAILED for arm {arm} — STOP")
    _write(os.path.join(out_root, "audit", "tiny_overfit.json"), out)
    return out


def stage_train(out_root: str = OUT_ROOT, device: str | None = None,
                seeds: tuple[int, ...] = SEEDS,
                arms: tuple[str, ...] = ARM_NAMES) -> dict:
    from python_jev.model import JevPolicyV0
    from python_jev.siggate.gates import arm_train_indices, load_manifest
    from python_jev.siggate.train import save_arm_checkpoint, train_arm_seed

    device = device or _device()
    print(f"STAGE train: arms {arms} seeds {seeds} (device={device})", flush=True)
    n_params = sum(p.numel() for p in JevPolicyV0().parameters())
    assert n_params == 1014430, n_params
    summary: dict = {"siggate_version": SIGGATE_VERSION,
                     "n_parameters": n_params, "arms": {}}
    for arm in arms:
        man = load_manifest(os.path.join(out_root, "manifests", f"{arm}.json"))
        idx = arm_train_indices(man)
        arm_rec: dict = {"manifest_hash": man["manifest_hash"],
                         "train_rows": len(idx), "seeds": {}}
        for seed in seeds:
            run = train_arm_seed(
                arm, idx, seed, device,
                log_fn=lambda m: print(f"  {m}", flush=True))
            path = save_arm_checkpoint(
                arm, run, man["manifest_hash"],
                os.path.join(out_root, "checkpoints", arm), n_params)
            arm_rec["seeds"][str(seed)] = {
                "best_epoch": run["best_epoch"],
                "best_val_loss": run["best_val_loss"],
                "epochs_run": run["epochs_run"],
                "wall_seconds": run["wall_seconds"],
                "samples_per_second": run["samples_per_second"],
                "checkpoint": path.replace("\\", "/"),
                "history": run["history"],
            }
        best = min(arm_rec["seeds"], key=lambda s: arm_rec["seeds"][s]["best_val_loss"])
        arm_rec["selected_seed"] = int(best)
        arm_rec["selection_rule"] = "lowest validation soft-target cross entropy"
        summary["arms"][arm] = arm_rec
        _write(os.path.join(out_root, "checkpoints", arm, "training.json"), arm_rec)
        print(f"  {arm}: selected seed {best} "
              f"val={arm_rec['seeds'][best]['best_val_loss']:.4f}", flush=True)
    _write(os.path.join(out_root, "summary", "training.json"), summary)
    return summary


def selected_ckpts(out_root: str = OUT_ROOT) -> dict[str, str]:
    out = {"v04": V04_CKPT, "v05": V05_CKPT}
    for arm in ARM_NAMES:
        with open(os.path.join(out_root, "checkpoints", arm, "training.json"),
                  encoding="utf-8") as f:
            rec = json.load(f)
        seed = rec["selected_seed"]
        out[arm] = os.path.join(out_root, "checkpoints", arm, f"seed{seed}.pt")
    return out


def stage_offline(out_root: str = OUT_ROOT, device: str | None = None) -> dict:
    """Parts H-M: validation/visited/high/low/agree/scout/IID for all models."""
    from python_jev.diagnose.collect import load_set
    from python_jev.siggate.evaluate import (
        frozen_d3_subsets,
        load_model,
        offline_on_distset,
        offline_on_shard,
        scout_mechanism,
    )
    from python_jev.siggate.gates import D3_SET, dagger3_signals

    device = device or _device()
    print("STAGE offline: all models x all frozen sets", flush=True)
    ckpts = selected_ckpts(out_root)
    models = {tag: load_model(ck, device) for tag, ck in ckpts.items()}
    d3 = load_set(D3_SET, verify=True)
    signals = dagger3_signals()
    subs = frozen_d3_subsets(signals, d3["provenance"])
    vv = load_set(os.path.join("artifacts", "jev_dagger_v2", "visited_validation",
                               "visited_v04.pt"), verify=True)
    vv_frozen = load_set(os.path.join("artifacts", "jev_dagger_v0", "visited_validation",
                                      "visited_validation.pt"), verify=True)
    out: dict = {"subsets": {k: len(v) for k, v in subs.items()}, "models": {}}
    for tag, model in models.items():
        m = {
            "validation": offline_on_shard(
                model, os.path.join(V05_DIR, "validation.pt")),
            "test": offline_on_shard(
                model, os.path.join(V05_DIR, "test.pt")),
            "visited_v04": offline_on_distset(
                model, vv, list(range(vv["n_records"]))),
            "visited_frozen_a1": offline_on_distset(
                model, vv_frozen, list(range(vv_frozen["n_records"]))),
            "d3_high": offline_on_distset(model, d3, subs["high"]),
            "d3_low": offline_on_distset(model, d3, subs["low"]),
            "d3_agree": offline_on_distset(model, d3, subs["agree"]),
            "d3_scout": offline_on_distset(model, d3, subs["scout"]),
        }
        out["models"][tag] = m
        print(f"  {tag}: val={m['validation']['loss']:.4f} "
              f"vv={m['visited_v04']['mean_regret']:.5f} "
              f"hi={m['d3_high']['mean_regret']:.5f} "
              f"agree_top1={m['d3_agree']['top1']:.3f}", flush=True)
    out["scout"] = scout_mechanism(models, d3, subs["scout"])
    _write(os.path.join(out_root, "validation", "offline.json"), out)
    _write(os.path.join(out_root, "scout", "scout.json"), out["scout"])
    _write(os.path.join(out_root, "high_signal", "high.json"),
           {t: v["d3_high"] for t, v in out["models"].items()})
    return out


def stage_closedloop(out_root: str = OUT_ROOT, device: str | None = None) -> dict:
    from python_jev.siggate.evaluate import load_model, oracle_gaps, run_closedloop

    device = device or _device()
    print("STAGE closedloop: V1 per model (8 models)", flush=True)
    ckpts = selected_ckpts(out_root)
    models = {tag: load_model(ck, device) for tag, ck in ckpts.items()}
    res = run_closedloop(models, device, os.path.join(out_root, "closedloop"),
                         log_fn=lambda m: print(f"  {m}", flush=True))
    comp = res["comparison"]["blue_vs_simple_red"]
    for tag in list(models) + ["Simple"]:
        v = comp[tag]
        print(f"  {tag}: dM={v['mean_mission_progress_delta_blue']:+.4f} "
              f"ex={v['mean_exchange_blue_view']:+.1f} "
              f"invalid={v['blue_invalid_rate']}", flush=True)
    gaps = oracle_gaps(res["reports"], os.path.join(out_root, "oracle", "oracle_gap.json"))
    for tag, g in gaps["models"].items():
        print(f"  oracle {tag}: ex={g['exchange']:+.1f} closed={g['gap_closed_fraction']}",
              flush=True)
    return {"closedloop": res["comparison"], "oracle": gaps}


def stage_exam(out_root: str = OUT_ROOT, device: str | None = None) -> dict:
    from python_jev.siggate.evaluate import load_model, run_exams

    device = device or _device()
    print("STAGE exam: 60 cases x8 models", flush=True)
    torch.manual_seed(0)
    ckpts = selected_ckpts(out_root)
    models = {tag: load_model(ck, device) for tag, ck in ckpts.items()}
    out = run_exams(models, device)
    for tag, rep in out.items():
        print(f"  {tag}: reg={rep['mean_regret']:.4f}", flush=True)
    _write(os.path.join(out_root, "exam", "exam.json"), out)
    return out


def stage_gradients(out_root: str = OUT_ROOT) -> dict:
    from python_jev.siggate.evaluate import retained_gradient_check
    from python_jev.siggate.gates import load_manifest

    print("STAGE gradients: retained-signal audit per arm", flush=True)
    pools = {}
    for arm in ARM_NAMES:
        man = load_manifest(os.path.join(out_root, "manifests", f"{arm}.json"))
        pools[arm] = man["retained_train_idx"]
    out = retained_gradient_check(pools, V04_CKPT)
    for arm, rep in out.items():
        print(f"  {arm}: n={rep['n_retained']} norm={rep['grad_norm_512']:.4f} "
              f"cos={rep['cos_vs_original']:.3f}/{rep['cos_vs_dagger1']:.3f}/"
              f"{rep['cos_vs_dagger2']:.3f}", flush=True)
    _write(os.path.join(out_root, "gradients", "retained.json"), out)
    return out


STAGES = {
    "verify": stage_verify,
    "gates": stage_gates,
    "overfit": stage_overfit,
    "train": stage_train,
    "offline": stage_offline,
    "closedloop": stage_closedloop,
    "exam": stage_exam,
    "gradients": stage_gradients,
}


def main(argv: list[str]) -> None:
    which = argv[1:] or list(STAGES)
    for name in which:
        STAGES[name]()


if __name__ == "__main__":
    main(sys.argv)
