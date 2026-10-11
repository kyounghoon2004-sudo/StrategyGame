class_name Step7ActionCommand
extends RefCounted

## ONE typed semantic command representation (Step 7 reset).
## No command-specific functions; presets are DATA over this schema.
##
##   ActionCommand { action, scope, direction, target, posture, constraints }
##
## Wire format reuses the validated Battle IR packet (single operation)
## so the existing deterministic planner consumes it unchanged.
## Zero natural-language interpretation. Zero LLM.

## Movement verb set (deterministic; semantic contracts in §6 block below).
## New verbs are target-oriented compositions over existing movement mechanics.
const VALID_ACTIONS := ["ADVANCE", "MOVE", "HOLD", "RETREAT", "RECON", "FLANK", "REPOSITION", "WITHDRAW", "REGROUP", "PROTECT", "SCREEN"]
const VALID_SCOPE_TYPES := ["ALL_AVAILABLE", "CLASS", "UNIT_ID", "SECTOR_CLASS", "FORMATION_CLUSTER", "FORMATION_CLUSTER_CLASS", "FORMATION_WING_CLASS"]
# SECTOR_CLASS + VALID_SECTORS are LEGACY (fixed one-third prototype). They
# still validate and resolve via the wing-compatibility adapter in the
# planner, but new callers must use FORMATION_CLUSTER* / FORMATION_WING_*.
const VALID_SECTORS := ["LEFT_WING", "CENTER", "RIGHT_WING"]
const VALID_WINGS := ["LEFT", "CENTER", "RIGHT"]
const VALID_CLASSES := ["SCOUT", "CAVALRY", "INFANTRY", "SPEARMAN", "ARCHER", "CONSCRIPT", "SIEGE", "SUPPLY", "HQ"]
const VALID_DIRECTIONS := ["NORTH", "SOUTH", "EAST", "WEST", "NORTHEAST", "NORTHWEST", "SOUTHEAST", "SOUTHWEST", "RIGHT", "LEFT", "CENTER", "HQ", "FORWARD", "BACK"]
## FORWARD/BACK are side-relative: BLUE forward is EAST (see direction model).
const VALID_TARGETS := ["HEX", "FORMATION", "HQ", "SUPPLY", "STRONGHOLD", "CENTER", "SECTOR", "CLUSTER"]
const VALID_POSTURES := ["NORMAL", "AGGRESSIVE", "DEFENSIVE", "CAUTIOUS", "FAST"]

## Actions that require a compass direction.
const DIRECTION_REQUIRED := ["ADVANCE", "RETREAT", "RECON", "FLANK"]

const ERROR_CODES := [
	"UNKNOWN_ACTION", "INVALID_SCOPE", "UNIT_NOT_FOUND", "WRONG_SIDE",
	"UNIT_NOT_READY", "NO_VALID_UNITS", "TARGET_UNREACHABLE", "OCCUPIED",
	"INSUFFICIENT_MOVEMENT", "NO_LEGAL_DESTINATION", "STALE_STATE",
	"REPLAN_REQUIRED", "NOT_IMPLEMENTED",
	"INVALID_TARGET", "TARGET_NOT_FOUND", "INVALID_DIRECTION",
	"ACTION_NOT_SUPPORTED_FOR_CLASS",
]


static func make(action: String, scope: Dictionary, direction: String = "", target: Dictionary = {}, posture: String = "NORMAL", constraints: Dictionary = {}) -> Dictionary:
	return {
		"action": action.to_upper().strip_edges(),
		"scope": scope,
		"direction": direction.to_upper().strip_edges(),
		"target": target,
		"posture": posture.to_upper().strip_edges(),
		"constraints": constraints,
	}


static func scope_all() -> Dictionary:
	return {"type": "ALL_AVAILABLE"}


static func scope_class(unit_class: String) -> Dictionary:
	return {"type": "CLASS", "class": unit_class.to_upper().strip_edges()}


static func scope_unit(unit_id: String) -> Dictionary:
	return {"type": "UNIT_ID", "unit_id": unit_id.to_upper().strip_edges()}


