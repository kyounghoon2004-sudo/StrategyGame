"""RL_VS_UTILITY V0 — vanilla GRPO: contextual Brain (init S0B) vs generalized GX Utility, real live games.

Phase-separated (the proven marathon pattern; the model is never resident while it is not needed):

  ROLLOUT  fresh process `serve`: inference-only policy (base NF4 + current adapter) on 127.0.0.1:8096.
           The orchestrator plays GROUPS_PER_ITER groups x 2 real games (tools/rl_arena.gd: one persistent visible watch
           scene: RED = this policy, context pack ON -> frozen Hand A -> frozen Hand B; BLUE = GX Utility tier),
           each game's first VICTORY_INITIAL completion is captured to disk. Then the server exits (VRAM freed).
  TRAIN    fresh process `train`: base + current adapter, one GRPO step per informative group, saves a NEW
           adapter dir, exits.
  The orchestrator (`run`, no GPU) logs games / loss, applies the promotion rule, repeats.

  <RL venv python> -m tools.contextual_brain.rl_vs_utility run [--iterations N]      (resumes from state.json)
  Stop: create artifacts/rl_vs_utility_v0/STOP (exits at the next iteration boundary).

Locked choices (user, 2026-10-01): Step0 sandbox HQ-vs-HQ board; EpisodeSpec.sample(mild|broad,"train",seed) gives ONLY movement+attack (per-match unit stat
variation; no new modes/maps); 30-turn cap (user 2026-10-01); reward = score() (invalid Brain output -5 ends the game;
mission achieved +5; anything else -3; +/-0.1 per own unit alive/lost); INITIAL plan only is
trained (V0 loop; full-episode credit is Phase 4); GRPO beta 0, one step per informative group, LR 5e-6 (marathon lock); ladder GX_BASIC -> GX_INTER -> GX_ADV,
promote when >= 20 games at the tier and >= 12 wins (decisive or judged) in the last 20; checkpoint carried forward.
"""
from __future__ import annotations

import argparse
import json
import os
import random
import secrets
import subprocess
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(os.environ.get("SG_ROOT", r"D:\Game development\Demon slayer\StrategyGame"))
OUT = ROOT / "artifacts" / "rl_vs_utility_v0"
S0B = ROOT / "artifacts" / "contextual_brain_s0b" / "candidate_S0B"
S0B_SHA = "32029f7acf0bdac257e38a4a72d550697c15cd17184b00791eeb322b7e65205b"
GODOT = os.environ.get("SG_GODOT", r"C:\Users\kyoun\AppData\Local\Programs\Godot\Godot_v4.2.2-stable_win64_console.exe")
PY = os.environ.get("SG_PY", r"D:\StrategyAI\runtimes\qwen3_8b_rl_v0\.venv\Scripts\python.exe")
PORT = 8096
TIERS = ["BASIC", "INTER", "ADV"]
STYLES = ["SPEARHEAD", "BULWARK", "OUTRIDER", "HARRIER"]
FAMILIES = ["mild", "broad"]
TURN_CAP = 80  # 2026-10-03: 30 turns ended almost every game in a 1-2 unit stalemate
LR = 5e-6
GROUPS_PER_ITER = 4
PROMOTE_WINDOW, PROMOTE_WINS = 20, 12


# ------------------------------------------------------------------ reward (pure; self-checked)
# v3 (user, 2026-10-05, from the cloud commander records: INTER/ADV losses were all-in races that left the own HQ
# empty): losing the own HQ is now worse than a stalemate, and own-HQ damage is penalised symmetrically.
INVALID_R, WIN_R, LOSS_R, STALEMATE_R = -16.0, 10.0, -12.0, -10.0  # invalid stays strictly worst (worst loss = -15)
OWN_HQ_DMG_TERM = 2.0  # x fraction of RED HQ soldiers lost
HQ_DMG_TERM = 2.0  # v2b (user, 2026-10-03): x fraction of BLUE HQ soldiers lost (rewards reaching and hitting the HQ)
# v2c (user, 2026-10-04): light penalty for flip-flopping a mission's task (changed again within
# FLIP_WINDOW turns of its last change). Meant to be removed (set 0.0) once the habit is gone.
FLIP_TERM, FLIP_WINDOW, FLIP_CAP = 0.0, 3, 1.0  # reverted to 0 (user, 2026-10-04): one problem at a time; flips still logged
# 2026-10-08 (user): army sizes vary (3..50 per side), so kills/losses count as SHARES of each army:
# + KILL_TERM x (BLUE units destroyed / BLUE start), - LOSS_TERM x (own units lost / own start). At 10 v 10 this is
# exactly the old +0.3 per kill / -0.1 per loss.
KILL_TERM, LOSS_TERM = 3.0, 1.0
# 2026-10-08 (user, trial): focus fire. + FOCUS_TERM x share of RED's attack phases (attacks on BLUE units, HQ not
# counted) in which two or more RED units hit the same BLUE unit (at most +3, like the kill term).
FOCUS_TERM = 0.0  # tried at 1.0 then 3.0 with a prompt line (2026-10-08); both removed by the user the same day


def focus_share(res: dict, side: str = "red") -> float:
    """Share of a side's phases with unit attacks where >= 2 of its units attacked the same enemy unit (game record)."""
    by_turn = {}
    for e in ((res.get("record") or {}).get("actions") or {}).get(side, []):
        if e.get("do") == "ATTACK" and "HQ" not in str(e.get("target", "")):
            by_turn.setdefault(e.get("turn"), []).append(str(e.get("target")))
    if not by_turn:
        return 0.0
    hit = sum(1 for tg in by_turn.values() if len(tg) != len(set(tg)))
    return hit / len(by_turn)


def score(res: dict, flips: int = 0) -> dict:
    """Reward contract v2 (user, 2026-10-03: stalemates must hurt far more; BLUE is passive, so RED must attack).
    Invalid Brain output ends the game: -15 (always the worst). Mission achieved (BLUE HQ destroyed): +10.
    Own HQ lost: -8. Turn cap without the mission (stalemate): -10 (worse than losing while attacking).
    v2b: + 2.0 x fraction of BLUE HQ soldiers lost. All add +0.3 per BLUE unit destroyed and -0.1 per own unit lost (GRPO normalizes per group, so the kill
    term is what separates an aggressive game from a passive one when all three games end the same way)."""
    if res.get("outcome") == "INVALID" or (res.get("strict_fault") or {}).get("code"):
        return {"reward": INVALID_R, "win": False, "kind": "INVALID"}
    u = (res.get("units") or {}).get("red") or {}
    b = (res.get("units") or {}).get("blue") or {}
    lost = (int(u.get("start", 0)) - int(u.get("alive", 0))) / max(1, int(u.get("start", 0)))
    kills = (int(b.get("start", 0)) - int(b.get("alive", 0))) / max(1, int(b.get("start", 0)))
    hq = ((res.get("hq") or {}).get("blue") or {})
    hq_frac = 1.0 - int(hq.get("end", 0)) / int(hq["start"]) if int(hq.get("start", 0)) > 0 else 0.0
    own = ((res.get("hq") or {}).get("red") or {})
    own_frac = 1.0 - int(own.get("end", 0)) / int(own["start"]) if int(own.get("start", 0)) > 0 else 0.0
    focus = focus_share(res)
    term = round(KILL_TERM * kills - LOSS_TERM * lost + FOCUS_TERM * focus + HQ_DMG_TERM * max(0.0, min(1.0, hq_frac))
                 - OWN_HQ_DMG_TERM * max(0.0, min(1.0, own_frac))
                 - min(FLIP_CAP, FLIP_TERM * flips), 4)
    if res.get("outcome") == "RED_WIN":
        return {"reward": round(WIN_R + term, 4), "win": True, "kind": "WIN", "unit_term": term, "focus": round(focus, 4)}
    kind = "LOSS" if res.get("outcome") == "BLUE_WIN" else "NOT_ACHIEVED"
    return {"reward": round((LOSS_R if kind == "LOSS" else STALEMATE_R) + term, 4), "win": False, "kind": kind,
            "unit_term": term, "focus": round(focus, 4)}


