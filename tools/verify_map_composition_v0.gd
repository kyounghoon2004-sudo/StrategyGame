extends SceneTree

## MAP COMPOSITION V0 — headless build verification (no rendering).
## Loads the review scene, waits for the build, prints the evidence report.
##
## Run:
##   Godot_v4.2.2-stable_win64_console.exe --headless --path "<proj>" \
##     -s res://tools/verify_map_composition_v0.gd

var _t0: int = 0


func _initialize() -> void:
	_t0 = Time.get_ticks_msec()
	change_scene_to_file("res://scenes/review/map_composition_v0.tscn")


func _process(_delta: float) -> bool:
	var cs: Node = current_scene
	if cs != null and cs.get("built") != null and bool(cs.get("built")):
		print("[MapCompVerify] verified")
		print(JSON.stringify(cs.get("report"), "  "))
		quit(0)
		return true
	if Time.get_ticks_msec() - _t0 > 180000:
		print("[MapCompVerify] scene never built (timeout); current_scene=%s" % str(cs))
		quit(1)
		return true
	return false
