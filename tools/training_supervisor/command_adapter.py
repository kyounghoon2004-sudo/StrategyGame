"""Declarative phase command specs — the command adapter contract.

The eventual real ROLLOUT / TRAIN_BRAIN / EVAL commands are NOT frozen yet
(the later MANUAL_RL_LOOP_V1 gate will freeze them). This module therefore
defines only the spec shape and a fail-closed execution guard: a phase whose
required command fields are unwired (command null, or expected_outputs
empty) is refused for live execution, with precise reasons.

``dry_run=True`` is the safe default everywhere.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

ROLLOUT = "ROLLOUT"
TRAIN_BRAIN = "TRAIN_BRAIN"
EVAL = "EVAL"

PHASE_KEYS = (ROLLOUT, TRAIN_BRAIN, EVAL)

UNWIRED = "UNWIRED"


@dataclass
class PhaseCommandSpec:
    """Declarative spec for one phase command.

    Mirrors the cold-prompt shape:

        {
          "phase": "ROLLOUT",
          "command": null,
          "args": [],
          "cwd": null,
          "env": {},
          "timeout_sec": null,
          "expected_outputs": []
        }

    All fields default to unwired; ``command`` null means UNWIRED.
    """

    phase: str
    command: Optional[str] = None
    args: List[str] = field(default_factory=list)
    cwd: Optional[str] = None
    env: Dict[str, str] = field(default_factory=dict)
    timeout_sec: Optional[float] = None
    expected_outputs: List[str] = field(default_factory=list)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "phase": self.phase,
            "command": self.command,
            "args": list(self.args),
            "cwd": self.cwd,
            "env": dict(self.env),
            "timeout_sec": self.timeout_sec,
            "expected_outputs": list(self.expected_outputs),
        }

    @classmethod
    def from_dict(cls, d: Dict[str, Any]) -> "PhaseCommandSpec":
        return cls(
            phase=str(d["phase"]),
            command=d.get("command"),
            args=list(d.get("args") or []),
            cwd=d.get("cwd"),
            env=dict(d.get("env") or {}),
            timeout_sec=d.get("timeout_sec"),
            expected_outputs=list(d.get("expected_outputs") or []),
        )

    def unwired_reasons(self) -> List[str]:
        """Reasons this spec is not eligible for live execution.

        Fail-closed rules:
        - command must be a non-empty string
        - expected_outputs must be non-empty (completeness must be provable
          by manifest before a phase can ever be considered successful)
        """
        reasons: List[str] = []
        if not self.command or not str(self.command).strip():
            reasons.append(f"{self.phase}.command is null/empty ({UNWIRED})")
        if not self.expected_outputs:
            reasons.append(
                f"{self.phase}.expected_outputs is empty; phase completeness "
                "cannot be proven without a manifest contract")
        return reasons

    def is_wired(self) -> bool:
        return not self.unwired_reasons()

    def wiring_status(self) -> str:
        return "WIRED" if self.is_wired() else UNWIRED


class PhaseCommandRegistry:
    """Holds one spec per executable phase; all default to UNWIRED specs."""

    def __init__(self,
                 specs: Optional[Dict[str, PhaseCommandSpec]] = None) -> None:
        self._specs: Dict[str, PhaseCommandSpec] = {}
        for key in PHASE_KEYS:
            self._specs[key] = (specs or {}).get(key, PhaseCommandSpec(phase=key))

    def get(self, phase: str) -> PhaseCommandSpec:
        if phase not in self._specs:
            # Machine-only phase (no command contract): auto-unwired.
            self._specs[phase] = PhaseCommandSpec(phase=phase)
        return self._specs[phase]

    def set(self, spec: PhaseCommandSpec) -> None:
        if spec.phase not in PHASE_KEYS:
            raise ValueError(f"unknown phase key: {spec.phase!r}")
        self._specs[spec.phase] = spec

    def wiring_report(self) -> Dict[str, str]:
        return {key: self._specs[key].wiring_status() for key in PHASE_KEYS}

    def to_dict(self) -> Dict[str, Dict[str, Any]]:
        return {key: self._specs[key].to_dict() for key in PHASE_KEYS}