def count_flips(changes) -> int:
    """changes: [(turn, phase, mission, new_task)] in turn order. A flip = a mission's task changed again
    within FLIP_WINDOW turns of its previous change."""
    last, n = {}, 0
    for turn, ph, mi, _task in changes:
        k = (str(ph).upper(), str(mi).upper().lstrip("M").lstrip("0") or "0")
        if k in last and turn - last[k] <= FLIP_WINDOW:
            n += 1
        last[k] = turn
    return n


def _game_task_changes(cap: Path, tag: str):
    """Task changes the Brain made in one game, from its captured review outputs (AMEND patches)."""
    out = []
    f = cap / "calls.jsonl"
    if not f.exists():
        return out
    for line in f.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        r = json.loads(line)
        if r.get("tag") != tag or r.get("request") != "VICTORY_REVIEW":
            continue
        try:
            d = json.loads(r.get("raw") or "")
        except ValueError:
            continue
        if isinstance(d, dict) and d.get("decision") == "AMEND_PLAN":
            for e in d.get("patch") or []:
                if isinstance(e, dict) and "task" in e:
                    out.append((int(r.get("turn") or 0), e.get("phase"), e.get("mission"), e.get("task")))
    return sorted(out, key=lambda x: x[0])


def advantages(rs):
    m = sum(rs) / len(rs)
    sd = (sum((r - m) ** 2 for r in rs) / len(rs)) ** 0.5
    return [0.0 for _ in rs] if sd < 1e-9 else [(r - m) / (sd + 1e-4) for r in rs]


def promote(history):
    return len(history) >= PROMOTE_WINDOW and sum(history[-PROMOTE_WINDOW:]) >= PROMOTE_WINS


def _selfcheck():
    U = lambda a, b=10: {"red": {"start": 10, "alive": a}, "blue": {"start": 10, "alive": b}}  # noqa: E731
    assert score({"outcome": "RED_WIN", "units": U(10, 9)})["reward"] == 10.3
    assert score({"outcome": "BLUE_WIN", "units": U(0, 4)})["reward"] == -11.2
    assert score({"outcome": "CAP", "units": U(10), "hq": {"red": {"start": 300, "end": 150}}})["reward"] == -11.0
    assert score({"outcome": "CAP", "units": U(9, 10)}) == {"reward": -10.1, "win": False, "kind": "NOT_ACHIEVED", "unit_term": -0.1,
                                                         "focus": 0.0}
    A = lambda t, u, x: {"turn": t, "unit": u, "do": "ATTACK", "target": x}  # noqa: E731
    rec = {"actions": {"red": [A(3, "R1", "B1"), A(3, "R2", "B1"), A(4, "R1", "B2"), A(5, "R1", "B_HQ_1"), A(5, "R2", "B_HQ_1")]}}
    assert focus_share({"record": rec}) == 0.5  # turn 3 focused, turn 4 not, turn 5 = HQ only (not counted)
    assert score({"outcome": "CAP", "units": U(10), "record": rec})["reward"] == round(-10.0 + FOCUS_TERM * 0.5, 4)
    assert score({"outcome": "CAP", "units": U(7, 5)})["reward"] == -8.8
    assert score({"outcome": "CAP", "units": U(10), "hq": {"blue": {"start": 300, "end": 150}}})["reward"] == -9.0
    assert score({"outcome": "CAP", "units": U(10), "hq": {"blue": {"start": 300, "end": 300}}})["reward"] == -10.0
    assert score({"outcome": "CAP", "units": U(10)}, flips=4)["reward"] == round(-10.0 - min(FLIP_CAP, FLIP_TERM * 4), 4)
    assert count_flips([(5, "P3", 1, "ATTACK"), (6, "P3", 1, "WITHDRAW"), (7, "P3", 1, "ATTACK"), (20, "P3", 1, "HOLD")]) == 2
    assert score({"outcome": "RED_WIN", "units": U(10), "strict_fault": {"code": "X"}})["reward"] == -16.0
    assert score({"outcome": "INVALID"})["kind"] == "INVALID"
    assert INVALID_R < LOSS_R - LOSS_TERM - OWN_HQ_DMG_TERM and LOSS_R < STALEMATE_R
    U50 = {"red": {"start": 50, "alive": 50}, "blue": {"start": 50, "alive": 0}}  # shares: 50 kills = +3, not +15
    assert score({"outcome": "CAP", "units": U50})["reward"] == -7.0
    assert advantages([1.0, 1.0]) == [0.0, 0.0] and advantages([5.0, -3.0])[0] > 0 > advantages([5.0, -3.0])[1]
    assert not promote([True] * 19) and promote([True] * 12 + [False] * 8) and not promote([False] * 9 + [True] * 11)


