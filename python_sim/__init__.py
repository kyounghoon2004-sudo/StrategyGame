"""python_sim — RulesetV0-faithful Python tactical simulator core (v0.1.0).

Deterministic, headless re-production of the frozen Godot tactical rules with
WorldTruth -> FactionKnowledge -> JevObservation separation and an
ObservationLayoutV0 projector. No training, no datasets, no skill executors.

Architecture (mirror of the authoritative Godot objects, same call shapes):

    rules/       geometry, terrain, movement, combat, visibility, turn
    state/       world_state, unit_state, faction_knowledge, contact_state
    sim/         battle (episode controller), executor (command seam)
    observation/ projector (ObservationLayoutV0)
    policies/    smoke policies for state-machine coverage (not tactical AI)
    parity/      fixtures + fingerprints for Godot-parity verification

Parity layer lives in rules/rounding.py (Godot roundi = half-away-from-zero)
and in every literal epsilon (0.0001 Dijkstra, 0.001 march/budget tolerances).
"""

from __future__ import annotations

SIM_VERSION = "python_sim_v0.1.0"
SIMULATOR_NAME = "python_sim"

__all__ = ["SIM_VERSION", "SIMULATOR_NAME"]
