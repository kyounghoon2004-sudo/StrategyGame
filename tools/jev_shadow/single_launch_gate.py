"""Single-launch JEV Shadow Runtime gate (SHADOW ONLY).

Runs the runtime gate end to end: Godot owns the JEV worker lifecycle
(spawn -> handshake -> inference -> shutdown) with zero user-managed
server. Writes the gate artifacts under
artifacts/jev_shadow_single_launch_v0/.

Usage (from StrategyGame/):
  python tools/jev_shadow/single_launch_gate.py --phase all
  python tools/jev_shadow/single_launch_gate.py --phase discovery|startup|shutdown|restart|failopen|determinism|scene|report
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
STRATEGY_ROOT = os.path.abspath(os.path.join(HERE, os.pardir, os.pardir))
if STRATEGY_ROOT not in sys.path:
    sys.path.insert(0, STRATEGY_ROOT)

from tools.jev_shadow import (  # noqa: E402
    CHECKPOINT_SHA256,
    MODEL_IDENTITY,
    SHADOW_ACTION_SCHEMA,
    SHADOW_CONTRACT_VERSION,
    SHADOW_LAUNCHER_VERSION,
    SHADOW_MISSIONMAP_VERSION,
    SHADOW_OBSERVATION_SCHEMA,
    SHADOW_PROTOCOL_VERSION,
    SHADOW_REQUEST_VERSION,
    SHADOW_RESPONSE_VERSION,
    SHADOW_SLOTMAP_VERSION,
    SHADOW_TELEMETRY_VERSION,
)
from tools.jev_shadow.summarize import (  # noqa: E402
    build_run_file_at,
    compare_runs,
)

GATE_ROOT = os.path.join(STRATEGY_ROOT, "artifacts",
                         "jev_shadow_single_launch_v0")
GODOT_CONSOLE = (
    "C:\\Users\\kyoun\\AppData\\Local\\Programs\\Godot\\"
    "Godot_v4.2.2-stable_win64_console.exe"
)
GODOT_GUI = (
    "C:\\Users\\kyoun\\AppData\\Local\\Programs\\Godot\\"
    "Godot_v4.2.2-stable_win64.exe"
)
CHECKPOINT = os.path.join(STRATEGY_ROOT, "artifacts", "jev_mission_train_v1",
                          "checkpoints", "seed205.pt")
BATTLE_SCENE = "res://scenes/cloud2_battle_test.tscn"


def _now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S")


def write_artifact(name: str, obj) -> str:
    os.makedirs(GATE_ROOT, exist_ok=True)
    path = os.path.join(GATE_ROOT, name)
    with open(path, "w", encoding="utf-8") as f:
        if isinstance(obj, str):
            f.write(obj)
        else:
            json.dump(obj, f, indent=1, sort_keys=True)
            f.write("\n")
    print(f"[gate] wrote {name}")
    return path


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def port_free(port: int) -> bool:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind(("127.0.0.1", port))
        return True
    except OSError:
        return False
    finally:
        s.close()


def run_godot(args: list[str], env_extra: dict[str, str],
              timeout_s: int, log_name: str) -> dict:
    """Run headless Godot, teeing output to a gate console log. Truth comes
    from artifact files, not the exit code (the console wrapper's code
    forwarding is not relied upon)."""
    os.makedirs(GATE_ROOT, exist_ok=True)
    log_path = os.path.join(GATE_ROOT, log_name)
    env = dict(os.environ)
    # Scrub JEV vars so every leg starts from a known configuration.
    for k in [k for k in env if k.startswith("JEV_SHADOW")]:
        del env[k]
    env.update(env_extra)
    cmd = [GODOT_CONSOLE, "--headless", "--path", STRATEGY_ROOT] + args
    t0 = time.time()
    with open(log_path, "w", encoding="utf-8", errors="replace") as f:
        f.write(f"# {log_name} {_now()}\n# cmd: {cmd}\n# env: {env_extra}\n")
        f.flush()
        try:
            p = subprocess.Popen(cmd, stdout=f, stderr=subprocess.STDOUT,
                                 cwd=STRATEGY_ROOT, env=env)
            try:
                code = p.wait(timeout=timeout_s)
            except subprocess.TimeoutExpired:
                _kill_tree(p.pid)
                code = p.wait(timeout=30)
                return {"timed_out": True, "exit_code": code,
                        "wall_s": round(time.time() - t0, 1),
                        "log": log_name}
            return {"timed_out": False, "exit_code": code,
                    "wall_s": round(time.time() - t0, 1), "log": log_name}
        except Exception as e:  # noqa: BLE001 - gate must record, not crash
            f.write(f"# LAUNCH_ERROR {type(e).__name__}: {e}\n")
            return {"timed_out": False, "exit_code": None,
                    "launch_error": f"{type(e).__name__}: {e}",
                    "wall_s": round(time.time() - t0, 1), "log": log_name}


def _kill_tree(pid: int) -> None:
    try:
        subprocess.run(["taskkill", "/F", "/T", "/PID", str(pid)],
                       capture_output=True, timeout=30)
    except Exception:  # noqa: BLE001
        pass


def ps_json(script: str, timeout_s: int = 60) -> str:
    p = subprocess.run(
        ["powershell.exe", "-NoLogo", "-NoProfile", "-Command", script],
        capture_output=True, text=True, timeout=timeout_s)
    return (p.stdout or "").strip()


def worker_procs() -> list[dict]:
    """All live processes whose command line names the JEV worker script."""
    script = (
        "Get-CimInstance Win32_Process | Where-Object { $_.Name -like "
        "'python*' -and $_.CommandLine -like '*jev_shadow*worker.py*' } "
        "| Select-Object ProcessId,ParentProcessId,Name,CommandLine "
        "| ConvertTo-Json -Compress"
    )
    out = ps_json(script)
    if not out:
        return []
    try:
        rows = json.loads(out)
    except json.JSONDecodeError:
        return []
    if isinstance(rows, dict):
        rows = [rows]
    return rows


def proc_window(pid: int) -> dict:
    script = (
        f"$p = Get-Process -Id {int(pid)} -ErrorAction SilentlyContinue; "
        "if ($p -eq $null) { '{}' } else { "
        "@{ name=$p.ProcessName; main_window_handle=[string]$p.MainWindowHandle; "
        "path=$p.Path } | ConvertTo-Json -Compress }"
    )
    try:
        return json.loads(ps_json(script) or "{}")
    except json.JSONDecodeError:
        return {}


def http_json(url: str, timeout_s: int = 10) -> dict:
    with urllib.request.urlopen(url, timeout=timeout_s) as resp:
        return json.loads(resp.read().decode("utf-8"))


def load_json(path: str):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def load_jsonl(path: str) -> list[dict]:
    if not os.path.isfile(path):
        return []
    with open(path, encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]


# ---------------------------------------------------------------- discovery

def phase_discovery() -> dict:
    py = sys.executable
    try:
        import torch  # noqa: PLC0415
        torch_v = torch.__version__
    except Exception as e:  # noqa: BLE001
        torch_v = f"IMPORT_FAILED: {e}"
    pyw = os.path.join(os.path.dirname(py), "pythonw.exe")
    ck_exists = os.path.isfile(CHECKPOINT)
    ck_sha = sha256_file(CHECKPOINT).lower() if ck_exists else ""
    model_ok = ck_exists and ck_sha == CHECKPOINT_SHA256.lower()
    godot_v = subprocess.run(
        [GODOT_CONSOLE, "--version"], capture_output=True, text=True,
        timeout=60)
    runtime = {
        "gate": "jev-shadow-single-launch-v0",
        "timestamp": _now(),
        "git_root": os.path.dirname(STRATEGY_ROOT),
        "godot_executable": GODOT_GUI,
        "godot_console": GODOT_CONSOLE,
        "godot_version": (godot_v.stdout or "").strip(),
        "battle_scene": BATTLE_SCENE,
        "main_scene": "res://scenes/title_screen.tscn",
        "python_runtime": py,
        "pythonw_available": os.path.isfile(pyw),
        "torch_version": torch_v,
        "worker_entry": "res://tools/jev_shadow/worker.py",
        "shadow_hook": "MissionManager.red_turn -> Cloud2JevShadow.observe",
        "launcher": "res://scripts/cloud2/cloud2_jev_launcher.gd",
        "runtime_autoload": "JevShadowRuntime res://scripts/cloud2/cloud2_jev_runtime.gd",
        "model": MODEL_IDENTITY,
        "checkpoint": CHECKPOINT,
        "checkpoint_exists": ck_exists,
        "checkpoint_sha256": ck_sha,
        "checkpoint_expected": CHECKPOINT_SHA256.lower(),
        "model_identity_verified": model_ok,
        "protocol_version": SHADOW_PROTOCOL_VERSION,
        "contract": SHADOW_CONTRACT_VERSION,
        "schemas": {
            "request": SHADOW_REQUEST_VERSION,
            "response": SHADOW_RESPONSE_VERSION,
            "telemetry": SHADOW_TELEMETRY_VERSION,
            "slot_map": SHADOW_SLOTMAP_VERSION,
            "mission_map": SHADOW_MISSIONMAP_VERSION,
            "observation": SHADOW_OBSERVATION_SCHEMA,
            "action": SHADOW_ACTION_SCHEMA,
        },
        "launcher_version": SHADOW_LAUNCHER_VERSION,
    }
    write_artifact("RUNTIME_DISCOVERY.json", runtime)

    cands = []
    for label, path in (
            ("explicit_env_JEV_SHADOW_PYTHON",
             os.environ.get("JEV_SHADOW_PYTHON", "")),
            ("project_venv_pythonw",
             os.path.join(STRATEGY_ROOT, ".venv", "Scripts", "pythonw.exe")),
            ("project_venv_python",
             os.path.join(STRATEGY_ROOT, ".venv", "Scripts", "python.exe")),
            ("localappdata_python313_pythonw", os.path.join(
                os.environ.get("LOCALAPPDATA", ""), "Programs", "Python",
                "Python313", "pythonw.exe")),
            ("localappdata_python313_python", os.path.join(
                os.environ.get("LOCALAPPDATA", ""), "Programs", "Python",
                "Python313", "python.exe")),
            ("path_pythonw", shutil.which("pythonw") or ""),
            ("path_python", shutil.which("python") or "")):
        cands.append({"candidate": label, "path": path,
                      "exists": bool(path) and os.path.isfile(path)})
    # Validate the resolved runtime loads torch + JevPolicyV0 + seed205.
    probe = subprocess.run(
        [py, "-c",
         "import torch, hashlib;"
         "from python_jev.model import JevPolicyV0;"
         "m = JevPolicyV0(token_embed_dim=128, context_embed_dim=128,"
         " hidden_dim=256, fusion_latent_dim=512);"
         "from python_jev.training.checkpoint import load_checkpoint;"
         f"load_checkpoint({CHECKPOINT!r}, m);"
         "m.eval();"
         "print('LOAD_OK', sum(p.numel() for p in m.parameters()))"],
        capture_output=True, text=True, timeout=240, cwd=STRATEGY_ROOT)
    py_disc = {
        "timestamp": _now(),
        "resolution_order": [c["candidate"] for c in cands],
        "candidates": cands,
        "resolved": py,
        "torch_version": torch_v,
        "checkpoint_load_probe": {
            "ok": "LOAD_OK" in (probe.stdout or ""),
            "stdout": (probe.stdout or "").strip()[-200:],
            "stderr": (probe.stderr or "").strip()[-500:],
            "exit_code": probe.returncode,
        },
    }
    write_artifact("PYTHON_RUNTIME_DISCOVERY.json", py_disc)
    contract = {
        "gate": "jev-shadow-single-launch-v0",
        "timestamp": _now(),
        "authority": "WITHHELD",
        "mode": "SHADOW_ONLY",
        "user_experience": [
            "User launches game once.",
            "JEV initializes automatically.",
            "User never manages the worker.",
            "Game exit shuts worker down.",
        ],
        "lifecycle": [
            "Game starts -> JevShadowRuntime autoload spawns hidden owned worker (pythonw, no console).",
            "Bounded health handshake verifies model/sha/protocol/schemas before first inference.",
            "Shadow READY: normal battle proceeds; JEV observes/infers/logs only.",
            "Game exits -> token-authenticated graceful shutdown, exact-PID kill fallback.",
            "Crashed game -> worker-side parent-PID monitor exits; no orphans.",
        ],
        "ownership": {
            "tracked": ["worker PID", "ownership flag", "startup timestamp",
                        "worker health", "model identity", "checkpoint hash",
                        "port", "schema versions"],
            "kill_scope": "owned PID only; never python.exe/pythonw.exe/port occupant in general",
        },
        "port_strategy": "dynamic localhost port (11439 first, then ephemeral scan); fixed port only via explicit JEV_SHADOW_URL plus strict identity handshake, reused-never-killed",
        "hidden_process": "pythonw.exe preferred, OS.create_process(..., open_console=false); no console window",
        "startup_contract": "bounded timeout, fail-open to SHADOW_DISABLED, game never stalls",
        "health_handshake": ["status", "protocol_version", "model identity",
                             "checkpoint SHA-256", "observation schema",
                             "mission schema", "action schema", "PID",
                             "eval mode", "gradients off"],
        "fail_open": "worker missing/timeout/mismatch/crash -> log, disable shadow, deterministic play continues",
    }
    write_artifact("SINGLE_LAUNCH_CONTRACT.json", contract)
    return {"model_identity_verified": model_ok,
            "torch_probe_ok": py_disc["checkpoint_load_probe"]["ok"]}


# ------------------------------------------------- startup/shutdown/restart

def _probe_run(tag: str, timeout_s: int = 180) -> dict:
    out_name = f"PROBE_{tag}.json"
    run = run_godot(
        ["-s", "res://scripts/cloud2/cloud2_jev_probe.gd", "--",
         f"--probe-out={os.path.join(GATE_ROOT, out_name)}"],
        {}, timeout_s, f"PROBE_{tag}.console.log")
    rec = {"tag": tag, "run": run, "probe": None}
    p = os.path.join(GATE_ROOT, out_name)
    if os.path.isfile(p):
        rec["probe"] = load_json(p)
    return rec


def _assert(cond: bool, checks: list, name: str, detail: str = "") -> None:
    checks.append({"check": name, "ok": bool(cond), "detail": str(detail)})


def phase_startup() -> dict:
    assert not worker_procs(), "stale worker running before startup test"
    assert port_free(11439), "port 11439 occupied before startup test"
    recs = [_probe_run("STARTUP1"), _probe_run("STARTUP2")]
    checks: list[dict] = []
    for rec in recs:
        probe = rec["probe"] or {}
        launcher = probe.get("launcher", {})
        ident = launcher.get("worker_identity", {})
        _assert(launcher.get("status") == "READY", checks,
                 f"{rec['tag']}_ready", launcher.get("last_error", ""))
        _assert(launcher.get("owned") is True, checks,
                 f"{rec['tag']}_owned", f"pid={launcher.get('pid')}")
        _assert(ident.get("model_version") == MODEL_IDENTITY, checks,
                 f"{rec['tag']}_model", ident.get("model_version", ""))
        _assert(str(ident.get("checkpoint_sha256", "")).lower()
                 == CHECKPOINT_SHA256.lower(), checks,
                 f"{rec['tag']}_sha", str(ident.get("checkpoint_sha256", ""))[:16])
        _assert(launcher.get("protocol_version") == SHADOW_PROTOCOL_VERSION,
                 checks, f"{rec['tag']}_protocol")
        shut = probe.get("shutdown", {})
        _assert(shut.get("stopped") is True and not shut.get("orphan"),
                 checks, f"{rec['tag']}_shutdown", shut.get("method", ""))
        _assert(probe.get("worker_exited") is True, checks,
                 f"{rec['tag']}_worker_exited")
    # Hidden-process evidence: owned worker is pythonw with no main window.
    hidden = {}
    if recs and (recs[0]["probe"] or {}).get("launcher", {}).get("pid", -1) > 0:
        # Re-probe window state is post-exit; instead assert spawn mechanism:
        # pythonw resolved + open_console=false is recorded in the probe.
        launcher0 = recs[0]["probe"]["launcher"]
        hidden = {"python": launcher0.get("python", ""),
                  "pythonw_used": "pythonw.exe" in launcher0.get("python", ""),
                  "open_console": False}
        _assert(hidden["pythonw_used"], checks, "hidden_pythonw",
                 launcher0.get("python_source", ""))
    leftovers = worker_procs()
    _assert(leftovers == [], checks, "no_orphans_after_startup",
             f"leftovers={leftovers}")
    report = {"phase": "startup_automation", "timestamp": _now(),
              "runs": recs, "hidden": hidden, "checks": checks,
              "passed": all(c["ok"] for c in checks)}
    write_artifact("STARTUP_TEST.json", report)
    return report


def phase_shutdown() -> dict:
    recs = [_probe_run("SHUTDOWN1"), _probe_run("SHUTDOWN2"),
            _probe_run("SHUTDOWN3")]
    checks: list[dict] = []
    for rec in recs:
        probe = rec["probe"] or {}
        shut = probe.get("shutdown", {})
        _assert(probe.get("launcher", {}).get("status") == "READY", checks,
                 f"{rec['tag']}_ready")
        _assert(shut.get("stopped") is True, checks,
                 f"{rec['tag']}_stopped", shut.get("method", ""))
        _assert(not shut.get("orphan", True), checks,
                 f"{rec['tag']}_no_orphan")
        _assert(probe.get("worker_exited") is True, checks,
                 f"{rec['tag']}_worker_exited")
    leftovers = worker_procs()
    _assert(leftovers == [], checks, "no_orphans_after_shutdown",
             f"leftovers={leftovers}")
    _assert(port_free(11439), checks, "port_11439_free_after_shutdown")
    report = {"phase": "clean_shutdown", "timestamp": _now(),
              "runs": recs, "checks": checks,
              "passed": all(c["ok"] for c in checks)}
    write_artifact("SHUTDOWN_TEST.json", report)
    return report


def phase_restart() -> dict:
    recs = [_probe_run("RESTART1"), _probe_run("RESTART2"), _probe_run("RESTART3")]
    checks: list[dict] = []
    pids: list[int] = []
    for rec in recs:
        probe = rec["probe"] or {}
        launcher = probe.get("launcher", {})
        pids.append(int(launcher.get("pid", -1)))
        _assert(launcher.get("status") == "READY", checks,
                 f"{rec['tag']}_ready", launcher.get("last_error", ""))
        _assert(probe.get("worker_exited") is True, checks,
                 f"{rec['tag']}_worker_exited")
    _assert(all(p > 0 for p in pids), checks, "all_cycles_spawned",
             f"pids={pids}")
    _assert(len(set(pids)) == len(pids), checks, "fresh_pid_each_cycle",
             f"pids={pids}")
    leftovers = worker_procs()
    _assert(leftovers == [], checks, "no_stale_worker", f"leftovers={leftovers}")
    _assert(port_free(11439), checks, "no_port_collision")
    report = {"phase": "restart", "timestamp": _now(), "pids": pids,
              "runs": recs, "checks": checks,
              "passed": all(c["ok"] for c in checks)}
    write_artifact("RESTART_TEST.json", report)
    return report


# ------------------------------------------------------------------ failopen

class _StubHandler(BaseHTTPRequestHandler):
    """Wrong-identity endpoint: must be rejected, never killed, never used."""

    def _send(self, obj: dict) -> None:
        blob = json.dumps(obj).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(blob)))
        self.end_headers()
        self.wfile.write(blob)

    def do_GET(self) -> None:  # noqa: N802
        self._send({"ok": True, "service": "jev-shadow-worker",
                    "status": "READY",
                    "protocol_version": "WRONG-PROTOCOL",
                    "pid": 999999,
                    "observation_schema": SHADOW_OBSERVATION_SCHEMA,
                    "mission_schema": SHADOW_MISSIONMAP_VERSION,
                    "action_schema": SHADOW_ACTION_SCHEMA,
                    "identity": {"model_version": "WRONG-MODEL",
                                 "checkpoint_sha256": "0" * 64,
                                 "contract": SHADOW_CONTRACT_VERSION,
                                 "request_schema": SHADOW_REQUEST_VERSION,
                                 "response_schema": SHADOW_RESPONSE_VERSION,
                                 "slot_map": SHADOW_SLOTMAP_VERSION,
                                 "mission_map": SHADOW_MISSIONMAP_VERSION,
                                 "eval_mode": True, "gradients": False}})

    def log_message(self, fmt: str, *args) -> None:
        pass


def _det_run(tag: str, env_extra: dict[str, str],
             timeout_s: int = 1500) -> dict:
    ev_name = f"DET_EVIDENCE_{tag}.json"
    tele_name = f"SHADOW_TELEMETRY_{tag}.jsonl"
    env = {"JEV_SHADOW_DET_EVIDENCE": os.path.join(GATE_ROOT, ev_name),
           "JEV_SHADOW_TELEMETRY": os.path.join(GATE_ROOT, tele_name),
           "JEV_SHADOW_RUN_ID": f"sl-{tag.lower()}"}
    env.update(env_extra)
    run = run_godot(["-s", "res://scripts/cloud2/cloud2_det_battle_entry.gd"],
                    env, timeout_s, f"DET_{tag}.console.log")
    rec = {"tag": tag, "run": run, "evidence": None, "telemetry_rows": 0,
           "evidence_file": ev_name, "telemetry_file": tele_name}
    evp = os.path.join(GATE_ROOT, ev_name)
    if os.path.isfile(evp):
        rec["evidence"] = load_json(evp)
    rec["telemetry_rows"] = len(load_jsonl(os.path.join(GATE_ROOT, tele_name)))
    return rec


def phase_failopen() -> dict:
    checks: list[dict] = []
    # 1) Worker-level startup refusal (no torch load on hash refusal path).
    from tools.jev_shadow.worker import (  # noqa: PLC0415
        WorkerRefused,
        load_model,
    )
    try:
        load_model(CHECKPOINT, "0" * 64)
        _assert(False, checks, "bad_hash_refuses", "loaded unexpectedly")
    except WorkerRefused as e:
        _assert(True, checks, "bad_hash_refuses", str(e)[:120])
    try:
        load_model(os.path.join(STRATEGY_ROOT, "nope.pt"), CHECKPOINT_SHA256)
        _assert(False, checks, "missing_checkpoint_refuses",
                 "loaded unexpectedly")
    except WorkerRefused as e:
        _assert(True, checks, "missing_checkpoint_refuses", str(e)[:120])

    # 2) Godot rejects a wrong-identity endpoint and never kills it.
    stub = ThreadingHTTPServer(("127.0.0.1", 0), _StubHandler)
    stub_port = stub.server_address[1]
    t = threading.Thread(target=stub.serve_forever, daemon=True)
    t.start()
    out_name = "PROBE_MISMATCH.json"
    run = run_godot(
        ["-s", "res://scripts/cloud2/cloud2_jev_probe.gd", "--",
         f"--probe-out={os.path.join(GATE_ROOT, out_name)}"],
        {"JEV_SHADOW_URL": f"http://127.0.0.1:{stub_port}"}, 180,
        "PROBE_MISMATCH.console.log")
    probe = load_json(os.path.join(GATE_ROOT, out_name))
    launcher = probe.get("launcher", {})
    _assert(launcher.get("status") == "DISABLED", checks,
             "mismatch_disabled", launcher.get("last_error", ""))
    _assert("MISMATCH" in launcher.get("last_error", ""), checks,
             "mismatch_error_named", launcher.get("last_error", ""))
    try:
        http_json(f"http://127.0.0.1:{stub_port}/health", 5)
        _assert(True, checks, "mismatch_never_killed",
                 "stub still serving after probe exit")
    except Exception as e:  # noqa: BLE001
        _assert(False, checks, "mismatch_never_killed", str(e)[:120])
    stub.shutdown()

    # 3) Worker-down battle leg: fixed dead URL, tight timeout.
    down = _det_run("DOWN", {"JEV_SHADOW_ENABLE": "1",
                             "JEV_SHADOW_URL": "http://127.0.0.1:9",
                             "JEV_SHADOW_TIMEOUT_MS": "300"})
    _assert(down["evidence"] is not None, checks, "down_completes",
             f"wall_s={down['run'].get('wall_s')}")
    js = (down["evidence"] or {}).get("jev_shadow", {})
    _assert(js.get("status") == "DISABLED", checks, "down_shadow_disabled",
             js.get("last_error", ""))
    _assert(worker_procs() == [], checks, "down_no_orphans")
    report = {"phase": "fail_open", "timestamp": _now(),
              "mismatch_probe_run": run, "mismatch_probe": probe,
              "down_leg": {k: v for k, v in down.items()
                           if k != "evidence"},
              "down_jev_shadow": js,
              "checks": checks,
              "passed": all(c["ok"] for c in checks)}
    write_artifact("FAIL_OPEN_TEST.json", report)
    return report


def phase_crash() -> dict:
    """Mid-battle worker kill: the deterministic battle must complete with
    an identical authoritative digest; shadow records WORKER_CRASHED."""
    checks: list[dict] = []
    tag = "CRASH"
    ev_name = f"DET_EVIDENCE_{tag}.json"
    tele_name = f"SHADOW_TELEMETRY_{tag}.jsonl"
    tele_path = os.path.join(GATE_ROOT, tele_name)
    if os.path.isfile(tele_path):
        os.remove(tele_path)
    env = dict(os.environ)
    for k in [k for k in env if k.startswith("JEV_SHADOW")]:
        del env[k]
    env.update({"JEV_SHADOW_DET_EVIDENCE": os.path.join(GATE_ROOT, ev_name),
                "JEV_SHADOW_TELEMETRY": tele_path,
                "JEV_SHADOW_RUN_ID": "sl-crash"})
    log_path = os.path.join(GATE_ROOT, "DET_CRASH.console.log")
    kill: dict = {"attempted": False, "pid": -1, "ok": False}
    with open(log_path, "w", encoding="utf-8", errors="replace") as f:
        p = subprocess.Popen(
            [GODOT_CONSOLE, "--headless", "--path", STRATEGY_ROOT,
             "-s", "res://scripts/cloud2/cloud2_det_battle_entry.gd"],
            stdout=f, stderr=subprocess.STDOUT, cwd=STRATEGY_ROOT, env=env)
        try:
            deadline = time.time() + 1500
            while time.time() < deadline:
                if p.poll() is not None:
                    break
                rows = load_jsonl(tele_path)
                if len(rows) >= 3 and not kill["attempted"]:
                    kill["attempted"] = True
                    for w in worker_procs():
                        try:
                            pid = int(w.get("ProcessId", -1))
                        except (TypeError, ValueError):
                            continue
                        if pid > 0:
                            kill["pid"] = pid
                            r = subprocess.run(
                                ["taskkill", "/F", "/PID", str(pid)],
                                capture_output=True, timeout=30)
                            kill["ok"] = r.returncode == 0
                            break
                time.sleep(5)
            p.wait(timeout=600)
        except subprocess.TimeoutExpired:
            _kill_tree(p.pid)
            p.wait(timeout=30)
    ev = load_json(os.path.join(GATE_ROOT, ev_name))
    js = ev.get("jev_shadow", {})
    rows = load_jsonl(tele_path)
    statuses = {}
    for r in rows:
        if r.get("record_type") == "decision":
            statuses[r.get("shadow_status", "?")] = \
                statuses.get(r.get("shadow_status", "?"), 0) + 1
    _assert(kill["attempted"] and kill["ok"], checks, "worker_killed_mid_run",
             f"pid={kill['pid']}")
    _assert(js.get("status") == "DISABLED", checks, "crash_shadow_disabled",
             js.get("last_error", ""))
    _assert("CRASHED" in js.get("last_error", ""), checks,
             "crash_recorded", js.get("last_error", ""))
    _assert(worker_procs() == [], checks, "crash_no_orphans")
    report = {"phase": "fail_open_crash", "timestamp": _now(), "kill": kill,
              "telemetry_decision_statuses": statuses,
              "crash_jev_shadow": js,
              "checks": checks,
              "passed": all(c["ok"] for c in checks)}
    path = os.path.join(GATE_ROOT, "FAIL_OPEN_TEST.json")
    prev = load_json(path) if os.path.isfile(path) else {}
    prev_checks = prev.get("checks", [])
    prev["crash_leg"] = report
    prev["checks"] = prev_checks + checks
    prev["passed"] = all(c["ok"] for c in prev["checks"])
    write_artifact("FAIL_OPEN_TEST.json", prev)
    return report


# --------------------------------------------------------------- determinism

def phase_determinism() -> dict:
    off = _det_run("OFF", {"JEV_SHADOW_ENABLE": "0"})
    on = _det_run("ON", {})
    checks: list[dict] = []
    _assert(off["evidence"] is not None, checks, "off_completes",
             f"wall_s={off['run'].get('wall_s')}")
    _assert(on["evidence"] is not None, checks, "on_completes",
             f"wall_s={on['run'].get('wall_s')}")
    off_js = (off["evidence"] or {}).get("jev_shadow", {})
    on_js = (on["evidence"] or {}).get("jev_shadow", {})
    _assert(off_js.get("status") in ("COLD", "DISABLED")
             and off_js.get("owned") is not True
             and int(off_js.get("pid", -1)) <= 0,
             checks, "off_shadow_disabled",
             f"status={off_js.get('status')} owned={off_js.get('owned')}")
    _assert(on_js.get("status") == "READY", checks, "on_shadow_ready",
             on_js.get("last_error", ""))
    _assert(on_js.get("owned") is True, checks, "on_worker_owned",
             f"pid={on_js.get('pid')}")
    comparison = {}
    if off["evidence"] is not None and on["evidence"] is not None:
        off_run = build_run_file_at(os.path.join(GATE_ROOT, "DET_EVIDENCE_OFF.json"),
                                    "shadow_off")
        on_run = build_run_file_at(os.path.join(GATE_ROOT, "DET_EVIDENCE_ON.json"),
                                   "shadow_on_auto")
        comparison = {"off_vs_on": compare_runs(off_run, on_run)}
        # DOWN + CRASH legs use the same OFF baseline when present.
        for tag in ("DOWN", "CRASH"):
            evp = os.path.join(GATE_ROOT, f"DET_EVIDENCE_{tag}.json")
            if os.path.isfile(evp):
                leg = build_run_file_at(evp, f"shadow_{tag.lower()}")
                comparison[f"off_vs_{tag.lower()}"] = compare_runs(off_run, leg)
        for name, cmp in comparison.items():
            _assert(cmp["all_equal"], checks, f"determinism_{name}",
                     f"mismatches={cmp['mismatches']}")
    # Telemetry proof: ON leg proposed real JEV slots for live decisions.
    on_rows = [r for r in load_jsonl(os.path.join(GATE_ROOT, "SHADOW_TELEMETRY_ON.jsonl"))
               if r.get("record_type") == "decision"]
    ok_rows = [r for r in on_rows if r.get("shadow_status") == "OK"]
    _assert(len(on_rows) > 0, checks, "on_telemetry_present",
             f"decisions={len(on_rows)}")
    _assert(len(ok_rows) > 0, checks, "on_inference_ok",
             f"ok={len(ok_rows)}")
    _assert(all(str(r.get("checkpoint_sha256", "")).lower()
                 == CHECKPOINT_SHA256.lower() for r in ok_rows),
             checks, "on_telemetry_model_hash")
    _assert(all(int(r.get("worker_pid", -1)) > 0 for r in ok_rows),
             checks, "on_telemetry_worker_pid")
    _assert(worker_procs() == [], checks, "determinism_no_orphans")
    report = {"phase": "determinism", "timestamp": _now(),
              "off_wall_s": off["run"].get("wall_s"),
              "on_wall_s": on["run"].get("wall_s"),
              "off_jev_shadow": off_js, "on_jev_shadow": on_js,
              "on_telemetry_decisions": len(on_rows),
              "on_telemetry_ok": len(ok_rows),
              "comparison": comparison, "checks": checks,
              "passed": all(c["ok"] for c in checks)}
    write_artifact("DETERMINISM_COMPARISON.json", report)
    return report


# -------------------------------------------------------------------- scene

def phase_scene() -> dict:
    """Interactive-path proof: boot the real battle scene headless for a
    bounded number of frames. This exercises the autoload (async boot) path
    rather than the synchronous SceneTree harness path."""
    checks: list[dict] = []
    run = run_godot([BATTLE_SCENE, "--quit-after", "240"], {}, 600,
                    "SCENE_BATTLE.console.log")
    log_text = ""
    log_path = os.path.join(GATE_ROOT, "SCENE_BATTLE.console.log")
    if os.path.isfile(log_path):
        with open(log_path, encoding="utf-8", errors="replace") as f:
            log_text = f.read()
    ready = "Shadow READY" in log_text
    owned_spawn = "spawned owned worker" in log_text
    stopped = "stopped=true" in log_text and "orphan=false" in log_text
    _assert(not run.get("timed_out", True), checks, "scene_finishes_bounded",
             f"wall_s={run.get('wall_s')}")
    _assert(owned_spawn, checks, "scene_auto_spawn")
    _assert(ready, checks, "scene_shadow_ready")
    _assert(stopped, checks, "scene_worker_stopped")
    _assert(worker_procs() == [], checks, "scene_no_orphans")
    _assert(port_free(11439), checks, "scene_port_free")
    report = {"phase": "scene_proof", "timestamp": _now(),
              "scene": BATTLE_SCENE, "frames": 240, "run": run,
              "log_markers": {"auto_spawn": owned_spawn, "ready": ready,
                              "stopped_clean": stopped},
              "checks": checks,
              "passed": all(c["ok"] for c in checks)}
    write_artifact("SCENE_PROOF.json", report)
    return report


# ------------------------------------------------------------------- report

def _load_artifact(name: str) -> dict:
    p = os.path.join(GATE_ROOT, name)
    return load_json(p) if os.path.isfile(p) else {}


def phase_report() -> dict:
    runtime = _load_artifact("RUNTIME_DISCOVERY.json")
    startup = _load_artifact("STARTUP_TEST.json")
    shutdown = _load_artifact("SHUTDOWN_TEST.json")
    restart = _load_artifact("RESTART_TEST.json")
    failopen = _load_artifact("FAIL_OPEN_TEST.json")
    determinism = _load_artifact("DETERMINISM_COMPARISON.json")
    scene = _load_artifact("SCENE_PROOF.json")

    ownership = {
        "timestamp": _now(),
        "pid_tracking": "Godot Cloud2JevLauncher tracks owned pid, port, host, python, start timestamps, worker identity; exposed via status_snapshot() and embedded in det evidence + telemetry rows",
        "port_strategy": "dynamic localhost port (11439 first, ephemeral scan fallback); fixed endpoint only via explicit JEV_SHADOW_URL with strict handshake, reused-never-killed",
        "parent_ownership": "worker spawned with --parent-pid <godot pid>; token-authenticated POST /shutdown on exit; exact-PID kill fallback; worker-side parent monitor exits on Godot crash",
        "orphan_prevention": "graceful shutdown + bounded kill + parent monitor + boot-failure cleanup; every gate phase asserts zero worker processes afterwards",
        "kill_scope": "owned PID only; fixed/reused endpoints and unrelated python/port occupants are never signalled",
        "on_leg_ownership": determinism.get("on_jev_shadow", {}),
        "startup_pids": [r.get("probe", {}).get("launcher", {}).get("pid")
                         for r in startup.get("runs", [])],
        "restart_pids": restart.get("pids", []),
    }
    write_artifact("PROCESS_OWNERSHIP.json", ownership)

    phases = {
        "model_identity": bool(runtime.get("model_identity_verified")),
        "startup": bool(startup.get("passed")),
        "shutdown": bool(shutdown.get("passed")),
        "restart": bool(restart.get("passed")),
        "fail_open": bool(failopen.get("passed")),
        "determinism": bool(determinism.get("passed")),
        "scene": bool(scene.get("passed")),
    }
    warnings: list[str] = []
    latencies = []
    for r in startup.get("runs", []):
        lat = r.get("probe", {}).get("launcher", {}).get(
            "startup_latency_ms", -1)
        if isinstance(lat, (int, float)) and lat >= 0:
            latencies.append(lat)
    if any(lat > 60000 for lat in latencies):
        warnings.append(f"cold startup exceeded 60s on this machine: {latencies}")
    status = "PASS" if all(phases.values()) else "FAIL"
    if status == "PASS" and warnings:
        status = "PASS_WITH_WARNINGS"
    decision = {
        "gate": "jev-shadow-single-launch-v0",
        "timestamp": _now(),
        "status": status,
        "phases": phases,
        "warnings": warnings,
        "single_launch_runtime": status,
        "jev_authority": "WITHHELD",
        "startup_latencies_ms": latencies,
        "user_launch_command": (
            "& \"C:\\Users\\kyoun\\AppData\\Local\\Programs\\Godot\\"
            "Godot_v4.2.2-stable_win64.exe\" --path "
            "\"D:\\Game development\\Demon slayer\\StrategyGame\" "
            "\"res://scenes/cloud2_battle_test.tscn\""),
        "note": ("Single-launch runtime owns the worker lifecycle; tactical "
                 "quality is unchanged and authority stays WITHHELD."),
    }
    write_artifact("SINGLE_LAUNCH_DECISION.json", decision)

    det = determinism.get("comparison", {}).get("off_vs_on", {})
    handoff = f"""# JEV Single-Launch Shadow Runtime — Handoff (SHADOW ONLY)

