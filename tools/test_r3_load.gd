extends SceneTree

func _init() -> void:
	print("--- Testing Battlefield Shell Scene Load ---")
	var scene = load("res://scenes/step2r_battlefield_shell.tscn")
	if scene == null:
		print("FAIL: Could not load step2r_battlefield_shell.tscn")
		quit(1)
		return
	var inst = scene.instantiate()
	root.add_child(inst)
	print("SUCCESS: step2r_battlefield_shell.tscn instantiated and added to root!")
	# Let it run 2 frames to execute _ready() and initial ticks
	await process_frame
	await process_frame
	print("Shell node ready successfully! painted_terrain=%s" % str(inst.get("painted_terrain")))
	inst.queue_free()
	quit(0)
