"""Refine the code-tested survivor SFT set (commander_survivors_20261007, built by tools/plan_search/survivor_policy.py).

The orders stay exactly as played. Only the words change: the policy wrote its own parameters into plan/notes/thinking
("Execute flank: hq_defense=1, opening_flank=8", "configured reserve"). Here every decision's thinking, plan and notes
are rewritten from what the packet shows plus the commander's own standing intent (when the strike group goes in,
how wide the opening swing is), so a student learns to reason from visible facts. Later packets of the same game
echo the earlier plan/notes (current_plan, history "RED decision" lines), so those are rewritten to match and the
history cap is re-applied the way commander_controller.gd does it.

Only strategies that win fast are kept (median winning turn <= --max-median, games over --max-turn dropped).

  python -m tools.cmd_rl.refine_survivors [--src <dir>] [--out <file>]
"""
from __future__ import annotations

import argparse
import json
import random
import re
import statistics
from collections import Counter, defaultdict
from pathlib import Path

from tools.plan_search.synth_commander import _mult

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "artifacts" / "brain_pipeline_v1" / "commander_survivors_20261007"
HISTORY_CAP = 16000
VS_RX = re.compile(r"^(\S+) eta (\d+) dealt (\d+)-(\d+) taken (\d+)-(\d+)(?: fw (\d+))?")
OMIT_RX = re.compile(r"^\((\d+) earlier history lines omitted\)$")
BANNED = re.compile(r"configured|commit_|abandon|hq_defense|field_attack|opening_|reserve_share|=\d|policy|Execute ")


def hexd(a, b):
    dq, dr = a[0] - b[0], a[1] - b[1]
    return (abs(dq) + abs(dr) + abs(dq + dr)) // 2


def vs_map(u):
    out = {}
    for s in u.get("vs", []):
        m = VS_RX.match(str(s))
        if m:
            out[m.group(1)] = dict(eta=int(m.group(2)), dealt="%s-%s" % m.group(3, 4), taken="%s-%s" % m.group(5, 6),
                                   fw=int(m.group(7) or 0))
    return out


def band(e):
    lo, _, hi = str(e.get("troops", "0")).partition("-")
    return int(lo or 0), int(hi or lo or 0)


def ids(us):
    return ", ".join(us) if len(us) <= 3 else "%s and %d more" % (", ".join(us[:2]), len(us) - 2)


