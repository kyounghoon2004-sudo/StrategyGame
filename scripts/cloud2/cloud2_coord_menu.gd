class_name Cloud2CoordMenu
extends RefCounted

## FAST COORDINATOR — Godot-owned coordination menu, doctrine profiles,
## operational concepts, and selection expansion.
##
## GODOT CREATES OPTIONS. CLOUD CHOOSES. GODOT EXECUTES.
##
## The Cloud never builds Mission/StrategicPlan JSON here. Godot groups live
## RED formations into stable force groups (G1..Gn, one per class family),
## offers each group a bounded set of fully-templated mission options
## (G1_FIX_CENTER, G2_RESERVE, ...), and expands the Cloud's ID selection
## back into the canonical StrategicPlan/Mission structures the existing
## MissionManager/MissionControllers already execute. Option templates use
## only validated vocabulary, so expansion is valid by construction; the
## production validators still re-check every expanded plan (defense in
## depth), and any expansion failure is reported as COORD_EXPAND_* (a Godot
## template bug, never a Cloud correction retry).
##
## Pure data + derivation. No network, no battle mutation.

const MissionCls = preload("res://scripts/cloud2/cloud2_mission.gd")
const PlanCls = preload("res://scripts/cloud2/cloud2_general_plan.gd")

const MENU_VERSION := "cloud2_coord_menu_v1"

## Families in stable menu order; only non-empty families become groups, so
## a menu holds at most 4 groups by construction (no merge logic needed).
const FAMILY_ORDER := ["LINE", "FAST", "SUPPORT", "COMMAND"]

## Doctrine profile categories (Cloud-facing) mapped to the existing numeric
## runtime representation. Deception stays a Godot-side default.
const DOCTRINE_DEFAULTS := {"aggression": "STANDARD", "tempo": "STANDARD",
	"risk": "BALANCED", "reserve": "STANDARD", "pursuit": "STANDARD"}
const DOCTRINE_TABLE := {
	"aggression": {"LOW": 0.25, "STANDARD": 0.5, "HIGH": 0.8},
	"tempo": {"SLOW": 0.25, "STANDARD": 0.5, "FAST": 0.8},
	"risk": {"CAUTIOUS": 0.25, "BALANCED": 0.5, "BOLD": 0.8},
	"reserve": {"LOOSE": 0.3, "STANDARD": 0.6, "STRICT": 0.9},
	"pursuit": {"LIMITED": 0.2, "STANDARD": 0.5, "STRONG": 0.85},
}
const DOCTRINE_NUMERIC_KEYS := {"aggression": "aggression", "tempo": "tempo",
	"risk": "risk_tolerance", "reserve": "reserve_discipline", "pursuit": "pursuit"}
const DOCTRINE_DECEPTION := 0.2
const RISK_POSTURE := {"CAUTIOUS": "CAUTIOUS", "BALANCED": "BALANCED", "BOLD": "BOLD"}

## Bounded operational concepts (Cloud-facing IDs) with Godot-authored text.
## The Cloud names the concept; Godot owns every word of the plan prose.
const CONCEPTS := {
	"FIX_AND_FLANK": {"objective": "Fix the enemy center with the main line while fast forces turn a flank.",
		"intent": "Decisive effort on the flank once BLUE commits centrally."},
	"HOLD_AND_PROBE": {"objective": "Hold key terrain and probe for weakness with fast forces.",
		"intent": "Conserve strength; strike only exposed objectives."},
	"CONCENTRATED_ADVANCE": {"objective": "Advance concentrated on the main effort axis.",
		"intent": "Massed pressure to seize the objective region."},
	"ACTIVE_DEFENSE": {"objective": "Defend in depth with local counterattacks.",
		"intent": "Yield nothing vital; punish overextension."},
	"DELAY_AND_COUNTER": {"objective": "Delay forward, preserve force, counterattack decisively.",
		"intent": "Trade space for advantage, then strike."},
	"SCREEN_AND_RAID": {"objective": "Screen with the line while fast forces raid.",
		"intent": "Disrupt and attrit; avoid decisive engagement."},
}

