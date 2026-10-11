extends SceneTree
## STEP-04R5 Runtime Reproduction Driver (pre-edit diagnosis)
## Instantiates the REAL playable scene and exercises REAL signal paths:
##   - Stronghold badge hover (rogue/oversized UI repro)
##   - NextTurnButton.pressed emission (NEXT unit cycling repro)
##   - End turn flow (PLAYER -> ENEMY -> PLAYER cycle repro)
## Writes JSON evidence + screenshots. Read-only: does not modify game code.

var _shell: Node2D
var _frame: int = 0
var _dir: String = "D:/Game development/.workflow/deliverables/STEP-04R5-RUNTIME-TURN-LOOP-RECOVERY/evidence"
var _report: Dictionary = {"phases": []}
var _stage: int = 0
var _wait_until_frame: int = 0
var _next_presses: int = 0
var _next_log: Array = []
var _end_turn_started_frame: int = -1
var _turn_before_end: int = -1
var _enemy_pos_before: Dictionary = {}
var _enemy_pos_after: Dictionary = {}

func _initialize() -> void:
	root.size = Vector2i(1920, 1080)
	root.content_scale_size = Vector2i(1920, 1080)
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	DirAccess.make_dir_recursive_absolute(_dir)
	var scene_res: PackedScene = load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene
	if scene_res == null:
		push_error("[R5-REPRO] Failed to load playable scene")
		quit(1)
		return
	_shell = scene_res.instantiate() as Node2D
	root.add_child(_shell)
	print("[R5-REPRO] Playable scene instantiated")

func _um() -> Variant:
	return _shell.get("unit_manager")

func _sr() -> Node:
	return _shell.get("stronghold_renderer")

func _btn() -> Button:
	return _shell.get("next_turn_button") as Button

func _end_btn() -> Button:
	return _shell.get("end_turn_button") as Button

func _selected_id() -> String:
	var um: Variant = _um()
	return um.get_selected_unit_id() if um else "<none>"

func _unreviewed() -> int:
	var um: Variant = _um()
	return um.get_unreviewed_count() if um else -1

func _badge_panel_size(sid: String) -> Vector2:
	var sr: Node = _sr()
	if sr == null:
		return Vector2(-1, -1)
	var badge: Variant = sr.call("get_badge", sid)
	if badge == null:
		return Vector2(-1, -1)
	var panel: Variant = badge.get("_panel")
	if panel == null:
		return Vector2(-1, -1)
	return panel.size * badge.scale

func _shot(name: String) -> void:
	var img: Image = root.get_texture().get_image()
	img.save_png("%s/%s" % [_dir, name])
	print("[R5-REPRO] screenshot %s" % name)

func _enemy_snapshot() -> Dictionary:
	var snap: Dictionary = {}
	var um: Variant = _um()
	for u in um.get_all_units():
		if str(u["faction"]) == "red":
			snap[str(u["id"])] = "%d,%d:%d" % [int(u["q"]), int(u["r"]), int(u["soldier_count"])]
	return snap

