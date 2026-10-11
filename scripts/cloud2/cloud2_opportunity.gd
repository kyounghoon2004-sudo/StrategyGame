class_name Cloud2Opportunity
extends RefCounted

## CLOUD-GENERAL MISSION HIERARCHY — deterministic opportunity enumeration.
##
## Godot already knows legality; neither the General nor the MissionControllers
## infer it. This layer turns authoritative reads into candidate sets:
##   attacks:  manager.get_attackable_targets (geometry + acted gating) ∩
##             RED-authorized visible contacts, enriched with the authoritative
##             service.preview_attack casualty preview.
##   movement: service.reachable_area (authoritative envelope) + Compiler
##             dry-run feasibility (the controller probes intents with
##             Cloud1Compiler.plan, which never mutates).
##   posture:  local advantage / commitment / HQ-threat / exposure facts over
##             the RED observation, with named thresholds (observable below).
##
## Read-only. No network, no mutation, no game truth owned here.

const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")
const CombatCls = preload("res://scripts/combat/combat_calculator.gd")

## HQ is threatened when a currently-visible BLUE formation closes inside
## this hex range of the RED HQ. Named + single-sourced for observability.
const HQ_THREAT_RANGE := 4
## Local advantage counts as HIGH at/above this friendly:enemy soldier ratio
## (blue estimates parsed from troop_estimate when numeric).
const ADVANTAGE_HIGH_RATIO := 1.5
## Commitment counts as HIGH at/above this many visible BLUE formations in
## one region (params may override per trigger evaluation).
const COMMITMENT_HIGH_COUNT := 3
## High-value classes whose isolation reads as OBJECTIVE_EXPOSED.
const EXPOSED_CLASSES := ["ARCHER", "SIEGE", "HQ", "SCOUT"]


## All legal attack opportunities for the given unit ids (side's own).
## Each row: {attacker_id, attacker_class, target_id, target_class, distance,
## matchup, expected_enemy_casualties_max, expected_friendly_casualties_max,
## kill_fraction, loss_fraction}. Sorted by target id, then attacker id.
## SYMMETRIC V1: side threads the authoritative service gates (default red).
static func legal_attacks(sim: RefCounted, unit_ids: Array, obs: Dictionary, side: String = "red") -> Array:
	var out: Array = []
	if sim == null:
		return out
	var mgr: RefCounted = sim.get_manager()
	var svc: RefCounted = sim.get_service()
	if mgr == null or svc == null:
		return out
	var visible := {}
	for e_val in (obs.get("known_enemy_units", []) as Array):
		if e_val is Dictionary and str((e_val as Dictionary).get("contact_state", "")) == "current_visible":
			visible[str((e_val as Dictionary).get("unit_id", "")).strip_edges().to_upper()] = e_val
	if visible.is_empty():
		return out
	for uid_val in unit_ids:
		var uid := str(uid_val).strip_edges().to_upper()
		var atk: Dictionary = mgr.get_unit_by_id(uid)
		if atk.is_empty():
			continue
		var atk_class := str(atk.get("class", "")).to_upper()
		var atk_sol := maxi(1, int(atk.get("soldier_count", 1)))
		var targets: Array = mgr.get_attackable_targets(uid)
		for t_val in targets:
			if not t_val is Dictionary:
				continue
			var t: Dictionary = t_val
			var tid := str(t.get("id", "")).strip_edges().to_upper()
			if not visible.has(tid):
				continue # side-authorized knowledge only (mirrors the compiler's visibility rule)
			var preview: Dictionary = svc.preview_attack(uid, tid, side)
			if not bool(preview.get("ok", false)):
				continue
			var def_sol := maxi(1, int(preview.get("defender_troops", t.get("soldier_count", 1))))
			var ekill := float(preview.get("expected_enemy_casualties_max", 0))
			var floss := float(preview.get("expected_friendly_casualties_max", 0))
			out.append({
				"attacker_id": uid,
				"attacker_class": atk_class,
				"target_id": tid,
				"target_class": str(t.get("class", "")).to_upper(),
				"distance": int(t.get("distance", preview.get("distance", 1))),
				"matchup": float(preview.get("matchup_multiplier", CombatCls.get_matchup_mult(atk_class.to_lower(), str(t.get("class", "")).to_lower()))),
				"expected_enemy_casualties_max": ekill,
				"expected_friendly_casualties_max": floss,
				"kill_fraction": clampf(ekill / float(def_sol), 0.0, 1.0),
				"loss_fraction": clampf(floss / float(atk_sol), 0.0, 1.0),
			})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if str(a.get("target_id", "")) != str(b.get("target_id", "")):
			return str(a.get("target_id", "")) < str(b.get("target_id", ""))
		return str(a.get("attacker_id", "")) < str(b.get("attacker_id", "")))
	return out


