class_name SymLocMount
extends Node

## SYMMETRIC LOCAL-vs-LOCAL SANDBOX V1 — DEV observable sandbox.
##
## LOCAL BRAIN + LAYA (RED) vs LOCAL BRAIN + LAYA (BLUE).
## Both sides use the SAME classes and decision interfaces:
##   Brain ..... LayaController (Cloud2TurnController hierarchy:
##               VictoryPlan -> missions -> coordinator -> blackboard)
##               + Cloud2Config/Cloud2Adapter LOCAL provider (ollama|custom)
##   Hands ..... Laya per-unit sequential (shared owned worker)
##   Authority . Godot (legality, occupancy, movement, combat, fog, outcome)
##
## RED and BLUE differ ONLY by side identity + side-local observation.
## No advisor shortcut, no scripted BLUE, no human NEXT/END TURN input:
## the mount drives BLUE directly and the shell routes RED through the
## bound controller (same routing Human-vs-Cloud uses).
##
## Opening fairness (recorded in match metadata): BLUE moves first (the
## shell-native order), but BOTH Brains prefetch their INITIAL VictoryPlan
## from the same frozen boot snapshot before BLUE acts — equal boot
## precompute, no hidden planning information either way.
##
## NO TRAINING here: no QLoRA/PPO/GRPO/gradients/updates of any kind.
## Match results expose the +5/-3/-2 contract as TELEMETRY ONLY.

const BridgeCls = preload("res://scripts/cloud1/cloud1_live_bridge.gd")
const ExecutorCls = preload("res://scripts/cloud1/cloud1_live_executor.gd")
const ConfigCls = preload("res://scripts/cloud2/cloud2_config.gd")
const SessionCls = preload("res://scripts/cloud2/cloud2_session.gd")
const AdapterCls = preload("res://scripts/cloud2/cloud2_adapter.gd")
const PlanCls = preload("res://scripts/cloud2/cloud2_plan_memory.gd")
const ObsCls = preload("res://scripts/cloud1/cloud1_observation.gd")
const LayaControllerCls = preload("res://scripts/laya/laya_controller.gd")
const LYLaunchCls = preload("res://scripts/laya/laya_launcher.gd")
const MatchCls = preload("res://scripts/symloc/symloc_match.gd")
const BrainCls = preload("res://scripts/symloc/symloc_brain.gd")
## TRAINING_CONTRACT_REVIEW_WAKE_V1 (additive): explicit TRAINING/EVAL
## STRICT poll. No-op unless TRAINING_STRICT_CONTRACT is on.
const StrictCls = preload("res://scripts/selfplay/training_strict.gd")

const BOOT_POLL_SEC := 0.5
const HUD_POLL_SEC := 0.5
const OPENING_RULE := "BLUE_FIRST_WITH_SYMMETRIC_BOOT_PREFETCH"

var shell: Node = null
var det: Node = null
var bridge: RefCounted = null
var executor: ExecutorCls = null
var red_config: ConfigCls = null
var blue_config: ConfigCls = null
var red_adapter: AdapterCls = null
var blue_adapter: AdapterCls = null
var red_plan: PlanCls = null
var blue_plan: PlanCls = null
## The TWO symmetric side controllers: same class, same interface.
var red_controller: LayaControllerCls = null
var blue_controller: LayaControllerCls = null

var mount_ready := false
var mount_error := ""
var match_result := {}
var match_over := false
var match_meta := {}
var fog_rows: Array = []

var _hud: PanelContainer = null
var _hud_lines: Array = []
var _boot_task := 0
var _hud_task := 0
var _loop_task := 0
var _brain_probes := {}


func _ready() -> void:
	print("[SymLoc] _ready called")
	call_deferred("_bootstrap")


func _exit_tree() -> void:
	_boot_task += 1
	_hud_task += 1
	_loop_task += 1
	var res: Dictionary = LYLaunchCls.shutdown_owned()
	print("[SymLoc] worker shutdown: %s" % JSON.stringify(res))


