extends SceneTree
## PERF HARNESS V1 for the map composition review scene — expanded profiling.
##
## Usage (key=value user args, all optional):
##   Godot_console.exe --path "<proj>" -s res://tools/perf_map_composition_v1.gd -- view=GAME msaa=2 shadows=1 gpu=1 frames=180 warmup=60
##   msaa accepts sample counts 0, 2, 4, 8 (not Godot's enum ordinals).
##
## Views (same camera math as v0 / capture script):
##   GAME    — zoom 1.15 over ALL (normal gameplay zoom, capture shot 01)
##   ALL     — zoom 1.6 over ALL
##   ALLP    — zoom 1.6 over ALL at diagnostic pitch 33.8 (the historical "full-map overview")
##   RANGE2  — zoom 1.6 over the range2 rect (gallery view)
##   FORESTS — zoom 1.6 over the 6 forest hexes
##   FA/VA/CA— single-hex close views (forest A / village A / city A)
##
## Conditions: VSync disabled, fixed 180-frame sample (60 warmup skipped — identical
## to v0 for comparability), MSAA and shadow config set explicitly, one run prints
## one RESULT line with frame-time percentiles plus renderer/shadow-pass counters.
##
## Metrics: fps, p50/p95/p99/mean frame ms, Performance.RENDER_TOTAL_* (main +
## shadow pass objects/primitives/draw calls), viewport render info, renderer
## memory monitors, node count, and (opt gpu=1) measured GPU frame time when the
## renderer supports it.

const Capture = preload("res://tools/capture_map_composition_v0.gd")

var _scene: Node = null
var _frames := 0
var _warmup := 60
var _total := 180
var _acc := 0.0
var _dts: Array = []
var _process_ms: Array = []
var _render_cpu_ms: Array = []
var _render_gpu_ms: Array = []
var _args: PackedStringArray = []

var _view := "GAME"
var _msaa := -1
var _shadows := -1
var _treeshadow := -1
var _nocast := -1
var _sd := -1.0
var _smode := ""
var _sblur := -1.0
var _split1 := -1.0
var _split2 := -1.0
var _split3 := -1.0
var _lodth := -1.0
var _gpu := false
var _rid: RID
var _gpu_ok := false
var _started := false


func _initialize() -> void:
	_args = OS.get_cmdline_user_args()
	for a in _args:
		var eq := a.find("=")
		if eq <= 0:
			# legacy positional: first bare arg = view
			_view = a
			continue
		var k := a.substr(0, eq)
		var v := a.substr(eq + 1)
		match k:
			"view": _view = v
			"msaa": _msaa = int(v)
			"shadows": _shadows = int(v)
			"treeshadow": _treeshadow = int(v)
			"nocast": _nocast = int(v)
			"sd": _sd = float(v)
			"smode": _smode = v
			"sblur": _sblur = float(v)
			"split1": _split1 = float(v)
			"split2": _split2 = float(v)
			"split3": _split3 = float(v)
			"lodth": _lodth = float(v)
			"gpu": _gpu = bool(int(v))
			"frames": _total = int(v)
			"warmup": _warmup = int(v)
	# deterministic benchmarking conditions
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	print("[perf1] view=%s msaa_samples=%d shadows=%d treeshadow=%d nocast=%d sd=%.1f smode=%s sblur=%.2f lodth=%.2f frames=%d warmup=%d" % [
		_view, _msaa, _shadows, _treeshadow, _nocast, _sd, _smode, _sblur, _lodth, _total, _warmup])
	change_scene_to_file("res://scenes/review/map_composition_v0.tscn")


