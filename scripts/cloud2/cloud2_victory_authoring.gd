class_name Cloud2VictoryAuthoring
extends RefCounted

## VICTORY PLAN AUTHORING CONTRACT (live API repair V1).
##
## The canonical INTERNAL VictoryPlan stays rich (Cloud2VictoryPlan). But the
## API model must NOT serialize Godot-owned state: no statuses, clocks,
## revision/lineage bookkeeping, mission progress, or runtime metadata. The
## model authors STRATEGY in this compact contract; Godot expands it into the
## full canonical persistent VictoryPlan and validates the result through the
## SAME canonical validators (invalid authoring is rejected, never patched).
##
## Why: the 2026-09-23 live run proved the full-plan JSON does not survive a
## 6144-token output budget (provider-side truncation -> "Unterminated String"
## -> VP_INVALID_JSON, 6/6 attempts). The compact form cuts model output to
## roughly a third while preserving every strategically meaningful field.
##
## COMPACT INITIAL SHAPE (model writes):
##   {objective, end_state?, cadence?, doctrine? [6 numbers],
##    phases: [{id?, name?, purpose?, intent?, groups? {name: [unit ids]},
##      missions: [{task, area, units [RED ids], vs? class, target? unit id,
##        zone? area, hold_fire? bool, pursue? bool, preserve? bool,
##        spread? 0-9, win? [conds], stop? [conds]}],
##      entry?/win?/lose?/abort? [conds], next? "P2"|""|"-"|"END",
##      on_fail? HOLD|ADVANCE|EMERGENCY, reserve? [ids], release? [conds],
##      exploit?}, ...2..4 phases],
##    abort? [conds], branches? [{id?, if?, when, then?, note?}],
##    hypotheses? [{h, conf?, ev?}]}
## COMPACT CONDITION: a bare trigger name string, or {"when": TRIGGER,
##   + flat params (mission_id, fraction, region, threshold, class, turns,
##   since, unit_id, side, ratio)}. Unknown triggers reject.
##
## REVIEW SHAPES: KEEP / ADVANCE_PHASE stay tiny ({decision, reason?,
## next_phase_id?}). AMEND carries the full phase array in COMPACT form
## (expanded + history-checked canonically). EMERGENCY carries a compact
## full body. Review PACKETS likewise carry plan_authoring + plan_live
## (statuses/evaluated conditions) instead of the full canonical JSON.
##
## Godot expands/dedupes: phase ids (default P<n>), mission ids (M01.. in
## phase order), statuses/clocks, transitions, objectives, engagements,
## constraints, force_intent groups, reserve mirrors. Unit ids MUST be real
## roster ids from the packet (unknown ids reject: VA_UNKNOWN_UNIT).

const VictoryPlanCls = preload("res://scripts/cloud2/cloud2_victory_plan.gd")
const MissionCls = preload("res://scripts/cloud2/cloud2_mission.gd")

const AUTHORING_VERSION := "victory_author_v1"
## BRAIN→HAND A CONTRACT (frozen v1, see Drive "09 — Brain JSON Contract &
## SFT Corpus — Addendum"). Opt-in via env BRAIN_CONTRACT_MODE=unalloc_v1;
## unset = legacy V1 (Brain allocates units). In unalloc mode the Brain
## authors UNALLOCATED missions (task/area/intent/priority + existing
## optional fields), exactly UNALLOC_MISSIONS_PER_PHASE per phase, and every
## friendly-allocation field is rejected. Force allocation belongs to Hand A.
const CONTRACT_MODE_ENV := "BRAIN_CONTRACT_MODE"
const CONTRACT_UNALLOC := "unalloc_v1"
const UNALLOC_MISSIONS_PER_PHASE := 3  # temporary benchmarking value, not a permanent limit
const UNALLOC_FORBIDDEN_MISSION := ["units", "roles", "support", "coord"]
const UNALLOC_FORBIDDEN_PHASE := ["groups", "reserve", "release"]


static func unalloc_mode() -> bool:
	return OS.get_environment(CONTRACT_MODE_ENV).strip_edges().to_lower() == CONTRACT_UNALLOC


static func _present(v: Variant) -> bool:
	if v == null:
		return false
	if v is Array or v is Dictionary:
		return not v.is_empty()
	return not str(v).strip_edges().is_empty()
const MAX_PHASES := 4
const MAX_MISSIONS := 4
const MAX_TEXT := 160
const MAX_OBJECTIVE := 200
const MAX_BRANCHES := 3
const MAX_CONDS := 4

const DOCTRINE_KEYS := ["aggression", "risk_tolerance", "tempo", "pursuit", "reserve_discipline", "deception"]
const COND_PARAMS := ["mission_id", "fraction", "region", "threshold", "class", "turns", "since", "unit_id", "side", "ratio"]
const FAIL_ACTIONS := ["HOLD", "ADVANCE", "EMERGENCY"]
const THEN_ACTIONS := ["REQUEST_REVIEW", "HOLD_PHASE", "RELEASE_RESERVE", "NOTE_ONLY"]


