"""Resident-format SFT rows from replayed games (2026-10-08). A replay (tools/predict/replay.py) plays a logged game
again in the current resident game, so every turn's request is the exact conversation the Brain reads today. The
answers are the logged ones, cleaned to the resident reply format:
  - orders: only the units whose order really changes (a code policy re-issued every order; repeats are dropped),
  - no plan / notes / think keys (the code policies' plan texts name their own parameters),
and the conversation is rewritten to match: earlier answers are the cleaned ones, and the digest's "Your plan" line
(built from the old plan texts) is dropped. Only replays that ended exactly like the original game and were won are
used; a package's own hold-out games are never used. Turns without any change are kept at --keep-empty share.

  python -m tools.cmd_rl.build_sft_resident [--replays <dir>,<dir>] [--keep-empty 0.3] --out <file>
"""
from __future__ import annotations

import argparse
import glob
import json
import random
import re
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BP = ROOT / "artifacts" / "brain_pipeline_v1"
PLAN_LINE = re.compile(r"^Your plan \(since turn \d+\): .*$", re.M)


def clean_answers(raws: list) -> list:
    """Logged answers in turn order -> resident answers (only changed orders)."""
    standing, out = {}, []
    for raw in raws:
        try:
            doc = json.loads(raw)
        except ValueError:
            doc = {}
        diff = {}
        for uid, o in (doc.get("orders") or {}).items():
            if isinstance(o, dict) and standing.get(uid.upper()) != o:
                diff[uid] = o
                standing[uid.upper()] = o
        out.append(json.dumps({"orders": diff}, ensure_ascii=False))
    return out


def game_rows(reqs: list, keep_empty: float, rnd: random.Random) -> list:
    reqs = sorted(reqs, key=lambda r: int(r["turn"]))
    answers = clean_answers([r["resp"] for r in reqs])
    by_turn = {int(r["turn"]): a for r, a in zip(reqs, answers)}
    rows = []
    for r, ans in zip(reqs, answers):
        t = int(r["turn"])
        msgs = [dict(m) for m in r["messages"]]
        asst = [i for i, m in enumerate(msgs) if m["role"] == "assistant"]
        if asst:
            # the opening answer is turn 1's; the others are the turns kept word for word, right before this one
            turns = [min(by_turn)] + list(range(t - (len(asst) - 1), t))
            for i, tt in zip(asst, turns):
                msgs[i]["content"] = by_turn.get(tt, '{"orders": {}}')
        for m in msgs:
            if m["role"] == "user" and "BATTLE DIGEST" in m["content"]:
                m["content"] = PLAN_LINE.sub("", m["content"]).replace("\n\n\n", "\n\n")
        if ans == '{"orders": {}}' and rnd.random() > keep_empty:
            continue
        rows.append({"messages": msgs, "completion": ans, "game": r["game"], "turn": t})
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--replays", default=",".join(str(BP / d) for d in ("replay_code_v1", "replay_cloud_v1")))
    ap.add_argument("--keep-empty", type=float, default=0.3)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    rnd = random.Random(0)
    rows, games, per_run = [], 0, Counter()
    for rep in a.replays.split(","):
        rep = Path(rep)
        orig = json.loads((rep / "originals.json").read_text(encoding="utf-8"))
        for fort in sorted(rep.glob("fort*")):
            res = {}
            for line in (fort / "results.jsonl").read_text(encoding="utf-8").splitlines() if (fort / "results.jsonl").exists() else []:
                r = json.loads(line)
                res[r["game"]] = r
            keep = {g for g, r in res.items() if g in orig and r.get("kind") == "WIN" and not orig[g].get("holdout")
                    and orig[g]["kind"] == r["kind"] and orig[g]["turn"] == r.get("turn") and orig[g]["units"] == r.get("units")}
            reqs = {}
            for f in glob.glob(str(fort / "manual" / "req_*.json")):
                q = json.loads(Path(f).read_text(encoding="utf-8"))
                resp = Path(f.replace("req_", "resp_").replace(".json", ".txt"))
                if q.get("request") != "VICTORY_COMMAND" or q.get("tag") not in keep or not resp.exists():
                    continue
                reqs.setdefault(q["tag"], []).append({"turn": q["turn"], "messages": q["messages"], "game": q["tag"],
                                                      "resp": resp.read_text(encoding="utf-8")})
            for g, rq in reqs.items():
                rows += game_rows(rq, a.keep_empty, rnd)
                games += 1
                per_run[orig[g]["run"]] += 1
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_text(json.dumps(rows, ensure_ascii=False), encoding="utf-8")
    empty = sum(r["completion"] == '{"orders": {}}' for r in rows)
    chars = sorted(sum(len(m["content"]) for m in r["messages"]) for r in rows)
    print("games %d %s -> rows %d (no-change %d), conversation chars median %d max %d" % (
        games, dict(per_run), len(rows), empty, chars[len(chars) // 2] if chars else 0, chars[-1] if chars else 0))


if __name__ == "__main__":
    main()
