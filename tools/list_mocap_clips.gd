extends SceneTree
## MEASUREMENT ONLY: list the retargeted mocap clips and their lengths.
func _initialize() -> void:
	var lib: AnimationLibrary = load("res://assets/units/mocap_mixamo/soldier_mixamo_lib.res")
	for n in lib.get_animation_list():
		print("%-34s %.2f s" % [n, lib.get_animation(n).length])
	quit()
