"""Process ownership: track and clean up ONLY PIDs the supervisor launched.

Safety contract:
- Every subprocess the supervisor launches is recorded in
  ``process_ids_started_by_supervisor`` together with the expected
  executable / command identity captured at launch time.
- Termination requires BOTH: the PID is recorded as supervisor-owned AND
  the live process identity still matches the recorded expectation
  (executable name check where the platform allows it).
- PIDs are recycled by operating systems: identity matching is mandatory
  before any signal is sent. On any identity doubt, do nothing and report.
- Foreign processes are NEVER terminated, only reported.
"""
from __future__ import annotations

import os
import signal
import subprocess  # noqa: S404 - used only to launch harmless, supervisor-owned test children
import time
from dataclasses import dataclass, field
from typing import Dict, List, Optional


@dataclass
class OwnedProcess:
    """Bookkeeping for one supervisor-launched process."""

    pid: int
    phase: str
    run_id: str
    expected_executable: str  # lowercase basename, e.g. "python.exe"
    command_line: List[str] = field(default_factory=list)
    started_at: float = field(default_factory=time.time)
    handle: Optional[subprocess.Popen] = None  # present only for scaffold-launched children


def _basename(path: str) -> str:
    return os.path.basename(str(path)).lower()


def _get_executable_of(pid: int) -> Optional[str]:
    """Best-effort executable basename for a live PID (Windows first)."""
    # Windows: query the process image name via ctypes without extra deps.
    try:
        import ctypes

        PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
        k32 = ctypes.windll.kernel32  # type: ignore[attr-defined]
        handle = k32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, int(pid))
        if not handle:
            return None
        try:
            # Preferred: QueryFullProcessImageNameW (modern, reliable).
            size = ctypes.c_ulong(1024)
            buf = ctypes.create_unicode_buffer(size.value)
            buf_len = ctypes.c_ulong(size.value)
            if k32.QueryFullProcessImageNameW(handle, 0, buf,
                                              ctypes.byref(buf_len)):
                return _basename(buf.value)
            # Fallback: GetModuleFileNameExW with NULL module == image name.
            psapi = ctypes.windll.psapi  # type: ignore[attr-defined]
            if psapi.GetModuleFileNameExW(handle, None, buf, size):
                return _basename(buf.value)
        finally:
            k32.CloseHandle(handle)
    except Exception:
        pass
    # POSIX fallback: /proc/<pid>/exe symlink.
    try:
        target = os.readlink(f"/proc/{pid}/exe")
        return _basename(target)
    except OSError:
        return None


