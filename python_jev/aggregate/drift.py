"""A1 drift/shift/depth analysis on OLD vs NEW policy trajectories.

All comparisons run on matched scenarios with driver selections computed
by forwarding each checkpoint over stored observations (uniform path —
stored sel_new always reflects the v0.2 checkpoint, never the driver).
"""

from __future__ import annotations

import math
import os
from concurrent.futures import ProcessPoolExecutor

import torch

ATTACK_SLOT = {"INFANTRY": 0, "SPEARMAN": 0, "CAVALRY": 0, "ARCHER": 0, "SCOUT": 2}


def collect_policy_set(driver_ckpt: str, set_name: str,
                       jobs: list[tuple[int, str, bool, str]], out_path: str,
                       ref_ckpt: str, log_fn=None) -> str:
    """One driver on matched scenarios (driver selections forwarded later).

    The reference ckpt scores stored sel_old/sel_new (provenance only);
    driver selections are forwarded at analysis time (see driver_sels).
    """
    from python_jev.diagnose.collect import (
        N_WORKERS,
        collect_job,
        save_distribution_set,
    )

    log = log_fn or (lambda m: print(m, flush=True))
    extra = {"driver_ckpt": driver_ckpt, "driver_label": set_name}
    work = [(set_name, i, p, o, sp, ref_ckpt, ref_ckpt, extra)
            for (i, p, o, sp) in jobs]
    rows: list[dict] = []
    with ProcessPoolExecutor(max_workers=N_WORKERS) as pool:
        for n, res in enumerate(pool.map(collect_job, work)):
            rows.extend(res["rows"])
            if (n + 1) % 30 == 0:
                log(f"  jobs {n + 1}/{len(work)} rows={len(rows)}")
    rows.sort(key=lambda r: (r["scenario_id"], r["trajectory_step"]))
    save_distribution_set(out_path, set_name, rows)
    log(f"  {set_name}: {len(rows)} states -> {out_path}")
    return out_path


def _load_model(ckpt_path: str):
    from python_jev.model import JevPolicyV0
    from python_jev.training.checkpoint import load_checkpoint

    model = JevPolicyV0().eval()
    load_checkpoint(ckpt_path, model)
    return model


@torch.no_grad()
def driver_sels(model, payload: dict, batch_size: int = 256) -> dict:
    """Forward selections + entropy for every row (uniform path)."""
    from python_jev.diagnose.shift import _batch_obs

    model.eval()
    n = payload["n_records"]
    sels, probs = [], []
    for lo in range(0, n, batch_size):
        idx = list(range(lo, min(n, lo + batch_size)))
        out = model(_batch_obs(payload, idx).to("cpu", torch.float32))
        sels.extend(int(x) for x in out.selected_slot.cpu().tolist())
        probs.extend(out.probabilities.cpu().tolist())
    ent = [-sum(v * math.log(v) for v in p if v > 0) for p in probs]
    return {"sel": sels, "prob": probs, "entropy": ent}


def contact_metrics(set_path: str, driver_ckpt: str) -> dict:
    """Part P/Q contact-drift metrics for one trajectory set."""
    from collections import Counter

    from python_jev.constants import ACTION_SPACE
    from python_jev.diagnose.collect import FEATURE_NAMES, load_set

    payload = load_set(set_path, verify=True)
    model = _load_model(driver_ckpt)
    fw = driver_sels(model, payload)
    feats = payload["tensors"]["features"].float()
    col = {name: i for i, name in enumerate(FEATURE_NAMES)}
    mean = lambda name: float(feats[:, col[name]].mean())
    n = payload["n_records"]
    atk_legal = atk_opp = 0
    scout = Counter()
    scout_n = 0
    skill_all: Counter = Counter()
    for i, prov in enumerate(payload["provenance"]):
        legal = [bool(x) for x in payload["tensors"]["legal"][i].tolist()]
        a_slot = ATTACK_SLOT[prov["actor_class"]]
        atk_legal += legal[a_slot]
        q = payload["tensors"]["teacher_q"][i, 0].tolist()
        qf = [(None if math.isnan(v) else v) for v in q]
        top = max([a for a in range(6) if legal[a]], key=lambda a: qf[a])
        atk_opp += (top == a_slot)
        sk = ACTION_SPACE[prov["actor_class"]][fw["sel"][i]]
        skill_all[sk] += 1
        if prov["actor_class"] == "SCOUT":
            scout_n += 1
            scout[sk] += 1
    return {
        "n": n,
        "mean_nearest_enemy": mean("min_enemy_dist"),
        "mean_enemy_dist": mean("mean_enemy_dist"),
        "local_enemy_count": mean("patch_enemy"),
        "visible_enemies": mean("visible_enemies"),
        "attack_legal_rate": atk_legal / n,
        "attack_opportunity_rate": atk_opp / n,
        "friendly_dispersion": mean("mean_friendly_dist"),
        "patch_friendly": mean("patch_friendly"),
        "legal_count": mean("legal_count"),
        "policy_entropy": sum(fw["entropy"]) / n,
        "scout_n": scout_n,
        "scout_evade_freq": scout.get("EVADE", 0) / max(1, scout_n),
        "scout_recon_freq": scout.get("RECON_ADVANCE", 0) / max(1, scout_n),
        "scout_skill_dist": dict(scout),
        "skill_dist": dict(skill_all),
    }