static func _clip(v: Variant, n: int = MAX_TEXT) -> String:
	return str(v).strip_edges().left(n)


static func _upper(v: Variant, n: int = 48) -> String:
	return str(v).strip_edges().to_upper().left(n)


static func _num(v: Variant, fallback: float) -> float:
	if v is bool:
		return fallback
	if v is int or v is float:
		return float(v)
	return fallback


## True when a parsed response doc is compact authoring (vs legacy full
## canonical form). INITIAL: "objective" key. Phase arrays: missions carry
## "units" instead of canonical "assigned_units".
static func is_compact_doc(doc: Dictionary) -> bool:
	if doc.has("objective") and doc.get("phases") is Array:
		return true
	# Unalloc contract: compact missions carry no "units"; any phase array
	# without canonical "assigned_units" is compact authoring.
	if unalloc_mode() and doc.get("phases") is Array:
		return true
	if doc.get("phases") is Array:
		for p_val in (doc.get("phases") as Array):
			if p_val is Dictionary:
				for m_val in ((p_val as Dictionary).get("missions", []) as Array):
					if m_val is Dictionary and (m_val as Dictionary).has("units") \
							and not (m_val as Dictionary).has("assigned_units"):
						return true
	return false


## Parse + expand + canonically validate a compact INITIAL body.
## ctx: {"turn": int, "roster": [RED unit ids]}. Returns {ok, code, detail,
## plan (canonical body), authoring (normalized compact)}.
static func author_initial(doc: Variant, ctx: Dictionary = {}) -> Dictionary:
	if not doc is Dictionary:
		return {"ok": false, "code": "VA_SHAPE", "detail": "Authoring body must be an object.", "plan": {}}
	var d: Dictionary = doc
	var roster := {}
	for u in (ctx.get("roster", []) as Array):
		roster[str(u).strip_edges().to_upper()] = true
	var out := {"final_objective": _clip(d.get("objective", ""), MAX_OBJECTIVE)}
	if str(out["final_objective"]).is_empty():
		return {"ok": false, "code": "VA_OBJECTIVE", "detail": "Authoring needs an 'objective'.", "plan": {}}
	out["desired_end_state"] = _clip(d.get("end_state", ""), MAX_OBJECTIVE)
	out["review_horizon_turns"] = clampi(int(d.get("cadence", 4)), 1, 12)
	var dd := VictoryPlanCls.default_doctrine()
	if d.get("doctrine") is Array:
		var nums: Array = d.get("doctrine")
		for i in range(mini(nums.size(), DOCTRINE_KEYS.size())):
			dd[DOCTRINE_KEYS[i]] = clampf(_num(nums[i], float(dd[DOCTRINE_KEYS[i]])), 0.0, 1.0)
	out["doctrine"] = dd
	if not d.get("phases") is Array or (d.get("phases") as Array).is_empty():
		return {"ok": false, "code": "VA_PHASES", "detail": "Authoring needs a non-empty 'phases' array.", "plan": {}}
	if (d.get("phases") as Array).size() > MAX_PHASES:
		return {"ok": false, "code": "VA_PHASES", "detail": "Authoring allows at most %d phases." % MAX_PHASES, "plan": {}}
	var phases: Array = []
	var n := 0
	for p_val in (d.get("phases") as Array):
		n += 1
		var one := expand_phase(p_val, n, roster)
		if not bool(one.get("ok", false)):
			return {"ok": false, "code": str(one.get("code", "VA_PHASE")), "detail": str(one.get("detail", "")), "plan": {}}
		phases.append(one.get("phase", {}))
	out["phases"] = phases
	var aborts := expand_conds(d.get("abort", []), "plan abort")
	if not bool(aborts.get("ok", false)):
		return {"ok": false, "code": str(aborts.get("code", "VA_COND")), "detail": str(aborts.get("detail", "")), "plan": {}}
	out["plan_abort_conditions"] = aborts.get("conditions", [])
	var branches: Array = []
	if d.get("branches") is Array:
		if (d.get("branches") as Array).size() > MAX_BRANCHES:
			return {"ok": false, "code": "VA_BRANCHES", "detail": "Authoring allows at most %d branches." % MAX_BRANCHES, "plan": {}}
		var bn := 0
		for b_val in (d.get("branches") as Array):
			bn += 1
			var bone := expand_branch(b_val, bn)
			if not bool(bone.get("ok", false)):
				return {"ok": false, "code": str(bone.get("code", "VA_BRANCH")), "detail": str(bone.get("detail", "")), "plan": {}}
			branches.append(bone.get("branch", {}))
	out["branches"] = branches
	out["opponent_hypotheses"] = expand_hypotheses(d.get("hypotheses", []))
	out["source"] = "general"
	var checked := VictoryPlanCls.validate_plan(out, ctx)
	if not bool(checked.get("ok", false)):
		return {"ok": false, "code": str(checked.get("code", "VA_CANONICAL")),
			"detail": "Expanded plan rejected: " + str(checked.get("detail", "")), "plan": {}}
	return {"ok": true, "code": "", "detail": "", "plan": checked.get("plan", {}), "authoring": d}


