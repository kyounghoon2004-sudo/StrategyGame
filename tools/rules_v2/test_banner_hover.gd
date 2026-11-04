extends SceneTree
## Hovering / clicking a structure's NAME PLATE (not its hex) unfolds its detail.
## godot --audio-driver Dummy --path . --script res://tools/rules_v2/test_banner_hover.gd
var fails := 0
func check(name: String, ok: bool, extra: String = "") -> void:
	print(("PASS " if ok else "FAIL ") + name + ((" | " + extra) if extra != "" else ""))
	if not ok: fails += 1

func _init() -> void:
	var shell: Node = (load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene).instantiate()
	shell.set("battlefield_id", "EDITOR_M1")
	shell.set("no_fog", true)
	root.add_child(shell)
	for i in 150:
		await process_frame
	await create_timer(2.0).timeout
	var art = shell.get("_v2_artifacts")
	var hex := Vector2i(-6, -7)
	var bn = art._banners.get("%d,%d" % [hex.x, hex.y])
	check("banner exists", bn != null)
	var sc: float = bn.scale.x
	var tl: Vector2 = bn.position + bn.pivot_offset * (1.0 - sc)
	var inside: Vector2 = tl + Vector2(bn.size.x * 0.7, bn.size.y * 0.45) * sc
	check("banner_at finds the banner on its name plate", art.banner_at(inside) == hex, str(art.banner_at(inside)))
	check("banner_at is empty far from it", art.banner_at(Vector2(5, 5)) == Vector2i(-999, -999))
	var plate_world: Vector2 = shell.call("_pointer_world", inside)
	var plate_hex: Vector2i = load("res://scripts/step2r/step2r_world_boundary.gd").world_to_axial(plate_world)
	print("[T] the plate sits over hex ", plate_hex, " (the structure is ", hex, ")")
	# a click on the plate pins the structure even though the pointer is over another hex
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = inside
	shell.call("_input", ev)
	check("click on the name plate pins the structure", art._pin == hex, str(art._pin))
	check("so its detail is unfolded", art.is_revealed(hex))
	art._pin = Vector2i(-999, -999)
	print("=== banner hover test: %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)
