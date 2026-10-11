class_name Step7OperationPlanner
extends RefCounted

## Deterministic Operation Planner — Translates validated Battle IR into
## a ConcreteActionPlan using Godot engine authoritative rules.
## Callers submit intent as validated Battle IR; this planner resolves units,
## legal destinations, occupancy reservation, tie-breaking, and execution
## sequencing. Zero inference. MOVE orders bind exactly one named formation
## to one hex and never substitute another unit.

const HexUtilsScript = preload("res://scripts/core/hex_utils.gd")
const Step3PathfindingScript = preload("res://scripts/step3/step3_pathfinding.gd")
const BattleIRScript = preload("res://scripts/step7/step7_battle_ir.gd")
const ClustersScript = preload("res://scripts/step7/step7_formation_clusters.gd")

## Movement verb semantics (all deterministic; planner resolves HOW).
## MOVE: exact UNIT_ID to exact HEX. No substitution, ever.
## ADVANCE: maximal legal progress along the command axis within allowance.
## REPOSITION: target-oriented move minimizing distance to target points.
## RETREAT: axis-away move (voluntary; distinct from forced ROUT, which the
##   engine owns and which removes player control).
## WITHDRAW: target-oriented move toward the rear (HQ); unlike RETREAT it names
##   a destination instead of a direction.
## RECON: axis-advance restricted to recon-capable classes (SCOUT/CAVALRY).
## FLANK: lateral + forward geometry relative to the command axis; no enemy
##   prediction, restricted to maneuver classes.
## REGROUP: target-oriented move toward a rally reference (HQ default).
## PROTECT: nearest legal hex to a protectee (HQ/SUPPLY/FORMATION); geometry
##   only, restricted to holding classes.
## SCREEN: geometry between a protectee and the nearest BLUE-authorized threat
##   contact (visible first, then stale last-known); rejects honestly when no
##   contact is legally known. Never reads hidden WorldTruth positions.
## HOLD: no movement; consumes the action per existing wait rules.

## Per-action class policy. Verbs absent here admit every movable class, which
## preserves the whole-army baselines (ADVANCE_ALL/HOLD_ALL/RETREAT_ALL and the
## universal target verbs). Policy-excluded formations are NOT queued: they get
## an ACCOUNTED unavailable row with ACTION_NOT_SUPPORTED_FOR_CLASS.
const ACTION_CLASS_ALLOW := {
	"RECON": ["SCOUT", "CAVALRY"],
	"FLANK": ["CAVALRY", "INFANTRY", "SPEARMAN", "SCOUT", "ARCHER"],
	"PROTECT": ["INFANTRY", "SPEARMAN", "ARCHER", "CAVALRY", "CONSCRIPT"],
	"SCREEN": ["INFANTRY", "SPEARMAN", "ARCHER", "CAVALRY", "CONSCRIPT"],
}

