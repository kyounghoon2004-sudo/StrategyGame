extends SceneTree

## CIV3D morale idle capture (VISUAL CHECK ONLY): three view-only blue units
## of one class side by side at morale level 2 / 1 / 0 (steady / wavering /
## low), idling, so the drop in activity can be compared.
##   Godot --fixed-fps 30 --path <project> --script res://tools/capture_civ3d_morale.gd

const OUT := "res://evidence/civ3d_morale/"
const Hex = preload("res://scripts/core/hex_utils.gd")
var CLASSES := [["infantry", 210], ["scout", 150], ["cavalry", 150]]
var trio: Array = []
var row_step := Vector2i(1, 0)

var shell: Node
var view: Node
var menu_frames := 0
var ci := -1
var frames := 0
var seq_left := 0
var blue: Dictionary = {}
var red: Dictionary = {}
var w_blue := Vector2.ZERO
var w_red := Vector2.ZERO

func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	change_scene_to_file("res://scenes/title_screen.tscn")

func _process(_d: float) -> bool:
	if current_scene != null and current_scene.scene_file_path == "res://scenes/title_screen.tscn":
		menu_frames += 1
		if menu_frames == 8:
			var collection: Node = current_scene.get("_map_collection")
			collection.call("open")
			collection.find_child("OpenExistingProductionLayout", true, false).emit_signal("pressed")
		return false
	if ci == -1:
		if current_scene == null:
			return false
		shell = current_scene
		view = shell.get("_view3d")
		if view == null or not bool(view.call("is_active")):
			return false
		# open ground behind the HQ; red one hex up-screen of blue, face to face
		var hq := _hq_hex()
		var fwd3: Vector3 = view.get("fwd")
		var up := Vector2(fwd3.x, fwd3.z).normalized()
		var step := Vector2i.ZERO
		var best := -2.0
		for n in [Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1), Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1)]:
			var dot: float = (Hex.hex_to_pixel(n.x, n.y) - Hex.hex_to_pixel(0, 0)).normalized().dot(up)
			if dot > best:
				best = dot
				step = n
		# three hexes in a row across the screen: the neighbour step best aligned with screen-right
		var right2 := Vector2(-up.y, up.x)
		var side := Vector2i.ZERO
		var best_r := -2.0
		for n in [Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1), Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1)]:
			var dr: float = (Hex.hex_to_pixel(n.x, n.y) - Hex.hex_to_pixel(0, 0)).normalized().dot(right2)
			if dr > best_r:
				best_r = dr
				side = n
		row_step = side
		var b: Vector2i = _open_pair(hq, side)
		w_blue = Hex.hex_to_pixel(b.x, b.y)
		w_red = Hex.hex_to_pixel(b.x + step.x, b.y + step.y)
		var only: String = OS.get_environment("SPAR_ONLY") # e.g. "archer" for a quick re-check
		if only != "":
			CLASSES = CLASSES.filter(func(c): return c[0] in only.split(","))
		ci = 0
		_begin()
		return false
	if seq_left > 0:
		return false
	frames += 1
	if frames == 15:
		_frame_camera() # again, once the map's own intro camera has settled
	if frames == 45:
		seq_left = int(CLASSES[ci][1])
		RenderingServer.frame_post_draw.connect(_save)
	return false

## Nearest plain hex to the HQ where blue (b) and red (b + step) both stand on
## open plain two to three hexes from the nearest unit (clear, but in sight).
func _open_pair(hq: Vector2i, step: Vector2i) -> Vector2i:
	var cells: Dictionary = shell.get("hex_grid").get("cell_data")
	var occupied: Array = []
	for u in shell.get("unit_renderer").call("get_all_units"):
		occupied.append(Vector2i(int(u.get("q", 0)), int(u.get("r", 0))))
	var play_r: int = int(view.get("PLAY_R"))
	var fog: Variant = shell.get("_fog")
	for radius in range(2, 14):
		for dq in range(-radius, radius + 1):
			for dr in range(-radius, radius + 1):
				var b := hq + Vector2i(dq, dr)
				if _dist(b, hq) != radius:
					continue
				var ok := true
				for h in [b, b + step, b + step * 2]:
					var c: Variant = cells.get("%d,%d" % [h.x, h.y])
					if c == null or int(c.terrain) != 0 or _dist(h, Vector2i.ZERO) > play_r - 2:
						ok = false
					elif fog != null and int(fog.call("get_fog_state", h.x, h.y)) != 2:
						ok = false # in sight right now, not under the shroud
					var near := 99
					for o in occupied:
						near = mini(near, _dist(h, o))
					if near < 2: # clear of units
						ok = false
				if ok:
					return b
	return hq

