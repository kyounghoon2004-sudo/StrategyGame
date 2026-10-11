"""Training projection gates — actual mission context + fail-fast.

P0-1  Training projection requires the canonical MissionContext.
P0-2  Missing / substitute / unidentified contexts fail fast.
P0-3  Actual context reaches mission features; legacy default preserved
      for historical simulator tests and non-training tooling.
"""

from __future__ import annotations

import pytest

from python_jev.training.projection import (
    TRAINING_PROJECTION_VERSION,
    project_for_training,
    require_training_context,
)


# ------------------------------------------------------------------ P0-1
def test_p0_1_canonical_mission_context_accepted() -> None:
    from python_jev.training.scenarios import (
        generate_scenario,
        mission_context_for_side,
    )
    from python_sim.skills.context import MissionContext

    assert TRAINING_PROJECTION_VERSION == "training-projection-v0.1.0"
    scenario = generate_scenario(0)["scenario"]
    ctx = MissionContext(**mission_context_for_side(scenario, "blue"))
    d = require_training_context(ctx)
    assert d["scenario_id"] == scenario["scenario_id"]
    assert d["mission_type"] == "SEEK_BATTLE"
    assert d["actor_mission_role"] in ("PRIMARY", "RECON")
    assert isinstance(d["doctrine"], dict)


# ------------------------------------------------------------------ P0-2
def test_p0_2_fail_fast_on_missing_or_substitute_context() -> None:
    from python_sim.skills.context import MissionContext

    with pytest.raises(ValueError):
        require_training_context(None)
    # a second representation (plain dict) is rejected: canonical type only
    with pytest.raises(TypeError):
        require_training_context({"scenario_id": "x", "mission_type": "SEEK_BATTLE"})
    # a default-constructed context is not an actual mission
    with pytest.raises(ValueError):
        require_training_context(MissionContext())
    with pytest.raises(ValueError):
        require_training_context(MissionContext(scenario_id=""))


# ------------------------------------------------------------------ P0-3
def test_p0_3_actual_context_reaches_features_and_legacy_default_kept() -> None:
    from python_jev.layout import MISSION_GROUP_OFFSETS
    from python_sim.observation.projector import ObservationProjector
    from python_sim.parity.fixtures import probe_scenario
    from python_sim.sim.battle import Battle
    from python_sim.skills.context import MissionContext

    battle = Battle(probe_scenario(), "DEV_FLAT_ALL_INFO")
    projector = ObservationProjector(battle)
    d0 = MISSION_GROUP_OFFSETS["doctrine_scalars"][0]
    k0 = MISSION_GROUP_OFFSETS["doctrine_known"][0]

    # actual context: declared doctrine scalar lands in mission features
    ctx = MissionContext(scenario_id="p0_probe", doctrine={"aggression": 0.9})
    proj = project_for_training(projector, "blue", "B_INF_1", ctx)
    assert proj.mission_features[d0] == pytest.approx(0.9)
    assert proj.mission_features[k0] == 1.0

    # legacy default preserved for historical tests / non-training tooling
    legacy = projector.project("blue", "B_INF_1")
    assert legacy.mission_features[d0] == pytest.approx(0.5)
    assert legacy.mission_features[k0] == 0.0
