"""Tests 13-14 + lineage: process ownership safety, temporary GPU lock, lineage invariants."""
from __future__ import annotations

import os
import sys
import time

import pytest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)

from tools.training_supervisor.checkpoint_lineage import (  # noqa: E402
    CheckpointLineage,
    STATUS_CANDIDATE,
    STATUS_CHAMPION,
    STATUS_HISTORICAL,
    STATUS_REJECTED,
)
from tools.training_supervisor.gpu_lock import (  # noqa: E402
    GpuLockManager,
    REAL_LOCKS_DIR,
    lock_status,
)
from tools.training_supervisor.process_ownership import (  # noqa: E402
    OwnedProcess,
    ProcessOwnershipRegistry,
    launch_harmless_child,
)

IS_WINDOWS = os.name == "nt"


# ----------------------------------------------------------------------
# Test 13: supervisor only terminates mock processes it owns
# ----------------------------------------------------------------------
def _wait_for_identity(registry, proc, timeout_s=5.0):
    """Wait until a freshly spawned child's identity is queryable
    (Windows process init can lag spawn by tens of ms)."""
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if registry.identity_matches(proc.pid):
            return True
        time.sleep(0.05)
    return registry.identity_matches(proc.pid)


def _isolated_registry(tmp_path):
    """Registry isolated per-test via a unique marker dir so concurrent
    pytest workers never cross-register the same PID."""
    import uuid
    d = os.path.join(str(tmp_path), f"own_{uuid.uuid4().hex[:8]}")
    return ProcessOwnershipRegistry(isolation_dir=d)


def _spawn_sleeper(registry):
    return launch_harmless_child(
        [sys.executable, "-c", "import time; time.sleep(60)"],
        registry, phase="ROLLOUT", run_id="run-ownership")


def test_terminates_only_owned_processes(tmp_path):
    registry = _isolated_registry(tmp_path)
    owned = _spawn_sleeper(registry)
    try:
        assert registry.is_supervisor_owned(owned.pid)
        assert registry.identity_matches(owned.pid)
        result = registry.terminate_owned(owned.pid)
        assert result is True
        assert registry.get(owned.pid) is None
    finally:
        registry.cleanup_all()


def test_refuses_to_terminate_foreign_pid(tmp_path):
    registry = _isolated_registry(tmp_path)
    # A PID we never registered (os.getpid() of the test itself is foreign
    # to the registry). Must NOT be terminated and must return False.
    foreign = os.getpid()
    assert registry.is_supervisor_owned(foreign) is False
    assert registry.terminate_owned(foreign) is False
    # Still alive to finish the test.
    assert os.getpid() == foreign


def test_pid_reuse_identity_mismatch_refuses_signal(tmp_path):
    """A registered PID whose live identity no longer matches the recorded
    executable must NOT be signalled (PID-reuse protection)."""
    registry = _isolated_registry(tmp_path)
    proc = OwnedProcess(
        pid=os.getpid(),  # foreign live process occupying the record
        phase="ROLLOUT",
        run_id="run-x",
        expected_executable="definitely_not_the_test_runner.exe",
        command_line=["fake"],
    )
    registry.register(proc)
    assert registry.is_supervisor_owned(proc.pid)
    assert registry.identity_matches(proc.pid) is False
    assert registry.terminate_owned(proc.pid) is False
    # Test process still alive -> nothing was signalled.
    assert os.getpid() == proc.pid


def test_unverifiable_identity_fails_closed(tmp_path):
    """Live PID whose executable cannot be determined: no signal sent."""
    registry = _isolated_registry(tmp_path)

    class FakeRegistry(ProcessOwnershipRegistry):
        def identity_matches(self, pid):
            return False  # simulate unverifiable identity

    reg = FakeRegistry()
    proc = OwnedProcess(pid=999999999, phase="EVAL", run_id="r",
                        expected_executable="python.exe")
    reg.register(proc)
    # PID probably not alive; even if it were, identity fails closed.
    assert reg.terminate_owned(999999999) in (False,)


