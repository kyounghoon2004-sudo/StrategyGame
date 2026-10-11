"""Live window for the prediction-model training (2026-10-08): plots tools/predict/train.py's metrics.jsonl as it
grows: train losses per head, and the held-out hit rates (action top-1/3/10, attack target, intent, value).

  python -m tools.predict.watch [--metrics <file>]
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import matplotlib.pyplot as plt
from matplotlib.animation import FuncAnimation

from tools.predict.train import OUT


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--metrics", default=str(OUT / "metrics.jsonl"))
    a = ap.parse_args()
    path = Path(a.metrics)
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(13, 5))
    fig.canvas.manager.set_window_title("Prediction model training")

    def draw(_):
        rows = [json.loads(l) for l in path.read_text(encoding="utf-8").splitlines() if l.strip()] if path.exists() else []
        if rows and "epoch" in rows[-1]:
            start = max(i for i, r in enumerate(rows) if r.get("epoch") == 1)  # the latest run only
            rows = rows[start:]
        ax1.clear()
        ax2.clear()
        ep = [r["epoch"] for r in rows]
        for k in ("act", "atk", "intent", "lost", "dead", "value", "c_lost", "c_dead", "c_value"):
            if rows and k in rows[0]["train"]:
                ax1.plot(ep, [r["train"][k] for r in rows], marker="o", label=k)
        ax1.set_title("train loss per head")
        ax1.set_xlabel("epoch")
        ax1.legend(loc="upper right")
        for k, lab in (("action_top1", "action top-1"), ("action_top3", "action top-3"), ("action_top10", "action top-10"),
                       ("attack_target_acc", "attack target"), ("intent_acc", "enemy intent"),
                       ("intent_acc_when_attacks", "intent (when it attacks)"), ("value_acc", "win/draw/loss"),
                       ("given_action_value_acc", "win/draw/loss given actions")):
            if rows and k in rows[-1]["heldout"]:
                ax2.plot(ep, [r["heldout"][k] for r in rows], marker="o", label=lab)
        ax2.set_ylim(0, 1)
        ax2.set_title("held-out games: hit rate")
        ax2.set_xlabel("epoch")
        ax2.legend(loc="lower right", fontsize=8)
        if not rows:
            ax2.text(0.5, 0.5, "waiting for the first epoch...", ha="center", transform=ax2.transAxes)
        fig.tight_layout()

    anim = FuncAnimation(fig, draw, interval=3000, cache_frame_data=False)  # noqa: F841
    plt.show()


if __name__ == "__main__":
    main()
