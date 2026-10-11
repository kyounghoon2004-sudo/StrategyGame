class_name Cloud1ActionTable
extends RefCounted

## CLOUD-GENERAL STEP 1B — Shared Operational Action Table (canonical schema).
##
## Compact parameterized model: ACTION x SCOPE x TARGET/DIRECTION
## x MOVEMENT POLICY x STANCE. No phrase-specific functions.
##
## Family rationalization vs the production Step7 verb set (documented, not
## duplicated): PRESSURE = ADVANCE+ASSERTIVE; PURSUE = REPOSITION toward a
## visible enemy formation; CONCENTRATE = REPOSITION toward CENTER;
## RESERVE = HOLD in place; SPREAD = schema-preserved but behavior DEFERRED
## (no neutral-board dispersion mechanic exists without an opaque scorer,
## which Step 1 forbids).

const ACTIVE_ACTIONS := ["ADVANCE", "HOLD", "WITHDRAW", "REPOSITION", "ATTACK", "FLANK", "RECON", "CONCENTRATE"]
const DEFERRED_ACTIONS := ["PRESSURE", "PURSUE", "SPREAD", "RESERVE"]
const ACTIONS := ["ADVANCE", "HOLD", "WITHDRAW", "REPOSITION", "ATTACK", "FLANK", "RECON", "CONCENTRATE", "PRESSURE", "PURSUE", "SPREAD", "RESERVE"]

## Directly executable through the authoritative path in Step 1.
const EXECUTABLE := ["ADVANCE", "HOLD", "WITHDRAW", "REPOSITION", "ATTACK", "FLANK", "RECON", "CONCENTRATE"]

const SCOPE_KINDS := ["ALL_FRIENDLY", "ALL_COMBAT", "CLASS", "REGION", "FORMATION", "SELECTED", "UNITS", "UNION", "INTERSECT", "DIFF"]
const KNOWN_CLASSES := ["INFANTRY", "ARCHER", "CAVALRY", "SPEARMAN", "SCOUT", "SIEGE", "CONSCRIPT", "HQ"]
const COMBAT_CLASSES := ["INFANTRY", "ARCHER", "CAVALRY", "SPEARMAN", "SCOUT", "SIEGE", "CONSCRIPT"]
const DIRECTIONS := ["FORWARD", "BACKWARD", "LEFT", "RIGHT", "NORTH", "SOUTH", "EAST", "WEST"]
const TARGET_TYPES := ["DIRECTION", "HEX", "FORMATION", "OBJECTIVE", "ZONE"]
const ZONES := ["CENTER", "HQ"]
const POLICIES := ["MINIMAL", "LIMITED", "STANDARD", "EXTENDED", "MAXIMUM"]
const STANCES := ["CAUTIOUS", "BALANCED", "ASSERTIVE", "AGGRESSIVE"]

const DIRECTION_REQUIRED := ["ADVANCE", "FLANK", "RECON", "PRESSURE"]
const TARGET_REQUIRED := ["ATTACK", "PURSUE", "WITHDRAW", "REPOSITION", "CONCENTRATE"]

## Stance semantics are schema-preserved but behavior-DEFERRED in Step 1:
## stance is recorded and inspectable, it never alters legality or silently
## re-scores destinations (no opaque AI scoring allowed in this step).
const STANCE_DEFERRED_NOTE := "Stance is recorded for intent; Step 1 movement legality is stance-independent (deferred)."


static func family_ids() -> Array:
	return ACTIONS.duplicate()


static func make_command(action: String, scope: Dictionary, target: Dictionary = {}, arg4: Variant = null, arg5: Variant = null) -> Dictionary:
	var stance := "BALANCED"
	if arg4 is String and arg4 in STANCES:
		stance = arg4
	elif arg5 is String and arg5 in STANCES:
		stance = arg5
	return {
		"action": action.strip_edges().to_upper(),
		"scope": scope.duplicate(true),
		"target": target.duplicate(true),
		"stance": stance.strip_edges().to_upper(),
	}


static func scope_all_friendly() -> Dictionary:
	return {"kind": "ALL_FRIENDLY"}


static func scope_all_combat() -> Dictionary:
	return {"kind": "ALL_COMBAT"}


static func scope_class(unit_class: String) -> Dictionary:
	return {"kind": "CLASS", "class": unit_class.strip_edges().to_upper()}


static func scope_region(region: String) -> Dictionary:
	return {"kind": "REGION", "region": region.strip_edges().to_upper()}


