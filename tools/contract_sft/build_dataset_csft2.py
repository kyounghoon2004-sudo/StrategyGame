"""CSFT2 dataset assembly (no new generation, no repair).

  python -m tools.contract_sft.build_dataset_csft2

Sources (all previously admitted, production-valid):
  R1      dataset/sft_rows.jsonl MINUS the contaminated rows (own-side unit ids
          outside the packet roster in fields production ignores, e.g.
          prefer.units / misplaced reserve) -- detected, not hand-listed
  B03R1   intake/B03R1_intake_v1.jsonl (160, admitted by the intake gate)
  REMAP   augment/remap_v1_rows.jsonl (accepted rows only; rejected rows were
          never written)
Excluded: the 24 paused Round-2 samples (gen/train_gen2_CSFT1.json).
Split: R1 dev rows stay dev; remap copies of dev rows go to dev; everything
else is train. Every row is re-checked: exactly one JSON object, friendly ids
in roster, prompt not held-out, roster signature not held-out.
Writes dataset_csft2/{sft_rows.jsonl,DATASET_MANIFEST.json}.
"""
from __future__ import annotations

import collections
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(r"D:\Game development\Demon slayer\StrategyGame\artifacts\contract_sft_v1")
UID = re.compile(r"\b[RB]_[A-Z]{2,3}_\d+\b")
VERSION = "CONTRACT_SFT_V1_DATASET_CSFT2"


def sha(t: str) -> str:
    return hashlib.sha256(t.encode("utf-8")).hexdigest()


def main() -> int:
    P = {}
    for n in ("train_gen", "rl_A", "heldout"):
        for p in json.loads((ROOT / "prompts" / f"{n}.json").read_text(encoding="utf-8")):
            P[p["prompt_id"]] = p
    for p in json.loads((ROOT / "augment" / "remap_v1_prompts.json").read_text(encoding="utf-8")):
        P[p["prompt_id"]] = p
    held_ids = {k for k, p in P.items() if p["split"] == "heldout"}
    held_sigs = {P[k]["roster_signature"] for k in held_ids}

    def roster(pid):
        return {u["unit_id"] for u in json.loads(P[pid]["messages"][1]["content"])["compact_state"]["friendly_units"]}

    def contaminated(pid, target):
        own = P[pid]["side"][0]
        r = roster(pid)
        return sorted(u for u in set(UID.findall(target)) if u[0] == own and u not in r)

    rows, excluded = [], []
    for l in open(ROOT / "dataset" / "sft_rows.jsonl", encoding="utf-8"):
        r = json.loads(l)
        bad = contaminated(r["prompt_id"], r["target"])
        if bad:
            excluded.append({"row_id": r["row_id"], "reason": "CONTAMINATED_OUT_OF_ROSTER_IDS", "ids": bad})
            continue
        rows.append({"row_id": "R1:" + r["row_id"], "source": "R1", "split": r["split"],
                     "prompt_id": r["prompt_id"], "target": r["target"]})
    for l in open(ROOT / "intake" / "B03R1_intake_v1.jsonl", encoding="utf-8"):
        r = json.loads(l)
        pv = r["provenance"]
        rows.append({"row_id": f"B03R1:{pv['scenario_id']}_{pv['variant_id']}", "source": "B03R1",
                     "split": "train", "prompt_id": r["prompt_id"], "target": r["target"]})
    excluded_src = {"R1:" + e["row_id"] for e in excluded}
    for l in open(ROOT / "augment" / "remap_v1_rows.jsonl", encoding="utf-8"):
        r = json.loads(l)
        if r["src_id"] in excluded_src:  # defensive: remap of a contaminated source
            excluded.append({"row_id": r["row_id"], "reason": "REMAP_OF_CONTAMINATED_SOURCE"})
            continue
        rows.append({"row_id": r["row_id"], "source": "REMAP", "split": "dev" if r["src_split"] == "dev" else "train",
                     "prompt_id": r["prompt_id"], "target": r["target"], "src_id": r["src_id"]})
    for r in rows:  # re-check invariants on every row
        json.loads(r["target"])
        assert r["prompt_id"] in P and r["prompt_id"] not in held_ids, r["row_id"]
        assert P[r["prompt_id"]]["roster_signature"] not in held_sigs, r["row_id"]
        assert not contaminated(r["prompt_id"], r["target"]), r["row_id"]
        r["target_sha256"] = sha(r["target"])
    out = ROOT / "dataset_csft2"
    out.mkdir(exist_ok=True)
    with open(out / "sft_rows.jsonl", "w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    tr = [r for r in rows if r["split"] == "train"]

    def lacks(pid):
        tags = {u[2:] for u in roster(pid)}
        return "CAV_1" not in tags or "INF_2" not in tags
    man = {"version": VERSION, "rows": len(rows), "train_rows": len(tr), "dev_rows": len(rows) - len(tr),
           "by_source_split": {f"{s}/{sp}": n for (s, sp), n in
                               collections.Counter((r["source"], r["split"]) for r in rows).items()},
           "excluded": excluded, "excluded_paused_r2_samples": 24,
           "train_rows_on_rosters_lacking_CAV_1_or_INF_2": sum(1 for r in tr if lacks(r["prompt_id"])),
           "train_share_lacking": round(sum(1 for r in tr if lacks(r["prompt_id"])) / len(tr), 4),
           "distinct_train_prompts": len({r["prompt_id"] for r in tr}),
           "heldout_prompt_or_roster_in_rows": 0,
           "sft_rows_sha256": hashlib.sha256((out / "sft_rows.jsonl").read_bytes()).hexdigest()}
    (out / "DATASET_MANIFEST.json").write_text(json.dumps(man, indent=1), encoding="utf-8")
    print(json.dumps({k: v for k, v in man.items() if k != "excluded"}, indent=1),
          "\nexcluded:", [(e["row_id"], e["reason"]) for e in excluded])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