## Builds a ConcreteActionPlan from validated Battle IR.
static func plan(ir: Dictionary, side: String, command_service: RefCounted, unit_manager: RefCounted, reserved_destinations: Dictionary = {}) -> Dictionary:
	var operations: Array = ir.get("operations", []) as Array
	var actions: Array = []
	var unavailable: Array = []
	# Keep the canonical, axis-sorted scope order separately from provisional
	# routes. Execution uses this list as its queue and replans each named unit
	# against the live world after the prior entry completes.
	var candidate_units: Array = []
	var candidate_seen: Dictionary = {}
	var policy_excluded: Dictionary = {}
	var reservations := reserved_destinations.duplicate(true)

	var op_id := "%s_T%d_OP_%d" % [side, unit_manager.get_current_turn() if unit_manager else 1, Time.get_ticks_msec()]

	for op_idx in range(operations.size()):
		var op: Dictionary = operations[op_idx] as Dictionary
		var scope: Dictionary = op.get("scope", {}) as Dictionary
		var op_code: String = str(op.get("op", "ADVANCE")).to_upper()
		var axis: String = str(op.get("axis", "NORTH")).to_upper()
		var march_mode: String = str(op.get("march_mode", "AUTO")).to_lower()

		# 1. Resolve Scope to Formation Candidates
		var candidates := _resolve_scope(scope, side, unit_manager)
		if candidates.is_empty():
			unavailable.append({
				"scope": scope,
				"reason": "NO_MATCHING_FORMATION",
				"detail": "No friendly formations matched scope."
			})
			continue

		# Target-oriented verbs resolve destination points once per operation
		# from canonical state. Failures reject the whole scope with one
		# accounted row (no per-unit spam, no coordinate leaks).
		var op_points: Array = []
		var op_nearest_supply := false
		if _verb_needs_target(op_code):
			var tres := _resolve_target_points(op, side, command_service, unit_manager)
			if not bool(tres.get("ok", false)):
				unavailable.append({
					"scope": scope,
					"reason": str(tres.get("code", "TARGET_NOT_FOUND")),
					"detail": str(tres.get("detail", "Target cannot be resolved.")),
				})
				continue
			op_points = tres.get("points", [])
			op_nearest_supply = bool(tres.get("nearest_supply", false))
		if op_code == "SCREEN":
			var sres := _resolve_screen_points(op, side, command_service, unit_manager)
			if not bool(sres.get("ok", false)):
				unavailable.append({
					"scope": scope,
					"reason": str(sres.get("code", "TARGET_NOT_FOUND")),
					"detail": str(sres.get("detail", "No screen position can be resolved.")),
				})
				continue
			op_points = sres.get("points", [])

		# Sort candidates to advance leading units first along axis
		_sort_formations_along_axis(candidates, axis)
		for candidate_val in candidates:
			if not candidate_val is Dictionary:
				continue
			var candidate: Dictionary = candidate_val as Dictionary
			var candidate_id := str(candidate.get("id", ""))
			if candidate_id.is_empty() or candidate_seen.has(candidate_id):
				continue
			candidate_seen[candidate_id] = true
			candidate_units.append({
				"unit_id": candidate_id,
				"class": str(candidate.get("class", "")).to_upper(),
				"start": [int(candidate.get("q", 0)), int(candidate.get("r", 0))],
			})

		# MOVE is an exact-unit order: one named formation, one hex.
		# Never substitute another unit when the requested one cannot move.
		if op_code == "MOVE":
			_plan_exact_move(op, candidates, side, command_service, reservations, actions, unavailable)
			continue

		for u in candidates:
			var uid: String = str(u.get("id", ""))
			var origin := Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))
			var u_class := str(u.get("class", "infantry")).to_upper()

			if bool(u.get("action_ended", false)):
				unavailable.append({
					"unit_id": uid,
					"class": u_class,
					"reason": "ALREADY_ACTED",
					"detail": "Formation has already ended its turn."
				})
				continue

			if bool(u.get("garrisoned", false)) or bool(u.get("routed", false)):
				unavailable.append({
					"unit_id": uid,
					"class": u_class,
					"reason": "UNAVAILABLE",
					"detail": "Formation is garrisoned or routed."
				})
				continue

			if not _class_allowed_for_action(op_code, u_class):
				unavailable.append({
					"unit_id": uid,
					"class": u_class,
					"reason": "ACTION_NOT_SUPPORTED_FOR_CLASS",
					"detail": "Formation class cannot perform %s." % op_code
				})
				policy_excluded[uid] = true
				continue

			match op_code:
				"HOLD":
					actions.append({
						"unit_id": uid,
						"action": "HOLD",
						"class": u_class,
						"from": [origin.x, origin.y],
						"to": [origin.x, origin.y]
					})
					reservations["%d,%d" % [origin.x, origin.y]] = uid

				"ATTACK":
					var target_id := str(op.get("target_unit_id", ""))
					var preview: Dictionary = command_service.preview_attack(uid, target_id, side) if command_service else {"ok": false}
					if bool(preview.get("ok", false)):
						actions.append({
							"unit_id": uid,
							"action": "ATTACK",
							"class": u_class,
							"target_unit_id": target_id,
							"from": [origin.x, origin.y]
						})
					else:
						unavailable.append({
							"unit_id": uid,
							"class": u_class,
							"reason": "ILLEGAL_ATTACK",
							"detail": str(preview.get("error", "Target is not a legal attack option."))
						})

				"REPOSITION", "WITHDRAW", "REGROUP", "PROTECT", "SCREEN":
					var eff_points: Array = op_points
					if op_nearest_supply:
						eff_points = _nearest_supply_points(origin, side, unit_manager)
						if eff_points.is_empty():
							unavailable.append({
								"unit_id": uid,
								"class": u_class,
								"reason": "TARGET_NOT_FOUND",
								"detail": "No own supply formation is available."
							})
							continue
					var tgt_dest := _find_best_destination_toward(
						uid, origin, eff_points, side, march_mode,
						command_service, reservations
					)
					if tgt_dest.x != -999:
						reservations["%d,%d" % [tgt_dest.x, tgt_dest.y]] = uid
						actions.append({
							"unit_id": uid,
							"action": "MOVE",
							"class": u_class,
							"from": [origin.x, origin.y],
							"to": [tgt_dest.x, tgt_dest.y],
							"cost": tgt_dest.z,
							"march_mode": march_mode,
							"axis": axis
						})
					else:
						unavailable.append({
							"unit_id": uid,
							"class": u_class,
							"reason": "NO_LEGAL_PROGRESS",
							"detail": "No unblocked legal destination found toward the target."
						})
					continue

				"ADVANCE", "FLANK", "RETREAT", "RECON":
					var best_dest := _find_best_destination(
						uid, origin, u, axis, op_code, side, march_mode,
						command_service, reservations
					)
					if best_dest.x != -999:
						reservations["%d,%d" % [best_dest.x, best_dest.y]] = uid
						actions.append({
							"unit_id": uid,
							"action": "MOVE",
							"class": u_class,
							"from": [origin.x, origin.y],
							"to": [best_dest.x, best_dest.y],
							"cost": best_dest.z, # stored cost
							"march_mode": march_mode,
							"axis": axis
						})
					else:
						unavailable.append({
							"unit_id": uid,
							"class": u_class,
							"reason": "NO_LEGAL_PROGRESS",
							"detail": "No unblocked legal destination found making progress along %s." % axis
						})

	# Policy-excluded formations never enter the execution queue; their
	# unavailable rows above are the complete accounting for them.
	if not policy_excluded.is_empty():
		var kept: Array = []
		for cand in candidate_units:
			if cand is Dictionary and not policy_excluded.has(str((cand as Dictionary).get("unit_id", ""))):
				kept.append(cand)
		candidate_units = kept
		policy_excluded.clear()

	var primary_op := str((operations[0] as Dictionary).get("op", "COMMAND")) if not operations.is_empty() else "COMMAND"
	var primary_axis := str((operations[0] as Dictionary).get("axis", "")) if not operations.is_empty() else ""

	return {
		"operation_id": op_id,
		"source_ir": ir,
		"side": side,
		"candidate_units": candidate_units,
		"summary": {
			"op": primary_op,
			"axis": primary_axis,
			"planned_count": actions.size(),
			"unavailable_count": unavailable.size(),
			"total_scope_count": actions.size() + unavailable.size()
		},
		"actions": actions,
		"unavailable": unavailable
	}

