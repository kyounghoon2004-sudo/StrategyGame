"""TRAINING_MARATHON_V1 — production wiring for the TrainingSupervisor.

Fills the scaffold's UNWIRED command contracts with the exact proven
MANUAL_RL_LOOP_V1 phase commands (parameterized per iteration), plus the
real manifest checkers, the deterministic promotion decision builder,
memory guards, seed allocation, and the production GPU lock.

This module ONLY ADDS wiring. It does not modify the scaffold's tested
state machine, atomic persistence, process ownership, GPU lock protocol,
checkpoint lineage, or crash/resume logic.
"""
from __future__ import annotations

import json
import os
import subprocess
import time
from typing import Any, Dict, List, Optional, Tuple

PROJECT_ROOT = r"D:\Game development\Demon slayer\StrategyGame"
SUPERVISOR_DIR = os.path.join(PROJECT_ROOT, "tools", "training_supervisor")
MARATHON_ROOT = os.path.join(PROJECT_ROOT, "artifacts", "training_marathon_v1")

RL_VENV_PYTHON = r"D:\StrategyAI\runtimes\qwen3_8b_rl_v0\.venv\Scripts\python.exe"

ROLLOUT_SCRIPT = os.path.join(SUPERVISOR_DIR, "marathon_phase_rollout.py")
TRAIN_SCRIPT = os.path.join(SUPERVISOR_DIR, "marathon_phase_train.py")
EVAL_SCRIPT = os.path.join(SUPERVISOR_DIR, "marathon_phase_eval.py")

REAL_LOCKS_DIR = r"D:\StrategyAI\locks"
MARATHON_LOCK_NAME = "training_marathon_v1.lock"

# Locked operational constants (mirror the marathon contract).
MAX_GROUPS = 8
NEED_INFORMATIVE = 2
OPTIMIZER_STEPS_PER_ITERATION = 2
EVAL_MATCHES_PER_ITERATION = 4
DEVICE_GUARD_GIB = 20.5
HOST_GUARD_GIB = 16.0
GPU_IDLE_GIB = 2.0  # GPU must return near idle between phases.

TIMEOUTS = {"ROLLOUT": 3600.0, "TRAIN_BRAIN": 3600.0, "EVAL": 3600.0}

# Deterministic seed plan. Manual-loop seeds (2101-2108, 8001/8002) are
# never reused. Training and eval streams stay separate.
TRAIN_SEED_BASE = 3101
TRAIN_SEED_STRIDE = 100  # iteration N consumes up to MAX_GROUPS*2 seeds.
EVAL_SEED_BASE = 9101
EVAL_SEED_STRIDE = 10


# Versioned GRPO reward contract (training signal only; eval/promotion never
# read it). Iterations 1..83 ran REWARD_CONTRACT_V1 and are never
# reinterpreted; V2 activates at a clean iteration boundary (V1 marathon
# stopped at PREPARE after iteration 83, champion T0053).
REWARD_CONTRACT_V1 = "REWARD_CONTRACT_V1"
REWARD_CONTRACT_V2 = "REWARD_CONTRACT_V2"
REWARD_CONTRACT_V2_FIRST_ITERATION = 84


def reward_contract_for_iteration(iteration: int) -> str:
    return (REWARD_CONTRACT_V2 if iteration >= REWARD_CONTRACT_V2_FIRST_ITERATION
            else REWARD_CONTRACT_V1)


def _iteration_of_dir(itdir: str) -> Optional[int]:
    name = os.path.basename(os.path.normpath(itdir))
    if name.startswith("iteration_") and name[len("iteration_"):].isdigit():
        return int(name[len("iteration_"):])
    return None


def train_seed_start(iteration: int) -> int:
    return TRAIN_SEED_BASE + (iteration - 1) * TRAIN_SEED_STRIDE


def eval_seeds(iteration: int) -> List[int]:
    base = EVAL_SEED_BASE + (iteration - 1) * EVAL_SEED_STRIDE
    return [base, base + 1]


def iteration_dir(iteration: int) -> str:
    return os.path.join(MARATHON_ROOT, "iterations",
                        f"iteration_{iteration:06d}")


def candidate_id(iteration: int) -> str:
    return f"T{iteration:04d}"