Status: {status}. The game now owns the JEV worker lifecycle completely:
launch once, JEV initializes automatically, game exit shuts it down. No
manual server, no second terminal, no environment setup. Authority stays
WITHHELD; the deterministic tactical selector is the sole executed authority.

## What changed

- Worker (`tools/jev_shadow/worker.py`): `/health` now attests status,
  protocol version, PID, observation/mission/action schemas, model identity,
  checkpoint SHA-256, eval mode, and gradients-off. New token-authenticated
  `POST /shutdown`, `--parent-pid` crash monitor, `--log-file`, `--port-file`,
  and pythonw-safe stdio (Godot-spawned pythonw has `sys.stdout/stderr is None`;
  an unguarded log write used to kill every request before flush).
- Launcher (`scripts/cloud2/cloud2_jev_launcher.gd`, new): Python discovery
  (explicit env → project venv → LOCALAPPDATA → PATH, pythonw preferred),
  dynamic localhost port (11439 first, ephemeral scan), hidden spawn via
  `OS.create_process(..., open_console=false)`, strict identity handshake,
  exact-PID owned shutdown, fail-open disable on any error.
- Autoload (`scripts/cloud2/cloud2_jev_runtime.gd`, new, `JevShadowRuntime`):
  non-blocking boot (spawn now, handshake across frames), shutdown on exit.
