#!/usr/bin/env python3
"""Build the five fixed tutorial map data files from compact axial layouts."""

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "data" / "battlefields" / "tutorial_v1"
TERRAIN_CHAR = {0: ".", 1: "M", 2: "F", 3: "S", 5: "V", 6: "R", 7: "W", 9: "X", 11: "C"}
ASSET_ROOT = "assets/map_composition_v0/source_glb"
RUNTIME_SYSTEMS = [
    "full_dev_map_transplant",
    "full_map_ground_batch",
    "forest_runtime_pilot",
    "full_map_mountain_range_batch",
    "full_map_agriculture_batch",
]


def unit(uid, unit_class, faction, q, r, count):
    return [uid, unit_class, faction, q, r, count]


def make_map(radius):
    """Return a true axial hex disk with an exact playable boundary."""
    q_min = -radius
    r_min = -radius
    terrain = {
        (q, r): 0
        for q in range(-radius, radius + 1)
        for r in range(-radius, radius + 1)
        if max(abs(q), abs(r), abs(q + r)) <= radius
    }
    return q_min, r_min, terrain


def cells_where(terrain, coords, value):
    for q, r in coords:
        if (q, r) in terrain:
            terrain[(q, r)] = value


def road(terrain, coords):
    cells_where(terrain, coords, 6)


def site(site_id, name, kind, owner, footprint, hp, slots=4):
    return {
        "id": site_id,
        "name": name,
        "type": kind,
        "owner": owner,
        "footprint": [list(c) for c in footprint],
        "hp": hp,
        "slots": slots,
    }


def area(center, radius):
    return {"center": list(center), "radius": radius}


def make_scenario(
    mission_id,
    family,
    side_role,
    objective_id,
    objective_kind,
    target_ref,
    objective_area,
    round_limit,
    blue_count,
    red_count,
    unlock,
    hq_blue,
    hq_red,
    control_sites=None,
    fortified_refs=None,
    collapse=None,
    result_rule="",
):
    return {
        "schema": "tutorial_scenario_v1",
        "mission_id": mission_id,
        "mission_family": family,
        "side_role": side_role,
        "objectives": [{
            "id": objective_id,
            "kind": objective_kind,
            "target_ref": target_ref,
            "objective_area": objective_area,
        }],
        "control_sites": control_sites or [],
        "round_limit": round_limit,
        "round_limit_provisional": True,
        "fortified_objective_refs": fortified_refs or [],
        "hq": {
            "blue": {"unit_id": "B_HQ", "location": list(hq_blue)},
            "red": {"unit_id": "R_HQ", "location": list(hq_red)},
            "universal_override": {
                "enemy_hq_destroyed": "immediate_victory",
                "own_hq_destroyed": "immediate_defeat",
            },
        },
        "deployment": {
            "player_formations": blue_count,
            "red_formations_including_garrisons": red_count,
            "unlocked_unit": unlock,
        },
        "collapse_withdrawal": collapse or {},
        "normal_result_rule": result_rule,
        "result_hook": "tutorial_mission_result_v1",
    }


