extends SceneTree
## Boots the standard shell with HC01 and checks its opening playable state.
## Run headless: -s res://tools/battlefields/handcrafted_turn0_probe.gd

const Catalog = preload("res://scripts/battlefields/handcrafted_battlefield_catalog.gd")
const Boundary = preload("res://scripts/step2r/step2r_world_boundary.gd")
const Config = preload("res://scripts/core/step3_config.gd")
const OUT := "res://evidence/handcrafted_v1/turn0_smoke.json"

var _shell: Node
var _frames := 0


func _initialize() -> void:
	_shell = (load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene).instantiate()
	_shell.set("battlefield_id", "HC01")
	root.add_child(_shell)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 30:
		return false
	var expected: Dictionary = Catalog.load_battlefield("HC01")
	var cells: Dictionary = _shell.get("hex_grid").get("cell_data")
	var river: Dictionary = _shell.get("_river_cells")
	var um: Variant = _shell.get("unit_manager")
	var units: Array = um.get_all_units_including_garrisoned()
	var mismatches := 0
	for key in expected["terrain"]:
		if not cells.has(key) or int(cells[key].terrain) != int(expected["terrain"][key]):
			mismatches += 1
	var strongholds: Array = []
	for sh in um.get_all_strongholds():
		strongholds.append({"id": str(sh.structure_id), "owner": str(sh.owner), "garrison": int(sh.get_garrison_count())})
	var invalid_units: Array = []
	for u in expected["units"]:
		var pos := Vector2i(int(u["q"]), int(u["r"]))
		if not Boundary.is_playable_hex(pos):
			invalid_units.append(str(u["id"]))
		elif Config.is_impassable(int(cells["%d,%d" % [pos.x, pos.y]].terrain)) and not _is_friendly_footprint(pos, str(u["faction"]), expected["strongholds"]):
			invalid_units.append(str(u["id"]))
	var data_file := FileAccess.open("res://data/battlefields/handcrafted_v1/hc01_cheongha_gorge.json", FileAccess.READ)
	var authored: Dictionary = JSON.parse_string(data_file.get_as_text())
	data_file.close()
	var bridges: Array = authored["info"]["bridges"]
	var bad_bridges: Array = []
	for p in bridges:
		var key := "%d,%d" % [int(p[0]), int(p[1])]
		if not river.has(key) or not cells.has(key) or int(cells[key].terrain) != 6:
			bad_bridges.append(key)
	var result := {
		"id": "HC01", "loaded_id": str(_shell.get("battlefield_id")),
		"turn": int(um.get_current_turn()), "cells": cells.size(),
		"terrain_mismatch": mismatches,
		"river_cells": river.size(), "river_expected": (expected["river"] as Dictionary).size(),
		"bridges": bridges, "bad_bridges": bad_bridges,
		"units_live": units.size(), "units_expected": (expected["units"] as Array).size(),
		"invalid_units": invalid_units, "strongholds": strongholds,
		"visual_specs": (_shell.call("stronghold_visual_specs") as Array).size(),
	}
	var ok: bool = result["loaded_id"] == "HC01" and result["turn"] == 1 \
		and result["cells"] == 4921 and mismatches == 0 \
		and result["river_cells"] == result["river_expected"] \
		and bridges.size() == 2 and bad_bridges.is_empty() \
		and result["units_live"] == result["units_expected"] \
		and invalid_units.is_empty() and strongholds.size() == 2
	result["status"] = "PASS" if ok else "FAIL"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://evidence/handcrafted_v1"))
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	f.store_string(JSON.stringify(result, "  "))
	f.close()
	print("[HC01-TURN0] " + JSON.stringify(result))
	quit(0 if ok else 1)
	return true


func _is_friendly_footprint(pos: Vector2i, faction: String, strongholds: Array) -> bool:
	for sh in strongholds:
		if str(sh["owner"]) != faction:
			continue
		for c in sh["footprint"]:
			if c == pos:
				return true
	return false
