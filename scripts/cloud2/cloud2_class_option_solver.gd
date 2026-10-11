class_name Cloud2ClassOptionSolver
extends RefCounted

## CLOUD-GENERAL PRE-DETERMINISTIC CLASS OPTIONS — generator + scorer.
##
## solve_unit() turns ONE ready formation into its six scored class options:
## generate -> mask (mission, then option rules) -> resolve survivors to
## Table commands -> compiler dry-run each (COMPILER_REJECTED) ->
## deterministic utility score + mission_fit -> seeded pick.
##
## Scoring REUSES Cloud2Utility (same weights, same families, same seeded
## tie-break): the option layer adds masking, mission voice, and per-option
## resolution on top. All terms stay inspectable in the option dicts, and
## base+mission+state+doctrine+risk always equals final_score.

const TableCls = preload("res://scripts/cloud1/cloud1_action_table.gd")
const CompilerCls = preload("res://scripts/cloud1/cloud1_compiler.gd")
const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")
const CombatCalcCls = preload("res://scripts/combat/combat_calculator.gd")
const OpportunityCls = preload("res://scripts/cloud2/cloud2_opportunity.gd")
const UtilityCls = preload("res://scripts/cloud2/cloud2_utility.gd")
const OptionCls = preload("res://scripts/cloud2/cloud2_class_option.gd")

## Threat radius for disengage/kite satisfaction (attack range + 1).
const THREAT_RADIUS := 2

## FLANK-POSITION-ACHIEVED geometry (TARGET_CONTRACT_V1 additive read):
## attacker bearing relative to the TARGET's facing axis (0 = directly ahead
## of T, 1 = directly behind T; lateral/rear >= FLANK_BEARING_ACHIEVED).
## bearing_distance_factor splits "frontal" by range: a distant frontal
## cavalry is still closing, a frontal cavalry already in melee contact has
## effectively reached its maneuver objective (further repositioning risks
## disengagement cost for no geometry gain).
const FLANK_BEARING_ACHIEVED := 0.55
const FLANK_BEARING_FRONTAL := 0.15
## Frontal-contact reach is PER-ATTACKER-CLASS (the class's weapon reach:
## cavalry 1, infantry 1, archer 3, siege 2): a frontal attacker already
## inside its own weapon reach has exhausted repositioning value even though
## its bearing is frontal. A fixed distance factor applied to all classes
## and starved melee FIX of the contact term (contact IS dist 1 for melee).

## Condition gate for the mission-conditioned contact terms (and HOLD
## damping): an actor row with expected friendly loss above this fraction
## (or kill contribution below this fraction) is NOT pressured into
## attacking — preservation evidence keeps scoring normally.
const CONDITION_LOSS_MAX := 0.2
const CONDITION_KILL_MIN := 0.05
## HOLD camping damping under FIX/FLANK designated contact (weight-space
## factor on hold_defense+reserve+calm via hold_damp in the HOLD split).
const HOLD_CONTACT_DAMP := 0.5
## FIX pre-contact approach (APPROACH_CONTRACT_V1): the generic ADVANCE
## exposure penalty (threat-radius anti-risk) must not out-shout a FIX
## mission's purpose — closing the last gap to the designated enemy.
## fix_approach fires only when ALL hold: task=FIX, designated T visible,
## the resolved destination actually closes on T, and the actor shows NO
## clear tactical disadvantage vs T (strength ratio vs T's RED-authorized
## troop estimate, preserve_force constraint, true depletion when max_count
## is known). Disadvantaged/preserve-constrained actors get NO bonus:
## their exposure/preserve terms keep preservation scoring normally.
const FIX_APPROACH_STRENGTH_RATIO := 0.75


## Solve one unit's six options. sim: bridge or SimController. unit: obs
## friendly row. opps: {attacks_all, attacks} (mission-filtered attacks).
## ctx: {turn, snapshot_id, turns_active, urgency, bounds, main_effort,
## mission_status}. Returns the Track-A unit table (see render_unit_table).
## SYMMETRIC V1: side threads dry-run compilation + reachable gates
## (default red = legacy behavior).
static func solve_unit(sim: RefCounted, unit: Dictionary, mission: Dictionary,
	doctrine: Dictionary, weights: Dictionary, ctx: Dictionary,
	opps: Dictionary, seed_base: int, side: String = "red") -> Dictionary:
	var uid := str(unit.get("unit_id", "?"))
	var uclass := str(unit.get("class", "INFANTRY")).strip_edges().to_upper()
	var mid := str(mission.get("mission_id", "?"))
	var task := str(mission.get("task", "HOLD")).strip_edges().to_upper()
	var dstate := designation_state(mission, opps.get("obs", {}))
	var geo := flank_geometry(opps.get("obs", {}), unit, str(dstate.get("id", "")))
	var flavor := "%s|%s|%s|%s|%s" % [task, str(dstate.get("id", "")), str(dstate.get("policy", "NONE")),
		"1" if bool(dstate.get("visible", false)) else "0", str(geo.get("lateral", "NO_CONTACT"))]
	var table := {"unit_id": uid, "unit_class": uclass, "mission_id": mid,
		"schema_version": OptionCls.SCHEMA_VERSION, "options": [],
		"selected_slot": -1, "selected_id": "NO_ACTION", "resolved_target": "",
		"resolved_destination": [], "resolved_command": {}, "compiler": "NONE",
		"fallback": false, "target_scores": [], "seed": OptionCls.tie_seed(
			seed_base, str(ctx.get("snapshot_id", "")), mid, uid, int(ctx.get("turn", 0))),
		"mission_target_type": "NONE", "mission_target_id": "",
		"designation_policy": "NONE", "target_match": null, "target_substitution_reason": "",
		"mission_flavor": flavor, "flank_geometry": geo}
	var _dstate := dstate
	table["mission_target_type"] = str(_dstate.get("type", "NONE"))
	table["mission_target_id"] = str(_dstate.get("id", ""))
	table["designation_policy"] = str(_dstate.get("policy", "NONE"))
	var slots: Array = OptionCls.slots_for_class(uclass)
	var area := OpportunityCls.reachable(sim, uid, "auto", side) if sim != null else {"ok": false, "reachable": []}
	var unit_rows := _unit_rows(opps.get("attacks", []), uid)
	var opts: Array = []
	for i in range(OptionCls.SLOT_COUNT):
		var oid := str(slots[i]) if i < slots.size() else "HOLD_LINE"
		opts.append(_skeleton(uid, uclass, mid, i, oid))
	_apply_mission_masks(opts, task, str(ctx.get("mission_status", "ACTIVE")))
	_apply_option_masks(opts, sim, unit, mission, ctx, opps, unit_rows, area)
	_resolve_survivors(opts, sim, unit, mission, doctrine, weights, ctx, opps, unit_rows, area, side)
	_score_survivors(opts, unit, mission, doctrine, weights, ctx, opps, unit_rows, area, geo)
	table["options"] = opts
	_select(table, int(table["seed"]))
	if bool(table.get("fallback", false)):
		# The fallback HOLD is still compiler-gated like any resolution.
		var fcmd: Dictionary = table.get("resolved_command", {})
		var fdry: Dictionary = CompilerCls.plan(sim, fcmd, "", side)
		if bool(fdry.get("ok", false)):
			table["compiler"] = "FALLBACK_PASS"
			table["dry_ok"] = true
		else:
			table["resolved_command"] = {}
			table["compiler"] = "FALLBACK_FAIL"
			table["dry_ok"] = false
			table["dry_code"] = str(fdry.get("code", "?"))
	else:
		table["dry_ok"] = true
	return table


