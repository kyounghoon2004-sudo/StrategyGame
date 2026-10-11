"""V0 acceptance-gate suite — frozen value-semantics contracts (V0-1..V0-18, V0-20).

Covers: TerminalOutcomeV0, MissionProgressV0, ObjectiveProgressV0,
BranchStartOutcomeSnapshotV0, ValueTargetV0, raw-outcome-vector-v0.2.0,
fog guard, determinism, pilot Q, masks, versioning, scope.

V0-19 (regression) is the full-suite run itself; V0-20 scope is asserted in
test_v0_20_no_training_scope below. No training, no optimizer, no production
dataset, no self-play is created anywhere in this task.
"""

from __future__ import annotations

import json
import math

import pytest

from python_jev.dataset.pilot_generator import generate_pilot_dataset
from python_jev.dataset.schema import validate_record
from python_sim.parity.fixtures import probe_scenario
from python_sim.rollout.branch_snapshot import (
    BRANCH_SNAPSHOT_VERSION,
    capture_branch_start,
    casualty_exchange,
    snapshot_bytes,
)
from python_sim.rollout.engine import CounterfactualEngine, state_hash
from python_sim.rollout.mission_progress import (
    MISSION_AUDIT,
    MISSION_PROGRESS_VERSION,
    mission_delta,
    mission_progress,
    mission_progress_blue,
    mission_view_from_battle,
)
from python_sim.rollout.objective_progress import (
    OBJECTIVE_AUDIT,
    OBJECTIVE_PROGRESS_VERSION,
    durability_progress_blue,
    objective_delta,
    objective_progress,
    objective_view_from_battle,
    relevant_objective_ids,
)
from python_sim.rollout.outcome import OUTCOME_VECTOR_VERSION_V2
from python_sim.rollout.terminal import (
    TERMINAL_OUTCOME_VERSION,
    describe_terminal,
    terminal_outcome,
)
from python_sim.rollout.value_target import (
    DEFEAT_MAX,
    NONTERMINAL_MAX,
    NONTERMINAL_MIN,
    VALUE_TARGET_VERSION,
    VICTORY_MIN,
    ValueTargetBlocked,
    assert_q_export_allowed,
    compute_scalar_q,
    content_hash as vt_hash,
    derive_branch_terms,
    derived_bytes,
    q_export_status,
    value_of,
)
from python_sim.rules.turn import VALID_OBJECTIVES
from python_sim.sim.battle import Battle
from python_sim.skills.context import MissionContext


# ---------------------------------------------------------------- helpers
def _probe(profile: str = "DEV_FLAT_ALL_INFO") -> Battle:
    return Battle(probe_scenario(), profile)


def _victory_battle() -> Battle:
    """Probe battle forced into authoritative victory (all red destroyed)."""
    b = _probe()
    for uid in [u.id for u in list(b.world.units.values()) if u.faction == "red"]:
        b.world.destroy_unit(uid)
    assert b.evaluate_mission()["mission_status"] == "victory"
    return b


def _defeat_battle() -> Battle:
    """Probe battle forced into authoritative defeat (blue HQ destroyed)."""
    b = _probe()
    b.world.destroy_unit("B_HQ_1")
    assert b.evaluate_mission()["mission_status"] == "defeat"
    return b


def _expired_battle() -> Battle:
    """Probe battle forced into distinct expired terminal (no verdict)."""
    b = _probe()
    for _ in range(6):  # turn_limit=6 -> turn 7 > 6 with reds alive => expired
        b.sim_end_turn()
    m = b.evaluate_mission()
    assert m["mission_status"] == "expired", m
    return b


