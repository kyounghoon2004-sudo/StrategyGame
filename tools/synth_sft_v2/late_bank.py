"""Late-game stall states (2026-10-10): the 9B answers {} for the whole late game of the games it cannot finish.

Collects the smoke games of the Qwen SFT runs (artifacts/brain_pipeline_v1/sft_mix_*/smoke/step*/{collapse,hq}) into a
bank of the same shape as bank.py (branch.py replays them with the recorded answers) and lists the late states
(turn >= MIN_TURN, answer {}) that need an acting answer.  CPU only.

  python -m tools.synth_sft_v2.late_bank   -> synth_sft_v2/late_bank_{collapse,hq}.json, late_states.jsonl
"""
from __future__ import annotations

import glob
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BP = ROOT / "artifacts" / "brain_pipeline_v1"
OUT = BP / "synth_sft_v2"
MIN_TURN = 30
EMPTY = re.compile(r'"orders"\s*:\s*\{\s*\}')


def main():
    banks = {"collapse": {}, "hq": {}}
    states = []
    for d in sorted(glob.glob(str(BP / "sft_mix_*" / "smoke" / "step*" / "*"))) + \
            sorted(glob.glob("D:/d/Game development/Demon slayer/StrategyGame/artifacts/brain_pipeline_v1/sft_mix_*/smoke/step*/*")):
        d = Path(d)
        mode = d.name
        if mode not in banks or not (d / "results.jsonl").exists() or not (d / "raw" / "calls.jsonl").exists():
            continue
        src = "%s/%s" % (d.parent.parent.parent.name, d.parent.name)
        jobs = {}
        for l in (d / "results.jsonl").read_text(encoding="utf-8").splitlines():
            if l.strip():
                r = json.loads(l)
                jobs[r["game"]] = r
        answers = {}
        for l in (d / "raw" / "calls.jsonl").read_text(encoding="utf-8").splitlines():
            if not l.strip():
                continue
            c = json.loads(l)
            if c.get("request") != "VICTORY_COMMAND" or c.get("served") != "LOCAL":
                continue
            raw = c["raw"] if isinstance(c["raw"], str) else json.dumps(c["raw"])
            answers.setdefault(c["tag"], {})[str(c["turn"])] = raw
        for g, j in jobs.items():
            a = answers.get(g)
            if not a or j.get("error") or j.get("fault"):
                continue
            gid = "%s__%s_%s" % (src.replace("/", "_"), mode, g)
            banks[mode][gid] = {"game": gid, "seed": j["seed"], "tier": j["tier"], "style": j["style"],
                                "family": j["family"], "army_size": (j.get("units") or {}).get("red", {}).get("start")
                                if mode == "collapse" else None, "outcome": j.get("outcome"), "kind": j.get("kind"),
                                "turn": j.get("turn"), "answers": a, "source": src}
            for t, raw in a.items():
                if int(t) >= MIN_TURN and EMPTY.search(raw):
                    states.append({"id": "%s__t%s" % (gid, t), "mode": mode, "game": gid, "turn": int(t), "source": src})
    for m, b in banks.items():
        (OUT / ("late_bank_%s.json" % m)).write_text(json.dumps(b, indent=1), encoding="utf-8")
    with open(OUT / "late_states.jsonl", "w", encoding="utf-8") as f:
        for s in states:
            f.write(json.dumps(s) + "\n")
    print("games collapse %d hq %d; late empty states %d (turn>=%d)" % (len(banks["collapse"]), len(banks["hq"]), len(states), MIN_TURN))


if __name__ == "__main__":
    main()
