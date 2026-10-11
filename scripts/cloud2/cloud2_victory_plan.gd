class_name Cloud2VictoryPlan
extends RefCounted

## VICTORY PLAN V0 — persistent long-horizon strategic memory (Godot-owned).
##
## One canonical VictoryPlan per battle: a multi-phase scheme the General
## authors at battle start and revises mid-battle (KEEP / ADVANCE_PHASE /
## AMEND_PLAN / EMERGENCY_REPLAN). Revisions never erase history: every
## adopted revision is appended to the battle-local revision list and the
## General audit trail.
##
## SEPARATION: the full VictoryPlan is STRATEGIC MEMORY. Only the ACTIVE
## phase derives operational missions into the execution layer (the existing
## StrategicPlan shape consumed by MissionControllers and Laya). Future
## phases stay PLANNED and inactive; past phases stay terminal history.
##
## PROSE vs OPERATIONAL (per-field contract — read before extending):
##   OPERATIONAL fields are consumed downstream by Godot code:
##     victory_plan_id / lineage_id / revision / current_phase_id,
##     final_objective (echoed to Laya + UI; terminal victory itself is
##       enforced by Godot battle rules, never by this text),
##     doctrine (MissionControllers read the 6 scalars),
##     review_horizon_turns (REVIEW CADENCE ONLY — turns between strategic
##       reviews; NOT a planning horizon; the plan itself spans the battle),
##     phases[].missions (active phase missions execute),
##     phases[].entry/success/failure/abort_conditions (evaluated by the
##       mission manager against authoritative state via the shared trigger
##       vocabulary; success/failure/abort propose reviews, never mutate),
##     phases[].transition (validates ADVANCE targets),
##     phases[].reserve_policy.release_when (evaluated; firing proposes a
##       RESERVE_RELEASE review — the General still decides the release),
##     phases[].force_intent units (validated known-or-dropped on reconcile;
##       reserve_hold advisory list is shown to Laya/UI but V0 coverage
##       still covers every unassigned ready formation),
##     plan_abort_conditions (evaluated; firing proposes VICTORY_ABORT review),
##     branches[].condition (evaluated while ARMED; firing marks TRIGGERED
##       and proposes a BRANCH_CONDITION review — V0 branches never
##       auto-mutate force; the General decides the response).
##   EXPLANATORY fields exist for the developer / the General's own
##   continuity and are NEVER executed: desired_end_state, phases[].purpose
##   (shown to Laya as advisory context, not a hard constraint),
##   phases[].commander_intent (same), exploitation_intent, notes,
##   branches[].if_text / then.note, revision notes, hypotheses prose.
##
## Pure data + validation. No network, no game truth, no mutation of live
## state. Condition *evaluation* lives in the mission manager (it owns the
## baselines); this file validates shapes and computes revisions/diffs.

const MissionCls = preload("res://scripts/cloud2/cloud2_mission.gd")

const PLAN_FORMAT := "victory_plan_v1"
const VP_VERSION := 1
const MAX_TEXT := 280
const MAX_PHASES := 6
const MAX_MISSIONS_PER_PHASE := 8
const MAX_BRANCHES := 4
const MAX_CONDITIONS := 6
const MAX_REVISIONS := 12
const MAX_AUDIT := 64

const PHASE_STATUSES := ["PLANNED", "ACTIVE", "COMPLETED", "FAILED", "ABORTED"]
const TERMINAL_PHASE_STATUSES := ["COMPLETED", "FAILED", "ABORTED"]
const DECISIONS := ["KEEP", "ADVANCE_PHASE", "AMEND_PLAN", "EMERGENCY_REPLAN"]
const SUCCESS_ACTIONS := ["ADVANCE", "COMPLETE_PLAN", "HOLD_FOR_REVIEW"]
const FAILURE_ACTIONS := ["HOLD_FOR_REVIEW", "ADVANCE_ANYWAY", "REQUEST_EMERGENCY"]
const BRANCH_ACTIONS := ["REQUEST_REVIEW", "HOLD_PHASE", "RELEASE_RESERVE", "NOTE_ONLY"]
const BRANCH_STATUSES := ["ARMED", "TRIGGERED", "SPENT", "STALE"]

const DEFAULT_REVIEW_HORIZON := 4

const DEFAULT_DOCTRINE := {
	"aggression": 0.5,
	"risk_tolerance": 0.5,
	"tempo": 0.5,
	"pursuit": 0.5,
	"reserve_discipline": 0.6,
	"deception": 0.2,
}
const DOCTRINE_KEYS := ["aggression", "risk_tolerance", "tempo", "pursuit", "reserve_discipline", "deception"]


static func default_doctrine() -> Dictionary:
	return DEFAULT_DOCTRINE.duplicate(true)


static func _clip(v: Variant) -> String:
	var s := str(v).strip_edges()
	if s.length() > MAX_TEXT:
		return s.left(MAX_TEXT)
	return s


static func _clamp01(v: Variant, fallback: float) -> float:
	if v is bool:
		return fallback
	if v is int or v is float:
		return clampf(float(v), 0.0, 1.0)
	return fallback


static func _upper(v: Variant, max_len: int = 64) -> String:
	return str(v).strip_edges().to_upper().left(max_len)


static func _phase_id_ok(pid: String) -> bool:
	var p := pid.strip_edges().to_upper()
	if p.length() < 2 or p.length() > 3 or not p.begins_with("P"):
		return false
	for i in range(1, p.length()):
		if p[i] < "0" or p[i] > "9":
			return false
	return true


static func empty_plan() -> Dictionary:
	return {
		"plan_format": PLAN_FORMAT,
		"victory_plan_id": "",
		"lineage_id": "",
		"revision": 0,
		"parent_revision": 0,
		"created_turn": 0,
		"last_revised_turn": 0,
		"last_review_turn": 0,
		"final_objective": "",
		"desired_end_state": "",
		"doctrine": default_doctrine(),
		"review_horizon_turns": DEFAULT_REVIEW_HORIZON,
		"current_phase_id": "",
		"phases": [],
		"plan_abort_conditions": [],
		"branches": [],
		"opponent_hypotheses": [],
		"source": "none",
		"revision_note": "",
	}


static func has_plan(vp: Dictionary) -> bool:
	if vp.is_empty():
		return false
	if str(vp.get("plan_format", "")) != PLAN_FORMAT:
		return false
	return int(vp.get("revision", 0)) > 0 and not (vp.get("phases", []) as Array).is_empty()


static func phase_by_id(vp: Dictionary, phase_id: String) -> Dictionary:
	var want := phase_id.strip_edges().to_upper()
	for p_val in (vp.get("phases", []) as Array):
		if p_val is Dictionary and str((p_val as Dictionary).get("phase_id", "")) == want:
			return p_val
	return {}


static func phase_index(vp: Dictionary, phase_id: String) -> int:
	var want := phase_id.strip_edges().to_upper()
	var phases: Array = vp.get("phases", [])
	for i in range(phases.size()):
		if phases[i] is Dictionary and str((phases[i] as Dictionary).get("phase_id", "")) == want:
			return i
	return -1


static func active_phase(vp: Dictionary) -> Dictionary:
	return phase_by_id(vp, str(vp.get("current_phase_id", "")))


