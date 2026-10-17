"""Teacher takeover on HQ games (2026-10-13, user): a Qwen game of the seed-grind pool is replayed with Qwen's own recorded
answers up to turn T-1, from T on the teacher answers every request (a local OpenAI-compatible server, e.g. Strata) and
Godot plays to the end.  T = the first turn at which >= MIN_FLAGGED own units made no progress for 3 turns (tools.cmd_rl.
steer_shim.stall_block), or 1 when Qwen's opening was empty.  Builds bank + branches for tools.synth_sft_v2.branch --mode hq.

  python -m tools.dagger_v1.strata_takeover --pool <seed_grind dir> --n 24 --out <dir>
"""
import argparse
import collections
import glob
import json
import random
import re
from pathlib import Path

from tools.cmd_rl.steer_shim import stall_block

MIN_FLAGGED = 3


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pool", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--n", type=int, default=24)
    ap.add_argument("--seed", type=int, default=7)
    a = ap.parse_args()
    pool, out = Path(a.pool), Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    summ = {}
    for l in (pool / "harvest" / "games_summary.jsonl").read_text(encoding="utf-8").splitlines():
        r = json.loads(l)
        summ[r["tag"]] = r
    fam = {}
    for f in pool.glob("seeds_cycle*.json"):
        for j in json.loads(f.read_text(encoding="utf-8")):
            fam[j["seed"]] = j
    calls = collections.defaultdict(dict)
    stall_t = {}
    for f in glob.glob(str(pool / "seeds" / "**" / "calls.jsonl"), recursive=True):
        for l in open(f, encoding="utf-8"):
            c = json.loads(l)
            if c.get("request") != "VICTORY_COMMAND" or not c.get("tag") or not isinstance(c.get("raw"), str):
                continue
            t = int(c["turn"])
            calls[c["tag"]][t] = c  # the last accepted answer of a turn (turn-1 re-asks)
    cand = []
    for tag, by in calls.items():
        s = summ.get(tag)
        if not s or s["kind"] == "WIN" or s["seed"] not in fam or len(by) < 10:
            continue
        T = None
        first = by.get(1, {}).get("raw", "")
        if re.search(r'"orders"\s*:\s*\{\s*\}', first):
            T = 1
        else:
            for t in sorted(by):
                if t < 6:
                    continue
                c = by[t]
                if not isinstance(c.get("state"), dict):
                    continue
                blk = stall_block(c["state"], c.get("messages"))
                if blk.count(chr(10) + "- ") >= MIN_FLAGGED:
                    T = t
                    break
        if T:
            cand.append((tag, T, s, fam[s["seed"]]))
    random.Random(a.seed).shuffle(cand)
    # spread over styles
    byst = collections.defaultdict(list)
    for x in cand:
        byst[x[3]["style"]].append(x)
    pick = []
    while len(pick) < a.n and any(byst.values()):
        for st in list(byst):
            if byst[st] and len(pick) < a.n:
                pick.append(byst[st].pop())
    bank, rows = {}, []
    for tag, T, s, j in pick:
        answers = {str(t): c["raw"] for t, c in calls[tag].items() if t < T}
        bank[tag] = {"game": tag, "seed": j["seed"], "tier": j["tier"], "style": j["style"], "family": j["family"],
                     "overlay": "", "army_size": None, "answers": answers, "outcome": s["kind"], "turn": s["turn"]}
        rows.append({"id": "tk__" + tag, "game": tag, "turn": T, "horizon": 60 - T, "answer": "__LIVE__", "after": "live"})
    (out / "bank.json").write_text(json.dumps(bank, indent=1), encoding="utf-8")
    (out / "branches.jsonl").write_text("".join(json.dumps(r) + chr(10) for r in rows), encoding="utf-8")
    print("candidates %d (of which T=1: %d); picked %d; T histogram %s" % (
        len(cand), sum(1 for x in cand if x[1] == 1), len(pick), sorted(collections.Counter(r["turn"] for r in rows).items())[:12]))


if __name__ == "__main__":
    main()
