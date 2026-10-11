class_name Step7ObservationProjector
extends RefCounted

## World Truth -> Blue/Red projected ledgers. Context builders never receive
## the unit manager; they only receive the dictionaries returned here.

const FogScript = preload("res://scripts/step5/fog_of_war.gd")
const HexUtilsScript = preload("res://scripts/core/hex_utils.gd")

var _unit_manager: RefCounted
var _blue_fog: RefCounted
var _cell_data: Dictionary = {}
var _memory: RefCounted
var _strongholds: Array = []
var _red_visible: Dictionary = {}
var _red_last_seen: Dictionary = {}
var _last_turn: int = 1

func configure(unit_manager: RefCounted, blue_fog: RefCounted, cell_data: Dictionary, memory: RefCounted, strongholds: Array = []) -> void:
	_unit_manager = unit_manager
	_blue_fog = blue_fog
	_cell_data = cell_data
	_memory = memory
	_strongholds = strongholds

func capture_turn(turn: int) -> Dictionary:
	_last_turn = turn
	_red_visible = _compute_red_visibility()
	var all_units := _all_units()
	var blue_facts := 0
	var red_facts := 0
	for u in all_units:
		var faction := str(u.get("faction", ""))
		var uid := str(u.get("id", ""))
		if int(u.get("soldier_count", 0)) <= 0 or uid.is_empty():
			continue
		if faction == "blue" and _is_blue_observed(u):
			var red_payload := _observed_enemy_payload(u, true, turn)
			if _memory:
				_memory.record_fact(turn, "red", uid, "red_observer", "blue_contact", red_payload)
			red_facts += 1
			_red_last_seen[uid] = {"turn": turn, "q": int(u.get("q", 0)), "r": int(u.get("r", 0)), "class": str(u.get("class", "unknown"))}
		elif faction == "red" and _is_blue_enemy_visible(u):
			var blue_payload := _observed_enemy_payload(u, false, turn)
			if _memory:
				_memory.record_fact(turn, "blue", uid, "blue_observer", "enemy_contact", blue_payload)
			blue_facts += 1
	# Own-side state is also a deterministic fact for continuity. It contains
	# only the side's own truth and is never placed in the other side's ledger.
	for u in all_units:
		var faction2 := str(u.get("faction", ""))
		if faction2 not in ["blue", "red"] or int(u.get("soldier_count", 0)) <= 0:
			continue
		if _memory:
			_memory.record_fact(turn, faction2, str(u.get("id", "")), faction2 + "_own_state", "own_state", _own_payload(u))
	return {"turn": turn, "blue_contacts": blue_facts, "red_contacts": red_facts, "red_visible_hexes": _red_visible.size()}

func build_blue_knowledge(turn: int) -> Dictionary:
	var own: Array = []
	var current_enemies: Array = []
	var all_units := _all_units()
	for u in all_units:
		if int(u.get("soldier_count", 0)) <= 0:
			continue
		var faction := str(u.get("faction", ""))
		if faction == "blue":
			own.append(_own_payload(u))
		elif faction == "red" and _is_blue_enemy_visible(u):
			current_enemies.append(_observed_enemy_payload(u, false, turn))
	var stale: Array = []
	if _blue_fog:
		for eid in (_blue_fog.get_all_stale() as Dictionary).keys():
			var snapshot: Dictionary = _blue_fog.get_stale_snapshot(str(eid))
			if not snapshot.is_empty():
				stale.append({
					"id": str(eid), "last_seen_turn": int(snapshot.get("turn", 0)),
					"q": int(snapshot.get("q", 0)), "r": int(snapshot.get("r", 0)),
					"class": str(snapshot.get("class", "unknown")),
					"troop_text": str(snapshot.get("troop_text", "병력: 알 수 없음")),
					"morale": "unknown", "food": "unknown", "fatigue": "unknown",
					"contact_state": "stale_last_known"
				})
	var visible_hexes: int = _blue_fog.visible.size() if _blue_fog else 0
	return {
		"side": "blue",
		"current_turn": turn,
		"own_forces": own,
		"current_enemy_observations": current_enemies,
		"last_known_enemy_contacts": stale,
		"visible_hexes": visible_hexes,
		"strongholds": _projected_strongholds(),
		"logistics": _logistics_for(own)
	}

