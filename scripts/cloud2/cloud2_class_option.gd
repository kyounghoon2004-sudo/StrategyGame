class_name Cloud2ClassOption
extends RefCounted

## CLOUD-GENERAL PRE-DETERMINISTIC CLASS OPTIONS — schema + matrix.
##
## Every ready formation exposes exactly SIX stable semantic option slots for
## its class. Options are behavior TEMPLATES (which existing mechanic to use
## and toward what), never new abilities: PROTECT_ARCHER means "use existing
## legal movement to screen archers", not a guard buff or aura.
##
## Pipeline (see Cloud2ClassOptionSolver): generate 6 -> mask the
## inapplicable (masks stay present, never removed) -> deterministic
## utility score survivors -> seeded pick -> resolve legal target or
## destination -> Table validate -> compiler dry-run -> order.
## A future reweighting model may adjust the scores; it cannot invent a
## seventh slot or bypass the compiler. This file is dependency-free pure
## data + math (safe for later Python reproduction).

const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")

const SCHEMA_VERSION := "CLASS_OPTION_V1"
const SLOT_COUNT := 6

const CLASSES := ["INFANTRY", "ARCHER", "SPEARMAN", "CAVALRY", "SCOUT", "HQ"]

## Canonical slot order per class. Slot indices are STABLE (a reweighting
## model addresses slots, so order changes are schema changes).
const MATRIX := {
	"INFANTRY": ["ATTACK_CONTACT", "ADVANCE_LINE", "HOLD_LINE", "CLOSE_GAP_SUPPORT", "PRESS_OBJECTIVE", "WITHDRAW_LINE"],
	"ARCHER": ["FIRE_PRIORITY_TARGET", "HOLD_FIRELINE", "REPOSITION_FOR_RANGE", "SUPPORT_ASSIGNED_GROUP", "KITE_FROM_THREAT", "WITHDRAW_TO_SCREEN"],
	"SPEARMAN": ["ATTACK_CAVALRY", "HOLD_ANTI_CAV_SCREEN", "ADVANCE_WITH_LINE", "PROTECT_ARCHER", "PROTECT_HQ", "FALLBACK_SCREEN"],
	"CAVALRY": ["CHARGE_PRIORITY_TARGET", "FLANK_LEFT", "FLANK_RIGHT", "EXPLOIT_REAR_OR_RANGED", "SCREEN_COUNTERFLANK", "DISENGAGE_TO_RESERVE"],
	"SCOUT": ["RECON_FORWARD", "RECON_LEFT", "RECON_RIGHT", "SHADOW_PRIORITY_ENEMY", "SCREEN_EDGE", "EVADE_RETURN"],
	"HQ": ["HOLD_REAR", "FOLLOW_MAIN_EFFORT", "RELOCATE_LEFT_SAFE", "RELOCATE_RIGHT_SAFE", "RELOCATE_CENTER_SAFE", "WITHDRAW_FROM_THREAT"],
}

