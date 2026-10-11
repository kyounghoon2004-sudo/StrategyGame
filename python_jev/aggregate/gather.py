"""A1 collection: JEV-visited states on TRAIN scenarios + dedup + gates.

Driver: jev-policy-v0.2.0-fi seed43, deterministic masked argmax, both
seats. No exploration noise, no teacher mixing. TRAIN-split scenarios
only (leakage raises); profiles follow the frozen split plan.
"""

from __future__ import annotations

import hashlib
from concurrent.futures import ProcessPoolExecutor

from python_jev.diagnose.collect import N_WORKERS, collect_job

DAGGER_SOURCE = "JEV_VISITED_DAGGER1"
MIN_UNIQUE = 4000
MAX_UNIQUE = 8000


def split_scenario_ids() -> dict[str, set[str]]:
    """Frozen scenario-id sets per split (leakage reference)."""
    from python_jev.training.dataset_gen import ood_plan, split_plan
    from python_jev.training.scenarios import generate_scenario

    plan = split_plan(192)
    ood = ood_plan(48)
    out: dict[str, set[str]] = {"train": set(), "validation": set(),
                                "test": set(), "generalization_test": set()}
    for i in range(192):
        sid = generate_scenario(i)["scenario"]["scenario_id"]
        out[plan[i]["split"]].add(sid)
    for i in range(48):
        out["generalization_test"].add(
            generate_scenario(i, ood=True)["scenario"]["scenario_id"])
    return out


def train_jobs() -> list[tuple[int, str, bool, str]]:
    from python_jev.training.dataset_gen import split_plan

    plan = split_plan(192)
    return [(i, plan[i]["profile"], False, "train")
            for i in sorted(j for j in range(192) if plan[j]["split"] == "train")]


DAGGER_CAP = 42  # 144 scenarios x 42 -> ~6k unique (pilot: dedup rate 1.0)


def collect_dagger1(ckpt_old: str, ckpt_collect: str,
                    scenarios: list[tuple[int, str, bool, str]] | None = None,
                    log_fn=None, max_states: int = DAGGER_CAP,
                    set_name: str = "dagger1",
                    driver_label: str = "dagger1-v02-seed43") -> list[dict]:
    """Pool-collect raw JEV-visited rows. Returns rows sorted by id/step."""
    log = log_fn or (lambda m: print(m, flush=True))
    jobs = scenarios if scenarios is not None else train_jobs()
    extra = {"driver_ckpt": ckpt_collect, "driver_label": driver_label,
             "max_states": max_states}
    work = [(set_name, i, p, o, sp, ckpt_old, ckpt_collect, extra)
            for (i, p, o, sp) in jobs]
    # TRAIN-only gate at dispatch: every job must be a train scenario.
    allowed = split_scenario_ids()["train"]
    from python_jev.training.scenarios import generate_scenario
    for (i, _p, o, _sp) in jobs:
        assert not o, "OOD job forbidden in dagger1-train collection"
        assert generate_scenario(i)["scenario"]["scenario_id"] in allowed
    rows: list[dict] = []
    with ProcessPoolExecutor(max_workers=N_WORKERS) as pool:
        for n, res in enumerate(pool.map(collect_job, work)):
            rows.extend(res["rows"])
            if (n + 1) % 36 == 0:
                log(f"  jobs {n + 1}/{len(work)} rows={len(rows)}")
    rows.sort(key=lambda r: (r["scenario_id"], r["trajectory_step"]))
    log(f"  raw JEV-visited rows: {len(rows)}")
    return rows


def dedup_key(row: dict) -> tuple:
    return (row["obs_hash"], row["actor_class"], row["mission"],
            tuple(bool(x) for x in row["legal"]))


def deduplicate(rows: list[dict], source: str = DAGGER_SOURCE,
                  traj_prefix: str = "dagger1") -> tuple[list[dict], dict]:
    """Collapse identical authorized decision states; count visits."""
    first: dict[tuple, dict] = {}
    visits: dict[tuple, int] = {}
    for r in rows:
        k = dedup_key(r)
        visits[k] = visits.get(k, 0) + 1
        if k not in first:
            first[k] = r
    unique = []
    for k, r in first.items():
        r = dict(r)
        r["visit_count"] = visits[k]
        r["trajectory_id"] = f"{traj_prefix}:{r['scenario_id']}"
        r["source"] = source
        unique.append(r)
    unique.sort(key=lambda r: (r["scenario_id"], r["trajectory_step"]))
    info = {"raw": len(rows), "unique": len(unique),
            "duplicates_removed": len(rows) - len(unique),
            "max_visit_count": max(visits.values()) if visits else 0}
    return unique, info


