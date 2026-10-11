"""Synthetic RED commander (2026-10-07): writes plan + orders from the packet facts only, following the pattern the
cloud models' fast wins share (plan corpus, artifacts/brain_pipeline_v1/plan_corpus): engage at once on favourable
matchups, commit a share of the army to the enemy HQ from a set turn, fortify the HQ and answer threats to it.
It is a data generator for synthetic planning examples, not the Brain. It plays through the collector's manual mode:

  python -m tools.plan_search.synth_commander <manual dir> [--commit-turn 17] [--commit-share 0.3] [--raid]
"""
from __future__ import annotations

import argparse
import json
import re
import time
from pathlib import Path

from tools.plan_search.brain_io import _resp, _try_claim

VS_RX = re.compile(r"^(\S+) eta (\d+) dealt (\d+)-(\d+) taken (\d+)-(\d+)(?: fw (\d+))?")


def _vs(unit: dict) -> dict:
    out = {}
    for s in unit.get("vs", []):
        m = VS_RX.match(str(s))
        if m:
            out[m.group(1)] = {"eta": int(m.group(2)), "dealt": (int(m.group(3)) + int(m.group(4))) / 2,
                               "taken": (int(m.group(5)) + int(m.group(6))) / 2, "fw": int(m.group(7) or 0)}
    return out


def _mult(pkt: dict, a: str, d: str) -> float:
    m = re.search(r"\b%s ([0-9.]+)" % re.escape(d), str(pkt.get("matchups", {}).get(a, "")))
    return float(m.group(1)) if m else 1.0