## Sector-aware scope (LEGACY tactical-frame pilot): formations of one class
## whose CURRENT hex sits in the fixed sector. Resolved by the planner through
## the wing-compatibility adapter. New callers: use scope_cluster_class().
static func scope_sector_class(sector: String, unit_class: String) -> Dictionary:
	return {"type": "SECTOR_CLASS", "sector": sector.to_upper().strip_edges(), "class": unit_class.to_upper().strip_edges()}


## Adaptive cluster scopes (canonical): CURRENT-hex band vs the FROZEN
## turn geometry owned by Step7FormationClusters. Data-driven, no per-cluster
## functions. Wing LEFT = all L*, CENTER = C, RIGHT = all R*.
static func scope_cluster_class(cluster: String, unit_class: String) -> Dictionary:
	return {"type": "FORMATION_CLUSTER_CLASS", "cluster": cluster.to_upper().strip_edges(), "class": unit_class.to_upper().strip_edges()}


static func scope_cluster(cluster: String) -> Dictionary:
	return {"type": "FORMATION_CLUSTER", "cluster": cluster.to_upper().strip_edges()}


static func scope_wing_class(wing: String, unit_class: String) -> Dictionary:
	return {"type": "FORMATION_WING_CLASS", "wing": wing.to_upper().strip_edges(), "class": unit_class.to_upper().strip_edges()}


static func target_hex(q: int, r: int) -> Dictionary:
	return {"type": "HEX", "q": q, "r": r}


## Entity target constructors. HQ/CENTER need no fields; SUPPLY accepts an
## empty unit_id meaning "nearest own supply"; STRONGHOLD takes the canonical
## stronghold id (e.g. "Capital_Luoyang").
static func target_formation(unit_id: String) -> Dictionary:
	return {"type": "FORMATION", "unit_id": unit_id.to_upper().strip_edges()}


static func target_hq() -> Dictionary:
	return {"type": "HQ"}


static func target_supply(unit_id: String = "") -> Dictionary:
	return {"type": "SUPPLY", "unit_id": unit_id.to_upper().strip_edges()}


static func target_stronghold(stronghold_id: String) -> Dictionary:
	return {"type": "STRONGHOLD", "id": stronghold_id.strip_edges()}


static func target_center() -> Dictionary:
	return {"type": "CENTER"}


## Sector target (LEGACY tactical-frame pilot): operate toward the sector
## anchor. A movement preference, never a movement prison (source != target
## is legal). New callers: use target_cluster().
static func target_sector(sector: String) -> Dictionary:
	return {"type": "SECTOR", "sector": sector.to_upper().strip_edges()}


## Adaptive cluster target: operate toward the frozen anchor hex of one
## tactical cluster (Step7FormationClusters.cluster_anchor).
static func target_cluster(cluster: String) -> Dictionary:
	return {"type": "CLUSTER", "cluster": cluster.to_upper().strip_edges()}


## Cluster-id shape check (C, L1..Ln, R1..Rn). Kept local so command
## validation has zero clustering-state dependencies.
static func is_valid_cluster_id(cid: String) -> bool:
	var c := cid.strip_edges().to_upper()
	if c == "C":
		return true
	var re := RegEx.new()
	re.compile("^[LR][1-9][0-9]*$")
	return re.search(c) != null


