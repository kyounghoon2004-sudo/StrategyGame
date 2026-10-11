"""GPU lock abstraction — mirrors the established project protocol.

Discovered convention (from brain_shootout / Phi / Spark / Qwen3-8B prep
gates): exclusive acquisition via atomic exclusive file creation
(``os.open(O_CREAT | O_EXCL)``) under ``D:\\StrategyAI\\locks\\``; payload
records PID / model / purpose / host / timestamp; a live holder blocks
(wait and poll, never terminate); a stale lock (dead PID) is recovered
conservatively; release only by the owner, in ``finally``.

This scaffold NEVER touches the real ``D:\\StrategyAI\\locks\\`` namespace
in tests: a ``test_only=True`` manager pointed at the real namespace
refuses acquire/release. All scaffold tests exercise temporary test locks
only. No CUDA, no model loading, no memory reservation: file ops only.
"""
from __future__ import annotations

import json
import os
import socket
import time
from datetime import datetime, timezone
from typing import Any, Dict, Optional

#: Real lock namespace (discovered). Production wiring will use this;
#: scaffold tests must NOT (managers run in test_only mode + tmp paths).
REAL_LOCKS_DIR = r"D:\StrategyAI\locks"
REAL_BRAIN_LOCK_NAME = "brain_shootout_gpu.lock"


def _utcnow_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def pid_alive(pid: int) -> bool:
    """Conservative, SIDE-EFFECT-FREE liveness probe.

    Windows: uses OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION) only.
    NOTE: ``os.kill(pid, 0)`` must NEVER be used on Windows — CPython
    implements it via TerminateProcess, which would KILL the probed
    holder (a live GPU-lock holder must never be disturbed).
    """
    if pid is None or int(pid) <= 0:
        return False
    pid = int(pid)
    if os.name == "nt":
        try:
            import ctypes
            PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
            k32 = ctypes.windll.kernel32  # type: ignore[attr-defined]
            handle = k32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,
                                     False, pid)
            if not handle:
                return False
            k32.CloseHandle(handle)
            return True
        except Exception:
            return False
    # POSIX: signal 0 is a true no-op liveness probe.
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False


def read_lock_payload(path: str) -> Optional[Dict[str, Any]]:
    """Read a lock file's JSON payload; None if unreadable/corrupt."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else None
    except (OSError, ValueError):
        return None


def lock_status(path: str) -> Dict[str, Any]:
    """Non-acquiring status probe: held? live holder? payload?"""
    payload = read_lock_payload(path)
    if payload is None:
        return {"held": False, "live_holder": False, "info": None}
    pid = payload.get("pid", -1)
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        pid = -1
    return {
        "held": True,
        "live_holder": pid_alive(pid),
        "info": payload,
    }


class GpuLockManager:
    """Exclusive, conservative GPU lock over one file path.

    ``test_only=True`` (scaffold default) refuses to operate on the real
    ``D:\\StrategyAI\\locks`` namespace, forcing tests onto temp paths.
    """

    def __init__(self, path: str, run_id: str, phase: str,
                 purpose: str = "training_supervisor_scaffold_v0",
                 poll_seconds: float = 0.05,
                 test_only: bool = True) -> None:
        self.path = os.path.abspath(path)
        self.run_id = run_id
        self.phase = phase
        self.purpose = purpose
        self.poll_seconds = poll_seconds
        self.test_only = test_only
        self.payload: Optional[Dict[str, Any]] = None
        self._validate_path_policy()

    # ------------------------------------------------------------------
    def _validate_path_policy(self) -> None:
        real_dir = os.path.abspath(REAL_LOCKS_DIR)
        if self.test_only and os.path.dirname(self.path) == real_dir:
            raise ValueError(
                "test_only GpuLockManager refuses the real D:\\StrategyAI\\locks "
                "namespace; use a temporary test lock path")

    # ------------------------------------------------------------------
    def acquire(self, wait_timeout_seconds: float = 30.0) -> Dict[str, Any]:
        """Acquire exclusively; block while a live holder exists.

        Conservative stale rule: a lock whose holder PID is dead is removed
        only after it has been observed stale on two consecutive polls.
        """
        deadline = time.monotonic() + wait_timeout_seconds
        stale_seen = False
        while True:
            try:
                fd = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            except FileExistsError:
                info = read_lock_payload(self.path)
                if info is None:
                    # Corrupt/empty lock file: conservative — treat as
                    # stale candidate; require double observation too.
                    if stale_seen and time.monotonic() < deadline:
                        try:
                            os.unlink(self.path)
                        except OSError:
                            pass
                        stale_seen = False
                        continue
                    stale_seen = True
                    time.sleep(self.poll_seconds)
                else:
                    holder_pid = info.get("pid", -1)
                    try:
                        holder_pid = int(holder_pid)
                    except (TypeError, ValueError):
                        holder_pid = -1
                    if pid_alive(holder_pid):
                        if time.monotonic() > deadline:
                            raise TimeoutError(
                                f"GPU lock at {self.path} held by live pid "
                                f"{holder_pid} ({info.get('purpose')}) beyond "
                                f"{wait_timeout_seconds}s")
                        time.sleep(self.poll_seconds)
                        stale_seen = False
                    else:
                        if stale_seen:
                            try:
                                os.unlink(self.path)
                            except OSError:
                                pass
                            stale_seen = False
                            continue
                        stale_seen = True
                        time.sleep(self.poll_seconds)
                if time.monotonic() > deadline:
                    raise TimeoutError(
                        f"GPU lock at {self.path} unavailable beyond "
                        f"{wait_timeout_seconds}s")
                continue
            else:
                payload = {
                    "pid": os.getpid(),
                    "run_id": self.run_id,
                    "phase": self.phase,
                    "purpose": self.purpose,
                    "host": socket.gethostname(),
                    "timestamp": _utcnow_iso(),
                }
                with os.fdopen(fd, "w", encoding="utf-8") as f:
                    json.dump(payload, f, indent=1)
                    f.flush()
                    os.fsync(f.fileno())
                self.payload = payload
                return payload

    # ------------------------------------------------------------------
    def release(self) -> None:
        """Release the lock only if we still own it (payload PID match)."""
        if self.payload is None:
            return
        try:
            info = read_lock_payload(self.path) or {}
            if info.get("pid") == self.payload.get("pid"):
                os.unlink(self.path)
        except OSError:
            pass
        finally:
            self.payload = None

    # ------------------------------------------------------------------
    def __enter__(self) -> "GpuLockManager":
        self.acquire()
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        # Release in finally semantics: always attempt release on exit.
        self.release()
