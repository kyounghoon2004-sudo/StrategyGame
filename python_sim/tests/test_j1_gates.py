"""J1 acceptance-gate suite — rollout/trajectory/dataset layers (J1-9..J1-23).

Skill-layer gates J1-1..J1-8 live in test_j1_skills.py. This module covers:

  J1-9  six-way branch           J1-16 fog label guard
  J1-10 clone isolation          J1-17 trajectory replay
  J1-11 legal/Q masks            J1-18 determinism
  J1-12 multi-step rollout       J1-19 pilot dataset
  J1-13 raw outcome vector       J1-20 versioning
  J1-14 value target safety      J1-21 JEV forward
  J1-15 full-info Q status       J1-22 performance
"""

from __future__ import annotations

import copy
import json
import time

import pytest

from python_jev.constants import ACTION_SPACE
from python_jev.dataset.pilot_generator import (
    generate_pilot_dataset,
    write_pilot_dataset,
)
from python_jev.dataset.schema import (
    DATASET_SCHEMA_VERSION,
    PARTIAL_INFO_PROFILES,
    assert_no_fog_oracle_labels,
    read_jsonl,
    validate_record,
)
from python_jev.layout import PATCH_NUM_CELLS
from python_jev.model import JevPolicyV0
from python_jev.observation import ObservationBatchV0
from python_sim.parity.fixtures import probe_scenario
from python_sim.rollout.config import (
    CONTINUATION_POLICIES,
    ROLLOUT_CONFIG_VERSION,
    RolloutConfig,
)
from python_sim.rollout.engine import CounterfactualEngine, state_hash
from python_sim.rollout.outcome import COMPONENT_NAMES, OUTCOME_VECTOR_VERSION_V2
from python_sim.rollout.value_target import (
    VALUE_TARGET_VERSION,
    ValueTargetBlocked,
    assert_q_export_allowed,
    compute_scalar_q,
    q_export_status,
)
from python_sim.sim.battle import Battle
from python_sim.skills.context import MissionContext
from python_sim.trajectory.recorder import TrajectoryRecorder, replay_trajectory

PILOT_PATH = "artifacts/j1_pilot_dataset.jsonl"


# --------------------------------------------------------------------- J1-9
def test_j1_9_six_way_branch_over_class_table() -> None:
    b = Battle(probe_scenario(), "DEV_FLAT_ALL_INFO")
    ev = CounterfactualEngine.from_name("SimpleAttackElseAdvancePolicy", 4, 7)\
        .evaluate(b, "B_INF_1", MissionContext())
    assert sorted(ev.branches) == [0, 1, 2, 3, 4, 5]
    for slot, name in enumerate(ACTION_SPACE["INFANTRY"]):
        assert ev.branches[slot].skill_name == name


# -------------------------------------------------------------------- J1-10
def test_j1_10_clone_isolation_identical_initial_hashes() -> None:
    b = Battle(probe_scenario(), "DEV_FLAT_ALL_INFO")
    eng = CounterfactualEngine.from_name("SimpleAttackElseAdvancePolicy", 4, 7)
    base = state_hash(b)
    ev = eng.evaluate(b, "B_INF_1", MissionContext())
    hashes = {ev.branches[s].initial_state_hash for s in range(6)}
    assert len(hashes) == 1
    assert hashes.pop() == base
    # the source battle was never mutated by evaluating its branches
    assert state_hash(b) == base
    # divergent post-skill hashes prove branches actually executed separately
    assert len({ev.branches[s].post_skill_state_hash for s in range(6)}) > 1


# -------------------------------------------------------------------- J1-11
def test_j1_11_masks_exclude_illegal_without_fake_values() -> None:
    # empty red army: ATTACK is illegal for every learned class
    scn = probe_scenario()
    scn["forces"] = [f for f in scn["forces"] if f["faction"] != "red"]
    scn["forces"].append({"id": "B_CAV_N", "class": "cavalry", "faction": "blue",
                          "q": -25, "r": -1, "soldiers": 300})
    b = Battle(scn, "DEV_FLAT_ALL_INFO")
    ev = CounterfactualEngine.from_name("SimpleAttackElseAdvancePolicy", 2, 7)\
        .evaluate(b, "B_CAV_N", MissionContext())
    assert ev.legal_mask[0] is False
    assert ev.q_valid_mask == ev.legal_mask
    masked = ev.branches[0]
    assert masked.execution_status == "MASKED"
    assert masked.outcome_scalar is None                      # no fake value
    assert masked.raw_outcome["terminal_result"] == "MASKED"
    # legal slots carry a real (non-MASKED) execution status
    legal_slots = [s for s in range(6) if ev.legal_mask[s]]
    assert legal_slots
    for s in legal_slots:
        assert ev.branches[s].execution_status in ("SUCCESS", "PARTIAL", "INTERRUPTED", "INVALID")


