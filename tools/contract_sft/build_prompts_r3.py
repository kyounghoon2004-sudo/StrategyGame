"""Round-3 prompt sets: sealed OOD hidden eval + targeted train_gen3.

  ood_hidden  48 prompts (24 RED / 24 BLUE), seeds 90000+, families
              big (only here: 11-15 formations, sparse ids) / no_cav / thin /
              sparse. SEALED: no training builder may read it (they assert);
              evaluated once, at the end, for confirmation.
  train_gen3  256 prompts, seeds 5000+, weighted to the CSFT2 failure types:
              no_cav 35% (CAV_1 lure has no referent), no_inf2 20%, thin 15%,
              sparse 15%, base 15%.
Roster signatures are disjoint from every existing prompt set and from each
other; no duplicate prompt text anywhere.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

from tools.contract_sft import harness as H
from tools.contract_sft import scenarios as S
from tools.contract_sft.build_prompts import OUT, pack

AUG = OUT.parent / "augment" / "remap_v1_prompts.json"
TRAIN_MIX = [("no_cav", 90), ("no_inf2", 51), ("thin", 38), ("sparse", 38), ("base", 39)]
OOD_MIX = [("big", 16), ("no_cav", 12), ("thin", 10), ("sparse", 10)]


def spec(seed, fam):
    s = S.generate(seed) if fam == "base" else S.generate_variant(seed, fam)
    if fam == "base":
        s = dict(s, scenario_id=f"csft3_base_s{seed:05d}", family="base")
    return s


def draw(mix, seed0, banned, balance_sides=True):
    out, seed = [], seed0
    for fam, n in mix:
        got = {"red": 0, "blue": 0}
        while sum(got.values()) < n:
            s = spec(seed, fam)
            seed += 1
            sig = S.roster_signature(s)
            if sig in banned or (balance_sides and got[s["side"]] >= (n + 1) // 2):
                continue
            banned.add(sig)
            got[s["side"]] += 1
            out.append(s)
    return out


def main() -> int:
    existing = []
    for n in ("train_gen", "train_gen2", "heldout", "rl_A"):
        existing += json.loads((OUT / f"{n}.json").read_text(encoding="utf-8"))
    existing += json.loads(AUG.read_text(encoding="utf-8"))
    banned = {p["roster_signature"] for p in existing}
    shas = {p["sha256"] for p in existing}
    ood_specs = draw(OOD_MIX, 90000, banned)
    tr_specs = draw(TRAIN_MIX, 5000, banned)
    ood = [dict(pack(p, s, "ood_hidden"), family=s["family"]) for p, s in zip(H.build_prompts(ood_specs), ood_specs)]
    tr = [dict(pack(p, s, "train_gen3"), family=s["family"]) for p, s in zip(H.build_prompts(tr_specs), tr_specs)]
    assert all("error" not in x for x in ood + tr)
    allsha = [x["sha256"] for x in ood + tr]
    assert len(set(allsha)) == len(allsha) and not (set(allsha) & shas)
    (OUT / "ood_hidden.json").write_text(json.dumps(ood, ensure_ascii=False), encoding="utf-8")
    (OUT / "train_gen3.json").write_text(json.dumps(tr, ensure_ascii=False), encoding="utf-8")
    seal = {"ood_hidden_sha256": hashlib.sha256((OUT / "ood_hidden.json").read_bytes()).hexdigest(),
            "n": len(ood), "families": {f: n for f, n in OOD_MIX},
            "sides": {"RED": sum(1 for x in ood if x["side"] == "RED"), "BLUE": sum(1 for x in ood if x["side"] == "BLUE")},
            "with_enemy_contact": sum(1 for x in ood if x["n_known_enemies"] > 0),
            "rule": "never read by any training/data builder; evaluated once for final confirmation"}
    (OUT / "OOD_HIDDEN_SEAL.json").write_text(json.dumps(seal, indent=1), encoding="utf-8")
    jobs = [{"job_id": "tg3_" + r["prompt_id"], "prompt_id": r["prompt_id"], "messages": r["messages"],
             "seed": 5000 + i // 8} for i, r in enumerate(tr)]
    (OUT / "jobs_train_gen3_CSFT2.json").write_text(json.dumps(jobs, ensure_ascii=False), encoding="utf-8")
    print(json.dumps(seal), "train_gen3", len(tr), {f: n for f, n in TRAIN_MIX})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
