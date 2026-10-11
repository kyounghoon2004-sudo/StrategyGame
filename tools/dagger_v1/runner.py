"""DAgger takeover collection (2026-10-11), collapse mission (WATCH_MISSION=remaining30_hq_guard, rout min 0, no HQ win).

A source game = a 9B (Qwen3.5-9B SFT) game with its recorded answers.  A takeover attempt replays it with the 9B's own
recorded answers up to turn T-1 (Godot is deterministic given seed + answers; every replayed request is checked against
the recorded request by hash) and answers every request from T on with a TEACHER (opencode step-5-preview-free, or agy
gemini-3.8-flash-medium).  Quota / usage / rate-limit / transport / timeout failures are TECHNICAL: the attempt is
aborted, its real teacher answers kept, and it is resumed later from the same turn (deterministic replay again).
A source game can also be (re)generated live from the 9B served by vLLM on :8000 (kind "gen").

  python -m tools.dagger_v1.runner run [--windows 10] [--slot 6]      # the campaign (stop rules: see should_stop)
  python -m tools.dagger_v1.runner replay SID[,SID..]                 # replay exactness check (no teacher)
  python -m tools.dagger_v1.runner pool                                # rebuild sources from the 9B game dirs
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import random
import re
import secrets
import subprocess
import sys
import threading
import time
import concurrent.futures
from pathlib import Path

from tools.dagger_v1 import teachers as TC

ROOT = Path(__file__).resolve().parents[2]
BP = ROOT / "artifacts" / "brain_pipeline_v1"
D = BP / "dagger_v1"
SIZES = "6,7,8,9,10,11,12,13,14,15,16"
STAND = '{"orders": {}}'
TEACHERS = ("opencode", "agy")
SRC_DIRS = [
    ("b536", BP / "sft_mix_v3b/baseline536/collapse"),
    ("s300", BP / "sft_mix_v3b/smoke/step300/collapse"),
    ("s450", BP / "sft_mix_v3b/smoke/step450/collapse"),
    ("s536", BP / "sft_mix_v3b/smoke/step536/collapse"),
    ("v3s150", Path("D:/d/Game development/Demon slayer/StrategyGame/artifacts/brain_pipeline_v1/sft_mix_v3/smoke/step150/collapse")),
]
WIN_STOP, ROW_STOP, HOURS_STOP, PLAYED_STOP, RATE_STOP = 60, 1500, 12.0, 30, 0.15
GEN_SEED0 = 9700000


def jdump(p, obj):
    p = Path(p)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(p.suffix + ".tmp")
    tmp.write_text(json.dumps(obj, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(tmp, p)


def jload(p, default=None):
    try:
        return json.loads(Path(p).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def mhash(msgs):
    return hashlib.sha1(json.dumps(msgs, sort_keys=True, ensure_ascii=False).encode("utf-8")).hexdigest()[:16]


def kill_ratio(units, hq_blue_end):
    """Share of BLUE's non-HQ units destroyed (units counts include the HQ)."""
    b = (units or {}).get("blue") or {}
    n = int(b.get("start", 0)) - 1
    alive = int(b.get("alive", 0)) - (1 if int(hq_blue_end or 0) > 0 else 0)
    return round(1 - alive / n, 4) if n > 0 else 0.0


def kind_of(res, RV):
    if res.get("outcome") in ("ABORTED",) or "error" in res:
        return "TECH_ARENA"
    return RV.score(res)["kind"]


# ----------------------------------------------------------------------------------------------- sources
def build_sources():
    """sources/<sid>.json from the 9B smoke / baseline game dirs (answers per turn, request hashes)."""
    out = {}
    for short, d in SRC_DIRS:
        if not (d / "results.jsonl").exists() or not (d / "raw" / "calls.jsonl").exists():
            continue
        res = {}
        for l in (d / "results.jsonl").read_text(encoding="utf-8").splitlines():
            if l.strip():
                r = json.loads(l)
                res[r["game"]] = r  # a later row of the same game wins
        segs = {}
        for l in (d / "raw" / "calls.jsonl").read_text(encoding="utf-8").splitlines():
            if not l.strip():
                continue
            c = json.loads(l)
            if c.get("request") != "VICTORY_COMMAND" or c.get("served") != "LOCAL":
                continue
            s = segs.setdefault(c["tag"], [[]])
            if s[-1] and int(c["turn"]) < int(s[-1][-1]["turn"]):
                s.append([])  # the same game played again from turn 1
            s[-1].append(c)
        for g, r in res.items():
            if g not in segs or r.get("kind") in ("INVALID", "ERROR") or r.get("fault") or r.get("error") or \
                    int(r.get("turn") or 0) <= 2 or r.get("outcome") == "ABORTED":
                continue
            calls = segs[g][-1]
            ans, hs = {}, {}
            for c in calls:
                ans.setdefault(str(c["turn"]), []).append(c["raw"] if isinstance(c["raw"], str) else json.dumps(c["raw"]))
                hs.setdefault(str(c["turn"]), []).append(mhash(c["messages"]))
            if str(max(int(t) for t in ans)) != str(len(ans)):  # turns 1..n complete
                continue
            sid = "%s_s%d" % (short, int(r["seed"]))
            out[sid] = {"sid": sid, "kind": "recorded", "game": g, "seed": int(r["seed"]), "tier": r["tier"],
                        "style": r["style"], "family": r["family"], "sizes": SIZES, "answers": ans, "hashes": hs,
                        "last_turn": max(int(t) for t in ans), "final": {"kind": r["kind"], "outcome": r.get("outcome"),
                        "turn": r.get("turn"), "units": r.get("units"), "hq": r.get("hq")}, "origin": str(d)}
    return out


