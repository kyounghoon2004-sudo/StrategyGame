"""Plan loop (2026-10-10): select by full-game rollouts, then verify on FRESH rollouts.

For every finished situation of a batch (report.json with "verify" results = each answer played to the end `reps`
times), pick the answer with the most wins (ties: fewer losses, then the earlier answer); then play the pick and the
control (the 9B's original answer) again to the end `--n` times each, independent of the runs used to pick (no
winner's curse). Live 9B after the branch turn (vLLM must be up: policy).

  python -m tools.plan_loop.reverify <batch dir> [--n 6] [--slot 0]
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import tools.plan_loop.loop as L


def tally(results: list) -> tuple:
    w = sum(1 for r in results if r.get("outcome") == "RED_WIN")
    lo = sum(1 for r in results if r.get("outcome") == "BLUE_WIN")
    return w, lo


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("batch")
    ap.add_argument("--n", type=int, default=6)
    ap.add_argument("--slot", type=int, default=0)
    a = ap.parse_args()
    L.SLOT = a.slot
    rows, picks = [], {}
    for rp in sorted(Path(a.batch).glob("*/report.json")):
        r = json.loads(rp.read_text(encoding="utf-8"))
        ans = {"control": r["control"]["answer"], "revised": r["revised"]["answer"]}
        ans.update({"cand%d" % i: c["answer"] for i, c in enumerate(r["candidates"])})
        order = list(r["verify"].keys())
        best = max(order, key=lambda k: (tally(r["verify"][k]["results"])[0], -tally(r["verify"][k]["results"])[1], -order.index(k)))
        g = r["game"]
        picks[g] = {"pick": best, "pick_selection_runs": tally(r["verify"][best]["results"]),
                    "control_selection_runs": tally(r["verify"]["control"]["results"]), "turn": r["turn"]}
        for k in range(a.n):
            rows.append({"id": "%s__pick_r%d" % (g, k), "game": g, "turn": r["turn"], "horizon": 0, "answer": ans[best], "after": "live"})
            rows.append({"id": "%s__ctrl_r%d" % (g, k), "game": g, "turn": r["turn"], "horizon": 0, "answer": ans["control"], "after": "live"})
    out = Path(a.batch) / "reverify"
    res = L.run_branches(rows, out, 8)
    tot = {"pick": [0, 0, 0], "ctrl": [0, 0, 0]}
    for g, p in picks.items():
        for kind in ("pick", "ctrl"):
            oc = [(res.get("%s__%s_r%d" % (g, kind, k)) or {}).get("outcome") for k in range(a.n)]
            t = [oc.count("RED_WIN"), oc.count("CAP"), oc.count("BLUE_WIN")]
            p["fresh_" + kind] = t
            tot[kind] = [x + y for x, y in zip(tot[kind], t)]
        print("%-18s pick %-8s fresh: pick W/D/L %s  control %s" % (g, p["pick"], p["fresh_pick"], p["fresh_ctrl"]), flush=True)
    print("TOTAL fresh W/D/L  pick %s  control %s" % (tot["pick"], tot["ctrl"]))
    (out / "reverify.json").write_text(json.dumps({"picks": picks, "total": tot}, indent=1), encoding="utf-8")


if __name__ == "__main__":
    main()
