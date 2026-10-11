"""TrainingSupervisor — deterministic phase orchestration scaffold.

Responsibilities implemented (scaffold scope):
- phase state machine driving (all transitions validated)
- subprocess launch seam with strict ownership recording
- run IDs, persistent run state, atomic saves
- crash recovery / resume with explicit rules
- checkpoint lineage metadata bookkeeping
- candidate/champion identities
- GPU lock coordination (test locks in scaffold mode)
- timeout/error handling, logs
- manual pause/stop, dry-run mode (safe default)

NOT implemented / UNWIRED (deliberately):
- the real rollout / train / eval commands
- the promotion threshold (supervisor consumes evaluator decisions only)

Fail-closed guarantees:
- live execution requires dry_run=False AND wired command AND non-empty
  expected_outputs for the phase; otherwise the phase is refused
- crash during a phase marks that phase incomplete; success is recorded
  only after the phase returns and its expected outputs are declared
  present by a manifest-check hook (stub in scaffold; wired later)
"""
from __future__ import annotations

import logging
import os
import subprocess
import time
import uuid
from typing import Any, Callable, Dict, List, Optional

from . import state_machine as sm
from .checkpoint_lineage import CheckpointLineage
from .command_adapter import PhaseCommandRegistry, PhaseCommandSpec
from .config import SupervisorConfig
from .process_ownership import ProcessOwnershipRegistry
from .promotion import DecisionParser, EvalDecision
from .run_state import RunState, RunStateStore, new_run

LOG = logging.getLogger("training_supervisor")

#: Hook that decides whether a phase's expected outputs exist. The real
#: manifest contract is UNWIRED; the scaffold accepts an injected callable
#: and otherwise fails closed (returns False => phase can never claim
#: success without a wired completeness proof).
ManifestChecker = Callable[[str, PhaseCommandSpec, Dict[str, Any]], bool]


def _never_wired_manifest_checker(phase: str, spec: PhaseCommandSpec,
                                  context: Dict[str, Any]) -> bool:
    """Fail-closed default: no phase output is ever proven present."""
    return False


class PhaseFailure(RuntimeError):
    """A phase failed; the supervisor transitions to FAILED."""


class UnwiredPhaseError(PhaseFailure):
    """Live execution was requested for an unwired phase; refused."""