static func next_phase_id(vp: Dictionary, from_id: String = "") -> String:
	var phases: Array = vp.get("phases", [])
	if phases.is_empty():
		return ""
	var base := from_id.strip_edges().to_upper()
	if base.is_empty():
		base = str(vp.get("current_phase_id", "")).strip_edges().to_upper()
	var idx := phase_index(vp, base)
	if idx < 0:
		return ""
	if idx + 1 < phases.size() and (phases[idx + 1] as Dictionary) != {}:
		return str((phases[idx + 1] as Dictionary).get("phase_id", ""))
	return ""


static func default_transition() -> Dictionary:
	return {
		"on_success": {"action": "ADVANCE", "next_phase_id": ""},
		"on_failure": {"action": "HOLD_FOR_REVIEW", "next_phase_id": ""},
	}


static func default_phase(phase_id: String) -> Dictionary:
	return {
		"phase_id": phase_id.strip_edges().to_upper(),
		"name": "",
		"purpose": "",
		"priority": 1,
		"status": "PLANNED",
		"status_turn": 0,
		"status_reason": "",
		"force_intent": {"groups": [], "reserve_hold": []},
		"missions": [],
		"entry_conditions": [],
		"success_conditions": [],
		"failure_conditions": [],
		"abort_conditions": [],
		"transition": default_transition(),
		"reserve_policy": {"hold": [], "release_when": [], "note": ""},
		"exploitation_intent": "",
		"commander_intent": "",
		"notes": "",
	}


## Validate + canonicalize a full VictoryPlan from untrusted input.
## ctx: {"turn": int, "snapshot_id": String}. Godot-owned identity fields
## (victory_plan_id / lineage_id / revision / parent_revision / status
## clocks) are accepted as echoes but REASSIGNED by the manager on adopt;
## lifecycle transitions (ADVANCE/AMEND/EMERGENCY) are enforced there, not
## here. Returns {ok, code, detail, plan}.
static func validate_plan(p_val: Variant, ctx: Dictionary = {}) -> Dictionary:
	if not p_val is Dictionary:
		return {"ok": false, "code": "VP_SHAPE", "detail": "VictoryPlan must be an object.", "plan": {}}
	var p: Dictionary = p_val
	var turn := int(ctx.get("turn", 0))
	var out := empty_plan()
	out["final_objective"] = _clip(p.get("final_objective", ""))
	if (out["final_objective"] as String).is_empty():
		return {"ok": false, "code": "VP_OBJECTIVE", "detail": "VictoryPlan needs a final_objective.", "plan": {}}
	out["desired_end_state"] = _clip(p.get("desired_end_state", ""))
	if p.get("doctrine") is Dictionary:
		var dd := default_doctrine()
		for k in DOCTRINE_KEYS:
			if (p.get("doctrine") as Dictionary).has(k):
				dd[k] = _clamp01((p.get("doctrine") as Dictionary).get(k), float(DEFAULT_DOCTRINE[k]))
		out["doctrine"] = dd
	out["review_horizon_turns"] = clampi(int(p.get("review_horizon_turns", DEFAULT_REVIEW_HORIZON)), 1, 12)
	if not p.get("phases") is Array or (p.get("phases") as Array).is_empty():
		return {"ok": false, "code": "VP_PHASES", "detail": "VictoryPlan needs at least one phase.", "plan": {}}
	var phases: Array = []
	var seen := {}
	for ph_val in (p.get("phases") as Array):
		var one := validate_phase(ph_val)
		if not bool(one.get("ok", false)):
			return {"ok": false, "code": str(one.get("code", "VP_PHASE")), "detail": str(one.get("detail", "")), "plan": {}}
		var ph: Dictionary = one.get("phase", {})
		var pid := str(ph.get("phase_id", ""))
		if seen.has(pid):
			return {"ok": false, "code": "VP_DUP_PHASE", "detail": "Duplicate phase_id '%s'." % pid, "plan": {}}
		seen[pid] = true
		phases.append(ph)
		if phases.size() >= MAX_PHASES:
			break
	out["phases"] = phases
	var aborts := MissionCls._validate_conditions(p.get("plan_abort_conditions", []))
	if not bool(aborts.get("ok", false)):
		return {"ok": false, "code": "VP_ABORT", "detail": "plan_abort_conditions: " + str(aborts.get("detail", "")), "plan": {}}
	out["plan_abort_conditions"] = (aborts.get("conditions", []) as Array).slice(0, MAX_CONDITIONS)
	var branches: Array = []
	if p.get("branches") is Array:
		for b_val in (p.get("branches") as Array):
			var bone := validate_branch(b_val)
			if not bool(bone.get("ok", false)):
				return {"ok": false, "code": str(bone.get("code", "VP_BRANCH")), "detail": str(bone.get("detail", "")), "plan": {}}
			branches.append(bone.get("branch", {}))
			if branches.size() >= MAX_BRANCHES:
				break
	out["branches"] = branches
	var hyps := _validate_hypotheses(p.get("opponent_hypotheses", []))
	if not bool(hyps.get("ok", false)):
		return {"ok": false, "code": str(hyps.get("code", "VP_HYPOTHESES")), "detail": str(hyps.get("detail", "")), "plan": {}}
	out["opponent_hypotheses"] = hyps.get("hypotheses", [])
	out["source"] = _clip(p.get("source", "general")).left(32)
	if str(out["source"]).is_empty():
		out["source"] = "general"
	out["revision_note"] = _clip(p.get("revision_note", p.get("notes", "")))
	# Echoes (reassigned on adopt; validated for shape only).
	out["victory_plan_id"] = _upper(p.get("victory_plan_id", ""), 48)
	out["lineage_id"] = _upper(p.get("lineage_id", ""), 48)
	out["revision"] = maxi(0, int(p.get("revision", 0)))
	out["parent_revision"] = maxi(0, int(p.get("parent_revision", 0)))
	out["created_turn"] = int(p.get("created_turn", turn))
	out["last_revised_turn"] = int(p.get("last_revised_turn", turn))
	out["last_review_turn"] = int(p.get("last_review_turn", turn))
	var want_current := _upper(p.get("current_phase_id", (phases[0] as Dictionary).get("phase_id", "")), 8)
	if phase_by_id(out, want_current).is_empty():
		return {"ok": false, "code": "VP_CURRENT", "detail": "current_phase_id '%s' names no phase." % want_current, "plan": {}}
	out["current_phase_id"] = want_current
	return {"ok": true, "code": "", "detail": "", "plan": out}


