class_name Step5FogOfWar
extends RefCounted

## STEP-05 Information Warfare — Fog of War + LOS + Scout Intelligence.
## Three hex states: UNEXPLORED / EXPLORED (past-seen) / CURRENTLY_VISIBLE.
## Player visibility = union of all living friendly observers with hex LOS.
## Observation API is the ONLY channel the future Advisor SLM may consume.

enum FogState { UNEXPLORED, EXPLORED, VISIBLE }

# Canonical base vision (hexes). Scout value is provisional/configurable.
var normal_vision: int = 2
var scout_vision: int = 4

# "q,r" -> true
var explored: Dictionary = {}
var visible: Dictionary = {}
# "q,r" -> true when the hex is currently seen by at least one Scout.
var visible_by_scout: Dictionary = {}
# Strategic objectives stay terrain-known even through fog.
var objective_hexes: Dictionary = {}
# enemy_id -> {"turn": int, "q": int, "r": int, "class": String}
var last_seen: Dictionary = {}
# enemy_id -> true for enemies visible at the previous recompute (discovery edge).
var _prev_visible_enemies: Dictionary = {}
# STEP-05R1 contact memory: combat-assessed enemies + frozen stale snapshots.
# combat_assessed: enemy_id -> true (player has directly fought this formation).
# assessed_health: enemy_id -> float last OBSERVED health ratio (0..1).
# stale_contacts: enemy_id -> frozen snapshot (never updated while hidden).
# ever_seen: enemy_id -> true (FIRST discovery vs re-discovery).
var combat_assessed: Dictionary = {}
var assessed_health: Dictionary = {}
var stale_contacts: Dictionary = {}
var ever_seen: Dictionary = {}
# STEP-06R1 §4-6: friendly command-loss memory. unit_id -> frozen snapshot
# {turn,q,r,class} taken at loss of command; NEVER updated while hidden.
var friendly_stale: Dictionary = {}

# Terrain codes (shared with battlefield generator).
const TERRAIN_MOUNTAIN: int = 1
const TERRAIN_FOREST: int = 2

const CLASS_KR_SHORT := {
	"infantry": "보병",
	"spearman": "창병",
	"spearmen": "창병",
	"archer": "궁병",
	"archers": "궁병",
	"cavalry": "기병",
	"scout": "정찰병",
	"scouts": "정찰병",
	"conscript": "징집병",
	"conscripts": "징집병",
	"siege": "공성병",
}

static func class_to_kr_short(uclass: String) -> String:
	return CLASS_KR_SHORT.get(uclass.to_lower(), uclass.capitalize())

static func is_scout_class(uclass: String) -> bool:
	var n: String = uclass.to_lower()
	return n == "scout" or n == "scouts"

func reset() -> void:
	explored.clear()
	visible.clear()
	visible_by_scout.clear()
	last_seen.clear()
	_prev_visible_enemies.clear()
	combat_assessed.clear()
	assessed_health.clear()
	stale_contacts.clear()
	ever_seen.clear()
	friendly_stale.clear()

# STEP-05R1: direct combat (either direction) makes the enemy COMBAT-ASSESSED.
# ratio is the health ratio OBSERVED at that moment; frozen while hidden.
func mark_combat_engaged(enemy_id: String, health_ratio: float) -> void:
	if enemy_id == "":
		return
	combat_assessed[enemy_id] = true
	assessed_health[enemy_id] = clampf(health_ratio, 0.0, 1.0)

func is_combat_assessed(enemy_id: String) -> bool:
	return bool(combat_assessed.get(enemy_id, false))

func get_assessed_ratio(enemy_id: String) -> float:
	return float(assessed_health.get(enemy_id, -1.0))

func get_stale_snapshot(enemy_id: String) -> Dictionary:
	return (stale_contacts.get(enemy_id, {}) as Dictionary).duplicate()

func get_all_stale() -> Dictionary:
	return stale_contacts.duplicate()

func was_ever_seen(enemy_id: String) -> bool:
	return ever_seen.has(enemy_id)

# ------------------------------------------------------------------
# STEP-06R1 §4-6: friendly command-loss observation. A formation that has
# genuinely lost command (ROUT) stops contributing LOS and leaves only a
# frozen last-known friendly contact. Recontact/rally clears it.
# ------------------------------------------------------------------
func note_friendly_command_loss(unit_id: String, q: int, r: int, uclass: String, turn: int) -> void:
	if unit_id == "":
		return
	if friendly_stale.has(unit_id):
		return # frozen — never overwrite while hidden
	friendly_stale[unit_id] = {"unit_id": unit_id, "turn": turn, "q": q, "r": r, "class": uclass}

