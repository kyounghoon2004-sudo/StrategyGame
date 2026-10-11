#!/usr/bin/env python3
"""
Simple Local Training Automation Dashboard V1 — Local Supervisor
HTML Control Panel + Local Supervisor for StrategyGame AI Training.

Features:
- Pure Python standard library (http.server, threading, json, time).
- Bound strictly to 127.0.0.1 (Never 0.0.0.0).
- In-memory API key handling (NEVER persisted to disk, HTML, or logs).
- Real training backend seam (honestly reports PIPELINE NOT WIRED).
- Labeled SIMULATION / UI TEST mode for verification.
- Live elapsed/target/remaining wall-clock timer.
- Non-secret status persistence and crash-recovery to INTERRUPTED state.
"""

from __future__ import annotations

import argparse
import datetime
import http.server
import json
import os
import socketserver
import sys
import threading
import time
import uuid
from typing import Any, Dict, List, Optional


def find_strategy_root() -> str:
    """Locate the StrategyGame project root directory."""
    current = os.path.dirname(os.path.abspath(__file__))
    # Walk upward to find StrategyGame
    p = current
    for _ in range(5):
        if os.path.basename(p) == "StrategyGame":
            return p
        if os.path.isdir(os.path.join(p, "StrategyGame")):
            return os.path.join(p, "StrategyGame")
        parent = os.path.dirname(p)
        if parent == p:
            break
        p = parent
    return current


STRATEGY_ROOT = find_strategy_root()
ARTIFACTS_DIR = os.path.join(STRATEGY_ROOT, "artifacts")
RUN_STATUS_DIR = os.path.join(ARTIFACTS_DIR, "training_runs", "current_run")
STATUS_FILE_PATH = os.path.join(RUN_STATUS_DIR, "status.json")


def sanitize_message_for_secrets(msg: str, secret: Optional[str] = None) -> str:
    """Ensure no secret tokens appear in log strings."""
    if secret and secret in msg:
        msg = msg.replace(secret, "[REDACTED_API_KEY]")
    return msg


class TrainingRunnerInterface:
    """Clean controller seam for the training pipeline."""

    def is_wired(self) -> bool:
        raise NotImplementedError

    def get_seam_name(self) -> str:
        raise NotImplementedError


class RealTrainingRunnerSeam(TrainingRunnerInterface):
    """
    Seam for future real training backend.
    Checks repository for active self-play / RL training engines.
    """

    def is_wired(self) -> bool:
        # Verified repository discovery: No automated RL self-play runner exists yet.
        return False

    def get_seam_name(self) -> str:
        return "RealRLSelfPlayRunner"