## Validate + canonicalize one phase. Mission entries use the canonical
## Cloud2Mission validator (same operational mission layer as V0 strategic
## plans). Godot-owned status clocks are shape-checked only.
static func validate_phase(ph_val: Variant) -> Dictionary:
	if not ph_val is Dictionary:
		return {"ok": false, "code": "VP_PHASE_SHAPE", "detail": "Phase must be an object.", "phase": {}}
	var ph: Dictionary = ph_val
	var pid := _upper(ph.get("phase_id", ""), 8)
	if not _phase_id_ok(pid):
		return {"ok": false, "code": "VP_PHASE_ID", "detail": "Phase needs a phase_id like P1..P6.", "phase": {}}
	var out := default_phase(pid)
	out["name"] = _clip(ph.get("name", pid))
	out["purpose"] = _clip(ph.get("purpose", ""))
	out["priority"] = clampi(int(ph.get("priority", 1)), 1, MAX_PHASES)
	var st := _upper(ph.get("status", "PLANNED"), 16)
	out["status"] = st if st in PHASE_STATUSES else "PLANNED"
	out["status_turn"] = maxi(0, int(ph.get("status_turn", 0)))
	out["status_reason"] = _upper(ph.get("status_reason", ""), 48)
	var fi := _validate_force_intent(ph.get("force_intent", {}))
	if not bool(fi.get("ok", false)):
		return {"ok": false, "code": str(fi.get("code", "VP_FORCE")), "detail": "Phase %s force_intent: %s" % [pid, str(fi.get("detail", ""))], "phase": {}}
	out["force_intent"] = fi.get("force_intent", {})
	if not ph.get("missions") is Array or (ph.get("missions") as Array).is_empty():
		return {"ok": false, "code": "VP_PHASE_MISSIONS", "detail": "Phase %s needs at least one mission." % pid, "phase": {}}
	var missions: Array = []
	var seen := {}
	for m_val in (ph.get("missions") as Array):
		var one := MissionCls.validate_mission(m_val)
		if not bool(one.get("ok", false)):
			return {"ok": false, "code": str(one.get("code", "VP_MISSION")), "detail": "Phase %s: %s" % [pid, str(one.get("detail", ""))], "phase": {}}
		var m: Dictionary = one.get("mission", {})
		var mid := str(m.get("mission_id", ""))
		if seen.has(mid):
			return {"ok": false, "code": "VP_DUP_MISSION", "detail": "Phase %s duplicate mission_id '%s'." % [pid, mid], "phase": {}}
		seen[mid] = true
		missions.append(m)
		if missions.size() >= MAX_MISSIONS_PER_PHASE:
			break
	out["missions"] = missions
	for key in ["entry_conditions", "success_conditions", "failure_conditions", "abort_conditions"]:
		var conds := MissionCls._validate_conditions(ph.get(key, []))
		if not bool(conds.get("ok", false)):
			return {"ok": false, "code": "VP_CONDITION", "detail": "Phase %s %s: %s" % [pid, key, str(conds.get("detail", ""))], "phase": {}}
		out[key] = (conds.get("conditions", []) as Array).slice(0, MAX_CONDITIONS)
	var tr := _validate_transition(ph.get("transition", {}), pid)
	if not bool(tr.get("ok", false)):
		return {"ok": false, "code": str(tr.get("code", "VP_TRANSITION")), "detail": "Phase %s: %s" % [pid, str(tr.get("detail", ""))], "phase": {}}
	out["transition"] = tr.get("transition", default_transition())
	var rp := _validate_reserve_policy(ph.get("reserve_policy", {}))
	if not bool(rp.get("ok", false)):
		return {"ok": false, "code": str(rp.get("code", "VP_RESERVE")), "detail": "Phase %s: %s" % [pid, str(rp.get("detail", ""))], "phase": {}}
	out["reserve_policy"] = rp.get("reserve_policy", {"hold": [], "release_when": [], "note": ""})
	out["exploitation_intent"] = _clip(ph.get("exploitation_intent", ""))
	out["commander_intent"] = _clip(ph.get("commander_intent", ""))
	out["notes"] = _clip(ph.get("notes", ""))
	return {"ok": true, "code": "", "detail": "", "phase": out}


static func _validate_force_intent(f_val: Variant) -> Dictionary:
	if f_val == null or (f_val is Dictionary and (f_val as Dictionary).is_empty()):
		return {"ok": true, "force_intent": {"groups": [], "reserve_hold": []}}
	if not f_val is Dictionary:
		return {"ok": false, "code": "VP_FORCE", "detail": "force_intent must be an object."}
	var f: Dictionary = f_val
	var groups: Array = []
	if f.get("groups") is Array:
		for g_val in (f.get("groups") as Array):
			if not g_val is Dictionary:
				return {"ok": false, "code": "VP_FORCE", "detail": "force group must be an object."}
			var g: Dictionary = g_val
			var units: Array = []
			if g.get("units") is Array:
				for u in (g.get("units") as Array):
					var uid := str(u).strip_edges().to_upper()
					if not uid.is_empty() and not uid in units:
						units.append(uid)
			units.sort()
			groups.append({"name": _clip(g.get("name", "")).left(48), "units": units,
				"role": _clip(g.get("role", ""))})
			if groups.size() >= MAX_MISSIONS_PER_PHASE:
				break
	var hold: Array = []
	if f.get("reserve_hold") is Array:
		for h in (f.get("reserve_hold") as Array):
			var hid := str(h).strip_edges().to_upper()
			if not hid.is_empty() and not hid in hold:
				hold.append(hid)
	hold.sort()
	return {"ok": true, "force_intent": {"groups": groups, "reserve_hold": hold}}


static func _validate_transition(t_val: Variant, pid: String) -> Dictionary:
	if t_val == null or (t_val is Dictionary and (t_val as Dictionary).is_empty()):
		return {"ok": true, "transition": default_transition()}
	if not t_val is Dictionary:
		return {"ok": false, "code": "VP_TRANSITION", "detail": "transition must be an object."}
	var t: Dictionary = t_val
	var out := default_transition()
	if t.get("on_success") is Dictionary:
		var s: Dictionary = t.get("on_success")
		var act := _upper(s.get("action", "ADVANCE"), 24)
		if not act in SUCCESS_ACTIONS:
			return {"ok": false, "code": "VP_TRANSITION", "detail": "Phase %s unknown on_success action '%s'." % [pid, str(s.get("action", ""))]}
		var nxt := _upper(s.get("next_phase_id", ""), 8)
		if not nxt.is_empty() and not _phase_id_ok(nxt):
			return {"ok": false, "code": "VP_TRANSITION", "detail": "Phase %s bad on_success next_phase_id." % pid}
		out["on_success"] = {"action": act, "next_phase_id": nxt}
	if t.get("on_failure") is Dictionary:
		var fl: Dictionary = t.get("on_failure")
		var fact := _upper(fl.get("action", "HOLD_FOR_REVIEW"), 24)
		if not fact in FAILURE_ACTIONS:
			return {"ok": false, "code": "VP_TRANSITION", "detail": "Phase %s unknown on_failure action '%s'." % [pid, str(fl.get("action", ""))]}
		var fnxt := _upper(fl.get("next_phase_id", ""), 8)
		if not fnxt.is_empty() and not _phase_id_ok(fnxt):
			return {"ok": false, "code": "VP_TRANSITION", "detail": "Phase %s bad on_failure next_phase_id." % pid}
		out["on_failure"] = {"action": fact, "next_phase_id": fnxt}
	return {"ok": true, "transition": out}


