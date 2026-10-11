"""BRAIN_VLLM_PHASE1 — whole-GPU VRAM sampler for the live 3-window group.

  python -m tools.brain_vllm.live_vram --out <VRAM_live.json> [--interval 5] [--stop-file <path>]

Samples `nvidia-smi memory.used` (whole GPU, incl. WSL) every interval seconds,
appends to <out>.jsonl and rewrites <out> (kill-safe). Reports peak.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path


def used_mib():
    try:
        p = subprocess.run(["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits"],
                           capture_output=True, text=True, timeout=15)
        return int(p.stdout.strip().splitlines()[0])
    except Exception:  # noqa: BLE001
        return -1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--interval", type=float, default=5.0)
    ap.add_argument("--stop-file", default="")
    a = ap.parse_args()
    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    jl = out.with_suffix(".jsonl")
    t0 = time.time()
    peak = 0
    n = 0
    while True:
        mib = used_mib()
        n += 1
        peak = max(peak, mib)
        row = {"t": round(time.time() - t0, 1), "used_mib": mib, "wall": time.strftime("%H:%M:%S")}
        with open(jl, "a", encoding="utf-8") as f:
            f.write(json.dumps(row) + "\n")
        tmp = out.with_name(out.name + ".tmp")
        tmp.write_text(json.dumps({"peak_used_mib": peak, "samples": n, "elapsed_s": round(time.time() - t0, 1),
                                   "peak_used_gib": round(peak / 1024, 3), "target_le_20_gib": peak <= 20 * 1024,
                                   "interval_s": a.interval}, indent=1), encoding="utf-8")
        tmp.replace(out)
        if a.stop_file and Path(a.stop_file).exists():
            break
        time.sleep(a.interval)
    print(json.dumps({"peak_used_mib": peak, "samples": n}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