## Structural validation only (no game-state access). Returns
## {ok, code, detail}. Game-state legality belongs to the planner.
static func validate_structure(cmd: Variant) -> Dictionary:
	if not cmd is Dictionary:
		return {"ok": false, "code": "INVALID_SCOPE", "detail": "Command must be a Dictionary."}
	var c: Dictionary = cmd
	var action := str(c.get("action", "")).to_upper()
	if action not in VALID_ACTIONS:
		return {"ok": false, "code": "UNKNOWN_ACTION", "detail": "Unknown action '%s'." % str(c.get("action", ""))}
	if not c.get("scope", {}) is Dictionary:
		return {"ok": false, "code": "INVALID_SCOPE", "detail": "Scope must be a Dictionary."}
	var scope: Dictionary = c["scope"]
	var scope_type := str(scope.get("type", "")).to_upper()
	if scope_type not in VALID_SCOPE_TYPES:
		return {"ok": false, "code": "INVALID_SCOPE", "detail": "Unknown scope type '%s'." % str(scope.get("type", ""))}
	if scope_type == "CLASS" and str(scope.get("class", "")).to_upper() not in VALID_CLASSES:
		return {"ok": false, "code": "INVALID_SCOPE", "detail": "Unknown class '%s'." % str(scope.get("class", ""))}
	if scope_type == "UNIT_ID" and str(scope.get("unit_id", "")).strip_edges().is_empty():
		return {"ok": false, "code": "INVALID_SCOPE", "detail": "UNIT_ID scope requires a unit_id."}
	if scope_type == "SECTOR_CLASS":
		if str(scope.get("sector", "")).to_upper() not in VALID_SECTORS:
			return {"ok": false, "code": "INVALID_SCOPE", "detail": "Unknown sector '%s'." % str(scope.get("sector", ""))}
		if str(scope.get("class", "")).to_upper() not in VALID_CLASSES:
			return {"ok": false, "code": "INVALID_SCOPE", "detail": "Unknown class '%s'." % str(scope.get("class", ""))}
	if scope_type == "FORMATION_CLUSTER_CLASS":
		if not is_valid_cluster_id(str(scope.get("cluster", ""))):
			return {"ok": false, "code": "INVALID_SCOPE", "detail": "Unknown cluster '%s'." % str(scope.get("cluster", ""))}
		if str(scope.get("class", "")).to_upper() not in VALID_CLASSES:
			return {"ok": false, "code": "INVALID_SCOPE", "detail": "Unknown class '%s'." % str(scope.get("class", ""))}
	if scope_type == "FORMATION_CLUSTER":
		if not is_valid_cluster_id(str(scope.get("cluster", ""))):
			return {"ok": false, "code": "INVALID_SCOPE", "detail": "Unknown cluster '%s'." % str(scope.get("cluster", ""))}
	if scope_type == "FORMATION_WING_CLASS":
		if str(scope.get("wing", "")).to_upper() not in VALID_WINGS:
			return {"ok": false, "code": "INVALID_SCOPE", "detail": "Unknown wing '%s'." % str(scope.get("wing", ""))}
		if str(scope.get("class", "")).to_upper() not in VALID_CLASSES:
			return {"ok": false, "code": "INVALID_SCOPE", "detail": "Unknown class '%s'." % str(scope.get("class", ""))}
	if action == "MOVE":
		var target: Variant = c.get("target", {})
		if not target is Dictionary or str((target as Dictionary).get("type", "")).to_upper() != "HEX":
			return {"ok": false, "code": "INVALID_SCOPE", "detail": "MOVE requires a HEX target."}
		if not (target as Dictionary).has("q") or not (target as Dictionary).has("r"):
			return {"ok": false, "code": "INVALID_SCOPE", "detail": "HEX target requires q and r."}
	elif action in ["REPOSITION", "WITHDRAW", "REGROUP", "PROTECT", "SCREEN"]:
		var tres: Dictionary = validate_target(c.get("target", {}))
		if not bool(tres.get("ok", false)):
			return tres
		if not str(c.get("direction", "")).is_empty() and str(c.get("direction", "")).to_upper() not in VALID_DIRECTIONS:
			return {"ok": false, "code": "INVALID_DIRECTION", "detail": "Unknown direction '%s'." % str(c.get("direction", ""))}
	elif action in DIRECTION_REQUIRED:
		if str(c.get("direction", "")).to_upper() not in VALID_DIRECTIONS:
			return {"ok": false, "code": "INVALID_SCOPE", "detail": "Action %s requires a valid direction." % action}
	if str(c.get("posture", "NORMAL")).to_upper() not in VALID_POSTURES:
		return {"ok": false, "code": "INVALID_SCOPE", "detail": "Unknown posture."}
	return {"ok": true, "code": "", "detail": ""}


