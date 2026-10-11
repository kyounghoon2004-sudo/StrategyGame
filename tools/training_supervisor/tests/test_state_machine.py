"""Tests 1-3: valid transitions, illegal transitions rejected, dry-run zero commands."""
from __future__ import annotations

import os
import sys

import pytest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)

from tools.training_supervisor import state_machine as sm  # noqa: E402
from tools.training_supervisor.config import default_config  # noqa: E402
from tools.training_supervisor.supervisor import TrainingSupervisor  # noqa: E402


# ----------------------------------------------------------------------
# Test 1: valid state transitions
# ----------------------------------------------------------------------
@pytest.mark.parametrize("path", [
    (sm.IDLE, sm.PREPARE),
    (sm.PREPARE, sm.ROLLOUT),
    (sm.ROLLOUT, sm.TRAIN_BRAIN),
    (sm.TRAIN_BRAIN, sm.EVAL),
    (sm.EVAL, sm.PROMOTE),
    (sm.EVAL, sm.REJECT),
    (sm.PROMOTE, sm.COMPLETE),
    (sm.PROMOTE, sm.PREPARE),      # next iteration
    (sm.REJECT, sm.COMPLETE),
    (sm.REJECT, sm.PREPARE),       # next iteration, champion retained
    (sm.PREPARE, sm.FAILED),
    (sm.ROLLOUT, sm.FAILED),
    (sm.TRAIN_BRAIN, sm.FAILED),
    (sm.EVAL, sm.FAILED),
    (sm.PREPARE, sm.PAUSED),
    (sm.ROLLOUT, sm.PAUSED),
    (sm.TRAIN_BRAIN, sm.PAUSED),
    (sm.EVAL, sm.PAUSED),
    (sm.PAUSED, sm.STOPPED),
    (sm.FAILED, sm.STOPPED),
])
def test_valid_transitions(path):
    t = sm.validate_transition(path[0], path[1],
                               resume_target_phase=sm.PREPARE)
    assert t.from_phase == path[0]
    assert t.to_phase == path[1]


def test_full_happy_path_through_machine(tmp_path):
    cfg = default_config(project_root=str(tmp_path), artifact_root=str(tmp_path))
    cfg.run_state_path = str(tmp_path / "run_state.json")
    sup = TrainingSupervisor(cfg)
    sup.start()
    assert sup.state.current_phase == sm.PREPARE
    assert sup.run_current_phase() == sm.ROLLOUT
    assert sup.run_current_phase() == sm.TRAIN_BRAIN
    assert sup.run_current_phase() == sm.EVAL


# ----------------------------------------------------------------------
# Test 2: illegal transitions rejected (state untouched)
# ----------------------------------------------------------------------
@pytest.mark.parametrize("path", [
    (sm.IDLE, sm.ROLLOUT),         # cannot skip PREPARE
    (sm.IDLE, sm.TRAIN_BRAIN),
    (sm.IDLE, sm.COMPLETE),
    (sm.PREPARE, sm.EVAL),         # cannot skip ROLLOUT+TRAIN
    (sm.ROLLOUT, sm.EVAL),         # cannot skip TRAIN_BRAIN
    (sm.ROLLOUT, sm.PROMOTE),
    (sm.TRAIN_BRAIN, sm.PROMOTE),  # must evaluate first
    (sm.EVAL, sm.TRAIN_BRAIN),     # no backwards edges
    (sm.PROMOTE, sm.EVAL),
    (sm.REJECT, sm.ROLLOUT),
    (sm.COMPLETE, sm.IDLE),        # terminal
    (sm.COMPLETE, sm.PREPARE),     # terminal
    (sm.STOPPED, sm.IDLE),         # terminal for scaffold
    (sm.STOPPED, sm.PREPARE),
    (sm.IDLE, sm.PAUSED),
    (sm.IDLE, sm.FAILED),
    (sm.PROMOTE, sm.REJECT),
])
def test_illegal_transitions_rejected(path):
    with pytest.raises(sm.IllegalTransitionError):
        sm.validate_transition(path[0], path[1])


