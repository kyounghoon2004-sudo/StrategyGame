"""Trajectory recorder + replay determinism.

Recording contract (task Part B): initial state hash, decision index, actor,
observation hash, selected skill, execution result, post-state hash, mission
state, terminal state. Replay re-executes the recorded skill sequence from a
fresh battle built from the same scenario/profile and must reach the same
final state hash (J1-17).
"""

from __future__ import annotations

import hashlib
import json

from python_sim import SIM_VERSION
from python_sim.skills import observation_safe_skill_mask
from python_sim.skills.context import MissionContext
from python_sim.skills.registry import execute_skill
from python_sim.rollout.engine import state_hash
from python_sim.sim.battle import Battle

TRAJECTORY_FORMAT_VERSION = "trajectory-v0.1.0"


class TrajectoryRecorder:
    """Record one decision per actor step (skill-driven episodes)."""

    def __init__(self, battle: Battle, ctx: MissionContext | None = None) -> None:
        self.battle = battle
        self.ctx = ctx or MissionContext(
            scenario_id=str(battle.scenario.get("scenario_id", "")))
        self.initial_state_hash = state_hash(battle)
        self.records: list[dict] = []
        self.terminal_state: dict | None = None

    # ------------------------------------------------------------------
    def record_decision(self, actor_id: str, skill_class: str, skill_slot: int) -> dict:
        """Execute the selected skill authoritatively and record the step."""
        from python_sim.observation.projector import ObservationProjector

        obs_hash = ""
        try:
            proj = ObservationProjector(self.battle)
            side = str(self.battle.world.unit_dict(actor_id).get("faction", "blue"))
            o = proj.project(side, actor_id)
            obs_hash = hashlib.sha256(json.dumps(
                [o.actor_features, o.tokens, o.hex_patch, o.mission_features,
                 o.global_features, o.legal_mask],
                sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()
        except Exception:
            obs_hash = ""  # observation unavailable for this actor (rare)
        pre = state_hash(self.battle)
        legal = observation_safe_skill_mask(self.battle, actor_id)
        envelope = execute_skill(self.battle, actor_id, skill_class, skill_slot, self.ctx)
        post = state_hash(self.battle)
        mission = self.battle.evaluate_mission()
        rec = {
            "decision_index": len(self.records),
            "turn": self.battle.world.current_turn,
            "actor_id": actor_id,
            "skill_class": skill_class,
            "skill_slot": skill_slot,
            "skill_name": envelope.get("skill_name"),
            "legal_mask": list(legal),
            "observation_hash": obs_hash,
            "execution": envelope,
            "pre_state_hash": pre,
            "post_state_hash": post,
            "mission_state": mission["mission_status"],
        }
        self.records.append(rec)
        return rec

    # ------------------------------------------------------------------
    def finalize(self) -> dict:
        m = self.battle.evaluate_mission()
        self.terminal_state = {
            "final_state_hash": state_hash(self.battle),
            "mission_status": m["mission_status"],
            "termination_reason": m["termination_reason"],
            "turn": self.battle.world.current_turn,
        }
        return self.to_dict()

    def trajectory_hash(self) -> str:
        payload = {
            "format": TRAJECTORY_FORMAT_VERSION,
            "sim_version": SIM_VERSION,
            "profile": self.battle.profile_name,
            "scenario_id": str(self.battle.scenario.get("scenario_id", "")),
            "initial_state_hash": self.initial_state_hash,
            "records": self.records,
            "terminal_state": self.terminal_state,
        }
        return hashlib.sha256(
            json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
        ).hexdigest()

    def to_dict(self) -> dict:
        return {
            "trajectory_format_version": TRAJECTORY_FORMAT_VERSION,
            "sim_version": SIM_VERSION,
            "profile": self.battle.profile_name,
            "scenario_id": str(self.battle.scenario.get("scenario_id", "")),
            "initial_state_hash": self.initial_state_hash,
            "records": self.records,
            "terminal_state": self.terminal_state,
            "trajectory_hash": self.trajectory_hash(),
        }


def replay_trajectory(traj: dict, scenario: dict, seed: int = 0) -> dict:
    """Replay a recorded skill sequence from a fresh battle.

    Returns {"ok", "final_state_hash", "expected_state_hash",
    "replay_trajectory_hash"}. Replay uses ONLY the recorded (actor, class,
    slot) decisions — no policy, no randomness."""
    battle = Battle(json.loads(json.dumps(scenario)), traj["profile"], seed=seed)
    for rec in traj["records"]:
        if rec["execution"].get("status") == "MASKED":
            continue
        execute_skill(
            battle, rec["actor_id"], rec["skill_class"], rec["skill_slot"],
            MissionContext(scenario_id=traj.get("scenario_id", "")),
        )
    got = state_hash(battle)
    want = (traj.get("terminal_state") or {}).get("final_state_hash", "")
    return {
        "ok": got == want,
        "final_state_hash": got,
        "expected_state_hash": want,
    }


__all__ = ["TRAJECTORY_FORMAT_VERSION", "TrajectoryRecorder", "replay_trajectory"]
