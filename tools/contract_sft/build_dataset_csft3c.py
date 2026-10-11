"""CSFT3c: CSFT3 rows passed through the strict-schema hygiene gate.

  python -m tools.contract_sft.build_dataset_csft3c

Every row of dataset_csft3 (all sources, incl. preserved CSFT2 rows):
  - schema_strict.audit clean            -> kept verbatim
  - otherwise schema_strict.hoist (misplaced keys moved where evidently
    intended; conflicts dropped) -> must then pass ALL gates again:
    strict schema clean, real Godot production strict first-pass, exactly one
    JSON object, coherence P1-P11, whole-text friendly authorization,
    enemy ids visible or enemy HQ_1, <= 1100 tokens      -> kept (hoisted)
  - anything failing                     -> excluded (reported with codes)
Remap rows are hoisted independently (same deterministic transform).
Writes dataset_csft3c/{sft_rows.jsonl, DATASET_MANIFEST.json, exclusions.json}.
"""
from __future__ import annotations

import collections
import hashlib
import json
from pathlib import Path

from tools.contract_sft import schema_strict as SS
from tools.contract_sft.build_dataset_csft3 import gate

ROOT = Path(r"D:\Game development\Demon slayer\StrategyGame\artifacts\contract_sft_v1")
VERSION = "CONTRACT_SFT_V1_DATASET_CSFT3C"


def main() -> int:
    from transformers import AutoTokenizer
    tok = AutoTokenizer.from_pretrained(r"D:\StrategyAI\models\Qwen3-8B")
    P = {}
    files = [ROOT / "prompts" / f"{n}.json" for n in ("train_gen", "train_gen3", "rl_A")] + \
        [ROOT / "augment" / "remap_v1_prompts.json", ROOT / "dataset_csft3" / "r3_augment_prompts.json"]
    for f in files:
        for p in json.loads(f.read_text(encoding="utf-8")):
            P[p["prompt_id"]] = p
    rows = [json.loads(l) for l in open(ROOT / "dataset_csft3" / "sft_rows.jsonl", encoding="utf-8")]
    kept, fixes, excl = [], [], []
    for r in rows:
        doc = json.loads(r["target"])
        if not SS.audit(doc):
            kept.append(dict(r, schema="CLEAN"))
            continue
        nd, notes = SS.hoist(doc)
        left = SS.audit(nd)
        if left:
            excl.append({"row_id": r["row_id"], "source": r["source"], "codes": left[:6]})
            continue
        t = json.dumps(nd, ensure_ascii=False, separators=(",", ":"))
        fixes.append((r, t, notes))
    res = gate([{"id": r["row_id"], "text": t, "prompt_id": r["prompt_id"]} for r, t, _ in fixes], P, tok)
    for (r, t, notes), (codes, v) in zip(fixes, res):
        if codes:
            excl.append({"row_id": r["row_id"], "source": r["source"], "codes": codes})
        else:
            kept.append(dict(r, target=t, target_sha256=hashlib.sha256(t.encode("utf-8")).hexdigest(),
                             schema="HOISTED", hoist_notes=notes))
    out = ROOT / "dataset_csft3c"
    out.mkdir(exist_ok=True)
    with open(out / "sft_rows.jsonl", "w", encoding="utf-8") as f:
        for r in kept:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    (out / "exclusions.json").write_text(json.dumps(excl, indent=1), encoding="utf-8")
    src = collections.Counter(r["source"] for r in rows)
    ksrc = collections.Counter(r["source"] for r in kept)
    man = {"version": VERSION, "input": "dataset_csft3/sft_rows.jsonl",
           "input_sha256": hashlib.sha256((ROOT / "dataset_csft3" / "sft_rows.jsonl").read_bytes()).hexdigest(),
           "rows_in": len(rows), "rows_kept": len(kept),
           "train_rows": sum(1 for r in kept if r["split"] == "train"),
           "dev_rows": sum(1 for r in kept if r["split"] == "dev"),
           "kept_clean": sum(1 for r in kept if r["schema"] == "CLEAN"),
           "kept_hoisted_and_regated": sum(1 for r in kept if r["schema"] == "HOISTED"),
           "excluded": len(excl),
           "excluded_code_counts": dict(collections.Counter(c.split(":")[0] + ":" + c.split(":")[1]
                                                            if c.count(":") else c
                                                            for e in excl for c in e["codes"]).most_common(12)),
           "by_source_kept_of_in": {s: f"{ksrc[s]}/{src[s]}" for s in src},
           "all_rows_schema_strict_clean": all(not SS.audit(json.loads(r["target"])) for r in kept),
           "HQ_DESTROYED_tokens_in_targets": sum("HQ_DESTROYED" in r["target"] for r in kept),
           "sft_rows_sha256": hashlib.sha256((out / "sft_rows.jsonl").read_bytes()).hexdigest()}
    (out / "DATASET_MANIFEST.json").write_text(json.dumps(man, indent=1), encoding="utf-8")
    print(json.dumps(man, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
