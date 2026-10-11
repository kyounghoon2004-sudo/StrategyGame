extends SceneTree

## Hex-native evidence capture (windowed only — headless renderer is dummy).
## State machine: settle -> apply view -> settle -> capture -> next -> quit.

const HexUtils = preload("res://scripts/core/hex_utils.gd")

var _shell: Node2D = null
var _cam: Camera2D = null
var _plan: Array = []
var _idx: int = -1 # -1 = initial settle
var _settle: int = 0
var _shots: Array = []
var _cool: int = -1 # -1 = not started; >=0 = fps cooldown frames left
var _acc: float = 0.0
var _frames: int = 0
var _dts: Array = []

func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene
	_shell = packed.instantiate() as Node2D
	root.add_child(_shell)
	_cam = _shell.get_node_or_null("Camera2D") as Camera2D
	# Evidence framing must be exact: kill smoothing convergence variance and
	# edge clamping for the capture run only. Game code untouched.
	if _cam != null:
		_cam.set("position_smoothing", 100000.0)
		_cam.set("_has_bounds", false)
	_plan = [
		{"name": "hex_native_macro", "at": Vector2i(0, 0), "zoom": 0.42},
		{"name": "hex_native_normal", "at": Vector2i(-8, 0), "zoom": 1.15},
		{"name": "hex_native_zoomin", "at": Vector2i(-8, 0), "zoom": 1.80},
		{"name": "hex_native_forest", "at": Vector2i(-26, -2), "zoom": 1.15},
		{"name": "hex_native_mountain_pass", "at": Vector2i(10, -22), "zoom": 1.15},
		{"name": "hex_native_pass_close", "at": Vector2i(10, -22), "zoom": 2.2},
		{"name": "hex_native_river_bridge", "at": Vector2i(-12, 0), "zoom": 1.30},
		{"name": "hex_native_stronghold", "at": Vector2i(-4, 2), "zoom": 1.30},
		{"name": "hex_native_settlement", "at": Vector2i(-18, -1), "zoom": 1.30},
		{"name": "hex_native_units", "at": Vector2i(-22, -1), "zoom": 1.30},
		{"name": "hex_native_fog_explored", "at": Vector2i(-22, -1), "zoom": 0.65},
		{"name": "hex_native_fog_unexplored", "at": Vector2i(8, -5), "zoom": 1.3},
	]
	# resolve real bridge cell once compositor is built (after first frames)
	_settle = 0

func _process(_delta: float) -> bool:
	_settle += 1
	if _idx == -1:
		if _settle < 20:
			return false
		# compositor built by now; snap bridge shot to real crossing
		var b: Vector2i = _find_bridge()
		if b != Vector2i(-999, -999):
			for item in _plan:
				if str((item as Dictionary).get("name", "")) == "hex_native_river_bridge":
					(item as Dictionary)["at"] = b
		_idx = 0
		_settle = 0
		_apply_view(_plan[_idx])
		return false
	if _idx >= _plan.size():
		# End of plan: idle 120 frames for a steady-state fps sample, then quit.
		if _cool == -1:
			_cool = 120
		if _cool > 0:
			_cool -= 1
			_acc += _delta
			_frames += 1
			_dts.append(_delta)
			return false
		if _frames > 0:
			_dts.sort()
			var p50: float = float(_dts[_dts.size() / 2]) * 1000.0
			var p95: float = float(_dts[int(_dts.size() * 0.95)]) * 1000.0
			var mx: float = float(_dts[_dts.size() - 1]) * 1000.0
			print("[HexNativeCapture] steady_fps=%.1f frames=%d p50=%.1fms p95=%.1fms max=%.1fms" % [float(_frames) / maxf(_acc, 0.001), _frames, p50, p95, mx])
		print("[HexNativeCapture] DONE %d shots" % _shots.size())
		_print_diagnostics()
		quit()
		return true
	if _settle < 8:
		return false
	if _settle == 8:
		# Re-snap instantly: one frame of smoothing drift is enough to slide
		# a zoomed close-up off its target cells.
		_apply_view(_plan[_idx])
		_settle += 1
		return false
	print("[HexNativeCapture] shot=%s cam=%s zoom=%s" % [str((_plan[_idx] as Dictionary)["name"]), str(_cam.global_position) if _cam != null else "nocam", str(_cam.zoom) if _cam != null else "?"])
	_save(str((_plan[_idx] as Dictionary)["name"]))
	_idx += 1
	_settle = 0
	if _idx < _plan.size():
		_apply_view(_plan[_idx])
	return false

