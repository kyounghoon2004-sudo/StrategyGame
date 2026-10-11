class_name Cloud2CoordResponse
extends RefCounted

## FAST COORDINATOR — Cloud-facing selection contract + validation.
##
## The Cloud chooses IDs from the Godot-built coordination menu; it never
## builds Mission/StrategicPlan JSON. Two request types:
##   INITIAL_COORDINATION — concept, main effort, doctrine profile, one
##     choice per force group, review horizon. Hypotheses NOT requested.
##   REVIEW_COORDINATION — KEEP the plan, ADJUST listed groups, or REPLAN
##     with a full initial-style body. Hypotheses optional, canonical shape.
##
## Fatal (precise COORD_* codes): bad JSON, wrong request echo, stale
## snapshot echo, unknown group/choice, duplicate assignment, bad doctrine,
## bad concept/effort, empty assignments/changes, missing ADJUST baseline.
## Lenient (drop + recorded warning, never fatal): malformed optional
## hypotheses, missing doctrine keys (defaults), unassigned groups (Godot
## RESERVE default), non-integer horizon (default 4), unknown top-level
## fields (ignored).
##
## Prompt and validator live in this one file so the contract cannot drift:
## every key the validator requires appears in the prompt example.

const MenuCls = preload("res://scripts/cloud2/cloud2_coord_menu.gd")
const MissionCls = preload("res://scripts/cloud2/cloud2_mission.gd")
const ResponseCls = preload("res://scripts/cloud2/cloud2_response.gd")

const REQUEST_INITIAL := "INITIAL_COORDINATION"
const REQUEST_REVIEW := "REVIEW_COORDINATION"

const COORDINATOR_SYSTEM_PROMPT := "You are the RED strategic coordinator. Godot has already generated all valid force groups and mission choices in the packet menu, and deterministic MissionControllers will execute whatever you choose.\n\nBATTLE OBJECTIVE (authoritative, terminal): your PRIMARY goal is to WIN THE BATTLE. Your HQ destroyed = IMMEDIATE DEFEAT: no further turns, orders, or reviews. Enemy HQ destroyed = IMMEDIATE VICTORY: the battle ends at once. SECONDARY: among plans that plausibly win, prefer the LOWEST expected friendly losses — preserve forces when it supports victory, never at the cost of defeat, never waste them pointlessly. Missions serve victory: complete them when useful and replan when they fail, but no mission outranks HQ survival or a decisive HQ kill.\n\nChoose among the supplied IDs. Return exactly one JSON object:\n{\"concept\": FIX_AND_FLANK|HOLD_AND_PROBE|CONCENTRATED_ADVANCE|ACTIVE_DEFENSE|DELAY_AND_COUNTER|SCREEN_AND_RAID, \"main_effort\": NORTH|CENTER|SOUTH|WEST|EAST|ANY, \"doctrine_profile\": {\"aggression\": LOW|STANDARD|HIGH, \"tempo\": SLOW|STANDARD|FAST, \"risk\": CAUTIOUS|BALANCED|BOLD, \"reserve\": LOOSE|STANDARD|STRICT, \"pursuit\": LIMITED|STANDARD|STRONG}, \"assignments\": [{\"group\": \"G1\", \"choice\": \"G1_FIX_CENTER\"}], \"review_horizon\": 1-12, \"snapshot_id\": \"<echo the packet snapshot_id>\"}.\n\nRules: one assignment per group, every group assigned; choice IDs must come from that group's menu options. Do not invent units, groups, or choice IDs. Do not issue tactical orders, hexes, targets, or explanations. Do not send hypotheses. No Markdown, no code fences.\n\nExample: {\"concept\": \"FIX_AND_FLANK\", \"main_effort\": \"CENTER\", \"doctrine_profile\": {\"aggression\": \"STANDARD\", \"tempo\": \"FAST\", \"risk\": \"BALANCED\", \"reserve\": \"STRICT\", \"pursuit\": \"STANDARD\"}, \"assignments\": [{\"group\": \"G1\", \"choice\": \"G1_FIX_CENTER\"}, {\"group\": \"G2\", \"choice\": \"G2_FLANK_NORTH\"}], \"review_horizon\": 3}"

