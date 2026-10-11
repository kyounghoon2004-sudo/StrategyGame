class_name Cloud2GeneralResponse
extends RefCounted

## CLOUD-GENERAL MISSION HIERARCHY — General output contract + validation.
##
## Parses the Cloud General's structured reply into a canonical StrategicPlan.
## Accepted shape:
##   {"concept": {...}, "doctrine": {...}, "missions": [...],
##    "contingencies": [...], "opponent_hypotheses": [...],
##    "review_conditions": [...], "review_horizon_turns": N,
##    "snapshot_id": "<optional echo>"}
## The model is never trusted: structure, mission shape, trigger names, and
## doctrine ranges are all re-checked here, and assignments are reconciled
## against live Godot state by the mission manager afterwards.
##
## Rejection codes: INVALID_JSON, INVALID_SCHEMA, plus Cloud2GeneralPlan /
## Cloud2Mission codes and STALE_SNAPSHOT (echo mismatch).

const PlanCls = preload("res://scripts/cloud2/cloud2_general_plan.gd")
const ResponseCls = preload("res://scripts/cloud2/cloud2_response.gd")


static func response_schema() -> Dictionary:
	return {
		"shape": {"concept": "object (required)", "doctrine": "object (required)",
			"missions": "array (required, 1..8)", "contingencies": "array (optional)",
			"opponent_hypotheses": "array (optional, <=4)", "review_conditions": "array (optional)",
			"review_horizon_turns": "int 1..12 (optional)", "snapshot_id": "string (optional echo)"},
		"concept": {"objective": "string <= 280", "intent": "string <= 280",
			"main_effort": "string <= 24", "risk_posture": "string <= 24"},
		"doctrine": {"aggression": "0..1", "risk_tolerance": "0..1", "tempo": "0..1",
			"pursuit": "0..1", "reserve_discipline": "0..1", "deception": "0..1"},
		"mission": {"mission_id": "string", "task": "HOLD|ADVANCE|FIX|ATTACK|FLANK|RECON|RESERVE|WITHDRAW",
			"area": "NORTH|CENTER|SOUTH|WEST|EAST|ANY", "assigned_units": "[RED unit ids]",
			"objective": "object", "engagement": "object", "constraints": "object",
			"success_conditions": "[triggers]", "abort_conditions": "[triggers]", "report_conditions": "[triggers]"},
		"rejection_codes": ["INVALID_JSON", "INVALID_SCHEMA", "PLAN_EMPTY", "PLAN_MISSION",
			"MISSION_TASK", "MISSION_AREA", "MISSION_OBJECTIVE", "MISSION_ENGAGEMENT",
			"MISSION_CONDITION", "PLAN_CONTINGENCY", "PLAN_HYPOTHESES", "STALE_SNAPSHOT"],
	}


## Parse + validate a full General reply.
## ctx: {"turn": int, "snapshot_id": "", "plan_version": int}.
static func parse(text: String, ctx: Dictionary = {}) -> Dictionary:
	if text.strip_edges().is_empty():
		return _fail("INVALID_JSON", "General returned an empty response.")
	var doc := ResponseCls.extract_json(text)
	if doc.is_empty():
		return _fail("INVALID_JSON", "General response is not a JSON object.")
	for k in ["concept", "doctrine", "missions"]:
		if not doc.has(k):
			return _fail("INVALID_SCHEMA", "General response needs '%s'." % k)
	if not doc.get("concept") is Dictionary:
		return _fail("INVALID_SCHEMA", "General 'concept' must be an object.")
	if not doc.get("doctrine") is Dictionary:
		return _fail("INVALID_SCHEMA", "General 'doctrine' must be an object.")
	if not doc.get("missions") is Array:
		return _fail("INVALID_SCHEMA", "General 'missions' must be an array.")
	var echo := str(doc.get("snapshot_id", doc.get("snapshot", ""))).strip_edges()
	var want := str(ctx.get("snapshot_id", "")).strip_edges()
	var stale := false
	if not echo.is_empty() and not want.is_empty() and echo != want:
		stale = true
	var plan_doc := {
		"plan_version": int(ctx.get("plan_version", 1)),
		"based_on_snapshot": want,
		"created_turn": int(ctx.get("turn", 0)),
		"last_review_turn": int(ctx.get("turn", 0)),
		"mission": doc.get("mission", {}),
		"concept": doc.get("concept", {}),
		"doctrine": doc.get("doctrine", {}),
		"missions": doc.get("missions", []),
		"contingencies": doc.get("contingencies", []),
		"opponent_hypotheses": doc.get("opponent_hypotheses", []),
		"review_conditions": doc.get("review_conditions", []),
		"review_horizon_turns": doc.get("review_horizon_turns", PlanCls.DEFAULT_REVIEW_HORIZON),
		"source": "general",
	}
	var checked := PlanCls.validate_plan(plan_doc, ctx)
	if not bool(checked.get("ok", false)):
		return {"ok": false, "code": str(checked.get("code", "INVALID_SCHEMA")),
			"detail": str(checked.get("detail", "")), "stale_snapshot": stale, "plan": {}}
	if stale:
		return {"ok": false, "code": "STALE_SNAPSHOT",
			"detail": "Snapshot echo '%s' does not match '%s'." % [echo, want],
			"stale_snapshot": true, "plan": {}}
	return {"ok": true, "code": "", "detail": "", "stale_snapshot": false,
		"plan": checked.get("plan", {})}


static func _fail(code: String, detail: String) -> Dictionary:
	return {"ok": false, "code": code, "detail": detail, "stale_snapshot": false, "plan": {}}


static func render_summary(parsed: Dictionary) -> String:
	if not bool(parsed.get("ok", false)):
		return "GENERAL RESPONSE REJECT %s: %s" % [str(parsed.get("code", "?")), str(parsed.get("detail", ""))]
	return "GENERAL RESPONSE OK\n" + PlanCls.render_summary(parsed.get("plan", {}))