## Resolution metadata per option: scoring kind (existing utility family),
## resolved command action, and target form. kind drives scoring; action +
## target drive the OperationalCommand.
const META := {
	"ATTACK_CONTACT": {"kind": "ATTACK", "action": "ATTACK"},
	"ADVANCE_LINE": {"kind": "ADVANCE", "action": "ADVANCE", "direction": "FORWARD"},
	"HOLD_LINE": {"kind": "HOLD", "action": "HOLD"},
	"CLOSE_GAP_SUPPORT": {"kind": "ADVANCE", "action": "ADVANCE", "direction": "FORWARD"},
	"PRESS_OBJECTIVE": {"kind": "ADVANCE", "action": "ADVANCE", "direction": "FORWARD"},
	"WITHDRAW_LINE": {"kind": "WITHDRAW", "action": "WITHDRAW", "zone": "HQ"},
	"FIRE_PRIORITY_TARGET": {"kind": "ATTACK", "action": "ATTACK"},
	"HOLD_FIRELINE": {"kind": "HOLD", "action": "HOLD"},
	"REPOSITION_FOR_RANGE": {"kind": "ADVANCE", "action": "ADVANCE", "direction": "FORWARD"},
	"SUPPORT_ASSIGNED_GROUP": {"kind": "ADVANCE", "action": "ADVANCE", "direction": "FORWARD"},
	"KITE_FROM_THREAT": {"kind": "WITHDRAW", "action": "WITHDRAW", "zone": "HQ"},
	"WITHDRAW_TO_SCREEN": {"kind": "WITHDRAW", "action": "WITHDRAW", "zone": "HQ"},
	"ATTACK_CAVALRY": {"kind": "ATTACK", "action": "ATTACK"},
	"HOLD_ANTI_CAV_SCREEN": {"kind": "HOLD", "action": "HOLD"},
	"ADVANCE_WITH_LINE": {"kind": "ADVANCE", "action": "ADVANCE", "direction": "FORWARD"},
	"PROTECT_ARCHER": {"kind": "ADVANCE", "action": "ADVANCE", "direction": "FORWARD"},
	"PROTECT_HQ": {"kind": "ADVANCE", "action": "ADVANCE", "direction": "FORWARD"},
	"FALLBACK_SCREEN": {"kind": "WITHDRAW", "action": "WITHDRAW", "zone": "HQ"},
	"CHARGE_PRIORITY_TARGET": {"kind": "ATTACK", "action": "ATTACK"},
	"FLANK_LEFT": {"kind": "ADVANCE", "action": "FLANK", "direction": "LEFT"},
	"FLANK_RIGHT": {"kind": "ADVANCE", "action": "FLANK", "direction": "RIGHT"},
	"EXPLOIT_REAR_OR_RANGED": {"kind": "ATTACK", "action": "ATTACK"},
	"SCREEN_COUNTERFLANK": {"kind": "ADVANCE", "action": "ADVANCE", "direction": "FORWARD"},
	"DISENGAGE_TO_RESERVE": {"kind": "WITHDRAW", "action": "WITHDRAW", "zone": "HQ"},
	"RECON_FORWARD": {"kind": "ADVANCE", "action": "RECON", "direction": "FORWARD"},
	"RECON_LEFT": {"kind": "ADVANCE", "action": "RECON", "direction": "LEFT"},
	"RECON_RIGHT": {"kind": "ADVANCE", "action": "RECON", "direction": "RIGHT"},
	"SHADOW_PRIORITY_ENEMY": {"kind": "ADVANCE", "action": "ADVANCE", "direction": "FORWARD"},
	"SCREEN_EDGE": {"kind": "HOLD", "action": "HOLD"},
	"EVADE_RETURN": {"kind": "WITHDRAW", "action": "WITHDRAW", "zone": "HQ"},
	"HOLD_REAR": {"kind": "HOLD", "action": "HOLD"},
	"FOLLOW_MAIN_EFFORT": {"kind": "ADVANCE", "action": "ADVANCE", "direction": "FORWARD"},
	"RELOCATE_LEFT_SAFE": {"kind": "WITHDRAW", "action": "ADVANCE", "direction": "LEFT"},
	"RELOCATE_RIGHT_SAFE": {"kind": "WITHDRAW", "action": "ADVANCE", "direction": "RIGHT"},
	"RELOCATE_CENTER_SAFE": {"kind": "WITHDRAW", "action": "REPOSITION", "zone": "CENTER"},
	"WITHDRAW_FROM_THREAT": {"kind": "WITHDRAW", "action": "ADVANCE", "direction": "BACKWARD"},
}

## Stable mask reasons. A masked option stays in its slot with masked=true.
const MASK_REASONS := ["NO_VALID_TARGET", "NO_LEGAL_MOVE", "NO_SAFE_DESTINATION",
	"NO_VISIBLE_CONTACT", "MISSION_CONFLICT", "WAITING_TRIGGER",
	"OBJECTIVE_UNAVAILABLE", "COMPILER_REJECTED", "ALREADY_SATISFIED"]

## Mission compatibility: scoring kinds each task may use. Options whose
## kind is absent mask as MISSION_CONFLICT. WITHDRAW is threat-gated by
## scoring, so HOLD/RESERVE forces may use it as safety without camping it.
const TASK_ALLOWED_KINDS := {
	"HOLD": ["HOLD", "ATTACK", "WITHDRAW"],
	"RESERVE": ["HOLD", "ATTACK", "WITHDRAW"],
	"ADVANCE": ["ATTACK", "ADVANCE", "HOLD"],
	"ATTACK": ["ATTACK", "ADVANCE", "HOLD"],
	"FLANK": ["ATTACK", "ADVANCE", "HOLD"],
	"FIX": ["ATTACK", "ADVANCE", "HOLD"],
	"RECON": ["ADVANCE", "ATTACK", "WITHDRAW", "HOLD"],
	"WITHDRAW": ["WITHDRAW", "HOLD"],
}

