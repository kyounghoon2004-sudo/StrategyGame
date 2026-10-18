extends RefCounted

## GX MISSIONS v1 — the ONE config file loader (scripts/gx_missions/gx_missions_config.json).
## Every numeric value used by MissionRules / MissionPolicy / MissionGxBot comes from here.

const PATH := "res://scripts/gx_missions/gx_missions_config.json"

static var _cache: Dictionary = {}
## Board-derived distances (set by MissionRules.setup from the live map, cleared on exit). Empty = the
## default board (diameter default_map_diameter).
static var _map: Dictionary = {}
static var _scaled: Dictionary = {}


static func load_config() -> Dictionary:
	if _cache.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
		if parsed is Dictionary:
			_cache = parsed
		else:
			push_error("[GxMissions] config unreadable: " + PATH)
	return _cache


static func section(name: String) -> Dictionary:
	var base: Dictionary = load_config().get(name, {})
	if name != "rules":  # GX distances (policy / hq) stay fixed
		return base
	if not _scaled.has(name):
		_scaled[name] = _derive_section(name, base)
	return _scaled[name]


## Set the board size: the rule distances follow the map diameter (see "_map_doc"); GX distances do not.
static func set_map_diameter(diameter: int) -> Dictionary:
	var rc: Dictionary = load_config().get("rules", {})
	var presets: Dictionary = rc.get("map_presets", {})
	var d := maxi(1, diameter)
	# The preset of the nearest board size (80 or 40).
	var best := ""
	for k in presets.keys():
		if best == "" or absi(int(k) - d) < absi(int(best) - d):
			best = str(k)
	var p: Dictionary = presets.get(best, {})
	_map = {
		"map_diameter": d,
		"map_preset": int(best),
		"supply_link_range": int(p.get("supply_link_range", 20)),
		"morale_zone_near_max": int(p.get("morale_zone_near_max", 10)),
		"morale_zone_mid_max": int(p.get("morale_zone_mid_max", 20)),
		"base_build_cooldown": int(p.get("base_build_cooldown", 22)),
		"unit_mp": (p.get("unit_mp", {}) as Dictionary).duplicate(),
	}
	_scaled.clear()
	return _map.duplicate(true)


static func clear_map() -> void:
	_map = {}
	_scaled.clear()


static func map_values() -> Dictionary:
	if _map.is_empty():
		set_map_diameter(int((load_config().get("rules", {}) as Dictionary).get("default_map_diameter", 80)))
	return _map.duplicate()


static func _derive_section(name: String, base: Dictionary) -> Dictionary:
	var mv := map_values()
	var out := base.duplicate(true)
	for k in ["map_diameter", "map_preset", "supply_link_range", "morale_zone_near_max", "morale_zone_mid_max", "base_build_cooldown", "unit_mp"]:
		out[k] = mv[k]
	return out


static func num(sect: String, key: String) -> float:
	var s := section(sect)
	if not s.has(key):
		push_error("[GxMissions] missing config value %s.%s" % [sect, key])
		return 0.0
	return float(s[key])