const DEFAULT_HORIZON := 4


## Class family of one obs unit class (upper- or lower-case). Unknown classes
## fall into LINE (documented default) so no formation is ever ungroupable.
static func family_of(unit_class: String) -> String:
	var c := unit_class.strip_edges().to_upper()
	if c == "HQ" or c == "HEADQUARTERS" or c.begins_with("HQ_"):
		return "COMMAND"
	if c in ["CAVALRY", "SCOUT"] or c.begins_with("CAV") or c.begins_with("SCT") or c.begins_with("SCOUT"):
		return "FAST"
	if c in ["CONSCRIPT", "SIEGE"] or c.begins_with("CON") or c.begins_with("SIEG") or c.begins_with("SIG"):
		return "SUPPORT"
	return "LINE"


## Build the coordination menu from a canonical RED observation. Deterministic:
## same obs bytes -> same menu bytes (sorted ids, fixed family order).
## Membership = every listed formation (obs lists only the living; statuses
## are annotated, and MissionControllers filter ready at decide-time), so the
## menu is stable across acted/ready flips within a turn.
static func build_menu(obs: Dictionary) -> Dictionary:
	var buckets := {"LINE": [], "FAST": [], "SUPPORT": [], "COMMAND": []}
	for u_val in (obs.get("friendly_units", []) as Array):
		if not u_val is Dictionary:
			continue
		var u: Dictionary = u_val
		var uid := str(u.get("unit_id", "")).strip_edges().to_upper()
		if uid.is_empty():
			continue
		var fam := family_of(str(u.get("class", "")))
		(buckets[fam] as Array).append({
			"unit_id": uid,
			"class": str(u.get("class", "")).strip_edges().to_upper(),
			"region": str(u.get("region", "ANY")).strip_edges().to_upper(),
			"status": str(u.get("status", "")).strip_edges().to_lower(),
			"soldiers": int(u.get("soldiers", 0)),
		})
	var groups: Array = []
	var gid := 0
	for fam in FAMILY_ORDER:
		var members: Array = buckets[fam]
		if members.is_empty():
			continue
		members.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.get("unit_id", "")) < str(b.get("unit_id", "")))
		gid += 1
		var gname := "G%d" % gid
		var regions := {}
		var soldiers := 0
		var ids: Array = []
		for m_val in members:
			var m: Dictionary = m_val
			regions[str(m.get("region", "ANY"))] = true
			soldiers += int(m.get("soldiers", 0))
			ids.append(str(m.get("unit_id", "")))
		var rlist: Array = regions.keys()
		rlist.sort()
		groups.append({
			"id": gname,
			"family": fam,
			"units": members,
			"unit_ids": ids,
			"regions": rlist,
			"soldiers": soldiers,
			"options": _options_for(fam, gname, rlist),
		})
	return {"menu_version": MENU_VERSION,
		"menu_id": "coord_%s" % str(obs.get("snapshot_id", "")).left(24),
		"snapshot_id": str(obs.get("snapshot_id", "")),
		"turn": int(obs.get("turn", 0)),
		"groups": groups}


## Slim mission options for one family: id + label + task + area only. The
## Cloud chooses among these; Godot completes the chosen option into a full
## Mission seed via complete_option (single template source). IDs are
## task-derived (stable across turns when the same option exists); every
## family offers RESERVE (the universal Godot-side default for unassigned
## groups). Slim options keep the frozen menu compact on the wire.
static func _options_for(family: String, gid: String, regions: Array) -> Array:
	var r := str(regions[0]) if not regions.is_empty() else "ANY"
	var out: Array = []
	match family:
		"LINE":
			out.append(_opt(gid, "FIX", r))
			out.append(_opt(gid, "ADVANCE", r))
			out.append(_opt(gid, "HOLD", r))
			out.append(_opt(gid, "WITHDRAW", r))
			out.append(_opt(gid, "RESERVE", "ANY"))
		"FAST":
			out.append(_opt(gid, "FLANK", r))
			out.append(_opt(gid, "RECON", r))
			out.append(_opt(gid, "ATTACK", r))
			out.append(_opt(gid, "RESERVE", "ANY"))
			if regions.size() > 1:
				out.append(_opt(gid, "FLANK", str(regions[1])))
		"SUPPORT":
			out.append(_opt(gid, "HOLD", r))
			out.append(_opt(gid, "ADVANCE", r))
			out.append(_opt(gid, "RESERVE", "ANY"))
		_:
			out.append(_opt(gid, "HOLD", "ANY", true))
			out.append(_opt(gid, "RESERVE", "ANY"))
	return out