func is_ready() -> bool:
	return mount_ready and bridge != null and bridge.is_loaded() \
		and red_controller != null and blue_controller != null \
		and shell != null and shell.get("cloud_red_controller") == red_controller


func get_match_result() -> Dictionary:
	return match_result.duplicate(true)


func get_side_status() -> Dictionary:
	return {
		"mount_ready": mount_ready,
		"mount_error": mount_error,
		"red_brain": BrainCls.backend_label(red_config),
		"blue_brain": BrainCls.backend_label(blue_config),
		"red_hands": "LAYA_LIVE",
		"blue_hands": "LAYA_LIVE",
		"red_side": str(red_controller.get_side()) if red_controller != null else "?",
		"blue_side": str(blue_controller.get_side()) if blue_controller != null else "?",
		"match_over": match_over,
	}


func _bootstrap() -> void:
	print("[SymLoc] _bootstrap starting")
	# Legacy JEV stays out of this sandbox: the shadow observer is
	# telemetry-only, and disabling it here keeps the hands path purely
	# Laya on both sides (documented process-wide DEV side effect).
	OS.set_environment("JEV_SHADOW_ENABLE", "0")
	for _i in range(600):
		shell = get_parent().get_node_or_null("Battle")
		if shell != null and shell.get("unit_manager") != null and shell.get("hud_layer") != null:
			break
		await get_tree().process_frame
	if shell == null or shell.get("unit_manager") == null or shell.get("hud_layer") == null:
		mount_error = "Battle dependencies not found."
		push_warning("[SymLoc] %s" % mount_error)
		return
	det = shell.get_node_or_null("Step7Integration")
	for _j in range(600):
		if det != null and bool(det.get("ready_for_step7")):
			break
		await get_tree().process_frame
	if det == null or not bool(det.get("ready_for_step7")):
		mount_error = "Step7Integration not ready."
		push_warning("[SymLoc] %s" % mount_error)
		return
	bridge = BridgeCls.new()
	if not bridge.bind(shell, det):
		mount_error = "Bridge binding failed."
		push_warning("[SymLoc] %s" % mount_error)
		return
	executor = ExecutorCls.new()
	executor.name = "SymLocLiveExecutor"
	add_child(executor)
	executor.bind(bridge)
	# Symmetric side stacks: same classes, same construction, per-side
	# configs/adapters/plans/controllers. Shared Laya worker (singleton).
	red_config = BrainCls.build_config("red")
	blue_config = BrainCls.build_config("blue")
	red_adapter = AdapterCls.new()
	red_adapter.name = "SymLocRedAdapter"
	add_child(red_adapter)
	blue_adapter = AdapterCls.new()
	blue_adapter.name = "SymLocBlueAdapter"
	add_child(blue_adapter)
	red_plan = PlanCls.new()
	blue_plan = PlanCls.new()
	red_controller = LayaControllerCls.new()
	red_controller.name = "SymLocRedController"
	add_child(red_controller)
	blue_controller = LayaControllerCls.new()
	blue_controller.name = "SymLocBlueController"
	add_child(blue_controller)
	red_controller.setup(bridge, executor, red_adapter, red_config, red_plan)
	red_controller.set_side("red")
	red_controller.set_control_mode("MISSION_HIERARCHY")
	blue_controller.setup(bridge, executor, blue_adapter, blue_config, blue_plan)
	blue_controller.set_side("blue")
	blue_controller.set_control_mode("MISSION_HIERARCHY")
	print("[SymLoc] RED brain=%s hands=LAYA_LIVE side=%s" % [
		BrainCls.backend_label(red_config), red_controller.get_side()])
	print("[SymLoc] BLUE brain=%s hands=LAYA_LIVE side=%s" % [
		BrainCls.backend_label(blue_config), blue_controller.get_side()])
	red_controller.laya_decision.connect(_on_laya_decision.bind("RED"))
	blue_controller.laya_decision.connect(_on_laya_decision.bind("BLUE"))
	_build_hud()
	_boot_task += 1
	_boot_async(_boot_task)
	_hud_task += 1
	_hud_poll_async(_hud_task)
	# Route the RED phase to the RED controller (same shell routing as
	# Human-vs-Cloud). BLUE is driven by the loop below, never by the shell.
	shell.set("cloud_red_controller", red_controller)
	mount_ready = true
	print("[SymLoc] symmetric mount ready | live=%s | turn=%d | red=%s/%s blue=%s/%s" % [
		str(bridge.scenario_id()), int(bridge.get_manager().get_current_turn()),
		BrainCls.backend_label(red_config), red_controller.get_side(),
		BrainCls.backend_label(blue_config), blue_controller.get_side()])
	# Symmetric boot precompute: BOTH brains prefetch INITIAL from the same
	# frozen deployment snapshot BEFORE either side acts (serialized).
	await _symmetric_prefetch()
	# Autonomous alternating loop (no human input from here on).
	_loop_task += 1
	_loop_async(_loop_task)


