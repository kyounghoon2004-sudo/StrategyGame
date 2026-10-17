"""Export replaced Harness-Zero rows as cold prompts for an external agent (answer key kept separate)."""
import json, random, collections
from pathlib import Path
from tools.synth_adv_v1.hz_pipeline import HZ

rows = json.loads((HZ / "hz_rows.json").read_text(encoding="utf-8"))
rep = [r for r in rows if r["source"] == "hz_replaced"]
rng = random.Random(5)
by = collections.defaultdict(list)
for r in rep:
    by[r["game"].split("|")[0]].append(r)
pick = []
for k in by:
    rng.shuffle(by[k]); pick += by[k][:5]
rng.shuffle(pick)
out = Path("artifacts/brain_pipeline_v1/synth_adv_v1/hz"); key = []
md = ["# Cold prompts (RED commander, hex wargame)\n",
      "Each item is a full prompt exactly as the student model saw it. Answer each with ONE JSON object "
      "`{\"orders\": {...}, \"plan\": \"...\"}` and nothing else. Do not use tools or search files; answer from the prompt only.\n"]
for i, r in enumerate(pick, 1):
    md.append("\n---\n## ITEM %d\n" % i)
    for m in r["messages"]:
        md.append("### [%s]\n%s\n" % (m["role"], m["content"]))
    key.append({"item": i, "game": r["game"], "turn": r["turn"], "reference": r["completion"]})
(out / "cold_prompts_hz.md").write_text("\n".join(md), encoding="utf-8")
(out / "cold_prompts_hz_key.json").write_text(json.dumps(key, ensure_ascii=False, indent=1), encoding="utf-8")
print(len(pick), collections.Counter(k["game"].split("|")[0] for k in key))
