extends SceneTree
## V2: a unit with no MP left (fortify spends all of it) hands the selection to the next unit by itself.
## godot --path . --script res://tools/rules_v2/test_auto_next.gd
var fails := 0
func check(name: String, ok: bool, extra: String = "") -> void:
	print(("PASS " if ok else "FAIL ") + name + ((" | " + extra) if extra != "" else ""))
	if not ok: fails += 1

func _init() -> void:
	var shell: Node = (load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene).instantiate()
	shell.set("battlefield_id", "EDITOR_M1")
	shell.set("no_fog", true)
	root.add_child(shell)
	for i in 120:
		await process_frame
	var um = shell.get("unit_manager")
	var id := "B_CONS_2"
	um.call("select_unit", id)
	await process_frame
	check("unit selected", um.get_selected_unit_id() == id)
	var res: Dictionary = um.v2_fortify(id)
	check("fortify works", res.get("success", false), str(res.get("error", "")))
	check("fortify spent all MP", float(um._units[id]["remaining_mp"]) == 0.0)
	shell.call("_v2_after_action", id, "요새화")
	await create_timer(1.6).timeout
	print("[T] phase ", shell.get("_turn_phase"), " lock ", shell.get("symmetric_auto_lock"), " anim ", shell.get("_is_animating_movement"), " ", shell.get("_is_animating_combat"), " unresolved ", um.get_unresolved_count())
	var sel: String = um.get_selected_unit_id() if um.is_unit_selected() else ""
	check("selection moved on to another unit", sel != "" and sel != id, sel)
	# a unit with MP left must NOT be skipped
	var keep := "B_CONS_3"
	um.call("select_unit", keep)
	shell.call("_v2_after_action", keep, "이동")
	await create_timer(1.0).timeout
	check("a unit with MP left keeps the selection", um.is_unit_selected() and um.get_selected_unit_id() == keep)
	print("=== auto next test: %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)
