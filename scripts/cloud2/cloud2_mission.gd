class_name Cloud2Mission
extends RefCounted

## CLOUD-GENERAL MISSION HIERARCHY — force-mission schema + trigger vocabulary.
##
## A mission is a Godot-owned assignment from the Cloud General to a dynamic
## force group: WHAT this force tries to accomplish, WHERE, under WHICH
## engagement policy — never per-turn unit orders. MissionControllers execute
## missions; the General assigns and re-plans them.
##
## Pure data + validation. No network, no game truth, no mutation.

## EXECUTE (liberation V1): the generic unfiltered task. No legacy filter
## branches on it (see mission_controller/compiler), so behavior comes only
## from the rich intent fields + live legality. Legacy tasks keep legacy
## behavior for compatibility; their labels remain as telemetry/UI tags.
const TASKS := ["HOLD", "ADVANCE", "FIX", "ATTACK", "FLANK", "RECON", "RESERVE", "WITHDRAW", "EXECUTE"]

const AREAS := ["NORTH", "CENTER", "SOUTH", "WEST", "EAST", "ANY"]

const STATUSES := ["ASSIGNED", "ACTIVE", "PROGRESSING", "BLOCKED", "SUCCESS", "FAILED", "ABORTED", "WAITING_TRIGGER"]

const TERMINAL_STATUSES := ["SUCCESS", "FAILED", "ABORTED"]

const ENGAGEMENT_POLICIES := ["ATTACK_IF_ADVANTAGEOUS", "HOLD_FIRE", "ATTACK_DESIGNATED_ONLY", "PURSUE_WEAKENED"]

const OBJECTIVE_KINDS := ["NONE", "FORMATION_CLASS", "ENEMY_FORMATION", "REGION", "ZONE"]

## Finite trigger vocabulary. The General names triggers; Godot evaluates
## them deterministically against authoritative state. Never executable text.
const TRIGGERS := [
	"MISSION_BLOCKED",
	"MISSION_COMPLETE",
	"FORCE_STRENGTH_BELOW",
	"ENEMY_COMMITMENT_HIGH",
	"ENEMY_CLASS_DETECTED",
	"HQ_THREATENED",
	"LOCAL_ADVANTAGE_HIGH",
	"OBJECTIVE_EXPOSED",
	"TURNS_ELAPSED",
	"TARGET_DESTROYED",
	"REGION_OCCUPIED",
	"REGION_REACHED",
	"ALWAYS",
	"NEVER",
]

const CONTINGENCY_ACTIONS := ["ACTIVATE_MISSION", "ABORT_MISSION", "REQUEST_REVIEW"]

const MAX_MISSIONS := 8
const MAX_TEXT := 280


static func default_objective() -> Dictionary:
	return {"kind": "NONE"}


static func default_engagement() -> Dictionary:
	return {"policy": "ATTACK_IF_ADVANTAGEOUS"}


static func default_constraints() -> Dictionary:
	return {"preserve_force": false, "max_overextension": 3, "hold_until_trigger": false}


static func default_mission(mission_id: String, task: String = "HOLD") -> Dictionary:
	return {
		"mission_id": mission_id.strip_edges().to_upper(),
		"task": task.strip_edges().to_upper() if task.strip_edges().to_upper() in TASKS else "HOLD",
		"area": "ANY",
		"assigned_units": [],
		"status": "ASSIGNED",
		"status_reason": "",
		"status_turn": 0,
		"objective": default_objective(),
		"engagement": default_engagement(),
		"constraints": default_constraints(),
		"success_conditions": [],
		"abort_conditions": [],
		"report_conditions": [],
		"activated_turn": 0,
		"progress_turn": 0,
		"intent": "",
		"priority": "",
		"desired_effects": [],
		"target_preferences": {"units": [], "classes": [], "areas": []},
		"force_roles": {},
		"coordination_intent": "",
		"constraints_nl": [],
		"support": [],
		"telemetry_tag": "",
	}


static func _clip(v: Variant) -> String:
	var s := str(v).strip_edges()
	if s.length() > MAX_TEXT:
		return s.left(MAX_TEXT)
	return s


