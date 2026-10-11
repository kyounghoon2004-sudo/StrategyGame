"""CLOUD LADDER (2026-10-04): can the fixed Hands beat GX at all when a strong cloud model is the Brain?

The cloud model (via the teacher proxy's --cloud-model) writes the opening plan and a strategic replan every N
turns; per-turn reviews are the deterministic REVIEW TEACHER v3 (speed). Stages STATIC -> PASSIVE -> BASIC ->
INTER -> ADV, unit stats fixed. Each stage plays --games games on a job queue over N headless windows and K Hand
workers; the next stage starts only if the stage win rate >= --pass-rate, else it stops and writes the failure
(a genuine fail = possible architecture problem). Every plan, game and result is kept for distillation.

  python -m tools.plan_search.cloud_ladder --out <dir> [--windows 6 --hands 2 --games 12 --replan-turns 10]
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
from tools.plan_search.cloud_brain import MODEL
from tools.plan_search.eval_plans import Hands, PROXY_PORT, DUMMY_BRAIN_PORT

STYLES = ["SPEARHEAD", "BULWARK", "OUTRIDER", "HARRIER"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--stages", default="STATIC,PASSIVE,BASIC,INTER,ADV")
    ap.add_argument("--games", type=int, default=12, help="games per stage")
    ap.add_argument("--pass-rate", type=float, default=0.5)
    ap.add_argument("--replan-turns", type=int, default=10)
    ap.add_argument("--turn-cap", type=int, default=80)
    ap.add_argument("--windows", type=int, default=6)
    ap.add_argument("--hands", type=int, default=2)
    ap.add_argument("--model", default=MODEL)
    ap.add_argument("--variant", default="")
    ap.add_argument("--visible", action="store_true")
    ap.add_argument("--manual-dir", default="", help="diagnosis: answer every Brain request by hand")
    ap.add_argument("--commander", action="store_true", help="COMMANDER v1: Brain orders units directly (no Hands)")
    ap.add_argument("--cmd-every", type=int, default=5, help="commander: Brain asked every N turns (+ stale orders)")
    ap.add_argument("--local-url", default="", help="commander Brain = local vLLM endpoint instead of the cloud")
    ap.add_argument("--local-model", default="q38")
    ap.add_argument("--cycle", action="store_true", help="repeat the stages forever (never stop on a low win rate) until <out>/STOP exists")
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    lock = threading.Lock()

    def log(m):
        line = time.strftime("%H:%M:%S ") + m
        with lock:
            print(line, flush=True)
            with open(out / "ladder.log", "a", encoding="utf-8") as f:
                f.write(line + "\n")

    res_path = out / "results.jsonl"
    headless_flag = RV.OUT / "HEADLESS"
    if not a.visible:
        headless_flag.write_text("cloud_ladder", encoding="utf-8")
    token = secrets.token_hex(8)
    (out / "raw").mkdir(exist_ok=True)
    proxy = subprocess.Popen([RV.PY, "-m", "tools.brain_review.teacher_proxy", "--session", token,
                              "--capture-dir", str(out / "raw"), "--port", str(PROXY_PORT),
                              "--brain-port", str(DUMMY_BRAIN_PORT), "--default-mode", "TEACHER",
                              "--cloud-model", "" if (a.manual_dir or a.local_url) else a.model, "--cloud-variant", a.variant,
                              "--manual-dir", a.manual_dir, "--local-url", a.local_url, "--local-model", a.local_model],
                             cwd=str(RV.ROOT), stdout=open(out / "raw" / "proxy.log", "a"), stderr=subprocess.STDOUT)
    # COMMANDER mode never uses the Hands; one CPU worker only satisfies the mount's boot check (no VRAM)
    hands = [Hands(i, out, log, "cpu" if a.commander else "cuda") for i in range(a.hands)]
    arenas = []
    try:
        if not wait_port(PROXY_PORT, token, 180):
            raise SystemExit("teacher proxy did not come up")
        for h in hands:
            h.start()
        for i in range(a.windows):
            env = {"LAYA_URL": hands[i % a.hands].url, "BRAIN_CONTRACT_MODE": "unalloc_v1",
                   "SELFPLAY_GENERAL_TIMEOUT_SEC": "36000" if a.manual_dir else "900", "WATCH_STRATEGIC_REPLAN_TURNS": str(a.replan_turns)}
            if a.commander:
                env["WATCH_RED_MODE"] = "COMMANDER"
                env["WATCH_CMD_EVERY"] = str(a.cmd_every)
            geom = RV.WINDOW_GEOMS[i] if (a.visible and i < len(RV.WINDOW_GEOMS)) else None
            arenas.append(RV.Arena(log, 10 + i, env, geom))
        stage_list = a.stages.split(",")
        cyc = 0
        while True:
          for si, stage in enumerate(stage_list):
            if (out / "STOP").exists():
                log("[LADDER] STOP file present; exiting")
                return
            jobs = queue.Queue()
            for k in range(a.games):
                if a.cycle:
                    jobs.put(("c%03d_%s_%s_g%02d" % (cyc, stage, STYLES[k % 4], k), stage, STYLES[k % 4],
                              600000 + cyc * 1000 + si * 100 + k))
                else:
                    jobs.put(("%s_%s_g%02d" % (stage, STYLES[k % 4], k), stage, STYLES[k % 4], 500000 + si * 100 + k))
            rows = []
            log("[LADDER] stage %s: %d games, %d windows" % (stage, a.games, a.windows))

            def worker(i, ar):
                win = "w%d" % (10 + i)
                while True:
                    try:
                        game, tier, style, seed = jobs.get_nowait()
                    except queue.Empty:
                        return
                    post(PROXY_PORT, "/admin/tags", {win: game})
                    job = {"family": "fixed", "seed": seed, "tier": tier, "style": style,
                           "turn_cap": a.turn_cap, "session": token}
                    o = out / "games" / ("%s.json" % game)
                    o.parent.mkdir(exist_ok=True)
                    t0 = time.time()
                    err = ar.play(job, o, 36000 if a.manual_dir else 7200)
                    res = json.loads(o.read_text(encoding="utf-8")) if o.exists() else {"error": err or "no result"}
                    s = RV.score(res) if "error" not in res else {"kind": "ERROR", "reward": None, "win": False}
                    row = {"game": game, "stage": tier, "style": style, "seed": seed, **s,
                           "outcome": res.get("outcome"), "turn": res.get("turn"), "units": res.get("units"),
                           "hq": res.get("hq"), "red_actions": res.get("red_actions"), "brain": res.get("brain"),
                           "fault": res.get("strict_fault"), "error": res.get("error"), "wall_s": round(time.time() - t0)}
                    with lock:
                        rows.append(row)
                        with open(res_path, "a", encoding="utf-8") as f:
                            f.write(json.dumps(row, ensure_ascii=False) + "\n")
                    log("[LADDER] %s -> %s r=%s turn=%s blue_hq=%s fault=%s wall=%ds" % (
                        game, s.get("kind"), s.get("reward"), res.get("turn"),
                        ((res.get("hq") or {}).get("blue") or {}).get("end"),
                        (res.get("strict_fault") or {}).get("code"), row["wall_s"]))

            threads = [threading.Thread(target=worker, args=(i, ar), daemon=True) for i, ar in enumerate(arenas)]
            for t in threads:
                t.start()
                time.sleep(3)
            for t in threads:
                t.join()
            wins = sum(1 for r in rows if r.get("win"))
            invalid = sum(1 for r in rows if r.get("kind") == "INVALID")
            rate = wins / max(1, len(rows))
            summary = {"cycle": cyc, "stage": stage, "games": len(rows), "wins": wins, "invalid": invalid,
                       "win_rate": round(rate, 3)}
            with open(out / "stages.jsonl", "a", encoding="utf-8") as f:
                f.write(json.dumps(summary) + "\n")
            log("[LADDER] STAGE %s DONE %s" % (stage, summary))
            if rate < a.pass_rate and not a.cycle:
                log("[LADDER] STOP: %s win rate %.2f < %.2f -> genuine fail, report" % (stage, rate, a.pass_rate))
                return
          if not a.cycle:
              break
          cyc += 1
    finally:
        for ar in arenas:
            ar.quit()
        for h in hands:
            h.stop()
        try:
            post(PROXY_PORT, "/admin/shutdown", {})
        except Exception:  # noqa: BLE001
            pass
        try:
            proxy.wait(timeout=60)
        except Exception:  # noqa: BLE001
            proxy.kill()
        headless_flag.unlink(missing_ok=True)
        log("[LADDER] stopped")


if __name__ == "__main__":
    main()
