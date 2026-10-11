class_name UtilityBotLiveController
extends Node

signal phase_finished(result: Dictionary)

## Human-vs-UtilityBot live adapter. The bot sees only the red knowledge
## projector and a freshly enumerated legal action set. Game mutations remain
## in Step3UnitManager / Step7BattleCommandService.

const UtilityBotCls = preload("res://scripts/utility_bot/utility_bot.gd")
const UtilityBotV1Cls = preload("res://scripts/utility_bot/utility_bot_v1.gd")
const UtilityBotV2Cls = preload("res://scripts/utility_bot/utility_bot_v2.gd")
const UtilityBotGxCls = preload("res://scripts/utility_bot/utility_bot_generalized.gd")
const UtilityProfilesCls = preload("res://scripts/utility_bot/utility_profiles.gd")
const EnumeratorCls = preload("res://scripts/utility_bot/live_legal_enumerator.gd")
const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")
const EpisodeRuntimeCls = preload("res://scripts/episodes/episode_runtime.gd")

const MAX_ACTIONS_PER_PHASE := 240
const MAX_STALE_RETRIES := 8

var shell: Node
var det: Node
var manager: RefCounted
var service: RefCounted
var projector: RefCounted
var red_knowledge: RefCounted  # the acting side's knowledge projector (name kept for callers)
## Acting side. Default "red" keeps every existing mode byte-identical; the watch tool sets "blue".
var side := "red"
var enumerator: RefCounted
var bot: RefCounted
var bot_seed := 1
var dev_difficulty := "V0"
## DEV curriculum (RL ladder) only: a PASSIVE opponent never moves or assaults; it attacks whatever is
## already in range and otherwise WAITs. Default off; the game never sets it.
var dev_passive := false
var mount_ready := false
var mount_error := ""
var auto_mount := true
var last_action := ""
var last_utility := 0.0
var last_phase_result: Dictionary = {}
## Every executed action of this side, oldest first (2026-10-06: read by the commander Brain as battle history;
## GX scoring never reads it). WAITs are not logged.
var action_log: Array = []
var _busy := false
var _debug_panel: PanelContainer
var _debug_label: Label


func _ready() -> void:
	if auto_mount:
		call_deferred("_bootstrap")


func _exit_tree() -> void:
	if shell != null and is_instance_valid(shell) \
			and shell.get("laya_red_controller") == self:
		shell.set("laya_red_controller", null)


func _bootstrap() -> void:
	for _i in range(600):
		shell = get_parent().get_node_or_null("Battle")
		if shell != null and shell.get("unit_manager") != null:
			break
		await get_tree().process_frame
	if shell == null:
		_fail_mount("Battle node unavailable.")
		return
	det = shell.get_node_or_null("Step7Integration")
	for _j in range(600):
		if det != null and bool(det.get("ready_for_step7")):
			break
		await get_tree().process_frame
	if det == null or not bool(det.get("ready_for_step7")):
		_fail_mount("Step7Integration did not become ready.")
		return
	var bound := bind_live(shell, det, true)
	if not bool(bound.get("ok", false)):
		_fail_mount(str(bound.get("error", "Utility Bot bind failed.")))