const REVIEW_SYSTEM_PROMPT := "You are the RED strategic coordinator reviewing the current plan in the packet. Deterministic MissionControllers execute it; you only coordinate.\n\nBATTLE OBJECTIVE (authoritative, terminal): PRIMARY is to WIN THE BATTLE. Your HQ destroyed = IMMEDIATE DEFEAT. Enemy HQ destroyed = IMMEDIATE VICTORY. SECONDARY: among viable winning plans, minimize expected friendly losses. Missions are subordinate to battle victory: complete them when useful, replan when they fail, never rank them above HQ survival or a decisive HQ kill.\n\nReturn exactly one JSON object with \"decision\": KEEP (plan stands) | ADJUST (change listed groups) | REPLAN (full new selection).\nKEEP: {\"decision\": \"KEEP\"}. ADJUST: {\"decision\": \"ADJUST\", \"changes\": [{\"group\": \"G2\", \"choice\": \"G2_RESERVE\"}]} using current menu IDs; if the packet has_baseline is false, never answer ADJUST. REPLAN: {\"decision\": \"REPLAN\", \"concept\": ..., \"main_effort\": ..., \"doctrine_profile\": {...}, \"assignments\": [...], \"review_horizon\": N} exactly like an initial selection.\n\nOptional: \"opponent_hypotheses\": [{\"hypothesis\": \"NAME\", \"confidence\": 0-1, \"evidence\": [\"short strings\"]}] — the key MUST be \"hypothesis\". Malformed entries are dropped, never fatal. Echo \"snapshot_id\" from the packet. Do not invent IDs, orders, hexes, or targets. No Markdown, no code fences.\n\nExample: {\"decision\": \"ADJUST\", \"changes\": [{\"group\": \"G2\", \"choice\": \"G2_RESERVE\"}]}"

const REJECTION_CODES := ["COORD_INVALID_JSON", "COORD_INVALID_SCHEMA", "COORD_WRONG_REQUEST",
	"COORD_STALE_SNAPSHOT", "COORD_UNKNOWN_GROUP", "COORD_UNKNOWN_CHOICE",
	"COORD_DUPLICATE_ASSIGNMENT", "COORD_INVALID_DOCTRINE", "COORD_INVALID_CONCEPT",
	"COORD_INVALID_MAIN_EFFORT", "COORD_NO_ASSIGNMENTS", "COORD_INVALID_DECISION",
	"COORD_NO_BASELINE", "COORD_EMPTY_MENU"]


static func response_schema() -> Dictionary:
	return {
		"initial": {"concept": "enum (required)", "main_effort": "AREA (required)",
			"doctrine_profile": "5 categories (required; missing keys default)",
			"assignments": "array (required, 1 per group)", "review_horizon": "int 1..12 (optional, default 4)",
			"snapshot_id": "string (optional echo)", "opponent_hypotheses": "NOT requested"},
		"review": {"decision": "KEEP|ADJUST|REPLAN (required)",
			"changes": "array (ADJUST required)", "concept/main_effort/doctrine_profile/assignments": "REPLAN required (initial rules)",
			"opponent_hypotheses": "array (optional; entries need key 'hypothesis')"},
		"hypothesis": {"hypothesis": "NAME string (required)", "confidence": "0..1 (optional, default 0.5)", "evidence": "[short strings] (optional)"},
		"rejection_codes": REJECTION_CODES.duplicate(),
	}


