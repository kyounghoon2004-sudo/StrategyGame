"""Replay logged Brain-vs-GX games to get their full record (2026-10-08). The old runs kept only the Brain's answers,
not every unit of both sides each phase. A game is deterministic given its seed and the orders, so the same game is
played again with the answers fed back on the turns they were given ({"orders": {}} on every other turn: orders
stand). The new arena then records both sides in full. A replay counts only if it ends like the original.

  python -m tools.predict.replay prepare <out dir>            LLM runs: game lists (fortify on / off) + answers
  python -m tools.predict.replay prepare-code <out dir>       code-policy packages (survivors, growth) the same way
  python -m tools.predict.replay serve <manual dir> <answers> answer the collector's manual requests
  python -m tools.predict.replay check <out dir>              replay vs original outcome
"""
from __future__ import annotations

import glob
import json
import re
import sys
import time
from pathlib import Path

from tools.plan_search.brain_io import _resp, _try_claim

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "artifacts" / "brain_pipeline_v1"
SKIP = re.compile(r"synth|smoke|devmode|gxgx|replay")  # code commanders and test runs: not LLM play
GAME_RX = re.compile(r"^(BASIC|INTER|ADV)_([A-Z]+)_(.+)_s(\d+)$")
# Godot's user:// of this project: each played game's exact rule overlay is kept there (user://watch/*.json).
USER_DIR = Path.home() / "AppData" / "Roaming" / "Godot" / "app_userdata" / "[unnamed project]"


def original_overlay(d: Path, game: str) -> str:
    """The exact rule overlay the original game ran with ("" when it is gone or was overwritten since). Until the
    2026-10-08 fix a long-lived arena re-jittered the previous match's rules, so the seed alone does not give them."""
    gf = d / "games" / ("%s.json" % game)
    if not gf.exists():
        return ""
    try:
        ep = json.loads(gf.read_text(encoding="utf-8")).get("episode") or {}
    except ValueError:
        return ""
    sp = str(ep.get("spec_path", ""))
    f = USER_DIR / sp.replace("user://", "") if sp.startswith("user://") else None
    if f is None or not f.exists():
        return ""
    try:
        ok = json.loads(f.read_text(encoding="utf-8")).get("episode_id") == ep.get("episode_id")
    except ValueError:
        return ""
    return str(f) if ok else ""


def runs() -> list:
    out = []
    for rp in glob.glob(str(SRC / "cmd_collect_*" / "results.jsonl")) + glob.glob(str(SRC / "cmd_collect_*" / "*" / "results.jsonl")):
        d = Path(rp).parent
        if not SKIP.search(str(d.relative_to(SRC))) and (d / "raw" / "calls.jsonl").exists():
            out.append(d)
    return out


CODE_PACKAGES = ("commander_survivors_20261007", "commander_growth_20261007")


def prepare(out: Path, code: bool = False):
    """code = False: the LLM runs (cmd_collect_*); True: the code-policy packages (their calls sit in slot dirs)."""
    out.mkdir(parents=True, exist_ok=True)
    lists = {True: [], False: []}
    answers, originals = {}, {}
    sources = [SRC / p for p in CODE_PACKAGES] if code else runs()
    for d in sources:
        name = str(d.relative_to(SRC)).replace("\\", "/").replace("/", "~")
        final = {}
        for line in (d / "results.jsonl").read_text(encoding="utf-8").splitlines():
            r = json.loads(line)
            if r.get("kind") not in ("INVALID", "ERROR"):
                final[r["game"]] = r
        calls, fort = {}, False
        call_files = sorted(d.rglob("calls.jsonl")) if code else [d / "raw" / "calls.jsonl"]
        lines = [l for f in call_files for l in f.read_text(encoding="utf-8").splitlines()]
        for line in lines:
            try:
                c = json.loads(line)
            except ValueError:
                continue
            if c.get("request") != "VICTORY_COMMAND" or c.get("tag") not in final:
                continue
            m = c.get("messages") or []
            if m and '"do": "FORTIFY"' in str(m[0].get("content", "")):
                fort = True
            calls.setdefault(c["tag"], {}).setdefault(str(c.get("turn")), []).append(c.get("raw") or '{"orders": {}}')
        for g, turns in calls.items():
            o = final[g]
            mm = GAME_RX.match(g)
            if all(k in o for k in ("tier", "style", "family", "seed")):
                job = {"tier": o["tier"], "style": o["style"], "family": o["family"], "seed": int(o["seed"])}
            elif mm:
                job = {"tier": mm.group(1), "style": mm.group(2), "family": mm.group(3), "seed": int(mm.group(4))}
            else:
                continue
            key = "%s__%s" % (name, g)
            job["overlay"] = original_overlay(d, g)
            lists[fort].append({"game": key, **job})
            answers[key] = turns
            originals[key] = {"kind": o.get("kind"), "turn": o.get("turn"), "units": o.get("units"), "run": name,
                              "actor": "code" if code else "llm",
                              "holdout": o.get("stage") == "holdout" or "_holdout_" in g}
    for fort, rows in lists.items():
        (out / ("games_fort%d.jsonl" % fort)).write_text("".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8")
    (out / "answers.json").write_text(json.dumps(answers), encoding="utf-8")
    (out / "originals.json").write_text(json.dumps(originals), encoding="utf-8")
    print("games: fortify on %d, off %d, runs %d; with the original rule overlay %d" % (
        len(lists[True]), len(lists[False]), len({v["run"] for v in originals.values()}),
        sum(1 for rows in lists.values() for r in rows if r["overlay"])))


def serve(md: Path, answers_file: Path):
    answers = json.loads(answers_file.read_text(encoding="utf-8"))
    used = {}
    md.mkdir(parents=True, exist_ok=True)
    while True:
        for f in sorted(md.glob("req_*.json")):
            if _resp(f).exists() or not _try_claim(f, "REPLAY"):
                continue
            r = json.loads(f.read_text(encoding="utf-8"))
            text = "{}"
            if r.get("request") == "VICTORY_COMMAND":
                key = (r.get("tag"), str(r.get("turn")))
                lst = answers.get(r.get("tag"), {}).get(key[1], [])
                i = used.get(key, 0)
                text = lst[i] if i < len(lst) else '{"orders": {}}'
                used[key] = i + 1
            _resp(f).write_text(text, encoding="utf-8")
        time.sleep(0.2)


def check(out: Path):
    orig = json.loads((out / "originals.json").read_text(encoding="utf-8"))
    same = diff = 0
    for rp in glob.glob(str(out / "fort*" / "results.jsonl")):
        for line in Path(rp).read_text(encoding="utf-8").splitlines():
            r = json.loads(line)
            o = orig.get(r["game"])
            if not o:
                continue
            ok = o["kind"] == r.get("kind") and o["turn"] == r.get("turn") and o["units"] == r.get("units")
            same += ok
            diff += not ok
            if not ok:
                print("DIFF", r["game"], "orig", o["kind"], o["turn"], o["units"], "replay", r.get("kind"), r.get("turn"), r.get("units"))
    print("replays matching the original: %d of %d" % (same, same + diff))


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "prepare":
        prepare(Path(sys.argv[2]))
    elif cmd == "prepare-code":
        prepare(Path(sys.argv[2]), code=True)
    elif cmd == "serve":
        serve(Path(sys.argv[2]), Path(sys.argv[3]))
    elif cmd == "check":
        check(Path(sys.argv[2]))
