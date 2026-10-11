"""D0 Parts I–J — covariate-shift stats, latent diagnostic, depth buckets.

Interpretable feature comparison uses plain battle readouts (no learned
embeddings). The latent check is read-only via a forward hook on the
frozen trunk — no head added, no weights touched.
"""

from __future__ import annotations

import math
import os
import random

import torch

from python_jev.diagnose.collect import FEATURE_NAMES, SETS, load_set


def feature_stats(dist_dir: str) -> dict:
    """Per-set numeric/categorical summaries + standardized shifts."""
    per_set: dict[str, dict] = {}
    for s in SETS:
        payload = load_set(os.path.join(dist_dir, f"{s}.pt"))
        feats = payload["tensors"]["features"].float()
        means = feats.mean(dim=0).tolist()
        stds = feats.std(dim=0, unbiased=False).tolist()
        cats: dict[str, dict[str, int]] = {}
        for key in ("actor_class", "mission", "side", "profile", "split"):
            counts: dict[str, int] = {}
            for p in payload["provenance"]:
                counts[str(p[key])] = counts.get(str(p[key]), 0) + 1
            cats[key] = counts
        per_set[s] = {
            "n": payload["n_records"],
            "numeric": {name: {"mean": means[i], "std": stds[i]}
                        for i, name in enumerate(FEATURE_NAMES)},
            "categorical": cats,
        }
    comparisons = {}
    for a, b in (("iid_test", "jev_new"), ("simple", "jev_new")):
        ranked = []
        for i, name in enumerate(FEATURE_NAMES):
            ma, sa = per_set[a]["numeric"][name]["mean"], per_set[a]["numeric"][name]["std"]
            mb, sb = per_set[b]["numeric"][name]["mean"], per_set[b]["numeric"][name]["std"]
            pooled = math.sqrt((sa ** 2 + sb ** 2) / 2.0)
            d = (mb - ma) / pooled if pooled > 1e-12 else 0.0
            ranked.append({"feature": name, "mean_a": ma, "mean_b": mb, "cohens_d": d})
        ranked.sort(key=lambda r: -abs(r["cohens_d"]))
        comparisons[f"{a}_vs_{b}"] = ranked
    return {"per_set": per_set, "comparisons": comparisons}


def _batch_obs(payload: dict, idx: list[int]):
    from python_jev.constants import PATCH_NUM_CELLS
    from python_jev.observation import ObservationBatchV0

    t = payload["tensors"]
    sel = torch.tensor(idx, dtype=torch.long)
    return ObservationBatchV0(
        actor_features=t["actor"][sel],
        tokens=t["tokens"][sel],
        token_padding_mask=t["token_pad"][sel],
        hex_patch=t["hex"][sel],
        hex_padding_mask=torch.zeros(len(idx), PATCH_NUM_CELLS, dtype=torch.bool),
        mission_features=t["mission"][sel],
        global_features=t["global"][sel],
        legal_mask=t["legal"][sel],
        acting_class_idx=t["class_idx"][sel],
        metadata={},
    )


@torch.no_grad()
def _latents_for(model, payload: dict, batch_size: int = 256) -> torch.Tensor:
    captured: list[torch.Tensor] = []
    handle = model.trunk.register_forward_hook(
        lambda _m, _i, o: captured.append(o.detach().cpu()))
    try:
        model.eval()
        n = payload["n_records"]
        for lo in range(0, n, batch_size):
            idx = list(range(lo, min(n, lo + batch_size)))
            model(_batch_obs(payload, idx).to("cpu", torch.float32))
    finally:
        handle.remove()
    return torch.cat(captured, dim=0)


def latent_diagnostic(dist_dir: str, new_ckpt: str,
                      train_shard: str, n_train: int = 2000) -> dict:
    """Nearest-neighbor distance of each set's fused latents to train latents."""
    from python_jev.model import JevPolicyV0
    from python_jev.retrain.data_v2 import JevFullInfoDatasetV2
    from python_jev.training.checkpoint import load_checkpoint

    model = JevPolicyV0().eval()
    load_checkpoint(new_ckpt, model)
    ds = JevFullInfoDatasetV2(train_shard)
    perm = torch.randperm(len(ds), generator=torch.Generator().manual_seed(7))[:n_train]
    train_payload = {"n_records": n_train, "tensors": {
        "actor": ds.tensors["actor"][perm], "tokens": ds.tensors["tokens"][perm],
        "token_pad": ds.tensors["token_pad"][perm], "hex": ds.tensors["hex"][perm],
        "mission": ds.tensors["mission"][perm], "global": ds.tensors["global"][perm],
        "class_idx": ds.tensors["class_idx"][perm], "legal": ds.tensors["legal"][perm]}}
    lat_train = _latents_for(model, train_payload)
    ref = torch.cdist(lat_train[:1000], lat_train[1000:]).min(dim=1).values
    out: dict = {
        "method": "euclidean NN distance of fused trunk latent (512-d, "
                  "read-only forward hook) to 2000 seeded train latents",
        "train_reference": {"n": 1000, "mean": float(ref.mean()),
                            "p50": float(ref.median()),
                            "p90": float(torch.quantile(ref, torch.tensor(0.90)))},
        "sets": {},
    }
    for s in SETS:
        payload = load_set(os.path.join(dist_dir, f"{s}.pt"))
        lat = _latents_for(model, payload)
        nn = torch.cdist(lat, lat_train).min(dim=1).values
        out["sets"][s] = {"n": int(nn.numel()), "mean": float(nn.mean()),
                          "p50": float(nn.median()),
                          "p90": float(torch.quantile(nn, torch.tensor(0.90))),
                          "max": float(nn.max())}
    return out


def trajectory_depth(dist_dir: str) -> dict:
    """Part J: NEW-JEV regret under Q_simple by trajectory-step bucket."""
    buckets = [(0, 4), (5, 9), (10, 19), (20, 10 ** 9)]
    out: dict[str, dict] = {}
    for s in SETS:
        payload = load_set(os.path.join(dist_dir, f"{s}.pt"))
        sel = payload["tensors"]["sel_new"].tolist()
        grouped: dict[str, list[float]] = {}
        for i, prov in enumerate(payload["provenance"]):
            step = int(prov["trajectory_step"])
            label = next(f"{lo}-{hi if hi < 10 ** 9 else '+'}" for lo, hi in buckets
                         if lo <= step <= hi)
            legal = [bool(x) for x in payload["tensors"]["legal"][i].tolist()]
            q = payload["tensors"]["teacher_q"][i, 0].tolist()
            qf = [(None if math.isnan(v) else float(v)) for v in q]
            best = max(v for v, ok in zip(qf, legal) if ok)
            r = max(0.0, best - qf[int(sel[i])])
            grouped.setdefault(label, []).append(r)
        stats = {}
        for lo, hi in buckets:
            label = f"{lo}-{hi if hi < 10 ** 9 else '+'}"
            v = grouped.get(label, [])
            vs = sorted(v)
            stats[label] = {"n": len(v),
                            "mean": sum(v) / len(v) if v else None,
                            "median": vs[len(vs) // 2] if vs else None,
                            "p95": vs[min(len(vs) - 1, int(0.95 * len(vs)))] if vs else None}
        early = stats["0-4"]["mean"]
        late = stats["20-+"]["mean"]
        stats["trend_late_minus_early"] = (
            late - early if early is not None and late is not None else None)
        out[s] = stats
    return out


__all__ = ["feature_stats", "latent_diagnostic", "trajectory_depth"]
