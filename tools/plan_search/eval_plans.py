"""PLAN SEARCH step 3 — the game decides which candidate opening plan is good (2026-10-04).

Job queue, no groups: every (candidate x setting x repeat) is one game. N headless arena windows each pull the
next job; the teacher proxy serves that window's candidate as the opening plan and answers every review with the
deterministic REVIEW TEACHER v3 (identical for all candidates); strategic replanning is off. K frozen Hand A/B
workers (separate ports) share the windows round-robin. No Brain model, no vLLM. Scored with the RL reward.

  python -m tools.plan_search.eval_plans --candidates <c.jsonl> --validated <v.jsonl> --out <dir>
        [--windows 6] [--hands 2] [--repeats 3] [--settings PASSIVE:BULWARK,BASIC:SPEARHEAD] [--turn-cap 80]
"""
from __future__ import annotations

import argparse
import itertools
import json
import os
import queue
import secrets
import subprocess
import threading
import time
import urllib.request
from pathlib import Path

from tools.brain_review.harvest import post, wait_port
from tools.contextual_brain import rl_vs_utility as RV

PROXY_PORT, DUMMY_BRAIN_PORT = 8096, 8106
HANDS_PORT0 = 11460
SEED0 = 400000  # plan-search seed range (RL 100000+, harvest 200000+, sealed 300000+ untouched)