static func scope_formation(formation: String) -> Dictionary:
	return {"kind": "FORMATION", "formation": formation.strip_edges().to_upper()}


static func scope_selected() -> Dictionary:
	return {"kind": "SELECTED"}


static func scope_units(unit_ids: Array) -> Dictionary:
	var ids: Array = []
	for v in unit_ids:
		ids.append(str(v).strip_edges().to_upper())
	ids.sort()
	return {"kind": "UNITS", "unit_ids": ids}


static func target_direction(direction: String) -> Dictionary:
	return {"type": "DIRECTION", "direction": direction.strip_edges().to_upper()}


static func target_hex(q: int, r: int) -> Dictionary:
	return {"type": "HEX", "q": q, "r": r}


static func target_formation(unit_id: String) -> Dictionary:
	return {"type": "FORMATION", "unit_id": unit_id.strip_edges().to_upper()}


static func target_objective() -> Dictionary:
	return {"type": "OBJECTIVE"}


static func target_zone(zone: String) -> Dictionary:
	return {"type": "ZONE", "zone": zone.strip_edges().to_upper()}


## Structural validation only (no game-state access). Returns {ok, code, detail}.
static func validate_command(cmd: Variant) -> Dictionary:
	if not cmd is Dictionary:
		return {"ok": false, "code": "INVALID_COMMAND", "detail": "Command must be a Dictionary."}
	var c: Dictionary = cmd
	var action := str(c.get("action", "")).strip_edges().to_upper()
	if not action in ACTIONS:
		return {"ok": false, "code": "UNKNOWN_ACTION", "detail": "Unknown action '%s'." % str(c.get("action", ""))}
	if action in DEFERRED_ACTIONS:
		return {"ok": false, "code": "ACTION_DEFERRED", "detail": "Action '%s' is schema-preserved but behavior-deferred in Step 1 (deferred, not silently dropped)." % action}
	var scope: Variant = c.get("scope", {})
	if not scope is Dictionary:
		return {"ok": false, "code": "INVALID_SCOPE", "detail": "Scope must be a Dictionary."}
	var sres := _validate_scope(scope)
	if not bool(sres.get("ok", false)):
		return sres
	var target: Variant = c.get("target", {})
	if not target is Dictionary:
		return {"ok": false, "code": "INVALID_TARGET", "detail": "Target must be a Dictionary."}
	if action in DIRECTION_REQUIRED:
		var ttype := str((target as Dictionary).get("type", (target as Dictionary).get("kind", ""))).strip_edges().to_upper()
		var flank_formation := false
		if action == "FLANK" and ttype == "FORMATION":
			var uid_f := str((target as Dictionary).get("unit_id", (target as Dictionary).get("value", ""))).strip_edges()
			if uid_f.is_empty():
				return {"ok": false, "code": "INVALID_TARGET", "detail": "FLANK formation target requires a unit_id."}
			# TARGET_CONTRACT_V1: FLANK + visible-enemy FORMATION names the
			# operational object; no direction is required (the compiler's
			# formation-flank path derives destination relative to it).
			flank_formation = true
		else:
			if ttype != "DIRECTION":
				return {"ok": false, "code": "INVALID_TARGET", "detail": "Action %s requires a DIRECTION target." % action}
		if not flank_formation:
			var d := str((target as Dictionary).get("direction", (target as Dictionary).get("value", ""))).strip_edges().to_upper()
			if d == "BACKWARD":
				d = "BACK"
			if not d in DIRECTIONS and d != "BACK":
				return {"ok": false, "code": "INVALID_DIRECTION", "detail": "Unknown direction '%s'." % str(d)}
	if action in TARGET_REQUIRED:
		if (target as Dictionary).is_empty():
			return {"ok": false, "code": "INVALID_TARGET", "detail": "Action %s requires a target." % action}
		var tres := _validate_target(target, action)
		if not bool(tres.get("ok", false)):
			return tres
	elif not (target as Dictionary).is_empty() and action in ["HOLD", "RESERVE", "SPREAD"]:
		return {"ok": false, "code": "INVALID_TARGET", "detail": "Action %s takes no target." % action}
	var policy := str(c.get("movement_policy", "")).strip_edges().to_upper()
	if not policy.is_empty() and not policy in POLICIES:
		return {"ok": false, "code": "INVALID_POLICY", "detail": "Unknown movement policy '%s'." % str(c.get("movement_policy", ""))}
	var stance := str(c.get("stance", "BALANCED")).strip_edges().to_upper()
	if stance.is_empty():
		stance = "BALANCED"
	if not stance in STANCES:
		return {"ok": false, "code": "INVALID_STANCE", "detail": "Unknown stance '%s'." % str(c.get("stance", ""))}
	return {"ok": true, "code": "", "detail": ""}


