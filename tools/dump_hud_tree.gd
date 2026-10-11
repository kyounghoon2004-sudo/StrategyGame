extends SceneTree
## Dumps the battle HUD controls (CanvasLayers under the shell): name, class,
## anchors, offsets, visibility. Headless, inspection only.
var menu_frames := 0
var done := false
var wait := 0
func _initialize() -> void:
	change_scene_to_file("res://scenes/title_screen.tscn")
func _process(_d: float) -> bool:
	if done:
		return false
	if current_scene != null and current_scene.scene_file_path == "res://scenes/title_screen.tscn":
		menu_frames += 1
		if menu_frames == 8:
			var collection: Node = current_scene.get("_map_collection")
			collection.call("open")
			collection.find_child("OpenExistingProductionLayout", true, false).emit_signal("pressed")
		return false
	if current_scene == null:
		return false
	wait += 1
	if wait < 30:
		return false
	done = true
	for layer in current_scene.find_children("*", "CanvasLayer", true, false):
		print("[HUD] LAYER %s layer=%d path=%s" % [layer.name, (layer as CanvasLayer).layer, current_scene.get_path_to(layer)])
		_dump(layer, 1)
	quit()
	return false
func _dump(n: Node, depth: int) -> void:
	for c in n.get_children():
		if c is Control:
			var k := c as Control
			if depth <= 2 or k is Button:
				print("[HUD] %s%s <%s> vis=%s anchors=(%.2f,%.2f,%.2f,%.2f) off=(%d,%d,%d,%d) %s" % ["  ".repeat(depth), k.name, k.get_class(), k.visible, k.anchor_left, k.anchor_top, k.anchor_right, k.anchor_bottom, k.offset_left, k.offset_top, k.offset_right, k.offset_bottom, ("'" + (k as Button).text.substr(0, 24) + "'") if k is Button else ""])
			if depth < 2:
				_dump(c, depth + 1)