def build_document(
    mission_id,
    name,
    name_zh,
    q_min,
    r_min,
    terrain,
    units,
    strongholds,
    scenario,
    info,
    metadata,
):
    width = max(q for q, _ in terrain) - q_min + 1
    height = max(r for _, r in terrain) - r_min + 1
    stronghold_owner_at = {
        (q, r): str(stronghold["owner"])
        for stronghold in strongholds
        for q, r in stronghold["footprint"]
    }
    placements = []
    for uid, unit_class, faction, q, r, count in units:
        role = "hq" if unit_class == "hq" else (
            "garrison" if stronghold_owner_at.get((q, r), "") == faction else "field"
        )
        placements.append({
            "unit_id": uid,
            "unit_class": unit_class,
            "side": faction,
            "location": [q, r],
            "strength": count,
            "role": role,
        })
    scenario["deployment"]["unit_placements"] = placements
    scenario["deployment"]["blue_unit_ids"] = [p["unit_id"] for p in placements if p["side"] == "blue"]
    scenario["deployment"]["red_unit_ids"] = [p["unit_id"] for p in placements if p["side"] == "red"]
    scenario["deployment"]["field_unit_ids"] = [p["unit_id"] for p in placements if p["role"] == "field"]
    scenario["deployment"]["garrison_unit_ids"] = [p["unit_id"] for p in placements if p["role"] == "garrison"]
    scenario["deployment"]["hq_unit_ids"] = [p["unit_id"] for p in placements if p["role"] == "hq"]
    rows = []
    for q in range(q_min, q_min + width):
        rows.append("".join(TERRAIN_CHAR[terrain[(q, r)]] if (q, r) in terrain else "#" for r in range(r_min, r_min + height)))
    radius = (width - 1) // 2
    metadata["playable_dimensions"] = {
        "q": width,
        "r": height,
        "hexes": len(terrain),
        "shape": "regular_axial_hexagon",
        "hex_radius": radius,
    }
    return {
        "format": "tutorial_battlefield_v1",
        "set": "tutorial_v1",
        "id": mission_id,
        "name": name,
        "name_zh": name_zh,
        "q_min": q_min,
        "r_min": r_min,
        "width_hexes": width,
        "height_hexes": height,
        "rows": rows,
        "units": units,
        "strongholds": strongholds,
        "scenario": scenario,
        "info": info,
        "map_metadata": metadata,
    }


def save(doc, filename):
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / filename).write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def m1():
    q_min, r_min, t = make_map(4)
    road(t, [(q, 0) for q in range(-4, 5)])
    road(t, [(q, 2) for q in range(-4, 3)])
    cells_where(t, [(q, r) for q in range(-1, 2) for r in range(-1, 2)], 5)
    cells_where(t, [(-3, -1), (-3, 0), (-2, 1), (-3, 2), (-2, 2), (2, -2), (3, -2), (3, -1)], 2)
    sh = [site("M1_VILLAGE_SQUARE", "Village Square", "fortress", "blue", [(0, 0)], 420)]
    # The gameplay stronghold remains authoritative, while its presentation is
    # a village hub instead of the castle/citadel treatment used by terrain 9.
    t[(0, 0)] = 5
    units = [
        unit("B_M1_GUARD", "spearman", "blue", 0, 0, 74),
        unit("B_M1_MILITIA_1", "conscript", "blue", -3, 0, 54),
        unit("B_M1_MILITIA_2", "conscript", "blue", -3, 1, 48),
        unit("B_M1_MILITIA_3", "conscript", "blue", -2, -1, 52),
        unit("B_M1_SPEAR_1", "spearman", "blue", -2, 1, 61),
        unit("B_HQ", "hq", "blue", -3, 2, 300),
        unit("R_M1_RAIDER_1", "conscript", "red", 3, 0, 60),
        unit("R_M1_RAIDER_2", "spearman", "red", 3, -1, 66),
        unit("R_M1_RAIDER_3", "conscript", "red", 2, 1, 58),
        unit("R_M1_RAIDER_4", "spearman", "red", 2, -2, 62),
        unit("R_HQ", "hq", "red", 4, -1, 300),
    ]
    scenario = make_scenario(
        "M1", "defense_delay", {"blue": "defender", "red": "attacker"},
        "village_defense", "hold_stronghold_until_round_limit", "M1_VILLAGE_SQUARE",
        area((0, 0), 1), 6, 5, 4, "none", (-3, 2), (4, -1),
        fortified_refs=["M1_VILLAGE_SQUARE"],
        collapse={"withdrawal_side": "red", "trigger": "village_square_captured"},
        result_rule="Keep Village Square under blue control through round 6. Loss of the site is defeat.",
    )
    scenario["deployment"]["garrison_unit_ids"] = ["B_M1_GUARD"]
    scenario["provisional_values"] = [
        {"key": "round_limit", "value": 6},
        {"key": "village_square_fortification_hp", "value": 420},
    ]
    metadata = {
        "primary_terrain": ["village", "road", "sparse_forest"],
        "defender_bias": "high",
        "front_width_hexes": 3,
        "flank_openness": 0.28,
        "choke_count": 1,
        "sightline_character": "short village-edge views with one main road and a narrow southern approach",
        "hq_exposure": {"blue": "low", "red": "low", "direct_hq_rush_lane": False},
        "objective_locations": {"Village Square": [0, 0]},
        "asset_kit": [ASSET_ROOT + "/tiles", ASSET_ROOT + "/buildings", ASSET_ROOT + "/fortifications", ASSET_ROOT + "/trees", ASSET_ROOT + "/agriculture"],
        "player_formation_count": 5,
        "unlocked_unit": "none",
        "normal_camera_readability": "village square and both approaches remain distinct at the opening strategy zoom",
        "dev_max_zoom_readability": "house and field details resolve without separating from the village objective",
        "performance_notes": "61 logical hexes in a radius-4 hexagonal footprint; compact use of the shared production batches",
        "optimized_runtime_systems": RUNTIME_SYSTEMS,
    }
    save(build_document("M1", "Village Defense", "村落防守", q_min, r_min, t, units, sh, scenario,
                        {"tactical": "Hold the village square; defend the main road and its short flank.", "units": {"blue": 5, "red": 4}, "strongholds": ["Village Square"]},
                        metadata), "m1_village_defense.json")


