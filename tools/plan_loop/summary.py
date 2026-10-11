"""Plan loop batch summary (2026-10-09): per situation, every answer's predicted P(win) at T+H vs its real result to the
end of the game; the loop's pick vs the control; and how often the predictor's ranking matches the real ranking.

  python -m tools.plan_loop.summary <batch dir>
"""
from __future__ import annotations

import itertools
import json
import sys
from pathlib import Path

RANK = {"RED_WIN": 2, "CAP": 1, None: 1, "BLUE_WIN": 0}


def main():
    pairs_ok = pairs_n = 0
    for rp in sorted(Path(sys.argv[1]).glob("*/report.json")):
        r = json.loads(rp.read_text(encoding="utf-8"))
        v = r.get("verify", {})
        print("== %s (original: %s turn %s)  loop pick: %s" % (r["game"], r["original"]["kind"], r["original"]["turn"], r.get("best")))
        for x in v.values():  # old reports: one result per answer
            x.setdefault("results", [{"outcome": x.get("outcome"), "turn": x.get("turn")}])
            done = [RANK.get(y["outcome"], 1) for y in x["results"] if y["outcome"]]
            x["real"] = sum(done) / len(done) if done else None
        for name, x in v.items():
            print("   %-8s predicted %.2f score %6.2f -> %s" % (name, x["p_win_at_T+H"], x["score"],
                  ", ".join("%s t%s" % (y["outcome"], y.get("turn")) for y in x["results"])))
        for (n1, a), (n2, b) in itertools.combinations(v.items(), 2):
            ra, rb = a["real"], b["real"]
            if ra is None or rb is None:
                continue
            if ra != rb and a["p_win_at_T+H"] != b["p_win_at_T+H"]:
                pairs_n += 1
                pairs_ok += (a["p_win_at_T+H"] > b["p_win_at_T+H"]) == (ra > rb)
    if pairs_n:
        print("predictor ranks pairs with different real results correctly: %d / %d (%.0f%%)" % (pairs_ok, pairs_n, 100.0 * pairs_ok / pairs_n))


if __name__ == "__main__":
    main()