# ----------------------------------------------------------------------
# phase specs
# ----------------------------------------------------------------------
def build_phase_specs(itdir: str, champion_adapter: str, candidate_out: str,
                      champion_label: str, cand_label: str,
                      train_seed: int, eval_seed_pair: List[int]
                      ) -> Dict[str, Dict[str, Any]]:
    """Return SupervisorConfig-ready phase_specs for one iteration."""
    rollout_out = os.path.join(itdir, "rollout", "rollout_manifest.json")
    train_out = os.path.join(itdir, "train", "train_summary.json")
    eval_out = os.path.join(itdir, "eval", "eval_summary.json")
    it_no = _iteration_of_dir(itdir)
    reward_contract = reward_contract_for_iteration(it_no) \
        if it_no is not None else REWARD_CONTRACT_V1
    return {
        "ROLLOUT": {
            "phase": "ROLLOUT",
            "command": RL_VENV_PYTHON,
            "args": [ROLLOUT_SCRIPT, "--iteration-dir", itdir,
                     "--champion-adapter", champion_adapter or "",
                     "--candidate-label", cand_label,
                     "--train-seed-start", str(train_seed),
                     "--max-groups", str(MAX_GROUPS),
                     "--need-informative", str(NEED_INFORMATIVE),
                     "--reward-contract", reward_contract],
            "cwd": PROJECT_ROOT,
            "env": {},
            "timeout_sec": TIMEOUTS["ROLLOUT"],
            "expected_outputs": [rollout_out],
        },
        "TRAIN_BRAIN": {
            "phase": "TRAIN_BRAIN",
            "command": RL_VENV_PYTHON,
            "args": [TRAIN_SCRIPT, "--iteration-dir", itdir,
                     "--champion-adapter", champion_adapter or "",
                     "--candidate-out", candidate_out],
            "cwd": PROJECT_ROOT,
            "env": {},
            "timeout_sec": TIMEOUTS["TRAIN_BRAIN"],
            "expected_outputs": [train_out, os.path.join(
                candidate_out, "adapter_model.safetensors")],
        },
        "EVAL": {
            "phase": "EVAL",
            "command": RL_VENV_PYTHON,
            "args": [EVAL_SCRIPT, "--iteration-dir", itdir,
                     "--champion-adapter", champion_adapter or "",
                     "--candidate-adapter", candidate_out,
                     "--eval-seeds", str(eval_seed_pair[0]),
                     str(eval_seed_pair[1]),
                     "--champion-label", champion_label,
                     "--candidate-label", cand_label],
            "cwd": PROJECT_ROOT,
            "env": {},
            "timeout_sec": TIMEOUTS["EVAL"],
            "expected_outputs": [eval_out],
        },
    }


# ----------------------------------------------------------------------
# manifest checkers (completeness proof per phase)
# ----------------------------------------------------------------------
def _read_json(path: str) -> Optional[Dict[str, Any]]:
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else None
    except (OSError, ValueError):
        return None


def check_rollout(itdir: str) -> Tuple[bool, str]:
    man = _read_json(os.path.join(itdir, "rollout", "rollout_manifest.json"))
    if not man:
        return False, "rollout_manifest.json missing/unreadable"
    if man.get("status") != "ROLLOUT_DONE":
        return False, f"rollout status={man.get('status')}"
    # Activation proof: a rollout must have been scored under the contract
    # active for its iteration. V1-era manifests carry no version field.
    it_no = _iteration_of_dir(itdir)
    if it_no is not None:
        want = reward_contract_for_iteration(it_no)
        got = man.get("reward_contract_version")
        if want == REWARD_CONTRACT_V2 and got != want:
            return False, f"reward_contract_version={got} != {want}"
        if want == REWARD_CONTRACT_V1 and got not in (None, want):
            return False, f"reward_contract_version={got} != {want}"
    groups = man.get("groups_attempted") or []
    inf = [g for g in groups if g.get("informative")]
    if len(inf) < NEED_INFORMATIVE:
        return False, f"informative {len(inf)} < {NEED_INFORMATIVE}"
    for g in inf:
        rewards = g.get("rewards") or []
        adv = g.get("advantages") or []
        if len(set(rewards)) < 2:
            return False, f"group{g.get('group_index')}: no reward spread"
        if not any(abs(a) > 1e-9 for a in adv):
            return False, f"group{g.get('group_index')}: zero advantage"
        gi = g.get("group_index")
        for s in g.get("seeds", []):
            if not os.path.exists(os.path.join(
                    itdir, "rollout", f"group{gi}_s{s}.txt")):
                return False, f"group{gi} seed {s} text missing"
    return True, (f"ROLLOUT_DONE n_attempted={man.get('n_attempted')} "
                  f"n_informative={len(inf)} "
                  f"reward_contract={man.get('reward_contract_version') or REWARD_CONTRACT_V1}")