# ------------------------------------------------------------------ phase: serve (inference only)
def cmd_serve(a):
    from tools.contract_sft import gpu_common as G
    from tools.contract_sft.brain_server import PROBE_TEXT, packet_of
    import torch
    from peft import PeftModel
    log = G.make_logger(Path(a.capture_dir) / "serve.log")
    guard = G.Guard(log)
    with G.gpu_lock("rl_vs_utility_serve", "RL_ROLLOUT"):
        tok = G.load_tokenizer()
        model = PeftModel.from_pretrained(G.load_base(), a.adapter)  # frozen, inference only
        model.eval()
        model.config.use_cache = True
        guard.check("loaded")
        lock = threading.Lock()
        st = {"tag": None, "calls": 0, "tag_map": {}}

        def tag_for(headers):
            import re
            from urllib.parse import unquote
            m = re.search(r"_(w[0-9]+)[.]json$", unquote(headers.get("X-Episode-Spec-Path") or ""))
            win = m.group(1) if m else None
            return win, (st["tag_map"].get(win) if win else None) or st["tag"]

        def gen(messages):
            with lock:
                enc = tok(G.render_prompt(tok, messages), add_special_tokens=False, return_tensors="pt").to("cuda:0")
                torch.manual_seed(int(time.time() * 1000) % 2 ** 31)
                with torch.inference_mode():
                    out = model.generate(**enc, max_new_tokens=G.SAMPLING["max_new_tokens"], do_sample=True,
                                         temperature=G.SAMPLING["temperature"], top_p=G.SAMPLING["top_p"],
                                         top_k=G.SAMPLING["top_k"], repetition_penalty=G.SAMPLING["repetition_penalty"],
                                         pad_token_id=tok.pad_token_id, eos_token_id=tok.eos_token_id)
                p = enc["input_ids"][0].tolist()
                c = out[0][len(p):].tolist()
                st["calls"] += 1
                del out, enc
                torch.cuda.empty_cache()
                guard.check(f"call{st['calls']}")
                return tok.decode(c, skip_special_tokens=True), p, c

        class H(BaseHTTPRequestHandler):
            def log_message(self, *x):
                pass

            def _json(self, code, obj):
                b = json.dumps(obj).encode("utf-8")
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(b)))
                self.end_headers()
                self.wfile.write(b)

            def do_GET(self):
                if self.path in ("/health", "/identity"):
                    self._json(200, {"ok": True, "label": "RL_POLICY", "model": "rl_policy", "rl_session": a.session,
                                     "adapter_dir": a.adapter, "adapter_is_csft6": False, "calls": st["calls"],
                                     "memory": guard.summary()})
                else:
                    self._json(404, {})

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
                if self.path == "/admin/tag":
                    st["tag"] = body.get("tag")
                    self._json(200, {"ok": True})
                    return
                if self.path == "/admin/tags":  # {window: tag}, e.g. {"w0": "g00012_0", ...}
                    st["tag_map"] = dict(body)
                    self._json(200, {"ok": True})
                    return
                if self.path == "/admin/shutdown":
                    self._json(200, {"ok": True})
                    threading.Thread(target=srv.shutdown, daemon=True).start()
                    return
                msgs = body.get("messages") or []
                last = next((str(m.get("content", "")) for m in reversed(msgs) if m.get("role") == "user"), "")
                if last.strip() == PROBE_TEXT:
                    raw, p, c = "OK", [], []
                else:
                    raw, p, c = gen(msgs)
                    pk = packet_of(msgs) or {}
                    win, tag = tag_for(self.headers)
                    # DEBUG ONLY (debug_group --corrupt-window): break that window's first review to prove the
                    # invalid-output path (game ends, reward -5). Never set by the RL loop.
                    if win and os.environ.get("RL_DEBUG_CORRUPT_WINDOW") == win and pk.get("request") == "VICTORY_REVIEW" \
                            and not st.get("corrupted"):
                        st["corrupted"] = True
                        raw = '{"decision": "KEEP", "reason": "broken'
                    with open(Path(a.capture_dir) / "calls.jsonl", "a", encoding="utf-8") as cf:
                        cf.write(json.dumps({"tag": tag, "window": win, "request": pk.get("request"), "turn": pk.get("turn"),
                                             "trigger": (pk.get("review_trigger") or {}).get("trigger"),
                                             "messages": msgs, "raw": raw, "episode": self.headers.get("X-Episode-Id")}) + "\n")
                    f = Path(a.capture_dir) / f"{tag}.json"
                    if tag and pk.get("request") == "VICTORY_INITIAL" and not f.exists():
                        f.write_text(json.dumps({"prompt_ids": p, "comp_ids": c, "text": raw,
                                                 "has_context": "context" in pk,
                                                 "episode": self.headers.get("X-Episode-Id")}), encoding="utf-8")
                self._json(200, {"id": f"rl-{st['calls']}", "object": "chat.completion", "model": "rl_policy",
                                 "choices": [{"index": 0, "message": {"role": "assistant", "content": raw},
                                              "finish_reason": "length" if len(c) >= G.SAMPLING["max_new_tokens"] else "stop"}],
                                 "usage": {"prompt_tokens": len(p), "completion_tokens": len(c), "total_tokens": len(p) + len(c)}})

        srv = ThreadingHTTPServer(("127.0.0.1", int(a.port)), H)
        log(f"[SERVE] adapter={a.adapter} ready on {int(a.port)}")
        srv.serve_forever()
        log(f"[SERVE] stopped calls={st['calls']} memory={guard.summary()}")
        del model
        torch.cuda.empty_cache()


# ------------------------------------------------------------------ phase: train (fresh process)
def cmd_train(a):
    from tools.contract_sft import gpu_common as G
    import torch
    from peft import PeftModel
    log = G.make_logger(Path(a.out).parent / "train.log")
    samples = json.loads(Path(a.samples).read_text(encoding="utf-8"))  # [{group, items:[{prompt_ids, comp_ids, adv}]}]
    guard = G.Guard(log)
    with G.gpu_lock("rl_vs_utility_train", "RL_TRAIN"):
        model = PeftModel.from_pretrained(G.load_base(), a.adapter, is_trainable=True)
        model.gradient_checkpointing_enable(gradient_checkpointing_kwargs={"use_reentrant": False})
        model.config.use_cache = False
        model.train()
        params = [p for n, p in model.named_parameters() if p.requires_grad]
        assert params and all("lora_" in n for n, p in model.named_parameters() if p.requires_grad)
        opt = torch.optim.AdamW(params, lr=LR, weight_decay=0.0)
        guard.check("loaded")
        steps = []
        for g in samples:
            opt.zero_grad(set_to_none=True)
            total = 0.0
            for it in g["items"]:
                ids = torch.tensor([it["prompt_ids"] + it["comp_ids"]], device="cuda:0")
                with torch.autocast(device_type="cuda", dtype=torch.bfloat16):
                    logits = model(input_ids=ids, logits_to_keep=len(it["comp_ids"]) + 1).logits
                lp = torch.log_softmax(logits[0, :len(it["comp_ids"])].float(), -1)
                tlp = lp.gather(1, torch.tensor(it["comp_ids"], device="cuda:0")[:, None])[:, 0]
                loss = -(it["adv"] * tlp.mean()) / len(g["items"])
                loss.backward()
                total += float(loss.detach())
                del logits, lp, tlp, loss, ids
                torch.cuda.empty_cache()
            gn = float(torch.nn.utils.clip_grad_norm_(params, 1.0))
            opt.step()
            opt.zero_grad(set_to_none=True)
            torch.cuda.empty_cache()
            guard.check(f"step{len(steps) + 1}")
            steps.append({"group": g["group"], "loss": round(total, 6), "grad_norm": round(gn, 4)})
            log(f"[TRAIN] step {steps[-1]}")
        model.save_pretrained(a.out)
        Path(a.out, "TRAIN_STEPS.json").write_text(json.dumps({"steps": steps, "memory": guard.summary(),
                                                              "init_adapter": a.adapter}, indent=1), encoding="utf-8")
        log(f"[TRAIN] saved {a.out} memory={guard.summary()}")