## Expand one compact phase (Godot assigns ids/clocks/statuses).
static func expand_phase(p_val: Variant, seq: int, roster: Dictionary) -> Dictionary:
	if not p_val is Dictionary:
		return {"ok": false, "code": "VA_PHASE", "detail": "Phase #%d must be an object." % seq, "phase": {}}
	var p: Dictionary = p_val
	var pid := _upper(p.get("id", p.get("phase_id", "P%d" % seq)), 8)
	if pid.is_empty():
		pid = "P%d" % seq
	if unalloc_mode():
		for fk in UNALLOC_FORBIDDEN_PHASE:
			if _present(p.get(fk)):
				return {"ok": false, "code": "VA_UNALLOC_FIELD",
					"detail": "Phase %s: '%s' allocates friendly units; forbidden in %s (Hand A allocates)." % [pid, fk, CONTRACT_UNALLOC], "phase": {}}
		if not p.get("missions") is Array or (p.get("missions") as Array).size() != UNALLOC_MISSIONS_PER_PHASE:
			return {"ok": false, "code": "VA_MISSIONS",
				"detail": "Phase %s needs EXACTLY %d concurrent missions in %s." % [pid, UNALLOC_MISSIONS_PER_PHASE, CONTRACT_UNALLOC], "phase": {}}
	var groups := {}
	if p.get("groups") is Dictionary:
		for gname in ((p.get("groups") as Dictionary) as Dictionary).keys():
			var gunits: Array = []
			var raw_units: Variant = (p.get("groups") as Dictionary).get(gname, [])
			if raw_units is Array:
				for u in (raw_units as Array):
					var uid := str(u).strip_edges().to_upper()
					if uid.is_empty():
						continue
					if not roster.is_empty() and not roster.has(uid):
						return {"ok": false, "code": "VA_UNKNOWN_UNIT",
							"detail": "Phase %s group '%s' names unknown unit '%s'." % [pid, str(gname), uid], "phase": {}}
					if not uid in gunits:
						gunits.append(uid)
			gunits.sort()
			groups[str(gname).strip_edges().left(32)] = gunits
	if not p.get("missions") is Array or (p.get("missions") as Array).is_empty():
		return {"ok": false, "code": "VA_MISSIONS", "detail": "Phase %s needs at least one mission." % pid, "phase": {}}
	if (p.get("missions") as Array).size() > MAX_MISSIONS:
		return {"ok": false, "code": "VA_MISSIONS", "detail": "Phase %s allows at most %d missions." % [pid, MAX_MISSIONS], "phase": {}}
	var missions: Array = []
	var mn := 0
	for m_val in (p.get("missions") as Array):
		mn += 1
		var one := expand_mission(m_val, pid, mn, roster)
		if not bool(one.get("ok", false)):
			return {"ok": false, "code": str(one.get("code", "VA_MISSION")), "detail": str(one.get("detail", "")), "phase": {}}
		missions.append(one.get("mission", {}))
	var cond_sets := {}
	for pair in [["entry", "entry"], ["win", "success"], ["lose", "failure"], ["abort", "abort"]]:
		var ck: String = (pair as Array)[0]
		var expanded := expand_conds(p.get(ck, []), "Phase %s %s" % [pid, ck])
		if not bool(expanded.get("ok", false)):
			return {"ok": false, "code": str(expanded.get("code", "VA_COND")), "detail": str(expanded.get("detail", "")), "phase": {}}
		cond_sets[(pair as Array)[1]] = expanded.get("conditions", [])
	var next_raw := str(p.get("next", "")).strip_edges().to_upper()
	var on_fail := _upper(p.get("on_fail", "HOLD"), 16)
	if on_fail.is_empty():
		on_fail = "HOLD"
	if not on_fail in FAIL_ACTIONS:
		return {"ok": false, "code": "VA_TRANSITION", "detail": "Phase %s on_fail must be HOLD|ADVANCE|EMERGENCY." % pid, "phase": {}}
	var on_success := {"action": "ADVANCE", "next_phase_id": next_raw}
	if next_raw == "-" or next_raw == "HOLD":
		on_success = {"action": "HOLD_FOR_REVIEW", "next_phase_id": ""}
	elif next_raw == "END":
		on_success = {"action": "COMPLETE_PLAN", "next_phase_id": ""}
	var on_failure := {"action": "HOLD_FOR_REVIEW", "next_phase_id": ""}
	if on_fail == "ADVANCE":
		on_failure = {"action": "ADVANCE_ANYWAY", "next_phase_id": ""}
	elif on_fail == "EMERGENCY":
		on_failure = {"action": "REQUEST_EMERGENCY", "next_phase_id": ""}
	var hold: Array = []
	for h in (p.get("reserve", []) as Array):
		var hid := str(h).strip_edges().to_upper()
		if hid.is_empty():
			continue
		if not roster.is_empty() and not roster.has(hid):
			return {"ok": false, "code": "VA_UNKNOWN_UNIT", "detail": "Phase %s reserve names unknown unit '%s'." % [pid, hid], "phase": {}}
		if not hid in hold:
			hold.append(hid)
	hold.sort()
	var rel := expand_conds(p.get("release", []), "Phase %s release" % pid)
	if not bool(rel.get("ok", false)):
		return {"ok": false, "code": str(rel.get("code", "VA_COND")), "detail": str(rel.get("detail", "")), "phase": {}}
	var fgroups: Array = []
	for gk in groups.keys():
		fgroups.append({"name": gk, "units": groups[gk], "role": ""})
	return {"ok": true, "code": "", "detail": "", "phase": {
		"phase_id": pid,
		"name": _clip(p.get("name", pid)),
		"purpose": _clip(p.get("purpose", "")),
		"priority": clampi(int(p.get("priority", seq)), 1, 6),
		"force_intent": {"groups": fgroups, "reserve_hold": hold},
		"missions": missions,
		"entry_conditions": cond_sets["entry"],
		"success_conditions": cond_sets["success"],
		"failure_conditions": cond_sets["failure"],
		"abort_conditions": cond_sets["abort"],
		"transition": {"on_success": on_success, "on_failure": on_failure},
		"reserve_policy": {"hold": hold, "release_when": rel.get("conditions", []), "note": ""},
		"exploitation_intent": _clip(p.get("exploit", "")),
		"commander_intent": _clip(p.get("intent", ""), MAX_OBJECTIVE),
		"notes": "",
	}}


