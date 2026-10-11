"""CSFT5 Brain server — loopback OpenAI-compatible endpoint for the REAL game.

  <RL venv python> -m tools.contract_sft.brain_server [--port 8096]

Serves the selected Contract-SFT model to the unmodified game General path
(cloud2 adapter "Ollama (local)" preset -> http://127.0.0.1:8096/v1/chat/completions).
The game keeps the production system prompt, packet builder, parser and
validator; this process only generates text.

Fidelity to the strict CSFT evaluations (tools/contract_sft/generate.py):
  Qwen3-8B @ pinned revision, NF4 double-quant BF16 compute, SDPA,
  CSFT5 LoRA adapter, NON-THINKING chat template, sampling LOCKED to
  temp 0.7 / top_p 0.8 / top_k 20 / rep 1.0 / max_new_tokens 1280,
  one generation per request, raw decoded text returned (no strip, no
  repair, no retry, no fallback, no constrained decoding). Requested
  temperature / max_tokens / response_format are logged, not applied.

Identity guard: refuses to start unless the adapter sha256 equals the
recorded CSFT5 hash and differs from CSFT6. Holds the exclusive GPU lock
(D:\\StrategyAI\\locks\\training_marathon_v1.lock) for its whole life, so no
RL/training can share the GPU. Memory guard: device <= 20.5 GiB, host
available >= 16 GiB, checked after load and after every generation.

Telemetry: artifacts/contract_sft_v1/human_benchmark/<session>/calls.jsonl,
one row per Brain call (raw output + observational flags). The production
PASS/FAIL verdict is logged by the game (VICTORY_ATTEMPT lines) and joined
by tools/contract_sft/human_benchmark_report.py. Nothing here alters output.
"""
from __future__ import annotations

import argparse
import json
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import sys

if __package__ in (None, ""):  # launched by path (Godot-owned worker): make the project root importable
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.contract_sft import gpu_common as G  # noqa: E402

CSFT5_DIR = G.ARTIFACT_ROOT / "candidate_CSFT5"
CSFT5_SHA = "d82e5369be7bb2155c7eda537a79316734743061458f4254977cc6053e92b4ae"
CSFT6_SHA = "546d2b1e9a88ddd223e60b27f393530b15a6163163838018741f983c7d5a4635"
MODEL_NAME = "csft5"
# Adapters this server may serve (sha256 of adapter_model.safetensors -> label). CSFT6 stays forbidden.
ALLOWED_ADAPTERS = {CSFT5_SHA: "CSFT5",
                    "32029f7acf0bdac257e38a4a72d550697c15cd17184b00791eeb322b7e65205b": "S0B"}
UID = re.compile(r"\b([RB])_([A-Z]{2,4})_(\d+)\b")
EXAMPLE_TAGS = {"CAV_1", "CAV_2", "INF_1", "INF_2"}
PROBE_TEXT = "Reply with OK."


def episode_provenance(headers):
    """Episode launch record sent by Godot (X-Episode-*); absent without an episode."""
    from urllib.parse import unquote
    eid = headers.get("X-Episode-Id")
    if not eid:
        return {}
    return {"episode_id": eid, "episode_spec_path": unquote(headers.get("X-Episode-Spec-Path", "")) or None}


def packet_of(messages):
    for m in messages:
        if isinstance(m, dict) and m.get("role") == "user":
            try:
                return json.loads(m.get("content", ""))
            except (ValueError, TypeError):
                return None
    return None


def find_units(pk, key):
    """friendly_units / known_enemy_units wherever the packet carries them."""
    out = []

    def walk(o):
        if isinstance(o, dict):
            for k, v in o.items():
                if k == key and isinstance(v, list):
                    out.extend(u for u in v if isinstance(u, dict))
                else:
                    walk(v)
        elif isinstance(o, list):
            for x in o:
                walk(x)
    walk(pk)
    return out


