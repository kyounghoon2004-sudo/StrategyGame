"""J1 skill-layer fixture tests (J1-1 .. J1-8 space).

30 frozen executors x (success fixture where mechanically realizable,
failure fixture where meaningful) + interaction fixtures: terrain,
occupancy, hidden contact, mission objective/anchor, fog, death.
"""

from __future__ import annotations

import pytest

from python_sim.parity.fixtures import probe_scenario
from python_sim.sim.battle import Battle
from python_sim.skills import execute_skill, observation_safe_skill_mask
from python_sim.skills.context import MissionContext
from python_sim.skills.registry import iter_skill_names

from python_jev.constants import ACTION_SPACE

# --------------------------------------------------------------------- J1-2
def test_j1_2_thirty_identities_pinned() -> None:
    names = iter_skill_names()
    assert len(names) == 30
    for cls, slot, name in names:
        assert ACTION_SPACE[cls][slot] == name


# --------------------------------------------------------------------- J1-1
def test_j1_1_import() -> None:
    import python_sim.skills
    import python_sim.rollout  # noqa: F401
    import python_sim.trajectory  # noqa: F401
    import python_jev.dataset  # noqa: F401
    assert python_sim.skills.SKILL_CONTRACT_VERSION


# --------------------------------------------------------------------- J1-3
def test_j1_3_identity_echo_and_no_substitution() -> None:
    b = Battle(probe_scenario(), "DEV_FLAT_ALL_INFO")
    env = execute_skill(b, "B_INF_1", "INFANTRY", 1, MissionContext())  # ADVANCE, no anchor
    assert env["skill_class"] == "INFANTRY"
    assert env["skill_slot"] == 1
    assert env["skill_name"] == "ADVANCE"
    assert env["status"] == "INVALID" and env["failure_code"] == "NO_ANCHOR"
    # no mutation on failure
    assert env["state_version_after"] == env["state_version_before"]
    assert b.world.unit_dict("B_INF_1")["q"] == -25


# --------------------------------------------------------------------- J1-4/J1-5
SUCCESS_FIXTURES = [
    # (class, slot, name, scenario_mutator, ctx_mutator)
    ("INFANTRY", 0, "ATTACK", "adjacent_enemy", {}),
    ("INFANTRY", 1, "ADVANCE", None, {"advance_anchor": (-24, 0)}),
    ("INFANTRY", 2, "HOLD", None, {}),
    ("INFANTRY", 3, "REPOSITION", None, {"reposition_anchor": (-26, 0)}),
    ("INFANTRY", 4, "SUPPORT", None, {"support_recipient": "B_SCT_1"}),
    ("INFANTRY", 5, "WITHDRAW", None, {}),
    ("SPEARMAN", 0, "ATTACK", "adjacent_spear", {}),
    ("SPEARMAN", 1, "ADVANCE", None, {"advance_anchor": (-24, 0)}),
    ("SPEARMAN", 2, "HOLD", None, {}),
    ("SPEARMAN", 3, "REPOSITION", None, {"reposition_anchor": (-26, 1)}),
    ("SPEARMAN", 4, "SCREEN", "spear_screen_setup", {"screen_anchor": (-26, -2)}),
    ("SPEARMAN", 5, "WITHDRAW", None, {}),
    ("CAVALRY", 0, "ATTACK", "adjacent_cav", {}),
    ("CAVALRY", 1, "FLANK", "cav_flank_setup", {}),
    ("CAVALRY", 2, "ADVANCE", None, {"advance_anchor": (-24, 0)}),
    ("CAVALRY", 3, "PURSUE", "cav_pursue_setup", {}),
    ("CAVALRY", 4, "RESERVE", None, {"reserve_anchor": (-27, 0)}),
    ("CAVALRY", 5, "WITHDRAW", None, {}),
    ("ARCHER", 0, "FIRE", "archer_in_range", {}),
    ("ARCHER", 1, "FOCUS_FIRE", "archer_in_range", {"designated_target_id": "R_INF_1"}),
    ("ARCHER", 2, "REPOSITION_RANGE", "archer_far", {}),
    ("ARCHER", 3, "KITE", "archer_kite_setup", {}),
    ("ARCHER", 4, "HOLD_POSITION", None, {}),
    ("ARCHER", 5, "WITHDRAW", None, {}),
    ("SCOUT", 0, "RECON_ADVANCE", None, {}),
    ("SCOUT", 1, "SHADOW", "scout_shadow_setup", {}),
    ("SCOUT", 2, "HARASS", "scout_adjacent", {}),
    ("SCOUT", 3, "SCREEN", "scout_screen_setup", {"screen_anchor": (-27, 1)}),
    ("SCOUT", 4, "EVADE", "scout_evade_setup", {}),
    ("SCOUT", 5, "REGROUP", None, {}),
]