## Expand one compact mission. Mission ids are Godot-assigned (M01..) in
## phase order; statuses/clocks are Godot-owned and never authored.
static func expand_mission(m_val: Variant, pid: String, seq: int, roster: Dictionary) -> Dictionary:
	if not m_val is Dictionary:
		return {"ok": false, "code": "VA_MISSION", "detail": "Phase %s mission #%d must be an object." % [pid, seq], "mission": {}}
	var m: Dictionary = m_val
	# Liberation V1: task is an optional telemetry tag, not semantic law.
	# Missing/blank task defaults to EXECUTE (unfiltered); unknown tasks
	# still reject so typos surface instead of silently degrading.
	var task := _upper(m.get("task", ""), 24)
	if task.is_empty():
		task = "EXECUTE"
	if not task in MissionCls.TASKS:
		return {"ok": false, "code": "VA_MISSION_TASK", "detail": "Phase %s mission #%d unknown task '%s'." % [pid, seq, str(m.get("task", ""))], "mission": {}}
	var area := _upper(m.get("area", "ANY"), 16)
	if area.is_empty():
		area = "ANY"
	if not area in MissionCls.AREAS:
		return {"ok": false, "code": "VA_MISSION_AREA", "detail": "Phase %s mission #%d unknown area '%s'." % [pid, seq, str(m.get("area", ""))], "mission": {}}
	var units: Array = []
	if unalloc_mode():
		for fk in UNALLOC_FORBIDDEN_MISSION:
			if _present(m.get(fk)):
				return {"ok": false, "code": "VA_UNALLOC_FIELD",
					"detail": "Phase %s mission #%d: '%s' allocates friendly units; forbidden in %s (Hand A allocates)." % [pid, seq, fk, CONTRACT_UNALLOC], "mission": {}}
		if m.get("prefer") is Dictionary and _present((m.get("prefer") as Dictionary).get("units")):
			return {"ok": false, "code": "VA_UNALLOC_FIELD",
				"detail": "Phase %s mission #%d: 'prefer.units' names units; forbidden in %s." % [pid, seq, CONTRACT_UNALLOC], "mission": {}}
	elif not m.get("units") is Array:
		return {"ok": false, "code": "VA_MISSION_UNITS", "detail": "Phase %s mission #%d needs a 'units' array." % [pid, seq], "mission": {}}
	for u in (m.get("units") if m.get("units") is Array else []):
		var uid := str(u).strip_edges().to_upper()
		if uid.is_empty():
			continue
		if not roster.is_empty() and not roster.has(uid):
			return {"ok": false, "code": "VA_UNKNOWN_UNIT",
				"detail": "Phase %s mission #%d names unknown unit '%s' (use packet friendly_units ids)." % [pid, seq, uid], "mission": {}}
		if not uid in units:
			units.append(uid)
	units.sort()
	var objective := {"kind": "NONE"}
	var vs := _upper(m.get("vs", ""), 24)
	var target := _upper(m.get("target", ""), 24)
	var zone := _upper(m.get("zone", ""), 16)
	if not vs.is_empty():
		objective = {"kind": "FORMATION_CLASS", "class": vs}
	elif not target.is_empty():
		objective = {"kind": "ENEMY_FORMATION", "unit_id": target}
	elif not zone.is_empty():
		if not zone in MissionCls.AREAS:
			return {"ok": false, "code": "VA_MISSION_ZONE", "detail": "Phase %s mission #%d unknown zone '%s'." % [pid, seq, str(m.get("zone", ""))], "mission": {}}
		objective = {"kind": "REGION", "region": zone}
	var policy := "ATTACK_IF_ADVANTAGEOUS"
	if bool(m.get("hold_fire", false)):
		policy = "HOLD_FIRE"
	elif bool(m.get("pursue", false)):
		policy = "PURSUE_WEAKENED"
	var win := expand_conds(m.get("win", []), "Phase %s mission #%d win" % [pid, seq])
	if not bool(win.get("ok", false)):
		return {"ok": false, "code": str(win.get("code", "VA_COND")), "detail": str(win.get("detail", "")), "mission": {}}
	var stop := expand_conds(m.get("stop", []), "Phase %s mission #%d stop" % [pid, seq])
	if not bool(stop.get("ok", false)):
		return {"ok": false, "code": str(stop.get("code", "VA_COND")), "detail": str(stop.get("detail", "")), "mission": {}}
	var rich := expand_mission_rich(m, pid, seq, units, roster)
	if not bool(rich.get("ok", false)):
		return {"ok": false, "code": str(rich.get("code", "VA_RICH")), "detail": str(rich.get("detail", "")), "mission": {}}
	var mission := {
		"mission_id": "M%02d" % seq,
		"task": task,
		"area": area,
		"assigned_units": units,
		"objective": objective,
		"engagement": {"policy": policy},
		"constraints": {"preserve_force": bool(m.get("preserve", false)),
			"max_overextension": clampi(int(m.get("spread", 3)), 0, 9)},
		"success_conditions": win.get("conditions", []),
		"abort_conditions": stop.get("conditions", []),
		"report_conditions": [],
	}
	for rk in ((rich.get("rich", {}) as Dictionary) as Dictionary).keys():
		mission[rk] = (rich.get("rich", {}) as Dictionary)[rk]
	return {"ok": true, "code": "", "detail": "", "mission": mission}


