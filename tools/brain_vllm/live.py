"""BRAIN_VLLM_PHASE1 — live 3-window group with the vLLM service standing in
for `serve`, plus whole-GPU VRAM sampling (5 s) for the <= 20 GiB gate.

  python -m tools.brain_vllm.live --name vllm_live [--windows 3] [--turn-cap 10] [--seed 100000]

Runs: python -m tools.contextual_brain.rl_vs_utility debug_group --name <name>
      --windows N --turn-cap T --backend vllm   (HF serve untouched, default)
while tools/brain_vllm/live_vram.py samples nvidia-smi every 5 s.
Writes artifacts/brain_pipeline_v1/vllm/LIVE.json + logs.
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

VLLM_DIR = ROOT / "artifacts" / "brain_pipeline_v1" / "vllm"
OUT_RL = ROOT / "artifacts" / "rl_vs_utility_v0"
PY = r"D:\StrategyAI\runtimes\qwen3_8b_rl_v0\.venv\Scripts\python.exe"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", default="vllm_live")
    ap.add_argument("--windows", type=int, default=3)
    ap.add_argument("--turn-cap", type=int, default=10)
    ap.add_argument("--seed", type=int, default=100000)
    a = ap.parse_args()
    d = OUT_RL / a.name
    logs = VLLM_DIR / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    stopf = logs / f"{a.name}_vram.stop"
    stopf.unlink(missing_ok=True)
    vram_out = VLLM_DIR / f"VRAM_live_{a.name}.json"

    sampler = subprocess.Popen([PY, "-u", "-m", "tools.brain_vllm.live_vram", "--out", str(vram_out),
                                "--interval", "5", "--stop-file", str(stopf)],
                               cwd=str(ROOT), stdout=open(logs / f"{a.name}_vram.stdout.log", "w"),
                               stderr=subprocess.STDOUT)
    t0 = time.time()
    try:
        cmd = [PY, "-u", "-m", "tools.contextual_brain.rl_vs_utility", "debug_group", "--name", a.name,
               "--windows", str(a.windows), "--turn-cap", str(a.turn_cap), "--seed", str(a.seed), "--backend", "vllm"]
        print(f"[live] running: {' '.join(cmd)}", flush=True)
        with open(logs / f"{a.name}.log", "w", encoding="utf-8", errors="replace") as lf:
            p = subprocess.run(cmd, cwd=str(ROOT), stdout=lf, stderr=subprocess.STDOUT, timeout=10800)
        rc = p.returncode
    finally:
        stopf.write_text("stop")
        try:
            sampler.wait(timeout=30)
        except subprocess.TimeoutExpired:
            sampler.kill()
    wall = round(time.time() - t0, 1)

    wins = []
    for i in range(a.windows):
        mo = d / f"match_w{i}.json"
        res = json.loads(mo.read_text(encoding="utf-8")) if mo.exists() else {}
        br = res.get("brain") or {}
        wins.append({"window": f"w{i}", "outcome": res.get("outcome"), "turn": res.get("turn"),
                     "turn_cap": res.get("turn_cap"), "wall_s": res.get("wall_s"),
                     "wall_s_per_turn": round((res.get("wall_s") or 0) / max(1, res.get("turn") or 1), 2),
                     "brain_failures": br.get("brain_failures"), "decisions": br.get("decisions"),
                     "strict_fault": res.get("strict_fault"), "error": res.get("error"),
                     "initial_captured": (d / f"debug_w{i}.json").exists()})
    calls = []
    capf = d / "calls.jsonl"
    if capf.exists():
        for l in open(capf, encoding="utf-8"):
            try:
                r = json.loads(l)
            except ValueError:
                continue
            calls.append(r)
    per_window = {}
    for r in calls:
        w = r.get("window") or "?"
        per_window.setdefault(w, []).append({"request": r.get("request"), "turn": r.get("turn"),
                                             "wall_s": r.get("wall_s"), "comp_ids_exact": r.get("comp_ids_exact", True)})
    initials = {w: sum(1 for x in v if x["request"] == "VICTORY_INITIAL") for w, v in per_window.items()}
    vram = json.loads(vram_out.read_text(encoding="utf-8")) if vram_out.exists() else {}
    res = {"name": a.name, "rc": rc, "wall_s": wall, "windows": wins,
           "brain_calls": {w: len(v) for w, v in per_window.items()},
           "victory_initial_per_window": initials,
           "brain_timeouts": sum(1 for w in wins if w["outcome"] == "TIMEOUT"),
           "brain_failures_total": sum(int(w["brain_failures"] or 0) for w in wins),
           "comp_ids_all_exact": all(x["comp_ids_exact"] for v in per_window.values() for x in v),
           "vram_peak_gib": vram.get("peak_used_gib"), "vram_target_le_20_gib": vram.get("target_le_20_gib"),
           "per_window_calls": per_window,
           "at": time.strftime("%Y-%m-%dT%H:%M:%S")}
    ok = (rc == 0 and all(w["outcome"] not in (None, "ABORTED") for w in wins)
          and all(w["brain_failures"] == 0 for w in wins) and res["brain_timeouts"] == 0
          and all(v >= 1 for v in initials.values()) and res["comp_ids_all_exact"])
    res["pass"] = bool(ok)
    (VLLM_DIR / "LIVE.json").write_text(json.dumps(res, indent=1), encoding="utf-8")
    print(json.dumps({k: res[k] for k in ("rc", "wall_s", "brain_timeouts", "brain_failures_total",
                                          "victory_initial_per_window", "vram_peak_gib", "comp_ids_all_exact",
                                          "pass", "windows")}, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
