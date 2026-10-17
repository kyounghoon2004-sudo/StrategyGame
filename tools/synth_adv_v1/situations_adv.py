"""Decision situations of the ADV-win bank (row shape of tools.synth_sft_v3 situations).
  python -m tools.synth_adv_v1.situations_adv
"""
import json
from tools.synth_adv_v1.bank_adv import BP, OUT
from tools.synth_sft_v3.grind_bank import decode_answer


def main():
    bank = json.loads((OUT / "bank_adv.json").read_text(encoding="utf-8"))
    out = []
    for g, b in bank.items():
        last = {}
        for l in (BP / b["src_dir"] / "captures" / "calls.jsonl").read_text(encoding="utf-8").splitlines():
            if l.strip():
                c = json.loads(l)
                if c.get("request") == "VICTORY_COMMAND" and c.get("messages"):
                    last[int(c["turn"])] = c
        orders, plan = {}, ""
        for t in sorted(int(k) for k in b["answers"]):
            c = last[t]
            users = [m["content"] for m in c["messages"] if m["role"] == "user"]
            opening = json.loads(users[0])
            now = json.loads(users[-1]) if len(users) > 1 else None
            alive = {x.split()[0] for x in now["my_units"]} if now else {u["id"] for u in opening["my_units"]}
            orders = {u: o for u, o in orders.items() if u in alive}
            raw = b["answers"][str(t)]
            out.append({"id": "%s__t%d" % (g, t), "game": g, "turn": t, "tier": "ADV", "style": b["style"],
                        "family": b["family"], "seed": b["seed"], "teacher_answer": raw, "messages": c["messages"],
                        "opening": users[0], "now": users[-1] if len(users) > 1 else "",
                        "standing_orders": dict(orders), "standing_plan": plan})
            try:
                a = decode_answer(raw)
            except Exception:
                a = {}
            orders.update({str(u).upper(): o for u, o in (a.get("orders") or {}).items() if isinstance(o, dict)})
            plan = str(a.get("plan", "")).strip()[:400] or plan
    with (OUT / "situations_adv.jsonl").open("w", encoding="utf-8", newline="\n") as f:
        for r in out:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    print("situations", len(out), "games", len(bank))


if __name__ == "__main__":
    main()
