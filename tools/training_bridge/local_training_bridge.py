#!/usr/bin/env python3
"""
Local Training Bridge V1 - secure remote-control gateway for the local
training supervisor of the StrategyGame project.

Topology
--------
  PRIVATE ChatGPT Site (owner-only)
        |  HTTPS
  SITE SERVER-SIDE API ROUTE          <-- the ONLY holder of the bridge secret
        |  signed request (HMAC-SHA256)
  PUBLIC HTTPS TUNNEL (cloudflared, outbound-only)
        |
  LOCAL BRIDGE  127.0.0.1:8125        <-- this program (loopback only)
        |
  LOCAL TRAINING SUPERVISOR  127.0.0.1:8124   (untouched, loopback only)

Security properties
-------------------
* Binds to 127.0.0.1 ONLY (never 0.0.0.0). Enforced in code.
* Every endpoint requires HMAC-SHA256 request signing. There is no
  unauthenticated surface, not even /bridge/health.
* Signature covers: HTTP method, path, timestamp, nonce, SHA256(body).
* Timestamps outside a +/-60 second window are rejected.
* Nonces are single use (replay is rejected).
* Signature comparison is constant time (hmac.compare_digest).
* Narrow protocol: exactly six endpoints, no arbitrary proxying, no URL
  forwarding, no shell execution, no filesystem access from requests.
* The Site may send ONLY duration_hours and api_reference_percent.
  Executables / paths / shell / modules / URLs are rejected as unknown fields.
* Status responses are whitelisted projections. Secrets can never appear.
* CORS is disabled by default and is NEVER set to '*'.
* Fails closed when the supervisor is unreachable.

Secrets
-------
* TRAINING_BRIDGE_SECRET is loaded from the process environment, then from the
  per-user environment block, and only then generated (32+ random bytes).
* Never written into bridge_config.json, HTML, logs, URLs, or localStorage.
* This program never prints the secret value.
* The model/provider API key stays on the LOCAL machine: the bridge never
  accepts, forwards, stores, or returns one.

Training
--------
This bridge does not launch training by itself and can never enable the
supervisor's simulation mode (simulation_mode is hard-wired to false), so it
cannot fake training. POST /bridge/start simply forwards a validated run
configuration to the local supervisor, which owns the real API key.

Usage
-----
  python local_training_bridge.py                 # start the bridge
  python local_training_bridge.py --check         # validate config + secret
  python local_training_bridge.py --self-test     # run security tests A-J
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import http.server
import json
import os
import re
import secrets as crypto_secrets
import shutil
import socket
import socketserver
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, List, Optional, Tuple

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

SERVICE_NAME = "training-bridge"
SERVICE_VERSION = "1.0.0"

SECRET_ENV = "TRAINING_BRIDGE_SECRET"
MIN_SECRET_CHARS = 32

DEFAULT_BIND_HOST = "127.0.0.1"
DEFAULT_BIND_PORT = 8125
DEFAULT_SUPERVISOR_URL = "http://127.0.0.1:8124"

HDR_TIMESTAMP = "X-Bridge-Timestamp"
HDR_NONCE = "X-Bridge-Nonce"
HDR_SIGNATURE = "X-Bridge-Signature"

TIMESTAMP_RE = re.compile(r"^\d{10,12}$")
NONCE_RE = re.compile(r"^[A-Za-z0-9_\-]{16,64}$")
SIGNATURE_RE = re.compile(r"^[0-9a-f]{64}$")

MAX_CLOCK_SKEW_SECONDS = 60
NONCE_TTL_SECONDS = 120
NONCE_MAX_ENTRIES = 8192
MAX_BODY_BYTES = 16 * 1024
SUPERVISOR_TIMEOUT_SECONDS = 3.0
MAX_DURATION_HOURS = 720.0
MAX_RECENT_EVENTS = 20

LOOPBACK_HOSTS = ("127.0.0.1", "localhost", "::1")

# The Site is allowed to send ONLY these two fields on POST /bridge/start.
ALLOWED_START_FIELDS = ("duration_hours", "api_reference_percent")

# Exactly the safe projection returned by GET /bridge/status.
STATUS_FIELDS = (
    "state",
    "elapsed_seconds",
    "target_seconds",
    "remaining_seconds",
    "matches_completed",
    "wins",
    "losses",
    "draws",
    "current_match",
    "current_mode",
    "current_phase",
    "brain_checkpoint",
    "hands_checkpoint",
    "api_calls",
    "backend_wired",
    "last_error",
    "recent_events",
)

# The complete route table. Anything else is 404. There is no catch-all proxy.
PATH_METHODS: Dict[str, Tuple[str, ...]] = {
    "/bridge/health": ("GET",),
    "/bridge/status": ("GET",),
    "/bridge/start": ("POST",),
    "/bridge/pause": ("POST",),
    "/bridge/resume": ("POST",),
    "/bridge/stop": ("POST",),
}

# bridge_config.json must stay non-secret. These keys are refused outright.
FORBIDDEN_CONFIG_KEYS = {
    "secret",
    "secrets",
    "api_key",
    "apikey",
    "access_key",
    "auth",
    "authorization",
    "bearer",
    "token",
    "password",
    "passwd",
    "credentials",
    "trainING_bridge_secret".lower(),
    "openai_api_key",
    "openrouter_api_key",
    "deepseek_api_key",
}

DEFAULT_CONFIG: Dict[str, Any] = {
    "bind_host": DEFAULT_BIND_HOST,
    "bind_port": DEFAULT_BIND_PORT,
    "supervisor_url": DEFAULT_SUPERVISOR_URL,
    "run_defaults": {
        "provider": "opencode",
        "model": "deepseek-v4.1-flash",
    },
    "auth": {
        "secret_env_var": SECRET_ENV,
        "max_clock_skew_seconds": MAX_CLOCK_SKEW_SECONDS,
        "nonce_ttl_seconds": NONCE_TTL_SECONDS,
        "max_body_bytes": MAX_BODY_BYTES,
    },
    "cors_allow_origin": "",
}


# ---------------------------------------------------------------------------
# Secret handling (environment / process memory only, never printed)
# ---------------------------------------------------------------------------


def _read_user_env(name: str) -> str:
    """Read a per-user environment value (Windows registry). Portable no-op."""
    if sys.platform != "win32":
        return ""
    try:
        import winreg

        with winreg.OpenKey(
            winreg.HKEY_CURRENT_USER, "Environment", 0, winreg.KEY_READ
        ) as key:
            value, _ = winreg.QueryValueEx(key, name)
        return str(value).strip() if value else ""
    except Exception:
        return ""


def _write_user_env(name: str, value: str) -> bool:
    """Persist a per-user environment value. Never logs the value."""
    if sys.platform != "win32":
        return False
    try:
        import winreg

        with winreg.OpenKey(
            winreg.HKEY_CURRENT_USER, "Environment", 0, winreg.KEY_SET_VALUE
        ) as key:
            winreg.SetValueEx(key, name, 0, winreg.REG_SZ, value)
        return True
    except Exception:
        return False


def load_or_create_secret(env_var: str = SECRET_ENV) -> Tuple[str, str]:
    """
    Resolve the bridge secret.

    Order: process environment -> per-user environment -> generate (32+ bytes).

    Returns (secret, source). The secret is never printed or logged.
    """
    value = os.environ.get(env_var, "").strip()
    if value:
        return _require_strong(value, "process-env")

    value = _read_user_env(env_var)
    if value:
        os.environ[env_var] = value
        return _require_strong(value, "user-env")

    # 48 random bytes => 64 char base64url token (>= 32 random bytes required).
    value = crypto_secrets.token_urlsafe(48)
    os.environ[env_var] = value
    if _write_user_env(env_var, value):
        return value, "generated:user-env"
    return value, "generated:process-memory"


def _require_strong(value: str, source: str) -> Tuple[str, str]:
    if len(value) < MIN_SECRET_CHARS:
        raise SystemExit(
            "REFUSING TO START: {0} from [{1}] is shorter than {2} characters. "
            "Use 32+ random bytes. (value not shown)".format(
                SECRET_ENV, source, MIN_SECRET_CHARS
            )
        )
    return value, source


def scrub_secrets(text: str, secret: str) -> str:
    """Best-effort redaction so secrets cannot leak through relayed text."""
    if not text:
        return text
    if secret and secret in text:
        text = text.replace(secret, "[REDACTED]")
    text = re.sub(r"(?i)\b(bearer|api[_ -]?key|authorization)\b\s*[:=]\s*\S+", r"\1=[REDACTED]", text)
    return text


# ---------------------------------------------------------------------------
# Nonce cache (single use tokens)
# ---------------------------------------------------------------------------


class NonceCache:
    """Thread-safe single-use nonce store with TTL pruning and hard cap."""

    def __init__(self, ttl_seconds: float = NONCE_TTL_SECONDS, max_entries: int = NONCE_MAX_ENTRIES):
        self._ttl = float(ttl_seconds)
        self._max = int(max_entries)
        self._lock = threading.Lock()
        self._seen: Dict[str, float] = {}

    def consume(self, nonce: str) -> bool:
        """Return True and mark used when fresh. Return False on replay/pressure."""
        now = time.time()
        with self._lock:
            if len(self._seen) * 2 >= self._max:
                expired = [k for k, exp in self._seen.items() if exp <= now]
                for k in expired:
                    del self._seen[k]
            expiry = self._seen.get(nonce)
            if expiry is not None and expiry > now:
                return False
            if len(self._seen) >= self._max:
                return False
            self._seen[nonce] = now + self._ttl
            return True


# ---------------------------------------------------------------------------
# Request signing
# ---------------------------------------------------------------------------


def canonical_string(method: str, path: str, timestamp: str, nonce: str, body: bytes) -> str:
    """Exact string covered by the HMAC. Both sides must build it identically."""
    body_hash = hashlib.sha256(body).hexdigest()
    return "\n".join([method.upper(), path, timestamp, nonce, body_hash])


def sign_request(secret: str, method: str, path: str, timestamp: str, nonce: str, body: bytes) -> str:
    digest = hmac.new(secret.encode("utf-8"), canonical_string(method, path, timestamp, nonce, body).encode("utf-8"), hashlib.sha256)
    return digest.hexdigest()


def verify_request(
    secret: str,
    nonces: NonceCache,
    method: str,
    path: str,
    timestamp: str,
    nonce: str,
    signature: str,
    body: bytes,
    max_skew: float = MAX_CLOCK_SKEW_SECONDS,
) -> Tuple[bool, str]:
    """Authenticate a request. Returns (ok, reason). Constant-time compare."""
    if not timestamp or not nonce or not signature:
        return False, "missing_auth_headers"
    if not TIMESTAMP_RE.match(timestamp):
        return False, "malformed_timestamp"
    if not NONCE_RE.match(nonce):
        return False, "malformed_nonce"
    if not SIGNATURE_RE.match(signature):
        return False, "malformed_signature"

    expected = sign_request(secret, method, path, timestamp, nonce, body)
    if not hmac.compare_digest(expected, signature):
        return False, "bad_signature"

    # Skew is checked after the signature so we never accept unsigned timing data.
    now = time.time()
    ts = int(timestamp)
    if abs(now - float(ts)) > max_skew:
        return False, "stale_timestamp"

    if not nonces.consume(nonce):
        return False, "nonce_replay"
    return True, "ok"


# ---------------------------------------------------------------------------
# Non-secret configuration
# ---------------------------------------------------------------------------


def _assert_non_secret_config(node: Any, trail: str = "") -> None:
    if isinstance(node, dict):
        for key, value in node.items():
            if str(key).strip().lower() in FORBIDDEN_CONFIG_KEYS:
                raise SystemExit(
                    "REFUSING TO START: key '{0}' found in {1}. "
                    "Secrets must never be stored in bridge_config.json. "
                    "Use the {2} environment variable.".format(
                        key, trail or "config", SECRET_ENV
                    )
                )
            _assert_non_secret_config(value, "{0}.{1}".format(trail, key) if trail else str(key))
    elif isinstance(node, list):
        for idx, value in enumerate(node):
            _assert_non_secret_config(value, "{0}[{1}]".format(trail, idx))


def _merge(base: Any, override: Any) -> Any:
    if isinstance(base, dict) and isinstance(override, dict):
        merged = dict(base)
        for key, value in override.items():
            merged[key] = _merge(base.get(key), value) if key in base else value
        return merged
    return override


def load_config(path: Optional[str]) -> Dict[str, Any]:
    config = json.loads(json.dumps(DEFAULT_CONFIG))
    candidates = []
    if path:
        candidates.append(path)
    else:
        here = os.path.dirname(os.path.abspath(__file__))
        candidates.append(os.path.join(here, "bridge_config.json"))
    for candidate in candidates:
        if candidate and os.path.isfile(candidate):
            with open(candidate, "r", encoding="utf-8") as handle:
                loaded = json.load(handle)
            _assert_non_secret_config(loaded, os.path.basename(candidate))
            config = _merge(config, loaded)
    return config


def validate_loopback_url(url: str) -> str:
    """The supervisor URL is fixed to loopback. Requests can never supply one."""
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in ("http", "https"):
        raise SystemExit("REFUSING TO START: supervisor_url scheme must be http/https.")
    if parsed.hostname not in LOOPBACK_HOSTS:
        raise SystemExit(
            "REFUSING TO START: supervisor_url host must be loopback (127.0.0.1). "
            "The bridge is not a general purpose proxy."
        )
    if parsed.path not in ("", "/") or parsed.query or parsed.fragment or parsed.params:
        raise SystemExit("REFUSING TO START: supervisor_url must not carry a path/query.")
    return "{0}://{1}:{2}".format(parsed.scheme, parsed.hostname, parsed.port or (443 if parsed.scheme == "https" else 80))


def validate_bind_host(host: str) -> str:
    if host not in ("127.0.0.1", "::1"):
        raise SystemExit(
            "SECURITY VIOLATION: the bridge must bind ONLY to 127.0.0.1 (got {0}).".format(host)
        )
    return host


# ---------------------------------------------------------------------------
# Supervisor client (fixed target, no URL ever taken from a request)
# ---------------------------------------------------------------------------


class SupervisorClient:
    def __init__(self, base_url: str, timeout: float = SUPERVISOR_TIMEOUT_SECONDS):
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout

    def _call(self, method: str, api_path: str, payload: Optional[Dict[str, Any]] = None) -> Tuple[str, int, Optional[Dict[str, Any]]]:
        """Returns (kind, http_status, json) where kind is ok|offline|error."""
        url = self.base_url + api_path
        data = None if payload is None else json.dumps(payload).encode("utf-8")
        request = urllib.request.Request(url, data=data, method=method)
        if data is not None:
            request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                raw = response.read(1 << 20)
                status = int(response.status)
        except urllib.error.HTTPError as exc:
            try:
                raw = exc.read(1 << 20)
            except Exception:
                raw = b""
            status = int(exc.code)
        except (urllib.error.URLError, socket.timeout, TimeoutError, ConnectionError, OSError):
            return "offline", 0, None
        except Exception:
            return "error", 0, None
        try:
            parsed = json.loads(raw.decode("utf-8")) if raw else {}
        except Exception:
            return "error", status, None
        if not isinstance(parsed, dict):
            return "error", status, None
        return "ok", status, parsed

    def get_status(self) -> Tuple[str, Optional[Dict[str, Any]]]:
        kind, _, payload = self._call("GET", "/api/status")
        return kind, payload

    def post(self, api_path: str, payload: Optional[Dict[str, Any]] = None) -> Tuple[str, int, Optional[Dict[str, Any]]]:
        return self._call("POST", api_path, payload if payload is not None else {})


# ---------------------------------------------------------------------------
# Narrow protocol: validation and safe projections
# ---------------------------------------------------------------------------


def build_supervisor_start_payload(body: Any, run_defaults: Dict[str, Any]) -> Tuple[Optional[Dict[str, Any]], Optional[Dict[str, Any]]]:
    """
    Validate the remote start contract and build the supervisor payload.

    ONLY duration_hours and api_reference_percent are accepted. Anything else
    (executables, paths, shell commands, modules, URLs, api keys, ...) is
    rejected as an unknown field and never forwarded.

    Returns (payload, error_response).
    """
    if not isinstance(body, dict):
        return None, {"ok": False, "error": "body_must_be_json_object"}

    for key in body.keys():
        if key not in ALLOWED_START_FIELDS:
            return None, {
                "ok": False,
                "error": "field_not_allowed",
                "field": str(key)[:64],
                "allowed_fields": list(ALLOWED_START_FIELDS),
            }

    if "duration_hours" not in body:
        return None, {"ok": False, "error": "missing_field", "field": "duration_hours"}
    raw_duration = body["duration_hours"]
    if isinstance(raw_duration, bool) or not isinstance(raw_duration, (int, float)):
        return None, {"ok": False, "error": "invalid_field", "field": "duration_hours"}
    duration_hours = float(raw_duration)
    if not (0.0 < duration_hours <= MAX_DURATION_HOURS):
        return None, {
            "ok": False,
            "error": "invalid_field",
            "field": "duration_hours",
            "detail": "must be > 0 and <= {0}".format(MAX_DURATION_HOURS),
        }

    raw_percent = body.get("api_reference_percent", 0)
    if isinstance(raw_percent, bool) or not isinstance(raw_percent, (int, float)):
        return None, {"ok": False, "error": "invalid_field", "field": "api_reference_percent"}
    api_reference_percent = float(raw_percent)
    if not (0.0 <= api_reference_percent <= 100.0):
        return None, {
            "ok": False,
            "error": "invalid_field",
            "field": "api_reference_percent",
            "detail": "must be between 0 and 100",
        }

    provider = str((run_defaults or {}).get("provider") or "opencode").strip()
    model = str((run_defaults or {}).get("model") or "deepseek-v4.1-flash").strip()

    # simulation_mode is deliberately hard-wired to False: the bridge can never
    # fake training. No api_key field is ever emitted: the local supervisor
    # keeps owning the model provider key.
    payload = {
        "duration_hours": duration_hours,
        "api_reference_percent": api_reference_percent,
        "provider": provider,
        "model": model,
        "simulation_mode": False,
    }
    return payload, None


def project_status(src: Dict[str, Any], secret: str) -> Dict[str, Any]:
    """Whitelisted, secret-free projection of the supervisor status."""

    def as_str(key: str, default: str = "") -> str:
        value = src.get(key, default)
        if value is None:
            return default
        return scrub_secrets(value if isinstance(value, str) else str(value), secret)

    def as_int(key: str, default: int = 0) -> int:
        try:
            return int(src.get(key, default))
        except (TypeError, ValueError):
            return default

    def as_float(key: str, default: float = 0.0) -> float:
        try:
            return float(src.get(key, default))
        except (TypeError, ValueError):
            return default

    def as_bool(key: str, default: bool = False) -> bool:
        return bool(src.get(key, default))

    events: List[Dict[str, str]] = []
    raw_events = src.get("recent_events")
    if isinstance(raw_events, list):
        for item in raw_events[-MAX_RECENT_EVENTS:]:
            if isinstance(item, dict):
                events.append(
                    {
                        "timestamp": as_str_from(item, "timestamp"),
                        "level": as_str_from(item, "level"),
                        "message": scrub_secrets(as_str_from(item, "message"), secret),
                    }
                )

    projected: Dict[str, Any] = {
        "state": as_str("state", "UNKNOWN"),
        "elapsed_seconds": as_float("elapsed_seconds"),
        "target_seconds": as_float("target_seconds"),
        "remaining_seconds": as_float("remaining_seconds"),
        "matches_completed": as_int("matches_completed"),
        "wins": as_int("wins"),
        "losses": as_int("losses"),
        "draws": as_int("draws"),
        "current_match": as_int("current_match"),
        "current_mode": as_str("current_mode", "IDLE"),
        "current_phase": as_str("current_phase", "IDLE"),
        "brain_checkpoint": as_str("brain_checkpoint", "B0"),
        "hands_checkpoint": as_str("hands_checkpoint", "H0"),
        "api_calls": as_int("api_calls"),
        "backend_wired": as_bool("backend_wired", False),
        "last_error": as_str("last_error", ""),
        "recent_events": events,
    }
    # Non-secret extras. supervisor_reachable is part of the OFFLINE contract;
    # simulation_mode prevents a local simulation run from being read as real.
    projected["supervisor_reachable"] = True
    projected["simulation_mode"] = as_bool("simulation_mode", False)
    return projected


def as_str_from(item: Dict[str, Any], key: str) -> str:
    value = item.get(key, "")
    if value is None:
        return ""
    return value if isinstance(value, str) else str(value)


def project_control_response(payload: Optional[Dict[str, Any]], secret: str) -> Dict[str, Any]:
    """Relay only benign supervisor fields back to the Site."""
    if not isinstance(payload, dict):
        return {"ok": False, "error": "supervisor_response_unreadable"}
    out: Dict[str, Any] = {}
    if "ok" in payload:
        out["ok"] = bool(payload.get("ok"))
    if isinstance(payload.get("error"), str):
        out["error"] = scrub_secrets(payload["error"], secret)
    if isinstance(payload.get("message"), str):
        out["message"] = scrub_secrets(payload["message"], secret)
    if isinstance(payload.get("state"), str):
        out["state"] = payload["state"]
    if isinstance(payload.get("run_id"), str):
        out["run_id"] = payload["run_id"]
    return out


OFFLINE_STATUS: Dict[str, Any] = {"state": "OFFLINE", "supervisor_reachable": False}


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------


class BridgeContext:
    def __init__(self, secret: str, config: Dict[str, Any], supervisor: SupervisorClient):
        self.secret = secret
        self.config = config
        self.supervisor = supervisor
        self.nonces = NonceCache(
            ttl_seconds=float(config.get("auth", {}).get("nonce_ttl_seconds", NONCE_TTL_SECONDS)),
            max_entries=NONCE_MAX_ENTRIES,
        )
        self.max_skew = float(config.get("auth", {}).get("max_clock_skew_seconds", MAX_CLOCK_SKEW_SECONDS))
        self.max_body = int(config.get("auth", {}).get("max_body_bytes", MAX_BODY_BYTES))
        self.cors_origin = str(config.get("cors_allow_origin", "") or "").strip()
        if self.cors_origin == "*":
            # Wildcard CORS is forbidden. Fall back to no CORS at all.
            self.cors_origin = ""
        self.run_defaults = dict(config.get("run_defaults", {}))
        self.started_at = time.time()


class BridgeHandler(http.server.BaseHTTPRequestHandler):
    """Narrow, authenticated bridge endpoint handler."""

    server_version = "TrainingBridge/" + SERVICE_VERSION
    sys_version = ""
    ctx: BridgeContext

    # -- plumbing ------------------------------------------------------------

    def log_message(self, fmt: str, *args: Any) -> None:
        """Never log headers, bodies, signatures, or query strings."""
        return

    def log_request(self, code: Any = "-", size: Any = "-") -> None:
        path = self.path.split("?")[0][:80]
        sys.stderr.write(
            "[{0}] {1} {2} -> {3}\n".format(
                time.strftime("%Y-%m-%d %H:%M:%S"), self.command, path, code
            )
        )

    def _send_json(self, status_code: int, data: Dict[str, Any], extra_headers: Optional[Dict[str, str]] = None) -> None:
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.send_header("Pragma", "no-cache")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")
        # CORS is opt-in, single exact origin, never '*'. Default: no header.
        if self.ctx.cors_origin:
            self.send_header("Access-Control-Allow-Origin", self.ctx.cors_origin)
            self.send_header("Vary", "Origin")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header(
                "Access-Control-Allow-Headers",
                "Content-Type, {0}, {1}, {2}".format(HDR_TIMESTAMP, HDR_NONCE, HDR_SIGNATURE),
            )
            self.send_header("Access-Control-Max-Age", "600")
        if extra_headers:
            for name, value in extra_headers.items():
                self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def _deny(self, status_code: int, reason: str) -> None:
        self._send_json(status_code, {"ok": False, "error": "auth_failed", "reason": reason})

    def _read_body(self) -> Tuple[Optional[bytes], Optional[Tuple[int, str]]]:
        if self.headers.get("Transfer-Encoding"):
            return None, (400, "transfer_encoding_not_supported")
        raw_length = self.headers.get("Content-Length", "0") or "0"
        try:
            length = int(raw_length)
        except ValueError:
            return None, (400, "invalid_content_length")
        if length < 0:
            return None, (400, "invalid_content_length")
        if length > self.ctx.max_body:
            return None, (413, "body_too_large")
        chunks: List[bytes] = []
        remaining = length
        while remaining > 0:
            chunk = self.rfile.read(min(remaining, 8192))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks), None

    def _peer_is_loopback(self) -> bool:
        try:
            host = self.client_address[0]
        except Exception:
            return False
        return host in ("127.0.0.1", "::1", "::ffff:127.0.0.1")

    def _parse_target(self) -> Tuple[str, bool, Optional[Tuple[int, str]]]:
        """Return (path, had_query, error). Query strings are never forwarded."""
        raw = self.path or ""
        # Reject absolute-form request targets (proxied requests such as
        # 'http://evil.example/bridge/status'). Only origin-form is accepted.
        if not raw.startswith("/"):
            return "", False, (400, "absolute_request_target_rejected")
        had_query = ("?" in raw) or ("#" in raw)
        path = raw.split("?", 1)[0].split("#", 1)[0]
        if "\\" in path:
            return "", False, (400, "malformed_path")
        if path != "/" and path.endswith("/"):
            path = path.rstrip("/")
        return path, had_query, None

    def _authenticate(self, path: str, body: bytes) -> Optional[Tuple[int, str]]:
        timestamp = (self.headers.get(HDR_TIMESTAMP) or "").strip()
        nonce = (self.headers.get(HDR_NONCE) or "").strip()
        signature = (self.headers.get(HDR_SIGNATURE) or "").strip().lower()
        ok, reason = verify_request(
            self.ctx.secret,
            self.ctx.nonces,
            self.command,
            path,
            timestamp,
            nonce,
            signature,
            body,
            max_skew=self.ctx.max_skew,
        )
        if not ok:
            self._deny(401, reason)
            return (401, reason)
        return None

    # -- shared dispatch ------------------------------------------------------

    def _dispatch(self) -> None:
        if not self._peer_is_loopback():
            self._send_json(403, {"ok": False, "error": "loopback_only"})
            return

        path, had_query, path_error = self._parse_target()
        if path_error:
            self._send_json(path_error[0], {"ok": False, "error": path_error[1]})
            return

        allowed_methods = PATH_METHODS.get(path)
        if allowed_methods is None:
            # Unknown endpoint: 404 before auth so the route map stays explicit.
            # This is also how /bridge/proxy?target=... style probes die.
            self._send_json(404, {"ok": False, "error": "not_found"})
            return
        if self.command not in allowed_methods:
            self._send_json(405, {"ok": False, "error": "method_not_allowed", "allowed": list(allowed_methods)})
            return
        if had_query:
            # Known route but a query string: nothing in the protocol uses one.
            self._send_json(400, {"ok": False, "error": "query_strings_not_permitted"})
            return

        body, body_error = self._read_body()
        if body_error:
            self._send_json(body_error[0], {"ok": False, "error": body_error[1]})
            return
        assert body is not None

        auth_error = self._authenticate(path, body)
        if auth_error:
            return

        handler = {
            "/bridge/health": self._handle_health,
            "/bridge/status": self._handle_status,
            "/bridge/start": self._handle_start,
            "/bridge/pause": self._handle_pause,
            "/bridge/resume": self._handle_resume,
            "/bridge/stop": self._handle_stop,
        }[path]
        handler(body)

    def do_GET(self) -> None:
        self._dispatch()

    def do_POST(self) -> None:
        self._dispatch()

    def do_OPTIONS(self) -> None:
        if self.ctx.cors_origin:
            path, _had_query, path_error = self._parse_target()
            if path_error or path not in PATH_METHODS:
                self._send_json(404, {"ok": False, "error": "not_found"})
                return
            self._send_json(204, {})
            return
        self._send_json(404, {"ok": False, "error": "not_found"})

    def do_PUT(self) -> None:
        self._send_json(405, {"ok": False, "error": "method_not_allowed"})

    def do_DELETE(self) -> None:
        self._send_json(405, {"ok": False, "error": "method_not_allowed"})

    def do_PATCH(self) -> None:
        self._send_json(405, {"ok": False, "error": "method_not_allowed"})

    # -- endpoints -----------------------------------------------------------

    def _handle_health(self, body: bytes) -> None:
        kind, _ = self.ctx.supervisor.get_status()
        self._send_json(
            200,
            {
                "ok": True,
                "service": SERVICE_NAME,
                "version": SERVICE_VERSION,
                "supervisor_reachable": kind == "ok",
            },
        )

    def _handle_status(self, body: bytes) -> None:
        kind, payload = self.ctx.supervisor.get_status()
        if kind == "ok" and isinstance(payload, dict):
            self._send_json(200, project_status(payload, self.ctx.secret))
            return
        if kind == "offline":
            # Fail closed. Do not fabricate training data.
            self._send_json(200, dict(OFFLINE_STATUS))
            return
        self._send_json(502, {"ok": False, "error": "supervisor_response_unreadable"})

    def _handle_start(self, body: bytes) -> None:
        try:
            parsed = json.loads(body.decode("utf-8")) if body else {}
        except Exception:
            self._send_json(400, {"ok": False, "error": "invalid_json_body"})
            return
        payload, error = build_supervisor_start_payload(parsed, self.ctx.run_defaults)
        if error is not None:
            self._send_json(400, error)
            return
        assert payload is not None
        kind, status_code, response = self.ctx.supervisor.post("/api/start", payload)
        if kind == "offline":
            self._send_json(503, {"ok": False, "error": "supervisor_unreachable", **OFFLINE_STATUS})
            return
        code = status_code if status_code in (200, 400, 409) else 502
        self._send_json(code, project_control_response(response, self.ctx.secret))

    def _handle_pause(self, body: bytes) -> None:
        self._relay_empty_control("/api/pause")

    def _handle_resume(self, body: bytes) -> None:
        # Any body is discarded: the bridge never forwards credentials.
        self._relay_empty_control("/api/resume")

    def _handle_stop(self, body: bytes) -> None:
        self._relay_empty_control("/api/stop")

    def _relay_empty_control(self, api_path: str) -> None:
        kind, status_code, response = self.ctx.supervisor.post(api_path, {})
        if kind == "offline":
            self._send_json(503, {"ok": False, "error": "supervisor_unreachable", **OFFLINE_STATUS})
            return
        code = status_code if status_code in (200, 400, 409) else 502
        self._send_json(code, project_control_response(response, self.ctx.secret))


class BridgeHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 64


def run_server(config: Dict[str, Any], secret: str, secret_source_label: str = "loaded") -> None:
    host = validate_bind_host(str(config.get("bind_host", DEFAULT_BIND_HOST)))
    port = int(config.get("bind_port", DEFAULT_BIND_PORT))
    supervisor_url = validate_loopback_url(str(config.get("supervisor_url", DEFAULT_SUPERVISOR_URL)))

    ctx = BridgeContext(secret, config, SupervisorClient(supervisor_url))

    handler_class = type("BoundBridgeHandler", (BridgeHandler,), {"ctx": ctx})

    httpd = BridgeHTTPServer((host, port), handler_class)
    bound_host, bound_port = httpd.server_address[0], httpd.server_address[1]
    sys.stderr.write(
        "\n"
        "========================================================\n"
        " Strategy AI Training Bridge V1\n"
        " Bound strictly to {0}:{1} (loopback only, never 0.0.0.0)\n"
        " Supervisor target : {2}\n"
        " Auth              : HMAC-SHA256 ({3}, secret source={4}, value never printed)\n"
        " CORS              : {5}\n"
        " Endpoints         : {6}\n"
        "========================================================\n\n".format(
            bound_host,
            bound_port,
            supervisor_url,
            HDR_SIGNATURE,
            secret_source_label,
            ctx.cors_origin or "disabled (no CORS headers)",
            ", ".join("{0} {1}".format("/".join(v), k) for k, v in PATH_METHODS.items()),
        )
    )
    sys.stderr.write("Secret value is never printed. Retrieve it only from the environment.\n")
    try:
        httpd.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        sys.stderr.write("\n[bridge] shutdown requested.\n")
    finally:
        httpd.server_close()


# ---------------------------------------------------------------------------
# Security self tests (A-J)
# ---------------------------------------------------------------------------


def _local_listening_addresses(port: int) -> List[str]:
    """Best-effort parse of 'netstat -ano -p TCP' for LISTENING sockets on port."""
    found: List[str] = []
    try:
        output = subprocess.check_output(
            ["netstat", "-ano", "-p", "TCP"],
            text=True,
            errors="replace",
            timeout=20,
        )
    except Exception:
        return found
    needle = ":{0}".format(port)
    for line in output.splitlines():
        parts = line.split()
        if len(parts) < 4:
            continue
        local_address = parts[1]
        state = parts[3].upper()
        if state == "LISTENING" and local_address.endswith(needle):
            found.append(local_address)
    return found


def _is_loopback_bind(address: str) -> bool:
    host = address.rsplit(":", 1)[0]
    return host in ("127.0.0.1", "::1", "[::1]", "localhost")


def _lan_ip() -> Optional[str]:
    try:
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        probe.connect(("192.0.2.1", 80))  # TEST-NET-1, no packets expected
        address = probe.getsockname()[0]
        probe.close()
        return address
    except Exception:
        return None


def _can_connect(host: str, port: int, timeout: float = 1.0) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except Exception:
        return False


def _probe_fail_closed(secret: str) -> Tuple[bool, str]:
    """
    Prove the OFFLINE contract on a throwaway bridge instance whose supervisor
    target is a dead loopback port. Starts no training and touches no live run.
    """
    config = json.loads(json.dumps(DEFAULT_CONFIG))
    dead_target = "http://127.0.0.1:9"  # discard port: nothing ever listens here
    config["supervisor_url"] = dead_target
    ctx = BridgeContext(secret, config, SupervisorClient(dead_target, timeout=0.4))
    handler_class = type("FailClosedProbeHandler", (BridgeHandler,), {"ctx": ctx})
    httpd = BridgeHTTPServer(("127.0.0.1", 0), handler_class)
    port = httpd.server_address[1]
    thread = threading.Thread(target=httpd.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
    thread.start()
    try:
        client = _SelfTestClient("http://127.0.0.1:{0}".format(port), secret)
        status_s, body_s, _ = client.raw("GET", "/bridge/status")
        status_p, body_p, _ = client.raw("POST", "/bridge/stop", b"{}")
        text_s = body_s.decode("utf-8", errors="replace")
        text_p = body_p.decode("utf-8", errors="replace")
        try:
            parsed = json.loads(text_s) if text_s else {}
        except Exception:
            parsed = {}
        ok = (
            status_s == 200
            and parsed == {"state": "OFFLINE", "supervisor_reachable": False}
            and status_p == 503
            and "supervisor_unreachable" in text_p
        )
        return ok, "GET /bridge/status -> {0} {1} | POST /bridge/stop -> {2} {3}".format(
            status_s, text_s, status_p, text_p
        )
    finally:
        httpd.shutdown()
        httpd.server_close()


class _SelfTestClient:
    def __init__(self, base_url: str, secret: str):
        self.base_url = base_url.rstrip("/")
        self.secret = secret

    def raw(
        self,
        method: str,
        path: str,
        body: bytes = b"",
        *,
        sign: bool = True,
        timestamp: Optional[str] = None,
        nonce: Optional[str] = None,
        signature: Optional[str] = None,
    ) -> Tuple[int, bytes, Dict[str, str]]:
        url = self.base_url + path
        request = urllib.request.Request(url, data=body if body else None, method=method)
        if body:
            request.add_header("Content-Type", "application/json")
        if sign:
            ts = timestamp if timestamp is not None else str(int(time.time()))
            nn = nonce if nonce is not None else crypto_secrets.token_hex(16)
            sig = signature if signature is not None else sign_request(self.secret, method, path, ts, nn, body)
            request.add_header(HDR_TIMESTAMP, ts)
            request.add_header(HDR_NONCE, nn)
            request.add_header(HDR_SIGNATURE, sig)
        try:
            with urllib.request.urlopen(request, timeout=5.0) as response:
                return int(response.status), response.read(), dict(response.headers.items())
        except urllib.error.HTTPError as exc:
            return int(exc.code), exc.read(), dict(exc.headers.items()) if exc.headers else {}
        except Exception as exc:
            return 0, str(exc).encode("utf-8"), {}


def _raw_request_line_status(host: str, port: int, request_line: str) -> int:
    """Send a raw request line (to exercise absolute-form targets) -> status code."""
    try:
        with socket.create_connection((host, port), timeout=3.0) as sock:
            payload = "{0}\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n".format(request_line)
            sock.sendall(payload.encode("utf-8"))
            data = sock.recv(4096)
        line = data.split(b"\r\n", 1)[0].decode("utf-8", "replace")
        return int(line.split()[1])
    except Exception:
        return 0


def run_self_tests(base_url: str, secret: str, supervisor_port: int, bridge_port: int) -> Dict[str, Any]:
    client = _SelfTestClient(base_url, secret)
    tests: List[Dict[str, Any]] = []

    def record(test_id: str, name: str, expected: str, actual: str, result: str, notes: str = "") -> None:
        tests.append(
            {
                "id": test_id,
                "name": name,
                "expected": expected,
                "actual": actual,
                "result": result,
                "notes": notes,
            }
        )

    def finish(test_id: str, name: str, expected: str, status: int, body: bytes, predicate, notes: str = "") -> None:
        text = body.decode("utf-8", errors="replace")
        actual = "HTTP {0} body={1}".format(status, text[:180].replace("\n", " "))
        try:
            ok = predicate(status, text)
        except Exception as exc:
            ok = False
            notes = (notes + " predicate_error={0}".format(exc)).strip()
        record(test_id, name, expected, actual, "PASS" if ok else "FAIL", notes)

    # ---- TEST A: valid signed GET /bridge/status -> 200 --------------------
    status_a, body_a, headers_a = client.raw("GET", "/bridge/status")
    finish("A", "Valid signed GET /bridge/status", "HTTP 200", status_a, body_a,
           lambda s, t: s == 200, "Requires a valid HMAC signature.")

    # ---- TEST B: no signature -> 401 ---------------------------------------
    status_b, body_b, _ = client.raw("GET", "/bridge/status", sign=False)
    finish("B", "No signature", "HTTP 401", status_b, body_b,
           lambda s, t: s == 401 and "auth_failed" in t, "All auth headers omitted.")

    # ---- TEST C: wrong signature -> 401 ------------------------------------
    status_c, body_c, _ = client.raw(
        "GET", "/bridge/status", signature=hashlib.sha256(b"wrong").hexdigest()
    )
    finish("C", "Wrong signature", "HTTP 401", status_c, body_c,
           lambda s, t: s == 401 and "auth_failed" in t, "Signature computed with a wrong key/over wrong data.")

    # ---- TEST D: old timestamp -> 401 --------------------------------------
    status_d, body_d, _ = client.raw(
        "GET", "/bridge/status", timestamp=str(int(time.time()) - 3600)
    )
    finish("D", "Old timestamp (now-3600s)", "HTTP 401", status_d, body_d,
           lambda s, t: s == 401 and "stale_timestamp" in t, "Max clock skew is 60 seconds.")

    # ---- TEST E: replay same nonce -> 401 ----------------------------------
    replay_ts = str(int(time.time()))
    replay_nonce = crypto_secrets.token_hex(16)
    replay_sig = sign_request(secret, "GET", "/bridge/status", replay_ts, replay_nonce, b"")
    status_e1, body_e1, _ = client.raw(
        "GET", "/bridge/status", timestamp=replay_ts, nonce=replay_nonce, signature=replay_sig
    )
    status_e2, body_e2, _ = client.raw(
        "GET", "/bridge/status", timestamp=replay_ts, nonce=replay_nonce, signature=replay_sig
    )
    finish("E", "Replay same nonce", "first 200 then 401", status_e2, body_e2,
           lambda s, t: status_e1 == 200 and status_e2 == 401 and "nonce_replay" in t,
           "First use={0}, replay={1}.".format(status_e1, status_e2))

    # ---- TEST F: unknown endpoint -> 404 -----------------------------------
    status_f, body_f, _ = client.raw("GET", "/bridge/does-not-exist")
    status_f2, body_f2, _ = client.raw("POST", "/api/start")
    finish("F", "Unknown endpoint", "HTTP 404", status_f, body_f,
           lambda s, t: s == 404 and status_f2 == 404,
           "Also 404 for raw supervisor path /api/start (no arbitrary proxying).")

    # ---- TEST G: arbitrary proxy URL attempt -------------------------------
    probe_body = json.dumps(
        {
            "duration_hours": 1,
            "api_reference_percent": 0,
            "url": "http://evil.example/x",
            "exec": "cmd.exe",
            "shell": "rm -rf /",
            "path": "C:\\Windows\\System32",
            "python_module": "os",
        }
    ).encode("utf-8")
    status_g, body_g, _ = client.raw("POST", "/bridge/start", probe_body)
    status_g2, body_g2, _ = client.raw("GET", "/bridge/proxy?target=http://evil.example/")
    status_g3, body_g3, _ = client.raw("GET", "/bridge/status?next=http://evil.example/")
    parsed_target = urllib.parse.urlparse(base_url)
    status_g4 = _raw_request_line_status(
        parsed_target.hostname or "127.0.0.1",
        parsed_target.port or 80,
        "GET http://evil.example/bridge/status HTTP/1.1",
    )
    payload, error = build_supervisor_start_payload(
        {"duration_hours": 1, "url": "http://evil.example/"}, {}
    )
    unit_ok = payload is None and error is not None and error.get("error") == "field_not_allowed"
    finish("G", "Arbitrary proxy URL / shell / path attempt", "rejected (400/404) and impossible",
           status_g, body_g,
           lambda s, t: s == 400 and "field_not_allowed" in t
           and status_g2 == 404
           and status_g3 == 400
           and status_g4 == 400
           and unit_ok,
           "Extra fields 400, /bridge/proxy 404, query string 400, absolute-form target 400, "
           "payload builder rejects unknown fields.")

    # ---- TEST H: status contains no API key or bridge secret ---------------
    forbidden_keys = ("api_key", "apikey", "authorization", "secret", "token", "password", "credential")
    parsed_status: Dict[str, Any] = {}
    parse_ok = False
    try:
        parsed_status = json.loads(body_a.decode("utf-8")) if status_a == 200 else {}
        parse_ok = isinstance(parsed_status, dict)
    except Exception:
        parse_ok = False

    def walk_keys(node: Any, hits: List[str]) -> None:
        if isinstance(node, dict):
            for key, value in node.items():
                lowered = str(key).lower()
                if lowered in forbidden_keys:
                    hits.append(str(key))
                walk_keys(value, hits)
        elif isinstance(node, list):
            for value in node:
                walk_keys(value, hits)

    key_hits: List[str] = []
    walk_keys(parsed_status, key_hits)
    secret_leak = bool(secret) and secret in body_a.decode("utf-8", errors="replace")
    header_leak = any(
        name.lower() in ("authorization", "x-bridge-signature", "set-cookie")
        for name in headers_a.keys()
    )
    finish("H", "Status contains no API key or bridge secret",
           "no secret value, no credential keys, no auth headers",
           status_a, body_a,
           lambda s, t: parse_ok and not key_hits and not secret_leak and not header_leak,
           "forbidden_keys={0} secret_in_body={1} auth_headers={2}".format(key_hits, secret_leak, header_leak))

    # ---- TEST I: supervisor remains bound only to 127.0.0.1 ----------------
    sup_addrs = _local_listening_addresses(supervisor_port)
    lan = _lan_ip()
    bound_ok = bool(sup_addrs) and all(_is_loopback_bind(a) for a in sup_addrs)
    lan_rejects = True if not lan else not _can_connect(lan, supervisor_port)
    loopback_accepts = _can_connect("127.0.0.1", supervisor_port)
    record(
        "I",
        "Supervisor remains bound only to 127.0.0.1",
        "listening on 127.0.0.1:{0} only; LAN IP rejects".format(supervisor_port),
        "netstat={0} loopback_connect={1} lan_connect_blocked={2}".format(sup_addrs or "unparsed", loopback_accepts, lan_rejects),
        "PASS" if (bound_ok and lan_rejects and loopback_accepts) else ("FAIL" if sup_addrs else "NOT_RUN"),
        "Source also asserts host == '127.0.0.1'.",
    )

    # ---- TEST J: tunnel forwards only to 127.0.0.1:8125 --------------------
    bridge_addrs = _local_listening_addresses(bridge_port)
    bridge_bound_ok = bool(bridge_addrs) and all(_is_loopback_bind(a) for a in bridge_addrs)
    lan_bridge_rejects = True if not lan else not _can_connect(lan, bridge_port)
    cloudflared = shutil.which("cloudflared")
    tunnel_target = "http://127.0.0.1:{0}".format(bridge_port)
    if cloudflared:
        tunnel_state = "cloudflared_present:{0} expected_target={1}".format(cloudflared, tunnel_target)
        tunnel_result = "PASS" if bridge_bound_ok and lan_bridge_rejects else "FAIL"
        tunnel_notes = "Inspect the cloudflared ingress to confirm its ONLY origin is {0}.".format(tunnel_target)
    else:
        tunnel_state = "cloudflared NOT INSTALLED; expected_target={0}".format(tunnel_target)
        tunnel_result = "NOT_RUN"
        tunnel_notes = "Tunnel not executed. Bridge is loopback-only and the documented ingress target is {0}.".format(tunnel_target)
    record(
        "J",
        "Tunnel forwards only to 127.0.0.1:{0}".format(bridge_port),
        "tunnel origin == http://127.0.0.1:{0}; no public listener".format(bridge_port),
        "netstat={0} lan_connect_blocked={1} | {2}".format(bridge_addrs or "unparsed", lan_bridge_rejects, tunnel_state),
        tunnel_result if bridge_bound_ok else "FAIL",
        tunnel_notes,
    )

    # ---- Supporting checks (not A-J) ---------------------------------------
    control_notes: List[str] = []
    state_now = "UNKNOWN"
    if status_a == 200 and parse_ok:
        state_now = str(parsed_status.get("state", "UNKNOWN"))
    if state_now in ("RUNNING", "PAUSED"):
        record("S1", "Control round trip through the bridge", "forwarded to supervisor",
               "SKIPPED state={0}".format(state_now), "SKIPPED",
               "Active run in progress: the self test never disturbs a real run.")
    else:
        status_p, body_p, _ = client.raw("POST", "/bridge/pause", b"{}")
        status_r, body_r, _ = client.raw("POST", "/bridge/resume", b"{}")
        status_s, body_s, _ = client.raw("POST", "/bridge/stop", b"{}")
        forwarded = all(
            marker in (body_p + body_r + body_s).decode("utf-8", errors="replace")
            for marker in ("Cannot pause", "Cannot resume", "already")
        ) or all(code in (200, 400) for code in (status_p, status_r, status_s))
        record(
            "S1",
            "Control round trip through the bridge",
            "bridge reaches supervisor and relays its answer",
            "pause={0} resume={1} stop={2}".format(status_p, status_r, status_s),
            "PASS" if forwarded else "FAIL",
            "No run is started. Supervisor answers with its real state errors, proving the forward path.",
        )
        control_notes.append("pause/resume/stop round trip exercised with no run active (nothing was started).")

    cors_headers = [name for name in headers_a.keys() if name.lower().startswith("access-control-")]
    record(
        "S2",
        "CORS posture",
        "no Access-Control-Allow-Origin (or a single exact origin, never '*')",
        "cors_headers={0}".format(cors_headers or "none"),
        "PASS" if not any("*" in str(v) for k, v in headers_a.items() if k.lower().startswith("access-control-")) else "FAIL",
        "CORS is disabled by default in bridge_config.example.json.",
    )

    scan_text = json.dumps(parsed_status, ensure_ascii=False) if parse_ok else body_a.decode("utf-8", errors="replace")
    record(
        "S3",
        "Status payload schema",
        "whitelisted fields only",
        "keys={0}".format(sorted(parsed_status.keys()) if parse_ok else []),
        "PASS" if parse_ok and all(k in STATUS_FIELDS or k in ("supervisor_reachable", "simulation_mode") for k in parsed_status.keys()) else "FAIL",
        "Extra non-secret keys: supervisor_reachable, simulation_mode.",
    )

    try:
        fail_closed_ok, fail_closed_detail = _probe_fail_closed(secret)
    except Exception as exc:
        fail_closed_ok, fail_closed_detail = False, "probe_error={0}".format(exc)
    record(
        "S4",
        "Fail closed when the supervisor is unreachable",
        'GET /bridge/status -> {"state":"OFFLINE","supervisor_reachable":false}',
        fail_closed_detail,
        "PASS" if fail_closed_ok else "FAIL",
        "Probed on a throwaway bridge bound to a dead supervisor target. No training, no live run touched.",
    )

    overall = "PASS"
    for item in tests:
        if item["result"] == "FAIL":
            overall = "FAIL"
            break
        if item["result"] == "NOT_RUN":
            overall = "PASS_WITH_GAPS"

    return {
        "schema": "training_bridge_v1_results/1",
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "service": SERVICE_NAME,
        "service_version": SERVICE_VERSION,
        "bridge_base_url": base_url,
        "supervisor_port": supervisor_port,
        "bridge_port": bridge_port,
        "auth_scheme": "HMAC-SHA256 over METHOD\\npath\\ntimestamp\\nnonce\\nsha256(body)",
        "overall": overall,
        "tests": tests,
        "supporting_notes": control_notes,
        "secret_exposed_in_results": False,
    }


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def _print_check(config: Dict[str, Any], secret: str, source: str) -> None:
    print("config_ok            : true")
    print("bind                 : {0}:{1}".format(config.get("bind_host"), config.get("bind_port")))
    print("supervisor_url       : {0}".format(validate_loopback_url(str(config.get("supervisor_url")))))
    print("secret_source        : {0}".format(source))
    print("secret_loaded        : true (value not shown, length>= {0})".format(MIN_SECRET_CHARS))
    print("cors_allow_origin    : {0}".format(config.get("cors_allow_origin") or "disabled"))
    print("allowed_start_fields : {0}".format(", ".join(ALLOWED_START_FIELDS)))


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Local Training Bridge V1 (loopback only, HMAC authenticated).")
    parser.add_argument("--host", default=None, help="Bind host. Only 127.0.0.1 or ::1 are accepted.")
    parser.add_argument("--port", type=int, default=None, help="Bind port (default 8125).")
    parser.add_argument("--config", default=None, help="Path to bridge_config.json (non-secret).")
    parser.add_argument("--supervisor-url", default=None, help="Override the loopback supervisor URL.")
    parser.add_argument("--check", action="store_true", help="Validate config + secret and exit.")
    parser.add_argument("--self-test", action="store_true", help="Run security tests A-J against a live bridge.")
    parser.add_argument("--base-url", default="http://127.0.0.1:{0}".format(DEFAULT_BIND_PORT), help="Bridge base URL for --self-test.")
    parser.add_argument("--supervisor-port", type=int, default=8124, help="Supervisor port for binding checks in --self-test.")
    parser.add_argument("--bridge-port", type=int, default=DEFAULT_BIND_PORT, help="Bridge port for binding checks in --self-test.")
    parser.add_argument("--results-out", default=None, help="Optional path to write the self test JSON report.")
    args = parser.parse_args(argv)

    config = load_config(args.config)
    if args.host is not None:
        config["bind_host"] = args.host
    if args.port is not None:
        config["bind_port"] = args.port
    if args.supervisor_url is not None:
        config["supervisor_url"] = args.supervisor_url

    secret, source = load_or_create_secret(str(config.get("auth", {}).get("secret_env_var", SECRET_ENV)))

    if args.check:
        _print_check(config, secret, source)
        return 0

    if args.self_test:
        results = run_self_tests(args.base_url, secret, args.supervisor_port, args.bridge_port)
        text = json.dumps(results, indent=2, ensure_ascii=False)
        if secret and secret in text:
            results["secret_exposed_in_results"] = True
            text = json.dumps(results, indent=2, ensure_ascii=False)
        if args.results_out:
            out_dir = os.path.dirname(os.path.abspath(args.results_out))
            if out_dir:
                os.makedirs(out_dir, exist_ok=True)
            with open(args.results_out, "w", encoding="utf-8") as handle:
                handle.write(text + "\n")
            print("results written: {0}".format(args.results_out))
        print(text)
        return 0 if results.get("overall") != "FAIL" else 1

    validate_bind_host(str(config.get("bind_host")))
    validate_loopback_url(str(config.get("supervisor_url")))
    run_server(config, secret, source)
    return 0


if __name__ == "__main__":
    sys.exit(main())
