"""Shared evaluators for the significance-gating ablation (Parts H-Q).

All metrics reuse frozen code paths (evaluate.metrics_from_rows, exam.run_exam,
benchmark_v1, CounterfactualEngine-free forwards). No new training states.
"""

from __future__ import annotations

import copy
import math
import os

import torch
from torch.utils.data import DataLoader

from python_jev.aggregate.data_v03 import JevFullInfoDatasetV5
from python_jev.constants import ACTION_SPACE, PATCH_NUM_CELLS
from python_jev.model import JevPolicyV0
from python_jev.observation import ObservationBatchV0
from python_jev.training.checkpoint import load_checkpoint
from python_jev.training.data import collate_jev
from python_jev.training.evaluate import metrics_from_rows

SCOUT_BOUNDARY = ("EVADE", "RECON_ADVANCE", "SHADOW")


def load_model(ckpt_path: str, device: str = "cpu"):
    model = JevPolicyV0().to(device).eval()
    load_checkpoint(ckpt_path, model)
    return model


def _slim(mt: dict, rows: dict) -> dict:
    q = rows["q"].float()
    qv = rows["q_valid"].bool()
    sel = rows["sel"].long().clamp_min(0)
    q_best = torch.where(qv, q, torch.full_like(q, float("-inf"))).amax(-1)
    q_sel = q.gather(1, sel.unsqueeze(-1)).squeeze(-1)
    eps = (q_sel >= q_best - 0.01).float().mean().item()
    return {"n": mt["samples"], "loss": mt["loss"], "kl": mt["kl"],
            "top1": mt["top1"], "mean_regret": mt["mean_regret"],
            "median_regret": mt["median_regret"], "p95_regret": mt["p95_regret"],
            "epsilon_at_0.01": eps}


@torch.no_grad()
def offline_on_shard(model, shard_path: str, batch: int = 512) -> dict:
    ds = JevFullInfoDatasetV5(shard_path)
    loader = DataLoader(ds, batch_size=batch, shuffle=False, collate_fn=collate_jev)
    rows = {"raw": [], "prob": [], "sel": [], "sel_prob": [],
            "p_target": [], "q": [], "q_valid": [], "legal": [], "class_idx": []}
    for obs, tgt in loader:
        out = model(obs)
        rows["raw"].append(out.raw_logits.cpu())
        rows["prob"].append(out.probabilities.cpu())
        rows["sel"].append(out.selected_slot.cpu())
        rows["sel_prob"].append(out.selected_prob.cpu())
        for k in ("p_target", "q", "q_valid", "legal", "class_idx"):
            rows[k].append(tgt[k].cpu())
    for k in rows:
        rows[k] = torch.cat(rows[k], dim=0)
    return _slim(metrics_from_rows(rows), rows)


@torch.no_grad()
def offline_on_distset(model, payload: dict, idx: list[int],
                       batch: int = 512) -> dict:
    from python_jev.training.policy_target import soft_targets_from_q

    t = payload["tensors"]
    rows = {"raw": [], "prob": [], "sel": [], "sel_prob": [],
            "p_target": [], "q": [], "q_valid": [], "legal": [], "class_idx": []}
    for a in range(0, len(idx), batch):
        kk = idx[a:a + batch]
        i = torch.tensor(kk, dtype=torch.long)
        b = len(kk)
        obs = ObservationBatchV0(
            actor_features=t["actor"][i].float(), tokens=t["tokens"][i].float(),
            token_padding_mask=t["token_pad"][i].bool(),
            hex_patch=t["hex"][i].float(),
            hex_padding_mask=torch.zeros(b, PATCH_NUM_CELLS, dtype=torch.bool),
            mission_features=t["mission"][i].float(),
            global_features=t["global"][i].float(),
            legal_mask=t["legal"][i].bool(),
            acting_class_idx=t["class_idx"][i].long(), metadata={})
        out = model(obs)
        q = torch.zeros(b, 6)
        qm = torch.zeros(b, 6, dtype=torch.bool)
        pt = torch.zeros(b, 6)
        for bi, k in enumerate(kk):
            legal = [bool(x) for x in t["legal"][k].tolist()]
            qv = t["teacher_q"][k, 0].tolist()
            pv = soft_targets_from_q(
                [(float(qv[s]) if legal[s] else None) for s in range(6)], legal)
            for s in range(6):
                if legal[s]:
                    q[bi, s] = float(qv[s])
                    qm[bi, s] = True
                    pt[bi, s] = pv[s]
        rows["raw"].append(out.raw_logits.cpu())
        rows["prob"].append(out.probabilities.cpu())
        rows["sel"].append(out.selected_slot.cpu())
        rows["sel_prob"].append(out.selected_prob.cpu())
        rows["p_target"].append(pt)
        rows["q"].append(q)
        rows["q_valid"].append(qm)
        rows["legal"].append(t["legal"][i].bool())
        rows["class_idx"].append(t["class_idx"][i].long())
    for k in rows:
        rows[k] = torch.cat(rows[k], dim=0)
    return _slim(metrics_from_rows(rows), rows)