static func _skeleton(uid: String, uclass: String, mid: String, slot: int, oid: String) -> Dictionary:
	return {"schema_version": OptionCls.SCHEMA_VERSION, "unit_id": uid,
		"unit_class": uclass, "mission_id": mid, "slot": slot, "option_id": oid,
		"kind": str((OptionCls.meta_for(oid) as Dictionary).get("kind", "HOLD")),
		"masked": false, "mask_reason": "", "base_score": 0.0, "mission_score": 0.0,
		"state_score": 0.0, "doctrine_score": 0.0, "risk_score": 0.0,
		"final_score": 0.0, "parts": {}, "features": {},
		"resolved_target": "", "resolved_destination": [], "resolved_command": {},
		"dry_ok": false, "dry_code": "",
		"mission_target_type": "", "mission_target_id": "", "designation_policy": "NONE",
		"target_match": null, "target_substitution_reason": ""}


## Designation state of one mission against live RED-authorized observation.
## Shared by solver resolution/telemetry and controller BLOCKED accounting
## (TARGET_CONTRACT_V1). Pure read, no mutation.
static func designation_state(mission: Dictionary, obs: Dictionary) -> Dictionary:
	var obj: Dictionary = mission.get("objective", {})
	var tid := ""
	if str(obj.get("kind", "")) == "ENEMY_FORMATION":
		tid = str(obj.get("unit_id", "")).strip_edges().to_upper()
	var policy := str((mission.get("engagement", {}) as Dictionary).get("policy", "ATTACK_IF_ADVANTAGEOUS")).strip_edges().to_upper()
	var dpol := "NONE"
	if not tid.is_empty():
		if policy == "ATTACK_DESIGNATED_ONLY":
			dpol = "HARD"
		elif policy != "HOLD_FIRE":
			dpol = "SOFT"
	var visible := false
	if not tid.is_empty():
		for e_val in (obs.get("known_enemy_units", []) as Array):
			if e_val is Dictionary and str((e_val as Dictionary).get("unit_id", "")).strip_edges().to_upper() == tid \
				and str((e_val as Dictionary).get("contact_state", "")) == "current_visible":
				visible = true
				break
	return {"type": str(obj.get("kind", "NONE")), "id": tid, "policy": dpol, "visible": visible}


## Flank geometry of one actor relative to a designated (or visible-nearest)
## enemy: distance, attack legality, and the target-facing bearing metric
## described at FLANK_BEARING_ACHIEVED. Pure read over RED-authorized obs;
## no mutation. Unknown/distant target -> achieved=false (honest default:
## geometry is NOT claimed without evidence).
static func flank_geometry(obs: Dictionary, unit: Dictionary, target_id: String) -> Dictionary:
	var origin := Vector2i(int(unit.get("q", 0)), int(unit.get("r", 0)))
	var uclass := str(unit.get("class", "infantry")).to_lower()
	var reach := maxi(1, int(CombatCalcCls.get_attack_range(uclass)))
	var tpos := Vector2i(-999, -999)
	var tvis := false
	if not target_id.is_empty():
		for e_val in (obs.get("known_enemy_units", []) as Array):
			if e_val is Dictionary and str((e_val as Dictionary).get("unit_id", "")).strip_edges().to_upper() == target_id \
				and str((e_val as Dictionary).get("contact_state", "")) == "current_visible":
				tpos = Vector2i(int((e_val as Dictionary).get("q", 0)), int((e_val as Dictionary).get("r", 0)))
				tvis = true
				break
	if tpos.x == -999:
		return {"target_id": target_id, "target_visible": false, "distance": -1,
			"bearing": -1.0, "achieved": false, "lateral": "NO_CONTACT", "reach": reach}
	var dist := HexUtilsCls.hex_distance_axial(origin, tpos)
	var bearing := _target_relative_bearing(tpos, origin)
	var achieved := bearing >= FLANK_BEARING_ACHIEVED or dist <= reach
	var lateral := "REAR/LATERAL" if bearing >= FLANK_BEARING_ACHIEVED else ("FRONTAL" if bearing <= FLANK_BEARING_FRONTAL else "OBLIQUE")
	return {"target_id": target_id, "target_visible": true, "distance": dist,
		"bearing": snappedf(bearing, 0.01), "achieved": achieved, "lateral": lateral,
		"reach": reach}