static func _opt(gid: String, task: String, area: String, hq_hold: bool = false) -> Dictionary:
	var oid := "%s_%s" % [gid, task] if task in ["RESERVE"] else "%s_%s_%s" % [gid, task, area]
	var label := task if area == "ANY" else "%s %s" % [task, area]
	if hq_hold:
		label = "HOLD HQ"
	return {"id": oid, "label": label, "task": task, "area": area}


## Complete a slim menu option into a full Mission seed using validated
## vocabulary only. Deterministic from (family, task, area) — the single
## template source for every expansion, so menus stay small on the wire.
static func complete_option(family: String, slim: Dictionary) -> Dictionary:
	var task := str(slim.get("task", ""))
	var area := str(slim.get("area", "ANY"))
	var objective := {"kind": "NONE"}
	if task == "HOLD" and family == "COMMAND":
		objective = {"kind": "ZONE", "zone": "HQ"}
	elif not task in ["RESERVE", "WITHDRAW"]:
		objective = {"kind": "REGION", "region": area}
	var policy := "ATTACK_IF_ADVANTAGEOUS"
	var preserve := false
	var overextend := 3
	match task:
		"FLANK":
			policy = "PURSUE_WEAKENED"
			overextend = 5
		"RECON":
			policy = "HOLD_FIRE"
			preserve = true
			overextend = 5
		"HOLD", "RESERVE", "WITHDRAW":
			policy = "HOLD_FIRE"
			preserve = true
			overextend = 1 if task in ["RESERVE", "WITHDRAW"] or family == "COMMAND" else 3
	return {"id": str(slim.get("id", "")), "label": str(slim.get("label", "")), "task": task, "area": area,
		"objective": objective, "engagement": {"policy": policy},
		"constraints": {"preserve_force": preserve, "max_overextension": overextend},
		"success_conditions": ["MISSION_COMPLETE"], "abort_conditions": ["FORCE_STRENGTH_BELOW"],
		"report_conditions": ["MISSION_BLOCKED"]}


static func find_group(menu: Dictionary, group_id: String) -> Dictionary:
	for g_val in (menu.get("groups", []) as Array):
		if g_val is Dictionary and str((g_val as Dictionary).get("id", "")) == group_id:
			return g_val
	return {}


static func find_option(menu: Dictionary, group_id: String, choice_id: String) -> Dictionary:
	var g := find_group(menu, group_id)
	if g.is_empty():
		return {}
	for o_val in (g.get("options", []) as Array):
		if o_val is Dictionary and str((o_val as Dictionary).get("id", "")) == choice_id:
			return o_val
	return {}


## Godot-side default for an unassigned group: its RESERVE option (every
## family offers one), else its first option. Deterministic, never guessed.
static func default_choice_id(group: Dictionary) -> String:
	for o_val in (group.get("options", []) as Array):
		if o_val is Dictionary and str((o_val as Dictionary).get("task", "")) == "RESERVE":
			return str((o_val as Dictionary).get("id", ""))
	var opts: Array = group.get("options", []) as Array
	if opts.is_empty() or not opts[0] is Dictionary:
		return ""
	return str((opts[0] as Dictionary).get("id", ""))


