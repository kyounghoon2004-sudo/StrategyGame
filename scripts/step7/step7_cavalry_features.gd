class_name Step7CavalryFeatures
extends RefCounted

## Shared one-pass tactical feature extractor (cavalry pilot).
## Pure static over passed dictionaries. Enemy input is BlueKnowledge ONLY
## (visible + stale last-known). WorldTruth hidden state never enters.
## Legality/reachability/cost come from the canonical envelope entries.

const HexUtilsScript = preload("res://scripts/core/hex_utils.gd")
const Step3ConfigScript = preload("res://scripts/core/step3_config.gd")
const BoundaryScript = preload("res://scripts/step2r/step2r_world_boundary.gd")
const CombatScript = preload("res://scripts/combat/combat_calculator.gd")
const TerrainModsScript = preload("res://scripts/combat/terrain_mods.gd")
const ClustersScript = preload("res://scripts/step7/step7_formation_clusters.gd")


static func axis_score(coord: Vector2i, axis: String) -> float:
	var q := float(coord.x)
	var r := float(coord.y)
	var axial_y := q + 2.0 * r
	match axis:
		"FORWARD":
			return q
		"BACK":
			return -q
		"RIGHT", "FLANK":
			return axial_y + 1.5 * q
		"LEFT":
			return -axial_y + 1.5 * q
		"NORTH":
			return -axial_y
		"SOUTH":
			return axial_y
		"EAST":
			return q
		"WEST":
			return -q
		_:
			return q


static func hex_dist(a: Vector2i, b: Vector2i) -> int:
	# Manual axial distance (no dependency on HexUtils internals).
	var aq := HexUtilsScript.offset_to_axial(a)
	var bq := HexUtilsScript.offset_to_axial(b)
	var dx: int = bq.x - aq.x
	var dz: int = bq.y - aq.y
	return int((abs(dx) + abs(dz) + abs(dx + dz)) / 2.0)


static func threat_range(contact_class: String, at: Vector2i, cell_data: Dictionary) -> int:
	var c := str(contact_class).to_lower()
	if c in ["archer", "archers"]:
		var terrain := _terrain_at(cell_data, at.x, at.y)
		return 3 + int(TerrainModsScript.get_archer_range_bonus(terrain))
	if c in ["siege"]:
		return 2
	return 1


static func _terrain_at(cell_data: Dictionary, q: int, r: int) -> int:
	var cell: Variant = cell_data.get("%d,%d" % [q, r], null)
	if cell == null:
		return 0
	return int(cell.terrain) if "terrain" in cell else 0


static func _is_open(cell_data: Dictionary, known_occupied: Dictionary, q: int, r: int) -> bool:
	var c := Vector2i(q, r)
	if not BoundaryScript.is_playable_hex(c):
		return false
	if Step3ConfigScript.is_impassable(_terrain_at(cell_data, q, r)):
		return false
	if known_occupied.has("%d,%d" % [q, r]):
		return false
	return true


static func build_cache(blue_knowledge: Dictionary, cell_data: Dictionary) -> Dictionary:
	var contacts: Array = []
	for src in [blue_knowledge.get("current_enemy_observations", []), blue_knowledge.get("last_known_enemy_contacts", [])]:
		for c_val in (src as Array):
			if not c_val is Dictionary:
				continue
			var c: Dictionary = c_val
			var pos := Vector2i(int(c.get("q", 0)), int(c.get("r", 0)))
			var stale := str(c.get("contact_state", "")) == "stale_last_known"
			contacts.append({
				"id": str(c.get("id", "?")), "pos": pos,
				"class": str(c.get("class", "unknown")).to_lower(),
				"stale": stale,
				"range": threat_range(str(c.get("class", "unknown")), pos, cell_data),
			})
	var friendlies: Array = []
	for f_val in (blue_knowledge.get("own_forces", []) as Array):
		if not f_val is Dictionary:
			continue
		var f: Dictionary = f_val
		friendlies.append({"id": str(f.get("id", "?")),
			"pos": Vector2i(int(f.get("q", 0)), int(f.get("r", 0))),
			"fclass": str(f.get("class", "unknown")).to_lower()})
	var objectives: Array = []
	for s_val in (blue_knowledge.get("strongholds", []) as Array):
		if s_val is Dictionary:
			var s: Dictionary = s_val
			if s.has("q") and s.has("r"):
				objectives.append(Vector2i(int(s.get("q", 0)), int(s.get("r", 0))))
	return {"contacts": contacts, "friendlies": friendlies, "objectives": objectives}


