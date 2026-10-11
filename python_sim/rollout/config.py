"""Rollout configuration + versioned continuation policies.

Continuation policies are SIMPLE, explicitly versioned, and frozen scripted
smoke policies (task-allowed set). JevPolicyV0 is NOT an authorized
continuation policy here (it is untrained).

Horizon is expressed in TACTICAL ACTOR DECISIONS after the initial skill
execution (not fixed turns) with a turn safety cap, and is versioned
configuration — never a hardcoded constant inside the dataset.
"""

from __future__ import annotations

import random
from dataclasses import dataclass, field

from python_sim.policies import HoldPolicy, RandomLegalPolicy, SimpleAttackElseAdvancePolicy

ROLLOUT_CONFIG_VERSION = "rollout-config-v0.1.0"
# v0.1.1: SimpleAttackElseAdvancePolicy advance-toward fix (T0). v0.1.0
# minimized (-dist, cost, key), fleeing from the enemy; v0.1.1 minimizes
# (dist, cost, key) per the documented "advance toward nearest known enemy".
CONTINUATION_POLICY_VERSION = "continuation-policies-v0.1.1"

CONTINUATION_POLICIES: dict[str, str] = {
    "RandomLegalPolicy": "seeded random over legal blue/red commands",
    "SimpleAttackElseAdvancePolicy": "attack else advance else hold (scripted)",
    "HoldPolicy": "hold in place (pure reset/cycle coverage)",
}


@dataclass
class RolloutConfig:
    continuation_policy: str = "SimpleAttackElseAdvancePolicy"
    seed: int = 0
    horizon_decisions: int = 8      # tactical actor decisions after the branch skill
    max_turns: int = 24             # hard turn safety cap
    red_policy: str = "SimpleAttackElseAdvancePolicy"

    def make_blue_policy(self):
        return _instantiate(self.continuation_policy, self.seed)

    def make_red_policy(self):
        return _instantiate(self.red_policy, self.seed)

    def to_dict(self) -> dict:
        return {
            "rollout_config_version": ROLLOUT_CONFIG_VERSION,
            "continuation_policy_version": CONTINUATION_POLICY_VERSION,
            "continuation_policy": self.continuation_policy,
            "seed": self.seed,
            "horizon_decisions": self.horizon_decisions,
            "max_turns": self.max_turns,
            "red_policy": self.red_policy,
        }


def _instantiate(name: str, seed: int):
    if name == "RandomLegalPolicy":
        return RandomLegalPolicy(seed=seed)
    if name == "SimpleAttackElseAdvancePolicy":
        return SimpleAttackElseAdvancePolicy()
    if name == "HoldPolicy":
        return HoldPolicy()
    raise KeyError(f"unknown continuation policy {name!r}; known: {sorted(CONTINUATION_POLICIES)}")


__all__ = [
    "CONTINUATION_POLICIES",
    "CONTINUATION_POLICY_VERSION",
    "ROLLOUT_CONFIG_VERSION",
    "RolloutConfig",
]