# ------------------------------------------------------- V0-1 terminal contract
def test_v0_1_terminal_victory_defeat_expired_ongoing() -> None:
    assert terminal_outcome("victory", "blue") == +1
    assert terminal_outcome("defeat", "blue") == -1
    assert terminal_outcome("ongoing", "blue") == 0
    # EXPIRED is a distinct no-verdict terminal: T=0, no invented penalty.
    assert terminal_outcome("expired", "blue") == 0
    assert terminal_outcome("expired", "red") == 0
    d = describe_terminal("expired", "turn_limit_reached_without_decision", "blue")
    assert d["expired"] is True
    assert d["T"] == 0
    assert d["terminal_verdict"] == "expired"
    assert d["terminal_reason"] == "turn_limit_reached_without_decision"
    # Unknown verdicts never invent victory/defeat.
    assert terminal_outcome("error", "blue") == 0
    # Battle-level: forced terminal states project correctly.
    assert describe_terminal("victory", "all_red_destroyed", "blue")["T"] == +1
    assert _victory_battle().evaluate_mission()["mission_status"] == "victory"
    assert _defeat_battle().evaluate_mission()["mission_status"] == "defeat"
    assert describe_terminal("defeat", "hq_destroyed", "blue")["T"] == -1


# ------------------------------------------------------- V0-2 perspective symmetry
def test_v0_2_blue_red_terminal_symmetry() -> None:
    assert terminal_outcome("victory", "blue") == +1
    assert terminal_outcome("victory", "red") == -1
    assert terminal_outcome("defeat", "blue") == -1
    assert terminal_outcome("defeat", "red") == +1
    assert terminal_outcome("ongoing", "blue") == terminal_outcome("ongoing", "red") == 0
    # Same physical terminal state inverts by perspective (battle-level).
    base = _probe()
    snap_blue = capture_branch_start(base, "blue")
    snap_red = capture_branch_start(base, "red")
    post = _victory_battle()
    d_blue = derive_branch_terms(snap_blue, post, "blue")
    d_red = derive_branch_terms(snap_red, post, "red")
    assert d_blue["T"] == +1 and d_red["T"] == -1
    assert d_blue["M"] == pytest.approx(-d_red["M"])
    assert d_blue["E"] == pytest.approx(-d_red["E"])
    assert d_blue["scalar_Q"] == pytest.approx(-d_red["scalar_Q"])
    post_def = _defeat_battle()
    assert derive_branch_terms(snap_blue, post_def, "blue")["T"] == -1
    assert derive_branch_terms(snap_red, post_def, "red")["T"] == +1


# ------------------------------------------------------- V0-3 mission audit coverage
def test_v0_3_every_mission_type_classified() -> None:
    audited = {m["mission_type"] for m in MISSION_AUDIT}
    assert audited == set(VALID_OBJECTIVES) == {
        "destroy_all_red", "capture_capital", "survive_turns", "hold_hq"}
    for m in MISSION_AUDIT:
        for k in ("authoritative_completion", "authoritative_measurable",
                  "p_definition", "normalization_denominator",
                  "terminal_interaction", "support", "binary_only", "overlap"):
            assert k in m, f"{m['mission_type']} missing {k}"
        assert isinstance(m["binary_only"], bool)


# ------------------------------------------------------- V0-4 mission range
def test_v0_4_mission_progress_always_in_unit_interval() -> None:
    views = [
        {"primary_objective": "destroy_all_red", "turn": 1, "turn_limit": 6,
         "red_formations_alive": a, "red_formations_initial": t, "capital": None}
        for a in (0, 1, 2, 5) for t in (0, 1, 2, 5)
    ]
    capitals: list = [None, {},
               {"breached": True, "owner": "red",
                "fortification_hp": 0, "fortification_hp_max": 1500},
               {"breached": False, "owner": "blue",
                "fortification_hp": 1500, "fortification_hp_max": 1500}]
    capitals += [{"breached": False, "owner": "red",
                  "fortification_hp": hp, "fortification_hp_max": 1500}
                 for hp in (0, 1, 749, 1499, 1500, 9999)]
    views += [
        {"primary_objective": "capture_capital", "turn": 1, "turn_limit": 6,
         "red_formations_alive": 1, "red_formations_initial": 1,
         "capital": c}
        for c in capitals
    ]
    views += [
        {"primary_objective": o, "turn": t, "turn_limit": lim,
         "red_formations_alive": 1, "red_formations_initial": 1, "capital": None}
        for o in ("survive_turns", "hold_hq") for t in (1, 2, 6, 7, 100)
        for lim in (1, 6, 12)
    ]
    views.append({"primary_objective": "unknown_mission", "turn": 1, "turn_limit": 6,
                  "red_formations_alive": 1, "red_formations_initial": 1, "capital": None})
    for v in views:
        for faction in ("blue", "red"):
            p = mission_progress(v, faction)
            assert 0.0 <= p <= 1.0, (v, faction, p)
    # Real battles across pilot missions/profiles.
    for rec in generate_pilot_dataset():
        b = Battle(_scenario_by_id(rec["scenario_id"]), rec["profile"])
        v = mission_view_from_battle(b)
        assert 0.0 <= mission_progress(v, "blue") <= 1.0
        assert 0.0 <= mission_progress(v, "red") <= 1.0