func _process(delta: float) -> bool:
	var cs: Node = current_scene
	if cs == null or cs.get("built") == null or not bool(cs.get("built")):
		return false
	if not _started:
		_started = true
		_scene = cs
		_apply_knobs(cs)
		if _gpu:
			_rid = root.get_viewport().get_viewport_rid()
			RenderingServer.viewport_set_measure_render_time(_rid, true)
			_gpu_ok = true
		var rect: Rect2 = _scene.call("focus_rect", "ALL")
		var zoom := 1.6
		var pitch := 0.0
		match _view:
			"GAME":
				zoom = 1.15
			"ALL":
				zoom = 1.6
			"ALLP":
				zoom = 1.6
				pitch = 33.8
			"RANGE2":
				rect = _scene.call("focus_rect", "RANGE2")
			"FORESTS":
				rect = _scene.call("focus_rect", "FORESTS")
			"FA":
				rect = _scene.call("focus_rect", "FA")
				zoom = 2.2
			"VA":
				rect = _scene.call("focus_rect", "VA")
				zoom = 2.8
			"CA":
				rect = _scene.call("focus_rect", "CA")
				zoom = 2.8
			"MOUNTAINS":
				rect = _scene.call("focus_rect", "MOUNTAINS")
			_:
				rect = _scene.call("focus_rect", "ALL")
		_scene.call("set_view_zoom", zoom, rect, 1.12, pitch)
		return false
	if _frames < _total:
		if _frames >= _warmup:
			_acc += delta
			_dts.append(delta)
			_process_ms.append(float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0)
			if _gpu_ok:
				var c: float = RenderingServer.viewport_get_measured_render_time_cpu(_rid)
				if c > 0.0:
					_render_cpu_ms.append(c)
				var g: float = RenderingServer.viewport_get_measured_render_time_gpu(_rid)
				if g > 0.0:
					_render_gpu_ms.append(g)
		_frames += 1
		return false
	_finish()
	return true


