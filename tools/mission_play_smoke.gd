extends SceneTree

## Smoke test of the mission play mode (2026-10-09): BLUE only ends its turns; checks RED GX acts, the round judge runs
## and the HUD fills. Optional PNG of the window (MISSION_PLAY_SHOT=<path>, needs a window).
##   Godot --path <project> --script res://tools/mission_play_smoke.gd -- M2 [rounds]

const MountCls = preload("res://scripts/gx_missions/mission_play_mount.gd")
var rounds := 4


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	root.set_meta(MountCls.META, MountCls.pick(a[0].to_upper() if a.size() > 0 else "M3"))
	if a.size() > 1:
		rounds = int(a[1])
	change_scene_to_file("res://scenes/mission_play.tscn")
	_run.call_deferred()


func _run() -> void:
	for _i in range(1200):
		await process_frame
		var m: Node = current_scene.get_node_or_null("MissionPlayMount") if current_scene != null else null
		if m != null and m.get("red") != null and bool(m.get("red").get("mount_ready")):
			break
	var mount: Node = current_scene.get_node("MissionPlayMount")
	var shell: Node = current_scene.get_node("Battle")
	if mount.get("red") == null:
		print("[Smoke] FAIL boot: ", mount.get("result_text"))
		quit(1)
		return
	for r in range(rounds):
		if not str(mount.get("result_text")).is_empty() or bool(shell.call("_battle_over")):
			break
		await shell.call("end_player_phase")
		for _j in range(600):
			await process_frame
			if int(shell.get("_turn_phase")) == 0:
				break
		for _k in range(5):
			await process_frame
		print("[Smoke] round %d done: turn=%d red_actions=%s" % [r + 1, int((shell.get("unit_manager") as RefCounted).call("get_current_turn")),
			JSON.stringify(mount.get("red").get("action_counts"))])
	print("[Smoke] HUD:\n", (mount.get("hud") as Label).text)
	var shot := OS.get_environment("MISSION_PLAY_SHOT")
	if not shot.is_empty() and DisplayServer.get_name() != "headless":
		await process_frame
		root.get_viewport().get_texture().get_image().save_png(shot)
	quit(0)