def t_candidates(src):
    """First turn with the 9B's second consecutive {} answer, plus 20, 30, 40; only turns the 9B actually played."""
    empty = re.compile(r'"orders"\s*:\s*\{\s*\}')
    last = src["last_turn"]
    ts = []
    for t in range(2, last + 1):
        if empty.search(src["answers"][str(t)][-1]) and empty.search(src["answers"][str(t - 1)][-1]):
            ts.append(t)
            break
    ts += [20, 30, 40]
    out = []
    for t in ts:
        if 2 <= t <= last and t not in out:
            out.append(t)
    return out


# ----------------------------------------------------------------------------------------------- campaign
class Campaign:
    def __init__(self, a):
        self.a = a
        self.lock = threading.RLock()
        self.t0 = time.time()
        self.sources = {}
        self.attempts = {}
        self.active = {}  # tag -> live attempt state
        self.cool = {t: 0.0 for t in TEACHERS}
        self.cool_n = {t: 0 for t in TEACHERS}
        self.disabled = {}
        self.cap = {"opencode": a.cap, "agy": a.cap}
        self.gen_active = 0
        self.gen_seed = GEN_SEED0
        self.gen_n = 0
        for f in sorted((D / "sources").glob("*.json")):
            s = jload(f)
            if s:
                self.sources[s["sid"]] = s
        for f in sorted((D / "attempts").glob("*.json")):
            x = jload(f)
            if x:
                if x["status"] == "RUNNING":
                    x["status"] = "TECH_WAIT"  # the runner died while it played: resume from its kept answers
                self.attempts[x["aid"]] = x
        self.gen_n = len([s for s in self.sources.values() if s["kind"] == "gen"])
        self.gen_seed = GEN_SEED0 + self.gen_n
        self.seed_all()

    # --- attempt bookkeeping
    def seed_all(self):
        with self.lock:
            for sid, s in self.sources.items():
                if s["final"].get("kind") == "WIN":  # the 9B finished it itself: no takeover state
                    continue
                for T in t_candidates(s):
                    for tch in TEACHERS:
                        aid = "%s_T%d_%s_r0" % (sid, T, tch)
                        if aid not in self.attempts:
                            self.attempts[aid] = {"aid": aid, "sid": sid, "T": T, "teacher": tch, "rep": 0,
                                                  "status": "PENDING", "teacher_answers": {}, "hashes": {},
                                                  "tech": [], "starts": 0}
                            self.save_attempt(aid)

    def save_attempt(self, aid):
        jdump(D / "attempts" / (aid + ".json"), self.attempts[aid])

    def add_repeats(self):
        """Every (state, teacher) done: another sample of the same states (new teacher randomness), rep+1."""
        with self.lock:
            reps = {}
            for x in self.attempts.values():
                reps.setdefault((x["sid"], x["T"], x["teacher"]), []).append(x["rep"])
            for (sid, T, tch), rs in list(reps.items()):
                if tch in self.disabled:
                    continue
                r = max(rs) + 1
                aid = "%s_T%d_%s_r%d" % (sid, T, tch, r)
                self.attempts[aid] = {"aid": aid, "sid": sid, "T": T, "teacher": tch, "rep": r, "status": "PENDING",
                                      "teacher_answers": {}, "hashes": {}, "tech": [], "starts": 0}
                self.save_attempt(aid)

    def played(self):
        return [x for x in self.attempts.values() if x["status"] == "DONE"]

    def counts(self):
        done = self.played()
        wins = [x for x in done if x["result"]["kind"] == "WIN"]
        rows = sum(x["result"]["n_rows"] for x in wins)
        return done, wins, rows

    def should_stop(self):
        if (D / "STOP").exists():
            return "STOP file"
        done, wins, rows = self.counts()
        if len(wins) >= WIN_STOP:
            return "rule (a): %d takeover games won" % len(wins)
        if rows >= ROW_STOP:
            return "rule (a): %d rows from won games" % rows
        if time.time() - self.t0 > HOURS_STOP * 3600:
            return "rule (b): 12 hours"
        if len(done) >= PLAYED_STOP and len(wins) / len(done) < RATE_STOP:
            return "rule (c): %d played, win rate %.1f%% < 15%%" % (len(done), 100 * len(wins) / len(done))
        return ""

    def pick(self):
        """-> ("attempt", att) | ("gen", None) | None."""
        now = time.time()
        with self.lock:
            if self.should_stop():
                return None
            act = {t: sum(1 for x in self.active.values() if x.get("teacher") == t) for t in TEACHERS}
            cand = [x for x in self.attempts.values()
                    if x["status"] in ("PENDING", "TECH_WAIT") and x["teacher"] not in self.disabled
                    and now >= x.get("not_before", 0) and now >= self.cool[x["teacher"]]
                    and act[x["teacher"]] < self.cap[x["teacher"]]]
            # per-teacher rule (c): a teacher with >= 30 own played games and < 15% wins is retired
            cand.sort(key=lambda x: (x["rep"], x["T"], x["starts"], x["sid"]))
            nsrc = len(self.sources)
            gen_pref = self.gen_active < self.a.gen_windows and self.gen_n < self.a.max_gen and \
                (not cand or nsrc < 40) and time.time() - getattr(self, "last_gen", 0) > 1
            if gen_pref and (not cand or self.gen_n % 3 == 0 or len(cand) < 4):
                self.gen_active += 1
                self.last_gen = time.time()
                return ("gen", None)
            if cand:
                x = cand[0]
                x["status"] = "RUNNING"
                x["starts"] += 1
                self.active[x["aid"]] = {"teacher": x["teacher"], "aid": x["aid"]}
                return ("attempt", x)
            if not any(x["status"] in ("PENDING", "TECH_WAIT", "RUNNING") for x in self.attempts.values()
                       if x["teacher"] not in self.disabled):
                self.add_repeats()
            return ("wait", None)

    # --- cooldowns
    def set_cooldown(self, teacher, e):
        with self.lock:
            self.cool_n[teacher] += 1
            if e.cause == "quota_or_rate_limit":
                w = e.wait_s or min(310 * 60, 30 * 60 * 2 ** (self.cool_n[teacher] - 1))
            else:
                w = min(30 * 60, 120 * 2 ** (self.cool_n[teacher] - 1))
            self.cool[teacher] = max(self.cool[teacher], time.time() + w)
            return w

    def cooldown_left(self, teacher):
        return max(0.0, self.cool[teacher] - time.time())

    # --- reporting
    def status_md(self, reason=""):
        with self.lock:
            done, wins, rows = self.counts()
            tech = [e for x in self.attempts.values() for e in x.get("tech", [])]
            L = ["# DAgger v1 takeover 수집 상태 (%s)" % time.strftime("%Y-%m-%d %H:%M:%S"),
                 "",
                 "- 경과: %.1f시간, 소스 게임 %d (녹화 %d, 9B 생성 %d), 시도 %d" % (
                     (time.time() - self.t0) / 3600, len(self.sources),
                     len([s for s in self.sources.values() if s["kind"] == "recorded"]), self.gen_n, len(self.attempts)),
                 "- 교사 플레이 완료(비-TECHNICAL) %d판, 승리 %d판 (승률 %s), 승리판 행 %d" % (
                     len(done), len(wins), "%.1f%%" % (100 * len(wins) / len(done)) if done else "-", rows),
                 "- 상태: %s" % (reason or "진행 중"), ""]
            L += ["## 교사별", "| 교사 | 완료 | 승 | 미달성 | 패배 | 무효 | 승률 | 평균 킬비율 | 승리 행 | 부분 행 |",
                  "|---|---|---|---|---|---|---|---|---|---|"]
            for t in TEACHERS:
                xs = [x for x in done if x["teacher"] == t]
                k = lambda kd: len([x for x in xs if x["result"]["kind"] == kd])
                kr = [x["result"]["kill_ratio"] for x in xs]
                wr = sum(x["result"]["n_rows"] for x in xs if x["result"]["kind"] == "WIN")
                pr = sum(x["result"]["n_rows"] for x in xs if x["result"]["kind"] != "WIN")
                L.append("| %s | %d | %d | %d | %d | %d | %s | %s | %d | %d |" % (
                    t, len(xs), k("WIN"), k("NOT_ACHIEVED"), k("LOSS"), k("INVALID"),
                    "%.0f%%" % (100 * k("WIN") / len(xs)) if xs else "-",
                    "%.2f" % (sum(kr) / len(kr)) if kr else "-", wr, pr))
            L += ["", "## 시작 턴(T)별", "| T | 완료 | 승 | 평균 킬비율 |", "|---|---|---|---|"]
            for T in sorted({x["T"] for x in done}):
                xs = [x for x in done if x["T"] == T]
                L.append("| %d | %d | %d | %.2f |" % (T, len(xs), len([x for x in xs if x["result"]["kind"] == "WIN"]),
                                                    sum(x["result"]["kill_ratio"] for x in xs) / len(xs)))
            L += ["", "## TECHNICAL (교사 패배 아님, 승률에서 제외)", "| 교사 | 원인 | 건수 |", "|---|---|---|"]
            by = {}
            for e in tech:
                by[(e["teacher"], e["cause"])] = by.get((e["teacher"], e["cause"]), 0) + 1
            for (t, c), n in sorted(by.items()):
                L.append("| %s | %s | %d |" % (t, c, n))
            if not by:
                L.append("| - | - | 0 |")
            L += ["", "- 대기 중 쿨다운: " + ", ".join("%s %.0f분" % (t, self.cooldown_left(t) / 60) for t in TEACHERS),
                  "- 비활성 교사: %s" % (self.disabled or "없음"),
                  "- 진행/대기 시도: %d / %d" % (len([x for x in self.attempts.values() if x["status"] == "RUNNING"]),
                                             len([x for x in self.attempts.values() if x["status"] in ("PENDING", "TECH_WAIT")]))]
        (D / "STATUS.md").write_text("\n".join(L) + "\n", encoding="utf-8")

    def write_rows(self):
        win, part = [], []
        for x in self.played():
            rf = D / "rows" / (x["aid"] + ".jsonl")
            if not rf.exists() or x["result"]["kind"] == "INVALID":
                continue
            for l in rf.read_text(encoding="utf-8").splitlines():
                r = json.loads(l)
                if not r.get("valid"):
                    continue
                r.update(outcome=x["result"]["kind"], kill_ratio=x["result"]["kill_ratio"], game_turn=x["result"]["turn"])
                (win if x["result"]["kind"] == "WIN" else part).append(r)
        for r in part:
            r["high_kill"] = r["kill_ratio"] >= 0.5
        jdump(D / "rows_winners.json", win)
        jdump(D / "rows_partial.json", part)
        return len(win), len(part)