## Category profile -> numeric runtime doctrine. Unknown keys are ignored
## here (the response validator already rejected them fatally); unknown
## values fall back to their key default (defense in depth, no warning —
## the validator owns warnings for input it accepted).
static func doctrine_to_numeric(profile: Dictionary) -> Dictionary:
	var out := {}
	for key in DOCTRINE_DEFAULTS.keys():
		var want := str(profile.get(key, DOCTRINE_DEFAULTS[key])).strip_edges().to_upper()
		var table: Dictionary = DOCTRINE_TABLE[key]
		out[str(DOCTRINE_NUMERIC_KEYS[key])] = float(table.get(want, table[DOCTRINE_DEFAULTS[key]]))
	out["deception"] = DOCTRINE_DECEPTION
	return out


## Expand a validated INITIAL/REPLAN selection into a canonical plan doc.
## sel: {concept, main_effort, doctrine, assignments(full, validated),
##   horizon, hypotheses}. warn_in: parser warnings to carry through.
## Returns {ok, code, detail, plan, warnings, choices, missions}. Expansion
## failures are COORD_EXPAND_* (Godot template bugs — never Cloud retries).
static func expand_initial(menu: Dictionary, sel: Dictionary, turn: int, snapshot: String, mission: Dictionary, warn_in: Array = []) -> Dictionary:
	if str(menu.get("snapshot_id", "")) != snapshot:
		return {"ok": false, "code": "COORD_STALE_SNAPSHOT", "detail": "Menu snapshot does not match the frozen observation.", "plan": {}, "warnings": warn_in}
	var missions: Array = []
	var choices := {}
	var warnings: Array = warn_in.duplicate(true)
	var picked := {}
	for a_val in (sel.get("assignments", []) as Array):
		if a_val is Dictionary:
			picked[str((a_val as Dictionary).get("group", ""))] = str((a_val as Dictionary).get("choice", ""))
	var idx := 0
	for g_val in (menu.get("groups", []) as Array):
		if not g_val is Dictionary:
			continue
		var g: Dictionary = g_val
		var grp := str(g.get("id", ""))
		var cho := str(picked.get(grp, ""))
		if cho.is_empty():
			continue # validated selections cover every group; defense only
		var opt := find_option(menu, grp, cho)
		if opt.is_empty():
			return {"ok": false, "code": "COORD_EXPAND_UNKNOWN", "detail": "Assignment %s->%s not in menu." % [grp, cho], "plan": {}, "warnings": warnings}
		idx += 1
		missions.append(_mission_from_option(idx, g, opt))
		choices[grp] = cho
	if missions.is_empty():
		return {"ok": false, "code": "COORD_NO_ASSIGNMENTS", "detail": "No usable mission assignments after menu reconciliation.", "plan": {}, "warnings": warnings}
	var concept: Dictionary = (CONCEPTS.get(str(sel.get("concept", "")), {}) as Dictionary).duplicate(true)
	var risk_cat := str((sel.get("doctrine", {}) as Dictionary).get("risk", "BALANCED")).strip_edges().to_upper()
	var plan := {
		"plan_version": 1,
		"based_on_snapshot": snapshot,
		"created_turn": turn,
		"last_review_turn": turn,
		"mission": {"type": str(mission.get("type", "")), "objective": str(mission.get("objective", ""))},
		"concept": {"objective": str(concept.get("objective", "")), "intent": str(concept.get("intent", "")),
			"main_effort": str(sel.get("main_effort", "ANY")), "risk_posture": str(RISK_POSTURE.get(risk_cat, "BALANCED"))},
		"doctrine": doctrine_to_numeric(sel.get("doctrine", {}) as Dictionary),
		"missions": missions,
		"contingencies": [],
		"opponent_hypotheses": (sel.get("hypotheses", []) as Array).duplicate(true),
		"review_conditions": [{"trigger": "MISSION_BLOCKED", "params": {}}],
		"review_horizon_turns": clampi(int(sel.get("horizon", DEFAULT_HORIZON)), 1, 12),
		"source": "coordinator",
	}
	var checked := PlanCls.validate_plan(plan, {"turn": turn, "snapshot_id": snapshot, "plan_version": 1})
	if not bool(checked.get("ok", false)):
		return {"ok": false, "code": "COORD_EXPAND_" + str(checked.get("code", "PLAN_INVALID")),
			"detail": str(checked.get("detail", "")), "plan": {}, "warnings": warnings}
	return {"ok": true, "code": "", "detail": "", "plan": checked.get("plan", {}),
		"warnings": warnings, "choices": choices, "missions": _missions_summary(missions)}