## Expand optional rich intent (liberation V1). Compact keys: intent,
## effects[], priority, prefer{units,classes,areas}, roles{unit: text},
## coord, limits[], support[{from,to,kind}], tag. All optional, bounded;
## role/support ids must belong to this mission's units.
static func expand_mission_rich(m: Dictionary, pid: String, seq: int, units: Array, roster: Dictionary) -> Dictionary:
	var where := "Phase %s mission #%d" % [pid, seq]
	var effects: Array = []
	for e in (m.get("effects", []) if m.get("effects") is Array else []):
		var s := _clip(e, 160)
		if not s.is_empty() and not s in effects:
			effects.append(s)
		if effects.size() >= 4:
			break
	var pref: Dictionary = m.get("prefer", {}) as Dictionary if m.get("prefer") is Dictionary else {}
	var pref_units: Array = []
	for u in (pref.get("units", []) if pref.get("units") is Array else []):
		var uid := _upper(u, 24)
		if not uid.is_empty() and not uid in pref_units:
			pref_units.append(uid)
		if pref_units.size() >= 4:
			break
	var pref_classes: Array = []
	for c in (pref.get("classes", []) if pref.get("classes") is Array else []):
		var cc := _upper(c, 16)
		if not cc.is_empty() and not cc in pref_classes:
			pref_classes.append(cc)
		if pref_classes.size() >= 4:
			break
	var pref_areas: Array = []
	for a in (pref.get("areas", []) if pref.get("areas") is Array else []):
		var aa := _upper(a, 16)
		if aa in MissionCls.AREAS and not aa in pref_areas:
			pref_areas.append(aa)
		if pref_areas.size() >= 3:
			break
	var roles := {}
	if m.get("roles") is Dictionary:
		for k in ((m.get("roles", {}) as Dictionary) as Dictionary).keys():
			var rid := str(k).strip_edges().to_upper()
			if rid.is_empty() or (not units.is_empty() and not rid in units):
				return {"ok": false, "code": "VA_RICH_ROLE",
					"detail": "%s role names unit '%s' outside this mission." % [where, str(k)], "rich": {}}
			if not roster.is_empty() and not roster.has(rid):
				return {"ok": false, "code": "VA_UNKNOWN_UNIT",
					"detail": "%s role names unknown unit '%s'." % [where, rid], "rich": {}}
			var rs := _clip((m.get("roles", {}) as Dictionary)[k], 160)
			if not rs.is_empty():
				roles[rid] = rs
			if roles.size() >= 8:
				break
	var limits: Array = []
	for l in (m.get("limits", []) if m.get("limits") is Array else []):
		var ls := _clip(l, 160)
		if not ls.is_empty() and not ls in limits:
			limits.append(ls)
		if limits.size() >= 4:
			break
	var sup: Array = []
	for s_val in (m.get("support", []) if m.get("support") is Array else []):
		if not s_val is Dictionary:
			continue
		var sd: Dictionary = s_val
		var sfrom := _upper(sd.get("from", ""), 24)
		var sto := _upper(sd.get("to", ""), 24)
		if sfrom.is_empty() or sto.is_empty():
			continue
		if not units.is_empty() and (not sfrom in units or not sto in units):
			return {"ok": false, "code": "VA_RICH_SUPPORT",
				"detail": "%s support '%s->%s' leaves this mission." % [where, sfrom, sto], "rich": {}}
		sup.append({"from": sfrom, "to": sto, "kind": _clip(sd.get("kind", ""), 80)})
		if sup.size() >= 4:
			break
	return {"ok": true, "code": "", "detail": "", "rich": {
		"intent": _clip(m.get("intent", ""), 300),
		"priority": _clip(m.get("priority", ""), 160),
		"desired_effects": effects,
		"target_preferences": {"units": pref_units, "classes": pref_classes, "areas": pref_areas},
		"force_roles": roles,
		"coordination_intent": _clip(m.get("coord", ""), 300),
		"constraints_nl": limits,
		"support": sup,
		"telemetry_tag": _upper(m.get("tag", ""), 24),
	}}