## Validate + canonicalize one mission dict from untrusted (model) input.
## Unknown units are NOT rejected here — the manager reconciles assignments
## against live Godot state (Godot truth wins, dead/unknown ids drop).
static func validate_mission(m_val: Variant) -> Dictionary:
	if not m_val is Dictionary:
		return {"ok": false, "code": "MISSION_SHAPE", "detail": "Mission must be an object.", "mission": {}}
	var m: Dictionary = m_val
	var mid := str(m.get("mission_id", "")).strip_edges().to_upper()
	if mid.is_empty():
		return {"ok": false, "code": "MISSION_ID", "detail": "Mission needs a mission_id.", "mission": {}}
	var task := str(m.get("task", "")).strip_edges().to_upper()
	if not task in TASKS:
		return {"ok": false, "code": "MISSION_TASK", "detail": "Unknown task '%s'." % str(m.get("task", "")), "mission": {}}
	var area := str(m.get("area", "ANY")).strip_edges().to_upper()
	if not area in AREAS:
		return {"ok": false, "code": "MISSION_AREA", "detail": "Unknown area '%s'." % str(m.get("area", "")), "mission": {}}
	var units: Array = []
	if m.get("assigned_units") is Array:
		for u in (m.get("assigned_units") as Array):
			var uid := str(u).strip_edges().to_upper()
			if not uid.is_empty() and not uid in units:
				units.append(uid)
	units.sort()
	var obj := _validate_objective(m.get("objective", {}), area)
	if not bool(obj.get("ok", false)):
		return {"ok": false, "code": str(obj.get("code", "MISSION_OBJECTIVE")), "detail": str(obj.get("detail", "")), "mission": {}}
	var eng := _validate_engagement(m.get("engagement", {}))
	if not bool(eng.get("ok", false)):
		return {"ok": false, "code": str(eng.get("code", "MISSION_ENGAGEMENT")), "detail": str(eng.get("detail", "")), "mission": {}}
	var con := _validate_constraints(m.get("constraints", {}))
	var out := default_mission(mid, task)
	out["area"] = area
	out["assigned_units"] = units
	out["objective"] = obj.get("objective", default_objective())
	out["engagement"] = eng.get("engagement", default_engagement())
	out["constraints"] = con
	for key in ["success_conditions", "abort_conditions", "report_conditions"]:
		var conds := _validate_conditions(m.get(key, []))
		if not bool(conds.get("ok", false)):
			return {"ok": false, "code": str(conds.get("code", "MISSION_CONDITION")), "detail": str(conds.get("detail", "")), "mission": {}}
		out[key] = conds.get("conditions", [])
	var want_status := str(m.get("status", "ASSIGNED")).strip_edges().to_upper()
	if want_status == "WAITING_TRIGGER":
		out["status"] = "WAITING_TRIGGER"
		out["constraints"]["hold_until_trigger"] = true
	elif want_status in STATUSES and not want_status in TERMINAL_STATUSES and want_status != "BLOCKED":
		out["status"] = want_status
	var rich := _validate_rich(m)
	for rk in rich.keys():
		out[rk] = rich[rk]
	return {"ok": true, "code": "", "detail": "", "mission": out}


