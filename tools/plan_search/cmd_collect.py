"""COMMANDER DATA COLLECTION (2026-10-06): the cloud model plays commander games over many situations; every Brain
call is kept with the cloud's thinking (raw/calls.jsonl) for SFT of the local Brain.

Situations = GX tier x GX style x stat family (per-class movement/attack variation) x repeats, one seed per game.
A round plays the tiers in order (BASIC block, then INTER, then ADV), styles x families shuffled inside a block;
--cycle repeats rounds with fresh seeds until <out>/STOP exists (running games finish). Packet facts are on
(WATCH_CMD_FACTS=1); the legacy opening-plan request is answered locally (--initial-stub). Re-running with the same
--out skips games already in results.jsonl. The Brain is resident: one conversation per game, asked every RED turn
(scripts/cloud_pipeline/commander_controller.gd).
Modes (2026-10-08; every game's result also keeps the full record of both sides: unit snapshots every round and
both controllers' actions, for the prediction model):
  --mode gx_vs_cloud    (default) the Brain plays RED, GX plays BLUE
  --mode gx_vs_gx       GX on both sides: every RED style x every BLUE style (--red-styles), no Brain calls
  --mode cloud_vs_cloud the Brain plays both sides, each through its own proxy (BLUE: --blue-model / --blue-variant,
                        calls in raw_blue/)

  python -m tools.plan_search.cmd_collect --out <dir> [--tiers BASIC,INTER,ADV] [--variant max] [--cycle]
         [--families fixed,mild,broad,counterfactual_valid] [--repeats 1] [--windows 8] [--visible]
"""
from __future__ import annotations

import argparse
import itertools
import json
import random
import secrets
import subprocess
import threading
import time
from pathlib import Path

from tools.brain_review.harvest import post, wait_port
from tools.contextual_brain import rl_vs_utility as RV
from tools.plan_search.cloud_brain import MODEL
from tools.plan_search.eval_plans import Hands, PROXY_PORT, DUMMY_BRAIN_PORT
import sys as _sys
_sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "battlefields"))
import gen_missions as GM  # noqa: E402  (generated mission maps)

