"""Versioned supervisor config schema.

Placeholders only: project/artifact roots, phase command specs (all
UNWIRED), VRAM policy (preferred 20.5 GiB / hard 22.0 GiB as established
by prior gates), timeouts, iteration limits, and ``dry_run=True`` as the
safe default. No real RL command is pre-filled anywhere in this scaffold.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any, Dict, Optional

from .command_adapter import PhaseCommandRegistry, PhaseCommandSpec

CONFIG_SCHEMA_VERSION = 1

#: VRAM policy constants from prior project gates (metadata only).
PREFERRED_VRAM_GIB = 20.5
HARD_VRAM_GIB = 22.0

DEFAULT_TIMEOUT_SEC = 3600.0
DEFAULT_MAX_ITERATIONS = 100


@dataclass
class SupervisorConfig:
    """Versioned config. ``dry_run=True`` is the safe default."""

    schema_version: int = CONFIG_SCHEMA_VERSION

    project_root: str = ""
    artifact_root: str = ""
    run_state_path: str = ""
    logs_dir: str = ""
    locks_dir: str = ""  # test/temp lock dir for scaffold; real dir only at wiring time

    phase_specs: Dict[str, Dict[str, Any]] = field(default_factory=dict)

    vram_policy: Dict[str, float] = field(default_factory=lambda: {
        "preferred_gib": PREFERRED_VRAM_GIB,
        "hard_gib": HARD_VRAM_GIB,
    })

    timeout_sec: Dict[str, Optional[float]] = field(default_factory=lambda: {
        "ROLLOUT": None,
        "TRAIN_BRAIN": None,
        "EVAL": None,
        "default": DEFAULT_TIMEOUT_SEC,
    })

    max_iterations: int = DEFAULT_MAX_ITERATIONS
    dry_run: bool = True  # SAFE DEFAULT: refuse live execution

    def resolved_phase_registry(self) -> PhaseCommandRegistry:
        specs = {
            key: PhaseCommandSpec.from_dict(value)
            for key, value in (self.phase_specs or {}).items()
        }
        return PhaseCommandRegistry(specs)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "schema_version": self.schema_version,
            "project_root": self.project_root,
            "artifact_root": self.artifact_root,
            "run_state_path": self.run_state_path,
            "logs_dir": self.logs_dir,
            "locks_dir": self.locks_dir,
            "phase_specs": self.phase_specs,
            "vram_policy": dict(self.vram_policy),
            "timeout_sec": dict(self.timeout_sec),
            "max_iterations": self.max_iterations,
            "dry_run": self.dry_run,
        }

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "SupervisorConfig":
        version = data.get("schema_version")
        if version != CONFIG_SCHEMA_VERSION:
            raise ValueError(
                f"config schema_version {version!r} not understood "
                f"(expected {CONFIG_SCHEMA_VERSION})")
        return cls(
            schema_version=version,
            project_root=data.get("project_root", ""),
            artifact_root=data.get("artifact_root", ""),
            run_state_path=data.get("run_state_path", ""),
            logs_dir=data.get("logs_dir", ""),
            locks_dir=data.get("locks_dir", ""),
            phase_specs=dict(data.get("phase_specs") or {}),
            vram_policy=dict(data.get("vram_policy") or {}),
            timeout_sec=dict(data.get("timeout_sec") or {}),
            max_iterations=int(data.get("max_iterations", DEFAULT_MAX_ITERATIONS)),
            dry_run=bool(data.get("dry_run", True)),
        )

    def save(self, path: str) -> None:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(self.to_dict(), f, indent=2)

    @classmethod
    def load(cls, path: str) -> "SupervisorConfig":
        with open(path, "r", encoding="utf-8") as f:
            return cls.from_dict(json.load(f))


def default_config(project_root: str, artifact_root: str) -> SupervisorConfig:
    """Scaffold-default config: every phase UNWIRED, dry_run forced True."""
    return SupervisorConfig(
        project_root=project_root,
        artifact_root=artifact_root,
        run_state_path="",
        logs_dir="",
        locks_dir="",
        phase_specs={},  # empty => registry produces UNWIRED specs for all phases
        dry_run=True,
    )