static func _validate_reserve_policy(r_val: Variant) -> Dictionary:
	if r_val == null or (r_val is Dictionary and (r_val as Dictionary).is_empty()):
		return {"ok": true, "reserve_policy": {"hold": [], "release_when": [], "note": ""}}
	if not r_val is Dictionary:
		return {"ok": false, "code": "VP_RESERVE", "detail": "reserve_policy must be an object."}
	var r: Dictionary = r_val
	var hold: Array = []
	if r.get("hold") is Array:
		for h in (r.get("hold") as Array):
			var hid := str(h).strip_edges().to_upper()
			if not hid.is_empty() and not hid in hold:
				hold.append(hid)
	hold.sort()
	var rel := MissionCls._validate_conditions(r.get("release_when", []))
	if not bool(rel.get("ok", false)):
		return {"ok": false, "code": "VP_RESERVE", "detail": "release_when: " + str(rel.get("detail", ""))}
	return {"ok": true, "reserve_policy": {"hold": hold,
		"release_when": (rel.get("conditions", []) as Array).slice(0, MAX_CONDITIONS),
		"note": _clip(r.get("note", ""))}}


## Bounded branch: one trigger condition + one bounded response. V0
## branches propose reviews; they never auto-mutate force (see header).
static func validate_branch(b_val: Variant) -> Dictionary:
	if not b_val is Dictionary:
		return {"ok": false, "code": "VP_BRANCH_SHAPE", "detail": "Branch must be an object.", "branch": {}}
	var b: Dictionary = b_val
	var bid := _upper(b.get("branch_id", ""), 16)
	if bid.is_empty():
		return {"ok": false, "code": "VP_BRANCH_ID", "detail": "Branch needs a branch_id.", "branch": {}}
	var rel := MissionCls._validate_conditions([b.get("condition", {})] if b.get("condition") is Dictionary else b.get("conditions", []))
	if not bool(rel.get("ok", false)):
		return {"ok": false, "code": "VP_BRANCH_COND", "detail": "Branch %s: %s" % [bid, str(rel.get("detail", ""))], "branch": {}}
	var conds: Array = rel.get("conditions", [])
	if conds.is_empty():
		return {"ok": false, "code": "VP_BRANCH_COND", "detail": "Branch %s needs a condition." % bid, "branch": {}}
	var then: Dictionary = b.get("then", {}) if b.get("then") is Dictionary else {}
	var act := _upper(then.get("action", "REQUEST_REVIEW"), 24)
	if not act in BRANCH_ACTIONS:
		return {"ok": false, "code": "VP_BRANCH_ACTION", "detail": "Branch %s unknown action '%s'." % [bid, str(then.get("action", ""))], "branch": {}}
	var bst := _upper(b.get("status", "ARMED"), 16)
	return {"ok": true, "code": "", "detail": "", "branch": {
		"branch_id": bid,
		"name": _clip(b.get("name", bid)),
		"if_text": _clip(b.get("if_text", b.get("if", ""))),
		"condition": (conds[0] as Dictionary).duplicate(true),
		"then": {"action": act, "note": _clip(then.get("note", ""))},
		"status": bst if bst in BRANCH_STATUSES else "ARMED",
	}}


static func _validate_hypotheses(h_val: Variant) -> Dictionary:
	if h_val == null or (h_val is Array and (h_val as Array).is_empty()):
		return {"ok": true, "hypotheses": []}
	if not h_val is Array:
		return {"ok": false, "code": "VP_HYPOTHESES", "detail": "opponent_hypotheses must be an array."}
	var out: Array = []
	for e_val in (h_val as Array):
		if not e_val is Dictionary:
			return {"ok": false, "code": "VP_HYPOTHESES", "detail": "Hypothesis must be an object."}
		var e: Dictionary = e_val
		var hname := _clip(e.get("hypothesis", "")).to_upper().left(64)
		if hname.is_empty():
			return {"ok": false, "code": "VP_HYPOTHESES", "detail": "Hypothesis needs a name."}
		var ev: Array = []
		if e.get("evidence") is Array:
			for x in (e.get("evidence") as Array):
				ev.append(_clip(x).left(160))
				if ev.size() >= 6:
					break
		out.append({"hypothesis": hname, "confidence": _clamp01(e.get("confidence", 0.5), 0.5), "evidence": ev})
		if out.size() >= 4:
			break
	return {"ok": true, "hypotheses": out}


## Godot-wins reconciliation: drop assigned units that are dead/unknown in
## the authoritative observation from every phase's missions, force-intent
## groups, and reserve lists. Phase statuses are Godot-owned and never
## changed here. Returns {plan, corrections}.
static func reconcile(vp: Dictionary, obs: Dictionary) -> Dictionary:
	var live := {}
	for u_val in (obs.get("friendly_units", []) as Array):
		if u_val is Dictionary:
			live[str((u_val as Dictionary).get("unit_id", "")).strip_edges().to_upper()] = true
	var corrections: Array = []
	var out: Dictionary = vp.duplicate(true)
	for p_val in (out.get("phases", []) as Array):
		if not p_val is Dictionary:
			continue
		var ph: Dictionary = p_val
		var pid := str(ph.get("phase_id", "?"))
		for m_val in (ph.get("missions", []) as Array):
			if not m_val is Dictionary:
				continue
			var m: Dictionary = m_val
			var kept: Array = []
			for u in (m.get("assigned_units", []) as Array):
				var uid := str(u).strip_edges().to_upper()
				if live.has(uid):
					kept.append(uid)
				else:
					corrections.append("drop %s from %s/%s (not in Godot state)" % [uid, pid, str(m.get("mission_id", "?"))])
			kept.sort()
			m["assigned_units"] = kept
		var fi: Dictionary = ph.get("force_intent", {})
		for g_val in (fi.get("groups", []) as Array):
			if not g_val is Dictionary:
				continue
			var g: Dictionary = g_val
			var gkept: Array = []
			for u2 in (g.get("units", []) as Array):
				if live.has(str(u2).strip_edges().to_upper()):
					gkept.append(str(u2).strip_edges().to_upper())
			g["units"] = gkept
		var hkept: Array = []
		for h in (fi.get("reserve_hold", []) as Array):
			if live.has(str(h).strip_edges().to_upper()):
				hkept.append(str(h).strip_edges().to_upper())
		fi["reserve_hold"] = hkept
		var rp: Dictionary = ph.get("reserve_policy", {})
		var rkept: Array = []
		for h2 in (rp.get("hold", []) as Array):
			if live.has(str(h2).strip_edges().to_upper()):
				rkept.append(str(h2).strip_edges().to_upper())
		rp["hold"] = rkept
	return {"plan": out, "corrections": corrections}