## Shared live setup for the H-vs-Utility mount and optional bounded Brain
## fallback. The fallback caller owns this node and invokes run_side_phase().
func bind_live(host_shell: Node, step7_node: Node, bind_as_red_controller: bool = false) -> Dictionary:
	shell = host_shell
	det = step7_node
	if shell == null or det == null or not bool(det.get("ready_for_step7")):
		return {"ok": false, "error": "Live shell/Step7Integration is not ready."}
	manager = shell.get("unit_manager") as RefCounted
	service = det.get("command_service") as RefCounted
	projector = det.get("projector") as RefCounted
	red_knowledge = det.get(side + "_service") as RefCounted
	if manager == null or service == null or projector == null or red_knowledge == null:
		return {"ok": false, "error": "Live authorities or RED knowledge projection unavailable."}
	enumerator = EnumeratorCls.new()
	enumerator.call("set_side", side)
	var grid := shell.get("hex_grid") as Node
	var bounds: Dictionary = shell.call("map_bounds") if shell.has_method("map_bounds") else {}
	var err: String = enumerator.call("configure", manager, service, projector, grid,
		bounds, Callable(shell, "_battle_over"),
		shell.get("_river_cells") as Dictionary,
		shell.get("_stronghold_cells") as Dictionary)
	if not err.is_empty():
		return {"ok": false, "error": "Legal action enumerator: " + err}
	bot_seed = _resolve_seed()
	if dev_difficulty in UtilityProfilesCls.PROFILE_IDS or str(dev_difficulty).begins_with("GX"):
		bot = UtilityBotGxCls.new()
	elif dev_difficulty == "V2":
		bot = UtilityBotV2Cls.new()
	elif dev_difficulty == "V1":
		bot = UtilityBotV1Cls.new()
	else:
		bot = UtilityBotCls.new()
	var archetype := OS.get_environment("UTILITY_BOT_ARCHETYPE").strip_edges().to_upper()
	if bot is UtilityBotGxCls and (dev_difficulty in UtilityProfilesCls.PROFILE_IDS or str(dev_difficulty).begins_with("GX")):
		bot.call("configure", bot_seed, str(dev_difficulty))
	else:
		bot.call("configure", bot_seed, archetype)
	if bind_as_red_controller:
		shell.set("laya_red_controller", self)
		_build_debug_panel()
	mount_ready = true
	print("[UtilityBot] live mount ready profile=%s" % JSON.stringify(bot.call("profile")))
	_refresh_debug("Ready")
	return {"ok": true, "seed": bot_seed, "profile": bot.call("profile")}


func _foe() -> String:
	return "blue" if side == "red" else "red"


## Ledger keys of the acting side's knowledge projection (RED and BLUE ledgers name contacts differently).
func _foe_key() -> String:
	return "observed_blue_forces" if side == "red" else "current_enemy_observations"


func _foe_stale_key() -> String:
	return "last_known_blue_contacts" if side == "red" else "last_known_enemy_contacts"


func _resolve_seed() -> int:
	var episode: Dictionary = EpisodeRuntimeCls.current()
	if not episode.is_empty():
		return int((episode.get("seeds", {}) as Dictionary).get("utility", 1))
	var raw := OS.get_environment("UTILITY_BOT_SEED").strip_edges()
	return int(raw) if raw.is_valid_int() else 1


func _fail_mount(reason: String) -> void:
	mount_error = reason
	push_error("[UtilityBot] mount failed: " + reason)
	_refresh_debug("Unavailable: " + reason)


func red_controller_mode() -> String:
	return "UTILITY_BOT" if mount_ready else "DETERMINISTIC"


## V1/V2 sequence the whole unresolved friendly phase from pooled per-unit
## legal sets. V0 keeps its original per-unit queue (frozen behavior).
func _pooled_phase() -> bool:
	return dev_difficulty == "V1" or dev_difficulty == "V2"