class Writer:
    """Words for one decision. `p` = the strategy's own intent (turns and shares it committed to)."""

    def __init__(self, pkt, orders, branches, p, rng):
        self.pkt, self.orders, self.br, self.p, self.rng = pkt, orders, branches, p, rng
        self.turn = int(pkt["turn"])
        self.mine = {u["id"]: u for u in pkt["my_units"]}
        self.foes = {e["id"]: e for e in pkt["enemy_units"]}
        self.field = [e for e in pkt["enemy_units"] if e["class"] != "HQ"]
        self.hq = next((u for u in pkt["my_units"] if u["class"] == "HQ"), None)
        self.ehq = next((e for e in pkt["enemy_units"] if e["class"] == "HQ"), None)
        self.n_field_mine = sum(u["class"] != "HQ" for u in pkt["my_units"])

    def pick(self, *opts):
        return self.rng.choice(opts)

    # ---- intent, stated as the commander's own plan ----
    def strike_reason(self):
        p, n = self.p, len(self.field)
        if n <= p["cleanup_count"]:
            return "only %d BLUE field unit%s left, so everyone turns on the enemy HQ" % (n, "" if n == 1 else "s")
        if self.turn >= p["abandon_turn"]:
            return "turn %d: no more time to trade in the field, everything goes at the enemy HQ" % self.turn
        if self.turn >= p["commit_turn"]:
            return "from turn %d the units nearest the enemy HQ (about %d%% of the army) go for it" % (
                p["commit_turn"], round(100 * p["commit_share"]))
        return "already close to the enemy HQ, so it goes straight in"

    def plan_text(self):
        p, t = self.p, self.turn
        parts = []
        if p["opening_turns"] and t <= p["opening_turns"] and p["opening"] == "flank":
            parts.append("Turns 1-%d: swing wide around BLUE's line toward their HQ" % p["opening_turns"])
        elif p["opening_turns"] and t <= p["opening_turns"] and p["opening"] == "defend":
            parts.append("Turns 1-%d: dig in and let BLUE come onto fortified lines" % p["opening_turns"])
        elif p["opening_turns"] and t <= p["opening_turns"] and p["opening"] == "regroup":
            parts.append("Turns 1-%d: pull the army together" % p["opening_turns"])
        else:
            parts.append("Fight BLUE's field units on the best trades (matchup, losses, distance), at most %d on one target"
                         % p["max_focus"])
        if p["commit_turn"] <= 1:
            parts.append("most of the army drives on the enemy HQ from the start")
        else:
            parts.append("from turn %d about %d%% of the army goes for the enemy HQ" % (p["commit_turn"], round(100 * p["commit_share"])))
        parts.append("all in once %d or fewer BLUE field units remain or by turn %d" % (p["cleanup_count"], p["abandon_turn"]))
        parts.append("HQ fortified%s" % ("; any BLUE unit within %d turns of it gets answered first" % p["threat_eta"]))
        return ("; ".join(parts) + ".")[:300]

    # ---- per-unit reasons from packet facts ----
    def reason(self, uid, o, b):
        u, f, kind = self.mine.get(uid, {}), b.get("facts", {}), b["branch"]
        vs = vs_map(u)
        tgt = o.get("target")
        if kind == "hq_defense":
            fw = u.get("fortified")
            return "%s fortifies%s" % (uid, (" (fieldworks %s)" % fw) if fw else "")
        if kind in ("field_attack", "raid", "hq_threat", "unfavorable_hold", "distant_regroup"):
            t = tgt if kind != "unfavorable_hold" and kind != "distant_regroup" else f.get("target")
            e, v = self.foes.get(t, {}), vs.get(t)
            m = _mult(self.pkt, u.get("class", ""), e.get("class", ""))
            pv = ("in range in %d, kills %s, loses %s%s" % (v["eta"], v["dealt"], v["taken"],
                  (", %d to fieldworks" % v["fw"]) if v["fw"] else "")) if v else "no preview"
            if kind == "hq_threat":
                return "%s on %s: %s is %s turns from my HQ; %s %.2f vs %s, %s" % (
                    uid, t, t, f.get("eta_strike_my_hq"), u.get("class", "").lower(), m, e.get("class", "").lower(), pv)
            if kind == "unfavorable_hold":
                return "%s holds: its best target %s would cost too much (%s)" % (uid, t, pv)
            if kind == "distant_regroup":
                return "%s falls back to my HQ: %s is far off (%s)" % (uid, t, pv)
            s = "%s on %s (%s %.2f vs %s): %s" % (uid, t, u.get("class", "").lower(), m, e.get("class", "").lower(), pv)
            if kind == "raid":
                s += ", then back toward %s" % o.get("back_to")
            return s
        if kind == "hq_strike":
            return "%s on the enemy HQ, in range in %s" % (uid, f.get("eta"))
        if kind == "no_field_target":
            return "%s on the enemy HQ: no BLUE field unit in its preview" % uid
        if kind == "reserve":
            return "%s stays dug in %d hexes from my HQ as a reserve" % (uid, f.get("distance_my_hq", 0))
        if kind == "wounded_retreat":
            return "%s is down to %s of %s soldiers: back to my HQ" % (uid, u.get("soldiers"), u.get("start"))
        if kind == "wounded_fortify":
            return "%s is down to %s of %s soldiers: digs in" % (uid, u.get("soldiers"), u.get("start"))
        if kind == "opening_defend":
            near = min((v["eta"] for v in vs.values()), default=None)
            return "%s digs in%s" % (uid, (", nearest BLUE unit %d turns off" % near) if near is not None else "")
        if kind == "opening_flank":
            d = f.get("destination") or o.get("to")
            near = min((hexd(d, (e["q"], e["r"])) for e in self.field), default=0)
            return "%s swings to %s (%d hexes from the nearest BLUE unit, %d from their HQ)" % (
                uid, d, near, hexd(d, f.get("enemy_hq", d)))
        if kind in ("opening_regroup", "regroup_anchor"):
            return "%s %s" % (uid, "anchors the regroup" if kind == "regroup_anchor" else "joins %s" % o.get("to"))
        if kind == "no_visible_target":
            return "%s holds: no BLUE unit visible" % uid
        return "%s %s" % (uid, o.get("do", "").lower())

    def write(self):
        pk, p, t = self.pkt, self.p, self.turn
        mine_f = [u for u in pk["my_units"] if u["class"] != "HQ"]
        lo = sum(band(e)[0] for e in self.field)
        hi = sum(band(e)[1] for e in self.field)
        cls = Counter(e["class"].lower() for e in self.field)
        L = ["Turn %d of %d, %s left. Asked: %s." % (t, pk.get("turn_limit", 80), pk.get("turns_left"), pk.get("why_asked"))]
        L.append("Mine: %d field units, %d soldiers (started %d)%s." % (
            len(mine_f), sum(u["soldiers"] for u in mine_f), sum(u.get("start", u["soldiers"]) for u in mine_f),
            ("; HQ %d soldiers%s" % (self.hq["soldiers"], (", fieldworks %s" % self.hq["fortified"]) if self.hq.get("fortified") else ", not dug in")) if self.hq else ""))
        L.append("BLUE: %s%s." % (
            ("%d field units (%s), %d-%d troops" % (len(self.field), ", ".join("%d %s" % (n, c) for c, n in sorted(cls.items())), lo, hi))
            if self.field else "no field units visible",
            ("; HQ %s-%s troops%s" % (*band(self.ehq), (", fieldworks %s" % self.ehq["fortified"]) if self.ehq.get("fortified") else "")) if self.ehq else ""))
        threats = sorted((e for e in self.field if int(e.get("eta_strike_my_hq", 99)) <= max(p["threat_eta"], 3)),
                         key=lambda e: int(e.get("eta_strike_my_hq", 99)))
        if threats:
            L.append("Threats to my HQ: " + "; ".join("%s in %s turns" % (e["id"], e["eta_strike_my_hq"]) for e in threats) + ".")
        elif self.field:
            c = min(self.field, key=lambda e: int(e.get("eta_strike_my_hq", 99)))
            L.append("No BLUE unit near my HQ (closest: %s, %s turns)." % (c["id"], c.get("eta_strike_my_hq")))
        cp = pk.get("current_plan") or {}
        if cp.get("text"):
            L.append("Standing plan (turn %s): keep it%s." % (cp.get("since_turn"), self.pick("", " and adjust the pairings", " unless the facts changed")))
        # decisions, grouped
        strike = [u for u, b in self.br.items() if b["branch"] == "hq_strike"]
        L.append("Orders:")
        if strike:
            L.append("- Enemy HQ: %s; %s." % (ids(sorted(strike)), self.strike_reason()))
            L.append("  " + "; ".join(self.reason(u, self.orders[u], self.br[u]) for u in sorted(strike, key=lambda x: self.br[x]["facts"].get("eta") or 99)) + ".")
        swing = defaultdict(list)  # same destination -> one line
        for uid, o in self.orders.items():
            if self.br.get(uid, {}).get("branch") == "opening_flank":
                swing[tuple(o.get("to"))].append(uid)
        for uid, o in self.orders.items():
            b = self.br.get(uid, {"branch": "?", "facts": {}})
            if b["branch"] == "hq_strike":
                continue
            if b["branch"] == "opening_flank":
                grp = swing.pop(tuple(o.get("to")), None)
                if grp:
                    L.append("- " + self.reason(uid, o, b).replace(uid, ", ".join(grp), 1).replace(" swings ", " swing " if len(grp) > 1 else " swings ", 1) + ".")
                continue
            L.append("- " + self.reason(uid, o, b) + ".")
        # check
        chk = []
        if strike:
            fast = min(self.br[u]["facts"].get("eta") or 99 for u in strike)
            chk.append("first strike unit in range in %d, %s turns left" % (fast, pk.get("turns_left")))
        elif self.ehq and t < p["commit_turn"]:
            chk.append("strike group goes in at turn %d" % p["commit_turn"])
        guards = [u for u, b in self.br.items() if b["branch"] in ("hq_threat", "reserve")]
        if threats:
            chk.append("threats answered by %s" % (ids(guards) if guards else "nobody free"))
        if chk:
            L.append("Check: " + "; ".join(chk) + ".")
        think = "\n".join(L)
        pairs = Counter(o.get("target") for o in self.orders.values() if o.get("do") in ("ATTACK", "RAID") and o.get("target") != "ENEMY_HQ")
        notes = "t%d: BLUE %d field units%s. %s%s" % (
            t, len(self.field), (" (%d-%d troops)" % (lo, hi)) if self.field else "",
            ("Targets: %s. " % ", ".join("%s x%d" % kv for kv in pairs.items())) if pairs else "",
            ("Strike group on the HQ: %s." % ids(sorted(strike))) if strike else
            ("Strike group goes in at turn %d." % p["commit_turn"] if t < p["commit_turn"] else ""))
        return think, self.plan_text(), notes[:600]