## Combat screen classes: formations that can physically screen others.
const SCREEN_CLASSES := ["infantry", "spear", "spearman", "archer", "cavalry",
	"conscript"]

## entries: Array of {q, r, cost, path:Array[Vector2i]} (origin excluded).
## scope_context (optional): {requested_cluster, target_cluster}. Intent wins:
## an explicit target_cluster overrides default cluster persistence. Legacy
## {requested_sector, target_sector} still resolves at wing granularity.
## Scoring-only preferences — never movement legality (planner owns legality).
## unit_class + combat generalize the extractor across doctrines:
##   combat = {counter_classes: Array (lowercased contact classes),
##             access_mode: cavalry|matchup|ranged|intercept|siege|none}.
## Empty combat reproduces exact legacy cavalry behavior.
static func extract(unit: Dictionary, entries: Array, cell_data: Dictionary,
		known_occupied: Dictionary, cache: Dictionary, intent_axis: String,
		budget: float, scope_context: Dictionary = {},
		unit_class: String = "cavalry",
		combat: Dictionary = {}) -> Array:
	var ucls := unit_class.strip_edges().to_lower()
	if ucls.is_empty():
		ucls = "cavalry"
	var counter_groups: Array = (combat.get("counter_classes",
		["spear", "spearman", "spearmen"]) as Array).duplicate()
	var access_mode := str(combat.get("access_mode", "cavalry"))
	var origin := Vector2i(int(unit.get("q", 0)), int(unit.get("r", 0)))
	var origin_cid := ClustersScript.cluster_of_hex(origin.x, origin.y)
	var anchor_cid := str(scope_context.get("target_cluster", scope_context.get("requested_cluster", ""))).to_upper()
	if anchor_cid.is_empty() or not ClustersScript.is_valid_cluster_id(anchor_cid):
		anchor_cid = origin_cid
	var anchor_wing := ""
	var legacy_sector := str(scope_context.get("target_sector", scope_context.get("requested_sector", ""))).to_upper()
	if not legacy_sector.is_empty():
		anchor_wing = legacy_sector.replace("_WING", "")
		anchor_cid = "" # wing-level comparison takes over for legacy callers
	var contacts: Array = cache.get("contacts", [])
	var friendlies: Array = cache.get("friendlies", [])
	var objectives: Array = cache.get("objectives", [])
	var own_id := str(unit.get("id", ""))
	var o_forward := axis_score(origin, intent_axis)
	var o_back := axis_score(origin, "BACK")

	# Pass 1: raw axis/back/objective scores for set normalization.
	var fwd: Array = []
	var back: Array = []
	for e in entries:
		var d := Vector2i(int(e["q"]), int(e["r"]))
		fwd.append(axis_score(d, intent_axis) - o_forward)
		back.append(axis_score(d, "BACK") - o_back)
	var fwd_max: float = maxf(0.001, _max_arr(fwd))
	var back_span: float = maxf(0.001, _max_arr(back) - _min_arr(back))

	var out: Array = []
	for i in range(entries.size()):
		var e: Dictionary = entries[i]
		var dest := Vector2i(int(e["q"]), int(e["r"]))
		var cost := float(e.get("cost", 0.0))
		var path: Array = e.get("path", [])
		var f: Dictionary = {}
		f["INTENT_PROGRESS"] = clampf(float(fwd[i]) / fwd_max, 0.0, 1.0)
		f["MOVEMENT_USE"] = clampf(cost / maxf(budget, 0.001), 0.0, 1.0)
		f["ROUTE_COST"] = clampf(cost / maxf(budget, 0.001), 0.0, 1.0)

		var terr_cost := Step3ConfigScript.get_terrain_cost(_terrain_at(cell_data, dest.x, dest.y), ucls)
		f["TERRAIN_MOBILITY"] = clampf(1.0 - terr_cost / 3.0, 0.0, 1.0)

		var free_n := 0
		var mob_acc := 0.0
		var rear_exits := 0
		var d_back := axis_score(dest, "BACK")
		for n in HexUtilsScript.get_all_neighbors(dest.x, dest.y):
			if not _is_open(cell_data, known_occupied, n.x, n.y):
				continue
			free_n += 1
			var nc := Step3ConfigScript.get_terrain_cost(_terrain_at(cell_data, n.x, n.y), ucls)
			mob_acc += clampf(1.0 - nc / 3.0, 0.0, 1.0)
			if axis_score(n, "BACK") > d_back:
				rear_exits += 1
		f["OPEN_MANEUVER_SPACE"] = float(free_n) / 6.0
		f["MOBILITY_FUTURE"] = clampf(mob_acc / 6.0, 0.0, 1.0)
		f["RETREAT_SAFETY"] = clampf(float(mini(rear_exits, 2)) / 2.0 * 0.7 + (float(back[i]) - _min_arr(back)) / back_span * 0.3, 0.0, 1.0)

		# Contact-driven features (BLUE-authorized contacts only: visible +
		# stale last-known. WorldTruth hidden state never enters).
		var best_match := 0.0
		var best_archer := 0.0
		var counter := 0.0
		var threat := 0.0
		var pressure_w := 0.0
		var denial_w := 0.0
		var refresh_w := 0.0
		var nearest_c := 99.0
		var nearest_cpos := Vector2i(0, 0)
		var stale_infl := 0
		var infl := 0
		var used_ids: Array = []
		var stale_ids: Array = []
		for c_val in contacts:
			var c: Dictionary = c_val
			var dist := float(hex_dist(dest, c["pos"]))
			if dist < nearest_c:
				nearest_c = dist
				nearest_cpos = c["pos"]
			var cls: String = str(c["class"])
			var ncls := CombatScript.normalize_class_name(cls)
			var tr: int = int(c["range"])
			var prox: float = clampf(1.0 - dist / float(tr + 3), 0.0, 1.0)
			if dist <= 5.0:
				infl += 1
				if bool(c["stale"]):
					stale_infl += 1
			if dist <= 3.0:
				pressure_w += 1.0 / (1.0 + dist)
				if not str(c["id"]) in used_ids:
					used_ids.append(str(c["id"]))
				if bool(c["stale"]) and not str(c["id"]) in stale_ids:
					stale_ids.append(str(c["id"]))
			if bool(c["stale"]) and dist <= 6.0:
				refresh_w += 1.0 / (1.0 + dist)
			threat += (1.0 / (1.0 + dist)) * prox
			if ncls in counter_groups and dist <= float(tr + 2):
				counter = maxf(counter, 0.875 * prox)
			else:
				match access_mode:
					"cavalry":
						var mult := float(CombatScript.get_matchup_mult("cavalry", cls))
						if mult > 1.0 and dist <= 3.0:
							best_match = maxf(best_match, (mult - 1.0) / 0.4 / (1.0 + dist * 0.5))
							if cls in ["archer", "archers"]:
								best_archer = maxf(best_archer, (mult - 1.0) / 0.4 / (1.0 + dist * 0.5))
					"matchup":
						var mult2 := float(CombatScript.get_matchup_mult(ucls, cls))
						if mult2 > 1.0 and dist <= 2.0:
							best_match = maxf(best_match, (mult2 - 1.0) / 0.4 / (1.0 + dist * 0.5))
					"ranged":
						var own_range := threat_range(ucls, dest, cell_data)
						if dist <= float(own_range + 1):
							best_archer = maxf(best_archer, clampf(1.0 - dist / float(own_range + 2), 0.0, 1.0))
					"intercept":
						if ncls == "cavalry" and dist <= float(tr + 2):
							best_match = maxf(best_match, 0.875 * prox)
					"siege":
						if dist <= 2.0:
							best_archer = maxf(best_archer, 1.0 / (1.0 + dist))
					"none":
						pass
			# Spearman denial: KNOWN enemy cavalry proximity is positional
			# value (blocking), not fear — the counter channel stays quiet
			# for cavalry so the two never double-count the same contact.
			if ncls == "cavalry" and dist <= float(tr + 3):
				denial_w += 1.0 / (1.0 + dist)
		f["MATCHUP_OPPORTUNITY"] = clampf(best_match, 0.0, 1.0)
		f["ARCHER_ACCESS"] = clampf(best_archer, 0.0, 1.0)
		f["CAVALRY_DENIAL"] = clampf(denial_w / 2.0, 0.0, 1.0)
		f["_refresh_w"] = refresh_w
		f["_nearest_cpos"] = nearest_cpos
		f["COUNTER_RISK"] = clampf(counter, 0.0, 1.0)
		f["THREAT_EXPOSURE"] = clampf(threat / 2.0, 0.0, 1.0)
		f["PRESSURE_VALUE"] = clampf(pressure_w / 2.0, 0.0, 1.0)
		f["UNCERTAINTY_RISK"] = (float(stale_infl) / float(maxi(infl, 1))) if infl > 0 else 0.0

		# Route exposure: sample up to 3 middle path cells.
		var route_exp := 0.0
		if path.size() >= 3:
			var samples: Array = [path[path.size() / 2]]
			if path.size() >= 5:
				samples.append(path[path.size() / 4])
				samples.append(path[3 * path.size() / 4])
			for s in samples:
				var st := 0.0
				for c_val in contacts:
					var c: Dictionary = c_val
					st += 1.0 / (1.0 + float(hex_dist(s, c["pos"])))
				route_exp = maxf(route_exp, st / 2.0)
		f["ROUTE_EXPOSURE"] = clampf(route_exp, 0.0, 1.0)

		# Support / isolation (own state).
		var sup := 0.0
		var nearest_f := 99.0
		var screen_raw := 0.0
		var has_screen_friend := false
		for f_val in friendlies:
			var fp: Vector2i = (f_val as Dictionary)["pos"]
			if str((f_val as Dictionary)["id"]) == own_id:
				continue
			var fd := float(hex_dist(dest, fp))
			nearest_f = minf(nearest_f, fd)
			if fd <= 4.0:
				sup += 1.0 / (1.0 + fd)
			# Screening geometry: a combat friendly between the destination
			# and the nearest KNOWN enemy covers the position. Lawful: own
			# positions + authorized contacts only.
			if fd <= 5.0 and str((f_val as Dictionary).get("fclass", "")).to_lower() in SCREEN_CLASSES:
				has_screen_friend = true
				var cover := 0.7
				if nearest_c < 99.0:
					var between := _seg_dist(Vector2(fp), Vector2(dest), Vector2(nearest_cpos))
					cover = 1.0 if between <= 2.5 else 0.4
				screen_raw = maxf(screen_raw, (1.0 / (1.0 + fd)) * cover)
		f["FORMATION_SUPPORT"] = clampf(sup / 2.0, 0.0, 1.0)
		f["ISOLATION_RISK"] = clampf(nearest_f / 6.0, 0.0, 1.0) if nearest_f < 99.0 else 1.0
		f["SCREEN_PROTECTION"] = clampf(screen_raw, 0.0, 1.0) if has_screen_friend else 0.0
		# Recon value: stale-contact refresh + novel ground + escape room.
		# Novelty is distance from own forces (lawful: own positions only);
		# a lone scout far out reads as novel, not as lost.
		var novel := 1.0 if nearest_f >= 99.0 else clampf(nearest_f / 6.0, 0.0, 1.0)
		f["INFORMATION_GAIN"] = clampf(0.6 * clampf(float(f["_refresh_w"]) / 2.0, 0.0, 1.0) + 0.4 * novel, 0.0, 1.0)
		f.erase("_refresh_w")
		f.erase("_nearest_cpos")

		# Flank: lateral share of displacement + contact closeness.
		var disp := Vector2(dest - origin).length()
		var lat := 0.0
		if disp > 0.01:
			var axis_dir := _axis_dir(intent_axis)
			var dv := Vector2(dest - origin)
			var proj: float = dv.dot(axis_dir) / maxf(axis_dir.length(), 0.001)
			lat = clampf((dv - axis_dir.normalized() * proj).length() / disp, 0.0, 1.0)
		var contact_f := 0.0
		if nearest_c < 99.0:
			contact_f = clampf(1.0 - nearest_c / 5.0, 0.0, 1.0)
		f["FLANK_VALUE"] = clampf(0.6 * lat + 0.4 * contact_f, 0.0, 1.0)

		# Objective (+ provenance).
		var obj := 0.0
		var obj_fallback := true
		if not objectives.is_empty():
			var bd := 1e9
			var bo := 1e9
			for o_val in objectives:
				var o: Vector2i = o_val
				bd = minf(bd, float(hex_dist(dest, o)))
				bo = minf(bo, float(hex_dist(origin, o)))
			obj = clampf((bo - bd) / maxf(bo, 1.0), 0.0, 1.0)
			obj_fallback = false
		else:
			obj = clampf(float(fwd[i]) / fwd_max, 0.0, 1.0)
		f["OBJECTIVE_VALUE"] = obj

		# Adaptive cluster features (explainable, intent-respecting).
		# CLUSTER_ALIGNMENT: 1.0 same band as anchor, 0.5 neighboring band in
		# frozen lateral order, 0.0 distant band. CLUSTER_COHESION:
		# same-band friendly support / 2. Legacy sector callers compare at
		# macro-wing granularity instead.
		var dest_cid := ClustersScript.cluster_of_hex(dest.x, dest.y)
		f["CLUSTER_ALIGNMENT"] = _cluster_alignment(dest_cid, anchor_cid, anchor_wing)
		var band_sup := 0.0
		for f_val in friendlies:
			var fpd: Dictionary = f_val
			if str(fpd.get("id", "")) == own_id:
				continue
			var fp: Vector2i = fpd["pos"]
			if anchor_wing.is_empty():
				if ClustersScript.cluster_of_hex(fp.x, fp.y) != dest_cid:
					continue
			elif ClustersScript.wing_of_cluster(ClustersScript.cluster_of_hex(fp.x, fp.y)) != ClustersScript.wing_of_cluster(dest_cid):
				continue
			var fd := float(hex_dist(dest, fp))
			if fd <= 4.0:
				band_sup += 1.0 / (1.0 + fd)
		f["CLUSTER_COHESION"] = clampf(band_sup / 2.0, 0.0, 1.0)

		out.append({"q": dest.x, "r": dest.y, "cost": cost, "path": path,
			"features": f, "known_ids": used_ids, "stale_ids": stale_ids,
			"objective_fallback": obj_fallback})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["q"]) == int(b["q"]):
			return int(a["r"]) < int(b["r"])
		return int(a["q"]) < int(b["q"]))
	return out