## ADVANCE_PHASE: same lineage, current phase closes with the given
## disposition (COMPLETED/FAILED — decided by the manager from evaluated
## conditions), target becomes ACTIVE. target_id "" resolves via the
## current phase transition, else next in sequence.
static func advance_phase(vp: Dictionary, target_id: String, disposition: String, turn: int, reason: String) -> Dictionary:
	if not has_plan(vp):
		return {"ok": false, "code": "VP_NO_PLAN", "detail": "No VictoryPlan to advance.", "plan": {}}
	var cur := active_phase(vp)
	if cur.is_empty():
		return {"ok": false, "code": "VP_NO_ACTIVE", "detail": "VictoryPlan has no active phase.", "plan": {}}
	var disp := disposition.strip_edges().to_upper()
	if disp != "COMPLETED" and disp != "FAILED":
		return {"ok": false, "code": "VP_DISPOSITION", "detail": "Disposition must be COMPLETED or FAILED.", "plan": {}}
	var want := target_id.strip_edges().to_upper()
	if want.is_empty():
		var tr: Dictionary = cur.get("transition", {})
		var on: Dictionary = tr.get("on_success" if disp == "COMPLETED" else "on_failure", {})
		want = str((on as Dictionary).get("next_phase_id", "")).strip_edges().to_upper()
	if want.is_empty():
		want = next_phase_id(vp)
	if want.is_empty():
		return {"ok": false, "code": "VP_NO_NEXT", "detail": "Phase %s is the last phase; nothing to advance to." % str(cur.get("phase_id", "?")), "plan": {}}
	var nxt := phase_by_id(vp, want)
	if nxt.is_empty():
		return {"ok": false, "code": "VP_UNKNOWN_PHASE", "detail": "Target phase '%s' does not exist." % want, "plan": {}}
	if str(nxt.get("status", "")) != "PLANNED":
		return {"ok": false, "code": "VP_TARGET_STATE", "detail": "Target phase '%s' is %s, not PLANNED." % [want, str(nxt.get("status", "?"))], "plan": {}}
	var out: Dictionary = vp.duplicate(true)
	var cur2 := phase_by_id(out, str(cur.get("phase_id", "")))
	cur2["status"] = disp
	cur2["status_turn"] = turn
	cur2["status_reason"] = _upper(reason, 48) if not reason.strip_edges().is_empty() else ("SUCCESS" if disp == "COMPLETED" else "FAILURE")
	var nxt2 := phase_by_id(out, want)
	nxt2["status"] = "ACTIVE"
	nxt2["status_turn"] = turn
	nxt2["status_reason"] = "ADVANCED_FROM_%s" % str(cur.get("phase_id", "?"))
	out["current_phase_id"] = want
	out["revision"] = int(vp.get("revision", 0)) + 1
	out["parent_revision"] = int(vp.get("revision", 0))
	out["last_revised_turn"] = turn
	out["last_review_turn"] = turn
	return {"ok": true, "code": "", "detail": "", "plan": out,
		"from_phase": str(cur.get("phase_id", "")), "to_phase": want}


## AMEND_PLAN: same lineage + same current phase; terminal (COMPLETED /
## FAILED / ABORTED) phases must be preserved byte-identical in their
## model-authored fields (history is immutable); active/future phases are
## replaced by the validated new array. new_phases must already be
## validated via validate_phase.
static func amend_phases(vp: Dictionary, new_phases: Array, turn: int, reason: String) -> Dictionary:
	if not has_plan(vp):
		return {"ok": false, "code": "VP_NO_PLAN", "detail": "No VictoryPlan to amend.", "plan": {}}
	if new_phases.is_empty():
		return {"ok": false, "code": "VP_PHASES", "detail": "AMEND needs a non-empty phases array.", "plan": {}}
	var new_ids := {}
	for n_val in new_phases:
		if n_val is Dictionary:
			new_ids[str((n_val as Dictionary).get("phase_id", ""))] = n_val
	for o_val in (vp.get("phases", []) as Array):
		if not o_val is Dictionary:
			continue
		var o: Dictionary = o_val
		var pid := str(o.get("phase_id", ""))
		if str(o.get("status", "")) in TERMINAL_PHASE_STATUSES:
			if not new_ids.has(pid):
				return {"ok": false, "code": "VP_HISTORY", "detail": "AMEND must preserve terminal phase %s." % pid, "plan": {}}
			# SELFPLAY V1: "priority" is Godot-assigned at authoring time and is
			# never shown back in review packets (compress_phase omits it), so a
			# verbatim echo cannot reproduce an explicit priority. It is exempt
			# from the echo contract; the stored body still wins below.
			var old_sub := _model_subset(o)
			var new_sub := _model_subset(new_ids[pid])
			old_sub.erase("priority")
			new_sub.erase("priority")
			if old_sub != new_sub:
				return {"ok": false, "code": "VP_HISTORY", "detail": "AMEND must not rewrite terminal phase %s history." % pid, "plan": {}}
	var cur_id := str(vp.get("current_phase_id", ""))
	if not new_ids.has(cur_id):
		return {"ok": false, "code": "VP_CURRENT", "detail": "AMEND must preserve the active phase %s (advance it instead)." % cur_id, "plan": {}}
	var out: Dictionary = vp.duplicate(true)
	var merged: Array = []
	for n_val in new_phases:
		var nph: Dictionary = (n_val as Dictionary).duplicate(true)
		var npid := str(nph.get("phase_id", ""))
		var old := phase_by_id(vp, npid)
		if old.is_empty():
			nph["status"] = "PLANNED" # brand-new future phase
			nph["status_turn"] = turn
			nph["status_reason"] = "AMEND_ADDED"
		elif str(old.get("status", "")) in TERMINAL_PHASE_STATUSES:
			# SELFPLAY V1: terminal phases are history. Keep the stored body
			# verbatim so exempt/unshown fields (priority, rich intent) can
			# never be rewritten by an echo.
			merged.append(old.duplicate(true))
			continue
		else:
			# Godot-owned clocks always win over model echoes.
			nph["status"] = str(old.get("status", "PLANNED"))
			nph["status_turn"] = int(old.get("status_turn", 0))
			nph["status_reason"] = str(old.get("status_reason", ""))
			_carry_mission_clocks(old, nph, turn)
		merged.append(nph)
	out["phases"] = merged
	out["revision"] = int(vp.get("revision", 0)) + 1
	out["parent_revision"] = int(vp.get("revision", 0))
	out["last_revised_turn"] = turn
	out["last_review_turn"] = turn
	if not reason.strip_edges().is_empty():
		out["revision_note"] = _clip(reason)
	return {"ok": true, "code": "", "detail": "", "plan": out}


## EMERGENCY_REPLAN: the strategic concept is no longer viable. The old
## plan stays in revision history; the new body (already validated via
## validate_plan) starts a NEW lineage with a monotonic revision.
static func emergency_replan(old_vp: Dictionary, new_body: Dictionary, new_lineage_id: String, turn: int, reason: String) -> Dictionary:
	if not has_plan(old_vp):
		return {"ok": false, "code": "VP_NO_PLAN", "detail": "No VictoryPlan to replace.", "plan": {}}
	var out: Dictionary = (new_body as Dictionary).duplicate(true)
	out["victory_plan_id"] = str(old_vp.get("victory_plan_id", ""))
	out["lineage_id"] = new_lineage_id.strip_edges().to_upper()
	out["revision"] = int(old_vp.get("revision", 0)) + 1
	out["parent_revision"] = int(old_vp.get("revision", 0))
	out["created_turn"] = int(old_vp.get("created_turn", turn))
	out["last_revised_turn"] = turn
	out["last_review_turn"] = turn
	if not reason.strip_edges().is_empty():
		out["revision_note"] = _clip(reason)
	# Fresh lineage: first phase ACTIVE, the rest PLANNED.
	var first := true
	for p_val in (out.get("phases", []) as Array):
		if not p_val is Dictionary:
			continue
		var ph: Dictionary = p_val
		if first:
			ph["status"] = "ACTIVE"
			ph["status_turn"] = turn
			ph["status_reason"] = "EMERGENCY_REPLAN"
			out["current_phase_id"] = str(ph.get("phase_id", ""))
			first = false
		else:
			ph["status"] = "PLANNED"
			ph["status_turn"] = 0
			ph["status_reason"] = ""
	return {"ok": true, "code": "", "detail": "", "plan": out}