def check_train(itdir: str, candidate_out: str) -> Tuple[bool, str]:
    summ = _read_json(os.path.join(itdir, "train", "train_summary.json"))
    if not summ:
        return False, "train_summary.json missing/unreadable"
    if summ.get("status") != "TRAIN_DONE":
        return False, f"train status={summ.get('status')}"
    if summ.get("optimizer_steps") != OPTIMIZER_STEPS_PER_ITERATION:
        return False, (f"optimizer_steps={summ.get('optimizer_steps')} "
                       f"!= {OPTIMIZER_STEPS_PER_ITERATION}")
    if not summ.get("adapter_saved"):
        return False, "adapter_saved is false"
    if not os.path.exists(os.path.join(candidate_out,
                                       "adapter_model.safetensors")):
        return False, "adapter_model.safetensors missing"
    if summ.get("peak_device_vram_gib", 99) > DEVICE_GUARD_GIB:
        return False, "train peak VRAM breached guard"
    if summ.get("minimum_available_system_ram_gib", 0) < HOST_GUARD_GIB:
        return False, "train min host RAM breached guard"
    if not summ.get("lora_changed_tensors"):
        return False, "LoRA changed tensors == 0"
    return True, (f"TRAIN_DONE steps={summ.get('optimizer_steps')} "
                  f"peak={summ.get('peak_device_vram_gib')}GiB")


def check_eval(itdir: str) -> Tuple[bool, str]:
    summ = _read_json(os.path.join(itdir, "eval", "eval_summary.json"))
    if not summ:
        return False, "eval_summary.json missing/unreadable"
    if summ.get("status") != "EVAL_DONE":
        return False, f"eval status={summ.get('status')}"
    matches = summ.get("matches") or []
    if len(matches) != EVAL_MATCHES_PER_ITERATION:
        return False, f"matches={len(matches)} != 4"
    required = ("winner", "candidate_result", "champion_result",
                "candidate_contract_valid", "terminal_reason", "turns",
                "seed", "candidate_side")
    for m in matches:
        for k in required:
            if k not in m:
                return False, f"{m.get('match_id')}: missing {k}"
        if m.get("candidate_reward") not in (5, -3, -2):
            return False, f"{m.get('match_id')}: bad reward"
    if summ.get("decision") not in ("PROMOTE", "REJECT"):
        return False, f"decision={summ.get('decision')}"
    return True, (f"EVAL_DONE W{summ.get('wins')}/L{summ.get('losses')}/"
                  f"D{summ.get('draws')} strict={summ.get('strict_failures')} "
                  f"{summ.get('decision')}")


def iteration_dir_from_spec(spec) -> Optional[str]:
    args = list(getattr(spec, "args", []) or [])
    for i, a in enumerate(args):
        if a == "--iteration-dir" and i + 1 < len(args):
            return args[i + 1]
    return None


def candidate_out_from_spec(spec) -> Optional[str]:
    args = list(getattr(spec, "args", []) or [])
    for i, a in enumerate(args):
        if a == "--candidate-out" and i + 1 < len(args):
            return args[i + 1]
        if a == "--candidate-adapter" and i + 1 < len(args):
            return args[i + 1]
    return None


def marathon_manifest_checker(phase: str, spec, context) -> bool:
    """Real completeness proof injected into the supervisor."""
    itdir = iteration_dir_from_spec(spec)
    if not itdir:
        return False
    if phase == "ROLLOUT":
        ok, _ = check_rollout(itdir)
        return ok
    if phase == "TRAIN_BRAIN":
        ok, _ = check_train(itdir, candidate_out_from_spec(spec) or "")
        return ok
    if phase == "EVAL":
        ok, _ = check_eval(itdir)
        return ok
    return False


# ----------------------------------------------------------------------
# promotion decision (deterministic operational rule)
# ----------------------------------------------------------------------
def build_eval_decision(itdir: str, cand_label: str, champ_label: str,
                       evaluation_id: str) -> Dict[str, Any]:
    summ = _read_json(os.path.join(itdir, "eval", "eval_summary.json")) or {}
    strict = int(summ.get("strict_failures", 999))
    wins = int(summ.get("wins", 0))
    losses = int(summ.get("losses", 0))
    draws = int(summ.get("draws", 0))
    if strict == 0 and wins > losses:
        decision = "PROMOTE"
        reason = (f"operational rule: strict_failures==0 and wins({wins}) > "
                  f"losses({losses}); draws={draws}")
    else:
        decision = "REJECT"
        reason = (f"operational rule: strict_failures={strict} wins={wins} "
                  f"losses={losses} draws={draws} "
                  f"(PROMOTE needs strict==0 and wins>losses)")
    return {"decision": decision, "candidate_id": cand_label,
            "champion_id": champ_label, "evaluation_id": evaluation_id,
            "metrics": {"wins": wins, "losses": losses, "draws": draws,
                        "strict_failures": strict,
                        "eval_seeds": summ.get("eval_seeds", [])},
            "reason": reason}