## Target shape validation for target-oriented verbs. Returns
## {ok, code, detail} with INVALID_TARGET / TARGET_NOT_FOUND semantics.
static func validate_target(target: Variant) -> Dictionary:
	if not target is Dictionary:
		return {"ok": false, "code": "INVALID_TARGET", "detail": "Target must be a Dictionary."}
	var t: Dictionary = target
	var ttype := str(t.get("type", "")).to_upper()
	if ttype not in VALID_TARGETS:
		return {"ok": false, "code": "INVALID_TARGET", "detail": "Unknown target type '%s'." % str(t.get("type", ""))}
	match ttype:
		"HEX":
			if not t.has("q") or not t.has("r"):
				return {"ok": false, "code": "INVALID_TARGET", "detail": "HEX target requires q and r."}
		"FORMATION":
			if str(t.get("unit_id", "")).strip_edges().is_empty():
				return {"ok": false, "code": "INVALID_TARGET", "detail": "FORMATION target requires a unit_id."}
		"STRONGHOLD":
			if str(t.get("id", "")).strip_edges().is_empty():
				return {"ok": false, "code": "TARGET_NOT_FOUND", "detail": "STRONGHOLD target requires a stronghold id."}
		"SECTOR":
			if str(t.get("sector", "")).to_upper() not in VALID_SECTORS:
				return {"ok": false, "code": "INVALID_TARGET", "detail": "Unknown sector '%s'." % str(t.get("sector", ""))}
		"CLUSTER":
			if not is_valid_cluster_id(str(t.get("cluster", ""))):
				return {"ok": false, "code": "INVALID_TARGET", "detail": "Unknown cluster '%s'." % str(t.get("cluster", ""))}
	return {"ok": true, "code": "", "detail": ""}


## Convert one ActionCommand to a single-operation Battle IR packet.
static func to_battle_ir(cmd: Dictionary) -> Dictionary:
	var op := {
		"op": str(cmd.get("action", "HOLD")),
		"scope": (cmd.get("scope", {}) as Dictionary).duplicate(true),
		"posture": str(cmd.get("posture", "NORMAL")),
	}
	if not str(cmd.get("direction", "")).is_empty():
		op["axis"] = str(cmd["direction"])
	var _t: Variant = cmd.get("target", {})
	if _t is Dictionary and not (_t as Dictionary).is_empty():
		op["target"] = (_t as Dictionary).duplicate(true)
	return {"version": 1, "mode": "COMMAND", "operations": [op]}


static func describe(cmd: Dictionary) -> String:
	var parts := [str(cmd.get("action", "?"))]
	var scope: Dictionary = cmd.get("scope", {})
	match str(scope.get("type", "")):
		"ALL_AVAILABLE":
			parts.append("ALL")
		"CLASS":
			parts.append(str(scope.get("class", "?")))
		"UNIT_ID":
			parts.append(str(scope.get("unit_id", "?")))
		"SECTOR_CLASS":
			parts.append("%s+%s" % [str(scope.get("sector", "?")), str(scope.get("class", "?"))])
		"FORMATION_CLUSTER_CLASS":
			parts.append("%s+%s" % [str(scope.get("cluster", "?")), str(scope.get("class", "?"))])
		"FORMATION_CLUSTER":
			parts.append(str(scope.get("cluster", "?")))
		"FORMATION_WING_CLASS":
			parts.append("%s+%s" % [str(scope.get("wing", "?")), str(scope.get("class", "?"))])
	if not str(cmd.get("direction", "")).is_empty():
		parts.append(str(cmd["direction"]))
	var _dt: Variant = cmd.get("target", {})
	if _dt is Dictionary and not (_dt as Dictionary).is_empty():
		parts.append(describe_target(_dt))
	return " ".join(parts)