func build_red_knowledge(turn: int) -> Dictionary:
	var own: Array = []
	var observed_blue: Array = []
	for u in _all_units():
		if int(u.get("soldier_count", 0)) <= 0:
			continue
		var faction := str(u.get("faction", ""))
		if faction == "red":
			own.append(_own_payload(u))
		elif faction == "blue" and _is_blue_observed(u):
			observed_blue.append(_observed_friendly_payload(u, turn))
	var red_stale: Array = []
	for eid in _red_last_seen.keys():
		var visible_now := false
		for contact in observed_blue:
			if str(contact.get("id", "")) == str(eid):
				visible_now = true
		if not visible_now:
			var snap: Dictionary = _red_last_seen[eid]
			red_stale.append({
				"id": str(eid), "last_seen_turn": int(snap.get("turn", 0)),
				"q": int(snap.get("q", 0)), "r": int(snap.get("r", 0)),
				"class": str(snap.get("class", "unknown")), "contact_state": "stale_last_known"
			})
	return {
		"side": "red",
		"current_turn": turn,
		"own_forces": own,
		"observed_blue_forces": observed_blue,
		"last_known_blue_contacts": red_stale,
		"visible_hexes": _red_visible.size(),
		"strongholds": _projected_strongholds(),
		"logistics": _logistics_for(own)
	}

func get_red_visible_ids() -> Dictionary:
	return _red_visible.duplicate()

func _all_units() -> Array:
	if _unit_manager == null:
		return []
	if _unit_manager.has_method("get_all_units_including_garrisoned"):
		return _unit_manager.get_all_units_including_garrisoned()
	return _unit_manager.get_all_units()

func _is_blue_enemy_visible(enemy: Dictionary) -> bool:
	if _blue_fog == null:
		return true
	return _blue_fog.is_enemy_visible(enemy)

func _is_blue_observed(player_unit: Dictionary) -> bool:
	# STEP 2 full-information symmetry: when no fog system exists at all
	# (the DEV sandbox signal — mirrors _is_blue_enemy_visible's null rule),
	# RED observes every BLUE formation. Production and sim probes always
	# carry a fog object, so radius-based RED visibility there is unchanged.
	if _blue_fog == null:
		return true
	var key := "%d,%d" % [int(player_unit.get("q", 0)), int(player_unit.get("r", 0))]
	return _red_visible.has(key)

func _observed_enemy_payload(u: Dictionary, for_red: bool, turn: int) -> Dictionary:
	if not for_red:
		var obs: Dictionary = _blue_fog.get_enemy_observation(u, turn) if _blue_fog else {}
		var troop_txt: String = str(obs.get("troop_text", ""))
		if troop_txt.is_empty():
			troop_txt = str(u.get("soldier_count", "unknown"))
		return {
			"id": str(u.get("id", "")), "q": int(u.get("q", 0)), "r": int(u.get("r", 0)),
			"class": str(u.get("class", "unknown")), "class_kr": str(obs.get("class_kr", str(u.get("class", "???")))),
			"troop_text": troop_txt,
			"morale": "unknown", "food": "unknown", "fatigue": "unknown",
			"scout_observed": bool(obs.get("scout_observed", true if _blue_fog == null else false)),
			"combat_assessed": bool(obs.get("combat_assessed", true if _blue_fog == null else false)),
			"contact_turn": turn, "contact_state": "current_visible"
		}
	return {
		"id": str(u.get("id", "")), "q": int(u.get("q", 0)), "r": int(u.get("r", 0)),
		"class": str(u.get("class", "unknown")),
		"troop_text": FogScript.estimate_band(int(u.get("soldier_count", 0)), "%s:%d:red" % [str(u.get("id", "")), turn]),
		"morale": "unknown", "food": "unknown", "fatigue": "unknown",
		"contact_turn": turn, "contact_state": "current_observed_by_red"
	}

func _observed_friendly_payload(u: Dictionary, turn: int) -> Dictionary:
	return _observed_enemy_payload(u, true, turn)

func _own_payload(u: Dictionary) -> Dictionary:
	var max_count := maxi(1, int(u.get("max_count", u.get("soldier_count", 1))))
	return {
		"id": str(u.get("id", "")), "class": str(u.get("class", "unknown")),
		"remaining_mp": float(u.get("remaining_mp", 0.0)), "base_mp": float(u.get("base_mp", 0.0)),
		"faction": str(u.get("faction", "")), "q": int(u.get("q", 0)), "r": int(u.get("r", 0)),
		"soldier_count": int(u.get("soldier_count", 0)), "max_count": max_count,
		"morale": float(u.get("morale", 100.0)), "local_supply": float(u.get("local_supply", 0.0)),
		"supply_days": float(u.get("local_supply", 0.0)) / float(maxi(1, int(u.get("max_count", 1))) * 0.01),
		"fatigue": float(u.get("fatigue", 0.0)), "routed": bool(u.get("routed", false)),
		"garrisoned": bool(u.get("garrisoned", false)), "action_ended": bool(u.get("action_ended", false)),
		"is_convoy": bool(u.get("is_convoy", false))
	}

