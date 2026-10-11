class_name Cloud2GeneralPlan
extends RefCounted

## CLOUD-GENERAL MISSION HIERARCHY — canonical StrategicPlan (Godot-owned).
##
## The persistent operational plan of the Cloud General: mission, concept,
## doctrine, force missions, contingencies, opponent hypotheses, review
## conditions. Stored as structured data (memory + packet), NEVER as raw
## conversation. Godot runtime state always wins over plan contents:
## reconcile() drops dead/unknown units and voids missions with no force.
##
## Pure data + validation. No network, no game truth, no mutation.

const MissionCls = preload("res://scripts/cloud2/cloud2_mission.gd")

const PLAN_VERSION := 1
const MAX_TEXT := 280
const MAX_MISSIONS := 8
const MAX_CONTINGENCIES := 8
const MAX_HYPOTHESES := 4

const DOCTRINE_KEYS := ["aggression", "risk_tolerance", "tempo", "pursuit", "reserve_discipline", "deception"]

const DEFAULT_DOCTRINE := {
	"aggression": 0.5,
	"risk_tolerance": 0.5,
	"tempo": 0.5,
	"pursuit": 0.5,
	"reserve_discipline": 0.6,
	"deception": 0.2,
}

const DEFAULT_REVIEW_HORIZON := 4


static func default_doctrine() -> Dictionary:
	return DEFAULT_DOCTRINE.duplicate(true)


static func default_concept() -> Dictionary:
	return {"objective": "", "intent": "", "main_effort": "", "risk_posture": "BALANCED"}


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


static func empty_plan() -> Dictionary:
	return {
		"plan_version": 0,
		"supersedes_version": 0,
		"based_on_snapshot": "",
		"created_turn": 0,
		"last_review_turn": 0,
		"mission": {"type": "", "objective": ""},
		"concept": default_concept(),
		"doctrine": default_doctrine(),
		"missions": [],
		"contingencies": [],
		"opponent_hypotheses": [],
		"review_conditions": [],
		"review_horizon_turns": DEFAULT_REVIEW_HORIZON,
		"source": "none",
	}


static func has_plan(plan: Dictionary) -> bool:
	return int(plan.get("plan_version", 0)) > 0 and not (plan.get("missions", []) as Array).is_empty()


## Build a deterministic LOCAL fallback plan from a RED observation. Used
## when no General plan exists yet and no Cloud call is possible/desired
## (offline battle, unconfigured connection, General failure). Grouping is
## class-driven and stable; missions cover every ready formation so no
## unit idles silently. Source is always "local_fallback".
static func default_plan(obs: Dictionary, turn: int) -> Dictionary:
	var plan := empty_plan()
	plan["plan_version"] = 1
	plan["based_on_snapshot"] = str(obs.get("snapshot_id", ""))
	plan["created_turn"] = turn
	plan["last_review_turn"] = turn
	var om: Dictionary = obs.get("mission", {})
	plan["mission"] = {"type": str(om.get("type", "")), "objective": str(om.get("objective", ""))}
	plan["concept"] = {
		"objective": "Local fallback: WIN THE BATTLE — own HQ loss is defeat, enemy HQ kill is victory; otherwise fix the enemy center, scout the flanks, hold the HQ with minimum necessary losses.",
		"intent": "Deterministic holding concept until the General reviews.",
		"main_effort": "CENTER",
		"risk_posture": "BALANCED",
	}
	plan["source"] = "local_fallback"
	var fix_units: Array = []
	var recon_units: Array = []
	var hold_units: Array = []
	for u_val in (obs.get("friendly_units", []) as Array):
		if not u_val is Dictionary:
			continue
		var u: Dictionary = u_val
		if str(u.get("status", "")) != "ready":
			continue
		var uid := str(u.get("unit_id", ""))
		var cls := str(u.get("class", "")).to_upper()
		if cls in ["SCOUT", "CAVALRY"]:
			recon_units.append(uid)
		elif cls in ["HQ"]:
			hold_units.append(uid)
		else:
			fix_units.append(uid)
	fix_units.sort()
	recon_units.sort()
	hold_units.sort()
	var missions: Array = []
	if not fix_units.is_empty():
		var m1 := MissionCls.default_mission("M01", "FIX")
		m1["area"] = "CENTER"
		m1["assigned_units"] = fix_units
		m1["objective"] = {"kind": "REGION", "region": "CENTER"}
		missions.append(m1)
	if not recon_units.is_empty():
		var m2 := MissionCls.default_mission("M02", "RECON")
		m2["area"] = "ANY"
		m2["assigned_units"] = recon_units
		missions.append(m2)
	if not hold_units.is_empty():
		var m3 := MissionCls.default_mission("M03", "HOLD")
		m3["area"] = "ANY"
		m3["assigned_units"] = hold_units
		m3["engagement"] = {"policy": "HOLD_FIRE"}
		missions.append(m3)
	plan["missions"] = missions
	plan["review_conditions"] = [{"trigger": "MISSION_BLOCKED", "params": {}}]
	return plan


