"""Shared plumbing for the vLLM-backed Brain service (Phase 1).

Windows side helpers: WSL command execution, path translation, adapter copy
into WSL's ext4 disk, engine lifecycle (start/sleep/wake/stop), HTTP JSON.
All model rendering/tokenization stays on the Windows side in
tools.contract_sft.gpu_common (G); this module never tokenizes.
"""
from __future__ import annotations

import json
import math
import os
import shlex
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Dict, Optional, Tuple

ROOT = Path(r"D:\Game development\Demon slayer\StrategyGame")

DISTRO = "Ubuntu-24.04"
WSL_HOME = "/opt/brain_vllm"
WSL_VENV = WSL_HOME + "/venv"
WSL_BASE = "/opt/models/Qwen3-8B"
WSL_ADAPTERS = "/opt/adapters"
RUN_SCRIPT = WSL_HOME + "/run_vllm.sh"
SETUP_LOG = WSL_HOME + "/logs/setup.log"

BASE_WIN = r"D:\StrategyAI\models\Qwen3-8B"

ENGINE_URL = "http://127.0.0.1:8000"
SHIM_URL = "http://127.0.0.1:8096"
SHIM_PORT = 8096

GPU_MEM_GB_DEFAULT = 14.0  # 2026-10-02: +0.5 GB KV for 10k-token review prompts
MAX_MODEL_LEN = 10240  # 2026-10-02: review prompts reach ~7k tokens + 1280 out (12288 does not fit the KV budget)


# ------------------------------------------------------------------ WSL glue
def wsl(cmd: str, timeout: Optional[int] = 600, check: bool = True) -> subprocess.CompletedProcess:
    """Run a bash command inside the WSL distro as root. UTF-8 decoded."""
    p = subprocess.run(["wsl.exe", "-d", DISTRO, "-u", "root", "--", "bash", "-lc", cmd],
                       capture_output=True, timeout=timeout)
    out = (p.stdout or b"").decode("utf-8", "replace")
    err = (p.stderr or b"").decode("utf-8", "replace")
    if check and p.returncode != 0:
        raise RuntimeError(f"wsl command failed rc={p.returncode}: {cmd[:200]}\n{out[-2000:]}\n{err[-2000:]}")
    p.out_text = out  # type: ignore[attr-defined]
    p.err_text = err  # type: ignore[attr-defined]
    return p


def wsl_distro_present() -> bool:
    p = subprocess.run(["wsl.exe", "-l", "-q"], capture_output=True)
    txt = (p.stdout or b"").decode("utf-16-le", "replace") if b"\x00" in (p.stdout or b"") \
        else (p.stdout or b"").decode("utf-8", "replace")
    return any(line.strip() == DISTRO for line in txt.splitlines())


def win_to_wsl(path: str) -> str:
    p = str(path).replace("\\", "/")
    if len(p) > 1 and p[1] == ":":
        return "/mnt/" + p[0].lower() + p[2:]
    return p


def gpu_total_gib() -> float:
    p = subprocess.run(["nvidia-smi", "--query-gpu=memory.total", "--format=csv,noheader,nounits"],
                       capture_output=True, text=True, timeout=15)
    return round(float(p.stdout.strip().splitlines()[0]) / 1024, 3)


def gpu_used_mib() -> int:
    try:
        p = subprocess.run(["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits"],
                           capture_output=True, text=True, timeout=15)
        return int(p.stdout.strip().splitlines()[0])
    except Exception:  # noqa: BLE001
        return -1


def gpu_util_fraction(gpu_mem_gb: float) -> float:
    """vLLM gpu_memory_utilization so that util * total <= gpu_mem_gb."""
    total = gpu_total_gib()
    v = math.floor((gpu_mem_gb / total) * 10_000) / 10_000
    return min(0.90, v)


# ------------------------------------------------------------------ HTTP JSON
def http_json(url: str, obj: Optional[dict] = None, method: Optional[str] = None,
              timeout: float = 900) -> Tuple[int, Any]:
    data = json.dumps(obj).encode("utf-8") if obj is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Content-Type": "application/json"} if data is not None else {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            body = r.read().decode("utf-8", "replace")
            try:
                return r.status, json.loads(body) if body else None
            except ValueError:
                return r.status, body
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        try:
            return e.code, json.loads(body) if body else None
        except ValueError:
            return e.code, body


