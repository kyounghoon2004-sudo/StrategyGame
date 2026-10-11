"""JEV execution-feasibility + benchmark-validation work (F0).

Read-only analysis and mechanical-feasibility contracts. This package MUST
never train: no optimizer, no backward(), no weight updates, no dataset
regeneration, no RL/self-play (enforced by test_f0_feasibility scope guard).
"""

from __future__ import annotations

FEASIBILITY_TASK_VERSION = "jev-feasibility-v0.1.0"

__all__ = ["FEASIBILITY_TASK_VERSION"]