def frozen_d3_subsets(signals: list[dict], provenance: list[dict]) -> dict[str, list[int]]:
    """M0-frozen subset definitions over novel D3 dagger indices."""
    high, low, agree, scout = [], [], [], []
    for rec in signals:
        k = rec["dagger_idx"]
        r = rec["driver_regret"]
        dis = rec["driver_sel"] != rec["teacher_top"]
        if r >= 0.01:
            high.append(k)
        if dis and r < 0.0025:
            low.append(k)
        if not dis:
            agree.append(k)
        prov = provenance[k]
        if prov["actor_class"] == "SCOUT":
            cls = prov["actor_class"]
            if (ACTION_SPACE[cls][rec["teacher_top"]] in SCOUT_BOUNDARY
                    or ACTION_SPACE[cls][rec["driver_sel"]] in SCOUT_BOUNDARY):
                scout.append(k)
    return {"high": high, "low": low, "agree": agree, "scout": scout}


@torch.no_grad()
def scout_mechanism(models: dict[str, object], payload: dict,
                    scout_idx: list[int], batch: int = 512) -> dict:
    """Per-skill selection rates + teacher mass on the frozen scout subset."""
    from python_jev.training.policy_target import soft_targets_from_q

    t = payload["tensors"]
    skills = ACTION_SPACE["SCOUT"]
    probs: dict[str, list] = {}
    for tag, model in models.items():
        pp: list = []
        for a in range(0, len(scout_idx), batch):
            kk = scout_idx[a:a + batch]
            i = torch.tensor(kk, dtype=torch.long)
            b = len(kk)
            obs = ObservationBatchV0(
                actor_features=t["actor"][i].float(), tokens=t["tokens"][i].float(),
                token_padding_mask=t["token_pad"][i].bool(),
                hex_patch=t["hex"][i].float(),
                hex_padding_mask=torch.zeros(b, PATCH_NUM_CELLS, dtype=torch.bool),
                mission_features=t["mission"][i].float(),
                global_features=t["global"][i].float(),
                legal_mask=t["legal"][i].bool(),
                acting_class_idx=t["class_idx"][i].long(), metadata={})
            pp.extend(model(obs).probabilities.cpu().tolist())
        probs[tag] = pp
    mass = {s: {"teacher": 0.0, **{tg: 0.0 for tg in models}} for s in skills}
    freq = {s: {"teacher": 0, **{tg: 0 for tg in models}} for s in skills}
    for j, k in enumerate(scout_idx):
        legal = [bool(x) for x in t["legal"][k].tolist()]
        qv = [float(v) for v in t["teacher_q"][k, 0].tolist()]
        pv = soft_targets_from_q(
            [(float(qv[s]) if legal[s] else None) for s in range(6)], legal)
        top = max([s for s in range(6) if legal[s]], key=lambda s: qv[s])
        freq[skills[top]]["teacher"] += 1
        for s in range(6):
            if legal[s]:
                mass[skills[s]]["teacher"] += pv[s]
        for tag in models:
            a = max(range(6), key=lambda s: probs[tag][j][s])
            freq[skills[a]][tag] += 1
            for s in range(6):
                if legal[s]:
                    mass[skills[s]][tag] += probs[tag][j][s]
    n = len(scout_idx)
    for s in mass:
        for k in mass[s]:
            mass[s][k] /= n
    return {"n": n, "mass": mass, "argmax_freq": freq}


def run_exams(models: dict[str, object], device: str = "cpu") -> dict:
    from python_jev.retrain.rebuild_v2 import new_mask_fn
    from python_jev.training.exam import build_exam_cases, run_exam

    out: dict = {}
    for tag, model in models.items():
        rep = run_exam(model, device, copy.deepcopy(build_exam_cases()),
                       mask_fn=new_mask_fn)
        o = rep["summary"]["overall"]
        out[tag] = {"mean_regret": o["mean_regret"], "cases": o["cases"],
                    "median_regret": o["median_regret"],
                    "p95_regret": o["p95_regret"],
                    "epsilon_optimal_rate": o["epsilon_optimal_rate"],
                    "per_class": {c: {"mean_regret": v["mean_regret"],
                                      "cases": v["cases"]}
                                  for c, v in rep["summary"]["per_class"].items()}}
    return out