static func _resolve_scope(scope: Dictionary, side: String, unit_manager: RefCounted) -> Array:
	var out: Array = []
	if unit_manager == null:
		return out

	var all_units: Array = unit_manager.get_all_units_including_garrisoned() if unit_manager.has_method("get_all_units_including_garrisoned") else []
	var scope_type: String = str(scope.get("type", "ALL_AVAILABLE")).to_upper()

	for u_val in all_units:
		if not u_val is Dictionary:
			continue
		var u: Dictionary = u_val as Dictionary
		if str(u.get("faction", "")) != side:
			continue
		if int(u.get("soldier_count", 0)) <= 0:
			continue

		var uid := str(u.get("id", "")).to_upper()
		var uclass := str(u.get("class", "")).to_upper()

		match scope_type:
			"ALL_AVAILABLE":
				out.append(u)
			"CLASS":
				var target_class := str(scope.get("class", "")).to_upper()
				if uclass == target_class:
					out.append(u)
			"UNIT_ID":
				var target_id := str(scope.get("unit_id", "")).to_upper()
				if uid == target_id:
					out.append(u)
			"UNIT_IDS":
				var target_ids: Array = scope.get("unit_ids", []) as Array
				for tid in target_ids:
					if uid == str(tid).to_upper():
						out.append(u)
						break
			"SECTOR_CLASS":
				# LEGACY adapter (fixed one-third prototype): map the old sector
				# to its macro wing (LEFT_WING -> LEFT, CENTER -> CENTER,
				# RIGHT_WING -> RIGHT) and resolve against the FROZEN adaptive
				# bands. Strict purity: CURRENT-hex band's wing must match AND
				# class must match. Empty result stays honest (no substitution).
				var want_sector := str(scope.get("sector", "")).to_upper()
				var want_wing := want_sector.replace("_WING", "")
				if uclass == str(scope.get("class", "")).to_upper() and ClustersScript.wing_of_cluster(ClustersScript.cluster_of_hex(int(u.get("q", 0)), int(u.get("r", 0)))) == want_wing:
					out.append(u)
			"FORMATION_CLUSTER_CLASS":
				# Canonical adaptive scope: CURRENT-hex frozen band must equal
				# the requested cluster AND class must match.
				var want_cluster := str(scope.get("cluster", "")).to_upper()
				var want_cclass := str(scope.get("class", "")).to_upper()
				if uclass == want_cclass and ClustersScript.cluster_of_hex(int(u.get("q", 0)), int(u.get("r", 0))) == want_cluster:
					out.append(u)
			"FORMATION_CLUSTER":
				# Direct cluster scope (any class in the frozen band).
				var want_only := str(scope.get("cluster", "")).to_upper()
				if ClustersScript.cluster_of_hex(int(u.get("q", 0)), int(u.get("r", 0))) == want_only:
					out.append(u)
			"FORMATION_WING_CLASS":
				# Macro wing scope: LEFT = all L*, CENTER = C, RIGHT = all R*.
				var want_mwing := str(scope.get("wing", "")).to_upper()
				var want_mclass := str(scope.get("class", "")).to_upper()
				if uclass == want_mclass and ClustersScript.wing_of_cluster(ClustersScript.cluster_of_hex(int(u.get("q", 0)), int(u.get("r", 0)))) == want_mwing:
					out.append(u)
	# Cluster/sector scopes resolve in deterministic id order (never Dictionary iteration).
	if str(scope.get("type", "ALL_AVAILABLE")).to_upper() in ["SECTOR_CLASS", "FORMATION_CLUSTER", "FORMATION_CLUSTER_CLASS", "FORMATION_WING_CLASS"]:
		out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.get("id", "")) < str(b.get("id", "")))
	return out

