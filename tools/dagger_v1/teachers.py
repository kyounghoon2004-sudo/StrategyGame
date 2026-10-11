"""DAgger v1 teachers (2026-10-11): one resident CLI conversation per takeover attempt.

TechnicalError = usage / quota / rate limit / cooldown / transport / timeout / empty or error response: NEVER a teacher
loss; the caller aborts the attempt as TECHNICAL and resumes it later from the same turn (deterministic replay).
A returned string is a real model answer (raw text).

The first call of a session sends the game's conversation so far (turn inputs and the answers given for them, oldest
first) as one user message; later calls send only the new game user message, verbatim (resident session).
"""
from __future__ import annotations

import hashlib
import json
import os
import queue
import re
import subprocess
import threading
import time
from pathlib import Path

from tools.plan_search.cloud_brain import extract_orders

WORK = Path("D:/StrategyGameOpenCodeTeacher_dagger")
OPENCODE_MODEL = "opencode-go/step-5-preview-free"
AGY_MODEL = "gemini-3.8-flash-medium"
OPENCODE_EXE = Path(os.environ.get("APPDATA", "")) / "npm/node_modules/opencode-ai/bin/opencode.exe"
AGY_EXE = Path(os.environ.get("LOCALAPPDATA", "")) / "agy/bin/agy.exe"
QUOTA_WORDS = ("usage limit", "quota", "rate limit", "rate_limit", "ratelimit", "too many requests", "429",
               "resource_exhausted", "exhausted", "capacity", "overloaded", "subscription", "cooldown", "limit reached",
               "billing", "credit", "insufficient", "free usage", "try again later", "resets in")


class TechnicalError(Exception):
    def __init__(self, cause, detail="", wait_s=0):
        super().__init__("%s: %s" % (cause, detail[:600]))
        self.cause, self.detail, self.wait_s = cause, detail, wait_s


def sha(t):
    return hashlib.sha256(t.encode("utf-8")).hexdigest()


def resets_in_seconds(text):
    """'Resets in 1h38m52s' / '2m30s' -> seconds (0 when absent)."""
    m = re.search(r"resets?\s+in\s+((?:\d+h)?\s*(?:\d+m)?\s*(?:\d+s)?)", text or "", re.I)
    if not m:
        return 0
    h, mi, s = (re.search(r"(\d+)%s" % u, m.group(1)) for u in "hms")
    return (int(h.group(1)) * 3600 if h else 0) + (int(mi.group(1)) * 60 if mi else 0) + (int(s.group(1)) if s else 0)


def classify(text):
    """-> (cause, suggested wait in seconds; 0 = caller's default for the cause)."""
    t = (text or "").lower()
    if any(w in t for w in QUOTA_WORDS):
        r = resets_in_seconds(t)
        return "quota_or_rate_limit", (r + 300) if r else 0
    if "timeout" in t or "timed out" in t:
        return "timeout", 0
    return "transport_or_provider_error", 0


def transcript(messages):
    """The conversation so far as one user message (the game's own turn inputs and the answers given for them)."""
    turns = [m for m in messages if m.get("role") in ("user", "assistant")]
    out = ["The game is already in progress. The conversation so far, oldest first; reply to the last turn input only."]
    for m in turns:
        out.append(("[YOUR ANSWER]" if m["role"] == "assistant" else "[TURN INPUT]") + "\n" + str(m.get("content", "")))
    return "\n\n".join(out)


def normalise(raw):
    """-> (answer text, ok). A real answer: pure JSON object with an orders object, or one wrapped in prose/fences."""
    s = (raw or "").strip()
    try:
        d = json.loads(s)
        if isinstance(d, dict) and isinstance(d.get("orders"), dict):
            return s, True
    except ValueError:
        pass
    d = extract_orders(s)
    if d is not None:
        return json.dumps(d, ensure_ascii=False), True
    return s, False


def _split(messages):
    system = next((str(m.get("content", "")) for m in messages if m.get("role") == "system"), "")
    if not system or messages[-1].get("role") != "user" or not isinstance(messages[-1].get("content"), str):
        raise TechnicalError("bad_request_shape", "no system prompt or last message is not user text")
    return system, messages[-1]["content"]


def _n_user(messages):
    return len([m for m in messages if m.get("role") == "user"])


