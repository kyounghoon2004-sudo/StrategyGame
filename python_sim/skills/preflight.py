"""SkillPreflightV0 — mechanical executability predicate (skill-preflight-v0.1.0).

The preflight question is ONLY: "does at least one deterministic mechanical
realization of this exact skill exist using information this faction is
authorized to know?" It NEVER asks whether the skill is tactically good.

Implementation: a thin dispatch over the shared resolvers in
python_sim.skills.candidates (the same functions the 30 executors call),
plus the structural guards below. Preflight contains zero tactical logic —
no foe-menace weighting, no pairing evaluation, no strength preference,
no value estimates. (Behavioral proof: scaling every soldier count, which
changes every pairing but no mechanical predicate, leaves all 30xN bits identical;
see test_f0_preflight.)

Fog rule: preflight consumes FactionKnowledge only. A hidden enemy blocking
a committed route yields preflight TRUE followed by executor PARTIAL /
HIDDEN_CONTACT — that is correct behavior, not a mask bug.

Full-information invariant: with no intervening state mutation, preflight
TRUE implies the executor does not return INVALID (test-enforced over the
Part A audit corpus).
"""

from __future__ import annotations

from dataclasses import dataclass

from python_jev.constants import ACTION_SPACE
from python_sim.sim.battle import Battle
from python_sim.skills import candidates as cand
from python_sim.skills.common import _CLASS_TO_LEARNED
from python_sim.skills.context import MissionContext
from python_sim.skills.contracts import FailureCode

SKILL_PREFLIGHT_VERSION = "skill-preflight-v0.1.0"
LEGAL_MASK_V2_VERSION = "observation-safe-skill-mask-v0.2.0"


@dataclass(frozen=True)
class PreflightResult:
    executable: bool
    reason_code: str  # FailureCode value (NONE when executable)
    candidate_count: int
    detail: str = ""
    sub: str = ""  # machine-readable fail point ("" when executable)


# (class, slot) -> shared resolver. 30/30 identities pinned to
# python_jev.constants.ACTION_SPACE (single authority for the tables).
def _attack(battle, actor, ctx):
    return cand.resolve_attack_target(battle, actor, ctx)


def _fire(battle, actor, ctx):
    return cand.resolve_attack_target(battle, actor, ctx, out_of_range_style=True)


_RESOLVERS = {
    ("INFANTRY", 0): (_attack, "ATTACK"),
    ("INFANTRY", 1): (cand.resolve_advance, "ADVANCE"),
    ("INFANTRY", 2): (cand.resolve_hold, "HOLD"),
    ("INFANTRY", 3): (cand.resolve_reposition, "REPOSITION"),
    ("INFANTRY", 4): (cand.resolve_support, "SUPPORT"),
    ("INFANTRY", 5): (cand.resolve_withdraw, "WITHDRAW"),
    ("SPEARMAN", 0): (_attack, "ATTACK"),
    ("SPEARMAN", 1): (cand.resolve_advance, "ADVANCE"),
    ("SPEARMAN", 2): (cand.resolve_hold, "HOLD"),
    ("SPEARMAN", 3): (cand.resolve_reposition, "REPOSITION"),
    ("SPEARMAN", 4): (cand.resolve_screen, "SCREEN"),
    ("SPEARMAN", 5): (cand.resolve_withdraw, "WITHDRAW"),
    ("CAVALRY", 0): (_attack, "ATTACK"),
    ("CAVALRY", 1): (cand.resolve_flank, "FLANK"),
    ("CAVALRY", 2): (cand.resolve_advance, "ADVANCE"),
    ("CAVALRY", 3): (cand.resolve_pursue, "PURSUE"),
    ("CAVALRY", 4): (cand.resolve_reserve, "RESERVE"),
    ("CAVALRY", 5): (cand.resolve_withdraw, "WITHDRAW"),
    ("ARCHER", 0): (_fire, "FIRE"),
    ("ARCHER", 1): (cand.resolve_focus_target, "FOCUS_FIRE"),
    ("ARCHER", 2): (cand.resolve_reposition_range, "REPOSITION_RANGE"),
    ("ARCHER", 3): (cand.resolve_kite, "KITE"),
    ("ARCHER", 4): (cand.resolve_hold, "HOLD_POSITION"),
    ("ARCHER", 5): (cand.resolve_withdraw, "WITHDRAW"),
    ("SCOUT", 0): (cand.resolve_recon_advance, "RECON_ADVANCE"),
    ("SCOUT", 1): (cand.resolve_shadow, "SHADOW"),
    ("SCOUT", 2): (_fire, "HARASS"),
    ("SCOUT", 3): (cand.resolve_screen, "SCREEN"),
    ("SCOUT", 4): (cand.resolve_evade, "EVADE"),
    ("SCOUT", 5): (cand.resolve_regroup, "REGROUP"),
}