class TrainingSupervisor:
    """
    Manages training state, timers, match progression, logging, and persistence.
    Thread-safe.
    """

    def __init__(self, status_path: str = STATUS_FILE_PATH):
        self.status_path = status_path
        self._lock = threading.RLock()
        self.real_runner = RealTrainingRunnerSeam()

        # Ephemeral secret in memory ONLY (never persisted)
        self._api_key: Optional[str] = None

        # State fields
        self.state: str = "IDLE"  # IDLE, RUNNING, PAUSED, STOPPED, ERROR, INTERRUPTED
        self.run_id: str = ""
        self.simulation_mode: bool = False
        self.started_at: Optional[str] = None
        self.start_timestamp: Optional[float] = None
        self.elapsed_seconds: float = 0.0
        self.target_seconds: float = 72 * 3600.0
        self.last_tick_time: Optional[float] = None

        # Match metrics
        self.matches_completed: int = 0
        self.wins: int = 0
        self.losses: int = 0
        self.draws: int = 0
        self.current_match: int = 0
        self.current_mode: str = "IDLE"
        self.current_phase: str = "IDLE"
        self.brain_checkpoint: str = "B0"
        self.hands_checkpoint: str = "H0"
        self.api_calls: int = 0
        self.last_error: str = ""

        # Activity log (capped at 100 entries)
        self.recent_events: List[Dict[str, str]] = []

        # Config snapshot (without secret)
        self.config: Dict[str, Any] = {
            "provider": "opencode",
            "model": "deepseek-v4.1-flash",
            "duration_hours": 72.0,
            "api_reference_percent": 5.0,
            "simulation_mode": False,
        }

        # Simulation thread handle and flags
        self._sim_thread: Optional[threading.Thread] = None
        self._stop_requested = threading.Event()
        self._pause_requested = threading.Event()

        # Crash recovery on init
        self._recover_prior_state()

    def _format_time_now(self) -> str:
        return datetime.datetime.now().strftime("%H:%M:%S")

    def _log_event(self, level: str, message: str):
        """Append to recent_events with secret sanitization."""
        clean_msg = sanitize_message_for_secrets(message, self._api_key)
        evt = {
            "timestamp": self._format_time_now(),
            "level": level,
            "message": clean_msg,
        }
        with self._lock:
            self.recent_events.append(evt)
            if len(self.recent_events) > 100:
                self.recent_events = self.recent_events[-100:]

    def _recover_prior_state(self):
        """Recover non-secret state from status.json if present."""
        if not os.path.exists(self.status_path):
            return
        try:
            with open(self.status_path, "r", encoding="utf-8") as f:
                data = json.load(f)

            prior_state = data.get("state", "IDLE")
            self.run_id = data.get("run_id", "")
            self.matches_completed = data.get("matches_completed", 0)
            self.wins = data.get("wins", 0)
            self.losses = data.get("losses", 0)
            self.draws = data.get("draws", 0)
            self.current_match = data.get("current_match", 0)
            self.current_mode = data.get("current_mode", "IDLE")
            self.current_phase = data.get("current_phase", "IDLE")
            self.brain_checkpoint = data.get("brain_checkpoint", "B0")
            self.hands_checkpoint = data.get("hands_checkpoint", "H0")
            self.elapsed_seconds = data.get("elapsed_seconds", 0.0)
            self.target_seconds = data.get("target_seconds", 72 * 3600.0)
            self.started_at = data.get("started_at")
            self.api_calls = data.get("api_calls", 0)
            self.recent_events = data.get("recent_events", [])
            if "config" in data and isinstance(data["config"], dict):
                # Ensure no api_key is in loaded config
                cfg = dict(data["config"])
                cfg.pop("api_key", None)
                self.config.update(cfg)

            # Crash recovery rule: If prior state was active (RUNNING or PAUSED),
            # mark as INTERRUPTED. Never claim active process unless verified.
            if prior_state in ("RUNNING", "PAUSED"):
                self.state = "INTERRUPTED"
                self._log_event(
                    "WARN",
                    "Supervisor restarted. Previous run marked INTERRUPTED. API key cleared from memory.",
                )
                self.save_state_to_disk()
            else:
                self.state = prior_state

        except Exception as e:
            self._log_event("ERROR", f"Failed to recover prior run state: {e}")

    def _update_elapsed_locked(self) -> None:
        """Update elapsed_seconds based on monotonic wall clock if RUNNING."""
        if self.state == "RUNNING" and self.last_tick_time is not None:
            now = time.monotonic()
            delta = now - self.last_tick_time
            if delta > 0:
                self.elapsed_seconds += delta
            self.last_tick_time = now

    def save_state_to_disk(self):
        """Persist non-secret state to status.json atomically."""
        with self._lock:
            self._update_elapsed_locked()
            rem = max(0.0, self.target_seconds - self.elapsed_seconds)
            # Build clean status dict with ZERO secrets
            payload = {
                "run_id": self.run_id,
                "state": self.state,
                "backend_wired": self.real_runner.is_wired(),
                "backend_status": (
                    "WIRED" if self.real_runner.is_wired() else "PIPELINE NOT WIRED"
                ),
                "simulation_mode": self.simulation_mode,
                "started_at": self.started_at,
                "elapsed_seconds": round(self.elapsed_seconds, 1),
                "target_seconds": round(self.target_seconds, 1),
                "remaining_seconds": round(rem, 1),
                "matches_completed": self.matches_completed,
                "wins": self.wins,
                "losses": self.losses,
                "draws": self.draws,
                "current_match": self.current_match,
                "current_mode": self.current_mode,
                "current_phase": self.current_phase,
                "brain_checkpoint": self.brain_checkpoint,
                "hands_checkpoint": self.hands_checkpoint,
                "api_calls": self.api_calls,
                "last_error": self.last_error,
                "recent_events": self.recent_events,
                "config": {
                    "provider": self.config.get("provider", "opencode"),
                    "model": self.config.get("model", "deepseek-v4.1-flash"),
                    "duration_hours": self.config.get("duration_hours", 72.0),
                    "api_reference_percent": self.config.get(
                        "api_reference_percent", 5.0
                    ),
                    "simulation_mode": self.simulation_mode,
                    "has_api_key": bool(self._api_key),
                },
                "updated_at": datetime.datetime.now().isoformat(),
            }

        try:
            os.makedirs(os.path.dirname(self.status_path), exist_ok=True)
            tmp_path = self.status_path + ".tmp"
            with open(tmp_path, "w", encoding="utf-8") as f:
                json.dump(payload, f, indent=2)
            # Atomic replace
            os.replace(tmp_path, self.status_path)
        except Exception as e:
            # Log failure without breaking supervisor
            pass

    def get_status_dict(self) -> Dict[str, Any]:
        """Generate status snapshot for GET /api/status."""
        with self._lock:
            self._update_elapsed_locked()
            rem = max(0.0, self.target_seconds - self.elapsed_seconds)

            return {
                "state": self.state,
                "backend_wired": self.real_runner.is_wired(),
                "backend_status": (
                    "WIRED" if self.real_runner.is_wired() else "PIPELINE NOT WIRED"
                ),
                "simulation_mode": self.simulation_mode,
                "started_at": self.started_at,
                "elapsed_seconds": round(self.elapsed_seconds, 1),
                "target_seconds": round(self.target_seconds, 1),
                "remaining_seconds": round(rem, 1),
                "matches_completed": self.matches_completed,
                "wins": self.wins,
                "losses": self.losses,
                "draws": self.draws,
                "current_match": self.current_match,
                "current_mode": self.current_mode,
                "current_phase": self.current_phase,
                "brain_checkpoint": self.brain_checkpoint,
                "hands_checkpoint": self.hands_checkpoint,
                "api_calls": self.api_calls,
                "last_error": self.last_error,
                "recent_events": list(self.recent_events),
                "config": {
                    "provider": self.config.get("provider", "opencode"),
                    "model": self.config.get("model", "deepseek-v4.1-flash"),
                    "duration_hours": self.config.get("duration_hours", 72.0),
                    "api_reference_percent": self.config.get(
                        "api_reference_percent", 5.0
                    ),
                    "simulation_mode": self.simulation_mode,
                    "has_api_key": bool(self._api_key),
                },
            }

    def start(self, config_in: Dict[str, Any]) -> Dict[str, Any]:
        """Start a run with configuration validation."""
        with self._lock:
            if self.state in ("RUNNING", "PAUSED"):
                return {
                    "ok": False,
                    "error": f"Training is already {self.state}. Stop the current run before starting a new one.",
                }
            old_thread = self._sim_thread
            self._stop_requested.set()

        # Join old thread outside lock to prevent deadlock
        if old_thread and old_thread.is_alive():
            old_thread.join(timeout=2.5)

        with self._lock:
            if self.state in ("RUNNING", "PAUSED"):
                return {
                    "ok": False,
                    "error": f"Training is already {self.state}. Stop the current run before starting a new one.",
                }
            self._stop_requested.clear()
            self._pause_requested.clear()

            # 1. Validation
            try:
                duration_hours = float(config_in.get("duration_hours", 0))
            except (ValueError, TypeError):
                return {
                    "ok": False,
                    "error": "Invalid duration: must be a positive number.",
                }

            if duration_hours <= 0:
                return {
                    "ok": False,
                    "error": "Duration must be greater than 0 hours.",
                }

            provider = str(config_in.get("provider", "")).strip()
            if not provider:
                return {"ok": False, "error": "Provider cannot be empty."}

            model = str(config_in.get("model", "")).strip()
            if not model:
                return {"ok": False, "error": "Model cannot be empty."}

            try:
                api_ref_pct = float(config_in.get("api_reference_percent", 5.0))
            except (ValueError, TypeError):
                api_ref_pct = 5.0

            if not (0.0 <= api_ref_pct <= 100.0):
                return {
                    "ok": False,
                    "error": "API reference games percent must be between 0 and 100.",
                }

            api_key = str(config_in.get("api_key", "")).strip()
            simulation_mode = bool(config_in.get("simulation_mode", False))

            # If API reference games > 0, require API key (unless local provider like ollama)
            if api_ref_pct > 0 and provider != "ollama":
                if not api_key and not self._api_key:
                    return {
                        "ok": False,
                        "error": "API Key is required when API reference games % > 0.",
                    }

            # 2. Check if real training backend exists
            if not simulation_mode and not self.real_runner.is_wired():
                self.last_error = "PIPELINE NOT WIRED"
                self._log_event(
                    "ERROR",
                    "Cannot start real training: PIPELINE NOT WIRED (Real backend does not exist yet).",
                )
                self.save_state_to_disk()
                return {
                    "ok": False,
                    "error": "PIPELINE NOT WIRED: Real training backend does not exist yet. Enable 'Simulation / UI Test' mode to test dashboard controls.",
                }

            # 3. Store API key strictly in memory
            if api_key:
                self._api_key = api_key

            # 4. Initialize run state for brand new run
            self.run_id = f"run_{datetime.datetime.now().strftime('%Y%m%d_%H%M%S')}_{uuid.uuid4().hex[:6]}"
            self.simulation_mode = simulation_mode
            self.started_at = datetime.datetime.now().isoformat()
            self.start_timestamp = time.time()
            self.last_tick_time = time.monotonic()
            self.elapsed_seconds = 0.0
            self.target_seconds = duration_hours * 3600.0
            self.last_error = ""

            # Reset match counters for new run
            self.matches_completed = 0
            self.wins = 0
            self.losses = 0
            self.draws = 0
            self.current_match = 0
            self.current_mode = "IDLE"
            self.current_phase = "IDLE"
            self.brain_checkpoint = "B0"
            self.hands_checkpoint = "H0"
            self.api_calls = 0

            self.config = {
                "provider": provider,
                "model": model,
                "duration_hours": duration_hours,
                "api_reference_percent": api_ref_pct,
                "simulation_mode": simulation_mode,
            }

            self.state = "RUNNING"

            mode_label = (
                "[SIMULATION / UI TEST]" if simulation_mode else "[REAL]"
            )
            self._log_event(
                "INFO",
                f"{mode_label} Run {self.run_id} started. Provider={provider}, Model={model}, Target={duration_hours:.2f}h, API-Ref={api_ref_pct:.0f}%",
            )

            # Launch simulation worker if requested
            if simulation_mode:
                self._sim_thread = threading.Thread(
                    target=self._run_simulation_worker, daemon=True
                )
                self._sim_thread.start()

            self.save_state_to_disk()
            return {
                "ok": True,
                "message": f"Run started in {mode_label} mode.",
                "run_id": self.run_id,
            }

    def pause(self) -> Dict[str, Any]:
        """Request clean pause."""
        with self._lock:
            if self.state != "RUNNING":
                return {
                    "ok": False,
                    "error": f"Cannot pause: state is {self.state}.",
                }

            # Update accumulated elapsed time before pausing
            self._update_elapsed_locked()
            self.last_tick_time = None

            self.state = "PAUSED"
            self._pause_requested.set()
            prefix = "[SIM] " if self.simulation_mode else ""
            self._log_event(
                "INFO", f"{prefix}Training PAUSED by user. State preserved."
            )
            self.save_state_to_disk()
            return {"ok": True, "state": "PAUSED"}

    def resume(self, data_in: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """Resume paused or interrupted run."""
        with self._lock:
            if self.state not in ("PAUSED", "INTERRUPTED"):
                return {
                    "ok": False,
                    "error": f"Cannot resume: state is {self.state}.",
                }

            # Handling resume from INTERRUPTED state (after server restart/crash)
            if self.state == "INTERRUPTED":
                api_key = ""
                if data_in and isinstance(data_in, dict):
                    api_key = str(data_in.get("api_key", "")).strip()
                if api_key:
                    self._api_key = api_key

                ref_pct = self.config.get("api_reference_percent", 5.0)
                sim_mode = bool(self.simulation_mode or self.config.get("simulation_mode", False))
                provider = self.config.get("provider", "opencode")

                if ref_pct > 0 and provider != "ollama" and not self._api_key:
                    return {
                        "ok": False,
                        "error": "API Key is required to resume an interrupted run when API reference games % > 0.",
                    }

                if not sim_mode and not self.real_runner.is_wired():
                    return {
                        "ok": False,
                        "error": "PIPELINE NOT WIRED: Real training backend does not exist yet.",
                    }

                self._stop_requested.clear()
                self._pause_requested.clear()
                self.state = "RUNNING"
                self.last_tick_time = time.monotonic()
                self._log_event(
                    "INFO",
                    f"Run {self.run_id} RESUMED manually from INTERRUPTED state.",
                )
                if sim_mode:
                    self._sim_thread = threading.Thread(
                        target=self._run_simulation_worker, daemon=True
                    )
                    self._sim_thread.start()

                self.save_state_to_disk()
                return {"ok": True, "state": "RUNNING"}

            # Normal resume from PAUSED
            self._update_elapsed_locked()
            self.state = "RUNNING"
            self.last_tick_time = time.monotonic()
            self._pause_requested.clear()
            prefix = "[SIM] " if self.simulation_mode else ""
            self._log_event("INFO", f"{prefix}Training RESUMED by user.")
            self.save_state_to_disk()
            return {"ok": True, "state": "RUNNING"}

    def stop(self) -> Dict[str, Any]:
        """Graceful stop."""
        with self._lock:
            if self.state in ("IDLE", "STOPPED"):
                return {
                    "ok": False,
                    "error": f"Run is already {self.state}.",
                }

            self._update_elapsed_locked()
            self.last_tick_time = None

            self.state = "STOPPED"
            self._stop_requested.set()
            self._pause_requested.clear()
            prefix = "[SIM] " if self.simulation_mode else ""
            self._log_event(
                "INFO",
                f"{prefix}Training STOPPED gracefully. Matches completed: {self.matches_completed}.",
            )
            self.save_state_to_disk()
            return {"ok": True, "state": "STOPPED"}

    def reset(self) -> Dict[str, Any]:
        """Reset state to IDLE when stopped or interrupted."""
        with self._lock:
            if self.state in ("RUNNING", "PAUSED"):
                return {
                    "ok": False,
                    "error": "Must STOP run before resetting.",
                }
            old_thread = self._sim_thread
            self._stop_requested.set()

        if old_thread and old_thread.is_alive():
            old_thread.join(timeout=2.0)

        with self._lock:
            self._stop_requested.clear()
            self._pause_requested.clear()
            self._api_key = None
            self.state = "IDLE"
            self.run_id = ""
            self.started_at = None
            self.start_timestamp = None
            self.last_tick_time = None
            self.elapsed_seconds = 0.0
            self.matches_completed = 0
            self.wins = 0
            self.losses = 0
            self.draws = 0
            self.current_match = 0
            self.current_mode = "IDLE"
            self.current_phase = "IDLE"
            self.brain_checkpoint = "B0"
            self.hands_checkpoint = "H0"
            self.api_calls = 0
            self.last_error = ""
            self._log_event("INFO", "Dashboard reset to IDLE.")
            self.save_state_to_disk()
            return {"ok": True, "state": "IDLE"}

    # =========================================================================
    # SIMULATION WORKER (Explicitly labeled SIMULATION / UI TEST)
    # =========================================================================
    def _run_simulation_worker(self):
        """
        Background simulation loop for UI testing.
        Simulates match execution, cycles phases, and honors target duration.
        """
        with self._lock:
            worker_run_id = self.run_id
        self._log_event("INFO", "[SIM] Simulation worker thread started.")
        match_idx = self.matches_completed

        while not self._stop_requested.is_set():
            # Check pause
            while self._pause_requested.is_set():
                if self._stop_requested.is_set():
                    break
                time.sleep(0.1)

            if self._stop_requested.is_set():
                break

            # Update wall-clock elapsed time and check if duration reached
            with self._lock:
                if self.run_id != worker_run_id:
                    return
                self._update_elapsed_locked()
                if self.elapsed_seconds >= self.target_seconds:
                    self._log_event(
                        "INFO",
                        "[SIM] Target duration reached. Finalizing last cycle.",
                    )
                    self.state = "STOPPED"
                    self.last_tick_time = None
                    self.save_state_to_disk()
                    break

                match_idx = self.matches_completed + 1
                ref_pct = self.config.get("api_reference_percent", 5.0)
                # Alternate or pick mode deterministically for testing
                if ref_pct > 0 and (match_idx % max(1, int(100 / ref_pct))) == 0:
                    current_mode = "LOCAL vs API"
                    self.api_calls += 1
                else:
                    current_mode = "LOCAL vs LOCAL"

                self.current_match = match_idx
                self.current_mode = current_mode
                self.current_phase = "ROLLOUT"

            self._log_event(
                "INFO",
                f"[SIM] match #{match_idx} starting ({current_mode})",
            )
            self.save_state_to_disk()

            # Simulate rollout phase (sleep in increments to allow fast stop/pause)
            for _ in range(6):
                if self._stop_requested.is_set():
                    break
                time.sleep(0.2)
            if self._stop_requested.is_set():
                break

            # Phase transition: EVAL / TRAIN
            with self._lock:
                if self.run_id != worker_run_id:
                    return
                self._update_elapsed_locked()
                self.current_phase = "EVAL"
            time.sleep(0.2)
            if self._stop_requested.is_set():
                break

            with self._lock:
                if self.run_id != worker_run_id:
                    return
                self._update_elapsed_locked()
                self.current_phase = "TRAIN BRAIN"
            time.sleep(0.2)
            if self._stop_requested.is_set():
                break

            # Match completion verdict
            with self._lock:
                if self.run_id != worker_run_id:
                    return
                self._update_elapsed_locked()
                self.matches_completed += 1
                # Semi-realistic outcome distribution
                mod = self.matches_completed % 10
                if mod in (1, 2, 4, 7, 8):
                    outcome = "RED WIN"
                    self.wins += 1
                elif mod in (0, 3, 5, 9):
                    outcome = "BLUE WIN"
                    self.losses += 1
                else:
                    outcome = "DRAW"
                    self.draws += 1

                self.current_phase = "CHECKPOINT"
                # Checkpoint progression every 5 matches
                brain_ver = f"B{max(1, (self.matches_completed // 5) + 1)}"
                hands_ver = f"H{max(1, (self.matches_completed // 10) + 1)}"
                self.brain_checkpoint = brain_ver
                self.hands_checkpoint = hands_ver

            self._log_event(
                "INFO",
                f"[SIM] match #{match_idx} complete {outcome}",
            )

            if match_idx % 5 == 0:
                self._log_event(
                    "INFO",
                    f"[SIM] checkpoint saved ({brain_ver} / {hands_ver})",
                )

            self.save_state_to_disk()

            # Small inter-match delay
            time.sleep(0.3)

        with self._lock:
            if self.run_id == worker_run_id:
                self._update_elapsed_locked()
                self.last_tick_time = None
                if self.state == "RUNNING":
                    self.state = "STOPPED"
                self.current_mode = "IDLE"
                self.current_phase = "IDLE"
                self.save_state_to_disk()
        self._log_event("INFO", "[SIM] Simulation worker exited cleanly.")


# =============================================================================
# HTTP SERVER & API HANDLER
# =============================================================================


class TrainingDashboardHandler(http.server.BaseHTTPRequestHandler):
    """
    HTTP handler serving:
    - GET / or /index.html: HTML dashboard
    - GET /api/status: supervisor status JSON
    - POST /api/start: start run
    - POST /api/pause: pause run
    - POST /api/resume: resume run
    - POST /api/stop: stop run
    - POST /api/reset: reset state
    """

    supervisor: TrainingSupervisor
    html_content: bytes

    def log_message(self, format: str, *args: Any):
        """Sanitize access logs to never print secrets."""
        # Suppress routine status polls from flooding console
        if (
            len(args) > 0
            and isinstance(args[0], str)
            and "/api/status" in args[0]
        ):
            return
        msg = format % args
        # Ensure no api_key or bearer leaked
        if hasattr(self.supervisor, "_api_key") and self.supervisor._api_key:
            msg = msg.replace(self.supervisor._api_key, "[REDACTED]")
        sys.stderr.write(f"[{self.log_date_time_string()}] {msg}\n")

    def _send_json(self, status_code: int, data: Dict[str, Any]):
        body = json.dumps(data).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        try:
            path = self.path.split("?")[0]
            if path in ("/", "/index.html", "/dashboard"):
                # Prefer latest template from disk if present
                content = load_html_template()
                if not content or len(content) < 50:
                    content = self.html_content
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(content)))
                self.send_header("Cache-Control", "no-cache")
                self.send_header("X-Content-Type-Options", "nosniff")
                self.end_headers()
                self.wfile.write(content)
            elif path == "/api/status":
                status = self.supervisor.get_status_dict()
                self._send_json(200, status)
            else:
                self._send_json(404, {"error": "Not Found"})
        except Exception as e:
            secret = getattr(self.supervisor, "_api_key", None)
            clean_err = sanitize_message_for_secrets(str(e), secret)
            self._send_json(500, {"error": f"Internal error: {clean_err}"})

    def do_POST(self):
        path = self.path.split("?")[0]
        content_length = int(self.headers.get("Content-Length", 0))
        body_bytes = self.rfile.read(content_length) if content_length > 0 else b"{}"

        try:
            req_data = (
                json.loads(body_bytes.decode("utf-8")) if body_bytes else {}
            )
        except Exception:
            self._send_json(400, {"ok": False, "error": "Invalid JSON body."})
            return

        try:
            if path == "/api/start":
                res = self.supervisor.start(req_data)
                code = 200 if res.get("ok") else 400
                self._send_json(code, res)
            elif path == "/api/pause":
                res = self.supervisor.pause()
                code = 200 if res.get("ok") else 400
                self._send_json(code, res)
            elif path == "/api/resume":
                res = self.supervisor.resume(req_data if isinstance(req_data, dict) else None)
                code = 200 if res.get("ok") else 400
                self._send_json(code, res)
            elif path == "/api/stop":
                res = self.supervisor.stop()
                code = 200 if res.get("ok") else 400
                self._send_json(code, res)
            elif path == "/api/reset":
                res = self.supervisor.reset()
                code = 200 if res.get("ok") else 400
                self._send_json(code, res)
            else:
                self._send_json(404, {"ok": False, "error": "Unknown API endpoint."})
        except Exception as e:
            secret = getattr(self.supervisor, "_api_key", None)
            clean_err = sanitize_message_for_secrets(str(e), secret)
            self._send_json(500, {"ok": False, "error": f"Internal server error: {clean_err}"})