## Authoritative reachable envelope for one unit (passthrough shape guard).
static func reachable(sim: RefCounted, unit_id: String, march_mode: String = "auto", side: String = "red") -> Dictionary:
	if sim == null:
		return {"ok": false, "error": "No battle bound.", "reachable": []}
	var svc: RefCounted = sim.get_service()
	if svc == null:
		return {"ok": false, "error": "No command service.", "reachable": []}
	var area: Dictionary = svc.reachable_area(unit_id, side, march_mode)
	if not bool(area.get("ok", false)):
		return {"ok": false, "error": str(area.get("error", "No reachable area.")), "reachable": []}
	return area


## Best (lowest-cost) reachable hex minimizing distance to a target point,
## or {} when no reachable hex improves on the origin. Pure scoring input —
## the compiler still chooses the executed destination.
static func best_progress_hex(area: Dictionary, origin: Vector2i, target: Vector2i) -> Dictionary:
	var best := {}
	var best_key := 1 << 30
	var best_cost := 1e30
	var d0 := HexUtilsCls.hex_distance_axial(origin, target)
	for e_val in (area.get("reachable", []) as Array):
		if not e_val is Dictionary:
			continue
		var e2: Dictionary = e_val
		var c := Vector2i(int(e2.get("q", -999)), int(e2.get("r", -999)))
		if c.x == -999 or c == origin:
			continue
		var d := HexUtilsCls.hex_distance_axial(c, target)
		if d >= d0:
			continue
		var cost := float(e2.get("cost", 1.0))
		if d < best_key or (d == best_key and cost < best_cost):
			best_key = d
			best_cost = cost
			best = {"q": c.x, "r": c.y, "dist": d, "from_dist": d0, "cost": cost}
	return best


## Friendly/enemy posture inside one region (or "ANY" for the whole field).
static func region_posture(obs: Dictionary, region: String) -> Dictionary:
	var want := region.strip_edges().to_upper()
	var red_units := 0
	var red_soldiers := 0
	var red_ready := 0
	for u_val in (obs.get("friendly_units", []) as Array):
		if not u_val is Dictionary:
			continue
		var u: Dictionary = u_val
		if want != "ANY" and str(u.get("region", "")).strip_edges().to_upper() != want:
			continue
		red_units += 1
		red_soldiers += int(u.get("soldiers", 0))
		if str(u.get("status", "")) == "ready":
			red_ready += 1
	var blue_visible := 0
	var blue_soldiers := 0
	for e_val in (obs.get("known_enemy_units", []) as Array):
		if not e_val is Dictionary:
			continue
		var e2: Dictionary = e_val
		if str(e2.get("contact_state", "")) != "current_visible":
			continue
		if want != "ANY" and str(e2.get("region", "")).strip_edges().to_upper() != want:
			continue
		blue_visible += 1
		blue_soldiers += _estimate_troops(str(e2.get("troop_estimate", "")))
	# No observed enemy means NO measured advantage (0.0), never an
	# infinite one: the ratio is relative, and holding against nothing
	# observed must not read as maximum defensive value. The same holds
	# when visible enemies carry no stated strength at all (unknown
	# estimates): unmeasured strength is not maximum advantage either.
	var ratio := 0.0
	if blue_visible > 0 and blue_soldiers > 0:
		ratio = float(red_soldiers) / float(blue_soldiers)
	return {
		"region": want,
		"red_units": red_units,
		"red_soldiers": red_soldiers,
		"red_ready": red_ready,
		"blue_visible": blue_visible,
		"blue_soldiers_estimate": blue_soldiers,
		"advantage_ratio": ratio,
	}


## Resolve authorized enemy strength text to a planning number. The fog layer
## never emits a bare integer: scout contacts read "약 150~250" (range) and
## combat-assessed contacts read "약 450명" (approximate, thousands-grouped);
## unknown contacts read "병력: ???" / "병력: 알 수 없음" / "unknown". A
## stated range resolves to its midpoint, a single stated number to itself,
## and unknown stays 0 (no measured strength, never infinite advantage).
static func _estimate_troops(text: String) -> int:
	var t := text.strip_edges().replace(",", "")
	var nums: Array = []
	var cur := ""
	for i in range(t.length()):
		var c := t.substr(i, 1)
		if c >= "0" and c <= "9":
			cur += c
		elif not cur.is_empty():
			nums.append(int(cur))
			cur = ""
	if not cur.is_empty():
		nums.append(int(cur))
	if nums.size() >= 2:
		return maxi(0, (int(nums[0]) + int(nums[1])) / 2)
	if nums.size() == 1:
		return maxi(0, int(nums[0]))
	return 0