def test_illegal_transition_does_not_mutate_state(tmp_path):
    cfg = default_config(project_root=str(tmp_path), artifact_root=str(tmp_path))
    cfg.run_state_path = str(tmp_path / "run_state.json")
    sup = TrainingSupervisor(cfg)
    before = sup.state.current_phase
    before_transitions = len(sup.state.transitions)
    with pytest.raises(sm.IllegalTransitionError):
        sup._transition(sm.ROLLOUT, "illegal jump attempt")
    assert sup.state.current_phase == before
    assert len(sup.state.transitions) == before_transitions


def test_resume_out_of_paused_requires_target():
    # No resume target recorded -> refused even though PAUSED -> x "exists".
    with pytest.raises(sm.IllegalTransitionError):
        sm.validate_transition(sm.PAUSED, sm.ROLLOUT)
    # Resume to a phase OTHER than the recorded target -> refused.
    with pytest.raises(sm.IllegalTransitionError):
        sm.validate_transition(sm.PAUSED, sm.ROLLOUT,
                               resume_target_phase=sm.EVAL)
    # Resume target must itself be resumable.
    with pytest.raises(sm.IllegalTransitionError):
        sm.validate_transition(sm.PAUSED, sm.COMPLETE,
                               resume_target_phase=sm.COMPLETE)
    # The recorded target itself is allowed.
    t = sm.validate_transition(sm.PAUSED, sm.ROLLOUT,
                               resume_target_phase=sm.ROLLOUT)
    assert t.to_phase == sm.ROLLOUT
    # Resume-exit stop is always allowed (safe exit from PAUSED/FAILED).
    t = sm.validate_transition(sm.PAUSED, sm.STOPPED)
    assert t.to_phase == sm.STOPPED


# ----------------------------------------------------------------------
# Test 3: dry-run performs zero real phase commands
# ----------------------------------------------------------------------
def test_dry_run_performs_zero_real_commands(tmp_path):
    executed = []

    class ExplodingLaunchGuard:
        """Monkeypatched launcher: any launch attempt fails the test."""

        def __init__(self):
            self.calls = 0

        def __call__(self, spec):
            self.calls += 1
            executed.append(spec.phase)
            raise AssertionError("dry-run attempted a real command launch")

    cfg = default_config(project_root=str(tmp_path),
                         artifact_root=str(tmp_path / "artifacts"))
    cfg.run_state_path = str(tmp_path / "run_state.json")
    assert cfg.dry_run is True  # safe default

    sup = TrainingSupervisor(cfg)
    guard = ExplodingLaunchGuard()
    sup._launch_phase_process = guard.__call__

    sup.start()
    assert sup.run_current_phase() == sm.ROLLOUT
    assert sup.run_current_phase() == sm.TRAIN_BRAIN
    assert sup.run_current_phase() == sm.EVAL

    assert executed == []           # zero real commands attempted
    assert guard.calls == 0
    assert sup.state.process_ids_started_by_supervisor == []
    # ROLLOUT/TRAIN dry-run bookkeeping succeeded; EVAL awaits decision.
    assert sup.state.current_phase == sm.EVAL
    assert sup.state.last_successful_phase == sm.TRAIN_BRAIN
    outcomes = [a["outcome"] for a in sup.state.phase_attempts]
    assert outcomes == ["success", "success", "success"]
    modes = [a["mode"] for a in sup.state.phase_attempts]
    assert modes == ["DRY_RUN", "DRY_RUN", "DRY_RUN"]


def test_dry_run_default_true_in_config(tmp_path):
    cfg = default_config(project_root=str(tmp_path), artifact_root=str(tmp_path))
    assert cfg.dry_run is True
    assert cfg.to_dict()["dry_run"] is True
