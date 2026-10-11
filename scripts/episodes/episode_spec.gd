extends RefCounted

## Canonical serialized EpisodeSpec v0. The JSON itself is the setup authority.
const Catalog = preload("res://scripts/battlefields/battlefield_catalog.gd")
const Combat = preload("res://scripts/combat/combat_calculator.gd")
const Movement = preload("res://scripts/core/step3_config.gd")
const SCHEMA := "episode_spec_v0"
const CLASSES := ["hq", "infantry", "spear", "archer", "cavalry", "scout", "siege", "conscript"]
const MATCHUP_KEYS := ["cavalry_vs_archer", "archer_vs_spear", "spear_vs_cavalry", "infantry_vs_archer", "infantry_vs_cavalry", "infantry_vs_spear", "conscript_vs_regular", "scout_vs_regular"]
const SPLIT_MAPS := {
	"train": ["BF01", "BF02", "BF04", "BF07"],
	"validation": ["BF03", "BF05", "BF06"],
	"test": ["BF08", "BF09", "BF10"],
}
const FAMILIES := ["nominal", "mild", "broad", "counterfactual_valid", "held_out"]

static func canonical(value: Variant) -> String:
	if value is int or value is float:
		return JSON.stringify(float(value))
	if value is Dictionary:
		var keys: Array = value.keys()
		keys.sort()
		var parts: Array[String] = []
		for key in keys:
			parts.append(JSON.stringify(str(key)) + ":" + canonical(value[key]))
		return "{" + ",".join(parts) + "}"
	if value is Array:
		var parts: Array[String] = []
		for item in value:
			parts.append(canonical(item))
		return "[" + ",".join(parts) + "]"
	return JSON.stringify(value)

static func identity(spec: Dictionary) -> String:
	var body := spec.duplicate(true)
	body.erase("episode_id")
	# Hash the JSON round trip, since JSON keys are strings and its parser
	# normalizes number types. This is stable before and after serialization.
	var wire: Variant = JSON.parse_string(JSON.stringify(body))
	return canonical(wire).sha256_text()

static func save(spec: Dictionary, path: String) -> bool:
	var check := validate(spec)
	if not bool(check.get("ok", false)):
		return false
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(spec, "  ") + "\n")
	file.close()
	return true

