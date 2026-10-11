"""Train the prediction model on game records and report, on held-out games (2026-10-08):
  action  top-1 / top-3 / top-10 hit rate of the joint (type, target) prediction per own unit
  attack  target accuracy when the unit attacked
  intent  accuracy of "whom will this enemy attack next" (and how often it predicted "none" right)
  outcome mean error of the soldiers-lost share; destroyed AUC-free accuracy
  value   win / draw / loss accuracy and log loss
  given the actions taken (2026-10-08): value log loss and the soldiers-lost error of units that lost soldiers, each
          against the plain (no-action) prediction on the same samples
plus the forward latency of one decision (one board, every unit at once).

  python -m tools.predict.train [--runs <dir>,<dir>] [--epochs 20] [--out <dir>]
"""
from __future__ import annotations

import argparse
import json
import math
import random
import time
from pathlib import Path

import torch
import torch.nn.functional as F

from tools.predict.data import ACT, MAX_UNITS, load
from tools.predict.model import Predictor

ROOT = Path(__file__).resolve().parents[2]
BP = ROOT / "artifacts" / "brain_pipeline_v1"
RUNS = ",".join(str(BP / d) for d in ("gxgx_mass_v1", "replay_cloud_v1/fort1", "replay_cloud_v1/fort0",
                                                  "replay_code_v1/fort1", "cmd_collect_resident_q35_nothink",
                                                  "gxgx_roster_v1", "replay_code_v2/fort1",
                                                  "cmd_eval_q35_sft_v1/sft_v1", "cmd_eval_q35_sft_v1_roster/sft_v1",
                                                  "cmd_eval_q35_sft_v1_roster_ext/sft_v1", "cmd_eval_q35_sft_v1_vs3/sft_v1"))
# RL v8 games (2026-10-09): iterations 1-39 train; 40-45 stay out for the live check
RUNS += "," + ",".join(str(BP / "cmd_rl_v8" / "iterations" / ("it%04d" % i)) for i in range(1, 40))
OUT = ROOT / "artifacts" / "brain_pipeline_v1" / "predict_v1"


class Packed:
    """All samples padded to MAX_UNITS once, in compact dtypes (2026-10-08): building the batch tensors from Python
    lists every step made an epoch take 20+ minutes. Indexing returns a Packed view/copy of the selected samples."""

    KEYS = ("feat", "dist", "own", "mask", "act", "tgt", "intent", "lost", "dead", "value", "vw", "w", "n")

    def __init__(self, samples: list = None, t: dict = None):
        if t is not None:
            self.t = t
            return
        S, N = len(samples), MAX_UNITS
        nf = len(samples[0]["feat"][0])
        t = {"feat": torch.zeros(S, N, nf, dtype=torch.float16), "dist": torch.zeros(S, N, N, dtype=torch.int8),
             "own": torch.zeros(S, N, dtype=torch.bool), "mask": torch.zeros(S, N, dtype=torch.bool),
             "act": torch.full((S, N), -100, dtype=torch.int16), "tgt": torch.full((S, N), -100, dtype=torch.int16),
             "intent": torch.full((S, N), -100, dtype=torch.int16), "lost": torch.zeros(S, N, dtype=torch.float16),
             "dead": torch.zeros(S, N, dtype=torch.bool), "value": torch.zeros(S, dtype=torch.int64),
             "vw": torch.ones(S), "w": torch.ones(S), "n": torch.zeros(S, dtype=torch.int16)}
        for i, x in enumerate(samples):
            k = len(x["feat"])
            t["feat"][i, :k] = torch.tensor(x["feat"], dtype=torch.float16)
            t["dist"][i, :k, :k] = torch.tensor(x["dist"], dtype=torch.int8)
            t["own"][i, :k] = torch.tensor(x["own"])
            t["mask"][i, :k] = True
            for key in ("act", "tgt"):
                t[key][i, :k] = torch.tensor(x[key], dtype=torch.int16)
            it = torch.tensor(x["intent"], dtype=torch.int16)
            it[it == k] = N  # "none" -> the shared slot after the last unit
            t["intent"][i, :k] = it
            t["lost"][i, :k] = torch.tensor(x["lost"], dtype=torch.float16)
            t["dead"][i, :k] = torch.tensor(x["dead"], dtype=torch.bool)
            t["value"][i] = int(x["value"])
            t["vw"][i] = float(x.get("vw", 1.0))
            t["w"][i] = float(x.get("w", 1.0))
            t["n"][i] = k
        self.t = t

    def __len__(self):
        return self.t["value"].shape[0]

    def __getitem__(self, idx):
        return Packed(t={k: v[idx] for k, v in self.t.items()})