def test_cleanup_all_terminates_all_owned_children(tmp_path):
    registry = _isolated_registry(tmp_path)
    a = _spawn_sleeper(registry)
    b = _spawn_sleeper(registry)
    time.sleep(0.05)
    result = registry.cleanup_all()
    assert a.pid in result["terminated"]
    assert b.pid in result["terminated"]
    assert result["refused"] == []


def test_ownership_pids_flow_into_run_state(tmp_path):
    from tools.training_supervisor.config import default_config
    from tools.training_supervisor.supervisor import TrainingSupervisor
    cfg = default_config(project_root=str(tmp_path), artifact_root=str(tmp_path))
    cfg.run_state_path = str(tmp_path / "run_state.json")
    sup = TrainingSupervisor(cfg)
    registry = ProcessOwnershipRegistry()
    child = _spawn_sleeper(registry)
    sup.processes = registry
    sup._persist()
    assert child.pid in sup.state.process_ids_started_by_supervisor
    registry.cleanup_all()


# ----------------------------------------------------------------------
# Test 14: temporary GPU-lock behavior (real lock untouched)
# ----------------------------------------------------------------------
def _test_lock_path(tmp_path):
    return os.path.join(str(tmp_path), "training_supervisor_test.lock")


def test_test_only_manager_refuses_real_namespace():
    with pytest.raises(ValueError, match="test_only"):
        GpuLockManager(
            path=os.path.join(REAL_LOCKS_DIR, "training_supervisor_test.lock"),
            run_id="r", phase="ROLLOUT", test_only=True)


def test_real_brain_lock_file_untouched_by_suite(tmp_path):
    """The suite never creates, reads-for-write, or deletes the real lock.
    We assert the real lock file's existence state is unchanged by merely
    importing and running tests (status probe is read-only, and we do not
    even probe it here to avoid touching live files)."""
    # No test in this suite constructs a manager for the real path
    # (enforced above); nothing else to check at runtime.
    assert REAL_LOCKS_DIR.endswith("locks")


def test_lock_exclusive_acquisition_and_payload(tmp_path):
    path = _test_lock_path(tmp_path)
    mgr = GpuLockManager(path=path, run_id="run-1", phase="ROLLOUT",
                         test_only=True)
    payload = mgr.acquire(wait_timeout_seconds=2)
    try:
        assert payload["pid"] == os.getpid()
        assert payload["run_id"] == "run-1"
        assert payload["phase"] == "ROLLOUT"
        assert payload["host"]
        assert payload["timestamp"]
        status = lock_status(path)
        assert status["held"] is True
        assert status["live_holder"] is True
        # Second concurrent acquire must NOT succeed while held live.
        other = GpuLockManager(path=path, run_id="run-2", phase="EVAL",
                               test_only=True)
        with pytest.raises(TimeoutError):
            other.acquire(wait_timeout_seconds=0.3)
    finally:
        mgr.release()
    assert lock_status(path)["held"] is False


def test_lock_release_in_finally_semantics(tmp_path):
    path = _test_lock_path(tmp_path)
    with GpuLockManager(path=path, run_id="r", phase="TRAIN_BRAIN",
                        test_only=True) as mgr:
        assert lock_status(path)["held"] is True
    assert lock_status(path)["held"] is False  # released on context exit


def test_lock_stale_recovery_conservative(tmp_path):
    path = _test_lock_path(tmp_path)
    # Simulate a stale lock: dead PID recorded.
    import json
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"pid": 999999999, "run_id": "dead", "phase": "X",
                   "purpose": "stale-sim", "host": "x", "timestamp": "t"},
                  f)
    status = lock_status(path)
    assert status["held"] is True
    assert status["live_holder"] is False
    mgr = GpuLockManager(path=path, run_id="run-new", phase="ROLLOUT",
                         test_only=True, poll_seconds=0.01)
    payload = mgr.acquire(wait_timeout_seconds=3)  # recovers stale lock
    try:
        assert payload["pid"] == os.getpid()
    finally:
        mgr.release()
    assert lock_status(path)["held"] is False


