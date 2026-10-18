extends RefCounted

## Fixed, data-only tutorial battlefields. IDs M1-M5 are kept apart from the
## RL and handcrafted sets; the standard Step2R shell interprets these rows.
const FORMAT := "tutorial_battlefield_v1"
const SET_ID := "tutorial_v1"
const DATA_DIR := "res://data/battlefields/tutorial_v1/"
const FILES := {
	"M1": "m1_village_defense.json",
	"M2": "m2_gate_fort.json",
	"M3": "m3_open_field_battle.json",
	"M4": "m4_roads_and_crossings.json",
	"M5": "m5_fortified_assault.json",
}
const LEGEND := {
	".": 0, "M": 1, "F": 2, "S": 3, "V": 5, "R": 6, "W": 7, "H": 8, "X": 9, "C": 11,
}
## Generated mission maps (tools/battlefields/gen_missions.py, 2026-10-09) load by id "@<file path>"; "H" = wall.
const GEN_SET_ID := "mission_gen_v1"

static func ids() -> Array:
	return ["M1", "M2", "M3", "M4", "M5"]

static func has_battlefield(id: String) -> bool:
	return id.begins_with("@") or FILES.has(id.to_upper())

static func title_of(id: String) -> String:
	var doc := _read(id)
	if doc.is_empty():
		return ""
	return "%s  %s" % [id.to_upper(), str(doc.get("name", ""))]

static func summary_of(id: String) -> Dictionary:
	var doc := _read(id)
	if doc.is_empty():
		return {}
	var info: Dictionary = doc.get("info", {})
	return {
		"id": id.to_upper(),
		"name": str(doc.get("name", "")),
		"name_zh": str(doc.get("name_zh", "")),
		"terrain": str((doc.get("map_metadata", {}) as Dictionary).get("primary_terrain", [])),
		"tactical": str(info.get("tactical", "")),
		"asymmetry": str((doc.get("map_metadata", {}) as Dictionary).get("defender_bias", "")),
		"units": info.get("units", {}),
		"strongholds": info.get("strongholds", []),
	}

static func _read(id: String) -> Dictionary:
	var key := id.to_upper()
	var generated := id.begins_with("@")
	if not generated and not FILES.has(key):
		return {}
	var path := id.substr(1) if generated else DATA_DIR + str(FILES[key])
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("[TutorialBattlefield] cannot open " + path)
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not (parsed is Dictionary) or str((parsed as Dictionary).get("format", "")) != FORMAT:
		push_error("[TutorialBattlefield] invalid format in " + path)
		return {}
	if str((parsed as Dictionary).get("set", "")) != (GEN_SET_ID if generated else SET_ID):
		push_error("[TutorialBattlefield] invalid set in " + path)
		return {}
	return parsed

## The scenario block is the single source of mission truth. This adapter adds
## the legacy GX mission keys without copying any mission policy into maps.
static func _adapt_gx_mission(scenario: Dictionary) -> Dictionary:
	var mission := scenario.duplicate(true)
	var mission_id := str(scenario.get("mission_id", ""))
	mission["family"] = mission_id
	mission["roles"] = (scenario.get("side_role", {}) as Dictionary).duplicate(true)
	# Tutorial "loss_ratio" = share of soldiers LOST; MissionRules collapse_frac = share REMAINING.
	var collapse: Dictionary = scenario.get("collapse_withdrawal", {})
	mission["collapse_frac"] = 1.0 - float(collapse["loss_ratio"]) if collapse.has("loss_ratio") else 0.30
	mission["morale"] = true
	match mission_id:
		"M1":
			var objectives: Array = scenario.get("objectives", [])
			if not objectives.is_empty():
				var objective_area: Dictionary = (objectives[0] as Dictionary).get("objective_area", {})
				# Explicit village hexes (the 3 V hexes) win over the legacy center+radius disk.
				if objective_area.has("hexes"):
					mission["village_hexes"] = (objective_area["hexes"] as Array).duplicate(true)
				else:
					mission["village_hexes"] = _hex_disk(objective_area.get("center", [0, 0]), int(objective_area.get("radius", 0)))
		"M2", "M5":
			var objectives: Array = scenario.get("objectives", [])
			if not objectives.is_empty():
				mission["stronghold_id"] = str((objectives[0] as Dictionary).get("target_ref", ""))
		"M4":
			var site_hexes: Array = []
			for entry in scenario.get("control_sites", []):
				var site_data: Dictionary = entry
				var location: Array = site_data.get("logistics_base_hex", [])
				if location.size() == 2:
					site_hexes.append(location.duplicate())
			mission["site_hexes"] = site_hexes
	return mission

