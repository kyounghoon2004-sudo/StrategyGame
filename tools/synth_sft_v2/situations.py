"""Synthetic commander SFT v2 (2026-10-09), step 2: situations for agents to answer.

Every decision of every bank game (real teacher wins) becomes a situation: the exact messages the game sent at that
turn (the SFT row's messages), plus a compact view an author can read quickly: the opening facts (unit stats,
matchups, board), the current turn message (events, every unit now), and the orders / plan standing before this turn.
An author writes new answers in the game's own format; branch.py then plays each one in Godot (cross-check).

  python -m tools.synth_sft_v2.situations        -> synth_sft_v2/situations.jsonl
"""
from __future__ import annotations

import json
from pathlib import Path

from tools.synth_sft_v2.bank import COLL, OUT


def standing(completions: list) -> tuple[dict, str]:
    orders, plan = {}, ""
    for c in completions:
        try:
            a = json.loads(c)
        except ValueError:
            continue
        orders.update(a.get("orders") or {})
        plan = a.get("plan") or plan
    return orders, plan


def main():
    bank = json.loads((OUT / "bank.json").read_text(encoding="utf-8"))
    files = {}
    rows_out = []
    for g, b in bank.items():
        turns = sorted(b["rows"], key=int)
        for i, t in enumerate(turns):
            f, idx = b["rows"][t]
            if f not in files:
                files[f] = json.loads((COLL / f).read_text(encoding="utf-8"))
            row = files[f][idx]
            msgs = row["messages"]
            users = [m["content"] for m in msgs if m["role"] == "user"]
            orders, plan = standing([b["answers"][x] for x in turns[:i]])
            rows_out.append({"id": "%s__t%s" % (g, t), "game": g, "turn": int(t), "tier": b["tier"], "style": b["style"],
                             "army_size": b["army_size"], "teacher_answer": b["answers"][t],
                             "opening": users[0], "now": users[-1] if len(users) > 1 else "",
                             "standing_orders": orders, "standing_plan": plan, "messages": msgs})
    with open(OUT / "situations.jsonl", "w", encoding="utf-8") as fo:
        for r in rows_out:
            fo.write(json.dumps(r) + "\n")
    print("situations %d from %d games" % (len(rows_out), len(bank)))


if __name__ == "__main__":
    main()
