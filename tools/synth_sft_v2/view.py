"""Synthetic commander SFT v2: compact author's view of situations (for writing answers by hand).

  python -m tools.synth_sft_v2.view <situation id> [<id> ...]
Prints per situation: tier/army/turn, kills so far / needed, standing plan, matchup highlights, every RED unit (class,
pos, soldiers/start, fort, standing order, nearest BLUE with distance) and every BLUE unit (class, pos, troops, fort,
eta to my HQ, nearest RED). Read-only.
"""
from __future__ import annotations

import json
import math
import sys

from tools.synth_sft_v2.bank import OUT

CLS = {"CAV": "CAVALRY", "SCT": "SCOUT", "INF": "INFANTRY", "ARC": "ARCHER", "SPE": "SPEARMAN", "HQ": "HQ"}


def dist(a, b):
    dq, dr = a[0] - b[0], a[1] - b[1]
    return (abs(dq) + abs(dr) + abs(dq + dr)) // 2


def load(ids=None):
    out = {}
    for line in open(OUT / "situations.jsonl", encoding="utf-8"):
        r = json.loads(line)
        if ids is None or r["id"] in ids:
            out[r["id"]] = r
    return out


def parse_now(r):
    """-> (my, enemy) dicts id -> info, from the turn message (or the opening on turn 1)."""
    op = json.loads(r["opening"])
    cls_of = {u["id"]: u["class"] for u in op["my_units"]}
    cls_of.update({u["id"]: u["class"] for u in op["enemy_units"]})
    start = {u["id"]: u["start"] for u in op["my_units"]}
    my, en = {}, {}
    if not r["now"]:
        for u in op["my_units"]:
            my[u["id"]] = {"cls": u["class"], "pos": (u["q"], u["r"]), "sol": u["soldiers"], "start": u["start"],
                           "fort": u.get("fortified", 0), "extra": ""}
        for u in op["enemy_units"]:
            en[u["id"]] = {"cls": u["class"], "pos": (u["q"], u["r"]), "troops": u["troops"], "fort": u.get("fortified", 0),
                           "extra": "eta_my_hq %s" % u.get("eta_strike_my_hq")}
        return op, my, en
    now = json.loads(r["now"])
    for line in now["my_units"]:
        head, _, vs = line.partition(" | ")
        p = head.split()
        q, rr = map(int, p[1].split(","))
        d = {"cls": cls_of.get(p[0], CLS.get(p[0].split("_")[1], "?")), "pos": (q, rr), "sol": int(p[2]),
             "start": start.get(p[0], int(p[2])), "fort": 0, "extra": vs}
        if "fort" in p:
            d["fort"] = int(p[p.index("fort") + 1])
        my[p[0]] = d
    for line in now["enemy_units"]:
        p = line.split()
        q, rr = map(int, p[1].split(","))
        d = {"cls": cls_of.get(p[0], CLS.get(p[0].split("_")[1], "?")), "pos": (q, rr), "troops": p[2], "fort": 0,
             "extra": " ".join(p[3:]).replace("fort %s" % p[p.index("fort") + 1] if "fort" in p else "@@", "").strip()}
        if "fort" in p:
            d["fort"] = int(p[p.index("fort") + 1])
        en[p[0]] = d
    return op, my, en


def short_vs(vs):
    out = []
    for e in vs.split("; "):
        p = e.split()
        if len(p) >= 7:
            x = "%s:%s %s/%s" % (p[0], p[2], p[4], p[6])
            if "fw" in p:
                x += " fw%s" % p[p.index("fw") + 1]
            out.append(x)
    return " ".join(out[:6])


def short_next(extra):
    if " next " not in " " + extra:
        return extra
    head, _, nxt = extra.partition("next ")
    n = nxt.split()[0].split(",")
    return head + "next %d" % len(n)


def show(r):
    op, my, en = parse_now(r)
    n_blue0 = sum(1 for u in op["enemy_units"] if u["class"] != "HQ")
    n_red0 = sum(1 for u in op["my_units"] if u["class"] != "HQ")
    need = math.ceil(0.7 * n_blue0)
    killed = n_blue0 - sum(1 for k, v in en.items() if v["cls"] != "HQ")
    lost = n_red0 - sum(1 for k, v in my.items() if v["cls"] != "HQ")
    print("=" * 100)
    print("%s  tier=%s style=%s army=%s turn=%d  kills %d/%d needed  lost %d (lose at %d)" % (
        r["id"], r["tier"], r["style"], r["army_size"], r["turn"], killed, need, lost, math.ceil(0.7 * n_red0)))
    print("PLAN:", r["standing_plan"] or "-")
    hi = []
    for a, s in op["matchups"].items():
        for kv in s.split(", "):
            dcl, v = kv.split(" ")
            v = float(v)
            if a not in ("SCOUT", "HQ") and dcl not in ("SCOUT", "HQ") and (v >= 1.15 or v <= 0.8):
                hi.append("%s>%s %.2f" % (a[:3], dcl[:3], v))
    print("MATCHUPS:", "; ".join(hi))
    st = r["standing_orders"]
    for k, v in my.items():
        o = st.get(k, {"do": "HOLD"})
        os_ = o["do"] + (" " + str(o.get("target")) if "target" in o else "") + (" " + str(o.get("to")) if "to" in o else "")
        if o.get("target", "").startswith("B_") and o["target"] not in en:
            os_ += "(DEAD)"
        near = sorted(en.items(), key=lambda kv: dist(v["pos"], kv[1]["pos"]))[:3]
        print("  R %-8s %-4s %4d,%-4d %4d/%-4d%s  [%s]  near: %s%s" % (
            k, v["cls"][:3], v["pos"][0], v["pos"][1], v["sol"], v["start"], " fort%d" % v["fort"] if v["fort"] else "",
            os_, ", ".join("%s d%d" % (e, dist(v["pos"], x["pos"])) for e, x in near),
            ("  | " + short_vs(v["extra"])) if v["extra"] else ""))
    for k, v in en.items():
        near = sorted(my.items(), key=lambda kv: dist(v["pos"], kv[1]["pos"]))[:2]
        print("  B %-8s %-4s %4d,%-4d %-8s%s %s  near: %s" % (
            k, v["cls"][:3], v["pos"][0], v["pos"][1], v["troops"], " fort%d" % v["fort"] if v["fort"] else "",
            short_next(v["extra"]), ", ".join("%s d%d" % (e, dist(v["pos"], x["pos"])) for e, x in near)))
    print("TEACHER:", r["teacher_answer"])


if __name__ == "__main__":
    rows = load(set(sys.argv[1:]))
    for i in sys.argv[1:]:
        show(rows[i])
