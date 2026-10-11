"""STEP 1 distillation set (2026-10-05): every commander call of the games the cloud model WON.

Sources: plan_search/cmd_ladder_v1, cmd_ladder_v2, cmd_cycle_v1 (cloud commander, deepseek-v4.1-flash). The raw
cloud reply is the target (orders JSON; the cloud's reasoning was not captured). Output rows:
{"messages": [...], "completion": "<orders json>", "game", "stage", "turn"}.

  python -m tools.cmd_rl.build_sft [--out artifacts/brain_pipeline_v1/cmd_sft/sft_v1.json]
"""
from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path

from tools.plan_search.cloud_brain import extract_orders

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "artifacts" / "brain_pipeline_v1" / "plan_search"
RUNS = ["cmd_ladder_v1", "cmd_ladder_v2", "cmd_cycle_v1"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(ROOT / "artifacts" / "brain_pipeline_v1" / "cmd_sft" / "sft_v1.json"))
    a = ap.parse_args()
    rows, per_stage = [], Counter()
    for run in RUNS:
        won = {r["game"]: r["stage"] for r in map(json.loads, (SRC / run / "results.jsonl").read_text(encoding="utf-8").splitlines())
               if r.get("win")}
        for line in (SRC / run / "raw" / "calls.jsonl").read_text(encoding="utf-8").splitlines():
            c = json.loads(line)
            if c.get("request") != "VICTORY_COMMAND" or c.get("tag") not in won or not c.get("raw"):
                continue
            doc = extract_orders(c["raw"])
            if doc is None:
                continue
            rows.append({"messages": c["messages"], "completion": json.dumps(doc, ensure_ascii=False),
                         "game": c["tag"], "stage": won[c["tag"]], "turn": c.get("turn"), "run": run})
            per_stage[won[c["tag"]]] += 1
    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(rows, ensure_ascii=False), encoding="utf-8")
    print("rows", len(rows), "games", len({r["game"] for r in rows}), dict(per_stage), "->", out)


if __name__ == "__main__":
    main()
