"""Plan loop (2026-10-09), HQ mission: the bank of RL v8 games the 9B played, to branch from (tools/synth_sft_v2/branch.py
--mode hq --bank <this bank>). Same entry format as the synthetic SFT bank; army_size None = the default roster.

  python -m tools.plan_loop.bank_hq [--stage INTER]   -> artifacts/brain_pipeline_v1/plan_loop_v1/bank_hq.json
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from tools.synth_sft_v2.bank import overlay_of

ROOT = Path(__file__).resolve().parents[2]
RL = ROOT / "artifacts" / "brain_pipeline_v1" / "cmd_rl_v8"
OUT = ROOT / "artifacts" / "brain_pipeline_v1" / "plan_loop_v1"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stage", default="INTER")
    a = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    bank = {}
    for line in (RL / "games.jsonl").read_text(encoding="utf-8").splitlines():
        r = json.loads(line)
        if r.get("stage") != a.stage or r.get("error") or r.get("kind") in ("INVALID", "ERROR"):
            continue
        it = RL / "iterations" / ("it%04d" % int(r["iteration"]))
        gf = it / "games" / ("%s.json" % r["tag"])
        if not gf.exists():
            continue
        bank[r["tag"]] = {"game": r["tag"], "seed": int(r["seed"]), "tier": r["stage"], "style": r["style"],
                          "family": r["family"], "army_size": None, "game_file": str(gf), "overlay": overlay_of(gf),
                          "outcome": r.get("outcome"), "kind": r.get("kind"), "turn": r.get("turn"), "units": r.get("units"),
                          "hq": r.get("hq"), "adapter": r.get("adapter"), "iteration": r["iteration"], "answers": {}}
    for tag, g in bank.items():
        for line in (RL / "iterations" / ("it%04d" % g["iteration"]) / "captures" / "calls.jsonl").read_text(encoding="utf-8").splitlines():
            try:
                c = json.loads(line)
            except ValueError:
                continue
            if c.get("tag") == tag and c.get("request") == "VICTORY_COMMAND":
                g["answers"][str(c.get("turn"))] = c.get("raw") or '{"orders": {}}'  # the last answer of a turn counts
    (OUT / "bank_hq.json").write_text(json.dumps(bank, indent=1), encoding="utf-8")
    kinds = {}
    for g in bank.values():
        kinds[g["kind"]] = kinds.get(g["kind"], 0) + 1
    print("%s games %d %s, with overlay %d" % (a.stage, len(bank), kinds, sum(1 for g in bank.values() if g["overlay"])))


if __name__ == "__main__":
    main()