## Mission voice: small legible bonus for the task's signature kinds.
## Recorded as its own score term (mission_fit), never a mask.
const TASK_KIND_FIT := {
	"HOLD": {"HOLD": 8.0},
	"RESERVE": {"HOLD": 8.0},
	"ADVANCE": {"ADVANCE": 8.0},
	"ATTACK": {"ATTACK": 8.0},
	"FLANK": {"ADVANCE": 8.0, "ATTACK": 4.0},
	"FIX": {"ATTACK": 4.0, "ADVANCE": 4.0},
	"RECON": {"ADVANCE": 6.0},
	"WITHDRAW": {"WITHDRAW": 8.0},
}

## Options whose resolution needs a visible enemy of a designated class set
## (checked against legal-attack target classes).
const CLASS_FILTER := {
	"ATTACK_CAVALRY": ["CAVALRY"],
	"EXPLOIT_REAR_OR_RANGED": ["ARCHER", "SCOUT"],
}


static func slots_for_class(unit_class: String) -> Array:
	var key := unit_class.strip_edges().to_upper()
	if MATRIX.has(key):
		return (MATRIX[key] as Array).duplicate()
	return (MATRIX["INFANTRY"] as Array).duplicate()


static func meta_for(option_id: String) -> Dictionary:
	return (META.get(option_id, {"kind": "HOLD", "action": "HOLD"}) as Dictionary).duplicate()


static func kind_allowed(task: String, kind: String) -> bool:
	var kinds: Array = TASK_ALLOWED_KINDS.get(task.strip_edges().to_upper(), ["HOLD"])
	return kinds.has(kind.strip_edges().to_upper())


static func mission_fit(task: String, kind: String) -> float:
	var row: Dictionary = TASK_KIND_FIT.get(task.strip_edges().to_upper(), {})
	return float(row.get(kind.strip_edges().to_upper(), 0.0))


## Per-unit deterministic tie seed (mission seed + unit: same state picks the
## same option every run, independent of sibling units).
static func tie_seed(seed_base: int, snapshot_id: String, mission_id: String, unit_id: String, turn: int) -> int:
	var h := hash("%d|%s|%s|%s|%d" % [seed_base, snapshot_id, mission_id, unit_id, turn])
	return int(abs(h)) % 2147483647


## Progress point per option: used ONLY for progress scoring hints (which
## reachable hexes gain ground toward this option's intent). The compiler
## always chooses executed hexes.
static func progress_point(option_id: String, unit: Dictionary, mission: Dictionary, obs: Dictionary, ctx: Dictionary) -> Vector2i:
	var origin := Vector2i(int(unit.get("q", 0)), int(unit.get("r", 0)))
	match option_id:
		"CLOSE_GAP_SUPPORT", "SHADOW_PRIORITY_ENEMY":
			var foe := _nearest_visible_enemy(obs, origin)
			return foe if foe.x != 9999 else mission_point(obs, mission, ctx)
		"PRESS_OBJECTIVE":
			return objective_point(obs, mission, ctx)
		"SUPPORT_ASSIGNED_GROUP":
			return _mates_centroid(unit, mission, obs)
		"PROTECT_ARCHER":
			var arc := _nearest_friendly_class(obs, origin, "ARCHER")
			return arc if arc.x != 9999 else mission_point(obs, mission, ctx)
		"PROTECT_HQ":
			var hq := _red_hq_pos(obs)
			return hq if hq.x != 9999 else mission_point(obs, mission, ctx)
		"SCREEN_COUNTERFLANK":
			var cav := _nearest_visible_enemy_class(obs, origin, "CAVALRY")
			return cav if cav.x != 9999 else mission_point(obs, mission, ctx)
		"FOLLOW_MAIN_EFFORT":
			var me := str(ctx.get("main_effort", "")).strip_edges().to_upper()
			if me.is_empty():
				me = str(mission.get("area", "CENTER"))
			return bounds_point(ctx, me)
	return mission_point(obs, mission, ctx)


