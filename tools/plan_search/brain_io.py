"""Brain-in-the-loop I/O for outside agents (e.g. official Freebuff app windows, started and watched by the user) that
play the RED commander through the collector's manual mode (cmd_collect --manual-dir <dir>). Several agents can play
at once: each request is claimed by exactly one agent (claim_NNNN.txt, created exclusively) before it is shown.

  python -m tools.plan_search.brain_io next <dir> <agent> [game]    claim the next request (only that game's, if
                                                                    given: one agent keeps one game's memory;
                                                                    NEW = the first request of a game not started yet)
  python -m tools.plan_search.brain_io answer <dir> <agent> <file>  answer the request this agent claimed
  python -m tools.plan_search.brain_io status <dir>                 counts and finished games

A claim not answered within STALE_S is released so another agent can take it. Legacy opening-plan requests
(VICTORY_INITIAL) are answered "{}" here, as the cloud collector does.
"""
from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

from tools.plan_search.cloud_brain import extract_orders, fmt_packet

STALE_S = 900


def _resp(f: Path) -> Path:
    return f.with_name(f.name.replace("req_", "resp_").replace(".json", ".txt"))


def _claim(f: Path) -> Path:
    return f.with_name(f.name.replace("req_", "claim_").replace(".json", ".txt"))


def _try_claim(f: Path, agent: str) -> bool:
    c = _claim(f)
    if c.exists() and time.time() - c.stat().st_mtime > STALE_S and not _resp(f).exists():
        c.unlink(missing_ok=True)  # the agent that held it went quiet
    try:
        fd = os.open(c, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError:
        return False
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(agent)
    return True


def _mine(d: Path, agent: str):
    for c in sorted(d.glob("claim_*.txt")):
        req = c.with_name(c.name.replace("claim_", "req_").replace(".txt", ".json"))
        if not _resp(req).exists() and c.read_text(encoding="utf-8").strip() == agent:
            return req
    return None


def next_request(d: Path, agent: str, wait_s: int = 1800, game: str = ""):
    held = _mine(d, agent)
    if held is not None:
        print("NOTE: you still hold %s; answer it first (shown again below)" % held.name)
        _show(d, held, agent)
        return
    deadline = time.time() + wait_s
    while time.time() < deadline:
        for f in sorted(d.glob("req_*.json")):
            if _resp(f).exists():
                continue
            if game:
                try:
                    rq = json.loads(f.read_text(encoding="utf-8"))
                except ValueError:
                    continue
                if game == "NEW":  # only a game's first request: a fresh agent takes a whole new game
                    if len(rq.get("messages", [])) > 2:
                        continue
                elif game not in str(rq.get("tag", "")):
                    continue
            if not _try_claim(f, agent):
                continue
            r = json.loads(f.read_text(encoding="utf-8"))
            if r.get("request") != "VICTORY_COMMAND":
                _resp(f).write_text("{}", encoding="utf-8")
                continue
            _show(d, f, agent)
            return
        time.sleep(2)
    print("no request within %d s (are games still running? see status)" % wait_s)


def _show(d: Path, f: Path, agent: str):
    r = json.loads(f.read_text(encoding="utf-8"))
    print("=== REQUEST %s (game %s, turn %s) for agent %s ===" % (f.name, r.get("tag"), r.get("turn"), agent))
    if len(r["messages"]) <= 2:  # a game's first message: the instructions and the full state
        print("=== INSTRUCTIONS ===")
        print(r["messages"][0]["content"])
        print("=== BATTLE STATE ===")
        print(fmt_packet(r["messages"][-1]["content"]))
    else:  # resident game: you already hold the instructions and everything before; this is only the new turn
        print("=== TURN MESSAGE ===")
        print(fmt_packet(r["messages"][-1]["content"]))
    print("=== END ===")
    print("Write ONLY the JSON object to a file and run: brain answer %s <file>" % agent)


def answer(d: Path, agent: str, src: str):
    f = _mine(d, agent)
    if f is None:
        print("ERROR: you hold no request; run: brain next %s" % agent)
        return
    txt = Path(src).read_text(encoding="utf-8") if src and Path(src).exists() else src
    doc = extract_orders(txt or "")
    if doc is None:
        print("ERROR: the answer must be one JSON object with an \"orders\" object; nothing was sent, fix it and answer again")
        return
    _resp(f).write_text(json.dumps(doc, ensure_ascii=False), encoding="utf-8")
    print("answered %s (%d orders)" % (f.name, len(doc.get("orders") or {})))


def status(d: Path):
    reqs = sorted(d.glob("req_*.json"))
    done = sum(1 for f in reqs if _resp(f).exists())
    print("requests %d, answered %d, waiting %d" % (len(reqs), done, len(reqs) - done))
    res = d.parent / "results.jsonl"
    if res.exists():
        for line in res.read_text(encoding="utf-8").splitlines():
            r = json.loads(line)
            print("  %s -> %s turn=%s" % (r.get("game"), r.get("kind"), r.get("turn")))


def main():
    cmd, d = sys.argv[1], Path(sys.argv[2])
    d.mkdir(parents=True, exist_ok=True)
    if cmd in ("next", "answer") and (len(sys.argv) < 4 or sys.argv[3].strip() in ("", "AGENT_ID")):
        print("ERROR: give your own agent id (e.g. G1), not AGENT_ID")
        return
    if cmd == "next":
        next_request(d, sys.argv[3] if len(sys.argv) > 3 else "A1", wait_s=int(os.environ.get("BRAIN_IO_WAIT_S", "1800")),
                     game=sys.argv[4] if len(sys.argv) > 4 else "")
    elif cmd == "answer":
        answer(d, sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else "")
    elif cmd == "status":
        status(d)


if __name__ == "__main__":
    main()