def batch(data: "Packed", dev):
    t = data.t
    n = int(t["n"].max())
    to = lambda x: x.to(dev, non_blocking=True)  # noqa: E731
    lab = {"act": to(t["act"][:, :n].long()), "tgt": to(t["tgt"][:, :n].long())}
    it = t["intent"][:, :n].long()
    it[it == MAX_UNITS] = n  # "none" slot = n for this batch's width
    lab["intent"] = to(it)
    lab["vw"] = to(t["vw"])
    return (to(t["feat"][:, :n].float()), to(t["dist"][:, :n, :n].long()), to(t["own"][:, :n]), to(t["mask"][:, :n]),
            lab, to(t["lost"][:, :n].float()), to(t["dead"][:, :n].float()), to(t["value"]))


def plan_inputs(lab, mask):
    """The acting side's actual actions this phase as model input: act_in, hit_in, and which samples have them."""
    act_in = torch.where(lab["act"] >= 0, lab["act"], torch.full_like(lab["act"], len(ACT)))
    hit_in = torch.zeros(lab["act"].shape, device=lab["act"].device)
    b_idx, _ = torch.nonzero(lab["tgt"] >= 0, as_tuple=True)
    hit_in.index_put_((b_idx, lab["tgt"][lab["tgt"] >= 0]), torch.ones_like(b_idx, dtype=hit_in.dtype), accumulate=True)
    return act_in, hit_in, (lab["act"] >= 0).any(1)


def cond_losses(out, mask, cond, lost, dead, value, vw):
    """Outcome and value given the actions (only samples whose actions are known)."""
    m = (mask & cond[:, None]).float()
    if not cond.any():
        z = out["value"].sum() * 0
        return {"c_lost": z, "c_dead": z, "c_value": z}
    c_l = (F.smooth_l1_loss(torch.sigmoid(out["lost"]), lost, reduction="none", beta=0.1) * m).sum() / m.sum()
    c_d = (F.binary_cross_entropy_with_logits(out["dead"], dead, reduction="none") * m).sum() / m.sum()
    return {"c_lost": c_l, "c_dead": c_d, "c_value": _vloss(out["value"][cond], value[cond], vw[cond])}


def _vloss(logits, value, vw):
    """Win/draw/loss cross-entropy weighted per sample (vw = 0: no value label, e.g. ADV GX-vs-GX draws)."""
    l = F.cross_entropy(logits, value, reduction="none")
    return (l * vw).sum() / vw.sum().clamp(min=1e-6)


def losses(out, own, mask, lab, lost, dead, value):
    act = F.cross_entropy(out["act"].flatten(0, 1), lab["act"].flatten(), ignore_index=-100)
    has = lab["tgt"] >= 0
    atk = F.cross_entropy(out["atk"][has], lab["tgt"][has]) if has.any() else out["act"].sum() * 0
    hi = lab["intent"] >= 0
    intent = F.cross_entropy(out["intent"][hi], lab["intent"][hi]) if hi.any() else out["act"].sum() * 0
    m = mask.float()
    out_l = (F.smooth_l1_loss(torch.sigmoid(out["lost"]), lost, reduction="none", beta=0.1) * m).sum() / m.sum()
    out_d = (F.binary_cross_entropy_with_logits(out["dead"], dead, reduction="none") * m).sum() / m.sum()
    val = _vloss(out["value"], value, lab["vw"])
    return {"act": act, "atk": atk, "intent": intent, "lost": out_l, "dead": out_d, "value": val}


