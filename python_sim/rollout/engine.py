"""Counterfactual six-skill rollout engine (rollout-engine-v0.2.0).

One frozen decision state + one current actor:

    snapshot S0 (BranchStartOutcomeSnapshotV0, captured ONCE, shared by all six)
    clone S0 -> skill 0 -> continuation -> raw outcome G0 (+ T/M/O/E -> Q0)
    ...                                     ...
    clone S0 -> skill 5 -> continuation -> raw outcome G5 (+ T/M/O/E -> Q5)

- Every branch starts from an INDEPENDENT clone of the same frozen state
  (clone-isolation tests hash the six pre-execution clones) and shares the
  exact same branch-start baseline snapshot (V0-9: snapshot bytes equal).
- Illegal skills are MASKED (legal_mask / q_valid_mask) — never assigned
  fake tactical values; masked branches carry no Q (V0-17).
- Scalar Q is exported for full-information profiles under ValueTargetV0
  (value-target-v0.1.0); partial-information profiles keep v0.1.0 raw vectors
  with no Q (fog oracle guard).
- Determinism: same (state, actor, config) -> identical results.
"""

from __future__ import annotations

import copy
import hashlib
import json
from dataclasses import dataclass, field

from python_jev.constants import ACTION_SPACE
from python_sim import SIM_VERSION
from python_sim.skills import observation_safe_skill_mask
from python_sim.skills.context import MissionContext
from python_sim.skills.registry import execute_skill
from python_sim.rollout.branch_snapshot import capture_branch_start, snapshot_bytes
from python_sim.rollout.config import RolloutConfig
from python_sim.rollout.outcome import (
    OUTCOME_VECTOR_VERSION,
    OUTCOME_VECTOR_VERSION_V2,
    raw_outcome_vector,
    raw_outcome_vector_v2,
)
from python_sim.rollout.value_target import VALUE_TARGET_VERSION, q_export_status
from python_sim.sim.battle import Battle

ROLLOUT_ENGINE_VERSION = "rollout-engine-v0.2.0"


def state_hash(battle: Battle) -> str:
    """Deterministic digest of the authoritative state + knowledge ledgers."""
    payload = {
        "fingerprint": battle.fingerprint(),
        "blue_kn": {
            "visible": sorted(battle.blue_knowledge.visible.keys()),
            "stale": {k: v for k, v in sorted(battle.blue_knowledge.stale_contacts.items())},
        },
        "red_kn": {
            "visible": sorted(battle.red_knowledge.visible.keys()),
            "stale": {k: v for k, v in sorted(battle.red_knowledge.stale_contacts.items())},
        },
        "action_seq": battle._action_seq,
    }
    return hashlib.sha256(
        json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    ).hexdigest()


@dataclass
class BranchResult:
    skill_slot: int
    skill_name: str
    execution_status: str
    execution_result: dict
    initial_state_hash: str          # hash of the branch's clone BEFORE the skill
    post_skill_state_hash: str
    post_rollout_state_hash: str
    raw_outcome: dict
    outcome_scalar: float | None = None   # Q for legal full-info branches; None if masked/forbidden

    def to_dict(self) -> dict:
        return {
            "skill_slot": self.skill_slot,
            "skill_name": self.skill_name,
            "execution_status": self.execution_status,
            "execution_result": self.execution_result,
            "initial_state_hash": self.initial_state_hash,
            "post_skill_state_hash": self.post_skill_state_hash,
            "post_rollout_state_hash": self.post_rollout_state_hash,
            "raw_outcome": self.raw_outcome,
            "outcome_scalar": self.outcome_scalar,
        }


