extends Node

const ControllerCls = preload("res://scripts/utility_bot/utility_live_controller.gd")

var shell: Node
var det: Node
var controller: Node


func _ready() -> void:
	call_deferred("_bootstrap")


func _bootstrap() -> void:
	for _i in range(600):
		shell = get_parent().get_node_or_null("Battle")
		if shell != null and shell.get("unit_manager") != null:
			break
		await get_tree().process_frame
	if shell == null:
		push_error("[UtilityBotMount] Battle node unavailable.")
		return
	det = shell.get_node_or_null("Step7Integration")
	for _j in range(600):
		if det != null and bool(det.get("ready_for_step7")):
			break
		await get_tree().process_frame
	if det == null or not bool(det.get("ready_for_step7")):
		push_error("[UtilityBotMount] Step7Integration unavailable.")
		return
	controller = ControllerCls.new()
	controller.name = "UtilityBotLiveController"
	controller.auto_mount = false
	var selected := str(get_tree().root.get_meta("utility_bot_dev_difficulty", "V0"))
	if get_tree().root.has_meta("utility_bot_dev_difficulty"):
		get_tree().root.remove_meta("utility_bot_dev_difficulty")
	controller.dev_difficulty = selected if (selected in ["V0", "V1", "V2"] or selected.begins_with("GX_")) else "V0"
	add_child(controller)
	var result: Dictionary = controller.call("bind_live", shell, det, true)
	if not bool(result.get("ok", false)):
		push_error("[UtilityBotMount] controller setup failed: " + str(result.get("error", "unknown")))
