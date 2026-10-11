class_name Step7BattleIR
extends RefCounted

## Battle IR v1 — Declarative, strict, finite military intermediate representation.
## Carries one validated commander intent into deterministic planning.
## Callers build it via Step7ActionCommand; Godot engine systems resolve
## exact units, legal movement, pathfinding, occupancy, combat, and execution.

const CURRENT_VERSION := 1
const VALID_MODES := ["COMMAND", "PLAN", "ADVICE"]
const VALID_OPS := ["ADVANCE", "MOVE", "HOLD", "REPOSITION", "RECON", "FLANK", "RETREAT", "ATTACK", "WITHDRAW", "REGROUP", "PROTECT", "SCREEN"]
const VALID_SCOPE_TYPES := ["ALL_AVAILABLE", "CLASS", "UNIT_ID", "UNIT_IDS", "SECTOR_CLASS", "FORMATION_CLUSTER", "FORMATION_CLUSTER_CLASS", "FORMATION_WING_CLASS"]
const VALID_SECTORS := ["LEFT_WING", "CENTER", "RIGHT_WING"]
const VALID_WINGS := ["LEFT", "CENTER", "RIGHT"]
const VALID_CLASSES := ["SCOUT", "CAVALRY", "INFANTRY", "SPEARMAN", "ARCHER", "CONSCRIPT", "SIEGE", "SUPPLY", "HQ"]
const VALID_AXES := ["NORTH", "SOUTH", "EAST", "WEST", "NORTHEAST", "NORTHWEST", "SOUTHEAST", "SOUTHWEST", "RIGHT", "LEFT", "CENTER", "HQ", "FORWARD", "BACK"]
const VALID_POSTURES := ["NORMAL", "AGGRESSIVE", "DEFENSIVE", "CAUTIOUS", "FAST"]
const VALID_MARCH_MODES := ["AUTO", "GREEN", "RED", "BLACK"]
const VALID_TARGETS := ["HEX", "FORMATION", "HQ", "SUPPLY", "STRONGHOLD", "CENTER", "SECTOR", "CLUSTER"]

const FORBIDDEN_FIELDS := [
	"eval", "exec", "script", "code", "shell", "cmd", "system", "c++",
	"assembly", "gdscript", "python", "payload", "call", "method", "function"
]