## Mission target point (shared default): objective geometry, else nearest
## visible enemy, else the mission area point. Compiler chooses hexes.
static func mission_point(obs: Dictionary, mission: Dictionary, ctx: Dictionary) -> Vector2i:
	var obj: Dictionary = mission.get("objective", {})
	match str(obj.get("kind", "NONE")):
		"ENEMY_FORMATION":
			var want := str(obj.get("unit_id", ""))
			for e_val in (obs.get("known_enemy_units", []) as Array):
				if e_val is Dictionary and str((e_val as Dictionary).get("unit_id", "")) == want:
					return Vector2i(int((e_val as Dictionary).get("q", 0)), int((e_val as Dictionary).get("r", 0)))
		"ZONE":
			if str(obj.get("zone", "")) == "HQ":
				var hq := _red_hq_pos(obs)
				if hq.x != 9999:
					return hq
			return bounds_point(ctx, "CENTER")
		"REGION":
			return bounds_point(ctx, str(obj.get("region", "CENTER")))
	var foes: Array = []
	for e2_val in (obs.get("known_enemy_units", []) as Array):
		if e2_val is Dictionary and str((e2_val as Dictionary).get("contact_state", "")) == "current_visible":
			foes.append(e2_val)
	if foes.is_empty():
		return bounds_point(ctx, str(mission.get("area", "CENTER")))
	var friends: Array = obs.get("friendly_units", [])
	var fq := 0
	var fr := 0
	if not friends.is_empty():
		var f0: Dictionary = friends[0]
		fq = int(f0.get("q", 0))
		fr = int(f0.get("r", 0))
	var best := Vector2i(fq, fr)
	var best_d := 1 << 30
	for f_val in foes:
		var f2: Dictionary = f_val
		var d := HexUtilsCls.hex_distance_axial(Vector2i(fq, fr), Vector2i(int(f2.get("q", 0)), int(f2.get("r", 0))))
		if d < best_d:
			best_d = d
			best = Vector2i(int(f2.get("q", 0)), int(f2.get("r", 0)))
	return best


## Objective geometry point; (9999, 0) when the mission names no resolvable
## objective (caller masks OBJECTIVE_UNAVAILABLE).
static func objective_point(obs: Dictionary, mission: Dictionary, ctx: Dictionary) -> Vector2i:
	var obj: Dictionary = mission.get("objective", {})
	match str(obj.get("kind", "NONE")):
		"ENEMY_FORMATION":
			var want := str(obj.get("unit_id", ""))
			for e_val in (obs.get("known_enemy_units", []) as Array):
				if e_val is Dictionary and str((e_val as Dictionary).get("unit_id", "")) == want:
					return Vector2i(int((e_val as Dictionary).get("q", 0)), int((e_val as Dictionary).get("r", 0)))
			return Vector2i(9999, 0)
		"ZONE":
			if str(obj.get("zone", "")) == "HQ":
				var hq := _red_hq_pos(obs)
				return hq if hq.x != 9999 else Vector2i(9999, 0)
			return bounds_point(ctx, "CENTER")
		"REGION":
			return bounds_point(ctx, str(obj.get("region", "CENTER")))
	return Vector2i(9999, 0)


static func bounds_point(ctx: Dictionary, area: String) -> Vector2i:
	var b: Dictionary = ctx.get("bounds", {})
	if b.is_empty():
		return Vector2i(0, 0)
	var q0 := int(b.get("q_min", -30))
	var q1 := int(b.get("q_max", -20))
	var r0 := int(b.get("r_min", -5))
	var r1 := int(b.get("r_max", 5))
	var qm := (q0 + q1) / 2
	var rm := (r0 + r1) / 2
	match area.strip_edges().to_upper():
		"NORTH":
			return Vector2i(qm, r0 + (r1 - r0) / 6)
		"SOUTH":
			return Vector2i(qm, r1 - (r1 - r0) / 6)
		"WEST":
			return Vector2i(q0 + (q1 - q0) / 4, rm)
		"EAST":
			return Vector2i(q1 - (q1 - q0) / 4, rm)
		"ANY":
			return Vector2i(qm, rm)
	return Vector2i(qm, rm)


static func _nearest_visible_enemy(obs: Dictionary, origin: Vector2i) -> Vector2i:
	var best := Vector2i(9999, 0)
	var best_d := 1 << 30
	for e_val in (obs.get("known_enemy_units", []) as Array):
		if not e_val is Dictionary or str((e_val as Dictionary).get("contact_state", "")) != "current_visible":
			continue
		var p := Vector2i(int((e_val as Dictionary).get("q", 0)), int((e_val as Dictionary).get("r", 0)))
		var d := HexUtilsCls.hex_distance_axial(origin, p)
		if d < best_d:
			best_d = d
			best = p
	return best


static func _nearest_visible_enemy_class(obs: Dictionary, origin: Vector2i, cls: String) -> Vector2i:
	var best := Vector2i(9999, 0)
	var best_d := 1 << 30
	for e_val in (obs.get("known_enemy_units", []) as Array):
		if not e_val is Dictionary or str((e_val as Dictionary).get("contact_state", "")) != "current_visible":
			continue
		if str((e_val as Dictionary).get("class", "")).strip_edges().to_upper() != cls:
			continue
		var p := Vector2i(int((e_val as Dictionary).get("q", 0)), int((e_val as Dictionary).get("r", 0)))
		var d := HexUtilsCls.hex_distance_axial(origin, p)
		if d < best_d:
			best_d = d
			best = p
	return best