static func load(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not parsed is Dictionary or not bool(validate(parsed).get("ok", false)):
		return {}
	return parsed

static func base_rules() -> Dictionary:
	var stats := {}
	var mp := {}
	for cls in CLASSES:
		stats[cls] = (Combat.BASE_STATS[cls] as Dictionary).duplicate(true)
		mp[cls] = Movement.get_base_movement(cls)
	var matchup := {}
	for key in MATCHUP_KEYS:
		matchup[key] = Combat.MATCHUP_TABLE[key]
	return {
		"class_stats": stats, "base_mp": mp, "matchup": matchup,
		"terrain_standard": Movement.TERRAIN_COSTS_STANDARD.duplicate(true),
		"terrain_scout": Movement.TERRAIN_COSTS_SCOUT.duplicate(true),
	}

## Family and split are separate: a held-out family is never sampled for train.
## Every random draw uses this local RNG; no global Godot RNG is touched.
static func sample(family: String, split: String, seed: int) -> Dictionary:
	if not FAMILIES.has(family) or not SPLIT_MAPS.has(split):
		return {}
	if family == "held_out" and split != "test":
		return {}
	if family == "counterfactual_valid" and split == "test":
		return {}
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var ids: Array = SPLIT_MAPS[split]
	var map_id: String = ids[rng.randi_range(0, ids.size() - 1)]
	var bf := Catalog.load_battlefield(map_id)
	if bf.is_empty():
		return {}
	var source_path: String = Catalog.DATA_DIR + str(Catalog.FILES[map_id])
	var stronghold_hp := {}
	for sh in bf["strongholds"]:
		var base_hp := int(sh["hp"])
		var hp_pct := 0 if family == "nominal" else (10 if family == "mild" else 25)
		stronghold_hp[str(sh["id"])] = maxi(1, int(round(base_hp * (1.0 + float(rng.randi_range(-hp_pct, hp_pct)) / 100.0))))
	var units: Array = []
	var source_units: Array = bf["units"]
	var stride := 1 if family == "nominal" else (2 if family == "mild" else (3 if family == "broad" else 4))
	for i in range(source_units.size()):
		var row: Dictionary = (source_units[i] as Dictionary).duplicate(true)
		var cls: String = Combat.normalize_class_name(str(row["class"]))
		if cls != "hq" and family != "nominal" and rng.randi_range(0, stride) == 0:
			continue
		if cls != "hq" and family == "counterfactual_valid" and rng.randi_range(0, 3) == 0:
			cls = ["infantry", "spear", "archer", "cavalry", "scout"][rng.randi_range(0, 4)]
		row["class"] = cls
		if family != "nominal":
			var pct := 10 if family == "mild" else 25
			row["count"] = maxi(1, int(round(int(row["count"]) * (1.0 + float(rng.randi_range(-pct, pct)) / 100.0))))
		units.append(row)
	var rules := base_rules()
	if family != "nominal":
		var pct := 10 if family == "mild" else 25
		for cls in CLASSES:
			var row: Dictionary = rules["class_stats"][cls]
			for key in ["attack", "defense"]:
				row[key] = snappedf(maxf(1.0, float(row[key]) * (1.0 + float(rng.randi_range(-pct, pct)) / 100.0)), 0.01)
			if family == "counterfactual_valid" and cls == "archer":
				row["range"] = 2
			rules["base_mp"][cls] = clampf(float(rules["base_mp"][cls]) + float(rng.randi_range(-1, 1)), 1.0, 5.0)
		for key in rules["matchup"].keys():
			rules["matchup"][key] = snappedf(clampf(float(rules["matchup"][key]) * (1.0 + float(rng.randi_range(-pct, pct)) / 100.0), 0.4, 2.0), 0.001)
		for terrain in [1, 2, 3]:
			var k := str(terrain)
			rules["terrain_standard"][terrain] = clampf(float(rules["terrain_standard"][terrain]) + float(rng.randi_range(-1, 1)) * 0.25, 1.0, 4.0)
			rules["terrain_scout"][terrain] = minf(float(rules["terrain_standard"][terrain]), clampf(float(rules["terrain_scout"][terrain]) + float(rng.randi_range(-1, 1)) * 0.25, 1.0, 2.0))
	var spec := {
		"schema": SCHEMA, "family": family, "split": split,
		"seeds": {"sample": seed, "combat": seed + 1009, "utility": seed + 2027},
		"map": {"id": map_id, "source_sha256": FileAccess.get_sha256(source_path), "radius": 40, "stronghold_hp": stronghold_hp},
		"rules": rules, "armies": units,
		"objective": {"mode": "native_hq_elimination", "blue": "destroy_red_hq", "red": "destroy_blue_hq", "turn_limit": 0},
	}
	spec["episode_id"] = identity(spec)
	return spec if bool(validate(spec).get("ok", false)) else {}

static func validate(spec: Dictionary) -> Dictionary:
	if str(spec.get("schema", "")) != SCHEMA or not FAMILIES.has(spec.get("family", "")):
		return {"ok": false, "error": "schema or family"}
	var split := str(spec.get("split", ""))
	var map: Dictionary = spec.get("map", {})
	var map_id := str(map.get("id", ""))
	if not SPLIT_MAPS.has(split) or not (SPLIT_MAPS[split] as Array).has(map_id):
		return {"ok": false, "error": "family split or map"}
	if spec.get("family") == "held_out" and split != "test":
		return {"ok": false, "error": "held out family in training"}
	if spec.get("family") == "counterfactual_valid" and split == "test":
		return {"ok": false, "error": "counterfactual family reserved for train/validation"}
	var path: String = Catalog.DATA_DIR + str(Catalog.FILES[map_id])
	if str(map.get("source_sha256", "")) != FileAccess.get_sha256(path) or int(map.get("radius", 0)) != 40:
		return {"ok": false, "error": "map source changed"}
	var objective: Dictionary = spec.get("objective", {})
	if str(objective.get("mode", "")) != "native_hq_elimination" or str(objective.get("blue", "")) != "destroy_red_hq" or str(objective.get("red", "")) != "destroy_blue_hq" or int(objective.get("turn_limit", -1)) != 0:
		return {"ok": false, "error": "unsupported objective"}
	var seeds: Dictionary = spec.get("seeds", {})
	if not seeds.get("sample", null) is int and not seeds.get("sample", null) is float:
		return {"ok": false, "error": "sample seed"}
	if int(seeds.get("combat", -1)) != int(seeds["sample"]) + 1009 or int(seeds.get("utility", -1)) != int(seeds["sample"]) + 2027:
		return {"ok": false, "error": "derived seeds"}
	var rules: Dictionary = spec.get("rules", {})
	for key in ["class_stats", "base_mp", "matchup", "terrain_standard", "terrain_scout"]:
		if not rules.get(key, null) is Dictionary:
			return {"ok": false, "error": "missing rules " + key}
	for cls in CLASSES:
		var row: Dictionary = rules["class_stats"].get(cls, {})
		if row.is_empty() or float(row.get("attack", 0)) < 1 or float(row.get("attack", 0)) > 30 or float(row.get("defense", 0)) < 1 or float(row.get("defense", 0)) > 25 or int(row.get("range", 0)) < 1 or int(row.get("range", 0)) > 3:
			return {"ok": false, "error": "class stats"}
		if float(rules["base_mp"].get(cls, 0)) < 1 or float(rules["base_mp"].get(cls, 0)) > 5:
			return {"ok": false, "error": "movement"}
		var base_range := int(Combat.BASE_STATS[cls]["range"])
		if int(row["range"]) != base_range and not (cls == "archer" and spec.get("family") == "counterfactual_valid" and int(row["range"]) == 2):
			return {"ok": false, "error": "range invariant"}
	for key in MATCHUP_KEYS:
		var mult := float(rules["matchup"].get(key, 0))
		if mult < 0.4 or mult > 2.0:
			return {"ok": false, "error": "matchup bounds"}
	for table_name in ["terrain_standard", "terrain_scout"]:
		var costs: Dictionary = rules[table_name]
		for terrain in [1, 2, 3]:
			var cost := float(costs.get(str(terrain), costs.get(terrain, 0)))
			if cost < 1.0 or cost > 4.0:
				return {"ok": false, "error": "terrain bounds"}
		if float(costs.get("0", costs.get(0, 0))) != 1.0 or float(costs.get("6", costs.get(6, 0))) != 0.5:
			return {"ok": false, "error": "plain/road invariant"}
	for terrain in [1, 2, 3]:
		if float(rules["terrain_scout"].get(str(terrain), rules["terrain_scout"].get(terrain, 0))) > float(rules["terrain_standard"].get(str(terrain), rules["terrain_standard"].get(terrain, 0))):
			return {"ok": false, "error": "scout terrain specialization"}
	for terrain in [8, 9, 10]:
		for table in [rules["terrain_standard"], rules["terrain_scout"]]:
			if float(table.get(str(terrain), table.get(terrain, 0))) != 99.0:
				return {"ok": false, "error": "impassable terrain invariant"}
	var bf := Catalog.load_battlefield(map_id)
	var hp_override: Dictionary = map.get("stronghold_hp", {})
	if hp_override.size() != (bf.get("strongholds", []) as Array).size():
		return {"ok": false, "error": "stronghold set"}
	for sh in bf.get("strongholds", []):
		var sid := str(sh["id"])
		var hp := int(hp_override.get(sid, 0))
		if hp < 500 or hp > 2000:
			return {"ok": false, "error": "stronghold HP bounds"}
	var source: Dictionary = {}
	for u in bf.get("units", []):
		source[str(u["id"])] = u
	var seen := {}
	var hq := {"blue": 0, "red": 0}
	var counts := {"blue": 0, "red": 0}
	for u in spec.get("armies", []):
		if not u is Dictionary:
			return {"ok": false, "error": "unit row"}
		var id := str(u.get("id", ""))
		var faction := str(u.get("faction", ""))
		var cls := str(u.get("class", ""))
		if seen.has(id) or not source.has(id) or not hq.has(faction) or not CLASSES.has(cls) or int(u.get("count", 0)) < 1 or int(u.get("count", 0)) > 1500:
			return {"ok": false, "error": "unit identity/class/count"}
		seen[id] = true
		var original: Dictionary = source[id]
		if str(original["class"]) == "hq" and cls != "hq" or str(original["class"]) != "hq" and cls == "hq":
			return {"ok": false, "error": "HQ identity invariant"}
		if int(u.get("q", 999)) != int(original["q"]) or int(u.get("r", 999)) != int(original["r"]) or faction != str(original["faction"]):
			return {"ok": false, "error": "deployment outside catalog slots"}
		counts[faction] += 1
		if cls == "hq": hq[faction] += 1
	for faction in ["blue", "red"]:
		if hq[faction] != 1 or counts[faction] < 4 or counts[faction] > 40:
			return {"ok": false, "error": "army bounds/HQ"}
	if str(spec.get("episode_id", "")) != identity(spec):
		return {"ok": false, "error": "episode hash"}
	return {"ok": true}