## Freeze one boot snapshot per side, prefetch both INITIAL plans, then
## probe both local brains (serialized: one shared model server) and fire
## any armed prefetches. Equal precompute for both sides.
func _symmetric_prefetch() -> void:
	var turn := int(bridge.get_manager().get_current_turn())
	var obs_red := ObsCls.build(bridge, "red")
	var obs_blue := ObsCls.build(bridge, "blue")
	match_meta["seed"] = _env_or("SYMLOC_SEED", "deployment:%s" % str(obs_red.get("battle_id", "?")))
	match_meta["seed_source"] = "SYMLOC_SEED" if not OS.get_environment("SYMLOC_SEED").strip_edges().is_empty() else "deployment_snapshot"
	match_meta["scenario"] = str(obs_red.get("scenario_id", "?"))
	match_meta["battle_id"] = str(obs_red.get("battle_id", "?"))
	match_meta["opening_rule"] = OPENING_RULE
	match_meta["max_turns"] = MatchCls.max_turns()
	match_meta["red_brain"] = BrainCls.backend_label(red_config)
	match_meta["blue_brain"] = BrainCls.backend_label(blue_config)
	var pre_red: Dictionary = red_controller.victory_prefetch_initial(obs_red)
	var pre_blue: Dictionary = blue_controller.victory_prefetch_initial(obs_blue)
	print("[SymLoc] prefetch RED started=%s reason=%s armed=%s snap=%s" % [
		str(bool(pre_red.get("started", false))), str(pre_red.get("reason", "")),
		str(bool(pre_red.get("armed", false))), str(obs_red.get("snapshot_id", "?")).left(32)])
	print("[SymLoc] prefetch BLUE started=%s reason=%s armed=%s snap=%s" % [
		str(bool(pre_blue.get("started", false))), str(pre_blue.get("reason", "")),
		str(bool(pre_blue.get("armed", false))), str(obs_blue.get("snapshot_id", "?")).left(32)])
	_brain_probes["red"] = await BrainCls.test_and_mark(red_adapter, red_config)
	_brain_probes["blue"] = await BrainCls.test_and_mark(blue_adapter, blue_config)
	print("[SymLoc] brain probe RED ok=%s (%s)" % [
		str(bool((_brain_probes["red"] as Dictionary).get("ok", false))),
		str((_brain_probes["red"] as Dictionary).get("detail", ""))])
	print("[SymLoc] brain probe BLUE ok=%s (%s)" % [
		str(bool((_brain_probes["blue"] as Dictionary).get("ok", false))),
		str((_brain_probes["blue"] as Dictionary).get("detail", ""))])
	# Serialized armed-fire: ONE shared model server serves both brains, so
	# the two INITIAL generations run sequentially (each from its own
	# frozen boot snapshot — order cannot favor either side). Parallel
	# fire starves one request past the provider timeout.
	# SELFPLAY V1: local reasoning Brains need longer than the 600 s
	# sandbox default to settle INITIAL plans; override is env-only.
	var prefetch_budget := 600.0
	var prefetch_raw := OS.get_environment("SELFPLAY_PREFETCH_BUDGET_SEC").strip_edges()
	if not prefetch_raw.is_empty():
		prefetch_budget = clampf(float(prefetch_raw), 60.0, 3600.0)
	var fire_red: Dictionary = red_controller.victory_backend_ready()
	print("[SymLoc] armed-fire RED=%s (turn %d)" % [JSON.stringify(fire_red), turn])
	await _await_vp_initial_settled(red_controller, prefetch_budget)
	var fire_blue: Dictionary = blue_controller.victory_backend_ready()
	print("[SymLoc] armed-fire BLUE=%s (turn %d)" % [JSON.stringify(fire_blue), turn])
	await _await_vp_initial_settled(blue_controller, prefetch_budget)
	print("[SymLoc] boot prefetch settled RED=%s BLUE=%s" % [
		str(red_controller.victory_initial_status().get("state", "?")),
		str(blue_controller.victory_initial_status().get("state", "?"))])


