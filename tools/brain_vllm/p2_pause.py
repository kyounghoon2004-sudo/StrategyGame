"""One-off operator tool: cleanly pause the Phase-2 review-corpus harvest to free the GPU.

Stops, in order: the teacher proxy (:8096), the brain serve (:8106 -> releases the
project GPU lock), the harvest/proxy/serve/hands python processes, and the arena
Godot windows (matched by res://tools/rl_arena.gd in their command line).
Then reports lock/port/GPU state. Never touches anything else.

  python tools/brain_vllm/p2_pause.py [--dry-run]
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

LOCK = Path(r"D:\StrategyAI\locks\training_marathon_v1.lock")


def ps_list():
    out = subprocess.run(["powershell.exe", "-NoProfile", "-Command",
                          "Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId,Name,CommandLine | ConvertTo-Json -Compress"],
                         capture_output=True, text=True, timeout=120).stdout
    try:
        d = json.loads(out)
        return d if isinstance(d, list) else [d]
    except ValueError:
        return []


def post(port: int, path: str, obj: dict, timeout: int = 10):
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=json.dumps(obj).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def kill(pid: int, dry: bool) -> str:
    if dry:
        return f"DRY kill {pid}"
    p = subprocess.run(["taskkill", "/PID", str(pid), "/F", "/T"], capture_output=True, text=True, timeout=60)
    return f"kill {pid}: rc={p.returncode} {p.stdout.strip().splitlines()[-1] if p.stdout.strip() else ''}"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    procs = ps_list()
    print(f"[pause] {len(procs)} processes visible")
    endpoints = [(8096, "teacher proxy"), (8106, "brain serve (holds GPU lock)")]
    for port, label in endpoints:
        try:
            post(port, "/admin/shutdown", {})
            print(f"[pause] /admin/shutdown -> {label} :{port} ok")
        except Exception as e:  # noqa: BLE001
            print(f"[pause] /admin/shutdown -> {label} :{port} failed/skipped: {e}")
    time.sleep(10)
    targets = []
    for p in procs:
        cmd = p.get("CommandLine") or ""
        pid = p.get("ProcessId")
        if ("brain_review.harvest" in cmd or "brain_review.teacher_proxy" in cmd
                or ("tools.contextual_brain.rl_vs_utility" in cmd and " serve " in cmd and "8106" in cmd)
                or "hands_worker" in cmd or "rl_arena.gd" in cmd):
            targets.append((pid, ("harvest" if "harvest" in cmd else
                                  "proxy" if "teacher_proxy" in cmd else
                                  "serve" if "rl_vs_utility" in cmd else
                                  "hands" if "hands_worker" in cmd else "arena"), cmd[:110]))
    for pid, kind, cmd in targets:
        print(f"[pause] stop {kind} pid={pid} :: {cmd}")
        print("[pause]  ", kill(pid, a.dry_run))
    if not a.dry_run:
        time.sleep(5)
        print(f"[pause] lock exists after stop: {LOCK.exists()}")
        import subprocess as sp
        gpu = sp.run(["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader"], capture_output=True, text=True).stdout.strip()
        print(f"[pause] gpu used now: {gpu}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