func run_red_phase() -> Dictionary:
	if not mount_ready or _busy:
		var unavailable := {"ok": false, "status": "NOT_READY" if not mount_ready else "BUSY", "actions": 0}
		phase_finished.emit(unavailable)
		return unavailable
	last_phase_result = {}
	_busy = true
	var steps := 0
	var after_id := ""
	while steps < MAX_ACTIONS_PER_PHASE and not _battle_over():
		var uid := ""
		var candidates: Array = []
		if _pooled_phase():
			# V1 may sequence the whole unresolved friendly phase. Every offer
			# still comes from the same per-unit authoritative enumerator.
			for unit_val in enumerator.call("unresolved_units"):
				var unit_row: Dictionary = unit_val
				var unit_pool: Dictionary = enumerator.call("enumerate_for_unit", str(unit_row.get("id", "")))
				candidates.append_array(_authorized_candidates(unit_pool.get("candidates", [])))
		else:
			var unit: Dictionary = enumerator.call("next_unresolved_unit", after_id)
			if unit.is_empty():
				break
			uid = str(unit.get("id", ""))
			var pool: Dictionary = enumerator.call("enumerate_for_unit", uid)
			if bool(pool.get("terminal", false)) or _battle_over():
				break
			candidates = _authorized_candidates(pool.get("candidates", []))
		if candidates.is_empty():
			if _pooled_phase() and (enumerator.call("unresolved_units") as Array).is_empty():
				break
			# Human-equivalent per-unit pools always include WAIT. If the
			# authority ever returns no candidates, stop rather than inventing an
			# action or spinning forever.
			push_warning("[UtilityBot] no authorized legal candidate for " + uid)
			break
		var observation := _build_observation()
		var selected: Dictionary = bot.call("select_action", observation, candidates)
		var candidate: Dictionary = selected.get("candidate", {}) as Dictionary
		_trace_decision(observation, candidates, selected)
		if _pooled_phase():
			uid = str(candidate.get("unit_id", ""))
		if not bool(selected.get("ok", false)) or candidate.is_empty():
			push_error("[UtilityBot] selection failed: %s" % str(selected.get("error", "unknown")))
			candidate = _wait_candidate(candidates)
			if candidate.is_empty():
				break
		var result := await _execute_fresh(candidate)
		if not bool(result.get("success", false)):
			# Retry against newly enumerated candidates only. An INVALID from the
			# executor is surfaced and never counted as a successful bot action.
			var recovered := false
			for _retry in range(MAX_STALE_RETRIES):
				if _battle_over():
					break
				var fresh: Dictionary = enumerator.call("enumerate_for_unit", uid)
				var fresh_candidates := _authorized_candidates(fresh.get("candidates", []))
				if fresh_candidates.is_empty():
					break
				var retry_choice: Dictionary = bot.call("select_action", _build_observation(), fresh_candidates)
				var retry_candidate: Dictionary = retry_choice.get("candidate", {}) as Dictionary
				if not bool(retry_choice.get("ok", false)) or retry_candidate.is_empty():
					break
				result = await _execute_fresh(retry_candidate)
				if bool(result.get("success", false)):
					selected = retry_choice
					candidate = retry_candidate
					recovered = true
					break
			if not recovered:
				push_error("[UtilityBot] action execution failed id=%s result=%s" % [
					str(candidate.get("candidate_id", "")), JSON.stringify(result)])
				var wait_cand := _wait_candidate(_authorized_candidates(
					enumerator.call("enumerate_for_unit", uid).get("candidates", [])))
				if wait_cand.is_empty() or wait_cand.get("candidate_id", "") == candidate.get("candidate_id", ""):
					break
				result = await _execute_fresh(wait_cand)
				candidate = wait_cand
				selected = {"score": 0.0}
				if not bool(result.get("success", false)):
					break
		steps += 1
		last_action = str(candidate.get("action_type", "?")) + " " + str(candidate.get("unit_id", ""))
		last_utility = float(selected.get("score", 0.0))
		_refresh_debug("Turn %d · %s · utility %.2f" % [
			int(manager.call("get_current_turn")), last_action, last_utility])
		if bool(enumerator.call("is_unit_id_resolved", uid)):
			after_id = uid
		if not _no_wait():  # GX_NO_WAIT=1: diagnostic only (2026-10-08: skipping the waits changed outcomes)
			await get_tree().create_timer(0.08).timeout
	if steps >= MAX_ACTIONS_PER_PHASE and not _battle_over():
		push_warning("[UtilityBot] phase action cap reached (%d)." % MAX_ACTIONS_PER_PHASE)
	_busy = false
	last_phase_result = {"ok": mount_ready and mount_error.is_empty(), "status": "UTILITY_BOT",
		"actions": steps, "seed": bot_seed, "profile": bot.call("profile"),
		"terminal": _battle_over(), "last_action": last_action,
		"last_utility": last_utility}
	phase_finished.emit(last_phase_result.duplicate(true))
	return last_phase_result.duplicate(true)


## Alias used by the opt-in Brain fallback seam. This resolves only the
## current RED phase and leaves normal Brain planning eligible next time.
func run_side_phase() -> Dictionary:
	var result: Dictionary = await run_red_phase()
	if bool(result.get("ok", false)):
		result["status"] = "UTILITY_BOT_FALLBACK"
	return result