assert len(_RESOLVERS) == 30
for (_cls, _slot), (_fn, _name) in _RESOLVERS.items():
    assert ACTION_SPACE[_cls][_slot] == _name, (_cls, _slot, _name)


def skill_preflight(battle: Battle, actor_id: str, ctx: MissionContext,
                    skill_class: str, skill_slot: int) -> PreflightResult:
    """Mechanical executability of one (class, slot) identity.

    Faction-authorized inputs only: the actor record, the acting side's
    FactionKnowledge (inside the resolvers), and the declared MissionContext.
    Pure: never mutates the battle.
    """
    key = (skill_class, int(skill_slot))
    entry = _RESOLVERS.get(key)
    if entry is None:
        return PreflightResult(False, FailureCode.PRECONDITION_FAILED.value, 0,
                               f"unknown skill identity {key!r}")
    u = battle.world.unit_dict(actor_id)
    if not u or u.get("soldier_count", 0) <= 0:
        return PreflightResult(False, FailureCode.NO_ACTOR.value, 0,
                               "actor missing or destroyed")
    # Structural guards (shared with mask v0.1.0 semantics): non-learned
    # actors and already-resolved actors have no executable Jev skill.
    if _CLASS_TO_LEARNED.get(str(u.get("class", "")).lower()) != skill_class:
        return PreflightResult(False, FailureCode.PRECONDITION_FAILED.value, 0,
                               "actor class does not match the skill identity")
    if u.get("action_ended", False):
        return PreflightResult(False, FailureCode.PRECONDITION_FAILED.value, 0,
                               "actor already resolved this turn")
    resolve, _name = entry
    res = resolve(battle, dict(u), ctx)
    return PreflightResult(bool(res.ok), str(res.reason), int(res.count),
                           res.detail, res.sub)


def observation_safe_skill_mask_v2(battle: Battle, actor_id: str,
                                   ctx: MissionContext | None = None) -> list[bool]:
    """Six-bit mechanical-executability mask (mask v0.2.0).

    Bit meaning: "mechanically executable according to authorized knowledge"
    — never "tactically recommended". Fixed six slots; class not learned,
    missing, destroyed, or already resolved -> all False.
    """
    from python_sim.skills.common import _CLASS_TO_LEARNED as _M

    ctx = ctx if ctx is not None else MissionContext()
    u = battle.world.unit_dict(actor_id)
    if not u or u.get("soldier_count", 0) <= 0:
        return [False] * 6
    cls = _M.get(str(u.get("class", "")).lower())
    if cls is None:
        return [False] * 6
    return [skill_preflight(battle, actor_id, ctx, cls, slot).executable
            for slot in range(6)]


def preflight_content_hash() -> str:
    """Deterministic hash of the preflight dispatch table (audit pin)."""
    import hashlib
    import json

    payload = {
        "preflight_version": SKILL_PREFLIGHT_VERSION,
        "mask_v2_version": LEGAL_MASK_V2_VERSION,
        "candidates_version": cand.CANDIDATES_VERSION,
        "dispatch": {f"{c}:{s}": n for (c, s), (_f, n) in sorted(_RESOLVERS.items())},
    }
    return hashlib.sha256(
        json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()


__all__ = [
    "LEGAL_MASK_V2_VERSION",
    "SKILL_PREFLIGHT_VERSION",
    "PreflightResult",
    "observation_safe_skill_mask_v2",
    "preflight_content_hash",
    "skill_preflight",
]
