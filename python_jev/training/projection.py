"""Training-scoped observation projection (mission-context fail-fast).

The production projector keeps its legacy ``mission_context=None`` default
for historical simulator tests and non-training tooling. Training and
data-generation collectors MUST route through :func:`project_for_training`,
which requires the canonical ``MissionContext``
(``python_sim.skills.context``) and fails fast otherwise — a missing or
substitute context must never silently produce default mission features
in training data.
"""

from __future__ import annotations

from python_sim.skills.context import MissionContext

TRAINING_PROJECTION_VERSION = "training-projection-v0.1.0"


def require_training_context(ctx: MissionContext) -> dict:
    """Validate the canonical context and return the projector dict.

    Raises:
        ValueError: ``ctx`` is None or carries no scenario identity
            (a default-constructed context is not an actual mission).
        TypeError: ``ctx`` is not the canonical ``MissionContext`` type.
    """
    if ctx is None:
        raise ValueError(
            "training projection requires the actual MissionContext for the "
            "acting side; got None (the projector legacy default is "
            "forbidden on training/data-generation paths)"
        )
    if not isinstance(ctx, MissionContext):
        raise TypeError(
            "training projection requires the canonical MissionContext "
            f"(python_sim.skills.context); got {type(ctx).__name__}"
        )
    d = ctx.to_dict()
    if not d.get("scenario_id"):
        raise ValueError(
            "training projection requires a MissionContext with scenario_id; "
            "got an unidentified (default) context"
        )
    return d


def project_for_training(projector, side: str, actor_id: str, ctx: MissionContext):
    """Project with the actual mission context (fail-fast wrapper).

    Uses the repo projector signature
    ``project(side, actor_id, mission_context=...)``; the context dict is
    derived from the canonical ``MissionContext`` via
    :func:`require_training_context`.
    """
    return projector.project(
        side, actor_id, mission_context=require_training_context(ctx)
    )


__all__ = [
    "TRAINING_PROJECTION_VERSION",
    "project_for_training",
    "require_training_context",
]
