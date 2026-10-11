"""Tests 7-12: failure non-advance, eval gating, transactional promote/reject, resume rules."""
from __future__ import annotations

import os
import sys

import pytest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)

from tools.training_supervisor import state_machine as sm  # noqa: E402
from tools.training_supervisor.checkpoint_lineage import (  # noqa: E402
    CheckpointLineage,
    STATUS_CHAMPION,
    STATUS_CANDIDATE,
    STATUS_HISTORICAL,
    STATUS_REJECTED,
)
from tools.training_supervisor.config import default_config  # noqa: E402
from tools.training_supervisor.supervisor import (  # noqa: E402
    PhaseFailure,
    TrainingSupervisor,
    UnwiredPhaseError,
)


def _make_sup(tmp_path, dry_run=True):
    cfg = default_config(project_root=str(tmp_path), artifact_root=str(tmp_path))
    cfg.run_state_path = str(tmp_path / "run_state.json")
    cfg.dry_run = dry_run
    return TrainingSupervisor(cfg)


def _advance_to(sup, phase):
    """Drive the machine (dry-run) until current_phase == phase."""
    path = [sm.PREPARE, sm.ROLLOUT, sm.TRAIN_BRAIN, sm.EVAL]
    for target in path:
        if sup.state.current_phase == phase:
            return
        sup.run_current_phase()
    assert sup.state.current_phase == phase


# ----------------------------------------------------------------------
# Test 7: failed ROLLOUT does not advance
# ----------------------------------------------------------------------
def test_failed_rollout_does_not_advance(tmp_path):
    sup = _make_sup(tmp_path, dry_run=False)  # live mode, all unwired
    sup.start()
    sup.run_current_phase()  # PREPARE machine-only -> ROLLOUT
    assert sup.state.current_phase == sm.ROLLOUT
    with pytest.raises(UnwiredPhaseError):
        sup.run_current_phase()
    assert sup.state.current_phase == sm.FAILED
    # Not advanced: TRAIN_BRAIN never reached.
    assert sup.state.last_successful_phase == sm.PREPARE
    assert sup.state.resume_target_phase == sm.ROLLOUT
    assert sup.state.resume_allowed is True


# ----------------------------------------------------------------------
# Test 8: failed TRAIN_BRAIN does not advance to EVAL
# ----------------------------------------------------------------------
def test_failed_train_does_not_reach_eval(tmp_path):
    """A live TRAIN failure at any point before checkpoint commit leaves
    the candidate untrained and the machine in FAILED — never EVAL."""
    sup = _make_sup(tmp_path, dry_run=False)
    # Wire a fake TRAIN that exits nonzero (harmless fake child process).
    from tools.training_supervisor.command_adapter import PhaseCommandSpec
    sup.phase_registry.set(PhaseCommandSpec(
        phase="TRAIN_BRAIN",
        command=sys.executable,
        args=["-c", "import sys; sys.exit(3)"],
        expected_outputs=["candidate_manifest.json"],
    ))
    sup.phase_registry.set(PhaseCommandSpec(
        phase="ROLLOUT",
        command=sys.executable,
        args=["-c", "print('fake rollout success')"],
        expected_outputs=["rollout_manifest.json"],
    ))
    sup.manifest_checker = lambda phase, spec, ctx: False  # fail closed
    sup.start()
    sup.run_current_phase()   # machine-only PREPARE -> ROLLOUT
    # ROLLOUT runs (fake child exits 0) but manifest cannot prove outputs:
    # phase must fail rather than silently advance.
    with pytest.raises(PhaseFailure):
        sup.run_current_phase()
    assert sup.state.current_phase == sm.FAILED
    assert sup.state.last_successful_phase == sm.PREPARE

    # Direct train-failure semantics: from a TRAIN state, a failing child
    # (nonzero exit) must land in FAILED, not EVAL.
    sup.state.current_phase = sm.TRAIN_BRAIN  # synthetic repair for the test
    sup.state.phase_status = sm.TRAIN_BRAIN
    sup.state.resume_allowed = False
    sup.state.resume_target_phase = None
    with pytest.raises(PhaseFailure):
        sup.run_current_phase()
    assert sup.state.current_phase == sm.FAILED
    assert sup.state.evaluation_id is None  # never reached EVAL