# ------------------------------------------------------------------ orchestrator (no GPU)
def _wait_health(token, timeout_s=600):
    t0 = time.time()
    while time.time() - t0 < timeout_s:
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/health", timeout=3) as r:
                if json.loads(r.read()).get("rl_session") == token:
                    return True
        except Exception:  # noqa: BLE001 - still booting
            pass
        time.sleep(3)
    return False


def _post(path, obj):
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}{path}", data=json.dumps(obj).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())


def _gpu_mib():
    try:
        return int(subprocess.run(["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits"],
                                  capture_output=True, text=True, timeout=15).stdout.strip().splitlines()[0])
    except Exception:  # noqa: BLE001
        return -1


LAYA_PY = os.environ.get("SG_LAYA_PY", r"D:\LayaRuntime\venv\Scripts\python.exe")
HANDS_PORT = 11450


class HandsService:
    """ONE frozen Hand A/B worker shared by every arena window (the game reuses it via LAYA_URL and never kills it).
    Stopped before each train phase so its VRAM is free, restarted for the next rollout."""

    def __init__(self, log):
        self.log = log
        self.proc = None
        self.token = ""
        self.url = f"http://127.0.0.1:{HANDS_PORT}"

    def _healthy(self) -> bool:
        try:
            with urllib.request.urlopen(self.url + "/health", timeout=3) as r:
                return json.loads(r.read().decode("utf-8")).get("ok", False) is not False
        except Exception:  # noqa: BLE001
            return False

    def start(self):
        if self.proc is not None and self.proc.poll() is None and self._healthy():
            return
        d = OUT / "hands"
        d.mkdir(parents=True, exist_ok=True)
        self.token = secrets.token_hex(8)
        self.proc = subprocess.Popen([LAYA_PY, "-u", str(ROOT / "tools" / "cloud_pipeline" / "hands_worker.py"),
                                      "--host", "127.0.0.1", "--port", str(HANDS_PORT), "--device", "cuda",
                                      "--parent-pid", str(os.getpid()), "--shutdown-token", self.token,
                                      "--log-file", str(d / "hands_worker.log")],
                                     stdout=open(d / "stdout.log", "a"), stderr=subprocess.STDOUT)
        deadline = time.time() + 300
        while not self._healthy():
            if time.time() > deadline or self.proc.poll() is not None:
                raise SystemExit("shared Hands worker did not come up (see hands/stdout.log)")
            time.sleep(2)
        self.log(f"[RL] shared Hands worker up pid={self.proc.pid} {self.url}")

    def stop(self):
        if self.proc is None or self.proc.poll() is not None:
            return
        try:
            req = urllib.request.Request(self.url + "/shutdown", data=json.dumps({"token": self.token}).encode("utf-8"),
                                         headers={"Content-Type": "application/json"}, method="POST")
            urllib.request.urlopen(req, timeout=5).read()
        except Exception:  # noqa: BLE001
            pass
        try:
            self.proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        self.log("[RL] shared Hands worker stopped")


WINDOW_GEOMS = [(0, 40, 850, 540), (855, 40, 850, 540), (1710, 40, 850, 540)]


class Arena:
    """ONE persistent visible Godot window (tools/rl_arena.gd) plays every match; relaunched only if it dies."""

    def __init__(self, log, idx=None, env_extra=None, geom=None, headless=None):
        self.idx = idx
        self.headless = headless  # None: the shared OUT/HEADLESS flag decides (racy when several collectors run)
        self.dir = OUT / ("arena" if idx is None else f"arena_{idx}")
        self.dir.mkdir(parents=True, exist_ok=True)
        self.log = log
        self.proc = None
        self.env_extra = dict(env_extra or {})
        if idx is not None:
            self.env_extra["WATCH_SPEC_TAG"] = f"w{idx}"  # one spec file per window -> request provenance per game
        self.geom = geom  # (x, y, w, h) window placement, None = Godot default

    def _job(self, job: dict):
        tmp = self.dir / "job.tmp"
        tmp.write_text(json.dumps(job), encoding="utf-8")
        os.replace(tmp, self.dir / "job.json")

    def ensure(self):
        if self.proc is not None and self.proc.poll() is None:
            return
        for f in ("job.json", "alive.json", "idle_ack.json"):
            (self.dir / f).unlink(missing_ok=True)
        headless = (OUT / "HEADLESS").exists() if self.headless is None else self.headless
        gargs = [GODOT] + (["--headless"] if headless else []) + \
            (["--position", f"{self.geom[0]},{self.geom[1]}", "--resolution", f"{self.geom[2]}x{self.geom[3]}"] if self.geom else []) + \
            ["--path", str(ROOT), "-s", "res://tools/rl_arena.gd"]
        self.proc = subprocess.Popen(gargs, env=dict(os.environ, RL_ARENA_DIR=str(self.dir), **self.env_extra),
                                     stdout=open(self.dir / "godot.log", "a", encoding="utf-8", errors="replace"),
                                     stderr=subprocess.STDOUT)
        deadline = time.time() + 120
        while not (self.dir / "alive.json").exists():
            if time.time() > deadline or self.proc.poll() is not None:
                raise SystemExit("arena window did not come up")
            time.sleep(1)
        self.log(f"[RL] arena window up pid={self.proc.pid} dir={self.dir.name}")

    def play(self, job: dict, out: Path, timeout_s: int) -> str:
        self.submit(job, out, timeout_s)
        return self.wait(out, timeout_s)

    def submit(self, job: dict, out: Path, timeout_s: int):
        self.ensure()
        out.unlink(missing_ok=True)
        self._job({"cmd": "play", "out": out.as_posix(), "timeout_s": timeout_s, **job})

    def wait(self, out: Path, timeout_s: int) -> str:
        deadline = time.time() + timeout_s + 300
        while not out.exists():
            if self.proc.poll() is not None:
                return f"arena exited rc={self.proc.returncode}"
            if time.time() > deadline:
                self.proc.kill()
                return "arena unresponsive (killed)"
            time.sleep(2)
        time.sleep(1)
        return ""

    def idle(self):
        if self.proc is None or self.proc.poll() is not None:
            return
        (self.dir / "idle_ack.json").unlink(missing_ok=True)
        self._job({"cmd": "idle"})
        deadline = time.time() + 60
        while not (self.dir / "idle_ack.json").exists() and time.time() < deadline:
            time.sleep(1)

    def quit(self):
        if self.proc is not None and self.proc.poll() is None:
            self._job({"cmd": "quit"})
            try:
                self.proc.wait(timeout=60)
            except subprocess.TimeoutExpired:
                self.proc.kill()