def decide(pkt: dict, verbs: set, commit_turn: int, commit_share: float, raid: bool) -> dict:
    turn = int(pkt.get("turn", 0))
    mine = [u for u in pkt.get("my_units", []) if u.get("class") != "HQ"]
    foes = {e["id"]: e for e in pkt.get("enemy_units", [])}
    field_foes = [e for e in foes.values() if e.get("class") != "HQ"]
    hq_foe = next((e["id"] for e in foes.values() if e.get("class") == "HQ"), None)
    orders, lines = {}, []
    my_hq = next((u for u in pkt.get("my_units", []) if u.get("class") == "HQ"), None)
    if my_hq:
        orders[my_hq["id"]] = {"do": "FORTIFY"} if "FORTIFY" in verbs else {"do": "HOLD"}

    # 1. Strike group on the enemy HQ: from commit_turn (or once few field enemies are left), the units closest to it.
    n_commit = 0
    if hq_foe and (turn >= commit_turn or len(field_foes) <= 2):
        n_commit = len(mine) if len(field_foes) <= 2 else max(1, round(commit_share * len(mine)))
    by_hq = sorted(mine, key=lambda u: (u.get("eta", {}).get("strike_enemy_hq", 99), -u.get("soldiers", 0)))
    strike = {u["id"] for u in by_hq[:n_commit]}

    # 2. Threats to my HQ (BLUE units about to strike it) get the best available answer first.
    threats = sorted([e for e in field_foes if int(e.get("eta_strike_my_hq", 99)) <= 3],
                     key=lambda e: int(e.get("eta_strike_my_hq", 99)))
    taken_by = {}
    why = {}  # unit id -> the fact behind its order (for the synthetic thinking)
    free = [u for u in mine if u["id"] not in strike]
    for e in threats:
        best = max(free, key=lambda u: (_mult(pkt, u["class"], e["class"]), -_vs(u).get(e["id"], {}).get("eta", 99)),
                   default=None)
        if best:
            orders[best["id"]] = {"do": "ATTACK", "target": e["id"]}
            why[best["id"]] = "%s can strike my HQ in %s turn(s); %s answers it (matchup %.2f)" % (
                e["id"], e.get("eta_strike_my_hq"), best["id"], _mult(pkt, best["class"], e["class"]))
            taken_by.setdefault(e["id"], []).append(best["id"])
            free.remove(best)
            lines.append("%s answers the threat %s" % (best["id"], e["id"]))

    # 3. Everyone else engages the field enemy it fares best against (net preview per turn of approach), at most two
    #    attackers per enemy so the line does not pile onto one target.
    for u in free:
        vs = _vs(u)
        cands = []
        for e in field_foes:
            v = vs.get(e["id"])
            if not v:
                continue
            # fieldworks damage counts as progress: a fortified target shows 0 soldiers dealt until they break
            score = _mult(pkt, u["class"], e["class"]) * (v["dealt"] + 0.5 * v["fw"] - v["taken"]) / (1 + v["eta"])
            cands.append((len(taken_by.get(e["id"], [])) >= 2, -score, e["id"]))
        if not cands:
            if hq_foe:
                strike.add(u["id"])
            continue
        _, _, tgt = min(cands)
        v = vs[tgt]
        why[u["id"]] = "%s vs %s: matchup %.2f, deals ~%d%s, takes ~%d, in range in %d turn(s)" % (
            u["class"], foes[tgt]["class"], _mult(pkt, u["class"], foes[tgt]["class"]), v["dealt"],
            (" plus %d to its fieldworks" % v["fw"]) if v["fw"] else "", v["taken"], v["eta"])
        taken_by.setdefault(tgt, []).append(u["id"])
        if raid and u["class"] == "CAVALRY" and foes[tgt]["class"] == "ARCHER" and "RAID" in verbs:
            orders[u["id"]] = {"do": "RAID", "target": tgt, "back_to": "MY_HQ"}
        else:
            orders[u["id"]] = {"do": "ATTACK", "target": tgt}
    for uid in strike:
        orders[uid] = {"do": "ATTACK", "target": "ENEMY_HQ"}
        u = next(x for x in mine if x["id"] == uid)
        why[uid] = "strike group: reaches the enemy HQ in %s turn(s)" % u.get("eta", {}).get("strike_enemy_hq", "?")

    pairs = ", ".join("%s>%s" % (k, v["target"]) for k, v in orders.items() if v.get("do") in ("ATTACK", "RAID")
                      and v.get("target") != "ENEMY_HQ")
    plan = ("Engage on favourable matchups now; %s; HQ %s." % (
        ("%s strike the enemy HQ" % ", ".join(sorted(strike))) if strike else
        "a strike group turns on the enemy HQ from turn %d" % commit_turn,
        "fortified" if "FORTIFY" in verbs else "holds"))[:300]
    notes = ("t%d: %d field enemies left. Pairings: %s. %s" % (turn, len(field_foes), pairs, "; ".join(lines)))[:600]
    tl = pkt.get("turns_left")
    my_n = sum(u.get("soldiers", 0) for u in mine)
    think = "\n".join([
        "SITUATION: Turn %d, %s turns left. %d field units (%d soldiers) against %d visible BLUE field units%s." % (
            turn, tl, len(mine), my_n, len(field_foes),
            "" if not my_hq else "; my HQ %s" % ("fortified" if my_hq.get("fortified") else "not fortified")),
        "BLUE: " + ("; ".join("%s (%s) can strike my HQ in %s turn(s)%s" % (
            e["id"], e["class"], e.get("eta_strike_my_hq"),
            (", next turn it can hit " + ", ".join(e["can_strike_next"])) if e.get("can_strike_next") else "")
            for e in sorted(field_foes, key=lambda e: int(e.get("eta_strike_my_hq", 99)))[:4]) or "no field units left."),
        "DECISIONS:",
        *["- %s %s: %s." % (uid, " ".join(str(x) for x in o.values()), why.get(uid, "holds the HQ")) for uid, o in orders.items()],
        "CHECK: %s" % (("the strike group needs %s turn(s) to reach the HQ, inside the %s turns left" % (
            min((next(x for x in mine if x["id"] == uid).get("eta", {}).get("strike_enemy_hq", 99) for uid in strike), default="?"), tl))
            if strike else "turn %d: hand the field fight to a strike group on the enemy HQ from turn %d" % (turn, commit_turn)),
    ])
    return {"plan": plan, "notes": notes, "orders": orders, "think": think}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("manual_dir")
    ap.add_argument("--commit-turn", type=int, default=17)
    ap.add_argument("--commit-share", type=float, default=0.3)
    ap.add_argument("--raid", action="store_true")
    ap.add_argument("--agent", default="SYNTH")
    a = ap.parse_args()
    d = Path(a.manual_dir)
    d.mkdir(parents=True, exist_ok=True)
    while True:
        for f in sorted(d.glob("req_*.json")):
            if _resp(f).exists() or not _try_claim(f, a.agent):
                continue
            r = json.loads(f.read_text(encoding="utf-8"))
            if r.get("request") != "VICTORY_COMMAND":
                _resp(f).write_text("{}", encoding="utf-8")
                continue
            system = r["messages"][0]["content"]
            verbs = {v for v in ("FORTIFY", "RAID", "REST", "ASSAULT", "GARRISON") if '"do": "%s"' % v in system}
            pkt = r.get("state") or json.loads(r["messages"][-1]["content"])  # resident game: full state rides along
            doc = decide(pkt, verbs, a.commit_turn, a.commit_share, a.raid)
            _resp(f).write_text(json.dumps(doc, ensure_ascii=False), encoding="utf-8")
        time.sleep(0.5)


if __name__ == "__main__":
    main()
