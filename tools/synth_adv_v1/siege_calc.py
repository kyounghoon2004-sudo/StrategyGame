"""HQ siege calculator (2026-10-17, user): the game's combat formula (scripts/combat/combat_calculator.gd, calculate_combat,
variance 1.0, morale neutral in the sandbox) ported for ONE question: if RED units keep attacking the BLUE HQ from their arrival
turns, when do its fieldworks break, when do its troops reach 0, and when does each attacker die from counter-attacks.
Mechanics (game code): a strike first hits the fieldworks; the excess of THAT strike passes to the troops; fieldworks damage
accumulates attack by attack; a unit fortifies only once per game, so broken fieldworks never come back (2026-10-18).
Not modelled: BLUE moving/attacking, HQ ring capacity and paths, the HQ attacking. Those are stated as assumptions.
  python -m tools.synth_adv_v1.siege_calc --validate <games/*.json>   (per-hit check against a recorded game)
"""
import json
import re
import sys

FW_HP = 180


def norm(c):
    c = str(c).lower()
    return {"archers": "archer", "spearman": "spear", "spearmen": "spear", "scouts": "scout"}.get(c, c)


def matchup_from_table(table, atk, dfn):
    atk, dfn = norm(atk), norm(dfn)
    if atk == dfn:
        return 1.0
    if "%s_vs_%s" % (atk, dfn) in table:
        return float(table["%s_vs_%s" % (atk, dfn)])
    if "%s_vs_%s" % (dfn, atk) in table:
        return 1.0 / float(table["%s_vs_%s" % (dfn, atk)])
    if atk == "scout" and "scout_vs_regular" in table:
        return float(table["scout_vs_regular"])
    if dfn == "scout" and "scout_vs_regular" in table:
        return 1.0 / float(table["scout_vs_regular"])
    return 1.0


def strike(stats, mult, atk_cls, atk_n, def_cls, def_n, fw, dist):
    """-> (fieldworks damage, defender casualties, attacker casualties): calculate_combat with variance 1.0."""
    sa, sd = stats[norm(atk_cls)], stats[norm(def_cls)]
    eff_atk = atk_n / 100.0 * float(sa["attack"]) * mult
    eff_def = def_n / 100.0 * float(sd["defense"])
    power = min(max(eff_atk / max(eff_def, 0.001), 0.0), 1.0)
    ratio = min(max(eff_atk / (max(eff_def, 1.0) * 4.2 + 80.0), 0.04 * power), 0.60)
    pct = round(def_n * ratio)
    finish = min(def_n, round(eff_atk * 0.60))
    if fw > 0:
        s = max(1, max(pct, round(eff_atk * 0.60)))
        fwd = min(s, fw)
        cas = min(max(s - fwd, 0), def_n)
    else:
        fwd, cas = 0, min(max(max(pct, finish), 1), def_n)
    took = 0
    if dist == 1 and def_n > 0:
        cm = 1.0 / mult
        eca = def_n / 100.0 * float(sd["attack"]) * cm
        ecd = atk_n / 100.0 * float(sa["defense"])
        cs = min(max(eca / max(ecd, 0.001), 0.0), 1.0)
        cr = min(max(eca / (max(ecd, 1.0) * 5.5 + 110.0), 0.02 * cs), 0.40)
        took = min(max(max(round(atk_n * cr), min(atk_n, round(eca * 0.40))), 0), atk_n)
    return fwd, cas, took


def round_half_even_guard():
    """GDScript roundi rounds half away from zero; Python round() is banker's rounding. Patch round for parity."""
    import math
    def r(x):
        return int(math.floor(x + 0.5)) if x >= 0 else -int(math.floor(-x + 0.5))
    return r


round = round_half_even_guard()  # noqa: A001  (module-level: every round() above is GDScript roundi)


def stats_from_state(st):
    out = {}
    for k, v in (st.get("class_stats") or {}).items():
        out[norm(k)] = v
    return out