static func describe_target(t: Dictionary) -> String:
	match str(t.get("type", "")).to_upper():
		"HEX":
			return "-> (%d,%d)" % [int(t.get("q", 0)), int(t.get("r", 0))]
		"FORMATION":
			return "-> %s" % str(t.get("unit_id", "?"))
		"SUPPLY":
			return "-> SUPPLY %s" % (str(t.get("unit_id", "?")) if not str(t.get("unit_id", "")).is_empty() else "(nearest)")
		"STRONGHOLD":
			return "-> %s" % str(t.get("id", "?"))
		"SECTOR":
			return "-> %s" % str(t.get("sector", "?"))
		"CLUSTER":
			return "-> %s" % str(t.get("cluster", "?"))
		_:
			return "-> %s" % str(t.get("type", "?"))


# --- Manual presets: DATA over ActionCommand, nothing else -----------------
# IDs are stable; future milestones may add more rows, never code paths.

static func move_preset(unit_id: String, q: int, r: int) -> Dictionary:
	return make("MOVE", scope_unit(unit_id), "", target_hex(q, r))


## Movement test catalog: DATA over the ActionCommand grammar. The original
## seven rows are byte-identical in meaning; "group" only organizes the panel.
static func preset_groups() -> Array:
	return ["GENERAL", "CAVALRY", "SCOUT", "INFANTRY", "SPEARMAN", "ARCHER", "SIEGE", "EXACT UNIT"]


