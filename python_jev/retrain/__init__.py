"""R1 corrected-target retraining (jev-fullinfo-dataset-v0.2.0 / jev-policy-v0.2.0-fi).

Controlled experiment: the ONLY major factor changed vs T0 is the legality
mask (SkillPreflightV0 / observation-safe-skill-mask-v0.2.0). Architecture,
ValueTargetV0, PolicyTargetV0 transform, horizon, continuation teacher,
optimizer, learning rate, batch size, scenario splits, and training seeds
are all identical to T0.

Supervised retraining from scratch only. No Fog training, no RL, no
self-play, no architecture change, no Godot change.
"""

from python_jev.retrain.dataset_v2 import (
    DATASET_V2_VERSION,
    MODEL_V2_VERSION,
    load_shard_v2,
)

__all__ = ["DATASET_V2_VERSION", "MODEL_V2_VERSION", "load_shard_v2"]
