#!/usr/bin/env python3
"""TRAINING_MARATHON_V1 — marathon runner over the TrainingSupervisor.

Execution/orchestration only. No RL redesign, no hyperparameter changes.

Modes:
  --plan        print wired commands + status (no execution)
  --dry-run     walk one iteration through the supervisor in DRY-RUN mode
                (zero real phase commands; proves wiring + transitions)
  --one-cycle   run exactly ONE complete supervised cycle (live)
  --marathon    loop iterations until manual stop or safety fault
  --status      print marathon + supervisor + lock status
  --stop        request manual stop (marathon exits at next boundary)

The first supervised cycle (--one-cycle) must pass before --marathon.
REJECT does not stop the marathon; the champion is retained and the next
candidate starts again from the unchanged champion.
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import time

if __package__ in (None, ""):
    sys.path.insert(0, os.path.dirname(os.path.dirname(
        os.path.dirname(os.path.abspath(__file__)))))

from tools.training_supervisor.checkpoint_lineage import CheckpointLineage  # noqa: E402
from tools.training_supervisor.command_adapter import PhaseCommandSpec  # noqa: E402
from tools.training_supervisor.config import SupervisorConfig  # noqa: E402
from tools.training_supervisor.gpu_lock import (  # noqa: E402
    GpuLockManager, lock_status)
from tools.training_supervisor.supervisor import (  # noqa: E402
    PhaseFailure, TrainingSupervisor)
from tools.training_supervisor import marathon_wiring as W  # noqa: E402

LOG = logging.getLogger("marathon")

BASE_MODEL_ID = r"D:\StrategyAI\models\Qwen3-8B"
BASE_REVISION = "b968826d9c46dd6066d109eabc6255188de91218"

STOP_FILE = os.path.join(W.MARATHON_ROOT, "STOP_REQUESTED")


# ----------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------
def ensure_dirs():
    for d in (W.MARATHON_ROOT,
              os.path.join(W.MARATHON_ROOT, "iterations"),
              os.path.join(W.MARATHON_ROOT, "logs")):
        os.makedirs(d, exist_ok=True)


def load_lineage_records():
    try:
        with open(W.champion_lineage_path(), "r", encoding="utf-8") as f:
            data = json.load(f)
        recs = data.get("records", []) if isinstance(data, dict) else []
        return [r for r in recs if isinstance(r, dict)]
    except (OSError, ValueError):
        return []


def save_lineage_records(records):
    tmp = W.champion_lineage_path() + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"lineage": "TRAINING_MARATHON_V1", "records": records,
                   "updated_at": W.utcnow()}, f, indent=2)
    os.replace(tmp, W.champion_lineage_path())


def ensure_b0_lineage(records):
    if any(r.get("checkpoint_id") == "B0" for r in records):
        return records
    records = list(records)
    records.append({
        "checkpoint_id": "B0", "kind": "BASE", "status": "CHAMPION",
        "parent_champion_id": None, "base_model_id": BASE_MODEL_ID,
        "base_revision": BASE_REVISION, "iteration": 0,
        "created_at": W.utcnow(), "artifact_path": None,
        "artifact_hash": None, "hash_algorithm": None,
        "evaluation_ref": None, "promotion_reason": "initial champion "
        "(official Qwen3-8B, no adapter)", "rejection_reason": None,
        "extra": {}})
    save_lineage_records(records)
    return records


def current_champion(records):
    for r in records:
        if r.get("status") == "CHAMPION":
            return r
    raise RuntimeError("no CHAMPION in lineage")


def make_supervisor(dry_run: bool, run_id: str | None,
                    phase_specs: dict) -> TrainingSupervisor:
    cfg = SupervisorConfig(
        schema_version=1, project_root=W.PROJECT_ROOT,
        artifact_root=W.MARATHON_ROOT,
        run_state_path=os.path.join(W.MARATHON_ROOT, "run_state.json"),
        logs_dir=os.path.join(W.MARATHON_ROOT, "logs"),
        locks_dir="",  # real GPU lock managed explicitly by the runner
        phase_specs=dict(phase_specs),
        timeout_sec={"ROLLOUT": W.TIMEOUTS["ROLLOUT"],
                     "TRAIN_BRAIN": W.TIMEOUTS["TRAIN_BRAIN"],
                     "EVAL": W.TIMEOUTS["EVAL"], "default": 3600.0},
        max_iterations=100000, dry_run=dry_run)
    sup = TrainingSupervisor(cfg, run_id=run_id,
                             manifest_checker=W.marathon_manifest_checker)
    return sup


def set_iteration_specs(sup: TrainingSupervisor, specs: dict) -> None:
    sup.config.phase_specs = dict(specs)
    for key, d in specs.items():
        sup.phase_registry.set(PhaseCommandSpec.from_dict(d))


def acquire_marathon_lock(run_id: str, phase: str,
                          timeout_s: float = 180.0):
    mgr = GpuLockManager(
        path=os.path.join(W.REAL_LOCKS_DIR, W.MARATHON_LOCK_NAME),
        run_id=run_id, phase=phase,
        purpose="training_marathon_v1", test_only=False)
    mgr.acquire(wait_timeout_seconds=timeout_s)
    return mgr


def update_state(patch: dict) -> dict:
    st = W.load_marathon_state() or W.new_marathon_state()
    st.update(patch)
    st["last_heartbeat"] = W.utcnow()
    W.save_marathon_state(st)
    return st


def owned_pids_live(sup: TrainingSupervisor):
    live = []
    for proc in sup.processes.all_owned():
        h = proc.handle
        try:
            if h is not None and h.poll() is None:
                live.append(proc.pid)
        except Exception:
            live.append(proc.pid)
    return live


def summarize_phase_outputs(itdir: str) -> dict:
    out = {}
    for name in ("rollout_manifest.json", "phase1_summary.json"):
        p = os.path.join(itdir, "rollout", name)
        if os.path.exists(p):
            try:
                out[name] = json.load(open(p, encoding="utf-8"))
            except ValueError:
                pass
    p = os.path.join(itdir, "train", "train_summary.json")
    if os.path.exists(p):
        try:
            out["train_summary.json"] = json.load(open(p, encoding="utf-8"))
        except ValueError:
            pass
    p = os.path.join(itdir, "eval", "eval_summary.json")
    if os.path.exists(p):
        try:
            out["eval_summary.json"] = json.load(open(p, encoding="utf-8"))
        except ValueError:
            pass
    return out


# ----------------------------------------------------------------------
# one supervised iteration (live or dry)
# ----------------------------------------------------------------------
def run_one_iteration(sup: TrainingSupervisor, iteration: int,
                      champ: dict, live: bool) -> dict:
    """Run a single supervised iteration. Returns the ITERATION_RESULT."""
    cand = W.candidate_id(iteration)
    itdir = W.iteration_dir(iteration)
    candidate_out = os.path.join(itdir, "train", f"candidate_{cand}")
    os.makedirs(os.path.join(itdir, "rollout"), exist_ok=True)
    os.makedirs(os.path.join(itdir, "train"), exist_ok=True)
    os.makedirs(os.path.join(itdir, "eval"), exist_ok=True)

    champ_label = champ["checkpoint_id"]
    champ_adapter = champ.get("artifact_path") or ""
    train_seed = W.train_seed_start(iteration)
    eval_seed_pair = W.eval_seeds(iteration)
    # Training/eval seeds must never overlap within an iteration.
    assert not (set([train_seed + i for i in range(W.MAX_GROUPS * 2)])
                & set(eval_seed_pair)), "seed stream collision"

    specs = W.build_phase_specs(itdir, champ_adapter, candidate_out,
                                champ_label, cand, train_seed,
                                eval_seed_pair)
    set_iteration_specs(sup, specs)

    # Lineage: mirror file lineage into the supervisor lineage.
    if sup.lineage.get("B0") is None:
        sup.lineage.register_base("B0", BASE_MODEL_ID, BASE_REVISION,
                                  artifact_path=None)
    if sup.lineage.get(cand) is None:
        sup.lineage.register_candidate(
            cand, iteration=iteration, parent_champion_id=champ_label,
            artifact_path=candidate_out)
    sup.state.champion_id = champ_label
    sup._persist()

    update_state({"current_iteration": iteration, "current_phase": "PREPARE",
                  "champion_id": champ_label,
                  "champion_adapter": champ_adapter or None,
                  "candidate_id": cand,
                  "supervisor_run_id": sup.run_id,
                  "supervisor_pid": os.getpid()})

    result = {"iteration": iteration, "candidate_id": cand,
              "champion_before": champ_label,
              "champion_adapter_before": champ_adapter or None,
              "started_at": W.utcnow(), "live": live}

    if sup.state.current_phase == "IDLE":
        sup.start()
    sup.begin_iteration(candidate_id=cand)

    # PREPARE (machine-only) -> ROLLOUT
    nxt = sup.run_current_phase()
    assert nxt == "ROLLOUT", nxt

    for phase in ("ROLLOUT", "TRAIN_BRAIN", "EVAL"):
        update_state({"current_phase": phase,
                      "last_phase_start": W.utcnow(),
                      "candidate_id": cand})
        if live:
            ok, detail = W.memory_healthy()
            if not ok:
                raise RuntimeError(f"FAILED_MEMORY_GUARD pre-{phase}: "
                                   f"{detail}")
            lock = None
            try:
                lock = acquire_marathon_lock(sup.run_id, phase)
                sup._persist()
                LOG.info("phase %s starting: %s", phase, detail)
                nxt = sup.run_current_phase()
            except PhaseFailure:
                raise
            finally:
                try:
                    if lock is not None:
                        lock.release()
                except Exception:
                    pass
                sup._persist()
        else:
            nxt = sup.run_current_phase()
        # Process separation proof: owned children must have exited.
        live_pids = owned_pids_live(sup)
        if live_pids:
            raise RuntimeError(f"phase {phase}: owned PIDs still live: "
                               f"{live_pids}")
        if live:
            idle_ok, idle_detail = W.gpu_near_idle()
            LOG.info("phase %s done -> %s; %s", phase, nxt, idle_detail)
            if not idle_ok:
                LOG.warning("GPU not idle after %s: %s", phase, idle_detail)
        update_state({"current_phase": nxt or phase,
                      "last_phase_start": W.utcnow()})

    # EVAL complete -> deterministic promotion decision.
    summaries = summarize_phase_outputs(itdir)
    evaluation_id = f"eval_it{iteration:06d}_{cand}_vs_{champ_label}"
    if live:
        decision_raw = W.build_eval_decision(itdir, cand, champ_label,
                                             evaluation_id)
        target = sup.apply_eval_decision(decision_raw)
    else:
        decision_raw = {"decision": "DRY_RUN", "candidate_id": cand,
                        "champion_id": champ_label,
                        "evaluation_id": evaluation_id}
        target = sup.state.current_phase
    result.update({"decision": decision_raw["decision"],
                   "decision_reason": decision_raw.get("reason", ""),
                   "evaluation_id": evaluation_id,
                   "target_phase": target,
                   "summaries": summaries,
                   "finished_at": W.utcnow()})
    return result


def finalize_iteration(result: dict, records: list) -> tuple:
    """Apply promotion/rejection to file lineage + marathon state. Returns
    (records, champion_record)."""
    iteration = result["iteration"]
    cand = result["candidate_id"]
    decision = result["decision"]
    itdir = W.iteration_dir(iteration)
    summaries = result.get("summaries", {})
    train_s = summaries.get("train_summary.json", {})
    eval_s = summaries.get("eval_summary.json", {})
    cand_artifact = os.path.join(itdir, "train", f"candidate_{cand}")

    # Upsert the candidate record: rejected (or historical) candidate
    # evidence must never be lost from the file lineage.
    seen = {r.get("checkpoint_id") for r in records}
    if cand not in seen:
        parent = result.get("champion_before")
        records = list(records) + [{
            "checkpoint_id": cand, "kind": "CANDIDATE",
            "status": "CANDIDATE", "parent_champion_id": parent,
            "base_model_id": BASE_MODEL_ID, "base_revision": BASE_REVISION,
            "iteration": iteration, "created_at": W.utcnow(),
            "artifact_path": cand_artifact, "artifact_hash": None,
            "hash_algorithm": None, "evaluation_ref": result.get(
                "evaluation_id"), "promotion_reason": None,
            "rejection_reason": None, "extra": {}}]

    if decision == "PROMOTE":
        new_records = []
        for r in records:
            r = dict(r)
            if r.get("status") == "CHAMPION":
                r["status"] = "HISTORICAL"
            if r.get("checkpoint_id") == cand:
                r["status"] = "CHAMPION"
                r["kind"] = "CHAMPION"
                r["evaluation_ref"] = result["evaluation_id"]
                r["promotion_reason"] = result["decision_reason"]
            new_records.append(r)
        records = new_records
        champ = current_champion(records)
    else:
        new_records = []
        for r in records:
            r = dict(r)
            if r.get("checkpoint_id") == cand and decision == "REJECT":
                r["status"] = "REJECTED"
                r["rejection_reason"] = result["decision_reason"]
            new_records.append(r)
        records = new_records
        champ = current_champion(records)
    save_lineage_records(records)

    result["champion_after"] = champ["checkpoint_id"]
    result["champion_adapter_after"] = champ.get("artifact_path")
    with open(os.path.join(itdir, "ITERATION_RESULT.json"), "w",
              encoding="utf-8") as f:
        json.dump(result, f, indent=2)

    st = W.load_marathon_state() or W.new_marathon_state()
    st.update({
        "champion_id": champ["checkpoint_id"],
        "champion_adapter": champ.get("artifact_path"),
        "candidate_id": None,
        "last_decision": {"iteration": iteration, "decision": decision,
                          "candidate": cand,
                          "champion": champ["checkpoint_id"],
                          "reason": result["decision_reason"],
                          "at": W.utcnow()},
        "vram_peak_gib": train_s.get("peak_device_vram_gib",
                                     st.get("vram_peak_gib")),
        "min_free_ram_gib": train_s.get("minimum_available_system_ram_gib",
                                        st.get("min_free_ram_gib")),
        "optimizer_steps_total": int(st.get("optimizer_steps_total", 0))
        + int(train_s.get("optimizer_steps", 0)),
        "wins": int(st.get("wins", 0)) + int(eval_s.get("wins", 0)),
        "losses": int(st.get("losses", 0)) + int(eval_s.get("losses", 0)),
        "draws": int(st.get("draws", 0)) + int(eval_s.get("draws", 0)),
        "strict_failures_total": int(st.get("strict_failures_total", 0))
        + int(eval_s.get("strict_failures", 0)),
        "last_heartbeat": W.utcnow()})
    W.save_marathon_state(st)
    return records, champ


# ----------------------------------------------------------------------
# commands
# ----------------------------------------------------------------------
def cmd_plan():
    ensure_dirs()
    records = ensure_b0_lineage(load_lineage_records())
    champ = current_champion(records)
    st = W.load_marathon_state() or W.new_marathon_state()
    nxt = int(st.get("current_iteration", 0)) + 1
    specs = W.build_phase_specs(
        W.iteration_dir(nxt), champ.get("artifact_path") or "",
        os.path.join(W.iteration_dir(nxt), "train",
                     f"candidate_{W.candidate_id(nxt)}"),
        champ["checkpoint_id"], W.candidate_id(nxt),
        W.train_seed_start(nxt), W.eval_seeds(nxt))
    sup = make_supervisor(True, None, specs)
    print(json.dumps({
        "marathon": "TRAINING_MARATHON_V1",
        "dry_run": sup.dry_run,
        "wiring": sup.phase_registry.wiring_report(),
        "next_iteration": nxt,
        "champion": champ["checkpoint_id"],
        "candidate": W.candidate_id(nxt),
        "train_seed_start": W.train_seed_start(nxt),
        "eval_seeds": W.eval_seeds(nxt),
        "phase_specs": specs,
        "marathon_state": W.load_marathon_state(),
    }, indent=2))
    return 0


def cmd_dry_run():
    ensure_dirs()
    records = ensure_b0_lineage(load_lineage_records())
    champ = current_champion(records)
    st = W.load_marathon_state()
    nxt = int((st or {}).get("current_iteration", 0)) + 1
    sup = make_supervisor(True, None, {})
    result = run_one_iteration(sup, nxt, champ, live=False)
    print(json.dumps({"dry_run": "PASS", "result": {
        "iteration": result["iteration"],
        "candidate": result["candidate_id"],
        "champion_before": result["champion_before"],
        "target_phase": result["target_phase"],
        "transitions": sup.state.transitions}}, indent=2))
    return 0


SKIPPED_NO_SIGNAL = "SKIPPED_NO_SIGNAL"


def record_skipped_no_signal(iteration: int, cand: str, reason: str,
                             summ: dict) -> list:
    """Persist a NO_SIGNAL iteration as skipped (champion unchanged).

    NO_SIGNAL and REJECT never stop the marathon: the candidate is marked
    SKIPPED_NO_SIGNAL (lineage-kept as REJECTED with an explicit skip
    reason, since lineage statuses are schema-fixed), the iteration result
    is persisted, and the caller advances to the next iteration with fresh
    seeds. Only memory-guard / process / integrity / GPU-lock faults stop.
    """
    itdir = W.iteration_dir(iteration)
    records = ensure_b0_lineage(load_lineage_records())
    seen = {r.get("checkpoint_id") for r in records}
    if cand not in seen:
        champ_now = current_champion(records)
        records = list(records) + [{
            "checkpoint_id": cand, "kind": "CANDIDATE",
            "status": "REJECTED", "parent_champion_id": champ_now[
                "checkpoint_id"],
            "base_model_id": BASE_MODEL_ID, "base_revision": BASE_REVISION,
            "iteration": iteration, "created_at": W.utcnow(),
            "artifact_path": None, "artifact_hash": None,
            "hash_algorithm": None,
            "evaluation_ref": None, "promotion_reason": None,
            "rejection_reason": f"{SKIPPED_NO_SIGNAL}: {reason[:500]}",
            "extra": {"skipped_no_signal": True}}]
    else:
        new_records = []
        for r in records:
            r = dict(r)
            if r.get("checkpoint_id") == cand:
                r["status"] = "REJECTED"
                r["rejection_reason"] = \
                    f"{SKIPPED_NO_SIGNAL}: {reason[:500]}"
                extra = dict(r.get("extra") or {})
                extra["skipped_no_signal"] = True
                r["extra"] = extra
            new_records.append(r)
        records = new_records
    save_lineage_records(records)
    with open(os.path.join(itdir, "ITERATION_RESULT.json"), "w",
              encoding="utf-8") as f:
        json.dump({"iteration": iteration, "candidate_id": cand,
                   "decision": SKIPPED_NO_SIGNAL,
                   "decision_reason": f"rollout found <2 informative groups "
                   f"after {W.MAX_GROUPS} groups; zero-signal data is never "
                   f"trained ({reason[:500]})",
                   "champion_after": current_champion(records)[
                       "checkpoint_id"],
                   "summaries": summ, "at": W.utcnow()}, f, indent=2)
    st = W.load_marathon_state() or W.new_marathon_state()
    st.update({"candidate_id": None,
               "last_decision": {"iteration": iteration,
                                 "decision": SKIPPED_NO_SIGNAL,
                                 "candidate": cand,
                                 "champion": current_champion(records)[
                                     "checkpoint_id"],
                                 "reason": reason[:500],
                                 "at": W.utcnow()},
               "status": "TRAINING_MARATHON_V1_RUNNING",
               "last_heartbeat": W.utcnow()})
    W.save_marathon_state(st)
    LOG.info("iteration %d %s (champion=%s retained)", iteration,
             SKIPPED_NO_SIGNAL, current_champion(records)["checkpoint_id"])
    return records


def fresh_supervisor_for_continuation(records: list) -> TrainingSupervisor:
    """New supervisor run reusing the persisted file lineage.

    A FAILED supervisor machine cannot transition back to PREPARE, so
    continuation after a skipped iteration starts a fresh run_id with the
    same champion lineage. The previous run_state.json is archived first.
    """
    rsp_path = os.path.join(W.MARATHON_ROOT, "run_state.json")
    try:
        if os.path.exists(rsp_path):
            arch = os.path.join(W.MARATHON_ROOT, "logs",
                                f"run_state_failed_"
                                f"{time.strftime('%Y%m%d-%H%M%S')}.json")
            import shutil
            shutil.copy(rsp_path, arch)
    except OSError:
        pass
    run_id = f"marathon-v1-{time.strftime('%Y%m%d-%H%M%S')}"
    sup = make_supervisor(False, run_id, {})
    sup.lineage = CheckpointLineage.from_state(records)
    sup._persist()
    update_state({"supervisor_run_id": run_id,
                  "supervisor_pid": os.getpid()})
    return sup


def run_live_iterations(sup: TrainingSupervisor, records: list,
                        start_iteration: int, max_iterations: int | None,
                        one_cycle: bool) -> int:
    champ = current_champion(records)
    iteration = start_iteration
    done = 0
    while True:
        if os.path.exists(STOP_FILE):
            update_state({"status": "STOPPED",
                          "current_phase": sup.state.current_phase})
            LOG.info("manual STOP requested; exiting at boundary")
            return 0
        if max_iterations is not None and done >= max_iterations:
            return 0
        # Re-point specs each iteration (supervisor registry is per-phase).
        try:
            result = run_one_iteration(sup, iteration, champ, live=True)
        except PhaseFailure as exc:
            reason = str(exc)
            # Classify: memory guard / no-signal / generic phase failure.
            itdir = W.iteration_dir(iteration)
            summ = summarize_phase_outputs(itdir)
            man = summ.get("rollout_manifest.json", {})
            status = "FAILED_PHASE"
            if "FAILED_MEMORY_GUARD" in reason or os.path.exists(
                    os.path.join(itdir, "train", "TRAIN_ABORT.json")):
                status = "FAILED_MEMORY_GUARD"
            elif man.get("status") == "BLOCKED_NO_SIGNAL":
                status = "BLOCKED_NO_SIGNAL"
            if status == "BLOCKED_NO_SIGNAL":
                # Recoverable: skip, keep champion, continue with fresh
                # seeds next iteration. Never train zero-signal data.
                records = record_skipped_no_signal(
                    iteration, sup.state.candidate_id or W.candidate_id(
                        iteration), reason, summ)
                champ = current_champion(records)
                sup = fresh_supervisor_for_continuation(records)
                iteration += 1
                continue
            update_state({"status": status, "current_phase": "FAILED",
                          "failure_reason": reason[:2000]})
            with open(os.path.join(itdir, "ITERATION_RESULT.json"), "w",
                      encoding="utf-8") as f:
                json.dump({"iteration": iteration, "status": status,
                           "failure_reason": reason[:2000],
                           "summaries": summ, "at": W.utcnow()}, f, indent=2)
            LOG.error("iteration %d stopped: %s: %s", iteration, status,
                      reason)
            return 1
        except RuntimeError as exc:
            msg = str(exc)
            status = ("FAILED_MEMORY_GUARD" if "FAILED_MEMORY_GUARD" in msg
                      else "FAILED_PHASE")
            update_state({"status": status, "failure_reason": msg[:2000]})
            LOG.error("iteration %d stopped: %s: %s", iteration, status, msg)
            return 1

        records, champ = finalize_iteration(result, records)
        done += 1
        LOG.info("iteration %d %s (champion=%s)", iteration,
                 result["decision"], champ["checkpoint_id"])
        update_state({"status": "RUNNING" if not one_cycle else "CYCLE_DONE",
                      "current_phase": sup.state.current_phase})
        if one_cycle:
            return 0
        # Next iteration through the supervisor machine.
        try:
            sup.next_iteration_or_complete(True)
        except Exception as exc:
            update_state({"status": "FAILED_SUPERVISOR",
                          "failure_reason": str(exc)[:2000]})
            return 1
        iteration += 1


def run_single_live_phase(sup: TrainingSupervisor, phase: str,
                          cand: str) -> str:
    """Run one live phase (lock, guards, separation proof). Returns next."""
    update_state({"current_phase": phase, "last_phase_start": W.utcnow(),
                  "candidate_id": cand})
    ok, detail = W.memory_healthy()
    if not ok:
        raise RuntimeError(f"FAILED_MEMORY_GUARD pre-{phase}: {detail}")
    lock = None
    try:
        lock = acquire_marathon_lock(sup.run_id, phase)
        sup._persist()
        LOG.info("phase %s starting: %s", phase, detail)
        nxt = sup.run_current_phase()
    finally:
        try:
            if lock is not None:
                lock.release()
        except Exception:
            pass
        sup._persist()
    live_pids = owned_pids_live(sup)
    if live_pids:
        raise RuntimeError(f"phase {phase}: owned PIDs still live: "
                           f"{live_pids}")
    idle_ok, idle_detail = W.gpu_near_idle()
    LOG.info("phase %s done -> %s; %s", phase, nxt, idle_detail)
    if not idle_ok:
        LOG.warning("GPU not idle after %s: %s", phase, idle_detail)
    update_state({"current_phase": nxt or phase,
                  "last_phase_start": W.utcnow()})
    return nxt


def cmd_skip_blocked():
    """Mark the currently BLOCKED_NO_SIGNAL iteration as skipped.

    Keeps the champion, persists the skip, and leaves the marathon state
    ready for --marathon to advance to the next iteration with fresh
    seeds. Used when no live supervisor remains to continue in-process.
    """
    ensure_dirs()
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s")
    st = W.load_marathon_state()
    if not st or st.get("status") != "BLOCKED_NO_SIGNAL":
        LOG.error("nothing blocked (status=%s)", (st or {}).get("status"))
        return 1
    iteration = int(st["current_iteration"])
    cand = st["candidate_id"] or W.candidate_id(iteration)
    itdir = W.iteration_dir(iteration)
    summ = summarize_phase_outputs(itdir)
    records = record_skipped_no_signal(
        iteration, cand, st.get("failure_reason", "BLOCKED_NO_SIGNAL"),
        summ)
    print(json.dumps({"skipped": iteration, "candidate": cand,
                      "champion": current_champion(records)["checkpoint_id"],
                      "next_iteration": iteration + 1,
                      "next_train_seed": W.train_seed_start(iteration + 1),
                      "next_eval_seeds": W.eval_seeds(iteration + 1)},
                     indent=2))
    return 0


def cmd_resume():
    """Resume a FAILED marathon iteration via the supervisor resume path.

    Reopens the SAME supervisor run_id (reloads persisted FAILED state),
    validates resume_allowed + resume target, re-runs ONLY the failed (and
    downstream) phases, then continues the marathon loop. Never restarts
    from iteration 1.
    """
    ensure_dirs()
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s")
    if os.path.exists(STOP_FILE):
        LOG.info("STOP requested; refusing resume")
        return 0
    st = W.load_marathon_state()
    if not st or st.get("status") not in ("FAILED_PHASE",
                                          "FAILED_MEMORY_GUARD",
                                          "BLOCKED_NO_SIGNAL"):
        LOG.error("nothing resumable (status=%s)",
                  (st or {}).get("status"))
        return 1
    if st.get("status") == "FAILED_MEMORY_GUARD":
        LOG.error("memory guard tripped; refusing auto-resume")
        return 1
    try:
        rsp = json.load(open(os.path.join(W.MARATHON_ROOT,
                                          "run_state.json"),
                             encoding="utf-8"))
        run_id = rsp["run_id"]
        target = rsp.get("resume_target_phase")
        if not rsp.get("resume_allowed") or not target:
            raise RuntimeError("supervisor resume not allowed/target missing")
    except (OSError, ValueError, KeyError, RuntimeError) as exc:
        LOG.error("cannot resume: %s", exc)
        return 1

    iteration = int(st["current_iteration"])
    cand = st["candidate_id"]
    records = ensure_b0_lineage(load_lineage_records())
    champ = current_champion(records)
    champ_label = champ["checkpoint_id"]
    champ_adapter = champ.get("artifact_path") or ""
    itdir = W.iteration_dir(iteration)
    candidate_out = os.path.join(itdir, "train", f"candidate_{cand}")
    specs = W.build_phase_specs(itdir, champ_adapter, candidate_out,
                                champ_label, cand,
                                W.train_seed_start(iteration),
                                W.eval_seeds(iteration))

    sup = make_supervisor(False, run_id, specs)
    sup.lineage = CheckpointLineage.from_state(records)
    if sup.lineage.get(cand) is None:
        sup.lineage.register_candidate(
            cand, iteration=iteration, parent_champion_id=champ_label,
            artifact_path=candidate_out)
    sup.state.champion_id = champ_label
    sup._persist()

    # Prerequisite check: resuming TRAIN/EVAL requires the upstream
    # manifest to already be proven (else the retry is invalid).
    if target in ("TRAIN_BRAIN", "EVAL"):
        ok, detail = W.check_rollout(itdir)
        if not ok:
            LOG.error("resume refused: rollout not proven: %s", detail)
            return 1
        LOG.info("resume prerequisite rollout: %s", detail)
    if target == "EVAL":
        ok, detail = W.check_train(itdir, candidate_out)
        if not ok:
            LOG.error("resume refused: train not proven: %s", detail)
            return 1
        LOG.info("resume prerequisite train: %s", detail)
    # Drop partial outputs of the failed TRAIN attempt (no evidence value;
    # phase.log is retained). The retry regenerates them.
    if target == "TRAIN_BRAIN" and os.path.isdir(candidate_out):
        import shutil
        shutil.rmtree(candidate_out, ignore_errors=True)
        LOG.info("cleared partial %s", candidate_out)

    sup.resume()
    LOG.info("resumed %s -> %s (iteration %d candidate %s)", run_id,
             target, iteration, cand)
    update_state({"status": "TRAINING_MARATHON_V1_RUNNING",
                  "supervisor_run_id": run_id,
                  "supervisor_pid": os.getpid()})
    order = ["ROLLOUT", "TRAIN_BRAIN", "EVAL"]
    try:
        for phase in order[order.index(target):]:
            run_single_live_phase(sup, phase, cand)
    except PhaseFailure as exc:
        reason = str(exc)
        summ = summarize_phase_outputs(itdir)
        status = "FAILED_PHASE"
        if "FAILED_MEMORY_GUARD" in reason or os.path.exists(
                os.path.join(itdir, "train", "TRAIN_ABORT.json")):
            status = "FAILED_MEMORY_GUARD"
        elif summ.get("rollout_manifest.json", {}).get("status") == \
                "BLOCKED_NO_SIGNAL":
            status = "BLOCKED_NO_SIGNAL"
        if status == "BLOCKED_NO_SIGNAL":
            # Recoverable: skip, keep champion, continue with fresh seeds
            # next iteration on a fresh supervisor run.
            records = record_skipped_no_signal(
                iteration, cand, reason, summ)
            champ = current_champion(records)
            sup = fresh_supervisor_for_continuation(records)
            update_state({"current_phase": sup.state.current_phase})
            return run_live_iterations(sup, records, iteration + 1,
                                       max_iterations=None, one_cycle=False)
        update_state({"status": status, "current_phase": "FAILED",
                      "failure_reason": reason[:2000]})
        LOG.error("resume iteration %d stopped: %s: %s", iteration,
                  status, reason)
        return 1
    except RuntimeError as exc:
        update_state({"status": "FAILED_PHASE",
                      "failure_reason": str(exc)[:2000]})
        LOG.error("resume iteration %d stopped: %s", iteration, exc)
        return 1

    evaluation_id = f"eval_it{iteration:06d}_{cand}_vs_{champ_label}"
    decision_raw = W.build_eval_decision(itdir, cand, champ_label,
                                         evaluation_id)
    sup.apply_eval_decision(decision_raw)
    result = {"iteration": iteration, "candidate_id": cand,
              "champion_before": champ_label,
              "champion_adapter_before": champ_adapter or None,
              "started_at": st.get("last_phase_start", ""),
              "live": True, "resumed": True,
              "decision": decision_raw["decision"],
              "decision_reason": decision_raw.get("reason", ""),
              "evaluation_id": evaluation_id,
              "target_phase": sup.state.current_phase,
              "summaries": summarize_phase_outputs(itdir),
              "finished_at": W.utcnow()}
    records, champ = finalize_iteration(result, records)
    LOG.info("resumed iteration %d %s (champion=%s)", iteration,
             result["decision"], champ["checkpoint_id"])
    update_state({"status": "TRAINING_MARATHON_V1_RUNNING",
                  "current_phase": sup.state.current_phase})
    try:
        sup.next_iteration_or_complete(True)
    except Exception as exc:
        update_state({"status": "FAILED_SUPERVISOR",
                      "failure_reason": str(exc)[:2000]})
        return 1
    return run_live_iterations(sup, records, iteration + 1,
                               max_iterations=None, one_cycle=False)


def cmd_one_cycle():
    ensure_dirs()
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s")
    records = ensure_b0_lineage(load_lineage_records())
    st = W.load_marathon_state()
    if not st:
        st = W.new_marathon_state()
        st["status"] = "FIRST_CYCLE"
        W.save_marathon_state(st)
    nxt = int(st.get("current_iteration", 0)) + 1
    run_id = f"marathon-v1-{time.strftime('%Y%m%d-%H%M%S')}"
    sup = make_supervisor(False, run_id, {})
    # Replay file lineage into the supervisor lineage (crash/resume safe).
    sup.lineage = CheckpointLineage.from_state(records)
    sup._persist()
    update_state({"status": "FIRST_CYCLE", "current_iteration": nxt - 1})
    rc = run_live_iterations(sup, records, nxt, max_iterations=1,
                             one_cycle=True)
    if rc == 0:
        update_state({"status": "CYCLE_DONE"})
    return rc


def cmd_marathon(args):
    ensure_dirs()
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s",
        handlers=[logging.FileHandler(os.path.join(W.MARATHON_ROOT,
                                                   "marathon.log"),
                                      encoding="utf-8"),
                  logging.StreamHandler()])
    records = ensure_b0_lineage(load_lineage_records())
    st = W.load_marathon_state() or W.new_marathon_state()
    start = int(args.start_iteration or 0) or \
        int(st.get("current_iteration", 0)) + 1
    run_id = f"marathon-v1-{time.strftime('%Y%m%d-%H%M%S')}"
    sup = make_supervisor(False, run_id, {})
    sup.lineage = CheckpointLineage.from_state(records)
    sup._persist()
    update_state({"status": "TRAINING_MARATHON_V1_RUNNING",
                  "supervisor_run_id": run_id,
                  "supervisor_pid": os.getpid()})
    LOG.info("TRAINING_MARATHON_V1_RUNNING from iteration %d pid=%d",
             start, os.getpid())
    return run_live_iterations(sup, records, start, max_iterations=None,
                               one_cycle=False)


def cmd_status():
    st = W.load_marathon_state()
    sup_state = None
    try:
        rsp = os.path.join(W.MARATHON_ROOT, "run_state.json")
        if os.path.exists(rsp):
            sup_state = json.load(open(rsp, encoding="utf-8"))
    except ValueError:
        pass
    lock_path = os.path.join(W.REAL_LOCKS_DIR, W.MARATHON_LOCK_NAME)
    print(json.dumps({
        "marathon_state": st,
        "supervisor_state": ({
            "run_id": (sup_state or {}).get("run_id"),
            "iteration": (sup_state or {}).get("iteration"),
            "current_phase": (sup_state or {}).get("current_phase"),
            "phase_status": (sup_state or {}).get("phase_status"),
            "champion_id": (sup_state or {}).get("champion_id"),
            "candidate_id": (sup_state or {}).get("candidate_id"),
            "failure_reason": (sup_state or {}).get("failure_reason"),
            "resume_allowed": (sup_state or {}).get("resume_allowed"),
            "resume_target_phase": (sup_state or {}).get(
                "resume_target_phase"),
            "pids": (sup_state or {}).get(
                "process_ids_started_by_supervisor"),
            "transitions": (sup_state or {}).get("transitions", [])[-8:],
        } if sup_state else None),
        "gpu": {"used_gib": W.gpu_used_gib(),
                "host_avail_gib": W.host_avail_gib()},
        "lock": lock_status(lock_path),
        "memory": {"vram_guard_gib": W.DEVICE_GUARD_GIB,
                   "host_guard_gib": W.HOST_GUARD_GIB},
    }, indent=2))
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="TRAINING_MARATHON_V1 runner")
    ap.add_argument("--plan", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--one-cycle", action="store_true")
    ap.add_argument("--marathon", action="store_true")
    ap.add_argument("--resume", action="store_true")
    ap.add_argument("--skip-blocked", action="store_true")
    ap.add_argument("--status", action="store_true")
    ap.add_argument("--stop", action="store_true")
    ap.add_argument("--start-iteration", type=int, default=0)
    args = ap.parse_args(argv)
    if args.stop:
        ensure_dirs()
        open(STOP_FILE, "w").write("stop requested " + W.utcnow())
        print("STOP requested at next phase boundary")
        return 0
    if args.status:
        return cmd_status()
    if args.plan:
        return cmd_plan()
    if args.dry_run:
        return cmd_dry_run()
    if args.one_cycle:
        return cmd_one_cycle()
    if args.resume:
        return cmd_resume()
    if args.skip_blocked:
        return cmd_skip_blocked()
    if args.marathon:
        return cmd_marathon(args)
    ap.print_help()
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
