"""Harness-Zero teacher benchmark (user, 2026-10-15): is gemini-3.8-flash-high good enough as the reviewer?
Items = real student turns (v3b_536, thinking off, plain prompt) from the HQ-blockade games; ground truth by code:
  BAD  = the student's proposal (plus the orders left standing) contains something that cannot work given the facts
         (melee unit ordered at the enemy HQ with all six HQ-adjacent hexes occupied; archers in range not shooting the HQ;
          kill-quota wording in the plan; orders on dead/unknown targets; empty orders while ranged units could hit the HQ)
  OK   = none of that.
The reviewer sees the packet + FACTS + the proposal and answers pass/replace(+response). Scored by code only.

  python -m tools.synth_adv_v1.hz_teacher_bench --model gemini-3.8-flash-high --n 40 --out <dir>
"""
import argparse
import concurrent.futures as cf
import json
import random
import re
import time
from pathlib import Path

from tools.plan_search.cloud_brain import _run_agy
from tools.synth_adv_v1.facts_shim import facts_block, dist
from tools.ckpt_sweep.items import RULES

ROOT = Path(__file__).resolve().parents[2]
BP = ROOT / "artifacts" / "brain_pipeline_v1" / "synth_adv_v1"
VERBS = {"ATTACK", "MOVE", "HOLD", "RAID", "FORTIFY"}
QUOTA = re.compile(r"(?i)\b(need|require)s?\s+\d+\s+(of\s+\d+\s+)?kills?|\b\d+\s*(of|/)\s*\d+\s*kills?")

PLAYBOOK = """You are the reviewing commander for RED in a hex wargame. A small student model proposed this turn's answer; you review it
BEFORE it is executed. Mission: RED wins only by destroying the BLUE HQ (there are no kill quotas); RED loses if the RED HQ falls.

""" + RULES + """

Order schema (JSON): {"orders": {"<RED unit id>": {"do": "ATTACK", "target": "<BLUE unit id or ENEMY_HQ>"} | {"do": "MOVE", "to": [q, r]} |
{"do": "HOLD"} | {"do": "FORTIFY"} | {"do": "RAID", "target": ..., "back_to": ...} }, "plan": "<optional, at most 300 chars>"}.
"orders" lists only units whose order changes; every other unit keeps its standing order. An ATTACK order moves toward the target
and hits only it.

Playbook: (1) a melee unit can hit the HQ only from a hex touching it; if all six are occupied it cannot, so it must first help
destroy a ring unit (focus fire on ONE ring unit; fortified units soak 180 earthwork points first) or wait; (2) archers within
distance 2-3 of the enemy HQ shoot it over any units, so they should be ordered ATTACK ENEMY_HQ; (3) an order on a dead target does
nothing; (4) keep the RED HQ fortified; (5) the plan is a strategy sentence, rewrite it only when the strategy changes.

Answer with ONE JSON object and nothing else:
{"decision": "pass" | "replace", "reason": "<at most 160 chars>", "response": {"orders": {...}, "plan": "..."}}
"response" only when decision is "replace". Keep corrections minimal: change only the units that need it. Use only unit ids that
exist in the packet. If the student's answer is sound, answer pass."""


def user_text(c):
    return [m["content"] for m in c["messages"] if m["role"] == "user"][-1]


def parse_json(raw):
    t = (raw or "").split("</think>", 1)[-1].strip()
    try:
        return json.loads(t)
    except ValueError:
        i, j = t.find("{"), t.rfind("}")
        try:
            return json.loads(t[i:j + 1]) if i >= 0 and j > i else None
        except ValueError:
            return None


def analyse(st, orders, plan):
    """-> list of problems of (standing orders + this proposal)."""
    mine = {u["id"]: u for u in st.get("my_units") or [] if isinstance(u, dict)}
    foes = {u["id"]: u for u in st.get("enemy_units") or [] if isinstance(u, dict)}
    stats = st.get("class_stats") or {}
    ehq = next((u for u in foes.values() if u.get("class") == "HQ"), None)
    probs = []
    if not ehq:
        return probs
    hq = (ehq["q"], ehq["r"])
    where = {(u["q"], u["r"]) for u in list(mine.values()) + list(foes.values())}
    ring = [(hq[0] + dq, hq[1] + dr) for dq, dr in [(1, 0), (-1, 0), (0, 1), (0, -1), (1, -1), (-1, 1)]]
    ring_full = all(h in where for h in ring)
    final = {}
    for uid, u in mine.items():
        o = str(u.get("order") or "")
        final[uid] = ("ATTACK", "ENEMY_HQ") if o == "ATTACK ENEMY_HQ" else (o.split(" ")[0], o.split(" ", 1)[1] if " " in o else "")
    for uid, o in (orders or {}).items():
        if isinstance(o, dict):
            final[uid] = (str(o.get("do")), str(o.get("target") or ""))
    rng = lambda uid: (stats.get(mine[uid].get("class")) or {}).get("range", 1)
    for uid, (verb, tgt) in final.items():
        if uid not in mine or mine[uid].get("class") == "HQ":
            continue
        if verb in ("ATTACK", "RAID") and tgt not in ("ENEMY_HQ",) and tgt not in foes:
            probs.append("dead_or_unknown_target:%s" % uid)
        if verb == "ATTACK" and tgt == "ENEMY_HQ" and rng(uid) < 2 and ring_full:
            probs.append("melee_cannot_reach_hq:%s" % uid)
        d = dist((mine[uid]["q"], mine[uid]["r"]), hq)
        if rng(uid) >= 2 and 2 <= d <= rng(uid) and not (verb == "ATTACK" and tgt == "ENEMY_HQ"):
            probs.append("archer_in_range_not_shooting_hq:%s" % uid)
    if plan and QUOTA.search(plan):
        probs.append("kill_quota_wording")
    return probs


