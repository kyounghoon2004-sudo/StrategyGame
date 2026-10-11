"""Seed grind (2026-10-11, user): overfit RL on ONE failed game at a time to harvest the 9B's own winning games.

For each failed seed (same map, roster, GX style/family): GROUP games of the SAME job are played at once with the
current adapter; reward = rl_vs_utility.score (kills + mission accomplished), group-relative advantage, one QLoRA GRPO
step (loop.py machinery), repeat until the seed has been WON `--wins-needed` times (or `--max-iters`).  Every winning
game's accepted commander calls (messages + exact completion) are harvested as SFT rows -> `harvest/sft_rows_wins.json`.
The tuned adapter is NOT kept: each seed starts again from the init adapter.  Collapse mission (70%) with --collapse.
Stop: create <out>/STOP (finishes the current iteration).

  python -m tools.cmd_rl.seed_grind --out artifacts/brain_pipeline_v1/seed_grind_v1 --seeds <out>/seeds.json \
      --adapter <init adapter> --collapse --no-think --turn-cap 60 --slot 0 --proxy-port 8120 --brain-port 8130
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


def won_calls(cap: Path, tag: str):
    """All accepted commander calls of one game, in turn order (messages + exact completion)."""
    rows = []
    f = cap / "calls.jsonl"
    if f.exists():
        for line in f.read_text(encoding="utf-8").splitlines():
            r = json.loads(line)
            if r.get("tag") == tag and r.get("request") == "VICTORY_COMMAND" and r.get("raw") \
                    and (r.get("local") or {}).get("completion"):
                rows.append({"messages": r["messages"], "completion": r["local"]["completion"],
                             "turn": int(r.get("turn") or 0)})
    return sorted(rows, key=lambda x: x["turn"])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--seeds", required=True, help="json list of jobs: {seed, tier, style, family, army}")
    ap.add_argument("--adapter", required=True, help="init adapter (WSL-visible Windows path), reset for every seed")
    ap.add_argument("--windows", type=int, default=8)
    ap.add_argument("--group", type=int, default=8, help="games of the same seed per iteration")
    ap.add_argument("--wins-needed", type=int, default=2)
    ap.add_argument("--max-iters", type=int, default=10, help="iterations per seed")
    ap.add_argument("--collapse", action="store_true", help="enemy-collapse mission (remaining30_hq_guard)")
    ap.add_argument("--no-think", action="store_true")
    ap.add_argument("--turn-cap", type=int, default=60)
    ap.add_argument("--slot", type=int, default=0)
    ap.add_argument("--proxy-port", type=int, default=8120)
    ap.add_argument("--brain-port", type=int, default=8130)
    ap.add_argument("--answer-tokens", type=int, default=2000)
    ap.add_argument("--max-tokens", type=int, default=12000)
    ap.add_argument("--think-budget", type=int, default=0)
    ap.add_argument("--vllm-script", default="run_vllm_q35_64k_fp8.sh")
    ap.add_argument("--max-calls", type=int, default=8, help="calls per game that carry the advantage in the GRPO step")
    ap.add_argument("--only-seed", type=int, default=0)
    ap.add_argument("--keep-all", action="store_true",
                    help="GRPO with negative advantages too (default: survival of the fittest, only games above the group mean "
                         "carry weight)")
    a = ap.parse_args()

    L.VLLM_SCRIPT = a.vllm_script
    L.RUN = RUN = Path(a.out)
    L.MAX_CALLS_PER_GAME = a.max_calls
    RUN.mkdir(parents=True, exist_ok=True)
    (RUN / "harvest").mkdir(exist_ok=True)
    lock = threading.Lock()

    def log(m):
        line = time.strftime("%m-%d %H:%M:%S ") + m
        with lock:
            print(line, flush=True)
            with open(RUN / "grind.log", "a", encoding="utf-8") as f:
                f.write(line + "\n")

    seeds = json.loads(Path(a.seeds).read_text(encoding="utf-8"))
    if a.only_seed:
        seeds = [s for s in seeds if s["seed"] == a.only_seed]
    sf = RUN / "state.json"
    state = json.loads(sf.read_text(encoding="utf-8")) if sf.exists() else {"seeds": {}, "iter": 0}
    hf = RUN / "harvest" / "sft_rows_wins.json"
    harvest = json.loads(hf.read_text(encoding="utf-8")) if hf.exists() else []

    env = {"LAYA_URL": None, "BRAIN_CONTRACT_MODE": "unalloc_v1", "SELFPLAY_GENERAL_TIMEOUT_SEC": "1800",
           "WATCH_STRATEGIC_REPLAN_TURNS": "0", "WATCH_RED_MODE": "COMMANDER", "WATCH_BLUE_MODE": "GX",
           "WATCH_CMD_FACTS": "1", "FIELD_FORTIFY": "1",
           "WATCH_CMD_URL": "http://127.0.0.1:%d/v1/chat/completions" % a.proxy_port,
           "WATCH_BRAIN_PORT": str(a.proxy_port),
           "WATCH_ROUT_MIN": "0" if a.collapse else "17", "WATCH_NO_HQ_WIN": "1" if a.collapse else "0"}
    if a.collapse:
        env["WATCH_MISSION"] = "remaining30_hq_guard"
    RV._selfcheck()
    hands = [Hands(a.slot, RUN, log, "cpu")]
    hands[0].start()
    env["LAYA_URL"] = hands[0].url
    arenas = [RV.Arena(log, 10 + 10 * a.slot + i, dict(env), None, headless=True) for i in range(a.windows)]
    loaded = None
    try:
        for job0 in seeds:
            sk = str(job0["seed"])
            st = state["seeds"].setdefault(sk, {"wins": 0, "iters": 0, "best_kill": 0.0, "done": False})
            if st["done"]:
                continue
            adapter = Path(a.adapter)
            log("[GRIND] seed %s style=%s family=%s army=%s from %s" % (sk, job0["style"], job0["family"],
                                                                      job0.get("army"), adapter.name))
            while st["wins"] < a.wins_needed and st["iters"] < a.max_iters:
                if (RUN / "STOP").exists():
                    log("[GRIND] STOP file; exiting")
                    return
                it = st["iters"] + 1
                itdir = RUN / "seeds" / sk / ("it%02d" % it)
                cap = itdir / "captures"
                cap.mkdir(parents=True, exist_ok=True)
                if loaded != str(adapter):  # a seed that won at the first iteration leaves the init adapter loaded: keep vLLM up
                    L.vllm_stop(log)
                    L.vllm_start(adapter, log)
                    loaded = str(adapter)
                L.probe(log, a.think_budget, a.no_think)
                token = secrets.token_hex(8)
                proxy = subprocess.Popen(
                    [RV.PY, "-m", "tools.brain_review.teacher_proxy", "--session", token, "--capture-dir", str(cap),
                     "--port", str(a.proxy_port), "--brain-port", str(a.brain_port), "--default-mode", "TEACHER",
                     "--initial-stub", "--local-url", L.VLLM_URL + "/v1/chat/completions", "--local-model", "policy",
                     "--local-answer-tokens", str(a.answer_tokens), "--local-think-budget", str(a.think_budget),
                     "--local-max-tokens", str(a.max_tokens), "--local-top-k", "0", "--local-presence-penalty", "0"]
                    + (["--local-no-think"] if a.no_think else []),
                    cwd=str(ROOT), stdout=open(cap / "proxy.log", "a"), stderr=subprocess.STDOUT)
                if not wait_port(a.proxy_port, token, 180):
                    raise SystemExit("teacher proxy did not come up")
                army = job0.get("army")
                job = {"family": job0["family"], "seed": job0["seed"], "tier": job0["tier"], "style": job0["style"],
                       "turn_cap": a.turn_cap, "session": token, "random_roster": bool(army),
                       "roster_sizes": "%d-%d" % (army, army) if army else ""}
                q = queue.Queue()
                for j in range(a.group):
                    q.put("s%s_it%02d_r%d" % (sk, it, j))
                results = {}

                def worker(i, ar):
                    win = "w%d" % (10 + 10 * a.slot + i)
                    while True:
                        try:
                            tag = q.get_nowait()
                        except queue.Empty:
                            return
                        post(a.proxy_port, "/admin/tags", {win: tag})
                        o = itdir / "games" / ("%s.json" % tag)
                        o.parent.mkdir(exist_ok=True)
                        err = ar.play(job, o, 7200)
                        res = json.loads(o.read_text(encoding="utf-8")) if o.exists() else {"error": err or "no result"}
                        bad = "error" in res or res.get("outcome") in ("ABORTED", "TIMEOUT")
                        s = {"reward": None, "win": False, "kind": "ERROR"} if bad else RV.score(res)
                        with lock:
                            results[tag] = (s, res)
                        u = (res.get("units") or {})
                        log("[GRIND] %s -> %s r=%s turn=%s red=%s blue=%s" % (
                            tag, s["kind"], s["reward"], res.get("turn"), (u.get("red") or {}).get("alive"),
                            (u.get("blue") or {}).get("alive")))

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
                # harvest the wins
                n_win = 0
                for tag, (s, res) in results.items():
                    if s["win"]:
                        rows = won_calls(cap, tag)
                        if rows:
                            n_win += 1
                            for r in rows:
                                harvest.append({"messages": r["messages"], "completion": r["completion"],
                                                "game": tag, "turn": r["turn"],
                                                "mission": "collapse70" if a.collapse else "hq",
                                                "seed": job0["seed"], "source": "9b_seed_grind"})
                hf.write_text(json.dumps(harvest), encoding="utf-8")
                st["wins"] += n_win
                st["iters"] = it
                valid = [(s, res) for s, res in results.values() if s["kind"] != "ERROR"]
                for s, res in valid:
                    u = (res.get("units") or {}).get("blue") or {}
                    if u.get("start"):
                        st["best_kill"] = max(st["best_kill"], round(1 - int(u.get("alive", 0)) / int(u["start"]), 3))
                state["iter"] += 1
                sf.write_text(json.dumps(state, indent=1), encoding="utf-8")
                log("[GRIND] seed %s it%d: wins %d/%d (total %d) best_kill=%s" % (
                    sk, it, n_win, len(valid), st["wins"], st["best_kill"]))
                if st["wins"] >= a.wins_needed or it >= a.max_iters:
                    break
                # GRPO step on this seed's group
                items = []
                for tag, (s, res) in results.items():
                    if s["kind"] == "ERROR":
                        continue
                    calls = L.game_calls(cap, tag)
                    if calls or s["kind"] == "INVALID":
                        items.append((s, calls))
                if len(items) < 2:
                    continue
                adv = RV.advantages([s["reward"] for s, _ in items])
                if not any(abs(x) > 1e-9 for x in adv):
                    log("[GRIND] no reward spread; skip train")
                    continue
                groups = [{"group": 0, "rewards": [s["reward"] for s, _ in items],
                           "items": [{**c, "adv": x} for (_, calls), x in zip(items, adv) for c in calls
                                     if a.keep_all or x > 0]}]
                if not groups[0]["items"]:
                    continue
                L.vllm_stop(log)
                loaded = None
                (itdir / "samples.json").write_text(json.dumps(groups), encoding="utf-8")
                new = RUN / "seeds" / sk / "adapters" / ("a%02d" % it)
                log("[GRIND] seed %s it%d TRAIN %d calls" % (sk, it, len(groups[0]["items"])))
                with open(itdir / "train.log", "w", encoding="utf-8") as tl:
                    r = subprocess.run(L.WSL + ["bash", L.wsl_path(ROOT / "tools" / "cmd_rl" / "wsl_run.sh"), "train",
                                                "--adapter", L.wsl_path(adapter), "--samples",
                                                L.wsl_path(itdir / "samples.json"), "--out", L.wsl_path(new)],
                                       stdout=tl, stderr=subprocess.STDOUT)
                if r.returncode != 0 or not (new / "adapter_model.safetensors").exists():
                    log("[GRIND] train failed rc=%s (see %s); next iteration reuses the same adapter" % (
                        r.returncode, itdir / "train.log"))
                    continue
                adapter = new
            st["done"] = True
            sf.write_text(json.dumps(state, indent=1), encoding="utf-8")
            log("[GRIND] seed %s finished: wins=%d iters=%d" % (sk, st["wins"], st["iters"]))
    finally:
        for ar in arenas:
            ar.quit()
        for h in hands:
            h.stop()
        L.vllm_stop(log)
        log("[GRIND] stopped")


if __name__ == "__main__":
    main()
