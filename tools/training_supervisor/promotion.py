"""Promotion interface — the supervisor consumes decisions, it does not make them.

The eventual eval strategy-quality threshold is UNWIRED. This module only
fixes the shape of the evaluator result the supervisor accepts:

    {
      "decision": "PROMOTE" | "REJECT" | "INCONCLUSIVE",
      "candidate_id": "...",
      "champion_id": "...",
      "evaluation_id": "...",
      "metrics": {},
      "reason": "..."
    }

``DecisionParser`` validates shape only. Tactical heuristics (score
thresholds, win-rate comparisons, etc.) live in the future EVAL phase
implementation, never in the supervisor.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Dict, Optional

PROMOTE = "PROMOTE"
REJECT = "REJECT"
INCONCLUSIVE = "INCONCLUSIVE"

DECISIONS = (PROMOTE, REJECT, INCONCLUSIVE)


class DecisionError(ValueError):
    """Raised when an evaluator result does not conform to the contract."""


@dataclass
class EvalDecision:
    decision: str
    candidate_id: str
    champion_id: Optional[str]
    evaluation_id: str
    metrics: Dict[str, Any] = field(default_factory=dict)
    reason: str = ""

    def to_dict(self) -> Dict[str, Any]:
        return {
            "decision": self.decision,
            "candidate_id": self.candidate_id,
            "champion_id": self.champion_id,
            "evaluation_id": self.evaluation_id,
            "metrics": dict(self.metrics),
            "reason": self.reason,
        }


class DecisionParser:
    """Strict shape validation of evaluator results (no heuristics)."""

    REQUIRED_KEYS = ("decision", "candidate_id", "evaluation_id")

    @classmethod
    def parse(cls, raw: Any) -> EvalDecision:
        if not isinstance(raw, dict):
            raise DecisionError("evaluator result must be a JSON object")
        for key in cls.REQUIRED_KEYS:
            if key not in raw:
                raise DecisionError(f"evaluator result missing key: {key!r}")
        decision = raw["decision"]
        if decision not in DECISIONS:
            raise DecisionError(
                f"decision must be one of {DECISIONS}; got {decision!r}")
        candidate_id = raw["candidate_id"]
        if not candidate_id or not isinstance(candidate_id, str):
            raise DecisionError("candidate_id must be a non-empty string")
        evaluation_id = raw["evaluation_id"]
        if not evaluation_id or not isinstance(evaluation_id, str):
            raise DecisionError("evaluation_id must be a non-empty string")
        champion_id = raw.get("champion_id")
        if champion_id is not None and not isinstance(champion_id, str):
            raise DecisionError("champion_id must be a string or null")
        metrics = raw.get("metrics")
        if metrics is not None and not isinstance(metrics, dict):
            raise DecisionError("metrics must be an object")
        reason = raw.get("reason", "")
        if not isinstance(reason, str):
            raise DecisionError("reason must be a string")
        return EvalDecision(
            decision=decision,
            candidate_id=candidate_id,
            champion_id=champion_id,
            evaluation_id=evaluation_id,
            metrics=dict(metrics or {}),
            reason=reason,
        )
