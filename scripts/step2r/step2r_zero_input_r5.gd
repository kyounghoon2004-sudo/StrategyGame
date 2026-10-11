extends SceneTree
## Zero-input stability gate for STEP-02R5 — real 62s wait

var HexUtilsCls: Script = preload("res://scripts/core/hex_utils.gd")
var _shell: Node
var _start_ms: int = 0
var _done: bool = false

func _initialize() -> void:
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	root.size = Vector2i(1920,1080)
	get_root().transparent_bg = false
	_start_ms = Time.get_ticks_msec()
	var scn: PackedScene = load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene
	assert(scn != null, "shell scene missing")
	_shell = scn.instantiate() as Node
	assert(_shell != null, "instantiate failed")
	root.add_child(_shell)
	await process_frame
	await process_frame
	print("[ZeroInputR5] Shell running, starting 62s zero-input gate...")

func _process(_delta: float) -> bool:
	if _done:
		return false
	var elapsed_ms: int = Time.get_ticks_msec() - _start_ms
	# wait 62 seconds (62000 ms) to cover checkpoints 0..60
	if elapsed_ms < 62000:
		return false
	_done = true
	# Collect trace from shell
	var trace: Array = _shell.get("_trace") as Array if _shell.get("_trace") != null else []
	var shell_mode = _shell.get("_instrumentation_done")
	print("[ZeroInputR5] Elapsed %d ms, trace size %d done=%s" % [elapsed_ms, trace.size(), str(shell_mode)])
	# Persist verification
	var evidence_dir: String = "D:/Game development/.workflow/deliverables/STEP-02R5-BOUNDARY-OVERVIEW-ZOOM/evidence"
	DirAccess.make_dir_recursive_absolute(evidence_dir)
	# Capture screenshots t0 already done, now capture t60
	var img: Image = root.get_texture().get_image() if root.get_texture() else null
	if img:
		var p0: String = "%s/zero_input_t0.png" % evidence_dir
		var p60: String = "%s/zero_input_t60.png" % evidence_dir
		# t0 already exists, overwrite t60
		var err: Error = img.save_png(p60)
		print("[ZeroInputR5] Saved t60 screenshot %s err=%d size %dx%d" % [p60, err, img.get_width(), img.get_height()])
	else:
		print("[ZeroInputR5] Failed to get viewport texture for t60")
	# Also write verification json
	var verify: Dictionary = {
		"meta": {
			"task": "STEP-02R5-BOUNDARY-OVERVIEW-ZOOM zero-input gate",
			"duration_sec": 62,
			"elapsed_ms": elapsed_ms,
			"generated_at": Time.get_datetime_string_from_system(true)
		},
		"trace_size": trace.size(),
		"trace": trace,
		"stable": _is_stable(trace)
	}
	var path: String = "%s/zero_input_gate_verification.json" % evidence_dir
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(verify, "	"))
		f.close()
		print("[ZeroInputR5] Wrote %s stable=%s" % [path, str(verify["stable"])])
	# quit
	print("[ZeroInputR5] Gate complete, quitting.")
	quit(0 if verify["stable"] else 1)
	return false

func _is_stable(trace: Array) -> bool:
	if trace.size() < 7:
		return false
	var first_state: String = str(trace[0].get("state_hash", ""))
	var first_pos: String = str(trace[0].get("unit_positions_hash", ""))
	var first_turn: Variant = trace[0].get("turn")
	var first_units: int = int(trace[0].get("unit_count", 0))
	for snap in trace:
		if str(snap.get("state_hash")) != first_state: return false
		if str(snap.get("unit_positions_hash")) != first_pos: return false
		if snap.get("turn") != first_turn: return false
		if int(snap.get("unit_count")) != first_units: return false
		if int(snap.get("modal_count",0)) != 0: return false
		if int(snap.get("ai_actions_fired",0)) != 0: return false
		if int(snap.get("slm_requests_fired",0)) != 0: return false
	return true
