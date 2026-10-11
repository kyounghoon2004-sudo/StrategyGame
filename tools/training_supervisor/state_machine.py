"""Phase state machine with explicit, validated transitions.

Phases (as required by the cold prompt):

    IDLE, PREPARE, ROLLOUT, TRAIN_BRAIN, EVAL, PROMOTE, REJECT,
    PAUSED, FAILED, STOPPED, COMPLETE

Legal edges:

    IDLE        -> PREPARE
    PREPARE     -> ROLLOUT | PAUSED | FAILED | STOPPED
    ROLLOUT     -> TRAIN_BRAIN | PAUSED | FAILED | STOPPED
    TRAIN_BRAIN -> EVAL       | PAUSED | FAILED | STOPPED
    EVAL        -> PROMOTE    | REJECT | PAUSED | FAILED | STOPPED
    PROMOTE     -> COMPLETE   | PREPARE (next iteration) | STOPPED
    REJECT      -> COMPLETE   | PREPARE (next iteration, champion retained) | STOPPED
    PAUSED      -> RESUME back to the exact phase stored at pause time
                   (validated against ``run_state.last_successful_phase``),
                   or -> STOPPED
    FAILED      -> STOPPED, or -> resume target ONLY through the explicit,
                   validated resume rule (see supervisor.resume)
    STOPPED, COMPLETE -> terminal (no edges out of COMPLETE; STOPPED
                   is terminal for this scaffold)

Every transition is validated; illegal transitions raise
``IllegalTransitionError`` and never mutate run state.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, FrozenSet, Optional

IDLE = "IDLE"
PREPARE = "PREPARE"
ROLLOUT = "ROLLOUT"
TRAIN_BRAIN = "TRAIN_BRAIN"
EVAL = "EVAL"
PROMOTE = "PROMOTE"
REJECT = "REJECT"
PAUSED = "PAUSED"
FAILED = "FAILED"
STOPPED = "STOPPED"
COMPLETE = "COMPLETE"

ALL_PHASES: FrozenSet[str] = frozenset({
    IDLE, PREPARE, ROLLOUT, TRAIN_BRAIN, EVAL,
    PROMOTE, REJECT, PAUSED, FAILED, STOPPED, COMPLETE,
})

#: Work phases in loop order; a phase is "complete" when the machine moves
#: past it to the next phase in this ordering.
WORK_PHASES = (PREPARE, ROLLOUT, TRAIN_BRAIN, EVAL)

#: Phases that may be targeted by a validated resume.
RESUMABLE_PHASES = (PREPARE, ROLLOUT, TRAIN_BRAIN, EVAL, PROMOTE)

#: Phases that record the phase-time pause origin for PAUSED.
PAUSABLE_PHASES = (PREPARE, ROLLOUT, TRAIN_BRAIN, EVAL)

#: Phases that may fail into FAILED.
FAILABLE_PHASES = (PREPARE, ROLLOUT, TRAIN_BRAIN, EVAL, PROMOTE)

#: Phases that may legitimately stop.
STOPPABLE_PHASES: FrozenSet[str] = ALL_PHASES - {COMPLETE}

# Explicit edge table. Terminal phases (STOPPED, COMPLETE) have no out-edges.
_TRANSITIONS: Dict[str, FrozenSet[str]] = {
    IDLE: frozenset({PREPARE}),
    PREPARE: frozenset({ROLLOUT, PAUSED, FAILED, STOPPED}),
    ROLLOUT: frozenset({TRAIN_BRAIN, PAUSED, FAILED, STOPPED}),
    TRAIN_BRAIN: frozenset({EVAL, PAUSED, FAILED, STOPPED}),
    EVAL: frozenset({PROMOTE, REJECT, PAUSED, FAILED, STOPPED}),
    PROMOTE: frozenset({COMPLETE, PREPARE, STOPPED}),
    REJECT: frozenset({COMPLETE, PREPARE, STOPPED}),
    PAUSED: frozenset(),  # filled dynamically: resume target or STOPPED
    FAILED: frozenset(),  # filled dynamically: resume target or STOPPED
    STOPPED: frozenset(),
    COMPLETE: frozenset(),
}

RESUME_EXIT_PHASES = frozenset({PAUSED, FAILED})


class IllegalTransitionError(ValueError):
    """Raised when a phase transition is not explicitly allowed."""


@dataclass(frozen=True)
class Transition:
    """One validated phase transition, appendable to run-state history."""

    from_phase: str
    to_phase: str
    reason: str = field(default="unspecified")
    allowed: bool = True


def _normalize(phase: str) -> str:
    return str(phase).strip().upper()


def is_valid_phase(phase: str) -> bool:
    return _normalize(phase) in ALL_PHASES


def validate_transition(from_phase: str, to_phase: str,
                        resume_target_phase: Optional[str] = None) -> Transition:
    """Validate ``from_phase -> to_phase`` and return a Transition record.

    ``resume_target_phase`` is the phase a PAUSED/FAILED machine may return
    to (recorded at pause/failure time). It is required for any edge out of
    PAUSED or FAILED and must itself be a resumable phase.

    Raises IllegalTransitionError on any edge not in the explicit table.
    """
    src = _normalize(from_phase)
    dst = _normalize(to_phase)

    if src not in ALL_PHASES:
        raise IllegalTransitionError(f"unknown source phase: {from_phase!r}")
    if dst not in ALL_PHASES:
        raise IllegalTransitionError(f"unknown target phase: {to_phase!r}")

    if src in RESUME_EXIT_PHASES:
        if dst == STOPPED:
            return Transition(src, dst, "resume-exit stop")
        if resume_target_phase is None:
            raise IllegalTransitionError(
                f"transition out of {src} requires a recorded resume target "
                "phase; refused")
        if dst != _normalize(resume_target_phase):
            raise IllegalTransitionError(
                f"transition out of {src} must target the recorded resume "
                f"phase {resume_target_phase!r}; got {dst!r}")
        target = _normalize(resume_target_phase)
        if target not in RESUMABLE_PHASES:
            raise IllegalTransitionError(
                f"resume target {target!r} is not a resumable phase")
        return Transition(src, target, "validated resume")

    allowed = _TRANSITIONS[src]
    if dst not in allowed:
        raise IllegalTransitionError(
            f"illegal transition {src} -> {dst}; allowed: {sorted(allowed)}")
    return Transition(src, dst)


def next_work_phase(phase: str) -> Optional[str]:
    """Return the next work phase after ``phase`` in loop order, else None."""
    p = _normalize(phase)
    try:
        idx = WORK_PHASES.index(p)
    except ValueError:
        return None
    return WORK_PHASES[idx + 1] if idx + 1 < len(WORK_PHASES) else None


def is_terminal(phase: str) -> bool:
    return _normalize(phase) in (STOPPED, COMPLETE)
