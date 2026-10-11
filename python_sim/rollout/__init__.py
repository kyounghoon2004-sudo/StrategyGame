"""python_sim.rollout — counterfactual six-skill rollout engine (v0.2.0).

One frozen decision state + one current actor -> all six class-specific
skills evaluated on independent state clones -> raw outcome vectors
(raw-outcome-vector-v0.2.0) + ValueTargetV0 scalar Q for full-information
profiles.

Scalar Q[6] export remains FORBIDDEN for partial-information profiles
(fog oracle guard in value_target.py).
"""

from python_sim.rollout.branch_snapshot import (
    BRANCH_SNAPSHOT_VERSION,
    capture_branch_start,
    casualty_exchange,
)
from python_sim.rollout.config import (
    CONTINUATION_POLICY_VERSION,
    ROLLOUT_CONFIG_VERSION,
    RolloutConfig,
)
from python_sim.rollout.mission_progress import MISSION_PROGRESS_VERSION
from python_sim.rollout.objective_progress import OBJECTIVE_PROGRESS_VERSION
from python_sim.rollout.outcome import (
    OUTCOME_VECTOR_VERSION,
    OUTCOME_VECTOR_VERSION_V2,
    raw_outcome_vector,
    raw_outcome_vector_v2,
)
from python_sim.rollout.terminal import TERMINAL_OUTCOME_VERSION
from python_sim.rollout.value_target import (
    Q_EXPORT_STATUS,
    VALUE_TARGET_CONTRACT_EXISTS,
    VALUE_TARGET_VERSION,
    ValueTargetBlocked,
    compute_scalar_q,
    derive_branch_terms,
    q_export_status,
    value_of,
)
from python_sim.rollout.engine import (
    ROLLOUT_ENGINE_VERSION,
    CounterfactualEngine,
    SixWayEvaluation,
)

__all__ = [
    "BRANCH_SNAPSHOT_VERSION",
    "CONTINUATION_POLICY_VERSION",
    "CounterfactualEngine",
    "MISSION_PROGRESS_VERSION",
    "OBJECTIVE_PROGRESS_VERSION",
    "OUTCOME_VECTOR_VERSION",
    "OUTCOME_VECTOR_VERSION_V2",
    "Q_EXPORT_STATUS",
    "ROLLOUT_CONFIG_VERSION",
    "ROLLOUT_ENGINE_VERSION",
    "RolloutConfig",
    "SixWayEvaluation",
    "TERMINAL_OUTCOME_VERSION",
    "VALUE_TARGET_CONTRACT_EXISTS",
    "VALUE_TARGET_VERSION",
    "ValueTargetBlocked",
    "capture_branch_start",
    "casualty_exchange",
    "compute_scalar_q",
    "derive_branch_terms",
    "q_export_status",
    "raw_outcome_vector",
    "raw_outcome_vector_v2",
    "value_of",
]
