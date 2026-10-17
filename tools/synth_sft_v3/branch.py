"""Synthetic commander SFT V3: replay and branch real winning commander games.

A branch = a bank game played again with its teacher answers up to turn T-1, one given answer at turn T (a synthetic
candidate, or the teacher's own answer as the control), then {"orders": {}} (orders stand) until turn T+H. Godot plays
both sides; the branch's own game record gives the result at T+H (kills, losses, HQ, win).

--runtime frozen uses the unchanged V2 runtime for the first Gate B test.
--runtime production leaves RV.ROOT unchanged and uses the seed_grind production game runtime.
Both use collapse mission, CPU Hands, headless Godot, fortify, original army size and rule overlay.

  python -m tools.synth_sft_v3.branch <branches.jsonl> <out dir> --windows 10 --slot 6 --proxy-port 8126 --brain-port 8136
branches.jsonl rows: {"id", "game", "turn", "horizon", "answer", "after"}   (answer = the JSON text played at turn T)
"replay" rows (turn 0, no answer) play the whole game with its teacher answers: the determinism check.
"after": "stand" (default: orders stand until T+horizon) or "live" (2026-10-09, plan loop: later turns are answered by
the local 9B at --live-url / --live-model, thinking off, to the game's end). "gx" keeps orders through T+H-1,
then switches RED to mission-free GX_INTER_BULWARK before its phase at T+H and plays to the 60-turn terminal cap.
Every request at the branch turn is saved
to <out>/requests/<id>.json (the exact messages the game sent there).
--mode hq (plan loop, 2026-10-09): the production runtime and the HQ mission as RL v8 played it (default roster, rout
min 17, HQ win); the bank game's own seed and overlay.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import sys
import threading
import time
from pathlib import Path

from tools.plan_search.brain_io import _resp, _try_claim
from tools.synth_sft_v3.grind_bank import decode_answer
SYN = Path(__file__).resolve().parents[2] / "artifacts" / "brain_pipeline_v1" / "synth_sft_v3"
FROZEN_RUNTIME = SYN.parent / "synth_sft_v2" / "runtime"

STAND = '{"orders": {}}'


def serve(md: Path, bank: dict, branches: dict, stop: threading.Event, live: dict = None):
    md.mkdir(parents=True, exist_ok=True)
    (md.parent / "requests").mkdir(exist_ok=True)
    pool = concurrent.futures.ThreadPoolExecutor(8)

    def answer_live(f, msgs):
        from tools.plan_search.cloud_brain import local_command
        text, _ = local_command(msgs, url=live["url"], model=live["model"], no_think=True, answer_tokens=2000,
                                temperature=0.6, timeout_s=600)
        _resp(f).write_text(text or STAND, encoding="utf-8")

    while not stop.is_set():
        for f in sorted(md.glob("req_*.json")):
            if _resp(f).exists() or not _try_claim(f, "BRANCH"):
                continue
            r = json.loads(f.read_text(encoding="utf-8"))
            text = "{}"
            if r.get("request") == "VICTORY_COMMAND":
                b = branches.get(str(r.get("tag")), {})
                g = bank.get(b.get("game", ""), {})
                t = int(r.get("turn", 0))
                bt = int(b.get("turn", 0))
                if bt == 0 or t < bt:
                    if "engine_answers" in g:
                        # Exact original wire content audited against capture calls.
                        # Missing prefix decisions are corruption, never invented STAND.
                        text = g["engine_answers"][str(t)]
                    else:
                        text = g.get("answers", {}).get(str(t), STAND)
                        text = json.dumps(decode_answer(text), ensure_ascii=False)
                    if bt == 0:
                        (md.parent / "requests" / ("%s__t%d.json" % (b["id"], t))).write_text(
                            json.dumps(r.get("messages") or [], ensure_ascii=False), encoding="utf-8")
                elif t == bt:
                    if b["id"].startswith("C__") and "engine_answers" in g:
                        text = g["engine_answers"][str(t)]
                    else:
                        text = b["answer"]
                    (md.parent / "requests" / ("%s.json" % b["id"])).write_text(json.dumps(r.get("messages") or []), encoding="utf-8")
                elif b.get("after") == "live" and live:
                    pool.submit(answer_live, f, r.get("messages") or [])
                    continue
                else:
                    text = STAND
            _resp(f).write_text(text, encoding="utf-8")
        time.sleep(0.1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("branches")
    ap.add_argument("out")
    ap.add_argument("--windows", type=int, default=6)
    ap.add_argument("--slot", type=int, default=0)
    ap.add_argument("--proxy-port", type=int, default=8120)
    ap.add_argument("--brain-port", type=int, default=8130)
    ap.add_argument("--bank", default=str(SYN / "bank_grind.json"))
    ap.add_argument("--runtime", choices=["frozen", "production"], default="production")
    ap.add_argument("--manual-poll-s", type=float, default=1.0,
                    help="Only changes proxy polling latency, never request or response content")
    ap.add_argument("--mode", default="collapse", choices=["collapse", "hq"])
    ap.add_argument("--live-url", default="http://127.0.0.1:8000/v1/chat/completions")
    ap.add_argument("--live-model", default="policy")
    a = ap.parse_args()
    out = Path(a.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    bank = json.loads(Path(a.bank).read_text(encoding="utf-8"))
    branches = {}
    for line in Path(a.branches).read_text(encoding="utf-8").splitlines():
        if line.strip():
            b = json.loads(line)
            branches[b["id"]] = b
    games = []
    for b in branches.values():
        g = bank[b["game"]]
        games.append({"game": b["id"], "tier": g["tier"], "style": g["style"], "family": g["family"], "seed": g["seed"],
                      "overlay": g["overlay"]})
    (out / "games.jsonl").write_text("".join(json.dumps(r) + "\n" for r in games), encoding="utf-8")

    from tools.contextual_brain import rl_vs_utility as RV
    if a.mode == "collapse":
        if a.runtime == "frozen":
            RV.ROOT = FROZEN_RUNTIME
        os.environ.update({"WATCH_MISSION": "remaining30_hq_guard", "WATCH_ROUT_MIN": "0", "WATCH_NO_HQ_WIN": "1"})
    else:
        for k in ("WATCH_MISSION", "WATCH_ROUT_MIN", "WATCH_NO_HQ_WIN", "WATCH_MISSION_MAP"):
            os.environ.pop(k, None)
    RV.OUT = out / "arenas"
    RV.OUT.mkdir(exist_ok=True)
    original_play = RV.Arena.play

    def play(self, job, out_file, *args, **kwargs):  # the bank game's army size; the branch's horizon as the turn cap
        b = branches[Path(out_file).stem]
        g = bank[b["game"]]
        job = dict(job)
        if g.get("army_size"):
            job["random_roster"] = True
            job["roster_sizes"] = g.get("roster_sizes") or "%d-%d" % (g["army_size"], g["army_size"])
        else:  # the default sandbox roster (RL v8)
            job["random_roster"] = False
            job["roster_sizes"] = ""
        live_end = int(b.get("turn", 0)) == 0 or b.get("after") in ("live", "gx")
        job["red_handoff_turn"] = int(b["turn"]) + int(b["horizon"]) if b.get("after") == "gx" else 0
        # Native 60-turn mission clock must remain in every original prompt.
        # crosscheck.facts selects only the branch's own V2 horizon endpoint;
        # later battle events never contribute to the candidate verdict.
        job["turn_cap"] = 60
        return original_play(self, job, out_file, *args, **kwargs)

    RV.Arena.play = play
    # A re-run in the same out dir (2026-10-10 fix): the collector numbers its requests from 1 again, so old
    # req/resp/claim files would answer the new requests with stale replies. Keep them aside, start empty.
    md_old = out / "manual"
    if md_old.exists() and any(md_old.iterdir()):
        md_old.rename(out / ("manual_prev_%d" % int(time.time())))
    stop = threading.Event()
    threading.Thread(target=serve, args=(out / "manual", bank, branches, stop, {"url": a.live_url, "model": a.live_model}),
                     daemon=True).start()
    from tools.plan_search import cmd_collect
    original_popen = cmd_collect.subprocess.Popen
    def start_with_manual_poll(args, *positional, **keywords):
        if a.runtime == 'production' and isinstance(args, list) and 'tools.brain_review.teacher_proxy' in args and '--manual-dir' in args:
            args = args + ['--manual-poll-s', str(a.manual_poll_s)]
        return original_popen(args, *positional, **keywords)
    cmd_collect.subprocess.Popen = start_with_manual_poll
    sys.argv = ["cmd_collect", "--out", str(out), "--games", str(out / "games.jsonl"), "--windows", str(a.windows),
                "--slot", str(a.slot), "--proxy-port", str(a.proxy_port), "--brain-port", str(a.brain_port),
                "--manual-dir", str(out / "manual"), "--turn-cap", "60", "--fortify", "--call-timeout", "900"]
    if a.mode == "collapse":
        sys.argv += ["--random-roster", "--roster-sizes", "10"]
    try:
        cmd_collect.main()
    finally:
        stop.set()
        cmd_collect.subprocess.Popen = original_popen


if __name__ == "__main__":
    main()