def load_html_template() -> bytes:
    """Load training_dashboard.html from same directory or StrategyGame directory."""
    current_dir = os.path.dirname(os.path.abspath(__file__))
    html_path = os.path.join(current_dir, "training_dashboard.html")
    if os.path.exists(html_path):
        with open(html_path, "rb") as f:
            return f.read()
    alt_path = os.path.join(STRATEGY_ROOT, "tools", "training_dashboard", "training_dashboard.html")
    if os.path.exists(alt_path):
        with open(alt_path, "rb") as f:
            return f.read()
    return b"<!DOCTYPE html><html><body>Dashboard template loading...</body></html>"


def run_server(port: int = 8124, host: str = "127.0.0.1"):
    """Launch the dashboard server bound ONLY to 127.0.0.1."""
    assert host == "127.0.0.1", "SECURITY VIOLATION: Server must bind ONLY to 127.0.0.1"

    supervisor = TrainingSupervisor()
    html_bytes = load_html_template()

    # Configure handler
    handler_class = TrainingDashboardHandler
    handler_class.supervisor = supervisor
    handler_class.html_content = html_bytes

    # Ensure socket reuse
    socketserver.TCPServer.allow_reuse_address = True
    httpd = None
    selected_port = port
    for p in range(port, port + 10):
        try:
            httpd = socketserver.TCPServer((host, p), handler_class)
            selected_port = p
            break
        except OSError as e:
            print(f"Port {p} in use ({e}). Trying {p + 1}...", flush=True)

    if httpd is None:
        raise RuntimeError(f"Could not bind to {host} on any port in range {port}..{port+9}")

    port = selected_port

    print("=" * 60, flush=True)
    print("STRATEGY AI TRAINING DASHBOARD V1", flush=True)
    print(f"Backend status: {supervisor.real_runner.is_wired() and 'WIRED' or 'PIPELINE NOT WIRED'}", flush=True)
    print(f"Bound strictly to: {host}", flush=True)
    print(f"Training Dashboard:\nhttp://{host}:{port}/", flush=True)
    print("=" * 60, flush=True)

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down Training Dashboard...", flush=True)
    finally:
        supervisor.stop()
        httpd.server_close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Strategy AI Training Dashboard Server"
    )
    parser.add_argument(
        "--port",
        type=int,
        default=8124,
        help="Port to bind (default: 8124, 127.0.0.1 only)",
    )
    args = parser.parse_args()
    run_server(port=args.port)
