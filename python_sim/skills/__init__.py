"""python_sim.skills — frozen E0-E6 deterministic skill executors (v0.1.0).

Implements the Notion freeze "MVP Deterministic Skill Executor Contracts —
Architecture-Only Freeze (30 Skills)" against the existing python_sim
primitives (Executor / Battle / movement / combat / FactionKnowledge).

Boundary (unchanged from the freeze):
  JEV policy  -> owns WHAT (one of six class-specific skill slots).
  Executor    -> owns HOW (geometry, targets, paths, occupancy, execution).
  Simulator   -> owns WHAT HAPPENS (authoritative rules resolution).

A selected skill that cannot execute returns an explicit failure envelope and
never silently substitutes another skill (invariant I8).

Skill-contract version pinning lives in python_sim.skills.contracts.
"""

from python_sim.skills.contracts import (
    FAILURE_CODE_VERSION,
    MODES_VERSION,
    RESULT_ENVELOPE_VERSION,
    SKILL_CONTRACT_VERSION,
    SKILLS_PACKAGE_VERSION,
    failure,
    success,
)
from python_sim.skills.context import (
    AnchorResolution,
    MissionContext,
    resolve_advance_anchor,
    resolve_recon_waypoint,
    resolve_regroup_anchor,
    resolve_reserve_anchor,
    resolve_withdraw_anchor,
)
from python_sim.skills.mask import observation_safe_skill_mask
from python_sim.skills.preflight import (
    LEGAL_MASK_V2_VERSION,
    SKILL_PREFLIGHT_VERSION,
    observation_safe_skill_mask_v2,
    skill_preflight,
)
from python_sim.skills.registry import execute_skill, get_executor, iter_skill_names
from python_sim.skills.result import SkillFailure, SkillResult

__all__ = [
    "AnchorResolution",
    "FAILURE_CODE_VERSION",
    "LEGAL_MASK_V2_VERSION",
    "MODES_VERSION",
    "MissionContext",
    "RESULT_ENVELOPE_VERSION",
    "SKILL_CONTRACT_VERSION",
    "SKILLS_PACKAGE_VERSION",
    "SKILL_PREFLIGHT_VERSION",
    "SkillFailure",
    "SkillResult",
    "execute_skill",
    "failure",
    "get_executor",
    "iter_skill_names",
    "observation_safe_skill_mask",
    "observation_safe_skill_mask_v2",
    "skill_preflight",
    "resolve_advance_anchor",
    "resolve_recon_waypoint",
    "resolve_regroup_anchor",
    "resolve_reserve_anchor",
    "resolve_withdraw_anchor",
    "success",
]