## Exact-unit MOVE planning. The scope must name exactly one formation and
## the op must carry one HEX target. Any failure rejects deterministically;
## no other formation is ever moved as a substitute.
static func _plan_exact_move(op: Dictionary, candidates: Array, side: String, command_service: RefCounted, reservations: Dictionary, actions: Array, unavailable: Array) -> void:
	var scope: Dictionary = op.get("scope", {}) as Dictionary
	var want_id := str(scope.get("unit_id", "")).to_upper()
	if str(scope.get("type", "")).to_upper() != "UNIT_ID" or want_id.is_empty():
		unavailable.append({"unit_id": "", "reason": "INVALID_SCOPE", "detail": "A move order must name exactly one formation."})
		return
	if candidates.size() != 1 or str((candidates[0] as Dictionary).get("id", "")).to_upper() != want_id:
		unavailable.append({"unit_id": want_id, "reason": "UNIT_NOT_FOUND", "detail": "The requested formation is not available to this side."})
		return
	var u: Dictionary = candidates[0]
	var uid := want_id
	var u_class := str(u.get("class", "infantry")).to_upper()
	if bool(u.get("action_ended", false)) or bool(u.get("garrisoned", false)) or bool(u.get("routed", false)):
		unavailable.append({"unit_id": uid, "class": u_class, "reason": "UNIT_NOT_READY", "detail": "The requested formation cannot move now."})
		return
	var target: Variant = op.get("target", {})
	if not target is Dictionary or str((target as Dictionary).get("type", "")).to_upper() != "HEX" or not (target as Dictionary).has("q") or not (target as Dictionary).has("r"):
		unavailable.append({"unit_id": uid, "class": u_class, "reason": "INVALID_SCOPE", "detail": "A move order needs a map hex target."})
		return
	var dest := Vector2i(int((target as Dictionary).get("q", 0)), int((target as Dictionary).get("r", 0)))
	var origin := Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))
	if dest == origin:
		unavailable.append({"unit_id": uid, "class": u_class, "reason": "TARGET_UNREACHABLE", "detail": "Destination cannot currently be completed."})
		return
	var dest_key := "%d,%d" % [dest.x, dest.y]
	if reservations.has(dest_key):
		unavailable.append({"unit_id": uid, "class": u_class, "reason": "OCCUPIED", "detail": "Destination cannot currently be completed."})
		return
	if command_service == null or not command_service.has_method("preview_move"):
		unavailable.append({"unit_id": uid, "class": u_class, "reason": "NOT_IMPLEMENTED", "detail": "Destination cannot currently be completed."})
		return
	# Player-visible failures stay generic on purpose: the planner may read
	# full occupancy internally, but hidden contacts must never leak through
	# error text.
	var preview: Dictionary = command_service.preview_move(uid, dest, side, "auto")
	if not bool(preview.get("legal", false)):
		var code := _move_rejection_code(str(preview.get("rejection_reason", "")))
		unavailable.append({"unit_id": uid, "class": u_class, "reason": code, "detail": "Destination cannot currently be completed."})
		return
	reservations[dest_key] = uid
	actions.append({
		"unit_id": uid,
		"action": "MOVE",
		"class": u_class,
		"from": [origin.x, origin.y],
		"to": [dest.x, dest.y],
		"march_mode": "auto",
	})


## Engine rejection strings are internal-only; map them to stable public codes.
static func _move_rejection_code(reason: String) -> String:
	var lower := reason.to_lower()
	if lower.contains("ccupied"):
		return "OCCUPIED"
	if lower.contains("budget") or lower.contains("march"):
		return "INSUFFICIENT_MOVEMENT"
	return "TARGET_UNREACHABLE"


