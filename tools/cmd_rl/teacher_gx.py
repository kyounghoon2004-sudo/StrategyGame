"""A local OpenAI-compatible model (Strata) plays RED, the whole game, against GX (HQ mission, RL v8 rules, 10v10): the
teacher test (2026-10-13, user): can it win on plain ADV the way the cloud teachers did?  Same prompts and runtime as the
Qwen games; only the endpoint differs.  No vLLM needed.

  python -m tools.cmd_rl.teacher_gx --tier ADV --games 16 --windows 8 --url http://127.0.0.1:8080/v1/chat/completions
"""
from __future__ import annotations

import argparse
import json
import queue
import secrets
import subprocess
import threading
import time
from pathlib import Path

from tools.brain_review.harvest import post, wait_port
from tools.contextual_brain import rl_vs_utility as RV
from tools.plan_search.eval_plans import Hands

ROOT = RV.ROOT
STYLES = ["SPEARHEAD", "BULWARK", "OUTRIDER", "HARRIER"]
FAMILY = ["fixed", "mild", "broad", "counterfactual_valid"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:8080/v1/chat/completions")
    ap.add_argument("--model", default="strata")
    ap.add_argument("--tier", default="ADV")
    ap.add_argument("--games", type=int, default=16)
    ap.add_argument("--windows", type=int, default=8)
    ap.add_argument("--seed0", type=int, default=9930000)
    ap.add_argument("--turn-cap", type=int, default=60)
    ap.add_argument("--slot", type=int, default=0)
    ap.add_argument("--proxy-port", type=int, default=8120)
    ap.add_argument("--brain-port", type=int, default=8130)
    ap.add_argument("--max-tokens", type=int, default=12000)
    ap.add_argument("--show", action="store_true", help="game windows visible (not headless)")
    ap.add_argument("--think", action="store_true")
    ap.add_argument("--think-budget", type=int, default=0, help="thinking tokens before the answer is forced (0 = unlimited)")
    ap.add_argument("--cmd-url", default="", help="URL the game calls for RED (default: the proxy), e.g. the steer_shim")
    ap.add_argument("--manual-dir", default="", help="RED requests are parked here and answered by hand (req_NNNN.json -> resp_NNNN.txt)")
    ap.add_argument("--style", default="", help="only this GX style (all games)")
    ap.add_argument("--family", default="", help="only this family (all games)")
    ap.add_argument("--out", default=str(ROOT / "artifacts" / "brain_pipeline_v1" / "teacher_gx_v1"))
    a = ap.parse_args()
    run = Path(a.out)
    run.mkdir(parents=True, exist_ok=True)
    lock = threading.Lock()

    def log(m):
        line = time.strftime("%m-%d %H:%M:%S ") + m
        with lock:
            print(line, flush=True)
            with open(run / "teacher.log", "a", encoding="utf-8") as fh:
                fh.write(line + "\n")

    hands = Hands(a.slot, run, log, "cpu")
    hands.start()
    env = {"LAYA_URL": hands.url, "BRAIN_CONTRACT_MODE": "unalloc_v1", "SELFPLAY_GENERAL_TIMEOUT_SEC": __import__("os").environ.get("GAME_TIMEOUT_S", "7200"),
           "WATCH_STRATEGIC_REPLAN_TURNS": "0", "WATCH_RED_MODE": "COMMANDER", "WATCH_BLUE_MODE": "GX",
           "WATCH_CMD_FACTS": "1", "FIELD_FORTIFY": "1", "WATCH_ROUT_MIN": __import__("os").environ.get("TG_ROUT_MIN", "17"), "WATCH_NO_HQ_WIN": __import__("os").environ.get("TG_NO_HQ_WIN", "0"),
           "WATCH_CMD_URL": a.cmd_url or "http://127.0.0.1:%d/v1/chat/completions" % a.proxy_port,
           "WATCH_BRAIN_PORT": str(a.proxy_port)}
    token = secrets.token_hex(8)
    cap = run / "captures"
    cap.mkdir(exist_ok=True)
    extra = ["--local-url", a.url, "--local-model", a.model, "--local-answer-tokens", "2000", "--local-think-budget", str(a.think_budget),
             "--local-max-tokens", str(a.max_tokens), "--local-top-k", "0", "--local-presence-penalty", "0", "--local-pass"]
    if not a.think:
        extra.append("--local-no-think")
    if a.manual_dir:
        extra = ["--manual-dir", a.manual_dir]
    proxy = subprocess.Popen(
        [RV.PY, "-m", "tools.brain_review.teacher_proxy", "--session", token, "--capture-dir", str(cap),
         "--port", str(a.proxy_port), "--brain-port", str(a.brain_port), "--default-mode", "TEACHER", "--initial-stub"] + extra,
        cwd=str(ROOT), stdout=open(cap / "proxy.log", "a"), stderr=subprocess.STDOUT)
    if not wait_port(a.proxy_port, token, 180):
        raise SystemExit("teacher proxy did not come up")
    q = queue.Queue()
    for i in range(a.games):
        q.put((a.seed0 + i, a.style or STYLES[i % 4], a.family or FAMILY[(i // 4) % 4]))
    arenas = [RV.Arena(log, 10 + 10 * a.slot + i, dict(env), None, headless=not a.show) for i in range(a.windows)]
    t0 = time.time()

    def worker(i, ar):
        win = "w%d" % (10 + 10 * a.slot + i)
        while True:
            try:
                seed, style, fam = q.get_nowait()
            except queue.Empty:
                return
            tag = "t_%s_%s_s%d" % (a.tier, style, seed)
            job = {"family": fam, "seed": seed, "tier": a.tier, "style": style, "turn_cap": a.turn_cap,
                   "session": token, "random_roster": False, "roster_sizes": ""}
            post(a.proxy_port, "/admin/tags", {win: tag})
            o = run / "games" / ("%s.json" % tag)
            o.parent.mkdir(exist_ok=True)
            g0 = time.time()
            err = ar.play(job, o, int(__import__("os").environ.get("GAME_TIMEOUT_S", "7200")))
            res = json.loads(o.read_text(encoding="utf-8")) if o.exists() else {"error": err or "no result"}
            try:
                sc = RV.score(res)
                kind = sc["kind"]
            except Exception:  # noqa: BLE001
                kind = "ERROR"
            hq = ((res.get("hq") or {}).get("blue") or {})
            row = {"tag": tag, "seed": seed, "tier": a.tier, "style": style, "family": fam, "kind": kind,
                   "outcome": res.get("outcome"), "turn": res.get("turn"), "units": res.get("units"),
                   "hq_end": hq.get("end"), "game_s": round(time.time() - g0)}
            with lock:
                with open(run / "games.jsonl", "a", encoding="utf-8") as fh:
                    fh.write(json.dumps(row) + "\n")
            log("[TEACHER] %s -> %s outcome=%s turn=%s hq_end=%s units=%s (%ds)" % (
                tag, kind, row["outcome"], row["turn"], row["hq_end"], row["units"], row["game_s"]))

    threads = [threading.Thread(target=worker, args=(i, ar), daemon=True) for i, ar in enumerate(arenas)]
    for t in threads:
        t.start()
        time.sleep(3)
    for t in threads:
        t.join()
    log("[TEACHER] done %d games in %ds" % (a.games, time.time() - t0))
    try:
        post(a.proxy_port, "/admin/shutdown", {})
        proxy.wait(timeout=60)
    except Exception:  # noqa: BLE001
        proxy.kill()
    for ar in arenas:
        ar.quit()
    hands.stop()


if __name__ == "__main__":
    main()
