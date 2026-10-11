"""Tests 4-6: unwired refusal, persistence reload, atomic crash survival."""
from __future__ import annotations

import json
import os
import sys

import pytest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)

from tools.training_supervisor import state_machine as sm  # noqa: E402
from tools.training_supervisor.command_adapter import (  # noqa: E402
    PhaseCommandRegistry,
    PhaseCommandSpec,
)
from tools.training_supervisor.config import default_config  # noqa: E402
from tools.training_supervisor.run_state import RunState, RunStateStore, new_run  # noqa: E402
from tools.training_supervisor.supervisor import (  # noqa: E402
    TrainingSupervisor,
    UnwiredPhaseError,
)


def _make_sup(tmp_path, dry_run=False, specs=None):
    cfg = default_config(project_root=str(tmp_path), artifact_root=str(tmp_path))
    cfg.run_state_path = str(tmp_path / "run_state.json")
    cfg.dry_run = dry_run
    if specs:
        cfg.phase_specs = {k: v.to_dict() for k, v in specs.items()}
    return TrainingSupervisor(cfg)


# ----------------------------------------------------------------------
# Test 4: unwired phase refuses live execution
# ----------------------------------------------------------------------
def test_unwired_phase_refuses_live_execution(tmp_path):
    sup = _make_sup(tmp_path, dry_run=False)  # live requested...
    sup.start()
    sup.run_current_phase()  # PREPARE is machine-only; advances to ROLLOUT
    assert sup.state.current_phase == sm.ROLLOUT
    with pytest.raises(UnwiredPhaseError) as excinfo:
        sup.run_current_phase()  # ROLLOUT: command null -> refuse
    assert "UNWIRED" in str(excinfo.value)
    # Fail-closed: state is FAILED, not advanced.
    assert sup.state.current_phase == sm.FAILED
    assert sup.state.last_successful_phase == sm.PREPARE
    assert "UNWIRED" in sup.state.failure_reason.upper()


def test_unwired_phase_refuses_even_with_command_but_no_expected_outputs(tmp_path):
    specs = {
        "ROLLOUT": PhaseCommandSpec(
            phase="ROLLOUT",
            command="python",
            args=["-c", "print('fake rollout')"],
            expected_outputs=[],  # completeness unprovable -> still unwired
        ),
    }
    sup = _make_sup(tmp_path, dry_run=False, specs=specs)
    sup.start()
    sup.run_current_phase()
    with pytest.raises(UnwiredPhaseError):
        sup.run_current_phase()
    assert sup.state.current_phase == sm.FAILED


def test_default_registry_reports_all_phases_unwired(tmp_path):
    reg = PhaseCommandRegistry()
    assert reg.wiring_report() == {
        "ROLLOUT": "UNWIRED",
        "TRAIN_BRAIN": "UNWIRED",
        "EVAL": "UNWIRED",
    }
    for key in ("ROLLOUT", "TRAIN_BRAIN", "EVAL"):
        d = reg.get(key).to_dict()
        assert d["command"] is None
        assert d["args"] == []
        assert d["expected_outputs"] == []


# ----------------------------------------------------------------------
# Test 5: state persists/reloads
# ----------------------------------------------------------------------
def test_state_persists_and_reloads(tmp_path):
    cfg = default_config(project_root=str(tmp_path), artifact_root=str(tmp_path))
    cfg.run_state_path = str(tmp_path / "run_state.json")
    sup = TrainingSupervisor(cfg)
    run_id = sup.run_id
    sup.start()
    sup.run_current_phase()  # machine-only PREPARE -> ROLLOUT (iteration=1)
    sup.record_rollout_batch("batch-042")
    assert sup.state.iteration == 1

    # Simulate process crash: fresh supervisor instance over the same state.
    sup2 = TrainingSupervisor(cfg, run_id=run_id)
    assert sup2.state.current_phase == sm.ROLLOUT
    assert sup2.state.rollout_batch_id == "batch-042"
    assert sup2.state.iteration == 1
    assert len(sup2.state.transitions) >= 2

    # Schema guard: unknown schema version refuses to load.
    bad = json.loads((tmp_path / "run_state.json").read_text(encoding="utf-8"))
    bad["schema_version"] = 999
    (tmp_path / "run_state_bad.json").write_text(
        json.dumps(bad), encoding="utf-8")
    bad_store = RunStateStore(str(tmp_path / "run_state_bad.json"))
    with pytest.raises(ValueError):
        bad_store.load()


def test_roundtrip_preserves_all_required_fields(tmp_path):
    st = new_run("run-1", base_model_id="B0", base_revision="rev0",
                 champion_id="C0")
    st.iteration = 3
    st.current_phase = "ROLLOUT"
    st.phase_status = "RUNNING"
    st.candidate_id = "T3"
    st.rollout_batch_id = "b9"
    st.training_step_range = [100, 200]
    st.evaluation_id = "e5"
    st.last_successful_phase = "PREPARE"
    st.resume_allowed = True
    st.failure_reason = "synthetic"
    st.phase_attempts = [{"phase": "ROLLOUT", "attempt": 1}]
    st.artifacts = {"rollout": "raw/rollout_b9.json"}
    st.process_ids_started_by_supervisor = [4242]
    st.gpu_lock_owner = {"path": "test.lock", "payload": {"pid": 1}}
    st.manual_stop_requested = False

    store = RunStateStore(str(tmp_path / "s.json"))
    store.save(st)
    loaded = store.load()

    for field in ("schema_version", "run_id", "created_at", "updated_at",
                  "iteration", "current_phase", "phase_status",
                  "base_model_id", "base_revision", "champion_id",
                  "candidate_id", "rollout_batch_id", "training_step_range",
                  "evaluation_id", "last_successful_phase", "resume_allowed",
                  "failure_reason", "phase_attempts", "artifacts",
                  "process_ids_started_by_supervisor", "gpu_lock_owner",
                  "manual_stop_requested"):
        assert getattr(loaded, field) == getattr(st, field), field


# ----------------------------------------------------------------------
# Test 6: atomic save survives simulated interruption
# ----------------------------------------------------------------------
def test_atomic_save_survives_simulated_crash(tmp_path):
    path = str(tmp_path / "run_state.json")
    store = RunStateStore(path)
    st1 = new_run("run-atomic")
    st1.current_phase = "ROLLOUT"
    store.save(st1)
    before = json.loads(open(path, encoding="utf-8").read())

    # Arm a crash between temp write and atomic replace.
    store.arm_crash_after_temp_write()
    st2 = new_run("run-atomic")
    st2.current_phase = "TRAIN_BRAIN"  # would-be new state
    with pytest.raises(RuntimeError, match="simulated crash"):
        store.save(st2)

    # Previous complete state survives; no half-written state file.
    after = json.loads(open(path, encoding="utf-8").read())
    assert after == before
    assert after["current_phase"] == "ROLLOUT"
    # Orphan temp files are cleaned up on the failure path.
    leftovers = [f for f in os.listdir(tmp_path) if f.endswith(".tmp")]
    assert leftovers == []


def test_temp_write_never_visible_as_state(tmp_path):
    """Unique temp naming: concurrent readers can never mistake a temp
    file for the state file (state filename is exact, temps are prefixed
    and suffixed)."""
    store = RunStateStore(str(tmp_path / "run_state.json"))
    store.save(new_run("r1"))
    names = os.listdir(tmp_path)
    assert "run_state.json" in names
    non_state = [n for n in names if n != "run_state.json"
                 and n.startswith("run_state.json")]
    # any stragglers must be clearly temporary, never the state path itself
    for n in non_state:
        assert n.endswith(".tmp")