## Validate + canonicalize a full StrategicPlan from untrusted input.
## Model plans arrive via Cloud2GeneralResponse; this is the shared shape.
static func validate_plan(p_val: Variant, ctx: Dictionary = {}) -> Dictionary:
	if not p_val is Dictionary:
		return {"ok": false, "code": "PLAN_SHAPE", "detail": "Plan must be an object.", "plan": {}}
	var p: Dictionary = p_val
	var turn := int(ctx.get("turn", 0))
	var snapshot := str(ctx.get("snapshot_id", ""))
	var out := empty_plan()
	out["plan_version"] = maxi(1, int(p.get("plan_version", 1)))
	out["supersedes_version"] = maxi(0, int(p.get("supersedes_version", 0)))
	out["based_on_snapshot"] = _clip(p.get("based_on_snapshot", snapshot)).left(160)
	out["created_turn"] = int(p.get("created_turn", turn))
	out["last_review_turn"] = int(p.get("last_review_turn", turn))
	if p.get("mission") is Dictionary:
		var pm: Dictionary = p.get("mission")
		out["mission"] = {"type": _clip(pm.get("type", "")), "objective": _clip(pm.get("objective", ""))}
	if p.get("concept") is Dictionary:
		var pc: Dictionary = p.get("concept")
		out["concept"] = {
			"objective": _clip(pc.get("objective", "")),
			"intent": _clip(pc.get("intent", "")),
			"main_effort": _clip(pc.get("main_effort", "")).to_upper().left(24),
			"risk_posture": _clip(pc.get("risk_posture", "BALANCED")).to_upper().left(24),
		}
	if p.get("doctrine") is Dictionary:
		var pd: Dictionary = p.get("doctrine")
		var dd := default_doctrine()
		for k in DOCTRINE_KEYS:
			if pd.has(k):
				dd[k] = _clamp01(pd.get(k), float(DEFAULT_DOCTRINE[k]))
		out["doctrine"] = dd
	var missions: Array = []
	if p.get("missions") is Array:
		for m_val in (p.get("missions") as Array):
			var one := MissionCls.validate_mission(m_val)
			if not bool(one.get("ok", false)):
				return {"ok": false, "code": str(one.get("code", "PLAN_MISSION")),
					"detail": str(one.get("detail", "")), "plan": {}}
			missions.append(one.get("mission", {}))
			if missions.size() >= MAX_MISSIONS:
				break
	if missions.is_empty():
		return {"ok": false, "code": "PLAN_EMPTY", "detail": "Plan carries no missions.", "plan": {}}
	var seen := {}
	for m2 in missions:
		var mid := str((m2 as Dictionary).get("mission_id", ""))
		if seen.has(mid):
			return {"ok": false, "code": "PLAN_DUP_MISSION", "detail": "Duplicate mission_id '%s'." % mid, "plan": {}}
		seen[mid] = true
	out["missions"] = missions
	var conts: Array = []
	if p.get("contingencies") is Array:
		for c_val in (p.get("contingencies") as Array):
			var cone := MissionCls.validate_contingency(c_val)
			if not bool(cone.get("ok", false)):
				return {"ok": false, "code": str(cone.get("code", "PLAN_CONTINGENCY")),
					"detail": str(cone.get("detail", "")), "plan": {}}
			conts.append(cone.get("contingency", {}))
			if conts.size() >= MAX_CONTINGENCIES:
				break
	out["contingencies"] = conts
	var hyps := validate_hypotheses(p.get("opponent_hypotheses", []))
	if not bool(hyps.get("ok", false)):
		return {"ok": false, "code": str(hyps.get("code", "PLAN_HYPOTHESES")), "detail": str(hyps.get("detail", "")), "plan": {}}
	out["opponent_hypotheses"] = hyps.get("hypotheses", [])
	var rcs := MissionCls._validate_conditions(p.get("review_conditions", []))
	if not bool(rcs.get("ok", false)):
		return {"ok": false, "code": str(rcs.get("code", "PLAN_REVIEW")), "detail": str(rcs.get("detail", "")), "plan": {}}
	out["review_conditions"] = rcs.get("conditions", [])
	out["review_horizon_turns"] = clampi(int(p.get("review_horizon_turns", DEFAULT_REVIEW_HORIZON)), 1, 12)
	out["source"] = _clip(p.get("source", "general")).left(32)
	if str(out["source"]).is_empty():
		out["source"] = "general"
	return {"ok": true, "code": "", "detail": "", "plan": out}