static func _dist(a: Vector2i, b: Vector2i) -> int:
	var d := a - b
	return (absi(d.x) + absi(d.y) + absi(d.x + d.y)) / 2

func _hq_hex() -> Vector2i:
	var ur: Node = shell.get("unit_renderer")
	for u in ur.call("get_all_units"):
		if str(u.get("faction", "")) == "blue" and str(u.get("class", "")) == "hq":
			return Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))
	return Vector2i.ZERO

func _spawn(cls: String, faction: String, w: Vector2) -> Dictionary:
	var d: Dictionary = view.call("_make_unit", {"id": "spar_%s_%s" % [faction, cls], "class": cls, "faction": faction})
	var root: Node3D = d["root"]
	root.position = view.call("_ground3", w)
	view.call("_place_formation", d, w)
	(d["badge"] as Control).visible = false
	var f: Node3D = d["f3d"]
	f.call("set_far", false)
	f.call("set_rate", 0.0)
	f.call("set_strength", 1.0)
	return d

func _begin() -> void:
	var cls: String = CLASSES[ci][0]
	# side by side across the screen: steady (left) / wavering / low (right)
	var fwd3: Vector3 = view.get("fwd")
	var right := Vector2(-fwd3.z, fwd3.x).normalized()
	var hexw: float = Hex.hex_to_pixel(1, 0).distance_to(Hex.hex_to_pixel(0, 0))
	trio = []
	for k in range(3):
		var hk: Vector2i = Hex.pixel_to_hex(w_blue) + row_step * k
		var d := _spawn(cls, "blue", Hex.hex_to_pixel(hk.x, hk.y))
		(d["f3d"] as Node3D).call("set_morale", 2 - k)
		trio.append(d)
	blue = trio[1]
	red = trio[1]
	_frame_camera()
	frames = 0
	print("[Morale] ", cls)

func _frame_camera() -> void:
	var cam: Node = shell.get("camera")
	cam.call("set_zoom_level", 4.0, true)
	cam.call("focus_on", w_blue, true)

func _attack() -> void:
	var f: Node3D = blue["f3d"]
	var to_target: Vector3 = (red["root"] as Node3D).position - (blue["root"] as Node3D).position
	var rd: Dictionary = red
	f.connect("struck", func(at_local: Vector3):
		view.call("_impact", rd, view.to_local(f.global_transform * at_local))
		# exactly one man falls
		var n: int = (rd["soldiers"] as Array).size()
		(rd["f3d"] as Node3D).call("set_strength", float(n - 1) / float(n)), CONNECT_ONE_SHOT)
	f.call("play_attack", to_target)

func _save() -> void:
	var cls: String = CLASSES[ci][0]
	var img := root.get_texture().get_image()
	# crop around the pair (the camera focus is clamped near the map edge)
	var mid: Vector3 = (trio[1]["root"] as Node3D).position
	var c: Vector2 = (view.get("cam") as Camera3D).unproject_position(mid)
	var x: int = clampi(int(c.x) - 560, 0, img.get_width() - 1120)
	var y: int = clampi(int(c.y) - 260, 0, img.get_height() - 420)
	img.get_region(Rect2i(x, y, 1120, 420)).save_png(OUT + "%s_%03d.png" % [cls, int(CLASSES[ci][1]) - seq_left])
	seq_left -= 1
	if seq_left > 0:
		return
	RenderingServer.frame_post_draw.disconnect(_save)
	for d in trio:
		(d["badge"] as Control).queue_free()
		(d["root"] as Node3D).queue_free()
	ci += 1
	if ci >= CLASSES.size():
		print("[Morale] COMPLETE")
		quit()
		return
	_begin()
