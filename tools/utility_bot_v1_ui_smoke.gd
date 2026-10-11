extends SceneTree

const TitleScene = preload("res://scenes/title_screen.tscn")
const V0Script = preload("res://scripts/utility_bot/utility_bot.gd")
const V1Script = preload("res://scripts/utility_bot/utility_bot_v1.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var tier := "V1" if "--tier=V1" in OS.get_cmdline_user_args() else "V0"
	var title := TitleScene.instantiate()
	root.add_child(title)
	current_scene = title
	await process_frame
	await process_frame
	var dev_button := title.get_node_or_null("VBox/Buttons/BtnHumanVsUtilityBot") as Button
	var selector := title.get_node_or_null("UtilityDifficultySelector") as Control
	var initial_hidden := selector != null and not selector.visible
	if dev_button != null:
		dev_button.pressed.emit()
	await process_frame
	var opened := selector != null and selector.visible
	var v0 := selector.get_node_or_null("CenterContainer/DifficultyPanel/Choices/V0Option") as Button if selector != null else null
	var v1 := selector.get_node_or_null("CenterContainer/DifficultyPanel/Choices/V1Option") as Button if selector != null else null
	var start := selector.get_node_or_null("CenterContainer/DifficultyPanel/Choices/StartBattle") as Button if selector != null else null
	var default_v0 := v0 != null and v0.text.begins_with("●")
	var both_options := v0 != null and v1 != null
	var entry_exists := dev_button != null
	if tier == "V1" and v1 != null:
		v1.pressed.emit()
	elif v0 != null:
		v0.pressed.emit()
	var selected := (v1.text.begins_with("●") if tier == "V1" else v0.text.begins_with("●")) if v0 != null and v1 != null else false
	if start != null:
		start.pressed.emit()
	var controller: Node = null
	var deadline := Time.get_ticks_msec() + 45000
	while Time.get_ticks_msec() < deadline:
		var battle := current_scene
		controller = battle.get_node_or_null("UtilityBotMount/UtilityBotLiveController") if battle != null else null
		if controller != null and bool(controller.get("mount_ready")):
			break
		await process_frame
	var mounted := controller != null and bool(controller.get("mount_ready"))
	var bot: RefCounted = controller.get("bot") as RefCounted if mounted else null
	var script_ok: bool = bot != null and bot.get_script() == (V1Script if tier == "V1" else V0Script)
	var record := {"tier": tier, "dev_entry_exists": entry_exists, "selector_initially_hidden": initial_hidden,
		"selector_opened": opened, "default_v0": default_v0, "both_options_exist": both_options,
		"selected": selected, "mounted": mounted, "correct_bot_script": script_ok,
		"profile": bot.call("profile") if bot != null else {},
		"pass": entry_exists and initial_hidden and opened and default_v0 and both_options and selected and mounted and script_ok}
	var output := "res://artifacts/utility_bot_v1/ui_%s.json" % tier.to_lower()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output).get_base_dir())
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(record, "\t") + "\n")
		file.close()
	print("UTILITY_V1_UI_SMOKE " + JSON.stringify(record))
	quit(0 if bool(record["pass"]) else 1)