## 0.0 = actor directly ahead of T's facing, 0.5 = abeam, 1.0 = directly
## behind. T faces +q (BLUE faces EAST; RED faces -q). Axial cross-check:
## hex-grid bearing via axis distance and q-offset — exact enough for the
## three-band threshold and cheap enough for per-option scoring.
##
## CONTACT clause (APPROACH_CONTRACT_V1 correction): distance <= weapon
## reach IS contact regardless of bearing — a melee unit on one of T's two
## "shoulder" hexes (bearing ~0.2-0.5) is adjacent and legally attackable;
## classifying it not-achieved left it camping (HOLD 37 vs unconditioned
## ATTACK ~31). Bearing-only "achieved" remains the FLANK maneuver semantic
## at range; contact is physical reach.
static func _target_relative_bearing(tpos: Vector2i, apos: Vector2i) -> float:
	var dq := float(apos.x - tpos.x)
	var axial_frac := absf(float(apos.y - tpos.y) - dq / 2.0)
	var radial := sqrt(dq * dq + axial_frac * axial_frac)
	if radial <= 0.001:
		return 0.0
	# cos of the angle from T's +q facing axis to the actor offset.
	var cosang := dq / radial
	return clampf(0.5 - 0.5 * cosang, 0.0, 1.0)


static func _mask(o: Dictionary, reason: String) -> void:
	o["masked"] = true
	o["mask_reason"] = reason
	o["final_score"] = 0.0


static func _unit_rows(attacks: Array, uid: String) -> Array:
	var out: Array = []
	for a_val in attacks:
		if a_val is Dictionary and str((a_val as Dictionary).get("attacker_id", "")) == uid:
			out.append(a_val)
	return out


## Mission masks: kind compatibility + waiting-trigger dormancy.
static func _apply_mission_masks(opts: Array, task: String, status: String) -> void:
	var dormant := status.strip_edges().to_upper() == "WAITING_TRIGGER"
	for o_val in opts:
		var o: Dictionary = o_val
		if dormant and str(o.get("kind", "")) != "HOLD":
			_mask(o, "WAITING_TRIGGER")
		elif not OptionCls.kind_allowed(task, str(o.get("kind", ""))):
			_mask(o, "MISSION_CONFLICT")


## Option masks: authoritative inapplicability per option. Dry-run failures
## apply COMPILER_REJECTED later in _resolve_survivors.
static func _apply_option_masks(opts: Array, sim: RefCounted, unit: Dictionary,
	mission: Dictionary, ctx: Dictionary, opps: Dictionary, unit_rows: Array,
	area: Dictionary) -> void:
	var obs: Dictionary = opps.get("obs", {})
	var uid_origin := Vector2i(int(unit.get("q", 0)), int(unit.get("r", 0)))
	var visible := _visible_enemies(obs)
	var threatened := _enemy_within(obs, uid_origin, THREAT_RADIUS)
	var hq_threat := bool(OpportunityCls.hq_threatened(obs).get("threatened", false))
	var unopposed_ranged_attack := false
	for a_val in unit_rows:
		if a_val is Dictionary and int((a_val as Dictionary).get("distance", 1)) > 1 \
			and float((a_val as Dictionary).get("expected_friendly_casualties_max", 1.0)) <= 0.0:
			unopposed_ranged_attack = true
			break
	var task := str(mission.get("task", "HOLD")).strip_edges().to_upper()
	for o_val in opts:
		var o: Dictionary = o_val
		if bool(o.get("masked", false)):
			continue
		var oid := str(o.get("option_id", ""))
		var kind := str(o.get("kind", ""))
		# A fire position is already valid when this archer has a legal,
		# mission-compatible target. Leaving REPOSITION_FOR_RANGE active here
		# lets generic progress scoring move an in-range archer instead of firing.
		if oid == "REPOSITION_FOR_RANGE" and not unit_rows.is_empty():
			_mask(o, "ALREADY_SATISFIED")
			continue
		# Holding the same fireline is strictly dominated by an authoritative
		# ranged shot with no modeled return casualties: firing does not move the
		# archer, and this ruleset has no ammunition or reveal cost to preserve.
		if oid == "HOLD_FIRELINE" and unopposed_ranged_attack:
			_mask(o, "ALREADY_SATISFIED")
			continue
		if kind == "ATTACK":
			var rows := _class_rows(oid, unit_rows)
			if rows.is_empty():
				_mask(o, "NO_VALID_TARGET")
				continue
		if kind == "ADVANCE":
			if not _has_legal_move(area, uid_origin):
				_mask(o, "NO_LEGAL_MOVE")
				continue
		match oid:
			"CLOSE_GAP_SUPPORT", "SHADOW_PRIORITY_ENEMY":
				if visible.is_empty():
					_mask(o, "NO_VISIBLE_CONTACT")
			"SCREEN_COUNTERFLANK":
				if _nearest_class(visible, uid_origin, "CAVALRY").is_empty():
					_mask(o, "NO_VISIBLE_CONTACT")
			"PRESS_OBJECTIVE":
				if OptionCls.objective_point(obs, mission, ctx).x == 9999:
					_mask(o, "OBJECTIVE_UNAVAILABLE")
			"PROTECT_ARCHER":
				if _nearest_friendly_class(obs, "ARCHER").is_empty():
					_mask(o, "ALREADY_SATISFIED")
			"PROTECT_HQ":
				if not hq_threat:
					_mask(o, "ALREADY_SATISFIED")
			"KITE_FROM_THREAT":
				if not threatened:
					_mask(o, "ALREADY_SATISFIED")
			"WITHDRAW_LINE", "WITHDRAW_TO_SCREEN", "FALLBACK_SCREEN", "DISENGAGE_TO_RESERVE", "EVADE_RETURN":
				if task != "WITHDRAW" and not threatened:
					_mask(o, "ALREADY_SATISFIED")
			"RELOCATE_LEFT_SAFE", "RELOCATE_RIGHT_SAFE", "RELOCATE_CENTER_SAFE", "WITHDRAW_FROM_THREAT":
				if not hq_threat:
					_mask(o, "ALREADY_SATISFIED")
	_apply_contact_precedence(opts, task)