def shift_compare(sets: dict[str, str]) -> dict:
    """Pairwise Cohen's d over interpretable features (local, any sets)."""
    from python_jev.diagnose.collect import FEATURE_NAMES, load_set

    stats = {}
    for name, path in sets.items():
        feats = load_set(path, verify=True)["tensors"]["features"].float()
        stats[name] = {"mean": feats.mean(dim=0).tolist(),
                       "std": feats.std(dim=0, unbiased=False).tolist()}
    out = {}
    names = sorted(sets)
    for x in range(len(names)):
        for y in range(x + 1, len(names)):
            a, b = names[x], names[y]
            ranked = []
            for i, feat in enumerate(FEATURE_NAMES):
                ma, sa = stats[a]["mean"][i], stats[a]["std"][i]
                mb, sb = stats[b]["mean"][i], stats[b]["std"][i]
                pooled = math.sqrt((sa ** 2 + sb ** 2) / 2.0)
                ranked.append({"feature": feat, "mean_a": ma, "mean_b": mb,
                               "cohens_d": (mb - ma) / pooled if pooled > 1e-12 else 0.0})
            ranked.sort(key=lambda r: -abs(r["cohens_d"]))
            out[f"{a}_vs_{b}"] = ranked
    return out


@torch.no_grad()
def latent_compare(fixed_ckpt: str, train_shard: str, sets: dict[str, str],
                   n_train: int = 2000) -> dict:
    """NN-to-train distances in one FIXED latent space (read-only hook)."""
    from python_jev.diagnose.collect import load_set
    from python_jev.diagnose.shift import _batch_obs, _latents_for
    from python_jev.retrain.data_v2 import JevFullInfoDatasetV2

    model = _load_model(fixed_ckpt)
    ds = JevFullInfoDatasetV2(train_shard)
    perm = torch.randperm(len(ds), generator=torch.Generator().manual_seed(7))[:n_train]
    pool = {"n_records": n_train, "tensors": {
        "actor": ds.tensors["actor"][perm], "tokens": ds.tensors["tokens"][perm],
        "token_pad": ds.tensors["token_pad"][perm], "hex": ds.tensors["hex"][perm],
        "mission": ds.tensors["mission"][perm], "global": ds.tensors["global"][perm],
        "class_idx": ds.tensors["class_idx"][perm], "legal": ds.tensors["legal"][perm]}}
    lat_pool = _latents_for(model, pool)
    out = {"fixed_checkpoint": os.path.abspath(fixed_ckpt), "sets": {}}
    for name, path in sets.items():
        lat = _latents_for(model, load_set(path, verify=True))
        nn = torch.cdist(lat, lat_pool).min(dim=1).values
        out["sets"][name] = {"n": int(nn.numel()), "mean": float(nn.mean()),
                             "p50": float(nn.median()),
                             "p90": float(torch.quantile(nn, torch.tensor(0.90)))}
    return out


