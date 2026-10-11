"""Paths and constants for the training observability sidecar.

This package NEVER imports tools.training_supervisor. Producer constants that
matter for interpretation (prompt source, seed plan) are restated here as
plain data and documented as "derived from producer code (read-only)".
"""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import List

PACKAGE_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = PACKAGE_DIR.parents[1]  # ...\StrategyGame
ARTIFACTS = PROJECT_ROOT / "artifacts"

MARATHON_ROOT = ARTIFACTS / "training_marathon_v1"
OUTPUT_ROOT = ARTIFACTS / "training_observability_v1"
HISTORICAL_ROOTS = {
    "rl_pipeline_proof_v0": ARTIFACTS / "rl_pipeline_proof_v0",
    "manual_rl_loop_v1": ARTIFACTS / "manual_rl_loop_v1",
}
SUPERVISOR_CODE_DIR = PROJECT_ROOT / "tools" / "training_supervisor"
# Producer constant (marathon_phase_rollout.py / marathon_phase_eval.py).
PROMPT_SRC = Path(r"D:\StrategyAI\runtimes\sparkx25\bench\raw\bench_prompt_A.json")
GPU_LOCK_PATH = Path(r"D:\StrategyAI\locks\training_marathon_v1.lock")  # never opened

# Producer seed plan (marathon_wiring.py), restated for disjointness checks.
TRAIN_SEED_BASE = 3101
TRAIN_SEED_STRIDE = 100
EVAL_SEED_BASE = 9101
EVAL_SEED_STRIDE = 10
MAX_GROUPS = 8
ROLLOUT_EPISODE_SEED_OFFSET = 1000  # rollout godot seed = 1000 + generation seed

# Rollout opponent, from tools/rl_proof_episode.gd (_blue_doc fixture).
ROLLOUT_OPPONENT = {"kind": "FROZEN_FIXTURE",
                    "id": "rl_proof_episode.gd::_blue_doc",
                    "side": "BLUE",
                    "provenance": "DERIVED_FROM_PRODUCER_CODE"}


@dataclass
class Paths:
    marathon_root: Path = MARATHON_ROOT
    output_root: Path = OUTPUT_ROOT
    historical_roots: dict = field(default_factory=lambda: dict(HISTORICAL_ROOTS))
    prompt_src: Path = PROMPT_SRC

    @property
    def protected_roots(self) -> List[Path]:
        roots = [self.marathon_root, SUPERVISOR_CODE_DIR, GPU_LOCK_PATH.parent,
                 self.prompt_src.parent]
        roots += list(self.historical_roots.values())
        return [Path(os.path.abspath(r)) for r in roots]

    @property
    def metrics_dir(self) -> Path:
        return self.output_root / "metrics"

    @property
    def dataset_dir(self) -> Path:
        return self.output_root / "dataset"

    @property
    def audits_dir(self) -> Path:
        return self.output_root / "audits"
