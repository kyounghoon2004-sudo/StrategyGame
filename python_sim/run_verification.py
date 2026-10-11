"""python_sim verification entry point (S0 gates + parity matrix + perf).

Usage:  python -m python_sim.run_verification
"""

from __future__ import annotations

import json
import subprocess
import sys
import time

from python_sim import SIM_VERSION
from python_jev.contracts import observation_layout as ol
from python_jev.contracts import ruleset as rs
from python_sim.parity.fixtures import battle_10v10, matrix_summary, run_parity_matrix
from python_sim.policies import SimpleAttackElseAdvancePolicy
from python_sim.sim.battle import SCENARIO_PROFILES, Battle


def _print(*args: object) -> None:
    print(*args, flush=True)


def main() -> int:
    _print("=" * 72)
    _print(f"python_sim verification - {SIM_VERSION}")
    _print(f"ruleset: {rs.RULESET_VERSION} (sha256 {rs.content_hash()[:16]}...)")
    _print(f"observation: {ol.LAYOUT_CONTRACT_VERSION} (sha256 {ol.content_hash()[:16]}...)")
    _print("=" * 72)

    # 1) unit gates (S0 suite) -----------------------------------------------
    _print("\n[1/4] running S0 gate test suite (pytest python_sim/tests) ...")
    proc = subprocess.run(
        [sys.executable, "-m", "pytest", "python_sim/tests", "-q", "--tb=short"],
        cwd=".", capture_output=True, text=True,
    )
    tail = proc.stdout.strip().splitlines()[-12:]
    for line in tail:
        _print("  " + line)
    suite_ok = proc.returncode == 0

    # 2) parity matrix ----------------------------------------------------------
    _print("\n[2/4] parity matrix P01-P16 + 10v10 ...")
    cases = run_parity_matrix()
    summary = matrix_summary(cases)
    for c in cases:
        _print(f"  {c.pid:>6} {c.name:<32} {c.status}")
        if c.status == "FAIL":
            _print(f"         detail: {json.dumps(c.detail)[:300]}")
    _print(f"  summary: {summary['pass_count']} pass / {summary['fail_count']} fail")

    # 3) profiles ----------------------------------------------------------------
    _print("\n[3/4] scenario profile matrix ...")
    for name in SCENARIO_PROFILES:
        flags = SCENARIO_PROFILES[name]
        degraded = " (DEGRADED: unresolved contract gaps)" if flags.get("degraded") else ""
        _print(f"  {name:<20} terrain={int(flags['terrain_effects'])} obstacles={int(flags['obstacles_strongholds'])} fog={int(flags['fog_stale_contacts'])} morale={int(flags['morale_rout_fatigue'])} ambush={int(flags['ambush'])}{degraded}")

    # 4) performance ---------------------------------------------------------------
    _print("\n[4/4] performance baseline ...")
    b = battle_10v10()
    policy = SimpleAttackElseAdvancePolicy()
    turns = 0
    decisions = 0
    start = time.perf_counter()
    for _ in range(5):
        for uid in sorted(u.id for u in list(b.world.units.values()) if u.faction == "blue"):
            if uid in b.world.units:
                policy.blue_action(b, uid)
                decisions += 1
        for uid in sorted(u.id for u in list(b.world.units.values()) if u.faction == "red"):
            if uid in b.world.units:
                policy.red_action(b, uid)
                decisions += 1
        b.sim_end_turn()
        turns += 1
    elapsed = time.perf_counter() - start
    t0 = time.perf_counter()
    b.clone()
    clone_ms = (time.perf_counter() - t0) * 1000.0
    t0 = time.perf_counter()
    for _ in range(20):
        b.clone()
    clone_ms_avg = (time.perf_counter() - t0) * 1000.0 / 20.0
    _print(f"  episode slice: {elapsed * 1000.0:.1f} ms for 5 turns of 10v10")
    _print(f"  turns/sec:     {turns / elapsed:.1f}")
    _print(f"  decisions/sec: {decisions / elapsed:.1f}")
    _print(f"  clone cost:    {clone_ms:.2f} ms (avg {clone_ms_avg:.2f} ms over 20)")

    _print("\nOVERALL: " + ("PASS" if suite_ok and summary["fail_count"] == 0 else "FAIL"))
    return 0 if (suite_ok and summary["fail_count"] == 0) else 1


if __name__ == "__main__":
    raise SystemExit(main())