def run_closedloop(models: dict[str, object], device: str, out_dir: str,
                   log_fn=None) -> dict:
    """One benchmark_v1 per model + comparison (same V1 jobs/mask as A3)."""
    import json

    from python_jev.feasibility.benchmark import run_benchmark_v1
    from python_jev.retrain.closedloop_v1 import bench_jobs_24
    from python_jev.retrain.rebuild_v2 import new_mask_fn

    log = log_fn or (lambda m: print(m, flush=True))
    os.makedirs(out_dir, exist_ok=True)
    jobs = bench_jobs_24()
    reports: dict[str, dict] = {}
    for tag, model in models.items():
        path = os.path.join(out_dir, f"v1_{tag}.json")
        log(f"V1 closed-loop: {tag} ({len(jobs)} jobs)")
        reports[tag] = run_benchmark_v1(model, device, jobs, path,
                                        mask_fn=new_mask_fn, mask_tag="new")

    def pick(s: dict) -> dict:
        return {
            "battles": s["battles"],
            "victory_rate_blue": s.get("victory_rate_blue"),
            "defeat_rate_blue": s.get("defeat_rate_blue"),
            "expired_rate": s["expired_rate"],
            "mean_turns": s["mean_turns"],
            "mean_decisions": s["mean_decisions"],
            "mean_mission_progress_delta_blue": s["mean_mission_progress_delta_blue"],
            "mean_exchange_blue_view": s["mean_exchange_blue_view"],
            "mean_blue_lost": s["mean_blue_lost"],
            "mean_red_lost": s["mean_red_lost"],
            "hq_survival_blue": s["hq_survival_blue"],
            "hq_survival_red": s["hq_survival_red"],
            "blue_invalid_rate": s.get("blue_invalid_rate"),
            "blue_partial_rate": s.get("blue_partial_rate"),
            "blue_driver_skill_distribution": s.get("blue_driver_skill_distribution"),
        }

    comp = {"benchmark_version": reports[next(iter(models))]["benchmark_version"],
            "mask": "new (observation-safe-skill-mask-v0.2.0)",
            "jobs": len(jobs), "blue_vs_simple_red": {}}
    for tag, rep in reports.items():
        cond = rep["conditions"]["blue=JEV_vs_red=Simple"]
        comp["blue_vs_simple_red"][tag] = pick(cond["summary"])
    # baselines must be bit-identical across runs (matched proof) and match A1
    first = next(iter(reports.values()))
    base: dict[str, dict] = {}
    for p in ("SimpleAttackElseAdvancePolicy", "RandomLegalPolicy", "HoldPolicy"):
        c = f"blue={p}_vs_red=Simple"
        base[p] = pick(first["conditions"][c]["summary"])
        blobs = set()
        for rep in reports.values():
            cc = copy.deepcopy(rep["conditions"][c])
            for b in cc.get("battles", []):
                b.pop("wall_seconds", None)
            blobs.add(json.dumps(cc, sort_keys=True))
        assert len(blobs) == 1, f"baseline not identical across runs: {p}"
    comp["blue_vs_simple_red"]["Simple"] = base["SimpleAttackElseAdvancePolicy"]
    comp["blue_vs_simple_red"]["Random"] = base["RandomLegalPolicy"]
    comp["blue_vs_simple_red"]["Hold"] = base["HoldPolicy"]
    a1 = json.load(open(os.path.join("artifacts", "jev_dagger_v0", "closedloop",
                                     "same_seat_comparison.json"),
                        encoding="utf-8"))
    for p, short in (("SimpleAttackElseAdvancePolicy", "Simple"),
                       ("RandomLegalPolicy", "Random"), ("HoldPolicy", "Hold")):
        got = {k: v for k, v in comp["blue_vs_simple_red"][short].items()
               if k in a1["blue_vs_simple_red"][p]}
        want = {k: a1["blue_vs_simple_red"][p][k] for k in got}
        assert json.dumps(got, sort_keys=True) == json.dumps(want, sort_keys=True), \
            f"baseline drift across rounds: {p}"
    with open(os.path.join(out_dir, "comparison.json"), "w", encoding="utf-8") as f:
        json.dump(comp, f, indent=1, sort_keys=True)
    return {"comparison": comp,
            "reports": {t: os.path.join(out_dir, f"v1_{t}.json")
                        for t in models}}