## Wait until a controller's INITIAL generation leaves REQUESTING/RETRYING
## (READY or FAILED) or the budget expires. Returns the latch status.
func _await_vp_initial_settled(ctl, budget_sec: float) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	while true:
		var st: Dictionary = ctl.victory_initial_status()
		var state := str(st.get("state", ""))
		if state != "REQUESTING" and state != "RETRYING":
			return st
		if Time.get_ticks_msec() - t0 > budget_sec * 1000.0:
			print("[SymLoc] prefetch settle TIMEOUT state=%s req=%s" % [state, str(st.get("req", "?"))])
			return st
		await get_tree().process_frame
	return {} # unreachable; satisfies the static return-path check.


func _env_or(key: String, fallback: String) -> String:
	# Live get_environment read (has_environment misses in-process sets).
	var v := OS.get_environment(key).strip_edges()
	if not v.is_empty():
		return v
	return fallback


## Autonomous alternating turn loop. BLUE first (shell-native order):
## BLUE controller acts during PLAYER_PHASE, then the shell transition
## runs RED through the bound controller. Terminal is Godot-owned.
func _loop_async(my: int) -> void:
	_set_next_disabled(true)
	while my == _loop_task and not match_over:
		var term := MatchCls.read_terminal(shell)
		if bool(term.get("over", false)):
			_finalize(term)
			return
		# STRICT (training/eval only): a latched Brain-contract fault on
		# either side finalizes immediately as a terminal LOSS for the
		# offender. Godot owns the outcome; this only observes the fault.
		var sterm := StrictCls.poll_strict_terminal(red_controller, blue_controller)
		if bool(sterm.get("over", false)):
			_finalize(sterm)
			return
		# Wait for PLAYER_PHASE (the shell returns here after each RED run).
		var guard := 0
		while my == _loop_task and not match_over \
				and int(shell.get("_turn_phase")) != 0 \
				and not bool(MatchCls.read_terminal(shell).get("over", false)):
			await get_tree().process_frame
			guard += 1
			if guard > 36000:
				break
		if my != _loop_task or match_over:
			return
		term = MatchCls.read_terminal(shell)
		if bool(term.get("over", false)):
			_finalize(term)
			return
		_note_fog_row("pre_blue")
		shell.set("symmetric_auto_lock", true)
		var res_blue := await blue_controller.run_side_phase()
		shell.set("symmetric_auto_lock", false)
		print("[SymLoc] BLUE phase done ok=%s status=%s" % [
			str(bool(res_blue.get("ok", false))), str(res_blue.get("status", res_blue.get("code", "?")))])
		_note_fog_row("post_blue")
		term = MatchCls.read_terminal(shell)
		if bool(term.get("over", false)):
			_finalize(term)
			return
		sterm = StrictCls.poll_strict_terminal(red_controller, blue_controller)
		if bool(sterm.get("over", false)):
			_finalize(sterm)
			return
		# Shell transition: ENEMY_PHASE runs RED via the bound controller,
		# then finish_enemy_phase returns to PLAYER_PHASE.
		await shell.call("end_player_phase")
		sterm = StrictCls.poll_strict_terminal(red_controller, blue_controller)
		if bool(sterm.get("over", false)):
			_finalize(sterm)
			return
		_note_fog_row("post_red")
		_refresh_hud()
	_set_next_disabled(false)