static func local_advantage_high(posture: Dictionary, ratio: float = ADVANTAGE_HIGH_RATIO) -> bool:
	return int(posture.get("blue_visible", 0)) > 0 and float(posture.get("advantage_ratio", 0.0)) >= ratio


static func enemy_commitment(obs: Dictionary, region: String) -> int:
	return int(region_posture(obs, region).get("blue_visible", 0))


## RED HQ threatened? True when a visible BLUE formation is inside
## HQ_THREAT_RANGE of the RED HQ. A missing HQ reads as NOT threatened
## (no HQ on the field means nothing to threaten; the mission judgment
## already covers HQ loss as battle outcome, not as a review trigger).
static func hq_threatened(obs: Dictionary) -> Dictionary:
	var hq := Vector2i(-999, -999)
	for u_val in (obs.get("friendly_units", []) as Array):
		if u_val is Dictionary and str((u_val as Dictionary).get("class", "")).to_upper() == "HQ":
			hq = Vector2i(int((u_val as Dictionary).get("q", 0)), int((u_val as Dictionary).get("r", 0)))
	if hq.x == -999:
		return {"threatened": false, "reason": "HQ_MISSING", "nearest": -1, "nearest_id": ""}
	var nearest := 1 << 30
	var nearest_id := ""
	for e_val in (obs.get("known_enemy_units", []) as Array):
		if not e_val is Dictionary:
			continue
		var e2: Dictionary = e_val
		if str(e2.get("contact_state", "")) != "current_visible":
			continue
		var d := HexUtilsCls.hex_distance_axial(hq, Vector2i(int(e2.get("q", 0)), int(e2.get("r", 0))))
		if d < nearest:
			nearest = d
			nearest_id = str(e2.get("unit_id", ""))
	if nearest > HQ_THREAT_RANGE:
		return {"threatened": false, "reason": "", "nearest": nearest, "nearest_id": nearest_id}
	return {"threatened": true, "reason": "ENEMY_NEAR_HQ", "nearest": nearest, "nearest_id": nearest_id}


## High-value BLUE formations with no visible BLUE escort within 1 hex.
static func exposed_objectives(obs: Dictionary) -> Array:
	var blues: Array = []
	for e_val in (obs.get("known_enemy_units", []) as Array):
		if e_val is Dictionary and str((e_val as Dictionary).get("contact_state", "")) == "current_visible":
			blues.append(e_val)
	var out: Array = []
	for b_val in blues:
		var b: Dictionary = b_val
		if not str(b.get("class", "")).to_upper() in EXPOSED_CLASSES:
			continue
		var bc := Vector2i(int(b.get("q", 0)), int(b.get("r", 0)))
		var escorted := false
		for o_val in blues:
			var o: Dictionary = o_val
			if str(o.get("unit_id", "")) == str(b.get("unit_id", "")):
				continue
			if HexUtilsCls.hex_distance_axial(bc, Vector2i(int(o.get("q", 0)), int(o.get("r", 0)))) <= 1:
				escorted = true
				break
		if not escorted:
			out.append(b)
	out.sort_custom(func(a: Dictionary, b2: Dictionary) -> bool: return str(a.get("unit_id", "")) < str(b2.get("unit_id", "")))
	return out


static func enemy_class_detected(obs: Dictionary, unit_class: String, region: String = "ANY") -> Array:
	var want := unit_class.strip_edges().to_upper()
	var reg := region.strip_edges().to_upper()
	var out: Array = []
	for e_val in (obs.get("known_enemy_units", []) as Array):
		if not e_val is Dictionary:
			continue
		var e2: Dictionary = e_val
		if str(e2.get("contact_state", "")) != "current_visible":
			continue
		if str(e2.get("class", "")).to_upper() != want:
			continue
		if reg != "ANY" and str(e2.get("region", "")).strip_edges().to_upper() != reg:
			continue
		out.append(e2)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.get("unit_id", "")) < str(b.get("unit_id", "")))
	return out
