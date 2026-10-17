"""Judge branches: per candidate compare the end state with the situation's controls.
  python -m tools.synth_adv_v1.judge_adv <out dir> [--candidates candidates.jsonl]
"""
import argparse, collections, json
from pathlib import Path


def feat(p):
    g = json.loads(p.read_text(encoding="utf-8"))
    sx, ss = g.get("soldiers_start", {}), g.get("soldiers_end", {})
    hq = g.get("hq", {})
    u = g.get("units", {})
    return {"outcome": g.get("outcome"), "turn": g.get("turn"), "fault": g.get("strict_fault") or None,
            "red_alive": u.get("red", {}).get("alive"), "blue_alive": u.get("blue", {}).get("alive"),
            "red_hq": hq.get("red", {}).get("end"), "blue_hq": hq.get("blue", {}).get("end"),
            "red_sol": ss.get("red"), "blue_sol": ss.get("blue"),
            "margin": (1 - (ss.get("blue", 0) / max(1, sx.get("blue", 1)))) - (1 - (ss.get("red", 0) / max(1, sx.get("red", 1))))}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--branches", default="")
    a = ap.parse_args()
    out = Path(a.out)
    res = {p.stem: feat(p) for p in (out / "games").glob("*.json")}
    by = collections.defaultdict(dict)
    for k, v in res.items():
        sid, _, var = k.rpartition("__")
        by[sid][var] = v
    rows = []
    for sid, d in by.items():
        c0, cT = d.get("ctrl0"), d.get("ctrlT")
        for var, v in d.items():
            if var.startswith("ctrl"):
                continue
            rows.append({"sid": sid, "variant": var, **v, "ctrl0": c0 and c0["outcome"], "ctrlT": cT and cT["outcome"],
                         "ctrl0_margin": c0 and round(c0["margin"], 3), "ctrlT_margin": cT and round(cT["margin"], 3)})
    for r in sorted(rows, key=lambda r: (r["sid"], r["variant"])):
        print(r["sid"][-34:], r["variant"], r["outcome"], r["turn"], "m=%.2f" % r["margin"], "ctrl0", r["ctrl0"], r["ctrl0_margin"],
              "ctrlT", r["ctrlT"], r["ctrlT_margin"])
    print(collections.Counter(r["outcome"] for r in rows), "ctrl0", collections.Counter(c.get("ctrl0") for c in rows))
    ctrl = [(k, v) for k, v in res.items() if "__ctrl" in k]
    print("controls:", collections.Counter((k.rsplit("__", 1)[1], v["outcome"]) for k, v in ctrl))


if __name__ == "__main__":
    main()