def collection_ckpt_hash(ckpt_path: str) -> str:
    with open(ckpt_path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def shard_tkey(tensors: dict, i: int, actor_class: str, mission: str) -> tuple:
    """Training-canonical state key: float32 obs bytes + class/mission/legal.

    This is the granularity the model actually sees: two rows with
    identical keys are indistinguishable to JevPolicyV0 and would
    produce identical gradients.
    """
    t = tensors
    return (t["actor"][i].contiguous().numpy().tobytes(),
            t["tokens"][i].contiguous().numpy().tobytes(),
            t["token_pad"][i].contiguous().numpy().tobytes(),
            t["hex"][i].contiguous().numpy().tobytes(),
            t["mission"][i].contiguous().numpy().tobytes(),
            t["global"][i].contiguous().numpy().tobytes(),
            int(t["class_idx"][i].item()), actor_class, mission,
            tuple(bool(x) for x in t["legal"][i].tolist()))


def cross_dedup_report(d3_payload: dict, v04_train_path: str,
                       dagger1_path: str, dagger2_path: str
                       ) -> tuple[list[int], dict]:
    """Classify round-3 uniques vs the v0.4 TRAIN corpus.

    Returns (novel_indices, report) where report holds NEW_UNIQUE /
    ALREADY_IN_V04 counts plus the join-verification outcome. Only
    NEW_UNIQUE rows may enter v0.5 TRAIN.

    Note: v0.4 TRAIN rows carry no stored obs_hash, and the D0 hash is
    computed pre-float32-rounding, so it cannot be recomputed from
    shard tensors (verified: 0/12096 dagger-row matches). The tensor
    key is the training-canonical equivalent and is verified bit-exact
    on all 12096 carried dagger rows instead.
    """
    from python_jev.aggregate.dataset_v04 import load_shard_v04
    from python_jev.diagnose.collect import load_set

    payload = load_shard_v04(v04_train_path, verify=True)
    t, prov = payload["tensors"], payload["provenance"]
    n = payload["n_records"]
    v04_keys: set[tuple] = set()
    join_index: dict[tuple, int] = {}
    for i, p in enumerate(prov):
        v04_keys.add(shard_tkey(t, i, p["actor_class"], p["mission_type"]))
        if p["source"] in ("JEV_VISITED_DAGGER1", "JEV_VISITED_DAGGER2"):
            join_index[(p["source"], p["trajectory_id"],
                        p["trajectory_index"])] = i
    # verify the method: every carried dagger row must key-match its
    # round's unique-set row (same tensors, bit-exact).
    checked = matched = 0
    for dset_path, source, prefix in (
            (dagger1_path, "JEV_VISITED_DAGGER1", "dagger1"),
            (dagger2_path, "JEV_VISITED_DAGGER2", "dagger2")):
        dset = load_set(dset_path, verify=True)
        dt = dset["tensors"]
        for k, dp in enumerate(dset["provenance"]):
            j = join_index.get((source, f"{prefix}:{dp['scenario_id']}",
                                dp["trajectory_step"]))
            if j is None:
                continue
            checked += 1
            want = shard_tkey(t, j, prov[j]["actor_class"],
                              prov[j]["mission_type"])
            got = shard_tkey(dt, k, dp["actor_class"], dp["mission"])
            if want == got:
                matched += 1
    if checked == 0 or matched != checked:
        raise RuntimeError(
            f"tensor-key join unverified: {matched}/{checked} matched")
    d3t = d3_payload["tensors"]
    novel_idx: list[int] = []
    already = 0
    for k, dp in enumerate(d3_payload["provenance"]):
        if shard_tkey(d3t, k, dp["actor_class"], dp["mission"]) in v04_keys:
            already += 1
        else:
            novel_idx.append(k)
    report = {"method": "float32-tensor-bytes+class+mission+legal",
              "round3_unique": len(d3_payload["provenance"]),
              "new_unique": len(novel_idx), "already_in_v04": already,
              "v04_train_rows": n, "v04_key_set": len(v04_keys),
              "tensor_join_checked": checked,
              "tensor_join_matched": matched}
    return novel_idx, report


__all__ = [
    "DAGGER_SOURCE",
    "MAX_UNIQUE",
    "MIN_UNIQUE",
    "collect_dagger1",
    "collection_ckpt_hash",
    "cross_dedup_report",
    "dedup_key",
    "deduplicate",
    "shard_tkey",
    "split_scenario_ids",
    "train_jobs",
]
