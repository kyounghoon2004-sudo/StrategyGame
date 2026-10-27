extends RefCounted
## Local DEV entry: keep the title open while the interactive library runs.
const MAP_SCRIPT := "res://tools/dev_visual_lab/unit_world.gd"
const SCALED_MAP_SCRIPT := "res://tools/dev_visual_lab/scaled_scenery_world.gd"
const VisualPaths = preload("res://tools/dev_visual_lab/visual_output_paths.gd")

static func open_library() -> int:
	return _open(MAP_SCRIPT)

static func open_scaled_library() -> int:
	return _open(SCALED_MAP_SCRIPT)

static func _open(script_path: String) -> int:
	var data_dir := OS.get_environment("SG_FULL_MAP_OUT")
	if data_dir.is_empty():
		data_dir = VisualPaths.output("full-map-lab")
	if not FileAccess.file_exists(script_path) or not FileAccess.file_exists(data_dir.path_join("optimization-manifest.json")):
		push_error("[AssetLibrary] DEV map or full-map-lab data is missing: " + data_dir)
		return -1
	var previous := OS.get_environment("SG_FULL_MAP_OUT")
	var had_previous := OS.has_environment("SG_FULL_MAP_OUT")
	OS.set_environment("SG_FULL_MAP_OUT", data_dir)
	var pid := OS.create_process(OS.get_executable_path(), PackedStringArray([
		"--path", ProjectSettings.globalize_path("res://"),
		"--script", script_path, "--", "--all-lod0"
	]))
	if had_previous:
		OS.set_environment("SG_FULL_MAP_OUT", previous)
	else:
		OS.unset_environment("SG_FULL_MAP_OUT")
	if pid < 0:
		push_error("[AssetLibrary] Failed to launch interactive map")
	else:
		print("[AssetLibrary] launched ", script_path, " pid=", pid)
	return pid
