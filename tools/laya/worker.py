"""LAYA LIVE INTEGRATION V0 - persistent local inference worker.

Loads convaiinnovations/laya-multilingual ONCE (frozen, eval, no grad) and
serves PER-UNIT SEQUENTIAL choice decisions for the Godot Hands loops
(RED live path; SYMMETRIC V1 also serves the BLUE side through the same
model, same schema, side-relative state - "side": "red" | "blue").

One request = ONE unresolved unit + ALL of that unit's legal actions.
The worker never sees other units' actions and never chooses unit order.

Endpoints (localhost only):
  GET  /health    readiness + strict identity handshake
  POST /decide    choose ONE candidate from this unit's legal set
  POST /shutdown  owned shutdown (token-authenticated)

NO TRAINING. No weight updates, no fine-tuning, no adapters. Inference only.
Rules/mission/state/legal-actions are runtime inputs from Godot.

Request contract: schema "laya-unit-choice-v1".
  {
    "schema_version": "laya-unit-choice-v1",
    "battle_id": str, "turn": int, "side": "red" | "blue",
    "unit_id": str,                       # the ONE current unit
    "authorized_state": {
      "unit": {...},                      # current unit full payload
      "unit_mission": {...},              # this unit's assigned mission (or {})
      "knowledge": {"ledger": {...}},     # RED-authorized ledger
      "mission": {"type": str, "objective": str, "status": str},
      "recent_events": [...]
    },
    "commander_context": {
      "plan_source": str, "plan_version": int,
      "concept": {...}, "doctrine": {...},
      "missions": [...], "unit_mission": {unit_id: mission_id}
    },
    "runtime_rules": [str, ...],           # REQUIRED, from Godot, verbatim
    "candidates": [{"candidate_id": str, "unit_id": str, "action_type": str,
                    "option_text": str, ...}]   # ALL for THIS unit only
  }

Response contract: schema "laya-unit-choice-response-v1".
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
if sys.stdout is None:  # pragma: no cover - launcher environment only
    sys.stdout = open(os.devnull, "w")
if sys.stderr is None:  # pragma: no cover - launcher environment only
    sys.stderr = open(os.devnull, "w")

os.environ.setdefault("USE_TF", "0")
os.environ.setdefault("HF_HUB_OFFLINE", "1")

HERE = os.path.dirname(os.path.abspath(__file__))

MODEL_IDENTITY = "laya-multilingual-322m"
MODEL_REPO = "convaiinnovations/laya-multilingual"
MODEL_REV = "052592a15d198d9ad47da779604259b10b47b7aa"
MODEL_WEIGHTS_SHA256 = "9D628FD971B700382AC6F65920A86F149777B2E748E0C955FB3B19695AA8F204"
EXPECTED_PARAMS = 321908995
# Checkpoint-identity budgets (rl_agent_config.json must say these).
CKPT_MAX_LEN = 1024
CKPT_HEAD_MAX_LEN = 256
# Operational budgets (verified override, recorded in HANDOFF + launcher):
# backbone is ModernBERT/RoPE with max_position_embeddings=8192, so 2048
# inference positions are natively supported. Default 256-token head
# budget mechanically destroyed per-unit option text (per-option squeeze
# to 4-7 tokens for 31-57 option sets); 1024 head fits complete per-unit
# sets (~60 options x ~16 tokens) with state room to spare (~1000).
# Tokenization parameters only: no weight/architecture change.
OP_MAX_LEN = 2048
OP_HEAD_MAX_LEN = 1024

PROTOCOL_VERSION = "laya-protocol-v1"
REQUEST_VERSION = "laya-unit-choice-v1"
RESPONSE_VERSION = "laya-unit-choice-response-v1"
GROUP_REQUEST_VERSION = "laya-group-choice-v1"
GROUP_RESPONSE_VERSION = "laya-group-choice-response-v1"
TEMPLATE_VERSION = "L2"

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 11442
DEFAULT_MODEL_DIR = r"D:\LayaRuntime\models\laya-multilingual"
DEFAULT_REQUEST_LOG = r"D:\LayaRuntime\logs\requests.jsonl"
MAX_BODY_BYTES = 8 << 20


class WorkerRefused(RuntimeError):
    """Startup refusal (missing files, identity mismatch, load failure)."""


# --------------------------------------------------------------------------
# Frozen decision template L1 (per-unit RED Hands). Factual rendering only:
# no editorial tactical hints. Runtime rules arrive from Godot and are passed
# through verbatim; NOTHING here hard-codes game rules into the worker.
# --------------------------------------------------------------------------

INSTRUCTIONS = (
    "What should this unit do now? Choose exactly one legal action."
)

STATE_HEADER = "RED PER-UNIT DECISION"

# Liberation V1: group coordinator question. Same frozen choice model, same
# budgets; the KEY stays "action" (SDK-addressed), only instructions/state
# change. Candidates are Godot-generated feasible group approaches.
GROUP_INSTRUCTIONS = (
    "Which coordinated approach should this group attempt now? "
    "Choose exactly one feasible group plan."
)

GROUP_STATE_HEADER = "RED GROUP COORDINATION"


def template_source() -> str:
    return "\n".join([TEMPLATE_VERSION, STATE_HEADER, INSTRUCTIONS])


def template_hash() -> str:
    return hashlib.sha256(template_source().encode("utf-8")).hexdigest()[:16]


def _fmt_unit(u: dict, mission_id: str = "") -> str:
    tag = (" [%s]" % mission_id) if mission_id else ""
    return "%s %s (%d,%d) %d/%d m%.0f mp%.1f/%.1f%s%s" % (
        u.get("id", "?"), u.get("class", "?"), u.get("q", 0), u.get("r", 0),
        u.get("soldier_count", 0), u.get("max_count", 0),
        u.get("morale", 0.0), u.get("remaining_mp", 0.0),
        u.get("base_mp", 0.0),
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


def _fmt_objective(obj) -> str:
    if isinstance(obj, dict):
        kind = str(obj.get("kind", ""))
        if kind == "UNIT":
            return "UNIT %s" % obj.get("unit_id", "?")
        if kind == "REGION":
            return "REGION %s" % obj.get("region", "?")
        return kind or "?"
    return str(obj) if obj else "?"


def _fmt_mission(m: dict) -> str:
    units = m.get("assigned_units", [])
    ulist = ",".join(str(x) for x in units) if isinstance(units, list) else ""
    base = "%s %s area=%s units=[%s] obj=%s" % (
        m.get("mission_id", "?"), m.get("task", "?"), m.get("area", "?"),
        ulist, _fmt_objective(m.get("objective", "")))
    # Liberation V1: rich intent rides the same line (bounded). Absent on
    # legacy-shaped missions, which render exactly as before.
    intent = str(m.get("intent", "") or "")[:120]
    if intent:
        base += " intent=%s" % intent
    coord = str(m.get("coordination_intent", "") or "")[:120]
    if coord:
        base += " coord=%s" % coord
    return base


def build_state_text(req: dict) -> str:
    """Compact authorized state for ONE unit. Factual lines only."""
    az = req.get("authorized_state", {})
    cc = req.get("commander_context", {})
    unit = az.get("unit", {})
    unit_mission = az.get("unit_mission", {})
    mission = az.get("mission", {})
    ledger = (az.get("knowledge", {}) or {}).get("ledger", {})
    # SYMMETRIC V1: the frozen template header/handshake is untouched (RED
    # prompts stay byte-identical); BLUE requests get one factual side line
    # plus their own ledger keys (mirrored names in the projector).
    side = req.get("side", "red")
    lines = [STATE_HEADER]
    if side == "blue":
        lines.append("SIDE blue")
    lines.append("TURN %s OBJ %s STATUS %s" % (
        req.get("turn", "?"), mission.get("objective", "?"),
        mission.get("status", "?")))
    for i, rule in enumerate(req.get("runtime_rules", [])):
        lines.append("RULE%d: %s" % (i + 1, str(rule)[:220]))
    concept = cc.get("concept", {})
    if concept:
        lines.append("CONCEPT obj=%s intent=%s main=%s" % (
            str(concept.get("objective", "?"))[:120],
            str(concept.get("intent", "?"))[:120],
            str(concept.get("main_effort", "?"))[:40]))
    doctrine = cc.get("doctrine", {})
    if isinstance(doctrine, dict) and doctrine:
        pairs = ["%s=%s" % (k, str(v)[:30]) for k, v in
                 sorted(doctrine.items())[:12]]
        lines.append("DOCTRINE " + " ".join(pairs))
    lines.append("UNIT " + _fmt_unit(
        unit, str((cc.get("unit_mission", {}) or {}).get(
            req.get("unit_id", ""), ""))))
    if isinstance(unit_mission, dict) and unit_mission:
        lines.append("ASSIGNED " + _fmt_mission(unit_mission))
    else:
        lines.append("ASSIGNED none")
    for m in (cc.get("missions", []) or [])[:8]:
        if isinstance(m, dict):
            lines.append("MISSION " + _fmt_mission(m))
    # Liberation V1: phase-level intent + this unit's role/limits + the
    # shared tactical blackboard. All optional; absent without Godot L2.
    vic = cc.get("victory", {})
    if isinstance(vic, dict) and vic:
        lines.append("VICTORY %s intent=%s" % (
            str(vic.get("current_phase_id", "?")),
            str(vic.get("commander_intent", "") or "")[:160]))
        if str(vic.get("phase_purpose", "") or ""):
            lines.append("PURPOSE %s" % str(vic.get("phase_purpose", ""))[:160])
    if isinstance(unit_mission, dict) and unit_mission:
        role = ""
        roles = unit_mission.get("force_roles", {})
        if isinstance(roles, dict):
            role = str(roles.get(req.get("unit_id", ""), "") or "")[:140]
        if role:
            lines.append("ROLE %s" % role)
        for lim in (unit_mission.get("constraints_nl", []) or [])[:3]:
            lines.append("LIMIT %s" % str(lim)[:140])
        for eff in (unit_mission.get("desired_effects", []) or [])[:3]:
            lines.append("EFFECT %s" % str(eff)[:140])
    tac = req.get("tactical", {})
    if isinstance(tac, dict) and str(tac.get("text", "") or ""):
        lines.append("TACTICAL-BEGIN")
        for tl in str(tac.get("text", "")).split("\n")[:24]:
            if tl.strip():
                lines.append(tl.strip()[:200])
        lines.append("TACTICAL-END")
    own = (ledger.get("own_forces", []) or [])[:14]
    for u in own:
        if isinstance(u, dict) and str(u.get("id", "")) != req.get("unit_id"):
            lines.append("OWN " + _fmt_unit(
                u, str((cc.get("unit_mission", {}) or {}).get(
                    str(u.get("id", "")), ""))))
    if side == "blue":
        foe_rows = ledger.get("current_enemy_observations", []) or []
        stale_rows = ledger.get("last_known_enemy_contacts", []) or []
    else:
        foe_rows = ledger.get("observed_blue_forces", []) or []
        stale_rows = ledger.get("last_known_blue_contacts", []) or []
    for e in foe_rows[:14]:
        if isinstance(e, dict):
            lines.append("FOE " + _fmt_enemy(e))
    for e in stale_rows[:6]:
        if isinstance(e, dict):
            lines.append("STALE " + _fmt_stale(e))
    for sh in (ledger.get("strongholds", []) or [])[:6]:
        if isinstance(sh, dict):
            lines.append("HOLD %s own=%s wall=%s gar=%s" % (
                sh.get("structure_id", sh.get("id", "?")),
                sh.get("owner", "?"), sh.get("wall_hp", "?"),
                sh.get("garrison_count", "?")))
    for ev in (az.get("recent_events", []) or [])[-5:]:
        lines.append("EVT " + str(ev)[:160])
    return "\n".join(lines)


def build_group_state_text(req: dict) -> str:
    """Compact group state for ONE mission group. Factual lines only."""
    lines = [GROUP_STATE_HEADER]
    lines.append("TURN %s MISSION %s" % (
        req.get("turn", "?"), req.get("mission_id", "?")))
    m = req.get("mission", {})
    if isinstance(m, dict) and m:
        lines.append("G-MISSION " + _fmt_mission(m))
        pri = str(m.get("priority", "") or "")[:140]
        if pri:
            lines.append("G-PRIORITY %s" % pri)
        for lim in (m.get("constraints_nl", []) or [])[:4]:
            lines.append("G-LIMIT %s" % str(lim)[:140])
        roles = m.get("force_roles", {})
        if isinstance(roles, dict):
            for uid, txt in sorted(roles.items())[:8]:
                lines.append("G-ROLE %s: %s" % (uid, str(txt)[:140]))
        prefs = m.get("target_preferences", {})
        if isinstance(prefs, dict):
            pu = [str(x) for x in (prefs.get("units", []) or [])[:4]]
            pc = [str(x) for x in (prefs.get("classes", []) or [])[:4]]
            if pu or pc:
                lines.append("G-PREFER units=[%s] classes=[%s]" % (
                    ",".join(pu), ",".join(pc)))
    for u in (req.get("group_units", []) or [])[:8]:
        if isinstance(u, dict):
            lines.append("G-UNIT " + _fmt_unit(u))
    bb = str(req.get("blackboard", "") or "")
    if bb:
        lines.append("TACTICAL-BEGIN")
        for tl in bb.split("\n")[:20]:
            if tl.strip():
                lines.append(tl.strip()[:200])
        lines.append("TACTICAL-END")
    for e in (req.get("known_foes", []) or [])[:8]:
        if isinstance(e, dict):
            lines.append("FOE " + _fmt_enemy(e))
    for ev in (req.get("recent_events", []) or [])[-4:]:
        lines.append("EVT " + str(ev)[:160])
    return "\n".join(lines)


def option_keys(n: int):
    """Short stable option keys: A..Z, AA..AZ, BA... (order = candidate order)."""
    keys = []
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    i = 0
    while len(keys) < n:
        if i < 26:
            keys.append(alphabet[i])
        else:
            keys.append(alphabet[(i // 26) - 1] + alphabet[i % 26])
        i += 1
    return keys


class SchemaMismatch(ValueError):
    pass


def validate_request(raw) -> dict:
    if not isinstance(raw, dict):
        raise SchemaMismatch("request must be a JSON object")
    if raw.get("schema_version") != REQUEST_VERSION:
        raise SchemaMismatch("schema_version must be %r" % REQUEST_VERSION)
    if raw.get("side") not in ("red", "blue"):
        raise SchemaMismatch("side must be 'red' or 'blue'")
    unit_id = str(raw.get("unit_id", ""))
    if not unit_id:
        raise SchemaMismatch("unit_id is required")
    rules = raw.get("runtime_rules", [])
    if not isinstance(rules, list) or not rules:
        raise SchemaMismatch("runtime_rules must be a non-empty list")
    cands = raw.get("candidates", [])
    if not isinstance(cands, list) or not cands:
        raise SchemaMismatch("candidates must be a non-empty list")
    seen = set()
    for c in cands:
        if not isinstance(c, dict):
            raise SchemaMismatch("candidate must be an object")
        cid = str(c.get("candidate_id", ""))
        if not cid:
            raise SchemaMismatch("candidate_id is required")
        if cid in seen:
            raise SchemaMismatch("duplicate candidate_id %r" % cid)
        seen.add(cid)
        if str(c.get("unit_id", "")) != unit_id:
            raise SchemaMismatch(
                "per-unit violation: candidate %r is not for unit %r"
                % (cid, unit_id))
        if not str(c.get("option_text", "")):
            raise SchemaMismatch("option_text required for %r" % cid)
    return raw


def validate_group_request(raw) -> dict:
    if not isinstance(raw, dict):
        raise SchemaMismatch("request must be a JSON object")
    if raw.get("schema_version") != GROUP_REQUEST_VERSION:
        raise SchemaMismatch("schema_version must be %r" % GROUP_REQUEST_VERSION)
    if raw.get("side") not in ("red", "blue"):
        raise SchemaMismatch("side must be 'red' or 'blue'")
    if not str(raw.get("mission_id", "")):
        raise SchemaMismatch("mission_id is required")
    gu = raw.get("group_units", [])
    if not isinstance(gu, list) or len(gu) < 2:
        raise SchemaMismatch("group_units needs 2+ units")
    cands = raw.get("candidates", [])
    if not isinstance(cands, list) or not cands:
        raise SchemaMismatch("candidates must be a non-empty list")
    seen = set()
    for c in cands:
        if not isinstance(c, dict):
            raise SchemaMismatch("candidate must be an object")
        cid = str(c.get("candidate_id", ""))
        if not cid:
            raise SchemaMismatch("candidate_id is required")
        if cid in seen:
            raise SchemaMismatch("duplicate candidate_id %r" % cid)
        seen.add(cid)
        if not str(c.get("option_text", "")):
            raise SchemaMismatch("option_text required for %r" % cid)
    return raw


def canonical_sha256(obj: dict) -> str:
    blob = json.dumps(obj, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False, default=str).encode("utf-8")
    return hashlib.sha256(blob).hexdigest()


def _sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest().upper()


def load_agent(model_dir: str, device: str, max_len: int, head_max_len: int):
    """Load the frozen Laya agent exactly once. Refuses on identity mismatch."""
    import torch
    t0 = time.perf_counter()
    if not os.path.isdir(model_dir):
        raise WorkerRefused("model dir missing: %s" % model_dir)
    for need in ("rl_agent_config.json", "model.safetensors"):
        if not os.path.exists(os.path.join(model_dir, need)):
            raise WorkerRefused("model file missing: %s" % need)
    got_sha = _sha256_file(os.path.join(model_dir, "model.safetensors"))
    if got_sha != MODEL_WEIGHTS_SHA256:
        raise WorkerRefused(
            "weights SHA256 mismatch: got %s want %s"
            % (got_sha[:16], MODEL_WEIGHTS_SHA256[:16]))
    if device == "cuda" and not torch.cuda.is_available():
        raise WorkerRefused("CUDA requested but torch.cuda unavailable")
    import laya
    agent = laya.load(model_dir, device=device)
    if int(agent.cfg.get("max_len", -1)) != CKPT_MAX_LEN:
        raise WorkerRefused("checkpoint max_len %r != %d" % (
            agent.cfg.get("max_len"), CKPT_MAX_LEN))
    if int(agent.cfg.get("head_max_len", -1)) != CKPT_HEAD_MAX_LEN:
        raise WorkerRefused("checkpoint head_max_len %r != %d" % (
            agent.cfg.get("head_max_len"), CKPT_HEAD_MAX_LEN))
    # Operational budget override (verified: RoPE backbone, 8192 max
    # positions). The SDK reads these per predict call; no reload needed.
    if max_len < 512 or max_len > 8192:
        raise WorkerRefused("operational max_len %d out of [512, 8192]" % max_len)
    if head_max_len < 64 or head_max_len >= max_len:
        raise WorkerRefused("operational head_max_len %d invalid" % head_max_len)
    agent.cfg["max_len"] = int(max_len)
    agent.cfg["head_max_len"] = int(head_max_len)
    n_params = sum(p.numel() for p in agent.model.parameters())
    if int(n_params) != EXPECTED_PARAMS:
        raise WorkerRefused("param count %d != %d" % (n_params, EXPECTED_PARAMS))
    # Freeze: inference-only, no grad anywhere (SDK runs under no_grad too).
    agent.model.eval()
    for p in agent.model.parameters():
        p.requires_grad_(False)
    if torch.cuda.is_available() and str(agent.device).startswith("cuda"):
        torch.cuda.synchronize()
        vram = torch.cuda.memory_allocated(agent.device) / 1e9
        vram_total = torch.cuda.get_device_properties(agent.device).total_memory / 1e9
    else:
        vram, vram_total = 0.0, 0.0
    info = {
        "load_s": round(time.perf_counter() - t0, 2),
        "n_parameters": int(n_params),
        "device": str(agent.device),
        "dtype": str(agent.dtype),
        "vram_gb": round(vram, 2),
        "vram_total_gb": round(vram_total, 2),
        "weights_sha256": got_sha[:16],
        "eval": bool(not agent.model.training),
        "no_grad": bool(all(not p.requires_grad
                            for p in agent.model.parameters())),
    }
    return agent, info


def token_telemetry(agent, state_text: str, instructions: str,
                    keys, option_texts) -> dict:
    """Exact token accounting via the SDK's own sequence builder.

    Measures (never guesses): per-option full token lengths, whether the
    SDK head-budget squeeze path engages, per-option kept tokens, state
    truncation, and the real total via build_sequence. Raises
    SchemaMismatch only if the SDK itself cannot place every option marker
    (markers != options): options are never silently dropped.
    """
    from laya.common import build_sequence, serialize_state
    tok = agent.tok
    max_len = int(agent.cfg.get("max_len", 1024))
    head_max = int(agent.cfg.get("head_max_len", 256))
    mask_id = tok.mask_token_id
    ins_clean = instructions.replace(tok.mask_token, " ")
    head_ids = tok("choice question: %s" % ins_clean,
                   add_special_tokens=False)["input_ids"]
    full_lens = []
    capped48 = []
    # NOTE: the SDK renders each option as "KEY: text" (render_options), so
    # the key prefix is part of the measured option tokens.
    for k, t in zip(keys, option_texts):
        rendered = "%s: %s" % (k, t)
        ids = tok((" " + rendered.replace(tok.mask_token, " ")),
                  add_special_tokens=False)["input_ids"][:48]
        full_lens.append(1 + len(ids))
        capped48.append(1 + len(ids))
    opt_total = sum(capped48)
    opt_budget = head_max - opt_total
    per_cap = None
    kept_lens = list(capped48)
    squeeze = False
    if opt_budget < 16:
        squeeze = True
        per_cap = max(4, (head_max - 16) // max(1, len(capped48)))
        kept_lens = [min(o, per_cap) for o in capped48]
        opt_budget = head_max - sum(kept_lens)
    head_kept = min(len(head_ids), max(8, opt_budget))
    head_total = 1 + head_kept + 1 + sum(kept_lens) + 1  # CLS head SEP opts SEP
    st_full = tok(serialize_state(state_text).replace(tok.mask_token, " "),
                  add_special_tokens=False)["input_ids"]
    room = max(0, max_len - head_total - 1)
    state_truncated = len(st_full) > room
    # Ground truth from the SDK builder itself.
    q_internal = {"t": "choice", "ins": instructions,
                  "crit": {k: v for k, v in zip(keys, option_texts)}}
    ids, markers = build_sequence(tok, state_text, q_internal,
                                  max_len, head_max)
    if len(markers) != len(keys):
        raise SchemaMismatch(
            "SDK placed %d/%d option markers; refusing (no silent drop)"
            % (len(markers), len(keys)))
    return {
        "max_len": max_len, "head_max_len": head_max,
        "instruction_tokens_full": len(head_ids),
        "instruction_tokens_kept": head_kept,
        "option_tokens_full": full_lens,
        "option_tokens_kept": kept_lens,
        "option_tokens_total_kept": sum(kept_lens),
        "head_tokens_total": head_total,
        "option_squeeze": squeeze,
        "per_option_cap": per_cap,
        "state_tokens_full": len(st_full),
        "state_tokens_kept": min(len(st_full), room),
        "state_truncated": state_truncated,
        "total_tokens": len(ids),
        "n_options": len(keys),
        "markers_placed": len(markers),
    }


class LayaDecider:
    """Resident frozen agent + per-unit choice service."""

    def __init__(self, agent, load_info: dict, model_dir: str,
                 device: str, request_log):
        self.agent = agent
        self.load_info = load_info
        self.model_dir = model_dir
        self.device = device
        self.request_log = request_log
        self.started_at = time.time()
        self.count = 0
        self._lock = threading.Lock()

    def identity(self) -> dict:
        import torch
        return {
            "model": MODEL_IDENTITY,
            "repo": MODEL_REPO,
            "revision": MODEL_REV,
            "n_parameters": EXPECTED_PARAMS,
            "device": str(self.agent.device),
            "dtype": str(self.agent.dtype),
            "eval": bool(not self.agent.model.training),
            "no_grad": bool(all(not p.requires_grad
                                for p in self.agent.model.parameters())),
            "max_len": int(self.agent.cfg.get("max_len", -1)),
            "head_max_len": int(self.agent.cfg.get("head_max_len", -1)),
            "ckpt_max_len": CKPT_MAX_LEN,
            "ckpt_head_max_len": CKPT_HEAD_MAX_LEN,
            "amp_dtype": self.agent.cfg.get("amp_dtype", "?"),
            "template_version": TEMPLATE_VERSION,
            "template_hash": template_hash(),
            "protocol_version": PROTOCOL_VERSION,
            "request_schema": REQUEST_VERSION,
            "response_schema": RESPONSE_VERSION,
            "group_request_schema": GROUP_REQUEST_VERSION,
            "group_response_schema": GROUP_RESPONSE_VERSION,
            "torch": torch.__version__,
            "cuda_available": bool(torch.cuda.is_available()),
        }

    def decide_request(self, req: dict) -> dict:
        import torch
        t_total = time.perf_counter()
        cands = req["candidates"]
        keys = option_keys(len(cands))
        option_texts = [str(c.get("option_text", "")) for c in cands]
        t_enc = time.perf_counter()
        state_text = build_state_text(req)
        telem = token_telemetry(self.agent, state_text, INSTRUCTIONS,
                                keys, option_texts)
        encode_ms = (time.perf_counter() - t_enc) * 1000.0
        questions = {"action": {
            "type": "choice",
            "instructions": INSTRUCTIONS,
            "criteria": {k: v for k, v in zip(keys, option_texts)},
        }}
        t_fwd = time.perf_counter()
        with self._lock:
            try:
                result = self.agent.predict(state_text, questions)
            except ValueError as e:
                return {"ok": False, "schema_version": RESPONSE_VERSION,
                        "error": {"code": "OPTIONS_EXCEED_BUDGET",
                                  "detail": str(e)[:300]},
                        "identity": self.identity()}
        if str(self.agent.device).startswith("cuda"):
            torch.cuda.synchronize()
        forward_ms = (time.perf_counter() - t_fwd) * 1000.0
        ans = (result.get("answers", {}) or {}).get("action", {})
        sel_key = str(ans.get("choice", ""))
        probs = ans.get("probabilities", {}) or {}
        key_to_cid = {k: str(c.get("candidate_id", "")) for k, c in
                      zip(keys, cands)}
        if sel_key not in key_to_cid:
            return {"ok": False, "schema_version": RESPONSE_VERSION,
                    "error": {"code": "SELECTION_NOT_IN_OPTIONS",
                              "detail": "model returned key %r" % sel_key},
                    "identity": self.identity()}
        options = []
        for i, k in enumerate(keys):
            options.append({
                "key": k,
                "candidate_id": key_to_cid[k],
                "prob": round(float(probs.get(k, 0.0)), 4),
                "tokens_full": telem["option_tokens_full"][i],
                "tokens_kept": telem["option_tokens_kept"][i],
            })
        options.sort(key=lambda o: -o["prob"])
        top5 = [{"candidate_id": o["candidate_id"], "prob": o["prob"]}
                for o in options[:5]]
        total_ms = (time.perf_counter() - t_total) * 1000.0
        return {
            "ok": True,
            "schema_version": RESPONSE_VERSION,
            "selected_key": sel_key,
            "selected_candidate_id": key_to_cid[sel_key],
            "confidence": ans.get("confidence"),
            "action": ans.get("action", {}),
            "options": options,
            "top5": top5,
            "latency_ms": {
                "encode": round(encode_ms, 1),
                "forward": round(forward_ms, 1),
                "total": round(total_ms, 1),
            },
            "token_usage": telem,
            "template_version": TEMPLATE_VERSION,
            "template_hash": template_hash(),
            "request_sha256": canonical_sha256(req)[:16],
            "identity": self.identity(),
        }

    def decide_from_json(self, body: bytes) -> tuple:
        try:
            raw = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as e:
            return ({"ok": False, "schema_version": RESPONSE_VERSION,
                     "error": {"code": "SCHEMA_MISMATCH",
                               "detail": "bad JSON: %s" % e},
                     "identity": self.identity()}, None)
        try:
            req = validate_request(raw)
        except SchemaMismatch as e:
            return ({"ok": False, "schema_version": RESPONSE_VERSION,
                     "error": {"code": "SCHEMA_MISMATCH", "detail": str(e)},
                     "identity": self.identity()}, raw)
        try:
            return (self.decide_request(req), req)
        except SchemaMismatch as e:
            return ({"ok": False, "schema_version": RESPONSE_VERSION,
                     "error": {"code": "SCHEMA_MISMATCH", "detail": str(e)},
                     "identity": self.identity()}, req)

    def decide_group_request(self, req: dict) -> dict:
        import torch
        t_total = time.perf_counter()
        cands = req["candidates"]
        keys = option_keys(len(cands))
        option_texts = [str(c.get("option_text", "")) for c in cands]
        t_enc = time.perf_counter()
        state_text = build_group_state_text(req)
        telem = token_telemetry(self.agent, state_text, GROUP_INSTRUCTIONS,
                                keys, option_texts)
        encode_ms = (time.perf_counter() - t_enc) * 1000.0
        questions = {"action": {
            "type": "choice",
            "instructions": GROUP_INSTRUCTIONS,
            "criteria": {k: v for k, v in zip(keys, option_texts)},
        }}
        t_fwd = time.perf_counter()
        with self._lock:
            try:
                result = self.agent.predict(state_text, questions)
            except ValueError as e:
                return {"ok": False, "schema_version": GROUP_RESPONSE_VERSION,
                        "error": {"code": "OPTIONS_EXCEED_BUDGET",
                                  "detail": str(e)[:300]},
                        "identity": self.identity()}
        if str(self.agent.device).startswith("cuda"):
            torch.cuda.synchronize()
        forward_ms = (time.perf_counter() - t_fwd) * 1000.0
        ans = (result.get("answers", {}) or {}).get("action", {})
        sel_key = str(ans.get("choice", ""))
        probs = ans.get("probabilities", {}) or {}
        key_to_cid = {k: str(c.get("candidate_id", "")) for k, c in
                      zip(keys, cands)}
        if sel_key not in key_to_cid:
            return {"ok": False, "schema_version": GROUP_RESPONSE_VERSION,
                    "error": {"code": "SELECTION_NOT_IN_OPTIONS",
                              "detail": "model returned key %r" % sel_key},
                    "identity": self.identity()}
        options = []
        for i, k in enumerate(keys):
            options.append({
                "key": k,
                "candidate_id": key_to_cid[k],
                "prob": round(float(probs.get(k, 0.0)), 4),
                "tokens_full": telem["option_tokens_full"][i],
                "tokens_kept": telem["option_tokens_kept"][i],
            })
        options.sort(key=lambda o: -o["prob"])
        top5 = [{"candidate_id": o["candidate_id"], "prob": o["prob"]}
                for o in options[:5]]
        total_ms = (time.perf_counter() - t_total) * 1000.0
        return {
            "ok": True,
            "schema_version": GROUP_RESPONSE_VERSION,
            "selected_key": sel_key,
            "selected_candidate_id": key_to_cid[sel_key],
            "confidence": ans.get("confidence"),
            "action": ans.get("action", {}),
            "options": options,
            "top5": top5,
            "latency_ms": {
                "encode": round(encode_ms, 1),
                "forward": round(forward_ms, 1),
                "total": round(total_ms, 1),
            },
            "token_usage": telem,
            "template_version": TEMPLATE_VERSION,
            "template_hash": template_hash(),
            "request_sha256": canonical_sha256(req)[:16],
            "identity": self.identity(),
        }

    def decide_group_from_json(self, body: bytes) -> tuple:
        try:
            raw = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as e:
            return ({"ok": False, "schema_version": GROUP_RESPONSE_VERSION,
                    "error": {"code": "SCHEMA_MISMATCH",
                              "detail": "bad JSON: %s" % e},
                    "identity": self.identity()}, None)
        try:
            req = validate_group_request(raw)
        except SchemaMismatch as e:
            return ({"ok": False, "schema_version": GROUP_RESPONSE_VERSION,
                    "error": {"code": "SCHEMA_MISMATCH", "detail": str(e)},
                    "identity": self.identity()}, raw)
        try:
            return (self.decide_group_request(req), req)
        except SchemaMismatch as e:
            return ({"ok": False, "schema_version": GROUP_RESPONSE_VERSION,
                    "error": {"code": "SCHEMA_MISMATCH", "detail": str(e)},
                    "identity": self.identity()}, req)

    def log_exchange(self, req, resp: dict) -> None:
        if not self.request_log:
            return
        try:
            with open(self.request_log, "a", encoding="utf-8") as f:
                f.write(json.dumps({
                    "t": time.strftime("%Y-%m-%dT%H:%M:%S"),
                    "unit": (req or {}).get("unit_id", "?") if req else "?",
                    "n": len((req or {}).get("candidates", [])) if req else 0,
                    "selected": resp.get("selected_candidate_id", "?"),
                    "confidence": resp.get("confidence"),
                    "latency_ms": resp.get("latency_ms", {}),
                    "token_usage": resp.get("token_usage", {}),
                    "top5": resp.get("top5", []),
                    "ok": bool(resp.get("ok", False)),
                    "error": resp.get("error", {}),
                }, ensure_ascii=False) + "\n")
        except OSError:
            pass
        # Full-payload evidence log (opt-in via env; proves General/mission
        # context reaches the model in live runs).
        if os.environ.get("LAYA_LOG_FULL", "") == "1":
            try:
                full_path = os.path.join(
                    os.path.dirname(os.path.abspath(self.request_log)),
                    "requests_full.jsonl")
                with open(full_path, "a", encoding="utf-8") as f:
                    f.write(json.dumps({"req": req, "resp": resp},
                                       ensure_ascii=False) + "\n")
            except OSError:
                pass


def make_handler(decider: LayaDecider, shutdown_token=None,
                 parent_pid=None, log_file=None):
    class Handler(BaseHTTPRequestHandler):
        server_version = "LayaWorker/1.0"

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
            with decider._lock:
                count = decider.count
            self._send({"ok": True, "service": "laya-worker",
                        "status": "READY",
                        "protocol_version": PROTOCOL_VERSION,
                        "pid": os.getpid(),
                        "parent_pid": parent_pid,
                        "identity": decider.identity(),
                        "load": decider.load_info,
                        "uptime_s": time.time() - decider.started_at,
                        "requests": count})

        def do_POST(self) -> None:  # noqa: N802
            path = self.path.split("?")[0]
            if path == "/shutdown":
                self._handle_shutdown()
                return
            is_group = (path == "/decide_group")
            if path != "/decide" and not is_group:
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
                            "identity": decider.identity()})
                return
            body = self.rfile.read(length)
            if is_group:
                resp, req = decider.decide_group_from_json(body)
            else:
                resp, req = decider.decide_from_json(body)
            with decider._lock:
                decider.count += 1
            decider.log_exchange(req, resp)
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
            sys.stderr.write("[laya-worker] owned shutdown requested\n")
            threading.Thread(target=self.server.shutdown,
                             name="owned-shutdown", daemon=True).start()

        def log_message(self, fmt: str, *args) -> None:
            try:
                sys.stderr.write("[laya-worker] " + fmt % args + "\n")
            except (AttributeError, OSError, ValueError):
                pass
            if log_file:
                try:
                    with open(log_file, "a", encoding="utf-8") as f:
                        f.write("[laya-worker] " + fmt % args + "\n")
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
                "[laya-worker] parent pid %d gone; exiting\n" % parent_pid)
            server.shutdown()
            return


def _warmup(decider: LayaDecider, log_file=None) -> None:
    """One tiny forward so READY means kernels are autotuned (inference-only)."""
    import torch
    t0 = time.perf_counter()
    result = decider.agent.predict(
        "RED PER-UNIT DECISION\nTURN 1 OBJ warmup STATUS ongoing",
        {"action": {"type": "choice",
                    "instructions": INSTRUCTIONS,
                    "criteria": {"A": "MOVE warmup", "B": "WAIT warmup",
                                 "C": "ATTACK warmup", "D": "REST warmup"}}})
    assert result["answers"]["action"]["choice"] in ("A", "B", "C", "D")
    if torch.cuda.is_available():
        torch.cuda.synchronize()
    decider.load_info["warmup_s"] = round(time.perf_counter() - t0, 2)
    _emit("[laya-worker] warmup done in %.1fs" % (time.perf_counter() - t0),
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


def serve(host: str, port: int, model_dir: str, device: str,
          request_log, parent_pid=None, shutdown_token=None,
          log_file=None, max_len: int = OP_MAX_LEN,
          head_max_len: int = OP_HEAD_MAX_LEN) -> None:
    agent, info = load_agent(model_dir, device, max_len, head_max_len)
    if request_log:
        try:
            os.makedirs(os.path.dirname(os.path.abspath(request_log)),
                        exist_ok=True)
        except OSError:
            pass
    decider = LayaDecider(agent, info, model_dir, device, request_log)
    _warmup(decider, log_file)
    server = ThreadingHTTPServer(
        (host, port), make_handler(decider, shutdown_token, parent_pid,
                                   log_file))
    server.daemon_threads = True
    bound_port = server.server_address[1]
    _emit("[laya-worker] READY model=%s rev=%s params=%d device=%s "
          "dtype=%s load_s=%.1f vram_gb=%.2f url=http://%s:%d pid=%d "
          "parent_pid=%s template=%s max_len=%d head_max_len=%d" % (
              MODEL_IDENTITY, MODEL_REV, info["n_parameters"], device,
              info["dtype"], info["load_s"], info["vram_gb"], host,
              bound_port, os.getpid(), parent_pid, TEMPLATE_VERSION,
              int(agent.cfg.get("max_len", -1)),
              int(agent.cfg.get("head_max_len", -1))), log_file)
    if parent_pid:
        threading.Thread(target=_watch_parent, args=(server, parent_pid),
                         name="parent-watch", daemon=True).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    _emit("[laya-worker] stopped", log_file)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Laya live inference worker (RED Hands decider)")
    ap.add_argument("--host", default=DEFAULT_HOST)
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--model-dir", default=DEFAULT_MODEL_DIR)
    ap.add_argument("--device", default="cuda")
    ap.add_argument("--max-len", type=int, default=OP_MAX_LEN)
    ap.add_argument("--head-max-len", type=int, default=OP_HEAD_MAX_LEN)
    ap.add_argument("--request-log", default=DEFAULT_REQUEST_LOG)
    ap.add_argument("--no-request-log", action="store_true")
    ap.add_argument("--parent-pid", type=int, default=0)
    ap.add_argument("--shutdown-token", default="")
    ap.add_argument("--log-file", default="")
    ap.add_argument("--smoke", action="store_true",
                    help="load model, run one synthetic /decide, print, exit")
    args = ap.parse_args(argv)
    log_file = args.log_file.strip() or None
    if args.smoke:
        return _smoke(args, log_file)
    try:
        serve(args.host, args.port, args.model_dir, args.device,
              None if args.no_request_log else args.request_log,
              parent_pid=args.parent_pid or None,
              shutdown_token=args.shutdown_token.strip() or None,
              log_file=log_file, max_len=args.max_len,
              head_max_len=args.head_max_len)
    except WorkerRefused as e:
        _emit("[laya-worker] REFUSED: %s" % e, log_file)
        return 2
    except OSError as e:
        _emit("[laya-worker] BIND FAILED: %s" % e, log_file)
        return 3
    return 0


def _smoke(args, log_file) -> int:
    """Load model once, decide one synthetic RED unit request, print, exit."""
    try:
        agent, info = load_agent(args.model_dir, args.device, args.max_len,
                                 args.head_max_len)
    except WorkerRefused as e:
        _emit("[laya-worker] SMOKE REFUSED: %s" % e, log_file)
        return 2
    decider = LayaDecider(agent, info, args.model_dir, args.device, None)
    req = {
        "schema_version": REQUEST_VERSION,
        "battle_id": "smoke", "turn": 1, "side": "red",
        "unit_id": "R_INF_1",
        "authorized_state": {
            "unit": {"id": "R_INF_1", "class": "infantry", "q": 1, "r": 0,
                     "soldier_count": 400, "max_count": 477, "morale": 95.0,
                     "remaining_mp": 2.0, "base_mp": 2.0},
            "unit_mission": {"mission_id": "M01", "task": "FIX",
                             "area": "CENTER", "assigned_units": ["R_INF_1"],
                             "objective": {"kind": "REGION",
                                           "region": "CENTER"}},
            "knowledge": {"ledger": {
                "own_forces": [
                    {"id": "R_HQ_1", "class": "hq", "q": 5, "r": 0,
                     "soldier_count": 200, "max_count": 200, "morale": 100.0,
                     "remaining_mp": 2.0, "base_mp": 2.0}],
                "observed_blue_forces": [
                    {"id": "B_HQ_1", "class": "hq", "q": 0, "r": 0,
                     "troop_text": "weak (band 1)"}],
                "last_known_blue_contacts": [],
                "strongholds": [],
            }},
            "mission": {"type": "destroy_all_red",
                        "objective": "Destroy the BLUE HQ.",
                        "status": "ongoing"},
            "recent_events": [],
        },
        "commander_context": {
            "plan_source": "local_fallback", "plan_version": 1,
            "concept": {"objective": "Smoke concept.", "intent": "Smoke.",
                        "main_effort": "CENTER"},
            "doctrine": {"aggression": "STANDARD"},
            "missions": [{"mission_id": "M01", "task": "FIX", "area": "CENTER",
                          "assigned_units": ["R_INF_1"],
                          "objective": {"kind": "REGION",
                                        "region": "CENTER"}}],
            "unit_mission": {"R_INF_1": "M01"},
        },
        "runtime_rules": [
            "PRIMARY: WIN THE BATTLE. Destroy the enemy (BLUE) HQ to win immediately.",
            "TERMINAL: OWN (RED) HQ DESTROYED = IMMEDIATE DEFEAT.",
        ],
        "candidates": [
            {"candidate_id": "MOVE|R_INF_1|2,0", "unit_id": "R_INF_1",
             "action_type": "MOVE",
             "option_text": "MOVE to (2,0) dir=EAST mission_target 6->5 terrain=PLAIN"},
            {"candidate_id": "ATTACK|R_INF_1|B_HQ_1", "unit_id": "R_INF_1",
             "action_type": "ATTACK",
             "option_text": "ATTACK B_HQ_1 hq (0,0) weak"},
            {"candidate_id": "WAIT|R_INF_1", "unit_id": "R_INF_1",
             "action_type": "WAIT", "option_text": "WAIT hold position"},
        ],
    }
    resp = decider.decide_request(validate_request(req))
    _emit("[laya-worker] SMOKE selected=%s conf=%s lat=%s tok=%s" % (
        resp.get("selected_candidate_id"), resp.get("confidence"),
        resp.get("latency_ms"), resp.get("token_usage")), log_file)
    if not resp.get("ok"):
        _emit("[laya-worker] SMOKE FAILED: %s" % resp.get("error"), log_file)
        return 1
    _emit("[laya-worker] SMOKE OK load=%s" % info, log_file)
    return 0


if __name__ == "__main__":
    sys.exit(main())