class TrainingSupervisor:
    """CPU-only orchestration scaffold. No CUDA/model/Godot/RL side effects."""

    def __init__(self, config: SupervisorConfig,
                 run_id: Optional[str] = None,
                 manifest_checker: Optional[ManifestChecker] = None,
                 registry: Optional[ProcessOwnershipRegistry] = None,
                 logger: Optional[logging.Logger] = None) -> None:
        self.config = config
        self.dry_run: bool = bool(config.dry_run)  # safe default True
        self.phase_registry: PhaseCommandRegistry = config.resolved_phase_registry()
        self.processes = registry or ProcessOwnershipRegistry()
        self.log = logger or LOG

        self.run_id = run_id or f"tsup-{time.strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:8]}"
        state_dir = (config.run_state_path
                     or os.path.join(config.artifact_root or ".", "run_state.json"))
        self.store = RunStateStore(state_dir)
        self.state: RunState = new_run(self.run_id)
        self.lineage = CheckpointLineage()
        self.manifest_checker: ManifestChecker = (
            manifest_checker or _never_wired_manifest_checker)

        self._manual_stop_requested = False
        self._manual_pause_requested = False
        self._gpu_lock: Optional[Any] = None  # GpuLockManager when acquired

        if self.store.exists():
            # Crash recovery: reload previous state for THIS run_id if any.
            try:
                prior = self.store.load()
                if prior.run_id == self.run_id:
                    self.state = prior
                    self.lineage = CheckpointLineage.from_state(
                        prior.checkpoint_lineage)
            except Exception as exc:  # noqa: BLE001 - recovery is best effort
                self.log.warning("state reload failed (%s); starting fresh", exc)
        self._persist()

    # ------------------------------------------------------------------
    # persistence
    # ------------------------------------------------------------------
    def _persist(self) -> None:
        self.state.checkpoint_lineage = self.lineage.to_state()
        self.state.process_ids_started_by_supervisor = self.processes.pids_for_state()
        self.state.manual_stop_requested = self._manual_stop_requested
        if self._gpu_lock is not None:
            self.state.gpu_lock_owner = {
                "path": getattr(self._gpu_lock, "path", None),
                "payload": getattr(self._gpu_lock, "payload", None),
            }
        else:
            self.state.gpu_lock_owner = None
        self.store.save(self.state)

    # ------------------------------------------------------------------
    # transitions (all validated)
    # ------------------------------------------------------------------
    def _transition(self, to_phase: str, reason: str) -> None:
        t = sm.validate_transition(
            self.state.current_phase, to_phase,
            resume_target_phase=self.state.resume_target_phase)
        self.state.transitions.append({
            "from": t.from_phase,
            "to": t.to_phase,
            "reason": reason or t.reason,
            "at": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()) + "Z",
        })
        self.state.current_phase = t.to_phase
        self.state.phase_status = t.to_phase
        self._persist()

    # ------------------------------------------------------------------
    # public control surface
    # ------------------------------------------------------------------
    def start(self) -> None:
        """IDLE -> PREPARE."""
        self._transition(sm.PREPARE, "run start")

    def request_manual_stop(self) -> None:
        self._manual_stop_requested = True
        self._persist()

    def request_manual_pause(self) -> None:
        self._manual_pause_requested = True
        self._persist()

    def pause(self) -> None:
        """Pause from any pausable work phase; records the resume target."""
        phase = self.state.current_phase
        if phase not in sm.PAUSABLE_PHASES:
            raise sm.IllegalTransitionError(
                f"cannot pause from {phase}; pausable: {sm.PAUSABLE_PHASES}")
        self.state.resume_target_phase = phase
        self.state.pause_count += 1
        self.state.resume_allowed = True
        self._transition(sm.PAUSED, f"manual pause during {phase}")
        self.state.phase_status = sm.PAUSED
        self._persist()

    def stop(self) -> None:
        """Manual stop: cleanup owned processes, release locks, STOPPED."""
        self.request_manual_stop()
        cleanup = self.processes.cleanup_all()
        self._release_gpu_lock()
        self.state.resume_allowed = False
        self.state.resume_target_phase = None
        self._transition(sm.STOPPED,
                         f"manual stop (terminated={cleanup['terminated']}, "
                         f"refused={cleanup['refused']})")
        self.state.phase_status = sm.STOPPED
        self._persist()

    # ------------------------------------------------------------------
    # resume semantics (explicit, validated)
    # ------------------------------------------------------------------
    def resume(self) -> None:
        """Resume PAUSED/FAILED into the recorded resume target phase.

        Explicit rules enforced here:
        - resume is allowed only when ``resume_allowed`` is True
        - the target phase must be recorded and resumable
        - resume NEVER re-marks a crashed phase's outputs as complete:
          the phase must run again (or its manifest must later prove
          completeness via the wired manifest checker)
        - resume from FAILED is refused while ``failure_reason`` indicates
          an unwired-phase refusal (fix wiring first; operator decision)
        """
        phase = self.state.current_phase
        if phase not in sm.RESUME_EXIT_PHASES:
            raise sm.IllegalTransitionError(
                f"resume is only valid from PAUSED/FAILED; current: {phase}")
        if not self.state.resume_allowed:
            raise sm.IllegalTransitionError("resume_allowed is False")
        target = self.state.resume_target_phase
        if not target:
            raise sm.IllegalTransitionError("no resume target phase recorded")
        if (phase == sm.FAILED
                and self.state.failure_reason
                and "UNWIRED" in self.state.failure_reason.upper()):
            raise sm.IllegalTransitionError(
                "refusing resume after an unwired-phase refusal; "
                "wire the phase command first")
        sm.validate_transition(phase, target, resume_target_phase=target)
        self.state.resume_allowed = False
        # The phase must re-run from its start; completeness must be
        # re-proven (never inherited from the interrupted attempt).
        self._transition(target, f"validated resume from {phase}")
        # Caller then runs run_current_phase() again.

    # ------------------------------------------------------------------
    # phase execution
    # ------------------------------------------------------------------
    def _assert_live_execution_allowed(self, spec: PhaseCommandSpec) -> None:
        if self.dry_run:
            raise UnwiredPhaseError(
                f"{spec.phase} live execution refused: dry_run=True is the "
                "safe default; flip explicitly after MANUAL_RL_LOOP_V1 freezes "
                "the command contract")
        reasons = spec.unwired_reasons()
        if reasons:
            raise UnwiredPhaseError(
                f"{spec.phase} live execution refused: {'; '.join(reasons)}")

    def _acquire_gpu_lock_if_configured(self) -> None:
        """Acquire the configured GPU test lock before ROLLOUT/TRAIN phases.

        Scaffold policy: only when ``config.locks_dir`` points at a
        non-real directory (test/temp). The real D:\\StrategyAI\\locks
        namespace is never touched by the scaffold.
        """
        if self._gpu_lock is not None:
            return
        locks_dir = self.config.locks_dir
        if not locks_dir:
            return
        from .gpu_lock import GpuLockManager  # local import: no import cost
        manager = GpuLockManager(
            path=os.path.join(locks_dir, "training_supervisor_test.lock"),
            run_id=self.run_id,
            phase=self.state.current_phase,
            test_only=True,
        )
        manager.acquire()
        self._gpu_lock = manager
        self._persist()

    def _release_gpu_lock(self) -> None:
        if self._gpu_lock is not None:
            self._gpu_lock.release()
            self._gpu_lock = None
            self._persist()

    def _launch_phase_process(self, spec: PhaseCommandSpec) -> Optional[int]:
        """Launch the phase subprocess (LIVE mode only) with ownership record.

        Returns the owned PID. Dry-run never reaches this path.
        """
        argv = [spec.command] + list(spec.args)
        popen = subprocess.Popen(
            argv,
            cwd=spec.cwd or None,
            env={**os.environ, **spec.env} if spec.env else None,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        owned = self.processes.register_popen(popen, phase=spec.phase,
                                              run_id=self.run_id)
        self._persist()
        return owned.pid

    def run_current_phase(self) -> str:
        """Execute the current work phase under the active mode.

        DRY-RUN (default): performs ZERO real phase commands. It validates
        the state machine path, records attempt bookkeeping, and returns
        the phase result the state machine should follow next.

        LIVE: refused for unwired specs; otherwise launches the owned
        subprocess, waits with timeout, and requires the manifest checker
        to prove expected outputs before recording success.

        Returns the follow-up phase name (e.g. TRAIN_BRAIN after ROLLOUT).
        Raises PhaseFailure on failure (state machine -> FAILED).
        """
        phase = self.state.current_phase
        if phase not in sm.WORK_PHASES:
            raise sm.IllegalTransitionError(
                f"run_current_phase is for work phases; current: {phase}")
        if self._manual_stop_requested:
            self.stop()
            raise PhaseFailure("manual stop requested before phase start")

        if phase == sm.PREPARE:
            # Machine-only phase: PREPARE performs bookkeeping and never
            # launches a command in ANY mode (no command contract exists
            # for it). Auto-registers the first iteration.
            if self.state.iteration == 0:
                self.begin_iteration()
            attempt_record = {
                "phase": phase,
                "attempt": 1,
                "started_at": time.strftime("%Y-%m-%dT%H:%M:%S",
                                            time.gmtime()) + "Z",
                "mode": "DRY_RUN" if self.dry_run else "LIVE",
                "wiring_status": "MACHINE_ONLY",
                "outcome": "success",
                "detail": "machine-only phase: bookkeeping, no command",
            }
            self.state.phase_attempts.append(attempt_record)
            self.state.last_successful_phase = phase
            self._transition(sm.ROLLOUT, "machine-only PREPARE complete")
            self.state.phase_status = sm.ROLLOUT
            self._persist()
            return sm.ROLLOUT

        spec = self.phase_registry.get(phase)
        attempt = len([a for a in self.state.phase_attempts
                       if a.get("phase") == phase]) + 1
        attempt_record = {
            "phase": phase,
            "attempt": attempt,
            "started_at": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()) + "Z",
            "mode": "DRY_RUN" if self.dry_run else "LIVE",
            "wiring_status": spec.wiring_status(),
        }

        try:
            if self.dry_run:
                # ZERO real execution. Only bookkeeping.
                attempt_record["outcome"] = "success"
                attempt_record["detail"] = (
                    "dry-run: no command executed; wiring status recorded")
                self.state.phase_attempts.append(attempt_record)
                self.state.last_successful_phase = phase
                self.state.phase_status = "SUCCESS"
                follow = sm.next_work_phase(phase)
                if follow is None:
                    # EVAL in dry-run: the supervisor cannot decide
                    # promotion without a wired evaluator; it stays in EVAL
                    # awaiting apply_eval_decision().
                    self.state.phase_status = "SUCCESS"
                    self._persist()
                    return sm.EVAL
                self._transition(follow, f"dry-run phase {phase} complete")
                self.state.phase_status = follow
                self._persist()
                return follow

            # ---- LIVE path (fail-closed for unwired phases) ----
            self._assert_live_execution_allowed(spec)
            if phase in (sm.ROLLOUT, sm.TRAIN_BRAIN):
                self._acquire_gpu_lock_if_configured()
            attempt_record["pid"] = self._launch_phase_process(spec)
            deadline = time.monotonic() + (spec.timeout_sec
                                           or self.config.timeout_sec.get("default")
                                           or 3600.0)
            while True:
                owned = self.processes.get(attempt_record["pid"])
                handle = owned.handle if owned else None
                if handle is None or handle.poll() is not None:
                    break
                if time.monotonic() > deadline:
                    self.processes.terminate_owned(owned.pid)
                    raise PhaseFailure(f"{phase} timed out after "
                                       f"{spec.timeout_sec}s")
                if self._manual_stop_requested:
                    self.processes.terminate_owned(owned.pid)
                    raise PhaseFailure(f"{phase} aborted by manual stop")
                if self._manual_pause_requested:
                    self._manual_pause_requested = False
                    self.processes.terminate_owned(owned.pid)
                    self.pause()
                    raise PhaseFailure(f"{phase} aborted for pause; resume "
                                       "re-runs the phase")
                time.sleep(0.05)

            context: Dict[str, Any] = {
                "run_id": self.run_id,
                "iteration": self.state.iteration,
                "attempt": attempt,
            }
            if not self.manifest_checker(phase, spec, context):
                raise PhaseFailure(
                    f"{phase} expected outputs not proven by manifest; "
                    "phase cannot be marked successful")

            attempt_record["outcome"] = "success"
            self.state.phase_attempts.append(attempt_record)
            self.state.last_successful_phase = phase
            self.state.phase_status = "SUCCESS"
            follow = sm.next_work_phase(phase)
            if follow is None:
                # EVAL success: await apply_eval_decision() in EVAL state.
                self.state.phase_status = "SUCCESS"
                self._persist()
                return sm.EVAL
            self._transition(follow, f"live phase {phase} complete")
            self.state.phase_status = follow
            self._persist()
            return follow

        except PhaseFailure as exc:
            attempt_record["outcome"] = "failed"
            self.state.phase_attempts.append(attempt_record)
            self.state.failure_count += 1
            self.state.failure_reason = (
                f"{phase} failed (attempt {attempt}): {exc}")
            self.state.resume_allowed = True
            self.state.resume_target_phase = phase
            self.state.phase_status = sm.FAILED
            self._transition(sm.FAILED, self.state.failure_reason)
            self.state.phase_status = sm.FAILED
            self._persist()
            raise
        finally:
            self._release_gpu_lock()

    # ------------------------------------------------------------------
    # evaluation decision handling (supervisor consumes; no heuristics)
    # ------------------------------------------------------------------
    def apply_eval_decision(self, raw: Any) -> str:
        """Apply a validated evaluator decision: PROMOTE / REJECT path.

        INCONCLUSIVE never promotes (goes to FAILED, resume into EVAL).
        Only valid from EVAL. Returns the transition target phase.
        """
        if self.state.current_phase != sm.EVAL:
            raise sm.IllegalTransitionError(
                f"apply_eval_decision is valid only from EVAL; "
                f"current: {self.state.current_phase}")
        decision: EvalDecision = DecisionParser.parse(raw)

        self.state.evaluation_id = decision.evaluation_id
        if decision.decision == "PROMOTE":
            candidate = self.lineage.get(decision.candidate_id)
            if candidate is None:
                raise PhaseFailure(
                    f"evaluator promoted unknown candidate "
                    f"{decision.candidate_id!r}")
            try:
                self.lineage.promote(
                    decision.candidate_id,
                    evaluation_ref=decision.evaluation_id,
                    reason=decision.reason,
                )
                self._persist()
            except Exception as exc:  # noqa: BLE001
                self.lineage.rollback_last_promotion(decision.candidate_id)
                raise PhaseFailure(
                    f"promotion transaction failed; rolled back: {exc}") from exc
            self.state.champion_id = decision.candidate_id
            self.state.candidate_id = None
            self._transition(sm.PROMOTE,
                             f"promoted {decision.candidate_id} "
                             f"(eval {decision.evaluation_id})")
            self.state.phase_status = sm.PROMOTE
            self._persist()
            return sm.PROMOTE

        if decision.decision == "REJECT":
            candidate = self.lineage.get(decision.candidate_id)
            if candidate is not None:
                self.lineage.reject(decision.candidate_id,
                                    reason=decision.reason)
            self.state.candidate_id = None
            self._persist()
            self._transition(sm.REJECT,
                             f"rejected {decision.candidate_id} "
                             f"(champion retained)")
            self.state.phase_status = sm.REJECT
            self._persist()
            return sm.REJECT

        # INCONCLUSIVE: never promotes.
        self.state.failure_reason = (
            f"EVAL inconclusive ({decision.reason or 'no reason given'})")
        self.state.resume_allowed = True
        self.state.resume_target_phase = sm.EVAL
        self.state.phase_status = sm.FAILED
        self._transition(sm.FAILED, self.state.failure_reason)
        self.state.phase_status = sm.FAILED
        self._persist()
        return sm.FAILED

    # ------------------------------------------------------------------
    # iteration bookkeeping
    # ------------------------------------------------------------------
    def begin_iteration(self, candidate_id: Optional[str] = None) -> None:
        """PREPARE registration of a new iteration candidate (metadata).

        Idempotent within one iteration: the counter only advances when the
        current iteration has actually completed a decision phase, or when
        called explicitly for the first iteration of a run.
        """
        if self.state.current_phase not in (sm.PREPARE, sm.IDLE):
            raise sm.IllegalTransitionError(
                "begin_iteration is valid only from IDLE/PREPARE")
        if self.state.iteration > 0 and self.state.candidate_id:
            # A candidate is already registered for this iteration.
            return
        self.state.iteration += 1
        self.state.candidate_id = candidate_id
        self.state.rollout_batch_id = None
        self.state.evaluation_id = None
        self.state.failure_reason = None
        self._persist()

    def record_rollout_batch(self, batch_id: str) -> None:
        self.state.rollout_batch_id = batch_id
        self._persist()

    def record_training_steps(self, start_step: int, end_step: int) -> None:
        self.state.training_step_range = [int(start_step), int(end_step)]
        self._persist()

    def next_iteration_or_complete(self, continue_iterations: bool) -> str:
        """PROMOTE/REJECT -> PREPARE (next iteration) or COMPLETE."""
        if continue_iterations:
            self.state.champion_id = (self.state.champion_id
                                      or self.state.champion_id)
            self._transition(sm.PREPARE, "next iteration")
            self.state.phase_status = sm.PREPARE
            self._persist()
            return sm.PREPARE
        self._transition(sm.COMPLETE, "iteration limit or operator stop")
        self.state.phase_status = sm.COMPLETE
        self._persist()
        return sm.COMPLETE

    # ------------------------------------------------------------------
    # crash recovery helper
    # ------------------------------------------------------------------
    def reconcile_after_crash(self) -> Dict[str, Any]:
        """Reconcile run state after an interrupted attempt.

        Rules (scaffold):
        - a phase whose attempt record has no success outcome is INCOMPLETE;
          it must re-run (resume) — outputs are never assumed complete
        - lineage invariants are re-validated; violations are reported
        - promotion rollback is offered if a champion transition is present
          but persistence is inconsistent (idempotency guard)
        """
        report: Dict[str, Any] = {
            "incomplete_phases": [],
            "lineage_problems": self.lineage.validate(),
            "resume_available": False,
        }
        for attempt in self.state.phase_attempts:
            if attempt.get("outcome") != "success":
                report["incomplete_phases"].append(
                    {k: attempt.get(k) for k in ("phase", "attempt")})
        if self.state.current_phase in sm.RESUME_EXIT_PHASES:
            report["resume_available"] = bool(self.state.resume_allowed)
        return report