def mult_from_state(st, atk_cls, def_cls="HQ"):
    line = (st.get("matchups") or {}).get(str(atk_cls).upper(), "")
    m = re.search(r"\b%s ([\d.]+)" % str(def_cls).upper(), line)
    return float(m.group(1)) if m else 1.0


def ring_info(st, ehq):
    """-> (number of free hexes touching the BLUE HQ, ids of RED units already on those hexes)."""
    q, r = ehq["q"], ehq["r"]
    ring = [(q + 1, r), (q - 1, r), (q, r + 1), (q, r - 1), (q + 1, r - 1), (q - 1, r + 1)]
    occ = {(u["q"], u["r"]): u["id"] for u in (st.get("my_units") or []) + (st.get("enemy_units") or [])
           if isinstance(u, dict) and "q" in u}
    on_ring = [occ[h] for h in ring if h in occ and occ[h].startswith("R_")]
    return sum(1 for h in ring if h not in occ), on_ring


def project(st, troops, horizon=None, ring_aware=True):
    """Turn-by-turn siege of the BLUE HQ from the request state; troops = assumed true HQ soldiers.
    ring_aware: a melee unit can strike only from a hex touching the HQ - the RED melee units already there, plus as many
    arriving melee units (in arrival order) as there are free ring hexes now. Ranged units always can."""
    turn = int(st.get("turn") or 0)
    limit = int(st.get("turn_limit") or 60)
    stats = stats_from_state(st)
    ehq = next((u for u in st.get("enemy_units") or [] if isinstance(u, dict) and u.get("class") == "HQ"), None)
    if not ehq or not stats:
        return None
    fw = int(ehq.get("fortified") or 0)
    att = []
    for u in st.get("my_units") or []:
        if not isinstance(u, dict) or u.get("class") == "HQ":
            continue
        eta = (u.get("eta") or {}).get("strike_enemy_hq")
        if eta is None:
            continue
        rng = int((stats.get(norm(u["class"])) or {}).get("range", 1))
        att.append({"id": u["id"], "cls": u["class"], "n": int(u["soldiers"]), "arr": turn + int(eta),
                    "dist": 1 if rng == 1 else min(3, rng), "mult": mult_from_state(st, u["class"])})
    free_now, _ = ring_info(st, ehq)
    if ring_aware and free_now == 0:  # only a FULLY blocked ring keeps melee out (hexes free up and refill otherwise)
        free, on_ring = ring_info(st, ehq)
        ranged = [a for a in att if a["dist"] > 1]
        melee = sorted([a for a in att if a["dist"] == 1], key=lambda a: (a["id"] not in on_ring, a["arr"]))
        keep = [a for a in melee if a["id"] in on_ring]
        keep += [a for a in melee if a["id"] not in on_ring][:free]
        att = ranged + keep
    att.sort(key=lambda x: x["id"])
    ev, first_break, fall, deaths = [], None, None, {}
    for t in range(turn, min(limit, horizon or limit) + 1):
        for a in att:
            if a["n"] <= 0 or t < a["arr"] or troops <= 0:
                continue
            fwd, cas, took = strike(stats, a["mult"], a["cls"], a["n"], "hq", troops, fw, a["dist"])
            fw -= fwd
            troops -= cas
            a["n"] -= took
            if fw == 0 and first_break is None:
                first_break = t
            if a["n"] <= 0 and a["id"] not in deaths:
                deaths[a["id"]] = t
        if troops <= 0:
            fall = t
            break
    return {"first_break": first_break, "fall": fall, "deaths": deaths, "used": sorted(a["id"] for a in att),
            "troops_left": max(troops, 0),
            "survivors": {a["id"]: a["n"] for a in att if a["n"] > 0}}


def band(s):
    p = [int(x) for x in re.findall(r"\d+", str(s))]
    return (p[0], p[-1]) if p else (0, 0)


