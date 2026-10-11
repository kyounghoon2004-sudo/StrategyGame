"""F0 gates — SkillPreflightV0 + shared mechanical candidate semantics.

Fast, torch-free. Covers F0-2 (30/30 auditable semantics), F0-3 (no tactical
scoring), F0-4 (shared resolver reuse), F0-5 (full-info invariant), F0-6
(fog anti-leak). No training, no Godot, no dataset writes.
"""

from __future__ import annotations

import copy
import json
import pathlib

from python_jev.constants import ACTION_SPACE
from python_sim.parity.fixtures import probe_scenario
from python_sim.sim.battle import Battle
from python_sim.skills import candidates, observation_safe_skill_mask_v2
from python_sim.skills import preflight as PF
from python_sim.skills.context import MissionContext
from python_sim.skills.contracts import FailureCode
from python_sim.skills.registry import execute_skill, iter_skill_names

ROOT = pathlib.Path(__file__).resolve().parents[2]
CLS_LOWER = {"INFANTRY": "infantry", "SPEARMAN": "spearman", "CAVALRY": "cavalry",
             "ARCHER": "archer", "SCOUT": "scout"}


def _rich_ctx() -> MissionContext:
    # Declared anchors only (deployment-geometry style); exercises every
    # anchor-dependent skill without hidden-state invention.
    return MissionContext(scenario_id="f0", primary_objective="destroy_all_red",
                          turn_limit=12, advance_anchor=(-22, 0),
                          reposition_anchor=(-26, 0), withdraw_anchor=(-28, 0),
                          reserve_anchor=(-28, 1), regroup_anchor=(-26, 1),
                          screen_anchor=(-24, 0), recon_waypoint=(-20, 0))


def _sample_battles() -> list[tuple[Battle, MissionContext]]:
    from python_jev.training.scenarios import generate_scenario, mission_context_for_side

    out = []
    for idx, profile in ((0, "DEV_FLAT_ALL_INFO"), (1, "TERRAIN_FULL_INFO"),
                         (5, "DEV_FLAT_ALL_INFO"), (6, "TERRAIN_FULL_INFO")):
        gen = generate_scenario(idx)["scenario"]
        battle = Battle(json.loads(json.dumps(gen)), profile, seed=gen["seed"])
        out.append((battle, MissionContext(**mission_context_for_side(gen, "blue"))))
    out.append((Battle(probe_scenario(), "DEV_FLAT_ALL_INFO"), _rich_ctx()))
    return out


def _learned_actors(battle: Battle) -> list[tuple[str, str]]:
    out = []
    for u in battle.world.units.values():
        if u.unit_class in CLS_LOWER.values() and u.soldier_count > 0 and not u.garrisoned:
            upper = {v: k for k, v in CLS_LOWER.items()}[u.unit_class]
            out.append((u.id, upper))
    return out


# ------------------------------------------------------------------ F0-2
def test_f0_2_thirty_identities_have_preflight_semantics() -> None:
    assert len(PF._RESOLVERS) == 30
    for cls, slot, name in iter_skill_names():
        assert (cls, slot) in PF._RESOLVERS
        assert PF._RESOLVERS[(cls, slot)][1] == name == ACTION_SPACE[cls][slot]


def test_f0_2_preflight_results_are_typed_and_tagged() -> None:
    codes = {c.value for c in FailureCode}
    checked = 0
    for battle, ctx in _sample_battles():
        for actor_id, cls in _learned_actors(battle):
            for slot in range(6):
                r = PF.skill_preflight(battle, actor_id, ctx, cls, slot)
                assert isinstance(r, PF.PreflightResult)
                assert r.reason_code in codes
                assert r.candidate_count >= 0
                if r.executable:
                    assert r.reason_code == FailureCode.NONE.value
                    assert r.candidate_count >= 1
                    assert r.sub == ""
                else:
                    assert r.candidate_count == 0
                    assert r.sub != "", f"untagged failure {cls}:{slot} {r.reason_code}"
                checked += 1
    assert checked > 100
    mask = observation_safe_skill_mask_v2(battle, actor_id, ctx)
    assert len(mask) == 6 and all(isinstance(x, bool) for x in mask)


def test_f0_2_preflight_is_pure() -> None:
    battle = Battle(probe_scenario(), "DEV_FLAT_ALL_INFO")
    ctx = _rich_ctx()
    v0, f0 = battle.world.state_version, battle.fingerprint()
    for actor_id, cls in _learned_actors(battle):
        for slot in range(6):
            PF.skill_preflight(battle, actor_id, ctx, cls, slot)
        observation_safe_skill_mask_v2(battle, actor_id, ctx)
    assert battle.world.state_version == v0
    assert battle.fingerprint() == f0


# ------------------------------------------------------------------ F0-3
def test_f0_3_no_tactical_scoring_soldier_scaling_invariant() -> None:
    # Tripling every soldier count changes every matchup but no mechanical
    # predicate: all preflight bits must be identical (the behavioral proof
    # that preflight scores no tactics).
    for battle, ctx in _sample_battles():
        actors = _learned_actors(battle)
        before = {(a, c, s): PF.skill_preflight(battle, a, ctx, c, s).executable
                  for a, c in actors for s in range(6)}
        scaled = battle.clone()
        for u in scaled.world.units.values():
            u.soldier_count *= 3
        for a, c in actors:
            for s in range(6):
                after = PF.skill_preflight(scaled, a, ctx, c, s).executable
                assert after == before[(a, c, s)], (a, c, s)


