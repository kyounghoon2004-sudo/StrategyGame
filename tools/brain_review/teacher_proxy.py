"""TEACHER PROXY — the RL_POLICY endpoint the live game talks to (127.0.0.1:8096).

Same contract as tools/contextual_brain/rl_vs_utility.py serve:
  GET  /health            -> {ok, label: "RL_POLICY", model: "rl_policy", rl_session, ...}
  POST /v1/chat/completions -> OpenAI-style chat completion
  POST /admin/tag | /admin/tags | /admin/shutdown
plus one admin-only extension (never called by the game):
  POST /admin/modes       -> {window: "TEACHER"|"MODEL"} per arena window

How it answers:
  * "Reply with OK." probe       -> "OK" (exactly like serve)
  * VICTORY_INITIAL              -> forwarded to the Brain service (another port)
  * VICTORY_REVIEW, TEACHER mode -> answered by the deterministic REVIEW TEACHER
  * VICTORY_REVIEW, MODEL mode   -> forwarded to the Brain (S0B), teacher labels it anyway
  * REPAIR RETRY requests        -> always forwarded to the Brain (a model repair is
                                    the model's own business; never a corpus row)
In BOTH modes the exact messages plus the teacher's decision are logged for every
review (capture dir: calls.jsonl = every call, reviews.jsonl = reviews only).

  python -m tools.brain_review.teacher_proxy --session <token> --capture-dir <dir>
        [--port 8096] [--brain-port 8106] [--default-mode TEACHER]
"""
from __future__ import annotations

import argparse
import json
import re
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import sys

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.brain_review.review_teacher import decide  # noqa: E402

PROBE_TEXT = "Reply with OK."
REVIEW_SYSTEM_PREFIX = "You are the RED general reviewing"
RETRY_MARKER = "REPAIR RETRY"
WIN_RE = re.compile(r"_(w[0-9]+)[.]json$")


def packet_of(messages):
    for m in messages or []:
        if isinstance(m, dict) and m.get("role") == "user":
            try:
                return json.loads(m.get("content", ""))
            except (ValueError, TypeError):
                return None
    return None


def system_text(messages):
    for m in messages or []:
        if isinstance(m, dict) and m.get("role") == "system":
            return str(m.get("content", ""))
    return ""


def conv_log(msgs):
    """The whole request: a game's conversation stays small (opening + digest + a few kept turns), so every call keeps
    exactly what the Brain read."""
    turns = [m for m in msgs or [] if isinstance(m, dict) and m.get("role") in ("user", "assistant")]
    return {"messages": msgs, "conv_len": len(turns)}


class State:
    def __init__(self, args):
        self.args = args
        self.lock = threading.Lock()
        self.calls = 0
        self.reviews = 0
        self.tag = ""
        self.tag_map = {}
        self.modes = {}
        self.plans = {}
        self.sessions = {}  # game tag -> {"dir", "sid"}: resident cloud Brain sessions
        self.capture = Path(args.capture_dir)
        self.capture.mkdir(parents=True, exist_ok=True)

    def window_of(self, headers):
        m = WIN_RE.search(urllib.parse.unquote(headers.get("X-Episode-Spec-Path") or ""))
        return m.group(1) if m else None

    def mode_of(self, win):
        if win and win in self.modes:
            return self.modes[win]
        return self.args.default_mode

    def log(self, name, row):
        with self.lock:
            with open(self.capture / name, "a", encoding="utf-8") as f:
                f.write(json.dumps(row, ensure_ascii=False) + "\n")


import urllib.parse  # noqa: E402  (used by State.window_of)