## Expand a compact condition list: bare trigger strings or {"when":
## TRIGGER, + flat params}. Unknown triggers reject.
static func expand_conds(c_val: Variant, where: String) -> Dictionary:
	if c_val == null or (c_val is Array and (c_val as Array).is_empty()):
		return {"ok": true, "conditions": []}
	if c_val is String and str(c_val).strip_edges().to_upper() in MissionCls.TRIGGERS:
		return {"ok": true, "conditions": [{"trigger": str(c_val).strip_edges().to_upper(), "params": {}}]}
	if not c_val is Array:
		return {"ok": false, "code": "VA_COND", "detail": "%s: conditions must be an array." % where, "conditions": []}
	var out: Array = []
	for e_val in (c_val as Array):
		if e_val is String and str(e_val).strip_edges().to_upper() in MissionCls.TRIGGERS:
			out.append({"trigger": str(e_val).strip_edges().to_upper(), "params": {}})
			continue
		if not e_val is Dictionary:
			return {"ok": false, "code": "VA_COND", "detail": "%s: condition must be a trigger name or {when, ...}." % where, "conditions": []}
		var e: Dictionary = e_val
		var name := _upper(e.get("when", e.get("trigger", "")), 40)
		if not name in MissionCls.TRIGGERS:
			return {"ok": false, "code": "VA_COND", "detail": "%s: unknown trigger '%s'." % [where, str(e.get("when", e.get("trigger", "")))], "conditions": []}
		var params := {}
		for k in COND_PARAMS:
			if e.has(k):
				params[k] = e.get(k)
		out.append({"trigger": name, "params": params})
		if out.size() >= MAX_CONDS:
			break
	return {"ok": true, "conditions": out}


static func expand_branch(b_val: Variant, seq: int) -> Dictionary:
	if not b_val is Dictionary:
		return {"ok": false, "code": "VA_BRANCH", "detail": "Branch #%d must be an object." % seq, "branch": {}}
	var b: Dictionary = b_val
	var cond := expand_conds([b.get("when", {})] if (b.get("when") is Dictionary or b.get("when") is String) else [], "Branch #%d" % seq)
	if not bool(cond.get("ok", false)):
		return {"ok": false, "code": str(cond.get("code", "VA_COND")), "detail": str(cond.get("detail", "")), "branch": {}}
	var conds: Array = cond.get("conditions", [])
	if conds.is_empty():
		return {"ok": false, "code": "VA_BRANCH", "detail": "Branch #%d needs a 'when' condition." % seq, "branch": {}}
	var then := _upper(b.get("then", "REQUEST_REVIEW"), 24)
	if not then in THEN_ACTIONS:
		return {"ok": false, "code": "VA_BRANCH", "detail": "Branch #%d unknown response '%s'." % [seq, str(b.get("then", ""))], "branch": {}}
	return {"ok": true, "code": "", "detail": "", "branch": {
		"branch_id": _upper(b.get("id", b.get("branch_id", "B%d" % seq)), 16),
		"name": _clip(b.get("name", "")),
		"if_text": _clip(b.get("if", b.get("if_text", ""))),
		"condition": conds[0],
		"then": {"action": then, "note": _clip(b.get("note", ""))},
		"status": "ARMED",
	}}


static func expand_hypotheses(h_val: Variant) -> Array:
	var out: Array = []
	if not h_val is Array:
		return out
	for e_val in (h_val as Array):
		if not e_val is Dictionary:
			continue
		var e: Dictionary = e_val
		var hname := _clip(e.get("h", e.get("hypothesis", ""))).to_upper().left(64)
		if hname.is_empty():
			continue
		var ev: Array = []
		for x in (e.get("ev", e.get("evidence", [])) as Array):
			ev.append(_clip(x))
			if ev.size() >= 6:
				break
		out.append({"hypothesis": hname, "confidence": clampf(_num(e.get("conf", e.get("confidence", 0.5)), 0.5), 0.0, 1.0), "evidence": ev})
		if out.size() >= 4:
			break
	return out