static func presets() -> Dictionary:
	return {
		"ADVANCE_ALL_NORTH": {
			"label": "ADVANCE_ALL_NORTH", "group": "GENERAL",
			"command": make("ADVANCE", scope_all(), "NORTH"),
		},
		"ADVANCE_ALL_SOUTH": {
			"label": "ADVANCE_ALL_SOUTH", "group": "GENERAL",
			"command": make("ADVANCE", scope_all(), "SOUTH"),
		},
		"ADVANCE_ALL_FORWARD": {
			"label": "ADVANCE_ALL_FORWARD", "group": "GENERAL",
			"command": make("ADVANCE", scope_all(), "FORWARD"),
		},
		"ADVANCE_ALL_BACK": {
			"label": "ADVANCE_ALL_BACK", "group": "GENERAL",
			"command": make("ADVANCE", scope_all(), "BACK"),
		},
		"ADVANCE_ALL_LEFT": {
			"label": "ADVANCE_ALL_LEFT", "group": "GENERAL",
			"command": make("ADVANCE", scope_all(), "LEFT"),
		},
		"ADVANCE_ALL_RIGHT": {
			"label": "ADVANCE_ALL_RIGHT", "group": "GENERAL",
			"command": make("ADVANCE", scope_all(), "RIGHT"),
		},
		"HOLD_ALL": {
			"label": "HOLD_ALL", "group": "GENERAL",
			"command": make("HOLD", scope_all()),
		},
		"RETREAT_ALL": {
			"label": "RETREAT_ALL", "group": "GENERAL",
			"command": make("RETREAT", scope_all(), "WEST"),
		},
		"WITHDRAW_ALL_TO_HQ": {
			"label": "WITHDRAW_ALL_TO_HQ", "group": "GENERAL",
			"command": make("WITHDRAW", scope_all(), "", target_hq()),
		},
		"REGROUP_ALL_TO_HQ": {
			"label": "REGROUP_ALL_TO_HQ", "group": "GENERAL",
			"command": make("REGROUP", scope_all(), "", target_hq()),
		},
		"ADVANCE_CAVALRY_LEFT": {
			"label": "ADVANCE_CAVALRY_LEFT", "group": "CAVALRY",
			"command": make("ADVANCE", scope_class("CAVALRY"), "LEFT"),
		},
		"ADVANCE_CAVALRY_RIGHT": {
			"label": "ADVANCE_CAVALRY_RIGHT", "group": "CAVALRY",
			"command": make("ADVANCE", scope_class("CAVALRY"), "RIGHT"),
		},
		"ADVANCE_CAVALRY_FORWARD": {
			"label": "ADVANCE_CAVALRY_FORWARD", "group": "CAVALRY",
			"command": make("ADVANCE", scope_class("CAVALRY"), "FORWARD"),
		},
		"FLANK_CAVALRY_RIGHT": {
			"label": "FLANK_CAVALRY_RIGHT", "group": "CAVALRY",
			"command": make("FLANK", scope_class("CAVALRY"), "RIGHT"),
		},
		"FLANK_CAVALRY_LEFT": {
			"label": "FLANK_CAVALRY_LEFT", "group": "CAVALRY",
			"command": make("FLANK", scope_class("CAVALRY"), "LEFT"),
		},
		"RETREAT_CAVALRY": {
			"label": "RETREAT_CAVALRY", "group": "CAVALRY",
			"command": make("RETREAT", scope_class("CAVALRY"), "WEST"),
		},
		"REPOSITION_CAVALRY_TO_CENTER": {
			"label": "REPOSITION_CAVALRY_TO_CENTER", "group": "CAVALRY",
			"command": make("REPOSITION", scope_class("CAVALRY"), "", target_center()),
		},
		"WITHDRAW_CAVALRY_TO_HQ": {
			"label": "WITHDRAW_CAVALRY_TO_HQ", "group": "CAVALRY",
			"command": make("WITHDRAW", scope_class("CAVALRY"), "", target_hq()),
		},
		"RECON_SCOUT_NORTH": {
			"label": "RECON_SCOUT_NORTH", "group": "SCOUT",
			"command": make("RECON", scope_class("SCOUT"), "NORTH"),
		},
		"RECON_SCOUT_FORWARD": {
			"label": "RECON_SCOUT_FORWARD", "group": "SCOUT",
			"command": make("RECON", scope_class("SCOUT"), "FORWARD"),
		},
		"RECON_SCOUT_RIGHT": {
			"label": "RECON_SCOUT_RIGHT", "group": "SCOUT",
			"command": make("RECON", scope_class("SCOUT"), "RIGHT"),
		},
		"RECON_SCOUT_SOUTH": {
			"label": "RECON_SCOUT_SOUTH", "group": "SCOUT",
			"command": make("RECON", scope_class("SCOUT"), "SOUTH"),
		},
		"RECON_SCOUT_LEFT": {
			"label": "RECON_SCOUT_LEFT", "group": "SCOUT",
			"command": make("RECON", scope_class("SCOUT"), "LEFT"),
		},
		"RETREAT_SCOUT": {
			"label": "RETREAT_SCOUT", "group": "SCOUT",
			"command": make("RETREAT", scope_class("SCOUT"), "WEST"),
		},
		"REPOSITION_SCOUT_TO_CENTER": {
			"label": "REPOSITION_SCOUT_TO_CENTER", "group": "SCOUT",
			"command": make("REPOSITION", scope_class("SCOUT"), "", target_center()),
		},
		"RETREAT_INFANTRY": {
			"label": "RETREAT_INFANTRY", "group": "INFANTRY",
			"command": make("RETREAT", scope_class("INFANTRY"), "WEST"),
		},
		"ADVANCE_INFANTRY_FORWARD": {
			"label": "ADVANCE_INFANTRY_FORWARD", "group": "INFANTRY",
			"command": make("ADVANCE", scope_class("INFANTRY"), "FORWARD"),
		},
		"WITHDRAW_INFANTRY_TO_HQ": {
			"label": "WITHDRAW_INFANTRY_TO_HQ", "group": "INFANTRY",
			"command": make("WITHDRAW", scope_class("INFANTRY"), "", target_hq()),
		},
		"HOLD_INFANTRY": {
			"label": "HOLD_INFANTRY", "group": "INFANTRY",
			"command": make("HOLD", scope_class("INFANTRY")),
		},
		"PROTECT_HQ_INFANTRY": {
			"label": "PROTECT_HQ_INFANTRY", "group": "INFANTRY",
			"command": make("PROTECT", scope_class("INFANTRY"), "", target_hq()),
		},
		"REPOSITION_INFANTRY_TO_STRONGHOLD": {
			"label": "REPOSITION_INFANTRY_TO_STRONGHOLD", "group": "INFANTRY",
			"command": make("REPOSITION", scope_class("INFANTRY"), "", target_stronghold("Capital_Luoyang")),
		},
		"ADVANCE_SPEARMAN_FORWARD": {
			"label": "ADVANCE_SPEARMAN_FORWARD", "group": "SPEARMAN",
			"command": make("ADVANCE", scope_class("SPEARMAN"), "FORWARD"),
		},
		"HOLD_SPEARMAN": {
			"label": "HOLD_SPEARMAN", "group": "SPEARMAN",
			"command": make("HOLD", scope_class("SPEARMAN")),
		},
		"RETREAT_SPEARMAN": {
			"label": "RETREAT_SPEARMAN", "group": "SPEARMAN",
			"command": make("RETREAT", scope_class("SPEARMAN"), "WEST"),
		},
		"PROTECT_HQ_SPEARMAN": {
			"label": "PROTECT_HQ_SPEARMAN", "group": "SPEARMAN",
			"command": make("PROTECT", scope_class("SPEARMAN"), "", target_hq()),
		},
		"REPOSITION_SPEARMAN_TO_CENTER": {
			"label": "REPOSITION_SPEARMAN_TO_CENTER", "group": "SPEARMAN",
			"command": make("REPOSITION", scope_class("SPEARMAN"), "", target_center()),
		},
		"REPOSITION_ARCHER_FORWARD": {
			"label": "REPOSITION_ARCHER_FORWARD", "group": "ARCHER",
			"command": make("REPOSITION", scope_class("ARCHER"), "FORWARD", target_center()),
		},
		"REPOSITION_ARCHER_BACK": {
			"label": "REPOSITION_ARCHER_BACK", "group": "ARCHER",
			"command": make("REPOSITION", scope_class("ARCHER"), "BACK", target_hq()),
		},
		"PROTECT_HQ_ARCHER": {
			"label": "PROTECT_HQ_ARCHER", "group": "ARCHER",
			"command": make("PROTECT", scope_class("ARCHER"), "", target_hq()),
		},
		"HOLD_ARCHER": {
			"label": "HOLD_ARCHER", "group": "ARCHER",
			"command": make("HOLD", scope_class("ARCHER")),
		},
		"RETREAT_ARCHER": {
			"label": "RETREAT_ARCHER", "group": "ARCHER",
			"command": make("RETREAT", scope_class("ARCHER"), "WEST"),
		},
		"ADVANCE_SIEGE_FORWARD": {
			"label": "ADVANCE_SIEGE_FORWARD", "group": "SIEGE",
			"command": make("ADVANCE", scope_class("SIEGE"), "FORWARD"),
		},
		"REPOSITION_SIEGE_TO_STRONGHOLD": {
			"label": "REPOSITION_SIEGE_TO_STRONGHOLD", "group": "SIEGE",
			"command": make("REPOSITION", scope_class("SIEGE"), "", target_stronghold("Capital_Luoyang")),
		},
		"HOLD_SIEGE": {
			"label": "HOLD_SIEGE", "group": "SIEGE",
			"command": make("HOLD", scope_class("SIEGE")),
		},
		"RETREAT_SIEGE": {
			"label": "RETREAT_SIEGE", "group": "SIEGE",
			"command": make("RETREAT", scope_class("SIEGE"), "WEST"),
		},
		"MOVE_SELECTED_UNIT_TO_HEX": {
			"label": "MOVE_SELECTED_UNIT_TO_HEX", "group": "EXACT UNIT",
			"template": true, "binding": "selected_unit_hex",
			"command": make("MOVE", scope_unit("*SELECTED*"), "", target_hex(0, 0)),
		},
		"MOVE_SELECTED_UNIT_TO_HQ": {
			"label": "MOVE_SELECTED_UNIT_TO_HQ", "group": "EXACT UNIT",
			"template": true, "binding": "selected_unit",
			"command": make("WITHDRAW", scope_unit("*SELECTED*"), "", target_hq()),
		},
		"MOVE_SELECTED_UNIT_TO_CENTER": {
			"label": "MOVE_SELECTED_UNIT_TO_CENTER", "group": "EXACT UNIT",
			"template": true, "binding": "selected_unit",
			"command": make("REPOSITION", scope_unit("*SELECTED*"), "", target_center()),
		},
		"HOLD_SELECTED_UNIT": {
			"label": "HOLD_SELECTED_UNIT", "group": "EXACT UNIT",
			"template": true, "binding": "selected_unit",
			"command": make("HOLD", scope_unit("*SELECTED*")),
		},
		"RETREAT_SELECTED_UNIT": {
			"label": "RETREAT_SELECTED_UNIT", "group": "EXACT UNIT",
			"template": true, "binding": "selected_unit",
			"command": make("RETREAT", scope_unit("*SELECTED*"), "WEST"),
		},
	}