class OpenCodeSession:
    name = "opencode"

    def __init__(self, aid, logdir, timeout=900):
        self.aid, self.logdir, self.timeout = aid, Path(logdir), timeout
        self.sid = None
        self.system_sha = None
        self.n = 0
        self.cwd = WORK / "oc" / sha(aid)[:16]

    def close(self):
        pass

    def ask(self, messages, turn):
        system, user = _split(messages)
        if self.system_sha and self.system_sha != sha(system):
            raise TechnicalError("system_changed", "system prompt changed inside a game")
        self.system_sha = sha(system)
        text = user if (self.sid or _n_user(messages) <= 1) else transcript(messages)
        self.n += 1
        call = self.logdir / ("oc_turn_%04d_%d" % (turn, self.n))
        call.mkdir(parents=True, exist_ok=True)
        self.cwd.mkdir(parents=True, exist_ok=True)
        cfgdir = self.cwd / "config_home" / "opencode"
        cfgdir.mkdir(parents=True, exist_ok=True)
        config = {"$schema": "https://opencode.ai/config.json", "model": OPENCODE_MODEL,
                  "enabled_providers": [OPENCODE_MODEL.split("/")[0]], "permission": "deny", "instructions": [],
                  "plugin": [], "mcp": {}, "share": "disabled", "autoupdate": False,
                  "compaction": {"auto": False, "prune": False},
                  "agent": {"commander": {"description": "Game resident commander", "mode": "primary",
                                          "prompt": system, "permission": "deny"}}, "default_agent": "commander"}
        env = dict(os.environ)
        env["XDG_CONFIG_HOME"] = str(self.cwd / "config_home")
        env["OPENCODE_CONFIG_DIR"] = str(cfgdir)
        env.pop("OPENCODE_CONFIG", None)
        env["OPENCODE_CONFIG_CONTENT"] = json.dumps(config, ensure_ascii=False)
        for f in ("DISABLE_PROJECT_CONFIG", "DISABLE_CLAUDE_CODE", "DISABLE_CLAUDE_CODE_PROMPT", "DISABLE_CLAUDE_CODE_SKILLS",
                  "DISABLE_EXTERNAL_SKILLS", "DISABLE_AUTOCOMPACT", "DISABLE_PRUNE", "DISABLE_DEFAULT_PLUGINS",
                  "DISABLE_SHARE", "DISABLE_AUTOUPDATE"):
            env["OPENCODE_" + f] = "true"
        cmd = [str(OPENCODE_EXE), "run", "--pure", "--format", "json", "--dir", str(self.cwd), "--agent", "commander",
               "-m", OPENCODE_MODEL] + (["-s", self.sid] if self.sid else [])
        (call / "stdin.txt").write_text(text, encoding="utf-8")
        try:
            with (call / "stdout.jsonl").open("wb") as so, (call / "stderr.log").open("wb") as se:
                p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=so, stderr=se, cwd=str(self.cwd), env=env,
                                     creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
                try:
                    p.communicate(text.encode("utf-8"), timeout=self.timeout)
                except subprocess.TimeoutExpired:
                    subprocess.run(["taskkill", "/PID", str(p.pid), "/T", "/F"], capture_output=True)
                    p.wait()
                    raise TechnicalError("timeout", "opencode CLI timeout %ds" % self.timeout)
        except OSError as e:
            raise TechnicalError("transport_or_provider_error", "cannot run opencode: %s" % e)
        events = []
        for line in (call / "stdout.jsonl").read_text(encoding="utf-8", errors="replace").splitlines():
            try:
                events.append(json.loads(line))
            except ValueError:
                pass
        err_txt = (call / "stderr.log").read_text(encoding="utf-8", errors="replace")
        ids = {e["sessionID"] for e in events if e.get("sessionID")}
        errs = [e for e in events if e.get("type") == "error"]
        if len(ids) == 1 and not self.sid:
            self.sid = next(iter(ids))
        if errs or p.returncode != 0:
            detail = json.dumps(errs, ensure_ascii=False)[:1500] + " | rc=%s | %s" % (p.returncode, err_txt[-800:])
            cause, wait = classify(detail)
            raise TechnicalError(cause, detail, wait)
        fin = [e.get("part", {}) for e in events if e.get("type") == "step_finish"]
        if not fin:
            raise TechnicalError("transport_or_provider_error", "no step_finish event (no completed answer)")
        if any(f.get("cost") not in (0, 0.0, None) for f in fin):
            raise TechnicalError("nonzero_cost", "free model reported cost %r: stopped, no paid fallback" %
                                 [f.get("cost") for f in fin])
        raw = "".join(e.get("part", {}).get("text", "") for e in events if e.get("type") == "text")
        (call / "answer_raw.txt").write_text(raw, encoding="utf-8")
        if not raw.strip():
            raise TechnicalError("empty_response", "no text in a completed step (tool use or empty answer): not a decision")
        return raw