def valid_row(messages, completion):
    """JSON with an orders object whose unit ids (and every id-like token) exist in the game's own messages."""
    try:
        d = json.loads(completion)
    except ValueError:
        return False, "invalid_json"
    if not isinstance(d, dict) or not isinstance(d.get("orders"), dict):
        return False, "no_orders_object"
    known = set(re.findall(r"\b[RB]_[A-Z]+_\d+\b", "\n".join(str(m.get("content", "")) for m in messages)))
    for tok in re.findall(r"\b[RB]_[A-Z]+_\d+\b", completion):
        if tok not in known:
            return False, "unknown_unit_id:" + tok
    return True, ""


# ----------------------------------------------------------------------------------------------- server
class Server(threading.Thread):
    def __init__(self, camp, md, stop):
        super().__init__(daemon=True)
        self.c, self.md, self.stop_ev = camp, md, stop
        self.pool = concurrent.futures.ThreadPoolExecutor(24)
        self.sess = {}

    def run(self):
        from tools.plan_search.brain_io import _resp, _try_claim
        while not self.stop_ev.is_set():
            for f in sorted(self.md.glob("req_*.json")):
                if _resp(f).exists() or not _try_claim(f, "DAGGER"):
                    continue
                self.pool.submit(self.handle, f)
            time.sleep(0.1)

    def reply(self, f, text):
        from tools.plan_search.brain_io import _resp
        p = _resp(f)
        tmp = p.with_suffix(".tmp")
        tmp.write_text(text, encoding="utf-8")
        os.replace(tmp, p)

    def handle(self, f):
        text = STAND
        try:
            r = json.loads(f.read_text(encoding="utf-8-sig"))
            if r.get("request") == "VICTORY_COMMAND":
                text = self.answer(r)
        except Exception as e:  # noqa: BLE001  (never leave the game waiting)
            sys.stderr.write("handle error %r\n" % (e,))
        self.reply(f, text)

    def answer(self, r):
        c = self.c
        tag, t, msgs = str(r.get("tag")), int(r.get("turn", 0)), r.get("messages") or []
        att = c.active.get(tag)
        if att is None or att.get("aborted"):
            return STAND
        k = att["seq"].get(t, 0)
        att["seq"][t] = k + 1
        h = mhash(msgs)
        mode = att["mode"]
        if mode == "gen":
            from tools.plan_search.cloud_brain import local_command
            content, meta = local_command(msgs, url=self.c.a.local_url, model="policy", no_think=True,
                                          answer_tokens=2000, tries=1)
            if not content:
                content = json.dumps({"orders": {}, "skipped": "error"})
            att["answers"].setdefault(str(t), []).append(content)
            att["hashes_rec"].setdefault(str(t), []).append(h)
            return content
        src = att["src"]
        if t < att["T"] or mode == "replay":
            lst = src["answers"].get(str(t))
            if not lst:
                att.update(aborted=True, tech={"cause": "replay_diverged", "detail": "no recorded answer for turn %d" % t})
                return STAND
            hs = src["hashes"].get(str(t), [])
            if k < len(hs) and hs[k] != h:
                att.update(aborted=True, tech={"cause": "replay_diverged",
                                               "detail": "request hash mismatch at turn %d (seq %d)" % (t, k)})
                att.setdefault("mismatch", []).append(t)
                return STAND
            att["replayed"] = att.get("replayed", 0) + 1
            return lst[min(k, len(lst) - 1)]
        # takeover turn
        a = att["rec"]
        got = a["teacher_answers"].get(str(t), [])
        hh = a["hashes"].setdefault(str(t), [])
        if k < len(got):
            if k < len(hh) and hh[k] != h:
                att.update(aborted=True, tech={"cause": "replay_diverged", "detail": "resume hash mismatch turn %d" % t})
                return STAND
            return got[k]
        sess = att["sess"]
        try:
            raw = self.ask(att, sess, msgs, t)
        except TC.TechnicalError as e:
            att.update(aborted=True, tech={"cause": e.cause, "detail": e.detail, "turn": t, "wait_s": e.wait_s})
            return STAND
        text, ok = TC.normalise(raw)
        got.append(text)
        hh.append(h)
        a["teacher_answers"][str(t)] = got
        valid, why = valid_row(msgs, text)
        row = {"game": a["aid"], "source_game": a["sid"], "T": a["T"], "turn": t, "teacher": a["teacher"],
               "messages": msgs, "completion": text, "raw_completion": raw if raw != text else None,
               "valid": valid, "invalid_reason": why, "replayed_after_resume": False}
        with (D / "rows" / (a["aid"] + ".jsonl")).open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")
        c.save_attempt(a["aid"])
        with c.lock:
            c.cool_n[a["teacher"]] = 0
        return text

    def ask(self, att, sess, msgs, t):
        c, tch = self.c, att["rec"]["teacher"]
        for i in range(3):
            left = c.cooldown_left(tch)
            if left > 0:
                if left <= 600:
                    time.sleep(left + 1)
                else:
                    raise TC.TechnicalError("cooldown_active", "teacher in cooldown, no inference sent", left)
            try:
                return sess.ask(msgs, t)
            except TC.TechnicalError as e:
                w = c.set_cooldown(tch, e)
                e.wait_s = w
                if e.cause in ("timeout", "transport_or_provider_error", "empty_response") and i < 2 and w <= 600:
                    time.sleep(w + 1)
                    continue
                raise
        raise TC.TechnicalError("retries_exhausted", "")