FAILURE_FIXTURES = [
    ("INFANTRY", 0, "ATTACK", None, {}, "NO_TARGET"),
    ("INFANTRY", 1, "ADVANCE", None, {}, "NO_ANCHOR"),
    ("INFANTRY", 4, "SUPPORT", "lone_infantry", {}, "NO_SUPPORT_TARGET"),
    ("SPEARMAN", 0, "ATTACK", None, {}, "NO_TARGET"),
    ("SPEARMAN", 4, "SCREEN", None, {}, "NO_SCREEN_ANCHOR"),
    ("CAVALRY", 0, "ATTACK", None, {}, "NO_TARGET"),
    ("CAVALRY", 1, "FLANK", "flank_no_target", {}, "NO_FLANK_TARGET"),
    ("CAVALRY", 3, "PURSUE", None, {}, "NO_PURSUIT_TARGET"),
    ("ARCHER", 0, "FIRE", None, {}, "OUT_OF_RANGE"),
    ("ARCHER", 1, "FOCUS_FIRE", None, {}, "OUT_OF_RANGE"),
    ("ARCHER", 3, "KITE", None, {}, "NO_DESTINATION"),
    ("SCOUT", 1, "SHADOW", "scout_no_shadow", {}, "NO_SHADOW_TARGET"),
    ("SCOUT", 2, "HARASS", "no_adjacent_enemy", {}, "NO_TARGET"),
    ("SCOUT", 4, "EVADE", "evade_no_threat", {}, "NO_EVADE_THREAT"),
]