static func _hex_disk(center: Array, radius: int) -> Array:
	var out: Array = []
	if center.size() != 2:
		return out
	var cq := int(center[0])
	var cr := int(center[1])
	for dq in range(-radius, radius + 1):
		for dr in range(maxi(-radius, -dq - radius), mini(radius, -dq + radius) + 1):
			out.append([cq + dq, cr + dr])
	return out

## Returned shape matches the live shell's canonical battlefield contract.
## `#` row markers are outside the playable axial hex disk and are omitted from
## terrain/cell_data, so every runtime subsystem sees the real hex boundary.
static func load_battlefield(id: String) -> Dictionary:
	var key := id if id.begins_with("@") else id.to_upper()
	if not key.begins_with("@") and not FILES.has(key):
		return {}
	var src := _read(key)
	if src.is_empty():
		return {}
	var q_min := int(src.get("q_min", 0))
	var r_min := int(src.get("r_min", 0))
	var terrain: Dictionary = {}
	for row_index in range((src.get("rows", []) as Array).size()):
		var row := str((src["rows"] as Array)[row_index])
		for col_index in range(row.length()):
			var glyph := row.substr(col_index, 1)
			if glyph == "#":
				continue
			if not LEGEND.has(glyph):
				push_error("[TutorialBattlefield] %s: unknown terrain glyph %s" % [key, glyph])
				return {}
			terrain["%d,%d" % [q_min + row_index, r_min + col_index]] = int(LEGEND[glyph])

	var river: Dictionary = {}
	for coord in src.get("river_cells", []):
		if coord is Array and coord.size() == 2:
			river["%d,%d" % [int(coord[0]), int(coord[1])]] = true
	for q in range(q_min, q_min + int(src.get("width_hexes", 0))):
		for r in range(r_min, r_min + int(src.get("height_hexes", 0))):
			if terrain.get("%d,%d" % [q, r], -1) == 7:
				river["%d,%d" % [q, r]] = true

	var strongholds: Array = []
	for spec in src.get("strongholds", []):
		var footprint: Array[Vector2i] = []
		for coord in spec.get("footprint", []):
			if coord is Array and coord.size() == 2:
				footprint.append(Vector2i(int(coord[0]), int(coord[1])))
		if footprint.is_empty():
			continue
		strongholds.append({
			"id": str(spec.get("id", "")),
			"name": str(spec.get("name", spec.get("id", ""))),
			"type": str(spec.get("type", "fortress")),
			"owner": str(spec.get("owner", "red")),
			"footprint": footprint,
			"anchor": footprint[0],
			"hp": int(spec.get("hp", 1000)),
			"slots": int(spec.get("slots", 4)),
		})

	var units: Array = []
	for row in src.get("units", []):
		if row is Array and row.size() == 6:
			units.append({
				"id": str(row[0]), "class": str(row[1]), "faction": str(row[2]),
				"q": int(row[3]), "r": int(row[4]), "count": int(row[5]),
			})
	var scenario: Dictionary = (src.get("scenario", {}) as Dictionary).duplicate(true)
	return {
		"id": str(src.get("id", key)) if key.begins_with("@") else key,
		"name": str(src.get("name", key)),
		"name_zh": str(src.get("name_zh", "")),
		"terrain": terrain,
		"river": river,
		"strongholds": strongholds,
		"units": units,
		"scenario": scenario,
		"mission": _adapt_gx_mission(scenario),
		"map_metadata": (src.get("map_metadata", {}) as Dictionary).duplicate(true),
		"tutorial": true,
		"generated": key.begins_with("@"),  # judged by MissionRules (the match driver), not the tutorial runtime
	}