func _authorized_candidates(raw_candidates: Array) -> Array:
	var allowed_contacts := {}
	var knowledge: Dictionary = red_knowledge.build(int(manager.call("get_current_turn")))
	for key in [_foe_key()]:
		for row_val in knowledge.get(key, []):
			if row_val is Dictionary:
				var contact_row := row_val as Dictionary
				allowed_contacts[str(contact_row.get("id", ""))] = str(contact_row.get("class", "unknown"))
	var out: Array = []
	for raw in raw_candidates:
		if not raw is Dictionary:
			continue
		var candidate: Dictionary = raw as Dictionary
		if dev_passive and str(candidate.get("action_type", "")) in ["MOVE", "ASSAULT"]:
			continue
		if str(candidate.get("action_type", "")) == "MOVE":
			var destination: Array = candidate.get("destination", [])
			if destination.size() < 2:
				continue
			var route: Variant = service.call("preview_move_route", str(candidate.get("unit_id", "")),
				Vector2i(int(destination[0]), int(destination[1])), side, "green")
			if route == null or not bool(route.found) or not bool(route.is_valid_destination):
				continue
			var route_visible := true
			for step_val in route.path:
				var step: Vector2i = step_val
				if not bool(projector.call("is_hex_visible_for_side", side, step.x, step.y)):
					route_visible = false
					break
			if not route_visible:
				continue
		# A breached stronghold's hidden garrison roster is not part of RED's
		# projected knowledge. Do not expose its private target ids to scoring.
		if str(candidate.get("action_type", "")) == "ASSAULT":
			var garrison_target := str(candidate.get("garrison_target_id", ""))
			if not garrison_target.is_empty() and not allowed_contacts.has(garrison_target):
				continue
		var visible_candidate := candidate.duplicate(true)
		if str(visible_candidate.get("action_type", "")) == "ATTACK":
			var target := str(visible_candidate.get("target_id", ""))
			var preview: Dictionary = service.call("preview_attack", str(visible_candidate.get("unit_id", "")), target, side)
			visible_candidate["target_class"] = str(allowed_contacts.get(target, "unknown"))
			if bool(preview.get("ok", false)):
				visible_candidate["expected_enemy_casualties_min"] = int(preview.get("expected_enemy_casualties_min", 0))
				visible_candidate["expected_enemy_casualties_max"] = int(preview.get("expected_enemy_casualties_max", 0))
				visible_candidate["expected_friendly_casualties_min"] = int(preview.get("expected_friendly_casualties_min", 0))
				visible_candidate["expected_friendly_casualties_max"] = int(preview.get("expected_friendly_casualties_max", 0))
				if visible_candidate["target_class"] == "hq":
					if int(preview.get("expected_enemy_casualties_min", 0)) >= int(preview.get("defender_troops", 1)):
						visible_candidate["guaranteed_enemy_hq_kill"] = true
		out.append(visible_candidate)
	return out