def depth_for_ckpt(set_path: str, ckpt_path: str) -> dict:
    """Regret-by-depth buckets under stored Q_simple for one checkpoint."""
    from python_jev.diagnose.collect import load_set

    payload = load_set(set_path, verify=True)
    fw = driver_sels(_load_model(ckpt_path), payload)
    buckets = [(0, 4), (5, 9), (10, 19), (20, 10 ** 9)]
    grouped: dict[str, list[float]] = {}
    for i, prov in enumerate(payload["provenance"]):
        step = int(prov["trajectory_step"])
        label = next(f"{lo}-{hi if hi < 10 ** 9 else '+'}" for lo, hi in buckets
                     if lo <= step <= hi)
        legal = [bool(x) for x in payload["tensors"]["legal"][i].tolist()]
        q = payload["tensors"]["teacher_q"][i, 0].tolist()
        qf = [(None if math.isnan(v) else v) for v in q]
        best = max(v for v, ok in zip(qf, legal) if ok)
        grouped.setdefault(label, []).append(max(0.0, best - qf[fw["sel"][i]]))
    stats = {}
    for lo, hi in buckets:
        label = f"{lo}-{hi if hi < 10 ** 9 else '+'}"
        v = sorted(grouped.get(label, []))
        stats[label] = {"n": len(v),
                        "mean": sum(v) / len(v) if v else None,
                        "median": v[len(v) // 2] if v else None}
    e, l = stats["0-4"]["mean"], stats["20-+"]["mean"]
    stats["trend_late_minus_early"] = l - e if e is not None and l is not None else None
    return stats


def scout_boundary(set_path: str) -> dict:
    """A2.2: teacher-EVADE vs teacher-RECON SCOUT states, existing features.

    Diagnostic only: compares the two teacher classes on the 27 stored
    interpretable features (no new features invented) and reports
    whether round-2 collection covers both sides of the boundary.
    """
    from collections import Counter

    from python_jev.constants import ACTION_SPACE
    from python_jev.diagnose.collect import FEATURE_NAMES, load_set

    payload = load_set(set_path, verify=True)
    sel = payload["tensors"]["sel_new"].tolist()
    feats = payload["tensors"]["features"].float()
    evade_rows, recon_rows = [], []
    policy_counts: Counter = Counter()
    teacher_counts: Counter = Counter()
    n_scout = 0
    for i, prov in enumerate(payload["provenance"]):
        if prov["actor_class"] != "SCOUT":
            continue
        n_scout += 1
        legal = [bool(x) for x in payload["tensors"]["legal"][i].tolist()]
        q = payload["tensors"]["teacher_q"][i, 0].tolist()
        qf = [(None if math.isnan(v) else v) for v in q]
        top = max([a for a in range(6) if legal[a]], key=lambda a: qf[a])
        teacher_counts[ACTION_SPACE["SCOUT"][top]] += 1
        policy_counts[ACTION_SPACE["SCOUT"][int(sel[i])]] += 1
        if ACTION_SPACE["SCOUT"][top] == "EVADE":
            evade_rows.append(i)
        elif ACTION_SPACE["SCOUT"][top] == "RECON_ADVANCE":
            recon_rows.append(i)
    diffs = []
    for j, name in enumerate(FEATURE_NAMES):
        a = feats[evade_rows, j].tolist() if evade_rows else []
        b = feats[recon_rows, j].tolist() if recon_rows else []
        if not a or not b:
            continue
        ma, mb = sum(a) / len(a), sum(b) / len(b)
        va = sum((x - ma) ** 2 for x in a) / len(a)
        vb = sum((x - mb) ** 2 for x in b) / len(b)
        pooled = math.sqrt((va + vb) / 2.0)
        diffs.append({"feature": name, "mean_teacher_evade": ma,
                      "mean_teacher_recon": mb,
                      "cohens_d": (mb - ma) / pooled if pooled > 1e-12 else 0.0})
    diffs.sort(key=lambda r: -abs(r["cohens_d"]))
    return {"scout_states": n_scout,
            "teacher_evade": len(evade_rows),
            "teacher_recon": len(recon_rows),
            "teacher_skill_counts": dict(teacher_counts),
            "policy_skill_counts": dict(policy_counts),
            "both_sides_covered": bool(evade_rows and recon_rows),
            "feature_differences": diffs}


__all__ = ["ATTACK_SLOT", "collect_policy_set", "contact_metrics",
           "depth_for_ckpt", "driver_sels", "latent_compare",
           "scout_boundary", "shift_compare"]