# ----------------------------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["run", "replay", "pool"])
    ap.add_argument("arg", nargs="?", default="")
    ap.add_argument("--slot", type=int, default=6)
    ap.add_argument("--proxy-port", type=int, default=8126)
    ap.add_argument("--brain-port", type=int, default=8136)
    ap.add_argument("--windows", type=int, default=10)
    ap.add_argument("--cap", type=int, default=4, help="max concurrent games per teacher")
    ap.add_argument("--gen-windows", type=int, default=2)
    ap.add_argument("--max-gen", type=int, default=40)
    ap.add_argument("--only", default="", help="comma list: teachers to use (smoke); default both")
    ap.add_argument("--max-attempts", type=int, default=0, help="smoke: stop after this many started attempts")
    ap.add_argument("--sids", default="", help="restrict to these source ids (comma)")
    ap.add_argument("--Ts", default="", help="restrict to these T values (comma)")
    ap.add_argument("--local-url", default="http://127.0.0.1:8000/v1/chat/completions")
    a = ap.parse_args()
    D.mkdir(parents=True, exist_ok=True)
    for d in ("sources", "attempts", "rows", "teachers", "games"):
        (D / d).mkdir(exist_ok=True)
    if a.cmd == "pool":
        for sid, s in build_sources().items():
            if not (D / "sources" / (sid + ".json")).exists():
                jdump(D / "sources" / (sid + ".json"), s)
            print(sid, s["last_turn"], s["final"]["kind"], t_candidates(s))
        return
    for sid, s in build_sources().items():  # recorded sources are always (re)read from their dirs
        if not (D / "sources" / (sid + ".json")).exists():
            jdump(D / "sources" / (sid + ".json"), s)
    camp = Campaign(a)
    if a.only:
        for t in TEACHERS:
            if t not in a.only.split(","):
                camp.disabled[t] = "not selected"
    if a.sids:
        keep = set(a.sids.split(","))
        for x in camp.attempts.values():
            if x["sid"] not in keep:
                x["status"] = "SKIPPED"
    if a.Ts:
        keepT = {int(v) for v in a.Ts.split(",")}
        for x in camp.attempts.values():
            if x["T"] not in keepT and x["status"] == "PENDING":
                x["status"] = "SKIPPED"

    os.environ.update({"WATCH_MISSION": "remaining30_hq_guard", "WATCH_ROUT_MIN": "0", "WATCH_NO_HQ_WIN": "1"})
    from tools.contextual_brain import rl_vs_utility as RV
    from tools.brain_review.harvest import post, wait_port
    from tools.plan_search.eval_plans import Hands
    RV.OUT = D / "arenas"
    RV.OUT.mkdir(exist_ok=True)
    (RV.OUT / "HEADLESS").write_text("dagger_v1", encoding="utf-8")
    log_lock = threading.Lock()

    def log(m):
        line = time.strftime("%m-%d %H:%M:%S ") + m
        with log_lock:
            print(line, flush=True)
            with open(D / "run.log", "a", encoding="utf-8") as f:
                f.write(line + "\n")

    md = D / "manual"
    if md.exists() and any(md.iterdir()):
        md.rename(D / ("manual_prev_%d" % int(time.time())))
    md.mkdir(exist_ok=True)
    token = secrets.token_hex(8)
    (D / "raw").mkdir(exist_ok=True)
    proxy = subprocess.Popen([RV.PY, "-m", "tools.brain_review.teacher_proxy", "--session", token, "--capture-dir",
                              str(D / "raw"), "--port", str(a.proxy_port), "--brain-port", str(a.brain_port),
                              "--default-mode", "TEACHER", "--initial-stub", "--manual-dir", str(md)],
                             cwd=str(RV.ROOT), stdout=open(D / "raw" / "proxy.log", "a"), stderr=subprocess.STDOUT)
    hands = Hands(a.slot, D, log, "cpu")
    arenas = []
    stop_ev = threading.Event()
    srv = Server(camp, md, stop_ev)
    started = {"n": 0}
    try:
        if not wait_port(a.proxy_port, token, 180):
            raise SystemExit("teacher proxy did not come up")
        hands.start()
        url = "http://127.0.0.1:%d/v1/chat/completions"
        for i in range(a.windows):
            env = {"LAYA_URL": hands.url, "BRAIN_CONTRACT_MODE": "unalloc_v1", "SELFPLAY_GENERAL_TIMEOUT_SEC": "1800",
                   "WATCH_STRATEGIC_REPLAN_TURNS": "0", "WATCH_RED_MODE": "COMMANDER", "WATCH_BLUE_MODE": "GX",
                   "WATCH_CMD_URL_BLUE": url % (a.proxy_port + 50), "WATCH_CMD_FACTS": "1", "FIELD_FORTIFY": "1",
                   "WATCH_CMD_URL": url % a.proxy_port, "WATCH_BRAIN_PORT": str(a.proxy_port),
                   "WATCH_PREFER_FEWER_LOSSES": "0", "WATCH_RECENT_TURNS": "0", "WATCH_COMPACT_AT": "0",
                   "WATCH_CMD_TRACE": "0"}
            arenas.append(RV.Arena(log, 10 + 10 * a.slot + i, env, None, headless=True))
        srv.start()

        def play(i, ar, att, mode):
            """One game in window i. mode: takeover | replay | gen."""
            win = "w%d" % (10 + 10 * a.slot + i)
            if mode == "gen":
                with camp.lock:
                    seed = camp.gen_seed
                    camp.gen_seed += 1
                    camp.gen_n += 1
                combos = [(s, f) for s in ("SPEARHEAD", "BULWARK", "OUTRIDER", "HARRIER")
                          for f in ("fixed", "mild", "broad", "counterfactual_valid")]
                style, fam = combos[(seed - GEN_SEED0) % 16]
                sid = "gen_s%d" % seed
                src = {"sid": sid, "kind": "gen", "seed": seed, "tier": "BASIC", "style": style, "family": fam,
                       "sizes": SIZES}
                tag = sid
                live = {"mode": "gen", "seq": {}, "answers": {}, "hashes_rec": {}, "src": src, "T": 999, "aid": tag}
                camp.active[tag] = live
            else:
                src = camp.sources[att["sid"]]
                tag = att["aid"]
                sess = TC.make_session(att["teacher"], tag, D / "teachers" / tag) if mode == "takeover" else None
                live = {"mode": mode, "seq": {}, "src": src, "T": att["T"] if mode == "takeover" else 999,
                        "rec": att, "sess": sess, "aid": tag, "teacher": att["teacher"] if mode == "takeover" else None}
                camp.active[tag] = live
            post(a.proxy_port, "/admin/tags", {win: tag})
            job = {"family": src["family"], "seed": src["seed"], "tier": src["tier"], "style": src["style"],
                   "red_style": "", "turn_cap": 60, "session": token, "overlay": "", "random_roster": True,
                   "roster_sizes": src["sizes"]}
            o = D / "games" / (tag + ".json")
            t0 = time.time()
            err = ar.play(job, o, 36000)
            res = json.loads(o.read_text(encoding="utf-8")) if o.exists() else {"error": err or "no result"}
            if live.get("sess"):
                live["sess"].close()
            return res, live, time.time() - t0

        def worker(i, ar):
            while not stop_ev.is_set():
                if a.max_attempts and started["n"] >= a.max_attempts:
                    return
                pk = camp.pick()
                if pk is None:
                    return
                kind, att = pk
                if kind == "wait":
                    time.sleep(5)
                    continue
                started["n"] += 1
                try:
                    if kind == "gen":
                        res, live, wall = play(i, ar, None, "gen")
                        camp.active.pop(live["aid"], None)
                        finish_gen(res, live, wall)
                    else:
                        res, live, wall = play(i, ar, att, "takeover")
                        camp.active.pop(att["aid"], None)
                        finish_attempt(att, res, live, wall)
                except Exception as e:  # noqa: BLE001
                    log("[ERR] worker %d %r" % (i, e))
                    with camp.lock:
                        if kind == "gen":
                            camp.gen_active -= 1
                        else:
                            camp.active.pop(att["aid"], None)
                            att["status"] = "TECH_WAIT"
                            att["not_before"] = time.time() + 120
                            att["tech"].append({"ts": time.time(), "teacher": att["teacher"], "cause": "runner_exception",
                                                "detail": repr(e)[:500]})
                            camp.save_attempt(att["aid"])
                    time.sleep(5)

        def finish_gen(res, live, wall):
            with camp.lock:
                camp.gen_active -= 1
            src = live["src"]
            if "error" in res or res.get("outcome") == "ABORTED" or not live["answers"]:
                log("[GEN] %s technical: %s" % (src["sid"], res.get("error") or res.get("outcome")))
                return
            s = RV.score(res)
            if s["kind"] in ("INVALID", "ERROR") or int(res.get("turn") or 0) <= 2:
                log("[GEN] %s unusable (%s)" % (src["sid"], s["kind"]))
                return
            ans = live["answers"]
            src.update(answers=ans, hashes=live["hashes_rec"], last_turn=max(int(t) for t in ans),
                       final={"kind": s["kind"], "outcome": res.get("outcome"), "turn": res.get("turn"),
                              "units": res.get("units"), "hq": res.get("hq")}, origin="gen")
            jdump(D / "sources" / (src["sid"] + ".json"), src)
            with camp.lock:
                camp.sources[src["sid"]] = src
                camp.seed_all()
            log("[GEN] %s -> %s turn=%s units=%s" % (src["sid"], s["kind"], res.get("turn"), res.get("units")))

        def finish_attempt(att, res, live, wall):
            with camp.lock:
                tech = live.get("tech")
                if tech is None and ("error" in res or res.get("outcome") == "ABORTED"):
                    tech = {"cause": "arena_error", "detail": str(res.get("error") or res.get("outcome"))}
                if tech is not None:
                    att["status"] = "TECH_WAIT"
                    w = float(tech.get("wait_s") or 0)
                    att["not_before"] = time.time() + (60 if tech["cause"] == "replay_diverged" else 30)
                    if tech["cause"] == "replay_diverged":
                        att["diverged"] = att.get("diverged", 0) + 1
                        if att["diverged"] >= 2:  # not a transient: the replay itself is not exact
                            att["status"] = "BROKEN"
                    att["tech"].append({"ts": time.time(), "aid": att["aid"], "teacher": att["teacher"], **tech})
                    jl = D / "technical.json"
                    allt = jload(jl, [])
                    allt.append({"ts": time.strftime("%Y-%m-%d %H:%M:%S"), "aid": att["aid"], "teacher": att["teacher"],
                                 "T": att["T"], **tech})
                    jdump(jl, allt)
                    camp.save_attempt(att["aid"])
                    log("[TECH] %s %s turn=%s %s" % (att["aid"], tech["cause"], tech.get("turn"), str(tech.get("detail"))[:160]))
                    return
                s = RV.score(res)
                kr = kill_ratio(res.get("units"), ((res.get("hq") or {}).get("blue") or {}).get("end"))
                rf = D / "rows" / (att["aid"] + ".jsonl")
                n_rows = 0
                if rf.exists():
                    byturn = {}
                    for l in rf.read_text(encoding="utf-8").splitlines():
                        x = json.loads(l)
                        if x["valid"]:
                            byturn[x["turn"]] = 1
                    n_rows = len(byturn)
                att["status"] = "DONE"
                att["result"] = {"kind": s["kind"], "outcome": res.get("outcome"), "turn": res.get("turn"),
                                 "kill_ratio": kr, "units": res.get("units"), "n_rows": n_rows,
                                 "wall_s": round(wall), "ts": time.strftime("%Y-%m-%d %H:%M:%S")}
                camp.save_attempt(att["aid"])
                with open(D / "results.jsonl", "a", encoding="utf-8") as f:
                    f.write(json.dumps({"aid": att["aid"], "sid": att["sid"], "T": att["T"], "teacher": att["teacher"],
                                        "rep": att["rep"], "tech_interruptions": len(att["tech"]), **att["result"]},
                                       ensure_ascii=False) + "\n")
                log("[PLAYED] %s -> %s turn=%s kill=%.2f rows=%d wall=%ds" % (att["aid"], s["kind"], res.get("turn"), kr,
                                                                              n_rows, wall))

        if a.cmd == "replay":
            return replay_check(a, camp, arenas, play, log, RV)

        threads = [threading.Thread(target=worker, args=(i, ar), daemon=True) for i, ar in enumerate(arenas)]
        for t in threads:
            t.start()
            time.sleep(3)
        last_status = 0
        while any(t.is_alive() for t in threads):
            time.sleep(10)
            if time.time() - last_status > (60 if a.max_attempts else 600):
                last_status = time.time()
                camp.status_md()
            r = camp.should_stop()
            if r and not (D / "STOP").exists():
                (D / "STOP").write_text(r, encoding="utf-8")
                log("[STOP] " + r)
        reason = camp.should_stop() or "종료"
        camp.write_rows()
        camp.status_md(reason)
        log("[DONE] " + reason)
    finally:
        stop_ev.set()
        for ar in arenas:
            try:
                ar.quit()
            except Exception:  # noqa: BLE001
                pass
        hands.stop()
        try:
            post(a.proxy_port, "/admin/shutdown", {})
            proxy.wait(timeout=60)
        except Exception:  # noqa: BLE001
            proxy.kill()