def m2():
    q_min, r_min, t = make_map(5)
    cells_where(t, [(q, -5) for q in range(0, 6)] + [(q, 5) for q in range(-5, 1)], 1)
    cells_where(t, [(q, -4) for q in range(-1, 5)] + [(q, 4) for q in range(-5, 2)], 1)
    road(t, [(q, 0) for q in range(-5, 6)])
    road(t, [(q, -1) for q in range(-5, 2)])
    fp = [(1, -1), (1, 0), (1, 1)]
    cells_where(t, fp, 9)
    sh = [site("M2_GATE_FORT", "Gate Fort", "fortress", "blue", fp, 560)]
    units = [
        unit("B_M2_GARRISON", "spearman", "blue", 1, 0, 82),
        unit("B_M2_MILITIA_1", "conscript", "blue", -3, 0, 56),
        unit("B_M2_MILITIA_2", "conscript", "blue", -3, 1, 52),
        unit("B_M2_SPEAR_1", "spearman", "blue", -2, -1, 70),
        unit("B_M2_ARCHER_1", "archer", "blue", -4, 0, 48),
        unit("B_M2_MILITIA_3", "conscript", "blue", -2, 2, 50),
        unit("B_HQ", "hq", "blue", -4, 1, 300),
        unit("R_M2_ASSAULT_1", "spearman", "red", 4, 0, 80),
        unit("R_M2_ASSAULT_2", "conscript", "red", 4, -1, 58),
        unit("R_M2_ASSAULT_3", "conscript", "red", 3, 1, 62),
        unit("R_M2_ASSAULT_4", "archer", "red", 3, -2, 46),
        unit("R_M2_ASSAULT_5", "spearman", "red", 3, 2, 72),
        unit("R_HQ", "hq", "red", 4, -3, 300),
    ]
    scenario = make_scenario(
        "M2", "fortress_defense", {"blue": "defender", "red": "attacker"},
        "gate_fort_defense", "hold_fortification_until_round_limit", "M2_GATE_FORT",
        area((1, 0), 2), 7, 6, 5, "archer", (-4, 1), (4, -3),
        fortified_refs=["M2_GATE_FORT"],
        collapse={"withdrawal_side": "red", "trigger": "gate_fort_captured"},
        result_rule="Keep Gate Fort and its garrison through round 7. Loss of the fort is defeat.",
    )
    scenario["deployment"]["garrison_unit_ids"] = ["B_M2_GARRISON"]
    scenario["deployment"]["reserve_unit_ids"] = ["B_M2_ARCHER_1"]
    scenario["provisional_values"] = [
        {"key": "round_limit", "value": 7},
        {"key": "gate_fort_fortification_hp", "value": 560},
    ]
    metadata = {
        "primary_terrain": ["mountain_pass", "road", "gate_fort"],
        "defender_bias": "very_high",
        "front_width_hexes": 3,
        "flank_openness": 0.20,
        "choke_count": 1,
        "sightline_character": "short to medium pass sightlines with high ground closing both outer flanks",
        "hq_exposure": {"blue": "low", "red": "low", "direct_hq_rush_lane": False},
        "objective_locations": {"Gate Fort": [1, 0]},
        "asset_kit": [ASSET_ROOT + "/tiles", ASSET_ROOT + "/mountains", ASSET_ROOT + "/fortifications", ASSET_ROOT + "/buildings"],
        "player_formation_count": 6,
        "unlocked_unit": "archer",
        "normal_camera_readability": "one narrow pass and one blue-held gate fort dominate the view",
        "dev_max_zoom_readability": "gate garrison and individual pass terrain remain easy to distinguish",
        "performance_notes": "91 logical hexes in a radius-5 hexagonal footprint; compact fort and mountain range compositions use shared batching",
        "optimized_runtime_systems": RUNTIME_SYSTEMS,
    }
    save(build_document("M2", "Gate Fort", "關門山口", q_min, r_min, t, units, sh, scenario,
                        {"tactical": "Hold the mountain pass and its Gate Fort; keep the archer in support.", "units": {"blue": 6, "red": 5}, "strongholds": ["Gate Fort"]},
                        metadata), "m2_gate_fort.json")