def _scenario_by_id(scenario_id: str) -> dict:
    from python_jev.dataset.pilot_generator import _scenario
    return _scenario(scenario_id, 7)


# ------------------------------------------------------- V0-5 mission delta range
def test_v0_5_mission_delta_in_unit_symmetric_interval() -> None:
    assert mission_delta(1.0, 0.0) == 1.0
    assert mission_delta(0.0, 1.0) == -1.0
    assert mission_delta(0.5, 0.5) == 0.0
    # destroy_all_red branch movement is bounded.
    pre = {"primary_objective": "destroy_all_red", "turn": 1, "turn_limit": 6,
           "red_formations_alive": 2, "red_formations_initial": 2, "capital": None}
    post = dict(pre, red_formations_alive=0)
    assert mission_delta(mission_progress(post, "blue"), mission_progress(pre, "blue")) == 1.0
    assert mission_delta(mission_progress(post, "red"), mission_progress(pre, "red")) == -1.0
    # survive branch movement over one horizon is a small fraction.
    s1 = {"primary_objective": "survive_turns", "turn": 1, "turn_limit": 10,
          "red_formations_alive": 1, "red_formations_initial": 1, "capital": None}
    s2 = dict(s1, turn=3)
    assert mission_delta(mission_progress(s2, "blue"), mission_progress(s1, "blue")) == pytest.approx(0.2)


# ------------------------------------------------------- V0-6 objective audit
def test_v0_6_objective_denominator_explicit_per_mission() -> None:
    audited = {m["mission_type"] for m in OBJECTIVE_AUDIT}
    assert audited == set(VALID_OBJECTIVES)
    cap = next(m for m in OBJECTIVE_AUDIT if m["mission_type"] == "capture_capital")
    assert cap["has_objective_component"] is True
    assert "durability" in cap["denominator"]
    # Denominator machinery works on synthetic capital views.
    view = {"primary_objective": "capture_capital", "strongholds": [
        {"structure_id": "Capital_Luoyang", "owner": "red", "breached": False,
         "fortification_hp": 750, "fortification_hp_max": 1500}]}
    ids = relevant_objective_ids(view)
    assert ids == ["Capital_Luoyang"]
    assert durability_progress_blue(view, ids) == pytest.approx(0.5)
    assert durability_progress_blue(view, []) == 0.0
    # Non-objective missions resolve an empty relevant set.
    for o in ("destroy_all_red", "survive_turns", "hold_hq"):
        assert relevant_objective_ids({"primary_objective": o, "strongholds": []}) == []


# ------------------------------------------------------- V0-7 objective range
def test_v0_7_objective_progress_and_delta_ranges() -> None:
    for o in VALID_OBJECTIVES:
        v = {"primary_objective": o, "strongholds": []}
        for faction in ("blue", "red"):
            assert 0.0 <= objective_progress(v, faction) <= 1.0
    assert objective_delta(1.0, 0.0) == 1.0
    assert objective_delta(0.0, 1.0) == -1.0
    # Live O is 0 for every current mission (overlap review); machinery only.
    b = Battle(probe_scenario(), "TERRAIN_FULL_INFO")
    ov = objective_view_from_battle(b)
    assert objective_progress(ov, "blue") == 0.0