## Expand a compact AMEND phase array (same per-phase rules as INITIAL).
## ctx: {"turn": int, "roster": []}. History checks run canonically later.
static func author_phases(arr: Variant, ctx: Dictionary = {}) -> Dictionary:
	if not arr is Array or (arr as Array).is_empty():
		return {"ok": false, "code": "VA_PHASES", "detail": "AMEND needs a non-empty compact 'phases' array.", "phases": []}
	if (arr as Array).size() > VictoryPlanCls.MAX_PHASES:
		return {"ok": false, "code": "VA_PHASES", "detail": "AMEND allows at most %d phases." % VictoryPlanCls.MAX_PHASES, "phases": []}
	var roster := {}
	for u in (ctx.get("roster", []) as Array):
		roster[str(u).strip_edges().to_upper()] = true
	var phases: Array = []
	var seen := {}
	var n := 0
	for p_val in (arr as Array):
		n += 1
		var one := expand_phase(p_val, n, roster)
		if not bool(one.get("ok", false)):
			return {"ok": false, "code": str(one.get("code", "VA_PHASE")), "detail": str(one.get("detail", "")), "phases": []}
		var ph: Dictionary = one.get("phase", {})
		# Canonical validator runs per phase for shape; clocks stay Godot-owned.
		var checked := VictoryPlanCls.validate_phase(ph)
		if not bool(checked.get("ok", false)):
			return {"ok": false, "code": str(checked.get("code", "VA_CANONICAL")),
				"detail": "Expanded phase rejected: " + str(checked.get("detail", "")), "phases": []}
		if seen.has(str(ph.get("phase_id", ""))):
			return {"ok": false, "code": "VA_PHASES", "detail": "Duplicate phase_id '%s'." % str(ph.get("phase_id", "")), "phases": []}
		seen[str(ph.get("phase_id", ""))] = true
		phases.append(checked.get("phase", {}))
	return {"ok": true, "code": "", "detail": "", "phases": phases}


## Compress a canonical VictoryPlan back to authoring form for slim review
## packets (the model re-authors from this; Godot clocks/statuses ride in
## the separate plan_live section, never in authoring). Returns {authoring,
## live_skeleton} — the caller fills evaluated truth into live_skeleton.
static func compress_plan(vp: Dictionary) -> Dictionary:
	var d: Dictionary = vp.get("doctrine", {})
	var doctr: Array = []
	for k in DOCTRINE_KEYS:
		doctr.append(float(d.get(k, 0.5)))
	var phases: Array = []
	for p_val in (vp.get("phases", []) as Array):
		if p_val is Dictionary:
			phases.append(compress_phase(p_val))
	var branches: Array = []
	for b_val in (vp.get("branches", []) as Array):
		if b_val is Dictionary:
			var b: Dictionary = b_val
			var bc: Dictionary = b.get("condition", {})
			branches.append({"id": str(b.get("branch_id", "?")), "name": str(b.get("name", "")),
				"if": str(b.get("if_text", "")), "when": compress_cond(bc),
				"then": str((b.get("then", {}) as Dictionary).get("action", "REQUEST_REVIEW")),
				"note": str((b.get("then", {}) as Dictionary).get("note", ""))})
	var hyps: Array = []
	for h_val in (vp.get("opponent_hypotheses", []) as Array):
		if h_val is Dictionary:
			var h: Dictionary = h_val
			hyps.append({"h": str(h.get("hypothesis", "")), "conf": float(h.get("confidence", 0.5)),
				"ev": (h.get("evidence", []) as Array).duplicate(true)})
	return {"authoring": {
		"objective": str(vp.get("final_objective", "")),
		"end_state": str(vp.get("desired_end_state", "")),
		"cadence": int(vp.get("review_horizon_turns", 4)),
		"doctrine": doctr,
		"phases": phases,
		"abort": compress_conds(vp.get("plan_abort_conditions", [])),
		"branches": branches,
		"hypotheses": hyps,
	}, "live_skeleton": {
		"revision": int(vp.get("revision", 0)),
		"lineage_id": str(vp.get("lineage_id", "")),
		"current_phase_id": str(vp.get("current_phase_id", "")),
	}}


