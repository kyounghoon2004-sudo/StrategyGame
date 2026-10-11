"""python_jev.contracts — machine-readable contract manifests.

ObservationLayoutV0 (obs-v0 rev 1) and RulesetV0 (rev 1) are the authority for
the future Python tactical simulator and the Godot observation projector.
Datasets, rollouts, checkpoints and evaluation reports must record both
manifest hashes; a mismatch must be detectable (R0-13).
"""

from python_jev.contracts.hex_patch import (
    MANIFEST as HEX_PATCH_MANIFEST,
    PATCH_CONTRACT_VERSION,
    content_hash as hex_patch_content_hash,
    offset_to_index,
)
from python_jev.contracts.observation_layout import (
    LAYOUT_CONTRACT_VERSION,
    MANIFEST as OBSERVATION_LAYOUT_MANIFEST,
    OBSERVATION_SCHEMA_REVISION,
    OBSERVATION_SCHEMA_VERSION,
    TOKEN_CAPACITY,
    TOKEN_CAPACITY_RATIONALE,
    content_hash as observation_layout_content_hash,
    to_manifest as observation_layout_manifest,
)
from python_jev.contracts.ruleset import (
    MANIFEST as RULESET_MANIFEST,
    RULESET_REVISION,
    RULESET_VERSION,
    UNRESOLVED_CONTRACT_GAPS,
    content_hash as ruleset_content_hash,
    to_manifest as ruleset_manifest,
)

__all__ = [
    "HEX_PATCH_MANIFEST",
    "LAYOUT_CONTRACT_VERSION",
    "OBSERVATION_LAYOUT_MANIFEST",
    "OBSERVATION_SCHEMA_REVISION",
    "OBSERVATION_SCHEMA_VERSION",
    "PATCH_CONTRACT_VERSION",
    "RULESET_MANIFEST",
    "RULESET_REVISION",
    "RULESET_VERSION",
    "TOKEN_CAPACITY",
    "TOKEN_CAPACITY_RATIONALE",
    "UNRESOLVED_CONTRACT_GAPS",
    "hex_patch_content_hash",
    "offset_to_index",
    "observation_layout_content_hash",
    "observation_layout_manifest",
    "ruleset_content_hash",
    "ruleset_manifest",
]