# ------------------------------------------------------- V0-8 no double count
def test_v0_8_mission_objective_overlap_reviewed() -> None:
    # capture_capital: damaged-but-unbreached capital moves M, never O.
    b = Battle(probe_scenario(), "TERRAIN_FULL_INFO")
    assert b.evaluate_mission()["primary_objective"] == "destroy_all_red"  # probe sanity
    cap_view = {"primary_objective": "capture_capital", "strongholds": [
        {"structure_id": "Capital_Luoyang", "owner": "red", "breached": False,
         "fortification_hp": 1000, "fortification_hp_max": 1500}]}
    m_view = {"primary_objective": "capture_capital", "turn": 1, "turn_limit": 6,
              "red_formations_alive": 1, "red_formations_initial": 1,
              "capital": {"breached": False, "owner": "red",
                          "fortification_hp": 1000, "fortification_hp_max": 1500}}
    assert mission_progress_blue(m_view) == pytest.approx(1.0 - 1000.0 / 1500.0)
    assert durability_progress_blue(cap_view, ["Capital_Luoyang"]) > 0.0  # machinery sees it
    assert objective_progress(cap_view, "blue") == 0.0  # live term zeroed: M carries it
    # destroy_all_red: troop damage without formation kill moves E, never M.
    base = _probe()
    snap = capture_branch_start(base, "blue")
    post = base.clone()
    post.world.units["R_INF_1"].soldier_count = 400  # 477 -> 400, formation survives
    d = derive_branch_terms(snap, post, "blue")
    assert d["M"] == 0.0
    assert d["E"] > 0.0
    assert d["O"] == 0.0


# ------------------------------------------------------- V0-9 branch baseline identity
def test_v0_9_all_six_branches_share_identical_snapshot() -> None:
    b = _probe()
    ev = CounterfactualEngine.from_name("SimpleAttackElseAdvancePolicy", 4, 7)\
        .evaluate(b, "B_INF_1", MissionContext())
    shared = snapshot_bytes(ev.branch_start_snapshot)
    assert snapshot_bytes(capture_branch_start(b, "blue")) == shared
    # Independent per-branch captures are byte-identical (frozen decision state).
    for slot in range(6):
        branch = b.clone()
        assert snapshot_bytes(capture_branch_start(branch, "blue")) == shared
    snap = ev.branch_start_snapshot
    assert snap["blue_live_soldiers"] > 0 and snap["red_live_soldiers"] > 0
    assert snap["terminal_before"]["terminal_verdict"] == "ongoing"
    assert "mission_progress_before" in snap and "objective_progress_before" in snap


# ------------------------------------------------------- V0-10 casualty baseline
def test_v0_10_exchange_uses_branch_start_not_scenario_start() -> None:
    base = _probe()
    # Inflict pre-branch casualties (scenario-start 830 blue / 1090 red).
    pre = base.clone()
    pre.world.units["R_INF_1"].soldier_count = 377  # -100 pre-branch red loss
    pre.world.units["B_INF_1"].soldier_count = 400  # -50 pre-branch blue loss
    snap = capture_branch_start(pre, "blue")
    assert snap["red_live_soldiers"] == 990   # branch-start, not 1090
    assert snap["blue_live_soldiers"] == 780  # branch-start, not 830
    # No further change across the branch => E=0 despite scenario-start losses.
    d = derive_branch_terms(snap, pre.clone(), "blue")
    assert d["E"] == 0.0
    assert d["enemy_casualties_since_branch_start"] == 0
    # Branch casualties divide by branch-start totals.
    post = pre.clone()
    post.world.units["R_INF_1"].soldier_count = 277  # -100 more since branch start
    d2 = derive_branch_terms(snap, post, "blue")
    assert d2["enemy_fraction"] == pytest.approx(100.0 / 990.0)
    assert d2["friendly_fraction"] == 0.0
    assert d2["E"] == pytest.approx(100.0 / 990.0)
    # Visible-only counts are never the denominator (full-information totals).
    assert d2["enemy_live_at_branch_start"] == 990