## Sorts units along the advance axis so front-rank formations plan and move first.
static func _sort_formations_along_axis(units: Array, axis: String) -> void:
	units.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var pos_a := Vector2i(int(a.get("q", 0)), int(a.get("r", 0)))
		var pos_b := Vector2i(int(b.get("q", 0)), int(b.get("r", 0)))
		var score_a := _eval_axis_score(pos_a, axis)
		var score_b := _eval_axis_score(pos_b, axis)
		if score_a == score_b:
			return str(a.get("id", "")) < str(b.get("id", ""))
		# Higher score means already further along the advance direction -> plans first!
		return score_a > score_b
	)

## Finds the best legal, unreserved reachable destination making directional progress.
## Returns Vector3i(q, r, cost) or Vector3i(-999, -999, 0).
static func _find_best_destination(
	unit_id: String,
	origin: Vector2i,
	unit_dict: Dictionary,
	axis: String,
	op_code: String,
	side: String,
	march_mode: String,
	command_service: RefCounted,
	reservations: Dictionary
) -> Vector3i:
	if command_service == null or not command_service.has_method("reachable_area"):
		return Vector3i(-999, -999, 0)

	var area: Dictionary = command_service.reachable_area(unit_id, side, march_mode)
	if not bool(area.get("ok", false)):
		return Vector3i(-999, -999, 0)

	var reachable: Array = area.get("reachable", []) as Array
	if reachable.is_empty():
		return Vector3i(-999, -999, 0)

	var origin_score := _eval_axis_score(origin, axis)

	var scored_candidates: Array = []
	for entry_val in reachable:
		if not entry_val is Dictionary:
			continue
		var entry: Dictionary = entry_val as Dictionary
		var coord := Vector2i(int(entry.get("q", -999)), int(entry.get("r", -999)))
		if coord.x == -999 or coord == origin:
			continue

		var coord_key := "%d,%d" % [coord.x, coord.y]
		if reservations.has(coord_key):
			continue # Occupancy collision avoidance

		var score := _eval_axis_score(coord, axis)
		var progress := score - origin_score

		# Must make positive progress along requested axis
		if progress <= 0:
			continue

		var cost := float(entry.get("cost", 1.0))
		scored_candidates.append({
			"coord": coord,
			"score": score,
			"progress": progress,
			"cost": cost
		})

	if scored_candidates.is_empty():
		return Vector3i(-999, -999, 0)

	# Deterministic Tie-Breaking (STEP 10):
	# 1. Maximum progress along requested axis
	# 2. Minimal terrain movement cost
	# 3. Stable coordinate string
	scored_candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if float(a.progress) != float(b.progress):
			return float(a.progress) > float(b.progress)
		if float(a.cost) != float(b.cost):
			return float(a.cost) < float(b.cost)
		var ca: Vector2i = a.coord
		var cb: Vector2i = b.coord
		return "%d,%d" % [ca.x, ca.y] < "%d,%d" % [cb.x, cb.y]
	)

	var best: Dictionary = scored_candidates[0] as Dictionary
	var best_coord: Vector2i = best.coord
	return Vector3i(best_coord.x, best_coord.y, int(float(best.cost) * 10.0))

## Direction model. Absolute compass scores use flat-top axial geometry.
## FORWARD/BACK are side-relative: BLUE faces EAST (field spawns west,
## stronghold targets east), so BLUE FORWARD scores as EAST and BACK as WEST.
## Only the BLUE execution path is wired; RED keeps its deterministic routine.
## Camera orientation never enters this mapping.
## Flat-top axial geometry:
## - North: decreases q + 2*r (y decreases) -> score is -(q + 2*r)
## - South: increases q + 2*r (y increases) -> score is (q + 2*r)
## - East: increases q (x increases) -> score is q
## - West: decreases q (x decreases) -> score is -q
## - Flank Right (for Blue): advance South & East -> score is (q + 2*r) + 2*q
## - Flank Left (for Blue): advance North & East -> score is -(q + 2*r) + 2*q
static func _eval_axis_score(coord: Vector2i, axis: String) -> float:
	var q := float(coord.x)
	var r := float(coord.y)
	var axial_y := q + 2.0 * r # 2 * normalized y in flat top

	match axis:
		"NORTH":
			return -axial_y
		"SOUTH":
			return axial_y
		"EAST":
			return q
		"WEST":
			return -q
		"NORTHEAST":
			return -axial_y + 2.0 * q
		"NORTHWEST":
			return -axial_y - 2.0 * q
		"SOUTHEAST":
			return axial_y + 2.0 * q
		"SOUTHWEST":
			return axial_y - 2.0 * q
		"FORWARD":
			# Blue forward (eastward).
			return q
		"BACK":
			# Blue rearward (westward).
			return -q
		"RIGHT", "FLANK":
			# For Blue (facing East), Right flank is southward and eastward
			return axial_y + 1.5 * q
		"LEFT":
			# Left flank is northward and eastward
			return -axial_y + 1.5 * q
		"CENTER":
			# Progress towards map center (0, 0)
			return -float(HexUtilsScript.hex_distance_axial(coord, Vector2i(0, 0)))
		"HQ":
			# Progress towards blue HQ (-26, 0) or Fortress
			return -float(HexUtilsScript.hex_distance_axial(coord, Vector2i(-26, 0)))
		_:
			return -axial_y