def test_f0_3_preflight_sources_contain_no_tactical_or_ml_logic() -> None:
    for name in ("candidates.py", "preflight.py"):
        src = (ROOT / "python_sim" / "skills" / name).read_text(encoding="utf-8")
        for banned in ("torch", "softmax", "reward", "danger", "matchup", "utility",
                       "heurist", "q_value", "expected_value", "advantage",
                       "self_play", "selfplay", "backward", "optim", "score"):
            assert banned not in src, f"skills/{name} mentions {banned!r}"


# ------------------------------------------------------------------ F0-4
def test_f0_4_executors_and_preflight_share_candidate_module() -> None:
    for name in ("infantry.py", "spearman.py", "cavalry.py", "archer.py",
                 "scout.py", "preflight.py"):
        src = (ROOT / "python_sim" / "skills" / name).read_text(encoding="utf-8")
        assert ("from python_sim.skills.candidates import" in src
                or "from python_sim.skills import candidates" in src), name
    # every dispatched resolver lives in the shared module (or is a thin
    # local wrapper over it).
    for (cls, slot), (fn, _name) in PF._RESOLVERS.items():
        mod = getattr(fn, "__module__", "")
        assert mod in ("python_sim.skills.candidates", "python_sim.skills.preflight"), (cls, slot)


# ------------------------------------------------------------------ F0-5
def test_f0_5_full_info_preflight_true_implies_executor_not_invalid() -> None:
    n_legal = n_invalid = 0
    for battle, ctx in _sample_battles():
        for actor_id, cls in _learned_actors(battle):
            for slot in range(6):
                pf = PF.skill_preflight(battle, actor_id, ctx, cls, slot)
                env = execute_skill(battle.clone(), actor_id, cls, slot, ctx)
                if pf.executable:
                    n_legal += 1
                    assert env["status"] != "INVALID", (
                        cls, slot, env.get("failure_code"), pf.reason_code)
                else:
                    # both directions: shared semantics means exact agreement
                    assert env["status"] == "INVALID", (cls, slot, env["status"])
                    n_invalid += 1
    assert n_legal > 50 and n_invalid > 20


def test_f0_5_mask_v2_agrees_with_trial_execution() -> None:
    battle = Battle(probe_scenario(), "DEV_FLAT_ALL_INFO")
    ctx = _rich_ctx()
    for actor_id, cls in _learned_actors(battle):
        mask = observation_safe_skill_mask_v2(battle, actor_id, ctx)
        for slot in range(6):
            env = execute_skill(battle.clone(), actor_id, cls, slot, ctx)
            assert mask[slot] == (env["status"] != "INVALID"), (cls, slot)


# ------------------------------------------------------------------ F0-6
def test_f0_6_preflight_is_fog_safe_under_divergent_hidden_truth() -> None:
    b1 = Battle(probe_scenario(), "FLAT_FOG")
    b2 = Battle(probe_scenario(), "FLAT_FOG")
    b2.world.units["R_CON_9"].soldier_count = 999  # hidden divergent truth
    ctx = MissionContext(advance_anchor=(-22, 0))
    assert (observation_safe_skill_mask_v2(b1, "B_INF_1", ctx)
            == observation_safe_skill_mask_v2(b2, "B_INF_1", ctx))


def test_f0_6_hidden_contact_keeps_preflight_true_and_never_invalid_by_oracle() -> None:
    scn = probe_scenario()
    scn["forces"].append({"id": "R_INF_HID", "class": "infantry", "faction": "red",
                          "q": -24, "r": 0, "soldiers": 200})
    b = Battle(copy.deepcopy(scn), "FLAT_FOG")
    ctx = MissionContext(advance_anchor=(-22, 0))
    # knowledge-legal ADVANCE: preflight must NOT peek at the hidden blocker
    assert PF.skill_preflight(b, "B_INF_1", ctx, "INFANTRY", 1).executable is True
    env = execute_skill(b, "B_INF_1", "INFANTRY", 1, ctx)
    assert env["status"] in ("SUCCESS", "PARTIAL")
    if env["status"] == "PARTIAL":
        assert env["partial"]["reason"] == "HIDDEN_CONTACT"


def test_f0_preflight_structural_guards() -> None:
    battle = Battle(probe_scenario(), "DEV_FLAT_ALL_INFO")
    ctx = _rich_ctx()
    assert observation_safe_skill_mask_v2(battle, "NO_SUCH_UNIT", ctx) == [False] * 6
    assert observation_safe_skill_mask_v2(battle, "B_HQ_1", ctx) == [False] * 6
    u = battle.world.units["B_INF_1"]
    u.action_ended = True
    assert observation_safe_skill_mask_v2(battle, "B_INF_1", ctx) == [False] * 6
    r = PF.skill_preflight(battle, "B_INF_1", ctx, "SCOUT", 0)
    assert r.executable is False  # class mismatch, not substitution