static func _cluster_alignment(dest_cid: String, anchor_cid: String, anchor_wing: String) -> float:
	if not anchor_wing.is_empty():
		var dw := ClustersScript.wing_of_cluster(dest_cid)
		if dw.is_empty() or anchor_wing.is_empty():
			return 0.5
		if dw == anchor_wing:
			return 1.0
		if dw == "CENTER" or anchor_wing == "CENTER":
			return 0.5
		return 0.0
	if dest_cid.is_empty() or anchor_cid.is_empty():
		return 0.5
	if dest_cid == anchor_cid:
		return 1.0
	var order: Array = ClustersScript.cluster_ids()
	var di := order.find(dest_cid)
	var ai := order.find(anchor_cid)
	if di < 0 or ai < 0:
		return 0.5
	if absi(di - ai) == 1:
		return 0.5
	return 0.0


static func _axis_dir(axis: String) -> Vector2:
	match axis:
		"FORWARD", "EAST":
			return Vector2(1, 0.5)
		"BACK", "WEST":
			return Vector2(-1, -0.5)
		"RIGHT", "FLANK":
			return Vector2(0.75, 1.0)
		"LEFT":
			return Vector2(0.75, -1.0)
		"NORTH":
			return Vector2(-0.5, -1.0)
		"SOUTH":
			return Vector2(0.5, 1.0)
		_:
			return Vector2(1, 0.5)


## Offset-space point-to-segment distance (heuristic screening geometry).
static func _seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var denom := maxf(ab.length_squared(), 0.001)
	var t := clampf((p - a).dot(ab) / denom, 0.0, 1.0)
	return (a + ab * t - p).length()


static func _max_arr(a: Array) -> float:
	var m := -1e9
	for v in a:
		m = maxf(m, float(v))
	return m


static func _min_arr(a: Array) -> float:
	var m := 1e9
	for v in a:
		m = minf(m, float(v))
	return m
