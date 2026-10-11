"""TerminalOutcomeV0 — frozen terminal-outcome semantics (terminal-outcome-v0.1.0).

Authoritative source: SimController.evaluate_mission (scripts/sim/sim_controller.gd)
as ported by python_sim.rules.turn.evaluate_mission / Battle.evaluate_mission.

Frozen semantics:
- T = +1 only when the authoritative mission/battle evaluator declares terminal
  victory for the ACTING faction.
- T = -1 only when it declares terminal defeat for the ACTING faction.
- T = 0 for every non-terminal state, INCLUDING "expired" when expiration is a
  distinct terminal/no-verdict state (which is exactly what the authoritative
  evaluator emits: "expired" is assigned only when status stayed "ongoing" past
  turn_limit, i.e. it is neither victory nor defeat).

The authoritative evaluator is BLUE-centric (blue mission contract, blue HQ,
blue annihilation). Faction relativity is therefore an explicit perspective
projection performed HERE, not in the evaluator:
- physical "victory"  = terminal success of the BLUE mission  -> T=+1 for blue, -1 for red
- physical "defeat"   = terminal failure of the BLUE mission  -> T=-1 for blue, +1 for red
- physical "expired"  = distinct no-verdict terminal          -> T=0 for both sides
- physical "ongoing"  = non-terminal                          -> T=0 for both sides

EXPIRED carries no invented penalty. The expiry fact is recorded separately as
(expired: bool, terminal_reason, terminal_verdict) for auditability.

Design constraints honoured:
- faction-relative (acting-side projection), bounded (T in {-1,0,+1}),
  deterministic (pure function of evaluator output + faction), auditable
  (verdict passthrough), no subjective heuristics.
"""

from __future__ import annotations

import hashlib
import json

TERMINAL_OUTCOME_VERSION = "terminal-outcome-v0.1.0"

# Canonical spec string hashed by content_hash(). Any semantic change requires
# a version bump; the hash pins the frozen wording.
_TERMINAL_SPEC_CANONICAL = json.dumps(
    {
        "version": TERMINAL_OUTCOME_VERSION,
        "victory": "T=+1 acting faction iff authoritative verdict is victory for acting faction",
        "defeat": "T=-1 acting faction iff authoritative verdict is defeat for acting faction",
        "expired": "distinct no-verdict terminal -> T=0 both sides, expired=True, no invented penalty",
        "ongoing": "T=0",
        "projection": "evaluator is blue-centric; red perspective inverts victory/defeat",
    },
    sort_keys=True,
    separators=(",", ":"),
    ensure_ascii=True,
)


def content_hash() -> str:
    """Stable content hash of the frozen terminal-outcome contract."""
    return hashlib.sha256(_TERMINAL_SPEC_CANONICAL.encode("utf-8")).hexdigest()


VALID_FACTIONS = ("blue", "red")


def terminal_outcome(mission_status: str, acting_faction: str) -> int:
    """Project the authoritative verdict onto the acting faction.

    Args:
        mission_status: authoritative verdict string ("victory" | "defeat" |
            "expired" | "ongoing"). Unknown verdicts are treated as
            non-terminal (T=0) — never invented as victory/defeat.
        acting_faction: "blue" | "red".

    Returns:
        +1 / -1 / 0 per the frozen contract.
    """
    faction = str(acting_faction).lower()
    if faction not in VALID_FACTIONS:
        raise ValueError(f"acting_faction must be one of {VALID_FACTIONS}, got {acting_faction!r}")
    status = str(mission_status)
    if status == "victory":
        return +1 if faction == "blue" else -1
    if status == "defeat":
        return -1 if faction == "blue" else +1
    # "expired", "ongoing", and any unknown verdict: non-scored terminal state.
    return 0


def is_expired(mission_status: str) -> bool:
    """Authoritative expiry flag (no verdict reinterpretation)."""
    return str(mission_status) == "expired"


def describe_terminal(mission_status: str, termination_reason: str, acting_faction: str) -> dict:
    """Auditable terminal record: scalar T plus separately-recorded metadata."""
    status = str(mission_status)
    return {
        "contract_version": TERMINAL_OUTCOME_VERSION,
        "contract_hash": content_hash()[:16],
        "acting_faction": str(acting_faction).lower(),
        "terminal_verdict": status,
        "terminal_reason": str(termination_reason),
        "expired": is_expired(status),
        "T": terminal_outcome(status, acting_faction),
    }


__all__ = [
    "TERMINAL_OUTCOME_VERSION",
    "VALID_FACTIONS",
    "content_hash",
    "describe_terminal",
    "is_expired",
    "terminal_outcome",
]
