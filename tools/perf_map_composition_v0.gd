extends SceneTree
## Perf harness for the map composition review scene.
## Usage: -s res://tools/perf_map_composition_v0.gd -- <view> <msaa:0|2> <shadows:1|0> <treeshadow:1|0>
## Measures a 120-frame steady-state sample at the given view and prints results.
## `<view>` is a focus-rect key (e.g. ALL, RANGE2, FA) or ALLP (overview pitch).

const Capture = preload("res://tools/capture_map_composition_v0.gd")

var _scene: Node = null
var _frames := 0
var _acc := 0.0
var _dts: Array = []
var _args: PackedStringArray = []
var _view := "RANGE2"
var _msaa := -1
var _shadows := -1
var _treeshadow := -1
var _nocast := -1
var _started := false


func _initialize() -> void:
	_args = OS.get_cmdline_user_args()
	if _args.size() > 0:
		_view = _args[0]
	if _args.size() > 1:
		_msaa = int(_args[1])
	if _args.size() > 2:
		_shadows = int(_args[2])
	if _args.size() > 3:
		_treeshadow = int(_args[3])
	if _args.size() > 4:
		_nocast = int(_args[4])
	print("[perf] view=%s msaa=%d shadows=%d treeshadow=%d" % [_view, _msaa, _shadows, _treeshadow])
	change_scene_to_file("res://scenes/review/map_composition_v0.tscn")


func _process(delta: float) -> bool:
	var cs: Node = current_scene
	if cs == null or cs.get("built") == null or not bool(cs.get("built")):
		return false
	if not _started:
		_started = true
		_scene = cs
		if _msaa >= 0:
			root.get_viewport().msaa_3d = _msaa
		if _shadows == 0:
			for n in _find_all(cs, "DirectionalLight3D"):
				(n as DirectionalLight3D).shadow_enabled = false
		if _treeshadow == 0:
			for n in _tree_meshes(cs):
				(n as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if _nocast == 0:
			var cnt := 0
			for n in _all_meshes(cs):
				(n as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				cnt += 1
			print("[perf] nocast applied to %d meshes" % cnt)
		var rect: Rect2 = _scene.call("focus_rect", _view)
		var pitch := 0.0
		if _view == "ALLP":
			rect = _scene.call("focus_rect", "ALL")
			pitch = 33.8
		_scene.call("set_view_zoom", 1.6, rect, 1.12, pitch)
		return false
	if _frames < 180:
		if _frames >= 60:  # skip warmup
			_acc += delta
			_dts.append(delta)
		_frames += 1
		return false
	var arr: Array = _dts.duplicate()
	arr.sort()
	var p50: float = float(arr[arr.size() / 2]) * 1000.0
	var p95: float = float(arr[int(arr.size() * 0.95)]) * 1000.0
	print("[perf] RESULT view=%s msaa=%d shadows=%d treeshadow=%d fps=%.1f p50=%.2fms p95=%.2fms nodes=%d" % [
		_view, _msaa, _shadows, _treeshadow, float(_dts.size()) / maxf(_acc, 0.001), p50, p95,
		Performance.get_monitor(Performance.OBJECT_NODE_COUNT)])
	quit(0)
	return true


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
	## Mesh instances that belong to a wrap created by _add_asset whose name is
	## NOT a mountain/tile piece — i.e. trees (forest + village + cover trees).
	var out: Array = []
	if node is MeshInstance3D:
		var anc: Node = node
		var is_tree := false
		while anc != null:
			var nm := String(anc.name)
			if nm.begins_with("P_"):
				if nm.find("foothill") == -1 and nm.find("tile_") == -1 and nm.find("stone_wall") == -1:
					is_tree = true
				break
			anc = anc.get_parent()
		if is_tree:
			out.append(node)
	for ch in node.get_children():
		out.append_array(_tree_meshes(ch))
	return out