## Parse an INITIAL_COORDINATION reply against the frozen menu.
## ctx: {"menu": {}, "snapshot_id": "", "turn": 0, "skip_request_echo": false}.
## Returns {ok, code, detail, json_ok, selection, warnings}.
static func parse_initial(text: String, ctx: Dictionary = {}) -> Dictionary:
	var menu: Dictionary = ctx.get("menu", {})
	var want_snap := str(ctx.get("snapshot_id", "")).strip_edges()
	if text.strip_edges().is_empty():
		return _fail("COORD_INVALID_JSON", "Coordinator returned an empty response.", false)
	var doc := ResponseCls.extract_json(text)
	if doc.is_empty():
		return _fail("COORD_INVALID_JSON", "Coordinator response is not a JSON object.", false)
	var echo_req := str(doc.get("request", "")).strip_edges()
	if not bool(ctx.get("skip_request_echo", false)) and not echo_req.is_empty() and echo_req != REQUEST_INITIAL:
		return _fail("COORD_WRONG_REQUEST", "Expected %s, got '%s'." % [REQUEST_INITIAL, echo_req], true)
	var echo := str(doc.get("snapshot_id", doc.get("snapshot", ""))).strip_edges()
	if not echo.is_empty() and not want_snap.is_empty() and echo != want_snap:
		return _fail("COORD_STALE_SNAPSHOT", "Snapshot echo '%s' does not match '%s'." % [echo, want_snap], true)
	var concept := str(doc.get("concept", "")).strip_edges().to_upper()
	if not MenuCls.CONCEPTS.has(concept):
		return _fail("COORD_INVALID_CONCEPT", "Unknown concept '%s'." % str(doc.get("concept", "")), true)
	var effort := str(doc.get("main_effort", "")).strip_edges().to_upper()
	if not effort in MissionCls.AREAS:
		return _fail("COORD_INVALID_MAIN_EFFORT", "Unknown main_effort '%s'." % str(doc.get("main_effort", "")), true)
	if not doc.get("doctrine_profile") is Dictionary:
		return _fail("COORD_INVALID_SCHEMA", "Response needs a 'doctrine_profile' object.", true)
	var warnings: Array = []
	var doctrine := _checked_doctrine(doc.get("doctrine_profile"), warnings)
	if doctrine.is_empty():
		return _fail("COORD_INVALID_DOCTRINE", str(warnings.pop_back()), true)
	if not doc.get("assignments") is Array or (doc.get("assignments") as Array).is_empty():
		return _fail("COORD_NO_ASSIGNMENTS", "Response carries no usable mission assignments.", true)
	var asn := _checked_assignments(doc.get("assignments"), menu, warnings)
	if not bool(asn.get("ok", false)):
		return _fail(str(asn.get("code", "COORD_INVALID_SCHEMA")), str(asn.get("detail", "")), true)
	var horizon := MenuCls.DEFAULT_HORIZON
	if doc.has("review_horizon"):
		if doc.get("review_horizon") is int or doc.get("review_horizon") is float:
			horizon = clampi(int(doc.get("review_horizon")), 1, 12)
		else:
			warnings.append("DEFAULTED_HORIZON reason=not-an-int value=%d" % MenuCls.DEFAULT_HORIZON)
	var hyps := parse_hypotheses(doc.get("opponent_hypotheses", []))
	warnings.append_array(hyps.get("warnings", []))
	return {"ok": true, "code": "", "detail": "", "json_ok": true,
		"selection": {"concept": concept, "main_effort": effort, "doctrine": doctrine,
			"assignments": asn.get("assignments", []), "horizon": horizon,
			"hypotheses": hyps.get("hypotheses", [])},
		"warnings": warnings}


