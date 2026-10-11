class_name Cloud2MissionController
extends RefCounted

## CLOUD-GENERAL MISSION HIERARCHY — ONE generic mission executor.
##
## Each instance executes ONE assigned mission for ONE dynamic force group:
## every ready formation generates its six class options (see
## Cloud2ClassOption / Cloud2ClassOptionSolver), masks the inapplicable,
## scores survivors with the shared deterministic utility, and resolves
## the pick to a Table-valid, compiler-dry-run OperationalCommand.
## Identical unit commands merge into group orders; the mission emits one
## or more orders per RED turn, executed sequentially by the existing
## compiler/executor path (which re-plans each order at execute time).
##
## Boundary (hard): the controller NEVER re-plans strategy. When the
## assigned mission cannot advance it reports BLOCKED with a reason and
## holds; the General re-plans. It calls no LLM, mutates no battle state
## (candidate feasibility uses the non-mutating Cloud1Compiler.plan), and
## emits only Table-valid commands the response gate re-checks.

const TableCls = preload("res://scripts/cloud1/cloud1_action_table.gd")
const CompilerCls = preload("res://scripts/cloud1/cloud1_compiler.gd")
const ScopeAlgebraCls = preload("res://scripts/step7/step7_scope_algebra.gd")
const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")
const MissionCls = preload("res://scripts/cloud2/cloud2_mission.gd")
const OpportunityCls = preload("res://scripts/cloud2/cloud2_opportunity.gd")
const UtilityCls = preload("res://scripts/cloud2/cloud2_utility.gd")
const SolverCls = preload("res://scripts/cloud2/cloud2_class_option_solver.gd")

## Tasks that must make spatial/combat progress: when NO unit resolves a
## progress option (ATTACK/ADVANCE/WITHDRAW kind), the mission reports
## BLOCKED even though HOLD fallbacks still execute.
const PROGRESS_TASKS := ["ADVANCE", "ATTACK", "FLANK", "WITHDRAW", "RECON"]
## PURSUE_WEAKENED keeps only targets meeting this kill bar (or a
## near-free hit with matchup edge). Named for observability.
const WEAKENED_KILL_BAR := 0.25

var _mission := {}
var _doctrine := {}
var _weights := {}
var _seed_base := 0


func setup(mission: Dictionary, doctrine: Dictionary, seed_base: int = 0, weights: Dictionary = {}) -> void:
	_mission = mission.duplicate(true)
	_doctrine = doctrine.duplicate(true)
	_seed_base = seed_base
	_weights = weights.duplicate(true) if not weights.is_empty() else UtilityCls.default_weights()


func mission_id() -> String:
	return str(_mission.get("mission_id", "?"))


## Decide one RED turn for the assigned force.
## sim: bridge or SimController (same interface). obs: canonical RED obs.
## ctx: {turn, snapshot_id, turns_active, urgency (0..1), bounds}.
static func tie_seed(seed_base: int, snapshot_id: String, mission_id: String, turn: int) -> int:
	var h := hash("%d|%s|%s|%d" % [seed_base, snapshot_id, mission_id, turn])
	return int(abs(h)) % 2147483647