func _build_observation() -> Dictionary:
	var turn := int(manager.call("get_current_turn"))
	var ledger: Dictionary = red_knowledge.build(turn)
	var friendly: Array = []
	for row_val in ledger.get("own_forces", []):
		if not row_val is Dictionary:
			continue
		var row: Dictionary = (row_val as Dictionary).duplicate(true)
		row["unit_id"] = str(row.get("id", ""))
		row["side"] = side.to_upper()
		row["soldiers"] = int(row.get("soldier_count", 0))
		row["status"] = "routed" if bool(row.get("routed", false)) else ("acted" if bool(row.get("action_ended", false)) else "ready")
		var strength_ratio := float(row.get("soldier_count", 0)) / float(maxi(1, int(row.get("max_count", 1))))
		row["condition"] = "critical" if strength_ratio < 0.25 else ("weakened" if strength_ratio < 0.5 else ("worn" if strength_ratio < 0.75 else "healthy"))
		friendly.append(row)
	var enemies: Array = []
	for key in [_foe_key(), _foe_stale_key()]:
		for row_val in ledger.get(key, []):
			if not row_val is Dictionary:
				continue
			var row: Dictionary = row_val as Dictionary
			var contact := "current_visible" if key == _foe_key() else "stale_last_known"
			var troop_text := str(row.get("troop_text", "unknown"))
			var enemy_view := {
				"unit_id": str(row.get("id", "")), "side": _foe().to_upper(),
				"class": str(row.get("class", "unknown")),
				"q": int(row.get("q", 0)), "r": int(row.get("r", 0)),
				"contact_state": contact,
				"troop_text": troop_text,
				"troop_estimate": troop_text,
				"last_seen_turn": int(row.get("contact_turn", row.get("last_seen_turn", 0))),
			}
			var estimate := _troop_band_midpoint(troop_text)
			if estimate > 0:
				enemy_view["troop_estimate"] = str(estimate)
			enemies.append(enemy_view)
	return {
		"schema_version": "utility_live_red_v0",
		"episode_id": EpisodeRuntimeCls.episode_id(),
		"ruleset_override": EpisodeRuntimeCls.rules(),
		"scenario_id": "live_step2r_battle",
		"side": side.to_upper(),
		"turn": turn,
		"phase": "ENGAGE",
		"board": {"dimensions": shell.call("map_bounds") if shell.has_method("map_bounds") else {}},
		"mission": {"type": "destroy_%s_hq" % _foe(), "objective": "Destroy the %s HQ; losing the %s HQ is immediate defeat." % [_foe().to_upper(), side.to_upper()]},
		"friendly_units": friendly,
		"known_enemy_units": enemies,
		"strongholds": [],
		"recent_events": [],
	}


func _wait_candidate(candidates: Array) -> Dictionary:
	for row_val in candidates:
		if row_val is Dictionary and str((row_val as Dictionary).get("action_type", "")) == "WAIT":
			return row_val as Dictionary
	return {}


func _troop_band_midpoint(text: String) -> int:
	var clean := text.replace(",", "")
	var values: Array[int] = []
	for segment in clean.split("~"):
		var digits := ""
		for i in range(str(segment).length()):
			var ch := str(segment).substr(i, 1)
			if ch.is_valid_int():
				digits += ch
		if not digits.is_empty():
			values.append(int(digits))
	if values.size() >= 2:
		return int((values[0] + values[1]) / 2)
	if values.size() == 1 and clean.contains("약"):
		return values[0]
	return 0


func _execute_fresh(candidate: Dictionary) -> Dictionary:
	if _battle_over():
		return {"success": false, "code": "BATTLE_ALREADY_TERMINAL"}
	var current: Dictionary = enumerator.call("revalidate", candidate)
	if not bool(current.get("ok", false)):
		return {"success": false, "code": str(current.get("code", "INVALID")), "error": "Candidate failed fresh legality check."}
	var result: Dictionary = await _execute(candidate)
	if bool(result.get("success", false)):
		var truth: RefCounted = det.get("truth") as RefCounted
		if truth != null:
			truth.call("notify_mutation", "utility_bot_" + str(candidate.get("action_type", "action")).to_lower())
		_log_action(candidate, result)
	return result


func _log_action(candidate: Dictionary, result: Dictionary) -> void:
	var kind := str(candidate.get("action_type", ""))
	if kind == "WAIT" or manager == null:
		return
	var uid := str(candidate.get("unit_id", ""))
	var ev := {"turn": int(manager.call("get_current_turn")), "side": side.to_upper(), "unit": uid, "do": kind,
		"seen_by_foe": projector != null and bool(projector.call("is_contact_visible", _foe(), uid))}
	match kind:
		"MOVE":
			ev["from"] = candidate.get("origin", [])
			ev["to"] = candidate.get("destination", [])
		"ATTACK":
			ev["seen_by_foe"] = true  # the side that was hit always knows who hit it
			ev["target"] = str(candidate.get("target_id", ""))
			ev["dealt"] = int(result.get("defender_casualties", 0))
			ev["took"] = int(result.get("attacker_casualties", 0))
			ev["fieldworks"] = int(result.get("field_fortification_damage", 0))
			ev["destroyed"] = bool(result.get("defender_destroyed", false))
			ev["attacker_destroyed"] = bool(result.get("attacker_destroyed", false))
		"ASSAULT", "ENTER_GARRISON":
			ev["target"] = str(candidate.get("stronghold_id", ""))
	action_log.append(ev)