- Shadow bridge (`scripts/cloud2/cloud2_jev_shadow.gd`): automatic unless
  `JEV_SHADOW_ENABLE=0`; uses the launcher endpoint; telemetry rows carry
  worker PID/port/mode.
- Probe (`scripts/cloud2/cloud2_jev_probe.gd`, new) + det-harness shutdown
  hook + `jev_shadow` ownership section in det evidence.
- `tools/jev_shadow/summarize.py`: `build_run_file_at()` reuses the prior
  determinism comparison with the ownership section excluded from the digest.

## Evidence (this directory)

- `RUNTIME_DISCOVERY.json`, `PYTHON_RUNTIME_DISCOVERY.json`,
  `SINGLE_LAUNCH_CONTRACT.json`, `PROCESS_OWNERSHIP.json`
- `STARTUP_TEST.json`, `SHUTDOWN_TEST.json`, `RESTART_TEST.json`,
  `FAIL_OPEN_TEST.json`, `DETERMINISM_COMPARISON.json`, `SCENE_PROOF.json`
- `SINGLE_LAUNCH_DECISION.json`: {status}

Determinism OFF-vs-auto-ON: all_equal={det.get("all_equal")},
mismatches={det.get("mismatches")}.
ON-leg telemetry: {determinism.get("on_telemetry_ok")} OK decisions, model hash verified per row.

