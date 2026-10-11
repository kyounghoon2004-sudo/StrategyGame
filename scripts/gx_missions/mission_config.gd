extends RefCounted

## GX MISSIONS v1 — the ONE config file loader (scripts/gx_missions/gx_missions_config.json).
## Every numeric value used by MissionRules / MissionPolicy / MissionGxBot comes from here.

const PATH := "res://scripts/gx_missions/gx_missions_config.json"

static var _cache: Dictionary = {}


static func load_config() -> Dictionary:
	if _cache.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
		if parsed is Dictionary:
			_cache = parsed
		else:
			push_error("[GxMissions] config unreadable: " + PATH)
	return _cache


static func section(name: String) -> Dictionary:
	return (load_config().get(name, {}) as Dictionary)


static func num(sect: String, key: String) -> float:
	var s := section(sect)
	if not s.has(key):
		push_error("[GxMissions] missing config value %s.%s" % [sect, key])
		return 0.0
	return float(s[key])