## Canonical 50-preset order (01-50). IDs match presets() keys.
const PRESET_ORDER := [
	"ADVANCE_ALL_FORWARD", "ADVANCE_ALL_BACK", "ADVANCE_ALL_NORTH",
	"ADVANCE_ALL_SOUTH", "ADVANCE_ALL_LEFT", "ADVANCE_ALL_RIGHT",
	"HOLD_ALL", "RETREAT_ALL", "REGROUP_ALL_TO_HQ", "WITHDRAW_ALL_TO_HQ",
	"ADVANCE_CAVALRY_FORWARD", "ADVANCE_CAVALRY_LEFT", "ADVANCE_CAVALRY_RIGHT",
	"FLANK_CAVALRY_LEFT", "FLANK_CAVALRY_RIGHT", "REPOSITION_CAVALRY_TO_CENTER",
	"RETREAT_CAVALRY", "WITHDRAW_CAVALRY_TO_HQ",
	"RECON_SCOUT_FORWARD", "RECON_SCOUT_NORTH", "RECON_SCOUT_SOUTH",
	"RECON_SCOUT_LEFT", "RECON_SCOUT_RIGHT", "REPOSITION_SCOUT_TO_CENTER",
	"RETREAT_SCOUT",
	"ADVANCE_INFANTRY_FORWARD", "HOLD_INFANTRY", "PROTECT_HQ_INFANTRY",
	"REPOSITION_INFANTRY_TO_STRONGHOLD", "RETREAT_INFANTRY", "WITHDRAW_INFANTRY_TO_HQ",
	"ADVANCE_SPEARMAN_FORWARD", "HOLD_SPEARMAN", "PROTECT_HQ_SPEARMAN",
	"REPOSITION_SPEARMAN_TO_CENTER", "RETREAT_SPEARMAN",
	"REPOSITION_ARCHER_FORWARD", "REPOSITION_ARCHER_BACK", "HOLD_ARCHER",
	"PROTECT_HQ_ARCHER", "RETREAT_ARCHER",
	"ADVANCE_SIEGE_FORWARD", "REPOSITION_SIEGE_TO_STRONGHOLD", "HOLD_SIEGE",
	"RETREAT_SIEGE",
	"MOVE_SELECTED_UNIT_TO_HEX", "MOVE_SELECTED_UNIT_TO_HQ",
	"MOVE_SELECTED_UNIT_TO_CENTER", "HOLD_SELECTED_UNIT", "RETREAT_SELECTED_UNIT",
]


## True when a preset row is a selected-unit template needing runtime binding.
static func is_template_preset(row: Dictionary) -> bool:
	return bool(row.get("template", false))


## Bind a template preset to a live selected unit (and hex for HEX binding).
## Returns {} when no unit is selected. Non-template rows return their command.
static func bind_preset(row: Dictionary, unit_id: String, q: int = 0, r: int = 0) -> Dictionary:
	if not is_template_preset(row):
		return (row.get("command", {}) as Dictionary).duplicate(true)
	var uid := unit_id.strip_edges()
	if uid.is_empty():
		return {}
	var cmd: Dictionary = (row.get("command", {}) as Dictionary).duplicate(true)
	cmd["scope"] = scope_unit(uid)
	if str(row.get("binding", "")) == "selected_unit_hex":
		cmd["target"] = target_hex(q, r)
	return cmd