# ------------------------------------------------------- V0-11 zero change gives zero
def test_v0_11_no_change_no_reward() -> None:
    base = _probe()
    for faction in ("blue", "red"):
        snap = capture_branch_start(base, faction)
        d = derive_branch_terms(snap, base.clone(), faction)
        assert d["T"] == 0 and d["M"] == 0.0 and d["O"] == 0.0 and d["E"] == 0.0
        assert d["scalar_Q"] == 0.0
    # Engine hold (frozen battlefield) also yields Q=0 on every legal branch.
    ev = CounterfactualEngine.from_name("HoldPolicy", 4, 7)\
        .evaluate(_probe(), "B_INF_1", MissionContext())
    for s in range(6):
        if ev.branches[s].execution_status != "MASKED":
            assert ev.branches[s].outcome_scalar == 0.0


# ------------------------------------------------------- V0-12 force exchange direction
def test_v0_12_enemy_losses_raise_q_friendly_losses_lower_q() -> None:
    base = _probe()
    snap = capture_branch_start(base, "blue")
    q0 = derive_branch_terms(snap, base.clone(), "blue")["scalar_Q"]
    assert q0 == 0.0
    hurt_red = base.clone()
    hurt_red.world.units["R_INF_1"].soldier_count = 377
    q_red_hurt = derive_branch_terms(snap, hurt_red, "blue")["scalar_Q"]
    assert q_red_hurt > q0
    hurt_blue = base.clone()
    hurt_blue.world.units["B_INF_1"].soldier_count = 350
    q_blue_hurt = derive_branch_terms(snap, hurt_blue, "blue")["scalar_Q"]
    assert q_blue_hurt < q0
    # Symmetry: the same physical exchange scores oppositely for red.
    snap_red = capture_branch_start(base, "red")
    assert derive_branch_terms(snap_red, hurt_red, "red")["scalar_Q"] < 0.0


# ------------------------------------------------------- V0-13 terminal dominance
def test_v0_13_victory_beats_every_nonterminal_beats_defeat() -> None:
    # Analytic extremes.
    assert value_of(0, 1, 1, 1) == NONTERMINAL_MAX == 7.0
    assert value_of(0, -1, -1, -1) == NONTERMINAL_MIN == -7.0
    assert value_of(1, -1, -1, -1) == VICTORY_MIN == 9.0
    assert value_of(-1, 1, 1, 1) == DEFEAT_MAX == -9.0
    assert VICTORY_MIN > NONTERMINAL_MAX > NONTERMINAL_MIN > DEFEAT_MAX
    # Battle-level: realized victory/defeat/ongoing Q respect the ordering.
    base = _probe()
    snap = capture_branch_start(base, "blue")
    q_ongoing = derive_branch_terms(snap, base.clone(), "blue")["scalar_Q"]
    assert NONTERMINAL_MIN <= q_ongoing <= NONTERMINAL_MAX
    q_victory = derive_branch_terms(snap, _victory_battle(), "blue")["scalar_Q"]
    assert q_victory >= VICTORY_MIN
    q_defeat = derive_branch_terms(snap, _defeat_battle(), "blue")["scalar_Q"]
    assert q_defeat <= DEFEAT_MAX
    assert q_victory > q_ongoing > q_defeat
    # Expired (no verdict) stays inside the non-terminal band: no expiry penalty.
    q_expired = derive_branch_terms(snap, _expired_battle(), "blue")["scalar_Q"]
    assert NONTERMINAL_MIN <= q_expired <= NONTERMINAL_MAX


