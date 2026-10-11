#!/usr/bin/env python3
"""Validate the fixed five-map tutorial data and captured visual evidence."""

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "data" / "battlefields" / "tutorial_v1"
EVIDENCE = ROOT / "evidence" / "tutorial_maps"
EXPECTED = {
    "M1": ("m1_village_defense.json", 4, 61, 5, "none"),
    "M2": ("m2_gate_fort.json", 5, 91, 6, "archer"),
    "M3": ("m3_open_field_battle.json", 6, 127, 7, "scout"),
    "M4": ("m4_roads_and_crossings.json", 7, 169, 8, "cavalry"),
    "M5": ("m5_fortified_assault.json", 9, 271, 10, "regular_infantry"),
}
TERRAIN = {".", "M", "F", "S", "V", "R", "W", "X", "C", "#"}
RUNTIME_SCRIPTS = {
    "full_dev_map_transplant": ROOT / "scripts/visual/full_dev_map_transplant.gd",
    "full_map_ground_batch": ROOT / "scripts/visual/full_map_ground_batch.gd",
    "forest_runtime_pilot": ROOT / "scripts/visual/map_composition_v0/forest_runtime_pilot.gd",
    "full_map_mountain_range_batch": ROOT / "scripts/visual/full_map_mountain_range_batch.gd",
    "full_map_agriculture_batch": ROOT / "scripts/visual/full_map_agriculture_batch.gd",
}
CAPTURES = ("closeup", "tactical", "commander", "terrain_cmd", "terrain_tac", "terrain_cu")


def require(condition, message):
    if not condition:
        raise AssertionError(message)


files = sorted(DATA.glob("*.json"))
require(len(files) == 5, f"expected exactly five scenario files, found {len(files)}")
docs = {}
for mission_id, (filename, radius, expected_hexes, formation_count, unlock) in EXPECTED.items():
    path = DATA / filename
    doc = json.loads(path.read_text(encoding="utf-8"))
    docs[mission_id] = doc
    width = height = radius * 2 + 1
    require(doc["id"] == mission_id, f"{filename}: id mismatch")
    require(doc["format"] == "tutorial_battlefield_v1", f"{filename}: format mismatch")
    require(doc["width_hexes"] == width and doc["height_hexes"] == height, f"{mission_id}: dimensions mismatch")
    require(len(doc["rows"]) == width and all(len(row) == height for row in doc["rows"]), f"{mission_id}: malformed row grid")
    require(set("".join(doc["rows"])) <= TERRAIN, f"{mission_id}: unknown terrain glyph")
    scenario = doc["scenario"]
    metadata = doc["map_metadata"]
    deployment = scenario["deployment"]
    require(scenario["mission_id"] == mission_id, f"{mission_id}: scenario identity mismatch")
    dimensions = metadata["playable_dimensions"]
    require(dimensions["q"] == width and dimensions["r"] == height, f"{mission_id}: playable bounds mismatch")
    require(dimensions["hexes"] == expected_hexes, f"{mission_id}: playable hex count mismatch")
    require(dimensions["shape"] == "regular_axial_hexagon" and dimensions["hex_radius"] == radius, f"{mission_id}: hex shape metadata mismatch")
    require(metadata["player_formation_count"] == formation_count, f"{mission_id}: formation progression mismatch")
    require(deployment["player_formations"] == formation_count, f"{mission_id}: deployment formation count mismatch")
    require(metadata["unlocked_unit"] == unlock and deployment["unlocked_unit"] == unlock, f"{mission_id}: unlock mismatch")
    require(scenario["round_limit_provisional"] is True, f"{mission_id}: provisional limit is not marked")
    require(scenario["hq"]["universal_override"] == {
        "enemy_hq_destroyed": "immediate_victory",
        "own_hq_destroyed": "immediate_defeat",
    }, f"{mission_id}: universal HQ override mismatch")
    require(metadata["hq_exposure"]["direct_hq_rush_lane"] is False, f"{mission_id}: exposed HQ rush lane")

    rows = doc["rows"]
    q_min, r_min = doc["q_min"], doc["r_min"]
    terrain_cells = {}
    for qi, row in enumerate(rows):
        for ri, glyph in enumerate(row):
            q, r = q_min + qi, r_min + ri
            in_hex = max(abs(q), abs(r), abs(q + r)) <= radius
            require((glyph != "#") == in_hex, f"{mission_id}: void mask does not form the declared axial hexagon at {(q, r)}")
            if glyph != "#":
                terrain_cells[(q, r)] = glyph
    require(len(terrain_cells) == expected_hexes, f"{mission_id}: actual playable cells do not match the expected hex count")
    stronghold_ids = set()
    for stronghold in doc["strongholds"]:
        require(stronghold["id"] not in stronghold_ids, f"{mission_id}: duplicate stronghold ID")
        stronghold_ids.add(stronghold["id"])
        for q, r in stronghold["footprint"]:
            require((q, r) in terrain_cells, f"{mission_id}: stronghold {stronghold['id']} extends outside the hex map")
    for objective in scenario.get("objectives", []):
        objective_area = objective.get("objective_area", {})
        center = objective_area.get("center", [])
        require(len(center) == 2 and tuple(center) in terrain_cells, f"{mission_id}: objective {objective.get('id')} has an invalid center")
        cq, cr = int(center[0]), int(center[1])
        area_radius = int(objective_area.get("radius", 0))
        for dq in range(-area_radius, area_radius + 1):
            for dr in range(-area_radius, area_radius + 1):
                if max(abs(dq), abs(dr), abs(dq + dr)) <= area_radius:
                    require((cq + dq, cr + dr) in terrain_cells, f"{mission_id}: objective area extends beyond the hex map")
    placements = scenario["deployment"]["unit_placements"]
    unit_rows = {row[0]: row for row in doc["units"]}
    require(len(unit_rows) == len(doc["units"]), f"{mission_id}: duplicate unit IDs")
    require(set(p["unit_id"] for p in placements) == set(unit_rows), f"{mission_id}: deployment roster mismatch")
    occupied = set()
    for placement in placements:
        uid = placement["unit_id"]
        row = unit_rows[uid]
        q, r = placement["location"]
        require((q, r) in terrain_cells, f"{mission_id}: {uid} lies outside the playable map")
        require([uid, row[1], row[2], q, r, row[5]] == row, f"{mission_id}: deployment and unit roster disagree for {uid}")
        require((q, r) not in occupied, f"{mission_id}: overlapping opening deployment at {(q, r)}")
        occupied.add((q, r))
    for side, unit_id in (("blue", "B_HQ"), ("red", "R_HQ")):
        require(unit_id in unit_rows and unit_rows[unit_id][2] == side, f"{mission_id}: missing {side} HQ")
        require(scenario["hq"][side]["unit_id"] == unit_id, f"{mission_id}: HQ reference mismatch")
        require(scenario["hq"][side]["location"] == unit_rows[unit_id][3:5], f"{mission_id}: HQ location mismatch")

    for asset_dir in metadata["asset_kit"]:
        require((ROOT / asset_dir).is_dir(), f"{mission_id}: missing asset kit {asset_dir}")
    for system in metadata["optimized_runtime_systems"]:
        require(system in RUNTIME_SCRIPTS and RUNTIME_SCRIPTS[system].is_file(), f"{mission_id}: missing runtime {system}")
    capture_dir = EVIDENCE / mission_id
    for mode in CAPTURES:
        png = capture_dir / f"{mission_id.lower()}_{mode}.png"
        require(png.is_file() and png.read_bytes()[:8] == b"\x89PNG\r\n\x1a\n", f"{mission_id}: missing/invalid {mode} capture")

