"""CPU-only curation of Harness-Zero correction rows (runs after hz_pipeline build; no GPU).
 1. plan <-> orders consistency: a RED unit named in the plan must have an order in the label, else the plan is dropped
 2. diversity: at most CAP correction rows per game (evenly spread over its turns)
 3. report HOLD-ifications for manual spot check
Output: hz_rows_clean.json (curated corrections + all pass rows)"""
import json, re, collections
from tools.synth_adv_v1.hz_pipeline import HZ

CAP = 12
RID = re.compile(r"\bR_[A-Z]{2,3}_\d+\b")
rows = json.loads((HZ / "hz_rows.json").read_text(encoding="utf-8"))
passes = [r for r in rows if r["source"] == "hz_pass_code_ok"]
corr = [r for r in rows if r["source"].startswith("hz_replaced")]
st = collections.Counter()
for r in corr:
    lab = json.loads(r["completion"])
    plan = lab.get("plan")
    if plan:
        named = set(RID.findall(plan))
        if named - set(lab["orders"]):
            st["plan_dropped_inconsistent"] += 1
            lab.pop("plan")
            r["completion"] = json.dumps(lab, ensure_ascii=False)
    r["_hold"] = any(o.get("do") == "HOLD" for o in lab["orders"].values())
by = collections.defaultdict(list)
for r in corr:
    by[r["game"]].append(r)
kept = []
for g, v in by.items():
    v.sort(key=lambda r: r["turn"])
    if len(v) > CAP:
        step = len(v) / CAP
        v = [v[int(i * step)] for i in range(CAP)]
        st["capped_games"] += 1
    kept += v
st["corr_in"] = len(corr); st["corr_kept"] = len(kept)
st["kept_with_hold"] = sum(r["_hold"] for r in kept)
for r in kept:
    r.pop("_hold", None)
out = passes + kept
(HZ / "hz_rows_clean.json").write_text(json.dumps(out, ensure_ascii=False), encoding="utf-8")
print(dict(st), "| games", len(by), "| by source", dict(collections.Counter(r["game"].split("|")[0] for r in kept)))
# spot-check list: HOLD cases
hold = [r for r in kept if "HOLD" in r["completion"]][:6]
for r in hold:
    print(r["game"], "T", r["turn"], r["completion"][:260])
