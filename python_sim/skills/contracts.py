"""Skill-layer contracts: versioning, failure vocabulary, canonical modes.

Authority chain:
  1. Notion freeze "MVP Deterministic Skill Executor Contracts" (30 skills),
     shared invariants I1-I14, canonical result envelope, per-skill
     resolution + tie-break chains. Fetched 2026-09-19 (unchanged).
  2. RulesetV0 SKILL_DEPENDENCIES (python_jev/contracts/ruleset.py) — the
     declared primitives each skill consumes.
  3. Live python_sim primitives (Executor / Battle) as the authoritative
     resolution layer (Notion I5 "legality at the point of execution").

Every deterministic mode choice the Notion freeze leaves open (SUPPORT
positional-vs-effect, FLANK band ranking, SHADOW band width, HARASS bound,
RESERVE/REGROUP envelope radius, threat-priority source) is pinned here in
one versioned table — never invented ad hoc inside an executor. Changing an
entry is a skill-contract version bump, never a silent change.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from enum import Enum

SKILL_CONTRACT_VERSION = "skill-contract-e0e6-v0.1.1"  # v0.1.1: exact Notion tie-break chain
SKILLS_PACKAGE_VERSION = "python_sim_skills_v0.1.0"
RESULT_ENVELOPE_VERSION = "skill-result-envelope-v0.1.0"
FAILURE_CODE_VERSION = "failure-codes-v0.1.0"
MODES_VERSION = "skill-modes-v0.1.0"


class FailureCode(str, Enum):
    """Versioned mechanical reason vocabulary (E0-E6 + canonical envelope).

    The Notion envelope names the families; this enum pins their machine
    spellings. NO_TARGET-style codes are prefixed by the failing predicate
    family so a failure is attributable without natural language.
    """

    NONE = "NONE"
    # actor / phase state
    PRECONDITION_FAILED = "PRECONDITION_FAILED"
    STALE_STATE = "STALE_STATE"
    ENGINE_REJECTED = "ENGINE_REJECTED"
    NO_ACTOR = "NO_ACTOR"
    NO_LINE_OF_SIGHT = "NO_LINE_OF_SIGHT"
    OUT_OF_RANGE = "OUT_OF_RANGE"
    NO_TARGET = "NO_TARGET"
    TARGET_NOT_ELIGIBLE = "TARGET_NOT_ELIGIBLE"
    NO_FLANK_TARGET = "NO_FLANK_TARGET"
    NO_PURSUIT_TARGET = "NO_PURSUIT_TARGET"
    NO_SHADOW_TARGET = "NO_SHADOW_TARGET"
    NO_FOCUS_TARGET = "NO_FOCUS_TARGET"
    NO_KITE_THREAT = "NO_KITE_THREAT"
    NO_EVADE_THREAT = "NO_EVADE_THREAT"
    NO_RANGE_TARGET = "NO_RANGE_TARGET"
    NO_SUPPORT_TARGET = "NO_SUPPORT_TARGET"
    # anchors / destinations (movement families)
    NO_ANCHOR = "NO_ANCHOR"
    NO_DESTINATION = "NO_DESTINATION"
    NO_PATH = "NO_PATH"
    BLOCKED = "BLOCKED"
    NO_FLANK_DESTINATION = "NO_FLANK_DESTINATION"
    NO_PURSUIT_ROUTE = "NO_PURSUIT_ROUTE"
    NO_WITHDRAW_ROUTE = "NO_WITHDRAW_ROUTE"
    NO_RESERVE_ANCHOR = "NO_RESERVE_ANCHOR"
    NO_SUPPORT_DESTINATION = "NO_SUPPORT_DESTINATION"
    NO_SCREEN_ANCHOR = "NO_SCREEN_ANCHOR"
    NO_SCREEN_DESTINATION = "NO_SCREEN_DESTINATION"
    NO_RANGE_ANCHOR = "NO_RANGE_ANCHOR"
    NO_RECON_ANCHOR = "NO_RECON_ANCHOR"
    NO_RECON_DESTINATION = "NO_RECON_DESTINATION"
    NO_SHADOW_DESTINATION = "NO_SHADOW_DESTINATION"
    NO_REGROUP_ANCHOR = "NO_REGROUP_ANCHOR"
    NO_SAFE_ROUTE = "NO_SAFE_ROUTE"


@dataclass(frozen=True)
class CanonicalModes:
    """Pinned mechanical modes for skills whose Notion contract defers the
    exact mode to the engine ("the canonical engine must choose one reviewed
    mode before implementation", invariant I14)."""

    # Infantry.SUPPORT: positional support is the canonical MVP mode — the
    # skill is realized as movement into a support position; no effect is
    # fired (no support-effect rule exists in RulesetV0).
    SUPPORT_MODE = "POSITIONAL"
    SUPPORT_DESIRED_DISTANCE = 1        # adjacent to the recipient
    SUPPORT_FALLBACK_DISTANCE = 2

    # Cavalry.FLANK: movement-only (Notion). Rear band ranks before side
    # band; both bands are width-2 axial rings around the target.
    FLANK_REAR_BAND = 2                 # hex distance ring behind the target
    FLANK_SIDE_BAND = 2                 # hex distance ring beside the target
    FLANK_BAND_ORDER = ("REAR", "SIDE")

    # Cavalry.PURSUE: movement-only (Notion). Eligible target = the exact
    # enemy that just WITHDREW from the actor's authorized view (contact
    # stop) or an adjacent visible enemy (fleeing engagement).
    PURSUE_ELIGIBILITY = "JUST_WITHDREW_OR_ADJACENT"

    # Cavalry.RESERVE: envelope = disc of radius R around the reserve anchor.
    RESERVE_ENVELOPE_RADIUS = 3

    # Archer.FOCUS_FIRE: no focus-marker ledger exists in RulesetV0; the
    # canonical stand-in is the NEAREST authorized visible enemy (lowest
    # stable id on tie), resolved once and locked for the invocation.
    FOCUS_TARGET_SOURCE = "NEAREST_VISIBLE_STABLE_ID"

    # Archer.KITE: preserve the ranged relationship at distance >= min band
    # (range - 1), maximizing separation from the threat within budget.
    KITE_MIN_RANGE_BAND = 2

    # Archer.REPOSITION_RANGE: valid fire positions are dist 2..range with
    # authorized LOS; prefer minimal |dist - ideal| where ideal = range - 1.
    REPOSITION_RANGE_IDEAL_OFFSET = 1   # ideal = attack_range - 1

    # Scout.SHADOW: band = (vision_radius, vision_radius + 2) around the
    # target — inside it the scout's own vision keeps the target visible.
    SHADOW_BAND_INNER = "VISION"        # replaced per-actor (vision radius)
    SHADOW_BAND_WIDTH = 2

    # Scout.HARASS: bounded harassment = one canonical attack limited to the
    # scout's min-1 casualty clamp (no attack-action lock consumed).
    HARASS_EFFECT = "SINGLE_CANONICAL_ATTACK_NO_LOCK"
    HARASS_MAX_RANGE = 1                # melee-only bounded effect

    # Scout.EVADE: threat priority comes from the mission context when
    # declared, else nearest authorized threat; separation in hex distance.
    EVADE_THREAT_PRIORITY = "MISSION_DECLARED_ELSE_NEAREST"

    # Spearman/Scout.SCREEN: corridor midpoint = anchor + threat vector
    # (vector from anchor to nearest authorized visible threat); standoff
    # = the corridor radius from the anchor.
    SCREEN_CORRIDOR_STANDOFF = 2

    # Movement skills: full-budget committed march (GREEN tier within the
    # remaining blue budget where possible — march order GREEN > ORANGE >
    # RED > BLACK).
    DESTINATION_TIER_PREFERENCE = ("GREEN", "ORANGE", "RED", "BLACK")


def content_hash() -> str:
    """Deterministic hash of the pinned modes table (versioned config)."""
    payload = {
        "skill_contract_version": SKILL_CONTRACT_VERSION,
        "result_envelope_version": RESULT_ENVELOPE_VERSION,
        "failure_code_version": FAILURE_CODE_VERSION,
        "modes_version": MODES_VERSION,
        "modes": {k: getattr(CanonicalModes, k) for k in dir(CanonicalModes)
                  if k.isupper() and not k.startswith("_")},
    }
    return hashlib.sha256(
        json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    ).hexdigest()


def success(
    *,
    skill_class: str,
    skill_slot: int,
    skill_name: str,
    actor_id: str,
    state_version_before: int,
    state_version_after: int,
    effects: dict | None = None,
    target_id: str | None = None,
    destination: tuple[int, int] | None = None,
    path: list[tuple[int, int]] | None = None,
    tie_break_trace: list[str] | None = None,
    partial: dict | None = None,
) -> dict:
    """Canonical result envelope (Notion) — SUCCESS / PARTIAL."""
    status = "PARTIAL" if partial is not None else "SUCCESS"
    return {
        "status": status,
        "skill_class": skill_class,
        "skill_slot": int(skill_slot),
        "skill_name": skill_name,
        "actor_id": actor_id,
        "state_version_before": int(state_version_before),
        "state_version_after": int(state_version_after),
        "target_id": target_id,
        "destination": list(destination) if destination is not None else None,
        "path": [list(h) for h in (path or [])],
        "mechanical_effects": effects or {},
        "tie_break_trace": list(tie_break_trace or []),
        "partial": partial,
        "failure_code": FailureCode.NONE.value,
    }


def failure(
    *,
    skill_class: str,
    skill_slot: int,
    skill_name: str,
    actor_id: str,
    state_version_before: int,
    code: FailureCode,
    detail: str = "",
    tie_break_trace: list[str] | None = None,
) -> dict:
    """Canonical result envelope — INVALID (failure commits no mutation)."""
    return {
        "status": "INVALID",
        "skill_class": skill_class,
        "skill_slot": int(skill_slot),
        "skill_name": skill_name,
        "actor_id": actor_id,
        "state_version_before": int(state_version_before),
        "state_version_after": int(state_version_before),  # unchanged: no mutation
        "target_id": None,
        "destination": None,
        "path": [],
        "mechanical_effects": {},
        "tie_break_trace": list(tie_break_trace or []),
        "partial": None,
        "failure_code": code.value if isinstance(code, FailureCode) else str(code),
        "detail": detail,
    }


__all__ = [
    "CanonicalModes",
    "FAILURE_CODE_VERSION",
    "FailureCode",
    "MODES_VERSION",
    "RESULT_ENVELOPE_VERSION",
    "SKILLS_PACKAGE_VERSION",
    "SKILL_CONTRACT_VERSION",
    "content_hash",
    "failure",
    "success",
]