def cmd_run(a):
    _selfcheck()
    OUT.mkdir(parents=True, exist_ok=True)
    sys.path.insert(0, str(ROOT))
    from tools.contract_sft import gpu_common as G
    log = G.make_logger(OUT / "rl.log")
    sf = OUT / "state.json"
    state = json.loads(sf.read_text(encoding="utf-8")) if sf.exists() else \
        {"iteration": 0, "group": 0, "updates": 0, "tier": "BASIC", "adapter": str(S0B),
         "tier_history": {t: [] for t in TIERS}, "promotions": []}
    if state["adapter"] == str(S0B):
        assert G.file_sha256(str(S0B / "adapter_model.safetensors")) == S0B_SHA, "S0B identity mismatch"
    arena = Arena(log)
    for _ in range(a.iterations):
        if (OUT / "STOP").exists():
            log("[RL] STOP file present; exiting")
            arena.quit()
            break
        it = state["iteration"] + 1
        itdir = OUT / "iterations" / f"it{it:04d}"
        cap = itdir / "captures"
        cap.mkdir(parents=True, exist_ok=True)
        assert _gpu_mib() < 4000, f"GPU not clear before rollout: {_gpu_mib()} MiB"
        token = secrets.token_hex(8)
        srv = subprocess.Popen([PY, "-m", "tools.contextual_brain.rl_vs_utility", "serve", "--adapter", state["adapter"],
                                "--session", token, "--capture-dir", str(cap)], cwd=str(ROOT),
                               stdout=open(itdir / "serve.stdout.log", "w"), stderr=subprocess.STDOUT)
        if not _wait_health(token):
            srv.kill()
            raise SystemExit("rollout server did not become ready")
        log(f"[RL] it{it} ROLLOUT adapter={state['adapter']} tier={state['tier']} gpu={_gpu_mib()}MiB")
        rng = random.Random(f"rl:{it}")
        groups = []
        for _g in range(GROUPS_PER_ITER):
            g = state["group"]
            family, seed, tier, style = FAMILIES[g % 2], 100000 + g, state["tier"], rng.choice(STYLES)
            items = []
            for k in range(2):
                tag = f"g{g:05d}_{k}"
                _post("/admin/tag", {"tag": tag})
                mo = itdir / "matches" / f"{tag}.json"
                mo.parent.mkdir(exist_ok=True)
                t0 = time.time()
                # Same visible arena window for every match (create OUT/HEADLESS before launch to hide it).
                err = arena.play({"family": family, "seed": seed, "tier": tier, "style": style,
                                  "turn_cap": TURN_CAP, "session": token}, mo, 7200)
                res = json.loads(mo.read_text(encoding="utf-8")) if mo.exists() else {"error": err or "no result"}
                bad = "error" in res or res.get("outcome") in ("ABORTED", "TIMEOUT") or \
                    int((res.get("brain") or {}).get("brain_failures", 0)) > 0
                s = {"reward": None, "win": False, "kind": "ERROR"} if bad else score(res)
                capf = cap / f"{tag}.json"
                row = {"iteration": it, "group": g, "k": k, "tier": tier, "gx_profile": f"GX_{tier}_{style}", "family": family,
                       "seed": seed, "episode_id": (res.get("episode") or {}).get("episode_id"), **s,
                       "outcome": res.get("outcome"), "turn": res.get("turn"), "red_frac": res.get("red_frac"),
                       "blue_frac": res.get("blue_frac"), "wall_s": round(time.time() - t0, 1),
                       "initial_captured": capf.exists(), "red_stats": res.get("red_stats"), "error": res.get("error"),
                       "units": res.get("units"), "red_actions": res.get("red_actions"), "brain": res.get("brain"),
                       "straightness": (res.get("wander") or {}).get("mean_straightness")}
                with open(OUT / "games.jsonl", "a", encoding="utf-8") as f:
                    f.write(json.dumps(row) + "\n")
                log(f"[RL] game g{g}/{k} GX_{tier}_{style} {family}:{seed} -> {s['kind']} r={s['reward']} "
                    f"turn={res.get('turn')} {row['wall_s']}s gpu={_gpu_mib()}MiB")
                if s["kind"] != "ERROR":
                    state["tier_history"][tier].append(bool(s["win"]))
                items.append((s, capf))
            state["group"] += 1
            if all(s["reward"] is not None and c.exists() for s, c in items):
                adv = advantages([s["reward"] for s, _ in items])
                if any(abs(x) > 1e-9 for x in adv):
                    groups.append({"group": g, "rewards": [s["reward"] for s, _ in items], "items": [
                        {**{k2: v for k2, v in json.loads(c.read_text(encoding="utf-8")).items() if k2 in ("prompt_ids", "comp_ids")},
                         "adv": x} for (s, c), x in zip(items, adv)]})
            hist = state["tier_history"][state["tier"]]
            if promote(hist) and TIERS.index(state["tier"]) < len(TIERS) - 1:
                nxt = TIERS[TIERS.index(state["tier"]) + 1]
                state["promotions"].append({"from": state["tier"], "to": nxt, "iteration": it, "group": g,
                                            "games_at_tier": len(hist), "wins_last20": sum(hist[-PROMOTE_WINDOW:]),
                                            "adapter": state["adapter"]})
                log(f"[RL] PROMOTED {state['tier']} -> {nxt} (wins {sum(hist[-PROMOTE_WINDOW:])}/{PROMOTE_WINDOW})")
                state["tier"] = nxt
        try:
            _post("/admin/shutdown", {})
        except Exception:  # noqa: BLE001
            pass
        try:
            srv.wait(timeout=120)
        except subprocess.TimeoutExpired:
            srv.kill()
        arena.idle()  # Hands worker down: the window stays open, the GPU is clear for training
        upd = {"iteration": it, "informative_groups": len(groups), "groups": GROUPS_PER_ITER}
        if groups:
            assert _gpu_mib() < 4000, f"GPU not clear before train: {_gpu_mib()} MiB"
            (itdir / "samples.json").write_text(json.dumps(groups), encoding="utf-8")
            new = itdir / "adapter"
            r = subprocess.run([PY, "-m", "tools.contextual_brain.rl_vs_utility", "train", "--adapter", state["adapter"],
                                "--samples", str(itdir / "samples.json"), "--out", str(new)], cwd=str(ROOT))
            if r.returncode != 0 or not (new / "adapter_model.safetensors").exists():
                raise SystemExit(f"train phase failed rc={r.returncode}")
            steps = json.loads((new / "TRAIN_STEPS.json").read_text(encoding="utf-8"))
            upd.update({"steps": steps["steps"], "memory": steps["memory"],
                        "mean_loss": round(sum(x["loss"] for x in steps["steps"]) / len(steps["steps"]), 6)})
            state["adapter"] = str(new)
            state["updates"] += len(steps["steps"])
        else:
            upd["skipped"] = "no informative group (equal rewards or missing results)"
        with open(OUT / "updates.jsonl", "a", encoding="utf-8") as f:
            f.write(json.dumps(upd) + "\n")
        state["iteration"] = it
        sf.write_text(json.dumps(state, indent=1), encoding="utf-8")
        wins = state["tier_history"][state["tier"]]
        log(f"[RL] it{it} done: {upd.get('informative_groups')} informative, mean_loss={upd.get('mean_loss')} "
            f"tier={state['tier']} games_at_tier={len(wins)} wins_last20={sum(wins[-20:])}")


