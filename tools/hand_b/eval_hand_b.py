"""HAND B evaluation: identical frozen inputs for any Laya-format checkpoint.

  <laya venv python> tools/hand_b/eval_hand_b.py --model <dir> --tag NAME [--limit N]

Sets: laya_synthetic_v2 val + test (frozen scenario-hash split) and the
independent counterfactual states (fresh scenarios 9,000,000+, rebuilt
deterministically with the QA seed and cached). Writes
artifacts/laya_hand_b_v1/eval/<tag>.json
"""
import argparse, collections, json, math, os, random, sys

import torch

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import common as C
from train_hand_b import encode_row, batches, forward, keys_for

ROOT = r"D:\Game development\Demon slayer\StrategyGame"
DATA = os.path.join(ROOT, "artifacts", "laya_synthetic_v2")
OUT = os.path.join(ROOT, "artifacts", "laya_hand_b_v1", "eval")
CF_CACHE = os.path.join(ROOT, "artifacts", "laya_hand_b_v1", "qa_v2", "cf_states.json")
PAIRS = [("ADVANCE", "FORWARD"), ("WITHDRAW", "BACK"), ("FLANK", "LEFT"), ("FLANK", "RIGHT"), ("FIX", "FORWARD"),
         ("RESERVE", "ANY"), ("ATTACK", "ANY"), ("HOLD", "ANY"), ("RECON", "FORWARD")]


def mean(v):
    v = [x for x in v if x is not None]
    return round(sum(v) / len(v), 4) if v else None


def cf_states():
    if os.path.exists(CF_CACHE):
        return json.load(open(CF_CACHE, encoding="utf-8"))
    import gen_v2 as HG
    HG.OUT = os.path.join(ROOT, "artifacts", "laya_hand_b_v1", "qa_v2")
    rnd = random.Random(99)
    reqs, sid = [], 9_000_000
    while len(reqs) < 160:
        s = HG.scenario(sid, rnd); sid += 1
        if s:
            reqs.extend(s)
    res = [s for s in HG.extract(reqs, "evalcf") if "units" in s]
    json.dump(res, open(CF_CACHE, "w", encoding="utf-8"))
    return res


@torch.no_grad()
def predict(model, items, dev):
    """-> list of (probs list) per item, in order."""
    out = [None] * len(items)
    model.eval()
    for bidx in batches(items, 12000, 32, False, 0):
        _, logits, mask, _ = forward(model, items, bidx, dev)
        p = torch.softmax(logits.masked_fill(~mask, -1e4), -1).float().cpu()
        for j, k in enumerate(bidx):
            out[k] = p[j, : int(mask[j].sum())].tolist()
    return out


def heldout(model, tok, dev, path, limit):
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            rows.append(json.loads(line))
    if limit and len(rows) > limit:
        rows = random.Random(7).sample(rows, limit)
    enc = [(r, encode_row(tok, r)) for r in rows]
    enc = [(r, e) for r, e in enc if e]
    probs = predict(model, [e for _, e in enc], dev)
    buckets = collections.defaultdict(lambda: collections.defaultdict(list))
    for (r, e), p in zip(enc, probs):
        acc = set(r["accepted"])
        am = max(range(len(p)), key=lambda i: p[i])
        hit = r["candidates"][am]["candidate_id"] in acc
        mass = sum(pi for pi, c in zip(p, r["candidates"]) if c["candidate_id"] in acc)
        k = len(p)
        ent = -sum(pi * math.log(max(pi, 1e-12)) for pi in p) / math.log(k) if k > 1 else 0.0
        n = len(r["candidates"])
        keys = ["ALL", "task:" + r["order"]["task"], "cls:" + ("ranged" if r["unit"]["class"] == "archer" else "melee"),
                "dir:" + r["order"]["relative_direction"], "cand:" + ("<=10" if n <= 10 else "11-25" if n <= 25 else "26-45" if n <= 45 else "46+"),
                "stage:" + r["stage"], "family:" + r["family_kind"]]
        for kk in keys:
            b = buckets[kk]
            b["top1"].append(1.0 if hit else 0.0); b["mass"].append(mass); b["norm_entropy"].append(ent); b["top_p"].append(max(p))
    return {k: {"n": len(v["top1"]), **{m: mean(x) for m, x in v.items()}} for k, v in sorted(buckets.items())}


