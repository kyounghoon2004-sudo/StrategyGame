"""Export the pending Harness-Zero review items as cold-prompt batch files for an external agent (answers -> JSON, ingested by hz_review_ingest)."""
import json, re
from pathlib import Path
from tools.synth_adv_v1.hz_pipeline import HZ, student_turns
from tools.synth_adv_v1.hz_teacher_bench import PLAYBOOK, parse_json, user_text
from tools.synth_adv_v1.facts_shim import facts_block

N = 8
scr = {(r["src"], r["tag"], r["turn"]): r for r in map(json.loads, (HZ / "screen.jsonl").read_text(encoding="utf-8").splitlines())}
done = {}
for l in (HZ / "reviews.jsonl").read_text(encoding="utf-8").splitlines():
    j = json.loads(l)
    if j["answer"].strip() and not j["answer"].startswith("ERR"):
        done[(j["src"], j["tag"], j["turn"])] = 1
todo = [(s, t, n, c) for s, t, n, c in student_turns() if scr[(s, t, n)]["bad"] and (s, t, n) not in done]
out = HZ / "review_batches"; out.mkdir(exist_ok=True)
head = ("# Review batch\n\nYou are the reviewing commander described below. For EACH item, read the packet, FACTS and the student's "
        "proposed answer, then decide pass/replace. Answer from this file only (no tools, no other files).\n"
        "Write your result to the output path given at the end as a JSON array: "
        "[{\"item\": <id>, \"decision\": \"pass\"|\"replace\", \"reason\": \"...\", \"response\": {\"orders\": {...}, \"plan\": \"...\"}}, ...] "
        "(`response` only when decision is replace).\n\n## INSTRUCTIONS (apply to every item)\n\n" + PLAYBOOK + "\n")
index = []
for b in range(0, len(todo), N):
    chunk = todo[b:b + N]; name = "batch_%03d" % (b // N)
    md = [head]
    for i, (s, t, n, c) in enumerate(chunk):
        iid = "%s|%s|%d" % (s, t, n)
        prop = parse_json(c.get("raw")) or {}
        md.append("\n---\n## ITEM %s\n### PACKET (turn %s)\n%s\n### FACTS\n%s\n### STUDENT'S PROPOSED ANSWER\n%s\n" %
                  (iid, n, user_text(c), facts_block(c["state"]), json.dumps(prop, ensure_ascii=False)))
        index.append({"batch": name, "item": iid})
    md.append("\n---\nOUTPUT: write the JSON array to answers_%s.json in the same folder as this file. Use item ids exactly as in the ITEM headers.\n" % name)
    (out / (name + ".md")).write_text("".join(md), encoding="utf-8")
(out / "index.json").write_text(json.dumps(index), encoding="utf-8")
print("items", len(todo), "batches", (len(todo) + N - 1) // N)
import os
print("avg KB", sum(os.path.getsize(out / f) for f in os.listdir(out) if f.endswith(".md")) / 1024 / max(1, (len(todo) + N - 1) // N))