func _logistics_for(own: Array) -> Dictionary:
	var troops := 0
	var supply := 0.0
	var morale := 0.0
	var count := 0
	for u in own:
		if str(u.get("class", "")) == "supply":
			continue
		troops += int(u.get("soldier_count", 0))
		supply += float(u.get("local_supply", 0.0))
		morale += float(u.get("morale", 0.0))
		count += 1
	return {"troops": troops, "portable_supply": supply, "average_morale": morale / float(maxi(1, count)), "formation_count": count}

func _projected_strongholds() -> Array:
	var out: Array = []
	for sh in _strongholds:
		if sh is Dictionary:
			out.append((sh as Dictionary).duplicate(true))
	return out

func _compute_red_visibility() -> Dictionary:
	var visible: Dictionary = {}
	for u in _all_units():
		if str(u.get("faction", "")) != "red" or int(u.get("soldier_count", 0)) <= 0:
			continue
		if bool(u.get("garrisoned", false)) or bool(u.get("routed", false)):
			continue
		var origin := Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))
		var radius := 4 if str(u.get("class", "")) in ["scout", "scouts"] else 2
		for q in range(origin.x - radius, origin.x + radius + 1):
			for r in range(origin.y - radius, origin.y + radius + 1):
				var target := Vector2i(q, r)
				if HexUtilsScript.hex_distance_axial(origin, target) > radius:
					continue
				var key := "%d,%d" % [q, r]
				if not _cell_data.has(key) or not _has_los(origin, target):
					continue
				visible[key] = true
	return visible

func _has_los(origin: Vector2i, target: Vector2i) -> bool:
	if origin == target:
		return true
	var line := _hex_line(origin, target)
	var distance := HexUtilsScript.hex_distance_axial(origin, target)
	for i in range(1, line.size() - 1):
		var cell: Variant = _cell_data.get("%d,%d" % [line[i].x, line[i].y], null)
		if cell == null:
			return false
		var terrain: int = int(cell.get("terrain", 0)) if cell is Dictionary else int(cell.terrain)
		if terrain == 1 or (terrain == 2 and distance >= 3):
			return false
	return true

func _hex_line(a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	var n := HexUtilsScript.hex_distance_axial(a, b)
	var out: Array[Vector2i] = []
	if n == 0:
		out.append(a)
		return out
	var ax := float(a.x); var az := float(a.y); var ay := -ax - az
	var bx := float(b.x); var bz := float(b.y); var by := -bx - bz
	for i in range(n + 1):
		var t := float(i) / float(n)
		out.append(_cube_round(ax + (bx - ax) * t, ay + (by - ay) * t, az + (bz - az) * t))
	return out

func _cube_round(fx: float, fy: float, fz: float) -> Vector2i:
	var rx := roundi(fx); var ry := roundi(fy); var rz := roundi(fz)
	var dx: float = abs(float(rx) - fx); var dy: float = abs(float(ry) - fy); var dz: float = abs(float(rz) - fz)
	if dx > dy and dx > dz:
		rx = -ry - rz
	elif dy > dz:
		ry = -rx - rz
	else:
		rz = -rx - ry
	return Vector2i(rx, rz)

func known_occupancy(side: String) -> Dictionary:
	var result: Dictionary = {}
	for unit in _all_units():
		if int(unit.get("soldier_count", 0)) <= 0 or bool(unit.get("garrisoned", false)):
			continue
		if str(unit.get("faction", "")) == side or (side == "blue" and _is_blue_enemy_visible(unit)) or (side == "red" and _is_blue_observed(unit)):
			result["%d,%d" % [int(unit.q), int(unit.r)]] = str(unit.id)
	return result

func is_contact_visible(side: String, id: String) -> bool:
	for unit in _all_units():
		if str(unit.get("id", "")) == id and str(unit.get("faction", "")) != side:
			return _is_blue_enemy_visible(unit) if side == "blue" else _is_blue_observed(unit)
	return false


## Public side-visibility query for conservative autonomous movement. A route
## across currently unseen hexes may collide with a concealed formation; bots
## may decline that route without consulting world occupancy.
func is_hex_visible_for_side(side: String, q: int, r: int) -> bool:
	if _blue_fog == null:
		return side == "blue" or side == "red"
	if side == "blue":
		return bool(_blue_fog.call("is_hex_visible", q, r))
	if side == "red":
		return _red_visible.has("%d,%d" % [q, r])
	return false