## Liberation V1 rich intent: optional NL semantics, bounded. Never rejects:
## unknown/overlong content is clipped, never fatal (a mission with no
## useful legacy label must still be executable).
static func _validate_rich(m: Dictionary) -> Dictionary:
	var effects: Array = []
	for e in (m.get("desired_effects", []) if m.get("desired_effects") is Array else []):
		var s := str(e).strip_edges().left(160)
		if not s.is_empty() and not s in effects:
			effects.append(s)
		if effects.size() >= 4:
			break
	var prefs: Dictionary = m.get("target_preferences", {}) as Dictionary if m.get("target_preferences") is Dictionary else {}
	var pref_units: Array = []
	for u in (prefs.get("units", []) if prefs.get("units") is Array else []):
		var uid := str(u).strip_edges().to_upper().left(24)
		if not uid.is_empty() and not uid in pref_units:
			pref_units.append(uid)
		if pref_units.size() >= 4:
			break
	var pref_classes: Array = []
	for c in (prefs.get("classes", []) if prefs.get("classes") is Array else []):
		var cc := str(c).strip_edges().to_upper().left(16)
		if not cc.is_empty() and not cc in pref_classes:
			pref_classes.append(cc)
		if pref_classes.size() >= 4:
			break
	var pref_areas: Array = []
	for a in (prefs.get("areas", []) if prefs.get("areas") is Array else []):
		var aa := str(a).strip_edges().to_upper()
		if aa in AREAS and not aa in pref_areas:
			pref_areas.append(aa)
		if pref_areas.size() >= 3:
			break
	var roles := {}
	if m.get("force_roles") is Dictionary:
		for k in ((m.get("force_roles", {}) as Dictionary) as Dictionary).keys():
			var rs := str((m.get("force_roles", {}) as Dictionary)[k]).strip_edges().left(160)
			if not rs.is_empty():
				roles[str(k).strip_edges().to_upper().left(24)] = rs
			if roles.size() >= 8:
				break
	var clim: Array = []
	for l in (m.get("constraints_nl", []) if m.get("constraints_nl") is Array else []):
		var ls := str(l).strip_edges().left(160)
		if not ls.is_empty() and not ls in clim:
			clim.append(ls)
		if clim.size() >= 4:
			break
	var sup: Array = []
	for s_val in (m.get("support", []) if m.get("support") is Array else []):
		if not s_val is Dictionary:
			continue
		var sd: Dictionary = s_val
		var sfrom := str(sd.get("from", "")).strip_edges().to_upper().left(24)
		var sto := str(sd.get("to", "")).strip_edges().to_upper().left(24)
		var skind := str(sd.get("kind", "")).strip_edges().left(80)
		if sfrom.is_empty() or sto.is_empty():
			continue
		sup.append({"from": sfrom, "to": sto, "kind": skind})
		if sup.size() >= 4:
			break
	return {
		"intent": str(m.get("intent", "")).strip_edges().left(300),
		"priority": str(m.get("priority", "")).strip_edges().left(160),
		"desired_effects": effects,
		"target_preferences": {"units": pref_units, "classes": pref_classes, "areas": pref_areas},
		"force_roles": roles,
		"coordination_intent": str(m.get("coordination_intent", "")).strip_edges().left(300),
		"constraints_nl": clim,
		"support": sup,
		"telemetry_tag": str(m.get("telemetry_tag", "")).strip_edges().to_upper().left(24),
	}


static func _validate_objective(o_val: Variant, area: String = "ANY") -> Dictionary:
	if o_val == null or (o_val is Dictionary and (o_val as Dictionary).is_empty()):
		return {"ok": true, "objective": default_objective()}
	if not o_val is Dictionary:
		return {"ok": false, "code": "MISSION_OBJECTIVE", "detail": "Objective must be an object."}
	var o: Dictionary = o_val
	var kind := str(o.get("kind", "NONE")).strip_edges().to_upper()
	if not kind in OBJECTIVE_KINDS:
		return {"ok": false, "code": "MISSION_OBJECTIVE", "detail": "Unknown objective kind '%s'." % str(o.get("kind", ""))}
	var out := {"kind": kind}
	match kind:
		"FORMATION_CLASS":
			out["class"] = str(o.get("class", "")).strip_edges().to_upper()
		"ENEMY_FORMATION":
			out["unit_id"] = str(o.get("unit_id", "")).strip_edges().to_upper()
		"REGION":
			# Canonicalization (not fabrication): an empty REGION defaults
			# to the mission's own area — the General's stated area. An
			# explicitly UNKNOWN region name still rejects.
			var reg := str(o.get("region", "")).strip_edges().to_upper()
			if reg.is_empty():
				reg = area.strip_edges().to_upper()
				if reg.is_empty() or reg == "ANY":
					reg = "CENTER"
			if not reg in AREAS:
				return {"ok": false, "code": "MISSION_OBJECTIVE", "detail": "Unknown objective region '%s'." % str(o.get("region", ""))}
			out["region"] = reg
		"ZONE":
			var zone := str(o.get("zone", "")).strip_edges().to_upper()
			if not zone in ["CENTER", "HQ"]:
				return {"ok": false, "code": "MISSION_OBJECTIVE", "detail": "Unknown objective zone '%s'." % str(o.get("zone", ""))}
			out["zone"] = zone
	return {"ok": true, "objective": out}