# ------------------------------------------------------- V0-14 fog guard
def test_v0_14_partial_information_q_export_impossible() -> None:
    for profile in ("FLAT_FOG", "TERRAIN_FOG", "MORALE_COMBAT", "FULL_PRODUCTION"):
        assert q_export_status(profile) == "FORBIDDEN_PARTIAL_INFORMATION"
        with pytest.raises(ValueTargetBlocked):
            assert_q_export_allowed(profile)
        with pytest.raises(ValueTargetBlocked):
            compute_scalar_q(1.0, 0.0, 0.0, 0.0, profile)
    for profile in ("DEV_FLAT_ALL_INFO", "TERRAIN_FULL_INFO"):
        assert q_export_status(profile) == "OK"
    # Engine fog evaluation: no Q anywhere, q_valid all False.
    ev = CounterfactualEngine.from_name("SimpleAttackElseAdvancePolicy", 2, 7)\
        .evaluate(Battle(probe_scenario(), "FLAT_FOG"), "B_INF_1", MissionContext())
    assert ev.q_export_status == "FORBIDDEN_PARTIAL_INFORMATION"
    assert ev.q_valid_mask == [False] * 6
    for s in range(6):
        assert ev.branches[s].outcome_scalar is None


# ------------------------------------------------------- V0-15 determinism
def test_v0_15_identical_inputs_identical_q_bytes() -> None:
    base = _probe()
    snap = capture_branch_start(base, "blue")
    post = base.clone()
    post.world.units["R_INF_1"].soldier_count = 400
    a = derive_branch_terms(snap, post, "blue")
    b = derive_branch_terms(
        json.loads(json.dumps(snap)), post.clone(), "blue")
    assert derived_bytes(a) == derived_bytes(b)
    assert a["scalar_Q"] == b["scalar_Q"]
    # Engine-level: repeated full evaluations are byte-identical incl. Q.
    def run() -> str:
        ev = CounterfactualEngine.from_name("SimpleAttackElseAdvancePolicy", 4, 7)\
            .evaluate(_probe(), "B_INF_1", MissionContext())
        return json.dumps(ev.to_dict(), sort_keys=True)
    assert run() == run()


# ------------------------------------------------------- V0-16 pilot end-to-end
def test_v0_16_pilot_scenarios_yield_valid_q_for_all_legal_branches() -> None:
    records = generate_pilot_dataset()
    assert len(records) >= 15
    n_legal = 0
    qs: list[float] = []
    for rec in records:
        assert validate_record(rec) == []
        assert rec["q_export_status"] == "OK"
        assert rec["contract_versions"]["value_target_version"] == VALUE_TARGET_VERSION
        assert rec["contract_versions"]["outcome_vector_version"] == OUTCOME_VECTOR_VERSION_V2
        for slot, ps in enumerate(rec["per_skill"]):
            ro = ps["raw_outcome"]
            if ps["execution_status"] == "MASKED":
                assert ps["outcome_scalar"] is None
                continue
            n_legal += 1
            q = ps["outcome_scalar"]
            assert isinstance(q, float) and math.isfinite(q)
            assert -23.0 <= q <= 23.0
            qs.append(q)
            # raw -> T/M/O/E -> Q chain is internally consistent.
            assert ro["scalar_Q"] == q
            assert ro["scalar_Q"] == pytest.approx(
                16 * ro["T"] + 4 * ro["M"] + 2 * ro["O"] + ro["E"], abs=1e-3)
            assert -1 <= ro["T"] <= 1
            assert -1.0 <= ro["M"] <= 1.0
            assert -1.0 <= ro["O"] <= 1.0
            assert -1.0 <= ro["E"] <= 1.0
    assert n_legal > 0
    assert min(qs) <= 0.0 <= max(qs)


# ------------------------------------------------------- V0-17 mask rule
def test_v0_17_illegal_branches_receive_no_q() -> None:
    scn = probe_scenario()
    scn["forces"] = [f for f in scn["forces"] if f["faction"] != "red"]
    scn["forces"].append({"id": "B_CAV_N", "class": "cavalry", "faction": "blue",
                          "q": -25, "r": -1, "soldiers": 300})
    ev = CounterfactualEngine.from_name("SimpleAttackElseAdvancePolicy", 2, 7)\
        .evaluate(Battle(scn, "DEV_FLAT_ALL_INFO"), "B_CAV_N", MissionContext())
    assert ev.legal_mask[0] is False
    assert ev.q_valid_mask[0] is False
    assert ev.branches[0].outcome_scalar is None
    assert ev.branches[0].raw_outcome["terminal_result"] == "MASKED"