def observe(text, pk):
    """Observational flags only (the verdict comes from the game)."""
    from tools.contract_sft import schema_strict as SS
    from tools.contract_sft.repair import AREAS, TASKS
    side = str((pk or {}).get("acting_side", "")).upper()[:1]
    roster = {u.get("unit_id") for u in find_units(pk, "friendly_units")}
    visible = {u.get("unit_id") for u in find_units(pk, "known_enemy_units")
               if u.get("contact_state", "current_visible") == "current_visible"}
    ids = sorted({m.group(0) for m in UID.finditer(text)})
    doc, direct = None, False
    try:
        doc = json.loads(text.strip())
        direct = isinstance(doc, dict)
    except ValueError:
        pass
    own = [u for u in ids if u[0] == side]
    unknown = [u for u in own if u not in roster] if roster else []
    enemy_prefix = "B" if side == "R" else "R"
    # wrong-side = an enemy-prefixed id placed in a FRIENDLY slot (units /
    # reserve / groups / roles / support) -- the plan tries to command it.
    friendly_slot_ids = set()
    if direct:
        for p in doc.get("phases") or []:
            if not isinstance(p, dict):
                continue
            friendly_slot_ids.update(str(x) for x in (p.get("reserve") or []) if isinstance(x, str))
            for g in (p.get("groups") or {}).values() if isinstance(p.get("groups"), dict) else []:
                friendly_slot_ids.update(str(x) for x in g if isinstance(x, str)) if isinstance(g, list) else None
            for m in p.get("missions") or []:
                if not isinstance(m, dict):
                    continue
                friendly_slot_ids.update(str(x) for x in (m.get("units") or []) if isinstance(x, str))
                if isinstance(m.get("roles"), dict):
                    friendly_slot_ids.update(m["roles"].keys())
                for s in m.get("support") or []:
                    if isinstance(s, dict):
                        friendly_slot_ids.update(str(s.get(k, "")) for k in ("from", "to"))
    else:  # unparseable: best-effort scan of "units"/"reserve" arrays
        for arr in re.findall(r'"(?:units|reserve)"\s*:\s*\[([^\]]*)\]', text):
            friendly_slot_ids.update(m.group(0) for m in UID.finditer(arr))
    wrong = sorted(u for u in friendly_slot_ids if UID.fullmatch(u) and u[0] == enemy_prefix)
    hidden = [u for u in ids if u[0] == enemy_prefix and u not in visible and u not in wrong]
    invented = []
    if direct and "decision" not in doc:  # plan schema checks apply to plans, not review decisions
        invented = [c for c in SS.audit(doc) if c.startswith(("BAD_CONDITION", "UNKNOWN_KEY"))]
        for p in doc.get("phases") or []:
            for m in (p.get("missions") or []) if isinstance(p, dict) else []:
                if isinstance(m, dict):
                    t = str(m.get("task", "")).upper()
                    if t and t not in TASKS:
                        invented.append("UNKNOWN_TASK:" + t)
                    a = str(m.get("area", "ANY")).upper()
                    if a and a not in AREAS:
                        invented.append("UNKNOWN_AREA:" + a)
    return {"units_referenced": ids, "json_exactly_one_object": direct,
            "unknown_friendly_ids": unknown,
            "system_example_id_copies": [u for u in unknown if u[2:] in EXAMPLE_TAGS],
            "wrong_side_ids": wrong,
            "hidden_enemy_ids": [u for u in hidden if not u.endswith("_HQ_1")],
            "hidden_enemy_hq_ids": [u for u in hidden if u.endswith("_HQ_1")],
            "invented_enum_task_trigger": invented,
            "phases_declared": [str(p.get("id", "")) for p in (doc or {}).get("phases", []) if isinstance(p, dict)]
            if direct else [],
            "decision": (doc or {}).get("decision") if direct else None}


class Brain:
    def __init__(self, adapter: Path, telemetry: Path, log):
        self.adapter = adapter
        self.telemetry = telemetry
        self.log = log
        self.lock = threading.Lock()
        self.seq = 0
        self.guard = G.Guard(log)

    def load(self):
        import torch
        from peft import PeftModel
        sha = G.file_sha256(str(self.adapter / "adapter_model.safetensors"))
        if sha not in ALLOWED_ADAPTERS or sha == CSFT6_SHA:
            raise SystemExit(f"adapter identity check failed: {sha} (allowed {sorted(ALLOWED_ADAPTERS.values())})")
        self.adapter_sha = sha
        torch.cuda.empty_cache()
        self.guard.check("init")
        self.tok = G.load_tokenizer()
        base = G.load_base()
        self.model = PeftModel.from_pretrained(base, str(self.adapter))
        self.model.eval()
        self.model.config.use_cache = True
        self.guard.check("loaded")
        self.identity = {"model": MODEL_NAME, "label": ALLOWED_ADAPTERS[sha], "adapter_dir": str(self.adapter),
                         "adapter_sha256": sha, "csft6_sha256_forbidden": CSFT6_SHA,
                         "adapter_is_csft6": sha == CSFT6_SHA,
                         "base": G.MODEL_DIR, "revision": G.REVISION, "quantization": "NF4 double-quant, BF16 compute",
                         "chat_template": "non-thinking (enable_thinking=False)",
                         "sampling_locked": G.SAMPLING, "repair": False, "retry": False, "fallback": False,
                         "constrained_decoding": False, "loaded_at": time.strftime("%Y-%m-%dT%H:%M:%S")}
        (self.telemetry / "SERVER_IDENTITY.json").write_text(json.dumps(self.identity, indent=1), encoding="utf-8")
        self.log(f"[BRAIN] ready {self.identity}")

    def generate(self, messages):
        import torch
        with self.lock:
            text = G.render_prompt(self.tok, messages)
            enc = self.tok(text, add_special_tokens=False, return_tensors="pt").to("cuda:0")
            seed = int(time.time() * 1000) % 2**31
            torch.manual_seed(seed)
            torch.cuda.manual_seed_all(seed)
            t0 = time.time()
            with torch.inference_mode():
                out = self.model.generate(**enc, max_new_tokens=G.SAMPLING["max_new_tokens"], do_sample=True,
                                          temperature=G.SAMPLING["temperature"], top_p=G.SAMPLING["top_p"],
                                          top_k=G.SAMPLING["top_k"],
                                          repetition_penalty=G.SAMPLING["repetition_penalty"],
                                          pad_token_id=self.tok.pad_token_id, eos_token_id=self.tok.eos_token_id)
            dt = time.time() - t0
            ids = out[0][enc["input_ids"].shape[1]:].tolist()
            ended = bool(ids) and ids[-1] == self.tok.eos_token_id
            raw = self.tok.decode(ids, skip_special_tokens=True)
            self.guard.check(f"call{self.seq + 1}")
            return raw, {"seed": seed, "latency_s": round(dt, 2), "prompt_tokens": int(enc["input_ids"].shape[1]),
                         "gen_tokens": len(ids), "hit_token_cap": (not ended) and len(ids) >= G.SAMPLING["max_new_tokens"]}

    def record(self, row):
        with open(self.telemetry / "calls.jsonl", "a", encoding="utf-8") as f:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")


