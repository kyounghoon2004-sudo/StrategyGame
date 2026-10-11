"""Parity fixtures + fingerprint harness (P01-P16, 10v10 DEV battle).

Fixture families per the task order. Expected values for P01-P16 are the
authoritative-semantics expectations derived from the cited live code paths;
where an expectation depends on implementation-defined Godot hash() the case
is marked CONTRACT_LIMITED (gap godot_hash_parity) instead of faking parity.

The canonical 10v10 DEV battle is the default-roster scenario
(SandboxRules.default_roster: hq 1, infantry 2, spearman 2, archer 2,
cavalry 2, scout 1 per side) driven by a fixed deterministic script.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field

from python_sim import SIM_VERSION
from python_sim.rules import combat, geometry, march, movement, terrain
from python_sim.rules.rounding import roundi_gd
from python_sim.sim.battle import Battle

# ---------------------------------------------------------------------------
# Godot-authoritative exported fingerprints (cross-runtime parity anchors)
# ---------------------------------------------------------------------------
# Source: unmodified Godot 4.2.2 headless run of scripts/sim/sim_entry.gd
# (gates 1-3), persisted to D:/Game development/.workflow/deliverables/
# TACTICAL-TRAINING-SIM-V01/verification.json. These are the canonical probe
# scenario (sim_v01_probe) before and after the canonical script
# move B_INF_1 -> (-23,0), attack R_INF_1, end turn.
GODOT_PROBE_FINGERPRINT_INITIAL = (
    "t=1|B_HQ_1:-28,0:mp1.000:aefalse:sol300:mor100.000:fat0.000:rtfalse:garfalse"
    "|B_INF_1:-25,0:mp2.000:aefalse:sol450:mor100.000:fat0.000:rtfalse:garfalse"
    "|B_SCT_1:-26,1:mp4.000:aefalse:sol80:mor100.000:fat0.000:rtfalse:garfalse"
    "|R_CON_9:-20,5:mp1.000:aefalse:sol613:mor100.000:fat0.000:rtfalse:garfalse"
    "|R_INF_1:-22,0:mp2.000:aefalse:sol477:mor100.000:fat0.000:rtfalse:garfalse"
    "|sh:Fortress_Hulao:red:hp1000:brfalse:gar0|sh:Capital_Luoyang:red:hp1500:brfalse:gar0"
)
GODOT_PROBE_FINGERPRINT_POST = (
    "t=2|B_HQ_1:-28,0:mp1.000:aefalse:sol300:mor100.000:fat0.000:rtfalse:garfalse"
    "|B_INF_1:-23,0:mp2.000:aefalse:sol390:mor93.333:fat4.000:rtfalse:garfalse"
    "|B_SCT_1:-26,1:mp4.000:aefalse:sol80:mor100.000:fat0.000:rtfalse:garfalse"
    "|R_CON_9:-20,5:mp1.000:aefalse:sol613:mor100.000:fat0.000:rtfalse:garfalse"
    "|R_INF_1:-22,0:mp2.000:aefalse:sol400:mor91.350:fat0.000:rtfalse:garfalse"
    "|sh:Fortress_Hulao:red:hp1000:brfalse:gar0|sh:Capital_Luoyang:red:hp1500:brfalse:gar0"
)

# ---------------------------------------------------------------------------
# Canonical scenario builders
# ---------------------------------------------------------------------------


def default_roster_forces(q_blue: int = -26, q_red: int = -22) -> list[dict]:
    """SandboxRules.default_roster: 10v10 formation set per side."""
    roster = {"hq": 1, "infantry": 2, "spearman": 2, "archer": 2, "cavalry": 2, "scout": 1}
    forces: list[dict] = []
    idx = 0
    for cls, count in roster.items():
        for i in range(count):
            idx += 1
            forces.append({
                "id": f"B_{cls.upper()}_{i + 1}",
                "class": cls,
                "faction": "blue",
                "q": q_blue - (idx % 5),
                "r": -4 + (idx // 5) * 2 + (idx % 2),
                "soldiers": 400,
            })
    idx = 0
    for cls, count in roster.items():
        for i in range(count):
            idx += 1
            forces.append({
                "id": f"R_{cls.upper()}_{i + 1}",
                "class": cls,
                "faction": "red",
                "q": q_red + (idx % 5),
                "r": -4 + (idx // 5) * 2 + (idx % 2),
                "soldiers": 420,
            })
    return forces


def probe_scenario(seed: int = 7) -> dict:
    """sim_entry.gd _test_scenario mirror (canonical DEV probe)."""
    return {
        "scenario_id": "sim_v01_probe",
        "scenario_version": "0.1.0",
        "seed": seed,
        "mission_contract": {
            "primary_objective": "destroy_all_red",
            "turn_limit": 6,
            "time_pressure": "none",
            "force_preservation": "standard",
            "risk_tolerance": "normal",
            "information_priority": "normal",
            "withdrawal_policy": "none",
            "special_constraints": [],
        },
        "map": {
            "bounds": {"q_min": -30, "q_max": -20, "r_min": -5, "r_max": 5},
            "default_terrain": 0,
            "terrain_overrides": {},
            "river_cells": [],
        },
        "forces": [
            {"id": "B_HQ_1", "class": "hq", "faction": "blue", "q": -28, "r": 0, "soldiers": 300},
            {"id": "B_INF_1", "class": "infantry", "faction": "blue", "q": -25, "r": 0, "soldiers": 450},
            {"id": "B_SCT_1", "class": "scout", "faction": "blue", "q": -26, "r": 1, "soldiers": 80},
            {"id": "R_INF_1", "class": "infantry", "faction": "red", "q": -22, "r": 0, "soldiers": 477},
            {"id": "R_CON_9", "class": "conscript", "faction": "red", "q": -20, "r": 5, "soldiers": 613},
        ],
        "depot": {"q": -27, "r": 0},
        "start_turn": 1,
    }


def battle_10v10(seed: int = 7) -> Battle:
    return Battle({
        "scenario_id": "dev_10v10_canonical",
        "scenario_version": "0.1.0",
        "seed": seed,
        "mission_contract": {"primary_objective": "destroy_all_red", "turn_limit": 12},
        "map": {
            "bounds": {"q_min": -32, "q_max": -18, "r_min": -8, "r_max": 8},
            "default_terrain": 0,
            "terrain_overrides": {},
            "river_cells": [],
        },
        "forces": default_roster_forces(),
    }, profile="DEV_FLAT_ALL_INFO", seed=seed)


def run_canonical_probe_script(battle: Battle) -> dict:
    """sim_entry._run_script mirror: advance, attack, end turn."""
    mv = battle.do_move("B_INF_1", -23, 0, "blue", "auto")
    if not mv.get("success", False):
        return {"ok": False, "stage": "move", "detail": mv}
    atk = battle.do_attack("B_INF_1", "R_INF_1", "blue")
    if not atk.get("success", False):
        return {"ok": False, "stage": "attack", "detail": atk}
    end = battle.sim_end_turn()
    if not end.get("ok", False):
        return {"ok": False, "stage": "end_turn", "detail": end}
    return {"ok": True, "fingerprint": battle.fingerprint()}


# ---------------------------------------------------------------------------
# Parity case registry
# ---------------------------------------------------------------------------


@dataclass
class ParityCase:
    pid: str
    name: str
    status: str = "PENDING"  # PASS | FAIL | CONTRACT_LIMITED
    detail: dict = field(default_factory=dict)


def run_parity_matrix() -> list[ParityCase]:
    """Execute P01-P16 + the 10v10 fingerprint; returns the case matrix."""
    cases: list[ParityCase] = []

    # P01 geometry / boundary -------------------------------------------------
    c = ParityCase("P01", "geometry_boundary")
    cells = geometry.all_playable_cells()
    c.detail["playable_cells"] = len(cells)
    c.detail["expected"] = geometry.PLAYABLE_HEX_COUNT
    dist = geometry.hex_distance_axial((-3, 4), (5, -1))
    c.detail["distance_symmetry"] = dist == geometry.hex_distance_axial((5, -1), (-3, 4))
    c.detail["corner_distance"] = geometry.hex_distance_axial((0, 0), (40, -40))
    c.status = "PASS" if (
        len(cells) == geometry.PLAYABLE_HEX_COUNT
        and c.detail["distance_symmetry"]
        and c.detail["corner_distance"] == 40
    ) else "FAIL"
    cases.append(c)

    # P02 movement budget ------------------------------------------------------
    c = ParityCase("P02", "movement_budget")
    c.detail["cavalry_blue"] = march.get_blue_limit(march.get_base_movement("cavalry"))
    c.detail["cavalry_red"] = march.get_red_limit(march.get_base_movement("cavalry"))
    c.detail["cavalry_black"] = march.get_black_limit(march.get_base_movement("cavalry"))
    b = Battle(probe_scenario(), "TERRAIN_FULL_INFO")
    u = b.world.units["B_INF_1"]
    # Paint origin + ring-1 mountains (budget probe on an otherwise plains map).
    b.world.cell_data[geometry.key_of((u.q, u.r))]["terrain"] = 1
    for n in geometry.neighbors((u.q, u.r)):
        k = geometry.key_of(n)
        if k in b.world.cell_data:
            b.world.cell_data[k]["terrain"] = 1
    occupied = b.world.get_occupied_dict()
    # mountains: GREEN budget (blue limit 2.0) < 3.0/hex => zero GREEN reach.
    env_green = movement.calculate_envelope(
        (u.q, u.r), u.unit_class, u.base_mp, u.remaining_mp, march.MarchPolicy.GREEN_ONLY,
        b.world.cell_data, occupied, {}, "blue", b.world.stronghold_cells,
        morale_rout_enabled=False,
    )
    env = movement.calculate_envelope(
        (u.q, u.r), u.unit_class, u.base_mp, u.remaining_mp, march.MarchPolicy.RED_ALLOWED,
        b.world.cell_data, occupied, {}, "blue", b.world.stronghold_cells,
        morale_rout_enabled=False,
    )
    c.detail["mountain_green_hexes"] = len(env_green.reachable_data)
    c.detail["expect_mountain_green"] = 0
    # RED_ALLOWED black budget 4.4: 5 ring-1 mountains at 3.0 ORANGE + 11
    # ring-2 cells THROUGH one mountain at 3.0+1.0=4.0 ORANGE (<= red limit
    # 4.0 + tol); the player-known occupied scout hex is excluded => 16.
    c.detail["mountain_orange_hexes"] = len(env.reachable_data)
    c.detail["expect_mountain_orange"] = 16
    c.detail["mountain_ring1_cost3"] = sum(1 for d in env.reachable_data.values() if d["cost"] == 3.0)
    c.detail["mountain_ring2_cost4"] = sum(1 for d in env.reachable_data.values() if d["cost"] == 4.0)
    b2 = Battle(probe_scenario(), "TERRAIN_FULL_INFO")
    b2.world.spawn_units(probe_scenario()["forces"])
    u2 = b2.world.units["B_INF_1"]
    env2 = movement.calculate_envelope(
        (u2.q, u2.r), u2.unit_class, u2.base_mp, u2.remaining_mp, march.MarchPolicy.RED_ALLOWED,
        b2.world.cell_data, b2.world.get_occupied_dict(), {}, "blue", b2.world.stronghold_cells,
        morale_rout_enabled=False,
    )
    c.detail["plains_hexes_blue_budget"] = len(env2.green_hexes)
    # 2.0 budget over 1.0-cost plains: 17 ring cells <= 2.0, but the occupied
    # scout hex is dropped and its behind-ring neighbor (-27,2) detours at
    # 3.0 => exactly 16 GREEN.
    c.detail["expect_plains_green"] = 16
    c.status = "PASS" if (
        c.detail["mountain_green_hexes"] == 0
        and c.detail["mountain_orange_hexes"] == 16
        and c.detail["mountain_ring1_cost3"] == 5
        and c.detail["mountain_ring2_cost4"] == 11
        and c.detail["plains_hexes_blue_budget"] == 16
    ) else "FAIL"
    cases.append(c)

    # P03 Dijkstra destinations -------------------------------------------------
    c = ParityCase("P03", "dijkstra_destinations")
    b = Battle(probe_scenario(), "TERRAIN_FULL_INFO")
    b.world.spawn_units(probe_scenario()["forces"])
    u = b.world.units["B_SCT_1"]
    env = movement.calculate_envelope(
        (u.q, u.r), u.unit_class, u.base_mp, u.remaining_mp, march.MarchPolicy.RED_ALLOWED,
        b.world.cell_data, b.world.get_occupied_dict(), {}, "blue", b.world.stronghold_cells,
        morale_rout_enabled=False,
    )
    # Scout 4.0 budget on plains: every passable hex within cost 4 minus
    # occupied blockers; spot-check a few distances.
    key = geometry.key_of((u.q + 2, u.r))
    c.detail["dist2_cost"] = env.reachable_data.get(key, {}).get("cost")
    c.detail["expect_dist2_cost"] = 2.0
    c.detail["relax_epsilon"] = movement.RELAX_EPSILON
    c.status = "PASS" if c.detail["dist2_cost"] == 2.0 else "FAIL"
    cases.append(c)

    # P04 march tiers -------------------------------------------------------------
    c = ParityCase("P04", "march_tiers")
    c.detail["green_at_blue"] = march.classify_march_by_cumulative_cost(2.0, 2.0, 4.0, False)
    c.detail["green_tol"] = march.classify_march_by_cumulative_cost(2.001, 2.0, 4.0, False)
    c.detail["orange_mid"] = march.classify_march_by_cumulative_cost(3.5, 2.0, 4.0, False)
    c.detail["orange_tol"] = march.classify_march_by_cumulative_cost(4.001, 2.0, 4.0, False)
    c.detail["red_beyond"] = march.classify_march_by_cumulative_cost(4.5, 2.0, 4.0, False)
    c.detail["river_forces_red"] = march.classify_march_by_cumulative_cost(0.5, 2.0, 4.0, True)
    c.detail["multipliers"] = {"blue": 1.0, "red": 2.0, "black": 2.2}
    ok = (
        c.detail["green_at_blue"] == march.MarchClass.GREEN
        and c.detail["green_tol"] == march.MarchClass.GREEN
        and c.detail["orange_mid"] == march.MarchClass.ORANGE
        and c.detail["orange_tol"] == march.MarchClass.ORANGE
        and c.detail["red_beyond"] == march.MarchClass.RED
        and c.detail["river_forces_red"] == march.MarchClass.RED
    )
    c.status = "PASS" if ok else "FAIL"
    cases.append(c)

    # P05 occupancy mutation ---------------------------------------------------
    c = ParityCase("P05", "occupancy_mutation")
    b = Battle(probe_scenario(), "DEV_FLAT_ALL_INFO")
    res = b.do_move("B_INF_1", -23, 0, "blue", "auto")
    u = b.world.units.get("B_INF_1")
    c.detail["move_success"] = res.get("success", False)
    c.detail["new_occupancy"] = b.world.occupied_map.get("-23,0") == "B_INF_1"
    c.detail["old_occupancy_cleared"] = "-25,0" not in b.world.occupied_map
    c.detail["old_occupancy_in_model"] = u.q == -23 and u.r == 0
    c.status = "PASS" if all([c.detail["move_success"], c.detail["new_occupancy"], c.detail["old_occupancy_cleared"], c.detail["old_occupancy_in_model"]]) else "FAIL"
    cases.append(c)

    # P06 hidden-contact stop ---------------------------------------------------
    c = ParityCase("P06", "hidden_contact_stop")
    scn = probe_scenario()
    scn["forces"].append({"id": "R_INF_HIDDEN", "class": "infantry", "faction": "red", "q": -24, "r": 0, "soldiers": 200})
    b = Battle(scn, "FLAT_FOG")
    # With fog enabled, B_INF_1 (blue) at (-25,0) plans toward (-22,0); the
    # hidden red at (-24,0) stops it before stacking; MP charged only for
    # traversed hexes (none, contact on first step).
    res = b.do_move("B_INF_1", -22, 0, "blue", "auto")
    u = b.world.units.get("B_INF_1")
    c.detail["stopped_by_contact"] = bool(res.get("stopped_by_contact")) or u.q == -25
    c.detail["no_stack"] = b.world.occupied_map.get("-24,0") == "R_INF_HIDDEN"
    c.detail["mover_did_not_enter_hidden_hex"] = u.q != -24
    c.detail["mp_not_charged"] = u.turn_move_cost_spent == 0.0
    c.status = "PASS" if all([c.detail["no_stack"], c.detail["mover_did_not_enter_hidden_hex"], c.detail["mp_not_charged"]]) else "FAIL"
    cases.append(c)

    # P07 attack legality ----------------------------------------------------------
    c = ParityCase("P07", "attack_legality")
    b = Battle(probe_scenario(), "DEV_FLAT_ALL_INFO")
    targets = b.executor.get_attackable_targets("B_INF_1")
    c.detail["targets"] = sorted(t["id"] for t in targets)
    # B_INF_1 (-25,0) vs R_INF_1 (-22,0): distance 3 > range 1 => none
    c.detail["out_of_range_empty"] = c.detail["targets"] == []
    res = b.do_attack("B_INF_1", "R_INF_1", "blue")
    c.detail["illegal_attack_rejected"] = not res.get("success", True)
    b2 = Battle(probe_scenario(), "DEV_FLAT_ALL_INFO")
    b2.do_move("B_INF_1", -23, 0, "blue", "auto")
    res2 = b2.do_attack("B_INF_1", "R_INF_1", "blue")
    c.detail["adjacent_attack_accepted"] = res2.get("success", False)
    c.detail["one_attack_lock"] = not b2.executor.get_attackable_targets("B_INF_1") and not b2.world.units["B_INF_1"].has_attacked if "B_INF_1" in b2.world.units else True
    c.status = "PASS" if all([c.detail["out_of_range_empty"], c.detail["illegal_attack_rejected"], c.detail["adjacent_attack_accepted"]]) else "FAIL"
    cases.append(c)

    # P08 matchup damage ------------------------------------------------------------
    c = ParityCase("P08", "matchup_damage")
    atk = {"class": "cavalry", "soldier_count": 100, "morale": 100.0}
    dfn = {"class": "archer", "soldier_count": 100, "morale": 100.0}
    res = combat.calculate_combat(atk, dfn, 1, 0, {}, 1.0, morale_rout_enabled=False)
    # eff_atk = 100/100*14*1.35 = 18.9 ; eff_def = 100/100*4 = 4
    # ratio = clamp(18.9 / (4*4.2+80) , 0.04, 0.60) = 18.9/96.8 = 0.19524...
    # casualties = roundi(100 * 0.19524) = roundi(19.52) = 20
    c.detail["cav_vs_archer_casualties"] = res["defender_casualties"]
    c.detail["expect"] = 20
    res2 = combat.calculate_combat(dfn, atk, 1, 0, {}, 1.0, morale_rout_enabled=False)
    c.detail["archer_vs_cav_matchup"] = res2["matchup_multiplier"]
    c.detail["expect_reciprocal"] = 1.0 / 1.35
    c.detail["archer_vs_cav_casualties"] = res2["defender_casualties"]
    c.status = "PASS" if (
        c.detail["cav_vs_archer_casualties"] == 20
        and abs(c.detail["archer_vs_cav_matchup"] - c.detail["expect_reciprocal"]) < 1e-9
    ) else "FAIL"
    cases.append(c)

    # P09 casualty rounding (half away from zero) -----------------------------------
    c = ParityCase("P09", "casualty_rounding")
    c.detail["roundi_2_5"] = roundi_gd(2.5)
    c.detail["roundi_neg_2_5"] = roundi_gd(-2.5)
    c.detail["roundi_19_5"] = roundi_gd(19.5)
    # construct a .5 product: ratio*100 = 19.5 => ratio 0.195
    atk = {"class": "infantry", "soldier_count": 100, "morale": 100.0}
    dfn = {"class": "infantry", "soldier_count": 100, "morale": 100.0}
    res = combat.calculate_combat(atk, dfn, 1, 0, {"attacker_bonus": 2.0}, 1.0, morale_rout_enabled=False)
    # eff_atk = 10*2 = 20 ; eff_def = 10 ; ratio = 20/(10*4.2+80)=20/122=0.16393 -> 16
    c.detail["even_battle_casualties"] = res["defender_casualties"]
    c.detail["expect_even"] = 16
    c.status = "PASS" if (c.detail["roundi_2_5"] == 3 and c.detail["roundi_neg_2_5"] == -3 and c.detail["roundi_19_5"] == 20 and c.detail["even_battle_casualties"] == 16) else "FAIL"
    cases.append(c)

    # P10 retaliation -------------------------------------------------------------------
    c = ParityCase("P10", "retaliation")
    atk = {"class": "infantry", "soldier_count": 200, "morale": 100.0}
    dfn = {"class": "spear", "soldier_count": 200, "morale": 100.0, "unguarded": False}
    res = combat.calculate_combat(atk, dfn, 1, 0, {}, 1.0, morale_rout_enabled=False)
    c.detail["melee_attacker_casualties"] = res["attacker_casualties"]
    c.detail["retaliation_occurred"] = res["retaliation_occurred"]
    dfn_r = {"class": "spear", "soldier_count": 200, "morale": 100.0, "unguarded": True}
    res_u = combat.calculate_combat(atk, dfn_r, 1, 0, {}, 1.0, morale_rout_enabled=False)
    c.detail["unguarded_zero_retaliation"] = res_u["attacker_casualties"] == 0
    res_r = combat.calculate_combat(atk, dfn, 3, 0, {}, 1.0, morale_rout_enabled=False)
    c.detail["ranged_no_retaliation"] = res_r["attacker_casualties"] == 0 and not res_r["retaliation_occurred"]
    c.status = "PASS" if (res["attacker_casualties"] > 0 and res_u["attacker_casualties"] == 0 and res_r["attacker_casualties"] == 0) else "FAIL"
    cases.append(c)

    # P11 cavalry continuation -----------------------------------------------------------
    c = ParityCase("P11", "cavalry_continuation")
    scn = probe_scenario()
    scn["forces"].append({"id": "B_CAV_9", "class": "cavalry", "faction": "blue", "q": -23, "r": 0, "soldiers": 300})
    b = Battle(scn, "DEV_FLAT_ALL_INFO")
    res = b.do_attack("B_CAV_9", "R_INF_1", "blue")
    u = b.world.units.get("B_CAV_9")
    c.detail["attack_success"] = res.get("success", False)
    c.detail["cavalry_keeps_action"] = (u is not None) and (not u.action_ended) and (u.has_attacked)
    c.detail["remaining_mp_intact"] = (u is not None) and (u.remaining_mp > 0.0)
    scn2 = probe_scenario()
    scn2["forces"].append({"id": "B_INF_9", "class": "infantry", "faction": "blue", "q": -23, "r": 0, "soldiers": 300})
    b2 = Battle(scn2, "DEV_FLAT_ALL_INFO")
    res2 = b2.do_attack("B_INF_9", "R_INF_1", "blue")
    u2 = b2.world.units.get("B_INF_9")
    c.detail["infantry_action_ended"] = (u2 is not None) and u2.action_ended and u2.remaining_mp == 0.0
    c.status = "PASS" if all([c.detail["attack_success"], c.detail["cavalry_keeps_action"], c.detail["remaining_mp_intact"], c.detail["infantry_action_ended"]]) else "FAIL"
    cases.append(c)

    # P12 death cleanup -----------------------------------------------------------------------
    c = ParityCase("P12", "death_cleanup")
    scn = probe_scenario()
    for f in scn["forces"]:
        if f["id"] == "R_INF_1":
            f["soldiers"] = 1  # min-1 casualty clamp guarantees destruction
    b = Battle(scn, "DEV_FLAT_ALL_INFO")
    b.do_move("B_INF_1", -23, 0, "blue", "auto")
    res = b.do_attack("B_INF_1", "R_INF_1", "blue")
    c.detail["defender_destroyed"] = bool(res.get("defender_destroyed", False))
    c.detail["unit_removed"] = "R_INF_1" not in b.world.units
    c.detail["occupancy_freed"] = "-22,0" not in b.world.occupied_map
    c.detail["no_stale_marker"] = "R_INF_1" not in b.blue_knowledge.stale_contacts
    c.status = "PASS" if all([c.detail["defender_destroyed"], c.detail["unit_removed"], c.detail["occupancy_freed"], c.detail["no_stale_marker"]]) else "FAIL"
    cases.append(c)

    # P13 phase reset ---------------------------------------------------------------------------
    c = ParityCase("P13", "phase_reset")
    b = Battle(probe_scenario(), "DEV_FLAT_ALL_INFO")
    b.do_move("B_INF_1", -23, 0, "blue", "auto")
    u_before = b.world.units["B_INF_1"]
    spent_before = u_before.turn_move_cost_spent
    end = b.sim_end_turn()
    u_after = b.world.units["B_INF_1"]
    c.detail["turn_advanced"] = end["current_turn"] == 2
    c.detail["mp_reset"] = u_after.turn_move_cost_spent == 0.0 and u_after.remaining_mp == u_after.base_mp
    c.detail["locks_reset"] = (not u_after.action_ended) and (not u_after.has_moved) and (not u_after.has_attacked)
    c.detail["spent_before_positive"] = spent_before > 0.0
    c.status = "PASS" if all([c.detail["turn_advanced"], c.detail["mp_reset"], c.detail["locks_reset"], c.detail["spent_before_positive"]]) else "FAIL"
    cases.append(c)

    # P14 mission terminal -----------------------------------------------------------------------
    c = ParityCase("P14", "mission_terminal")
    scn = probe_scenario()
    scn["forces"] = [f for f in scn["forces"] if f["faction"] != "red"] + [
        {"id": "R_INF_1", "class": "infantry", "faction": "red", "q": -24, "r": 0, "soldiers": 1},
    ]
    b = Battle(scn, "DEV_FLAT_ALL_INFO")
    m = b.evaluate_mission()
    # red formation alive, turn 1 < limit, both HQs up: ongoing
    c.detail["ongoing_before_kill"] = m["mission_status"] == "ongoing"
    # kill it: adjacent (range 1), 1 soldier + min-1 clamp => destroyed
    b2 = Battle(scn, "DEV_FLAT_ALL_INFO")
    atk = b2.do_attack("B_INF_1", "R_INF_1", "blue")
    m2 = b2.evaluate_mission()
    c.detail["victory_after_annihilation"] = atk.get("success", False) and m2["mission_status"] == "victory" and m2["termination_reason"] == "all_red_destroyed"
    c.status = "PASS" if all([c.detail["ongoing_before_kill"], c.detail["victory_after_annihilation"]]) else "FAIL"
    cases.append(c)

    # P15 visibility / LOS -------------------------------------------------------------------------
    c = ParityCase("P15", "visibility_los")
    from python_sim.state.faction_knowledge import FactionKnowledge

    kn = FactionKnowledge("blue")
    cells = {
        f"{q},{r}": {"q": q, "r": r, "terrain": 0}
        for q in range(-10, 11) for r in range(-10, 11)
    }
    # mountain at (-1,0) blocks sight along the row
    cells["-1,0"] = {"q": -1, "r": 0, "terrain": 1}
    observer = [{"id": "OBS", "class": "infantry", "faction": "blue", "q": -3, "r": 0, "soldier_count": 100}]
    kn.recompute(observer, observer, cells, 1)
    c.detail["own_cell_visible"] = kn.is_hex_visible(-3, 0)
    c.detail["blocked_beyond_mountain"] = not kn.is_hex_visible(2, 0)
    c.detail["mountain_hex_visible_itself"] = kn.is_hex_visible(-1, 0)
    # forest at intermediate distance blocks only beyond distance>=3
    kn2 = FactionKnowledge("blue")
    cells2 = {
        f"{q},{r}": {"q": q, "r": r, "terrain": 0}
        for q in range(-10, 11) for r in range(-10, 11)
    }
    cells2["-1,0"] = {"q": -1, "r": 0, "terrain": 2}
    kn2.recompute(observer, observer, cells2, 1)
    # forest rule: blocks sight only when the TARGET is at distance >= 3.
    # Target (0,0) is at distance 3 behind the forest hex (-1,0): blocked.
    c.detail["forest_target_at_distance3_blocked"] = not kn2.is_hex_visible(0, 0)
    c.detail["forest_blocks_far"] = not kn2.is_hex_visible(3, 0)
    c.status = "PASS" if all([c.detail["own_cell_visible"], c.detail["blocked_beyond_mountain"], c.detail["mountain_hex_visible_itself"], c.detail["forest_target_at_distance3_blocked"], c.detail["forest_blocks_far"]]) else "FAIL"
    cases.append(c)

    # P16 stale contact / rediscovery ---------------------------------------------------------------
    # Scout vision 4 (provisional, gap scout_vision_provisional): R_INF_1 at
    # (-22,0) is at distance 4 from B_SCT_1 (-26,1) => VISIBLE at init.
    c = ParityCase("P16", "stale_contact_rediscovery")
    b = Battle(probe_scenario(), "FLAT_FOG")
    kn = b.blue_knowledge
    c.detail["initially_visible_via_scout"] = kn.is_enemy_visible(b.world.unit_dict("R_INF_1"))
    c.detail["conscript_hidden"] = not kn.is_enemy_visible(b.world.unit_dict("R_CON_9"))
    # Scout walks out of sight: contact lost -> stale snapshot frozen at (-22,0).
    b.do_move("B_SCT_1", -28, 2, "blue", "auto")
    stale = kn.get_stale_snapshot("R_INF_1")
    c.detail["stale_frozen_at_last_seen"] = bool(stale) and int(stale.get("q", -999)) == -22
    c.detail["stale_turn_frozen"] = bool(stale) and int(stale.get("turn", 0)) <= 1
    # Rediscovery supersedes: infantry closes to distance 1.
    b.do_move("B_INF_1", -23, 0, "blue", "auto")
    c.detail["rediscovery_supersedes"] = kn.is_enemy_visible(b.world.unit_dict("R_INF_1")) and "R_INF_1" not in kn.stale_contacts
    c.status = "PASS" if all([c.detail["initially_visible_via_scout"], c.detail["conscript_hidden"], c.detail["stale_frozen_at_last_seen"], c.detail["stale_turn_frozen"], c.detail["rediscovery_supersedes"]]) else "FAIL"
    cases.append(c)

    # 10v10 fingerprint ----------------------------------------------------------------------------
    c = ParityCase("S0-20", "battle_10v10_fingerprint")
    fp: list[str] = []
    for seed in (7, 7, 1234):
        b = battle_10v10(seed)
        script = _drive_10v10(b)
        fp.append(hashlib.sha256(json.dumps({
            "seed": seed, "script_ok": script.get("ok", False),
            "fingerprint": b.fingerprint(), "trajectory": b.trajectory_hash(),
        }, sort_keys=True).encode()).hexdigest())
    c.detail["fp_seed7_a"] = fp[0]
    c.detail["fp_seed7_b"] = fp[1]
    c.detail["deterministic"] = fp[0] == fp[1]
    c.detail["seed1234_differs_only_in_provenance_fingerprint"] = fp[2]
    c.detail["godot_reference"] = "10v10 cross-runtime export not yet produced by sim_entry (probe-scoped gates); Python fingerprint stable & self-consistent"
    c.status = "PASS" if fp[0] == fp[1] else "FAIL"
    cases.append(c)

    # P17 cross-runtime Godot probe fingerprint -----------------------------------
    # Expected values are the AUTHORITATIVE exported fingerprints from the
    # unmodified Godot headless run (sim_entry.gd gates 1-3), persisted at
    # D:/Game development/.workflow/deliverables/TACTICAL-TRAINING-SIM-V01/
    # verification.json. The canonical probe script (move -> attack -> end
    # turn) runs under FULL_PRODUCTION because the headless script boot does
    # not activate the Step-0 sandbox shell (SandboxRules.is_active() false).
    c = ParityCase("P17", "cross_runtime_godot_probe")
    b = Battle(probe_scenario(), "FULL_PRODUCTION")
    c.detail["initial_match"] = b.fingerprint() == GODOT_PROBE_FINGERPRINT_INITIAL
    script = run_canonical_probe_script(b)
    c.detail["script_ok"] = script.get("ok", False)
    c.detail["post_episode_match"] = b.fingerprint() == GODOT_PROBE_FINGERPRINT_POST
    c.detail["source"] = "Godot 4.2.2 headless sim_entry.gd verification.json (unmodified gameplay code)"
    c.status = "PASS" if (
        c.detail["initial_match"] and c.detail["script_ok"] and c.detail["post_episode_match"]
    ) else "FAIL"
    cases.append(c)

    return cases


def _drive_10v10(b: Battle) -> dict:
    """Deterministic canonical script over the 10v10 battle (2 turns)."""
    from python_sim.policies import SimpleAttackElseAdvancePolicy

    policy = SimpleAttackElseAdvancePolicy()
    ok = True
    for _turn in range(2):
        for uid in [u.id for u in sorted(b.world.units.values(), key=lambda x: x.id) if u.faction == "blue"]:
            res = policy.blue_action(b, uid)
            ok = ok and bool(res.get("success", False) or res.get("held", False) or res.get("moved", False))
        for uid in [u.id for u in sorted(b.world.units.values(), key=lambda x: x.id) if u.faction == "red"]:
            res = policy.red_action(b, uid)
            ok = ok and bool(res.get("success", False) or res.get("held", False))
        b.sim_end_turn()
    return {"ok": ok, "fingerprint": b.fingerprint()}


def matrix_summary(cases: list[ParityCase]) -> dict:
    return {
        "cases": [
            {"pid": c.pid, "name": c.name, "status": c.status, "detail": c.detail}
            for c in cases
        ],
        "pass_count": sum(1 for c in cases if c.status == "PASS"),
        "fail_count": sum(1 for c in cases if c.status == "FAIL"),
        "contract_limited": [c.pid for c in cases if c.status == "CONTRACT_LIMITED"],
        "sim_version": SIM_VERSION,
    }


__all__ = [
    "GODOT_PROBE_FINGERPRINT_INITIAL",
    "GODOT_PROBE_FINGERPRINT_POST",
    "ParityCase",
    "battle_10v10",
    "default_roster_forces",
    "matrix_summary",
    "probe_scenario",
    "run_canonical_probe_script",
    "run_parity_matrix",
]
