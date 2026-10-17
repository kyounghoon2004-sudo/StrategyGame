"""R1 rows: stall-triggered plan reviews -> SFT rows under the ORIGINAL (long history) prompt.
  python -m tools.synth_adv_v1.build_r1_rows [--gap 6]
Game identity = hash of the opening user message (the request carries no game id); tag/seed from the captures.
Filters: valid JSON + orders on live units/targets, plan <=300 chars with ids/numbers present in the packet, plan differs
from the standing one, >= gap turns between two kept rows of one game, game not lost within 8 turns of the row.
-> synth_adv_v1/r1_rows.json, r1_report.json
"""
import argparse, collections, hashlib, json, re
from pathlib import Path
from tools.synth_adv_v1.bank_adv import OUT
from tools.synth_adv_v1.merge_plans import check as plan_check

DD = OUT / "collect_r1"
VERBS = {"ATTACK", "MOVE", "HOLD", "RAID", "FORTIFY"}


def first_user(messages):
    for m in messages or []:
        if m.get("role") == "user":
            return m.get("content") or ""
    return ""


def gid(messages):
    return hashlib.sha1(first_user(messages).encode("utf-8")).hexdigest()[:12]


def parse(raw):
    t = (raw or "").split("</think>", 1)[-1].strip()
    try:
        return json.loads(t)
    except ValueError:
        i, j = t.find("{"), t.rfind("}")
        try:
            return json.loads(t[i:j + 1]) if i >= 0 and j > i else None
        except ValueError:
            return None


NUM2 = re.compile(r"^\[?\s*(-?\d+)\s*,\s*(-?\d+)\s*\]?$")


def normalize(a):
    """The reset prompt shows each unit's standing order as a string ("ATTACK B_INF_1"); half of the answers copy that
    form: {"do": "ATTACK B_INF_1"}. Rewrite it into the order schema, same meaning, or return None if not parseable."""
    if not isinstance(a, dict) or not isinstance(a.get("orders"), dict):
        return a
    out = {}
    for u, o in a["orders"].items():
        if not isinstance(o, dict):
            return None
        d = o.get("do")
        if isinstance(d, str) and d not in VERBS:
            parts = d.strip().split(None, 1)
            verb, rest = parts[0].upper(), (parts[1].strip() if len(parts) > 1 else "")
            if verb in ("ATTACK",) and rest and len(set(o) - {"do"}) == 0:
                o = {"do": "ATTACK", "target": rest}
            elif verb == "MOVE" and NUM2.match(rest) and len(set(o) - {"do"}) == 0:
                m = NUM2.match(rest); o = {"do": "MOVE", "to": [int(m.group(1)), int(m.group(2))]}
            elif verb == "RAID" and len(set(o) - {"do"}) == 0:
                m = re.match(r"^(\S+)\s+back(?:_to)?\s+(.+)$", rest, re.I)
                if not m:
                    return None
                b = m.group(2).strip(); n = NUM2.match(b)
                o = {"do": "RAID", "target": m.group(1), "back_to": [int(n.group(1)), int(n.group(2))] if n else b}
            else:
                return None
        out[str(u).upper()] = o
    return {**a, "orders": out}


def orders_ok(a, st):
    if not isinstance(a, dict) or not isinstance(a.get("orders"), dict) or not a["orders"]:
        return "no orders"
    mine = {u["id"] for u in st.get("my_units") or [] if isinstance(u, dict)}
    foes = {u["id"] for u in st.get("enemy_units") or [] if isinstance(u, dict)}
    for u, o in a["orders"].items():
        if u not in mine or not isinstance(o, dict) or o.get("do") not in VERBS:
            return "bad unit/verb %s" % u
        t = o.get("target")
        if t is not None and t != "ENEMY_HQ" and t not in foes:
            return "dead/unknown target %s" % t
        if o["do"] in ("ATTACK", "RAID") and t is None:
            return "attack without target"
    return ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gap", type=int, default=6)
    a = ap.parse_args()
    # game hash -> tag, seed (from the captured non-reset calls) and outcome
    tags = {}
    for l in (DD / "captures" / "calls.jsonl").read_text(encoding="utf-8").splitlines():
        if not l.strip():
            continue
        c = json.loads(l)
        if c.get("request") == "VICTORY_COMMAND" and c.get("messages") and c.get("tag"):
            tags.setdefault(gid(c["messages"]), c["tag"])
    games = {}
    for l in (DD / "games.jsonl").read_text(encoding="utf-8").splitlines():
        if l.strip():
            g = json.loads(l); games[g["tag"]] = g
    trig = [json.loads(l) for l in (OUT / "r1_triggers.jsonl").read_text(encoding="utf-8").splitlines() if l.strip()]
    stats = collections.Counter(); rows = []; last = {}
    for r in sorted(trig, key=lambda r: (gid(r["orig_messages"]), r["turn"])):
        stats["raw"] += 1
        g = gid(r["orig_messages"]); tag = tags.get(g)
        if not tag or tag not in games:
            stats["no_game"] += 1; continue
        G = games[tag]
        ans = normalize(parse(r.get("response")))
        raw_ans = parse(r.get("response"))
        if ans is not None and raw_ans is not None and ans != raw_ans:
            stats["salvaged_format"] += 1
        why = orders_ok(ans, r["state"]) if ans is not None else "unparsable"
        if why:
            stats["bad_orders"] += 1; continue
        plan = ans.get("plan")
        if not isinstance(plan, str) or not plan.strip():
            stats["no_plan"] += 1; continue
        job = {"state": json.dumps(r["state"], ensure_ascii=False), "answer": ans, "prior_plan": "", "turn": r["turn"]}
        pc = plan_check(plan, job)
        if pc:
            stats["plan_fact_fail"] += 1; continue
        cp = r["state"].get("current_plan"); old = (cp.get("text") if isinstance(cp, dict) else cp) or ""
        if old and plan.strip() == str(old).strip():
            stats["same_plan"] += 1; continue
        if G.get("outcome") == "BLUE_WIN" and int(G.get("turn") or 99) - r["turn"] <= 8:
            stats["lost_soon"] += 1; continue
        if r["turn"] - last.get(g, -99) < a.gap:
            stats["gap"] += 1; continue
        last[g] = r["turn"]
        msgs = r["orig_messages"]
        rows.append({"messages": msgs, "completion": json.dumps({"orders": ans["orders"], "plan": plan.strip()}, ensure_ascii=False),
                     "game": tag, "turn": r["turn"], "seed": str(G["seed"]), "source": "r1_review", "mission": "hq"})
        stats["kept"] += 1
    (OUT / "r1_rows.json").write_text(json.dumps(rows, ensure_ascii=False), encoding="utf-8")
    rep = {"stats": dict(stats), "games_with_rows": len({r["game"] for r in rows}),
           "turn_bins": dict(collections.Counter(r["turn"] // 10 * 10 for r in rows)),
           "outcomes": dict(collections.Counter(g.get("outcome") for g in games.values()))}
    (OUT / "r1_report.json").write_text(json.dumps(rep, indent=1), encoding="utf-8")
    print(json.dumps(rep, indent=1))


if __name__ == "__main__":
    main()