@dataclass
class SixWayEvaluation:
    profile: str
    scenario_id: str
    actor_id: str
    actor_class: str
    acting_faction: str
    decision_state_hash: str
    branch_start_snapshot: dict       # BranchStartOutcomeSnapshotV0, shared by all six branches
    legal_mask: list                  # observation-safe six-bit mask
    q_valid_mask: list                # legal AND Q-export-allowed (all-False under fog)
    branches: dict                    # slot -> BranchResult
    rollout_config: dict
    q_export_status: str
    value_target_version: str

    def to_dict(self) -> dict:
        return {
            "profile": self.profile,
            "scenario_id": self.scenario_id,
            "actor_id": self.actor_id,
            "actor_class": self.actor_class,
            "acting_faction": self.acting_faction,
            "decision_state_hash": self.decision_state_hash,
            "branch_start_snapshot": self.branch_start_snapshot,
            "legal_mask": self.legal_mask,
            "q_valid_mask": self.q_valid_mask,
            "branches": {str(k): v.to_dict() for k, v in self.branches.items()},
            "rollout_config": self.rollout_config,
            "q_export_status": self.q_export_status,
            "value_target_version": self.value_target_version,
        }


class CounterfactualEngine:
    """Evaluate one decision state across all six class-specific skills."""

    def __init__(self, config: RolloutConfig | None = None) -> None:
        self.config = config or RolloutConfig()

    @classmethod
    def from_name(cls, continuation_policy: str, horizon: int, seed: int) -> "CounterfactualEngine":
        return cls(RolloutConfig(continuation_policy=continuation_policy,
                                 horizon_decisions=int(horizon), seed=int(seed)))

    # ------------------------------------------------------------------
    def evaluate(
        self,
        battle: Battle,
        actor_id: str,
        ctx: MissionContext | None = None,
        mask_fn=None,
    ) -> SixWayEvaluation:
        # F0 hook (additive): mask_fn(battle, actor_id, ctx) overrides the
        # legality mask; None keeps the frozen v0.1.0 mask path bit-identical.
        ctx = ctx or MissionContext(scenario_id=str(battle.scenario.get("scenario_id", "")))
        cls_names = _class_table(battle, actor_id)
        if cls_names is None:
            raise ValueError(f"actor {actor_id!r} is not a learned five-class actor")
        profile = battle.profile_name
        acting_faction = _faction_of(battle, actor_id)
        if mask_fn is None:
            legal = observation_safe_skill_mask(battle, actor_id)
        else:
            legal = [bool(x) for x in mask_fn(battle, actor_id, ctx)]
        export_ok = q_export_status(profile) == "OK"
        q_valid = [bool(v) and export_ok for v in legal]
        base_hash = state_hash(battle)
        # Branch-start baseline: captured ONCE from the frozen decision state
        # and shared byte-identically by all six branches (V0-9).
        snapshot = capture_branch_start(battle, acting_faction)
        branches: dict[int, BranchResult] = {}

        for slot in range(6):
            branch_battle = battle.clone()  # fresh equivalent frozen state
            pre_hash = state_hash(branch_battle)
            if not legal[slot]:
                branches[slot] = BranchResult(
                    skill_slot=slot, skill_name=cls_names[slot],
                    execution_status="MASKED",
                    execution_result={"status": "MASKED", "skill_slot": slot,
                                      "skill_name": cls_names[slot],
                                      "failure_code": "MASKED_ILLEGAL",
                                      "actor_id": actor_id},
                    initial_state_hash=pre_hash,
                    post_skill_state_hash=pre_hash,
                    post_rollout_state_hash=pre_hash,
                    raw_outcome=_empty_outcome(),
                )
                continue
            env = execute_skill(branch_battle, actor_id, _class_name(battle, actor_id), slot, ctx)
            post_skill_hash = state_hash(branch_battle)
            outcome = _run_continuation(branch_battle, actor_id, self.config,
                                        snapshot, acting_faction, export_ok)
            branches[slot] = BranchResult(
                skill_slot=slot, skill_name=cls_names[slot],
                execution_status=env.get("status", "INVALID"),
                execution_result=env,
                initial_state_hash=pre_hash,
                post_skill_state_hash=post_skill_hash,
                post_rollout_state_hash=state_hash(branch_battle),
                raw_outcome=outcome,
                outcome_scalar=(float(outcome["scalar_Q"]) if export_ok else None),
            )

        return SixWayEvaluation(
            profile=profile,
            scenario_id=str(battle.scenario.get("scenario_id", "")),
            actor_id=actor_id,
            actor_class=_class_name(battle, actor_id),
            acting_faction=acting_faction,
            decision_state_hash=base_hash,
            branch_start_snapshot=snapshot,
            legal_mask=legal,
            q_valid_mask=q_valid,
            branches=branches,
            rollout_config=self.config.to_dict(),
            q_export_status=q_export_status(profile),
            value_target_version=VALUE_TARGET_VERSION,
        )


