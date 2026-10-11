"""Live accuracy of a trained predictor on games it never saw (2026-10-08): the same held-out metrics as training
(tools/predict/train.evaluate) plus win-probability calibration, by probability bin and by game stage.

  python -m tools.predict.eval_live --model <predictor.pt> --games "<glob>[::llm]" ["<glob>[::llm]" ...]

"::llm" = RED was the LLM commander in those games (default: GX on both sides). The games must have phase records.
"""
from __future__ import annotations

import argparse
import glob
import json
from pathlib import Path

import torch
import torch.nn.functional as F

from tools.predict.data import game_rules, game_samples
from tools.predict.model import load
from tools.predict.train import Packed, batch, evaluate


def samples_of(pattern: str) -> tuple[list, int]:
    pat, _, actor = pattern.partition("::")
    out, n = [], 0
    for f in sorted(glob.glob(pat)):
        try:
            g = json.loads(Path(f).read_text(encoding="utf-8"))
        except (ValueError, OSError):
            continue
        rec = g.get("record") or {}
        ss = game_samples(rec, str(g.get("outcome", "")), {"red": actor or "gx", "blue": "gx"}, True, game_rules(g))
        if ss:
            n += 1
            out.extend(ss)
    return out, n


@torch.no_grad()
def calibration(model, data: Packed, dev, bs: int = 256) -> dict:
    """Predicted P(win) of the side about to act vs. how often it really won, per 0.2 bin and per game stage."""
    model.eval()
    bins = {i: [0, 0.0, 0] for i in range(5)}  # n, sum p, wins
    stage = {}
    for j in range(0, len(data), bs):
        part = data[j:j + bs]
        feat, dist, own, mask, lab, lost, dead, value = batch(part, dev)
        p = F.softmax(model(feat, dist, own, mask)["value"].float(), -1)[:, 0].cpu()  # class 0 = win
        turn = (part.t["feat"][:, 0, 16].float() * 80).round()  # feature 16 = turn / 80
        for pi, v, t in zip(p.tolist(), value.cpu().tolist(), turn.tolist()):
            b = bins[min(4, int(pi * 5))]
            b[0] += 1; b[1] += pi; b[2] += v == 0
            k = "turn 1-10" if t <= 10 else "turn 11-30" if t <= 30 else "turn 31+"
            s = stage.setdefault(k, [0, 0.0, 0, 0.0])  # n, correct (argmax win == won), brier
            s[0] += 1
            s[1] += (pi >= 0.5) == (v == 0)
            s[3] += (pi - (v == 0)) ** 2
    return {"by_predicted_win_prob": {f"{i * 0.2:.1f}-{(i + 1) * 0.2:.1f}": {"samples": b[0], "mean_pred": round(b[1] / max(1, b[0]), 3),
                                                                             "actual_win": round(b[2] / max(1, b[0]), 3)}
                                      for i, b in bins.items()},
            "by_stage": {k: {"samples": s[0], "win_call_acc": round(s[1] / max(1, s[0]), 3), "brier": round(s[3] / max(1, s[0]), 3)}
                         for k, s in sorted(stage.items())}}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--games", nargs="+", required=True)
    a = ap.parse_args()
    dev = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    if dev.type == "cuda":
        torch.cuda.set_per_process_memory_fraction(0.05)
    for pattern in a.games:
        ss, n = samples_of(pattern)
        if not ss:
            print(pattern, "no games")
            continue
        data = Packed(ss)
        model = load(a.model, len(ss[0]["feat"][0]), dev)
        r = evaluate(model, data, dev)
        print("==", pattern, "games", n, "samples", len(ss))
        print(json.dumps({k: round(v, 3) for k, v in r.items()}))
        print(json.dumps(calibration(model, data, dev)))


if __name__ == "__main__":
    main()
