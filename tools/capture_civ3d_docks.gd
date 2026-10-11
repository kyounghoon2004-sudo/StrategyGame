extends SceneTree
## Captures the CIV3D HUD docks open and minimized (VISUAL CHECK ONLY).
const OUT := "res://evidence/civ3d_showcase/"
var menu_frames := 0
var f := 0
var entered := false
func _initialize() -> void:
	change_scene_to_file("res://scenes/title_screen.tscn")
func _process(_d: float) -> bool:
	if current_scene != null and current_scene.scene_file_path == "res://scenes/title_screen.tscn":
		menu_frames += 1
		if menu_frames == 8:
			var collection: Node = current_scene.get("_map_collection")
			collection.call("open")
			collection.find_child("OpenExistingProductionLayout", true, false).emit_signal("pressed")
		return false
	if current_scene == null or current_scene.get("_view3d") == null:
		return false
	f += 1
	if f == 90:
		RenderingServer.frame_post_draw.connect(func(): root.get_texture().get_image().save_png(OUT + "06_docks_open.png"), CONNECT_ONE_SHOT)
	if f == 95:
		var hud: Node = current_scene.get("hud_layer")
		for n in ["OrdersPanel", "AdvisorWindow"]:
			var p: Node = hud.find_child(n, true, false)
			if p:
				(p.get("_collapse_btn") as Button).emit_signal("pressed")
	if f == 110:
		RenderingServer.frame_post_draw.connect(func(): root.get_texture().get_image().save_png(OUT + "07_docks_minimized.png"), CONNECT_ONE_SHOT)
	if f == 115:
		quit()
	return false