## Contact precedence (FIX/ATTACK only): a unit with actionable contact — an
## unmasked ATTACK-kind option, i.e. a legal, mission-filtered, preview-accepted
## attack inside an ATTACK slot's class scope — has satisfied the
## close-to-contact purpose of progress movement. Still-active ADVANCE options
## mask as ALREADY_SATISFIED (contact satisfied); engage-vs-hold then follows
## existing scores. Final pass so structural reasons (NO_LEGAL_MOVE,
## OBJECTIVE_UNAVAILABLE, WAITING_TRIGGER, MISSION_CONFLICT) keep precedence.
## ADVANCE/FLANK/RECON/RESERVE/HOLD/WITHDRAW keep score-decided behavior.
static func _apply_contact_precedence(opts: Array, task: String) -> void:
	if task != "FIX" and task != "ATTACK":
		return
	var actionable := false
	for o_val in opts:
		var o: Dictionary = o_val
		if str(o.get("kind", "")) == "ATTACK" and not bool(o.get("masked", false)):
			actionable = true
			break
	if not actionable:
		return
	for o2_val in opts:
		var o2: Dictionary = o2_val
		if bool(o2.get("masked", false)):
			continue
		if str(o2.get("kind", "")) == "ADVANCE":
			_mask(o2, "ALREADY_SATISFIED")


static func _class_rows(oid: String, unit_rows: Array) -> Array:
	var want: Array = OptionCls.CLASS_FILTER.get(oid, [])
	if want.is_empty():
		return unit_rows.duplicate()
	var out: Array = []
	for a_val in unit_rows:
		if want.has(str((a_val as Dictionary).get("target_class", "")).strip_edges().to_upper()):
			out.append(a_val)
	return out


static func _has_legal_move(area: Dictionary, origin: Vector2i) -> bool:
	if not bool(area.get("ok", false)):
		return false
	for h_val in (area.get("reachable", []) as Array):
		var hq := 0
		var hr := 0
		if h_val is Dictionary:
			hq = int((h_val as Dictionary).get("q", origin.x))
			hr = int((h_val as Dictionary).get("r", origin.y))
		elif h_val is Array and (h_val as Array).size() >= 2:
			hq = int((h_val as Array)[0])
			hr = int((h_val as Array)[1])
		else:
			continue
		if hq != origin.x or hr != origin.y:
			return true
	return false


## Resolution: survivors get exact targets + Table commands + dry-runs.
## Attack options sub-select the best legal target first (scores recorded).
static func _resolve_survivors(opts: Array, sim: RefCounted, unit: Dictionary,
	mission: Dictionary, doctrine: Dictionary, weights: Dictionary,
	ctx: Dictionary, opps: Dictionary, unit_rows: Array,
	area: Dictionary, side: String = "red") -> void:
	var obs: Dictionary = opps.get("obs", {})
	var uid := str(unit.get("unit_id", "?"))
	var posture := OpportunityCls.region_posture(obs, str(mission.get("area", "ANY")))
	var advantage := clampf(float(posture.get("advantage_ratio", 0.0)) / 2.0, 0.0, 1.0)
	var preserve := 1.0 if bool((mission.get("constraints", {}) as Dictionary).get("preserve_force", false)) else 0.0
	var pressure := clampf(float(ctx.get("urgency", 0.0)) + float(ctx.get("turns_active", 0)) / 6.0, 0.0, 1.0)
	for o_val in opts:
		var o: Dictionary = o_val
		if bool(o.get("masked", false)):
			continue
		var oid := str(o.get("option_id", ""))
		var meta: Dictionary = OptionCls.meta_for(oid)
		var kind := str(meta.get("kind", "HOLD"))
		var dstate := designation_state(mission, obs)
		var dtid := str(dstate.get("id", ""))
		var dpol := str(dstate.get("policy", "NONE"))
		var dvis := bool(dstate.get("visible", false))
		o["mission_target_type"] = str(dstate.get("type", "NONE"))
		o["mission_target_id"] = dtid
		o["designation_policy"] = dpol
		var cmd := {}
		if kind == "ATTACK":
			var rows := _class_rows(oid, unit_rows)
			if rows.is_empty():
				_mask(o, "NO_VALID_TARGET")
				continue
			var best := _best_target(rows, mission, obs, doctrine, weights, advantage, preserve, pressure)
			o["target_scores"] = best.get("scores", [])
			var tid := str(best.get("target_id", ""))
			if tid.is_empty():
				_mask(o, "NO_VALID_TARGET")
				continue
			o["resolved_target"] = tid
			cmd = TableCls.make_command("ATTACK", TableCls.scope_units([uid]), TableCls.target_formation(tid))
			_fill_attack_telemetry(o, tid, dtid, dpol)
		elif kind ==		"HOLD":
			cmd = TableCls.make_command("HOLD", TableCls.scope_units([uid]))
			_fill_noattack_telemetry(o, dtid, dvis, false)
		else:
			var act := str(meta.get("action", "ADVANCE"))
			if meta.has("zone"):
				cmd = TableCls.make_command(act, TableCls.scope_units([uid]),
					TableCls.target_zone(str(meta.get("zone", "HQ"))))
				_fill_noattack_telemetry(o, dtid, dvis, false)
			elif act == "FLANK" and not dtid.is_empty() and dvis:
				# TARGET_CONTRACT_V1: a visible designated enemy rides the
				# FLANK command as a formation reference (the compiler's
				# implemented formation-flank path derives the destination
				# relative to it). Unobserved T keeps the direction form.
				cmd = TableCls.make_command(act, TableCls.scope_units([uid]),
					TableCls.target_formation(dtid))
				o["resolved_target"] = dtid
				o["target_match"] = true
				o["target_substitution_reason"] = ""
			else:
				cmd = TableCls.make_command(act, TableCls.scope_units([uid]),
					TableCls.target_direction(str(meta.get("direction", "FORWARD"))))
				_fill_noattack_telemetry(o, dtid, dvis, true)
		o["resolved_command"] = cmd
		var structural := TableCls.validate_command(cmd)
		if not bool(structural.get("ok", false)):
			_mask(o, "COMPILER_REJECTED")
			o["dry_code"] = str(structural.get("code", "?"))
			continue
		var dry: Dictionary = CompilerCls.plan(sim, cmd, "", side)
		if not bool(dry.get("ok", false)):
			_mask(o, "COMPILER_REJECTED")
			o["dry_code"] = str(dry.get("code", "?"))
			continue
		# A WITHDRAW that goes nowhere is already satisfied: hold instead.
		var planned: Array = dry.get("planned", [])
		if kind == "WITHDRAW" and planned.size() == 1:
			var to_arr: Array = (planned[0] as Dictionary).get("to", [])
			var from_arr: Array = (planned[0] as Dictionary).get("from", [])
			if to_arr == from_arr and not to_arr.is_empty():
				var hold_cmd := TableCls.make_command("HOLD", TableCls.scope_units([uid]))
				var hold_dry: Dictionary = CompilerCls.plan(sim, hold_cmd, "", side)
				if bool(hold_dry.get("ok", false)):
					o["resolved_command"] = hold_cmd
					o["resolved_note"] = "WITHDRAW destination is current hex: HOLD instead."
					dry = hold_dry
					planned = dry.get("planned", [])
		o["dry_ok"] = true
		o["planned_count"] = planned.size()
		# Destinations only for real relocation: HOLD plans carry from==to
		# (the unit stays) and ATTACK plans carry no hex at all.
		if not planned.is_empty() and str((planned[0] as Dictionary).get("action", "")) == "MOVE":
			o["resolved_destination"] = ((planned[0] as Dictionary).get("to", []) as Array).duplicate()