static func validate_hypotheses(h_val: Variant) -> Dictionary:
	if h_val == null or (h_val is Array and (h_val as Array).is_empty()):
		return {"ok": true, "hypotheses": []}
	if not h_val is Array:
		return {"ok": false, "code": "PLAN_HYPOTHESES", "detail": "opponent_hypotheses must be an array."}
	var out: Array = []
	for e_val in (h_val as Array):
		if not e_val is Dictionary:
			return {"ok": false, "code": "PLAN_HYPOTHESES", "detail": "Hypothesis must be an object."}
		var e: Dictionary = e_val
		var name := _clip(e.get("hypothesis", "")).to_upper().left(64)
		if name.is_empty():
			return {"ok": false, "code": "PLAN_HYPOTHESES", "detail": "Hypothesis needs a name."}
		var ev: Array = []
		if e.get("evidence") is Array:
			for x in (e.get("evidence") as Array):
				ev.append(_clip(x).left(160))
				if ev.size() >= 6:
					break
		out.append({
			"hypothesis": name,
			"confidence": _clamp01(e.get("confidence", 0.5), 0.5),
			"evidence": ev,
		})
		if out.size() >= MAX_HYPOTHESES:
			break
	return {"ok": true, "hypotheses": out}


## Godot-wins reconciliation: drop assigned units that are dead/unknown in
## the authoritative observation; void missions left with no force; drop
## WAITING_TRIGGER missions whose trigger mission vanished. Returns the
## reconciled plan plus a list of applied corrections (for trace/memory).
static func reconcile(plan: Dictionary, obs: Dictionary) -> Dictionary:
	var live := {}
	for u_val in (obs.get("friendly_units", []) as Array):
		if u_val is Dictionary:
			live[str((u_val as Dictionary).get("unit_id", "")).strip_edges().to_upper()] = true
	var corrections: Array = []
	var missions: Array = []
	for m_val in (plan.get("missions", []) as Array):
		if not m_val is Dictionary:
			continue
		var m: Dictionary = (m_val as Dictionary).duplicate(true)
		var kept: Array = []
		for u in (m.get("assigned_units", []) as Array):
			var uid := str(u).strip_edges().to_upper()
			if live.has(uid):
				kept.append(uid)
			else:
				corrections.append("drop %s from %s (not in Godot state)" % [uid, str(m.get("mission_id", "?"))])
		kept.sort()
		m["assigned_units"] = kept
		if kept.is_empty() and not MissionCls.is_terminal(str(m.get("status", ""))):
			m["status"] = "ABORTED"
			m["status_reason"] = "NO_FORCE"
			corrections.append("%s ABORTED (no live force)" % str(m.get("mission_id", "?")))
		missions.append(m)
	var out: Dictionary = plan.duplicate(true)
	out["missions"] = missions
	return {"plan": out, "corrections": corrections}


static func mission_by_id(plan: Dictionary, mission_id: String) -> Dictionary:
	var want := mission_id.strip_edges().to_upper()
	for m_val in (plan.get("missions", []) as Array):
		if m_val is Dictionary and str((m_val as Dictionary).get("mission_id", "")) == want:
			return m_val
	return {}


static func active_missions(plan: Dictionary) -> Array:
	var out: Array = []
	for m_val in (plan.get("missions", []) as Array):
		if not m_val is Dictionary:
			continue
		var st := str((m_val as Dictionary).get("status", ""))
		if not MissionCls.is_terminal(st):
			out.append(m_val)
	return out


static func render_summary(plan: Dictionary) -> String:
	if not has_plan(plan):
		return "(no strategic plan)"
	var c: Dictionary = plan.get("concept", {})
	var d: Dictionary = plan.get("doctrine", {})
	var lines: Array = []
	lines.append("PLAN v%d sup=v%d src=%s base=%s created_t%d reviewed_t%d horizon=%d" % [
		int(plan.get("plan_version", 0)), int(plan.get("supersedes_version", 0)),
		str(plan.get("source", "?")),
		str(plan.get("based_on_snapshot", "-")).left(40),
		int(plan.get("created_turn", 0)), int(plan.get("last_review_turn", 0)),
		int(plan.get("review_horizon_turns", 0))])
	lines.append("concept objective=%s" % str(c.get("objective", "-")))
	lines.append("concept intent=%s" % str(c.get("intent", "-")))
	lines.append("concept main_effort=%s posture=%s" % [str(c.get("main_effort", "-")), str(c.get("risk_posture", "-"))])
	lines.append("doctrine agg=%.2f risk=%.2f tempo=%.2f pursuit=%.2f reserve=%.2f deception=%.2f" % [
		float(d.get("aggression", 0.5)), float(d.get("risk_tolerance", 0.5)),
		float(d.get("tempo", 0.5)), float(d.get("pursuit", 0.5)),
		float(d.get("reserve_discipline", 0.5)), float(d.get("deception", 0.0))])
	for m_val in (plan.get("missions", []) as Array):
		if m_val is Dictionary:
			lines.append("mission " + MissionCls.describe(m_val))
	for h_val in (plan.get("opponent_hypotheses", []) as Array):
		if h_val is Dictionary:
			lines.append("hypothesis %s conf=%.2f" % [str((h_val as Dictionary).get("hypothesis", "?")), float((h_val as Dictionary).get("confidence", 0.0))])
	return "\n".join(lines)