# ------------------------------------------------------------------ dev debugging (no training)
def cmd_debug_match(a):
    """One capped match in the arena window with a given adapter; every Brain call captured to OUT/<name>/calls.jsonl."""
    sys.path.insert(0, str(ROOT))
    from tools.contract_sft import gpu_common as G
    d = OUT / a.name
    d.mkdir(parents=True, exist_ok=True)
    log = G.make_logger(d / "debug.log")
    assert _gpu_mib() < 4000, f"GPU not clear: {_gpu_mib()} MiB"
    token = secrets.token_hex(8)
    srv = subprocess.Popen([PY, "-m", "tools.contextual_brain.rl_vs_utility", "serve", "--adapter", a.adapter,
                            "--session", token, "--capture-dir", str(d)], cwd=str(ROOT),
                           stdout=open(d / "serve.stdout.log", "w"), stderr=subprocess.STDOUT)
    try:
        if not _wait_health(token):
            raise SystemExit("serve did not become ready")
        _post("/admin/tag", {"tag": "debug"})
        arena = Arena(log)
        mo = d / "match.json"
        err = arena.play({"family": a.family, "seed": a.seed, "tier": a.tier, "style": a.style,
                          "turn_cap": a.turn_cap, "session": token}, mo, 7200)
        log(f"[DEBUG] match done err={err!r} result={mo.read_text(encoding='utf-8')[:300] if mo.exists() else None}")
        arena.quit()
    finally:
        try:
            _post("/admin/shutdown", {})
        except Exception:  # noqa: BLE001
            pass
        try:
            srv.wait(timeout=120)
        except subprocess.TimeoutExpired:
            srv.kill()


def cmd_debug_group(a):
    """Verify the 3-window setup: one serve (adapter), one shared Hands worker, N arena windows playing the SAME
    episode / GX seed side by side. Results + every Brain call (tagged per window) land in OUT/<name>/.
    --backend vllm (Phase 1): the Brain server is the vLLM-backed drop-in in tools.brain_vllm
    (shim on 127.0.0.1:8096 + WSL vLLM engine); HF serve stays the default."""
    sys.path.insert(0, str(ROOT))
    from tools.contract_sft import gpu_common as G
    d = OUT / a.name
    d.mkdir(parents=True, exist_ok=True)
    log = G.make_logger(d / "debug.log")
    backend = getattr(a, "backend", "hf")
    BV = None
    if backend == "vllm":
        from tools.brain_vllm import client as BV
        log(f"[DEBUG] backend=vllm idle-engine: {BV.ensure_idle_engine(log)}")
    assert _gpu_mib() < 4000, f"GPU not clear: {_gpu_mib()} MiB"
    token = secrets.token_hex(8)
    senv = dict(os.environ, RL_DEBUG_CORRUPT_WINDOW=a.corrupt_window) if a.corrupt_window else None
    srv = None
    if BV is not None:
        h = BV.start(a.adapter, token, str(d), log=log,
                     env_extra={"RL_DEBUG_CORRUPT_WINDOW": a.corrupt_window} if a.corrupt_window else None)
        log(f"[DEBUG] vLLM shim ready sha={h.get('adapter_sha256')} session={token}")
    else:
        srv = subprocess.Popen([PY, "-m", "tools.contextual_brain.rl_vs_utility", "serve", "--adapter", a.adapter,
                                "--session", token, "--capture-dir", str(d)], cwd=str(ROOT), env=senv,
                               stdout=open(d / "serve.stdout.log", "w"), stderr=subprocess.STDOUT)
    hands = HandsService(log)
    arenas = []
    try:
        if not _wait_health(token):
            raise SystemExit("serve did not become ready")
        hands.start()
        _post("/admin/tags", {f"w{i}": f"debug_w{i}" for i in range(a.windows)})
        arenas = [Arena(log, i, {"LAYA_URL": hands.url}, WINDOW_GEOMS[i]) for i in range(a.windows)]
        job = {"family": a.family, "seed": a.seed, "tier": a.tier, "style": a.style, "turn_cap": a.turn_cap, "session": token}
        outs = [d / f"match_w{i}.json" for i in range(a.windows)]
        for ar, mo in zip(arenas, outs):
            ar.submit(job, mo, 7200)
        for ar, mo in zip(arenas, outs):
            err = ar.wait(mo, 7200)
            res = json.loads(mo.read_text(encoding="utf-8")) if mo.exists() else {"error": err}
            log(f"[DEBUG] {ar.dir.name} err={err!r} outcome={res.get('outcome')} turn={res.get('turn')} "
                f"score={score(res) if not err else None} units={res.get('units')} actions={res.get('red_actions')} "
                f"brain={res.get('brain')} straightness={(res.get('wander') or {}).get('mean_straightness')} gpu={_gpu_mib()}MiB")
    finally:
        for ar in arenas:
            ar.quit()
        hands.stop()
        if BV is not None:
            BV.stop(log=log)
        else:
            try:
                _post("/admin/shutdown", {})
            except Exception:  # noqa: BLE001
                pass
            try:
                srv.wait(timeout=120)
            except subprocess.TimeoutExpired:
                srv.kill()


def cmd_replay(a):
    """Re-ask the model captured prompts under variants. Input jsonl rows: {id, messages}; n samples each."""
    from tools.contract_sft import gpu_common as G
    import torch
    from peft import PeftModel
    rows = [json.loads(l) for l in open(a.inp, encoding="utf-8") if l.strip()]
    with G.gpu_lock("rl_vs_utility_replay", "RL_ROLLOUT"):
        tok = G.load_tokenizer()
        model = PeftModel.from_pretrained(G.load_base(), a.adapter)
        model.eval()
        with open(a.out, "w", encoding="utf-8") as f:
            for r in rows:
                enc = tok(G.render_prompt(tok, r["messages"]), add_special_tokens=False, return_tensors="pt").to("cuda:0")
                for k in range(a.n):
                    torch.manual_seed(1000 + k)
                    with torch.inference_mode():
                        out = model.generate(**enc, max_new_tokens=G.SAMPLING["max_new_tokens"], do_sample=True,
                                             temperature=G.SAMPLING["temperature"], top_p=G.SAMPLING["top_p"],
                                             top_k=G.SAMPLING["top_k"], repetition_penalty=G.SAMPLING["repetition_penalty"],
                                             pad_token_id=tok.pad_token_id, eos_token_id=tok.eos_token_id)
                    txt = tok.decode(out[0][enc["input_ids"].shape[1]:], skip_special_tokens=True)
                    f.write(json.dumps({"id": r["id"], "k": k, "prompt_tokens": int(enc["input_ids"].shape[1]), "raw": txt}) + "\n")
                    f.flush()
                del enc
                torch.cuda.empty_cache()


# ------------------------------------------------------------------ PHASE 4: full-episode GRPO (brain_pipeline_v1)
RL4_OUT = ROOT / "artifacts" / "brain_pipeline_v1" / "rl"
RL4_GROUPS_PER_ITER = 3        # 3 groups x 3 windows = 9 games per iteration
RL4_MAX_REVIEWS_PER_GAME = 12  # INITIAL + up to 8 evenly spaced reviews carry the game's advantage
RL4_WINDOWS = 3