## Evidence diagnostics: which cell the bridge shot centered on, and the
## authoritative terrain strip through the north pass (road truth vs visual).
func _print_diagnostics() -> void:
	print("[HexNativeCapture] bridge_shot_at=%s" % str(_bridge_plan_at()))
	if _shell != null:
		var grid = _shell.get_node_or_null("HexGrid")
		if grid != null:
			var cell_data: Dictionary = grid.get("cell_data")
			var strip: Array = []
			for q in range(6, 19):
				var cell = cell_data.get("%d,%d" % [q, -22], null)
				strip.append(int(cell.get("terrain")) if cell != null else -1)
			print("[HexNativeCapture] north_pass_r-22_terrain=%s" % str(strip))
		var comp = _shell.get("hex_compositor")
		if comp != null and comp.get("descriptors") != null:
			var descs: Dictionary = comp.get("descriptors")
			var spots: Array = []
			for q in [9, 10, 11]:
				var dd = descs.get(Vector2i(q, -22), null)
				if dd == null:
					spots.append("(%d:-)" % q)
				else:
					spots.append("(%d:t%d/road%d/route%d/pass%d)" % [q, int(dd.terrain_type), int(bool(dd.road_present)), int(dd.route_role), int(bool(dd.pass_corridor))])
			print("[HexNativeCapture] north_pass_desc=%s" % str(spots))
			var roles: Dictionary = {}
			var bridges: Array = []
			for item in (comp.get("structure_plan") as Array):
				var r: int = int(item.get("role", -1))
				roles[r] = int(roles.get(r, 0)) + 1
				if r == 4:
					bridges.append(str(item["anchor"]))
			print("[HexNativeCapture] struct_roles=%s bridges=%s" % [str(roles), str(bridges)])
		var struct_nodes: Array = _shell.find_children("Struct_*", "Sprite2D", true, false)
		var back_nodes: Array = _shell.find_children("BridgeBack_*", "Polygon2D", true, false)
		print("[HexNativeCapture] struct_sprite_nodes=%d bridge_back_nodes=%d" % [struct_nodes.size(), back_nodes.size()])
		for sn in struct_nodes:
			var sp2: Sprite2D = sn as Sprite2D
			var tinfo: String = "nulltex"
			if sp2 != null and sp2.texture != null:
				tinfo = "%dx%d" % [sp2.texture.get_width(), sp2.texture.get_height()]
			print("[HexNativeCapture] structnode %s tex=%s pos=%s vis=%s z=%d" % [sp2.name if sp2 != null else "?", tinfo, str(sp2.position) if sp2 != null else "?", str(sp2.visible) if sp2 != null else "?", int(sp2.z_index) if sp2 != null else -1])
		var pass_cells: int = 0
		var pass_ribbons: int = 0
		if comp != null and comp.get("descriptors") != null:
			var descs2: Dictionary = comp.get("descriptors")
			for c in descs2.keys():
				if bool(descs2[c].pass_corridor):
					pass_cells += 1
			for item in (comp.get("route_ribbons") as Array):
				var rc: Vector2i = item["coord"]
				if descs2.has(rc) and bool(descs2[rc].pass_corridor):
					pass_ribbons += 1
			print("[HexNativeCapture] pass_cells=%d pass_ribbon_polys=%d" % [pass_cells, pass_ribbons])
		if _shell.get("_fog") != null and comp != null and comp.get("descriptors") != null:
			var fg = _shell.get("_fog")
			var vd: Dictionary = fg.get("visible") if fg.get("visible") != null else {}
			var ed: Dictionary = fg.get("explored") if fg.get("explored") != null else {}
			var descs3: Dictionary = comp.get("descriptors")
			var samps: Array = []
			for qq in range(8, 30):
				for rr in range(-8, 10):
					var cc := Vector2i(qq, rr)
					var sk := "%d,%d" % [qq, rr]
					if descs3.has(cc) and not vd.has(sk) and not vd.has(cc) and not ed.has(sk) and not ed.has(cc):
						samps.append(str(cc))
						if samps.size() >= 6:
							break
				if samps.size() >= 6:
					break
			print("[HexNativeCapture] unexplored_sample=%s" % str(samps))
			var fstrip: Array = []
			for qq2 in range(-28, 22, 2):
				var dd2 = descs3.get(Vector2i(qq2, -5), null)
				fstrip.append("%d:%s" % [qq2, str(int(dd2.fog_state)) if dd2 != null else "x"])
			print("[HexNativeCapture] fogstate_r-5=%s vis_n=%d exp_n=%d" % [str(fstrip), vd.size(), ed.size()])
			var fognode: Node = comp.get_node_or_null("HexFog")
			for slotname in ["_mi_explored", "_mi_unexplored"]:
				var infor: String = "%s:missing" % slotname
				if fognode != null:
					var miv = fognode.get(slotname)
					if miv != null and (miv as MeshInstance2D).mesh != null:
						var arr: Array = (miv as MeshInstance2D).mesh.surface_get_arrays(0)
						infor = "%s:verts=%d" % [slotname, (arr[Mesh.ARRAY_VERTEX] as PackedVector2Array).size()]
					elif miv != null:
						infor = "%s:nullmesh" % slotname
				print("[HexNativeCapture] fogmesh %s" % infor)
		print("[HexNativeCapture] perf nodes=%d resources=%d orphans=%d proc=%.2fms phys=%.2fms" % [
			Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
			Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT),
			Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT),
			Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
			Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		])

