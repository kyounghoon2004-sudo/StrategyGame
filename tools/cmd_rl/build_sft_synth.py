"""Synthetic SFT set (2026-10-07): the synthetic commander's decisions (tools/plan_search/synth_commander.py) from the
games it WON, in the format of sft_v2 / sft_v3_think: {"messages", "completion", "game", "tier", "turn", "run"}.
The answer carries the commander's fact-grounded thinking in "think"; --think puts it before the answer as
"<thinking>\n</think>\n\n{answer}" (the sft --think layout), otherwise the answer alone.

  python -m tools.cmd_rl.build_sft_synth --runs cmd_collect_synth_sft1 [--think] [--tiers BASIC,INTER] --out <file>
"""
from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "artifacts" / "brain_pipeline_v1"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", default="cmd_collect_synth_sft1")
    ap.add_argument("--tiers", default="BASIC,INTER")
    ap.add_argument("--think", action="store_true")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    tiers = set(a.tiers.split(","))
    rows, per, games = [], Counter(), set()
    for run in a.runs.split(","):
        won = {}
        for line in (SRC / run / "results.jsonl").read_text(encoding="utf-8").splitlines():
            r = json.loads(line)
            if r.get("kind") == "WIN" and r.get("tier") in tiers:
                won[r["game"]] = r["tier"]
        for line in (SRC / run / "raw" / "calls.jsonl").read_text(encoding="utf-8").splitlines():
            c = json.loads(line)
            if c.get("request") != "VICTORY_COMMAND" or c.get("tag") not in won or not c.get("raw"):
                continue
            doc = json.loads(c["raw"])
            think = doc.pop("think", "")
            answer = json.dumps(doc, ensure_ascii=False)
            rows.append({"messages": c["messages"],
                         "completion": (think + "\n</think>\n\n" + answer) if a.think else answer,
                         "game": c["tag"], "tier": won[c["tag"]], "turn": c.get("turn"), "run": run})
            per[won[c["tag"]]] += 1
            games.add((run, c["tag"]))
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_text(json.dumps(rows, ensure_ascii=False), encoding="utf-8")
    print("rows", len(rows), dict(per), "games", len(games))


if __name__ == "__main__":
    main()