def m3():
    q_min, r_min, t = make_map(6)
    road(t, [(q, 0) for q in range(-6, 7)])
    cells_where(t, [(-5, -1), (-5, 0), (-4, 1), (-5, 4), (-4, 5), (4, -5), (5, -4), (5, 0), (4, 1), (5, 3)], 1)
    cells_where(t, [(-4, -3), (-3, -4), (-4, 4), (3, -4), (4, 3)], 2)
    units = [
        unit("B_M3_MILITIA_1", "conscript", "blue", -3, 0, 58),
        unit("B_M3_MILITIA_2", "conscript", "blue", -3, -1, 52),
        unit("B_M3_MILITIA_3", "conscript", "blue", -3, 1, 54),
        unit("B_M3_SPEAR_1", "spearman", "blue", -2, -2, 72),
        unit("B_M3_SPEAR_2", "spearman", "blue", -2, 2, 70),
        unit("B_M3_ARCHER_1", "archer", "blue", -4, 0, 48),
        unit("B_M3_SCOUT_1", "scout", "blue", -4, -2, 28),
        unit("B_HQ", "hq", "blue", -5, 3, 300),
        unit("R_M3_FIELD_1", "conscript", "red", 3, 0, 58),
        unit("R_M3_FIELD_2", "conscript", "red", 3, -1, 54),
        unit("R_M3_FIELD_3", "conscript", "red", 3, 1, 52),
        unit("R_M3_FIELD_4", "spearman", "red", 2, -2, 72),
        unit("R_M3_FIELD_5", "spearman", "red", 2, 2, 70),
        unit("R_M3_FIELD_6", "archer", "red", 4, 0, 46),
        unit("R_M3_FIELD_7", "scout", "red", 4, -2, 28),
        unit("R_HQ", "hq", "red", 5, -3, 300),
    ]
    red_field = [u[0] for u in units if u[2] == "red" and u[1] != "hq"]
    scenario = make_scenario(
        "M3", "field_battle", {"blue": "attacker", "red": "defender"},
        "break_red_field_army", "field_force_collapse", "red_field_force",
        area((0, 0), 3), 9, 7, 7, "scout", (-5, 3), (5, -3),
        collapse={
            "target_unit_ids": red_field,
            "loss_ratio": 0.60,
            "loss_ratio_provisional": True,
            "withdrawal_side": "red",
            "withdrawal_trigger": "60_percent_field_force_lost",
        },
        result_rule="Break at least 60% of the red field force by round 9. HQ destruction still ends the battle immediately.",
    )
    scenario["deployment"]["recon_unit_ids"] = ["B_M3_SCOUT_1"]
    scenario["deployment"]["main_effort_unit_ids"] = ["B_M3_SPEAR_1", "B_M3_SPEAR_2"]
    scenario["deployment"]["reserve_unit_ids"] = ["B_M3_MILITIA_3"]
    scenario["provisional_values"] = [
        {"key": "round_limit", "value": 9},
        {"key": "red_field_loss_ratio", "value": 0.60},
    ]
    metadata = {
        "primary_terrain": ["open_plain", "road", "sparse_edge_hills"],
        "defender_bias": "slight_red",
        "front_width_hexes": 9,
        "flank_openness": 0.82,
        "choke_count": 0,
        "sightline_character": "long open sightlines with broad north and south flank space and rear reserve depth",
        "hq_exposure": {"blue": "low", "red": "low", "direct_hq_rush_lane": False},
        "objective_locations": {"Main Effort": [0, 0], "Reconnaissance Area": [-4, -2]},
        "asset_kit": [ASSET_ROOT + "/tiles", ASSET_ROOT + "/trees", ASSET_ROOT + "/mountains"],
        "player_formation_count": 7,
        "unlocked_unit": "scout",
        "normal_camera_readability": "the central front and both flanks remain visible at normal strategy zoom",
        "dev_max_zoom_readability": "scout can inspect open flank lanes without filling the view with props",
        "performance_notes": "127 logical hexes in a radius-6 hexagonal footprint; predominantly batched open ground with low prop density",
        "optimized_runtime_systems": RUNTIME_SYSTEMS,
    }
    save(build_document("M3", "Open Field Battle", "平原野战", q_min, r_min, t, units, [], scenario,
                        {"tactical": "Scout the flank, choose the main effort, and break the red field army.", "units": {"blue": 7, "red": 7}, "strongholds": []},
                        metadata), "m3_open_field_battle.json")


