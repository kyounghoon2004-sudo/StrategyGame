"""A1 first supervised state-aggregation round (dagger1, NOT RL).

Collect JEV-visited states on TRAIN scenarios, label with the frozen
Simple-continuation counterfactual teacher, append to the supervised
corpus, retrain from scratch. Only the training-state distribution
changes; every contract stays frozen.
"""

from python_jev.aggregate.dataset_v03 import (
    AGGREGATION_VERSION,
    DATASET_V03_VERSION,
    MODEL_V03_VERSION,
)

__all__ = ["AGGREGATION_VERSION", "DATASET_V03_VERSION", "MODEL_V03_VERSION"]