def _rl4_calls(cap: Path, tag: str):
    """All captured Brain calls of one game (opening plan + reviews), in call order."""
    f = cap / "calls.jsonl"
    rows = []
    if f.exists():
        for line in f.read_text(encoding="utf-8").splitlines():
            if line.strip():
                r = json.loads(line)
                if r.get("tag") == tag and r.get("prompt_ids") and r.get("comp_ids"):
                    rows.append(r)
    init = [r for r in rows if r.get("request") == "VICTORY_INITIAL"]  # opening plan + every strategic replan
    rev = [r for r in rows if r.get("request") == "VICTORY_REVIEW"]
    if len(rev) > RL4_MAX_REVIEWS_PER_GAME:
        rev = [rev[min(len(rev) - 1, round(i * len(rev) / RL4_MAX_REVIEWS_PER_GAME))] for i in range(RL4_MAX_REVIEWS_PER_GAME)]
    return init + rev


def _rl4_free_gpu(log):
    """Stop the vLLM engine and the WSL VM (the VM keeps ~20 GB host RAM after an engine stop)."""
    from tools.brain_vllm import client as BV
    try:
        BV.stop(hard_engine=True, log=log)
    except Exception as e:  # noqa: BLE001
        log(f"[RL4] BV.stop note: {e}")
    subprocess.run(["wsl.exe", "--terminate", "Ubuntu-24.04"], capture_output=True, timeout=120)
    time.sleep(5)


# Curriculum ladder (user, 2026-10-04): easy opponent + fixed unit stats first, then the per-match
# movement/attack variation, then the GX tiers. Promote at 12 wins in the last 20 games of a stage.
# Unit movement/attack stay FIXED through ADV (user: first prove the task is learnable at all); the
# per-match variation comes only after ADV_FIXED is passed.
RL4_STAGES = ["STATIC_FIXED", "PASSIVE_FIXED", "BASIC_FIXED", "INTER_FIXED", "ADV_FIXED", "BASIC", "INTER", "ADV"]


def _rl4_stage_job(stage: str, g: int):
    """stage -> (opponent tier for the watch driver, rules family). *_FIXED = stock movement/attack."""
    opp = stage.split("_")[0]
    return opp, ("fixed" if stage.endswith("_FIXED") else FAMILIES[g % 2])


def _rl4_probe(log):
    """The served policy must write a parseable opening plan for a known prompt, else stop (no garbage training)."""
    rows = [json.loads(l) for l in (ROOT / "artifacts" / "brain_pipeline_v1" / "s1_sft" / "sft_rows.jsonl")
            .read_text(encoding="utf-8").splitlines() if l.strip()]
    pid = next(r["prompt_id"] for r in rows if r.get("kind") == "INITIAL_REPLAY" and r["split"] == "dev")
    msgs = next(p["messages"] for p in json.loads((ROOT / "artifacts" / "brain_pipeline_v1" / "s1_sft" / "sft_prompts.json")
                                                  .read_text(encoding="utf-8")) if p["prompt_id"] == pid)
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}/v1/chat/completions", data=json.dumps(
        {"model": "rl_policy", "messages": msgs}).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=300) as r:
        txt = json.loads(r.read())["choices"][0]["message"]["content"]
    try:
        doc = json.loads(txt.strip())
        ok = isinstance(doc, dict) and isinstance(doc.get("phases"), list) and len(doc["phases"]) >= 1
    except ValueError:
        ok = False
    log(f"[RL4] generation probe {'OK' if ok else 'FAILED'} ({len(txt)} chars)")
    if not ok:
        raise SystemExit("policy generation probe failed (unparseable opening plan): %r" % txt[:300])