def make_handler(brain: Brain):
    class H(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            pass

        def _json(self, code, obj):
            body = json.dumps(obj).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path in ("/health", "/identity"):
                self._json(200, {"ok": True, **brain.identity, "calls": brain.seq,
                                 "memory": brain.guard.summary()})
            elif self.path in ("/v1/models", "/models"):
                self._json(200, {"object": "list", "data": [{"id": MODEL_NAME, "object": "model"}]})
            else:
                self._json(404, {"error": "not found"})

        def do_POST(self):
            if self.path == "/admin/shutdown":  # loopback-only graceful stop (releases the GPU lock)
                self._json(200, {"ok": True, "stopping": True})
                threading.Thread(target=brain.server.shutdown, daemon=True).start()
                return
            if not self.path.endswith("/chat/completions"):
                self._json(404, {"error": "not found"})
                return
            try:
                req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
            except ValueError as e:
                self._json(400, {"error": str(e)})
                return
            messages = req.get("messages") or []
            last_user = next((str(m.get("content", "")) for m in reversed(messages)
                              if isinstance(m, dict) and m.get("role") == "user"), "")
            if last_user.strip() == PROBE_TEXT:  # connection test, not a Brain call
                brain.record({"kind": "CONNECTION_PROBE", "at": time.strftime("%Y-%m-%dT%H:%M:%S")})
                self._json(200, {"id": "csft5-probe", "object": "chat.completion", "model": MODEL_NAME,
                                 "choices": [{"index": 0, "message": {"role": "assistant", "content": "OK"},
                                              "finish_reason": "stop"}],
                                 "usage": {"prompt_tokens": 0, "completion_tokens": 1, "total_tokens": 1}})
                return
            pk = packet_of(messages)
            raw, gen = brain.generate(messages)
            brain.seq += 1
            row = {"kind": "BRAIN_CALL", "call_seq": brain.seq, "at": time.strftime("%Y-%m-%dT%H:%M:%S"),
                   "request": (pk or {}).get("request", "UNKNOWN"), "turn": (pk or {}).get("turn"),
                   "side": (pk or {}).get("acting_side"), "snapshot_id": (pk or {}).get("snapshot_id"),
                   "review_trigger": (pk or {}).get("review_trigger"),
                   "requested": {k: req.get(k) for k in ("model", "temperature", "max_tokens", "response_format",
                                                         "top_p", "stream")},
                   "applied_sampling": G.SAMPLING, "adapter_sha256": brain.adapter_sha, **gen,
                   "raw_output": raw, "raw_chars": len(raw), **observe(raw, pk),
                   **episode_provenance(self.headers)}
            brain.record(row)
            brain.log(f"[BRAIN] call {brain.seq} {row['request']} turn={row['turn']} side={row['side']} "
                      f"{gen['latency_s']}s tokens={gen['gen_tokens']} json1={row['json_exactly_one_object']} "
                      f"unknown={row['unknown_friendly_ids']} example={row['system_example_id_copies']}")
            self._json(200, {"id": f"csft5-{brain.seq}", "object": "chat.completion", "model": MODEL_NAME,
                             "choices": [{"index": 0, "message": {"role": "assistant", "content": raw},
                                          "finish_reason": "length" if gen["hit_token_cap"] else "stop"}],
                             "usage": {"prompt_tokens": gen["prompt_tokens"], "completion_tokens": gen["gen_tokens"],
                                       "total_tokens": gen["prompt_tokens"] + gen["gen_tokens"]}})
    return H


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8096)
    ap.add_argument("--adapter", default=str(CSFT5_DIR))
    ap.add_argument("--session", default=time.strftime("session_%Y%m%d_%H%M%S"))
    a = ap.parse_args()
    tel = G.ARTIFACT_ROOT / "human_benchmark" / a.session
    tel.mkdir(parents=True, exist_ok=True)
    log = G.make_logger(tel / "server.log")
    brain = Brain(Path(a.adapter), tel, log)
    with G.gpu_lock("csft5_brain_server", "BRAIN_SERVE"):
        brain.load()
        srv = ThreadingHTTPServer(("127.0.0.1", a.port), make_handler(brain))
        brain.server = srv
        log(f"[BRAIN] listening http://127.0.0.1:{a.port}/v1/chat/completions telemetry={tel}")
        try:
            srv.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            srv.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