def review_prompt(c, st, proposal):
    return (PLAYBOOK + "\n\n=== CURRENT PACKET (turn %s) ===\n%s\n\n=== FACTS (computed by the game) ===\n%s\n\n"
            "=== STUDENT'S PROPOSED ANSWER ===\n%s\n" % (st.get("turn"), user_text(c), facts_block(st), json.dumps(proposal, ensure_ascii=False)))


def load_items(n, seed=3):
    rows = []
    for d in ("ptest/blockade_control", "ptest/blockade_review"):
        p = BP / d / "captures" / "red" / "calls.jsonl"
        for l in p.read_text(encoding="utf-8").splitlines():
            if not l.strip():
                continue
            c = json.loads(l)
            if c.get("request") != "VICTORY_COMMAND" or not c.get("messages") or not isinstance(c.get("state"), dict):
                continue
            prop = parse_json(c.get("raw"))
            if not isinstance(prop, dict) or not isinstance(prop.get("orders"), dict) or int(c["turn"]) < 5:
                continue
            probs = analyse(c["state"], prop["orders"], prop.get("plan"))
            rows.append({"c": c, "prop": prop, "probs": probs, "bad": bool(probs)})
    rng = random.Random(seed)
    bad = [r for r in rows if r["bad"]]
    ok = [r for r in rows if not r["bad"]]
    rng.shuffle(bad); rng.shuffle(ok)
    return bad[:n // 2] + ok[:n - min(len(bad), n // 2)], len(bad), len(ok)


def score(item, out):
    st = item["c"]["state"]
    r = parse_json(out)
    res = {"parsed": isinstance(r, dict), "decision": None, "valid": False, "residual": None, "minimal": None, "correct_decision": None}
    if not isinstance(r, dict):
        return res
    dec = str(r.get("decision", "")).lower()
    res["decision"] = dec
    res["correct_decision"] = (dec == "replace") == item["bad"] if dec in ("pass", "replace") else False
    if dec == "pass":
        res["valid"] = True
        res["residual"] = item["probs"]
        return res
    resp = r.get("response") if isinstance(r.get("response"), dict) else {}
    orders = resp.get("orders")
    mine = {u["id"] for u in st.get("my_units") or [] if isinstance(u, dict)}
    foes = {u["id"] for u in st.get("enemy_units") or [] if isinstance(u, dict)}
    ok = isinstance(orders, dict) and orders
    if ok:
        for u, o in orders.items():
            if u not in mine or not isinstance(o, dict) or o.get("do") not in VERBS:
                ok = False
            elif o.get("target") not in (None, "ENEMY_HQ") and o.get("target") not in foes:
                ok = False
    res["valid"] = bool(ok) and (not resp.get("plan") or len(str(resp["plan"])) <= 300)
    if res["valid"]:
        res["residual"] = analyse(st, orders, resp.get("plan"))
        res["minimal"] = len(orders)
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="gemini-3.8-flash-high")
    ap.add_argument("--n", type=int, default=40)
    ap.add_argument("--workers", type=int, default=6)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    items, nbad, nok = load_items(a.n)
    print("pool: bad %d, ok %d | benchmark items %d (bad %d)" % (nbad, nok, len(items), sum(1 for i in items if i["bad"])), flush=True)

    def run(it):
        t0 = time.time()
        try:
            text, usage, _, _ = _run_agy(a.model, "", review_prompt(it["c"], it["c"]["state"], it["prop"]), 420)
        except Exception as e:  # noqa: BLE001
            text, usage = "ERR " + str(e)[:200], {}
        return {"turn": it["c"]["turn"], "tag": it["c"].get("tag"), "bad": it["bad"], "probs": it["probs"], "answer": text,
                "s": round(time.time() - t0, 1), "usage": usage, "score": score(it, text)}

    with cf.ThreadPoolExecutor(a.workers) as ex:
        res = list(ex.map(run, items))
    (out / "bench.jsonl").write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in res), encoding="utf-8")
    n = len(res)
    sc = [r["score"] for r in res]
    bad = [r for r in res if r["bad"]]; ok = [r for r in res if not r["bad"]]
    print("model", a.model, "| n", n)
    print("parsed %d/%d, valid %d/%d" % (sum(s["parsed"] for s in sc), n, sum(s["valid"] for s in sc), n))
    print("decision correct: %d/%d (bad turns replaced %d/%d, ok turns passed %d/%d)" % (
        sum(1 for s in sc if s["correct_decision"]), n, sum(1 for r in bad if r["score"]["decision"] == "replace"), len(bad),
        sum(1 for r in ok if r["score"]["decision"] == "pass"), len(ok)))
    rep = [r for r in res if r["score"]["decision"] == "replace" and r["score"]["valid"]]
    print("replacements valid and with no residual problem: %d/%d" % (sum(1 for r in rep if not r["score"]["residual"]), len(rep)))
    print("median replace size (units changed): %s | median latency %.0fs" % (
        sorted(r["score"]["minimal"] for r in rep)[len(rep) // 2] if rep else "-", sorted(r["s"] for r in res)[n // 2]))


if __name__ == "__main__":
    main()
