"""OPENJEV LIVE INTEGRATION V0 - persistent local inference worker.

Loads AlexWortega/openjev qwen3.5-4b-nli-v2 ONCE (frozen, eval, no grad)
and scores full legal-candidate pools from the Godot RED Hands loop.

Endpoints (localhost only):
  GET  /health    readiness + strict identity handshake
  POST /score     score ALL candidates, return global argmax (entailment)
  POST /shutdown  owned shutdown (token-authenticated)

NO TRAINING. No weight updates, no fine-tuning, no adapters. Inference only.

Request contract: schema "openjev-score-request-v1".
  {
    "schema_version": "openjev-score-request-v1",
    "battle_id": str, "turn": int, "side": "red",
    "authorized_state": {
      "knowledge": {"ledger": {
        "own_forces": [...], "observed_blue_forces": [...],
        "last_known_blue_contacts": [...], "strongholds": [...],
        "logistics": {...}}},
      "mission": {"type": str, "objective": str, "status": str},
      "recent_events": [...]
    },
    "commander_context": {
      "plan_source": str,
      "concept": {"objective": str, "intent": str, "main_effort": str},
      "doctrine": {...},
      "missions": [{"mission_id": str, "task": str, "area": str,
                    "assigned_units": [...], "objective": {...}}],
      "unit_mission": {unit_id: mission_id}
    },
    "runtime_rules": [str, ...],   # REQUIRED, supplied by Godot (authoritative)
    "candidates": [{"candidate_id": str, "unit_id": str, "action_type": str,
                    "destination": [q, r], "origin": [q, r], "target_id": str,
                    "stronghold_id": str, "garrison_target_id": str,
                    "cost": float, "march_class": int}]
  }

Response contract: schema "openjev-score-response-v1".
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Hidden spawn (pythonw.exe / no console) may leave stdio as None; never let
# a log write crash the worker or a request handler.
STDIO_WAS_NONE = (sys.stdout is None, sys.stderr is None)
if sys.stdout is None:  # pragma: no cover - launcher environment only
    sys.stdout = open(os.devnull, "w")
if sys.stderr is None:  # pragma: no cover - launcher environment only
    sys.stderr = open(os.devnull, "w")

HERE = os.path.dirname(os.path.abspath(__file__))

MODEL_IDENTITY = "openjev-qwen3.5-4b-nli-v2"
MODEL_REPO = "AlexWortega/openjev"
MODEL_REV = "f004f37e52695d6ddfb914a64dbf93942839ba1e"
MODEL_SUBFOLDER = "qwen3.5-4b-nli-v2"
ENTAILMENT_INDEX = 1  # verified config id2label: 0 contradiction, 1 entailment, 2 neutral
EXPECTED_ID2LABEL = {"0": "contradiction", "1": "entailment", "2": "neutral"}

PROTOCOL_VERSION = "openjev-protocol-v1"
REQUEST_VERSION = "openjev-score-request-v1"
RESPONSE_VERSION = "openjev-score-response-v1"
TEMPLATE_VERSION = "T2"

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 11441
DEFAULT_MODEL_DIR = r"D:\OpenJevRuntime\models\qwen3.5-4b-nli-v2"
DEFAULT_REQUEST_LOG = r"D:\OpenJevRuntime\logs\requests.jsonl"
MAX_BODY_BYTES = 8 << 20
MAX_SEQ_LEN = 2048
# Token budget per forward chunk: chunk = BUDGET // premise_seq_len, clamped.
TOKEN_BUDGET = 32768
CHUNK_MIN = 1
CHUNK_MAX = 128


class WorkerRefused(RuntimeError):
    """Startup refusal (missing files, identity mismatch, load failure)."""


# --------------------------------------------------------------------------
# Frozen decision template T1 (RED Hands). Factual rendering only: no
# editorial tactical hints. Runtime rules arrive from Godot and are passed
# through verbatim; NOTHING here hard-codes game rules into the worker.
# --------------------------------------------------------------------------

HYPOTHESIS_LEAD = "The best immediate legal action for RED is: "

DECISION_RULE = (
    "Score each hypothesis: would a good RED commander choose this single "
    "action right now?"
)


def template_source() -> str:
    return "\n".join([TEMPLATE_VERSION, HYPOTHESIS_LEAD, DECISION_RULE])


def _fmt_own(u: dict, mission_id: str = "") -> str:
    tag = (" [%s]" % mission_id) if mission_id else ""
    return "%s %s (%d,%d) %d/%d m%.0f mp%.1f/%.1f%s%s" % (
        u.get("id", "?"), u.get("class", "?"), u.get("q", 0), u.get("r", 0),
        u.get("soldier_count", 0), u.get("max_count", 0),
        u.get("morale", 0.0), u.get("remaining_mp", 0.0), u.get("base_mp", 0.0),
        " acted" if u.get("action_ended") else " ready", tag)


def _fmt_enemy(e: dict) -> str:
    return "%s %s (%d,%d) %s" % (
        e.get("id", "?"), e.get("class", "?"), e.get("q", 0), e.get("r", 0),
        e.get("troop_text", e.get("troop_estimate", "?")))


def _fmt_stale(e: dict) -> str:
    return "%s %s t%d (%d,%d)" % (
        e.get("id", "?"), e.get("class", "?"),
        e.get("last_seen_turn", e.get("contact_turn", 0)),
        e.get("q", 0), e.get("r", 0))


def _fmt_mission(m: dict) -> str:
    obj = m.get("objective", "")
    if isinstance(obj, dict):
        kind = str(obj.get("kind", ""))
        if kind == "UNIT":
            obj = "UNIT %s" % obj.get("unit_id", "?")
        elif kind == "REGION":
            obj = "REGION %s" % obj.get("region", "?")
        else:
            obj = kind or "?"
    units = m.get("assigned_units", [])
    ulist = ",".join(str(x) for x in units) if isinstance(units, list) else ""
    return "%s %s area=%s units=[%s] obj=%s" % (
        m.get("mission_id", "?"), m.get("task", "?"), m.get("area", "?"),
        ulist, obj)


def build_premise(req: dict) -> str:
    """ONE shared premise from authorized state + commander context + rules."""
    st = req.get("authorized_state", {})
    know = st.get("knowledge", {})
    ledger = know.get("ledger", know)
    lines = []
    lines.append("BATTLE DECISION - RED TO ACT (turn %s, battle %s)." % (
        req.get("turn", "?"), req.get("battle_id", "?")))
    mission = st.get("mission", {})
    if isinstance(mission, dict) and mission.get("objective"):
        lines.append("BATTLE OBJECTIVE: %s" % mission.get("objective"))
    rules = req.get("runtime_rules", [])
    lines.append("RUNTIME RULES (authoritative, follow exactly):")
    for r in rules:
        lines.append("- %s" % r)
    ctx = req.get("commander_context", {})
    concept = ctx.get("concept", {})
    if isinstance(concept, dict) and any(concept.get(k) for k in ("objective", "intent", "main_effort")):
        lines.append("COMMANDER CONCEPT (%s): objective=%s intent=%s main_effort=%s" % (
            ctx.get("plan_source", "?"), concept.get("objective", ""),
            concept.get("intent", ""), concept.get("main_effort", "")))
    doctrine = ctx.get("doctrine", {})
    if isinstance(doctrine, dict) and doctrine:
        keys = sorted(str(k) for k in doctrine.keys())[:12]
        lines.append("DOCTRINE: %s" % ", ".join(
            "%s=%s" % (k, doctrine.get(k, "")) for k in keys))
    missions = ctx.get("missions", [])
    if isinstance(missions, list) and missions:
        lines.append("MISSIONS (%d):" % len(missions))
        for m in sorted(missions, key=lambda x: str(x.get("mission_id", ""))):
            if isinstance(m, dict):
                lines.append("- " + _fmt_mission(m))
    unit_mission = ctx.get("unit_mission", {})
    if not isinstance(unit_mission, dict):
        unit_mission = {}
    own = [u for u in ledger.get("own_forces", []) if isinstance(u, dict)]
    lines.append("OWN FORCES (%d):" % len(own))
    for u in sorted(own, key=lambda x: str(x.get("id", ""))):
        lines.append("- " + _fmt_own(u, str(unit_mission.get(u.get("id", ""), ""))))
    cur = [e for e in ledger.get("observed_blue_forces", ledger.get("current_enemy_observations", []))
           if isinstance(e, dict)]
    lines.append("OBSERVED ENEMIES (%d):" % len(cur))
    for e in sorted(cur, key=lambda x: str(x.get("id", ""))):
        lines.append("- " + _fmt_enemy(e))
    stale = [e for e in ledger.get("last_known_blue_contacts", ledger.get("last_known_enemy_contacts", []))
             if isinstance(e, dict)]
    if stale:
        lines.append("LAST KNOWN (stale, %d):" % len(stale))
        for e in sorted(stale, key=lambda x: str(x.get("id", "")))[:6]:
            lines.append("- " + _fmt_stale(e))
    shs = ledger.get("strongholds", [])
    if shs:
        lines.append("STRONGHOLDS:")
        for s in shs:
            if isinstance(s, dict):
                lines.append("- %s owner=%s walls=%s/%s breached=%s garrison=%s" % (
                    s.get("structure_id", "?"), s.get("owner", "?"),
                    s.get("fortification_hp", "?"), s.get("fortification_hp_max", "?"),
                    s.get("breached", "?"), s.get("garrison_count", "?")))
    evs = st.get("recent_events", [])
    if isinstance(evs, list) and evs:
        lines.append("RECENT EVENTS (%d):" % len(evs))
        for e in evs[-5:]:
            if isinstance(e, dict):
                lines.append("- %s" % str(e)[:160])
    cands = req.get("candidates", [])
    units = sorted({c.get("unit_id", "") for c in cands
                    if isinstance(c, dict) and c.get("unit_id")})
    lines.append("LEGAL ACTIONS AVAILABLE: %d across %d ready units%s." % (
        len(cands), len(units),
        " (+END_TURN)" if any(isinstance(c, dict) and c.get("action_type") == "END_TURN" for c in cands) else ""))
    lines.append(DECISION_RULE)
    return "\n".join(lines)


def hypothesis_for(cand: dict) -> str:
    t = cand.get("action_type", "?")
    u = cand.get("unit_id", "")
    if t == "MOVE":
        d = cand.get("destination", [0, 0])
        o = cand.get("origin", None)
        if isinstance(o, (list, tuple)) and len(o) >= 2:
            body = "%s MOVE from (%d,%d) to (%d,%d)." % (u, o[0], o[1], d[0], d[1])
        else:
            body = "%s MOVE to (%d,%d)." % (u, d[0], d[1])
    elif t == "ATTACK":
        body = "%s ATTACK %s." % (u, cand.get("target_id", "?"))
    elif t == "ASSAULT":
        gt = cand.get("garrison_target_id", "")
        body = "%s ASSAULT %s%s." % (u, cand.get("stronghold_id", "?"),
                                    " targeting garrison %s" % gt if gt else "")
    elif t == "ENTER_GARRISON":
        body = "%s ENTER_GARRISON %s." % (u, cand.get("stronghold_id", "?"))
    elif t == "END_TURN":
        body = "END_TURN (end the turn now)."
    else:
        body = "%s %s." % (u, t)
    return HYPOTHESIS_LEAD + body


# --------------------------------------------------------------------------
# Validation
# --------------------------------------------------------------------------

class SchemaMismatch(ValueError):
    pass


def validate_request(raw) -> dict:
    if not isinstance(raw, dict):
        raise SchemaMismatch("body must be a JSON object")
    if raw.get("schema_version") != REQUEST_VERSION:
        raise SchemaMismatch("schema_version must be %r" % REQUEST_VERSION)
    if str(raw.get("side", "")).lower() != "red":
        raise SchemaMismatch("side must be 'red'")
    rules = raw.get("runtime_rules", [])
    if not isinstance(rules, list) or not rules or not all(
            isinstance(r, str) and r.strip() for r in rules):
        raise SchemaMismatch("runtime_rules must be a non-empty string list (rules stay external to weights)")
    cands = raw.get("candidates", [])
    if not isinstance(cands, list) or not cands:
        raise SchemaMismatch("candidates must be a non-empty list")
    seen = set()
    for c in cands:
        if not isinstance(c, dict):
            raise SchemaMismatch("each candidate must be an object")
        cid = c.get("candidate_id", "")
        if not cid or not isinstance(cid, str):
            raise SchemaMismatch("each candidate needs a string candidate_id")
        if cid in seen:
            raise SchemaMismatch("duplicate candidate_id: %s" % cid)
        seen.add(cid)
        if not c.get("action_type"):
            raise SchemaMismatch("candidate %s needs action_type" % cid)
    return raw


def canonical_sha256(obj: dict) -> str:
    blob = json.dumps(obj, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(blob).hexdigest()


# --------------------------------------------------------------------------
# Model (loaded ONCE, frozen)
# --------------------------------------------------------------------------

def load_model(model_dir: str, device: str, dtype: str):
    import torch
    from transformers import AutoModelForSequenceClassification, AutoTokenizer
    if not os.path.isdir(model_dir):
        raise WorkerRefused("model dir not found: %s" % model_dir)
    for f in ("config.json", "model.safetensors", "tokenizer.json"):
        if not os.path.isfile(os.path.join(model_dir, f)):
            raise WorkerRefused("model dir missing %s: %s" % (f, model_dir))
    t0 = time.perf_counter()
    dt = torch.bfloat16 if dtype == "bf16" else torch.float16
    tok = AutoTokenizer.from_pretrained(model_dir, local_files_only=True)
    model = AutoModelForSequenceClassification.from_pretrained(
        model_dir, dtype=dt, local_files_only=True)
    # Fail closed on label identity: entailment MUST be index 1.
    id2label = {str(k): str(v) for k, v in model.config.id2label.items()}
    if id2label != EXPECTED_ID2LABEL:
        raise WorkerRefused("id2label mismatch: %s" % id2label)
    model.to(device).eval()
    for p in model.parameters():
        p.requires_grad_(False)
    if tok.pad_token is None:
        tok.pad_token = tok.eos_token
    tok.padding_side = "right"
    template = getattr(model.config, "nli_template", None)
    if not template or "{premise}" not in template or "{hypothesis}" not in template:
        raise WorkerRefused("config nli_template missing/malformed: %r" % template)
    dt_load = time.perf_counter() - t0
    vram = 0.0
    if device == "cuda" and torch.cuda.is_available():
        vram = float(torch.cuda.max_memory_allocated(device)) / 1e9
    else:
        raise WorkerRefused("CUDA unavailable (device=%s)" % device)
    n_params = sum(p.numel() for p in model.parameters())
    info = {"load_s": round(dt_load, 2), "vram_gb": round(vram, 2),
            "template": template, "id2label": id2label,
            "n_parameters": int(n_params)}
    return model, tok, template, info


class OpenJevScorer:
    """In-process scoring API (shared by HTTP handler and tests)."""

    def __init__(self, model, tok, template: str, load_info: dict,
                 model_dir: str, device: str, dtype: str,
                 request_log=None) -> None:
        self.model = model
        self.tok = tok
        self.template = template
        self.load_info = load_info
        self.model_dir = model_dir
        self.device = device
        self.dtype = dtype
        self.request_log = request_log
        self.started_at = time.time()
        self.count = 0
        self._lock = threading.Lock()

    def identity(self) -> dict:
        return {
            "model_identity": MODEL_IDENTITY,
            "model_repo": MODEL_REPO,
            "model_rev": MODEL_REV,
            "subfolder": MODEL_SUBFOLDER,
            "protocol_version": PROTOCOL_VERSION,
            "request_schema": REQUEST_VERSION,
            "response_schema": RESPONSE_VERSION,
            "template_version": TEMPLATE_VERSION,
            "template_sha256": hashlib.sha256(
                template_source().encode()).hexdigest(),
            "entailment_index": ENTAILMENT_INDEX,
            "id2label": EXPECTED_ID2LABEL,
            "n_parameters": self.load_info.get("n_parameters", 0),
            "device": self.device,
            "dtype": self.dtype,
            "eval_mode": True,
            "gradients": False,
            "pid": os.getpid(),
        }

    def score_request(self, req: dict) -> dict:
        import torch
        t_all = time.perf_counter()
        premise = build_premise(req)
        cands = req["candidates"]
        hyps = [(c.get("candidate_id", "?"), hypothesis_for(c)) for c in cands]
        texts = [self.template.format(premise=premise, hypothesis=h)
                 for _, h in hyps]
        # Measure untruncated lengths first (honest truncation telemetry).
        probe = self.tok(texts, padding=False, truncation=False,
                         return_attention_mask=False)
        lens = [len(ids) for ids in probe["input_ids"]]
        max_len = max(lens) if lens else 0
        truncated = [hyps[i][0] for i, n in enumerate(lens) if n > MAX_SEQ_LEN]
        premise_toks = len(self.tok(premise, truncation=False,
                                    return_attention_mask=False)["input_ids"])
        chunk = max(CHUNK_MIN, min(CHUNK_MAX, TOKEN_BUDGET // max(1, premise_toks)))
        out = []
        t_encode = 0.0
        t_fwd = 0.0
        for s in range(0, len(texts), chunk):
            part = texts[s:s + chunk]
            t0 = time.perf_counter()
            batch = self.tok(part, padding=True, truncation=True,
                             max_length=MAX_SEQ_LEN, return_tensors="pt")
            batch = {k: v.to(self.device) for k, v in batch.items()}
            t_encode += time.perf_counter() - t0
            t0 = time.perf_counter()
            with torch.no_grad():
                logits = self.model(**batch).logits.float()
            t_fwd += time.perf_counter() - t0
            for j, row in enumerate(logits.cpu().tolist()):
                out.append({"candidate_id": hyps[s + j][0],
                            "entailment": float(row[ENTAILMENT_INDEX])})
        # Deterministic global argmax: entailment desc, input order tie-break.
        order = {cid: i for i, (cid, _) in enumerate(hyps)}
        ranked = sorted(out, key=lambda r: (-r["entailment"], order[r["candidate_id"]]))
        for i, r in enumerate(ranked):
            r["rank"] = i + 1
        by_id = {r["candidate_id"]: r for r in ranked}
        ordered = [dict(by_id[cid]) for cid, _ in hyps]
        top = ranked[0] if ranked else None
        total_ms = (time.perf_counter() - t_all) * 1000.0
        return {
            "ok": True,
            "schema_version": RESPONSE_VERSION,
            "model": MODEL_IDENTITY,
            "model_rev": MODEL_REV,
            "template_version": TEMPLATE_VERSION,
            "candidate_count": len(hyps),
            "selected_candidate_id": top["candidate_id"] if top else None,
            "scores": ordered,
            "top5": [r["candidate_id"] for r in ranked[:5]],
            "latency_ms": {"total": round(total_ms, 1),
                           "encode": round(t_encode * 1000.0, 1),
                           "forward": round(t_fwd * 1000.0, 1)},
            "premise_chars": len(premise),
            "premise_tokens": premise_toks,
            "max_seq_len": max_len,
            "truncated_count": len(truncated),
            "truncated_ids": truncated[:8],
            "chunk": chunk,
            "rules_count": len(req.get("runtime_rules", [])),
            "request_sha256": canonical_sha256(req),
            "identity": self.identity(),
        }

    def score_from_json(self, body: bytes) -> tuple:
        try:
            raw = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as e:
            return ({"ok": False, "schema_version": RESPONSE_VERSION,
                     "error": {"code": "SCHEMA_MISMATCH",
                               "detail": "body is not valid JSON: %s" % e},
                     "identity": self.identity()}, None)
        try:
            req = validate_request(raw)
        except SchemaMismatch as e:
            return ({"ok": False, "schema_version": RESPONSE_VERSION,
                     "error": {"code": "SCHEMA_MISMATCH", "detail": str(e)},
                     "identity": self.identity()}, None)
        try:
            resp = self.score_request(req)
        except Exception as e:  # noqa: BLE001 - service must never raise raw
            return ({"ok": False, "schema_version": RESPONSE_VERSION,
                     "error": {"code": "INFERENCE_ERROR",
                               "detail": "%s: %s" % (type(e).__name__, e)[:500]},
                     "identity": self.identity()}, req)
        return resp, req

    def log_exchange(self, req, resp: dict) -> None:
        if not self.request_log or req is None:
            return
        row = {"request": req, "response": resp}
        with self._lock:
            with open(self.request_log, "a", encoding="utf-8") as f:
                f.write(json.dumps(row, separators=(",", ":")) + "\n")


# --------------------------------------------------------------------------
# HTTP service
# --------------------------------------------------------------------------

def make_handler(scorer: OpenJevScorer, shutdown_token=None,
                 parent_pid=None, log_file=None):
    class Handler(BaseHTTPRequestHandler):
        server_version = "OpenJevWorker/1.0"

        def _send(self, obj: dict) -> None:
            blob = json.dumps(obj).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(blob)))
            self.end_headers()
            self.wfile.write(blob)

        def do_GET(self) -> None:  # noqa: N802
            if self.path.split("?")[0] != "/health":
                self.send_response(404)
                self.end_headers()
                return
            with scorer._lock:
                count = scorer.count
            self._send({"ok": True, "service": "openjev-worker",
                        "status": "READY",
                        "protocol_version": PROTOCOL_VERSION,
                        "pid": os.getpid(),
                        "parent_pid": parent_pid,
                        "identity": scorer.identity(),
                        "load": scorer.load_info,
                        "uptime_s": time.time() - scorer.started_at,
                        "requests": count})

        def do_POST(self) -> None:  # noqa: N802
            path = self.path.split("?")[0]
            if path == "/shutdown":
                self._handle_shutdown()
                return
            if path != "/score":
                self.send_response(404)
                self.end_headers()
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                length = 0
            if length <= 0 or length > MAX_BODY_BYTES:
                self._send({"ok": False, "schema_version": RESPONSE_VERSION,
                            "error": {"code": "SCHEMA_MISMATCH",
                                      "detail": "bad Content-Length %s" % length},
                            "identity": scorer.identity()})
                return
            body = self.rfile.read(length)
            resp, req = scorer.score_from_json(body)
            with scorer._lock:
                scorer.count += 1
            scorer.log_exchange(req, resp)
            self._send(resp)

        def _handle_shutdown(self) -> None:
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                length = 0
            body = self.rfile.read(length) if 0 < length <= 4096 else b""
            presented = ""
            try:
                presented = str(json.loads(body.decode("utf-8") or "{}")
                                .get("token", ""))
            except (UnicodeDecodeError, json.JSONDecodeError, AttributeError):
                presented = ""
            if not shutdown_token or presented != shutdown_token:
                self._send({"ok": False, "error": {"code": "FORBIDDEN",
                           "detail": "shutdown token missing or mismatch"}})
                return
            self._send({"ok": True, "status": "SHUTTING_DOWN",
                        "pid": os.getpid()})
            sys.stderr.write("[openjev-worker] owned shutdown requested\n")
            threading.Thread(target=self.server.shutdown,
                             name="owned-shutdown", daemon=True).start()

        def log_message(self, fmt: str, *args) -> None:
            try:
                sys.stderr.write("[openjev-worker] " + fmt % args + "\n")
            except (AttributeError, OSError, ValueError):
                pass
            if log_file:
                try:
                    with open(log_file, "a", encoding="utf-8") as f:
                        f.write("[openjev-worker] " + fmt % args + "\n")
                except OSError:
                    pass

    return Handler


def _parent_alive(pid) -> bool:
    if pid is None or pid <= 0:
        return True  # unmonitored (manual start)
    if os.name == "nt":
        try:
            import ctypes
            kernel32 = ctypes.windll.kernel32
            handle = kernel32.OpenProcess(0x1000, False, pid)
            if not handle:
                return False
            code = ctypes.c_ulong()
            alive = (kernel32.GetExitCodeProcess(handle, ctypes.byref(code))
                     and code.value == 259)  # STILL_ACTIVE
            kernel32.CloseHandle(handle)
            return bool(alive)
        except Exception:  # noqa: BLE001 - monitoring must never crash serve
            return True
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False
    except Exception:  # noqa: BLE001
        return True


def _watch_parent(server: ThreadingHTTPServer, parent_pid: int,
                  interval_s: float = 2.0) -> None:
    while True:
        time.sleep(interval_s)
        if not _parent_alive(parent_pid):
            sys.stderr.write(
                "[openjev-worker] parent pid %d gone; exiting\n" % parent_pid)
            server.shutdown()
            return


def _warmup(scorer: OpenJevScorer, log_file=None) -> None:
    """One tiny forward so READY means kernels are autotuned (inference-only)."""
    import torch
    t0 = time.perf_counter()
    batch = scorer.tok(["Premise: warmup\nHypothesis: warmup."] * 4,
                       padding=True, truncation=True, max_length=64,
                       return_tensors="pt")
    batch = {k: v.to(scorer.device) for k, v in batch.items()}
    with torch.no_grad():
        scorer.model(**batch)
    if torch.cuda.is_available():
        torch.cuda.synchronize()
    scorer.load_info["warmup_s"] = round(time.perf_counter() - t0, 2)
    _emit("[openjev-worker] warmup done in %.1fs" % (time.perf_counter() - t0),
          log_file)


def _emit(line: str, log_file=None) -> None:
    try:
        print(line, flush=True)
    except (AttributeError, OSError, ValueError):
        pass
    if log_file:
        try:
            stamp = time.strftime("%Y-%m-%dT%H:%M:%S")
            with open(log_file, "a", encoding="utf-8") as f:
                f.write("%s %s\n" % (stamp, line))
        except OSError:
            pass


def serve(host: str, port: int, model_dir: str, device: str, dtype: str,
          request_log, parent_pid=None, shutdown_token=None,
          log_file=None) -> None:
    model, tok, template, info = load_model(model_dir, device, dtype)
    if request_log:
        try:
            os.makedirs(os.path.dirname(os.path.abspath(request_log)),
                        exist_ok=True)
        except OSError:
            pass
    scorer = OpenJevScorer(model, tok, template, info, model_dir, device,
                           dtype, request_log)
    _warmup(scorer, log_file)
    server = ThreadingHTTPServer(
        (host, port), make_handler(scorer, shutdown_token, parent_pid,
                                   log_file))
    server.daemon_threads = True
    bound_port = server.server_address[1]
    _emit("[openjev-worker] READY model=%s rev=%s params=%d device=%s "
          "dtype=%s load_s=%.1f vram_gb=%.2f url=http://%s:%d pid=%d "
          "parent_pid=%s template=%s entailment_index=%d" % (
              MODEL_IDENTITY, MODEL_REV, info["n_parameters"], device, dtype,
              info["load_s"], info["vram_gb"], host, bound_port, os.getpid(),
              parent_pid, TEMPLATE_VERSION, ENTAILMENT_INDEX), log_file)
    if parent_pid:
        threading.Thread(target=_watch_parent, args=(server, parent_pid),
                         name="parent-watch", daemon=True).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    _emit("[openjev-worker] stopped", log_file)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="OpenJev live inference worker (RED Hands scorer)")
    ap.add_argument("--host", default=DEFAULT_HOST)
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--model-dir", default=DEFAULT_MODEL_DIR)
    ap.add_argument("--device", default="cuda")
    ap.add_argument("--dtype", default="bf16")
    ap.add_argument("--request-log", default=DEFAULT_REQUEST_LOG)
    ap.add_argument("--no-request-log", action="store_true")
    ap.add_argument("--parent-pid", type=int, default=0)
    ap.add_argument("--shutdown-token", default="")
    ap.add_argument("--log-file", default="")
    ap.add_argument("--smoke", action="store_true",
                    help="load model, run one synthetic /score, print, exit")
    args = ap.parse_args(argv)
    log_file = args.log_file.strip() or None
    if args.smoke:
        return _smoke(args, log_file)
    try:
        serve(args.host, args.port, args.model_dir, args.device, args.dtype,
              None if args.no_request_log else args.request_log,
              parent_pid=args.parent_pid or None,
              shutdown_token=args.shutdown_token.strip() or None,
              log_file=log_file)
    except WorkerRefused as e:
        _emit("[openjev-worker] REFUSED: %s" % e, log_file)
        return 2
    except OSError as e:
        _emit("[openjev-worker] BIND FAILED: %s" % e, log_file)
        return 3
    return 0


def _smoke(args, log_file) -> int:
    """Load model once, score one synthetic RED request, print, exit."""
    try:
        model, tok, template, info = load_model(args.model_dir, args.device,
                                               args.dtype)
    except WorkerRefused as e:
        _emit("[openjev-worker] SMOKE REFUSED: %s" % e, log_file)
        return 2
    scorer = OpenJevScorer(model, tok, template, info, args.model_dir,
                           args.device, args.dtype, None)
    req = {
        "schema_version": REQUEST_VERSION,
        "battle_id": "smoke", "turn": 1, "side": "red",
        "authorized_state": {
            "knowledge": {"ledger": {
                "own_forces": [
                    {"id": "R_HQ_1", "class": "hq", "q": 5, "r": 0,
                     "soldier_count": 200, "max_count": 200, "morale": 100.0,
                     "remaining_mp": 2.0, "base_mp": 2.0},
                    {"id": "R_INF_1", "class": "infantry", "q": 1, "r": 0,
                     "soldier_count": 400, "max_count": 477, "morale": 95.0,
                     "remaining_mp": 2.0, "base_mp": 2.0}],
                "observed_blue_forces": [
                    {"id": "B_HQ_1", "class": "hq", "q": 0, "r": 0,
                     "troop_text": "weak (band 1)"}],
                "last_known_blue_contacts": [],
                "strongholds": [],
            }},
            "mission": {"type": "destroy_all_red", "objective": "Destroy the BLUE HQ.",
                        "status": "ongoing"},
            "recent_events": [],
        },
        "commander_context": {
            "plan_source": "local_fallback",
            "concept": {"objective": "Smoke concept.", "intent": "Smoke.",
                        "main_effort": "CENTER"},
            "doctrine": {"aggression": "STANDARD"},
            "missions": [{"mission_id": "M01", "task": "FIX", "area": "CENTER",
                          "assigned_units": ["R_INF_1"],
                          "objective": {"kind": "REGION", "region": "CENTER"}}],
            "unit_mission": {"R_INF_1": "M01"},
        },
        "runtime_rules": [
            "PRIMARY: WIN THE BATTLE.",
            "TERMINAL: OWN HQ DESTROYED = IMMEDIATE DEFEAT. ENEMY HQ DESTROYED = IMMEDIATE VICTORY.",
            "SECONDARY: AMONG COMPARABLY WINNING OPTIONS, MINIMIZE UNNECESSARY FRIENDLY LOSSES.",
            "MISSION: FOLLOW COMMANDER MISSION/TARGET/DOCTRINE UNLESS IMMEDIATE TERMINAL VICTORY/DEFEAT OVERRIDES IT.",
        ],
        "candidates": [
            {"candidate_id": "ATTACK|R_INF_1|B_HQ_1", "unit_id": "R_INF_1",
             "action_type": "ATTACK", "target_id": "B_HQ_1"},
            {"candidate_id": "MOVE|R_INF_1|2,0", "unit_id": "R_INF_1",
             "action_type": "MOVE", "origin": [1, 0], "destination": [2, 0]},
            {"candidate_id": "WAIT|R_INF_1", "unit_id": "R_INF_1",
             "action_type": "WAIT"},
            {"candidate_id": "WAIT|R_HQ_1", "unit_id": "R_HQ_1",
             "action_type": "WAIT"},
        ],
    }
    t0 = time.perf_counter()
    resp = scorer.score_request(validate_request(req))
    dt = time.perf_counter() - t0
    print(json.dumps({"load": info, "top1": resp["selected_candidate_id"],
                      "top5": resp["top5"], "latency_ms": resp["latency_ms"],
                      "total_s": round(dt, 2),
                      "premise_chars": resp["premise_chars"],
                      "truncated": resp["truncated_count"],
                      "chunk": resp["chunk"]}, indent="\t"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
