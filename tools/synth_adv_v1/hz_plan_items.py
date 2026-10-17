"""Plan-review items for the teacher (user, 2026-10-15): teach Qwen to KEEP or REVISE its plan, with the reason.

Qwen never revises the plan it wrote on turn 1 -- in any game, not only the blockade. The teacher is a MODEL (external agent), not
code: at chosen turns of the harvested student games it sees what Qwen sees (packet + its standing plan) PLUS the next turns of
that same game and how it ended (hindsight, which Qwen will not have), and decides: KEEP (the plan is still right, say why)
or REVISE (write the plan that wins, say why the old one fails). Code only builds the items and validates the format.

  python -m tools.synth_adv_v1.hz_plan_items            # -> hz/plan_review/items.jsonl + batch_NNN.md (6 items each)
Teacher answer file (per batch): answers_batch_NNN.json = [{"item": id, "verdict": "keep"|"revise",
  "text": "KEEP: <why>. <plan>" | "REVISE: <why old plan fails>. <new plan>"  (<=300 chars, ids from the packet)}]
"""
import collections
import json
import os
import random
import re
from pathlib import Path

from tools.synth_adv_v1.hz_pipeline import HZ, SOURCES
from tools.synth_adv_v1.stall_shim import progress

OUT = HZ / "plan_review"
N = 6
PER_GAME = 10
HORIZON = 10
ATK = re.compile(r"^t(\d+) ([RB])_\S+ attack (\S+): dealt (\d+) took (\d+)(?: fieldworks -(\d+))?")


def user_json(c):
    return json.loads([m["content"] for m in c["messages"] if m["role"] == "user"][-1])


def standing_plan(c):
    plan = None
    for m in c["messages"]:
        if m["role"] != "assistant":
            continue
        try:
            d = json.loads(m["content"])
        except ValueError:
            continue
        if isinstance(d, dict) and d.get("plan"):
            plan = d["plan"]
    return plan


def games():
    for src, path in SOURCES:
        g = collections.defaultdict(dict)
        for l in path.read_text(encoding="utf-8").splitlines():
            if not l.strip():
                continue
            c = json.loads(l)
            if c.get("request") == "VICTORY_COMMAND" and c.get("messages") and isinstance(c.get("state"), dict) and c.get("turn") is not None:
                g[c["tag"]][int(c["turn"])] = c
        for tag, turns in g.items():
            yield src, tag, turns


def outcome_of(src, tag):
    f = HZ / ("harvest_" + ("blockade" if src == "BLOCKADE" else src)) / "games.jsonl"
    for l in f.read_text(encoding="utf-8").splitlines():
        j = json.loads(l)
        t = j.get("tag") or "%s_s%s" % (j.get("model"), j.get("seed"))
        if t == tag:
            return "%s at turn %s (RED %s of %s units alive, BLUE %s of %s)" % (
                j.get("kind") or j.get("outcome"), j.get("turn"), j["units"]["red"]["alive"], j["units"]["red"]["start"],
                j["units"]["blue"]["alive"], j["units"]["blue"]["start"])
    return "unknown"


def future_digest(turns, T):
    """What happened over the next HORIZON turns of this very game (hindsight; Qwen does not see it)."""
    rows = []
    seen = set()
    for t in range(T, T + HORIZON + 1):
        c = turns.get(t + 1) or turns.get(t)
        if not c:
            break
        u = user_json(c)
        dealt = took = fw = 0
        for e in u.get("events") or []:
            x = ATK.match(e)
            if x and T <= int(x.group(1)) <= T + HORIZON and e not in seen:
                seen.add(e)
                if x.group(2) == "R":
                    dealt += int(x.group(4)); fw += int(x.group(6) or 0); took += int(x.group(5))
                else:
                    took += int(x.group(4))
        s = c["state"]
        hq = next((e for e in s["enemy_units"] if e["class"] == "HQ"), None)
        mine = next((e for e in s["my_units"] if e["class"] == "HQ"), None)
        rows.append({"turn": int(c["turn"]), "red_units": len(s["my_units"]), "blue_units": len(s["enemy_units"]),
                     "blue_hq_fieldworks": hq.get("fortified") if hq else None, "red_hq_soldiers": mine.get("soldiers") if mine else None})
    ev = [e for t in range(T + 1, T + HORIZON + 2) for e in ((user_json(turns[t]).get("events") or []) if t in turns else [])]
    ev = list(dict.fromkeys(e for e in ev if ATK.match(e) or "destroyed" in e))[:14]
    return {"per_turn": rows[::2] if len(rows) > 6 else rows, "key_events": ev}


def pick_points(turns):
    ts = sorted(turns)
    pts = [ts[0]]
    last = ts[0]
    for t in ts:
        if t < 8 or t - last < 5 or t + 3 > ts[-1]:
            continue
        prog, _ = progress(turns[t]["messages"], t, 5)
        if prog < 40 or (t - last) >= 9:
            pts.append(t)
            last = t
    return pts[:PER_GAME]


def main():
    OUT.mkdir(exist_ok=True)
    for f in OUT.iterdir():
        if f.is_file():
            f.unlink()
    items = []
    rng = random.Random(4)
    for src, tag, turns in games():
        res = outcome_of(src, tag)
        for T in pick_points(turns):
            c = turns[T]
            u = [m["content"] for m in c["messages"] if m["role"] == "user"][-1]
            items.append({"id": "%s|%s|%d" % (src, tag, T), "src": src, "tag": tag, "turn": T, "plan": standing_plan(c),
                          "packet": u, "future": future_digest(turns, T), "result": res,
                          "own_orders": (json.loads(c["raw"].split("</think>")[-1]).get("orders") if c.get("raw") else None)
                          if c.get("raw") else None})
    rng.shuffle(items)
    (OUT / "items.jsonl").write_text("".join(json.dumps(i, ensure_ascii=False) + "\n" for i in items), encoding="utf-8")
    head = open(Path(__file__).with_name("hz_plan_teacher_prompt.md"), encoding="utf-8").read()
    for b in range(0, len(items), N):
        name = "batch_%03d" % (b // N)
        md = [head]
        for it in items[b:b + N]:
            md.append("\n---\n## ITEM %s\n### YOUR CURRENT STANDING PLAN (what Qwen wrote earlier; null = none yet)\n%s\n"
                      "### WHAT QWEN SEES THIS TURN (the game packet)\n%s\n"
                      "### HINDSIGHT (Qwen does NOT see this: the next turns of this same game and how the game ended)\n"
                      "result: %s\n%s\n" % (it["id"], json.dumps(it["plan"], ensure_ascii=False), it["packet"], it["result"],
                                            json.dumps(it["future"], ensure_ascii=False)))
        md.append("\n---\nOUTPUT: write the JSON array to answers_%s.json in the same folder as this file, then validate it parses.\n" % name)
        (OUT / (name + ".md")).write_text("".join(md), encoding="utf-8")
    print("items", len(items), "batches", (len(items) + N - 1) // N, dict(collections.Counter(i["src"] for i in items)),
          "with standing plan", sum(1 for i in items if i["plan"]))


if __name__ == "__main__":
    main()