class AgySession:
    name = "agy"

    def __init__(self, aid, logdir, timeout=900):
        self.aid, self.logdir, self.timeout = aid, Path(logdir), timeout
        self.proc = None
        self.events = queue.Queue()
        self.conv = None
        self.system_sha = None
        self.n = 0

    def close(self):
        if self.proc and self.proc.poll() is None:
            subprocess.run(["taskkill", "/PID", str(self.proc.pid), "/T", "/F"], capture_output=True)
        self.proc = None

    def _start(self, system):
        cwd = WORK / "agy" / sha(self.aid)[:16]
        if not (cwd / ".git").exists():
            cwd.mkdir(parents=True, exist_ok=True)
            subprocess.run(["git", "init", "--quiet", str(cwd)], check=True, capture_output=True)
        agent = cwd / ".agents/agents/commander.md"
        agent.parent.mkdir(parents=True, exist_ok=True)
        header = ("---\nname: commander\ndescription: Resident game commander\nmainAgent: true\nsubagent: false\n"
                  "model: inherit\ntools: []\nmcpServers: []\nskills: []\nplugins: []\ncommandExecutionPolicy: \"off\"\n---\n")
        agent.write_bytes((header + system).encode("utf-8"))
        env = dict(os.environ)
        for k in ("GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_GEMINI_BASE_URL", "AGY_LLM_GATEWAY_API_KEY",
                  "AGY_LLM_GATEWAY_HEADERS", "AGY_LLM_GATEWAY_CA_CERT"):
            env.pop(k, None)
        self.logdir.mkdir(parents=True, exist_ok=True)
        cmd = [str(AGY_EXE), "--new-project", "--agent", "commander", "--model", AGY_MODEL, "--input-format",
               "stream-json", "--output-format", "stream-json", "--disable-slash-commands", "--log-file",
               str(self.logdir / ("agy_cli_%d.log" % self.n))]
        self.events = q = queue.Queue()
        try:
            self.proc = proc = subprocess.Popen(cmd, cwd=cwd, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                                stderr=(self.logdir / "agy_stderr.log").open("ab"),
                                                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        except OSError as e:
            raise TechnicalError("transport_or_provider_error", "cannot run agy: %s" % e)

        def reader():
            with (self.logdir / "agy_events.jsonl").open("ab") as log:
                for line in iter(proc.stdout.readline, b""):
                    log.write(line)
                    log.flush()
                    try:
                        q.put(json.loads(line))
                    except ValueError:
                        q.put({"event": "transport_error", "error": "non-JSON stream line"})
            q.put({"event": "transport_error", "error": "CLI stdout closed"})

        threading.Thread(target=reader, daemon=True).start()
        try:
            init = q.get(timeout=90)
        except queue.Empty:
            raise TechnicalError("timeout", "agy init event timeout")
        if init.get("event") != "init" or init.get("init", {}).get("model") != AGY_MODEL or \
                init["init"].get("agent") != "commander":
            raise TechnicalError("transport_or_provider_error", "agy init mismatch: " + json.dumps(init)[:500])
        self.conv = init.get("conversation_id")
        if not self.conv:
            raise TechnicalError("transport_or_provider_error", "agy init lacks conversation id")

    def ask(self, messages, turn):
        system, user = _split(messages)
        if self.system_sha and self.system_sha != sha(system):
            raise TechnicalError("system_changed", "system prompt changed inside a game")
        self.system_sha = sha(system)
        self.n += 1
        try:
            if self.proc is None or self.proc.poll() is not None:
                self.conv = None
                self._start(system)
                text = transcript(messages) if _n_user(messages) > 1 else user
            else:
                text = user
            call = self.logdir / ("agy_turn_%04d_%d" % (turn, self.n))
            call.mkdir(parents=True, exist_ok=True)
            (call / "stdin.txt").write_text(text, encoding="utf-8")
            msg = {"event": "user", "message": {"content": text}}
            try:
                self.proc.stdin.write((json.dumps(msg, ensure_ascii=False) + "\n").encode("utf-8"))
                self.proc.stdin.flush()
            except OSError as e:
                raise TechnicalError("transport_or_provider_error", "agy stdin closed: %s" % e)
            deadline = time.monotonic() + self.timeout
            while True:
                try:
                    e = self.events.get(timeout=max(0.1, deadline - time.monotonic()))
                except queue.Empty:
                    raise TechnicalError("timeout", "agy answer timeout %ds" % self.timeout)
                ev = e.get("event")
                if ev in ("error", "usage_limit", "rate_limit"):
                    detail = json.dumps(e, ensure_ascii=False)
                    cause, wait = classify(detail)
                    raise TechnicalError(cause if ev == "error" else "quota_or_rate_limit", detail, wait)
                if ev == "transport_error":
                    raise TechnicalError("transport_or_provider_error", json.dumps(e)[:600])
                up = e.get("step_update") if isinstance(e.get("step_update"), dict) else {}
                if up.get("tool_info") or up.get("subagent_info") or up.get("tool_name") or ev in ("tool_call", "tool_use"):
                    raise TechnicalError("empty_response", "tool activity attempted (no answer): " + json.dumps(e)[:400])
                if ev == "result":
                    result = e["result"]
                    break
            (call / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=1), encoding="utf-8")
            if result.get("status") != "SUCCESS" or (self.conv and result.get("conversation_id") != self.conv):
                detail = json.dumps(result, ensure_ascii=False)
                cause, wait = classify(detail)
                raise TechnicalError(cause, detail, wait)
            raw = result.get("response") or ""
            if not raw.strip():
                raise TechnicalError("empty_response", "SUCCESS result with empty response: not a decision")
            return raw
        except TechnicalError:
            self.close()  # a new process (and a transcript) on the next try
            raise


def make_session(teacher, aid, logdir):
    return (OpenCodeSession if teacher == "opencode" else AgySession)(aid, logdir)
