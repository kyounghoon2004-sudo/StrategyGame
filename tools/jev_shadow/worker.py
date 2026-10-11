"""Persistent JEV shadow inference worker (localhost HTTP, SHADOW ONLY).

Loads jev-policy-v0.6.0-mission1 (seed205) ONCE, verifies its SHA-256, enters
eval mode with gradients disabled, and serves single-decision inference until
stopped. No gameplay state exists in this process; it only maps facts to a
six-slot proposal.
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

import torch

# Hidden spawn (pythonw.exe / no console) may leave stdio as None; never let
# a log write crash the worker or a request handler.
STDIO_WAS_NONE = (sys.stdout is None, sys.stderr is None)
if sys.stdout is None:  # pragma: no cover - launcher environment only
    sys.stdout = open(os.devnull, "w")
if sys.stderr is None:  # pragma: no cover - launcher environment only
    sys.stderr = open(os.devnull, "w")

HERE = os.path.dirname(os.path.abspath(__file__))
STRATEGY_ROOT = os.path.abspath(os.path.join(HERE, os.pardir, os.pardir))
if STRATEGY_ROOT not in sys.path:
    sys.path.insert(0, STRATEGY_ROOT)

from python_jev.model import JevPolicyV0  # noqa: E402
from python_jev.constants import LEARNED_CLASSES  # noqa: E402
from python_jev.training.checkpoint import load_checkpoint  # noqa: E402
from tools.jev_shadow import (  # noqa: E402
    CHECKPOINT_SHA256,
    MODEL_IDENTITY,
    SHADOW_ACTION_SCHEMA,
    SHADOW_CONTRACT_VERSION,
    SHADOW_MISSIONMAP_VERSION,
    SHADOW_OBSERVATION_SCHEMA,
    SHADOW_PROTOCOL_VERSION,
    SHADOW_REQUEST_VERSION,
    SHADOW_RESPONSE_VERSION,
    SHADOW_SLOTMAP_VERSION,
)
from tools.jev_shadow.missionmap import MissionMap, MissionMapError  # noqa: E402
from tools.jev_shadow.project import ShadowProjector  # noqa: E402
from tools.jev_shadow.schemas import SchemaMismatch, validate_request  # noqa: E402
from tools.jev_shadow.slotmap import SlotMap, SlotMapError  # noqa: E402

DEFAULT_CHECKPOINT = os.path.join(
    STRATEGY_ROOT, "artifacts", "jev_mission_train_v1", "checkpoints",
    "seed205.pt")
DEFAULT_PORT = 11439
DEFAULT_HOST = "127.0.0.1"
MAX_BODY_BYTES = 8 << 20

MODEL_CONFIG = {
    "token_embed_dim": 128,
    "context_embed_dim": 128,
    "hidden_dim": 256,
    "fusion_latent_dim": 512,
}


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def canonical_sha256(obj: dict) -> str:
    blob = json.dumps(obj, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(blob).hexdigest()


class WorkerRefused(RuntimeError):
    """Startup refusal (missing file, hash mismatch, strict-load failure)."""


def load_model(checkpoint_path: str, expect_sha256: str):
    if not os.path.isfile(checkpoint_path):
        raise WorkerRefused(f"checkpoint not found: {checkpoint_path}")
    digest = sha256_file(checkpoint_path)
    if digest.lower() != expect_sha256.lower():
        raise WorkerRefused(
            f"checkpoint SHA-256 mismatch: got {digest}, want {expect_sha256}")
    model = JevPolicyV0(**MODEL_CONFIG)
    meta = load_checkpoint(checkpoint_path, model)  # strict=True inside
    model.eval()
    for p in model.parameters():
        p.requires_grad_(False)
    n_params = sum(p.numel() for p in model.parameters())
    return model, meta, digest.lower(), n_params


class ShadowWorker:
    """In-process inference API (shared by the HTTP handler and tests)."""

    def __init__(self, model, checkpoint_sha256: str, n_parameters: int,
                 checkpoint_path: str, request_log: str | None = None) -> None:
        self.model = model
        self.checkpoint_sha256 = checkpoint_sha256
        self.n_parameters = n_parameters
        self.checkpoint_path = checkpoint_path
        self.slot_map = SlotMap()
        self.mission_map = MissionMap()
        self.projector = ShadowProjector(self.slot_map, self.mission_map)
        self.request_log = request_log
        self.started_at = time.time()
        self.count = 0
        self._lock = threading.Lock()

    def identity(self) -> dict:
        return {
            "model_version": MODEL_IDENTITY,
            "checkpoint_sha256": self.checkpoint_sha256,
            "n_parameters": self.n_parameters,
            "contract": SHADOW_CONTRACT_VERSION,
            "protocol_version": SHADOW_PROTOCOL_VERSION,
            "request_schema": SHADOW_REQUEST_VERSION,
            "response_schema": SHADOW_RESPONSE_VERSION,
            "slot_map": SHADOW_SLOTMAP_VERSION,
            "mission_map": SHADOW_MISSIONMAP_VERSION,
            "observation_schema": SHADOW_OBSERVATION_SCHEMA,
            "action_schema": SHADOW_ACTION_SCHEMA,
            "device": "cpu",
            "eval_mode": True,
            "gradients": False,
            "pid": os.getpid(),
        }

    def infer(self, req: dict) -> dict:
        t0 = time.perf_counter()
        unit_class = str(req.get("unit_class", "")).strip().upper()
        if unit_class not in LEARNED_CLASSES:
            latency_ms = (time.perf_counter() - t0) * 1000.0
            return {
                "ok": True,
                "schema_version": SHADOW_RESPONSE_VERSION,
                "request_id": str(req.get("request_id", "")),
                "eligible": False,
                "reason": "NOT_JEV_ELIGIBLE",
                "unit_class": unit_class,
                "latency_ms": {"total": latency_ms, "forward": 0.0},
                "identity": self.identity(),
            }
        proj = self.projector.project(req)
        obs = self.projector.to_tensors(proj, req)
        t1 = time.perf_counter()
        with torch.no_grad():
            out = self.model(obs)
        t2 = time.perf_counter()
        raw = out.raw_logits[0].detach().cpu().tolist()
        probs = out.probabilities[0].detach().cpu().tolist()
        masked = out.masked_logits[0].detach().cpu().tolist()
        selected = int(out.selected_slot[0].item())
        all_illegal = bool(out.all_illegal[0].item())
        legal = [bool(v) for v in proj.legal_mask]
        if not all_illegal and not legal[selected]:
            raise RuntimeError(
                f"internal: selected slot {selected} is masked illegal")
        table = self.slot_map.jev_table(unit_class)
        godot_legal = [not bool(o["masked"]) for o in req["godot_options"]]
        base_opt = str(req["baseline"]["option_id"])
        resp = {
            "ok": True,
            "schema_version": SHADOW_RESPONSE_VERSION,
            "request_id": str(req["request_id"]),
            "eligible": True,
            "mapping": {
                **proj.mapping,
                "slot_map_version": SHADOW_SLOTMAP_VERSION,
                "baseline_jev_slot": self.slot_map.baseline_to_jev(unit_class, base_opt),
            },
            "legal_mask": legal,
            "godot_legal": godot_legal,
            "logits": [float(v) for v in raw],
            "masked_logits": [None if v != v or v in (float("inf"), float("-inf"))
                              else float(v) for v in masked],
            "probabilities": [float(v) for v in probs],
            "selected_slot": selected,
            "selected_skill": None if all_illegal else table[selected],
            "all_illegal": all_illegal,
            "status": "ALL_ILLEGAL" if all_illegal else "OK",
            "latency_ms": {
                "total": (t2 - t0) * 1000.0,
                "forward": (t2 - t1) * 1000.0,
            },
            "identity": self.identity(),
            "request_sha256": canonical_sha256(req),
        }
        return resp

    def infer_from_json(self, body: bytes) -> tuple[dict, dict | None]:
        """Parse + validate + infer. Returns (response, validated_request)."""
        try:
            raw = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as e:
            return ({"ok": False, "schema_version": SHADOW_RESPONSE_VERSION,
                     "error": {"code": "SCHEMA_MISMATCH",
                               "detail": f"body is not valid JSON: {e}"},
                     "identity": self.identity()}, None)
        try:
            req = validate_request(raw)
        except SchemaMismatch as e:
            return ({"ok": False, "schema_version": SHADOW_RESPONSE_VERSION,
                     "request_id": str(raw.get("request_id", "")) if isinstance(raw, dict) else "",
                     "error": {"code": "SCHEMA_MISMATCH", "detail": str(e)},
                     "identity": self.identity()}, None)
        try:
            resp = self.infer(req)
        except (MissionMapError, SlotMapError, SchemaMismatch) as e:
            return ({"ok": False, "schema_version": SHADOW_RESPONSE_VERSION,
                     "request_id": str(req.get("request_id", "")),
                     "error": {"code": "SCHEMA_MISMATCH", "detail": str(e)},
                     "identity": self.identity()}, req)
        except Exception as e:  # noqa: BLE001 - shadow must never raise raw
            return ({"ok": False, "schema_version": SHADOW_RESPONSE_VERSION,
                     "request_id": str(req.get("request_id", "")),
                     "error": {"code": "INFERENCE_ERROR", "detail": f"{type(e).__name__}: {e}"[:500]},
                     "identity": self.identity()}, req)
        return resp, req

    def log_exchange(self, req: dict | None, resp: dict) -> None:
        if not self.request_log or req is None:
            return
        row = {"request": req, "response": resp}
        with self._lock:
            with open(self.request_log, "a", encoding="utf-8") as f:
                f.write(json.dumps(row, separators=(",", ":")) + "\n")


def make_handler(worker: ShadowWorker, shutdown_token: str | None = None,
                 parent_pid: int | None = None,
                 log_file: str | None = None):
    class Handler(BaseHTTPRequestHandler):
        server_version = "JevShadowWorker/1.1"

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
            with worker._lock:
                count = worker.count
            self._send({"ok": True, "service": "jev-shadow-worker",
                        "status": "READY",
                        "protocol_version": SHADOW_PROTOCOL_VERSION,
                        "pid": os.getpid(),
                        "parent_pid": parent_pid,
                        "observation_schema": SHADOW_OBSERVATION_SCHEMA,
                        "mission_schema": SHADOW_MISSIONMAP_VERSION,
                        "action_schema": SHADOW_ACTION_SCHEMA,
                        "identity": worker.identity(),
                        "uptime_s": time.time() - worker.started_at,
                        "requests": count})

        def do_POST(self) -> None:  # noqa: N802
            path = self.path.split("?")[0]
            if path == "/shutdown":
                self._handle_shutdown()
                return
            if path != "/infer":
                self.send_response(404)
                self.end_headers()
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                length = 0
            if length <= 0 or length > MAX_BODY_BYTES:
                self._send({"ok": False, "schema_version": SHADOW_RESPONSE_VERSION,
                            "error": {"code": "SCHEMA_MISMATCH",
                                      "detail": f"bad Content-Length {length}"},
                            "identity": worker.identity()})
                return
            body = self.rfile.read(length)
            resp, req = worker.infer_from_json(body)
            with worker._lock:
                worker.count += 1
            worker.log_exchange(req, resp)
            self._send(resp)

        def _handle_shutdown(self) -> None:
            # Owned shutdown only: the token is generated per spawn by the
            # owning Godot process and never logged. Without a configured
            # token (legacy manual start) remote shutdown is refused.
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
            sys.stderr.write("[jev-shadow-worker] owned shutdown requested\n")
            threading.Thread(target=self.server.shutdown,
                             name="owned-shutdown", daemon=True).start()

        def log_message(self, fmt: str, *args) -> None:
            try:
                sys.stderr.write("[jev-shadow-worker] " + fmt % args + "\n")
            except (AttributeError, OSError, ValueError):
                pass
            if log_file:
                try:
                    with open(log_file, "a", encoding="utf-8") as f:
                        f.write("[jev-shadow-worker] " + fmt % args + "\n")
                except OSError:
                    pass

    return Handler


def _parent_alive(pid: int | None) -> bool:
    if pid is None or pid <= 0:
        return True  # unmonitored (legacy manual start)
    if os.name == "nt":
        try:
            import ctypes
            kernel32 = ctypes.windll.kernel32
            # PROCESS_QUERY_LIMITED_INFORMATION; 0 on failure.
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
                f"[jev-shadow-worker] parent pid {parent_pid} gone; exiting\n")
            server.shutdown()
            return


def _emit(line: str, log_file: str | None) -> None:
    # pythonw.exe (hidden spawn) may have no usable stdio; never crash on it.
    try:
        print(line, flush=True)
    except (AttributeError, OSError, ValueError):
        pass
    if log_file:
        try:
            stamp = time.strftime("%Y-%m-%dT%H:%M:%S")
            with open(log_file, "a", encoding="utf-8") as f:
                f.write(f"{stamp} {line}\n")
        except OSError:
            pass


def serve(host: str, port: int, checkpoint: str, expect_sha256: str,
          request_log: str | None, parent_pid: int | None = None,
          shutdown_token: str | None = None,
          log_file: str | None = None,
          port_file: str | None = None) -> None:
    model, meta, digest, n_params = load_model(checkpoint, expect_sha256)
    worker = ShadowWorker(model, digest, n_params, checkpoint, request_log)
    server = ThreadingHTTPServer(
        (host, port),
        make_handler(worker, shutdown_token, parent_pid, log_file))
    server.daemon_threads = True
    bound_port = server.server_address[1]
    if port_file:
        with open(port_file, "w", encoding="utf-8") as f:
            f.write(str(bound_port))
    _emit(f"[jev-shadow-worker] READY model={MODEL_IDENTITY} "
          f"sha256={digest} params={n_params} device=cpu eval=true "
          f"url=http://{host}:{bound_port} pid={os.getpid()} "
          f"parent_pid={parent_pid} checkpoint_meta_keys={sorted(meta)}",
          log_file)
    _emit(f"[jev-shadow-worker] stdio stdout={sys.stdout!r} "
          f"stderr={sys.stderr!r} was_none={STDIO_WAS_NONE} "
          f"executable={sys.executable}",
          log_file)
    if parent_pid:
        threading.Thread(target=_watch_parent, args=(server, parent_pid),
                         name="parent-watch", daemon=True).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    _emit("[jev-shadow-worker] stopped", log_file)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="JEV shadow inference worker (SHADOW ONLY)")
    ap.add_argument("--host", default=DEFAULT_HOST)
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--checkpoint", default=DEFAULT_CHECKPOINT)
    ap.add_argument("--expect-sha256", default=CHECKPOINT_SHA256)
    ap.add_argument("--request-log",
                    default=os.path.join(STRATEGY_ROOT, "artifacts",
                                         "jev_godot_shadow_v0", "REQUESTS.jsonl"))
    ap.add_argument("--no-request-log", action="store_true")
    # Single-launch ownership: set by the owning Godot process only.
    ap.add_argument("--parent-pid", type=int, default=0)
    ap.add_argument("--shutdown-token", default="")
    ap.add_argument("--log-file", default="")
    ap.add_argument("--port-file", default="")
    args = ap.parse_args(argv)
    log_file = args.log_file.strip() or None
    try:
        serve(args.host, args.port, args.checkpoint, args.expect_sha256,
              None if args.no_request_log else args.request_log,
              parent_pid=args.parent_pid or None,
              shutdown_token=args.shutdown_token.strip() or None,
              log_file=log_file,
              port_file=args.port_file.strip() or None)
    except WorkerRefused as e:
        _emit(f"[jev-shadow-worker] REFUSED: {e}", log_file)
        return 2
    except OSError as e:
        _emit(f"[jev-shadow-worker] BIND FAILED: {e}", log_file)
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
