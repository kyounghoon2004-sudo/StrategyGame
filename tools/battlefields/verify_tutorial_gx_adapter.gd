extends SceneTree

const Catalog = preload("res://scripts/battlefields/tutorial_battlefield_catalog.gd")
const MissionScenario = preload("res://scripts/gx_missions/mission_scenario.gd")
const HexCellCls = preload("res://scripts/core/hex_cell.gd")
const Step3PathfindingCls = preload("res://scripts/step3/step3_pathfinding.gd")
const Step3ConfigCls = preload("res://scripts/core/step3_config.gd")

func _initialize() -> void:
	for mission_id in Catalog.ids():
		var battlefield: Dictionary = Catalog.load_battlefield(str(mission_id))
		if battlefield.is_empty():
			push_error("tutorial adapter failed to load " + str(mission_id))
			quit(1)
			return
		var mission: Dictionary = battlefield.get("mission", {})
		var normalized: Dictionary = MissionScenario.normalize(mission)
		if normalized.has("error") or str(normalized.get("family", "")) != str(mission_id):
			push_error("GX mission normalization failed for %s: %s" % [str(mission_id), str(normalized)])
			quit(1)
			return
		var terrain: Dictionary = battlefield.get("terrain", {})
		var cell_data: Dictionary = {}
		for key in terrain.keys():
			var parts := str(key).split(",")
			var q := int(parts[0])
			var r := int(parts[1])
			cell_data[key] = HexCellCls.new(q, r, int(terrain[key]))
		var metadata: Dictionary = battlefield.get("map_metadata", {})
		var dimensions: Dictionary = metadata.get("playable_dimensions", {})
		var radius := int(dimensions.get("hex_radius", 0))
		var void_corner := Vector2i(radius, radius)
		var void_key := "%d,%d" % [void_corner.x, void_corner.y]
		var edge_route: Variant = Step3PathfindingCls.find_route(
			Vector2i.ZERO, void_corner, "conscript", 10.0, 10.0,
			Step3ConfigCls.MarchPolicy.RED_ALLOWED, cell_data, {}, {}, "blue"
		)
		if cell_data.has(void_key) or edge_route.found or edge_route.is_valid_destination:
			push_error("%s hex-map void corner became pathable: %s" % [str(mission_id), void_key])
			quit(1)
			return
		var envelope: Variant = Step3PathfindingCls.calculate_envelope(
			Vector2i.ZERO, "conscript", 100.0, 100.0,
			Step3ConfigCls.MarchPolicy.RED_ALLOWED, cell_data, {}, {}, "blue"
		)
		for reached in envelope.reachable_data.keys():
			var reached_key := "%d,%d" % [reached.x, reached.y]
			if not cell_data.has(reached_key):
				push_error("%s pathfinding envelope escaped its hex mask at %s" % [str(mission_id), reached_key])
				quit(1)
				return
			for step in envelope.reachable_data[reached].get("path", []):
				var step_key := "%d,%d" % [step.x, step.y]
				if not cell_data.has(step_key):
					push_error("%s route crossed a void hex at %s" % [str(mission_id), step_key])
					quit(1)
					return
		if mission_id == "M4":
			var sites: Array = normalized.get("site_hexes", [])
			if sites.size() != 3:
				push_error("M4 adapter must expose exactly three logistics-base hexes")
				quit(1)
				return
			var blocked: Dictionary = {}
			for stronghold in battlefield.get("strongholds", []):
				for coord in (stronghold as Dictionary).get("footprint", []):
					blocked["%d,%d" % [coord.x, coord.y]] = true
			for site_hex in sites:
				var key := "%d,%d" % [int(site_hex[0]), int(site_hex[1])]
				if blocked.has(key):
					push_error("M4 logistics base hex overlaps a blocked stronghold hex: " + key)
					quit(1)
					return
	print("PASS: M1-M5 adapters normalize, axial void corners stay outside pathfinding, and M4 exposes three logistics-base sites.")
	quit(0)
