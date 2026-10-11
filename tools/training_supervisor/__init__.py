"""TrainingSupervisor scaffold V0 — deterministic RL training control-plane skeleton.

ISOLATED SCAFFOLD — NOT OPERATIONAL PRODUCTION AUTOMATION.

All real rollout / train / eval phase commands are UNWIRED. The later
MANUAL_RL_LOOP_V1 gate will freeze the exact commands and schemas to wire.
This package ships only validated interfaces, a phase state machine,
atomic persistent run state, and safety contracts, CPU-only.

Zero GPU / model / Godot / RL side effects on import.
"""
from __future__ import annotations

SCAFFOLD_VERSION = "TRAINING_SUPERVISOR_SCAFFOLD_V0"

__all__ = ["SCAFFOLD_VERSION"]