# -------------------------------------------------------------------- J1-12
def test_j1_12_bounded_multistep_continuation() -> None:
    b = Battle(probe_scenario(), "DEV_FLAT_ALL_INFO")
    for horizon in (2, 8):
        ev = CounterfactualEngine.from_name("SimpleAttackElseAdvancePolicy", horizon, 7)\
            .evaluate(b, "B_INF_1", MissionContext())
        for s in range(6):
            ro = ev.branches[s].raw_outcome
            assert isinstance(ro["horizon_steps"], int)
            assert 0 <= ro["horizon_steps"] <= horizon


# -------------------------------------------------------------------- J1-13
def test_j1_13_raw_outcome_vector_frozen_components() -> None:
    b = Battle(probe_scenario(), "DEV_FLAT_ALL_INFO")
    ev = CounterfactualEngine.from_name("SimpleAttackElseAdvancePolicy", 4, 7)\
        .evaluate(b, "B_INF_1", MissionContext())
    for s in range(6):
        ro = ev.branches[s].raw_outcome
        for k in COMPONENT_NAMES:
            assert k in ro, f"slot {s} missing {k}"
        assert ro["own_hq_alive"] in (0, 1)
        assert 0.0 <= ro["own_strength_ratio"] <= 1.0
        if ev.branches[s].execution_status != "MASKED":
            # full-info legal branches carry the v0.2.0 derived section
            assert ro["outcome_vector_version"] == OUTCOME_VECTOR_VERSION_V2
            for k in ("T", "M", "O", "E", "scalar_Q", "mission_progress_before",
                      "mission_progress_after", "objective_progress_before",
                      "objective_progress_after", "terminal_reason", "expired",
                      "enemy_live_at_branch_start", "friendly_live_at_branch_start"):
                assert k in ro, f"slot {s} missing derived {k}"
            assert ro["scalar_Q"] == ev.branches[s].outcome_scalar


def test_j1_13b_continuation_policies_all_run_and_are_versioned() -> None:
    b = Battle(probe_scenario(), "DEV_FLAT_ALL_INFO")
    outs = {}
    for pol in CONTINUATION_POLICIES:
        ev = CounterfactualEngine(RolloutConfig(continuation_policy=pol, horizon_decisions=12, seed=7))\
            .evaluate(b, "B_INF_1", MissionContext())
        outs[pol] = {s: ev.branches[s].raw_outcome for s in range(6)}
        assert ev.rollout_config["rollout_config_version"] == ROLLOUT_CONFIG_VERSION
        for s in range(6):
            for k in COMPONENT_NAMES:
                assert k in outs[pol][s]
            # every legal branch consumed the full decision budget (holds and
            # moves both count as decisions) — proof of bounded multi-step
            # continuation, not a single action.
            if ev.branches[s].execution_status != "MASKED":
                assert outs[pol][s]["horizon_steps"] == 12
    # HOLD freezes the battlefield: no faction ever closes, so no casualties
    # can occur under the scripted red policy either.
    hold = outs["HoldPolicy"]
    assert all(v["enemy_casualties"] == 0 and v["friendly_casualties"] == 0
               for v in hold.values())


# ------------------------------------------------------- J1-14 / J1-15
def test_j1_14_value_target_guard_allows_full_info_blocks_fog() -> None:
    # ValueTargetV0 (value-target-v0.1.0) is frozen: scalar Q exports for
    # full-information profiles; fog profiles remain permanently forbidden.
    from python_sim.rollout.value_target import (
        VALUE_TARGET_CONTRACT_EXISTS,
        value_of,
    )

    assert VALUE_TARGET_CONTRACT_EXISTS is True
    assert VALUE_TARGET_VERSION == "value-target-v0.1.0"
    for profile in ("DEV_FLAT_ALL_INFO", "TERRAIN_FULL_INFO"):
        assert q_export_status(profile) == "OK"
        assert_q_export_allowed(profile)  # must not raise
        assert compute_scalar_q(1.0, 0.0, 0.0, 0.0, profile) == 16.0
        assert compute_scalar_q(0.0, 1.0, 1.0, 1.0, profile) == 7.0
        assert compute_scalar_q(-1.0, 0.0, 0.0, 0.0, profile) == -16.0
    assert value_of(1.0, -1.0, -1.0, -1.0) == 9.0    # terminal victory min
    assert value_of(-1.0, 1.0, 1.0, 1.0) == -9.0     # terminal defeat max


