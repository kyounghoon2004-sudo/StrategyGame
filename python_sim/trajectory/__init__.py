"""python_sim.trajectory — reusable trajectory recorder (v0.1.0).

A trajectory preserves: initial state hash, decision index, actor, selected
skill, execution result, post-state hash, mission state, terminal state —
enough to replay and re-derive the whole episode (replay determinism J1-17).
"""

from python_sim.trajectory.recorder import (
    TRAJECTORY_FORMAT_VERSION,
    TrajectoryRecorder,
    replay_trajectory,
)

__all__ = ["TRAJECTORY_FORMAT_VERSION", "TrajectoryRecorder", "replay_trajectory"]