static func _nearest_friendly_class(obs: Dictionary, origin: Vector2i, cls: String) -> Vector2i:
	var best := Vector2i(9999, 0)
	var best_d := 1 << 30
	for u_val in (obs.get("friendly_units", []) as Array):
		if not u_val is Dictionary:
			continue
		if str((u_val as Dictionary).get("class", "")).strip_edges().to_upper() != cls:
			continue
		var p := Vector2i(int((u_val as Dictionary).get("q", 0)), int((u_val as Dictionary).get("r", 0)))
		var d := HexUtilsCls.hex_distance_axial(origin, p)
		if d < best_d:
			best_d = d
			best = p
	return best


static func _red_hq_pos(obs: Dictionary) -> Vector2i:
	return _nearest_friendly_class(obs, Vector2i(0, 0), "HQ")


static func _mates_centroid(unit: Dictionary, mission: Dictionary, obs: Dictionary) -> Vector2i:
	var self_id := str(unit.get("unit_id", "")).strip_edges().to_upper()
	var ids := {}
	for u in (mission.get("assigned_units", []) as Array):
		ids[str(u).strip_edges().to_upper()] = true
	var n := 0
	var sq := 0
	var sr := 0
	for u_val in (obs.get("friendly_units", []) as Array):
		if not u_val is Dictionary:
			continue
		var uid := str((u_val as Dictionary).get("unit_id", "")).strip_edges().to_upper()
		if uid == self_id or not ids.has(uid):
			continue
		sq += int((u_val as Dictionary).get("q", 0))
		sr += int((u_val as Dictionary).get("r", 0))
		n += 1
	if n == 0:
		return Vector2i(int(unit.get("q", 0)), int(unit.get("r", 0)))
	return Vector2i(sq / n, sr / n)


## Schema check for gates/debuggers: every option carries the V1 identity +
## score block. Resolution fields fill on selection.
static func validate_option_schema(opt: Dictionary) -> Dictionary:
	for k in ["schema_version", "unit_id", "unit_class", "mission_id", "slot",
		"option_id", "masked", "mask_reason", "base_score", "mission_score",
		"state_score", "doctrine_score", "risk_score", "final_score",
		"resolved_target", "resolved_destination", "resolved_command"]:
		if not opt.has(k):
			return {"ok": false, "code": "OPTION_SCHEMA", "detail": "Option misses '%s'." % k}
	if str(opt.get("schema_version", "")) != SCHEMA_VERSION:
		return {"ok": false, "code": "OPTION_SCHEMA_VERSION", "detail": "Schema must be %s." % SCHEMA_VERSION}
	return {"ok": true, "code": "", "detail": ""}


## Track-A trace text for one acted unit: six slots, masks, terms, selection,
## resolution, compiler + execution results (execution filled by the caller).
static func render_unit_table(t: Dictionary) -> String:
	var lines: Array = []
	lines.append("UNIT %s (%s) MISSION %s [%s]" % [str(t.get("unit_id", "?")),
		str(t.get("unit_class", "?")), str(t.get("mission_id", "?")), SCHEMA_VERSION])
	for o_val in (t.get("options", []) as Array):
		if not o_val is Dictionary:
			continue
		var o: Dictionary = o_val
		if bool(o.get("masked", false)):
			lines.append("  [%d] %-22s MASKED %s" % [int(o.get("slot", -1)),
				str(o.get("option_id", "?")), str(o.get("mask_reason", "?"))])
		else:
			lines.append("  [%d] %-22s %6.1f base=%.1f mission=%.1f state=%.1f doctrine=%.1f risk=%.1f" % [
				int(o.get("slot", -1)), str(o.get("option_id", "?")), float(o.get("final_score", 0.0)),
				float(o.get("base_score", 0.0)), float(o.get("mission_score", 0.0)),
				float(o.get("state_score", 0.0)), float(o.get("doctrine_score", 0.0)),
				float(o.get("risk_score", 0.0))])
	lines.append("SELECTED: %s" % str(t.get("selected_id", "?")))
	if not str(t.get("resolved_target", "")).is_empty():
		lines.append("TARGET: %s" % str(t.get("resolved_target", "")))
	if not (t.get("resolved_destination", []) as Array).is_empty():
		lines.append("DEST: %s" % JSON.stringify(t.get("resolved_destination", [])))
	lines.append("COMMAND: %s" % JSON.stringify(t.get("resolved_command", {})))
	lines.append("COMPILER: %s" % str(t.get("compiler", "?")))
	if not str(t.get("execution", "")).is_empty():
		lines.append("EXECUTION: %s" % str(t.get("execution", "")))
	return "\n".join(lines)