m4 = docs["M4"]
sites = m4["scenario"]["control_sites"]
require(len(sites) == 3, "M4 must have exactly three designated control sites")
site_ids = [entry["stronghold_id"] for entry in sites]
require(len(set(site_ids)) == 3, "M4 control site IDs must be unique")
anchors = {s["id"]: s["footprint"][0] for s in m4["strongholds"]}
require(set(site_ids) == set(anchors), "M4 designated sites must reference the three map strongholds")
base_hexes = [tuple(entry["logistics_base_hex"]) for entry in sites]
occupied = {(u[3], u[4]) for u in m4["units"]}
stronghold_hexes = {tuple(coord) for s in m4["strongholds"] for coord in s["footprint"]}
terrain_cells = {
    (m4["q_min"] + qi, m4["r_min"] + ri): glyph
    for qi, row in enumerate(m4["rows"])
    for ri, glyph in enumerate(row)
    if glyph != "#"
}
for site, base_hex in zip(sites, base_hexes):
    require(site["control_truth"] == "existing_hq_built_logistics_base", "M4 site must use the existing logistics-base system")
    require(base_hex in terrain_cells, f"M4 logistics base hex {base_hex} is outside the map")
    require(base_hex not in occupied and base_hex not in stronghold_hexes, f"M4 logistics base hex {base_hex} is occupied or blocked")
    require(terrain_cells[base_hex] not in {"M", "W", "X"}, f"M4 logistics base hex {base_hex} is on blocked terrain")
    objective_area = site["objective_area"]
    require(objective_area["center"] == list(base_hex), "M4 control area must include its logistics base hex")
for i, left_id in enumerate(site_ids):
    for right_id in site_ids[i + 1:]:
        lq, lr = anchors[left_id]
        rq, rr = anchors[right_id]
        distance = (abs(lq-rq) + abs(lr-rr) + abs((lq+lr)-(rq+rr))) // 2
        require(distance >= 8, f"M4 control sites too close: {left_id}/{right_id} distance {distance}")
for i, left in enumerate(base_hexes):
    for right in base_hexes[i + 1:]:
        distance = (abs(left[0]-right[0]) + abs(left[1]-right[1]) + abs((left[0]+left[1])-(right[0]+right[1]))) // 2
        require(distance >= 8, f"M4 logistics base sites too close: {left}/{right} distance {distance}")
require(m4["scenario"]["round_limit"] == 9, "M4 round limit mismatch")
require(m4["scenario"]["provisional_values"][1]["value"] == 3, "M4 full-control streak must be three rounds")
require(m4["scenario"]["provisional_values"][2]["value"] == 2, "M4 end-of-battle majority must be two sites")
require("infantry" not in [row[1] for row in m4["units"] if row[2] == "blue"], "M4 must not unlock Regular Infantry")
m5_blue_classes = {row[1] for row in docs["M5"]["units"] if row[2] == "blue"}
require("infantry" in m5_blue_classes and "cavalry" in m5_blue_classes, "M5 must include prior Cavalry and new Regular Infantry")
require(EXPECTED["M5"][2] > 2.5 * EXPECTED["M2"][2], "M5 must be materially larger than M2")

print("PASS: exactly five maps; axial hex boundaries, deployments, HQ data, progression, asset kits, renderer references, M4 spacing/contract, and 30 PNG captures validated.")
for mission_id, doc in docs.items():
    md = doc["map_metadata"]["playable_dimensions"]
    print(f"{mission_id}: hex radius {md['hex_radius']} ({md['hexes']} hexes), {doc['map_metadata']['player_formation_count']} player formations, unlock={doc['map_metadata']['unlocked_unit']}")