## Expand an ADJUST review: baseline choices overlaid with validated changes.
## Groups missing from the current menu are dropped (+warning); new menu
## groups get the Godot default (+warning). Prior contingencies/hypotheses
## carry over unless the review supplies fresh hypotheses; prior doctrine
## carries over unless a doctrine override is supplied. Concept/effort stay.
static func expand_adjust(menu: Dictionary, baseline: Dictionary, changes: Array, turn: int, snapshot: String, mission: Dictionary, prior_plan: Dictionary, warn_in: Array = [], doctrine_override: Dictionary = {}, fresh_hypotheses: Array = [], has_fresh_hypotheses: bool = false) -> Dictionary:
	if str(menu.get("snapshot_id", "")) != snapshot:
		return {"ok": false, "code": "COORD_STALE_SNAPSHOT", "detail": "Menu snapshot does not match the frozen observation.", "plan": {}, "warnings": warn_in}
	var warnings: Array = warn_in.duplicate(true)
	var full: Dictionary = (baseline.get("choices", {}) as Dictionary).duplicate(true)
	for c_val in changes:
		if c_val is Dictionary:
			full[str((c_val as Dictionary).get("group", ""))] = str((c_val as Dictionary).get("choice", ""))
	var missions: Array = []
	var choices := {}
	var idx := 0
	for g_val in (menu.get("groups", []) as Array):
		if not g_val is Dictionary:
			continue
		var g: Dictionary = g_val
		var gid := str(g.get("id", ""))
		var cho := str(full.get(gid, ""))
		if cho.is_empty():
			cho = default_choice_id(g)
			warnings.append("DEFAULTED_GROUP %s reason=new-group choice=%s" % [gid, cho])
		var opt := find_option(menu, gid, cho)
		if opt.is_empty():
			cho = default_choice_id(g)
			warnings.append("DEFAULTED_GROUP %s reason=baseline-choice-gone choice=%s" % [gid, cho])
			opt = find_option(menu, gid, cho)
		if opt.is_empty():
			continue
		idx += 1
		missions.append(_mission_from_option(idx, g, opt))
		choices[gid] = cho
	for old_gid in full.keys():
		if not choices.has(str(old_gid)):
			warnings.append("DROPPED_BASELINE_GROUP %s reason=not-in-menu" % str(old_gid))
	if missions.is_empty():
		return {"ok": false, "code": "COORD_NO_ASSIGNMENTS", "detail": "No usable mission assignments after menu reconciliation.", "plan": {}, "warnings": warnings}
	var doctrine: Dictionary = (prior_plan.get("doctrine", {}) as Dictionary).duplicate(true)
	if doctrine.is_empty():
		doctrine = doctrine_to_numeric({})
	for k in doctrine_override.keys():
		var ks := str(k)
		if DOCTRINE_TABLE.has(ks):
			var want := str(doctrine_override[ks]).strip_edges().to_upper()
			var table: Dictionary = DOCTRINE_TABLE[ks]
			if table.has(want):
				doctrine[str(DOCTRINE_NUMERIC_KEYS[ks])] = float(table[want])
	var plan := {
		"plan_version": 1,
		"based_on_snapshot": snapshot,
		"created_turn": int(prior_plan.get("created_turn", turn)),
		"last_review_turn": turn,
		"mission": {"type": str(mission.get("type", "")), "objective": str(mission.get("objective", ""))},
		"concept": (prior_plan.get("concept", {}) as Dictionary).duplicate(true),
		"doctrine": doctrine,
		"missions": missions,
		"contingencies": (prior_plan.get("contingencies", []) as Array).duplicate(true),
		"opponent_hypotheses": fresh_hypotheses.duplicate(true) if has_fresh_hypotheses else (prior_plan.get("opponent_hypotheses", []) as Array).duplicate(true),
		"review_conditions": (prior_plan.get("review_conditions", []) as Array).duplicate(true),
		"review_horizon_turns": int(prior_plan.get("review_horizon_turns", DEFAULT_HORIZON)),
		"source": "coordinator",
	}
	var checked := PlanCls.validate_plan(plan, {"turn": turn, "snapshot_id": snapshot, "plan_version": 1})
	if not bool(checked.get("ok", false)):
		return {"ok": false, "code": "COORD_EXPAND_" + str(checked.get("code", "PLAN_INVALID")),
			"detail": str(checked.get("detail", "")), "plan": {}, "warnings": warnings}
	return {"ok": true, "code": "", "detail": "", "plan": checked.get("plan", {}),
		"warnings": warnings, "choices": choices, "missions": _missions_summary(missions)}