## TARGET_CONTRACT_V1 telemetry: attack-bearing options state whether the
## resolved target honors the mission designation (additive fields only).
static func _fill_attack_telemetry(o: Dictionary, resolved: String, dtid: String, dpol: String) -> void:
	if dtid.is_empty():
		o["target_match"] = null
		o["target_substitution_reason"] = ""
	elif resolved == dtid:
		o["target_match"] = true
		o["target_substitution_reason"] = ""
	else:
		o["target_match"] = false
		o["target_substitution_reason"] = "SOFT_POLICY_HIGHER_SCORE" if dpol == "SOFT" else "HARD_POLICY_VIOLATION"


## Non-attack options carry no strike target; under designation they still
## record WHY (unobserved T vs direction movement vs plain hold).
static func _fill_noattack_telemetry(o: Dictionary, dtid: String, dvis: bool, is_direction_move: bool) -> void:
	o["target_match"] = null
	if dtid.is_empty():
		o["target_substitution_reason"] = ""
	elif not dvis:
		o["target_substitution_reason"] = "TARGET_UNOBSERVED"
	elif is_direction_move:
		o["target_substitution_reason"] = "DIRECTION_MOVEMENT"
	else:
		o["target_substitution_reason"] = "NO_TARGET_ACTION"


## Target sub-selection: every legal candidate scored, best wins by
## (score desc, target asc). Deterministic and fully inspectable.
static func _best_target(rows: Array, mission: Dictionary, obs: Dictionary,
	doctrine: Dictionary, weights: Dictionary, advantage: float, preserve: float,
	pressure: float) -> Dictionary:
	var scored: Array = []
	for a_val in rows:
		var a: Dictionary = a_val
		var s := UtilityCls.score_candidate("ATTACK",
			_attack_features(a, mission, advantage, preserve, pressure, obs),
			doctrine, weights)
		scored.append({"target_id": str(a.get("target_id", "?")),
			"score": float(s.get("score", 0.0))})
	scored.sort_custom(func(x: Dictionary, y: Dictionary) -> bool:
		if float(x.get("score", 0.0)) != float(y.get("score", 0.0)):
			return float(x.get("score", 0.0)) > float(y.get("score", 0.0))
		return str(x.get("target_id", "")) < str(y.get("target_id", "")))
	if scored.is_empty():
		return {"target_id": "", "scores": []}
	return {"target_id": str(scored[0].get("target_id", "")), "scores": scored}


## Scoring: utility families + mission voice. final = base + mission +
## state + doctrine + risk (exact partition, asserted by gates).
static func _score_survivors(opts: Array, unit: Dictionary, mission: Dictionary,
	doctrine: Dictionary, weights: Dictionary, ctx: Dictionary, opps: Dictionary,
	unit_rows: Array, area: Dictionary, geo: Dictionary) -> void:
	var obs: Dictionary = opps.get("obs", {})
	var task := str(mission.get("task", "HOLD")).strip_edges().to_upper()
	var dstate := designation_state(mission, obs)
	var posture := OpportunityCls.region_posture(obs, str(mission.get("area", "ANY")))
	var advantage := clampf(float(posture.get("advantage_ratio", 0.0)) / 2.0, 0.0, 1.0)
	var preserve := 1.0 if bool((mission.get("constraints", {}) as Dictionary).get("preserve_force", false)) else 0.0
	var pressure := clampf(float(ctx.get("urgency", 0.0)) + float(ctx.get("turns_active", 0)) / 6.0, 0.0, 1.0)
	for o_val in opts:
		var o: Dictionary = o_val
		if bool(o.get("masked", false)):
			continue
		var oid := str(o.get("option_id", ""))
		var kind := str(o.get("kind", "HOLD"))
		var feat := {}
		match kind:
			"ATTACK":
				feat = _attack_features(_row_for(o, unit_rows), mission, advantage, preserve, pressure, obs)
				var state_row: Dictionary = _row_for(o, unit_rows)
				_fill_mission_conditioned_terms(feat, task, dstate, geo, state_row, mission)
			"ADVANCE":
				feat = _move_features(unit, oid, mission, obs, ctx,
					(o.get("resolved_destination", []) as Array).duplicate(),
					int(o.get("planned_count", 0)), pressure, preserve)
				_fill_fix_approach_term(feat, task, dstate, geo, unit, obs,
					(o.get("resolved_destination", []) as Array), mission)
			"WITHDRAW":
				feat = _withdraw_features(mission, posture, obs, preserve)
			_:
				feat = _hold_features(task, advantage, not unit_rows.is_empty())
				if task in ["FIX", "FLANK"]:
					var hd := 0.0
					for a_val in unit_rows:
						if a_val is Dictionary and str((a_val as Dictionary).get("target_id", "")) == str(dstate.get("id", "")):
							var hrow: Dictionary = a_val
							if bool(geo.get("achieved", false)) \
								and float(hrow.get("loss_fraction", 1.0)) <= CONDITION_LOSS_MAX \
								and float(hrow.get("kill_fraction", 0.0)) >= CONDITION_KILL_MIN:
								hd = HOLD_CONTACT_DAMP
					feat["hold_damp"] = hd
		var s := UtilityCls.score_candidate(kind, feat, doctrine, weights)
		var parts: Dictionary = s.get("parts", {})
		var split := _split_scores(kind, parts)
		o["features"] = feat
		o["parts"] = parts
		o["base_score"] = float(split.get("base", 0.0))
		o["state_score"] = float(split.get("state", 0.0))
		o["doctrine_score"] = float(split.get("doctrine", 0.0))
		o["risk_score"] = float(split.get("risk", 0.0))
		o["mission_score"] = OptionCls.mission_fit(task, kind)
		o["final_score"] = float(o["base_score"]) + float(o["mission_score"]) \
			+ float(o["state_score"]) + float(o["doctrine_score"]) + float(o["risk_score"])
		if not str(o.get("conditioned_reason", "")).is_empty():
			o["conditioned_reason"] = str(o.get("conditioned_reason", ""))