def m4():
    q_min, r_min, t = make_map(7)
    for r in range(-7, 8):
        t[(0, r)] = 7
    # Terrain 6 is the bridge deck; river membership is stored separately.
    t[(0, 0)] = 6
    road(t, [(q, 0) for q in range(-7, 8)])
    road(t, [(q, -5) for q in range(0, 6)])
    road(t, [(q, 5) for q in range(-1, 3)])
    cells_where(t, [(-4, -5), (-3, -5), (-5, 4), (-4, 5)], 2)
    cells_where(t, [(4, -6), (5, -6), (2, 5), (2, 4)], 1)
    site_defs = [
        site("M4_MILL_VILLAGE", "Mill Village", "fortress", "red", [(-6, 0)], 220),
        site("M4_BRIDGEHEAD", "Bridgehead Depot", "fortress", "red", [(6, -6)], 260),
        site("M4_HIGH_GROUND", "High Ground Relay", "fortress", "red", [(1, 6)], 220),
    ]
    # Logistics bases are built on the field by the HQ. Keep their build hexes
    # adjacent to each fort so they remain reachable under the existing
    # stronghold movement rules.
    logistics_sites = {
        "M4_MILL_VILLAGE": (-5, 0),
        "M4_BRIDGEHEAD": (5, -5),
        "M4_HIGH_GROUND": (1, 5),
    }
    for stronghold in site_defs:
        for q, r in stronghold["footprint"]:
            t[(q, r)] = 9
    units = [
        unit("B_M4_MILITIA_1", "conscript", "blue", -4, 1, 56),
        unit("B_M4_MILITIA_2", "conscript", "blue", -4, 0, 52),
        unit("B_M4_MILITIA_3", "conscript", "blue", -4, 2, 54),
        unit("B_M4_SPEAR_1", "spearman", "blue", -3, -1, 70),
        unit("B_M4_SPEAR_2", "spearman", "blue", -3, 2, 72),
        unit("B_M4_ARCHER_1", "archer", "blue", -5, -2, 48),
        unit("B_M4_SCOUT_1", "scout", "blue", -5, 3, 30),
        unit("B_M4_CAVALRY_1", "cavalry", "blue", -4, 4, 50),
        unit("B_HQ", "hq", "blue", -6, 3, 300),
        unit("R_M4_FIELD_1", "conscript", "red", 5, 0, 58),
        unit("R_M4_FIELD_2", "conscript", "red", 5, -2, 52),
        unit("R_M4_FIELD_3", "spearman", "red", 4, 1, 70),
        unit("R_M4_FIELD_4", "archer", "red", 4, -3, 46),
        unit("R_M4_FIELD_5", "scout", "red", 3, -4, 28),
        unit("R_M4_GARRISON_1", "conscript", "red", -6, 0, 42),
        unit("R_M4_GARRISON_2", "spearman", "red", 6, -6, 56),
        unit("R_M4_GARRISON_3", "conscript", "red", 1, 6, 40),
        unit("R_HQ", "hq", "red", 6, -1, 300),
    ]
    scenario = make_scenario(
        "M4", "occupation", {"blue": "contester", "red": "contester"},
        "control_three_logistics_sites", "three_site_logistics_control", "M4_CONTROL_SITES",
        area((0, 0), 7), 9, 8, 8, "cavalry", (-6, 3), (6, -1),
        control_sites=[
            {
                "stronghold_id": s["id"],
                "logistics_base_hex": list(logistics_sites[s["id"]]),
                "objective_area": area(logistics_sites[s["id"]], 1),
                "control_truth": "existing_hq_built_logistics_base",
            }
            for s in site_defs
        ],
        fortified_refs=[s["id"] for s in site_defs],
        collapse={
            "target_unit_ids": [u[0] for u in units if u[2] == "red" and u[1] != "hq"],
            "loss_ratio": 0.60,
            "loss_ratio_provisional": True,
            "withdrawal_side": "red",
            "withdrawal_trigger": "all_three_logistics_bases_blue",
        },
        result_rule="Establish valid logistics bases at all three designated sites and retain them for three consecutive rounds. At round 9, blue control of at least two of three wins.",
    )
    scenario["deployment"]["mobile_unit_ids"] = ["B_M4_CAVALRY_1"]
    scenario["provisional_values"] = [
        {"key": "round_limit", "value": 9},
        {"key": "full_control_consecutive_rounds", "value": 3},
        {"key": "end_of_battle_majority_sites", "value": 2},
        {"key": "site_wall_hp", "values": {"M4_MILL_VILLAGE": 220, "M4_BRIDGEHEAD": 260, "M4_HIGH_GROUND": 220}},
        {"key": "site_garrison_strength", "values": {"M4_MILL_VILLAGE": 42, "M4_BRIDGEHEAD": 56, "M4_HIGH_GROUND": 40}},
    ]
    metadata = {
        "primary_terrain": ["open_fields", "river_crossing", "road_junction", "village", "high_ground"],
        "defender_bias": "balanced",
        "front_width_hexes": 11,
        "flank_openness": 0.76,
        "choke_count": 1,
        "sightline_character": "open mixed-terrain sightlines split by a north-south river and one road bridge",
        "hq_exposure": {"blue": "low", "red": "low", "direct_hq_rush_lane": False},
        "objective_locations": {name: list(logistics_sites[s["id"]]) for s, name in zip(site_defs, ["Mill Village", "Bridgehead Depot", "High Ground Relay"])},
        "stronghold_locations": {s["name"]: list(s["footprint"][0]) for s in site_defs},
        "asset_kit": [ASSET_ROOT + "/tiles", ASSET_ROOT + "/water", ASSET_ROOT + "/buildings", ASSET_ROOT + "/fortifications", ASSET_ROOT + "/mountains", ASSET_ROOT + "/trees", ASSET_ROOT + "/agriculture"],
        "player_formation_count": 8,
        "unlocked_unit": "cavalry",
        "normal_camera_readability": "three control sites span the full field; the central bridge is visually distinct",
        "dev_max_zoom_readability": "river, bridge deck, village, and high ground resolve without hiding site badges",
        "performance_notes": "169 logical hexes in a radius-7 hexagonal footprint; three separated HQ-build logistics sites sit beside their defensive strongholds",
        "optimized_runtime_systems": RUNTIME_SYSTEMS,
    }
    doc = build_document("M4", "Roads and Crossings", "道路与渡口", q_min, r_min, t, units, site_defs, scenario,
                         {"tactical": "Establish bases at the separated village, bridgehead, and high-ground sites; cavalry makes the distance manageable.", "units": {"blue": 8, "red": 8}, "strongholds": ["Mill Village", "Bridgehead Depot", "High Ground Relay"]},
                         metadata)
    doc["river_cells"] = [[0, r] for r in range(-7, 8)]
    save(doc, "m4_roads_and_crossings.json")


