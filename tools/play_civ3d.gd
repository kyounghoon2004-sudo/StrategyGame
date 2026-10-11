extends SceneTree

## Opens the game straight on the default production map in the CIV3D view
## (title -> DEV map collection -> existing production layout, automated), then
## hands control to the player. Presentation-check hotkeys, VISUAL ONLY:
##   F5  every 3D formation attacks (cavalry: couched-lance charge)
##   F6  every 3D formation takes a hit
## Units move normally through the game's own commands (gameplay untouched).
##   Godot_v4.2.2-stable_win64.exe --path <project> --script res://tools/play_civ3d.gd

var _menu_frames := 0
var _entered := false
var _keys := {}

func _initialize() -> void:
	change_scene_to_file("res://scenes/title_screen.tscn")

func _process(_delta: float) -> bool:
	if not _entered:
		if current_scene != null and current_scene.scene_file_path == "res://scenes/title_screen.tscn":
			_menu_frames += 1
			if _menu_frames == 8:
				var collection: Node = current_scene.get("_map_collection")
				collection.call("open")
				collection.find_child("OpenExistingProductionLayout", true, false).emit_signal("pressed")
				_entered = true
				print("[PlayCiv3D] entering the default map ... F5 attack / charge, F6 hit")
		return false
	if _pressed(KEY_F5):
		_all("play_attack")
	if _pressed(KEY_F6):
		_all("play_hit")
	var q := OS.get_environment("SG_QUIT_AFTER_MS")
	if q != "" and Time.get_ticks_msec() > q.to_int():
		quit()
	return false

func _pressed(k: Key) -> bool:
	var down := Input.is_key_pressed(k)
	var was: bool = _keys.get(k, false)
	_keys[k] = down
	return down and not was

func _all(method: String) -> void:
	if current_scene == null:
		return
	var view: Node = current_scene.get("_view3d")
	if view == null:
		return
	var units: Dictionary = view.get("_units")
	for id in units.keys():
		var f: Node = units[id].get("f3d")
		if f != null and is_instance_valid(f):
			f.call(method)