static func validate(data: Variant, known_units: Variant = null) -> Dictionary:
	if not data is Dictionary:
		return {"ok": false, "code": "MALFORMED_STRUCTURE", "detail": "Battle IR envelope must be a JSON object."}

	var d: Dictionary = data as Dictionary

	# Security check: absolutely reject any execution/script attempt
	for k in d.keys():
		var key_str := str(k).to_lower().strip_edges()
		if key_str in FORBIDDEN_FIELDS:
			return {"ok": false, "code": "FORBIDDEN_FIELD", "detail": "Arbitrary executable field forbidden: %s" % key_str}

	# Version check
	var version_val: Variant = d.get("version", null)
	if version_val == null or int(version_val) != CURRENT_VERSION:
		return {
			"ok": false,
			"code": "INVALID_VERSION",
			"detail": "Supported Battle IR version is %d, got %s" % [CURRENT_VERSION, str(version_val)]
		}

	# Mode check
	var mode_val: String = str(d.get("mode", "COMMAND")).to_upper().strip_edges()
	if mode_val not in VALID_MODES:
		return {
			"ok": false,
			"code": "INVALID_MODE",
			"detail": "Mode must be one of %s, got '%s'" % [str(VALID_MODES), mode_val]
		}

	# Operations array check
	var ops_val: Variant = d.get("operations", null)
	if not ops_val is Array:
		return {"ok": false, "code": "MALFORMED_OPERATIONS", "detail": "'operations' must be an array."}
	var ops_array: Array = ops_val as Array
	if ops_array.is_empty():
		return {"ok": false, "code": "EMPTY_OPERATIONS", "detail": "'operations' array cannot be empty."}
	if ops_array.size() > 16:
		return {"ok": false, "code": "OPERATIONS_OVERFLOW", "detail": "Maximum 16 operations allowed per packet."}

	var validated_ops: Array = []
	for i in range(ops_array.size()):
		var op_item: Variant = ops_array[i]
		if not op_item is Dictionary:
			return {"ok": false, "code": "MALFORMED_OPERATION", "detail": "Operation [%d] must be a JSON object." % i}
		var op_dict: Dictionary = op_item as Dictionary

		for k in op_dict.keys():
			var k_str := str(k).to_lower().strip_edges()
			if k_str in FORBIDDEN_FIELDS:
				return {"ok": false, "code": "FORBIDDEN_FIELD", "detail": "Operation [%d] contains forbidden field '%s'." % [i, k_str]}

		var op_code := str(op_dict.get("op", "")).to_upper().strip_edges()
		if op_code not in VALID_OPS:
			return {
				"ok": false,
				"code": "INVALID_OPERATION",
				"detail": "Unknown operation '%s' at index %d. Valid: %s" % [op_code, i, str(VALID_OPS)]
			}

		# Scope validation
		var scope_val: Variant = op_dict.get("scope", null)
		if not scope_val is Dictionary:
			return {
				"ok": false,
				"code": "INVALID_SCOPE",
				"detail": "Operation [%d] must contain a 'scope' object." % i
			}
		var scope_dict: Dictionary = scope_val as Dictionary
		var scope_type := str(scope_dict.get("type", "")).to_upper().strip_edges()
		if scope_type not in VALID_SCOPE_TYPES:
			return {
				"ok": false,
				"code": "INVALID_SCOPE_TYPE",
				"detail": "Scope type '%s' at index %d is invalid. Valid: %s" % [scope_type, i, str(VALID_SCOPE_TYPES)]
			}

		var clean_scope: Dictionary = {"type": scope_type}
		match scope_type:
			"CLASS":
				var cls_str := str(scope_dict.get("class", "")).to_upper().strip_edges()
				if cls_str not in VALID_CLASSES:
					return {
						"ok": false,
						"code": "INVALID_CLASS",
						"detail": "Class '%s' at index %d is invalid. Valid: %s" % [cls_str, i, str(VALID_CLASSES)]
					}
				clean_scope["class"] = cls_str
			"UNIT_ID":
				var uid := str(scope_dict.get("unit_id", "")).strip_edges().to_upper()
				if uid.is_empty():
					return {
						"ok": false,
						"code": "INVALID_UNIT_ID",
						"detail": "UNIT_ID scope requires a non-empty 'unit_id' string."
					}
				if known_units != null and not _is_known_unit(uid, known_units):
					return {
						"ok": false,
						"code": "UNKNOWN_UNIT_ID",
						"detail": "Unit ID '%s' is not an eligible formation." % uid
					}
				clean_scope["unit_id"] = uid
			"UNIT_IDS":
				var uids_val: Variant = scope_dict.get("unit_ids", null)
				if not uids_val is Array or (uids_val as Array).is_empty():
					return {
						"ok": false,
						"code": "INVALID_UNIT_IDS",
						"detail": "UNIT_IDS scope requires a non-empty array of unit IDs."
					}
				var clean_uids: Array = []
				for id_entry in (uids_val as Array):
					var id_str := str(id_entry).strip_edges().to_upper()
					if id_str.is_empty():
						continue
					if known_units != null and not _is_known_unit(id_str, known_units):
						return {
							"ok": false,
							"code": "UNKNOWN_UNIT_ID",
							"detail": "Unit ID '%s' in UNIT_IDS is not an eligible formation." % id_str
						}
					clean_uids.append(id_str)
				clean_scope["unit_ids"] = clean_uids
			"ALL_AVAILABLE":
				pass
			"SECTOR_CLASS":
				var sec := str(scope_dict.get("sector", "")).to_upper().strip_edges()
				if sec not in VALID_SECTORS:
					return {
						"ok": false,
						"code": "INVALID_SECTOR",
						"detail": "Sector '%s' at index %d is invalid. Valid: %s" % [str(scope_dict.get("sector", "")), i, str(VALID_SECTORS)]
					}
				var scls := str(scope_dict.get("class", "")).to_upper().strip_edges()
				if scls not in VALID_CLASSES:
					return {
						"ok": false,
						"code": "INVALID_CLASS",
						"detail": "Class '%s' at index %d is invalid. Valid: %s" % [scls, i, str(VALID_CLASSES)]
					}
				clean_scope["sector"] = sec
				clean_scope["class"] = scls
			"FORMATION_CLUSTER_CLASS":
				var cc := str(scope_dict.get("cluster", "")).to_upper().strip_edges()
				if not _is_cluster_id(cc):
					return {
						"ok": false,
						"code": "INVALID_CLUSTER",
						"detail": "Cluster '%s' at index %d is invalid. Use C, L1..Ln, R1..Rn." % [str(scope_dict.get("cluster", "")), i]
					}
				var ccls := str(scope_dict.get("class", "")).to_upper().strip_edges()
				if ccls not in VALID_CLASSES:
					return {
						"ok": false,
						"code": "INVALID_CLASS",
						"detail": "Class '%s' at index %d is invalid. Valid: %s" % [ccls, i, str(VALID_CLASSES)]
					}
				clean_scope["cluster"] = cc
				clean_scope["class"] = ccls
			"FORMATION_CLUSTER":
				var conly := str(scope_dict.get("cluster", "")).to_upper().strip_edges()
				if not _is_cluster_id(conly):
					return {
						"ok": false,
						"code": "INVALID_CLUSTER",
						"detail": "Cluster '%s' at index %d is invalid. Use C, L1..Ln, R1..Rn." % [str(scope_dict.get("cluster", "")), i]
					}
				clean_scope["cluster"] = conly
			"FORMATION_WING_CLASS":
				var wing := str(scope_dict.get("wing", "")).to_upper().strip_edges()
				if wing not in VALID_WINGS:
					return {
						"ok": false,
						"code": "INVALID_WING",
						"detail": "Wing '%s' at index %d is invalid. Valid: %s" % [str(scope_dict.get("wing", "")), i, str(VALID_WINGS)]
					}
				var wcls := str(scope_dict.get("class", "")).to_upper().strip_edges()
				if wcls not in VALID_CLASSES:
					return {
						"ok": false,
						"code": "INVALID_CLASS",
						"detail": "Class '%s' at index %d is invalid. Valid: %s" % [wcls, i, str(VALID_CLASSES)]
					}
				clean_scope["wing"] = wing
				clean_scope["class"] = wcls

		# Axis validation for directional ops
		var axis_val := str(op_dict.get("axis", "")).to_upper().strip_edges()
		if not axis_val.is_empty() and axis_val not in VALID_AXES:
			return {
				"ok": false,
				"code": "INVALID_AXIS",
				"detail": "Axis '%s' at index %d is invalid. Valid: %s" % [axis_val, i, str(VALID_AXES)]
			}
		if op_code in ["ADVANCE", "REPOSITION", "FLANK", "RETREAT", "RECON", "WITHDRAW", "REGROUP", "PROTECT", "SCREEN"] and axis_val.is_empty():
			if not op_dict.has("destination") and not op_dict.has("target"):
				return {
					"ok": false,
					"code": "MISSING_AXIS",
					"detail": "Operation '%s' at index %d requires an 'axis' (e.g. NORTH, SOUTH, EAST, WEST, FLANK)." % [op_code, i]
				}

		# Posture validation
		var posture_val := str(op_dict.get("posture", "NORMAL")).to_upper().strip_edges()
		if posture_val not in VALID_POSTURES:
			posture_val = "NORMAL"

		# March mode validation
		var march_val := str(op_dict.get("march_mode", "AUTO")).to_upper().strip_edges()
		if march_val not in VALID_MARCH_MODES:
			march_val = "AUTO"

		var clean_op: Dictionary = {
			"op": op_code,
			"scope": clean_scope,
			"posture": posture_val,
			"march_mode": march_val
		}
		if not axis_val.is_empty():
			clean_op["axis"] = axis_val

		# Attack specific validation
		if op_code == "ATTACK":
			var tgt := str(op_dict.get("target_unit_id", op_dict.get("target_id", op_dict.get("target", "")))).strip_edges().to_upper()
			if tgt.is_empty():
				return {
					"ok": false,
					"code": "MISSING_ATTACK_TARGET",
					"detail": "ATTACK operation requires a 'target_unit_id'."
				}
			clean_op["target_unit_id"] = tgt

		if op_dict.has("destination"):
			clean_op["destination"] = op_dict["destination"]

		# Movement targets ride the envelope for every op; the planner resolves
		# them against canonical state. Shape-checked here, existence-checked
		# by ActionCommand validation for verbs that require a target.
		if op_dict.get("target", {}) is Dictionary and not (op_dict.get("target", {}) as Dictionary).is_empty():
			var raw_target: Dictionary = op_dict["target"]
			var ttype := str(raw_target.get("type", "")).to_upper().strip_edges()
			if ttype not in VALID_TARGETS:
				return {
					"ok": false,
					"code": "INVALID_TARGET",
					"detail": "Target type '%s' at index %d is invalid." % [str(raw_target.get("type", "")), i]
				}
			if ttype == "HEX" and (not raw_target.has("q") or not raw_target.has("r")):
				return {
					"ok": false,
					"code": "INVALID_TARGET",
					"detail": "HEX target at index %d requires q and r." % i
				}
			if ttype == "FORMATION" and str(raw_target.get("unit_id", "")).strip_edges().is_empty():
				return {
					"ok": false,
					"code": "INVALID_TARGET",
					"detail": "FORMATION target at index %d requires a unit_id." % i
				}
			if ttype == "STRONGHOLD" and str(raw_target.get("id", "")).strip_edges().is_empty():
				return {
					"ok": false,
					"code": "TARGET_NOT_FOUND",
					"detail": "STRONGHOLD target at index %d requires a stronghold id." % i
				}
			if ttype == "SECTOR" and str(raw_target.get("sector", "")).to_upper().strip_edges() not in VALID_SECTORS:
				return {
					"ok": false,
					"code": "INVALID_TARGET",
					"detail": "SECTOR target at index %d requires a valid sector." % i
				}
			if ttype == "CLUSTER" and not _is_cluster_id(str(raw_target.get("cluster", "")).to_upper().strip_edges()):
				return {
					"ok": false,
					"code": "INVALID_TARGET",
					"detail": "CLUSTER target at index %d requires a valid cluster (C, L1..Ln, R1..Rn)." % i
				}
			var clean_target := {"type": ttype}
			for tk in ["q", "r", "unit_id", "id", "sector", "cluster", "class"]:
				if raw_target.has(tk):
					clean_target[tk] = str(raw_target[tk]).to_upper().strip_edges() if tk in ["sector", "cluster", "class"] else raw_target[tk]
			clean_op["target"] = clean_target

		validated_ops.append(clean_op)

	var validated_packet: Dictionary = {
		"version": CURRENT_VERSION,
		"mode": mode_val,
		"operations": validated_ops
	}
	if d.has("rationale"):
		validated_packet["rationale"] = str(d["rationale"]).left(300)

	return {
		"ok": true,
		"ir": validated_packet
	}

static func _is_cluster_id(cid: String) -> bool:
	var c := cid.strip_edges().to_upper()
	if c == "C":
		return true
	var re := RegEx.new()
	re.compile("^[LR][1-9][0-9]*$")
	return re.search(c) != null


static func _is_known_unit(uid: String, known_units: Variant) -> bool:
	if known_units is Array:
		for item in (known_units as Array):
			if str(item).to_upper() == uid:
				return true
			if item is Dictionary and str((item as Dictionary).get("id", "")).to_upper() == uid:
				return true
	elif known_units is Dictionary:
		var d: Dictionary = known_units as Dictionary
		if d.has(uid) or d.has(uid.to_lower()):
			return true
	return false
