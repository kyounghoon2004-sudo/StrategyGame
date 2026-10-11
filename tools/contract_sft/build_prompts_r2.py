"""Round-2 train prompts (train_gen2) for CONTRACT_SFT_V1.

Targets the dominant round-1 held-out failure: VA_UNKNOWN_UNIT from copying
the production system prompt's example ids ("reserve": ["R_CAV_1"],
"CenterFix": ["R_INF_1","R_INF_2"]) into rosters that lack them. 128 new
scenarios (seeds 1000..), ~75% of them rosters missing R_CAV_1/B_CAV_1 or
the *_INF_2 unit. Roster signatures stay disjoint from held-out and rl_A;
no prompt duplicates any existing prompt. R1 prompt files are untouched.
"""
from __future__ import annotations

import json
from pathlib import Path

from tools.contract_sft import harness as H
from tools.contract_sft import scenarios as S
from tools.contract_sft.build_prompts import OUT, pack

N = 128


def lacks_example_ids(spec) -> bool:
    ids = {u["id"][2:] for u in (spec["red_forces"] if spec["side"] == "red" else spec["blue_forces"])}
    return "CAV_1" not in ids or "INF_2" not in ids


def main() -> int:
    existing = []
    for name in ("train_gen", "heldout", "rl_A"):
        existing += json.loads((OUT / f"{name}.json").read_text(encoding="utf-8"))
    banned_sig = {p["roster_signature"] for p in existing if p["split"] in ("heldout", "rl_A")}
    seen_sha = {p["sha256"] for p in existing}
    lack, other = [], []
    for k in range(1000, 4000):
        s = S.generate(k)
        if S.roster_signature(s) in banned_sig:
            continue
        (lack if lacks_example_ids(s) else other).append(s)
        if len(lack) >= 96 and len(other) >= 32:
            break
    specs = lack[:96] + other[:32]
    rows = [pack(p, s, "train_gen2") for p, s in zip(H.build_prompts(specs), specs)]
    assert all(r["sha256"] not in seen_sha for r in rows)
    assert all(r["roster_signature"] not in banned_sig for r in rows)
    (OUT / "train_gen2.json").write_text(json.dumps(rows, ensure_ascii=False), encoding="utf-8")
    man = json.loads((OUT / "PROMPTS_MANIFEST.json").read_text(encoding="utf-8"))
    man["counts"]["train_gen2"] = len(rows)
    man["train_gen2"] = {"lacking_example_ids": sum(1 for s in specs if lacks_example_ids(s)),
                         "sides": {"RED": sum(1 for r in rows if r["side"] == "RED"),
                                   "BLUE": sum(1 for r in rows if r["side"] == "BLUE")},
                         "heldout_or_rlA_roster_overlap": 0, "duplicate_prompts": 0}
    man["sha256"].update({r["prompt_id"]: r["sha256"] for r in rows})
    (OUT / "PROMPTS_MANIFEST.json").write_text(json.dumps(man, indent=1), encoding="utf-8")
    jobs = [{"job_id": "tg2_" + r["prompt_id"], "prompt_id": r["prompt_id"], "messages": r["messages"],
             "seed": 3000 + i // 8} for i, r in enumerate(rows)]
    (OUT / "jobs_train_gen2_CSFT1.json").write_text(json.dumps(jobs, ensure_ascii=False), encoding="utf-8")
    print(json.dumps(man["train_gen2"]), len(jobs))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
