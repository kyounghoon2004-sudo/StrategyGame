"""BRAIN_VLLM_PHASE1 — client used by the RL orchestrator / debug tooling.

  from tools.brain_vllm import client as BV
  h = BV.start(adapter, session, capture_dir)      # or BV.start(..., gpu_mem_gb=13.5)
  BV.load_adapter(path)                            # hot-swap (no base reload)
  BV.sleep(level=2) ; BV.wake()
  BV.health()
  BV.stop()

CLI (also used by start.cmd / stop.cmd):
  python -m tools.brain_vllm.client start --adapter <dir> --session <tok> --capture-dir <dir>
  python -m tools.brain_vllm.client stop | sleep [--level 2] | wake | load-adapter --path <dir> | health
  python -m tools.brain_vllm.client engine-start [--gpu-mem-gb 13.5] | engine-stop [--hard]
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.brain_vllm import common as C  # noqa: E402

PY = r"D:\StrategyAI\runtimes\qwen3_8b_rl_v0\.venv\Scripts\python.exe"

_state = {"proc": None, "session": None}


def shim_health(port: int = C.SHIM_PORT, timeout: float = 5):
    try:
        code, body = C.http_json(f"http://127.0.0.1:{port}/health", timeout=timeout)
        return body if code == 200 and isinstance(body, dict) else None
    except Exception:  # noqa: BLE001
        return None


def start(adapter: str, session: str, capture_dir: str, gpu_mem_gb: float = C.GPU_MEM_GB_DEFAULT,
          port: int = C.SHIM_PORT, wait_s: int = 1800, env_extra: dict | None = None, log=print) -> dict:
    """Start the shim (which owns the engine session). Returns the ready identity dict."""
    cap = Path(capture_dir)
    cap.mkdir(parents=True, exist_ok=True)
    log(f"[client] start adapter={adapter} session={session} capture={cap}")
    h = shim_health(port)
    if h is not None:
        if h.get("rl_session") == session and h.get("adapter_sha256") == C.adapter_sha(adapter):
            log("[client] reusing running shim")
            return h
        raise RuntimeError(f"port {port} already serves session={h.get('rl_session')} sha={h.get('adapter_sha256')}")
    env = dict(__import__("os").environ)
    if env_extra:
        env.update(env_extra)
    cmd = [PY, "-u", "-m", "tools.brain_vllm.service", "--adapter", adapter, "--session", session,
           "--capture-dir", str(cap), "--gpu-mem-gb", str(gpu_mem_gb), "--port", str(port)]
    proc = subprocess.Popen(cmd, cwd=str(ROOT), env=env,
                            stdout=open(cap / "shim.stdout.log", "a", encoding="utf-8", errors="replace"),
                            stderr=subprocess.STDOUT)
    _state["proc"] = proc
    _state["session"] = session
    t0 = time.time()
    while time.time() - t0 < wait_s:
        if proc.poll() is not None:
            raise SystemExit(f"shim exited rc={proc.returncode} (see {cap / 'shim.stdout.log'})")
        h = shim_health(port)
        if h and h.get("ok") and h.get("rl_session") == session:
            log(f"[client] shim ready in {round(time.time() - t0, 1)}s pid={proc.pid} sha={h.get('adapter_sha256')}")
            return h
        time.sleep(3)
    raise SystemExit("shim did not become ready")


def ensure_idle_engine(log=print) -> dict:
    """Used by debug_group --backend vllm before its GPU-clear assert: an awake
    orphan engine holds ~13 GiB; sleep it (level 2) so the group can start."""
    if not C.engine_up():
        return {"engine": "down"}
    h = shim_health()
    if h and h.get("asleep"):
        return {"engine": "asleep"}
    # 2026-10-02: hard stop (a level-2 sleep discards weights; reusing it produced random tokens)
    log("[client] orphan engine -> hard stop for a clear GPU before the group starts")
    C.engine_stop(hard=True)
    return {"engine": "stopped"}


def stop(port: int = C.SHIM_PORT, timeout: int = 300, hard_engine: bool = False, log=print) -> dict:
    """Shutdown the shim (engine is put to sleep level 2 by the shim)."""
    out = {"shim": False, "engine_stopped": False}
    try:
        C.http_json(f"http://127.0.0.1:{port}/admin/shutdown", {}, method="POST", timeout=30)
        out["shim"] = True
    except Exception as e:  # noqa: BLE001
        log(f"[client] shutdown post failed: {e}")
    t0 = time.time()
    while time.time() - t0 < timeout and shim_health(port, timeout=2) is not None:
        time.sleep(2)
    if hard_engine:
        C.engine_stop(hard=True)
        out["engine_stopped"] = True
    return out


def load_adapter(path: str, port: int = C.SHIM_PORT) -> dict:
    code, body = C.http_json(f"http://127.0.0.1:{port}/admin/load_adapter", {"path": path}, method="POST", timeout=900)
    if code != 200:
        raise RuntimeError(f"load_adapter http {code}: {body}")
    return body


def sleep(level: int = 2, port: int = C.SHIM_PORT) -> dict:
    code, body = C.http_json(f"http://127.0.0.1:{port}/admin/sleep", {"level": level}, method="POST", timeout=600)
    if code != 200:
        raise RuntimeError(f"sleep http {code}: {body}")
    return body


def wake(port: int = C.SHIM_PORT) -> dict:
    code, body = C.http_json(f"http://127.0.0.1:{port}/admin/wake", {}, method="POST", timeout=1200)
    if code != 200:
        raise RuntimeError(f"wake http {code}: {body}")
    return body


def health(port: int = C.SHIM_PORT) -> dict:
    h = shim_health(port)
    if h is None:
        raise SystemExit("shim not reachable")
    return h


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("start")
    s.add_argument("--adapter", required=True)
    s.add_argument("--session", required=True)
    s.add_argument("--capture-dir", required=True)
    s.add_argument("--gpu-mem-gb", type=float, default=C.GPU_MEM_GB_DEFAULT)
    s.add_argument("--port", type=int, default=C.SHIM_PORT)
    st = sub.add_parser("stop")
    st.add_argument("--port", type=int, default=C.SHIM_PORT)
    st.add_argument("--hard-engine", action="store_true")
    sl = sub.add_parser("sleep")
    sl.add_argument("--level", type=int, default=2)
    sl.add_argument("--port", type=int, default=C.SHIM_PORT)
    wk = sub.add_parser("wake")
    wk.add_argument("--port", type=int, default=C.SHIM_PORT)
    la = sub.add_parser("load-adapter")
    la.add_argument("--path", required=True)
    la.add_argument("--port", type=int, default=C.SHIM_PORT)
    hh = sub.add_parser("health")
    hh.add_argument("--port", type=int, default=C.SHIM_PORT)
    es = sub.add_parser("engine-start")
    es.add_argument("--gpu-mem-gb", type=float, default=C.GPU_MEM_GB_DEFAULT)
    ep = sub.add_parser("engine-stop")
    ep.add_argument("--hard", action="store_true")
    a = ap.parse_args()
    if a.cmd == "start":
        print(json.dumps(start(a.adapter, a.session, a.capture_dir, a.gpu_mem_gb, a.port), indent=1))
    elif a.cmd == "stop":
        print(json.dumps(stop(a.port, hard_engine=a.hard_engine), indent=1))
    elif a.cmd == "sleep":
        print(json.dumps(sleep(a.level, a.port), indent=1))
    elif a.cmd == "wake":
        print(json.dumps(wake(a.port), indent=1))
    elif a.cmd == "load-adapter":
        print(json.dumps(load_adapter(a.path, a.port), indent=1))
    elif a.cmd == "health":
        print(json.dumps(health(a.port), indent=1))
    elif a.cmd == "engine-start":
        print(json.dumps(C.engine_start(a.gpu_mem_gb, log=print), indent=1))
    elif a.cmd == "engine-stop":
        C.engine_stop(hard=a.hard)
        print("engine stopped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