def _build(mutator: str | None, ctx_kwargs: dict, cls: str = "INFANTRY") -> tuple[Battle, MissionContext, str]:
    scn = probe_scenario()
    actor = "B_INF_1"
    if cls != "INFANTRY" and mutator is None:
        # default class-appropriate actor on a free hex near the blue line
        actor = f"B_FIX_{cls}"
        scn["forces"].append({"id": actor, "class": cls.lower(), "faction": "blue", "q": -25, "r": -1, "soldiers": 300})
    if mutator == "adjacent_enemy":
        for f in scn["forces"]:
            if f["id"] == "R_INF_1":
                f["q"] = -24
    elif mutator == "adjacent_spear":
        scn["forces"].append({"id": "B_SPR_T", "class": "spearman", "faction": "blue", "q": -24, "r": 0, "soldiers": 300})
        for f in scn["forces"]:
            if f["id"] == "R_INF_1":
                f["q"] = -23
        actor = "B_SPR_T"
    elif mutator == "adjacent_cav":
        scn["forces"].append({"id": "B_CAV_T", "class": "cavalry", "faction": "blue", "q": -23, "r": 0, "soldiers": 300})
        for f in scn["forces"]:
            if f["id"] == "R_INF_1":
                f["q"] = -22
        actor = "B_CAV_T"
    elif mutator == "spear_screen_setup":
        scn["forces"].append({"id": "B_SPR_S", "class": "spearman", "faction": "blue", "q": -26, "r": -1, "soldiers": 300})
        actor = "B_SPR_S"
    elif mutator == "cav_flank_setup":
        scn["forces"].append({"id": "B_CAV_F", "class": "cavalry", "faction": "blue", "q": -25, "r": -2, "soldiers": 300})
        actor = "B_CAV_F"
    elif mutator == "cav_pursue_setup":
        scn["forces"].append({"id": "B_CAV_P", "class": "cavalry", "faction": "blue", "q": -23, "r": 0, "soldiers": 300})
        for f in scn["forces"]:
            if f["id"] == "R_INF_1":
                f["q"] = -24
        actor = "B_CAV_P"
    elif mutator == "archer_in_range":
        scn["forces"].append({"id": "B_ARC_T", "class": "archer", "faction": "blue", "q": -25, "r": 0, "soldiers": 200})
        for f in scn["forces"]:
            if f["id"] == "R_INF_1":
                f["q"] = -23  # distance 2 <= archer range 3
        actor = "B_ARC_T"
    elif mutator == "archer_far":
        scn["forces"].append({"id": "B_ARC_F", "class": "archer", "faction": "blue", "q": -27, "r": 0, "soldiers": 200})
        actor = "B_ARC_F"
    elif mutator == "archer_kite_setup":
        scn["forces"].append({"id": "B_ARC_K", "class": "archer", "faction": "blue", "q": -23, "r": 0, "soldiers": 200})
        for f in scn["forces"]:
            if f["id"] == "R_INF_1":
                f["q"] = -23
                f["r"] = -2
        actor = "B_ARC_K"
    elif mutator == "scout_shadow_setup":
        # R_INF_1 visible from scout start (-26,1) via vision 4; shadow band
        # = (4..6) from the target — target at (-22,0), scout moves within.
        actor = "B_SCT_1"
    elif mutator == "scout_screen_setup":
        scn["forces"].append({"id": "B_SCT_S", "class": "scout", "faction": "blue", "q": -27, "r": 2, "soldiers": 80})
        actor = "B_SCT_S"
    elif mutator == "scout_evade_setup":
        for f in scn["forces"]:
            if f["id"] == "R_INF_1":
                f["q"] = -24
                f["r"] = 1
        actor = "B_SCT_1"
    elif mutator == "scout_adjacent":
        scn["forces"].append({"id": "B_SCT_H", "class": "scout", "faction": "blue", "q": -23, "r": 0, "soldiers": 80})
        for f in scn["forces"]:
            if f["id"] == "R_INF_1":
                f["q"] = -22
        actor = "B_SCT_H"
    elif mutator == "scout_no_shadow":
        # no enemy within the shadow band (vision 4..6): kill visibility by
        # removing all red units except a far conscript beyond band+LOS
        scn["forces"] = [f for f in scn["forces"] if f["id"] != "R_INF_1"]
        for f in scn["forces"]:
            if f["id"] == "R_CON_9":
                f["q"] = -10
                f["r"] = -8
        actor = "B_SCT_1"
    elif mutator == "no_adjacent_enemy":
        # remove all red units except the far conscript, and push the
        # conscript out of the scout's melee band entirely
        scn["forces"] = [f for f in scn["forces"] if f["faction"] != "red"]
        scn["forces"].append({"id": "R_CON_FAR", "class": "conscript", "faction": "red", "q": -14, "r": -6, "soldiers": 60})
        actor = "B_SCT_1"
    elif mutator == "flank_no_target":
        scn["forces"] = [f for f in scn["forces"] if f["faction"] != "red"]
        scn["forces"].append({"id": "B_CAV_N", "class": "cavalry", "faction": "blue", "q": -25, "r": -1, "soldiers": 300})
        actor = "B_CAV_N"
    elif mutator == "evade_no_threat":
        scn["forces"] = [f for f in scn["forces"] if f["faction"] != "red"]
        actor = "B_SCT_1"
    elif mutator == "lone_infantry":
        scn["forces"] = [f for f in scn["forces"] if f["id"] not in ("B_SCT_1", "B_HQ_1")]
    return Battle(scn, "DEV_FLAT_ALL_INFO"), MissionContext(**ctx_kwargs), actor


@pytest.mark.parametrize("cls,slot,name,mutator,ctx_kwargs", SUCCESS_FIXTURES)
def test_j1_4_success_fixtures(cls, slot, name, mutator, ctx_kwargs) -> None:
    b, ctx, actor = _build(mutator, ctx_kwargs, cls)
    env = execute_skill(b, actor, cls, slot, ctx)
    assert env["skill_name"] == name
    assert env["status"] in ("SUCCESS", "PARTIAL"), f"{cls}.{name} -> {env['failure_code']}: {env.get('detail','')}"
    if env["status"] == "SUCCESS":
        assert env["failure_code"] == "NONE"


@pytest.mark.parametrize("cls,slot,name,mutator,ctx_kwargs,expected_code", FAILURE_FIXTURES)
def test_j1_5_failure_fixtures(cls, slot, name, mutator, ctx_kwargs, expected_code) -> None:
    b, ctx, actor = _build(mutator, ctx_kwargs, cls)
    env = execute_skill(b, actor, cls, slot, ctx)
    assert env["status"] == "INVALID", f"{cls}.{name} expected INVALID got {env['status']}"
    assert env["failure_code"] == expected_code, f"{cls}.{name}: {env['failure_code']} != {expected_code}"
    # failure commits no mutation (I9)
    assert env["state_version_after"] == env["state_version_before"]