## Fog telemetry: per-side authorized view vs central truth. Proves neither
## Brain receives omniscient information (exact foe troops never exposed;
## contacts are banded/current-vs-stale; counts bounded by truth).
func _note_fog_row(when: String) -> void:
	if bridge == null or shell == null:
		return
	var mgr: RefCounted = bridge.get_manager()
	var truth_red := 0
	var truth_blue := 0
	for u_val in ((mgr as RefCounted).call("get_all_units") as Array):
		if not u_val is Dictionary:
			continue
		var u: Dictionary = u_val
		if int(u.get("soldier_count", 0)) <= 0:
			continue
		if str(u.get("faction", "")) == "red":
			truth_red += 1
		elif str(u.get("faction", "")) == "blue":
			truth_blue += 1
	var obs_red := ObsCls.build(bridge, "red")
	var obs_blue := ObsCls.build(bridge, "blue")
	var row := {
		"when": when,
		"turn": int((mgr as RefCounted).call("get_current_turn")),
		"truth": {"red": truth_red, "blue": truth_blue},
		"red": _fog_side_summary(obs_red, truth_blue),
		"blue": _fog_side_summary(obs_blue, truth_red),
	}
	fog_rows.append(row)
	print("[SymLoc] FOG %s t%d truth=R%d/B%d red_sees=%d blue_sees=%d leak=%s" % [
		when, int(row["turn"]), truth_red, truth_blue,
		int((row["red"] as Dictionary).get("known_foe", 0)),
		int((row["blue"] as Dictionary).get("known_foe", 0)),
		str(bool((row["red"] as Dictionary).get("leak", false))
			or bool((row["blue"] as Dictionary).get("leak", false)))])


func _fog_side_summary(obs: Dictionary, truth_foe: int) -> Dictionary:
	var foes: Array = obs.get("known_enemy_units", [])
	var exact := 0
	var visible := 0
	for f_val in foes:
		if not f_val is Dictionary:
			continue
		var f: Dictionary = f_val
		if f.has("soldier_count"):
			exact += 1
		if str(f.get("contact_state", "")) == "current_visible":
			visible += 1
	var leak := exact > 0 or foes.size() > truth_foe
	return {"known_foe": foes.size(), "visible_foe": visible,
		"exact_troop_rows": exact, "truth_foe": truth_foe,
		"omniscient": false, "leak": leak}


