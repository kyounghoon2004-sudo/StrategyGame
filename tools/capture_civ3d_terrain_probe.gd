extends SceneTree

## CIV3D terrain probe (VISUAL CHECK ONLY): in a throwaway run, moves the 2D
## DISPLAY nodes of a few friendly units onto visible forest / mountain /
## village / farm hexes and shoots close-ups, to check that a hex's terrain
## still reads under a formation. Logical unit positions are never touched and
## nothing is saved except the screenshots.

const OUT := "res://evidence/civ3d_terrain_probe/"
const Hex = preload("res://scripts/core/hex_utils.gd")
## [label, terrain id, needs a village / capital neighbour (farm)]
const WANT := [["forest", 2, false], ["mountain", 1, false], ["village", 5, false], ["farm", 0, true], ["plain", 0, false]]
const ZOOMS := [2.4, 4.0]

var shell: Node
var view: Node
var shots: Array = [] # [name, world pos, zoom]
var index := -1
var frames := 0
var menu_frames := 0
var forced: Array = [] # probe only: hexes kept visible in the view's fog texture

func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	change_scene_to_file("res://scenes/title_screen.tscn")

func _process(_delta: float) -> bool:
	if current_scene != null and current_scene.scene_file_path == "res://scenes/title_screen.tscn":
		menu_frames += 1
		if menu_frames == 8:
			var collection: Node = current_scene.get("_map_collection")
			collection.call("open")
			collection.find_child("OpenExistingProductionLayout", true, false).emit_signal("pressed")
		return false
	if index == -1:
		if current_scene == null:
			return false
		shell = current_scene
		view = shell.get("_view3d")
		if view == null or not bool(view.call("is_active")):
			return false
		_place_units()
		index = 0
		_apply()
		return false
	var img: Image = view.get("_cell_img")
	for h in forced:
		var px: Color = img.get_pixel(h.x + 85, h.y + 85)
		if px.g8 != 255:
			px.g8 = 255
			img.set_pixel(h.x + 85, h.y + 85, px)
			view.set("_cell_dirty", true)
	frames += 1
	if frames < 24:
		return false
	if index < shots.size():
		RenderingServer.frame_post_draw.connect(_save, CONNECT_ONE_SHOT)
		frames = -1000000
	return false

func _place_units() -> void:
	var cells: Dictionary = shell.get("hex_grid").get("cell_data")
	var fog: Object = shell.get("_fog")
	var ur: Node = shell.get("unit_renderer")
	var occupied: Dictionary = {}
	var movers: Array = []
	for u in ur.call("get_all_units"):
		occupied[Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))] = true
		if str(u.get("faction", "")) == "blue" and str(u.get("class", "")) in ["infantry", "spearman", "archer", "cavalry", "conscript"]:
			movers.append(u)
	var used: Dictionary = {}
	var mi := 0
	for want in WANT:
		var best: Variant = null
		var best_d := 1e9
		for c in cells.values():
			var h := Vector2i(int(c.q), int(c.r))
			if int(c.terrain) != int(want[1]) or occupied.has(h) or used.has(h):
				continue
			if fog != null and int(fog.call("get_fog_state", h.x, h.y)) != 2 and int(want[1]) != 1:
				continue
			if bool(want[2]):
				var near := false
				for d in Hex.DIRECTIONS:
					var k := "%d,%d" % [h.x + d.x, h.y + d.y]
					if cells.has(k) and int(cells[k].terrain) in [5, 11]:
						near = true
				if not near:
					continue
			var dist: float = Hex.hex_to_pixel(h.x, h.y).length()
			if dist < best_d:
				best_d = dist
				best = h
		if best == null or mi >= movers.size():
			print("[TerrainProbe] no visible free hex for ", want[0])
			continue
		used[best] = true
		var u: Dictionary = movers[mi]
		mi += 1
		var n2: Node2D = ur.call("get_unit_node", str(u["id"])) as Node2D
		var w: Vector2 = Hex.hex_to_pixel(best.x, best.y)
		n2.position = w
		for d in [Vector2i.ZERO] + Hex.DIRECTIONS:
			forced.append(best + d)
		for z in ZOOMS:
			shots.append(["%s_%s_z%.1f" % [want[0], str(u["class"]), z], w, z])
		print("[TerrainProbe] ", want[0], " -> ", best, " unit ", u["id"])

func _apply() -> void:
	var camera: Node = shell.get("camera")
	camera.call("set_zoom_level", float(shots[index][2]), true)
	camera.call("focus_on", shots[index][1], true)
	frames = 0

func _save() -> void:
	root.get_texture().get_image().save_png(OUT + shots[index][0] + ".png")
	index += 1
	if index < shots.size():
		_apply()
	else:
		print("[TerrainProbe] COMPLETE ", shots.size())
		quit()