# ----------------------------------------------------------------------
# Test 9: failed / inconclusive EVAL never promotes
# ----------------------------------------------------------------------
def test_inconclusive_eval_never_promotes(tmp_path):
    sup = _make_sup(tmp_path)
    sup.lineage.register_base("B0", "Qwen-fake", "rev0")
    sup.lineage.register_candidate("T1", iteration=1, parent_champion_id="B0")
    sup.state.champion_id = "B0"
    sup.state.candidate_id = "T1"
    sup.start()
    _advance_to(sup, sm.EVAL)

    result = sup.apply_eval_decision({
        "decision": "INCONCLUSIVE",
        "candidate_id": "T1",
        "evaluation_id": "eval-1",
        "metrics": {},
        "reason": "evaluator crashed mid-scoring",
    })
    assert result == sm.FAILED
    assert sup.state.current_phase == sm.FAILED
    # Champion unchanged; candidate NOT promoted.
    assert sup.lineage.champion().checkpoint_id == "B0"
    assert sup.lineage.get("T1").status == STATUS_CANDIDATE
    assert sup.state.champion_id == "B0"
    assert sup.state.resume_target_phase == sm.EVAL


def test_malformed_eval_decision_refused(tmp_path):
    sup = _make_sup(tmp_path)
    sup.start()
    _advance_to(sup, sm.EVAL)
    from tools.training_supervisor.promotion import DecisionError
    for bad in (
        {"decision": "SORT_OF_OK", "candidate_id": "T1",
         "evaluation_id": "e1"},
        {"decision": "PROMOTE", "evaluation_id": "e1"},       # no candidate
        {"decision": "PROMOTE", "candidate_id": "T1"},        # no eval id
        "not-a-dict",
        {"decision": "PROMOTE", "candidate_id": "T1",
         "evaluation_id": "e1", "metrics": "not-a-dict"},
    ):
        with pytest.raises(DecisionError):
            sup.apply_eval_decision(bad)
    assert sup.state.current_phase == sm.EVAL  # unchanged


def test_eval_decision_only_from_eval(tmp_path):
    sup = _make_sup(tmp_path)
    sup.start()  # PREPARE
    with pytest.raises(sm.IllegalTransitionError):
        sup.apply_eval_decision({
            "decision": "PROMOTE", "candidate_id": "T1",
            "evaluation_id": "e1"})


# ----------------------------------------------------------------------
# Test 10: PROMOTE updates lineage transactionally
# ----------------------------------------------------------------------
def test_promote_transactional_with_rollback(tmp_path):
    sup = _make_sup(tmp_path)
    sup.lineage.register_base("B0", "Qwen-fake", "rev0")
    sup.lineage.register_candidate("T1", iteration=1, parent_champion_id="B0")
    sup.state.champion_id = "B0"
    sup.state.candidate_id = "T1"
    sup.start()
    _advance_to(sup, sm.EVAL)

    result = sup.apply_eval_decision({
        "decision": "PROMOTE",
        "candidate_id": "T1",
        "champion_id": "B0",
        "evaluation_id": "eval-9",
        "metrics": {"win_rate": 0.61},
        "reason": "synthetic evaluator decision",
    })
    assert result == sm.PROMOTE
    assert sup.state.current_phase == sm.PROMOTE
    assert sup.lineage.champion().checkpoint_id == "T1"
    assert sup.lineage.get("B0").status == STATUS_HISTORICAL  # not overwritten
    assert sup.lineage.get("T1").evaluation_ref == "eval-9"
    assert sup.lineage.validate() == []
    assert sup.state.champion_id == "T1"

    # Persistence round-trip keeps the promoted lineage consistent.
    sup2 = TrainingSupervisor(sup.config, run_id=sup.run_id)
    assert sup2.lineage.champion().checkpoint_id == "T1"
    assert sup2.lineage.validate() == []


def test_promote_rolls_back_when_persistence_fails(tmp_path):
    sup = _make_sup(tmp_path)
    sup.lineage.register_base("B0", "Qwen-fake", "rev0")
    sup.lineage.register_candidate("T1", iteration=1, parent_champion_id="B0")
    sup.state.champion_id = "B0"

    # Force the post-promotion persist to fail -> transactional rollback.
    def exploding_persist():
        raise RuntimeError("disk full (simulated)")

    sup.start()
    _advance_to(sup, sm.EVAL)
    sup._persist = exploding_persist
    with pytest.raises(PhaseFailure, match="rolled back"):
        sup.apply_eval_decision({
            "decision": "PROMOTE", "candidate_id": "T1",
            "evaluation_id": "eval-1", "reason": "x"})
    # Rollback: champion retained, candidate back to CANDIDATE.
    assert sup.lineage.champion().checkpoint_id == "B0"
    assert sup.lineage.get("T1").status == STATUS_CANDIDATE


