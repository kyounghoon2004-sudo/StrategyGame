"""Harness-Zero round-1 SFT set: corrections x2 + sampled student-pass rows + regular HQ rows (rule understanding). Plain prompt, no FACTS."""
import collections, json, random
from pathlib import Path
from tools.synth_adv_v1.hz_pipeline import HZ

ROOT = Path(__file__).resolve().parents[2]
rng = random.Random(7)
rows = json.loads((HZ / "hz_rows.json").read_text(encoding="utf-8"))
corr = [r for r in rows if r["source"].startswith("hz_replaced")]
pas = [r for r in rows if r["source"] == "hz_pass_code_ok"]
# keep pass rows with non-empty orders mostly (the student already over-produces empties); balance by mission source
by = collections.defaultdict(list)
for r in pas:
    by[r["game"].split("|")[0]].append(r)
pas_pick = []
for k, v in by.items():
    ne = [r for r in v if json.loads(r["completion"]).get("orders")]
    rng.shuffle(ne)
    pas_pick += ne[:100]
reg = json.loads((ROOT / "artifacts/brain_pipeline_v1/sft_mix_v3b/data.json").read_text(encoding="utf-8"))
hq = [r for r in reg if r.get("mission") == "hq"]
rng.shuffle(hq)
hq = hq[:250]
out = [{"messages": r["messages"], "completion": r["completion"], "mission": "hq", "source": r["source"]} for r in corr for _ in range(2)]
out += [{"messages": r["messages"], "completion": r["completion"], "mission": "hq", "source": r["source"]} for r in pas_pick]
out += [{"messages": r["messages"], "completion": r["completion"], "mission": r.get("mission"), "source": "regular_hq"} for r in hq]
rng.shuffle(out)
d = ROOT / "artifacts/brain_pipeline_v1/hz_sft_r1"; d.mkdir(parents=True, exist_ok=True)
(d / "data.json").write_text(json.dumps(out, ensure_ascii=False), encoding="utf-8")
print(len(out), dict(collections.Counter(r["source"] for r in out)))