## Model-authored subset of a phase (everything except Godot-owned phase
## clocks and per-mission live clocks). Used for AMEND history checks and
## for detecting real General edits vs clock churn.
static func _model_subset(ph: Dictionary) -> Dictionary:
	var out := {}
	for k in ["phase_id", "name", "purpose", "priority", "force_intent", "entry_conditions",
			"success_conditions", "failure_conditions", "abort_conditions", "transition",
			"reserve_policy", "exploitation_intent", "commander_intent", "notes"]:
		out[k] = ph.get(k)
	var missions: Array = []
	for m_val in (ph.get("missions", []) as Array):
		if not m_val is Dictionary:
			continue
		var m: Dictionary = m_val
		var mm := {}
		for mk in ["mission_id", "task", "area", "assigned_units", "objective", "engagement",
				"constraints", "success_conditions", "abort_conditions", "report_conditions"]:
			mm[mk] = m.get(mk)
		missions.append(mm)
	out["missions"] = missions
	return out


## Carry live mission clocks (status/progress/activation) across an AMEND
## for missions that keep their mission_id inside the same phase, so a
## minor amendment does not destroy execution continuity.
static func _carry_mission_clocks(old_ph: Dictionary, new_ph: Dictionary, turn: int) -> void:
	var old_by_id := {}
	for m_val in (old_ph.get("missions", []) as Array):
		if m_val is Dictionary:
			old_by_id[str((m_val as Dictionary).get("mission_id", ""))] = m_val
	for n_val in (new_ph.get("missions", []) as Array):
		if not n_val is Dictionary:
			continue
		var n: Dictionary = n_val
		var o: Dictionary = old_by_id.get(str(n.get("mission_id", "")), {})
		if o.is_empty():
			n["activated_turn"] = turn
		else:
			n["status"] = str(o.get("status", "ASSIGNED"))
			n["status_reason"] = str(o.get("status_reason", ""))
			n["status_turn"] = int(o.get("status_turn", 0))
			n["progress_turn"] = int(o.get("progress_turn", 0))
			n["activated_turn"] = int(o.get("activated_turn", turn))


## Derive the execution-layer StrategicPlan from the ACTIVE phase only.
## Future phases stay stored but inactive; past phases stay history. The
## execution plan_version tracks the VictoryPlan revision 1:1 so every
## mission trace maps to exactly one strategic revision. Mission live
## clocks carry over by mission_id while the same phase stays active.
## mission_contract/hypotheses ride along from the previous execution plan.
static func derive_execution(vp: Dictionary, prev_exec: Dictionary, mission_contract: Dictionary, turn: int, snapshot: String) -> Dictionary:
	var ph := active_phase(vp)
	var missions: Array = []
	var same_phase := str((prev_exec.get("victory", {}) as Dictionary).get("current_phase_id", "")) == str(vp.get("current_phase_id", ""))
	var prev_by_id := {}
	if same_phase:
		for m_val in (prev_exec.get("missions", []) as Array):
			if m_val is Dictionary:
				prev_by_id[str((m_val as Dictionary).get("mission_id", ""))] = m_val
	if not ph.is_empty():
		for sm_val in (ph.get("missions", []) as Array):
			if not sm_val is Dictionary:
				continue
			var m: Dictionary = (sm_val as Dictionary).duplicate(true)
			var o: Dictionary = prev_by_id.get(str(m.get("mission_id", "")), {})
			if not o.is_empty():
				m["status"] = str(o.get("status", "ASSIGNED"))
				m["status_reason"] = str(o.get("status_reason", ""))
				m["status_turn"] = int(o.get("status_turn", 0))
				m["progress_turn"] = int(o.get("progress_turn", 0))
				m["activated_turn"] = int(o.get("activated_turn", turn))
			else:
				m["activated_turn"] = turn
			missions.append(m)
	var main_effort := "ANY"
	if not missions.is_empty():
		main_effort = str((missions[0] as Dictionary).get("area", "ANY"))
	var review_conds: Array = [{"trigger": "MISSION_BLOCKED", "params": {}}]
	if not ph.is_empty():
		for c_val in (ph.get("abort_conditions", []) as Array):
			review_conds.append((c_val as Dictionary).duplicate(true))
			if review_conds.size() >= 4:
				break
	for c2_val in (vp.get("plan_abort_conditions", []) as Array):
		review_conds.append((c2_val as Dictionary).duplicate(true))
		if review_conds.size() >= 6:
			break
	return {
		"plan_version": int(vp.get("revision", 0)),
		"supersedes_version": int(prev_exec.get("plan_version", 0)),
		"based_on_snapshot": snapshot,
		"created_turn": int(prev_exec.get("created_turn", turn)),
		"last_review_turn": int(vp.get("last_review_turn", turn)),
		"mission": mission_contract.duplicate(true),
		"concept": {
			"objective": str(vp.get("final_objective", "")),
			"intent": str(ph.get("commander_intent", "")) if not ph.is_empty() else "",
			"main_effort": main_effort,
			"risk_posture": str(((prev_exec.get("concept", {}) as Dictionary).get("risk_posture", "BALANCED"))),
		},
		"doctrine": (vp.get("doctrine", {}) as Dictionary).duplicate(true),
		"missions": missions,
		"contingencies": [],
		"opponent_hypotheses": (prev_exec.get("opponent_hypotheses", []) as Array).duplicate(true),
		"review_conditions": review_conds,
		"review_horizon_turns": int(vp.get("review_horizon_turns", DEFAULT_REVIEW_HORIZON)),
		"source": "victory_plan",
		"victory": victory_header(vp),
	}


## Compact victory header embedded in the derived execution plan and sent
## to Laya. Small by design: Laya executes the active phase, it does not
## need the full multi-phase memory.
static func victory_header(vp: Dictionary) -> Dictionary:
	var ph := active_phase(vp)
	var phases: Array = vp.get("phases", [])
	return {
		"victory_plan_id": str(vp.get("victory_plan_id", "")),
		"lineage_id": str(vp.get("lineage_id", "")),
		"revision": int(vp.get("revision", 0)),
		"current_phase_id": str(vp.get("current_phase_id", "")),
		"phase_name": str(ph.get("name", "")) if not ph.is_empty() else "",
		"phase_status": str(ph.get("status", "")) if not ph.is_empty() else "",
		"phase_index": phase_index(vp, str(vp.get("current_phase_id", ""))) + 1,
		"total_phases": phases.size(),
	}


