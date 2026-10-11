extends SceneTree

const UnitTypesScript = preload("res://scripts/combat/unit_types.gd")

func _init() -> void:
	var factory = UnitTypesScript.new()
	var dir := "res://data/unit_types"
	DirAccess.make_dir_recursive_absolute(dir)
	var types: Array[UnitType] = [
		factory.make_infantry(),
		factory.make_archers(),
		factory.make_cavalry(),
		factory.make_spearmen(),
		factory.make_siege(),
		factory.make_conscripts(),
		factory.make_scouts(),
	]
	for t in types:
		var path := "%s/%s.tres" % [dir, t.id]
		var err := ResourceSaver.save(t, path)
		print("Saved %s -> %s err=%d" % [t.id, path, err])
	print("DONE")
	quit()