# ----------------------------------------------------------------------
def _faction_of(battle: Battle, actor_id: str) -> str:
    u = battle.world.units.get(actor_id)
    faction = str(u.faction).lower() if u is not None else "blue"
    if faction not in ("blue", "red"):
        raise ValueError(f"actor {actor_id!r} has unknown faction {faction!r}")
    return faction


def _class_name(battle: Battle, actor_id: str) -> str:
    m = {"infantry": "INFANTRY", "spearman": "SPEARMAN", "spear": "SPEARMAN",
         "cavalry": "CAVALRY", "archer": "ARCHER", "archers": "ARCHER",
         "scout": "SCOUT", "scouts": "SCOUT"}
    return m[str(battle.world.unit_dict(actor_id).get("class", "")).lower()]


def _class_table(battle: Battle, actor_id: str):
    cls = _class_name(battle, actor_id)
    return ACTION_SPACE.get(cls)


def _empty_outcome() -> dict:
    return {
        "enemy_casualties": 0, "friendly_casualties": 0, "objective_delta": 0,
        "mission_delta": 0, "own_hq_alive": 0, "enemy_hq_alive": 0,
        "own_strength_ratio": 0.0, "enemy_visible_strength_ratio": 0.0,
        "terminal_result": "MASKED", "horizon_steps": 0,
    }


def _run_continuation(battle: Battle, actor_id: str, config: RolloutConfig,
                      snapshot: dict, acting_faction: str, export_ok: bool) -> dict:
    """Bounded multi-step continuation: after the branch skill, drive BOTH
    factions with the frozen scripted policies for horizon_decisions tactical
    decisions (blue and red each count), ending early on terminal state."""
    blue_policy = config.make_blue_policy()
    red_policy = config.make_red_policy()
    steps = 0
    turn_guard = 0
    while steps < config.horizon_decisions and turn_guard < config.max_turns:
        turn_guard += 1
        # BLUE phase: every unresolved unit acts once (deterministic order).
        for uid in sorted(u.id for u in list(battle.world.units.values())
                          if u.faction == "blue"):
            if uid in battle.world.units:
                blue_policy.blue_action(battle, uid)
                steps += 1
                if steps >= config.horizon_decisions:
                    break
        if steps >= config.horizon_decisions:
            break
        m = battle.evaluate_mission()
        if m["mission_status"] != "ongoing":
            break
        # RED phase
        for uid in sorted(u.id for u in list(battle.world.units.values())
                          if u.faction == "red"):
            if uid in battle.world.units:
                red_policy.red_action(battle, uid)
                steps += 1
                if steps >= config.horizon_decisions:
                    break
        if steps >= config.horizon_decisions:
            break
        if battle.evaluate_mission()["mission_status"] != "ongoing":
            break
        battle.sim_end_turn()
    if export_ok:
        # Full-information ValueTargetV0 derivation (raw v0.2.0, T/M/O/E + Q).
        return raw_outcome_vector_v2(battle, steps, snapshot, acting_faction)
    # Partial-information profiles: v0.1.0 raw vector only, never Q (fog guard).
    outcome = raw_outcome_vector(battle, steps)
    return outcome


__all__ = [
    "ROLLOUT_ENGINE_VERSION",
    "BranchResult",
    "CounterfactualEngine",
    "SixWayEvaluation",
    "state_hash",
]
