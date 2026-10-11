"""python_jev — Jev-inspired System-1 Tactical Neural Policy, v0 skeleton.

Untrained network package only. This package intentionally contains:
  - the frozen production observation tensor contract (schema adapter layer),
  - the JevPolicyV0 neural skeleton (encoders, fusion trunk, class heads),
  - observation-safe legality masking,
  - a synthetic observation factory for shape/verification tests.

It intentionally does NOT contain a battle simulator, training loop, dataset
generation, RL, ONNX export, an inference server, or any Godot gameplay code.

Authoritative architecture: Notion page
"Research Branch — System-1 Tactical Neural Model / Jev-inspired"
(Production Observation Schema Freeze; MVP six-skill tables).
"""

from python_jev.constants import (
    ACTION_SPACE,
    LEARNED_CLASSES,
    MODEL_VERSION,
    NUM_SKILL_SLOTS,
    OBSERVATION_SCHEMA_VERSION,
    SCHEMA_REVISION,
)
from python_jev.masking import (
    ALL_ILLEGAL_SLOT,
    LegalMaskResult,
    apply_legal_mask,
)
from python_jev.model import (
    FusionTrunk,
    GlobalEncoder,
    HexEncoder,
    JevPolicyV0,
    MissionEncoder,
    TokenEncoder,
    UnitContextPool,
)
from python_jev.observation import ObservationBatchV0
from python_jev.output import JevPolicyOutput

__all__ = [
    "ACTION_SPACE",
    "ALL_ILLEGAL_SLOT",
    "FusionTrunk",
    "GlobalEncoder",
    "HexEncoder",
    "JevPolicyOutput",
    "JevPolicyV0",
    "LEARNED_CLASSES",
    "LegalMaskResult",
    "MODEL_VERSION",
    "MissionEncoder",
    "NUM_SKILL_SLOTS",
    "OBSERVATION_SCHEMA_VERSION",
    "ObservationBatchV0",
    "SCHEMA_REVISION",
    "TokenEncoder",
    "UnitContextPool",
    "apply_legal_mask",
]
