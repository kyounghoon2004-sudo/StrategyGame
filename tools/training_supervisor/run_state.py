"""Versioned persistent run state with atomic writes.

Schema version: 1

Persistence guarantees (scaffold contract):
- Every save writes to a unique temp file in the same directory.
- fsync on the temp file (data) and on the directory where the platform
  supports it, then an atomic ``os.replace`` onto the state path.
- Readers therefore never observe a half-written state file; a crash mid
  save leaves the previous complete state intact plus an orphan temp file.
- Load validates ``schema_version`` and refuses to silently reinterpret
  an unknown schema.
"""
from __future__ import annotations

import json
import os
import tempfile
import time
from dataclasses import asdict, dataclass, field
from typing import Any, Dict, List, Optional

SCHEMA_VERSION = 1

STATE_FILENAME = "run_state.json"


def _utcnow_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()) + "Z"


@dataclass
class PhaseAttempt:
    """Attempt bookkeeping for one phase of one iteration."""

    phase: str
    attempt: int
    started_at: str
    ended_at: Optional[str] = None
    outcome: Optional[str] = None  # "success" | "failed" | "aborted"
    detail: str = ""


@dataclass
class RunState:
    """Versioned run state, JSON-serializable via ``to_dict``/``from_dict``."""

    schema_version: int = SCHEMA_VERSION
    run_id: str = ""
    created_at: str = field(default_factory=_utcnow_iso)
    updated_at: str = field(default_factory=_utcnow_iso)

    iteration: int = 0
    current_phase: str = "IDLE"
    phase_status: str = "IDLE"  # IDLE | RUNNING | PAUSED | FAILED | SUCCESS

    base_model_id: str = ""
    base_revision: str = ""

    champion_id: Optional[str] = None
    candidate_id: Optional[str] = None

    rollout_batch_id: Optional[str] = None
    training_step_range: Optional[List[int]] = None
    evaluation_id: Optional[str] = None

    last_successful_phase: Optional[str] = None
    resume_allowed: bool = False
    failure_reason: Optional[str] = None
    # Phase a PAUSED/FAILED machine may resume into (validated).
    resume_target_phase: Optional[str] = None

    phase_attempts: List[Dict[str, Any]] = field(default_factory=list)
    artifacts: Dict[str, Any] = field(default_factory=dict)
    # Only PIDs this supervisor launched are ever recorded here.
    process_ids_started_by_supervisor: List[int] = field(default_factory=list)

    gpu_lock_owner: Optional[Dict[str, Any]] = None
    manual_stop_requested: bool = False

    checkpoint_lineage: List[Dict[str, Any]] = field(default_factory=list)
    transitions: List[Dict[str, Any]] = field(default_factory=list)
    pause_count: int = 0
    failure_count: int = 0

    # ------------------------------------------------------------------
    # serialization
    # ------------------------------------------------------------------
    def to_dict(self) -> Dict[str, Any]:
        d = asdict(self)
        return d

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "RunState":
        version = data.get("schema_version")
        if version != SCHEMA_VERSION:
            raise ValueError(
                f"run state schema_version {version!r} not understood "
                f"(expected {SCHEMA_VERSION}); refusing to load")
        known = set(cls.__dataclass_fields__.keys())  # type: ignore[attr-defined]
        filtered = {k: v for k, v in data.items() if k in known}
        state = cls(**filtered)
        return state


def new_run(run_id: str, base_model_id: str = "", base_revision: str = "",
            champion_id: Optional[str] = None) -> RunState:
    """Build a fresh RunState for a new supervised run."""
    state = RunState()
    state.run_id = run_id
    state.base_model_id = base_model_id
    state.base_revision = base_revision
    state.champion_id = champion_id
    return state


class RunStateStore:
    """Atomic persistence for a single RunState JSON file.

    Crash simulation hook: ``inject_crash_after_temp_write`` makes the next
    save abandon between temp-file write and atomic replace, to prove that
    the previous complete state survives and only a ``.tmp`` orphan remains.
    """

    def __init__(self, path: str):
        self.path = os.path.abspath(path)
        self._crash_after_temp_write = False

    # ------------------------------------------------------------------
    # atomic save
    # ------------------------------------------------------------------
    def save(self, state: RunState) -> None:
        state.updated_at = _utcnow_iso()
        directory = os.path.dirname(self.path)
        os.makedirs(directory, exist_ok=True)

        fd, tmp_path = tempfile.mkstemp(
            prefix=STATE_FILENAME + ".", suffix=".tmp", dir=directory)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(state.to_dict(), f, indent=2, sort_keys=True)
                f.flush()
                os.fsync(f.fileno())
            if self._crash_after_temp_write:
                self._crash_after_temp_write = False
                # Simulated supervisor crash BEFORE os.replace.
                raise RuntimeError("simulated crash after temp write")
            os.replace(tmp_path, self.path)
            self._fsync_directory(directory)
        except BaseException:
            # Best effort temp cleanup; the previous complete state file,
            # if any, is untouched and remains loadable.
            try:
                if os.path.exists(tmp_path):
                    os.unlink(tmp_path)
            except OSError:
                pass
            raise

    @staticmethod
    def _fsync_directory(directory: str) -> None:
        try:
            dfd = os.open(directory, os.O_RDONLY)
        except OSError:
            return
        try:
            os.fsync(dfd)
        except OSError:
            pass
        finally:
            os.close(dfd)

    # ------------------------------------------------------------------
    # load
    # ------------------------------------------------------------------
    def load(self) -> RunState:
        with open(self.path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return RunState.from_dict(data)

    def exists(self) -> bool:
        return os.path.exists(self.path)

    # ------------------------------------------------------------------
    # crash simulation (test support)
    # ------------------------------------------------------------------
    def arm_crash_after_temp_write(self) -> None:
        """Arm a one-shot simulated crash between temp write and replace."""
        self._crash_after_temp_write = True
