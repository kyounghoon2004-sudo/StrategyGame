extends SceneTree
## Compiles every CIV3D script headless (CPU only) and reports errors.
func _initialize() -> void:
	var bad := 0
	for f in DirAccess.get_files_at("res://scripts/visual/civ3d"):
		if not f.ends_with(".gd"):
			continue
		var s: GDScript = load("res://scripts/visual/civ3d/" + f)
		var ok := s != null and s.can_instantiate()
		if not ok:
			bad += 1
		print("[Compile] %-28s %s" % [f, "ok" if ok else "FAILED"])
	for f in ["res://tools/play_civ3d.gd", "res://scripts/visual/full_dev_map_transplant.gd", "res://scripts/step2r/step2r_battlefield_shell.gd"]:
		var s2: GDScript = load(f)
		print("[Compile] %-28s %s" % [f.get_file(), "ok" if s2 != null and s2.can_instantiate() else "FAILED"])
	print("[Compile] failures: ", bad)
	quit()
