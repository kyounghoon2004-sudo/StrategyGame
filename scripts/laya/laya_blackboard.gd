class_name LayaBlackboard
extends RefCounted

## LIBERATION V1 — shared tactical blackboard (ephemeral, per mission group).
##
## Pure state container + serializer + invalidation. NO game truth, NO
## policy: commitments record EXECUTED legal actions as facts, open needs
## derive from the coordinator plan minus completions, staleness drops
## references to dead/missing units. The model reads the serialized block;
## Godot owns every byte of it.
##
## Lifecycle: created per mission group per RED phase -> coordinator sets
## the group plan -> each unit execution notes its commitment -> stale
## entries invalidated from fresh state -> discarded at phase end.

const MAX_TEXT := 140
const MAX_INTENT := 200
const MAX_FOCUS := 4
const MAX_NEEDS := 6
const MAX_RISKS := 6
const MAX_DONE := 8
const MAX_TRACE := 40

var mission_id := ""
var intent := ""
var group_units: Array = []
var focus_targets: Array = []
var commitments: Array = []
var open_needs: Array = []
var risks: Array = []
var completed_effects: Array = []
var invalidated: Array = []
var group_plan := {}
var trace: Array = []


static func create(mission: Dictionary, units: Array) -> LayaBlackboard:
	var bb := LayaBlackboard.new()
	bb.mission_id = str(mission.get("mission_id", ""))
	bb.intent = str(mission.get("intent", "")).strip_edges().left(MAX_INTENT)
	for u in units:
		var uid := str(u).strip_edges().to_upper()
		if not uid.is_empty() and not uid in bb.group_units:
			bb.group_units.append(uid)
	for t in ((mission.get("target_preferences", {}) as Dictionary).get("units", []) as Array):
		var tid := str(t).strip_edges().to_upper()
		if not tid.is_empty() and not tid in bb.focus_targets:
			bb.focus_targets.append(tid)
		if bb.focus_targets.size() >= MAX_FOCUS:
			break
	bb._trace("CREATE", "group=[%s] intent=%s" % [",".join(bb.group_units), bb.intent.left(80)])
	return bb


## Bind the coordinator's chosen group approach. assignments: {unit_id:
## {kind: ATTACK|MOVE|HOLD|..., target: str, note: str}}. Open needs are
## the assignment notes not yet completed.
func set_group_plan(plan: Dictionary) -> void:
	group_plan = (plan as Dictionary).duplicate(true)
	open_needs.clear()
	var assigns: Dictionary = group_plan.get("assignments", {}) as Dictionary if group_plan.get("assignments") is Dictionary else {}
	for uid in assigns.keys():
		var note := str((assigns[uid] as Dictionary).get("note", "")).strip_edges().left(MAX_TEXT)
		if note.is_empty():
			var akind := str((assigns[uid] as Dictionary).get("kind", ""))
			var atarget := str((assigns[uid] as Dictionary).get("target", ""))
			note = ("%s %s %s" % [str(uid), akind, atarget]).strip_edges()
		if not note.is_empty() and not note in open_needs:
			open_needs.append(note)
		if open_needs.size() >= MAX_NEEDS:
			break
	_trace("PLAN", str(group_plan.get("text", "")).left(120))


## Record one EXECUTED legal action as a commitment (factual effect text
## derived by the caller from the candidate + result).
func note_commitment(uid: String, cand: Dictionary, effect: String, step: int) -> void:
	var kind := str(cand.get("action_type", ""))
	var ref := ""
	if kind == "ATTACK":
		ref = str(cand.get("target_id", ""))
	elif kind == "MOVE":
		var d: Array = cand.get("destination", [])
		if d.size() == 2:
			ref = "%d,%d" % [int(d[0]), int(d[1])]
	elif kind == "ASSAULT":
		ref = str(cand.get("stronghold_id", ""))
	_drop_unit_active(uid, "superseded")
	commitments.append({"unit": uid.strip_edges().to_upper(), "kind": kind,
		"ref": ref, "effect": effect.strip_edges().left(MAX_TEXT),
		"status": "ACTIVE", "step": step})
	_trace("COMMIT", "%s %s %s" % [uid, kind, ref])


## Mark a unit's commitment DONE after successful execution; record the
## completed effect and refresh open needs.
func note_execution_done(uid: String, summary: String) -> void:
	var key := uid.strip_edges().to_upper()
	for c_val in commitments:
		var c: Dictionary = c_val
		if str(c.get("unit", "")) == key and str(c.get("status", "")) == "ACTIVE":
			c["status"] = "DONE"
			var done_line := "%s: %s" % [key, summary.strip_edges().left(MAX_TEXT)]
			if not done_line in completed_effects:
				completed_effects.append(done_line)
			while completed_effects.size() > MAX_DONE:
				completed_effects.pop_front()
			_trace("DONE", done_line.left(120))
			_refresh_needs()
			return


