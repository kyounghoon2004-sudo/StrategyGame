"""Skill registry — (class, slot/name) -> executor dispatch (invariant I1).

The registry echoes the selected identity UNCHANGED (slot + name + class),
executes exactly the selected skill, and never falls back to another skill
(invariant I8). All 30 (class, slot) pairs are pinned to their frozen names
via python_jev.constants.ACTION_SPACE (single authority for the tables).
"""

from __future__ import annotations

from python_jev.constants import ACTION_SPACE
from python_sim.skills.contracts import FailureCode, failure, success  # noqa: F401
from python_sim.skills.context import MissionContext
from python_sim.skills.infantry import EXECUTORS as INFANTRY_EXEC
from python_sim.skills.spearman import EXECUTORS as SPEARMAN_EXEC
from python_sim.skills.cavalry import EXECUTORS as CAVALRY_EXEC
from python_sim.skills.archer import EXECUTORS as ARCHER_EXEC
from python_sim.skills.scout import EXECUTORS as SCOUT_EXEC
from python_sim.sim.battle import Battle

EXECUTOR_TABLE: dict[str, tuple] = {
    "INFANTRY": (INFANTRY_EXEC, "INFANTRY"),
    "SPEARMAN": (SPEARMAN_EXEC, "SPEARMAN"),
    "CAVALRY": (CAVALRY_EXEC, "CAVALRY"),
    "ARCHER": (ARCHER_EXEC, "ARCHER"),
    "SCOUT": (SCOUT_EXEC, "SCOUT"),
}

_REG_CLASS_MAP = {
    "infantry": "INFANTRY", "spearman": "SPEARMAN", "spear": "SPEARMAN",
    "cavalry": "CAVALRY", "archer": "ARCHER", "archers": "ARCHER",
    "scout": "SCOUT", "scouts": "SCOUT",
}


def iter_skill_names() -> list[tuple[str, int, str]]:
    """All 30 (class, slot, name) triples in frozen table order."""
    out = []
    for cls, skills in ACTION_SPACE.items():
        for slot, name in enumerate(skills):
            out.append((cls, slot, name))
    return out


def get_executor(skill_class: str, slot: int):
    names = ACTION_SPACE.get(skill_class)
    if names is None or not 0 <= slot < len(names):
        raise KeyError(f"unknown skill identity ({skill_class!r}, slot {slot})")
    module, _ = EXECUTOR_TABLE[skill_class]
    return module, names[slot]


def execute_skill(
    battle: Battle,
    actor_id: str,
    skill_class: str,
    skill_slot: int,
    ctx: MissionContext | None = None,
) -> dict:
    """Execute one selected skill for one actor; returns the canonical
    envelope. Identity is echoed unchanged; failures are explicit."""
    ctx = ctx or MissionContext()
    u = battle.world.unit_dict(actor_id)
    if not u:
        return failure(
            skill_class=skill_class, skill_slot=skill_slot,
            skill_name=f"slot{skill_slot}", actor_id=actor_id,
            state_version_before=battle.world.state_version,
            code=FailureCode.NO_ACTOR, detail=f"actor {actor_id!r} not found")
    reg_cls = _REG_CLASS_MAP.get(str(u.get("class", "")).lower())
    if reg_cls != skill_class:
        return failure(
            skill_class=skill_class, skill_slot=skill_slot,
            skill_name=f"slot{skill_slot}", actor_id=actor_id,
            state_version_before=battle.world.state_version,
            code=FailureCode.PRECONDITION_FAILED,
            detail=f"actor class {u.get('class')!r} does not match selected skill class {skill_class!r}")
    module, name = get_executor(skill_class, skill_slot)
    state_version_before = battle.world.state_version
    fn = module[name]
    envelope = fn(battle, u, ctx, state_version_before)
    # I1: identity echo guard — the envelope must never re-write the identity.
    envelope["skill_class"] = skill_class
    envelope["skill_slot"] = int(skill_slot)
    envelope["skill_name"] = name
    envelope["actor_id"] = actor_id
    return envelope


__all__ = ["EXECUTOR_TABLE", "execute_skill", "get_executor", "iter_skill_names"]