static func compress_phase(ph: Dictionary) -> Dictionary:
	var groups := {}
	for g_val in ((ph.get("force_intent", {}) as Dictionary).get("groups", []) as Array):
		if g_val is Dictionary:
			groups[str((g_val as Dictionary).get("name", "?"))] = ((g_val as Dictionary).get("units", []) as Array).duplicate(true)
	var missions: Array = []
	for m_val in (ph.get("missions", []) as Array):
		if m_val is Dictionary:
			missions.append(compress_mission(m_val))
	var tr: Dictionary = ph.get("transition", {})
	var on_s: Dictionary = tr.get("on_success", {})
	var next := ""
	if str(on_s.get("action", "ADVANCE")) == "ADVANCE":
		next = str(on_s.get("next_phase_id", ""))
	elif str(on_s.get("action", "")) == "COMPLETE_PLAN":
		next = "END"
	else:
		next = "-"
	var on_fail := "HOLD"
	if str((tr.get("on_failure", {}) as Dictionary).get("action", "")) == "ADVANCE_ANYWAY":
		on_fail = "ADVANCE"
	elif str((tr.get("on_failure", {}) as Dictionary).get("action", "")) == "REQUEST_EMERGENCY":
		on_fail = "EMERGENCY"
	var rp: Dictionary = ph.get("reserve_policy", {})
	return {
		"id": str(ph.get("phase_id", "?")),
		"name": str(ph.get("name", "")),
		"purpose": str(ph.get("purpose", "")),
		"intent": str(ph.get("commander_intent", "")),
		"groups": groups,
		"missions": missions,
		"entry": compress_conds(ph.get("entry_conditions", [])),
		"win": compress_conds(ph.get("success_conditions", [])),
		"lose": compress_conds(ph.get("failure_conditions", [])),
		"abort": compress_conds(ph.get("abort_conditions", [])),
		"next": next,
		"on_fail": on_fail,
		"reserve": (rp.get("hold", []) as Array).duplicate(true),
		"release": compress_conds(rp.get("release_when", [])),
		"exploit": str(ph.get("exploitation_intent", "")),
	}


static func compress_mission(m: Dictionary) -> Dictionary:
	var out := {
		"task": str(m.get("task", "?")),
		"area": str(m.get("area", "?")),
		"units": (m.get("assigned_units", []) as Array).duplicate(true),
	}
	var o: Dictionary = m.get("objective", {})
	if str(o.get("kind", "NONE")) == "FORMATION_CLASS":
		out["vs"] = str(o.get("class", ""))
	elif str(o.get("kind", "NONE")) == "ENEMY_FORMATION":
		out["target"] = str(o.get("unit_id", ""))
	elif str(o.get("kind", "NONE")) == "REGION":
		out["zone"] = str(o.get("region", ""))
	var pol := str((m.get("engagement", {}) as Dictionary).get("policy", "ATTACK_IF_ADVANTAGEOUS"))
	if pol == "HOLD_FIRE":
		out["hold_fire"] = true
	elif pol == "PURSUE_WEAKENED":
		out["pursue"] = true
	if bool((m.get("constraints", {}) as Dictionary).get("preserve_force", false)):
		out["preserve"] = true
	var spread := int((m.get("constraints", {}) as Dictionary).get("max_overextension", 3))
	if spread != 3:
		out["spread"] = spread
	var win := compress_conds(m.get("success_conditions", []))
	if not win.is_empty():
		out["win"] = win
	var stop := compress_conds(m.get("abort_conditions", []))
	if not stop.is_empty():
		out["stop"] = stop
	# Liberation V1: rich intent rides review packets so KEEP/AMEND see it.
	if not str(m.get("intent", "")).is_empty():
		out["intent"] = str(m.get("intent", ""))
	if not str(m.get("priority", "")).is_empty():
		out["priority"] = str(m.get("priority", ""))
	if not (m.get("desired_effects", []) as Array).is_empty():
		out["effects"] = (m.get("desired_effects", []) as Array).duplicate(true)
	var tp: Dictionary = m.get("target_preferences", {}) as Dictionary if m.get("target_preferences") is Dictionary else {}
	if not (tp.get("units", []) as Array).is_empty() or not (tp.get("classes", []) as Array).is_empty() \
			or not (tp.get("areas", []) as Array).is_empty():
		out["prefer"] = tp.duplicate(true)
	if not (m.get("force_roles", {}) as Dictionary).is_empty():
		out["roles"] = (m.get("force_roles", {}) as Dictionary).duplicate(true)
	if not str(m.get("coordination_intent", "")).is_empty():
		out["coord"] = str(m.get("coordination_intent", ""))
	if not (m.get("constraints_nl", []) as Array).is_empty():
		out["limits"] = (m.get("constraints_nl", []) as Array).duplicate(true)
	if not (m.get("support", []) as Array).is_empty():
		out["support"] = (m.get("support", []) as Array).duplicate(true)
	if not str(m.get("telemetry_tag", "")).is_empty():
		out["tag"] = str(m.get("telemetry_tag", ""))
	return out


static func compress_conds(conds: Array) -> Array:
	var out: Array = []
	for c_val in conds:
		if c_val is Dictionary:
			out.append(compress_cond(c_val))
	return out


static func compress_cond(c: Dictionary) -> Dictionary:
	var out := {"when": str(c.get("trigger", "?"))}
	for k in COND_PARAMS:
		if (c.get("params", {}) as Dictionary).has(k):
			out[k] = (c.get("params", {}) as Dictionary).get(k)
	return out


## Serialized size comparison for the repair report: canonical full JSON
## chars vs compact authoring chars for the same plan.
static func size_report(vp: Dictionary) -> Dictionary:
	var comp := compress_plan(vp)
	var canon_chars := JSON.stringify(vp).length()
	var auth_chars := JSON.stringify(comp.get("authoring", {})).length()
	return {"canonical_chars": canon_chars, "authoring_chars": auth_chars,
		"ratio": float(auth_chars) / float(maxi(1, canon_chars))}