def siege_text(st):
    ehq = next((u for u in st.get("enemy_units") or [] if isinstance(u, dict) and u.get("class") == "HQ"), None)
    if not ehq:
        return ""
    lo, hi = band(ehq.get("troops"))
    out = []
    for label, tr in (("low", lo), ("high", hi)):
        p = project(st, tr)
        if not p:
            return ""
        out.append("if HQ troops = %d (%s end of its band): fieldworks first broken t%s; HQ falls %s; attackers lost to "
                   "counter-attacks: %s" % (tr, label, p["first_break"] or "never",
                                             "at t%d" % p["fall"] if p["fall"] else
                                             "NOT before the turn limit (%d troops left)" % p["troops_left"],
                                             ", ".join("%s t%d" % kv for kv in sorted(p["deaths"].items(), key=lambda x: x[1]))
                                             or "none"))
    free, on_ring = ring_info(st, ehq)
    used = project(st, lo)["used"]
    return ("SIEGE FORECAST (the game's own combat formula, exact per hit; ESTIMATE over turns): ring hexes free now %d, RED "
            "melee already on the ring: %s. Counted attackers: %s (all ranged units + melee units; "
            "melee units are left out only while all 6 ring hexes are taken). Assumes they attack the BLUE HQ every turn from their arrival, "
            "open paths, BLUE not interfering: " % (free, ",".join(on_ring) or "none", ",".join(used) or "none") + " | ".join(out))


def validate(path):
    g = json.load(open(path, encoding="utf-8"))
    rec = g["record"]
    rules = rec["rules"]
    stats = {norm(k): v for k, v in rules["class_stats"].items()}
    table = rules.get("matchup", {})
    snaps = {(s["turn"], s.get("to_act", "?")): {u[0]: u for u in s["units"]} for s in rec["snapshots"]}
    acts = [a for a in rec["actions"].get("red", []) if str(a.get("target", "")).startswith("B_HQ")]
    ok = bad = 0
    state = {}
    for a in acts:
        t = int(a["turn"])
        sn = snaps.get((t, "red"))
        if not sn:
            continue
        key = t
        if key not in state:  # HQ soldiers and fieldworks when RED starts acting this turn
            hq = sn[a["target"]]
            state[key] = {"troops": int(hq[5]), "fw": int(hq[7]) if len(hq) > 7 else 0}
        s = state[key]
        u = sn[a["unit"]]
        rng = int(stats[norm(u[2])].get("range", 1))
        dist = max(1, abs(u[3] - sn[a["target"]][3]) + abs(u[4] - sn[a["target"]][4]) + abs(u[3] + u[4] - sn[a["target"]][3] - sn[a["target"]][4])) // 2
        dist = 1 if rng == 1 else max(2, dist)  # a melee unit always strikes from an adjacent hex (it may have moved first)
        fwd, cas, took = strike(stats, matchup_from_table(table, u[2], "hq"), u[2], int(u[5]), "hq", s["troops"], s["fw"], dist)
        rec_fw, rec_cas, rec_took = int(a.get("fieldworks") or 0), int(a.get("dealt") or 0), int(a.get("took") or 0)
        match = (fwd, cas, took) == (rec_fw, rec_cas, rec_took)
        ok += match
        bad += not match
        if not match:
            print("MISMATCH t%d %s(%s,%d) vs HQ troops %d fw %d dist %d: calc fw %d dealt %d took %d | game fw %d dealt %d took %d" % (
                t, a["unit"], u[2], u[5], s["troops"], s["fw"], dist, fwd, cas, took, rec_fw, rec_cas, rec_took))
        s["fw"] = max(0, s["fw"] - rec_fw)
        s["troops"] = max(0, s["troops"] - rec_cas)
    print("%s: %d HQ attacks, %d exact, %d mismatched" % (path.split("\\")[-1].split("/")[-1], ok + bad, ok, bad))
    return ok, bad


if __name__ == "__main__":
    if sys.argv[1] == "--validate":
        tot = [0, 0]
        for p in sys.argv[2:]:
            o, b = validate(p)
            tot[0] += o
            tot[1] += b
        print("TOTAL exact %d / %d" % (tot[0], tot[0] + tot[1]))