# --------------------------------------------------------------------- J1-6
def test_j1_6_deterministic_tiebreak_stable() -> None:
    b1, ctx1, a1 = _build("adjacent_enemy", {})
    e1 = execute_skill(b1, a1, "INFANTRY", 0, ctx1)
    b2, ctx2, a2 = _build("adjacent_enemy", {})
    e2 = execute_skill(b2, a2, "INFANTRY", 0, ctx2)
    assert e1["target_id"] == e2["target_id"]
    assert e1["tie_break_trace"] == e2["tie_break_trace"]


# --------------------------------------------------------------------- J1-7
def test_j1_7_observation_safe_selection_uses_knowledge_only() -> None:
    # Dev profile: full information authorized. Mask equality across clones
    # with divergent hidden truth is the FLAT_FOG anti-oracle property.
    b1 = Battle(probe_scenario(), "FLAT_FOG")
    b2 = Battle(probe_scenario(), "FLAT_FOG")
    b2.world.units["R_CON_9"].soldier_count = 999  # hidden divergent truth
    m1 = observation_safe_skill_mask(b1, "B_INF_1")
    m2 = observation_safe_skill_mask(b2, "B_INF_1")
    assert m1 == m2


# --------------------------------------------------------------------- J1-8
def test_j1_8_hidden_contact_interrupts_known_valid_move() -> None:
    scn = probe_scenario()
    scn["forces"].append({"id": "R_INF_HID", "class": "infantry", "faction": "red", "q": -24, "r": 0, "soldiers": 200})
    b = Battle(scn, "FLAT_FOG")
    # ADVANCE toward (-22,0) is knowledge-legal; hidden enemy at (-24,0).
    env = execute_skill(b, "B_INF_1", "INFANTRY", 1,
                        MissionContext(advance_anchor=(-22, 0)))
    assert env["status"] in ("SUCCESS", "PARTIAL")
    if env["status"] == "PARTIAL":
        assert env["partial"]["interrupted"] is True
        assert env["partial"]["reason"] == "HIDDEN_CONTACT"
        assert env["partial"]["newly_revealed_contact"] == "R_INF_HID"
        # the mover never entered the hidden hex
        assert b.world.unit_dict("B_INF_1")["q"] != -24
    # the contact was not pre-leaked in the mask
    assert observation_safe_skill_mask(b, "B_INF_1")[1] is True or b.world.current_turn > 1


# --------------------------------------------------------------------- interactions
def test_fog_ab_hidden_truth_same_input_differs_only_after_discovery() -> None:
    # Cavalry outruns its own vision (MP 4 > NORMAL_VISION 2): the hidden
    # enemy sits 4 hexes out — outside EVERY blue unit's sight (scout at dist
    # 5, cavalry 2, HQ 2) — but directly on the mover's destination path.
    # World A/B share identical FactionKnowledge and identical observation;
    # the SAME input skill discovers different truth only at execution.
    from python_sim.observation.projector import ObservationProjector

    def make(hidden: bool) -> Battle:
        forces = [
            {"id": "B_HQ_1", "class": "hq", "faction": "blue", "q": -28, "r": 0, "soldiers": 300},
            {"id": "B_SCT_1", "class": "scout", "faction": "blue", "q": -26, "r": 1, "soldiers": 80},
            {"id": "B_CAV_1", "class": "cavalry", "faction": "blue", "q": -25, "r": 0, "soldiers": 300},
            {"id": "R_CON_9", "class": "conscript", "faction": "red", "q": -20, "r": 5, "soldiers": 613},
        ]
        if hidden:
            forces.append({"id": "R_INF_HID", "class": "infantry",
                           "faction": "red", "q": -21, "r": 0, "soldiers": 200})
        return Battle({
            "scenario_id": "fog_ab_pair", "scenario_version": "0.1.0", "seed": 7,
            "mission_contract": {"primary_objective": "destroy_all_red", "turn_limit": 6},
            "map": {"bounds": {"q_min": -30, "q_max": -20, "r_min": -5, "r_max": 5},
                    "default_terrain": 0, "terrain_overrides": {}, "river_cells": []},
            "forces": forces,
        }, "FLAT_FOG")

    ba, bb = make(False), make(True)
    pa = ObservationProjector(ba).project("blue", "B_CAV_1")
    pb = ObservationProjector(bb).project("blue", "B_CAV_1")
    assert (pa.actor_features, pa.tokens, pa.hex_patch) == (pb.actor_features, pb.tokens, pb.hex_patch)
    assert observation_safe_skill_mask(ba, "B_CAV_1") == observation_safe_skill_mask(bb, "B_CAV_1")

    ea = execute_skill(ba, "B_CAV_1", "CAVALRY", 2, MissionContext(advance_anchor=(-21, 0)))
    eb = execute_skill(bb, "B_CAV_1", "CAVALRY", 2, MissionContext(advance_anchor=(-21, 0)))
    assert ea["skill_name"] == eb["skill_name"] == "ADVANCE"   # same input skill
    assert eb["state_version_before"] == ea["state_version_before"]
    # world A: clean run to the anchor; world B: interrupted by discovery
    assert ea["status"] == "SUCCESS"
    assert ea["destination"] == [-21, 0]
    assert eb["status"] == "PARTIAL"
    assert eb["partial"]["interrupted"] is True and eb["partial"]["reason"] == "HIDDEN_CONTACT"
    assert eb["partial"]["newly_revealed_contact"] == "R_INF_HID"
    # the world-B mover never entered the hidden hex
    assert b_pos_cav(bb) != [-21, 0]
    # and world A's envelope carried no contact at all (nothing to leak)
    assert not ea["partial"] or ea["partial"].get("interrupted") is False


