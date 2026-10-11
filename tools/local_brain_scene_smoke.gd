extends SceneTree

## Headless integration smoke for "DEV: Human vs Local (Qwen 8B)" (tool-only).
## 1 title screen loads and has BtnLocalBrainHumanVsLocal
## 2 local_brain_battle_test.tscn mounts in local mode
## 3 the owned CSFT5 server reaches READY (identity verified) and the REAL
##   adapter connection test passes (CONNECTED); INITIAL prefetch starts
## 4 leaving the scene shuts the owned server down (no lingering server)
## Prints SMOKE_CHECK lines; exits 0 only if all checks pass.
## Usage: godot --headless --path <project> -s res://tools/local_brain_scene_smoke.gd

const LocalBrainCls = preload("res://scripts/cloud2/cloud2_local_brain_launcher.gd")

var fails := 0


func _init() -> void:
	call_deferred("_run")


func check(name: String, ok: bool, detail: String = "") -> void:
	print("SMOKE_CHECK %s %s %s" % ["PASS" if ok else "FAIL", name, detail])
	if not ok:
		fails += 1


func _wait_ms(ms: int) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < ms:
		await process_frame


func _find(node: Node, name: String) -> Node:
	if node.name == name:
		return node
	for c in node.get_children():
		var f := _find(c, name)
		if f != null:
			return f
	return null


func _run() -> void:
	change_scene_to_file("res://scenes/title_screen.tscn")
	await _wait_ms(2000)
	check("title_button", _find(root, "BtnLocalBrainHumanVsLocal") != null)
	check("cloud_button_still_present", _find(root, "BtnCloud2HumanVsCloud") != null)
	change_scene_to_file("res://scenes/local_brain_battle_test.tscn")
	await _wait_ms(3000)
	var mount := _find(root, "Cloud2LiveMount")
	check("mount_present", mount != null)
	if mount == null:
		quit(1)
		return
	check("brain_mode_local", str(mount.get("brain_mode")) == "local_qwen8b", str(mount.get("brain_mode")))
	var t0 := Time.get_ticks_msec()
	var ready := false
	while Time.get_ticks_msec() - t0 < 300000:
		var cfg = mount.get("cloud_config")
		if bool(mount.get("mount_ready")) and cfg != null and str(cfg.get("connection_status")) == "CONNECTED":
			ready = true
			break
		if str(LocalBrainCls.status_snapshot().get("status", "")) == "DISABLED":
			break
		await _wait_ms(500)
	var snap := LocalBrainCls.status_snapshot()
	check("local_brain_ready", str(snap.get("status", "")) == "READY", JSON.stringify(snap))
	check("adapter_is_csft5", str(snap.get("adapter_sha256", "")) == LocalBrainCls.CSFT5_SHA256)
	var cfg2 = mount.get("cloud_config")
	check("provider_local", cfg2 != null and str(cfg2.get("provider_id")) == "local_qwen8b",
		str(cfg2.get("provider_id")) if cfg2 != null else "null")
	check("connection_tested", ready)
	check("strict_env_on", OS.get_environment("TRAINING_STRICT_CONTRACT") == "1")
	var hud_lines: Array = mount.get("_hud_lines")
	await _wait_ms(1500)
	var brain_line := str((hud_lines[1] as Label).text) if hud_lines.size() > 1 else ""
	check("hud_local_label", brain_line.begins_with("RED BRAIN: LOCAL Qwen3-8B CSFT5"), brain_line)
	var ctl = mount.get("cloud_controller")
	var ist: Dictionary = ctl.victory_initial_status() if ctl != null and ctl.has_method("victory_initial_status") else {}
	check("initial_prefetch_started", str(ist.get("state", "")) in ["REQUESTING", "READY", "RETRYING", "FAILED"],
		str(ist.get("state", "")))
	var owned := bool(snap.get("owned", false))
	change_scene_to_file("res://scenes/title_screen.tscn")
	await _wait_ms(12000)
	var still := LocalBrainCls.probe_identity(1500)
	check("owned_server_stopped_on_exit", (not owned) or still.is_empty(), "owned=%s alive=%s" % [str(owned), str(not still.is_empty())])
	print("SMOKE_RESULT %s fails=%d" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(0 if fails == 0 else 1)
