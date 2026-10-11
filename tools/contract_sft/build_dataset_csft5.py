"""CSFT5 dataset = dataset_csft4 (preserved unchanged) + canonically admitted
CSFT5 adversarial rows (intake/CSFT5_admission_v2.jsonl; production-rebuilt
prompts prompts/csft5_train_rebuilt_v2.json). The paused round-5 sequential
no-cav samples (gen/train_gen5_CSFT4.json) are NOT included.

  python -m tools.contract_sft.build_dataset_csft5
"""
from __future__ import annotations

import collections
import hashlib
import json
from pathlib import Path

from tools.contract_sft import schema_strict as SS

ROOT = Path(r"D:\Game development\Demon slayer\StrategyGame\artifacts\contract_sft_v1")


def main() -> int:
    base = [json.loads(l) for l in open(ROOT / "dataset_csft4" / "sft_rows.jsonl", encoding="utf-8")]
    adv = [json.loads(l) for l in open(ROOT / "intake" / "CSFT5_admission_v2.jsonl", encoding="utf-8")]
    P = {p["prompt_id"]: p for p in json.loads((ROOT / "prompts" / "csft5_train_rebuilt_v2.json").read_text(encoding="utf-8"))}
    chal = json.loads((ROOT / "prompts" / "csft5_challenge_v2.json").read_text(encoding="utf-8"))
    held = json.loads((ROOT / "prompts" / "heldout.json").read_text(encoding="utf-8"))
    csha = {p["sha256"] for p in chal}
    bad_sigs = {p["roster_signature"] for p in held}
    for r in adv:
        assert r["prompt_id"] in P and P[r["prompt_id"]]["sha256"] not in csha
        assert P[r["prompt_id"]]["roster_signature"] not in bad_sigs
        assert not SS.audit(json.loads(r["target"]))
    rows = base + adv
    out = ROOT / "dataset_csft5"
    out.mkdir(exist_ok=True)
    with open(out / "sft_rows.jsonl", "w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    man = {"version": "CONTRACT_SFT_V1_DATASET_CSFT5", "base": "dataset_csft4",
           "base_sha256": hashlib.sha256((ROOT / "dataset_csft4" / "sft_rows.jsonl").read_bytes()).hexdigest(),
           "base_rows_preserved": len(base),
           "csft5_admission": "intake/CSFT5_admission_v2.jsonl",
           "csft5_admission_sha256": hashlib.sha256((ROOT / "intake" / "CSFT5_admission_v2.jsonl").read_bytes()).hexdigest(),
           "csft5_rows": len(adv), "csft5_by_family": dict(collections.Counter(r["family"] for r in adv)),
           "rows": len(rows), "train_rows": sum(r["split"] == "train" for r in rows),
           "dev_rows": sum(r["split"] == "dev" for r in rows),
           "excluded": {"paused_round5_sequential_samples": "gen/train_gen5_CSFT4.json (120 rows, not admitted)",
                        "csft5_challenge": "sealed (prompt hash + roster checked)"},
           "sft_rows_sha256": hashlib.sha256((out / "sft_rows.jsonl").read_bytes()).hexdigest()}
    (out / "DATASET_MANIFEST.json").write_text(json.dumps(man, indent=1), encoding="utf-8")
    print(json.dumps(man, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
