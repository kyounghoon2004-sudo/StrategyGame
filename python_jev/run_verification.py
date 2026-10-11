"""Verification / benchmark entry point for the Jev v0 skeleton.

Usage (from the repository root `Demon slayer/StrategyGame`):
    python -m python_jev.run_verification

Runs the N0 gate suite and a consolidated forward benchmark, then prints
STATUS, parameter count, per-gate results and latency numbers. This is a
verification harness only — no training, no simulator, no dataset generation.
"""

from __future__ import annotations

import subprocess
import sys
import time

import torch

from python_jev.constants import MODEL_VERSION
from python_jev.model import JevPolicyV0
from python_jev.synthetic import make_observation_batch

GATE_SUITE = "python_jev/tests/test_n0_gates.py"


def run_gate_suite() -> int:
    cmd = [
        sys.executable, "-m", "pytest", GATE_SUITE,
        "-v", "--tb=short", "-s",
    ]
    print(f"$ {' '.join(cmd)}\n", flush=True)
    return subprocess.call(cmd)


def benchmark_forward() -> dict[str, object]:
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    dtype = torch.float32
    torch.manual_seed(0)
    model = JevPolicyV0().to(device=device, dtype=dtype)
    model.eval()

    total_params = sum(p.numel() for p in model.parameters() if p.requires_grad)

    results: dict[str, object] = {
        "device": str(device),
        "dtype": str(dtype),
        "cuda_available": torch.cuda.is_available(),
        "cuda_name": torch.cuda.get_device_name(0) if device.type == "cuda" else "n/a",
        "parameters": total_params,
        "model_version": MODEL_VERSION,
    }

    def bench(batch: int, iters: int, warmup: int = 8) -> float:
        obs = make_observation_batch(
            batch_size=batch, num_friendly=4, num_visible_enemies=3,
            num_stale=2, device=device,
        )
        with torch.no_grad():
            for _ in range(warmup):
                model(obs)
            if device.type == "cuda":
                torch.cuda.synchronize()
            t0 = time.perf_counter()
            for _ in range(iters):
                model(obs)
            if device.type == "cuda":
                torch.cuda.synchronize()
            return (time.perf_counter() - t0) / iters * 1000.0

    results["batch1_ms"] = bench(1, iters=100 if device.type == "cpu" else 200)
    results["batch32_ms"] = bench(32, iters=50 if device.type == "cpu" else 100)
    results["batch64_ms"] = bench(64, iters=50 if device.type == "cpu" else 100)
    return results


def main() -> int:
    # Windows consoles (e.g. cp949) cannot print every Unicode glyph; keep
    # the report strictly ASCII-safe.
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")

    print("=" * 72)
    print("JEV POLICY V0 - N0 VERIFICATION (untrained skeleton only)")
    print("=" * 72)

    print("\n--- N0 gate suite ---", flush=True)
    rc = run_gate_suite()
    if rc != 0:
        print("\nGATE SUITE FAILED — see pytest output above.")
        return rc

    print("\n--- Consolidated forward benchmark ---")
    b = benchmark_forward()
    for key, val in b.items():
        val_s = f"{val:,.2f} ms" if isinstance(val, float) else str(val)
        print(f"  {key:>16}: {val_s}")

    print("\nScope check: simulator NOT STARTED; training NOT STARTED; "
          "dataset generation NOT STARTED; Godot gameplay untouched.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