## Verb/target helpers (movement completeness milestone) ---------------------

static func _verb_needs_target(op_code: String) -> bool:
	return op_code in ["REPOSITION", "WITHDRAW", "REGROUP", "PROTECT"]


static func _class_allowed_for_action(op_code: String, uclass: String) -> bool:
	if not ACTION_CLASS_ALLOW.has(op_code):
		return true
	return uclass in (ACTION_CLASS_ALLOW[op_code] as Array)


## Resolve an op target to deterministic destination points from canonical
## state. Returns {ok, points: Array[Vector2i], nearest_supply: bool, code,
## detail}. Never leaks hidden positions: enemy formations resolve only through
## BLUE-authorized contact visibility.
static func _resolve_target_points(op: Dictionary, side: String, command_service: RefCounted, unit_manager: RefCounted) -> Dictionary:
	var target: Dictionary = op.get("target", {}) as Dictionary
	var ttype := str(target.get("type", "")).to_upper()
	match ttype:
		"HEX":
			return {"ok": true, "points": [Vector2i(int(target.get("q", 0)), int(target.get("r", 0)))], "nearest_supply": false}
		"FORMATION":
			var want := str(target.get("unit_id", "")).to_upper()
			var u := _lookup_unit(unit_manager, want)
			if u.is_empty():
				return _target_fail("TARGET_NOT_FOUND", "Target formation is not available.")
			if str(u.get("faction", "")) != side:
				if not _is_contact_visible_to(command_service, side, want):
					return _target_fail("TARGET_NOT_FOUND", "Target formation is not available.")
			return {"ok": true, "points": [Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))], "nearest_supply": false}
		"HQ":
			var hq := _first_own_class_unit(unit_manager, side, "HQ")
			if hq.is_empty():
				return _target_fail("TARGET_NOT_FOUND", "No HQ formation is available.")
			return {"ok": true, "points": [Vector2i(int(hq.get("q", 0)), int(hq.get("r", 0)))], "nearest_supply": false}
		"SUPPLY":
			var sid := str(target.get("unit_id", "")).to_upper()
			if sid.is_empty():
				return {"ok": true, "points": [], "nearest_supply": true}
			var sup := _lookup_unit(unit_manager, sid)
			if sup.is_empty() or str(sup.get("faction", "")) != side:
				return _target_fail("TARGET_NOT_FOUND", "Target supply formation is not available.")
			return {"ok": true, "points": [Vector2i(int(sup.get("q", 0)), int(sup.get("r", 0)))], "nearest_supply": false}
		"STRONGHOLD":
			var perim: Array = unit_manager.get_stronghold_perimeter_hexes(str(target.get("id", ""))) if unit_manager and unit_manager.has_method("get_stronghold_perimeter_hexes") else []
			if perim.is_empty():
				return _target_fail("TARGET_NOT_FOUND", "Stronghold has no reachable perimeter.")
			var pts: Array = []
			for h in perim:
				if h is Vector2i:
					pts.append(h)
			if pts.is_empty():
				return _target_fail("TARGET_NOT_FOUND", "Stronghold has no reachable perimeter.")
			return {"ok": true, "points": pts, "nearest_supply": false}
		"CENTER":
			return {"ok": true, "points": [Vector2i(0, 0)], "nearest_supply": false}
		"SECTOR":
			# LEGACY adapter: an old-sector target seeks the frozen anchor of
			# the corresponding macro wing (LEFT_WING -> extreme-left anchor,
			# CENTER -> C anchor, RIGHT_WING -> extreme-right anchor).
			# Cross-band movement stays legal — cluster is context, not prison.
			var want := str(target.get("sector", "")).to_upper()
			if want not in ["LEFT_WING", "CENTER", "RIGHT_WING"]:
				return _target_fail("INVALID_TARGET", "Target sector is not available.")
			var wres: Dictionary = ClustersScript.wing_anchor(want.replace("_WING", ""))
			if not bool(wres.get("ok", false)):
				return _target_fail("TARGET_NOT_FOUND", "No live tactical band backs that sector.")
			return {"ok": true, "points": [wres.get("point")], "nearest_supply": false}
		"CLUSTER":
			# Canonical adaptive target: frozen anchor hex of one cluster.
			var want_c := str(target.get("cluster", "")).to_upper()
			var info: Dictionary = ClustersScript.cluster_info(want_c)
			if info.is_empty():
				return _target_fail("TARGET_NOT_FOUND", "Target cluster is not active.")
			return {"ok": true, "points": [Vector2i(int(info.get("anchor_q", 0)), int(info.get("anchor_r", 0)))], "nearest_supply": false}
	return _target_fail("INVALID_TARGET", "Target cannot be resolved.")