_ENGINE_PROC: Dict[str, Any] = {"p": None, "log": None}


def engine_up(timeout: float = 3) -> bool:
    try:
        code, _ = http_json(ENGINE_URL + "/health", timeout=timeout)
        return code == 200
    except Exception:  # noqa: BLE001
        return False


def engine_sleeping() -> bool:
    """True when the engine process is up but asleep (weights discarded/offloaded)."""
    try:
        code, body = http_json(ENGINE_URL + "/is_sleeping", timeout=5)
        return code == 200 and isinstance(body, dict) and bool(body.get("is_sleeping"))
    except Exception:  # noqa: BLE001
        return False


def engine_start(gpu_mem_gb: float = GPU_MEM_GB_DEFAULT, wait_s: int = 900, log=None) -> Dict[str, Any]:
    """Ensure the vLLM engine is up (start if needed; wake if asleep).

    This host kills every process family shortly after the wsl.exe session that
    spawned it exits (verified: even systemd transient units stop ~18 s after
    their launching session ends). The engine is therefore NOT detached: it runs
    as the foreground child of a held `wsl.exe` session owned by THIS process —
    the engine lives exactly as long as its owner (shim / generate / the test
    tool). When the owner exits, the engine session ends and the GPU is freed.
    """
    info: Dict[str, Any] = {"started": False, "load_s": 0.0, "gpu_total_gib": gpu_total_gib()}
    if engine_up():
        if not engine_sleeping():
            return info
        # 2026-10-02: a level-2 sleep discards the weights and wake_up does not reload them -> the engine
        # emitted random tokens (S1 live check). Never reuse a sleeping engine: stop it and boot fresh.
        if log:
            log("[engine] engine is asleep -> hard stop + fresh boot (level-2 wake does not reload weights)")
        engine_stop(hard=True)
        t_stop = time.time()
        while engine_up(timeout=2) and time.time() - t_stop < 120:
            time.sleep(3)
    util = gpu_util_fraction(gpu_mem_gb)
    info["util"] = util
    logfile = ROOT / "artifacts" / "brain_pipeline_v1" / "vllm" / "logs" / \
        f"vllm_{time.strftime('%Y%m%d_%H%M%S')}.log"
    logfile.parent.mkdir(parents=True, exist_ok=True)
    info["logfile"] = str(logfile)
    if log:
        log(f"[engine] starting vLLM (gpu_memory_utilization={util} of {info['gpu_total_gib']} GiB) log={logfile}")
    cmd = ["wsl.exe", "-d", DISTRO, "-u", "root", "--", "bash", "-lc",
           f"cd {WSL_HOME} && VLLM_GPU_UTIL={util:.4f} exec bash {RUN_SCRIPT}"]
    p = subprocess.Popen(cmd, stdout=open(logfile, "w", encoding="utf-8", errors="replace"),
                         stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, creationflags=0x08000000)
    _ENGINE_PROC["p"] = p
    _ENGINE_PROC["log"] = str(logfile)
    t0 = time.time()
    while time.time() - t0 < wait_s:
        if p.poll() is not None:
            tail = ""
            try:
                tail = logfile.read_text(encoding="utf-8", errors="replace")[-3000:]
            except Exception:  # noqa: BLE001
                pass
            raise RuntimeError(f"vLLM engine exited rc={p.returncode} (log {logfile}).\n{tail}")
        if engine_up():
            info.update(started=True, load_s=round(time.time() - t0, 1), pid=p.pid)
            if log:
                log(f"[engine] up after {info['load_s']}s pid={p.pid}")
            return info
        time.sleep(3)
    raise RuntimeError(f"vLLM engine did not come up within {wait_s}s (log {logfile})")


def engine_sleep(level: int = 2) -> Dict[str, Any]:
    t0 = time.time()
    code, body = http_json(ENGINE_URL + f"/sleep?level={level}", {}, method="POST", timeout=300)
    if code != 200:
        raise RuntimeError(f"sleep failed http {code}: {str(body)[:500]}")
    time.sleep(2)
    time.sleep(1)
    return {"level": level, "sleep_s": round(time.time() - t0, 1), "gpu_used_mib_after": gpu_used_mib()}


