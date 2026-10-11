"""Win-probability recalibration for a trained predictor (2026-10-09): the value head was trained with draws
down-weighted, so its live P(win) is overconfident. Fit a temperature and a per-class bias on the logits (4 numbers)
on one set of unseen games, save them next to the model (calib.json), and compare calibration on another set.

  python -m tools.predict.calibrate --model <predictor.pt> --fit "<glob>[::llm]" ... --test "<glob>[::llm]" ...
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import torch
import torch.nn.functional as F

from tools.predict.eval_live import samples_of
from tools.predict.model import load
from tools.predict.train import Packed, batch


@torch.no_grad()
def logits_of(model, data: Packed, dev, bs: int = 256):
    out_l, out_v = [], []
    for j in range(0, len(data), bs):
        feat, dist, own, mask, lab, lost, dead, value = batch(data[j:j + bs], dev)
        out_l.append(model(feat, dist, own, mask)["value"].float().cpu())
        out_v.append(value.cpu())
    return torch.cat(out_l), torch.cat(out_v)


def table(p_win: torch.Tensor, value: torch.Tensor) -> dict:
    won = (value == 0).float()
    out = {}
    for i in range(5):
        m = (p_win >= i * 0.2) & (p_win < (i + 1) * 0.2 if i < 4 else p_win <= 1.0)
        if m.any():
            out["%.1f-%.1f" % (i * 0.2, (i + 1) * 0.2)] = {"samples": int(m.sum()), "mean_pred": round(float(p_win[m].mean()), 3),
                                                         "actual_win": round(float(won[m].mean()), 3)}
    out["brier"] = round(float(((p_win - won) ** 2).mean()), 4)
    return out


def load_set(patterns: list) -> Packed:
    ss = []
    for pat in patterns:
        ss.extend(samples_of(pat)[0])
    return Packed(ss), len(ss[0]["feat"][0])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--fit", nargs="+", required=True)
    ap.add_argument("--test", nargs="+", required=True)
    a = ap.parse_args()
    dev = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    fit, nf = load_set(a.fit)
    test, _ = load_set(a.test)
    model = load(a.model, nf, dev)
    model.eval()
    lf, vf = logits_of(model, fit, dev)
    lt, vt = logits_of(model, test, dev)
    log_t = torch.zeros(1, requires_grad=True)
    bias = torch.zeros(3, requires_grad=True)
    opt = torch.optim.LBFGS([log_t, bias], lr=0.1, max_iter=200)

    def closure():
        opt.zero_grad()
        loss = F.cross_entropy(lf / log_t.exp() + bias, vf)
        loss.backward()
        return loss
    opt.step(closure)
    T, b = float(log_t.exp()), [round(float(x), 4) for x in bias]
    cal = lambda l: F.softmax(l / T + torch.tensor(b), -1)  # noqa: E731
    res = {"temperature": round(T, 4), "bias": b, "fit_samples": len(fit), "test_samples": len(test),
           "test_logloss_before": round(float(F.cross_entropy(lt, vt)), 4),
           "test_logloss_after": round(float(F.cross_entropy(torch.log(cal(lt)), vt)), 4),
           "test_before": table(F.softmax(lt, -1)[:, 0], vt), "test_after": table(cal(lt)[:, 0], vt)}
    (Path(a.model).parent / "calib.json").write_text(json.dumps(res, indent=1), encoding="utf-8")
    print(json.dumps(res, indent=1))


if __name__ == "__main__":
    main()
