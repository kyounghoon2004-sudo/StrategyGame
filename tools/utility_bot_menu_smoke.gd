extends SceneTree

const TitleScene = preload("res://scenes/title_screen.tscn")
const OUT_PATH := "res://artifacts/utility_bot_v0/menu_smoke.json"


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene := TitleScene.instantiate()
	root.add_child(scene)
	current_scene = scene
	await process_frame
	await process_frame
	# Headless root.size is 64x64 on this Godot build, even though Control
	# layout uses the configured game viewport. Check against that viewport.
	var viewport := Vector2i(int(ProjectSettings.get_setting("display/window/size/viewport_width", 1920)),
		int(ProjectSettings.get_setting("display/window/size/viewport_height", 1080)))
	var results := {}
	var all_visible := true
	var buttons := scene.get_node("VBox/Buttons") as VBoxContainer
	for child in buttons.get_children():
		if not child is Button:
			continue
		var btn := child as Button
		var name := btn.name
		var rect := btn.get_global_rect()
		var visible := rect.position.x >= 0 and rect.position.y >= 0 \
			and rect.end.x <= viewport.x and rect.end.y <= viewport.y
		results[name] = {"exists": true, "visible_in_window": visible,
			"rect": [rect.position.x, rect.position.y, rect.size.x, rect.size.y]}
		all_visible = all_visible and visible
	for required in ["BtnHumanVsUtilityBot", "BtnBrainVsUtilityBot"]:
		all_visible = all_visible and results.has(required)
	var record := {"pass": all_visible, "viewport": [viewport.x, viewport.y], "buttons": results}
	var file := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(record, "\t") + "\n")
		file.close()
	print("UTILITY_MENU_SMOKE " + JSON.stringify(record))
	quit(0 if all_visible else 1)