# ----------------------------------------------------------------------
# memory helpers (supervisor-side guards)
# ----------------------------------------------------------------------
def gpu_used_gib() -> float:
    try:
        p = subprocess.run(["nvidia-smi", "--query-gpu=memory.used",
                            "--format=csv,noheader,nounits"],
                           capture_output=True, text=True, timeout=20)
        return round(float(p.stdout.strip().splitlines()[0]) / 1024, 3)
    except Exception:
        return -1.0


def host_avail_gib() -> float:
    try:
        import psutil
        return round(psutil.virtual_memory().available / 2**30, 3)
    except Exception:
        try:
            import ctypes

            class MS(ctypes.Structure):
                _fields_ = [("dwLength", ctypes.c_ulong),
                            ("dwMemoryLoad", ctypes.c_ulong),
                            ("ullTotalPhys", ctypes.c_ulonglong),
                            ("ullAvailPhys", ctypes.c_ulonglong),
                            ("ullTotalPageFile", ctypes.c_ulonglong),
                            ("ullAvailPageFile", ctypes.c_ulonglong),
                            ("ullTotalVirtual", ctypes.c_ulonglong),
                            ("ullAvailVirtual", ctypes.c_ulonglong),
                            ("ullAvailExtendedVirtual", ctypes.c_ulonglong)]

            ms = MS()
            ms.dwLength = ctypes.sizeof(MS)
            ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(ms))
            return round(ms.ullAvailPhys / 2**30, 3)
        except Exception:
            return -1.0


def memory_healthy() -> Tuple[bool, str]:
    d = gpu_used_gib()
    h = host_avail_gib()
    if d >= 0 and d > DEVICE_GUARD_GIB:
        return False, f"device VRAM {d} GiB > {DEVICE_GUARD_GIB}"
    if h >= 0 and h < HOST_GUARD_GIB:
        return False, f"host avail RAM {h} GiB < {HOST_GUARD_GIB}"
    return True, f"device={d}GiB host_avail={h}GiB"


def gpu_near_idle() -> Tuple[bool, str]:
    d = gpu_used_gib()
    if d >= 0 and d > GPU_IDLE_GIB:
        return False, f"GPU not near idle: {d} GiB in use"
    return True, f"GPU near idle: {d} GiB"


# ----------------------------------------------------------------------
# marathon state / lineage files
# ----------------------------------------------------------------------
def utcnow() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()) + "Z"


def marathon_state_path() -> str:
    return os.path.join(MARATHON_ROOT, "MARATHON_STATE.json")


def champion_lineage_path() -> str:
    return os.path.join(MARATHON_ROOT, "CHAMPION_LINEAGE.json")


def load_marathon_state() -> Dict[str, Any]:
    try:
        with open(marathon_state_path(), "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save_marathon_state(state: Dict[str, Any]) -> None:
    os.makedirs(MARATHON_ROOT, exist_ok=True)
    tmp = marathon_state_path() + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2)
        f.flush()
        try:
            os.fsync(f.fileno())
        except OSError:
            pass
    os.replace(tmp, marathon_state_path())


def new_marathon_state() -> Dict[str, Any]:
    return {"marathon": "TRAINING_MARATHON_V1", "status": "INITIALIZING",
            "current_iteration": 0, "current_phase": "IDLE",
            "champion_id": "B0", "champion_adapter": None,
            "candidate_id": None, "last_phase_start": None,
            "last_heartbeat": utcnow(), "last_decision": None,
            "vram_peak_gib": None, "min_free_ram_gib": None,
            "optimizer_steps_total": 0, "wins": 0, "losses": 0, "draws": 0,
            "strict_failures_total": 0, "supervisor_pid": os.getpid(),
            "supervisor_run_id": None, "state_file": marathon_state_path(),
            "log_file": os.path.join(MARATHON_ROOT, "marathon.log")}
