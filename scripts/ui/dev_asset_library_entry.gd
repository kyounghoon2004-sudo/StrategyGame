extends RefCounted
## Local DEV entry: keep the title open while the interactive library runs.
const MAP_SCRIPT := "res://tools/dev_visual_lab/unit_world.gd"
const DATA_DIR := "C:/Users/User/Documents/Codex/2026-10-18/strategygame-godot-4-2-2-repo/outputs/full-map-lab"

static func open_library() -> int:
	if not FileAccess.file_exists(MAP_SCRIPT) or not FileAccess.file_exists(DATA_DIR.path_join("optimization-manifest.json")):
		push_error("[AssetLibrary] DEV map or local asset data is missing")
		return -1
	var previous := OS.get_environment("SG_FULL_MAP_OUT")
	var had_previous := OS.has_environment("SG_FULL_MAP_OUT")
	OS.set_environment("SG_FULL_MAP_OUT",DATA_DIR)
	var pid := OS.create_process(OS.get_executable_path(),PackedStringArray([
		"--path",ProjectSettings.globalize_path("res://"),
		"--script",MAP_SCRIPT,"--","--all-lod0"
	]))
	if had_previous: OS.set_environment("SG_FULL_MAP_OUT",previous)
	else: OS.unset_environment("SG_FULL_MAP_OUT")
	if pid<0: push_error("[AssetLibrary] Failed to launch interactive map")
	else: print("[AssetLibrary] launched interactive map pid=",pid)
	return pid


const SCALED_MAP_SCRIPT := "res://tools/dev_visual_lab/scaled_scenery_world.gd"

static func open_scaled_library() -> int:
	if not FileAccess.file_exists(SCALED_MAP_SCRIPT) or not FileAccess.file_exists(DATA_DIR.path_join("optimization-manifest.json")):
		push_error("[AssetLibrary] DEV scaled scenery map or local asset data is missing")
		return -1
	var previous := OS.get_environment("SG_FULL_MAP_OUT")
	var had_previous := OS.has_environment("SG_FULL_MAP_OUT")
	OS.set_environment("SG_FULL_MAP_OUT", DATA_DIR)
	var pid := OS.create_process(OS.get_executable_path(), PackedStringArray([
		"--path", ProjectSettings.globalize_path("res://"),
		"--script", SCALED_MAP_SCRIPT, "--", "--all-lod0"
	]))
	if had_previous: OS.set_environment("SG_FULL_MAP_OUT", previous)
	else: OS.unset_environment("SG_FULL_MAP_OUT")
	if pid < 0: push_error("[AssetLibrary] Failed to launch scaled scenery map")
	else: print("[AssetLibrary] launched scaled scenery map pid=", pid)
	return pid

