"""COMMANDER RL (2026-10-05): Qwen3.5-9B Brain gives per-unit orders, GX executes; GRPO vs the GX Utility bot.

Per iteration
  ROLLOUT  vLLM (WSL) serves base + current LoRA as "policy"; N headless windows; each group = G windows playing the
           same job (stage, style, seed); budget-forced thinking (proxy --local-think-budget).
  SCORE    reward v3 (rl_vs_utility.score); group-relative advantage; every accepted Brain call of a game (capped,
           evenly spaced) carries that game's advantage.
  TRAIN    vLLM stopped -> WSL QLoRA step per group (tools/cmd_rl/train_wsl.py) -> new adapter -> next iteration.
  LADDER   STATIC -> PASSIVE -> BASIC -> INTER -> ADV; promote at 12 wins in the last 20 games.
Never plays and trains at the same time. Stop: create <out>/STOP (finishes the current iteration).
2026-10-08: the resident commander (one conversation per game, thinking off with --no-think), a random rule family
per group (--families) and random same-size armies (--roster-sizes, e.g. 3-50), its own slot (--slot: arenas, Hands
port; --proxy-port/--brain-port) and per-arena headless (no shared HEADLESS flag). Reward: rl_vs_utility.score (v2b).

  python -m tools.cmd_rl.loop [--windows 8 --group 4 --think-budget 3000]
"""
from __future__ import annotations

import argparse
import json
import queue
import random
import secrets
import subprocess
import threading
import time
import urllib.request
from pathlib import Path

from tools.brain_review.harvest import post, wait_port
from tools.contextual_brain import rl_vs_utility as RV
from tools.plan_search.eval_plans import Hands

ROOT = RV.ROOT
OUT = ROOT / "artifacts" / "brain_pipeline_v1" / "cmd_rl"
WSL = ["wsl.exe", "-d", "Ubuntu-24.04", "--"]
STAGES = ["STATIC", "PASSIVE", "BASIC", "INTER", "ADV"]
STYLES = ["SPEARHEAD", "BULWARK", "OUTRIDER", "HARRIER"]
PROMOTE_WINDOW, PROMOTE_WINS = 20, 12
DEMOTE_BELOW = 4  # user 2026-10-09: under 4 wins in the last 20 games at a stage -> demoted one stage
MAX_CALLS_PER_GAME = 12
VLLM_URL = "http://127.0.0.1:8000"
SEED0 = 700000  # commander RL seed range
VLLM_SCRIPT = "run_vllm_q35_32k_fp8.sh"
PROBE_PP = 0.0  # in cmd_rl/; --vllm-script overrides


def wsl_path(p: Path) -> str:
    s = str(p).replace("\\", "/")
    return "/mnt/" + s[0].lower() + s[2:]


def gpu_mib():
    try:
        return int(subprocess.run(["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits"],
                                  capture_output=True, text=True, timeout=20).stdout.strip().splitlines()[0])
    except Exception:  # noqa: BLE001
        return -1


def vllm_stop(log):
    subprocess.run(WSL + ["bash", wsl_path(OUT / "stop_vllm.sh")], capture_output=True, timeout=120)
    t0 = time.time()
    while gpu_mib() > 1500 and time.time() - t0 < 180:
        time.sleep(3)
    log(f"[CRL] vLLM stopped gpu={gpu_mib()}MiB")


def vllm_start(adapter: Path, log):
    subprocess.Popen(WSL + ["bash", wsl_path(OUT / VLLM_SCRIPT), wsl_path(adapter)],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, creationflags=0x08000000)
    t0 = time.time()
    while time.time() - t0 < 900:
        try:
            with urllib.request.urlopen(VLLM_URL + "/v1/models", timeout=5) as r:
                if "policy" in [m["id"] for m in json.loads(r.read())["data"]]:
                    log(f"[CRL] vLLM up adapter={adapter.name} ({round(time.time() - t0)}s) gpu={gpu_mib()}MiB")
                    return
        except Exception:  # noqa: BLE001
            pass
        time.sleep(5)
    raise SystemExit("vLLM did not come up (see cmd_rl/vllm.log)")


