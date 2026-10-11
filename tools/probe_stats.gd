extends SceneTree
## Throwaway: prints per-variant mountain build stats (cover tree counts).
const Builder = preload("res://scripts/visual/map_composition_v0/map_composition_builder.gd")

func _initialize() -> void:
	for v in [5, 6, 7, 8]:
		var r: Dictionary = Builder.build_mountain(v, 777)
		var st: Dictionary = r["stats"]
		print("[stats] v=%d %s pieces=%s cover=%s tri=%d viol=%.4f" % [
			v, st["name"], str((st["spec"] as Dictionary).get("pieces", -1)),
			str((st["spec"] as Dictionary).get("cover_trees", "NONE")),
			int(st["triangles"]), float(st["max_violation"])])
	quit(0)
