extends SceneTree
## Windowed steady-state presentation cost per mode (vsync off): frame time
## (CPU wall per frame) and measured GPU render time of the main viewport plus
## the projection's offscreen viewports. Works on pre- and post-change trees.
## Usage: godot --path <p> --script res://tools/visual_contract/perf_modes_probe.gd -- <out.json> [sandbox 0|1]

var _shell: Node
var _out: String
var _frame: int = 0
var _t_last: int = 0
var _stage: int = 0
var _stage_frame: int = 0
var _samples: Dictionary = {}
var _gpu: Dictionary = {}
var _rids: Array = []
const WARM := 120
const MEASURE := 180
const STAGES := ["closeup", "high_tactical", "high_commander"]

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	_out = args[0]
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	root.size = Vector2i(1920, 1080)
	var ps: PackedScene = load("res://scenes/step2r_battlefield_shell.tscn")
	_shell = ps.instantiate()
	_shell.set("is_step0_sandbox", args.size() > 1 and args[1] == "1")
	root.add_child(_shell)
	_t_last = Time.get_ticks_usec()

func _measure_rids() -> void:
	_rids = [root.get_viewport_rid()]
	var proj: Node = _shell.get("_projection")
	if proj:
		for k in ["_sub", "_sub_far"]:
			var sv: SubViewport = proj.get(k)
			if sv:
				_rids.append(sv.get_viewport_rid())
	var v: Node = _shell.get_node_or_null("BattlefieldCloseupView")
	if v:
		var ov: SubViewport = v.get("_overlay_vp")
		if ov:
			_rids.append(ov.get_viewport_rid())
	for r in _rids:
		RenderingServer.viewport_set_measure_render_time(r, true)

func _enter_stage(i: int) -> void:
	var cam: Node = _shell.get_node_or_null("Camera2D")
	var v: Node = _shell.get_node_or_null("BattlefieldCloseupView")
	match STAGES[i]:
		"high_tactical":
			if v:
				v.call("request_mode", false)
		"high_commander":
			if cam:
				cam.call("set_zoom_level", float(cam.get("min_zoom")), true)

func _process(_d: float) -> bool:
	var now := Time.get_ticks_usec()
	var dt := float(now - _t_last) / 1000.0
	_t_last = now
	_frame += 1
	if _frame == 90:
		_measure_rids()
		_stage = 0
		_stage_frame = 0
		_enter_stage(0)
		return false
	if _frame < 90:
		return false
	_stage_frame += 1
	if _stage_frame > WARM:
		var key: String = STAGES[_stage]
		if not _samples.has(key):
			_samples[key] = []
			_gpu[key] = []
		(_samples[key] as Array).append(dt)
		var g := 0.0
		for r in _rids:
			g += RenderingServer.viewport_get_measured_render_time_gpu(r)
		(_gpu[key] as Array).append(g)
	if _stage_frame >= WARM + MEASURE:
		_stage += 1
		_stage_frame = 0
		if _stage >= STAGES.size():
			_finish()
			return true
		_enter_stage(_stage)
	return false

static func _stats(a: Array) -> Dictionary:
	var s := a.duplicate()
	s.sort()
	var sum := 0.0
	for x in s:
		sum += float(x)
	return {"avg": sum / maxf(1.0, s.size()), "median": s[s.size() / 2], "p95": s[int(s.size() * 0.95)]}

func _finish() -> void:
	var rep := {}
	for k in _samples.keys():
		rep[k] = {"frame_ms": _stats(_samples[k]), "gpu_ms": _stats(_gpu[k])}
	var f := FileAccess.open(_out, FileAccess.WRITE)
	f.store_string(JSON.stringify(rep, "  ", true))
	f.close()
	print("[PERF] ", JSON.stringify(rep))