func _finalize(term: Dictionary) -> void:
	if match_over:
		return
	match_over = true
	_loop_task += 1
	shell.set("symmetric_auto_lock", false)
	_set_next_disabled(false)
	var red_view: Dictionary = red_controller.get_victory_plan_view()
	var blue_view: Dictionary = blue_controller.get_victory_plan_view()
	match_meta["red_plan_revision"] = int((red_view.get("plan", {}) as Dictionary).get("revision", 0))
	match_meta["blue_plan_revision"] = int((blue_view.get("plan", {}) as Dictionary).get("revision", 0))
	match_meta["laya_worker"] = LYLaunchCls.status_snapshot()
	match_result = MatchCls.build_result(str(term.get("winner", "DRAW")),
		str(term.get("reason", "")), int(term.get("turn", 0)), match_meta)
	print("[SymLoc] MATCH_OVER %s" % JSON.stringify(match_result))
	if shell != null and shell.has_method("_show_combat_log"):
		shell.call("_show_combat_log", "SYMMETRIC MATCH OVER: %s (%s)" % [
			str(match_result.get("winner", "?")), str(match_result.get("reason", "?"))])
	var f := FileAccess.open("user://symloc_last_match.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(match_result, "\t"))
		f.close()
	_refresh_hud()
	if OS.get_environment("SYMLOC_QUIT_ON_OVER").strip_edges() == "1":
		print("[SymLoc] SYMLOC_QUIT_ON_OVER=1 -> quitting.")
		get_tree().quit()


func _set_next_disabled(disabled: bool) -> void:
	if shell == null:
		return
	var btn := shell.get("next_turn_button") as BaseButton
	if btn != null:
		btn.disabled = disabled


func _on_laya_decision(info: Dictionary, side: String) -> void:
	var ev := str(info.get("event", "?"))
	if ev == "DECISION":
		print("[SymLoc][%s] t%d #%d %s unit=%s pool=%d lat=%.0fms exec=%s" % [side,
			int(info.get("turn", 0)), int(info.get("step", 0)),
			str(info.get("selected", "?")), str(info.get("unit_id", "?")),
			int(info.get("candidate_count", 0)),
			float(info.get("latency_ms", 0.0)), str(bool(info.get("executed", false)))])
	else:
		print("[SymLoc][%s] %s %s" % [side, ev, JSON.stringify(info)])


func _build_hud() -> void:
	var hud: CanvasLayer = shell.get("hud_layer") as CanvasLayer
	if hud == null:
		return
	_hud = PanelContainer.new()
	_hud.name = "SymLocHUD"
	_hud.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_hud.offset_left = -460
	_hud.offset_top = 8
	_hud.offset_right = -8
	_hud.offset_bottom = 420
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.07, 0.10, 0.90)
	sb.border_width_left = 2
	sb.border_width_top = 2
	sb.border_width_right = 2
	sb.border_width_bottom = 2
	sb.border_color = Color(0.45, 0.75, 1.0, 0.9)
	sb.corner_radius_top_left = 4
	sb.corner_radius_top_right = 4
	sb.corner_radius_bottom_right = 4
	sb.corner_radius_bottom_left = 4
	_hud.add_theme_stylebox_override("panel", sb)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 2)
	_hud.add_child(vb)
	_hud_lines = []
	for i in range(16):
		var lbl := Label.new()
		lbl.add_theme_font_size_override("font_size", 13)
		lbl.add_theme_color_override("font_color", Color(0.85, 0.90, 1.0))
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		vb.add_child(lbl)
		_hud_lines.append(lbl)
	hud.add_child(_hud)
	_refresh_hud()


func _hud_poll_async(my: int) -> void:
	while my == _hud_task and is_instance_valid(_hud):
		_refresh_hud()
		await get_tree().create_timer(HUD_POLL_SEC).timeout


func _side_hud_lines(side: String, ctl, base: int) -> void:
	if _hud_lines.size() <= base + 4:
		return
	var stats: Dictionary = ctl.laya_stats() if ctl != null else {}
	var last: Dictionary = stats.get("last", {})
	var last_txt := "last: —"
	if not last.is_empty():
		if str(last.get("event", "")) == "DECISION":
			last_txt = "last: %s unit=%s [pool=%d, %.0fms]" % [str(last.get("selected", "?")),
				str(last.get("unit_id", "?")), int(last.get("candidate_count", 0)),
				float(last.get("latency_ms", 0.0))]
		else:
			last_txt = "last: %s" % str(last.get("event", "?"))
	var vp: Dictionary = ctl.get_victory_plan_view() if ctl != null and ctl.has_method("get_victory_plan_view") else {}
	var plan_txt := "PLAN: (none)"
	if bool(vp.get("has_plan", false)):
		var plan: Dictionary = vp.get("plan", {})
		plan_txt = "PLAN: %s v%d phase=%s" % [str(plan.get("victory_plan_id", "?")),
			int(plan.get("revision", 0)), str(plan.get("current_phase_id", "?"))]
	else:
		var init: Dictionary = vp.get("initial", {})
		if not init.is_empty():
			plan_txt = "PLAN: (%s)" % str(init.get("state", "?"))
	var brain := BrainCls.backend_label(red_config if side == "RED" else blue_config)
	(_hud_lines[base] as Label).text = "%s BRAIN: %s | HANDS: LAYA" % [side, brain]
	(_hud_lines[base + 1] as Label).text = "%s %s" % [side, plan_txt]
	(_hud_lines[base + 2] as Label).text = "%s turns=%d dec=%d mv=%d atk=%d wt=%d fail=%d" % [side,
		int(stats.get("side_turns", 0)), int(stats.get("decision_count", 0)),
		int(stats.get("moves", 0)), int(stats.get("attacks", 0)),
		int(stats.get("waits", 0)), int(stats.get("exec_failures", 0))]
	(_hud_lines[base + 3] as Label).text = "%s %s" % [side, last_txt]


