extends SceneTree
func _init():
	var Lib = load("res://scripts/visual/map_composition_v0/map_composition_library.gd")
	var Builder = load("res://scripts/visual/map_composition_v0/map_composition_builder.gd")
	var root := Node3D.new()
	var t0: int = Time.get_ticks_msec()
	for i in range(4921):
		var tile: Node3D = Builder.build_tile("tile_open_grassland")
		root.add_child(tile)
	var dt: int = Time.get_ticks_msec() - t0
	print("Instantiated 4921 full GLB tiles in %d ms!" % dt)
	quit(0)