# ------------------------------------------------------- V0-18 versioning
def test_v0_18_stable_versions_and_content_hashes() -> None:
    import hashlib

    versions = [TERMINAL_OUTCOME_VERSION, MISSION_PROGRESS_VERSION,
                OBJECTIVE_PROGRESS_VERSION, BRANCH_SNAPSHOT_VERSION,
                VALUE_TARGET_VERSION, OUTCOME_VECTOR_VERSION_V2]
    assert len(set(versions)) == 6  # each contract versioned distinctly
    from python_sim.rollout import branch_snapshot, mission_progress, objective_progress, terminal
    hashes = [terminal.content_hash(), mission_progress.content_hash(),
              objective_progress.content_hash(), branch_snapshot.content_hash(),
              vt_hash()]
    for h in hashes:
        assert len(h) == 64 and all(c in "0123456789abcdef" for c in h)
    assert len(set(hashes)) == 5  # distinct contract contents
    assert terminal.content_hash() == hashlib.sha256(
        terminal._TERMINAL_SPEC_CANONICAL.encode()).hexdigest()  # stable


# ------------------------------------------------------- V0-20 scope (no training artefacts)
# T0 SCOPE MIGRATION (documented, analogous to the V0 J1-13/14/15 flip): the
# T0 task is the FIRST AUTHORIZED supervised training run, so training
# modules now exist — but ONLY inside python_jev/training/ (+ its T0 tests).
# Everything else this guard protected still holds: the rollout/value path
# performs no learning, no RL/self-play machinery exists anywhere, the pilot
# generator stays small-scale, and JevPolicyV0 stays out of the rollout engine.
T0_TRAINING_DIRS = ("python_jev/training",)


def test_v0_20_no_training_optimizer_dataset_or_selfplay() -> None:
    import pathlib

    root = pathlib.Path(__file__).resolve().parents[2]
    # Optimizer / training-loop / checkpoint modules may exist ONLY inside the
    # authorized T0 training package (nowhere else in either package).
    suspects = [p for p in list((root / "python_sim").rglob("*.py"))
                + list((root / "python_jev").rglob("*.py"))
                if any(k in p.name.lower() for k in ("optim", "train_", "_train", "checkpoint", "selfplay"))
                and not any(str(p.relative_to(root)).replace("\\", "/").startswith(d)
                            for d in T0_TRAINING_DIRS)
                and p.name != "test_t0_training.py"]
    assert suspects == [], f"training modules outside python_jev/training/: {suspects}"
    # No RL / self-play machinery anywhere in non-test sources (source-level;
    # hyphens in prose like "self-play"/"no RL" do not trip these substrings;
    # test files may NAME the forbidden concepts they guard against).
    for pkg in ("python_sim", "python_jev"):
        for p in (root / pkg).rglob("*.py"):
            rel = str(p.relative_to(root)).replace("\\", "/")
            if "/tests/" in rel or p.name.startswith("test_"):
                continue
            src = p.read_text(encoding="utf-8")
            for banned in ("selfplay", "self_play", "policy_gradient", "PPO(", "DQN("):
                assert banned not in src, f"{rel} mentions {banned}"
    # Value-target path performs no learning: rollout sources import no
    # torch/optim/self-play machinery (source-level check, no imports needed).
    for name in ("terminal", "mission_progress", "objective_progress",
                 "branch_snapshot", "value_target", "outcome", "engine"):
        src = (root / "python_sim" / "rollout" / f"{name}.py").read_text(encoding="utf-8")
        for banned in ("torch", "optim", "self_play", "selfplay", "DataLoader", "backward("):
            assert banned not in src, f"rollout/{name}.py mentions {banned}"
    # Pilot artifact stays small-scale (no production corpus).
    assert len(generate_pilot_dataset()) < 100
    # No Godot gameplay rewrite: no value-target symbols in gameplay sources,
    # and the policy itself is untouched by this task (no training entry).
    import python_sim.rollout.engine as eng
    assert "JevPolicyV0" not in dir(eng)
