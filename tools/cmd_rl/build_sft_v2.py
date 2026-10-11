"""SFT set v2 (2026-10-06): the cloud's answers (plan / notes / expect / orders, no thinking) from the commander games
it WON in the current packet format (cmd_collect v3 / v4_fort / v6_fewerloss, deepseek-v4.1-flash). Passed calls
("skipped") are left out. Output rows: {"messages", "completion", "game", "tier", "turn", "run"}.

  python -m tools.cmd_rl.build_sft_v2 [--runs cmd_collect_v3,cmd_collect_v4_fort,cmd_collect_v6_fewerloss]
"""
from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path

from tools.plan_search.cloud_brain import extract_orders

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "artifacts" / "brain_pipeline_v1"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", default="cmd_collect_v3,cmd_collect_v4_fort,cmd_collect_v6_fewerloss")
    ap.add_argument("--out", default=str(SRC / "cmd_sft" / "sft_v2.json"))
    a = ap.parse_args()
    rows, per = [], Counter()
    for run in a.runs.split(","):
        won = {}
        for line in (SRC / run / "results.jsonl").read_text(encoding="utf-8").splitlines():
            r = json.loads(line)
            if r.get("kind") == "WIN":
                won[r["game"]] = r["tier"]
        for line in (SRC / run / "raw" / "calls.jsonl").read_text(encoding="utf-8").splitlines():
            c = json.loads(line)
            if c.get("request") != "VICTORY_COMMAND" or c.get("tag") not in won or not c.get("raw"):
                continue
            if (c.get("cloud") or {}).get("skipped"):
                continue
            doc = extract_orders(c["raw"])
            if doc is None:
                continue
            doc.pop("skipped", None)
            rows.append({"messages": c["messages"], "completion": json.dumps(doc, ensure_ascii=False),
                         "game": c["tag"], "tier": won[c["tag"]], "turn": c.get("turn"), "run": run})
            per[(run, won[c["tag"]])] += 1
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_text(json.dumps(rows, ensure_ascii=False), encoding="utf-8")
    print("rows", len(rows), dict(per), "games", len({r["game"] + r["run"] for r in rows}))


if __name__ == "__main__":
    main()