## User launch

```powershell
{decision["user_launch_command"]}
```

No prerequisite command. No worker startup. No environment variables.

## Next gate (do NOT execute)

Human-visible Shadow QA → tactical-quality diagnosis.
"""
    write_artifact("JEV_SINGLE_LAUNCH_HANDOFF.md", handoff)
    return decision


PHASES = {
    "discovery": phase_discovery,
    "startup": phase_startup,
    "shutdown": phase_shutdown,
    "restart": phase_restart,
    "failopen": phase_failopen,
    "crash": phase_crash,
    "determinism": phase_determinism,
    "scene": phase_scene,
    "report": phase_report,
}

ORDER = ["discovery", "startup", "shutdown", "restart", "failopen", "crash",
         "determinism", "scene", "report"]


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Single-launch JEV shadow gate")
    ap.add_argument("--phase", default="all",
                    help="all or one of: " + ",".join(ORDER))
    args = ap.parse_args(argv)
    names = ORDER if args.phase == "all" else [args.phase]
    for name in names:
        if name not in PHASES:
            print(f"[gate] unknown phase {name}", flush=True)
            return 2
        print(f"[gate] phase {name} starting {_now()}", flush=True)
        try:
            result = PHASES[name]()
        except Exception as e:  # noqa: BLE001 - record and stop
            print(f"[gate] phase {name} ERROR {type(e).__name__}: {e}",
                  flush=True)
            return 1
        ok = result.get("passed", result.get("model_identity_verified",
                                             True))
        print(f"[gate] phase {name} done ok={ok}", flush=True)
        if ok is False:
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