## Mission-conditioned additive scoring terms (SCORING_CONTRACT_V1):
## NEVER a forced override — skill selection stays a scored choice; these
## terms voice the mission's tactical semantic for THIS state.
##
## FIX + valid visible designated T + legal T-row + adequate actor condition:
##   attacking T directly applies pressure/fixation -> fix_contact=1
##   (weak/depleted attacker rows fail the condition gate and get no bonus;
##   the negative loss/preserve terms still decide normally).
## FLANK/ATTACK + designated T + achieved flank geometry + legal T-row:
##   post-maneuver exploitation -> flank_exploit=1 (pre-maneuver attacks
##   get nothing; the FLANK maneuver itself keeps its mission_fit voice).
static func _fill_mission_conditioned_terms(feat: Dictionary, task: String, dstate: Dictionary,
	geo: Dictionary, state_row: Dictionary, mission: Dictionary) -> void:
	var tid := str(dstate.get("id", ""))
	if tid.is_empty() or not bool(dstate.get("visible", false)):
		return
	var rtid := str(state_row.get("target_id", ""))
	if rtid != tid:
		return # bonus applies ONLY to the designated target
	var row_kill := float(state_row.get("kill_fraction", 0.0))
	var row_loss := float(state_row.get("loss_fraction", 1.0))
	var adequate := row_loss <= CONDITION_LOSS_MAX and row_kill >= CONDITION_KILL_MIN
	var achieved := bool(geo.get("achieved", false))
	match task.strip_edges().to_upper():
		"FIX":
			if achieved and adequate:
				feat["fix_contact"] = 1.0
				feat["conditioned_reason"] = "FIX_CONTACT_PRESSURE"
			# Weak/depleted rows simply get no bonus; the negative
			# loss/preserve terms keep preservation scoring normally.
		"FLANK":
			if achieved and adequate:
				feat["flank_exploit"] = 1.0
				feat["conditioned_reason"] = "FLANK_EXPLOIT_STRIKE"
		"ATTACK":
			if achieved and adequate:
				feat["flank_exploit"] = 1.0
				feat["conditioned_reason"] = "ATTACK_DESIGNATED_CONTACT"


## FIX pre-contact approach (APPROACH_CONTRACT_V1): sets fix_approach=1 on an
## ADVANCE-kind feature dict when the move is a true designated-target
## approach: task=FIX, T visible, actor healthy, NOT in useful contact
## (geometry not achieved), and the resolved destination strictly closes on
## T. Purpose-relative by construction: no closing move, no bonus (generic
## direction drifting gets nothing). Weakened/critical actors get nothing —
## their exposure/preserve terms keep preservation scoring normally.
static func _fill_fix_approach_term(feat: Dictionary, task: String, dstate: Dictionary,
	geo: Dictionary, unit: Dictionary, obs: Dictionary, resolved_dest: Array,
	mission: Dictionary) -> void:
	if task.strip_edges().to_upper() != "FIX":
		return
	if str(dstate.get("id", "")).is_empty() or not bool(dstate.get("visible", false)):
		return
	if bool(geo.get("achieved", false)):
		return # contact phase: the contact-pressure contract owns scoring
	if bool((mission.get("constraints", {}) as Dictionary).get("preserve_force", false)):
		return # mission is explicitly preservation-constrained
	var my_sol := maxi(1, int(unit.get("soldiers", 0)))
	var my_max := int(unit.get("max_count", 0))
	if my_max > 0 and float(my_sol) / float(my_max) < 0.4:
		return # true depletion evidence (max_count known): preservation
	var t_est := _troop_estimate_of(obs, str(dstate.get("id", "")))
	if t_est > 0 and float(my_sol) < float(t_est) * FIX_APPROACH_STRENGTH_RATIO:
		return # clear tactical disadvantage vs the designated enemy
	if resolved_dest.size() < 2:
		return # no relocation resolved: HOLD-like movement, never a bonus
	var dest := Vector2i(int(resolved_dest[0]), int(resolved_dest[1]))
	var tpos := Vector2i(-999, -999)
	for e_val in (obs.get("known_enemy_units", []) as Array):
		if e_val is Dictionary and str((e_val as Dictionary).get("unit_id", "")).strip_edges().to_upper() == str(dstate.get("id", "")):
			tpos = Vector2i(int((e_val as Dictionary).get("q", 0)), int((e_val as Dictionary).get("r", 0)))
			break
	if tpos.x == -999:
		return
	var d_before := int(geo.get("distance", -1))
	var d_after := HexUtilsCls.hex_distance_axial(dest, tpos)
	if d_after >= d_before or d_after < 1:
		return # must strictly close and never step ONTO the target hex
	feat["fix_approach"] = 1.0
	feat["conditioned_reason"] = "FIX_APPROACH_CLOSING"

