class_name Step7WorldTruth
extends RefCounted

## Deterministic World Truth facade (Step 7 reset).
## Read-only access contract over the existing canonical systems.
## The shell + UnitManager + HexGrid + Fog remain the ONLY storage;
## this facade never duplicates game state into a second database.
##
## Owns the monotonic `state_version` and the OCC fingerprint used to
## reject stale plans. Zero LLM calls. Zero gameplay MCP calls.

var _shell: Node = null
var _unit_manager: RefCounted = null
var _hex_grid: Node = null
var _state_version: int = 0
var _battle_id: String = "det_battle_luoyang"


func configure(shell_ref: Node) -> bool:
	_shell = shell_ref
	if _shell == null:
		return false
	_unit_manager = _shell.get("unit_manager") as RefCounted
	_hex_grid = _shell.get("hex_grid") as Node
	return _unit_manager != null and _hex_grid != null


func is_ready() -> bool:
	return _shell != null and _unit_manager != null and _hex_grid != null


# --- Identity -------------------------------------------------------------

func get_battle_id() -> String:
	return _battle_id


func get_turn() -> int:
	if _unit_manager != null and _unit_manager.has_method("get_current_turn"):
		return int(_unit_manager.get_current_turn())
	return 1


## Milestone scope is the BLUE (player) command path; RED keeps its
## accepted deterministic Step-4 routine. Active side is fixed until a
## later milestone needs phase-accurate switching.
func get_active_side() -> String:
	return "blue"


# --- Version + OCC ---------------------------------------------------------

func get_version() -> int:
	return _state_version


## Record one action-relevant world mutation. Called by the action
## service after every executed plan and whenever an external change
## is detected at plan-check time.
func notify_mutation(_reason: String = "") -> int:
	_state_version += 1
	return _state_version


## Cheap deterministic fingerprint of action-relevant state:
## turn + per-unit position / movement / readiness / strength.
## Compared at execute time; no per-frame polling anywhere.
func fingerprint() -> String:
	var parts: Array = ["t=%d" % get_turn()]
	for u_val in _all_units_sorted():
		var u: Dictionary = u_val
		parts.append("%s:%d,%d:%s:%s:%d:%s" % [
			str(u.get("id", "?")),
			int(u.get("q", 0)), int(u.get("r", 0)),
			str(u.get("remaining_mp", "?")),
			str(u.get("action_ended", "?")),
			int(u.get("soldier_count", 0)),
			str(u.get("routed", "?")),
		])
	return "|".join(parts)


## Stale-plan rule. Returns exactly one of: VALID / REPLAN_REQUIRED / INVALID.
## Never executes stale cached coordinates blindly; the action service
## rebuilds from the stored command on REPLAN_REQUIRED.
func check_plan(plan: Dictionary) -> String:
	if plan.is_empty() or not plan.has("command") or not plan.has("fingerprint"):
		return "INVALID"
	if int(plan.get("turn", -1)) != get_turn():
		return "REPLAN_REQUIRED"
	if str(plan.get("fingerprint", "")) != fingerprint():
		# World moved under this plan (e.g. a manual map click executed
		# through the shell). Mark the version honestly, then replan.
		notify_mutation("external_change_detected")
		return "REPLAN_REQUIRED"
	return "VALID"


# --- Formations (internal legality access; never shown to players) ---------

func get_unit(unit_id: String) -> Dictionary:
	if _unit_manager != null and _unit_manager.has_method("get_unit_by_id"):
		return _unit_manager.get_unit_by_id(unit_id) as Dictionary
	return {}


func snapshot_units() -> Array:
	return _all_units_sorted()


# --- World (delegated to canonical owners) ---------------------------------

func cell_data() -> Dictionary:
	if _hex_grid != null:
		return _hex_grid.get("cell_data") as Dictionary
	return {}


func occupied_all() -> Dictionary:
	if _unit_manager != null and _unit_manager.has_method("get_occupied_dict"):
		return _unit_manager.get_occupied_dict() as Dictionary
	return {}


func _all_units_sorted() -> Array:
	var out: Array = []
	if _unit_manager == null:
		return out
	var raw: Array = []
	if _unit_manager.has_method("get_all_units_including_garrisoned"):
		raw = _unit_manager.get_all_units_including_garrisoned()
	for u_val in raw:
		if u_val is Dictionary:
			out.append(u_val)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("id", "")) < str(b.get("id", ""))
	)
	return out