@torch.no_grad()
def evaluate(model, data, dev, bs=256):
    model.eval()
    hit = {1: 0, 3: 0, 10: 0}
    n_act = atk_ok = atk_n = int_ok = int_n = none_ok = none_n = 0
    lost_err = dead_ok = n_units = 0.0
    val_ok = val_n = 0
    val_ll = 0.0
    # conditioned on the actions taken (samples with known actions), against the plain prediction on the same samples
    c = {"n": 0, "ll": 0.0, "ll0": 0.0, "ok": 0, "hit_n": 0.0, "hit_err": 0.0, "hit_err0": 0.0}
    for j in range(0, len(data), bs):
        feat, dist, own, mask, lab, lost, dead, value = batch(data[j:j + bs], dev)
        out = model(feat, dist, own, mask)
        act_in, hit_in, cond = plan_inputs(lab, mask)
        if cond.any():
            oc = model(feat, dist, own, mask, act_in, hit_in)
            lpc = F.log_softmax(oc["value"][cond].float(), -1)
            lp0 = F.log_softmax(out["value"][cond].float(), -1)
            vc = value[cond][:, None]
            c["n"] += int(cond.sum())
            c["ll"] += float(-lpc.gather(-1, vc).sum())
            c["ll0"] += float(-lp0.gather(-1, vc).sum())
            c["ok"] += int((lpc.argmax(-1) == value[cond]).sum())
            hm = mask & cond[:, None] & (lost > 0)  # units that actually lost soldiers this phase
            c["hit_n"] += float(hm.sum())
            c["hit_err"] += float((torch.sigmoid(oc["lost"])[hm] - lost[hm]).abs().sum())
            c["hit_err0"] += float((torch.sigmoid(out["lost"])[hm] - lost[hm]).abs().sum())
        pt = F.softmax(out["act"].float(), -1)
        pa = F.softmax(out["atk"].float(), -1).nan_to_num(0)
        ia = ACT.index("ATTACK")
        # joint candidates: non-attack types + (attack x each enemy)
        joint = torch.cat([pt[..., :ia], pt[..., ia + 1:], pt[..., ia:ia + 1] * pa], -1)  # [B,N,9+N]
        truth = torch.where(lab["act"] == ia, (len(ACT) - 1) + lab["tgt"].clamp(min=0),
                            torch.where(lab["act"] > ia, lab["act"] - 1, lab["act"]))
        sel = lab["act"] >= 0
        if sel.any():
            rank = (joint[sel] > joint[sel].gather(-1, truth[sel][:, None])).sum(-1)
            for k in hit:
                hit[k] += int((rank < k).sum())
            n_act += int(sel.sum())
        has = lab["tgt"] >= 0
        if has.any():
            atk_ok += int((out["atk"][has].argmax(-1) == lab["tgt"][has]).sum())
            atk_n += int(has.sum())
        hi = lab["intent"] >= 0
        if hi.any():
            pred = out["intent"][hi].argmax(-1)
            int_ok += int((pred == lab["intent"][hi]).sum())
            int_n += int(hi.sum())
            nn_ = lab["intent"][hi] == out["intent"].shape[-1] - 1
            none_ok += int((pred[nn_] == lab["intent"][hi][nn_]).sum())
            none_n += int(nn_.sum())
        m = mask
        lost_err += float((torch.sigmoid(out["lost"])[m] - lost[m]).abs().sum())
        dead_ok += float(((out["dead"][m] > 0).float() == dead[m]).sum())
        n_units += float(m.sum())
        vm = lab["vw"] > 0  # samples with a value label
        lp = F.log_softmax(out["value"].float(), -1)[vm]
        val_ok += int((lp.argmax(-1) == value[vm]).sum())
        val_ll += float(-lp.gather(-1, value[vm][:, None]).sum())
        val_n += int(vm.sum())
    r = {"action_top1": hit[1] / max(1, n_act), "action_top3": hit[3] / max(1, n_act), "action_top10": hit[10] / max(1, n_act),
         "attack_target_acc": atk_ok / max(1, atk_n), "intent_acc": int_ok / max(1, int_n),
         "intent_none_share": none_n / max(1, int_n), "intent_acc_when_attacks": (int_ok - none_ok) / max(1, int_n - none_n),
         "outcome_lost_mae": lost_err / max(1, n_units), "destroyed_acc": dead_ok / max(1, n_units),
         "value_acc": val_ok / max(1, val_n), "value_logloss": val_ll / max(1, val_n),
         "given_action_value_acc": c["ok"] / max(1, c["n"]),
         "given_action_value_logloss": c["ll"] / max(1, c["n"]), "plain_value_logloss_same": c["ll0"] / max(1, c["n"]),
         "given_action_lost_mae_hit": c["hit_err"] / max(1, c["hit_n"]),
         "plain_lost_mae_hit": c["hit_err0"] / max(1, c["hit_n"])}
    model.train()
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", default=RUNS)
    ap.add_argument("--epochs", type=int, default=20)
    ap.add_argument("--bs", type=int, default=128)
    ap.add_argument("--lr", type=float, default=3e-4)
    ap.add_argument("--out", default=str(OUT))
    ap.add_argument("--holdout", type=float, default=0.1, help="share of games held out (split by game)")
    ap.add_argument("--d", type=int, default=128, help="model width (2026-10-09)")
    ap.add_argument("--layers", type=int, default=4)
    ap.add_argument("--heads", type=int, default=4)
    ap.add_argument("--llm-weight", type=float, default=1.0, help="games with an LLM side drawn this many times per epoch")
    ap.add_argument("--gpu-frac", type=float, default=0.05, help="cap on this process's share of GPU memory (0 = none)")
    a = ap.parse_args()
    dev = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    if dev.type == "cuda" and a.gpu_frac > 0:
        torch.cuda.set_per_process_memory_fraction(a.gpu_frac)  # share the GPU with the RL engine (2026-10-08)
    t0 = time.time()
    train, val, info = load(a.runs.split(","), a.holdout)
    print("games %d (skipped %d without phase records, rules known %d) -> samples train %d, held-out %d (%.0fs)" % (
        info["games"], info["skipped"], info.get("rules_known", 0), len(train), len(val), time.time() - t0), flush=True)
    if not train or not val:
        print("not enough data yet")
        return
    nf = len(train[0]["feat"][0])
    t1 = time.time()
    train, val = Packed(train), Packed(val)
    print("packed into tensors (%.0fs)" % (time.time() - t1), flush=True)
    size = {"d": a.d, "layers": a.layers, "heads": a.heads}
    model = Predictor(nf, **size).to(dev)
    (Path(a.out) / "model.json").parent.mkdir(parents=True, exist_ok=True)
    (Path(a.out) / "model.json").write_text(json.dumps(size), encoding="utf-8")
    print("parameters %.2fM, device %s" % (sum(p.numel() for p in model.parameters()) / 1e6, dev), flush=True)
    opt = torch.optim.AdamW(model.parameters(), lr=a.lr, weight_decay=0.01)
    steps = a.epochs * (math.ceil(float(train.t["w"].sum()) * 1.05 / a.bs) + 2)  # epochs draw ~sum(w) samples
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=a.lr, total_steps=steps, pct_start=0.1)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    log = open(out / "metrics.jsonl", "a", encoding="utf-8")
    print("before training: " + json.dumps({k: round(v, 3) for k, v in evaluate(model, val, dev).items()}), flush=True)
    rnd = random.Random(0)
    best = float("inf")
    for ep in range(a.epochs):
        # a sample with weight w is drawn floor(w) times plus once more with probability frac(w) (w < 1: GX-vs-GX draws,
        # w > 1: --llm-weight)
        g = torch.Generator().manual_seed(ep)
        w = train.t["w"]
        reps = w.floor().long() + (torch.rand(len(train), generator=g) < (w - w.floor())).long()
        idx = torch.repeat_interleave(torch.arange(len(train)), reps)
        ep_data = train[idx[torch.randperm(len(idx), generator=g)]]
        tot = {}
        for j in range(0, len(ep_data), a.bs):
            feat, dist, own, mask, lab, lost, dead, value = batch(ep_data[j:j + a.bs], dev)
            ls = losses(model(feat, dist, own, mask), own, mask, lab, lost, dead, value)
            act_in, hit_in, cond = plan_inputs(lab, mask)
            ls.update(cond_losses(model(feat, dist, own, mask, act_in, hit_in), mask, cond, lost, dead, value, lab["vw"]))
            loss = (ls["act"] + ls["atk"] + ls["intent"] + 2 * ls["lost"] + ls["dead"] + 0.5 * ls["value"]
                    + 2 * ls["c_lost"] + ls["c_dead"] + 0.5 * ls["c_value"])
            opt.zero_grad(set_to_none=True)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            opt.step()
            sched.step()
            for k, v in ls.items():
                tot[k] = tot.get(k, 0) + float(v.detach())
        nb = math.ceil(len(ep_data) / a.bs)
        r = evaluate(model, val, dev)
        print("epoch %2d | loss %s | held-out %s" % (ep + 1, " ".join("%s %.3f" % (k, v / nb) for k, v in tot.items()),
                                                      " ".join("%s %.3f" % (k, v) for k, v in r.items())), flush=True)
        log.write(json.dumps({"epoch": ep + 1, "train": {k: v / nb for k, v in tot.items()}, "heldout": r}) + "\n")
        if r["value_logloss"] < best:  # early stopping on held-out win/draw/loss log loss (v1 overfit after epoch 2)
            best = r["value_logloss"]
            torch.save(model.state_dict(), out / "predictor_best.pt")
            print("  best so far (value log loss %.4f) -> predictor_best.pt" % best, flush=True)
        log.flush()
    torch.save(model.state_dict(), out / "predictor.pt")
    # latency: one board, every unit at once
    model.eval()
    feat, dist, own, mask, *_ = batch(val[:1], dev)
    with torch.no_grad():
        for _ in range(10):
            model(feat, dist, own, mask)
        if dev.type == "cuda":
            torch.cuda.synchronize()
        t1 = time.perf_counter()
        for _ in range(100):
            model(feat, dist, own, mask)
        if dev.type == "cuda":
            torch.cuda.synchronize()
    print("latency per decision: %.2f ms (%s)" % ((time.perf_counter() - t1) * 10, dev), flush=True)
    print("saved", out / "predictor.pt")


if __name__ == "__main__":
    main()
