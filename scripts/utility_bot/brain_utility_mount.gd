extends Node

## Autonomous BLUE Brain vs RED UtilityBot on the same isolated dev map used
## by Human-vs-UtilityBot. The normal battle shell owns turns and state.

const BridgeCls = preload("res://scripts/cloud1/cloud1_live_bridge.gd")
const ExecutorCls = preload("res://scripts/cloud1/cloud1_live_executor.gd")
const AdapterCls = preload("res://scripts/cloud2/cloud2_adapter.gd")
const PlanCls = preload("res://scripts/cloud2/cloud2_plan_memory.gd")
const ControllerCls = preload("res://scripts/utility_bot/brain_utility_blue_controller.gd")
const BrainCls = preload("res://scripts/symloc/symloc_brain.gd")
const UtilityControllerCls = preload("res://scripts/utility_bot/utility_live_controller.gd")
const MatchCls = preload("res://scripts/symloc/symloc_match.gd")
const StrictCls = preload("res://scripts/selfplay/training_strict.gd")

var shell: Node
var det: Node
var bridge: RefCounted
var executor: Node
var brain_config: RefCounted
var brain_adapter: Node
var brain_controller: Node
var utility_controller: Node
var mount_ready := false
var mount_error := ""
var _loop_generation := 0
var _hud: PanelContainer
var _status: Label


func _ready() -> void:
	call_deferred("_bootstrap")


func _exit_tree() -> void:
	_loop_generation += 1
	if shell != null and is_instance_valid(shell) \
			and shell.get("cloud_red_controller") == utility_controller:
		shell.set("cloud_red_controller", null)
	if shell != null and is_instance_valid(shell):
		shell.set("symmetric_auto_lock", false)


func _bootstrap() -> void:
	for _i in range(600):
		shell = get_parent().get_node_or_null("Battle")
		if shell != null and shell.get("unit_manager") != null and shell.get("hud_layer") != null:
			break
		await get_tree().process_frame
	if shell == null:
		_fail("Battle node unavailable.")
		return
	det = shell.get_node_or_null("Step7Integration")
	for _j in range(600):
		if det != null and bool(det.get("ready_for_step7")):
			break
		await get_tree().process_frame
	if det == null or not bool(det.get("ready_for_step7")):
		_fail("Step7Integration unavailable.")
		return
	bridge = BridgeCls.new()
	if not bridge.bind(shell, det):
		_fail("Live bridge unavailable.")
		return
	executor = ExecutorCls.new()
	executor.name = "BrainBlueLiveExecutor"
	add_child(executor)
	executor.call("bind", bridge)
	brain_config = BrainCls.build_config("blue")
	_build_status_panel()
	_status.text = "Testing BLUE Brain connection..."
	brain_adapter = AdapterCls.new()
	brain_adapter.name = "BrainBlueAdapter"
	add_child(brain_adapter)
	var tested: Dictionary = await BrainCls.test_and_mark(brain_adapter, brain_config)
	if not bool(tested.get("ok", false)):
		_fail("BLUE Brain connection failed: %s %s" % [str(tested.get("code", "")), str(tested.get("detail", ""))])
		return
	brain_controller = ControllerCls.new()
	brain_controller.name = "BrainBlueTurnController"
	add_child(brain_controller)
	brain_controller.call("setup", bridge, executor, brain_adapter, brain_config, PlanCls.new())
	brain_controller.call("set_side", "blue")
	brain_controller.call("set_control_mode", "MISSION_HIERARCHY")
	utility_controller = UtilityControllerCls.new()
	utility_controller.name = "UtilityBotRedController"
	utility_controller.set("auto_mount", false)
	add_child(utility_controller)
	var bound: Dictionary = utility_controller.call("bind_live", shell, det, false)
	if not bool(bound.get("ok", false)):
		_fail("RED UtilityBot setup failed: " + str(bound.get("error", "unknown")))
		return
	shell.set("cloud_red_controller", utility_controller)
	mount_ready = true
	print("[BrainUtility] ready | BLUE=%s | RED UtilityBot=%s" % [
		BrainCls.backend_label(brain_config), JSON.stringify(bound.get("profile", {}))])
	_loop_generation += 1
	_run_loop(_loop_generation)


