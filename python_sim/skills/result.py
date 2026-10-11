"""Typed skill result wrapper (thin view over the canonical envelope dict)."""

from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class SkillResult:
    """Typed view of the canonical envelope (fields mirror contracts.success)."""

    status: str                       # SUCCESS | PARTIAL | INVALID
    skill_class: str
    skill_slot: int
    skill_name: str
    actor_id: str
    state_version_before: int
    state_version_after: int
    failure_code: str = "NONE"
    target_id: str | None = None
    destination: list[int] | None = None
    path: list[list[int]] = field(default_factory=list)
    mechanical_effects: dict = field(default_factory=dict)
    tie_break_trace: list[str] = field(default_factory=list)
    partial: dict | None = None
    detail: str = ""

    @property
    def success(self) -> bool:
        return self.status in ("SUCCESS", "PARTIAL")

    @property
    def interrupted(self) -> bool:
        return self.status == "PARTIAL"

    @property
    def invalid(self) -> bool:
        return self.status == "INVALID"

    def to_dict(self) -> dict:
        return {
            "status": self.status,
            "skill_class": self.skill_class,
            "skill_slot": self.skill_slot,
            "skill_name": self.skill_name,
            "actor_id": self.actor_id,
            "state_version_before": self.state_version_before,
            "state_version_after": self.state_version_after,
            "failure_code": self.failure_code,
            "target_id": self.target_id,
            "destination": self.destination,
            "path": self.path,
            "mechanical_effects": self.mechanical_effects,
            "tie_break_trace": self.tie_break_trace,
            "partial": self.partial,
            "detail": self.detail,
        }

    @classmethod
    def from_dict(cls, d: dict) -> "SkillResult":
        return cls(
            status=d["status"],
            skill_class=d["skill_class"],
            skill_slot=d["skill_slot"],
            skill_name=d["skill_name"],
            actor_id=d["actor_id"],
            state_version_before=d["state_version_before"],
            state_version_after=d["state_version_after"],
            failure_code=d.get("failure_code", "NONE"),
            target_id=d.get("target_id"),
            destination=d.get("destination"),
            path=d.get("path", []),
            mechanical_effects=d.get("mechanical_effects", {}),
            tie_break_trace=d.get("tie_break_trace", []),
            partial=d.get("partial"),
            detail=d.get("detail", ""),
        )


# Legacy alias (handoff vocabulary)
SkillFailure = SkillResult

__all__ = ["SkillFailure", "SkillResult"]