func clear_friendly_command_loss(unit_id: String) -> void:
	friendly_stale.erase(unit_id)

func is_friendly_command_lost(unit_id: String) -> bool:
	return friendly_stale.has(unit_id)

func get_all_friendly_stale() -> Dictionary:
	return friendly_stale.duplicate()

func set_objective_hexes(hexes: Array) -> void:
	objective_hexes.clear()
	for h in hexes:
		if h is Vector2i:
			objective_hexes["%d,%d" % [h.x, h.y]] = true
	for key in objective_hexes.keys():
		explored[key] = true

func is_hex_visible(q: int, r: int) -> bool:
	return visible.has("%d,%d" % [q, r])

func is_hex_explored(q: int, r: int) -> bool:
	return explored.has("%d,%d" % [q, r])

func is_hex_scout_observed(q: int, r: int) -> bool:
	return visible_by_scout.has("%d,%d" % [q, r])

func get_fog_state(q: int, r: int) -> int:
	var key: String = "%d,%d" % [q, r]
	if visible.has(key):
		return FogState.VISIBLE
	if explored.has(key) or objective_hexes.has(key):
		return FogState.EXPLORED
	return FogState.UNEXPLORED

func is_enemy_visible(enemy: Dictionary) -> bool:
	if enemy.is_empty():
		return false
	return is_hex_visible(int(enemy.get("q", -999)), int(enemy.get("r", -999)))

func is_enemy_scout_observed(enemy: Dictionary) -> bool:
	if enemy.is_empty():
		return false
	return is_hex_scout_observed(int(enemy.get("q", -999)), int(enemy.get("r", -999)))

func get_last_seen(enemy_id: String) -> Dictionary:
	return last_seen.get(enemy_id, {})

# ------------------------------------------------------------------
# Recompute — call only on discrete game-state changes (never per-frame).
# friendly_units: blue field units (alive). all_units: every field unit.
# Returns {"visible_hexes": int, "newly_visible_enemies": Array[Dictionary]}.
# ------------------------------------------------------------------
func recompute(friendly_units: Array, all_units: Array, cell_data: Dictionary, turn: int) -> Dictionary:
	visible.clear()
	visible_by_scout.clear()
	for key in objective_hexes.keys():
		explored[key] = true
	for u in friendly_units:
		if int(u.get("soldier_count", 0)) <= 0:
			continue
		if bool(u.get("garrisoned", false)):
			continue
		# STEP-06R1 §5: command-lost formations contribute no LOS from their
		# hidden true position and must not leak it.
		if bool(u.get("routed", false)):
			continue
		var origin := Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))
		var radius: int = scout_vision if is_scout_class(str(u.get("class", ""))) else normal_vision
		var scout: bool = is_scout_class(str(u.get("class", "")))
		for dq in range(-radius, radius + 1):
			for dr in range(-radius, radius + 1):
				var cand := Vector2i(origin.x + dq, origin.y + dr)
				if _axial_distance(origin, cand) > radius:
					continue
				var key: String = "%d,%d" % [cand.x, cand.y]
				if not cell_data.has(key):
					continue
				if not _has_los(origin, cand, cell_data):
					continue
				visible[key] = true
				if scout:
					visible_by_scout[key] = true
				explored[key] = true
	# Update last-seen registry + discovery edge detection.
	# STEP-05R1: last_seen carries a frozen-capable record (scout flag, troop
	# text, observed health). Visible->hidden transitions freeze a stale
	# snapshot that is NEVER updated until re-discovery (no truth leak).
	var newly: Array = []
	var now_visible: Dictionary = {}
	var present_red: Dictionary = {}
	for e in all_units:
		if str(e.get("faction", "")) != "red":
			continue
		if int(e.get("soldier_count", 0)) <= 0:
			continue
		if bool(e.get("garrisoned", false)):
			continue
		var eid: String = str(e.get("id", ""))
		present_red[eid] = true
		if is_enemy_visible(e):
			now_visible[eid] = true
			var _is_first: bool = not ever_seen.has(eid)
			ever_seen[eid] = true
			var escout: bool = is_enemy_scout_observed(e)
			var ecount: int = int(e.get("soldier_count", 0))
			# STEP-05R2 §13/§21/§24: last_seen shares ONE model with badge+panel.
			# Combat-assessed approx wins over scout range; frozen on loss of contact.
			var etroop: String = "병력: ???"
			var ecombat: bool = bool(combat_assessed.get(eid, false))
			if ecombat:
				etroop = "병력: " + combat_troop_text(ecount)
			elif escout:
				etroop = "병력: " + estimate_band(ecount, "%s:%d" % [eid, turn])
			var erh: float = -1.0
			if bool(combat_assessed.get(eid, false)):
				var emax: int = maxi(1, int(e.get("max_count", ecount)))
				erh = clampf(float(ecount) / float(emax), 0.0, 1.0)
				assessed_health[eid] = erh
			last_seen[eid] = {
				"turn": turn,
				"q": int(e.get("q", 0)),
				"r": int(e.get("r", 0)),
				"class": str(e.get("class", "")),
				"scout": escout,
				"troop_text": etroop,
				"health_ratio": erh,
				"has_health": erh >= 0.0,
				"combat_assessed": ecombat,
			}
			stale_contacts.erase(eid)
			if not _prev_visible_enemies.has(eid):
				var _ec: Dictionary = (e as Dictionary).duplicate()
				_ec["first_discovery"] = _is_first
				newly.append(_ec)
		elif _prev_visible_enemies.has(eid):
			# Fresh loss of contact — freeze the last observed record as-is.
			var frozen: Dictionary = (last_seen.get(eid, {}) as Dictionary).duplicate()
			if not frozen.is_empty():
				stale_contacts[eid] = {
					"enemy_id": eid,
					"turn": int(frozen.get("turn", turn)),
					"q": int(frozen.get("q", 0)),
					"r": int(frozen.get("r", 0)),
					"class": str(frozen.get("class", "")),
					"scout": bool(frozen.get("scout", false)),
					"troop_text": str(frozen.get("troop_text", "병력: ???")),
					"health_ratio": float(frozen.get("health_ratio", -1.0)),
					"has_health": bool(frozen.get("has_health", false)),
					"combat_assessed": bool(frozen.get("combat_assessed", combat_assessed.get(eid, false))),
				}
	# Destroyed enemies leave no stale marker behind.
	for eid in stale_contacts.keys():
		if not present_red.has(eid):
			stale_contacts.erase(eid)
	# STEP-06R1 §6: destroyed friendlies leave no stale marker; rallied
	# (present and back under command) self-heal even if a clear was missed.
	var present_blue: Dictionary = {}
	for e in all_units:
		if str(e.get("faction", "")) != "blue":
			continue
		if int(e.get("soldier_count", 0)) <= 0:
			continue
		if bool(e.get("garrisoned", false)):
			continue
		present_blue[str(e.get("id", ""))] = not bool(e.get("routed", false))
	for fid in friendly_stale.keys():
		if not present_blue.has(fid) or bool(present_blue[fid]):
			friendly_stale.erase(fid)
	_prev_visible_enemies = now_visible
	return {"visible_hexes": visible.size(), "newly_visible_enemies": newly}