def replay_check(a, camp, arenas, play, log, RV):
    """Play recorded sources with only their recorded answers; compare every request hash and the final result."""
    sids = [s for s in a.arg.split(",") if s]
    report = []
    lock = threading.Lock()
    todo = list(sids)

    def w(i, ar):
        while True:
            with lock:
                if not todo:
                    return
                sid = todo.pop(0)
            src = camp.sources[sid]
            att = {"aid": "replay_" + sid, "sid": sid, "T": 999, "teacher": None, "teacher_answers": {}, "hashes": {}}
            res, live, wall = play(i, ar, att, "replay")
            camp.active.pop(att["aid"], None)
            fin = src["final"]
            u = res.get("units")
            ok = (not live.get("aborted")) and res.get("turn") == fin["turn"] and u == fin["units"] and \
                res.get("outcome") == fin["outcome"]
            rep = {"sid": sid, "exact": bool(ok), "requests_replayed": live.get("replayed", 0), "mismatch": live.get("mismatch"),
                   "tech": live.get("tech"), "recorded": {"turn": fin["turn"], "outcome": fin["outcome"], "units": fin["units"]},
                   "replayed": {"turn": res.get("turn"), "outcome": res.get("outcome"), "units": u}}
            report.append(rep)
            log("[REPLAY] %s exact=%s %s" % (sid, ok, json.dumps(rep["replayed"])))

    ts = [threading.Thread(target=w, args=(i, ar), daemon=True) for i, ar in enumerate(arenas[:max(1, min(len(arenas), len(sids)))])]
    for t in ts:
        t.start()
        time.sleep(3)
    for t in ts:
        t.join()
    jdump(D / "replay_exactness.json", report)
    print(json.dumps(report, indent=1))


if __name__ == "__main__":
    main()
