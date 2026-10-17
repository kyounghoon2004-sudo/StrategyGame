"""Pick rows where the strategy actually changes (code), to get a plan sentence written by an agent and verified by code.
  python -m tools.synth_adv_v1.plan_targets
-> synth_adv_v1/plan_jobs.jsonl  {job, kind, turn, shift, answer, prior_plan, state(compact)}
"""
import collections, glob, json, os, re
from pathlib import Path
from tools.synth_adv_v1.bank_adv import BP, OUT


def jl(x):
    try:
        return json.loads(x) if isinstance(x, str) else x
    except ValueError:
        return {}


def packet(msgs):
    users = [m["content"] for m in msgs if m["role"] == "user"]
    return users[-1] if users else ""


def shifts(turn, orders, standing, seen):
    """-> reason or ''. seen: dict state of the game so far."""
    tg = {o.get("target") for o in orders.values() if isinstance(o, dict) and o.get("do") in ("ATTACK", "RAID") and o.get("target")}
    if "ENEMY_HQ" in tg and not seen["hq"]:
        return "start_hq_assault"
    prev = {o.get("target") for o in standing.values() if isinstance(o, dict) and o.get("target")}
    n_back = sum(1 for o in orders.values() if isinstance(o, dict) and o.get("do") == "MOVE" and o.get("to") in ("MY_HQ",))
    if n_back >= 2:
        return "pull_back"
    if tg and not (tg & prev) and prev and len(orders) >= 3:
        return "new_main_target"
    if tg and not seen["contact"]:
        return "first_contact_attack"
    if sum(1 for o in orders.values() if isinstance(o, dict) and o.get("do") == "FORTIFY") >= 2 and turn > 3:
        return "dig_in"
    return ""


def main():
    jobs = []
    # real wins: rows.jsonl rows grouped by source_dir
    rows = [json.loads(l) for l in open(BP / "real_sft" / "rows.jsonl", encoding="utf-8")]
    by = collections.defaultdict(list)
    for r in rows:
        by[r["source_dir"]].append(r)
    for sd, rs in by.items():
        rs.sort(key=lambda r: int(r["turn"]))
        standing, plan, seen = {}, "", {"hq": False, "contact": False}
        for r in rs:
            a = jl(r["response"]); orders = a.get("orders") or {}
            t = int(r["turn"])
            why = shifts(t, orders, standing, seen) if orders else ""
            if why and not a.get("plan") and t > 1:
                jobs.append({"job": "real|%s|%d" % (sd, t), "kind": "real", "turn": t, "shift": why, "answer": a,
                             "prior_plan": plan, "state": packet(r["messages"]), "standing": standing})
            tg = {o.get("target") for o in orders.values() if isinstance(o, dict) and o.get("target")}
            if "ENEMY_HQ" in tg: seen["hq"] = True
            if tg: seen["contact"] = True
            standing = {**standing, **{u: o for u, o in orders.items() if isinstance(o, dict)}}
            plan = a.get("plan") or plan
    # synthetic survivors: HQ patterns already carry a template plan; others get one
    cand = {x["sid"] + "__" + x["variant"]: x for x in map(json.loads, (OUT / "candidates.jsonl").read_text(encoding="utf-8").splitlines())}
    sit = {}
    for l in (OUT / "situations_adv.jsonl").read_text(encoding="utf-8").splitlines():
        r = json.loads(l); sit[r["id"]] = r
    for f in glob.glob(str(OUT / "full_t" / "out" / "games" / "*.json")):
        k = os.path.basename(f)[:-5]
        if "__ctrl" in k or json.load(open(f, encoding="utf-8")).get("outcome") != "RED_WIN":
            continue
        c = cand[k]; s = sit[c["sid"]]
        a = json.loads(c["answer"])
        jobs.append({"job": "synth|" + k, "kind": "synth", "turn": c["turn"], "shift": c["pattern"], "answer": a,
                     "prior_plan": s["standing_plan"], "state": packet(s["messages"]), "standing": s["standing_orders"],
                     "has_template_plan": bool(a.get("plan"))})
    (OUT / "plan_jobs.jsonl").write_text("".join(json.dumps(j, ensure_ascii=False) + "\n" for j in jobs), encoding="utf-8")
    print("jobs", len(jobs), collections.Counter((j["kind"], j["shift"]) for j in jobs).most_common())


if __name__ == "__main__":
    main()