static func _target_fail(code: String, detail: String) -> Dictionary:
	return {"ok": false, "points": [], "nearest_supply": false, "code": code, "detail": detail}


## SCREEN points: two hexes from the protectee toward the nearest
## BLUE-authorized threat contact (visible first, then stale last-known).
## No contact legally known -> honest TARGET_NOT_FOUND, never WorldTruth.
static func _resolve_screen_points(op: Dictionary, side: String, command_service: RefCounted, unit_manager: RefCounted) -> Dictionary:
	var target: Dictionary = op.get("target", {}) as Dictionary
	if str(target.get("type", "")).to_upper() == "STRONGHOLD":
		return _target_fail("INVALID_TARGET", "SCREEN needs a single-point protectee (HEX, FORMATION, HQ, SUPPLY, CENTER).")
	var pres := _resolve_target_points(op, side, command_service, unit_manager)
	if not bool(pres.get("ok", false)):
		return pres
	var pts: Array = pres.get("points", [])
	if pts.is_empty():
		return _target_fail("TARGET_NOT_FOUND", "Protectee cannot be resolved.")
	var protectee: Vector2i = pts[0]
	var contacts := _blue_threat_contacts(command_service, unit_manager)
	if contacts.is_empty():
		return _target_fail("TARGET_NOT_FOUND", "No observed threat contact to screen against.")
	var best: Dictionary = contacts[0]
	var best_d := HexUtilsScript.hex_distance_axial(protectee, Vector2i(int(best.get("q", 0)), int(best.get("r", 0))))
	for c in contacts:
		var d := HexUtilsScript.hex_distance_axial(protectee, Vector2i(int(c.get("q", 0)), int(c.get("r", 0))))
		if d < best_d or (d == best_d and str(c.get("id", "")) < str(best.get("id", ""))):
			best = c
			best_d = d
	var threat := Vector2i(int(best.get("q", 0)), int(best.get("r", 0)))
	return {"ok": true, "points": [_screen_point(protectee, threat)], "nearest_supply": false}


## Two hexes from protectee toward threat, snapped to the axial grid.
static func _screen_point(protectee: Vector2i, threat: Vector2i) -> Vector2i:
	var d := HexUtilsScript.hex_distance_axial(protectee, threat)
	if d <= 0:
		return protectee
	var step: Vector2 = Vector2(threat - protectee) / float(d) * minf(2.0, float(d))
	return HexUtilsScript.hex_round(Vector2(protectee) + step)


## BLUE-authorized threat contacts: currently visible first, then stale
## last-known snapshots. Positions only, no strength/morale leakage.
static func _blue_threat_contacts(command_service: RefCounted, unit_manager: RefCounted) -> Array:
	var out: Array = []
	var seen := {}
	if command_service == null or unit_manager == null:
		return out
	var proj: Variant = command_service.get("projector")
	if not (proj is RefCounted):
		return out
	var turn := 1
	if unit_manager.has_method("get_current_turn"):
		turn = int(unit_manager.get_current_turn())
	var k: Dictionary = (proj as RefCounted).call("build_blue_knowledge", turn)
	for c in k.get("current_enemy_observations", []):
		if c is Dictionary:
			out.append({"id": str((c as Dictionary).get("id", "")), "q": int((c as Dictionary).get("q", 0)), "r": int((c as Dictionary).get("r", 0))})
			seen[str((c as Dictionary).get("id", ""))] = true
	for c in k.get("last_known_enemy_contacts", []):
		if c is Dictionary and not seen.has(str((c as Dictionary).get("id", ""))):
			out.append({"id": str((c as Dictionary).get("id", "")), "q": int((c as Dictionary).get("q", 0)), "r": int((c as Dictionary).get("r", 0))})
	return out


