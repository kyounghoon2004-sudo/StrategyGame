extends SceneTree
## V2: figures stand still unless hovered / selected / walking / in a fight.
## godot --audio-driver Dummy --path . --script res://tools/rules_v2/test_idle_freeze.gd
var fails := 0
func check(name: String, ok: bool, extra: String = "") -> void:
	print(("PASS " if ok else "FAIL ") + name + ((" | " + extra) if extra != "" else ""))
	if not ok: fails += 1

func _active(d: Dictionary) -> int:
	var n := 0
	var f3d: Node3D = d["f3d"]
	if f3d == null:
		return -1
	for s in f3d.get("_soldiers"):
		if (s["ap"] as AnimationPlayer).active:
			n += 1
	return n

func _init() -> void:
	var shell: Node = (load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene).instantiate()
	shell.set("battlefield_id", "EDITOR_M1")
	shell.set("no_fog", true)
	root.add_child(shell)
	for i in 150:
		await process_frame
	await create_timer(4.0).timeout
	var um = shell.get("unit_manager")
	var view = shell.get("_view3d")
	var id := "B_CONS_2"
	var d: Dictionary = view._units[id]
	check("idle unit is frozen after settling", bool(d.get("frozen", false)) and _active(d) == 0, "frozen=%s active figures=%d" % [str(d.get("frozen")), _active(d)])
	um.call("select_unit", id)
	await create_timer(0.6).timeout
	check("selected unit animates", not bool(d.get("frozen", true)) and _active(d) > 0, "active figures=%d" % _active(d))
	um.call("deselect")
	await create_timer(1.5).timeout
	check("deselected: frozen again", bool(d.get("frozen", false)) and _active(d) == 0)
	view.call("_busy", id, 3.0)
	await create_timer(0.6).timeout
	check("busy (fight / work) animates", not bool(d.get("frozen", true)) and _active(d) > 0)
	await create_timer(3.5).timeout
	check("after the work: frozen", bool(d.get("frozen", false)) and _active(d) == 0)
	var cav = null
	for k in view._units:
		if str(view._units[k]["cls"]) == "cavalry":
			cav = view._units[k]
	if cav != null:
		check("cavalry frozen too", bool(cav.get("frozen", false)))
	print("=== idle freeze test: %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)