func _process(_delta: float) -> bool:
	_frame += 1
	match _stage:
		0:
			if _frame >= 6:
				_stage0_connections()
		1:
			if _frame >= _wait_until_frame:
				_stage1_hover_repro()
		10:  # capital hover settle
			if _frame >= _wait_until_frame:
				_report["capital_panel_hovered"] = str(_badge_panel_size("Capital_Luoyang"))
				print("[R5-REPRO] Capital badge panel HOVERED screen size=%s" % _report["capital_panel_hovered"])
				_shot("repro_hover_capital_expansion.png")
				_sr().call("set_stronghold_hovered", "Capital_Luoyang", false)
				_stage = 2
				_wait_until_frame = _frame + 2
		2:
			if _frame >= _wait_until_frame:
				_stage2_next_repro()
		20:  # record NEXT result
			if _frame >= _wait_until_frame:
				var entry: Dictionary = {
					"press": _next_presses,
					"before": _report.get("_pending_before", ""),
					"after": _selected_id(),
					"unreviewed_before": _report.get("_pending_unrev", -1),
					"unreviewed_after": _unreviewed(),
					"button_text": _btn().text,
					"camera_pos": str(_shell.get("camera").global_position if _shell.get("camera") else Vector2.ZERO)
				}
				_next_log.append(entry)
				print("[R5-REPRO] NEXT #%d: '%s' -> '%s' | unreviewed %d->%d | btn='%s'" % [entry["press"], entry["before"], entry["after"], entry["unreviewed_before"], entry["unreviewed_after"], entry["button_text"]])
				_stage = 2
				_wait_until_frame = _frame + 1
		21:  # drain queue until END TURN appears
			if _frame >= _wait_until_frame:
				var t: String = _btn().text
				if t.contains("END TURN") or _unreviewed() <= 0:
					print("[R5-REPRO] Queue exhausted after %d presses; button='%s'" % [_next_presses, t])
					_report["presses_to_exhaust"] = _next_presses
					_stage = 3
					_wait_until_frame = _frame + 1
				elif _next_presses > 45:
					_report["queue_never_exhausted"] = true
					print("[R5-REPRO] FAIL: queue never exhausted after 45 presses, unreviewed=%d" % _unreviewed())
					_stage = 6
				else:
					_report["_pending_before"] = _selected_id()
					_report["_pending_unrev"] = _unreviewed()
					_btn().pressed.emit()
					_next_presses += 1
					_wait_until_frame = _frame + 2
					_stage = 20
		3:
			if _frame >= _wait_until_frame:
				_stage3_end_turn_begin()
		4:
			_stage4_poll_enemy_phase()
		5:
			if _frame >= _wait_until_frame:
				_stage5_post_turn_check()
		22:  # post-reset NEXT result
			if _frame >= _wait_until_frame:
				_report["post_reset_next"] = {
					"before": _report.get("_pending_before", ""),
					"after": _selected_id(),
					"button_text": _btn().text
				}
				print("[R5-REPRO] Post-reset NEXT: '%s' -> '%s' btn='%s'" % [_report["_pending_before"], _selected_id(), _btn().text])
				_stage = 6
		6:
			_finish()
	return false

func _stage0_connections() -> void:
	var nb: Button = _btn()
	var eb: Button = _end_btn()
	var nb_conns: int = nb.get_signal_connection_list("pressed").size() if nb else -1
	var eb_conns: int = eb.get_signal_connection_list("pressed").size() if eb else -1
	print("[R5-REPRO] NextTurnButton exists=%s pressed_connections=%d text='%s'" % [str(nb != null), nb_conns, nb.text if nb else "?"])
	print("[R5-REPRO] EndTurnButton exists=%s pressed_connections=%d text='%s' visible=%s" % [str(eb != null), eb_conns, eb.text if eb else "?", str(eb.visible) if eb else "?"])
	_report["next_button_connections"] = nb_conns
	_report["end_turn_button_connections"] = eb_conns
	_report["end_turn_button_present"] = (eb != null)
	_report["unreviewed_start"] = _unreviewed()
	_report["selected_start"] = _selected_id()
	print("[R5-REPRO] unreviewed_start=%d selected='%s' turn=%d" % [_unreviewed(), _selected_id(), _um().get_current_turn()])
	# Rogue UI baseline: compact badge panel size (screen-space)
	_report["fortress_panel_compact"] = str(_badge_panel_size("Fortress_Hulao"))
	_report["capital_panel_compact"] = str(_badge_panel_size("Capital_Luoyang"))
	print("[R5-REPRO] Fortress badge panel compact screen size=%s" % _report["fortress_panel_compact"])
	print("[R5-REPRO] Capital badge panel compact screen size=%s" % _report["capital_panel_compact"])
	# Trigger hover via the SAME live path the shell uses on mouse motion
	var sr: Node = _sr()
	sr.call("set_stronghold_hovered", "Fortress_Hulao", true)
	_wait_until_frame = _frame + 4
	_stage = 1

