"""Gate A: exact harvest messages/completions and prior standing commander state.

python -m tools.synth_sft_v3.situations_grind
No sft_collect_v2 rows are used; game records only validate the real grind bank.
"""
from __future__ import annotations

import collections
import json

from tools.synth_sft_v3.grind_bank import BP, OUT, decoded


def main():
    bank = json.loads((OUT / "bank_grind.json").read_text(encoding="utf-8"))
    cache, output = {}, []
    for game, b in bank.items():
        orders, plan = {}, ""
        for turn in sorted(b["answers"], key=int):
            filename, index = b["rows"][turn]
            if filename not in cache:
                cache[filename] = json.loads((BP / filename).read_text(encoding="utf-8"))
            original = cache[filename][index]
            assert original["game"] == game and original["turn"] == int(turn)
            assert original["completion"] == b["answers"][turn]
            msgs = original["messages"]
            users = [m["content"] for m in msgs if m["role"] == "user"]
            opening = json.loads(users[0])
            now = json.loads(users[-1]) if len(users) > 1 else None
            alive = {x.split()[0] for x in now["my_units"]} if now else {u["id"] for u in opening["my_units"]}
            orders = {uid: order for uid, order in orders.items() if uid in alive}
            output.append({
                "id": f"{game}__t{turn}", "game": game, "turn": int(turn),
                "tier": b["tier"], "style": b["style"], "family": b["family"],
                "army_size": b["army_size"], "seed": b["seed"], "mission": original["mission"],
                "source": "seed_grind", "source_run": b["source_run"], "game_file": b["game_file"],
                "teacher_answer": original["completion"], "messages": msgs,
                "opening": users[0], "now": users[-1] if len(users) > 1 else "",
                "standing_orders": dict(orders), "standing_plan": plan,
                "harvest_row": [filename, index],
            })
            answer = decoded(original["completion"])
            orders.update({str(uid).upper(): order for uid, order in (answer.get("orders") or {}).items() if isinstance(order, dict)})
            new_plan = str(answer.get("plan", "")).strip()[:400]
            plan = new_plan or plan
    assert len({r["id"] for r in output}) == len(output)
    target = OUT / "situations_grind.jsonl"
    with target.open("w", encoding="utf-8", newline="\n") as stream:
        for row in output:
            stream.write(json.dumps(row, ensure_ascii=False) + "\n")
    audit = {"situations": len(output), "games": len(bank),
             "by_tier": dict(collections.Counter(r["tier"] for r in output)),
             "messages_equal_original": True, "completion_equal_original": True,
             "standing_semantics": "commander_controller.gd: dictionary orders only, uppercase IDs, dead own units pruned; top-level plan stripped and capped at 400"}
    (OUT / "situations_grind_audit.json").write_text(json.dumps(audit, indent=2), encoding="utf-8")
    print(json.dumps(audit))


if __name__ == "__main__":
    main()
