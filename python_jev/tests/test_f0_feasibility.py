"""F0 gates — feasibility audit, benchmark V1, epsilon/sensitivity contracts.

Fast unit-level gates (no full benchmark runs here; the heavy protocols
write artifacts/jev_feasibility_v0/*). Covers F0-1 (classification
completeness), F0-7 (checkpoint untouched), F0-12/13 (benchmark contract),
F0-14 (frozen metric intact), F0-15 (sensitivity math), F0-19/20 (scope).
"""

from __future__ import annotations

import hashlib
import pathlib

import torch

ROOT = pathlib.Path(__file__).resolve().parents[2]
SEED43 = ROOT / "artifacts" / "jev_training_v0" / "checkpoints" / "seed43.pt"
SEED43_SHA256 = "02d46c8a3ad56e893b5fd88d1ed5509d3f95b0e70f5d715c86ecae595d9ca2b2"


# ------------------------------------------------------------------ F0-1
def test_f0_1_every_mask_legal_nonsuccess_classifies() -> None:
    from python_jev.feasibility.audit import FAILURE_CLASSES, classify_failure

    assert len(FAILURE_CLASSES) == 5
    for status in ("INVALID", "PARTIAL", "INTERRUPTED"):
        for skill in ("ATTACK", "ADVANCE", "HOLD", "REPOSITION", "SUPPORT",
                      "WITHDRAW", "SCREEN", "FLANK", "PURSUE", "RESERVE",
                      "FIRE", "FOCUS_FIRE", "REPOSITION_RANGE", "KITE",
                      "HOLD_POSITION", "RECON_ADVANCE", "SHADOW", "HARASS",
                      "EVADE", "REGROUP"):
            for code in ("NO_TARGET", "NO_DESTINATION", "NO_ANCHOR", "NONE",
                         "STALE_STATE", "ENGINE_REJECTED", "BLOCKED"):
                env = {"status": status, "failure_code": code,
                       "partial": {"interrupted": status == "INTERRUPTED",
                                   "reason": "HIDDEN_CONTACT"} if status != "INVALID" else None}
                got = classify_failure(skill, env, True, 10, 10)
                assert got in FAILURE_CLASSES, (status, skill, code, got)
    # stale evidence always wins; masked rows are not failures
    assert classify_failure("ATTACK", {"status": "INVALID",
                                       "failure_code": "NO_TARGET"}, True, 10, 11) == "STALE_STATE_RACE"
    assert classify_failure("ATTACK", {"status": "INVALID",
                                       "failure_code": "STALE_STATE"}, True, 10, 10) == "STALE_STATE_RACE"
    assert classify_failure("ATTACK", {"status": "INVALID",
                                       "failure_code": "NO_TARGET"}, False, 10, 10) == "MASKED"


def test_f0_1_mismatch_pairs_are_declared() -> None:
    from python_jev.feasibility.audit import MISMATCH_PAIRS, classify_failure

    assert len(MISMATCH_PAIRS) >= 3
    env = {"status": "INVALID", "failure_code": "NO_TARGET", "partial": None}
    assert classify_failure("ATTACK", env, True, 3, 3) == "CONTRACT_MISMATCH"
    assert classify_failure("ADVANCE", {"status": "INVALID", "failure_code": "NO_DESTINATION",
                                        "partial": None}, True, 3, 3) == "MASK_UNDERSPECIFIED"


# ------------------------------------------------------------------ F0-7
def test_f0_7_seed43_checkpoint_bytes_unchanged() -> None:
    assert SEED43.exists()
    digest = hashlib.sha256(SEED43.read_bytes()).hexdigest()
    assert digest == SEED43_SHA256


def test_f0_7_checkpoint_loads_and_selects_deterministically() -> None:
    from python_jev.model import JevPolicyV0
    from python_jev.synthetic import make_observation_batch
    from python_jev.training.checkpoint import load_checkpoint

    model = JevPolicyV0().eval()
    meta = load_checkpoint(str(SEED43), model)
    assert meta["model_version"] == "jev-policy-v0.1.0-fi"
    assert meta["seed"] == 43
    batch = make_observation_batch(batch_size=2, seed=0)
    with torch.no_grad():
        a = model(batch).selected_slot.clone()
        b = model(batch).selected_slot.clone()
    assert torch.equal(a, b)


# ------------------------------------------------------------- F0-12/13
def test_f0_12_comparability_contract() -> None:
    from python_jev.feasibility.benchmark import (
        BENCHMARK_V1_VERSION,
        scenario_comparability,
    )

    assert BENCHMARK_V1_VERSION == "closed-loop-benchmark-v0.1.0"
    for mission in ("destroy_all_red", "capture_capital", "survive_turns", "hold_hq"):
        c = scenario_comparability({"mission_contract": {"primary_objective": mission}})
        assert c["same_seat_blue_terminal"] is True
        assert c["side_swapped_terminal"] is False
        assert c["side_swapped_terminal_benchmark"] == "INVALID"
    # unknown missions fail closed, never open
    c = scenario_comparability({"mission_contract": {"primary_objective": "nope"}})
    assert c["side_swapped_terminal"] is False