def test_j1_15_full_info_branches_carry_scalar_q() -> None:
    for rec in generate_pilot_dataset():
        assert rec["q_export_status"] == "OK"
        assert isinstance(rec["q_values"], list) and len(rec["q_values"]) == 6
        for slot, ps in enumerate(rec["per_skill"]):
            assert ps["outcome_scalar"] == rec["q_values"][slot]
            if ps["execution_status"] == "MASKED":
                assert ps["outcome_scalar"] is None
            else:
                assert isinstance(ps["outcome_scalar"], float)


# -------------------------------------------------------------------- J1-16
def test_j1_16_fog_oracle_label_guard() -> None:
    for profile in PARTIAL_INFO_PROFILES:
        assert "FORBIDDEN" in q_export_status(profile) or q_export_status(
            profile) == "FORBIDDEN_PARTIAL_INFORMATION"
        with pytest.raises(ValueTargetBlocked):
            assert_q_export_allowed(profile)


def test_j1_16b_fog_records_cannot_carry_q_and_guard_raises() -> None:
    rec = {
        "profile": "FLAT_FOG",
        "q_values": [1.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "q_export_status": "OK",
        "world_truth_in_payload": False,
    }
    with pytest.raises(ValueError, match="LEAKAGE"):
        assert_no_fog_oracle_labels(rec)
    rec2 = {"profile": "FLAT_FOG", "q_values": None,
            "q_export_status": "FORBIDDEN_PARTIAL_INFORMATION",
            "world_truth_in_payload": True}
    with pytest.raises(ValueError, match="LEAKAGE"):
        assert_no_fog_oracle_labels(rec2)


def test_j1_16c_fog_hidden_truth_never_reaches_observation_or_mask() -> None:
    from python_sim.observation.projector import ObservationProjector
    from python_sim.skills import observation_safe_skill_mask

    b1 = Battle(probe_scenario(), "FLAT_FOG")
    b2 = Battle(probe_scenario(), "FLAT_FOG")
    b2.world.units["R_CON_9"].soldier_count = 999
    b2.world.units["R_CON_9"].q = -20        # move the hidden unit
    p1 = ObservationProjector(b1).project("blue", "B_INF_1")
    p2 = ObservationProjector(b2).project("blue", "B_INF_1")
    assert p1.actor_features == p2.actor_features
    assert p1.tokens == p2.tokens
    assert p1.hex_patch == p2.hex_patch
    assert p1.global_features == p2.global_features
    assert observation_safe_skill_mask(b1, "B_INF_1") == \
        observation_safe_skill_mask(b2, "B_INF_1")


# -------------------------------------------------------------------- J1-17
def test_j1_17_trajectory_replay_same_final_hash() -> None:
    scenario = probe_scenario()
    b = Battle(copy.deepcopy(scenario), "DEV_FLAT_ALL_INFO")
    rec = TrajectoryRecorder(b, MissionContext(scenario_id="probe"))
    # deterministic scripted selection: every blue combatant advances then holds
    for uid in ("B_INF_1", "B_SCT_1"):
        rec.record_decision(uid, "INFANTRY", 1)
        rec.record_decision(uid, "INFANTRY", 2)
    traj = rec.finalize()
    assert traj["terminal_state"]["final_state_hash"] == state_hash(b)

    r1 = replay_trajectory(traj, scenario)
    r2 = replay_trajectory(traj, scenario)
    assert r1["ok"] and r2["ok"]
    assert r1["final_state_hash"] == r2["final_state_hash"] == traj["terminal_state"]["final_state_hash"]


# -------------------------------------------------------------------- J1-18
def test_j1_18_counterfactual_determinism_across_runs() -> None:
    def run() -> dict:
        b = Battle(probe_scenario(), "TERRAIN_FULL_INFO")
        eng = CounterfactualEngine(RolloutConfig(
            continuation_policy="RandomLegalPolicy", horizon_decisions=6, seed=11))
        return eng.evaluate(b, "B_INF_1", MissionContext()).to_dict()

    a, c = run(), run()
    assert json.dumps(a, sort_keys=True) == json.dumps(c, sort_keys=True)


# -------------------------------------------------------------------- J1-19
def test_j1_19_pilot_dataset_written_and_valid() -> None:
    import os
    os.makedirs("artifacts", exist_ok=True)
    summary = write_pilot_dataset(PILOT_PATH)
    assert summary["records"] >= 15
    assert summary["profiles"] == ["DEV_FLAT_ALL_INFO", "TERRAIN_FULL_INFO"]
    assert set(summary["classes"]) == {"INFANTRY", "SPEARMAN", "CAVALRY", "ARCHER", "SCOUT"}
    records = read_jsonl(PILOT_PATH)
    assert len(records) == summary["records"]
    # every (class, slot) pair — the real 30-skill coverage unit, since tables
    # share names across classes — appears at least once.
    pairs = {(r["actor_class"], ps["skill_slot"]) for r in records for ps in r["per_skill"]}
    expected = {(cls, s) for cls in ACTION_SPACE for s in range(6)}
    assert expected <= pairs
    # all records schema-clean, no leakage, versions pinned
    for r in records:
        assert validate_record(r) == []
        assert r["dataset_schema_version"] == DATASET_SCHEMA_VERSION
        assert r["world_truth_in_payload"] is False
        cv = r["contract_versions"]
        for k, v in cv.items():
            if k != "jev_action_space_version":
                assert v, f"empty version pin: {k}"
        # masked slots never smuggle a scalar
        for ps in r["per_skill"]:
            if ps["execution_status"] == "MASKED":
                assert ps["outcome_scalar"] is None


# -------------------------------------------------------------------- J1-20
def test_j1_20_record_pins_all_contract_versions() -> None:
    rec = generate_pilot_dataset()[0]
    cv = rec["contract_versions"]
    for k in ("sim_version", "ruleset_version", "ruleset_hash",
              "observation_layout_version", "observation_layout_hash",
              "skill_contract_version", "skill_modes_hash",
              "rollout_config_version", "continuation_policy_version",
              "outcome_vector_version", "value_target_version",
              "trajectory_format_version", "dataset_schema_version"):
        assert cv.get(k), k
    assert rec["state_hash"]
    assert rec["observation"]["payload_hash"]


# -------------------------------------------------------------------- J1-21
def test_j1_21_pilot_observation_forwards_through_jevpolicyv0() -> None:
    import torch

    rec = next(r for r in generate_pilot_dataset()
               if r["profile"] == "DEV_FLAT_ALL_INFO" and r["actor_class"] == "INFANTRY")
    obs = dict(rec["observation"])
    obs.pop("payload_hash")
    batch = ObservationBatchV0(
        actor_features=torch.tensor([obs["actor_features"]], dtype=torch.float32),
        tokens=torch.tensor([obs["tokens"]], dtype=torch.float32),
        token_padding_mask=torch.tensor([obs["token_padding_mask"]], dtype=torch.bool),
        hex_patch=torch.tensor([obs["hex_patch"]], dtype=torch.float32),
        hex_padding_mask=torch.zeros(1, PATCH_NUM_CELLS, dtype=torch.bool),
        mission_features=torch.tensor([obs["mission_features"]], dtype=torch.float32),
        global_features=torch.tensor([obs["global_features"]], dtype=torch.float32),
        legal_mask=torch.tensor([rec["legal_mask"]], dtype=torch.bool),
        acting_class_idx=torch.tensor([obs["acting_class_idx"]], dtype=torch.long),
        metadata={},
    )
    torch.manual_seed(0)
    policy = JevPolicyV0().eval()
    with torch.no_grad():
        out = policy(batch)
    assert tuple(out.raw_logits.shape) == (1, 6)          # raw_logits[6]
    assert out.legal_mask[0].tolist() == [bool(x) for x in rec["legal_mask"]]
    assert int(out.selected_slot[0]) in range(6)


# -------------------------------------------------------------------- J1-22
@pytest.mark.parametrize("profile", ["DEV_FLAT_ALL_INFO", "TERRAIN_FULL_INFO"])
def test_j1_22_counterfactual_throughput_measured(profile) -> None:
    n_evals = 10
    b = Battle(probe_scenario(), profile)
    ctx = MissionContext()
    eng = CounterfactualEngine.from_name("SimpleAttackElseAdvancePolicy", 8, 7)

    # warm-up
    eng.evaluate(b, "B_INF_1", ctx)

    clone_time = 0.0
    t0 = time.perf_counter()
    for _ in range(n_evals):
        for _ in range(6):
            tc0 = time.perf_counter()
            b.clone()
            clone_time += time.perf_counter() - tc0
        eng.evaluate(b, "B_INF_1", ctx)
    total = time.perf_counter() - t0

    per_eval_ms = total / n_evals * 1000.0
    rollouts_per_sec = (n_evals * 6) / total
    decision_states_per_sec = n_evals / total
    clone_share = clone_time / total
    print(f"\n[{profile}] six-branch evaluation: {per_eval_ms:.1f} ms  | "
          f"rollouts/sec: {rollouts_per_sec:.1f}  | "
          f"decision states/sec: {decision_states_per_sec:.2f}  | "
          f"clone share: {clone_share:.1%}")
    assert per_eval_ms > 0 and rollouts_per_sec > 0
