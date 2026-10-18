extends SceneTree

## Human play on the 5 generated mission maps (2026-10-09): you are BLUE, RED is the mission GX.
## In game: F1-F5 mission M1..M5 (new random map), F8 same map again, F6 GX tier, F7 GX style, B build base.
##   Godot_v4.2.2-stable_win64.exe --path <project> --script res://tools/play_missions.gd [-- M3 INTER BULWARK]
##   ... [-- SIM mild] = the collection board (Step0 sandbox, GX BASIC) with bases + morale.
##   ... [-- T3]  = tutorial map M3 (data/battlefields/tutorial_v1); F1-F5 then switch between tutorials.

const MountCls = preload("res://scripts/gx_missions/mission_play_mount.gd")


func _initialize() -> void:
	randomize()
	var a := OS.get_cmdline_user_args()
	var fam := a[0].to_upper() if a.size() > 0 else "M3"
	# "T1".."T5" = the fixed tutorial maps M1..M5 (MissionRules + mission GX, morale on).
	var prev := {"source": "tutorial"} if fam.begins_with("T") else {}
	# "SIM" [fixed|mild|broad|counterfactual_valid] = the collection games' board (Step0 sandbox, GX BASIC) + bases + morale.
	if fam == "SIM":
		prev = {"source": "sim", "sim_family": a[1].to_lower() if a.size() > 1 else "fixed", "tier": "BASIC"}
		a = a.slice(1)
	var c: Dictionary = MountCls.pick(MountCls.SIM_MISSION_FAMILY if fam == "SIM" else ("M" + fam.substr(1) if fam.begins_with("T") else fam), prev)
	if a.size() > 1:
		c["tier"] = a[1].to_upper()
	if a.size() > 2:
		c["style"] = a[2].to_upper()
	root.set_meta(MountCls.META, c)
	change_scene_to_file("res://scenes/mission_play.tscn")