# ------------------------------------------------------------------
# Observation API (Advisor boundary: never expose hidden truth).
# ------------------------------------------------------------------
func get_enemy_observation(enemy: Dictionary, turn: int) -> Dictionary:
	var base: Dictionary = {
		"visible": false,
		"scout_observed": false,
		"class_kr": "???",
		"troop_text": "병력: 알 수 없음",
		"morale_text": "사기: 알 수 없음",
	}
	if enemy.is_empty():
		return base
	if not is_enemy_visible(enemy):
		return base
	var eid: String = str(enemy.get("id", ""))
	var uclass: String = str(enemy.get("class", ""))
	var scout: bool = is_enemy_scout_observed(enemy)
	base["visible"] = true
	base["scout_observed"] = scout
	base["class_kr"] = class_to_kr_short(uclass)
	# STEP-05R2 §17-§18/§21: DIRECT COMBAT outranks scout range.
	# Combat-assessed => approximate CURRENT remaining strength even on normal obs.
	if bool(combat_assessed.get(eid, false)):
		base["troop_text"] = "병력: " + combat_troop_text(int(enemy.get("soldier_count", 0)))
		base["combat_assessed"] = true
	elif scout:
		base["troop_text"] = "병력: " + estimate_band(int(enemy.get("soldier_count", 0)), "%s:%d" % [eid, turn])
		base["combat_assessed"] = false
	else:
		base["troop_text"] = "병력: ???"
		base["combat_assessed"] = false
	# STEP-05R1: direct combat reveals remaining-strength while CURRENTLY visible.
	if bool(combat_assessed.get(eid, false)):
		var emax2: int = maxi(1, int(enemy.get("max_count", enemy.get("soldier_count", 1))))
		base["health_ratio"] = clampf(float(enemy.get("soldier_count", 0)) / float(emax2), 0.0, 1.0)
		base["has_health"] = true
	else:
		base["health_ratio"] = -1.0
		base["has_health"] = false
	return base