def _pid_alive(pid: int) -> bool:
    """SIDE-EFFECT-FREE liveness probe.

    Windows: OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION) only —
    ``os.kill(pid, 0)`` is FORBIDDEN on Windows because CPython maps it
    to TerminateProcess and would KILL the probed process.
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
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        # Exists but owned by someone else; treat as alive (conservative).
        return True
    except OSError:
        return False


class ProcessOwnershipRegistry:
    """Registry of supervisor-owned processes with safe termination.

    Registry records persist to a lock file keyed by PID (atomic
    exclusive creation, same protocol as the GPU lock). This keeps
    concurrent supervisor/test instances from cross-registering a PID:
    registration fails if another live registry instance already owns it.
    """

    def __init__(self, isolation_dir: Optional[str] = None) -> None:
        self._owned: Dict[int, OwnedProcess] = {}
        self.isolation_dir = isolation_dir

    # ------------------------------------------------------------------
    # registration
    # ------------------------------------------------------------------
    def register(self, proc: OwnedProcess) -> OwnedProcess:
        if self.isolation_dir:
            os.makedirs(self.isolation_dir, exist_ok=True)
            marker = os.path.join(self.isolation_dir,
                                  f"proc_{proc.pid}.own")
            try:
                fd = os.open(marker, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
                os.write(fd, str(proc.pid).encode("utf-8"))
                os.close(fd)
            except FileExistsError:
                raise RuntimeError(
                    f"pid {proc.pid} already registered by another "
                    "registry instance") from None
        self._owned[proc.pid] = proc
        return proc

    def register_popen(self, popen: subprocess.Popen, phase: str,
                       run_id: str) -> OwnedProcess:
        argv = [popen.args] if isinstance(popen.args, str) else list(popen.args)
        expected = _basename(argv[0]) if argv else ""
        proc = OwnedProcess(
            pid=popen.pid,
            phase=phase,
            run_id=run_id,
            expected_executable=expected,
            command_line=[str(a) for a in argv],
            handle=popen,
        )
        return self.register(proc)

    def get(self, pid: int) -> Optional[OwnedProcess]:
        return self._owned.get(int(pid))

    def all_owned(self) -> List[OwnedProcess]:
        return list(self._owned.values())

    def record_terminated(self, pid: int) -> None:
        self._owned.pop(int(pid), None)
        if self.isolation_dir:
            try:
                os.unlink(os.path.join(self.isolation_dir,
                                       f"proc_{int(pid)}.own"))
            except OSError:
                pass

    # ------------------------------------------------------------------
    # identity + safety checks
    # ------------------------------------------------------------------
    def is_supervisor_owned(self, pid: int) -> bool:
        return int(pid) in self._owned

    def identity_matches(self, pid: int) -> bool:
        """True if the live process at ``pid`` still matches the recorded
        executable identity. Unknown live identity => False (do not kill)."""
        proc = self._owned.get(int(pid))
        if proc is None:
            return False
        actual = _get_executable_of(int(pid))
        if actual is None:
            # Cannot verify identity: fail closed (do not terminate).
            return False
        return actual == proc.expected_executable.lower()

    # ------------------------------------------------------------------
    # termination
    # ------------------------------------------------------------------
    def terminate_owned(self, pid: int, timeout_s: float = 5.0) -> bool:
        """Terminate a supervisor-owned process after identity verification.

        Returns True if a termination signal was delivered to a verified
        supervisor-owned process. Never signals foreign processes.
        """
        pid = int(pid)
        if not self.is_supervisor_owned(pid):
            return False
        if not _pid_alive(pid):
            self.record_terminated(pid)
            return False
        if not self.identity_matches(pid):
            # PID reuse or unverifiable identity: refuse to signal.
            return False
        proc = self._owned[pid]
        try:
            if proc.handle is not None and proc.handle.poll() is None:
                proc.handle.terminate()
                try:
                    proc.handle.wait(timeout=timeout_s)
                except subprocess.TimeoutExpired:
                    proc.handle.kill()
                    proc.handle.wait(timeout=timeout_s)
                self.record_terminated(pid)
                return True
            # No handle (adopted record): use SIGTERM where meaningful.
            os.kill(pid, signal.SIGTERM)
            self.record_terminated(pid)
            return True
        except OSError:
            return False

    def cleanup_all(self, timeout_s: float = 5.0) -> Dict[str, List[int]]:
        """Terminate every live, verified, supervisor-owned process."""
        terminated, refused = [], []
        for proc in list(self._owned.values()):
            if _pid_alive(proc.pid) and self.terminate_owned(proc.pid, timeout_s):
                terminated.append(proc.pid)
            elif _pid_alive(proc.pid):
                refused.append(proc.pid)
            else:
                self.record_terminated(proc.pid)
        return {"terminated": terminated, "refused": refused}

    def pids_for_state(self) -> List[int]:
        return sorted(self._owned.keys())


def launch_harmless_child(argv: List[str], registry: ProcessOwnershipRegistry,
                          phase: str, run_id: str) -> OwnedProcess:
    """Launch a harmless child (used by tests / dry-run validation only).

    The caller owns the returned record; typical children are
    ``python -c "import time; time.sleep(60)"`` style no-ops.
    """
    popen = subprocess.Popen(
        argv,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return registry.register_popen(popen, phase=phase, run_id=run_id)