ST: State  # set in main()


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

    def _forward(self, body_obj):
        req = urllib.request.Request(
            "http://127.0.0.1:%d/v1/chat/completions" % self.server.brain_port,
            data=json.dumps(body_obj).encode("utf-8"),
            headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=1800) as r:
            return json.loads(r.read())

    def do_GET(self):
        if self.path in ("/health", "/identity"):
            with ST.lock:
                self._json(200, {"ok": True, "label": "RL_POLICY", "model": "rl_policy",
                                 "rl_session": ST.args.session, "adapter_dir": "",
                                 "adapter_is_csft6": False, "calls": ST.calls,
                                 "proxy": "teacher_proxy_v1", "brain_port": self.server.brain_port,
                                 "modes": dict(ST.modes)})
        else:
            self._json(404, {})

    def _reply(self, content, usage=None):
        with ST.lock:
            ST.calls += 1
            cid = "tp-%d" % ST.calls
        self._json(200, {"id": cid, "object": "chat.completion", "model": "rl_policy",
                         "choices": [{"index": 0, "message": {"role": "assistant", "content": content},
                                      "finish_reason": "stop"}],
                         "usage": usage or {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}})

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0") or 0)) or b"{}"
        try:
            body = json.loads(raw)
        except ValueError:
            body = {}
        if self.path == "/admin/tag":
            ST.tag = str(body.get("tag", ""))
            self._json(200, {"ok": True})
            return
        if self.path == "/admin/tags":
            ST.tag_map.update({str(k): str(v) for k, v in dict(body).items()})  # merge (harvest sets every window anyway)
            try:
                self._forward_admin("/admin/tags", body)
            except Exception:  # noqa: BLE001
                pass
            self._json(200, {"ok": True})
            return
        if self.path == "/admin/plans":
            # PLAN SEARCH (2026-10-04): window -> fixed opening-plan text served for VICTORY_INITIAL
            ST.plans.update({str(k): str(v) for k, v in dict(body).items()})  # merge: windows are refilled one by one
            self._json(200, {"ok": True, "windows": sorted(ST.plans)})
            return
        if self.path == "/admin/modes":
            ST.modes = {str(k): str(v).upper() for k, v in dict(body).items()}
            self._json(200, {"ok": True, "modes": dict(ST.modes)})
            return
        if self.path == "/admin/shutdown":
            self._json(200, {"ok": True})
            try:
                self._forward_admin("/admin/shutdown", {})
            except Exception:  # noqa: BLE001
                pass
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return
        if self.path != "/v1/chat/completions":
            self._json(404, {})
            return

        msgs = body.get("messages") or []
        last = next((str(m.get("content", "")) for m in reversed(msgs) if m.get("role") == "user"), "")
        win = ST.window_of(self.headers)
        tag = ST.tag_map.get(win) if win else None
        # Commander: the full battle state rides along as "state"; the messages are the game's resident conversation.
        pkt = body.get("state") if isinstance(body.get("state"), dict) else packet_of(msgs)
        req_kind = str((pkt or {}).get("request", ""))
        sys_txt = system_text(msgs)
        is_retry = RETRY_MARKER in sys_txt
        mode = ST.mode_of(win)

        if last.strip() == PROBE_TEXT:
            ST.log("calls.jsonl", {"ts": time.time(), "window": win, "tag": tag, "mode": mode,
                                   "request": "PROBE", "raw": "OK"})
            self._reply("OK")
            return

        if req_kind == "VICTORY_INITIAL" and getattr(ST.args, "initial_stub", False):
            # COMMANDER mode still boots the legacy mount, which asks for an opening plan it never uses
            ST.log("calls.jsonl", {"ts": time.time(), "window": win, "tag": tag, "mode": mode, "request": req_kind,
                                   "turn": (pkt or {}).get("turn"), "raw": "{}", "served": "STUB"})
            self._reply("{}")
            return

        if req_kind in ("VICTORY_INITIAL", "VICTORY_REVIEW", "VICTORY_COMMAND") and getattr(ST.args, "manual_dir", ""):
            # MANUAL BRAIN (diagnosis): park the request in a file, wait for a human/agent answer file
            md = Path(ST.args.manual_dir)
            md.mkdir(parents=True, exist_ok=True)
            with ST.lock:
                ST.manual_seq = getattr(ST, "manual_seq", 0) + 1
                n = ST.manual_seq
            (md / ("req_%04d.json" % n)).write_text(json.dumps({"n": n, "request": req_kind, "turn": (pkt or {}).get("turn"),
                                                                 "retry": is_retry, "messages": msgs, "state": body.get("state"),
                                                                 "tag": tag, "window": win}, ensure_ascii=False), encoding="utf-8")
            resp_f = md / ("resp_%04d.txt" % n)
            while not resp_f.exists():
                time.sleep(getattr(ST.args, "manual_poll_s", 1.0))
            time.sleep(min(0.3, getattr(ST.args, "manual_poll_s", 1.0)))
            content = resp_f.read_text(encoding="utf-8").strip()
            ST.log("calls.jsonl", {"ts": time.time(), "window": win, "tag": tag, "mode": "MANUAL", "request": req_kind,
                                   "turn": (pkt or {}).get("turn"), **conv_log(msgs), "state": body.get("state"),
                                   "raw": content, "served": "MANUAL"})
            self._reply(content)
            return
        if req_kind == "VICTORY_REVIEW" and not is_retry:
            with ST.lock:
                ST.reviews += 1
            t = decide(pkt or {})
            teacher_row = {"ts": time.time(), "window": win, "tag": tag, "mode": mode,
                           "episode_id": self.headers.get("X-Episode-Id"),
                           "spec_path": urllib.parse.unquote(self.headers.get("X-Episode-Spec-Path") or ""),
                           "request": req_kind,
                           "turn": (pkt or {}).get("turn"),
                           "trigger": ((pkt or {}).get("review_trigger") or {}).get("trigger"),
                           "also_due": ((pkt or {}).get("review_trigger") or {}).get("also_due"),
                           "snapshot_id": (pkt or {}).get("snapshot_id"),
                           "active_phase": ((pkt or {}).get("plan_live") or {}).get("current_phase_id"),
                           "messages": msgs,
                           "teacher": {"target": t["target"], "rule": t["rule"], "subkind": t["subkind"],
                                       "why": t["why"], "drop_reason": t["drop_reason"]},
                           "served": "TEACHER" if mode == "TEACHER" else "MODEL", "brain_raw": None}
            if mode == "TEACHER":
                served_t = t["target"]
                if served_t is not None and served_t.get("decision") == "AMEND_PLAN":
                    from tools.brain_review.to_patch import to_patch
                    served_t = to_patch(served_t, pkt or {}) or served_t
                content = json.dumps(served_t, ensure_ascii=False) if served_t is not None else \
                    json.dumps({"decision": "KEEP", "reason": "teacher drop %s" % t["drop_reason"]})
                ST.log("reviews.jsonl", teacher_row)
                ST.log("calls.jsonl", {"ts": teacher_row["ts"], "window": win, "tag": tag, "mode": mode,
                                       "request": req_kind, "turn": teacher_row["turn"],
                                       "trigger": teacher_row["trigger"], "messages": msgs,
                                       "raw": content, "served": "TEACHER"})
                self._reply(content)
                return
            # MODEL mode: forward to the Brain, label with the teacher anyway
            try:
                resp = self._forward(body)
                content = (((resp.get("choices") or [{}])[0]).get("message") or {}).get("content", "")
            except Exception as e:  # noqa: BLE001
                content = ""
                resp = {"error": str(e)}
            teacher_row["brain_raw"] = content
            teacher_row["brain_resp_head"] = {k: resp.get(k) for k in ("id", "model", "usage")}
            ST.log("reviews.jsonl", teacher_row)
            ST.log("calls.jsonl", {"ts": teacher_row["ts"], "window": win, "tag": tag, "mode": mode,
                                   "request": req_kind, "turn": teacher_row["turn"],
                                   "trigger": teacher_row["trigger"], "messages": msgs,
                                   "raw": content, "served": "MODEL"})
            if "error" in resp:
                self._json(200, {"id": "tp-err", "object": "chat.completion", "model": "rl_policy",
                                 "choices": [{"index": 0, "message": {"role": "assistant", "content": content},
                                              "finish_reason": "stop"}],
                                 "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}})
            else:
                self._json(200, resp)
            return

        if req_kind == "VICTORY_COMMAND" and getattr(ST.args, "local_url", ""):
            # COMMANDER v1 on a local vLLM model
            from tools.plan_search.cloud_brain import local_command
            kw = dict(url=ST.args.local_url, model=ST.args.local_model, think_budget=ST.args.local_think_budget,
                      no_think=ST.args.local_no_think, max_tokens=ST.args.local_max_tokens,
                      top_k=ST.args.local_top_k, presence_penalty=ST.args.local_presence_penalty,
                      answer_tokens=ST.args.local_answer_tokens, reasoning_effort=ST.args.local_reasoning_effort)
            if ST.args.local_pass:
                kw["tries"] = 1
            content, meta = local_command(msgs, **kw)  # the whole conversation: the server's prefix cache holds the rest
            if not content and ST.args.local_pass:
                # No usable answer this turn (cut at the token cap, unparsable, server error): only this turn is
                # skipped, every order stands and the game goes on.
                last = (meta.get("attempts") or [{}])[-1]
                meta["skipped"] = ("cut at %d tokens" % ST.args.local_max_tokens if last.get("finish") == "length"
                                   else "error" if last.get("error") else "unusable answer")
                content = json.dumps({"orders": {}, "skipped": meta["skipped"]})
            ST.log("calls.jsonl", {"ts": time.time(), "window": win, "tag": tag, "mode": "LOCAL", "request": req_kind,
                                   "turn": (pkt or {}).get("turn"), **conv_log(msgs), "state": body.get("state"), "raw": content, "served": "LOCAL",
                                   "local": meta})
            self._reply(content)
            return
        if req_kind == "VICTORY_COMMAND" and getattr(ST.args, "cloud_model", ""):
            # COMMANDER: the cloud model continues the game's conversation (one opencode session per game)
            from tools.plan_search.cloud_brain import cloud_command, RUN_TMP
            key = tag or win or "game"
            with ST.lock:
                sess = ST.sessions.setdefault(key, {"dir": str(RUN_TMP / ("game_" + re.sub(r"[^A-Za-z0-9_.-]", "_", key)))})
            content, meta = cloud_command(msgs, model=ST.args.cloud_model, variant=ST.args.cloud_variant,
                                          session=sess, timeout_s=ST.args.cloud_timeout, pass_on_fail=ST.args.cloud_pass)
            ST.log("calls.jsonl", {"ts": time.time(), "window": win, "tag": tag, "mode": "CLOUD", "request": req_kind,
                                   "turn": (pkt or {}).get("turn"), **conv_log(msgs), "state": body.get("state"), "raw": content, "served": "CLOUD",
                                   "cloud": meta})
            self._reply(content)
            return
        if req_kind == "VICTORY_INITIAL" and getattr(ST.args, "cloud_model", ""):
            # CLOUD BRAIN (plan search): opening plans and strategic replans come from the cloud model
            from tools.plan_search.cloud_brain import cloud_plan
            content, meta = cloud_plan(msgs, model=ST.args.cloud_model, variant=ST.args.cloud_variant)
            ST.log("calls.jsonl", {"ts": time.time(), "window": win, "tag": tag, "mode": "CLOUD",
                                   "request": req_kind, "retry": is_retry, "turn": (pkt or {}).get("turn"),
                                   "messages": msgs, "raw": content, "served": "CLOUD", "cloud": meta})
            self._reply(content)
            return
        if req_kind == "VICTORY_INITIAL" and not is_retry and win and getattr(ST, "plans", {}).get(win):
            content = ST.plans[win]
            ST.log("calls.jsonl", {"ts": time.time(), "window": win, "tag": tag, "mode": mode,
                                   "request": req_kind, "retry": False, "turn": (pkt or {}).get("turn"),
                                   "messages": msgs, "raw": content, "served": "PLAN"})
            self._reply(content)
            return
        # INITIAL, repair retries, and anything else: straight to the Brain
        try:
            resp = self._forward(body)
            content = (((resp.get("choices") or [{}])[0]).get("message") or {}).get("content", "")
        except Exception as e:  # noqa: BLE001
            content = ""
            resp = {"error": str(e)}
        ST.log("calls.jsonl", {"ts": time.time(), "window": win, "tag": tag, "mode": mode,
                               "request": req_kind or "OTHER", "retry": is_retry,
                               "turn": (pkt or {}).get("turn"), "trigger": ((pkt or {}).get("review_trigger") or {}).get("trigger"),
                               "messages": msgs, "raw": content, "served": "MODEL"})
        if "error" in resp:
            self._json(200, {"id": "tp-err", "object": "chat.completion", "model": "rl_policy",
                             "choices": [{"index": 0, "message": {"role": "assistant", "content": content},
                                          "finish_reason": "stop"}],
                             "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}})
        else:
            self._json(200, resp)

    def _forward_admin(self, path, body):
        req = urllib.request.Request(
            "http://127.0.0.1:%d%s" % (self.server.brain_port, path),
            data=json.dumps(body).encode("utf-8"),
            headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.read()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--session", required=True, help="RL_SESSION token the game verifies")
    ap.add_argument("--capture-dir", required=True)
    ap.add_argument("--port", type=int, default=8096)
    ap.add_argument("--brain-port", type=int, default=8106)
    ap.add_argument("--default-mode", default="TEACHER", choices=["TEACHER", "MODEL"])
    ap.add_argument("--cloud-model", default="", help="plan search: opening plans/replans from this opencode model")
    ap.add_argument("--cloud-variant", default="", help="opencode reasoning variant ('' = model default)")
    ap.add_argument("--manual-dir", default="", help="diagnosis: Brain requests are parked here and answered by hand")
    ap.add_argument("--manual-poll-s", type=float, default=1.0, help="manual response polling interval; inputs unchanged")
    ap.add_argument("--local-url", default="", help="commander: local OpenAI-compatible endpoint (vLLM)")
    ap.add_argument("--local-model", default="q38")
    ap.add_argument("--local-max-tokens", type=int, default=12000)
    ap.add_argument("--local-top-k", type=int, default=0)
    ap.add_argument("--local-reasoning-effort", default="", help="commander local: chat-template effort (low / medium / xhigh)")
    ap.add_argument("--local-presence-penalty", type=float, default=0.0)
    ap.add_argument("--local-no-think", action="store_true", help="commander local: thinking OFF")
    ap.add_argument("--local-pass", action="store_true",
                    help="commander local: a turn without a usable answer is skipped (orders stand) instead of failing the game")
    ap.add_argument("--local-answer-tokens", type=int, default=1500, help="commander local: answer token cap (thinking OFF / after a forced cut)")
    ap.add_argument("--local-think-budget", type=int, default=0, help="commander local: budget-forced thinking tokens (0 = unlimited)")
    ap.add_argument("--initial-stub", action="store_true", help="commander: answer the legacy opening-plan request locally")
    ap.add_argument("--cloud-timeout", type=int, default=1800, help="commander: seconds allowed per cloud request")
    ap.add_argument("--cloud-pass", action="store_true",
                    help="commander: when a cloud request fails or runs out of time, keep the current orders and go on")
    args = ap.parse_args()
    global ST
    ST = State(args)
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), H)
    srv.brain_port = args.brain_port
    print("[TEACHER_PROXY] ready on %d -> brain %d session=%s default_mode=%s capture=%s" %
          (args.port, args.brain_port, args.session, args.default_mode, args.capture_dir), flush=True)
    srv.serve_forever()
    print("[TEACHER_PROXY] stopped calls=%d reviews=%d" % (ST.calls, ST.reviews), flush=True)


if __name__ == "__main__":
    main()