## Deterministic coarse estimate band. Same (count, key) -> same band, no flicker.
static func estimate_band(true_count: int, seed_key: String) -> String:
	var half: int = maxi(50, int(round(float(maxi(0, true_count)) * 0.20)))
	var h: int = absi(hash(seed_key))
	var shift: int = (h % 21) - 10 # -10..+10
	var center: int = true_count + int(round(float(half) * float(shift) / 10.0))
	var lo: int = maxi(0, _round_to(center - half, 50))
	var hi: int = maxi(lo + 50, _round_to(center + half, 50))
	if hi - lo < 100:
		hi = lo + 100
	return "약 %d~%d" % [lo, hi]

## STEP-05R2 §18: deterministic combat-assessed approximation.
## Direct engagement reveals approximate CURRENT remaining strength —
## nearest 50 (<500) else nearest 100. Same count -> same text, no flicker.
static func combat_approx_troops(true_count: int) -> int:
	var c: int = maxi(0, true_count)
	if c < 500:
		return _round_to(c, 50)
	return _round_to(c, 100)

static func format_thousands(v: int) -> String:
	var neg: bool = v < 0
	var s: String = str(absi(v))
	var out: String = ""
	while s.length() > 3:
		out = "," + s.right(3) + out
		s = s.left(s.length() - 3)
	out = s + out
	return ("-" + out) if neg else out

static func combat_troop_text(true_count: int) -> String:
	return "약 %s명" % format_thousands(combat_approx_troops(true_count))

## STEP-05R2 §20/§24: compact world-badge notation sharing ONE observation record.
## Panel knows combat-assessed 40% => badge knows the same record.
static func combat_badge_text(true_count: int) -> String:
	return "~%s" % format_thousands(combat_approx_troops(true_count))

static func _round_to(v: int, step: int) -> int:
	return int(round(float(v) / float(step))) * step

# ------------------------------------------------------------------
# Hex LOS — deterministic axial ray trace.
# MOUNTAIN: strong blocker — any intermediate mountain hex blocks.
# FOREST: target forest hex itself is visible, but any intermediate forest
#   hex blocks sight to hexes beyond it at distance >= 3.
# ------------------------------------------------------------------
func _has_los(origin: Vector2i, target: Vector2i, cell_data: Dictionary) -> bool:
	if origin == target:
		return true
	var dist: int = _axial_distance(origin, target)
	var line: Array[Vector2i] = _hex_line(origin, target)
	# Intermediate hexes exclude origin (index 0) and target (last).
	for i in range(1, line.size() - 1):
		var h: Vector2i = line[i]
		var cell: Variant = cell_data.get("%d,%d" % [h.x, h.y], null)
		if cell == null:
			return false # off-map gap blocks
		var t: int = int(cell.terrain) if not (cell is Dictionary) else int((cell as Dictionary).get("terrain", 0))
		if t == TERRAIN_MOUNTAIN:
			return false
		if t == TERRAIN_FOREST and dist >= 3:
			return false
	return true

static func _axial_distance(a: Vector2i, b: Vector2i) -> int:
	var ds: int = -(a.x + a.y) + (b.x + b.y)
	return maxi(maxi(absi(a.x - b.x), absi(a.y - b.y)), absi(ds))

## Axial cube-lerp line inclusive of both endpoints.
static func _hex_line(a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	var n: int = _axial_distance(a, b)
	var ax: float = float(a.x)
	var az: float = float(a.y)
	var ay: float = -ax - az
	var bx: float = float(b.x)
	var bz: float = float(b.y)
	var by: float = -bx - bz
	var out: Array[Vector2i] = []
	if n == 0:
		out.append(a)
		return out
	for i in range(n + 1):
		var t: float = float(i) / float(n)
		var fx: float = ax + (bx - ax) * t
		var fy: float = ay + (by - ay) * t
		var fz: float = az + (bz - az) * t
		out.append(_cube_round(fx, fy, fz))
	return out

static func _cube_round(fx: float, fy: float, fz: float) -> Vector2i:
	var rx: int = roundi(fx)
	var ry: int = roundi(fy)
	var rz: int = roundi(fz)
	var dx: float = abs(float(rx) - fx)
	var dy: float = abs(float(ry) - fy)
	var dz: float = abs(float(rz) - fz)
	if dx > dy and dx > dz:
		rx = -ry - rz
	elif dy > dz:
		ry = -rx - rz
	else:
		rz = -rx - ry
	return Vector2i(rx, rz)