## Parse a REVIEW_COORDINATION reply.
## ctx: {"menu": {}, "snapshot_id": "", "turn": 0, "baseline": {}, "has_baseline": false}.
## KEEP -> {decision, hypotheses}; ADJUST -> {decision, changes, doctrine_override,
## hypotheses}; REPLAN -> {decision, selection(initial rules)}.
static func parse_review(text: String, ctx: Dictionary = {}) -> Dictionary:
	var menu: Dictionary = ctx.get("menu", {})
	var want_snap := str(ctx.get("snapshot_id", "")).strip_edges()
	if text.strip_edges().is_empty():
		return _fail("COORD_INVALID_JSON", "Coordinator returned an empty response.", false)
	var doc := ResponseCls.extract_json(text)
	if doc.is_empty():
		return _fail("COORD_INVALID_JSON", "Coordinator response is not a JSON object.", false)
	var echo_req := str(doc.get("request", "")).strip_edges()
	if not echo_req.is_empty() and echo_req != REQUEST_REVIEW:
		return _fail("COORD_WRONG_REQUEST", "Expected %s, got '%s'." % [REQUEST_REVIEW, echo_req], true)
	var echo := str(doc.get("snapshot_id", doc.get("snapshot", ""))).strip_edges()
	if not echo.is_empty() and not want_snap.is_empty() and echo != want_snap:
		return _fail("COORD_STALE_SNAPSHOT", "Snapshot echo '%s' does not match '%s'." % [echo, want_snap], true)
	var decision := str(doc.get("decision", "")).strip_edges().to_upper()
	if decision.is_empty():
		return _fail("COORD_INVALID_DECISION", "Review response needs a 'decision' (KEEP|ADJUST|REPLAN).", true)
	if decision == "KEEP":
		var khy := parse_hypotheses(doc.get("opponent_hypotheses", []))
		return {"ok": true, "code": "", "detail": "", "json_ok": true,
			"review": {"decision": "KEEP", "hypotheses": khy.get("hypotheses", []),
				"has_hypotheses": doc.has("opponent_hypotheses")},
			"warnings": khy.get("warnings", [])}
	if decision == "ADJUST":
		if not bool(ctx.get("has_baseline", false)):
			return _fail("COORD_NO_BASELINE", "ADJUST needs a prior choice record; answer REPLAN instead.", true)
		if not doc.get("changes") is Array or (doc.get("changes") as Array).is_empty():
			return _fail("COORD_INVALID_DECISION", "ADJUST needs a non-empty 'changes' array.", true)
		var warnings: Array = []
		var ch := _checked_assignments(doc.get("changes"), menu, warnings, true)
		if not bool(ch.get("ok", false)):
			return _fail(str(ch.get("code", "COORD_INVALID_SCHEMA")), str(ch.get("detail", "")), true)
		var override := {}
		if doc.has("doctrine_profile"):
			if not doc.get("doctrine_profile") is Dictionary:
				return _fail("COORD_INVALID_SCHEMA", "'doctrine_profile' override must be an object.", true)
			override = _checked_doctrine(doc.get("doctrine_profile"), warnings, true)
			if override.is_empty() and not (doc.get("doctrine_profile") as Dictionary).is_empty():
				return _fail("COORD_INVALID_DOCTRINE", str(warnings.pop_back()), true)
		var ahy := parse_hypotheses(doc.get("opponent_hypotheses", []))
		warnings.append_array(ahy.get("warnings", []))
		return {"ok": true, "code": "", "detail": "", "json_ok": true,
			"review": {"decision": "ADJUST", "changes": ch.get("assignments", []),
				"doctrine_override": override, "hypotheses": ahy.get("hypotheses", []),
				"has_hypotheses": doc.has("opponent_hypotheses")},
			"warnings": warnings}
	if decision == "REPLAN":
		var sub := parse_initial(text, {"menu": menu, "snapshot_id": want_snap, "turn": int(ctx.get("turn", 0)), "skip_request_echo": true})
		if not bool(sub.get("ok", false)):
			return sub
		var rev: Dictionary = {"decision": "REPLAN", "selection": sub.get("selection", {})}
		return {"ok": true, "code": "", "detail": "", "json_ok": true, "review": rev, "warnings": sub.get("warnings", [])}
	return _fail("COORD_INVALID_DECISION", "Unknown decision '%s' (KEEP|ADJUST|REPLAN)." % str(doc.get("decision", "")), true)


## Validate one doctrine profile object. allow_partial: missing keys are kept
## (ADJUST override) instead of defaulted. Returns the canonical profile, or
## {} with the fatal reason appended to warnings.
static func _checked_doctrine(d_val: Variant, warnings: Array, allow_partial: bool = false) -> Dictionary:
	if not d_val is Dictionary:
		return {}
	var d: Dictionary = d_val
	var out := {}
	for k in (d as Dictionary).keys():
		var ks := str(k)
		if not MenuCls.DOCTRINE_TABLE.has(ks):
			warnings.append("Unknown doctrine key '%s'." % ks)
			return {}
		var want := str(d[ks]).strip_edges().to_upper()
		if not (MenuCls.DOCTRINE_TABLE[ks] as Dictionary).has(want):
			warnings.append("Unknown doctrine value '%s' for '%s'." % [str(d[ks]), ks])
			return {}
		out[ks] = want
	if not allow_partial:
		for key in MenuCls.DOCTRINE_DEFAULTS.keys():
			if not out.has(key):
				out[key] = MenuCls.DOCTRINE_DEFAULTS[key]
				warnings.append("DEFAULTED_DOCTRINE key=%s value=%s" % [key, out[key]])
	return out