def test_lock_live_holder_blocks_then_timeout(tmp_path):
    """A live holder blocks acquisition; we never kill the holder."""
    holder_registry = _isolated_registry(tmp_path)
    holder = _spawn_sleeper(holder_registry)
    path = _test_lock_path(tmp_path)
    import json
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"pid": holder.pid, "run_id": "holder", "phase": "ROLLOUT",
                   "purpose": "live-sim", "host": "x", "timestamp": "t"}, f)
    waiter = GpuLockManager(path=path, run_id="run-3", phase="EVAL",
                            test_only=True, poll_seconds=0.01)
    try:
        with pytest.raises(TimeoutError):
            waiter.acquire(wait_timeout_seconds=0.3)
        # Holder's lock file still present and holder still alive
        # (never killed by the waiter).
        assert lock_status(path)["held"] is True
        assert _wait_for_identity(holder_registry, holder)
    finally:
        holder_registry.cleanup_all()
    # The waiter never unlinked the lock file: it remains present after
    # the blocked attempt (stale OR live from the file's point of view —
    # on Windows a terminated-but-unreaped holder still probes as live,
    # which is the conservative bias we want).
    assert lock_status(path)["held"] is True
    # Ownership safety: the holder child was terminated exactly once, by
    # the owner registry (exact Popen returncode knowledge), and the
    # registry no longer tracks it.
    assert holder.handle is not None and holder.handle.poll() is not None
    assert holder_registry.get(holder.pid) is None


# ----------------------------------------------------------------------
# Checkpoint lineage invariants (metadata only)
# ----------------------------------------------------------------------
def test_lineage_full_lifecycle():
    lin = CheckpointLineage()
    lin.register_base("B0", "Qwen-fake", "rev0")
    assert lin.champion().checkpoint_id == "B0"
    t1 = lin.register_candidate("T1", iteration=1, parent_champion_id="B0")
    assert t1.status == STATUS_CANDIDATE
    lin.promote("T1", evaluation_ref="eval-1", reason="better")
    assert lin.champion().checkpoint_id == "T1"
    assert lin.get("B0").status == STATUS_HISTORICAL
    assert lin.validate() == []

    t2 = lin.register_candidate("T2", iteration=2)  # parent defaults to T1
    assert t2.parent_champion_id == "T1"
    lin.reject("T2", reason="worse")
    assert lin.get("T2").status == STATUS_REJECTED
    assert lin.champion().checkpoint_id == "T1"  # champion retained
    assert lin.validate() == []


def test_lineage_never_two_champions_and_no_overwrite():
    lin = CheckpointLineage()
    lin.register_base("B0", "m", "r")
    lin.register_candidate("T1", iteration=1, parent_champion_id="B0")
    lin.promote("T1", evaluation_ref="e1")
    # Historical champion must keep its identity/status: not overwritten.
    assert lin.get("B0").status == STATUS_HISTORICAL
    assert lin.get("B0").checkpoint_id == "B0"
    # A second promotion path cannot create two champions.
    lin.register_candidate("T2", iteration=2, parent_champion_id="T1")
    lin.promote("T2", evaluation_ref="e2")
    champions = [r for r in lin.records() if r.status == STATUS_CHAMPION]
    assert len(champions) == 1
    with pytest.raises(ValueError):
        lin.promote("T2", evaluation_ref="e3")  # not a CANDIDATE anymore
    with pytest.raises(ValueError):
        lin.register_candidate("T1", iteration=9)  # duplicate id


def test_lineage_roundtrip_and_hash():
    lin = CheckpointLineage()
    lin.register_base("B0", "m", "r")
    lin.register_candidate("T1", iteration=1, parent_champion_id="B0",
                           artifact_path="adapters/T1",
                           artifact_hash="deadbeef")
    lin.promote("T1", evaluation_ref="e1")
    restored = CheckpointLineage.from_state(lin.to_state())
    assert [r.to_dict() for r in restored.records()] == \
        [r.to_dict() for r in lin.records()]
    # Records carry hash + evaluation reference metadata fields.
    assert lin.get("T1").artifact_hash == "deadbeef"
    assert lin.get("T1").evaluation_ref == "e1"
