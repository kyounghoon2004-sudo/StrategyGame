extends RefCounted

## GX MISSIONS v1 — the ONE config file loader (scripts/gx_missions/gx_missions_config.json).
## Every numeric value used by MissionRules / MissionPolicy / MissionGxBot comes from here.

const PATH := "res://scripts/gx_missions/gx_missions_config.json"

static var _cache: Dictionary = {}
## Board-derived distances (set by MissionRules.setup from the live map, cleared on exit). Empty = the
## reference board (diameter gx_dist_ref_diameter).
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
	if not name in ["rules", "policy", "hq"]:
		return base
	if not _scaled.has(name):
		_scaled[name] = _derive_section(name, base)
	return _scaled[name]


## Set the board size: every distance in rules / policy / hq follows the map diameter (see "_map_doc").
static func set_map_diameter(diameter: int) -> Dictionary:
	var rc: Dictionary = load_config().get("rules", {})
	var d := maxi(1, diameter)
	var rng := maxi(int(rc.get("supply_link_range_min", 2)), roundi(float(d) * float(rc.get("supply_link_range_frac", 0.25))))
	_map = {
		"map_diameter": d,
		"supply_link_range": rng,
		"morale_zone_near_max": maxi(1, roundi(float(rng) * 0.5)),
		"morale_zone_mid_max": rng,
		"base_build_cooldown": rng + int(rc.get("base_build_cooldown_extra", 2)),
		"hq_mp": maxi(int(rc.get("hq_mp_min", 1)), roundi(float(rng) * float(rc.get("hq_mp_frac", 0.5)))),
		"gx_dist_scale": float(d) / float(rc.get("gx_dist_ref_diameter", 16)),
	}
	_scaled.clear()
	return _map.duplicate()


static func clear_map() -> void:
	_map = {}
	_scaled.clear()


static func map_values() -> Dictionary:
	if _map.is_empty():
		set_map_diameter(int((load_config().get("rules", {}) as Dictionary).get("gx_dist_ref_diameter", 16)))
	return _map.duplicate()


static func _derive_section(name: String, base: Dictionary) -> Dictionary:
	var mv := map_values()
	var out := base.duplicate(true)
	if name == "rules":
		for k in ["map_diameter", "supply_link_range", "morale_zone_near_max", "morale_zone_mid_max", "base_build_cooldown", "hq_mp"]:
			out[k] = mv[k]
		return out
	var keys: Array = ((load_config().get("rules", {}) as Dictionary).get("gx_scaled_keys", {}) as Dictionary).get(name, [])
	for k in keys:
		if out.has(k):
			out[k] = maxi(1, roundi(float(out[k]) * float(mv["gx_dist_scale"])))
	return out


static func num(sect: String, key: String) -> float:
	var s := section(sect)
	if not s.has(key):
		push_error("[GxMissions] missing config value %s.%s" % [sect, key])
		return 0.0
	return float(s[key])
