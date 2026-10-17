"""Rule-based synthetic candidates for the ADV-win situations (facts from the packet; plans only state checked facts).
  python -m tools.synth_adv_v1.author_adv [--n 500]
-> synth_adv_v1/candidates.jsonl  {"sid","variant","pattern","answer","plan_facts"}
"""
import argparse, collections, json, random, re
from tools.synth_adv_v1.bank_adv import OUT
from tools.synth_sft_v3.authoring import proposals, attack
import tools.synth_sft_v3.crosscheck as XC
from tools.synth_sft_v3.crosscheck import check
from tools.synth_sft_v3.view import parse_now, dist

def _decode(v):
    try:
        return json.loads(v) if isinstance(v, str) else v
    except ValueError:
        from tools.synth_sft_v3.grind_bank import decode_answer
        return decode_answer(v)


XC.decode_answer = _decode

DROP_PLAN_TEXT = {
    "retarget_dead_preserve_focus": "Units whose targets died retarget live enemies; the rest keep their focus.",
    "coordinated_focus_finish": "Healthy units focus one reachable enemy field unit; HQ stays fortified.",
    "matchup_two_target_pressure": "Split into class-counter groups on two weak enemy units to avoid bad melee matchups.",
    "withdraw_damaged_reform_focus": "Pull battered units back to the rear; healthy units keep pressure on one target.",
    "cavalry_soft_target_raid_screen": "Cavalry raids archers/scouts and returns; main body grinds the hard targets.",
    "concentrated_fieldworks_break": "Mass hitters on one fortified enemy until its fieldworks collapse.",
    "visible_hq_threat_intercept": "Intercept the enemy about to reach my HQ with nearby units; keep the rest on the main target.",
}


def hq_patterns(s):
    op, mine, enemies = parse_now(s)
    ehq = next((u for u, v in enemies.items() if v["cls"] == "HQ"), None)
    mhq = next((u for u, v in mine.items() if v["cls"] == "HQ"), None)
    if not ehq:
        return []
    red = {u: v for u, v in mine.items() if v["cls"] != "HQ"}
    blue = {u: v for u, v in enemies.items() if v["cls"] != "HQ"}
    good = [u for u, v in red.items() if v["sol"] / max(1, v["start"]) >= .35]
    standing = s.get("standing_orders", {})
    t = int(s["turn"])
    out = []
    if len(good) >= 3 and t >= 15:
        orders = {u: {"do": "ATTACK", "target": "ENEMY_HQ"} for u in good}
        if mhq and not mine[mhq]["fort"]:
            orders[mhq] = {"do": "FORTIFY"}
        out.append(("hq_mass_assault", {"orders": orders,
                    "plan": "Turn %d: %d healthy units go for the BLUE HQ together while %d BLUE field units remain; my HQ digs in." % (t, len(good), len(blue))}))
    if len(good) >= 4 and t >= 12 and blue:
        near = sorted(blue, key=lambda b: min(dist(red[u]["pos"], blue[b]["pos"]) for u in good))
        guards = [u for u in good if red[u]["cls"] in ("CAVALRY", "SPEARMAN")][:2]
        rest = [u for u in good if u not in guards]
        if guards and len(rest) >= 2:
            orders = {u: {"do": "ATTACK", "target": near[0]} for u in guards}
            orders.update({u: {"do": "ATTACK", "target": "ENEMY_HQ"} for u in rest})
            out.append(("hq_assault_with_screen", {"orders": orders,
                        "plan": "Turn %d: %d units strike the BLUE HQ; %d fast/spear units hold off the nearest BLUE unit %s." % (t, len(rest), len(guards), near[0])}))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=500)
    ap.add_argument("--seed", type=int, default=7)
    a = ap.parse_args()
    rng = random.Random(a.seed)
    sits = [json.loads(l) for l in (OUT / "situations_adv.jsonl").read_text(encoding="utf-8").splitlines()]
    by_game = collections.defaultdict(list)
    for s in sits:
        by_game[s["game"]].append(s)
    pool, seen_rej = [], collections.Counter()
    for g, ss in by_game.items():
        last = max(s["turn"] for s in ss)
        for s in ss:
            if s["turn"] < 5 or s["turn"] > last - 2 or s["turn"] % 2:
                continue
            cands = [(p, ans) for p, ans, _ in proposals(s)]
            for p, ans, _ in [(p, ans, 0) for p, ans in hq_patterns(s)]:
                cands.append((p, ans))
            for p, ans in cands:
                if p in DROP_PLAN_TEXT and "plan" in ans:
                    pass
                txt = json.dumps(ans, ensure_ascii=False, separators=(",", ":"))
                probs = [x for x in check(s, txt) if x != "no actionable changed order"]
                if probs:
                    seen_rej[p] += 1
                    continue
                # actionable = at least one order differs from the standing order
                st = s["standing_orders"]
                if not any(o != st.get(u) for u, o in ans["orders"].items()):
                    seen_rej[p + ":same"] += 1
                    continue
                pool.append({"sid": s["id"], "game": g, "turn": s["turn"], "pattern": p, "answer": txt})
    # stratified pick: round-robin over (pattern) then games
    rng.shuffle(pool)
    buckets = collections.defaultdict(list)
    for c in pool:
        buckets[c["pattern"]].append(c)
    pick, per_pat = [], collections.Counter()
    while len(pick) < a.n and any(buckets.values()):
        for p in sorted(buckets):
            if buckets[p] and len(pick) < a.n:
                pick.append(buckets[p].pop())
    for i, c in enumerate(pick):
        c["variant"] = "c%04d" % i
    (OUT / "candidates.jsonl").write_text("".join(json.dumps(c, ensure_ascii=False) + "\n" for c in pick), encoding="utf-8")
    print("pool", len(pool), "picked", len(pick), "rejected", dict(seen_rej))
    print("by pattern", dict(collections.Counter(c["pattern"] for c in pick)))
    print("games", len({c["game"] for c in pick}), "situations", len({c["sid"] for c in pick}))
    print("turn buckets", dict(collections.Counter(min(c["turn"] // 10 * 10, 50) for c in pick)))


if __name__ == "__main__":
    main()