## Validate an assignments/changes array against the frozen menu. strict_all:
## every menu group must be assigned (initial); else partial is fine (ADJUST
## changes) and unassigned groups are Godot-defaulted with warnings recorded.
## Returns {ok, code, detail, assignments(full canonical list)}.
static func _checked_assignments(a_val: Variant, menu: Dictionary, warnings: Array, is_changes: bool = false) -> Dictionary:
	if not a_val is Array:
		return {"ok": false, "code": "COORD_INVALID_SCHEMA", "detail": "Assignments must be an array.", "assignments": []}
	var seen := {}
	var out: Array = []
	for e_val in (a_val as Array):
		if not e_val is Dictionary:
			return {"ok": false, "code": "COORD_INVALID_SCHEMA", "detail": "Assignment must be a {group, choice} object.", "assignments": []}
		var grp := str((e_val as Dictionary).get("group", "")).strip_edges().to_upper()
		var cho := str((e_val as Dictionary).get("choice", "")).strip_edges().to_upper()
		if grp.is_empty() or cho.is_empty():
			return {"ok": false, "code": "COORD_INVALID_SCHEMA", "detail": "Assignment needs 'group' and 'choice'.", "assignments": []}
		if MenuCls.find_group(menu, grp).is_empty():
			return {"ok": false, "code": "COORD_UNKNOWN_GROUP", "detail": "Unknown group '%s'." % grp, "assignments": []}
		if MenuCls.find_option(menu, grp, cho).is_empty():
			return {"ok": false, "code": "COORD_UNKNOWN_CHOICE", "detail": "Unknown choice '%s' for group '%s'." % [cho, grp], "assignments": []}
		if seen.has(grp):
			return {"ok": false, "code": "COORD_DUPLICATE_ASSIGNMENT", "detail": "Duplicate assignment for group '%s'." % grp, "assignments": []}
		seen[grp] = true
		out.append({"group": grp, "choice": cho})
	if not is_changes:
		for g_val in (menu.get("groups", []) as Array):
			if not g_val is Dictionary:
				continue
			var gid := str((g_val as Dictionary).get("id", ""))
			if not seen.has(gid):
				var def_choice := MenuCls.default_choice_id(g_val)
				out.append({"group": gid, "choice": def_choice})
				warnings.append("DEFAULTED_GROUP %s reason=unassigned choice=%s" % [gid, def_choice])
	return {"ok": true, "code": "", "detail": "", "assignments": out}


## Lenient hypotheses: canonical entries are kept ({hypothesis, confidence,
## evidence}); malformed entries are DROPPED with a recorded warning and can
## never kill the core plan. Non-array input yields no hypotheses (+warning
## when the key was present but unusable).
static func parse_hypotheses(h_val: Variant, key_present: bool = true) -> Dictionary:
	var out: Array = []
	var warnings: Array = []
	if h_val == null or (h_val is Array and (h_val as Array).is_empty()):
		return {"hypotheses": [], "warnings": []}
	if not h_val is Array:
		if key_present:
			warnings.append("DROPPED_HYPOTHESES reason=not-an-array")
		return {"hypotheses": [], "warnings": warnings}
	var idx := 0
	for e_val in (h_val as Array):
		idx += 1
		if not e_val is Dictionary:
			warnings.append("DROPPED_INVALID_HYPOTHESIS idx=%d reason=not-an-object" % idx)
			continue
		var e: Dictionary = e_val
		var name := str(e.get("hypothesis", "")).strip_edges()
		if name.is_empty():
			warnings.append("DROPPED_INVALID_HYPOTHESIS idx=%d reason=missing-name" % idx)
			continue
		var ev: Array = []
		if e.get("evidence") is Array:
			for x in (e.get("evidence") as Array):
				ev.append(str(x).strip_edges().left(160))
				if ev.size() >= 6:
					break
		var conf := 0.5
		if e.get("confidence") is int or e.get("confidence") is float:
			conf = clampf(float(e.get("confidence")), 0.0, 1.0)
		out.append({"hypothesis": name.to_upper().left(64), "confidence": conf, "evidence": ev})
		if out.size() >= 4:
			break
	return {"hypotheses": out, "warnings": warnings}


static func _fail(code: String, detail: String, json_ok: bool) -> Dictionary:
	return {"ok": false, "code": code, "detail": detail, "json_ok": json_ok, "selection": {}, "review": {}, "warnings": []}