static func _validate_engagement(e_val: Variant) -> Dictionary:
	if e_val == null or (e_val is Dictionary and (e_val as Dictionary).is_empty()):
		return {"ok": true, "engagement": default_engagement()}
	if not e_val is Dictionary:
		return {"ok": false, "code": "MISSION_ENGAGEMENT", "detail": "Engagement must be an object."}
	var policy := str((e_val as Dictionary).get("policy", "ATTACK_IF_ADVANTAGEOUS")).strip_edges().to_upper()
	if not policy in ENGAGEMENT_POLICIES:
		return {"ok": false, "code": "MISSION_ENGAGEMENT", "detail": "Unknown engagement policy '%s'." % str(policy)}
	return {"ok": true, "engagement": {"policy": policy}}


static func _validate_constraints(c_val: Variant) -> Dictionary:
	var out := default_constraints()
	if c_val is Dictionary:
		var c: Dictionary = c_val
		out["preserve_force"] = bool(c.get("preserve_force", false))
		out["max_overextension"] = clampi(int(c.get("max_overextension", 3)), 0, 9)
		out["hold_until_trigger"] = bool(c.get("hold_until_trigger", false))
	return out


static func _validate_conditions(c_val: Variant) -> Dictionary:
	if c_val == null or (c_val is Array and (c_val as Array).is_empty()):
		return {"ok": true, "conditions": []}
	if not c_val is Array:
		return {"ok": false, "code": "MISSION_CONDITION", "detail": "Conditions must be an array."}
	var out: Array = []
	for e_val in (c_val as Array):
		if e_val is String and str(e_val).strip_edges().to_upper() in TRIGGERS:
			out.append({"trigger": str(e_val).strip_edges().to_upper(), "params": {}})
			continue
		if not e_val is Dictionary:
			return {"ok": false, "code": "MISSION_CONDITION", "detail": "Condition must be a trigger name or {trigger, params}."}
		var e: Dictionary = e_val
		var name := str(e.get("trigger", "")).strip_edges().to_upper()
		if not name in TRIGGERS:
			return {"ok": false, "code": "MISSION_CONDITION", "detail": "Unknown trigger '%s'." % str(e.get("trigger", ""))}
		var params: Dictionary = {}
		if e.get("params") is Dictionary:
			params = (e.get("params") as Dictionary).duplicate(true)
		out.append({"trigger": name, "params": params})
	return {"ok": true, "conditions": out}


## Validate one contingency definition from untrusted input.
static func validate_contingency(c_val: Variant) -> Dictionary:
	if not c_val is Dictionary:
		return {"ok": false, "code": "CONTINGENCY_SHAPE", "detail": "Contingency must be an object.", "contingency": {}}
	var c: Dictionary = c_val
	var cid := str(c.get("contingency_id", "")).strip_edges().to_upper()
	if cid.is_empty():
		return {"ok": false, "code": "CONTINGENCY_ID", "detail": "Contingency needs a contingency_id.", "contingency": {}}
	var trig := str(c.get("trigger", "")).strip_edges().to_upper()
	if not trig in TRIGGERS or trig in ["ALWAYS", "NEVER"]:
		return {"ok": false, "code": "CONTINGENCY_TRIGGER", "detail": "Contingency needs an evaluable trigger.", "contingency": {}}
	var action := str(c.get("action", "")).strip_edges().to_upper()
	if not action in CONTINGENCY_ACTIONS:
		return {"ok": false, "code": "CONTINGENCY_ACTION", "detail": "Unknown contingency action '%s'." % str(c.get("action", "")), "contingency": {}}
	var params: Dictionary = {}
	if c.get("params") is Dictionary:
		params = (c.get("params") as Dictionary).duplicate(true)
	return {"ok": true, "code": "", "detail": "", "contingency": {
		"contingency_id": cid,
		"trigger": trig,
		"params": params,
		"action": action,
		"mission_id": str(c.get("mission_id", "")).strip_edges().to_upper(),
		"note": _clip(c.get("note", "")),
		"consumed": false,
	}}


static func is_terminal(status: String) -> bool:
	return status.strip_edges().to_upper() in TERMINAL_STATUSES


static func describe(m: Dictionary) -> String:
	return "%s %s %s [%s] units=%d (%s)" % [
		str(m.get("mission_id", "?")), str(m.get("task", "?")), str(m.get("area", "?")),
		str(m.get("status", "?")), (m.get("assigned_units", []) as Array).size(),
		str(m.get("status_reason", "-")),
	]