PROBE_CALLS = ROOT / "artifacts" / "brain_pipeline_v1" / "cmd_eval_q35_sft_v1" / "sft_v1" / "raw" / "calls.jsonl"


def probe(log, think_budget, no_think=False):
    """One real (resident) commander request must give parseable orders before any game counts."""
    from tools.plan_search.cloud_brain import local_command
    msgs = next(json.loads(l)["messages"] for l in PROBE_CALLS.read_text(encoding="utf-8").splitlines()
                if '"VICTORY_COMMAND"' in l)
    txt, meta = local_command(msgs, url=VLLM_URL + "/v1/chat/completions", model="policy", think_budget=think_budget,
                              top_k=20, presence_penalty=PROBE_PP,
                              no_think=no_think)
    log(f"[CRL] probe {'OK' if txt else 'FAILED'} {meta['attempts'][-1].get('s')}s")
    if not txt:
        raise SystemExit("policy probe failed: %r" % str(meta)[:400])


def game_calls(cap: Path, tag: str):
    """Accepted Brain calls of one game (messages + exact completion), evenly capped."""
    rows = []
    f = cap / "calls.jsonl"
    if f.exists():
        for line in f.read_text(encoding="utf-8").splitlines():
            r = json.loads(line)
            if r.get("tag") == tag and r.get("request") == "VICTORY_COMMAND" and r.get("raw") \
                    and (r.get("local") or {}).get("completion"):
                rows.append({"messages": r["messages"], "completion": r["local"]["completion"]})
    if len(rows) > MAX_CALLS_PER_GAME:
        rows = [rows[min(len(rows) - 1, round(i * len(rows) / MAX_CALLS_PER_GAME))] for i in range(MAX_CALLS_PER_GAME)]
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--iterations", type=int, default=10 ** 6)
    ap.add_argument("--windows", type=int, default=8)
    ap.add_argument("--group", type=int, default=4, help="games per GRPO group (same job)")
    ap.add_argument("--think-budget", type=int, default=3000)
    ap.add_argument("--slot", type=int, default=1, help="arenas 10+10*slot.., Hands port 11460+slot")
    ap.add_argument("--proxy-port", type=int, default=8097)
    ap.add_argument("--brain-port", type=int, default=8107)
    ap.add_argument("--families", default="fixed,mild,broad,counterfactual_valid", help="rule variation, one per group")
    ap.add_argument("--roster-sizes", default="", help="random same-size armies, e.g. 3-50 (units per side incl. HQ)")
    ap.add_argument("--answer-tokens", type=int, default=2000)
    ap.add_argument("--rout-min", type=int, default=17, help="units per side (HQ incl.) from which 60%% losses = defeat")
    ap.add_argument("--no-hq-win", action="store_true", help="test: destroying an HQ does not end the match (collapse only)")
    ap.add_argument("--turn-cap", type=int, default=80)
    ap.add_argument("--out", default="", help="run dir (default cmd_rl); vLLM scripts always come from cmd_rl")
    ap.add_argument("--adapter", default="", help="initial adapter (fresh state only)")
    ap.add_argument("--stage", default=STAGES[0], help="initial stage (fresh state only)")
    ap.add_argument("--floor-stage", default="BASIC", help="never demoted below this stage")
    ap.add_argument("--eval-only", action="store_true", help="play and score, never train or promote")
    ap.add_argument("--no-think", action="store_true", help="thinking OFF (SFT student)")
    ap.add_argument("--vllm-script", default="run_vllm_q35_32k_fp8.sh", help="launcher in cmd_rl/ (e.g. run_vllm_q38_policy.sh)")
    ap.add_argument("--seed0", type=int, default=SEED0)
    ap.add_argument("--visible", action="store_true", help="show the game windows (4 x 2 grid)")
    ap.add_argument("--facts", action="store_true", help="packet facts (distances/arrival turns) + timing prompt")
    ap.add_argument("--top-k", type=int, default=0)
    ap.add_argument("--presence-penalty", type=float, default=0.0)
    ap.add_argument("--max-tokens", type=int, default=12000, help="local Brain max tokens (think_budget 0 = unlimited thinking)")
    ap.add_argument("--external-server", action="store_true", help="policy server already running on :8000 (no vLLM start/stop)")
    ap.add_argument("--promote", action="store_true", help="eval-only: still climb the stage ladder")
    a = ap.parse_args()
    global RUN, VLLM_SCRIPT, PROBE_PP
    VLLM_SCRIPT = a.vllm_script
    PROBE_PP = a.presence_penalty
    RUN = Path(a.out) if a.out else OUT
    RUN.mkdir(parents=True, exist_ok=True)
    lock = threading.Lock()

    def log(m):
        line = time.strftime("%m-%d %H:%M:%S ") + m
        with lock:
            print(line, flush=True)
            with open(RUN / "rl.log", "a", encoding="utf-8") as f:
                f.write(line + "\n")

    sf = RUN / "state.json"
    state = json.loads(sf.read_text(encoding="utf-8")) if sf.exists() else \
        {"iteration": 0, "group": 0, "stage": a.stage, "adapter": a.adapter or str(OUT / "adapters" / "a0000"),
         "history": {s: [] for s in STAGES}, "promotions": []}
    RV._selfcheck()
    hands = [Hands(a.slot, RUN, log, "cpu")]  # commander never uses the Hands; satisfies the mount boot check only
    hands[0].start()
    arenas = [RV.Arena(log, 10 + 10 * a.slot + i,
                       {"LAYA_URL": hands[0].url, "BRAIN_CONTRACT_MODE": "unalloc_v1",
                        "SELFPLAY_GENERAL_TIMEOUT_SEC": "1800", "WATCH_STRATEGIC_REPLAN_TURNS": "0",
                        "WATCH_RED_MODE": "COMMANDER", "WATCH_BLUE_MODE": "GX", "WATCH_CMD_FACTS": "1",
                        "FIELD_FORTIFY": "1",
                        "WATCH_CMD_URL": "http://127.0.0.1:%d/v1/chat/completions" % a.proxy_port,
                        "WATCH_BRAIN_PORT": str(a.proxy_port), "WATCH_ROUT_MIN": str(a.rout_min),
                        "WATCH_NO_HQ_WIN": "1" if a.no_hq_win else "0"},
                       ((i % 4) * 640, 30 + (i // 4) * 760, 636, 700) if a.visible else None, headless=not a.visible)
              for i in range(a.windows)]
    n_groups = a.windows // a.group
    try:
        for _ in range(a.iterations):
            if (RUN / "STOP").exists():
                log("[CRL] STOP file present; exiting")
                break
            it = state["iteration"] + 1
            itdir = RUN / "iterations" / f"it{it:04d}"
            cap = itdir / "captures"
            cap.mkdir(parents=True, exist_ok=True)
            adapter = Path(state["adapter"])
            if not a.external_server:
                vllm_stop(log)
                vllm_start(adapter, log)
            probe(log, a.think_budget, a.no_think)
            token = secrets.token_hex(8)
            proxy = subprocess.Popen([RV.PY, "-m", "tools.brain_review.teacher_proxy", "--session", token,
                                      "--capture-dir", str(cap), "--port", str(a.proxy_port),
                                      "--brain-port", str(a.brain_port), "--default-mode", "TEACHER", "--initial-stub",
                                      "--local-url", VLLM_URL + "/v1/chat/completions", "--local-model", "policy",
                                      "--local-answer-tokens", str(a.answer_tokens),
                                      "--local-think-budget", str(a.think_budget), "--local-max-tokens", str(a.max_tokens),
                                      "--local-top-k", str(a.top_k), "--local-presence-penalty", str(a.presence_penalty)] + (["--local-no-think"] if a.no_think else []),
                                     cwd=str(ROOT), stdout=open(cap / "proxy.log", "a"), stderr=subprocess.STDOUT)
            if not wait_port(a.proxy_port, token, 180):
                raise SystemExit("teacher proxy did not come up")
            stage = state["stage"]
            rng = random.Random(f"crl:{it}")
            jobs = []
            for k in range(n_groups):
                g = state["group"] + k
                style = rng.choice(STYLES)
                job = {"family": rng.choice(a.families.split(",")), "seed": a.seed0 + g, "tier": stage,
                       "style": style, "turn_cap": a.turn_cap, "session": token,
                       "random_roster": bool(a.roster_sizes), "roster_sizes": a.roster_sizes}
                jobs += [(g, f"it{it:04d}_g{g:05d}_r{j}", job) for j in range(a.group)]
            state["group"] += n_groups
            log(f"[CRL] it{it} ROLLOUT stage={stage} adapter={adapter.name} groups={n_groups}x{a.group}")
            q = queue.Queue()
            for j in jobs:
                q.put(j)
            results = {}

            def worker(i, ar):
                win = f"w{10 + 10 * a.slot + i}"
                while True:
                    try:
                        g, tag, job = q.get_nowait()
                    except queue.Empty:
                        return
                    post(a.proxy_port, "/admin/tags", {win: tag})
                    o = itdir / "games" / f"{tag}.json"
                    o.parent.mkdir(exist_ok=True)
                    t0 = time.time()
                    err = ar.play(job, o, 7200)
                    res = json.loads(o.read_text(encoding="utf-8")) if o.exists() else {"error": err or "no result"}
                    bad = "error" in res or res.get("outcome") in ("ABORTED", "TIMEOUT")
                    s = {"reward": None, "win": False, "kind": "ERROR"} if bad else RV.score(res)
                    calls = [] if bad else game_calls(cap, tag)
                    row = {"iteration": it, "group": g, "tag": tag, "stage": job["tier"], "style": job["style"],
                           "family": job["family"], "army": ((res.get("units") or {}).get("red") or {}).get("start"),
                           "seed": job["seed"], **s, "outcome": res.get("outcome"), "turn": res.get("turn"),
                           "units": res.get("units"), "hq": res.get("hq"), "red_actions": res.get("red_actions"),
                           "fault": (res.get("strict_fault") or {}).get("code"), "calls_trained": len(calls),
                           "focus": s.get("focus"),
                           "adapter": adapter.name, "error": res.get("error"), "wall_s": round(time.time() - t0)}
                    with lock:
                        results[tag] = (g, s, calls)
                        with open(RUN / "games.jsonl", "a", encoding="utf-8") as f:
                            f.write(json.dumps(row) + "\n")
                    log(f"[CRL] {tag} {job['tier']}_{job['style']} -> {s['kind']} r={s['reward']} turn={res.get('turn')} "
                        f"red={((res.get('units') or {}).get('red') or {}).get('alive')} "
                        f"blue={((res.get('units') or {}).get('blue') or {}).get('alive')} "
                        f"blue_hq={((res.get('hq') or {}).get('blue') or {}).get('end')} fault={row['fault']} "
                        f"calls={len(calls)} wall={row['wall_s']}s")

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
            # ---- score groups
            groups = []
            for g in sorted({v[0] for v in results.values()}):
                items = [(s, calls) for (gg, s, calls) in results.values() if gg == g and s["kind"] != "ERROR"]
                for s, _ in items:
                    state["history"].setdefault(stage, []).append(bool(s["win"]))
                items = [(s, c) for s, c in items if c or s["kind"] == "INVALID"]
                if len(items) < 2:
                    continue
                adv = RV.advantages([s["reward"] for s, _ in items])
                if not any(abs(x) > 1e-9 for x in adv):
                    continue
                groups.append({"group": g, "rewards": [s["reward"] for s, _ in items],
                               "items": [{**c, "adv": x} for (_, calls), x in zip(items, adv) for c in calls]})
            groups = [gr for gr in groups if gr["items"]]
            hist = state["history"].setdefault(stage, [])
            if (not a.eval_only or a.promote) and len(hist) >= PROMOTE_WINDOW and sum(hist[-PROMOTE_WINDOW:]) >= PROMOTE_WINS and \
                    STAGES.index(stage) < len(STAGES) - 1:
                nxt = STAGES[STAGES.index(stage) + 1]
                state["promotions"].append({"from": stage, "to": nxt, "iteration": it, "adapter": adapter.name,
                                            "wins_last20": sum(hist[-PROMOTE_WINDOW:])})
                log(f"[CRL] PROMOTED {stage} -> {nxt} (wins {sum(hist[-PROMOTE_WINDOW:])}/{PROMOTE_WINDOW})")
                state["stage"] = nxt
                state["history"][nxt] = []  # a fresh 20-game window at the new stage (no stale games from earlier visits)
            elif (not a.eval_only or a.promote) and len(hist) >= PROMOTE_WINDOW and \
                    sum(hist[-PROMOTE_WINDOW:]) < DEMOTE_BELOW and STAGES.index(stage) > STAGES.index(a.floor_stage):
                # user 2026-10-09: fewer than DEMOTE_BELOW wins in the last 20 -> back down to learn to win more there
                prv = STAGES[STAGES.index(stage) - 1]
                state["promotions"].append({"from": stage, "to": prv, "iteration": it, "adapter": adapter.name,
                                            "wins_last20": sum(hist[-PROMOTE_WINDOW:]), "demoted": True})
                log(f"[CRL] DEMOTED {stage} -> {prv} (wins {sum(hist[-PROMOTE_WINDOW:])}/{PROMOTE_WINDOW})")
                state["stage"] = prv
                state["history"][prv] = []
            # ---- train (GPU free)
            upd = {"iteration": it, "stage": stage, "informative_groups": len(groups), "groups": n_groups}
            if a.eval_only:
                upd["skipped"] = "eval-only"
            elif groups:
                vllm_stop(log)
                (itdir / "samples.json").write_text(json.dumps(groups), encoding="utf-8")
                new = RUN / "adapters" / f"a{it:04d}"
                log(f"[CRL] it{it} TRAIN {len(groups)} groups, {sum(len(g['items']) for g in groups)} calls")
                with open(itdir / "train.log", "w", encoding="utf-8") as tl:
                    r = subprocess.run(WSL + ["bash", wsl_path(ROOT / "tools" / "cmd_rl" / "wsl_run.sh"), "train",
                                              "--adapter", wsl_path(adapter), "--samples", wsl_path(itdir / "samples.json"),
                                              "--out", wsl_path(new)], stdout=tl, stderr=subprocess.STDOUT)
                if r.returncode != 0 or not (new / "adapter_model.safetensors").exists():
                    raise SystemExit(f"train failed rc={r.returncode} (see {itdir / 'train.log'})")
                steps = json.loads((new / "TRAIN_STEPS.json").read_text(encoding="utf-8"))
                upd.update({"steps": steps["steps"], "train_s": steps["total_s"]})
                state["adapter"] = str(new)
            else:
                upd["skipped"] = "no informative group"
            with open(RUN / "updates.jsonl", "a", encoding="utf-8") as f:
                f.write(json.dumps(upd) + "\n")
            state["iteration"] = it
            sf.write_text(json.dumps(state, indent=1), encoding="utf-8")
            h = state["history"].get(state["stage"], [])
            log(f"[CRL] it{it} done: informative={len(groups)}/{n_groups} stage={state['stage']} "
                f"games_at_stage={len(h)} wins_last20={sum(h[-PROMOTE_WINDOW:])} train_s={upd.get('train_s')}")
    finally:
        for ar in arenas:
            ar.quit()
        for h in hands:
            h.stop()
        if not a.external_server:
            vllm_stop(log)  # never leave an idle engine holding the GPU
        log("[CRL] stopped")


if __name__ == "__main__":
    main()
