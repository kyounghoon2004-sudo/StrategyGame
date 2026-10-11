"""Speed / fit numbers for a local commander Brain (2026-10-05).

Replays REAL commander requests captured from the cloud runs (cmd_cycle_v1, cycle 0 = valid) against the local
vLLM server at concurrency 1 / 6 / 12 and reports: latency per call, completion tokens (incl. reasoning),
generation throughput, valid-order rate, and GPU memory in use.

  python -m tools.brain_moe.bench_q38 [--levels 1,6,12] [--per-level 12] [--out <json>]
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import json
import subprocess
import time
from pathlib import Path

from tools.plan_search.cloud_brain import local_command

ROOT = Path(__file__).resolve().parents[2]
CALLS = ROOT / "artifacts" / "brain_pipeline_v1" / "plan_search" / "cmd_cycle_v1" / "raw" / "calls.jsonl"


def gpu_mem():
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=memory.used,memory.total", "--format=csv,noheader,nounits"],
                             capture_output=True, text=True, timeout=20).stdout.strip().split(",")
        return {"used_mib": int(out[0]), "total_mib": int(out[1])}
    except Exception:  # noqa: BLE001
        return {}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--levels", default="1,6,12")
    ap.add_argument("--per-level", type=int, default=12)
    ap.add_argument("--max-tokens", type=int, default=12000)
    ap.add_argument("--out", default=str(ROOT / "artifacts" / "brain_pipeline_v1" / "local_q38" / "bench.json"))
    a = ap.parse_args()
    reqs = []
    for line in CALLS.read_text(encoding="utf-8").splitlines():
        r = json.loads(line)
        if r.get("request") == "VICTORY_COMMAND" and str(r.get("tag", "")).startswith("c000") and r.get("raw"):
            reqs.append(r["messages"])
    print("real commander requests available:", len(reqs), "| gpu before:", gpu_mem(), flush=True)
    report = {"gpu_idle": gpu_mem(), "levels": []}
    k = 0
    for level in [int(x) for x in a.levels.split(",")]:
        batch = [reqs[(k + i) % len(reqs)] for i in range(a.per_level)]
        k += a.per_level
        t0 = time.time()
        peak = {}
        with cf.ThreadPoolExecutor(max_workers=level) as ex:
            futs = [ex.submit(local_command, m, max_tokens=a.max_tokens, tries=1) for m in batch]
            while not all(f.done() for f in futs):
                g = gpu_mem()
                if g.get("used_mib", 0) > peak.get("used_mib", 0):
                    peak = g
                time.sleep(2)
            res = [f.result() for f in futs]
        wall = time.time() - t0
        rows = []
        for text, meta in res:
            at = (meta.get("attempts") or [{}])[-1]
            u = at.get("usage") or {}
            rows.append({"ok": bool(text), "s": at.get("s"), "completion_tokens": u.get("completion_tokens"),
                         "prompt_tokens": u.get("prompt_tokens"), "finish": at.get("finish"), "error": at.get("error")})
        comp = sum(r["completion_tokens"] or 0 for r in rows)
        lat = sorted(r["s"] or 0 for r in rows)
        lv = {"concurrency": level, "requests": len(rows), "valid": sum(r["ok"] for r in rows), "wall_s": round(wall, 1),
              "latency_s": {"min": lat[0], "median": lat[len(lat) // 2], "max": lat[-1]},
              "completion_tokens": {"mean": round(comp / len(rows)), "max": max(r["completion_tokens"] or 0 for r in rows)},
              "prompt_tokens_mean": round(sum(r["prompt_tokens"] or 0 for r in rows) / len(rows)),
              "gen_tok_per_s_total": round(comp / wall, 1), "gpu_peak": peak,
              "finishes": sorted({str(r["finish"]) for r in rows}), "errors": [r["error"] for r in rows if r["error"]][:3]}
        report["levels"].append(lv)
        print(json.dumps(lv), flush=True)
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_text(json.dumps(report, indent=1), encoding="utf-8")
    print("wrote", a.out)


if __name__ == "__main__":
    main()