def engine_wake() -> Dict[str, Any]:
    t0 = time.time()
    code, body = http_json(ENGINE_URL + "/wake_up", {}, method="POST", timeout=600)
    if code != 200:
        raise RuntimeError(f"wake_up failed http {code}: {str(body)[:500]}")
    t = round(time.time() - t0, 1)
    while not engine_up(timeout=5) and time.time() - t0 < 300:
        time.sleep(2)
    return {"wake_s": t, "engine_up": engine_up()}


def engine_stop(hard: bool = False) -> None:
    """Stop the vLLM engine: terminate the held session (own process) if any,
    else pkill inside WSL. hard=True also terminates the distro."""
    p = _ENGINE_PROC.get("p")
    if p is not None and p.poll() is None:
        try:
            p.terminate()
        except Exception:  # noqa: BLE001
            pass
    wsl("pkill -f 'vllm serve' || true; sleep 2; pkill -9 -f 'vllm serve' || true; echo stopped", timeout=120, check=False)
    if hard:
        subprocess.run(["wsl.exe", "--terminate", DISTRO], capture_output=True, timeout=120)
    t0 = time.time()
    while time.time() - t0 < 60 and engine_up(timeout=2):
        time.sleep(2)


# ------------------------------------------------------------------ adapters
def adapter_sha(dir_win: str) -> str:
    from tools.contract_sft import gpu_common as G
    f = Path(dir_win) / "adapter_model.safetensors"
    if not f.exists():
        raise FileNotFoundError(str(f))
    return G.file_sha256(str(f))


def ensure_adapter_in_wsl(dir_win: str, log=None) -> Tuple[str, str]:
    """Copy adapter (content-addressed by sha256) into WSL ext4. Returns (sha, wsl_dir)."""
    sha = adapter_sha(dir_win)
    d8 = sha[:8]
    dest = f"{WSL_ADAPTERS}/{d8}"
    src = win_to_wsl(dir_win)
    cmd = (f"if [ ! -f {dest}/adapter_model.safetensors ]; then "
           f"rm -rf {dest}.tmp && mkdir -p {dest}.tmp && cp -r {shlex.quote(src)}/. {dest}.tmp/ && mv {dest}.tmp {dest}; "
           f"fi; sha256sum {dest}/adapter_model.safetensors | cut -d' ' -f1")
    p = wsl(cmd, timeout=600)
    got = p.out_text.strip().splitlines()[-1].strip()
    if got != sha:
        raise RuntimeError(f"adapter copy sha mismatch in WSL: {got} != {sha}")
    if log:
        log(f"[adapter] {dir_win} -> {dest} sha={sha[:12]}...")
    return sha, dest


def load_lora_into_engine(dir_win: str, current_lora: Optional[str] = None, log=None) -> Dict[str, Any]:
    """Ensure adapter is in WSL and registered in the engine as a dynamic LoRA.
    Unloads current_lora first when different. Returns {sha, wsl_dir, lora_name, load_s}. """
    sha, wsl_dir = ensure_adapter_in_wsl(dir_win, log=log)
    name = "brain_" + sha[:8]
    if current_lora and current_lora != name:
        http_json(ENGINE_URL + "/v1/unload_lora_adapter", {"lora_name": current_lora}, method="POST", timeout=120)
    t0 = time.time()
    code, body = http_json(ENGINE_URL + "/v1/load_lora_adapter", {"lora_name": name, "lora_path": wsl_dir},
                           method="POST", timeout=300)
    if code != 200:
        msg = str(body)
        if "already" in msg.lower() or "exist" in msg.lower():
            if log:
                log(f"[adapter] {name} already loaded")
        else:
            raise RuntimeError(f"load_lora_adapter failed http {code}: {msg[:600]}")
    load_s = round(time.time() - t0, 1)
    if log:
        log(f"[adapter] engine lora {name} ready in {load_s}s")
    return {"sha": sha, "wsl_dir": wsl_dir, "lora_name": name, "load_s": load_s}
