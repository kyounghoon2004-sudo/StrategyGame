extends SceneTree

## Human play on the 5 generated mission maps (2026-10-09): you are BLUE, RED is the mission GX.
## In game: F1-F5 mission M1..M5 (new random map), F8 same map again, F6 GX tier, F7 GX style, B build base.
##   Godot_v4.2.2-stable_win64.exe --path <project> --script res://tools/play_missions.gd [-- M3 INTER BULWARK]

const MountCls = preload("res://scripts/gx_missions/mission_play_mount.gd")


func _initialize() -> void:
	randomize()
	var a := OS.get_cmdline_user_args()
	var c: Dictionary = MountCls.pick(a[0].to_upper() if a.size() > 0 else "M3")
	if a.size() > 1:
		c["tier"] = a[1].to_upper()
	if a.size() > 2:
		c["style"] = a[2].to_upper()
	root.set_meta(MountCls.META, c)
	change_scene_to_file("res://scenes/mission_play.tscn")
