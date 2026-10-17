"""Plan x opponent factorial at the opening (2026-10-12): does the best opening plan depend on the variables?

Plans (RED, default 10v10 roster, HQ mission): rush (every field unit ATTACK ENEMY_HQ, HQ fortifies), spread (every field
unit attacks a class counter), fortify (every unit FORTIFY), qwen (the live policy answers turn 1 as well).  After turn 1
the live Qwen policy plays on in every arm.  Cells = GX tier x style.  R rollouts per cell and plan.

  python -m tools.plan_loop.factorial build --rollouts 8 --out <dir>
  python -m tools.plan_loop.factorial agg <run dir> --jobs <jobs.jsonl>
"""
from __future__ import annotations

import argparse
import collections
import json
from pathlib import Path

TIERS = ["BASIC", "INTER", "ADV"]
STYLES = ["BULWARK", "SPEARHEAD", "HARRIER", "OUTRIDER"]
FIELD = ["R_ARC_1", "R_ARC_2", "R_CAV_1", "R_CAV_2", "R_INF_1", "R_INF_2", "R_SCT_1", "R_SPE_1", "R_SPE_2"]
COUNTER = {"ARC": ["B_SPE_1", "B_SPE_2"], "CAV": ["B_ARC_1", "B_ARC_2"], "INF": ["B_INF_1", "B_INF_2"],
           "SPE": ["B_CAV_1", "B_CAV_2"], "SCT": ["B_SCT_1", "B_SCT_1"]}


def plan(name: str) -> str:
    o = {"R_HQ_1": {"do": "FORTIFY"}}
    if name == "rush":
        o.update({u: {"do": "ATTACK", "target": "ENEMY_HQ"} for u in FIELD})
    elif name == "spread":
        for u in FIELD:
            o[u] = {"do": "ATTACK", "target": COUNTER[u.split("_")[1]][int(u[-1]) - 1]}
    elif name == "fortify":
        o.update({u: {"do": "FORTIFY"} for u in FIELD})
    else:
        return "__LIVE__"
    return json.dumps({"orders": o})


def build(a):
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    bank, jobs = {}, []
    for ci, (tier, style) in enumerate((t, s) for t in TIERS for s in STYLES):
        gid = "fx_%s_%s" % (tier, style)
        bank[gid] = {"game": gid, "seed": 9800000 + ci, "tier": tier, "style": style, "family": "fixed",
                     "army_size": None, "overlay": "", "answers": {}}
        for pl in ("rush", "spread", "fortify", "qwen"):
            for r in range(a.rollouts):
                jobs.append({"id": "%s_%s__q%d" % (gid, pl, r), "game": gid, "turn": 1, "horizon": 60,
                             "answer": plan(pl), "after": "live", "variant": pl, "tier": tier, "style": style,
                             "parent_id": "%s_%s" % (gid, pl)})
    (out / "bank.json").write_text(json.dumps(bank, indent=1), encoding="utf-8")
    (out / "jobs.jsonl").write_text("".join(json.dumps(j) + "\n" for j in jobs), encoding="utf-8")
    print("cells %d, games %d" % (len(bank), len(jobs)))


def agg(a):
    meta = {}
    for line in Path(a.jobs).read_text(encoding="utf-8").splitlines():
        b = json.loads(line)
        meta[b["id"]] = b
    cell = collections.defaultdict(lambda: collections.defaultdict(list))
    for run in a.runs:
        for line in (Path(run) / "results.jsonl").read_text(encoding="utf-8").splitlines():
            r = json.loads(line)
            m = meta.get(r.get("game"))
            if not m or r.get("error") or (r.get("turn") or 0) <= 1:
                continue
            cell[(m["tier"], m["style"])][m["variant"]].append((r.get("outcome"), r.get("turn")))
    print("%-7s %-10s" % ("tier", "style") + "".join("%-18s" % p for p in ("rush", "spread", "fortify", "qwen")))
    for k in sorted(cell):
        row = "%-7s %-10s" % k
        for p in ("rush", "spread", "fortify", "qwen"):
            L = cell[k].get(p, [])
            w = sum(o == "RED_WIN" for o, _ in L)
            row += "%-18s" % ("%d/%d" % (w, len(L)) if L else "-")
        print(row)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--rollouts", type=int, default=8)
    b.add_argument("--out", required=True)
    g = sub.add_parser("agg")
    g.add_argument("runs", nargs="+")
    g.add_argument("--jobs", required=True)
    a = ap.parse_args()
    build(a) if a.cmd == "build" else agg(a)


if __name__ == "__main__":
    main()