STYLES = ["SPEARHEAD", "BULWARK", "OUTRIDER", "HARRIER"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--tiers", default="BASIC,INTER,ADV")
    ap.add_argument("--cycle", action="store_true", help="repeat rounds with fresh seeds until <out>/STOP")
    ap.add_argument("--styles", default=",".join(STYLES))
    ap.add_argument("--families", default="fixed,mild,broad,counterfactual_valid")
    ap.add_argument("--repeats", type=int, default=1)
    ap.add_argument("--seed0", type=int, default=800000)
    ap.add_argument("--turn-cap", type=int, default=80)
    ap.add_argument("--windows", type=int, default=8)
    ap.add_argument("--model", default=MODEL)
    ap.add_argument("--variant", default="", help="opencode reasoning effort ('' = the model's default)")
    ap.add_argument("--call-timeout", type=int, default=180,
                    help="seconds per Brain request; past it the Brain passes (current orders stand) and the game goes on")
    ap.add_argument("--visible", action="store_true")
    ap.add_argument("--trace", action="store_true", help="log every executed RED action in the arena log")
    ap.add_argument("--window-row", type=int, default=0, help="--visible: screen row of this run's windows (two runs side by side)")
    ap.add_argument("--local-url", default="", help="play a local vLLM Brain instead of the cloud (e.g. "
                    "http://127.0.0.1:8000/v1/chat/completions)")
    ap.add_argument("--local-model", default="q35")
    ap.add_argument("--local-no-think", action="store_true")
    ap.add_argument("--local-answer-tokens", type=int, default=4000)
    ap.add_argument("--local-max-tokens", type=int, default=12000, help="local: token cap of one answer (thinking + answer)")
    ap.add_argument("--local-reasoning-effort", default="", help="local: chat-template effort (low / medium / xhigh)")
    ap.add_argument("--local-think-budget", type=int, default=0, help="local thinking budget in tokens (0 = unlimited)")
    ap.add_argument("--recent-turns", type=int, default=0, help="turns kept word for word after a fold into the digest (0 = game default)")
    ap.add_argument("--compact-at", type=int, default=0, help="kept turns that trigger a fold into the digest (0 = game default)")
    ap.add_argument("--proxy-port", type=int, default=PROXY_PORT, help="a second collector in parallel needs its own ports")
    ap.add_argument("--brain-port", type=int, default=DUMMY_BRAIN_PORT)
    ap.add_argument("--slot", type=int, default=0, help="parallel collector slot: hands worker index and arena numbers 10+10*slot")
    ap.add_argument("--mode", default="gx_vs_cloud", choices=["gx_vs_cloud", "gx_vs_gx", "cloud_vs_cloud"])
    ap.add_argument("--random-roster", action="store_true",
                    help="both sides get the same seeded random army (HQ + 5..15 units) instead of the stock 10v10")
    ap.add_argument("--roster-sizes", default="",
                    help="with --random-roster: allowed units per side INCLUDING the HQ, e.g. 6,7,14,15,16 (default 6..16)")
    ap.add_argument("--mission-families", default="",
                    help="play generated mission maps (tools/battlefields/gen_missions.py), e.g. M1,M2,M3,M4,M5: "
                         "family = families[seed %% n]; the map seed is the game seed; MissionRules ends the match")
    ap.add_argument("--games", default="",
                    help="play exactly these games once: a JSON-lines file of {game, tier, style, family, seed} (replays)")
    ap.add_argument("--red-styles", default=",".join(STYLES), help="gx_vs_gx: RED's GX styles")
    ap.add_argument("--blue-model", default="", help="cloud_vs_cloud: BLUE's model (default: --model)")
    ap.add_argument("--blue-variant", default=None, help="cloud_vs_cloud: BLUE's variant (default: --variant)")
    ap.add_argument("--prefer-fewer-losses", action="store_true", help="A/B: put 'prefer fewer losses' back in the WIN rule")
    ap.add_argument("--games-per-tier", type=int, default=0, help="play only the first N games of each tier block (0 = all)")
    ap.add_argument("--tier-games", default="", help="per-tier game cap, e.g. BASIC=5 (overrides --games-per-tier)")
    ap.add_argument("--manual-dir", default="",
                    help="Brain requests are parked in this dir and answered by an outside agent (tools/plan_search/brain_io.py)")
    ap.add_argument("--fortify", action="store_true", help="field fortification on (removed from the game by default)")
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    lock = threading.Lock()

    def log(m):
        line = time.strftime("%m-%d %H:%M:%S ") + m
        with lock:
            print(line, flush=True)
            with open(out / "collect.log", "a", encoding="utf-8") as f:
                f.write(line + "\n")

    res_path = out / "results.jsonl"
    # Games already played; an INVALID / ERROR game is played again on a restart (its old rows stay in the log).
    done = set()
    if res_path.exists():
        for line in res_path.read_text(encoding="utf-8").splitlines():
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if row.get("kind") not in ("INVALID", "ERROR"):
                done.add(row.get("game"))
            else:
                done.discard(row.get("game"))
    tiers = a.tiers.split(",")
    red_styles = a.red_styles.split(",") if a.mode == "gx_vs_gx" else [""]
    combos = list(itertools.product(a.styles.split(","), red_styles, a.families.split(","), range(a.repeats)))
    per_round = len(tiers) * len(combos)
    jlock = threading.Lock()
    jstate = {"round": 0, "pending": []}

    overlays = {}  # --games: a replay's original rule overlay file (tools/predict/replay.py), by game

    def round_jobs(r):
        """Round r: tiers in order, styles x families shuffled inside each tier block; seeds unique across rounds."""
        if a.games:  # a fixed list (replays of logged games): played once
            if r > 0:
                return []
            rows = [json.loads(l) for l in Path(a.games).read_text(encoding="utf-8").splitlines() if l.strip()]
            overlays.update({g["game"]: g["overlay"] for g in rows if g.get("overlay")})
            return [(g["game"], g["tier"], g["style"], g["family"], int(g["seed"]), g.get("red_style", ""))
                    for g in rows if g["game"] not in done]
        jobs_r = []
        for ti, tier in enumerate(tiers):
            block = []
            for ci, (style, red_style, fam, rep) in enumerate(combos):
                seed = a.seed0 + r * per_round + ti * len(combos) + ci
                game = ("%s_%s_vs_%s_%s_s%d" % (tier, red_style, style, fam, seed) if red_style else
                        "%s_%s_%s_s%d" % (tier, style, fam, seed))
                block.append((game, tier, style, fam, seed, red_style))
            # Shuffle and cap the full block first, so the same games are picked on a resume and across models.
            random.Random("%d:%d:%s" % (a.seed0, r, tier)).shuffle(block)
            caps = dict(x.split("=") for x in a.tier_games.split(",") if "=" in x)
            cap = int(caps.get(tier, a.games_per_tier))
            if tier in caps and cap == 0:
                block = []  # --tier-games TIER=0 skips the tier (seeds of the other tiers stay the same)
            elif cap > 0:
                block = block[:cap]
            jobs_r += [j for j in block if j[0] not in done]
        return jobs_r

    def next_job():
        msg, job = "", None
        with jlock:
            while not (out / "STOP").exists():
                if jstate["pending"]:
                    job = jstate["pending"].pop(0)
                    break
                if jstate["round"] > 0 and not a.cycle:
                    break
                r = jstate["round"]
                jstate["round"] += 1
                jstate["pending"] = round_jobs(r)
                msg += "[COLLECT] round %d: %d games (%s)\n" % (r, len(jstate["pending"]), ">".join(tiers))
        if msg:
            log(msg.strip())
        return job

    log("[COLLECT] %d situations per round, %d games already done, cycle=%s, %d windows, model=%s variant=%s" % (
        per_round, len(done), a.cycle, a.windows, a.model, a.variant or "default"))

    headless_flag = RV.OUT / "HEADLESS"
    if not a.visible:
        headless_flag.write_text("cmd_collect", encoding="utf-8")
    token = secrets.token_hex(8)
    (out / "raw").mkdir(exist_ok=True)
    def start_proxy(port, brain_port, capture, model, variant, manual=""):
        capture.mkdir(exist_ok=True)
        return subprocess.Popen([RV.PY, "-m", "tools.brain_review.teacher_proxy", "--session", token,
                                 "--capture-dir", str(capture), "--port", str(port),
                                 "--brain-port", str(brain_port), "--default-mode", "TEACHER", "--initial-stub"]
                                + (["--manual-dir", manual] if manual else
                                   (["--local-url", a.local_url, "--local-model", a.local_model,
                                    "--local-answer-tokens", str(a.local_answer_tokens),
                                    "--local-max-tokens", str(a.local_max_tokens),
                                    "--local-reasoning-effort", a.local_reasoning_effort,
                                    "--local-think-budget", str(a.local_think_budget), "--local-pass"]
                                   + (["--local-no-think"] if a.local_no_think else []) if a.local_url else
                                   ["--cloud-model", model, "--cloud-variant", variant,
                                    "--cloud-timeout", str(a.call_timeout), "--cloud-pass"])),
                                cwd=str(RV.ROOT), stdout=open(capture / "proxy.log", "a"), stderr=subprocess.STDOUT)

    proxy = start_proxy(a.proxy_port, a.brain_port, out / "raw", a.model, a.variant, a.manual_dir)
    proxies = [proxy]
    blue_port = a.proxy_port + 50  # cloud_vs_cloud: BLUE's proxy
    if a.mode == "cloud_vs_cloud":
        proxies.append(start_proxy(blue_port, a.brain_port + 50, out / "raw_blue", a.blue_model or a.model,
                                   a.variant if a.blue_variant is None else a.blue_variant,
                                   (a.manual_dir.rstrip("/\\") + "_blue") if a.manual_dir else ""))
    hands = [Hands(a.slot, out, log, "cpu")]  # commander never uses the Hands; one CPU worker satisfies the mount check
    arenas = []
    try:
        if not wait_port(a.proxy_port, token, 180) or (a.mode == "cloud_vs_cloud" and not wait_port(blue_port, token, 180)):
            raise SystemExit("teacher proxy did not come up")
        hands[0].start()
        url = "http://127.0.0.1:%d/v1/chat/completions"
        for i in range(a.windows):
            env = {"LAYA_URL": hands[0].url, "BRAIN_CONTRACT_MODE": "unalloc_v1", "SELFPLAY_GENERAL_TIMEOUT_SEC": "1800",
                   "WATCH_STRATEGIC_REPLAN_TURNS": "0", "WATCH_RED_MODE": "GX" if a.mode == "gx_vs_gx" else "COMMANDER",
                   "WATCH_BLUE_MODE": "COMMANDER" if a.mode == "cloud_vs_cloud" else "GX",
                   "WATCH_CMD_URL_BLUE": url % blue_port,
                   "WATCH_CMD_FACTS": "1",
                   "FIELD_FORTIFY": "1" if a.fortify else "0",
                   "WATCH_CMD_URL": "http://127.0.0.1:%d/v1/chat/completions" % a.proxy_port,
                   "WATCH_BRAIN_PORT": str(a.proxy_port),
                   "WATCH_PREFER_FEWER_LOSSES": "1" if a.prefer_fewer_losses else "0",
                   "WATCH_RECENT_TURNS": str(a.recent_turns), "WATCH_COMPACT_AT": str(a.compact_at),
                   "WATCH_CMD_TRACE": "1" if a.trace else "0"}
            geom = (i * 855, 40 + a.window_row * 790, 850, 720) if (a.visible and i < 3) else None
            arenas.append(RV.Arena(log, 10 + 10 * a.slot + i, env, geom, headless=not a.visible))

        def worker(i, ar):
            win = "w%d" % (10 + 10 * a.slot + i)
            while True:
                nxt = next_job()
                if nxt is None:
                    return
                game, tier, style, fam, seed, red_style = nxt
                post(a.proxy_port, "/admin/tags", {win: game})
                if a.mode == "cloud_vs_cloud":
                    post(blue_port, "/admin/tags", {win: game})
                job = {"family": fam, "seed": seed, "tier": tier, "style": style, "red_style": red_style,
                       "turn_cap": a.turn_cap, "session": token, "overlay": overlays.get(game, ""),
                       "random_roster": a.random_roster, "roster_sizes": a.roster_sizes}
                if a.mission_families:  # a generated mission map per game; its own round limit ends the match
                    fams = a.mission_families.split(",")
                    mfam = fams[seed % len(fams)]
                    mp = out / "maps" / ("%s_s%d.json" % (mfam, seed))
                    if not mp.exists():
                        mp.parent.mkdir(exist_ok=True)
                        mp.write_text(json.dumps(GM.generate(mfam, seed), indent=1), encoding="utf-8")
                    job.update({"mission_map": str(mp.resolve()).replace("\\", "/"), "turn_cap": 999})
                o = out / "games" / ("%s.json" % game)
                o.parent.mkdir(exist_ok=True)
                t0 = time.time()
                err = ar.play(job, o, 36000)  # max-effort calls take minutes each; never cut a game short
                res = json.loads(o.read_text(encoding="utf-8")) if o.exists() else {"error": err or "no result"}
                s = RV.score(res) if "error" not in res else {"kind": "ERROR", "reward": None, "win": False}
                row = {"game": game, "tier": tier, "style": style, "family": fam, "seed": seed, "mode": a.mode, "red_style": red_style, **s,
                       "outcome": res.get("outcome"), "turn": res.get("turn"), "units": res.get("units"),
                       "hq": res.get("hq"), "red_actions": res.get("red_actions"), "brain": res.get("brain"),
                       "fault": res.get("strict_fault"), "error": res.get("error"), "wall_s": round(time.time() - t0),
                       "mission": res.get("mission"), "win_rule": res.get("win_rule")}
                with lock:
                    with open(res_path, "a", encoding="utf-8") as f:
                        f.write(json.dumps(row, ensure_ascii=False) + "\n")
                log("[COLLECT] %s -> %s turn=%s red=%s blue=%s blue_hq=%s fault=%s wall=%ds" % (
                    game, s.get("kind"), res.get("turn"), ((res.get("units") or {}).get("red") or {}).get("alive"),
                    ((res.get("units") or {}).get("blue") or {}).get("alive"),
                    ((res.get("hq") or {}).get("blue") or {}).get("end"),
                    (res.get("strict_fault") or {}).get("code"), row["wall_s"]))

        threads = [threading.Thread(target=worker, args=(i, ar), daemon=True) for i, ar in enumerate(arenas)]
        for t in threads:
            t.start()
            time.sleep(3)
        for t in threads:
            t.join()
    finally:
        for ar in arenas:
            ar.quit()
        for h in hands:
            h.stop()
        for port, px in zip([a.proxy_port, blue_port], proxies):
            try:
                post(port, "/admin/shutdown", {})
            except Exception:  # noqa: BLE001
                pass
            try:
                px.wait(timeout=60)
            except Exception:  # noqa: BLE001
                px.kill()
        headless_flag.unlink(missing_ok=True)
        log("[COLLECT] stopped")


if __name__ == "__main__":
    main()