## RED-authorized troop estimate for one known enemy ("약 400~500" -> 450;
## "약 450명" -> 450; unknown -> 0 = no measured strength). Same parser as
## region_posture (one source of truth for measured strength).
static func _troop_estimate_of(obs: Dictionary, tid: String) -> int:
	for e_val in (obs.get("known_enemy_units", []) as Array):
		if e_val is Dictionary and str((e_val as Dictionary).get("unit_id", "")).strip_edges().to_upper() == tid:
			return OpportunityCls._estimate_troops(str((e_val as Dictionary).get("troop_estimate", "")))
	return 0


## Exact partition of each utility family into base/state/doctrine/risk.
## base = core kind value, state = battlefield situation, doctrine =
## doctrine-weighted terms, risk = costs. Utility parts are already SIGNED
## (costs arrive negative), so the partition sums them as-is: base + state
## + doctrine + risk always equals the raw utility score.
static func _split_scores(kind: String, parts: Dictionary) -> Dictionary:
	match kind:
		"ATTACK":
			return {"base": float(parts.get("kill", 0.0)) + float(parts.get("matchup", 0.0)) + float(parts.get("designated", 0.0)) + float(parts.get("class_match", 0.0)) \
				+ float(parts.get("fix_contact", 0.0)) + float(parts.get("flank_exploit", 0.0)),
				"state": float(parts.get("pressure", 0.0)) + float(parts.get("advantage", 0.0)),
				"doctrine": float(parts.get("aggression", 0.0)),
				"risk": float(parts.get("loss", 0.0)) + float(parts.get("overextension", 0.0)) + float(parts.get("preserve", 0.0))}
		"ADVANCE":
			return {"base": float(parts.get("progress", 0.0)) + float(parts.get("task_fit", 0.0)) + float(parts.get("fix_approach", 0.0)),
				"state": float(parts.get("pressure", 0.0)),
				"doctrine": float(parts.get("tempo", 0.0)) + float(parts.get("aggression", 0.0)),
				"risk": float(parts.get("exposure", 0.0)) + float(parts.get("formation_break", 0.0)) + float(parts.get("preserve", 0.0))}
		"HOLD":
			var damp := clampf(1.0 - float(parts.get("hold_damp", 0.0)), 0.0, 1.0)
			return {"base": (float(parts.get("defense", 0.0)) + float(parts.get("mission_fit", 0.0))) * damp,
				"state": 0.0,
				"doctrine": (float(parts.get("reserve_discipline", 0.0)) + float(parts.get("calm", 0.0))) * damp,
				"risk": float(parts.get("opportunity", 0.0))}
	return {"base": float(parts.get("threat", 0.0)), "state": 0.0, "doctrine": 0.0,
		"risk": float(parts.get("hold_pressure", 0.0)) + float(parts.get("preserve", 0.0)) + float(parts.get("retreat_cost", 0.0))}


static func _select(table: Dictionary, seed: int) -> void:
	var cands: Array = []
	for o_val in (table.get("options", []) as Array):
		if not bool((o_val as Dictionary).get("masked", false)):
			cands.append(o_val)
	if cands.is_empty():
		# No option available: the unit holds (absence-of-action default,
		# not a seventh option). Command filled by the caller.
		table["selected_slot"] = -1
		table["selected_id"] = "HOLD (fallback)"
		table["fallback"] = true
		table["resolved_command"] = TableCls.make_command("HOLD",
			TableCls.scope_units([str(table.get("unit_id", "?"))]))
		table["compiler"] = "FALLBACK"
		table["target_substitution_reason"] = "FALLBACK_HOLD"
		return
	var scored: Array = []
	for c_val in cands:
		scored.append({"score": float((c_val as Dictionary).get("final_score", 0.0)), "opt": c_val})
	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if float(a.get("score", 0.0)) != float(b.get("score", 0.0)):
			return float(a.get("score", 0.0)) > float(b.get("score", 0.0))
		return str((a.get("opt", {}) as Dictionary).get("option_id", "")) < str((b.get("opt", {}) as Dictionary).get("option_id", "")))
	var pick := UtilityCls.pick_best(scored, seed)
	var win: Dictionary = scored[int(pick.get("index", 0))].get("opt", {})
	table["selected_slot"] = int(win.get("slot", -1))
	table["selected_id"] = str(win.get("option_id", "?"))
	table["rolled"] = bool(pick.get("rolled", false))
	table["resolved_target"] = str(win.get("resolved_target", ""))
	table["resolved_destination"] = (win.get("resolved_destination", []) as Array).duplicate()
	table["resolved_command"] = (win.get("resolved_command", {}) as Dictionary).duplicate(true)
	table["compiler"] = "PASS" if bool(win.get("dry_ok", false)) else "FAIL"
	table["target_scores"] = (win.get("target_scores", []) as Array).duplicate(true)
	table["target_match"] = win.get("target_match", null)
	table["target_substitution_reason"] = str(win.get("target_substitution_reason", ""))


# --- per-unit features (same formulas as the mission baseline) ---

static func _row_for(o: Dictionary, unit_rows: Array) -> Dictionary:
	var tid := str(o.get("resolved_target", ""))
	for a_val in unit_rows:
		if str((a_val as Dictionary).get("target_id", "")) == tid:
			return a_val
	return unit_rows[0] if not unit_rows.is_empty() else {}


