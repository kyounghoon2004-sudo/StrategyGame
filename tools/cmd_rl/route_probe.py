"""Route probe (2026-10-12, user): with BOTH win routes open (destroy the enemy HQ OR 70% of its other units), which one
does the 9B take, does it switch when one is hard, and does a one-line prompt steer move it?

Cells = GX tier x GX style (the opponent that makes a route easy or hard).  Variants of the prompt:
neutral | hq ("Route: win by destroying the BLUE HQ.") | collapse ("Route: win by destroying BLUE's units other than
the HQ.").  The same seeds are used in every variant (paired).  Per game: outcome, win_rule (hq | rout | ""), turn,
share of attack orders aimed at the enemy HQ, first turn an order targets the HQ, plan text of turn 1.

  python -m tools.cmd_rl.route_probe --variants neutral,hq,collapse --per-cell 4
"""
from __future__ import annotations

import argparse
import json
import queue
import re
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
OUT = ROOT / "artifacts" / "brain_pipeline_v1" / "route_probe_v1"
TIERS = ["BASIC", "INTER", "ADV"]
STYLES = ["BULWARK", "SPEARHEAD", "HARRIER", "OUTRIDER"]
FAMILY = ["fixed", "mild", "broad", "counterfactual_valid"]
ADAPTER = ROOT / "artifacts" / "brain_pipeline_v1" / "sft_mix_v3b" / "adapters" / "ckpt_step536"


def features(cap: Path, tag: str) -> dict:
    n_hq = n_all = 0
    first_hq = None
    plan1 = ""
    f = cap / "calls.jsonl"
    if f.exists():
        for line in f.read_text(encoding="utf-8").splitlines():
            r = json.loads(line)
            if r.get("tag") != tag or r.get("request") != "VICTORY_COMMAND":
                continue
            txt = (r.get("local") or {}).get("completion") or r.get("raw") or ""
            try:
                doc = json.loads(txt)
            except ValueError:
                continue
            t = int(r.get("turn") or 0)
            if t <= 1 and doc.get("plan"):
                plan1 = str(doc.get("plan"))[:400]
            for o in (doc.get("orders") or {}).values():
                if isinstance(o, dict) and str(o.get("do", "")).upper() in ("ATTACK", "RAID", "ASSAULT"):
                    tgt = str(o.get("target", "")).upper()
                    n_all += 1
                    if tgt == "ENEMY_HQ" or re.match(r"^B_HQ", tgt):
                        n_hq += 1
                        first_hq = t if first_hq is None else min(first_hq, t)
    return {"attack_orders": n_all, "hq_orders": n_hq, "hq_share": round(n_hq / n_all, 3) if n_all else None,
            "first_hq_turn": first_hq, "plan1": plan1}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--variants", default="neutral,hq,collapse")
    ap.add_argument("--per-cell", type=int, default=4)
    ap.add_argument("--windows", type=int, default=8)
    ap.add_argument("--adapter", default=str(ADAPTER))
    ap.add_argument("--turn-cap", type=int, default=60)
    ap.add_argument("--seed0", type=int, default=9700000)
    ap.add_argument("--slot", type=int, default=0)
    ap.add_argument("--proxy-port", type=int, default=8120)
    ap.add_argument("--brain-port", type=int, default=8130)
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
            with open(run / "probe.log", "a", encoding="utf-8") as fh:
                fh.write(line + "\n")

    done = set()
    rf = run / "games.jsonl"
    if rf.exists():
        for line in rf.read_text(encoding="utf-8").splitlines():
            r = json.loads(line)
            if r.get("kind") != "ERROR":
                done.add((r["variant"], r["tier"], r["style"], r["seed"]))
    L.vllm_stop(log)
    L.vllm_start(Path(a.adapter), log)
    L.probe(log, 0, True)
    hands = Hands(a.slot, run, log, "cpu")
    hands.start()
    cells = [(t, s) for t in TIERS for s in STYLES]
    try:
        for variant in a.variants.split(","):
            env = {"LAYA_URL": hands.url, "BRAIN_CONTRACT_MODE": "unalloc_v1", "SELFPLAY_GENERAL_TIMEOUT_SEC": "1800",
                   "WATCH_STRATEGIC_REPLAN_TURNS": "0", "WATCH_RED_MODE": "COMMANDER", "WATCH_BLUE_MODE": "GX",
                   "WATCH_CMD_FACTS": "1", "FIELD_FORTIFY": "1",
                   "WATCH_CMD_URL": "http://127.0.0.1:%d/v1/chat/completions" % a.proxy_port,
                   "WATCH_BRAIN_PORT": str(a.proxy_port), "WATCH_ROUT_MIN": "0", "WATCH_NO_HQ_WIN": "0",
                   "WATCH_ROUT_SHARE": "0.7", "WATCH_STEER": "" if variant == "neutral" else variant}
            arenas = [RV.Arena(log, 10 + 10 * a.slot + i, dict(env), None, headless=True) for i in range(a.windows)]
            cap = run / "captures" / variant
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
            q = queue.Queue()
            for ci, (tier, style) in enumerate(cells):
                for k in range(a.per_cell):
                    seed = a.seed0 + ci * 100 + k
                    if (variant, tier, style, seed) not in done:
                        q.put((tier, style, seed, k))
            log("[PROBE] variant=%s games=%d" % (variant, q.qsize()))

            def worker(i, ar):
                win = "w%d" % (10 + 10 * a.slot + i)
                while True:
                    try:
                        tier, style, seed, k = q.get_nowait()
                    except queue.Empty:
                        return
                    tag = "%s_%s_%s_s%d" % (variant, tier, style, seed)
                    job = {"family": FAMILY[seed % 4], "seed": seed, "tier": tier, "style": style,
                           "turn_cap": a.turn_cap, "session": token, "random_roster": False, "roster_sizes": ""}
                    post(a.proxy_port, "/admin/tags", {win: tag})
                    o = run / "games" / ("%s.json" % tag)
                    o.parent.mkdir(exist_ok=True)
                    err = ar.play(job, o, 7200)
                    res = json.loads(o.read_text(encoding="utf-8")) if o.exists() else {"error": err or "no result"}
                    bad = "error" in res or res.get("outcome") in ("ABORTED", "TIMEOUT") or (res.get("turn") or 0) <= 1
                    row = {"variant": variant, "tier": tier, "style": style, "seed": seed, "kind": "ERROR" if bad else "OK",
                           "outcome": res.get("outcome"), "win_rule": res.get("win_rule"), "turn": res.get("turn"),
                           "units": res.get("units"), "hq": res.get("hq")}
                    if not bad:
                        row.update(features(cap, tag))
                    with lock:
                        with open(rf, "a", encoding="utf-8") as fh:
                            fh.write(json.dumps(row) + "\n")
                    log("[PROBE] %s -> %s %s turn=%s win_rule=%s hq_share=%s" % (
                        tag, row["kind"], row["outcome"], row["turn"], row["win_rule"], row.get("hq_share")))

            threads = [threading.Thread(target=worker, args=(i, ar), daemon=True) for i, ar in enumerate(arenas)]
            for t in threads:
                t.start()
                time.sleep(3)
            for t in threads:
                t.join()
            try:
                post(a.proxy_port, "/admin/shutdown", {})
                proxy.wait(timeout=60)
            except Exception:  # noqa: BLE001
                proxy.kill()
            for ar in arenas:
                ar.quit()
    finally:
        hands.stop()
        L.vllm_stop(log)
        log("[PROBE] stopped")


if __name__ == "__main__":
    main()