def oracle_gaps(v1_paths: dict[str, str], out_path: str) -> dict:
    """Frozen 6-scenario oracle subset per model (same as A3 stage_oracle)."""
    import json

    d0 = json.load(open(os.path.join("artifacts", "jev_target_diagnostic_v0",
                                     "oracle_closedloop", "report.json"),
                        encoding="utf-8"))
    a2 = json.load(open(os.path.join("artifacts", "jev_dagger_v1", "metrics",
                                     "oracle_gap.json"), encoding="utf-8"))
    o_ex = d0["oracles"]["CounterfactualGreedySimple"]["summary"]["mean_exchange_blue_view"]
    old_ex = a2["v02_exchange"]
    out = {"oracle_exchange": o_ex, "v02_exchange": old_ex, "models": {},
           "subset_scenario_ids": d0["subset_scenario_ids"]}
    for tag, path in v1_paths.items():
        rep = json.load(open(path, encoding="utf-8"))
        sub = [b for b in rep["conditions"]["blue=JEV_vs_red=Simple"]["battles"]
               if b["scenario_id"] in d0["subset_scenario_ids"]]
        assert len(sub) == 6, f"{tag}: oracle subset has {len(sub)} battles"
        ex = sum(b["exchange_blue_view"] for b in sub) / 6.0
        dm = sum(b["mission_progress_delta_blue"] for b in sub) / 6.0
        out["models"][tag] = {
            "exchange": ex, "dM": dm,
            "gap_closed_fraction": ((ex - old_ex) / (o_ex - old_ex)
                                    if o_ex != old_ex else None)}
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=1, sort_keys=True)
    return out


def retained_gradient_check(arm_retained_train_idx: dict[str, list[int]],
                            v04_ckpt: str) -> dict:
    """M0-protocol gradient audit for each arm's retained D3 rows (no steps)."""
    from python_jev.aggregate.dataset_v05 import load_shard_v05
    from python_jev.observation import ObservationBatchV0
    from python_jev.siggate.gates import V05_TRAIN
    from python_jev.training.train import soft_target_policy_loss

    shard = load_shard_v05(V05_TRAIN, verify=True)
    t, prov = shard["tensors"], shard["provenance"]
    base_idx = {
        "B0_original": [i for i, p in enumerate(prov) if p["source"] == "JEV_FULLINFO_V02"],
        "B1_dagger1": [i for i, p in enumerate(prov) if p["source"] == "JEV_VISITED_DAGGER1"],
        "B2_dagger2": [i for i, p in enumerate(prov) if p["source"] == "JEV_VISITED_DAGGER2"],
    }
    model = load_model(v04_ckpt).train()
    NB = 512
    g = torch.Generator().manual_seed(0)

    def batch(idx: list[int]) -> tuple[ObservationBatchV0, torch.Tensor]:
        i = torch.tensor(idx, dtype=torch.long)
        b = len(idx)
        obs = ObservationBatchV0(
            actor_features=t["actor"][i].float(), tokens=t["tokens"][i].float(),
            token_padding_mask=t["token_pad"][i].bool(),
            hex_patch=t["hex"][i].float(),
            hex_padding_mask=torch.zeros(b, PATCH_NUM_CELLS, dtype=torch.bool),
            mission_features=t["mission"][i].float(),
            global_features=t["global"][i].float(),
            legal_mask=t["legal"][i].bool(),
            acting_class_idx=t["class_idx"][i].long(), metadata={})
        return obs, t["p_target"][i].float()

    def grads(idx: list[int]) -> torch.Tensor:
        model.zero_grad(set_to_none=True)
        obs, pt = batch(idx)
        loss = soft_target_policy_loss(model(obs).raw_logits, obs.legal_mask, pt)
        loss.backward()
        return torch.cat([p.grad.detach().cpu().reshape(-1)
                          for _, p in model.named_parameters()])

    G: dict[str, torch.Tensor] = {}
    for tag, pool in base_idx.items():
        pick = [pool[i] for i in torch.randperm(len(pool), generator=g)[:NB].tolist()]
        G[tag] = grads(pick)
    out: dict = {}
    for arm, pool in arm_retained_train_idx.items():
        if len(pool) >= NB:
            pick = [pool[i] for i in torch.randperm(len(pool), generator=g)[:NB].tolist()]
        else:
            pick = (pool * ((NB // len(pool)) + 1))[:NB]
        gv = grads(pick)
        nrm = float(gv.norm().item())
        cos = {}
        for tag in base_idx:
            denom = nrm * float(G[tag].norm().item())
            cos[tag] = float((gv @ G[tag]).item() / denom) if denom else 0.0
        out[arm] = {"n_retained": len(pool), "grad_norm_512": nrm,
                    "cos_vs_original": cos["B0_original"],
                    "cos_vs_dagger1": cos["B1_dagger1"],
                    "cos_vs_dagger2": cos["B2_dagger2"]}
    return out


def _unused_math_guard() -> float:
    return math.inf


__all__ = [
    "SCOUT_BOUNDARY",
    "frozen_d3_subsets",
    "load_model",
    "offline_on_distset",
    "offline_on_shard",
    "oracle_gaps",
    "retained_gradient_check",
    "run_closedloop",
    "run_exams",
    "scout_mechanism",
]