static func _validate_scope(scope: Dictionary) -> Dictionary:
	if scope.has("op"):
		var ScopeAlgebraScript = load("res://scripts/step7/step7_scope_algebra.gd")
		if ScopeAlgebraScript:
			var v_res: Dictionary = ScopeAlgebraScript.validate_expr(scope)
			if not bool(v_res.get("ok", false)):
				return {"ok": false, "code": "INVALID_SCOPE", "detail": str(v_res.get("why", "Invalid scope expression."))}
			return {"ok": true, "code": "", "detail": ""}
	var kind := str(scope.get("kind", "")).strip_edges().to_upper()
	if not kind in SCOPE_KINDS:
		return {"ok": false, "code": "INVALID_SCOPE", "detail": "Unknown scope kind '%s'." % str(scope.get("kind", ""))}
	match kind:
		"CLASS":
			var cls_val := str(scope.get("class", scope.get("value", ""))).strip_edges().to_upper()
			if not cls_val in KNOWN_CLASSES:
				return {"ok": false, "code": "INVALID_SCOPE", "detail": "Unknown class '%s'." % cls_val}
		"REGION":
			var reg := str(scope.get("region", scope.get("value", ""))).strip_edges().to_upper()
			if not reg in ["NORTH", "CENTER", "SOUTH", "WEST", "EAST"]:
				return {"ok": false, "code": "INVALID_SCOPE", "detail": "Unknown region '%s'." % reg}
		"FORMATION":
			var form_val := str(scope.get("formation", scope.get("value", ""))).strip_edges()
			if form_val.is_empty():
				return {"ok": false, "code": "INVALID_SCOPE", "detail": "FORMATION scope requires a formation id."}
		"UNITS":
			var ids: Variant = scope.get("unit_ids", scope.get("units", scope.get("value", [])))
			if not ids is Array or (ids as Array).is_empty():
				return {"ok": false, "code": "INVALID_SCOPE", "detail": "UNITS scope requires a non-empty unit_ids array."}
	return {"ok": true, "code": "", "detail": ""}


static func _validate_target(target: Dictionary, action: String) -> Dictionary:
	var ttype := str(target.get("type", target.get("kind", ""))).strip_edges().to_upper()
	if not ttype in TARGET_TYPES:
		return {"ok": false, "code": "INVALID_TARGET", "detail": "Unknown target type '%s'." % str(ttype)}
	match ttype:
		"DIRECTION":
			var d := str(target.get("direction", target.get("value", ""))).strip_edges().to_upper()
			if d == "BACKWARD":
				d = "BACK"
			if not d in DIRECTIONS and d != "BACK":
				return {"ok": false, "code": "INVALID_DIRECTION", "detail": "Unknown direction '%s'." % str(d)}
		"HEX":
			var has_coord := (target.has("q") and target.has("r")) or (target.has("value") and target["value"] is Vector2i)
			if not has_coord:
				return {"ok": false, "code": "INVALID_TARGET", "detail": "HEX target requires q and r."}
		"FORMATION":
			var uid := str(target.get("unit_id", target.get("value", ""))).strip_edges()
			if uid.is_empty():
				return {"ok": false, "code": "INVALID_TARGET", "detail": "FORMATION target requires a unit_id."}
		"ZONE":
			var z := str(target.get("zone", target.get("value", ""))).strip_edges().to_upper()
			if not z in ZONES:
				return {"ok": false, "code": "INVALID_TARGET", "detail": "Unknown zone '%s'." % str(z)}
		"OBJECTIVE":
			pass
	if action == "ATTACK" and ttype != "FORMATION":
		return {"ok": false, "code": "INVALID_TARGET", "detail": "ATTACK requires a FORMATION (enemy unit) target."}
	return {"ok": true, "code": "", "detail": ""}