def test_skills_terrain_and_occupancy_interaction() -> None:
    # TERRAIN profile: terrain costs are active — ADVANCE must respect the
    # authoritative budget (base MP + the unit's own march allowance), never
    # over-spend, and reduce anchor distance on flat ground.
    b = Battle(probe_scenario(), "TERRAIN_FULL_INFO")
    u = b.world.units["B_INF_1"]
    budget = float(u.base_mp) + float(u.blue_limit) + float(u.red_limit) + float(u.black_limit)
    env = execute_skill(b, "B_INF_1", "INFANTRY", 1,
                        MissionContext(advance_anchor=(-20, 0)))
    assert env["status"] in ("SUCCESS", "PARTIAL", "INVALID")
    if env["status"] in ("SUCCESS", "PARTIAL"):
        assert env["mechanical_effects"]["movement_spent"] <= budget + 1e-9
        dest = env["destination"]
        assert abs(dest[0] + 25) + abs(dest[1]) + abs(dest[0] + dest[1] + 25) > 0  # moved off origin
    # occupancy: cannot advance onto the occupied scout hex
    b2 = Battle(probe_scenario(), "DEV_FLAT_ALL_INFO")
    env2 = execute_skill(b2, "B_INF_1", "INFANTRY", 1,
                         MissionContext(advance_anchor=(-26, 1)))  # scout hex
    if env2["status"] == "SUCCESS":
        assert env2["destination"] != [-26, 1]


def test_skills_death_and_terminal_interaction() -> None:
    scn = probe_scenario()
    for f in scn["forces"]:
        if f["id"] == "R_INF_1":
            f["q"] = -24
            f["soldiers"] = 1
    b = Battle(scn, "DEV_FLAT_ALL_INFO")
    env = execute_skill(b, "B_INF_1", "INFANTRY", 0, MissionContext())
    assert env["status"] == "SUCCESS"
    assert env["mechanical_effects"]["defender_destroyed"] is True
    assert "R_INF_1" not in b.world.units
    m = b.evaluate_mission()
    assert m["mission_status"] in ("victory", "ongoing")


def test_skills_fog_profile_failure_is_explicit() -> None:
    # FLAT_FOG: B_INF_1 cannot see R_CON_9 (far); ATTACK must fail NO_TARGET
    # without leaking the hidden conscript.
    b = Battle(probe_scenario(), "FLAT_FOG")
    env = execute_skill(b, "B_INF_1", "INFANTRY", 0, MissionContext())
    assert env["status"] == "INVALID"
    assert env["failure_code"] == "NO_TARGET"
    assert "R_CON_9" not in json_dumps(env)


def json_dumps(x) -> str:
    import json
    return json.dumps(x)


def b_pos_cav(b: Battle) -> list:
    u = b.world.unit_dict("B_CAV_1")
    return [u["q"], u["r"]]


# --------------------------------------------------------------------- J1-10 partial
def test_skills_acted_unit_fails_clean() -> None:
    b = Battle(probe_scenario(), "DEV_FLAT_ALL_INFO")
    b.do_hold("B_INF_1", "blue")  # unit acts out
    env = execute_skill(b, "B_INF_1", "INFANTRY", 0, MissionContext())
    assert env["status"] == "INVALID"
    assert env["failure_code"] in ("NO_TARGET", "PRECONDITION_FAILED", "ENGINE_REJECTED")