def recap(history):
    total = sum(len(h) + 3 for h in history)
    if total <= HISTORY_CAP:
        return history
    k0 = 0
    m = OMIT_RX.match(history[0]) if history else None
    if m:
        k0, history = int(m.group(1)), history[1:]
        total = sum(len(h) + 3 for h in history)
    k = 0
    while total > HISTORY_CAP and k < len(history):
        total -= len(history[k]) + 3
        k += 1
    return ["(%d earlier history lines omitted)" % (k0 + k)] + history[k:]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=str(SRC))
    ap.add_argument("--out", default=str(SRC / "sft_refined.json"))
    ap.add_argument("--max-median", type=float, default=30)
    ap.add_argument("--max-turn", type=int, default=35)
    a = ap.parse_args()
    src = Path(a.src)
    rows = json.loads((src / "sft_robust.json").read_text(encoding="utf-8"))
    lin = json.loads((src / "sft_lineage.json").read_text(encoding="utf-8"))
    pop = {p["id"]: p for p in json.loads((src / "population.json").read_text(encoding="utf-8"))}
    from tools.plan_search.survivor_policy import DEFAULT
    end = {}
    for line in (src / "results.jsonl").read_text(encoding="utf-8").splitlines():
        r = json.loads(line)
        if r.get("kind") == "WIN":
            end[r["game"]] = r["turn"]
    games = defaultdict(list)
    for i, (r, l) in enumerate(zip(rows, lin)):
        assert r["game"] == l["game"] and r["turn"] == l["trace"]["turn"]
        games[r["game"]].append(i)
    med = defaultdict(list)
    for g, idx in games.items():
        med[(rows[idx[0]]["tier"], rows[idx[0]]["strategy"])].append(end[g])
    keep_strat = {k for k, v in med.items() if statistics.median(v) <= a.max_median}

    out, stats = [], Counter()
    for g, idx in games.items():
        r0 = rows[idx[0]]
        if (r0["tier"], r0["strategy"]) not in keep_strat or end[g] > a.max_turn:
            continue
        p = DEFAULT | pop[r0["strategy"]]["params"]
        rng = random.Random(g)
        new_plan = []  # (old plan, new plan, new notes) per decision, in game order
        for i in sorted(idx, key=lambda i: rows[i]["turn"]):
            r = rows[i]
            pkt = json.loads(r["messages"][-1]["content"])
            think_old, _, ans = r["completion"].partition("\n</think>\n\n")
            reply = json.loads(ans)
            # echo the rewritten earlier decisions in this packet
            prev = {old: (np, nn) for old, np, nn in new_plan}
            reds = [j for j, h in enumerate(pkt["history"]) if " RED decision " in h]
            for j, (old, np_, _) in zip(reds, new_plan[-len(reds):] if reds else []):
                h = pkt["history"][j]
                assert ("plan: %s | orders:" % old) in h, (g, h[:200])
                pkt["history"][j] = h.replace("plan: %s | orders:" % old, "plan: %s | orders:" % np_, 1)
            pkt["history"] = recap(pkt["history"])
            cp = pkt.get("current_plan")
            if cp and cp.get("text"):
                assert new_plan and cp["text"] == new_plan[-1][0]
                cp["text"], cp["notes"] = new_plan[-1][1], new_plan[-1][2]
            w = Writer(pkt, reply["orders"], lin[i]["trace"]["branches"], p, rng)
            think, plan, notes = w.write()
            for s in (think, plan, notes):
                assert not BANNED.search(s), (g, s)
            new_plan.append((reply["plan"], plan, notes))
            doc = {"plan": plan, "notes": notes, "orders": reply["orders"]}
            msgs = [dict(m) for m in r["messages"]]
            msgs[-1]["content"] = json.dumps(pkt, ensure_ascii=False)
            out.append({"messages": msgs, "completion": think + "\n</think>\n\n" + json.dumps(doc, ensure_ascii=False),
                        "game": g, "tier": r["tier"], "turn": r["turn"], "run": r["run"], "strategy": r["strategy"],
                        "win_turn": end[g]})
            stats[r["tier"]] += 1
    Path(a.out).write_text(json.dumps(out, ensure_ascii=False), encoding="utf-8")
    print("strategies kept", sorted(keep_strat))
    print("rows", len(out), dict(stats), "games", len({r["game"] for r in out}))


if __name__ == "__main__":
    main()