## Compact per-unit strategic context for Laya Hands: identity + active
## phase purpose/intent + the unit's own mission. Full-plan JSON is never
## sent per decision.
static func victory_context_for_laya(vp: Dictionary, unit_mission: Dictionary) -> Dictionary:
	var ph := active_phase(vp)
	var rp: Dictionary = ph.get("reserve_policy", {}) if not ph.is_empty() else {}
	return {
		"victory_plan_id": str(vp.get("victory_plan_id", "")),
		"victory_plan_revision": int(vp.get("revision", 0)),
		"lineage_id": str(vp.get("lineage_id", "")),
		"current_phase_id": str(vp.get("current_phase_id", "")),
		"phase_name": str(ph.get("name", "")) if not ph.is_empty() else "",
		"phase_purpose": str(ph.get("purpose", "")) if not ph.is_empty() else "",
		"commander_intent": str(ph.get("commander_intent", "")) if not ph.is_empty() else "",
		"phase_status": str(ph.get("status", "")) if not ph.is_empty() else "",
		"total_phases": (vp.get("phases", []) as Array).size(),
		"final_objective": str(vp.get("final_objective", "")),
		"reserve_hold": ((rp.get("hold", []) as Array).duplicate(true)) if not rp.is_empty() else [],
		"unit_mission_id": str(unit_mission.get("mission_id", "")),
		"unit_mission_task": str(unit_mission.get("task", "")),
		"unit_mission_area": str(unit_mission.get("area", "")),
		"unit_mission_intent": str(unit_mission.get("intent", "")),
		"unit_mission_coord": str(unit_mission.get("coordination_intent", "")),
	}


## Semantic revision diff for the developer: what the General changed vs
## what survived. Returns {changed: [lines], unchanged: [lines],
## mission_changes: [{phase_id, mission_id, change}]}.
static func semantic_diff(before: Dictionary, after: Dictionary) -> Dictionary:
	var changed: Array = []
	var unchanged: Array = []
	var mission_changes: Array = []
	if str(before.get("lineage_id", "")) != str(after.get("lineage_id", "")):
		changed.append("lineage: %s -> %s (EMERGENCY_REPLAN)" % [str(before.get("lineage_id", "?")), str(after.get("lineage_id", "?"))])
	else:
		unchanged.append("lineage " + str(after.get("lineage_id", "?")))
	if str(before.get("final_objective", "")) != str(after.get("final_objective", "")):
		changed.append("final_objective revised")
	else:
		unchanged.append("final objective")
	if str(before.get("desired_end_state", "")) != str(after.get("desired_end_state", "")):
		changed.append("desired_end_state revised")
	if (before.get("doctrine", {}) as Dictionary) != (after.get("doctrine", {}) as Dictionary):
		changed.append("doctrine revised")
	if int(before.get("review_horizon_turns", 0)) != int(after.get("review_horizon_turns", 0)):
		changed.append("review cadence: %d -> %d turns" % [int(before.get("review_horizon_turns", 0)), int(after.get("review_horizon_turns", 0))])
	if str(before.get("current_phase_id", "")) != str(after.get("current_phase_id", "")):
		changed.append("current phase: %s -> %s" % [str(before.get("current_phase_id", "?")), str(after.get("current_phase_id", "?"))])
	var b_ids := {}
	for b_val in (before.get("phases", []) as Array):
		if b_val is Dictionary:
			b_ids[str((b_val as Dictionary).get("phase_id", ""))] = b_val
	var a_ids := {}
	for a_val in (after.get("phases", []) as Array):
		if a_val is Dictionary:
			a_ids[str((a_val as Dictionary).get("phase_id", ""))] = a_val
	for pid in b_ids.keys():
		if not a_ids.has(pid):
			changed.append("phase %s removed" % pid)
	for pid2 in a_ids.keys():
		if not b_ids.has(pid2):
			changed.append("phase %s added (%s)" % [pid2, str((a_ids[pid2] as Dictionary).get("name", ""))])
	for pid3 in a_ids.keys():
		if not b_ids.has(pid3):
			continue
		var bo: Dictionary = b_ids[pid3]
		var ao: Dictionary = a_ids[pid3]
		if str(bo.get("status", "")) != str(ao.get("status", "")):
			changed.append("phase %s status: %s -> %s" % [pid3, str(bo.get("status", "?")), str(ao.get("status", "?"))])
		if _model_subset(bo) != _model_subset(ao):
			changed.append("phase %s %s content revised" % [pid3, str(ao.get("name", "")).strip_edges()])
			_diff_missions(pid3, bo, ao, mission_changes, changed)
		else:
			unchanged.append("phase %s %s" % [pid3, str(ao.get("name", "")).strip_edges()])
	if (before.get("plan_abort_conditions", []) as Array) != (after.get("plan_abort_conditions", []) as Array):
		changed.append("plan_abort_conditions revised")
	if _branch_subset(before) != _branch_subset(after):
		changed.append("branches revised")
	elif not (after.get("branches", []) as Array).is_empty():
		unchanged.append("%d branch(es)" % (after.get("branches", []) as Array).size())
	return {"changed": changed, "unchanged": unchanged, "mission_changes": mission_changes}


static func _branch_subset(vp: Dictionary) -> Array:
	var out: Array = []
	for b_val in (vp.get("branches", []) as Array):
		if b_val is Dictionary:
			var b: Dictionary = b_val
			out.append({"branch_id": str(b.get("branch_id", "")), "condition": b.get("condition", {}), "then": b.get("then", {})})
	return out


static func _diff_missions(pid: String, bo: Dictionary, ao: Dictionary, mission_changes: Array, changed: Array) -> void:
	var b_by_id := {}
	for m_val in (bo.get("missions", []) as Array):
		if m_val is Dictionary:
			b_by_id[str((m_val as Dictionary).get("mission_id", ""))] = m_val
	var a_by_id := {}
	for m2_val in (ao.get("missions", []) as Array):
		if m2_val is Dictionary:
			a_by_id[str((m2_val as Dictionary).get("mission_id", ""))] = m2_val
	for mid in b_by_id.keys():
		if not a_by_id.has(mid):
			mission_changes.append({"phase_id": pid, "mission_id": mid, "change": "REMOVED"})
			changed.append("%s/%s removed" % [pid, mid])
	for mid2 in a_by_id.keys():
		if not b_by_id.has(mid2):
			mission_changes.append({"phase_id": pid, "mission_id": mid2, "change": "ADDED"})
			changed.append("%s/%s added (%s %s)" % [pid, mid2, str((a_by_id[mid2] as Dictionary).get("task", "?")), str((a_by_id[mid2] as Dictionary).get("area", "?"))])
	for mid3 in a_by_id.keys():
		if not b_by_id.has(mid3):
			continue
		var bm: Dictionary = b_by_id[mid3]
		var am: Dictionary = a_by_id[mid3]
		var edits: Array = []
		for k in ["task", "area"]:
			if str(bm.get(k, "")) != str(am.get(k, "")):
				edits.append("%s %s->%s" % [k, str(bm.get(k, "?")), str(am.get(k, "?"))])
		if (bm.get("assigned_units", []) as Array) != (am.get("assigned_units", []) as Array):
			var blo: Array = (bm.get("assigned_units", []) as Array).duplicate()
			var alo: Array = (am.get("assigned_units", []) as Array).duplicate()
			var gone: Array = blo.filter(func(x: Variant) -> bool: return not alo.has(x))
			var added: Array = alo.filter(func(x: Variant) -> bool: return not blo.has(x))
			if not gone.is_empty():
				edits.append("units -%s" % ",".join(gone))
			if not added.is_empty():
				edits.append("units +%s" % ",".join(added))
		for k2 in ["objective", "engagement", "success_conditions", "abort_conditions"]:
			if bm.get(k2) != am.get(k2):
				edits.append(k2 + " revised")
		if not edits.is_empty():
			mission_changes.append({"phase_id": pid, "mission_id": mid3, "change": "; ".join(edits)})
			changed.append("%s/%s: %s" % [pid, mid3, "; ".join(edits)])