func _stage1_hover_repro() -> void:
	_report["fortress_panel_hovered"] = str(_badge_panel_size("Fortress_Hulao"))
	print("[R5-REPRO] Fortress badge panel HOVERED screen size=%s" % _report["fortress_panel_hovered"])
	_shot("repro_hover_fortress_expansion.png")
	var sr: Node = _sr()
	sr.call("set_stronghold_hovered", "Fortress_Hulao", false)
	sr.call("set_stronghold_hovered", "Capital_Luoyang", true)
	_stage = 10  # interim: capital hover
	_wait_until_frame = _frame + 4

func _stage2_next_repro() -> void:
	# Press NEXT via REAL signal emission; record selection transitions
	if _next_presses < 6:
		var before: String = _selected_id()
		var unrev_before: int = _unreviewed()
		_btn().pressed.emit()
		_next_presses += 1
		# wait 3 frames then record
		_wait_until_frame = _frame + 3
		_stage = 20  # record sub-stage
		_report["_pending_before"] = before
		_report["_pending_unrev"] = unrev_before
	else:
		_stage = 21  # drain queue
		_wait_until_frame = _frame + 1

func _stage3_end_turn_begin() -> void:
	_turn_before_end = _um().get_current_turn()
	_enemy_pos_before = _enemy_snapshot()
	print("[R5-REPRO] END TURN pressed at turn=%d unreviewed=%d" % [_turn_before_end, _unreviewed()])
	_btn().pressed.emit()
	_end_turn_started_frame = _frame
	_stage = 4

func _stage4_poll_enemy_phase() -> void:
	var now_turn: int = _um().get_current_turn()
	if now_turn != _turn_before_end:
		_enemy_pos_after = _enemy_snapshot()
		var moved: Array = []
		var casualties: Array = []
		for id in _enemy_pos_before.keys():
			if not _enemy_pos_after.has(id):
				casualties.append(id + "(destroyed/removed)")
			elif _enemy_pos_after[id] != _enemy_pos_before[id]:
				moved.append("%s: %s -> %s" % [id, _enemy_pos_before[id], _enemy_pos_after[id]])
		for id in _enemy_pos_after.keys():
			if not _enemy_pos_before.has(id):
				moved.append("%s: appeared %s" % [id, _enemy_pos_after[id]])
		print("[R5-REPRO] ENEMY PHASE COMPLETE: turn %d -> %d | enemy actions=%d" % [_turn_before_end, now_turn, moved.size()])
		for m in moved.slice(0, 12):
			print("[R5-REPRO]   enemy delta: %s" % m)
		_report["enemy_actions"] = moved
		_report["enemy_casualty_events"] = casualties
		_report["enemy_action_count"] = moved.size()
		_report["turn_incremented"] = now_turn == _turn_before_end + 1
		_wait_until_frame = _frame + 3
		_stage = 5
	elif _frame > _end_turn_started_frame + 3600:  # 60s timeout at 60fps
		_report["enemy_phase_timeout"] = true
		print("[R5-REPRO] FAIL: enemy phase never completed within 60s")
		_stage = 6

func _stage5_post_turn_check() -> void:
	_report["unreviewed_after_reset"] = _unreviewed()
	_report["button_text_after_reset"] = _btn().text
	print("[R5-REPRO] Post-turn: unreviewed=%d button='%s' turn=%d" % [_unreviewed(), _btn().text, _um().get_current_turn()])
	# Verify NEXT queue restored: one more press must select a real unit
	var before: String = _selected_id()
	_btn().pressed.emit()
	_wait_until_frame = _frame + 3
	_report["_pending_before"] = before
	_report["_pending_unrev"] = _unreviewed()
	_stage = 22

func _finish() -> void:
	_report["next_log"] = _next_log
	var f: FileAccess = FileAccess.open("%s/repro_report.json" % _dir, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(_report, "  "))
		f.close()
	print("[R5-REPRO] DONE — report written")
	quit(0)