def counterfactual(model, tok, dev):
    states = cf_states()
    items, meta = [], []
    for st in states:
        for u in st["units"]:
            if len(u["candidates"]) < 2:
                continue
            ctx = C.build_ctx(st, u["unit"])
            for t, d in PAIRS:
                o = {"task": t, "relative_direction": d, "intent": C.TASK_INTENTS[t]}
                acc, _ = C.accepted_ids(t, d, u["unit"], u["candidates"], ctx)
                row = {"side": st["side"], "bounds": st["bounds"], "ledger": st["ledger"], "turn": st["turn"], "unit": u["unit"],
                       "candidates": u["candidates"], "order": o, "accepted": acc or [u["candidates"][0]["candidate_id"]]}
                e = encode_row(tok, row)
                if e:
                    items.append(e); meta.append((st, u, ctx, t, d, set(acc)))
    probs = predict(model, items, dev)
    agg = collections.defaultdict(lambda: collections.defaultdict(list))
    per_unit = collections.defaultdict(dict)
    for (st, u, ctx, t, d, acc), p in zip(meta, probs):
        am = max(range(len(p)), key=lambda i: p[i])
        c = u["candidates"][am]
        up = C.pos(u["unit"])
        f, l = C.rel(up, C.cand_pos(c, u["unit"]), ctx["fr"])
        k = t + "_" + d
        V = ctx["V"]
        d0 = C.dmin(up, V)
        a = agg[k]
        a["top1"].append(1.0 if c["candidate_id"] in acc else 0.0)
        a["fwd"].append(f); a["left"].append(l)
        a["stationary"].append(1.0 if c["action_type"] in C.STATIONARY else 0.0)
        a["attack"].append(1.0 if c["action_type"] == "ATTACK" else 0.0)
        a["top_p"].append(max(p))
        if t in ("FIX", "ATTACK") and not (d0 is not None and d0 <= 1):
            a["retreat_without_contact"].append(1.0 if f < -0.5 else 0.0)
        if t in ("HOLD", "RESERVE"):
            behind = ctx["fwd_coord"](up) <= ctx["line"] - 0.5 and not (d0 is not None and d0 <= 2)
            if t == "HOLD" or behind:
                a["churn"].append(1.0 if c["action_type"] == "MOVE" else 0.0)
        if u["unit"]["class"] == "archer" and V and t in ("FIX", "ATTACK"):
            if c["action_type"] == "ATTACK":
                a["ranged_good_geometry"].append(1.0 if d0 >= 2 else 0.0)
            else:
                a["ranged_good_geometry"].append(1.0 if 2 <= C.dmin(C.cand_pos(c, u["unit"]), V) <= 3 else 0.0)
        if any(x["action_type"] == "ATTACK" for x in u["candidates"]):
            a["attack_when_legal"].append(1.0 if c["action_type"] == "ATTACK" else 0.0)
        per_unit[(st["id"], u["unit"]["id"])][k] = (f, l, c["action_type"])
    sens = collections.defaultdict(list)
    for key, v in per_unit.items():
        if "ADVANCE_FORWARD" in v and "WITHDRAW_BACK" in v:
            sens["ADV_fwd>WDR_fwd"].append(1.0 if v["ADVANCE_FORWARD"][0] > v["WITHDRAW_BACK"][0] else 0.0)
        if "FLANK_LEFT" in v and "FLANK_RIGHT" in v:
            sens["FLANK_L.left>R.left"].append(1.0 if v["FLANK_LEFT"][1] > v["FLANK_RIGHT"][1] else 0.0)
        if "FIX_FORWARD" in v and "RESERVE_ANY" in v:
            sens["FIX_fwd>RESERVE_fwd"].append(1.0 if v["FIX_FORWARD"][0] >= v["RESERVE_ANY"][0] and v["FIX_FORWARD"] != v["RESERVE_ANY"] else 0.0)
        if "ATTACK_ANY" in v and "HOLD_ANY" in v and v["ATTACK_ANY"][2] == "ATTACK":
            sens["ATTACK_attacks_while_HOLD_holds"].append(1.0 if v["HOLD_ANY"][2] in C.STATIONARY else 0.0)
    return {"units": len(per_unit), "per_command": {k: {m: mean(x) for m, x in v.items()} for k, v in agg.items()},
            "sensitivity": {k: {"n": len(v), "rate": mean(v)} for k, v in sens.items()}}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--limit", type=int, default=0)
    a = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    import laya
    agent = laya.load(a.model, device="cuda")
    model, tok, dev = agent.model, agent.tok, agent.device
    res = {"model": a.model, "tag": a.tag,
           "val": heldout(model, tok, dev, os.path.join(DATA, "val.jsonl"), a.limit),
           "test": heldout(model, tok, dev, os.path.join(DATA, "test.jsonl"), a.limit),
           "counterfactual": counterfactual(model, tok, dev)}
    json.dump(res, open(os.path.join(OUT, a.tag + ".json"), "w"), indent=1)
    print(json.dumps({"val_ALL": res["val"]["ALL"], "test_ALL": res["test"]["ALL"], "cf_sens": res["counterfactual"]["sensitivity"]}, indent=1))


if __name__ == "__main__":
    main()
