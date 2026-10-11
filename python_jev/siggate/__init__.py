"""Significance-gated aggregation ablation (experimental, NOT production v0.6).

Tests whether including only tactically significant EXISTING Dagger3 rows
(driver_regret / teacher_margin gates) recovers v0.4-quality behavior.
No new collection, no architecture/teacher/target/optimizer changes.
"""

from __future__ import annotations

SIGGATE_VERSION = "significance-gated-aggregation-ablation-v0.1.0"
OUT_ROOT = "artifacts/jev_significance_gate_v0"

# (arm, predicate-kind, regret threshold, margin threshold)
ARMS: tuple[tuple[str, str, float, float], ...] = (
    ("r25", "R", 0.0025, 0.0),
    ("m25", "M", 0.0, 0.0025),
    ("or25", "OR", 0.0025, 0.0025),
    ("and25", "AND", 0.0025, 0.0025),
    ("or10", "OR", 0.001, 0.001),
    ("or50", "OR", 0.005, 0.005),
)

ARM_NAMES = tuple(a[0] for a in ARMS)
SEEDS = (42, 43, 44)
N_BASE_ROWS = 21290  # v0.4 corpus prefix inside the v0.5 train shard

__all__ = ["ARM_NAMES", "ARMS", "N_BASE_ROWS", "OUT_ROOT", "SEEDS", "SIGGATE_VERSION"]