static func revision_record(rev_before: int, rev_after: int, turn: int, trigger: String, reason: String, decision: String, diff: Dictionary, phase_before: String, phase_after: String) -> Dictionary:
	return {
		"revision": rev_after,
		"parent_revision": rev_before,
		"turn": turn,
		"trigger": trigger,
		"reason": reason.left(MAX_TEXT),
		"decision": decision,
		"phase_before": phase_before,
		"phase_after": phase_after,
		"changed": (diff.get("changed", []) as Array).duplicate(true),
		"unchanged": (diff.get("unchanged", []) as Array).duplicate(true),
		"mission_changes": (diff.get("mission_changes", []) as Array).duplicate(true),
	}


static func _cond_text(conds: Array) -> String:
	if conds.is_empty():
		return "-"
	var parts: Array = []
	for c_val in conds:
		if c_val is Dictionary:
			var params: Dictionary = (c_val as Dictionary).get("params", {})
			if params.is_empty():
				parts.append(str((c_val as Dictionary).get("trigger", "?")))
			else:
				parts.append("%s%s" % [str((c_val as Dictionary).get("trigger", "?")), JSON.stringify(params)])
	return "; ".join(parts)


static func render_summary(vp: Dictionary) -> String:
	if not has_plan(vp):
		return "(no VictoryPlan)"
	var lines: Array = []
	lines.append("VICTORY PLAN %s rev=%d parent=%d lineage=%s src=%s created_t%d revised_t%d reviewed_t%d cadence=%d" % [
		str(vp.get("victory_plan_id", "?")), int(vp.get("revision", 0)), int(vp.get("parent_revision", 0)),
		str(vp.get("lineage_id", "?")), str(vp.get("source", "?")),
		int(vp.get("created_turn", 0)), int(vp.get("last_revised_turn", 0)), int(vp.get("last_review_turn", 0)),
		int(vp.get("review_horizon_turns", 0))])
	lines.append("final objective: %s" % str(vp.get("final_objective", "-")))
	lines.append("desired end: %s" % str(vp.get("desired_end_state", "-")))
	var d: Dictionary = vp.get("doctrine", {})
	lines.append("doctrine agg=%.2f risk=%.2f tempo=%.2f pursuit=%.2f reserve=%.2f deception=%.2f" % [
		float(d.get("aggression", 0.5)), float(d.get("risk_tolerance", 0.5)), float(d.get("tempo", 0.5)),
		float(d.get("pursuit", 0.5)), float(d.get("reserve_discipline", 0.5)), float(d.get("deception", 0.0))])
	lines.append("current phase: %s" % str(vp.get("current_phase_id", "?")))
	for p_val in (vp.get("phases", []) as Array):
		if not p_val is Dictionary:
			continue
		var ph: Dictionary = p_val
		lines.append("phase %s [%s] %s :: %s" % [str(ph.get("phase_id", "?")), str(ph.get("status", "?")),
			str(ph.get("name", "")), str(ph.get("purpose", ""))])
		for m_val in (ph.get("missions", []) as Array):
			if m_val is Dictionary:
				lines.append("  mission " + MissionCls.describe(m_val))
		lines.append("  success: %s" % _cond_text(ph.get("success_conditions", [])))
		lines.append("  failure: %s" % _cond_text(ph.get("failure_conditions", [])))
		lines.append("  abort: %s" % _cond_text(ph.get("abort_conditions", [])))
		var tr: Dictionary = ph.get("transition", {})
		var on_s: Dictionary = tr.get("on_success", {})
		var on_f: Dictionary = tr.get("on_failure", {})
		lines.append("  transition: success->%s(%s) failure->%s(%s)" % [str(on_s.get("action", "?")),
			str(on_s.get("next_phase_id", "next")), str(on_f.get("action", "?")), str(on_f.get("next_phase_id", "-"))])
		var rp: Dictionary = ph.get("reserve_policy", {})
		lines.append("  reserve: hold=[%s] release_when=%s" % [",".join(rp.get("hold", [])),
			_cond_text(rp.get("release_when", []))])
	for b_val in (vp.get("branches", []) as Array):
		if b_val is Dictionary:
			var b: Dictionary = b_val
			lines.append("branch %s [%s] IF %s :: %s" % [str(b.get("branch_id", "?")), str(b.get("status", "?")),
				str(b.get("if_text", "")), str((b.get("then", {}) as Dictionary).get("action", "?"))])
	lines.append("plan abort: %s" % _cond_text(vp.get("plan_abort_conditions", [])))
	return "\n".join(lines)


static func render_current_phase(vp: Dictionary) -> String:
	var ph := active_phase(vp)
	if ph.is_empty():
		return "(no active phase)"
	var phases: Array = vp.get("phases", [])
	var idx := phase_index(vp, str(vp.get("current_phase_id", "")))
	var nxt := next_phase_id(vp)
	return "CURRENT PHASE %s (%d/%d)\nname: %s\npurpose: %s\nstatus: %s (t%d %s)\nsuccess: %s\nabort: %s\nnext: %s" % [
		str(ph.get("phase_id", "?")), idx + 1, phases.size(), str(ph.get("name", "")),
		str(ph.get("purpose", "")), str(ph.get("status", "?")), int(ph.get("status_turn", 0)),
		str(ph.get("status_reason", "-")), _cond_text(ph.get("success_conditions", [])),
		_cond_text(ph.get("abort_conditions", [])), nxt if not nxt.is_empty() else "(last phase)"]


static func render_revision(diff_rev: Dictionary) -> String:
	var lines: Array = []
	lines.append("v%d -> v%d | t%d | %s | %s" % [int(diff_rev.get("parent_revision", 0)),
		int(diff_rev.get("revision", 0)), int(diff_rev.get("turn", 0)),
		str(diff_rev.get("decision", "?")), str(diff_rev.get("trigger", "?"))])
	lines.append("reason: %s" % str(diff_rev.get("reason", "-")))
	lines.append("phase: %s -> %s" % [str(diff_rev.get("phase_before", "?")), str(diff_rev.get("phase_after", "?"))])
	var ch: Array = diff_rev.get("changed", [])
	if ch.is_empty():
		lines.append("CHANGED: (none)")
	else:
		lines.append("CHANGED:")
		for c in ch:
			lines.append("  - " + str(c))
	var un: Array = diff_rev.get("unchanged", [])
	if not un.is_empty():
		lines.append("UNCHANGED: " + "; ".join(un))
	return "\n".join(lines)