## SYMMETRIC V1: side threads dry-run compilation + opportunity gates
## (default red = legacy behavior).
func decide(sim: RefCounted, obs: Dictionary, ctx: Dictionary, side: String = "red") -> Dictionary:
	var mid := mission_id()
	var turn := int(ctx.get("turn", 0))
	var snapshot := str(ctx.get("snapshot_id", ""))
	var eside := side.strip_edges().to_lower()
	if eside != "blue" and eside != "red":
		eside = "red"
	var ready := _ready_units(obs)
	var trace := {"mission_id": mid, "task": str(_mission.get("task", "?")),
		"ready_units": ready.duplicate(), "candidates": [], "units": [],
		"seed": tie_seed(_seed_base, snapshot, mid, turn)}
	trace["designation"] = SolverCls.designation_state(_mission, obs)
	if ready.is_empty():
		trace["chosen"] = "NO_READY_UNITS"
		trace["reason"] = "No assigned formation is ready to act."
		return {"mission_id": mid, "command": {}, "orders": [], "trace": trace,
			"status_hint": "ACTIVE", "reason": "NO_READY_UNITS", "ready_units": [],
			"planned_count": 0}
	var attacks_all := OpportunityCls.legal_attacks(sim, ready, obs, eside)
	var attacks := _filtered_attacks(attacks_all, obs)
	var opps := {"attacks_all": attacks_all, "attacks": attacks, "obs": obs}
	var uctx := ctx.duplicate()
	uctx["mission_status"] = str(_mission.get("status", "ACTIVE"))
	var tables: Array = []
	for uid in ready:
		tables.append(SolverCls.solve_unit(sim, _obs_unit(obs, uid), _mission,
			_doctrine, _weights, uctx, opps, _seed_base, eside))
	trace["units"] = tables
	var conditioned := {}
	for t_val in tables:
		var t: Dictionary = t_val
		for o_val in (t.get("options", []) as Array):
			var o: Dictionary = o_val
			var cr := str(o.get("conditioned_reason", ""))
			if not cr.is_empty() and int(o.get("slot", -1)) == int(t.get("selected_slot", -2)):
				conditioned[str(t.get("unit_id", "?"))] = cr
	if not conditioned.is_empty():
		trace["mission_conditioning"] = conditioned
	var groups := _group_tables(tables, sim, eside)
	trace["candidates"] = _group_rows(groups)
	if groups.is_empty():
		trace["chosen"] = "NO_FEASIBLE_ACTION"
		trace["reason"] = "Every unit failed dry-run feasibility."
		return {"mission_id": mid, "command": {}, "orders": [], "trace": trace,
			"status_hint": "BLOCKED", "reason": "NO_FEASIBLE_ACTION",
			"ready_units": ready, "planned_count": 0}
	var top: Dictionary = groups[0]
	trace["chosen"] = str(top.get("label", "?"))
	trace["chosen_score"] = float(top.get("score", 0.0))
	trace["rolled"] = false
	trace["tied_count"] = 1
	var orders: Array = []
	var planned_total := 0
	for g_val in groups:
		var g: Dictionary = g_val
		orders.append({"command": (g.get("command", {}) as Dictionary).duplicate(true),
			"units": (g.get("units", []) as Array).duplicate()})
		planned_total += int(g.get("planned_count", 0))
	var progress_ok := _progress_feasible(groups)
	var hint := "ACTIVE"
	var reason := "EXECUTING"
	if str(_mission.get("task", "")) in PROGRESS_TASKS and not progress_ok:
		hint = "BLOCKED"
		reason = "NO_PROGRESS_ACTION"
		trace["reason"] = "Task %s cannot advance: no unit resolved ATTACK/ADVANCE/WITHDRAW; HOLD fallback executes." % str(_mission.get("task", ""))
	# TARGET_CONTRACT_V1: a hard-designated mission whose T is not
	# currently visible reports BLOCKED/TARGET_UNOBSERVED (explicit, never
	# silent substitution). HOLD/move fallbacks still execute below, and the
	# existing BLOCKED->ACTIVE resume clears automatically when T reappears.
	var dstate: Dictionary = trace.get("designation", {})
	if str(dstate.get("policy", "NONE")) == "HARD" and not bool(dstate.get("visible", false)):
		hint = "BLOCKED"
		reason = "TARGET_UNOBSERVED"
		trace["reason"] = "Designated target %s is not currently visible; no substitute attacked." % str(dstate.get("id", "?"))
	var primary: Dictionary = (orders[0] as Dictionary).get("command", {})
	return {"mission_id": mid, "command": primary.duplicate(true), "orders": orders,
		"trace": trace, "status_hint": hint, "reason": reason,
		"ready_units": ready, "planned_count": planned_total}


## Merge identical unit commands into group orders (same action + target).
## Each group is dry-run as a whole; a group that fails splits back into
## its already-dry-run unit orders. Deterministic order: score desc, label.
func _group_tables(tables: Array, sim: RefCounted, side: String = "red") -> Array:
	var buckets := {}
	var order: Array = []
	for t_val in tables:
		var t: Dictionary = t_val
		var cmd: Dictionary = t.get("resolved_command", {})
		if cmd.is_empty():
			continue
		var key := _group_key(cmd)
		if not buckets.has(key):
			buckets[key] = {"key": key, "command": cmd.duplicate(true),
				"units": [], "tables": [], "score": 0.0, "kind": _kind_of(t)}
			order.append(key)
		var b: Dictionary = buckets[key]
		(b.get("units", []) as Array).append(str(t.get("unit_id", "?")))
		(b.get("tables", []) as Array).append(t)
		b["score"] = maxf(float(b.get("score", 0.0)), _selected_score(t))
	var groups: Array = []
	for k in order:
		var b2: Dictionary = buckets[k]
		var units: Array = b2.get("units", [])
		units.sort()
		var gcmd: Dictionary = (b2.get("command", {}) as Dictionary).duplicate(true)
		gcmd["scope"] = TableCls.scope_units(units)
		var dry: Dictionary = CompilerCls.plan(sim, gcmd, "", side)
		if bool(dry.get("ok", false)):
			b2["command"] = gcmd
			b2["planned_count"] = (dry.get("planned", []) as Array).size()
			b2["label"] = _group_label(gcmd)
			groups.append(b2)
		else:
			# Intra-group conflict (reservations): emit the unit orders,
			# each already dry-run at solve time.
			for t2_val in (b2.get("tables", []) as Array):
				var t2: Dictionary = t2_val
				var ucmd: Dictionary = (t2.get("resolved_command", {}) as Dictionary).duplicate(true)
				if ucmd.is_empty():
					continue
				groups.append({"key": k, "command": ucmd,
					"units": [str(t2.get("unit_id", "?"))], "tables": [t2],
					"score": _selected_score(t2), "kind": _kind_of(t2),
					"planned_count": 1, "label": _group_label(ucmd)})
	groups.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if float(a.get("score", 0.0)) != float(b.get("score", 0.0)):
			return float(a.get("score", 0.0)) > float(b.get("score", 0.0))
		return str(a.get("label", "")) < str(b.get("label", "")))
	return groups