func _refresh_hud() -> void:
	if _hud == null or not is_instance_valid(_hud) or _hud_lines.is_empty():
		return
	var turn := 0
	var phase := "?"
	if bridge != null:
		turn = int(bridge.get_manager().get_current_turn())
	if shell != null:
		phase = "PLAYER(→BLUE auto)" if int(shell.get("_turn_phase")) == 0 else "ENEMY(RED)"
	(_hud_lines[0] as Label).text = "DEV: LOCAL vs LOCAL (symmetric)"
	(_hud_lines[1] as Label).text = "turn=%d phase=%s" % [turn, phase]
	_side_hud_lines("RED", red_controller, 2)
	_side_hud_lines("BLUE", blue_controller, 7)
	var svc: Dictionary = LYLaunchCls.status_snapshot()
	(_hud_lines[12] as Label).text = "LAYA worker(shared): %s pid=%s port=%s" % [
		str(svc.get("status", "?")), str(svc.get("pid", "?")), str(svc.get("port", "?"))]
	if match_over and not match_result.is_empty():
		(_hud_lines[13] as Label).text = "OUTCOME: %s (%s)" % [
			str(match_result.get("winner", "?")), str(match_result.get("reason", "?"))]
		(_hud_lines[14] as Label).text = "REWARD red=%s blue=%s | turns=%d" % [
			str(match_result.get("reward_red", "?")), str(match_result.get("reward_blue", "?")),
			int(match_result.get("turns", 0))]
		(_hud_lines[15] as Label).text = "TRAINING: NONE (telemetry only)"
	else:
		(_hud_lines[13] as Label).text = "reward contract: WIN +5 / LOSS -3 / DRAW -2"
		(_hud_lines[14] as Label).text = "max_turns=%d (0=unlimited)" % MatchCls.max_turns()
		(_hud_lines[15] as Label).text = "TRAINING: NONE (telemetry only)"


## Owned Laya worker boot (same lifecycle contract as the Cloud mount:
## async boot, visible status, clean shutdown, no manual step). ONE worker
## serves BOTH sides (singleton launcher): the mount never spawns a
## second one — requests from both Laya loops serialize on it.
func _boot_async(my: int) -> void:
	if not LYLaunchCls.auto_enabled():
		LYLaunchCls.mark_disabled("EXPLICIT_OFF")
		return
	if str(LYLaunchCls.status_snapshot().get("status", "COLD")) != "COLD":
		return
	if LYLaunchCls.fixed_url_mode():
		await _boot_fixed_async(my)
		return
	var spawned: Dictionary = LYLaunchCls.spawn_owned_or_fixed()
	if not bool(spawned.get("ok", false)):
		return
	if str(spawned.get("status", "")) == "READY":
		return
	var deadline := Time.get_ticks_msec() + LYLaunchCls.startup_timeout_ms()
	while Time.get_ticks_msec() < deadline:
		if my != _boot_task:
			return
		if LYLaunchCls.is_ready() or LYLaunchCls.is_disabled():
			return
		if not LYLaunchCls.boot_in_progress():
			return
		if not LYLaunchCls.owned_pid_alive():
			LYLaunchCls.mark_disabled("WORKER_DIED_DURING_BOOT")
			return
		var snap: Dictionary = LYLaunchCls.status_snapshot()
		var res: Dictionary = await _http_get_json(
			str(snap.get("host", "127.0.0.1")), int(snap.get("port", 11442)),
			"/health", 4.0)
		if my != _boot_task:
			return
		if LYLaunchCls.is_ready() or LYLaunchCls.is_disabled():
			return
		if bool(res.get("ok", false)) and res.get("body", {}) is Dictionary:
			var v: Dictionary = LYLaunchCls.verify_health_dict(res.get("body", {}))
			if bool(v.get("ok", false)):
				LYLaunchCls.mark_ready(v.get("identity", {}), (res.get("body", {}) as Dictionary).get("load", {}))
				_announce_ready()
				return
			LYLaunchCls.mark_disabled(str(v.get("error", "HEALTH_MISMATCH")))
			return
		await get_tree().create_timer(BOOT_POLL_SEC).timeout
	LYLaunchCls.on_boot_timeout()


