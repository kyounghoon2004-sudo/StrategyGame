"""Predictor check on plan-loop situations (2026-10-10): for each answer of a situation, the predictor's P(RED win)
at T+H (its 8-turn branch) vs its real results played to the end; counts answer pairs with different real results
that the predictor orders correctly.

  python -m tools.plan_loop.pred_eval <predictor.pt> <situation dir> [<situation dir> ...]
"""
from __future__ import annotations

import itertools
import json
import sys
from pathlib import Path

import tools.plan_loop.loop as L

RANK = {"RED_WIN": 2, "CAP": 1, "BLUE_WIN": 0}
STAGE = {"control": ("s1_ctrl", "ctrl"), "revised": ("s4_rev", "rev")}


def main():
    L.PRED = Path(sys.argv[1])
    L._model = None
    ok = n = 0
    for d in map(Path, sys.argv[2:]):
        r = json.loads((d / "report.json").read_text(encoding="utf-8"))
        pts = []
        for name, v in r["verify"].items():
            st, i = STAGE.get(name, ("s3_cands", "c" + name[4:]))
            gf = d / st / "games" / ("%s.json" % i)
            if not gf.exists():
                continue
            real = [RANK[x["outcome"]] for x in v["results"] if x.get("outcome") in RANK]
            if real:
                pts.append((name, L.win_prob(json.loads(gf.read_text(encoding="utf-8"))), sum(real) / len(real)))
        for (n1, p1, r1), (n2, p2, r2) in itertools.combinations(pts, 2):
            if r1 != r2 and p1 != p2:
                n += 1
                ok += (p1 > p2) == (r1 > r2)
        print(d.name, " ".join("%s %.2f/%.1f" % (a, p, q) for a, p, q in pts))
    print("pairs ordered correctly: %d / %d (%.0f%%)" % (ok, n, 100.0 * ok / max(1, n)))


if __name__ == "__main__":
    main()