## Drop ACTIVE commitments whose unit or target no longer exists.
## alive_red/alive_blue: arrays of live unit-id strings (fresh state).
## SYMMETRIC V1: side selects own/foe sets (default red = legacy behavior).
func invalidate_stale(alive_red: Array, alive_blue: Array, side: String = "red") -> void:
	var own := {}
	var foe := {}
	if side.strip_edges().to_lower() == "blue":
		for u in alive_blue:
			own[str(u).strip_edges().to_upper()] = true
		for b in alive_red:
			foe[str(b).strip_edges().to_upper()] = true
	else:
		for u in alive_red:
			own[str(u).strip_edges().to_upper()] = true
		for b in alive_blue:
			foe[str(b).strip_edges().to_upper()] = true
	for c_val in commitments:
		var c: Dictionary = c_val
		if str(c.get("status", "")) != "ACTIVE":
			continue
		var dead := ""
		if not own.has(str(c.get("unit", ""))):
			dead = "actor %s gone" % str(c.get("unit", ""))
		elif str(c.get("kind", "")) == "ATTACK" and not foe.has(str(c.get("ref", ""))):
			dead = "target %s gone" % str(c.get("ref", ""))
		if not dead.is_empty():
			c["status"] = "INVALIDATED"
			var rec := "%s %s %s (%s)" % [str(c.get("unit", "")), str(c.get("kind", "")),
				str(c.get("ref", "")), dead]
			invalidated.append(rec)
			_trace("DROP", rec.left(140))
	var kept_focus: Array = []
	for f in focus_targets:
		if foe.has(str(f)):
			kept_focus.append(f)
		else:
			_trace("UNFOCUS", "%s gone" % str(f))
	focus_targets = kept_focus
	_refresh_needs()


func note_risks(rows: Array) -> void:
	risks.clear()
	for r in rows:
		var s := str(r).strip_edges().left(MAX_TEXT)
		if not s.is_empty() and not s in risks:
			risks.append(s)
		if risks.size() >= MAX_RISKS:
			break


func note_focus(tids: Array) -> void:
	focus_targets.clear()
	for t in tids:
		var tid := str(t).strip_edges().to_upper()
		if not tid.is_empty() and not tid in focus_targets:
			focus_targets.append(tid)
		if focus_targets.size() >= MAX_FOCUS:
			break


func note_execution_failed(uid: String, reason: String) -> void:
	_drop_unit_active(uid.strip_edges().to_upper(), "exec-failed: %s" % reason.left(60))


func active_for(uid: String) -> Dictionary:
	var key := uid.strip_edges().to_upper()
	for c_val in commitments:
		var c: Dictionary = c_val
		if str(c.get("unit", "")) == key and str(c.get("status", "")) == "ACTIVE":
			return (c as Dictionary).duplicate(true)
	return {}


func active_commitments() -> Array:
	var out: Array = []
	for c_val in commitments:
		if str((c_val as Dictionary).get("status", "")) == "ACTIVE":
			out.append((c_val as Dictionary).duplicate(true))
	return out


## Compact NL block for decide requests. Bounded; facts only.
func serialize_for_laya() -> Dictionary:
	var lines: Array = []
	lines.append("BB %s intent=%s" % [mission_id, intent.left(120)])
	if not focus_targets.is_empty():
		lines.append("FOCUS %s" % ",".join(focus_targets))
	for c_val in commitments:
		var c: Dictionary = c_val
		if str(c.get("status", "")) == "ACTIVE":
			lines.append("COMMIT %s:%s %s" % [str(c.get("unit", "")), str(c.get("kind", "")),
				str(c.get("ref", ""))])
	for n in open_needs:
		lines.append("NEED %s" % str(n).left(120))
	for r in risks:
		lines.append("RISK %s" % str(r).left(120))
	for d in completed_effects:
		lines.append("DONE %s" % str(d).left(120))
	for iv in invalidated:
		lines.append("DROP %s" % str(iv).left(120))
	if not str(group_plan.get("text", "")).is_empty():
		lines.append("PLAN %s" % str(group_plan.get("text", "")).left(160))
	return {"mission_id": mission_id, "text": "\n".join(lines),
		"chars": "\n".join(lines).length()}


func snapshot() -> Dictionary:
	return {"mission_id": mission_id, "intent": intent,
		"group_units": group_units.duplicate(true),
		"focus_targets": focus_targets.duplicate(true),
		"commitments": commitments.duplicate(true),
		"open_needs": open_needs.duplicate(true), "risks": risks.duplicate(true),
		"completed_effects": completed_effects.duplicate(true),
		"invalidated": invalidated.duplicate(true),
		"group_plan": (group_plan as Dictionary).duplicate(true),
		"trace": trace.duplicate(true)}


func _drop_unit_active(uid: String, why: String) -> void:
	var key := uid.strip_edges().to_upper()
	for c_val in commitments:
		var c: Dictionary = c_val
		if str(c.get("unit", "")) == key and str(c.get("status", "")) == "ACTIVE":
			c["status"] = "INVALIDATED"
			invalidated.append("%s %s %s (%s)" % [key, str(c.get("kind", "")),
				str(c.get("ref", "")), why])


func _refresh_needs() -> void:
	# Needs bound to DONE units are satisfied; keep the rest verbatim.
	if group_plan.is_empty():
		return
	var assigns: Dictionary = group_plan.get("assignments", {}) as Dictionary if group_plan.get("assignments") is Dictionary else {}
	var done_units := {}
	for c_val in commitments:
		var c: Dictionary = c_val
		if str(c.get("status", "")) == "DONE":
			done_units[str(c.get("unit", ""))] = true
	var kept: Array = []
	for uid in assigns.keys():
		if done_units.has(str(uid)):
			continue
		var note := str((assigns[uid] as Dictionary).get("note", "")).strip_edges().left(MAX_TEXT)
		if note.is_empty():
			note = ("%s %s %s" % [str(uid), str((assigns[uid] as Dictionary).get("kind", "")),
				str((assigns[uid] as Dictionary).get("target", ""))]).strip_edges()
		if not note.is_empty() and not note in kept:
			kept.append(note)
		if kept.size() >= MAX_NEEDS:
			break
	open_needs = kept


func _trace(event: String, text: String) -> void:
	trace.append({"event": event, "text": text.left(160)})
	while trace.size() > MAX_TRACE:
		trace.pop_front()
