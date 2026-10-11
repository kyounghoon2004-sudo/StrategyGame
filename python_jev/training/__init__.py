"""python_jev.training — first supervised JevPolicyV0 training run (T0).

Supervised tactical policy learning from six-way counterfactual rollout
values (ValueTargetV0 Q[6] -> PolicyTargetV0 soft targets). No RL, no
self-play, no Fog training.
"""

from python_jev.training.policy_target import (
    POLICY_TARGET_NUM_SLOTS,
    POLICY_TARGET_STD_EPSILON,
    POLICY_TARGET_TEMPERATURE,
    POLICY_TARGET_VERSION,
    POLICY_TARGET_Z_CLIP,
    content_hash as policy_target_hash,
    soft_targets_from_q,
    validate_targets,
)

__all__ = [
    "POLICY_TARGET_NUM_SLOTS",
    "POLICY_TARGET_STD_EPSILON",
    "POLICY_TARGET_TEMPERATURE",
    "POLICY_TARGET_VERSION",
    "POLICY_TARGET_Z_CLIP",
    "policy_target_hash",
    "soft_targets_from_q",
    "validate_targets",
]
