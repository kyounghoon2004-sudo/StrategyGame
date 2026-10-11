"""HARVEST — live sandbox games for the Brain review corpus (Phase 2).

Drives the EXISTING tooling only (tools/rl_arena.gd + tools/contextual_brain/
rl_vs_utility.py Arena / HandsService / debug_group pattern):
  * one frozen Hand A/B worker shared by all windows (HandsService),
  * N arena windows, one episode per group (same family/seed/tier/style),
  * the Brain (S0B) served by `rl_vs_utility serve --port 8106` (GPU-locked),
  * the game's RL_POLICY endpoint is the teacher proxy on 8096
    (tools/brain_review/teacher_proxy.py): VICTORY_INITIAL always reaches the
    Brain; VICTORY_REVIEW is answered by the deterministic REVIEW TEACHER
    (TEACHER mode) or forwarded to S0B (MODEL mode). Every review is labeled
    by the teacher in both modes.

Episode mix: families mild/broad alternate, GX tiers cycle BASIC/INTER/ADV,
styles rotate SPEARHEAD/BULWARK/OUTRIDER/HARRIER, seeds 200000+ (the sealed
300000+ and RL 100000+ ranges are never touched). Mode per window alternates
[TEACHER, TEACHER, MODEL] / [MODEL, MODEL, TEACHER] across groups (half the
games per mode). A group of 3 windows plays the same episode and GX seed.

Only the tools' own env knobs are used (BRAIN_CONTRACT_MODE=unalloc_v1,
BRAIN_CONTEXT_PACK=v0 via the watch driver, WATCH_STRICT_REVIEWS via the RL
job, SELFPLAY_GENERAL_TIMEOUT_SEC for slow-queue review waits).

  python -m tools.brain_review.harvest --groups 40 [--windows 3] [--resume]
"""
from __future__ import annotations

import argparse
import json
import os
import secrets
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(r"D:\Game development\Demon slayer\StrategyGame")
sys.path.insert(0, str(ROOT))

from tools.contextual_brain.rl_vs_utility import (  # noqa: E402
    Arena, HandsService, WINDOW_GEOMS, score, S0B, PY, FAMILIES, TIERS, STYLES)

OUT = ROOT / "artifacts" / "brain_pipeline_v1" / "review_corpus"
BRAIN_PORT = 8106
PROXY_PORT = 8096
STAGGER_S = 190          # >= 3 min between window starts (serial HF Brain)
PATTERNS = [["TEACHER", "TEACHER", "MODEL"], ["TEACHER", "TEACHER", "TEACHER"]]


def log(msg: str) -> None:
    line = "%s %s" % (time.strftime("%H:%M:%S"), msg)
    print(line, flush=True)
    with open(OUT / "harvest.log", "a", encoding="utf-8") as f:
        f.write(line + "\n")


def health(port: int, token: str):
    try:
        with urllib.request.urlopen("http://127.0.0.1:%d/health" % port, timeout=5) as r:
            h = json.loads(r.read())
            return h if h.get("rl_session") == token and h.get("ok") else None
    except Exception:  # noqa: BLE001
        return None


def post(port: int, path: str, obj):
    req = urllib.request.Request("http://127.0.0.1:%d%s" % (port, path),
                                 data=json.dumps(obj).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())