static func _group_key(cmd: Dictionary) -> String:
	return JSON.stringify({"action": str(cmd.get("action", "?")), "target": cmd.get("target", {})})


static func _group_label(cmd: Dictionary) -> String:
	var act := str(cmd.get("action", "?"))
	var tgt: Dictionary = cmd.get("target", {})
	match act:
		"ATTACK":
			return "ATTACK %s" % str(tgt.get("unit_id", tgt.get("value", "?")))
		"HOLD":
			return "HOLD"
		"WITHDRAW":
			return "WITHDRAW ZONE(%s)" % str(tgt.get("zone", tgt.get("value", "?")))
		"REPOSITION":
			if str(tgt.get("type", "")) == "ZONE":
				return "REPOSITION ZONE(%s)" % str(tgt.get("zone", "?"))
			return "REPOSITION %s" % str(tgt.get("direction", tgt.get("value", "?")))
	return "%s %s" % [act, str(tgt.get("direction", tgt.get("value", tgt.get("unit_id", "?"))))]


static func _kind_of(t: Dictionary) -> String:
	for o_val in (t.get("options", []) as Array):
		if int((o_val as Dictionary).get("slot", -2)) == int(t.get("selected_slot", -1)):
			return str((o_val as Dictionary).get("kind", "HOLD"))
	return "HOLD"


static func _selected_score(t: Dictionary) -> float:
	for o_val in (t.get("options", []) as Array):
		if int((o_val as Dictionary).get("slot", -2)) == int(t.get("selected_slot", -1)):
			return float((o_val as Dictionary).get("final_score", 0.0))
	return 0.0


func _group_rows(groups: Array) -> Array:
	var out: Array = []
	for g_val in groups:
		var g: Dictionary = g_val
		out.append({"label": str(g.get("label", "?")), "kind": str(g.get("kind", "?")),
			"feasible": true, "code": "", "score": float(g.get("score", 0.0)),
			"parts": {}, "planned_count": int(g.get("planned_count", 0)),
			"units": (g.get("units", []) as Array).duplicate()})
	return out


func _ready_units(obs: Dictionary) -> Array:
	var assigned := {}
	for u in (_mission.get("assigned_units", []) as Array):
		assigned[str(u).strip_edges().to_upper()] = true
	var out: Array = []
	for u_val in (obs.get("friendly_units", []) as Array):
		if not u_val is Dictionary:
			continue
		var u: Dictionary = u_val
		if not assigned.has(str(u.get("unit_id", "")).strip_edges().to_upper()):
			continue
		if str(u.get("status", "")) != "ready":
			continue
		out.append(str(u.get("unit_id", "")))
	out.sort()
	return out