func _apply_knobs(cs: Node) -> void:
	if _msaa >= 0:
		match _msaa:
			0: root.get_viewport().msaa_3d = Viewport.MSAA_DISABLED
			2: root.get_viewport().msaa_3d = Viewport.MSAA_2X
			4: root.get_viewport().msaa_3d = Viewport.MSAA_4X
			8: root.get_viewport().msaa_3d = Viewport.MSAA_8X
			_: push_error("msaa must be one of 0, 2, 4, 8 samples")
	if _lodth >= 0.0:
		root.get_viewport().mesh_lod_threshold = _lodth
	var sun: DirectionalLight3D = null
	for n in _find_all(cs, "DirectionalLight3D"):
		sun = n
	if sun != null:
		if _shadows == 0:
			sun.shadow_enabled = false
		if _sd > 0.0:
			sun.directional_shadow_max_distance = _sd
		if _sblur >= 0.0:
			sun.shadow_blur = _sblur
		if _smode == "pssm2":
			sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
		elif _smode == "pssm4":
			sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
		elif _smode == "ortho":
			sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
		if _split1 >= 0.0:
			sun.directional_shadow_split_1 = _split1
		if _split2 >= 0.0:
			sun.directional_shadow_split_2 = _split2
		if _split3 >= 0.0:
			sun.directional_shadow_split_3 = _split3
	if _treeshadow == 0:
		var cnt := 0
		for n in _tree_meshes(cs):
			(n as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			cnt += 1
		print("[perf1] treeshadow off on %d mesh instances" % cnt)
	if _nocast == 0:
		var cnt2 := 0
		for n in _all_meshes(cs):
			(n as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			cnt2 += 1
		print("[perf1] nocast applied to %d meshes" % cnt2)


func _finish() -> void:
	var arr: Array = _dts.duplicate()
	arr.sort()
	var n := arr.size()
	var p50: float = float(arr[n / 2]) * 1000.0
	var p95: float = float(arr[int(n * 0.95)]) * 1000.0
	var p99: float = float(arr[int(n * 0.99)]) * 1000.0
	var mean: float = (_acc / maxf(n, 1)) * 1000.0
	var fps: float = float(n) / maxf(_acc, 0.001)
	var process_p50: float = _median(_process_ms)
	var render_cpu_p50: float = _median(_render_cpu_ms)
	var render_gpu_p50: float = _median(_render_gpu_ms)
	var ri := root.get_viewport().get_viewport_rid()
	var vp_objects: int = RenderingServer.viewport_get_render_info(ri, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_OBJECTS_IN_FRAME)
	var vp_prims: int = RenderingServer.viewport_get_render_info(ri, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME)
	var vp_dc: int = RenderingServer.viewport_get_render_info(ri, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME)
	var sh_objects: int = RenderingServer.viewport_get_render_info(ri, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_SHADOW, RenderingServer.VIEWPORT_RENDER_INFO_OBJECTS_IN_FRAME)
	var sh_prims: int = RenderingServer.viewport_get_render_info(ri, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_SHADOW, RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME)
	var sh_dc: int = RenderingServer.viewport_get_render_info(ri, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_SHADOW, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME)
	var res := {
		"view": _view, "msaa": _msaa, "shadows": _shadows, "treeshadow": _treeshadow,
		"nocast": _nocast, "sd": _sd, "smode": _smode, "sblur": _sblur,
		"lodth": _lodth, "msaa_effective_enum": int(root.get_viewport().msaa_3d),
		"viewport_size": [root.get_viewport().size.x, root.get_viewport().size.y],
		"render_texture_size": [root.get_texture().get_width(), root.get_texture().get_height()],
		"content_scale_size": [root.content_scale_size.x, root.content_scale_size.y],
		"content_scale_mode": int(root.content_scale_mode),
		"fps": snappedf(fps, 0.1),
		"p50_ms": snappedf(p50, 0.01), "p95_ms": snappedf(p95, 0.01),
		"p99_ms": snappedf(p99, 0.01), "mean_ms": snappedf(mean, 0.01),
		"process_p50_ms": snappedf(process_p50, 0.01),
		"render_cpu_p50_ms": snappedf(render_cpu_p50, 0.01), "render_cpu_samples": _render_cpu_ms.size(),
		"render_gpu_p50_ms": snappedf(render_gpu_p50, 0.01), "render_gpu_samples": _render_gpu_ms.size(),
		"render_objects": int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		"render_prims": int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		"render_draw_calls": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"shadow_objects": sh_objects, "shadow_prims": sh_prims, "shadow_draw_calls": sh_dc,
		"vp_objects": vp_objects, "vp_prims": vp_prims, "vp_draw_calls": vp_dc,
		"video_mem_mb": snappedf(float(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)) / 1048576.0, 0.1),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
	}
	print("[perf1] RESULT " + JSON.stringify(res))
	quit(0)
	return


func _median(values: Array) -> float:
	if values.is_empty():
		return -1.0
	var ordered: Array = values.duplicate()
	ordered.sort()
	return float(ordered[ordered.size() / 2])


func _find_all(node: Node, cls: String) -> Array:
	var out: Array = []
	if node.is_class(cls):
		out.append(node)
	for ch in node.get_children():
		out.append_array(_find_all(ch, cls))
	return out


func _all_meshes(node: Node) -> Array:
	var out: Array = []
	if node is MeshInstance3D:
		out.append(node)
	for ch in node.get_children():
		out.append_array(_all_meshes(ch))
	return out


func _tree_meshes(node: Node) -> Array:
	## Tree geometry = MeshInstance3D or MultiMeshInstance3D under a "P_"-prefixed
	## wrap that is NOT a mountain/tile piece (matches v0 semantics; v0 ignored
	## MultiMesh — v1 counts both, so the flag works before AND after batching).
	var out: Array = []
	if node is MeshInstance3D or node is MultiMeshInstance3D:
		var anc: Node = node
		var is_tree := false
		while anc != null:
			var nm := String(anc.name)
			if nm.begins_with("P_"):
				if MapCompositionLibrary.TREES.has(nm.substr(2)):
					is_tree = true
				break
			anc = anc.get_parent()
		if is_tree:
			out.append(node)
	for ch in node.get_children():
		out.append_array(_tree_meshes(ch))
	return out