class Hands:
    """One frozen Hand A/B worker on its own port."""

    def __init__(self, i, out: Path, log, device: str = "cuda"):
        self.port = HANDS_PORT0 + i
        self.url = "http://127.0.0.1:%d" % self.port
        self.dir = out / ("hands_%d" % i)
        self.dir.mkdir(parents=True, exist_ok=True)
        self.log, self.proc, self.device = log, None, device

    def healthy(self):
        try:
            with urllib.request.urlopen(self.url + "/health", timeout=3) as r:
                return json.loads(r.read().decode("utf-8")).get("ok", False) is not False
        except Exception:  # noqa: BLE001
            return False

    def start(self):
        self.proc = subprocess.Popen([RV.LAYA_PY, "-u", str(RV.ROOT / "tools" / "cloud_pipeline" / "hands_worker.py"),
                                      "--host", "127.0.0.1", "--port", str(self.port), "--device", self.device,
                                      "--parent-pid", str(os.getpid()), "--shutdown-token", secrets.token_hex(8),
                                      "--log-file", str(self.dir / "hands_worker.log")],
                                     stdout=open(self.dir / "stdout.log", "a"), stderr=subprocess.STDOUT)
        t0 = time.time()
        while not self.healthy():
            if time.time() - t0 > 300 or self.proc.poll() is not None:
                raise SystemExit("Hands worker %s did not come up" % self.url)
            time.sleep(2)
        self.log("[EVAL] Hands worker up %s" % self.url)

    def stop(self):
        if self.proc is not None and self.proc.poll() is None:
            self.proc.kill()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--candidates", required=True)
    ap.add_argument("--validated", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--settings", default="PASSIVE:BULWARK,PASSIVE:HARRIER,BASIC:SPEARHEAD,BASIC:OUTRIDER")
    ap.add_argument("--repeats", type=int, default=3)
    ap.add_argument("--turn-cap", type=int, default=80)
    ap.add_argument("--windows", type=int, default=6)
    ap.add_argument("--hands", type=int, default=2)
    ap.add_argument("--visible", action="store_true", help="show windows (default headless)")
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    lock = threading.Lock()

    def log(m):
        line = time.strftime("%H:%M:%S ") + m
        with lock:
            print(line, flush=True)
            with open(out / "eval.log", "a", encoding="utf-8") as f:
                f.write(line + "\n")

    ok = {r["id"] for r in map(json.loads, Path(a.validated).read_text(encoding="utf-8").splitlines()) if r.get("ok")}
    cands = [r for r in map(json.loads, Path(a.candidates).read_text(encoding="utf-8").splitlines()) if r["id"] in ok]
    settings = [tuple(s.split(":")) for s in a.settings.split(",")]
    res_path = out / "results.jsonl"
    done = set()
    if res_path.exists():
        for l in res_path.read_text(encoding="utf-8").splitlines():
            r = json.loads(l)
            if r.get("kind") != "ERROR":
                done.add(r["game"])
    jobs = queue.Queue()
    for rep, (si, (tier, style)), c in itertools.product(range(a.repeats), enumerate(settings), cands):
        game = "%s_%s_%s_r%d" % (c["id"], tier, style, rep)
        if game not in done:
            jobs.put((game, c, tier, style, SEED0 + si * 10 + rep))
    log("[EVAL] %d candidates x %d settings x %d repeats -> %d games to play, %d windows, %d Hands workers" % (
        len(cands), len(settings), a.repeats, jobs.qsize(), a.windows, a.hands))

    headless_flag = RV.OUT / "HEADLESS"
    if not a.visible:
        headless_flag.write_text("plan_search", encoding="utf-8")
    token = secrets.token_hex(8)
    (out / "raw").mkdir(exist_ok=True)
    proxy = subprocess.Popen([RV.PY, "-m", "tools.brain_review.teacher_proxy", "--session", token,
                              "--capture-dir", str(out / "raw"), "--port", str(PROXY_PORT),
                              "--brain-port", str(DUMMY_BRAIN_PORT), "--default-mode", "TEACHER"],
                             cwd=str(RV.ROOT), stdout=open(out / "raw" / "proxy.log", "a"), stderr=subprocess.STDOUT)
    hands = [Hands(i, out, log) for i in range(a.hands)]
    arenas = []
    try:
        if not wait_port(PROXY_PORT, token, 120):
            raise SystemExit("teacher proxy did not come up")
        for h in hands:
            h.start()
        for i in range(a.windows):
            env = {"LAYA_URL": hands[i % a.hands].url, "BRAIN_CONTRACT_MODE": "unalloc_v1",
                   "SELFPLAY_GENERAL_TIMEOUT_SEC": "900", "WATCH_STRATEGIC_REPLAN_TURNS": "0"}
            geom = RV.WINDOW_GEOMS[i] if (a.visible and i < len(RV.WINDOW_GEOMS)) else None
            arenas.append(RV.Arena(log, 10 + i, env, geom))  # arena_10.. : never collides with RL's arena_0..2

        def worker(i, ar):
            win = "w%d" % (10 + i)
            while True:
                try:
                    game, c, tier, style, seed = jobs.get_nowait()
                except queue.Empty:
                    return
                post(PROXY_PORT, "/admin/tags", {win: game})
                post(PROXY_PORT, "/admin/plans", {win: json.dumps(c["plan"], ensure_ascii=False)})
                job = {"family": "fixed", "seed": seed, "tier": tier, "style": style,
                       "turn_cap": a.turn_cap, "session": token}
                o = out / "games" / ("%s.json" % game)
                o.parent.mkdir(exist_ok=True)
                t0 = time.time()
                err = ar.play(job, o, 7200)
                res = json.loads(o.read_text(encoding="utf-8")) if o.exists() else {"error": err or "no result"}
                s = RV.score(res) if "error" not in res else {"kind": "ERROR", "reward": None, "win": False}
                row = {"game": game, "cand": c["id"], "name": c.get("name", ""), "tier": tier, "style": style,
                       "seed": seed, **s, "outcome": res.get("outcome"), "turn": res.get("turn"),
                       "units": res.get("units"), "hq": res.get("hq"), "red_actions": res.get("red_actions"),
                       "fault": (res.get("strict_fault") or {}).get("code"), "error": res.get("error"),
                       "wall_s": round(time.time() - t0)}
                with lock:
                    with open(res_path, "a", encoding="utf-8") as f:
                        f.write(json.dumps(row, ensure_ascii=False) + "\n")
                log("[EVAL] %s -> %s r=%s turn=%s blue_hq=%s wall=%ds" % (
                    game, s.get("kind"), s.get("reward"), res.get("turn"),
                    ((res.get("hq") or {}).get("blue") or {}).get("end"), row["wall_s"]))

        threads = [threading.Thread(target=worker, args=(i, ar), daemon=True) for i, ar in enumerate(arenas)]
        for i, t in enumerate(threads):
            t.start()
            time.sleep(3)
        for t in threads:
            t.join()
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
        log("[EVAL] stopped")


if __name__ == "__main__":
    main()