func _boot_fixed_async(my: int) -> void:
	var deadline := Time.get_ticks_msec() + LYLaunchCls.FIXED_PROBE_TIMEOUT_MS * 3
	while Time.get_ticks_msec() < deadline:
		if my != _boot_task:
			return
		if LYLaunchCls.is_ready() or LYLaunchCls.is_disabled():
			return
		var ep: Dictionary = LYLaunchCls.fixed_endpoint()
		var res: Dictionary = await _http_get_json(
			str(ep.get("host", "127.0.0.1")), int(ep.get("port", 11442)),
			"/health", 4.0)
		if my != _boot_task:
			return
		if LYLaunchCls.is_ready() or LYLaunchCls.is_disabled():
			return
		if bool(res.get("ok", false)) and res.get("body", {}) is Dictionary:
			var v: Dictionary = LYLaunchCls.verify_health_dict(res.get("body", {}))
			if bool(v.get("ok", false)):
				LYLaunchCls.adopt_fixed_health(v.get("identity", {}),
					(res.get("body", {}) as Dictionary).get("load", {}),
					str(ep.get("host", "")), int(ep.get("port", 11442)))
				_announce_ready()
				return
			LYLaunchCls.mark_disabled("FIXED_IDENTITY_MISMATCH: %s" % str(v.get("error", "?")))
			return
		await get_tree().create_timer(BOOT_POLL_SEC).timeout
	LYLaunchCls.mark_disabled("FIXED_UNREACHABLE")


func _http_get_json(host: String, port: int, path: String,
	timeout_sec: float) -> Dictionary:
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	var http := HTTPClient.new()
	if http.connect_to_host(host, port) != OK:
		return {"ok": false}
	while Time.get_ticks_msec() < deadline:
		http.poll()
		var st := http.get_status()
		if st == HTTPClient.STATUS_CONNECTED:
			break
		if st != HTTPClient.STATUS_RESOLVING and st != HTTPClient.STATUS_CONNECTING:
			http.close()
			return {"ok": false}
		await get_tree().process_frame
	if http.get_status() != HTTPClient.STATUS_CONNECTED:
		http.close()
		return {"ok": false}
	if http.request(HTTPClient.METHOD_GET, path, PackedStringArray(), "") != OK:
		http.close()
		return {"ok": false}
	while http.get_status() == HTTPClient.STATUS_REQUESTING:
		if Time.get_ticks_msec() > deadline:
			http.close()
			return {"ok": false}
		http.poll()
		await get_tree().process_frame
	if http.get_response_code() != 200:
		http.close()
		return {"ok": false}
	var chunks := PackedByteArray()
	while http.get_status() == HTTPClient.STATUS_BODY:
		if Time.get_ticks_msec() > deadline:
			http.close()
			return {"ok": false}
		http.poll()
		var chunk := http.read_response_body_chunk()
		if chunk.size() > 0:
			chunks.append_array(chunk)
		else:
			await get_tree().process_frame
	http.close()
	var parsed: Variant = JSON.parse_string(chunks.get_string_from_utf8())
	if parsed is Dictionary:
		return {"ok": true, "body": parsed}
	return {"ok": false}


func _announce_ready() -> void:
	var snap: Dictionary = LYLaunchCls.status_snapshot()
	var load_info: Dictionary = snap.get("load_info", {})
	print("[SymLoc] worker READY load_s=%s vram=%s (shared RED+BLUE)" % [
		str(load_info.get("load_s", "?")), str(load_info.get("vram_gb", "?"))])
	if shell != null and shell.has_method("_show_combat_log"):
		shell.call("_show_combat_log", "LAYA READY (shared RED+BLUE) — model %s (load %ss, VRAM %sGB)" % [
			LYLaunchCls.MODEL_IDENTITY, str(load_info.get("load_s", "?")),
			str(load_info.get("vram_gb", "?"))])