func _bridge_plan_at() -> String:
	for item in _plan:
		if str((item as Dictionary).get("name", "")) == "hex_native_river_bridge":
			return str((item as Dictionary)["at"])
	return "missing"

func _find_bridge() -> Vector2i:
	if _shell != null and _shell.get("hex_compositor") != null:
		var comp = _shell.get("hex_compositor")
		if comp != null and comp.get("descriptors") != null:
			var descs: Dictionary = comp.get("descriptors")
			for c in descs.keys():
				if int(descs[c].structure_role) == 4:
					return c
	return Vector2i(-999, -999)

func _apply_view(item: Dictionary) -> void:
	var at: Vector2i = item["at"]
	var z: float = float(item["zoom"])
	var wp: Vector2 = HexUtils.hex_to_pixel(at.x, at.y)
	if _cam != null and _cam.has_method("focus_on"):
		_cam.call("focus_on", wp, true)
		_cam.call("set_zoom_level", z, true)
	elif _cam != null:
		_cam.position = wp
		_cam.zoom = Vector2(z, z)

func _save(shot_name: String) -> void:
	var img: Image = root.get_texture().get_image()
	if img == null or img.is_empty():
		print("[HexNativeCapture] NULL image for %s (dummy renderer?)" % shot_name)
		return
	var dir: String = "D:/Game development/Demon slayer/StrategyGame/screenshots/hex_native"
	DirAccess.make_dir_recursive_absolute(dir)
	var path: String = "%s/%s.png" % [dir, shot_name]
	var err: int = img.save_png(path)
	if err != OK:
		print("[HexNativeCapture] SAVE FAILED %s err=%d" % [path, err])
		return
	print("[HexNativeCapture] saved %s" % path)
	_shots.append(path)