## Legal attacks constrained by mission engagement/objective/area BEFORE any
## scoring: a high combat number never overrides the assigned mission.
##
## PURSUE_WEAKENED narrowing (FLANK_EXPLOIT_V1): the kill bar remains the
## target preference for NON-designated rows, but the mission's designated
## enemy T is exempt when the actor has achieved effective flank geometry
## and the T-row is condition-adequate (no suicidal strike on a healthy T).
## PREMATURE (pre-maneuver) strikes on T stay filtered; EXPLOIT strikes
## after successful maneuver pass. Scoring still decides — the filter only
## stops pre-empting the maneuver phase.
func _filtered_attacks(all: Array, obs: Dictionary) -> Array:
	var policy := str((_mission.get("engagement", {}) as Dictionary).get("policy", "ATTACK_IF_ADVANTAGEOUS"))
	if policy == "HOLD_FIRE":
		return []
	if all.is_empty():
		return []
	var obj: Dictionary = _mission.get("objective", {})
	var otype := str(obj.get("kind", "NONE"))
	var task := str(_mission.get("task", ""))
	var area := str(_mission.get("area", "ANY"))
	var dstate := SolverCls.designation_state(_mission, obs)
	var dtid := str(dstate.get("id", ""))
	var dvis := bool(dstate.get("visible", false))
	var enemies_by_id := {}
	for e_val in (obs.get("known_enemy_units", []) as Array):
		if e_val is Dictionary:
			enemies_by_id[str((e_val as Dictionary).get("unit_id", "")).strip_edges().to_upper()] = e_val
	var out: Array = []
	for a_val in all:
		var a: Dictionary = a_val
		var tid := str(a.get("target_id", ""))
		if policy == "ATTACK_DESIGNATED_ONLY":
			if otype != "ENEMY_FORMATION" or str(obj.get("unit_id", "")) != tid:
				continue
		elif policy == "PURSUE_WEAKENED":
			var weak := float(a.get("kill_fraction", 0.0)) >= WEAKENED_KILL_BAR
			var free_hit := float(a.get("loss_fraction", 1.0)) <= 0.05 and float(a.get("matchup", 1.0)) >= 1.0
			if not weak and not free_hit:
				var exempt := false
				if dvis and not dtid.is_empty() and tid == dtid \
						and str(task.strip_edges().to_upper()) == "FLANK" \
						and float(a.get("loss_fraction", 1.0)) <= SolverCls.CONDITION_LOSS_MAX \
						and float(a.get("kill_fraction", 0.0)) >= SolverCls.CONDITION_KILL_MIN:
					for u_val in (obs.get("friendly_units", []) as Array):
						if u_val is Dictionary and str((u_val as Dictionary).get("unit_id", "")) == str(a.get("attacker_id", "")):
							var g: Dictionary = SolverCls.flank_geometry(obs, u_val, dtid)
							exempt = bool(g.get("achieved", false))
							break
				if not exempt:
					continue
		if otype == "FORMATION_CLASS" and task in ["FIX", "ATTACK", "FLANK"]:
			if str(a.get("target_class", "")) != str(obj.get("class", "")):
				continue
		if task in ["FIX", "HOLD", "RESERVE"] and area != "ANY":
			var erow: Dictionary = enemies_by_id.get(tid, {})
			if not erow.is_empty() and str(erow.get("region", "")).strip_edges().to_upper() != area:
				continue
		out.append(a)
	out.sort_custom(func(a2: Dictionary, b: Dictionary) -> bool:
		if float(a2.get("kill_fraction", 0.0)) != float(b.get("kill_fraction", 0.0)):
			return float(a2.get("kill_fraction", 0.0)) > float(b.get("kill_fraction", 0.0))
		return str(a2.get("target_id", "")) < str(b.get("target_id", "")))
	# Full sorted list: per-unit target sub-selection scores rows cheaply
	# (no compiler cost) and dry-runs only the winner, so no mission cap.
	return out


func _progress_feasible(scored: Array) -> bool:
	for s_val in scored:
		if str((s_val as Dictionary).get("kind", "")) in ["ATTACK", "ADVANCE", "WITHDRAW"]:
			return true
	return false


## Per-unit scoring lives in Cloud2ClassOptionSolver (same utility
## families, same weights, same formulas — one implementation). This file
## keeps mission scope: readiness, engagement filters, order grouping.


func _obs_unit(obs: Dictionary, uid: String) -> Dictionary:
	for u_val in (obs.get("friendly_units", []) as Array):
		if u_val is Dictionary and str((u_val as Dictionary).get("unit_id", "")) == uid:
			return u_val
	return {}


static func render_trace(trace: Dictionary) -> String:
	var lines: Array = []
	lines.append("%s %s (seed=%d)" % [str(trace.get("mission_id", "?")), str(trace.get("task", "?")), int(trace.get("seed", 0))])
	lines.append("ready=[%s]" % ",".join(trace.get("ready_units", [])))
	for c_val in (trace.get("candidates", []) as Array):
		var c: Dictionary = c_val
		if bool(c.get("feasible", false)):
			lines.append("  %-24s %5.1f %s" % [str(c.get("label", "?")), float(c.get("score", 0.0)), JSON.stringify(c.get("parts", {}))])
		else:
			lines.append("  %-24s INFEASIBLE(%s)" % [str(c.get("label", "?")), str(c.get("code", "?"))])
	lines.append("CHOSEN %s%s" % [str(trace.get("chosen", "?")), " (seeded tie-break)" if bool(trace.get("rolled", false)) else ""])
	if not str(trace.get("reason", "")).is_empty():
		lines.append("note: %s" % str(trace.get("reason", "")))
	return "\n".join(lines)
