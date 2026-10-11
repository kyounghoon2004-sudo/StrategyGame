extends RefCounted

## Separate, playable DEV map collection. RL canonical files and ids() remain
## exclusively owned by battlefield_catalog.gd.

const FORMAT := "canonical_battlefield_v1"
const SET_ID := "handcrafted_v1"
const SET_TITLE := "수제 전장 · Handcrafted Battlefields"
const DATA_DIR := "res://data/battlefields/handcrafted_v1/"
const FILES := {"HC01": "hc01_cheongha_gorge.json"}
const LEGEND := {".": 0, "M": 1, "F": 2, "S": 3, "V": 5, "R": 6, "B": 6, "W": 7, "X": 9, "C": 11}


static func ids() -> Array:
	var out := FILES.keys()
	out.sort()
	return out


static func has_battlefield(id: String) -> bool:
	return FILES.has(id.to_upper())


static func summary_of(id: String) -> Dictionary:
	var d := _read(id)
	if d.is_empty():
		return {}
	var info: Dictionary = d.get("info", {})
	var sh: Array = []
	for s in d.get("strongholds", []):
		sh.append(str(s.get("name", s.get("id", ""))))
	return {
		"id": id.to_upper(), "name": str(d.get("name", "")),
		"name_zh": str(d.get("name_zh", "")),
		"terrain": str(info.get("terrain", "")),
		"tactical": str(info.get("tactical", "")),
		"asymmetry": str(info.get("asymmetry", "")),
		"units": info.get("units", {}), "strongholds": sh,
	}


static func _read(id: String) -> Dictionary:
	var key := id.to_upper()
	if not FILES.has(key):
		return {}
	var path: String = DATA_DIR + str(FILES[key])
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("[HandcraftedBattlefield] cannot open " + path)
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		push_error("[HandcraftedBattlefield] invalid JSON " + path)
		return {}
	var data: Dictionary = parsed
	if str(data.get("format", "")) != FORMAT or str(data.get("set", "")) != SET_ID or str(data.get("id", "")) != key:
		push_error("[HandcraftedBattlefield] format/set/id mismatch " + path)
		return {}
	return data


static func load_battlefield(id: String) -> Dictionary:
	var key := id.to_upper()
	var src := _read(key)
	if src.is_empty():
		return {}
	var q_min := int(src.get("q_min", -40))
	var r_min := int(src.get("r_min", -40))
	var terrain := {}
	var river := {}
	var rows: Array = src.get("rows", [])
	if rows.size() != 81:
		push_error("[HandcraftedBattlefield] expected 81 q-rows")
		return {}
	for i in range(rows.size()):
		var row: String = str(rows[i])
		if row.length() != 81:
			push_error("[HandcraftedBattlefield] expected 81 r-columns in row %d" % i)
			return {}
		var q := q_min + i
		for j in range(row.length()):
			var ch: String = row[j]
			if ch == " ":
				continue
			if not LEGEND.has(ch):
				push_error("[HandcraftedBattlefield] bad terrain char '%s'" % ch)
				return {}
			var k := "%d,%d" % [q, r_min + j]
			terrain[k] = int(LEGEND[ch])
			if ch == "W" or ch == "B":
				river[k] = true
	if terrain.size() != 4921:
		push_error("[HandcraftedBattlefield] expected 4921 playable cells")
		return {}
	var strongholds: Array = []
	for s in src.get("strongholds", []):
		var fp: Array[Vector2i] = []
		for h in s.get("footprint", []):
			fp.append(Vector2i(int(h[0]), int(h[1])))
		if fp.is_empty():
			push_error("[HandcraftedBattlefield] empty stronghold footprint")
			return {}
		strongholds.append({
			"id": str(s.get("id", "")), "name": str(s.get("name", "")),
			"type": str(s.get("type", "fortress")),
			"owner": str(s.get("owner", "red")),
			"footprint": fp, "anchor": fp[0],
			"hp": int(s.get("hp", 1000)), "slots": int(s.get("slots", 4)),
		})
	var units: Array = []
	for u in src.get("units", []):
		units.append({"id": str(u[0]), "class": str(u[1]),
			"faction": str(u[2]), "q": int(u[3]), "r": int(u[4]),
			"count": int(u[5])})
	return {
		"id": key, "name": str(src.get("name", key)),
		"name_zh": str(src.get("name_zh", "")),
		"terrain": terrain, "river": river,
		"strongholds": strongholds, "units": units,
	}