static func _mission_from_option(idx: int, group: Dictionary, slim: Dictionary) -> Dictionary:
	var opt := complete_option(str(group.get("family", "LINE")), slim)
	return {
		"mission_id": "M%02d" % idx,
		"task": str(opt.get("task", "")),
		"area": str(opt.get("area", "")),
		"assigned_units": (group.get("unit_ids", []) as Array).duplicate(true),
		"objective": (opt.get("objective", {}) as Dictionary).duplicate(true),
		"engagement": (opt.get("engagement", {}) as Dictionary).duplicate(true),
		"constraints": (opt.get("constraints", {}) as Dictionary).duplicate(true),
		"success_conditions": (opt.get("success_conditions", []) as Array).duplicate(true),
		"abort_conditions": (opt.get("abort_conditions", []) as Array).duplicate(true),
		"report_conditions": (opt.get("report_conditions", []) as Array).duplicate(true),
	}


static func _missions_summary(missions: Array) -> Array:
	var out: Array = []
	for m_val in missions:
		if m_val is Dictionary:
			var m: Dictionary = m_val
			out.append({"mission_id": str(m.get("mission_id", "")), "task": str(m.get("task", "")),
				"area": str(m.get("area", "")), "units": (m.get("assigned_units", []) as Array).size()})
	return out


# --- render helpers (Model View / panel; presentation only) -------------------

static func render_menu_text(menu: Dictionary) -> String:
	var lines: Array = []
	for g_val in (menu.get("groups", []) as Array):
		if not g_val is Dictionary:
			continue
		var g: Dictionary = g_val
		var opts: Array = []
		for o_val in (g.get("options", []) as Array):
			if o_val is Dictionary:
				opts.append("%s %s" % [str((o_val as Dictionary).get("id", "?")), str((o_val as Dictionary).get("label", "?"))])
		lines.append("%s [%s] %s (%s, %d men): %s" % [str(g.get("id", "?")), str(g.get("family", "?")),
			",".join(g.get("unit_ids", [])), ",".join(g.get("regions", [])), int(g.get("soldiers", 0)), " | ".join(opts)])
	return "\n".join(lines)


static func render_choices_text(choices: Dictionary) -> String:
	var parts: Array = []
	for gid in choices.keys():
		parts.append("%s->%s" % [str(gid), str(choices[gid])])
	parts.sort()
	return " ".join(parts)


static func render_missions_text(missions: Array) -> String:
	var parts: Array = []
	for m_val in missions:
		if m_val is Dictionary:
			var m: Dictionary = m_val
			parts.append("%s %s %s(%d)" % [str(m.get("mission_id", "?")), str(m.get("task", "?")),
				str(m.get("area", "?")), int(m.get("units", 0))])
	return " ".join(parts)