# ----------------------------------------------------------------------
# Test 11: REJECT retains champion
# ----------------------------------------------------------------------
def test_reject_retains_champion(tmp_path):
    sup = _make_sup(tmp_path)
    sup.lineage.register_base("B0", "Qwen-fake", "rev0")
    sup.lineage.register_candidate("T1", iteration=1, parent_champion_id="B0")
    sup.state.champion_id = "B0"
    sup.state.candidate_id = "T1"
    sup.start()
    _advance_to(sup, sm.EVAL)

    result = sup.apply_eval_decision({
        "decision": "REJECT",
        "candidate_id": "T1",
        "champion_id": "B0",
        "evaluation_id": "eval-2",
        "metrics": {"win_rate": 0.40},
        "reason": "weaker than champion",
    })
    assert result == sm.REJECT
    assert sup.state.current_phase == sm.REJECT
    assert sup.lineage.champion().checkpoint_id == "B0"
    assert sup.lineage.get("T1").status == STATUS_REJECTED
    assert sup.lineage.get("T1").rejection_reason == "weaker than champion"
    assert sup.state.champion_id == "B0"


def test_reject_unknown_candidate_is_refused(tmp_path):
    sup = _make_sup(tmp_path)
    sup.start()
    _advance_to(sup, sm.EVAL)
    with pytest.raises(PhaseFailure):
        sup.apply_eval_decision({
            "decision": "PROMOTE", "candidate_id": "GHOST",
            "evaluation_id": "e1"})


# ----------------------------------------------------------------------
# Test 12: resume from each synthetic phase state obeys explicit rules
# ----------------------------------------------------------------------
def test_resume_from_paused_rolls_to_exact_phase(tmp_path):
    for paused_at, expect in ((sm.PREPARE, sm.ROLLOUT),):
        sup = _make_sup(tmp_path / f"p_{paused_at}")
        sup.start()
        sup.run_current_phase()  # -> ROLLOUT
        sup.pause()
        assert sup.state.current_phase == sm.PAUSED
        sup.resume()
        assert sup.state.current_phase == expect


def test_resume_from_paused_during_each_work_phase(tmp_path):
    for paused_at in (sm.PREPARE, sm.ROLLOUT, sm.TRAIN_BRAIN, sm.EVAL):
        sup = _make_sup(tmp_path / f"resume_{paused_at}")
        sup.start()
        _advance_to(sup, paused_at)
        sup.pause()
        assert sup.state.current_phase == sm.PAUSED
        assert sup.state.resume_target_phase == paused_at
        sup.resume()
        assert sup.state.current_phase == paused_at  # exact re-entry


def test_resume_refused_without_flag_or_target(tmp_path):
    sup = _make_sup(tmp_path)
    sup.start()
    sup.run_current_phase()  # ROLLOUT
    sup.pause()
    sup.resume()  # ok
    assert sup.state.current_phase == sm.ROLLOUT

    # Reset into PAUSED synthetically without resume_allowed.
    sup.pause()
    sup.state.resume_allowed = False
    with pytest.raises(sm.IllegalTransitionError):
        sup.resume()


def test_resume_from_failed_unwired_refusal_is_blocked(tmp_path):
    sup = _make_sup(tmp_path, dry_run=False)  # live, unwired
    sup.start()
    sup.run_current_phase()   # machine-only PREPARE -> ROLLOUT
    with pytest.raises(UnwiredPhaseError):
        sup.run_current_phase()   # ROLLOUT refusal -> FAILED
    assert sup.state.current_phase == sm.FAILED
    # Explicit rule: cannot resume past an unwired refusal.
    with pytest.raises(sm.IllegalTransitionError, match="unwired"):
        sup.resume()
    # Operator may stop instead.
    sup.stop()
    assert sup.state.current_phase == sm.STOPPED


def test_resume_from_failed_phase_reenters_that_phase(tmp_path):
    sup = _make_sup(tmp_path)
    sup.start()
    sup.run_current_phase()  # -> ROLLOUT
    # Synthetic failure during ROLLOUT (no command executed; dry-run).
    sup.state.failure_reason = "ROLLOUT failed (attempt 1): synthetic"
    sup.state.resume_allowed = True
    sup.state.resume_target_phase = sm.ROLLOUT
    sup.state.phase_status = sm.FAILED
    sup._transition(sm.FAILED, "synthetic rollout failure")
    sup.state.phase_status = sm.FAILED
    sup.resume()
    assert sup.state.current_phase == sm.ROLLOUT
    # Re-run completes in dry-run and moves on.
    assert sup.run_current_phase() == sm.TRAIN_BRAIN


def test_resume_from_each_synthetic_failure_state(tmp_path):
    for failed_at in (sm.PREPARE, sm.ROLLOUT, sm.TRAIN_BRAIN, sm.EVAL):
        sup = _make_sup(tmp_path / f"fail_{failed_at}")
        sup.start()
        _advance_to(sup, failed_at)
        sup.state.failure_reason = f"{failed_at} failed (attempt 1): synthetic"
        sup.state.resume_allowed = True
        sup.state.resume_target_phase = failed_at
        sup.state.phase_status = sm.FAILED
        sup._transition(sm.FAILED, "synthetic failure")
        sup.state.phase_status = sm.FAILED
        sup.resume()
        assert sup.state.current_phase == failed_at
