"""Review batches v2 for an external agent: explicit procedure, explicit DO / DO NOT lists, worked example, self-check, one JSON file per batch.
Only turns that still have no usable decision (empty/unparsable/not reviewed)."""
import json, os
from tools.synth_adv_v1.hz_pipeline import HZ, student_turns
from tools.synth_adv_v1.hz_teacher_bench import PLAYBOOK, parse_json, user_text
from tools.synth_adv_v1.facts_shim import facts_block

N = 6
scr = {(r["src"], r["tag"], r["turn"]): r for r in map(json.loads, (HZ / "screen.jsonl").read_text(encoding="utf-8").splitlines())}
have = set()
for l in (HZ / "reviews.jsonl").read_text(encoding="utf-8").splitlines():
    j = json.loads(l)
    if isinstance(parse_json(j["answer"]), dict):
        have.add((j["src"], j["tag"], j["turn"]))
todo = [(s, t, n, c) for s, t, n, c in student_turns() if scr[(s, t, n)]["bad"] and (s, t, n) not in have]

PROC = """
## HOW TO REVIEW ONE ITEM (follow these steps IN ORDER; do not skip)

STEP 1. Read the FACTS block of the item. It lists: which of the six hexes around the enemy HQ are occupied (ring), which RED archers
        are within distance 2-3 of the enemy HQ, which standing melee orders cannot execute. Treat FACTS as true.
STEP 2. Write down (in your head) the list L of RED units whose CURRENT order (standing order + the student's change) is one of:
        (a) a melee unit (infantry, cavalry, scout, spearman) ordered ATTACK ENEMY_HQ while all six ring hexes are occupied;
        (b) an archer inside distance 2-3 of the enemy HQ that is not ordered ATTACK ENEMY_HQ;
        (c) an ATTACK/RAID on a unit id that is dead or not in the packet;
        (d) an order that is an obvious waste: attacking a fortified unit that the preview shows 0 damage dealt, or an empty orders object
            while units idle although the HQ can be hit.
STEP 3. If L is empty and the plan has no kill-quota wording -> decision "pass".
STEP 4. Otherwise decision "replace". Your response.orders MUST contain an entry for EVERY unit in L (not only the first one you find).
        Choose ONE focus target among the ring units (the weakest: fewest troops/fieldworks) and send ALL blocked melee units at that
        same unit. Archers in range -> ATTACK ENEMY_HQ. Dead target -> pick a live ring unit (ring full) or ENEMY_HQ (ring not full).
STEP 5. Self-check before writing: every unit id in orders appears in this item's packet; every target is a live BLUE id or ENEMY_HQ;
        no melee unit is left on ATTACK ENEMY_HQ while the ring is full; every archer in range is on ATTACK ENEMY_HQ.

## DO
- Name the exact unit ids and target ids that appear in the packet.
- Keep the student's good orders: do not list units that were already fine.
- plan: ONE sentence, max 300 chars, saying what the group does now and why (use numbers/ids from the packet only), or omit plan.
- If the situation is lost on the clock, still send units to the enemy HQ / ring: the HQ is the only win condition.

## DO NOT
- Do NOT write kill quotas ("need 5 kills", "3 of 8 kills"). There are none.
- Do NOT invent unit ids, hexes or numbers that are not in the packet.
- Do NOT order a melee unit at ENEMY_HQ when the ring is full.
- Do NOT answer "pass" just because the student's answer looks reasonable: run STEP 2 on every unit.
- Do NOT change units that are fine; do NOT rewrite everything.
- Do NOT use tools, search files or read other files. Answer from this file only.

## WORKED EXAMPLE (ids are fictional)
Facts: ring of B_HQ_9 is full (B_INF_1, B_INF_2, B_SPE_1, B_ARC_1, B_CAV_1, B_SPE_2). R_ARC_1 at distance 3 of B_HQ_9.
Student: {"orders": {"R_INF_1": {"do":"ATTACK","target":"ENEMY_HQ"}, "R_CAV_1": {"do":"ATTACK","target":"ENEMY_HQ"}}, "plan":"Need 6 kills to win"}
Standing: R_SPE_1 ATTACK ENEMY_HQ, R_ARC_1 HOLD.
L = R_INF_1, R_CAV_1, R_SPE_1 (melee at full ring), R_ARC_1 (archer in range not shooting).  Weakest ring unit: B_ARC_1.
Correct answer: {"decision":"replace","reason":"ring full: melee focus B_ARC_1; archer must shoot HQ; no kill quota",
 "response":{"orders":{"R_INF_1":{"do":"ATTACK","target":"B_ARC_1"},"R_CAV_1":{"do":"ATTACK","target":"B_ARC_1"},
 "R_SPE_1":{"do":"ATTACK","target":"B_ARC_1"},"R_ARC_1":{"do":"ATTACK","target":"ENEMY_HQ"}},
 "plan":"Ring is full, so the melee group breaks B_ARC_1 together while R_ARC_1 shells the HQ from range."}}
"""
HEAD = ("# Review batch (v2)\n\nYou are a careful reviewing commander for RED. Below: the rules, a step-by-step procedure, then ITEMS. "
        "For EACH item produce one decision object. Write ALL results as ONE JSON array to the output file named at the end:\n"
        "[{\"item\": \"<id exactly as in the ITEM header>\", \"decision\": \"pass\"|\"replace\", \"reason\": \"<=160 chars\", "
        "\"response\": {\"orders\": {...}, \"plan\": \"...\"}}]  (`response` only for replace).\n\n## RULES\n\n" + PLAYBOOK + "\n" + PROC)
out = HZ / "review_v2"; out.mkdir(exist_ok=True)
for f in os.listdir(out):
    os.remove(out / f)
idx = []
for b in range(0, len(todo), N):
    name = "v2_%03d" % (b // N)
    md = [HEAD]
    for s, t, n, c in todo[b:b + N]:
        iid = "%s|%s|%d" % (s, t, n)
        prop = parse_json(c.get("raw")) or {}
        md.append("\n---\n## ITEM %s\n### PACKET (turn %s)\n%s\n### FACTS\n%s\n### STUDENT'S PROPOSED ANSWER\n%s\n" %
                  (iid, n, user_text(c), facts_block(c["state"]), json.dumps(prop, ensure_ascii=False)))
        idx.append({"batch": name, "item": iid})
    md.append("\n---\nOUTPUT: write the JSON array to answers_%s.json in the same folder as this file, then validate that it parses.\n" % name)
    (out / (name + ".md")).write_text("".join(md), encoding="utf-8")
(out / "index.json").write_text(json.dumps(idx), encoding="utf-8")
print("items", len(todo), "batches", (len(todo) + N - 1) // N)