def cmd_rl(a):
    """Phase 4 RL: the Brain (init S1) vs GX Utility, 3 visible windows per group, vLLM rollouts, every Brain
    call of a game (opening plan + reviews) trained with that game's group-relative advantage.
    Never plays and trains at the same time: rollout (vLLM + Hands up) -> both down + WSL stopped -> train."""
    _selfcheck()
    sys.path.insert(0, str(ROOT))
    from tools.contract_sft import gpu_common as G
    from tools.brain_vllm import client as BV
    RL4_OUT.mkdir(parents=True, exist_ok=True)
    log = G.make_logger(RL4_OUT / "rl.log")
    sf = RL4_OUT / "state.json"
    state = json.loads(sf.read_text(encoding="utf-8")) if sf.exists() else \
        {"iteration": 0, "group": 0, "updates": 0, "tier": RL4_STAGES[0], "adapter": a.init_adapter,
         "tier_history": {t: [] for t in TIERS}, "promotions": []}
    hands = HandsService(log)
    arenas = [Arena(log, i, {"LAYA_URL": hands.url}, WINDOW_GEOMS[i]) for i in range(RL4_WINDOWS)]
    for _ in range(a.iterations):
        if (RL4_OUT / "STOP").exists():
            log("[RL4] STOP file present; exiting")
            break
        it = state["iteration"] + 1
        itdir = RL4_OUT / "iterations" / f"it{it:04d}"
        cap = itdir / "captures"
        cap.mkdir(parents=True, exist_ok=True)
        token = secrets.token_hex(8)
        _rl4_free_gpu(log)  # never inherit an engine (a sleeping one emits random tokens)
        BV.start(state["adapter"], token, str(cap), log=log)
        _rl4_probe(log)     # one REAL opening plan must parse before any game counts
        hands.start()
        log(f"[RL4] it{it} ROLLOUT adapter={state['adapter']} tier={state['tier']} gpu={_gpu_mib()}MiB")
        rng = random.Random(f"rl4:{it}")
        groups = []
        for _g in range(RL4_GROUPS_PER_ITER):
            g = state["group"]
            seed, tier, style = 100000 + g, state["tier"], rng.choice(STYLES)
            opp, family = _rl4_stage_job(tier, g)
            tags = [f"g{g:05d}_w{i}" for i in range(RL4_WINDOWS)]
            _post("/admin/tags", {f"w{i}": tags[i] for i in range(RL4_WINDOWS)})
            job = {"family": family, "seed": seed, "tier": opp, "style": style, "turn_cap": TURN_CAP, "session": token}
            outs = [itdir / "matches" / f"{t}.json" for t in tags]
            outs[0].parent.mkdir(exist_ok=True)
            for ar, mo in zip(arenas, outs):
                ar.submit(job, mo, 7200)
                time.sleep(5)
            items = []
            for ar, mo, tag in zip(arenas, outs, tags):
                err = ar.wait(mo, 7200)
                res = json.loads(mo.read_text(encoding="utf-8")) if mo.exists() else {"error": err or "no result"}
                bad = "error" in res or res.get("outcome") in ("ABORTED", "TIMEOUT") or \
                    int((res.get("brain") or {}).get("brain_failures", 0)) > 0
                flips = 0 if bad else count_flips(_game_task_changes(cap, tag))
                s = {"reward": None, "win": False, "kind": "ERROR"} if bad else score(res, flips)
                calls = [] if bad else _rl4_calls(cap, tag)
                row = {"iteration": it, "group": g, "tag": tag, "tier": tier, "gx_profile": f"GX_{tier}_{style}",
                       "family": family, "seed": seed, **s, "outcome": res.get("outcome"), "turn": res.get("turn"),
                       "units": res.get("units"), "hq": res.get("hq"), "flips": flips, "red_actions": res.get("red_actions"), "brain": res.get("brain"),
                       "straightness": (res.get("wander") or {}).get("mean_straightness"), "calls_trained": len(calls),
                       "adapter": state["adapter"], "error": res.get("error")}
                with open(RL4_OUT / "games.jsonl", "a", encoding="utf-8") as f:
                    f.write(json.dumps(row) + "\n")
                log(f"[RL4] {tag} GX_{tier}_{style} {family}:{seed} -> {s['kind']} r={s['reward']} turn={res.get('turn')} "
                    f"units={((res.get('units') or {}).get('red') or {}).get('alive')}/10 attacks={(res.get('red_actions') or {}).get('attacks')} "
                    f"calls={len(calls)} flips={flips} blue_hq={((res.get('hq') or {}).get('blue') or {}).get('end')}")
                if s["kind"] != "ERROR":
                    state["tier_history"].setdefault(tier, []).append(bool(s["win"]))
                    items.append((s["reward"], calls))
            state["group"] += 1
            if len(items) >= 2 and all(c for _, c in items):
                adv = advantages([r for r, _ in items])
                if any(abs(x) > 1e-9 for x in adv):
                    groups.append({"group": g, "rewards": [r for r, _ in items], "items": [
                        {"prompt_ids": c["prompt_ids"], "comp_ids": c["comp_ids"], "adv": x}
                        for (_, calls), x in zip(items, adv) for c in calls]})
            hist = state["tier_history"].setdefault(state["tier"], [])
            if promote(hist) and RL4_STAGES.index(state["tier"]) < len(RL4_STAGES) - 1:
                nxt = RL4_STAGES[RL4_STAGES.index(state["tier"]) + 1]
                state["promotions"].append({"from": state["tier"], "to": nxt, "iteration": it, "group": g,
                                            "games_at_tier": len(hist), "wins_last20": sum(hist[-PROMOTE_WINDOW:]),
                                            "adapter": state["adapter"]})
                log(f"[RL4] PROMOTED {state['tier']} -> {nxt} (wins {sum(hist[-PROMOTE_WINDOW:])}/{PROMOTE_WINDOW})")
                state["tier"] = nxt
        # ---- rollout over: Brain + Hands out of VRAM, WSL VM stopped (host RAM), windows stay open idle
        hands.stop()
        _rl4_free_gpu(log)
        upd = {"iteration": it, "informative_groups": len(groups), "groups": RL4_GROUPS_PER_ITER}
        if groups:
            assert _gpu_mib() < 6000, f"GPU not clear before train: {_gpu_mib()} MiB"
            (itdir / "samples.json").write_text(json.dumps(groups), encoding="utf-8")
            new = itdir / "adapter"
            r = subprocess.run([PY, "-m", "tools.contextual_brain.rl_vs_utility", "train", "--adapter", state["adapter"],
                                "--samples", str(itdir / "samples.json"), "--out", str(new)], cwd=str(ROOT))
            if r.returncode != 0 or not (new / "adapter_model.safetensors").exists():
                raise SystemExit(f"train phase failed rc={r.returncode}")
            steps = json.loads((new / "TRAIN_STEPS.json").read_text(encoding="utf-8"))
            upd.update({"steps": steps["steps"], "memory": steps["memory"],
                        "mean_loss": round(sum(x["loss"] for x in steps["steps"]) / len(steps["steps"]), 6)})
            state["adapter"] = str(new)
            state["updates"] += len(steps["steps"])
        else:
            upd["skipped"] = "no informative group (equal rewards or missing results)"
        with open(RL4_OUT / "updates.jsonl", "a", encoding="utf-8") as f:
            f.write(json.dumps(upd) + "\n")
        state["iteration"] = it
        sf.write_text(json.dumps(state, indent=1), encoding="utf-8")
        wins = state["tier_history"].setdefault(state["tier"], [])
        log(f"[RL4] it{it} done: {upd.get('informative_groups')} informative, mean_loss={upd.get('mean_loss')} "
            f"tier={state['tier']} games_at_tier={len(wins)} wins_last20={sum(wins[-20:])}")
    for ar in arenas:
        ar.quit()



if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("serve")
    s.add_argument("--adapter", required=True)
    s.add_argument("--session", required=True)
    s.add_argument("--capture-dir", required=True)
    s.add_argument("--port", type=int, default=PORT, help="listen port (default 8096)")
    t = sub.add_parser("train")
    t.add_argument("--adapter", required=True)
    t.add_argument("--samples", required=True)
    t.add_argument("--out", required=True)
    dm = sub.add_parser("debug_match")
    dm.add_argument("--name", required=True)
    dm.add_argument("--adapter", default=str(S0B))
    dm.add_argument("--family", default="mild")
    dm.add_argument("--seed", type=int, default=100000)
    dm.add_argument("--tier", default="BASIC")
    dm.add_argument("--style", default="SPEARHEAD")
    dm.add_argument("--turn-cap", type=int, default=14)
    dg = sub.add_parser("debug_group")
    dg.add_argument("--name", required=True)
    dg.add_argument("--adapter", default=str(S0B))
    dg.add_argument("--windows", type=int, default=3)
    dg.add_argument("--family", default="mild")
    dg.add_argument("--seed", type=int, default=100000)
    dg.add_argument("--tier", default="BASIC")
    dg.add_argument("--style", default="SPEARHEAD")
    dg.add_argument("--turn-cap", type=int, default=8)
    dg.add_argument("--corrupt-window", default="", help="debug: e.g. w2 -> that window's first review is broken JSON")
    dg.add_argument("--backend", choices=["hf", "vllm"], default="hf",
                    help="Brain server backend for the group: hf = HF NF4 serve (default); "
                         "vllm = tools.brain_vllm drop-in (Phase 1)")
    rp = sub.add_parser("replay")
    rp.add_argument("--adapter", default=str(S0B))
    rp.add_argument("--inp", required=True)
    rp.add_argument("--out", required=True)
    rp.add_argument("--n", type=int, default=4)
    rl = sub.add_parser("rl")
    rl.add_argument("--iterations", type=int, default=10 ** 6)
    rl.add_argument("--init-adapter", default=str(ROOT / "artifacts" / "brain_pipeline_v1" / "candidate_S2"))
    r = sub.add_parser("run")
    r.add_argument("--iterations", type=int, default=10 ** 6)
    a = ap.parse_args()
    {"serve": cmd_serve, "train": cmd_train, "run": cmd_run, "debug_match": cmd_debug_match, "debug_group": cmd_debug_group, "rl": cmd_rl, "replay": cmd_replay}[a.cmd](a)
