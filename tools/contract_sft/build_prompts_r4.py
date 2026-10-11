"""Round-4 train prompts (train_gen4): the single remaining CSFT3 failure family.

CSFT3 held-out residue = 3/96, all RED-side R_CAV_1 copies on rosters with NO
cavalry (the production system-prompt example's "reserve": ["R_CAV_1"]).
train_gen4 = 128 NEW no_cav scenarios (96 RED / 32 BLUE), seeds 7000+,
roster signatures disjoint from every existing prompt set incl. held-out and
the sealed OOD set (signatures only, read for exclusion).
"""
from __future__ import annotations

import json

from tools.contract_sft import harness as H
from tools.contract_sft import scenarios as S
from tools.contract_sft.build_prompts import OUT, pack


def max_suffix(s):
    units = s["red_forces"] if s["side"] == "red" else s["blue_forces"]
    return max(int(u["id"].rsplit("_", 1)[1]) for u in units)


def main() -> int:
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--round", type=int, default=4)
    ap.add_argument("--policy", default="CSFT3")
    a = ap.parse_args()
    rnd = a.round
    existing = []
    for n in ("train_gen", "train_gen2", "train_gen3", "heldout", "rl_A", "ood_hidden"):
        existing += json.loads((OUT / f"{n}.json").read_text(encoding="utf-8"))
    extra = [OUT.parent / "augment" / "remap_v1_prompts.json", OUT.parent / "dataset_csft3" / "r3_augment_prompts.json"]
    if rnd >= 5:
        extra += [OUT / "train_gen4.json", OUT.parent / "dataset_csft4" / "r4_augment_prompts.json"]
    for f in extra:
        existing += json.loads(f.read_text(encoding="utf-8"))
    # Round 4 banned every existing signature (over-strict: exhausted the
    # sequential no_cav space and pushed data to sparse numbering, which does
    # NOT trigger the CAV_1 lure). Round 5+ bans only evaluation rosters
    # (held-out, sealed OOD, rl_A); training-roster reuse with a new layout /
    # objective is a new, legitimate training scenario. Exact prompt text is
    # still never duplicated.
    eval_splits = ("heldout", "ood_hidden", "rl_A")
    banned = {p["roster_signature"] for p in existing if rnd == 4 or p.get("split") in eval_splits}
    shas = {p["sha256"] for p in existing}
    want = {"red": 96, "blue": 32}
    specs, seed0 = [], {4: 7000, 5: 9000}[rnd]
    seed = seed0
    mode = "no_cav_sparse" if rnd == 4 else "no_cav"
    # Sequential-numbered no_cav rosters are nearly exhausted by earlier rounds
    # (~144 per side); sparse numbering keeps the same trigger (no cavalry at
    # all) with a large roster space. Hard bound: fail loudly, never spin.
    while any(want.values()):
        if seed > seed0 + 200000:
            raise RuntimeError(f"roster space exhausted; still need {want}")
        s = S.generate_variant(seed, mode)
        seed += 1
        sig = S.roster_signature(s)
        if sig in banned or want[s["side"]] == 0 or (rnd >= 5 and max_suffix(s) > 3):
            continue
        if rnd == 4:
            banned.add(sig)
        want[s["side"]] -= 1
        specs.append(dict(s, scenario_id=s["scenario_id"].replace("csft3_", f"csft{rnd}_")))
    rows = [dict(pack(p, s, f"train_gen{rnd}"), family=mode) for p, s in zip(H.build_prompts(specs), specs)]
    assert all("error" not in r for r in rows) and not ({r["sha256"] for r in rows} & shas)
    (OUT / f"train_gen{rnd}.json").write_text(json.dumps(rows, ensure_ascii=False), encoding="utf-8")
    jobs = [{"job_id": f"tg{rnd}_" + r["prompt_id"], "prompt_id": r["prompt_id"], "messages": r["messages"],
             "seed": seed0 + i // 8} for i, r in enumerate(rows)]
    (OUT / f"jobs_train_gen{rnd}_{a.policy}.json").write_text(json.dumps(jobs, ensure_ascii=False), encoding="utf-8")
    print(len(rows), {"RED": sum(r["side"] == "RED" for r in rows), "BLUE": sum(r["side"] == "BLUE" for r in rows)})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
