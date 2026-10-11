"""Frozen significance signals + deterministic gate membership (Parts A-E).

Signals are derived from the FROZEN horizon-8 Simple-continuation Q stored in
the Dagger3 unique set. Full precision; no rounding before gating. Membership
never uses argmax disagreement (contaminated by exact ties).
"""

from __future__ import annotations

import hashlib
import json
import os

from python_jev.siggate import ARMS, N_BASE_ROWS, SIGGATE_VERSION

V05_TRAIN = os.path.join("artifacts", "jev_dagger_v2", "dataset_v05", "train.pt")
D3_SET = os.path.join("artifacts", "jev_dagger_v2", "round3_collection",
                      "dagger3_unique.pt")
D3_XD = os.path.join("artifacts", "jev_dagger_v2", "round3_collection",
                     "crossdedup.json")


def dagger3_signals() -> list[dict]:
    """One record per novel D3 row (ascending dagger order == v0.5 train order).

    Returns list of {dagger_idx, train_idx, driver_regret, teacher_margin,
    single_legal, teacher_top, driver_sel, legal_n}.
    """
    from python_jev.diagnose.collect import load_set

    payload = load_set(D3_SET, verify=True)
    with open(D3_XD, encoding="utf-8") as f:
        novel = sorted(json.load(f)["novel_indices"])
    t = payload["tensors"]
    sel = t["sel_new"].tolist()
    out: list[dict] = []
    for j, k in enumerate(novel):
        legal = [bool(x) for x in t["legal"][k].tolist()]
        qv = [float(v) for v in t["teacher_q"][k, 0].tolist()]
        lq = sorted([qv[s] for s in range(6) if legal[s]], reverse=True)
        best = lq[0]
        margin = lq[0] - lq[1] if len(lq) > 1 else 0.0
        top = max([s for s in range(6) if legal[s]], key=lambda s: qv[s])
        cur = int(sel[k])
        out.append({
            "dagger_idx": k,
            "train_idx": N_BASE_ROWS + j,
            "driver_regret": max(0.0, best - qv[cur]),
            "teacher_margin": margin,
            "single_legal": sum(legal) <= 1,
            "teacher_top": top,
            "driver_sel": cur,
            "legal_n": sum(legal),
        })
    return out


def arm_predicate(kind: str, regret_thr: float, margin_thr: float, rec: dict) -> bool:
    r, m = rec["driver_regret"], rec["teacher_margin"]
    if kind == "R":
        return r >= regret_thr
    if kind == "M":
        return m >= margin_thr
    if kind == "OR":
        return (r >= regret_thr) or (m >= margin_thr)
    if kind == "AND":
        return (r >= regret_thr) and (m >= margin_thr)
    raise ValueError(f"unknown gate kind {kind!r}")


def gate_membership(signals: list[dict]) -> dict[str, list[int]]:
    """arm -> sorted list of positions into `signals` (== v0.5-train D3 order)."""
    out: dict[str, list[int]] = {}
    for arm, kind, rt, mt in ARMS:
        out[arm] = [j for j, rec in enumerate(signals)
                    if arm_predicate(kind, rt, mt, rec)]
    return out


def manifest_hash(spec: dict) -> str:
    return hashlib.sha256(
        json.dumps(spec, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()


def build_manifests(out_dir: str) -> dict:
    """Write one manifest per arm; returns {arm: manifest}."""
    from python_jev.aggregate.gather import collection_ckpt_hash

    signals = dagger3_signals()
    member = gate_membership(signals)
    total_regret = sum(r["driver_regret"] for r in signals)
    manifests: dict[str, dict] = {}
    os.makedirs(out_dir, exist_ok=True)
    for arm, kind, rt, mt in ARMS:
        keep = member[arm]
        kept_regret = sum(signals[j]["driver_regret"] for j in keep)
        spec = {
            "siggate_version": SIGGATE_VERSION,
            "arm": arm,
            "gate": {"kind": kind, "driver_regret_thr": rt,
                     "teacher_margin_thr": mt},
            "base": {"source": "v0.4-train-prefix-in-v0.5-train",
                     "train_idx": [0, N_BASE_ROWS]},
            "d3_pool": len(signals),
            "retained_positions": keep,
            "retained_train_idx": [signals[j]["train_idx"] for j in keep],
            "retained_dagger_idx": [signals[j]["dagger_idx"] for j in keep],
            "total_train_rows": N_BASE_ROWS + len(keep),
            "d3_correction_total": total_regret,
            "d3_correction_retained": kept_regret,
        }
        spec["manifest_hash"] = manifest_hash(
            {k: v for k, v in spec.items() if k != "manifest_hash"})
        # source pins (read-only references; SG0-1 verifies them)
        spec["sources"] = {
            "v05_train": V05_TRAIN.replace("\\", "/"),
            "dagger3_set": D3_SET.replace("\\", "/"),
            "crossdedup": D3_XD.replace("\\", "/"),
        }
        manifests[arm] = spec
        with open(os.path.join(out_dir, f"{arm}.json"), "w", encoding="utf-8") as f:
            json.dump(spec, f, indent=1, sort_keys=True)
    # keep a copy of the frozen signals for audit (full precision)
    with open(os.path.join(out_dir, "_d3_signals.json"), "w", encoding="utf-8") as f:
        json.dump(signals, f, indent=1)
    _ = collection_ckpt_hash  # import guard: ckpt hashing lives in gather
    return manifests


def load_manifest(manifest_path: str) -> dict:
    with open(manifest_path, encoding="utf-8") as f:
        spec = json.load(f)
    want = spec.pop("manifest_hash")
    # sources are descriptive pins, excluded from the membership hash
    spec.pop("sources", None)
    got = manifest_hash(spec)
    assert got == want, f"manifest hash mismatch: {manifest_path}"
    spec["manifest_hash"] = want
    return spec


def arm_train_indices(manifest: dict) -> list[int]:
    return list(range(N_BASE_ROWS)) + list(manifest["retained_train_idx"])


__all__ = [
    "D3_SET",
    "D3_XD",
    "N_BASE_ROWS",
    "V05_TRAIN",
    "arm_predicate",
    "arm_train_indices",
    "build_manifests",
    "dagger3_signals",
    "gate_membership",
    "load_manifest",
    "manifest_hash",
]