def m5():
    q_min, r_min, t = make_map(9)
    road(t, [(q, 0) for q in range(-9, 10)])
    road(t, [(q, -4) for q in range(-5, 3)])
    road(t, [(q, 4) for q in range(-3, 6)])
    cells_where(t, [(q, -9) for q in range(0, 10)] + [(q, 9) for q in range(-9, 1)], 1)
    cells_where(t, [(-6, -3), (-5, -4), (-6, 4), (-5, 5), (5, -8), (6, -8), (6, 7), (5, 8)], 2)
    cells_where(t, [(-4, -5), (-3, -6), (3, -6), (4, -5), (-4, 5), (-3, 6), (3, 6), (4, 5)], 1)
    gate_fp = [(2, -1), (2, 0), (2, 1)]
    keep_fp = [(5, -1), (5, 0), (5, 1)]
    cells_where(t, gate_fp, 9)
    cells_where(t, keep_fp, 11)
    sh = [
        site("M5_OUTER_GATE", "Outer Gate", "fortress", "red", gate_fp, 520),
        site("M5_INNER_CITADEL", "Inner Citadel", "capital", "red", keep_fp, 760, 6),
    ]
    units = [
        unit("B_M5_MILITIA_1", "conscript", "blue", -6, 0, 56),
        unit("B_M5_MILITIA_2", "conscript", "blue", -6, -2, 52),
        unit("B_M5_MILITIA_3", "conscript", "blue", -6, 2, 54),
        unit("B_M5_SPEAR_1", "spearman", "blue", -5, -3, 72),
        unit("B_M5_SPEAR_2", "spearman", "blue", -5, 3, 70),
        unit("B_M5_ARCHER_1", "archer", "blue", -7, -2, 48),
        unit("B_M5_SCOUT_1", "scout", "blue", -7, 2, 32),
        unit("B_M5_CAVALRY_1", "cavalry", "blue", -7, 4, 52),
        unit("B_M5_INFANTRY_1", "infantry", "blue", -4, -3, 64),
        unit("B_M5_INFANTRY_2", "infantry", "blue", -4, 3, 62),
        unit("B_HQ", "hq", "blue", -8, 0, 300),
        unit("R_M5_FIELD_1", "conscript", "red", 6, -1, 62),
        unit("R_M5_FIELD_2", "conscript", "red", 6, 1, 56),
        unit("R_M5_FIELD_3", "spearman", "red", 7, -2, 76),
        unit("R_M5_FIELD_4", "spearman", "red", 7, 2, 74),
        unit("R_M5_FIELD_5", "archer", "red", 8, 0, 48),
        unit("R_M5_FIELD_6", "cavalry", "red", 8, -1, 50),
        unit("R_M5_FIELD_7", "conscript", "red", 7, -4, 54),
        unit("R_M5_FIELD_8", "infantry", "red", 6, 3, 68),
        unit("R_M5_GATE_GARRISON", "spearman", "red", 2, 0, 84),
        unit("R_M5_CITADEL_GARRISON", "archer", "red", 5, 0, 76),
        unit("R_HQ", "hq", "red", 8, -5, 300),
    ]
    scenario = make_scenario(
        "M5", "siege", {"blue": "attacker", "red": "defender"},
        "capture_inner_citadel", "capture_fortified_objective", "M5_INNER_CITADEL",
        area((5, 0), 2), 14, 10, 10, "regular_infantry", (-8, 0), (8, -5),
        fortified_refs=["M5_OUTER_GATE", "M5_INNER_CITADEL"],
        collapse={
            "target_unit_ids": [u[0] for u in units if u[2] == "red" and u[1] != "hq"],
            "loss_ratio": 0.70,
            "loss_ratio_provisional": True,
            "withdrawal_side": "red",
            "withdrawal_trigger": "inner_citadel_captured",
        },
        result_rule="Capture the Inner Citadel by round 14. Enemy HQ destruction remains an immediate universal victory.",
    )
    scenario["deployment"]["recon_unit_ids"] = ["B_M5_SCOUT_1"]
    scenario["deployment"]["mobile_unit_ids"] = ["B_M5_CAVALRY_1"]
    scenario["deployment"]["reserve_unit_ids"] = ["B_M5_INFANTRY_1", "B_M5_INFANTRY_2"]
    scenario["provisional_values"] = [
        {"key": "round_limit", "value": 14},
        {"key": "outer_gate_fortification_hp", "value": 520},
        {"key": "inner_citadel_fortification_hp", "value": 760},
        {"key": "red_collapse_loss_ratio", "value": 0.70},
    ]
    metadata = {
        "primary_terrain": ["approach_fields", "outer_gate_fort", "breach_space", "inner_citadel"],
        "defender_bias": "high_red",
        "front_width_hexes": 9,
        "flank_openness": 0.58,
        "choke_count": 2,
        "sightline_character": "long approach views narrow at the gate, open briefly between walls, and close again at the citadel",
        "hq_exposure": {"blue": "low", "red": "low", "direct_hq_rush_lane": False},
        "objective_locations": {"Outer Gate": [2, 0], "Inner Citadel": [5, 0]},
        "asset_kit": [ASSET_ROOT + "/tiles", ASSET_ROOT + "/fortifications", ASSET_ROOT + "/buildings", ASSET_ROOT + "/mountains", ASSET_ROOT + "/trees", ASSET_ROOT + "/agriculture"],
        "player_formation_count": 10,
        "unlocked_unit": "regular_infantry",
        "normal_camera_readability": "the outer gate, breach gap, and inner citadel read as separate strategic stages",
        "dev_max_zoom_readability": "the castle stays legible as a fortress without dominating the battlefield view",
        "performance_notes": "271 logical hexes in a radius-9 hexagonal footprint, 2.98x M2; the same optimized shared runtime handles all terrain families",
        "optimized_runtime_systems": RUNTIME_SYSTEMS,
    }
    save(build_document("M5", "Fortified Assault", "攻城战", q_min, r_min, t, units, sh, scenario,
                        {"tactical": "Reconnoitre the approach, breach the outer gate, then concentrate on the Inner Citadel.", "units": {"blue": 10, "red": 10}, "strongholds": ["Outer Gate", "Inner Citadel"]},
                        metadata), "m5_fortified_assault.json")


if __name__ == "__main__":
    m1()
    m2()
    m3()
    m4()
    m5()
    print(f"Wrote exactly five tutorial maps to {OUT}")
