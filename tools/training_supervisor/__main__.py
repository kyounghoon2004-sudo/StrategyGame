#!/usr/bin/env python3
"""CLI entry for the TrainingSupervisor scaffold.

Scaffold behavior is deliberately minimal and safe:
- ``--plan`` (default): print wiring status, config, and state machine
  summary; perform ZERO real phase commands.
- ``--status``: print persisted run state if present.

The scaffold refuses to run any live phase: real ROLLOUT/TRAIN_BRAIN/EVAL
commands are UNWIRED and will only be wired by the MANUAL_RL_LOOP_V1
result.
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import sys

if __package__ in (None, ""):
    # Run as a script: put the StrategyGame root (parent of tools/) on sys.path
    sys.path.insert(0, os.path.dirname(os.path.dirname(
        os.path.dirname(os.path.abspath(__file__)))))

from tools.training_supervisor.config import default_config  # noqa: E402
from tools.training_supervisor.supervisor import TrainingSupervisor  # noqa: E402


def _strategy_root() -> str:
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main(argv: list = None) -> int:
    parser = argparse.ArgumentParser(description="TrainingSupervisor scaffold V0")
    parser.add_argument("--plan", action="store_true",
                        help="print wiring status and plan (no execution)")
    parser.add_argument("--status", action="store_true",
                        help="print persisted run state if present")
    parser.add_argument("--config", default=None,
                        help="optional JSON config path")
    parser.add_argument("--log-level", default="INFO")
    args = parser.parse_args(argv)
    logging.basicConfig(level=getattr(logging, args.log_level.upper(),
                                      logging.INFO))

    root = _strategy_root()
    # Runtime state lives under raw/ so the gate artifact root keeps only
    # SUPERVISOR_RESULTS.json, HANDOFF.md, and raw/ at top level.
    artifact_root = os.path.join(
        root, "artifacts", "training_supervisor_scaffold_v0", "raw",
        "scaffold_runtime")
    if args.config:
        config = __import__("json").load(open(args.config, encoding="utf-8"))
        from tools.training_supervisor.config import SupervisorConfig
        cfg = SupervisorConfig.from_dict(config)
    else:
        cfg = default_config(project_root=root, artifact_root=artifact_root)
        cfg.run_state_path = os.path.join(artifact_root, "run_state.json")

    sup = TrainingSupervisor(cfg)
    if args.status:
        print(json.dumps(sup.state.to_dict(), indent=2, default=str))
        return 0
    # plan (default)
    report = {
        "scaffold": "TRAINING_SUPERVISOR_SCAFFOLD_V0",
        "dry_run": sup.dry_run,
        "wiring": sup.phase_registry.wiring_report(),
        "wiring_note": "All real ROLLOUT/TRAIN_BRAIN/EVAL commands are "
                       "UNWIRED; wiring inputs come from MANUAL_RL_LOOP_V1.",
        "state": sup.state.to_dict(),
    }
    print(json.dumps(report, indent=2, default=str))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
