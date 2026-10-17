"""Play against the 9B yourself (2026-10-11, user): YOU are BLUE, the local Qwen commander is RED, collapse mission.

Starts vLLM with the adapter as "policy" (WSL), the teacher proxy, the Hands worker and ONE visible game window
(WATCH_BLUE_MODE=HUMAN: you move/attack with the mouse and press End Turn; Qwen answers after every End Turn).
Win: destroy 70%+ of RED's non-HQ units. Lose: you lose 70%+ of yours, or your HQ falls. 60 turns.

  python -m tools.cmd_rl.play_vs_qwen [--army 10] [--games 3] [--adapter <dir>] [--seed N]
"""
from __future__ import annotations

import argparse
import json
import random
import secrets
import subprocess
import time
from pathlib import Path

from tools.brain_review.harvest import post, wait_port
from tools.cmd_rl import loop as L
from tools.contextual_brain import rl_vs_utility as RV
from tools.plan_search.eval_plans import Hands

ROOT = RV.ROOT
DEFAULT_ADAPTER = ROOT / "artifacts" / "brain_pipeline_v1" / "sft_mix_v3b" / "adapters" / "ckpt_step536"
OUT = ROOT / "artifacts" / "brain_pipeline_v1" / "play_vs_qwen"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mission", choices=["collapse", "hq", "both"], default="collapse",
                    help="collapse: kill 70%% of RED's units; hq: destroy the RED HQ (RL v8 rules, default 10v10 roster)")
    ap.add_argument("--army", type=int, default=10, help="units per side (HQ included), same on both sides (collapse)")
    ap.add_argument("--games", type=int, default=3)
    ap.add_argument("--adapter", default=str(DEFAULT_ADAPTER))
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--turn-cap", type=int, default=60)
    ap.add_argument("--slot", type=int, default=0)
    ap.add_argument("--proxy-port", type=int, default=8120)
    ap.add_argument("--brain-port", type=int, default=8130)
    ap.add_argument("--keep-vllm", action="store_true", default=True, help="leave vLLM running when done (default)")
    a = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    L.VLLM_SCRIPT = "run_vllm_q35_64k_fp8.sh"
    L.RUN = OUT

    def log(m):
        print(time.strftime("%H:%M:%S ") + m, flush=True)

    adapter = Path(a.adapter)
    up = False
    try:  # a previous play session left the same policy server running: reuse it (saves the 3 minute load)
        import urllib.request
        with urllib.request.urlopen(L.VLLM_URL + "/v1/models", timeout=5) as r:
            up = "policy" in [m["id"] for m in json.loads(r.read())["data"]]
    except Exception:  # noqa: BLE001
        up = False
    if up:
        log("vLLM already serving 'policy': reusing it")
    else:
        log("vLLM starting with %s (about 3 minutes) ..." % adapter.name)
        L.vllm_stop(log)
        L.vllm_start(adapter, log)
    L.probe(log, 0, True)
    hands = Hands(a.slot, OUT, log, "cpu")
    hands.start()
    env = {"LAYA_URL": hands.url, "BRAIN_CONTRACT_MODE": "unalloc_v1", "SELFPLAY_GENERAL_TIMEOUT_SEC": "7200",
           "WATCH_STRATEGIC_REPLAN_TURNS": "0", "WATCH_RED_MODE": "COMMANDER", "WATCH_BLUE_MODE": "HUMAN",
           "WATCH_CMD_FACTS": "1", "FIELD_FORTIFY": "1",
           "WATCH_CMD_URL": "http://127.0.0.1:%d/v1/chat/completions" % a.proxy_port,
           "WATCH_BRAIN_PORT": str(a.proxy_port)}
    if a.mission == "collapse":
        env.update({"WATCH_ROUT_MIN": "0", "WATCH_NO_HQ_WIN": "1", "WATCH_MISSION": "remaining30_hq_guard"})
    elif a.mission == "both":  # HQ win OR 70% collapse, for both sides, every roster size
        env.update({"WATCH_ROUT_MIN": "0", "WATCH_NO_HQ_WIN": "0", "WATCH_ROUT_SHARE": "0.7"})
    else:  # the HQ mission of the RL v8 ladder: HQ win, rout rule from 17 units, default sandbox roster
        env.update({"WATCH_ROUT_MIN": "17", "WATCH_NO_HQ_WIN": "0"})
    arena = RV.Arena(log, 10 + 10 * a.slot, env, None, headless=False)
    try:
        for g in range(a.games):
            cap = OUT / ("game_%s_%d" % (time.strftime("%m%d_%H%M%S"), g))
            cap.mkdir(parents=True, exist_ok=True)
            token = secrets.token_hex(8)
            proxy = subprocess.Popen(
                [RV.PY, "-m", "tools.brain_review.teacher_proxy", "--session", token, "--capture-dir", str(cap),
                 "--port", str(a.proxy_port), "--brain-port", str(a.brain_port), "--default-mode", "TEACHER",
                 "--initial-stub", "--local-url", L.VLLM_URL + "/v1/chat/completions", "--local-model", "policy",
                 "--local-answer-tokens", "2000", "--local-think-budget", "0", "--local-max-tokens", "12000",
                 "--local-top-k", "0", "--local-presence-penalty", "0", "--local-no-think"],
                cwd=str(ROOT), stdout=open(cap / "proxy.log", "a"), stderr=subprocess.STDOUT)
            if not wait_port(a.proxy_port, token, 180):
                raise SystemExit("teacher proxy did not come up")
            seed = a.seed or random.randint(9600000, 9699999)
            rng = random.Random(seed)
            job = {"family": rng.choice(["fixed", "mild", "broad", "counterfactual_valid"]), "seed": seed,
                   "tier": "BASIC", "style": rng.choice(["SPEARHEAD", "BULWARK", "OUTRIDER", "HARRIER"]),
                   "turn_cap": a.turn_cap, "session": token, "random_roster": a.mission != "hq",
                   "roster_sizes": "%d-%d" % (a.army, a.army) if a.mission != "hq" else ""}
            post(a.proxy_port, "/admin/tags", {"w%d" % (10 + 10 * a.slot): "human_%d" % g})
            log("game %d/%d seed=%d army=%d: the window opens; you are BLUE" % (g + 1, a.games, seed, a.army))
            out = cap / "result.json"
            err = arena.play(job, out, 7200)
            res = json.loads(out.read_text(encoding="utf-8")) if out.exists() else {"error": err or "no result"}
            try:
                post(a.proxy_port, "/admin/shutdown", {})
                proxy.wait(timeout=60)
            except Exception:  # noqa: BLE001
                proxy.kill()
            u = res.get("units") or {}
            who = {"BLUE_WIN": "YOU WIN", "RED_WIN": "QWEN WINS", "CAP": "turn cap (draw)"}.get(str(res.get("outcome")), str(res.get("outcome")))
            log("RESULT: %s  turn=%s  you=%s/%s  qwen=%s/%s  win_rule=%s" % (
                who, res.get("turn"), (u.get("blue") or {}).get("alive"), (u.get("blue") or {}).get("start"),
                (u.get("red") or {}).get("alive"), (u.get("red") or {}).get("start"), res.get("win_rule")))
    finally:
        arena.quit()
        hands.stop()
        if not a.keep_vllm:
            L.vllm_stop(log)


if __name__ == "__main__":
    main()
