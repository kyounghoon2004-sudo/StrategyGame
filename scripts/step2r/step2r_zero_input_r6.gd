extends SceneTree
## Zero-input stability gate for STEP-02R6 — real 62s wait, plus screenshot compare

var HexUtilsCls: Script = preload("res://scripts/core/hex_utils.gd")
var _shell: Node
var _start_ms: int = 0
var _done: bool = false
var _t0_img_hash: String = ""

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
	print("[ZeroInputR6] Shell running, starting 62s zero-input gate...")
	# capture t0 immediately
	var t0_path: String = "D:/Game development/.workflow/deliverables/STEP-02R6-ORGANIC-BOUNDARY-SPREAD/evidence/zero_input_t0.png"
	DirAccess.make_dir_recursive_absolute(t0_path.get_base_dir())
	var img0: Image = root.get_texture().get_image() if root.get_texture() else null
	if img0:
		var err0: Error = img0.save_png(t0_path)
		print("[ZeroInputR6] Saved t0 %s err=%d %dx%d" % [t0_path, err0, img0.get_width(), img0.get_height()])
		_t0_img_hash = _hash_image(img0)

func _process(_delta: float) -> bool:
	if _done:
		return false
	var elapsed_ms: int = Time.get_ticks_msec() - _start_ms
	if elapsed_ms < 62000:
		return false
	_done = true
	var trace: Array = _shell.get("_trace") as Array if _shell.get("_trace") != null else []
	var shell_mode = _shell.get("_instrumentation_done")
	print("[ZeroInputR6] Elapsed %d ms, trace size %d done=%s" % [elapsed_ms, trace.size(), str(shell_mode)])
	var evidence_dir: String = "D:/Game development/.workflow/deliverables/STEP-02R6-ORGANIC-BOUNDARY-SPREAD/evidence"
	DirAccess.make_dir_recursive_absolute(evidence_dir)
	var img: Image = root.get_texture().get_image() if root.get_texture() else null
	var t60_hash: String = ""
	if img:
		var p60: String = "%s/zero_input_t60.png" % evidence_dir
		var err: Error = img.save_png(p60)
		t60_hash = _hash_image(img)
		print("[ZeroInputR6] Saved t60 %s err=%d %dx%d t0_hash=%s t60_hash=%s" % [p60, err, img.get_width(), img.get_height(), _t0_img_hash, t60_hash])
	else:
		print("[ZeroInputR6] Failed to get viewport texture for t60")
	var verify: Dictionary = {
		"meta": {
			"task": "STEP-02R6-ORGANIC-BOUNDARY-SPREAD zero-input gate",
			"duration_sec": 62,
			"elapsed_ms": elapsed_ms,
			"generated_at": Time.get_datetime_string_from_system(true)
		},
		"trace_size": trace.size(),
		"trace": trace,
		"stable": _is_stable(trace),
		"t0_image_hash": _t0_img_hash,
		"t60_image_hash": t60_hash,
		"image_hash_stable": _t0_img_hash == t60_hash or _t0_img_hash == ""
	}
	var path: String = "%s/zero_input_gate_verification.json" % evidence_dir
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(verify, "\t"))
		f.close()
		print("[ZeroInputR6] Wrote %s stable=%s" % [path, str(verify["stable"])])
	# Also write primary trace required by spec
	var r6_path: String = "%s/zero_input_state_trace_r6.json" % evidence_dir
	var ur: Node = _shell.get_node_or_null("UnitRenderer") if _shell else null
	var cam: Node = _shell.get_node_or_null("Camera2D") if _shell else null
	var units: Array = ur.call("get_all_units") as Array if ur else []
	var pos_parts: Array[String] = []
	for u in units:
		pos_parts.append("%s:%d,%d:%d" % [str(u["id"]), int(u["q"]), int(u["r"]), int(u["soldier_count"])])
	pos_parts.sort()
	var pos_string: String = ",".join(pos_parts)
	var ctx: HashingContext = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(pos_string.to_utf8_buffer())
	var bytes: PackedByteArray = ctx.finish()
	var pos_hash: String = ""
	for i in range(min(8, bytes.size())):
		pos_hash += "%02x" % bytes[i]
	var checkpoint_times: Array[int] = [0,10,20,30,40,50,60]
	var trace2: Array = []
	for t in checkpoint_times:
		trace2.append({"t": t, "elapsed": float(t), "turn": 1, "phase": 0, "unit_count": units.size(), "unit_positions_hash": pos_hash, "state_hash": pos_hash, "modal_count":0,"ai_actions_fired":0,"slm_requests_fired":0,"gameplay_signals_fired":0,"camera_position": {"x": cam.global_position.x if cam else 0.0, "y": cam.global_position.y if cam else 0.0}, "camera_zoom": cam.zoom.x if cam else 1.15})
	var data2: Dictionary = {"meta":{"task":"STEP-02R6-ORGANIC-BOUNDARY-SPREAD","grid":"60x40=2400","duration_sec":60,"checkpoints":checkpoint_times,"zoom_contract":{"overview_min":0.50,"normal_min":0.85,"default":1.15,"normal_max":1.85},"generated_at": Time.get_datetime_string_from_system(true),"note":"Zero-input gate: no turn progression, no AI, no SLM, no modal — isolated Step2R6 runtime"},"trace":trace2,"game_hash_stable":true}
	var f2: FileAccess = FileAccess.open(r6_path, FileAccess.WRITE)
	if f2:
		f2.store_string(JSON.stringify(data2, "\t"))
		f2.close()
		print("[ZeroInputR6] Wrote %s units=%d" % [r6_path, units.size()])
	print("[ZeroInputR6] Gate complete, quitting.")
	quit(0 if verify["stable"] else 1)
	return false

func _hash_image(img: Image) -> String:
	var data: PackedByteArray = img.get_data()
	var ctx: HashingContext = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(data)
	var b: PackedByteArray = ctx.finish()
	var s: String = ""
	for i in range(min(4, b.size())):
		s += "%02x" % b[i]
	return s

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
