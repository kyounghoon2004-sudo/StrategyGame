"""JEV Godot shadow bridge (SHADOW ONLY).

Persistent localhost inference worker + canonical fact-to-tensor projector so a
live Godot tactical decision can be shown to the trained JEV policy without the
policy ever touching authoritative state.

Authority: SHADOW_ONLY. Nothing in this package mutates gameplay; the Godot
side (scripts/cloud2/cloud2_jev_shadow.gd) only reads state, POSTs facts here,
and appends telemetry.
"""

from __future__ import annotations

SHADOW_CONTRACT_VERSION = "jev-shadow-contract-v1"
SHADOW_REQUEST_VERSION = "jev-shadow-request-v1"
SHADOW_RESPONSE_VERSION = "jev-shadow-response-v1"
SHADOW_TELEMETRY_VERSION = "jev-shadow-telemetry-v1"
SHADOW_SLOTMAP_VERSION = "jev-shadow-slotmap-v1"
SHADOW_MISSIONMAP_VERSION = "jev-shadow-missionmap-v1"

# Single-launch runtime handshake (Godot owns the worker lifecycle).
# Protocol version pins the HTTP surface (GET /health, POST /infer,
# POST /shutdown); observation/action schemas pin the tensor semantics the
# health handshake must attest before the first inference.
SHADOW_PROTOCOL_VERSION = "jev-shadow-protocol-v1"
SHADOW_OBSERVATION_SCHEMA = "observation-layout-v0.1.0"
SHADOW_ACTION_SCHEMA = "jev-shadow-slotmap-v1"
SHADOW_LAUNCHER_VERSION = "jev-shadow-launcher-v1"

MODEL_IDENTITY = "jev-policy-v0.6.0-mission1"
CHECKPOINT_SHA256 = "2c3eae26b09021e2a856090de3bf343f5df432dd50f01c43c1c1d8fefd413867"

__all__ = [
    "CHECKPOINT_SHA256",
    "MODEL_IDENTITY",
    "SHADOW_ACTION_SCHEMA",
    "SHADOW_CONTRACT_VERSION",
    "SHADOW_LAUNCHER_VERSION",
    "SHADOW_MISSIONMAP_VERSION",
    "SHADOW_OBSERVATION_SCHEMA",
    "SHADOW_PROTOCOL_VERSION",
    "SHADOW_REQUEST_VERSION",
    "SHADOW_RESPONSE_VERSION",
    "SHADOW_SLOTMAP_VERSION",
    "SHADOW_TELEMETRY_VERSION",
]