func _execute(candidate: Dictionary) -> Dictionary:
	var kind := str(candidate.get("action_type", ""))
	var uid := str(candidate.get("unit_id", ""))
	var renderer := shell.get("unit_renderer") as Node
	match kind:
		"MOVE":
			var d: Array = candidate.get("destination", [])
			if d.size() < 2:
				return {"success": false, "code": "BAD_DESTINATION"}
			var moved: Dictionary = service.call("execute_move_intent", uid,
				Vector2i(int(d[0]), int(d[1])), side, "green")
			if bool(moved.get("success", false)):
				if renderer != null and renderer.has_method("update_unit_position"):
					renderer.call("update_unit_position", uid, int(d[0]), int(d[1]))
				shell.call("_fog_recalc", "enemy_move")
				shell.call("_show_combat_log", "[%s] UtilityBot MOVE" % uid)
			return moved
		"ATTACK":
			var target := str(candidate.get("target_id", ""))
			var s6: RefCounted = shell.get("_step6") as RefCounted
			var mods: Dictionary = s6.call("attacker_bonus_vs", manager, uid, target) if s6 != null else {}
			var atk: Dictionary = manager.call("get_unit_by_id", uid)
			var def: Dictionary = manager.call("get_unit_by_id", target)
			var result: Dictionary = service.call("execute_attack_intent", uid, target, side, mods)
			if bool(result.get("success", false)):
				await _present_attack(uid, target, atk, def, result)
			return result
		"ASSAULT":
			var assaulted: Dictionary = manager.call("execute_stronghold_assault", uid,
				str(candidate.get("stronghold_id", "")), str(candidate.get("garrison_target_id", "")), {})
			if bool(assaulted.get("success", false)):
				shell.call("_fog_recalc", "enemy_attack")
				shell.call("_show_combat_log", "[%s] UtilityBot ASSAULT" % uid)
			return assaulted
		"WAIT":
			var held: Dictionary = service.call("execute_hold_intent", uid, side)
			if bool(held.get("success", false)) and renderer != null:
				renderer.call("set_unit_dimmed", uid, true)
			return held
		"REST":
			if not bool(manager.call("can_unit_rest", uid)):
				return {"success": false, "code": "REST_NOT_LEGAL"}
			var rested: Dictionary = manager.call("rest_unit", uid)
			if bool(rested.get("success", false)) and renderer != null:
				renderer.call("set_unit_dimmed", uid, true)
				if renderer.has_method("set_unit_resting"):
					renderer.call("set_unit_resting", uid, true)
			return rested
		"FORTIFY":
			if not bool(manager.call("can_unit_fortify", uid)):
				return {"success": false, "code": "FORTIFY_NOT_LEGAL"}
			var fortified: Dictionary = manager.call("fortify_unit", uid)
			if bool(fortified.get("success", false)) and renderer != null:
				renderer.call("set_unit_dimmed", uid, true)
				renderer.call("set_unit_fortified", uid, true)
			return fortified
		"DISMANTLE":
			if not bool(manager.call("can_dismantle_fortification", uid)):
				return {"success": false, "code": "DISMANTLE_NOT_LEGAL"}
			var dismantled: Dictionary = manager.call("dismantle_fortification", uid)
			if bool(dismantled.get("success", false)) and renderer != null:
				renderer.call("set_unit_fortified", uid, false)
			return dismantled
		"ENTER_GARRISON":
			var entered: Dictionary = manager.call("garrison_enter", uid, str(candidate.get("stronghold_id", "")))
			if bool(entered.get("success", false)) and renderer != null:
				renderer.call("remove_unit", uid)
			return entered
	return {"success": false, "code": "UNKNOWN_ACTION", "action_type": kind}


