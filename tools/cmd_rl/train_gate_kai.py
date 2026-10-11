"""Fine-tune the Kai gate (tools/cmd_rl/gate_kai.py) on resident games and measure what it would save (2026-10-08).

Label = what the LLM actually answered that turn: a changed order or a new plan = change, {"orders": {}} = keep.
Games are split by situation (the same situation played by two A/B blocks stays on one side). The held-out report:
AUC, and for each threshold how many turns the gate would answer "keep" without the LLM, the LLM time that saves,
and how many real changes it would have missed.

  python -m tools.cmd_rl.train_gate_kai [--epochs 3] [--holdout 0.3] [--save <dir>]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import random
import sys
import time
from pathlib import Path

from tools.cmd_rl.gate_kai import MODEL, QUESTION, RUNS, ROOT, load_kai, rows, state_text

OUT = ROOT / "artifacts" / "brain_pipeline_v1" / "jev_gate"


def _held(tag: str, frac: float) -> bool:
    return int(hashlib.sha256(tag.encode()).hexdigest(), 16) % 1000 < frac * 1000


def auc(pos: list, neg: list) -> float:
    return sum((a > b) + 0.5 * (a == b) for a in pos for b in neg) / max(1, len(pos) * len(neg))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", default=",".join(sorted(str(p) for p in RUNS.glob("b0*"))))
    ap.add_argument("--epochs", type=int, default=3)
    ap.add_argument("--lr", type=float, default=2e-5)
    ap.add_argument("--head-lr", type=float, default=1e-3)
    ap.add_argument("--accum", type=int, default=8)
    ap.add_argument("--holdout", type=float, default=0.3)
    ap.add_argument("--save", default="")
    a = ap.parse_args()
    import torch
    import torch.nn.functional as F

    data = rows(a.runs.split(","))
    kai = load_kai(MODEL)
    backend = kai.runtime.backend
    model, tok = backend.model, backend.tokenizer
    infer = next(m for n, m in sys.modules.items() if n.endswith("_vendor.dev2model.infer"))
    dm = next(m for n, m in sys.modules.items() if n.endswith("_vendor.dev2model.decision_model"))
    pad = tok.pad_token_id if tok.pad_token_id is not None else tok.eos_token_id

    def encoded(r, i):
        row = infer.question_to_row({"id": "r%d" % i, "state": state_text(r)}, "change", QUESTION["change"])
        keys = [o["key"] for o in row["options"]]
        row["label"] = keys.index("true" if r["change"] else "false")
        row.setdefault("family", "gate")
        return dm.encode(row, tok, backend.cap)

    train, test = [], []
    for i, r in enumerate(data):
        (test if _held(r["game"], a.holdout) else train).append((r, encoded(r, i)))
    print("rows train %d test %d (change share %.2f / %.2f)" % (
        len(train), len(test), sum(r["change"] for r, _ in train) / len(train), sum(r["change"] for r, _ in test) / len(test)))

    def predict(items):
        model.eval()
        out = []
        with torch.inference_mode(), torch.autocast(device_type="cuda", dtype=torch.bfloat16):
            for _, e in items:
                b = {k: v.to(backend.device) if torch.is_tensor(v) else v for k, v in dm.collate([e], pad).items()}
                lg = model(**b)[0][:len(e["keys"])].float()
                p = torch.softmax(lg, -1)[e["keys"].index("true")].item()
                out.append(p)
        return out

    def report(name, items, probs):
        pos = [p for (r, _), p in zip(items, probs) if r["change"]]
        neg = [p for (r, _), p in zip(items, probs) if not r["change"]]
        total = sum(r["llm_s"] for r, _ in items)
        lines = ["%s: AUC %.3f" % (name, auc(pos, neg))]
        for th in (0.05, 0.1, 0.2, 0.3, 0.4, 0.5):
            skip = [(r, p) for (r, _), p in zip(items, probs) if p < th]
            missed = sum(r["change"] for r, _ in skip)
            lines.append("  p(change)<%.2f: skip %d of %d turns (%.0f%%), LLM time saved %.0f%%, missed changes %d of %d (%.0f%%)" % (
                th, len(skip), len(items), 100 * len(skip) / len(items), 100 * sum(r["llm_s"] for r, _ in skip) / total,
                missed, len(pos), 100 * missed / max(1, len(pos))))
        print("\n".join(lines))
        return lines

    log = report("held-out before training", test, predict(test))
    model.requires_grad_(True)
    head_params = list(model.head.parameters())
    head_ids = {id(p) for p in head_params}
    body = [p for p in model.parameters() if id(p) not in head_ids]
    opt = torch.optim.AdamW([{"params": body, "lr": a.lr}, {"params": head_params, "lr": a.head_lr}], weight_decay=0.0)
    steps = math.ceil(len(train) * a.epochs / a.accum)
    sched = torch.optim.lr_scheduler.LambdaLR(opt, lambda s: min(1.0, (s + 1) / 10) * max(0.0, 1 - s / max(1, steps)))
    rnd = random.Random(0)
    t0 = time.time()
    for ep in range(a.epochs):
        model.train()
        order = list(range(len(train)))
        rnd.shuffle(order)
        tot, n = 0.0, 0
        for j, idx in enumerate(order):
            e = train[idx][1]
            b = {k: v.to(backend.device) if torch.is_tensor(v) else v for k, v in dm.collate([e], pad).items()}
            with torch.autocast(device_type="cuda", dtype=torch.bfloat16):
                lg = model(**b)[:, :len(e["keys"])].float()
            loss = F.cross_entropy(lg, b["labels"]) / a.accum
            loss.backward()
            tot += loss.item() * a.accum
            n += 1
            if (j + 1) % a.accum == 0 or j == len(order) - 1:
                torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
                opt.step()
                sched.step()
                opt.zero_grad(set_to_none=True)
        print("epoch %d loss %.4f (%.0fs)" % (ep + 1, tot / n, time.time() - t0), flush=True)
    probs = predict(test)
    log += report("held-out after training", test, probs)
    # latency of one gate decision through the product API (warm)
    ms = []
    for r, _ in test[:50]:
        t1 = time.perf_counter()
        kai.system_one(state=state_text(r), questions=QUESTION)
        ms.append((time.perf_counter() - t1) * 1000)
    ms.sort()
    lat = "gate latency per turn: median %.1f ms, p90 %.1f ms" % (ms[len(ms) // 2], ms[int(len(ms) * .9)])
    print(lat)
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "train_report.txt").write_text("\n".join(log + [lat]), encoding="utf-8")
    (OUT / "heldout_probs.json").write_text(json.dumps([{"game": r["game"], "turn": r["turn"], "change": r["change"],
                                                          "p": p, "llm_s": r["llm_s"]} for (r, _), p in zip(test, probs)]),
                                            encoding="utf-8")
    if a.save:
        torch.save({k: v.to(torch.bfloat16) for k, v in model.state_dict().items()}, a.save)
        print("saved", a.save)


if __name__ == "__main__":
    main()