static func _attack_features(a: Dictionary, mission: Dictionary, advantage: float,
	preserve: float, pressure: float, obs: Dictionary) -> Dictionary:
	var obj: Dictionary = mission.get("objective", {})
	var designated := 0.0
	if str(obj.get("kind", "")) == "ENEMY_FORMATION" and str(obj.get("unit_id", "")) == str(a.get("target_id", "")):
		designated = 1.0
	var class_match := 0.0
	if str(obj.get("kind", "")) == "FORMATION_CLASS" and str(obj.get("class", "")) == str(a.get("target_class", "")):
		class_match = 1.0
	var over := 0.0
	var area := str(mission.get("area", "ANY"))
	if area != "ANY":
		for e_val in (obs.get("known_enemy_units", []) as Array):
			if e_val is Dictionary and str((e_val as Dictionary).get("unit_id", "")) == str(a.get("target_id", "")):
				if str((e_val as Dictionary).get("region", "")).strip_edges().to_upper() != area:
					over = 0.5
	return {"kill": float(a.get("kill_fraction", 0.0)), "loss": float(a.get("loss_fraction", 0.0)),
		"matchup_edge": clampf(float(a.get("matchup", 1.0)) - 1.0, 0.0, 1.0),
		"pressure": pressure, "designated": designated, "class_match": class_match,
		"advantage": advantage, "preserve": preserve, "overextension": over}


static func _move_features(unit: Dictionary, oid: String, mission: Dictionary,
	obs: Dictionary, ctx: Dictionary, resolved_dest: Array, planned: int,
	pressure: float, preserve: float) -> Dictionary:
	var origin := Vector2i(int(unit.get("q", 0)), int(unit.get("r", 0)))
	var point := OptionCls.progress_point(oid, unit, mission, obs, ctx)
	# Score/execute consistency: progress measures the compiler-resolved
	# destination (the hex that will actually execute), never the mere
	# existence of an improving hex. A resolved move away from or past the
	# point earns no progress instead of false progress.
	var dest := Vector2i(-999, -999)
	if resolved_dest.size() >= 2:
		dest = Vector2i(int(resolved_dest[0]), int(resolved_dest[1]))
	var d0 := HexUtilsCls.hex_distance_axial(origin, point)
	var d1 := d0
	var progressed := 0.0
	if dest.x != -999 and dest != origin:
		d1 = HexUtilsCls.hex_distance_axial(dest, point)
		if d1 < d0:
			progressed = 1.0
	var exposed := 0.0
	if _enemy_within(obs, origin, THREAT_RADIUS):
		exposed = 1.0
	return {"progress": progressed, "pressure": pressure,
		"task_fit": _move_fit(str(mission.get("task", ""))),
		"exposure": exposed, "formation_break": 1.0 - float(mini(maxi(planned, 0), 1)),
		"preserve": preserve, "scored_destination": [dest.x, dest.y] if dest.x != -999 else [],
		"progress_point": [point.x, point.y], "dist_before": d0, "dist_after": d1}


static func _hold_features(task: String, advantage: float, has_attacks: bool) -> Dictionary:
	return {"defense": clampf(0.4 + advantage * 0.6, 0.0, 1.0),
		"mission_fit": _hold_fit(task),
		"opportunity": 0.5 if has_attacks else 0.1}


static func _withdraw_features(mission: Dictionary, posture: Dictionary, obs: Dictionary, preserve: float) -> Dictionary:
	var threat := 0.0
	if int(posture.get("blue_visible", 0)) > 0:
		threat = clampf(0.5 * (1.0 - clampf(float(posture.get("advantage_ratio", 0.0)) / 2.0, 0.0, 1.0)) + (0.5 if bool(OpportunityCls.hq_threatened(obs).get("threatened", false)) else 0.0), 0.0, 1.0)
	var hold_pressure := 0.8 if str(mission.get("task", "")) != "WITHDRAW" else 0.1
	return {"threat": threat, "hold_pressure": hold_pressure, "preserve": preserve, "retreat_cost": 0.2}


static func _hold_fit(task: String) -> float:
	match task.strip_edges().to_upper():
		"HOLD", "RESERVE":
			return 1.0
		"FIX":
			return 0.7
		"WITHDRAW", "RECON":
			return 0.3
	return 0.45


static func _move_fit(task: String) -> float:
	match task.strip_edges().to_upper():
		"ADVANCE", "ATTACK", "FLANK":
			return 1.0
		"RECON":
			return 0.9
		"FIX":
			return 0.8
		"HOLD":
			return 0.3
		"RESERVE", "WITHDRAW":
			return 0.2
	return 0.45


# --- small obs helpers ---

static func _visible_enemies(obs: Dictionary) -> Array:
	var out: Array = []
	for e_val in (obs.get("known_enemy_units", []) as Array):
		if e_val is Dictionary and str((e_val as Dictionary).get("contact_state", "")) == "current_visible":
			out.append(e_val)
	return out


static func _nearest_class(visible: Array, origin: Vector2i, cls: String) -> Dictionary:
	var best := {}
	var best_d := 1 << 30
	for e_val in visible:
		if str((e_val as Dictionary).get("class", "")).strip_edges().to_upper() != cls:
			continue
		var d := HexUtilsCls.hex_distance_axial(origin,
			Vector2i(int((e_val as Dictionary).get("q", 0)), int((e_val as Dictionary).get("r", 0))))
		if d < best_d:
			best_d = d
			best = e_val
	return best


static func _nearest_friendly_class(obs: Dictionary, cls: String) -> Dictionary:
	for u_val in (obs.get("friendly_units", []) as Array):
		if u_val is Dictionary and str((u_val as Dictionary).get("class", "")).strip_edges().to_upper() == cls:
			return u_val
	return {}


static func _enemy_within(obs: Dictionary, origin: Vector2i, dist: int) -> bool:
	for e_val in (obs.get("known_enemy_units", []) as Array):
		if not e_val is Dictionary:
			continue
		var e2: Dictionary = e_val
		if str(e2.get("contact_state", "")) != "current_visible":
			continue
		var d := HexUtilsCls.hex_distance_axial(origin,
			Vector2i(int(e2.get("q", 0)), int(e2.get("r", 0))))
		if d <= dist:
			return true
	return false