def wait_port(port: int, token: str, deadline_s: int = 300):
    t0 = time.time()
    while time.time() - t0 < deadline_s:
        if health(port, token):
            return True
        time.sleep(3)
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--groups", type=int, default=42, help="3-window groups (3 games each)")
    ap.add_argument("--windows", type=int, default=3)
    ap.add_argument("--turn-cap", type=int, default=30)
    ap.add_argument("--resume", action="store_true", help="skip groups already in games/index.jsonl")
    ap.add_argument("--backend", default="vllm", choices=["vllm", "hf"])
    ap.add_argument("--stagger", type=int, default=None)
    ap.add_argument("--out", default="", help="output dir (default: review_corpus)")
    ap.add_argument("--modes", default="", help="force a mode for every window, e.g. TEACHER")
    ap.add_argument("--group-offset", type=int, default=0, help="first group number (seeds 200000 + 7*g)")
    a = ap.parse_args()
    global OUT
    if a.out:
        OUT = Path(a.out)

    if a.stagger is None:
        a.stagger = 5 if a.backend == "vllm" else STAGGER_S

    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "games").mkdir(exist_ok=True)
    (OUT / "raw").mkdir(exist_ok=True)
    idx_path = OUT / "games" / "index.jsonl"
    done = set()
    if a.resume and idx_path.exists():
        for line in idx_path.read_text(encoding="utf-8").splitlines():
            if line.strip():
                row = json.loads(line)
                done.add(row["game_id"])
        log("[HARVEST] resume: %d games already done" % len(done))

    token = secrets.token_hex(8)
    # --- no engine from a previous run may linger (a dying engine answered /health and the new
    #     service skipped its own start -> every completion was refused, 2026-10-01)
    if a.backend == "vllm":
        from tools.brain_vllm import common as C0
        C0.engine_stop()
        t_stop = time.time()
        while C0.engine_up(timeout=2) and time.time() - t_stop < 120:
            time.sleep(3)
        if C0.engine_up(timeout=2):
            raise SystemExit("an old vLLM engine is still up; refusing to start")
    # --- Brain on 8106; teacher proxy on 8096 is the game's endpoint
    if a.backend == "vllm":
        brain = subprocess.Popen([PY, "-u", "-m", "tools.brain_vllm.service",
                                  "--adapter", str(S0B), "--session", token,
                                  "--capture-dir", str(OUT / "raw" / "brain"), "--port", str(BRAIN_PORT)],
                                 cwd=str(ROOT), stdout=open(OUT / "raw" / "brain_serve.log", "a"),
                                 stderr=subprocess.STDOUT)
    else:
        brain = subprocess.Popen([PY, "-m", "tools.contextual_brain.rl_vs_utility", "serve",
                                  "--adapter", str(S0B), "--session", token,
                                  "--capture-dir", str(OUT / "raw" / "brain"), "--port", str(BRAIN_PORT)],
                                 cwd=str(ROOT), stdout=open(OUT / "raw" / "brain_serve.log", "a"),
                                 stderr=subprocess.STDOUT)
    proxy = subprocess.Popen([PY, "-m", "tools.brain_review.teacher_proxy",
                              "--session", token, "--capture-dir", str(OUT / "raw"),
                              "--port", str(PROXY_PORT), "--brain-port", str(BRAIN_PORT),
                              "--default-mode", "TEACHER"],
                             cwd=str(ROOT), stdout=open(OUT / "raw" / "proxy.log", "a"),
                             stderr=subprocess.STDOUT)
    hands = HandsService(log)
    arenas = []
    try:
        if not wait_port(BRAIN_PORT, token, 600):
            raise SystemExit("brain serve did not come up on %d" % BRAIN_PORT)
        log("[HARVEST] brain serve up on %d (backend=%s)" % (BRAIN_PORT, a.backend))
        # one REAL generation before any game (health alone proved nothing)
        probe = post(BRAIN_PORT, "/v1/chat/completions",
                     {"model": "rl_policy", "messages": [{"role": "user", "content": "Reply with the single word READY."}]})
        txt = str((((probe or {}).get("choices") or [{}])[0].get("message") or {}).get("content", ""))
        if not txt.strip():
            raise SystemExit("brain generation probe failed: %r" % (probe,))
        log("[HARVEST] brain generation probe ok (%d chars)" % len(txt))
        if not wait_port(PROXY_PORT, token, 120):
            raise SystemExit("teacher proxy did not come up on %d" % PROXY_PORT)
        log("[HARVEST] teacher proxy up on %d" % PROXY_PORT)
        hands.start()
        env_extra = {"LAYA_URL": hands.url, "BRAIN_CONTRACT_MODE": "unalloc_v1",
                     "SELFPLAY_GENERAL_TIMEOUT_SEC": "900"}
        arenas = [Arena(log, i, env_extra, WINDOW_GEOMS[i]) for i in range(a.windows)]
        for g in range(a.group_offset, a.group_offset + a.groups):
            wins = [f"w{i}" for i in range(a.windows)]
            gids = [f"g{g:04d}_w{i}" for i in range(a.windows)]
            if a.resume and all(x in done for x in gids):
                continue
            family = FAMILIES[g % 2]
            seed = 200000 + g * 7
            tier = TIERS[g % 3]
            style = STYLES[g % 4]
            pattern = [a.modes.upper()] * a.windows if a.modes else PATTERNS[g % 2][: a.windows]
            post(PROXY_PORT, "/admin/tags", {w: gid for w, gid in zip(wins, gids)})
            post(PROXY_PORT, "/admin/modes", {w: m for w, m in zip(wins, pattern)})
            log("[HARVEST] group %d %s:%d GX_%s_%s modes=%s" % (g, family, seed, tier, style, pattern))
            job = {"family": family, "seed": seed, "tier": tier, "style": style,
                   "turn_cap": a.turn_cap, "session": token}
            outs = [OUT / "games" / ("%s.result.json" % gid) for gid in gids]
            t0 = time.time()
            for i, ar in enumerate(arenas):
                ar.submit(job, outs[i], 7200)
                if i < a.windows - 1:
                    time.sleep(a.stagger)
            for i, ar in enumerate(arenas):
                err = ar.wait(outs[i], 7200)
                res = {}
                if outs[i].exists():
                    try:
                        res = json.loads(outs[i].read_text(encoding="utf-8"))
                    except ValueError:
                        res = {"error": "bad result json"}
                res = res or {"error": err or "no result"}
                meta = {"game_id": gids[i], "group": g, "window": wins[i], "mode": pattern[i],
                        "family": family, "seed": seed, "tier": tier, "style": style,
                        "gx_profile": "GX_%s_%s" % (tier, style),
                        "episode_id": (res.get("episode") or {}).get("episode_id"),
                        "episode_spec_path": (res.get("episode") or {}).get("episode_spec_path"),
                        "turn_cap": a.turn_cap, "session": token,
                        "started_ts": t0, "ended_ts": time.time(), "wait_error": err,
                        "result": res}
                with open(OUT / "games" / ("%s.json" % gids[i]), "w", encoding="utf-8") as f:
                    json.dump(meta, f, ensure_ascii=False, indent=1)
                with open(idx_path, "a", encoding="utf-8") as f:
                    f.write(json.dumps({k: meta[k] for k in ("game_id", "group", "window", "mode", "family",
                                                             "seed", "tier", "style", "episode_id",
                                                             "gx_profile")}) + "\n")
                s = score(res) if res and "error" not in res else {"kind": "ERROR", "reward": None}
                if not res.get("red_actions", {}).get("moves") and not (res.get("brain") or {}).get("decisions", {}).get("INITIAL"):
                    log("[HARVEST] FAIL-FAST: %s RED never acted (no opening plan) -> stopping" % gids[i])
                    raise SystemExit("RED never acted in %s" % gids[i])
                log("[HARVEST] %s -> %s r=%s turn=%s wall=%.0fs err=%r" % (
                    gids[i], res.get("outcome"), s.get("reward"), res.get("turn"),
                    float(res.get("wall_s", 0)), err))
            # per-window godot logs (marker-split later by build_corpus)
            wdir = OUT / "games" / "_windows"
            wdir.mkdir(exist_ok=True)
            for i, ar in enumerate(arenas):
                src = ar.dir / "godot.log"
                if src.exists():
                    (wdir / ("w%d.godot.log" % i)).write_bytes(src.read_bytes())
    finally:
        for ar in arenas:
            ar.quit()
        hands.stop()
        for port in (PROXY_PORT, BRAIN_PORT):
            try:
                post(port, "/admin/shutdown", {})
            except Exception:  # noqa: BLE001
                pass
        for p in (proxy, brain):
            try:
                p.wait(timeout=60)
            except Exception:  # noqa: BLE001
                p.kill()
        if a.backend == "vllm":
            try:
                from tools.brain_vllm import common as C
                C.engine_stop()
            except Exception:  # noqa: BLE001
                pass
        log("[HARVEST] stopped")


if __name__ == "__main__":
    main()