static func _is_contact_visible_to(command_service: RefCounted, side: String, unit_id: String) -> bool:
	if command_service == null:
		return false
	var proj: Variant = command_service.get("projector")
	if proj is RefCounted and (proj as RefCounted).has_method("is_contact_visible"):
		return bool((proj as RefCounted).call("is_contact_visible", side, unit_id))
	return false


static func _lookup_unit(unit_manager: RefCounted, unit_id: String) -> Dictionary:
	if unit_manager == null or not unit_manager.has_method("get_unit_by_id"):
		return {}
	return unit_manager.get_unit_by_id(unit_id) as Dictionary


static func _first_own_class_unit(unit_manager: RefCounted, side: String, uclass: String) -> Dictionary:
	if unit_manager == null or not unit_manager.has_method("get_all_units_including_garrisoned"):
		return {}
	var found: Array = []
	for u_val in unit_manager.get_all_units_including_garrisoned():
		if u_val is Dictionary:
			var u: Dictionary = u_val
			if str(u.get("faction", "")) == side and str(u.get("class", "")).to_upper() == uclass and int(u.get("soldier_count", 0)) > 0:
				found.append(u)
	found.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.get("id", "")) < str(b.get("id", "")))
	return found[0] if not found.is_empty() else {}


## Nearest own supply formation to the candidate origin.
static func _nearest_supply_points(origin: Vector2i, side: String, unit_manager: RefCounted) -> Array:
	if unit_manager == null or not unit_manager.has_method("get_all_units_including_garrisoned"):
		return []
	var best := {}
	var best_d := 1 << 30
	for u_val in unit_manager.get_all_units_including_garrisoned():
		if u_val is Dictionary:
			var u: Dictionary = u_val
			if str(u.get("faction", "")) != side or str(u.get("class", "")).to_upper() != "SUPPLY":
				continue
			if int(u.get("soldier_count", 0)) <= 0 or bool(u.get("garrisoned", false)) or bool(u.get("routed", false)):
				continue
			var p := Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))
			var d := HexUtilsScript.hex_distance_axial(origin, p)
			if d < best_d:
				best = u
				best_d = d
	if best.is_empty():
		return []
	return [Vector2i(int(best.get("q", 0)), int(best.get("r", 0)))]


## Target-oriented destination selection: nearest reachable, unreserved hex
## minimizing axial distance to the target points. Deterministic tie-breaks:
## minimal distance, then minimal terrain cost, then stable coordinate string.
## Returns Vector3i(q, r, cost10) or Vector3i(-999, -999, 0).
static func _find_best_destination_toward(
	unit_id: String,
	origin: Vector2i,
	target_points: Array,
	side: String,
	march_mode: String,
	command_service: RefCounted,
	reservations: Dictionary
) -> Vector3i:
	if command_service == null or not command_service.has_method("reachable_area"):
		return Vector3i(-999, -999, 0)
	if target_points.is_empty():
		return Vector3i(-999, -999, 0)
	var area: Dictionary = command_service.reachable_area(unit_id, side, march_mode)
	if not bool(area.get("ok", false)):
		return Vector3i(-999, -999, 0)
	var reachable: Array = area.get("reachable", []) as Array
	if reachable.is_empty():
		return Vector3i(-999, -999, 0)
	var scored: Array = []
	for entry_val in reachable:
		if not entry_val is Dictionary:
			continue
		var entry: Dictionary = entry_val as Dictionary
		var coord := Vector2i(int(entry.get("q", -999)), int(entry.get("r", -999)))
		if coord.x == -999 or coord == origin:
			continue
		var coord_key := "%d,%d" % [coord.x, coord.y]
		if reservations.has(coord_key):
			continue
		var dist := 1 << 30
		for tp_val in target_points:
			if tp_val is Vector2i:
				dist = mini(dist, HexUtilsScript.hex_distance_axial(coord, tp_val))
		scored.append({
			"coord": coord,
			"dist": dist,
			"cost": float(entry.get("cost", 1.0))
		})
	if scored.is_empty():
		return Vector3i(-999, -999, 0)
	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a.dist) != int(b.dist):
			return int(a.dist) < int(b.dist)
		if float(a.cost) != float(b.cost):
			return float(a.cost) < float(b.cost)
		var ca: Vector2i = a.coord
		var cb: Vector2i = b.coord
		return "%d,%d" % [ca.x, ca.y] < "%d,%d" % [cb.x, cb.y]
	)
	var best: Dictionary = scored[0] as Dictionary
	var best_coord: Vector2i = best.coord
	return Vector3i(best_coord.x, best_coord.y, int(float(best.cost) * 10.0))
