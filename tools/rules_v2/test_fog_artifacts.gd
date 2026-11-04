extends SceneTree
## Fog of war on: enemy supply bases / edge bases / icons must NOT show unless the hex is visible.
## godot --path . --script res://tools/rules_v2/test_fog_artifacts.gd

var fails := 0

func check(name: String, ok: bool, extra: String = "") -> void:
	print(("PASS " if ok else "FAIL ") + name + ((" | " + extra) if extra != "" else ""))
	if not ok:
		fails += 1

func _init() -> void:
	var shell: Node = (load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene).instantiate()
	shell.set("battlefield_id", "EDITOR_M1")
	root.add_child(shell)
	for i in 150:
		await process_frame
	var um = shell.get("unit_manager")
	var art = shell.get("_v2_artifacts")
	check("fog of war is on in this test", shell.get("_fog") != null)
	# blue builds one base, red builds one (far away, in the fog)
	um._units["B_HQ"]["action_ended"] = false
	check("blue HQ builds", um.v2_build_base("B_HQ").get("success", false))
	check("red base exists in the rules", um.supply_v2.place_node(um._units, "red").get("success", false))
	for i in 40:
		await process_frame
	var blue_models := 0
	var red_models := 0
	for key in art._models:
		if str(key).contains("red") or (str(key).begins_with("B:RED")):
			red_models += 1
		else:
			blue_models += 1
	check("blue edge bases + the new base are shown", blue_models >= 3, "models %s" % str(art._models.keys()))
	check("no enemy base model is shown in the fog", red_models == 0, "red models %d" % red_models)
	var red_hex_icons := 0
	for key in art._clusters:
		if str(art._clusters[key]["sig"]).contains("/red/"):
			red_hex_icons += 1
	check("no enemy icon is shown in the fog", red_hex_icons == 0, "red icons %d" % red_hex_icons)
	var red_entry: Vector2i = um.supply_v2.fixed["red"]["entries"][0]
	check("enemy edge base cannot be hovered while unseen", not art._artifact_hexes.has(red_entry))
	# the blue edge bases carry no icon, only the HQ-built base does
	var blue_icons := 0
	for key in art._clusters:
		if str(art._clusters[key]["sig"]).contains("base/blue"):
			blue_icons += 1
	check("only the built base has an icon (edge bases do not)", blue_icons == 1, "base icons %d" % blue_icons)
	check("blue edge bases can still be hovered", art._artifact_hexes.has(um.supply_v2.fixed["blue"]["entries"][0]))
	print("=== fog artifacts test: %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)