## Per-turn Action Catalog: what can actually be expressed right now.
## Built from the live observation (roster composition), not from statics.
static func build_catalog(obs: Dictionary) -> Array:
	var friendlies: Array = obs.get("friendly_units", [])
	var classes := {}
	var formations := {}
	var ready_count := 0
	for u_val in friendlies:
		if not u_val is Dictionary:
			continue
		var u: Dictionary = u_val
		classes[str(u.get("class", "")).to_upper()] = true
		formations[str(u.get("formation", "FIELD")).to_upper()] = true
		if str(u.get("status", "")) == "ready":
			ready_count += 1
	var has_scout := classes.has("SCOUT")
	var has_cav := classes.has("CAVALRY")
	var enemies: Array = obs.get("known_enemy_units", [])
	var has_visible := false
	for e_val in enemies:
		if e_val is Dictionary and str((e_val as Dictionary).get("contact_state", "")) == "current_visible":
			has_visible = true
	var formation_ids: Array = formations.keys()
	formation_ids.sort()
	var out: Array = []
	for action in ACTIONS:
		var row := {
			"action_family": action,
			"allowed_scopes": _scopes_for(action, classes, formation_ids),
			"allowed_targets": _targets_for(action, has_visible),
			"movement_policies": POLICIES.duplicate(),
			"stances": STANCES.duplicate(),
			"stance_note": STANCE_DEFERRED_NOTE,
			"executable": action in EXECUTABLE and ready_count > 0 and _gated(action, has_scout, has_cav, has_visible),
			"note": _note_for(action, has_scout, has_cav, has_visible),
		}
		out.append(row)
	return out


static func _scopes_for(action: String, classes: Dictionary, formation_ids: Array) -> Array:
	var scopes: Array = ["ALL_FRIENDLY", "ALL_COMBAT", "UNITS", "SELECTED"]
	for c in KNOWN_CLASSES:
		if classes.has(c):
			scopes.append("CLASS(%s)" % c)
	for f in formation_ids:
		scopes.append("FORMATION(%s)" % str(f))
	if action == "RECON":
		var filtered: Array = []
		for s in scopes:
			if s == "ALL_FRIENDLY" or s == "ALL_COMBAT" or s.begins_with("CLASS(SCOUT)") or s.begins_with("CLASS(CAVALRY)") or s in ["UNITS", "SELECTED"]:
				filtered.append(s)
		return filtered
	return scopes


static func _targets_for(action: String, has_visible: bool) -> Array:
	match action:
		"ADVANCE", "RECON", "PRESSURE":
			return ["FORWARD", "BACKWARD", "LEFT", "RIGHT", "NORTH", "SOUTH", "EAST", "WEST"]
		"FLANK":
			var f := ["FORWARD", "BACKWARD", "LEFT", "RIGHT", "NORTH", "SOUTH", "EAST", "WEST"]
			if has_visible:
				f.append("FORMATION(enemy_unit_id)")
			return f
		"ATTACK":
			return ["FORMATION(enemy_unit_id)"] if has_visible else []
		"PURSUE":
			return ["FORMATION(enemy_unit_id)"] if has_visible else ["OBJECTIVE"]
		"WITHDRAW":
			return ["ZONE(HQ)", "HEX(q,r)"]
		"REPOSITION", "CONCENTRATE":
			return ["ZONE(CENTER)", "ZONE(HQ)", "HEX(q,r)", "FORMATION(own_unit_id)"]
		"HOLD", "RESERVE", "SPREAD":
			return []
	return []


static func _gated(action: String, has_scout: bool, has_cav: bool, has_visible: bool) -> bool:
	match action:
		"RECON":
			return has_scout or has_cav
		"FLANK":
			return has_cav
		"ATTACK", "PURSUE":
			return has_visible
	return true


static func _note_for(action: String, has_scout: bool, has_cav: bool, has_visible: bool) -> String:
	match action:
		"PRESSURE":
			return "Rationalized as ADVANCE with ASSERTIVE stance (forward presence; no separate mechanic)."
		"PURSUE":
			return "REPOSITION toward a currently-visible enemy formation; rejects honestly when no contact is visible." if has_visible else "No visible contact: PURSUE unavailable until a contact is observed."
		"CONCENTRATE":
			return "REPOSITION toward ZONE(CENTER) (mass on the middle)."
		"RESERVE":
			return "HOLD in place (reserve posture)."
		"SPREAD":
			return "DEFERRED: schema-preserved, no neutral-board dispersion mechanic in Step 1."
		"RECON":
			return "Restricted to SCOUT/CAVALRY." if (has_scout or has_cav) else "No recon-capable formation available."
		"FLANK":
			return "Restricted to maneuver classes." if has_cav else "No cavalry available for FLANK."
		"ATTACK":
			return "Requires a currently-visible enemy FORMATION target." if has_visible else "No visible target: ATTACK unavailable."
	return ""
