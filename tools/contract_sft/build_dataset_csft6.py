"""CSFT6 dataset = dataset_csft5 with the CSFT5-package prose template
downsampled (no target edits; rows dropped deterministically) + round-5
sequential no-cavalry rows (dataset_r5seq: R5_SELF_* + R5_REMAP).

Why: CSFT5 memorized the package template "Pressure confirmed cavalry contact
<ID> in <REGION> ..." (284/446 admitted rows) and wrote it with a non-existent
own-side id in 2 passing held-out outputs; the remaining hard failure is the
RED sequential-numbered no-cavalry R_CAV_1 lure, which round-5 targets.

  python -m tools.contract_sft.build_dataset_csft6
"""
from __future__ import annotations

import collections
import hashlib
import json
import random
from pathlib import Path

from tools.contract_sft import schema_strict as SS

ROOT = Path(r"D:\Game development\Demon slayer\StrategyGame\artifacts\contract_sft_v1")
TEMPLATE = "Pressure confirmed cavalry contact"
TEMPLATE_CAP = 60


def main() -> int:
    base = [json.loads(l) for l in open(ROOT / "dataset_csft5" / "sft_rows.jsonl", encoding="utf-8")]
    r5 = [json.loads(l) for l in open(ROOT / "dataset_r5seq" / "sft_rows.jsonl", encoding="utf-8")]
    r5 = [r for r in r5 if r["source"].startswith("R5_")]
    tmpl = sorted([r for r in base if TEMPLATE in r["target"]], key=lambda r: r["row_id"])
    random.Random(20260927).shuffle(tmpl)
    keep_t = {r["row_id"] for r in tmpl[:TEMPLATE_CAP]}
    kept = [r for r in base if TEMPLATE not in r["target"] or r["row_id"] in keep_t]
    rows = kept + r5
    assert all(not SS.audit(json.loads(r["target"])) for r in rows)
    out = ROOT / "dataset_csft6"
    out.mkdir(exist_ok=True)
    with open(out / "sft_rows.jsonl", "w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    man = {"version": "CONTRACT_SFT_V1_DATASET_CSFT6",
           "base": "dataset_csft5",
           "base_sha256": hashlib.sha256((ROOT / "dataset_csft5" / "sft_rows.jsonl").read_bytes()).hexdigest(),
           "template_rows_in_base": len(tmpl), "template_rows_kept": TEMPLATE_CAP,
           "template_rows_dropped": len(tmpl) - TEMPLATE_CAP,
           "template_share_after": round(sum(TEMPLATE in r["target"] for r in rows) / len(rows), 4),
           "r5seq_rows_added": len(r5), "r5seq_by_source": dict(collections.Counter(r["source"] for r in r5)),
           "r5seq_sha256": hashlib.sha256((ROOT / "dataset_r5seq" / "sft_rows.jsonl").read_bytes()).hexdigest(),
           "rows": len(rows), "train_rows": sum(r["split"] == "train" for r in rows),
           "dev_rows": sum(r["split"] == "dev" for r in rows),
           "by_source": dict(collections.Counter(r["source"] for r in rows)),
           "sft_rows_sha256": hashlib.sha256((out / "sft_rows.jsonl").read_bytes()).hexdigest()}
    (out / "DATASET_MANIFEST.json").write_text(json.dumps(man, indent=1), encoding="utf-8")
    print(json.dumps(man, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