def test_f0_13_v1_battle_reports_full_metrics_without_red_win_claims() -> None:
    from python_jev.feasibility.benchmark import run_v1_battle, summarize_v1
    from python_jev.training.scenarios import generate_scenario
    from python_sim.policies import HoldPolicy

    scenario = generate_scenario(0)["scenario"]
    b = run_v1_battle(scenario, "DEV_FLAT_ALL_INFO", HoldPolicy(), HoldPolicy(),
                      max_turns=2, seed=scenario["seed"])
    for key in ("mission_progress_delta_blue", "mission_progress_delta_red",
                "objective_progress_delta_blue", "exchange_blue_view",
                "blue_hq_alive", "red_hq_alive", "mission_status",
                "mission_progress_turn_normalized_blue"):
        assert key in b, key
    s = summarize_v1([b])
    assert "victory_rate_blue" in s  # blue-seat terminal claims are valid
    assert "jev_victory_rate" not in s  # no side-swapped win-rate vocabulary
    assert "red_victory_rate" not in s


# ----------------------------------------------------------------- F0-14
def test_f0_14_frozen_epsilon_metric_intact() -> None:
    from python_jev.training import evaluate

    assert evaluate.EPSILON_OPTIMAL_VERSION == "epsilon-optimal-v0.1.0"
    assert evaluate.Q_EPSILON == 0.25


def test_f0_14_tighter_epsilons_are_monotone_and_discriminating() -> None:
    from python_jev.feasibility.epsilon_audit import CANDIDATE_EPSILONS, epsilon_rates

    assert tuple(CANDIDATE_EPSILONS) == (0.005, 0.01, 0.02, 0.05)
    # synthetic rows: model picks slot 0 always; regret 0.03 on row 0, 0.0 on row 1
    rows = {
        "raw": torch.zeros(2, 6),
        "q": torch.tensor([[0.07, 0.10, 0.0, -0.1, -0.2, -0.3],
                           [0.05, 0.05, 0.0, -0.1, -0.2, -0.3]]),
        "q_valid": torch.ones(2, 6, dtype=torch.bool),
        "sel": torch.tensor([0, 0]),
    }
    rates = epsilon_rates(rows)
    assert rates["0.005"] == 0.5
    assert rates["0.05"] == 1.0
    assert rates["0.25"] == 1.0
    assert rates["q_gap_distribution"]["median"] > 0.0


# ----------------------------------------------------------------- F0-15
def test_f0_15_sensitivity_math_reference_values() -> None:
    from python_jev.feasibility.sensitivity import PAIRS, POLICIES, _spearman

    assert len(POLICIES) == 3 and len(PAIRS) == 3
    assert abs(_spearman([1.0, 2.0, 3.0], [1.0, 2.0, 3.0]) - 1.0) < 1e-9
    assert abs(_spearman([1.0, 2.0, 3.0], [3.0, 2.0, 1.0]) + 1.0) < 1e-9
    import math

    assert math.isnan(_spearman([1.0, 1.0, 1.0], [1.0, 2.0, 3.0]))


# ------------------------------------------------------------- F0-19/20
def test_f0_19_no_training_anywhere_in_feasibility_scope() -> None:
    files = list((ROOT / "python_jev" / "feasibility").rglob("*.py")) + [
        ROOT / "python_sim" / "skills" / "candidates.py",
        ROOT / "python_sim" / "skills" / "preflight.py",
    ]
    assert len(files) >= 8
    for p in files:
        src = p.read_text(encoding="utf-8")
        for banned in (".backward(", "torch.optim", "Optimizer(", "optimizer =",
                       "selfplay", "self_play", "policy_gradient", "PPO(",
                       "DQN(", "REINFORCE", "CrossEntropyLoss", "MSELoss",
                       "torch.save", "save_checkpoint", "save_shard",
                       "lr_scheduler", ".step()"):
            assert banned not in src, f"{p.name} mentions {banned!r}"


def test_f0_20_no_gameplay_or_godot_rewrite_markers() -> None:
    hits = []
    for pat in ("scripts/**/*.gd", "scenes/**/*.tscn"):
        for p in ROOT.glob(pat):
            try:
                src = p.read_text(encoding="utf-8")
            except (UnicodeDecodeError, OSError):
                continue
            for token in ("SkillPreflight", "skill_preflight", "closed-loop-benchmark",
                          "jev-feasibility", "skill-candidates"):
                if token in src:
                    hits.append((str(p), token))
    assert hits == []