func _present_attack(uid: String, target: String, atk: Dictionary, def: Dictionary, result: Dictionary) -> void:
	var atk_coord := Vector2i(int(atk.get("q", 0)), int(atk.get("r", 0)))
	var def_coord := Vector2i(int(def.get("q", 0)), int(def.get("r", 0)))
	shell.set("_is_animating_combat", true)
	var renderer := shell.get("unit_renderer") as Node
	if renderer != null:
		renderer.call("animate_unit_attack", uid, def_coord)
	if not _no_wait():
		await get_tree().create_timer(0.15).timeout
	if renderer != null:
		var def_cas := int(result.get("defender_casualties", 0))
		if def_cas > 0:
			renderer.call("animate_unit_hit", target, def_cas)
		renderer.call("update_unit_health", target, int(result.get("defender_remaining_troops", 0)))
		if bool(result.get("defender_destroyed", false)):
			renderer.call("remove_unit", target)
		var atk_cas := int(result.get("attacker_casualties", 0))
		if atk_cas > 0:
			renderer.call("animate_unit_hit", uid, atk_cas)
		renderer.call("update_unit_health", uid, int(result.get("attacker_remaining_troops", 0)))
		if bool(result.get("attacker_destroyed", false)):
			renderer.call("remove_unit", uid)
		elif bool(result.get("attacker_action_ended", true)):
			renderer.call("set_unit_dimmed", uid, true)
	shell.call("_fog_mark_engaged", uid)
	shell.set("_fog_recent_combat", true)
	shell.call("_fog_recalc", "enemy_attack")
	shell.call("_s6_after_combat", result, uid, target, atk_coord, def_coord)
	shell.call("_show_combat_log", "[%s] UtilityBot ATTACK -> [%s]" % [uid, target])
	shell.set("_is_animating_combat", false)


func _battle_over() -> bool:
	return shell != null and shell.has_method("_battle_over") and bool(shell.call("_battle_over"))


func _build_debug_panel() -> void:
	var hud := shell.get("hud_layer") as CanvasLayer
	if hud == null:
		return
	_debug_panel = PanelContainer.new()
	_debug_panel.name = "UtilityBotDebug"
	_debug_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_debug_panel.offset_left = -290
	_debug_panel.offset_top = 8
	_debug_panel.offset_right = -8
	_debug_panel.offset_bottom = 72
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.06, 0.08, 0.10, 0.78)
	box.border_width_left = 1
	box.border_width_top = 1
	box.border_width_right = 1
	box.border_width_bottom = 1
	box.border_color = Color(0.35, 0.65, 0.58, 0.8)
	_debug_panel.add_theme_stylebox_override("panel", box)
	_debug_label = Label.new()
	_debug_label.add_theme_font_size_override("font_size", 12)
	_debug_label.add_theme_color_override("font_color", Color(0.82, 0.92, 0.87))
	_debug_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_debug_panel.add_child(_debug_label)
	hud.add_child(_debug_panel)
	_refresh_debug("Ready")


func _refresh_debug(status: String) -> void:
	if _debug_label == null or not is_instance_valid(_debug_label):
		return
	var p: Dictionary = bot.call("profile") if bot != null else {}
	var tier: String = str({"V1": "INTERMEDIATE", "V2": "ADVANCED"}.get(dev_difficulty, "NOVICE"))
	if bot != null:
		tier = str((bot.call("profile") as Dictionary).get("tier", tier))
	_debug_label.text = "UTILITY BOT %s — %s · %s · seed %d\n%s" % [
		dev_difficulty, tier, str(p.get("archetype", "pending")), bot_seed, status]


func _no_wait() -> bool:
	return OS.get_environment("GX_NO_WAIT") == "1"


## GX_TRACE_DIR set: append the inputs and choice of each turn-1 decision (diagnostic only, 2026-10-08).
func _trace_decision(observation: Dictionary, candidates: Array, selected: Dictionary) -> void:
	var d := OS.get_environment("GX_TRACE_DIR")
	if d.is_empty() or int(manager.call("get_current_turn")) > 1:
		return
	var path := d.path_join("%s_%s.jsonl" % [OS.get_environment("GX_TRACE_TAG"), side])
	var f := FileAccess.open(path, FileAccess.READ_WRITE) if FileAccess.file_exists(path) else FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	f.store_line(JSON.stringify({"observation": observation, "candidates": candidates, "selected": selected,
		"profile": bot.call("profile")}))
	f.close()