func _run_loop(generation: int) -> void:
	var next_button := shell.get("next_turn_button") as Button
	if next_button != null:
		next_button.disabled = true
	while generation == _loop_generation and mount_ready:
		if _battle_over():
			break
		while generation == _loop_generation and not _battle_over() \
				and int(shell.get("_turn_phase")) != 0:
			await get_tree().process_frame
		if generation != _loop_generation or _battle_over():
			break
		if _status != null:
			_status.text = "BLUE Brain planning · turn %d\nRED UtilityBot · %s · seed %d" % [
				int(bridge.get_manager().call("get_current_turn")),
				str(_utility_profile().get("archetype", "?")),
				int(utility_controller.get("bot_seed"))]
		shell.set("symmetric_auto_lock", true)
		var blue_result: Dictionary = await brain_controller.call("run_side_phase")
		shell.set("symmetric_auto_lock", false)
		print("[BrainUtility] BLUE phase ok=%s status=%s" % [
			str(blue_result.get("ok", false)), str(blue_result.get("status", blue_result.get("code", "?")))])
		var strict_result: Dictionary = StrictCls.poll_strict_terminal(null, brain_controller)
		if bool(strict_result.get("over", false)):
			_finish_strict(strict_result)
			return
		# A non-strict rejected INITIAL remains a genuine logged Brain failure.
		# The dev controller held this BLUE phase; retry only on the next phase.
		brain_controller.call("rearm_failed_initial_for_dev")
		if _battle_over():
			break
		await shell.call("end_player_phase")
		strict_result = StrictCls.poll_strict_terminal(null, brain_controller)
		if bool(strict_result.get("over", false)):
			_finish_strict(strict_result)
			return
		if _status != null:
			_status.text = "BLUE Brain · turn %d\nRED UtilityBot resolved · %s" % [
				int(bridge.get_manager().call("get_current_turn")),
				str(_utility_profile().get("archetype", "?"))]
		await get_tree().create_timer(0.2).timeout
	if next_button != null:
		next_button.disabled = false
	if _battle_over():
		print("[BrainUtility] battle ended: %s" % JSON.stringify(MatchCls.read_terminal(shell)))


func _fail(reason: String) -> void:
	mount_error = reason
	push_error("[BrainUtility] " + reason)
	if _status != null:
		_status.text = "Brain vs Utility Bot unavailable\n" + reason
	var next_button := shell.get("next_turn_button") as Button if shell != null else null
	if next_button != null:
		next_button.disabled = false


func _finish_strict(term: Dictionary) -> void:
	_loop_generation += 1
	shell.set("symmetric_auto_lock", true)
	var next_button := shell.get("next_turn_button") as Button
	if next_button != null:
		next_button.disabled = true
	var msg := "STRICT Brain contract failure: %s" % str(term.get("reason", "invalid response"))
	print("[BrainUtility] %s" % JSON.stringify(term))
	if shell.has_method("_show_combat_log"):
		shell.call("_show_combat_log", msg)
	if _status != null:
		_status.text = msg


func _battle_over() -> bool:
	return shell != null and shell.has_method("_battle_over") and bool(shell.call("_battle_over"))


func _utility_profile() -> Dictionary:
	var bot := utility_controller.get("bot") as RefCounted if utility_controller != null else null
	return bot.call("profile") if bot != null else {}


func _build_status_panel() -> void:
	var hud := shell.get("hud_layer") as CanvasLayer
	if hud == null:
		return
	_hud = PanelContainer.new()
	_hud.name = "BrainUtilityStatus"
	_hud.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_hud.offset_left = -300
	_hud.offset_top = 8
	_hud.offset_right = -8
	_hud.offset_bottom = 74
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.08, 0.10, 0.80)
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.border_color = Color(0.35, 0.65, 0.58, 0.8)
	_hud.add_theme_stylebox_override("panel", style)
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 12)
	_status.add_theme_color_override("font_color", Color(0.82, 0.92, 0.87))
	_hud.add_child(_status)
	hud.add_child(_hud)
	_status.text = "Preparing Brain BLUE vs UtilityBot RED..."
