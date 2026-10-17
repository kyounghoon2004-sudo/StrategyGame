"""Sparring (2026-10-12, user): the local Qwen commander is RED (HQ mission, RL v8 rules, 10v10), BLUE is a COMMANDER
too: a cloud model through the opencode/agy CLI (--models) or an agent/human answering by hand (--manual).  The point
is to see how flexible the Qwen is against opponents that are not GX.

  python -m tools.cmd_rl.spar --models agy/gemini-3.8-flash-medium,opencode-go/gpt-6-luna,opencode-go/step-5-preview-free --per-model 2
  python -m tools.cmd_rl.spar --manual            # one game, BLUE answers are files in <out>/manual/ (req_NNNN.json -> resp_NNNN.txt)
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
from tools.cmd_rl import loop as L
from tools.contextual_brain import rl_vs_utility as RV
from tools.plan_search.eval_plans import Hands

ROOT = RV.ROOT
OUT = ROOT / "artifacts" / "brain_pipeline_v1" / "spar_v1"
ADAPTER = ROOT / "artifacts" / "brain_pipeline_v1" / "seed_grind_hq_adv" / "seeds" / "9900000" / "adapters" / "a15"
FAMILY = ["fixed", "mild", "broad", "counterfactual_valid"]


def proxy_cmd(token, cap, port, brain_port, extra):
    return [RV.PY, "-m", "tools.brain_review.teacher_proxy", "--session", token, "--capture-dir", str(cap),
            "--port", str(port), "--brain-port", str(brain_port), "--default-mode", "TEACHER", "--initial-stub"] + extra


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", default="")
    ap.add_argument("--manual", action="store_true")
    ap.add_argument("--per-model", type=int, default=2)
    ap.add_argument("--adapter", default=str(ADAPTER))
    ap.add_argument("--turn-cap", type=int, default=60)
    ap.add_argument("--seed0", type=int, default=9800000)
    ap.add_argument("--slot", type=int, default=1)
    ap.add_argument("--red-port", type=int, default=8121)
    ap.add_argument("--red-brain-port", type=int, default=8131)
    ap.add_argument("--blue-port0", type=int, default=8150)
    ap.add_argument("--cloud-timeout", type=int, default=600)
    ap.add_argument("--local-model", default="strata", help="model name sent to a local: BLUE server")
    ap.add_argument("--local-max-tokens", type=int, default=12000)
    ap.add_argument("--local-think", action="store_true", help="let a local: BLUE model think (default: thinking off)")
    ap.add_argument("--cmd-url", default="", help="RED commander URL the game calls (default: the RED proxy); e.g. a prompt shim")
    ap.add_argument("--out", default=str(OUT))
    a = ap.parse_args()
    run = Path(a.out)
    run.mkdir(parents=True, exist_ok=True)
    L.VLLM_SCRIPT = "run_vllm_q35_64k_fp8.sh"
    L.RUN = run
    lock = threading.Lock()

    def log(m):
        line = time.strftime("%m-%d %H:%M:%S ") + m
        with lock:
            print(line, flush=True)
            with open(run / "spar.log", "a", encoding="utf-8") as fh:
                fh.write(line + "\n")

    models = ["MANUAL"] if a.manual else [m for m in a.models.split(",") if m]
    jobs = []  # (model, k, seed)
    for mi, m in enumerate(models):
        for k in range(a.per_model):
            jobs.append((m, k, a.seed0 + mi * 100 + k))
    up = False
    try:
        import urllib.request
        with urllib.request.urlopen(L.VLLM_URL + "/v1/models", timeout=5) as r:
            up = "policy" in [x["id"] for x in json.loads(r.read())["data"]]
    except Exception:  # noqa: BLE001
        up = False
    if not up:
        L.vllm_stop(log)
        L.vllm_start(Path(a.adapter), log)
    L.probe(log, 0, True)
    hands = Hands(a.slot, run, log, "cpu")
    hands.start()
    token = secrets.token_hex(8)
    procs = []
    red_cap = run / "captures" / "red"
    red_cap.mkdir(parents=True, exist_ok=True)
    procs.append(subprocess.Popen(
        proxy_cmd(token, red_cap, a.red_port, a.red_brain_port,
                  ["--local-url", L.VLLM_URL + "/v1/chat/completions", "--local-model", "policy",
                   "--local-answer-tokens", "2000", "--local-think-budget", "0", "--local-max-tokens", "12000",
                   "--local-top-k", "0", "--local-presence-penalty", "0", "--local-no-think"]),
        cwd=str(ROOT), stdout=open(red_cap / "proxy.log", "a"), stderr=subprocess.STDOUT))
    blue_port = {}
    for i, m in enumerate(models):
        port = a.blue_port0 + i
        blue_port[m] = port
        cap = run / "captures" / ("blue_%d" % i)
        cap.mkdir(parents=True, exist_ok=True)
        if m == "MANUAL":
            extra = ["--manual-dir", str(run / "manual")]
        elif m.startswith("local:"):  # an OpenAI-compatible server, e.g. Strata: local:http://127.0.0.1:8080/v1/chat/completions
            extra = ["--local-url", m[6:], "--local-model", a.local_model, "--local-answer-tokens", "2000",
                     "--local-think-budget", "0", "--local-max-tokens", str(a.local_max_tokens), "--local-top-k", "0",
                     "--local-presence-penalty", "0", "--local-pass"] + ([] if a.local_think else ["--local-no-think"])
        else:
            extra = ["--cloud-model", m, "--cloud-timeout", str(a.cloud_timeout), "--cloud-pass"]
        procs.append(subprocess.Popen(proxy_cmd(token, cap, port, port + 1000, extra), cwd=str(ROOT),
                                      stdout=open(cap / "proxy.log", "a"), stderr=subprocess.STDOUT))
    for p in [a.red_port] + list(blue_port.values()):
        if not wait_port(p, token, 180):
            raise SystemExit("proxy %d did not come up" % p)
    qs = {m: queue.Queue() for m in models}
    for j in jobs:
        qs[j[0]].put(j)
    arenas = []
    base_env = {"LAYA_URL": hands.url, "BRAIN_CONTRACT_MODE": "unalloc_v1", "SELFPLAY_GENERAL_TIMEOUT_SEC": __import__("os").environ.get("GAME_TIMEOUT_S", "7200"),
                "WATCH_STRATEGIC_REPLAN_TURNS": "0", "WATCH_RED_MODE": "COMMANDER", "WATCH_BLUE_MODE": "COMMANDER",
                "WATCH_CMD_FACTS": "1", "FIELD_FORTIFY": "1", "WATCH_ROUT_MIN": "17", "WATCH_NO_HQ_WIN": "0",
                "WATCH_CMD_URL": a.cmd_url or "http://127.0.0.1:%d/v1/chat/completions" % a.red_port,
                "WATCH_BRAIN_PORT": str(a.red_port)}
    results = run / "games.jsonl"

    def worker(i, ar, mdl):
        win = "w%d" % (10 + 10 * a.slot + i)
        while True:
            try:
                m, k, seed = qs[mdl].get_nowait()
            except queue.Empty:
                return
            tag = "%s_s%d" % (m.replace("/", "_").replace(":", "_"), seed)
            job = {"family": FAMILY[seed % 4], "seed": seed, "tier": "BASIC", "style": "BULWARK",
                   "turn_cap": a.turn_cap, "session": token, "random_roster": False, "roster_sizes": ""}
            post(a.red_port, "/admin/tags", {win: tag})
            post(blue_port[m], "/admin/tags", {win: tag})
            o = run / "games" / ("%s.json" % tag)
            o.parent.mkdir(exist_ok=True)
            log("[SPAR] start %s" % tag)
            err = ar.play(job, o, int(__import__("os").environ.get("GAME_TIMEOUT_S", "7200")))
            res = json.loads(o.read_text(encoding="utf-8")) if o.exists() else {"error": err or "no result"}
            row = {"model": m, "seed": seed, "outcome": res.get("outcome"), "win_rule": res.get("win_rule"),
                   "turn": res.get("turn"), "units": res.get("units"), "hq": res.get("hq"), "error": res.get("error")}
            with lock:
                with open(results, "a", encoding="utf-8") as fh:
                    fh.write(json.dumps(row) + "\n")
            log("[SPAR] %s -> %s turn=%s win_rule=%s units=%s hq=%s" % (
                tag, row["outcome"], row["turn"], row["win_rule"], row["units"], row["hq"]))

    try:
        owners = []
        for m in models:  # the BLUE endpoint is an environment variable of the game process: one arena per game of a model
            for _ in range(min(qs[m].qsize(), 8 // max(1, len(models)) or 1)):
                owners.append(m)
        for i, m in enumerate(owners):
            env = dict(base_env, WATCH_CMD_URL_BLUE="http://127.0.0.1:%d/v1/chat/completions" % blue_port[m])
            arenas.append(RV.Arena(log, 10 + 10 * a.slot + i, env, None, headless=True))
        threads = [threading.Thread(target=worker, args=(i, ar, owners[i]), daemon=True) for i, ar in enumerate(arenas)]
        for t in threads:
            t.start()
            time.sleep(3)
        for t in threads:
            t.join()
    finally:
        for p in [a.red_port] + list(blue_port.values()):
            try:
                post(p, "/admin/shutdown", {})
            except Exception:  # noqa: BLE001
                pass
        for pr in procs:
            try:
                pr.wait(timeout=30)
            except Exception:  # noqa: BLE001
                pr.kill()
        for ar in arenas:
            ar.quit()
        hands.stop()
        log("[SPAR] stopped")


if __name__ == "__main__":
    main()
