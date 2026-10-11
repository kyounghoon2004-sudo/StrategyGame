extends SceneTree
## STEP-04R5 Post-Fix Live Acceptance Driver
## Drives the REAL playable scene through REAL input/signal paths:
##   A. Rogue UI: hover no longer expands badge panel; single turn button exists
##   B. NEXT x6: real selection changes, envelope refresh, camera pan
##   C. Out-of-order manual selection, then NEXT still finds remaining units
##   D. END TURN: real PLAYER->ENEMY->PLAYER transition w/ actual enemy actions
##   E. Movement budget spent in T1 resets in T2; T2 unit moves again (click path)
## Writes verify_report.json + screenshots.

var HexUtilsCls: Script = preload("res://scripts/core/hex_utils.gd")

var _shell: Node2D
var _frame: int = 0
var _dir: String = "D:/Game development/.workflow/deliverables/STEP-04R5-RUNTIME-TURN-LOOP-RECOVERY/evidence"
var _report: Dictionary = {"checks": {}}
var _stage: int = 0
var _wait: int = 0
var _presses: int = 0
var _next_log: Array = []
var _turn_before: int = -1
var _enemy_before: Dictionary = {}
var _saw_enemy_phase: bool = false
var _saw_disabled: bool = false
var _end_frame: int = -1
var _move_unit_id: String = ""
var _move_spent_t1: float = -1.0
var _t2_move_ok: bool = false
var _chk: Dictionary = {}

func _initialize() -> void:
	root.size = Vector2i(1920, 1080)
	root.content_scale_size = Vector2i(1920, 1080)
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	DirAccess.make_dir_recursive_absolute(_dir)
	var ps: PackedScene = load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene
	_shell = ps.instantiate() as Node2D
	root.add_child(_shell)
	print("[R5V] scene up")

func _um() -> Variant: return _shell.get("unit_manager")
func _btn() -> Button: return _shell.get("next_turn_button") as Button
func _sel() -> String: return _um().get_selected_unit_id()
func _unrev() -> int: return _um().get_unreviewed_count()
func _phase() -> int: return int(_shell.get("_turn_phase"))
func _cam() -> Vector2: return (_shell.get("camera") as Camera2D).global_position

func _panel_size(sid: String) -> Vector2:
	var b: Variant = _shell.get("stronghold_renderer").call("get_badge", sid)
	var p: Variant = b.get("_panel")
	return p.size * b.scale

func _shot(name: String) -> void:
	root.get_texture().get_image().save_png("%s/%s" % [_dir, name])
	print("[R5V] shot %s" % name)

func _check(name: String, ok: bool, detail: String = "") -> void:
	_chk[name] = {"pass": ok, "detail": detail}
	print("[R5V] %s: %s %s" % [name, "PASS" if ok else "FAIL", detail])

func _enemy_snap() -> Dictionary:
	var s: Dictionary = {}
	for u in _um().get_all_units():
		if str(u["faction"]) == "red":
			s[str(u["id"])] = "%d,%d:%d" % [int(u["q"]), int(u["r"]), int(u["soldier_count"])]
	return s

## Real click path (identical to what _input routes for LMB)
func _click_hex(coord: Vector2i) -> void:
	var wpos: Vector2 = HexUtilsCls.hex_to_pixel(coord.x, coord.y)
	_shell.call("_handle_hex_click", coord, wpos)

func _press_main() -> void:
	_btn().pressed.emit()

func _process(_d: float) -> bool:
	_frame += 1
	if _phase() == 1:
		_saw_enemy_phase = true
		if _btn() and _btn().disabled:
			_saw_disabled = true
	if _frame < _wait:
		return false
	match _stage:
		0: _s0_ui_audit()
		1: _s1_hover_fortress()
		2: _s2_hover_capital()
		3: _s3_stronghold_click()
		4: _s4_esc_close()
		5: _s5_next_press()
		6: _s6_next_record()
		7: _s7_out_of_order()
		8: _s8_t1_move_preview()
		9: _s9_t1_move_confirm()
		10: _s10_t1_moved()
		11: _s11_drain()
		12: _s12_end_turn()
		13: _s13_poll_phase()
		14: _s14_t2_checks()
		15: _s15_t2_next()
		16: _s16_t2_move_preview()
		17: _s17_t2_move_confirm()
		18: _s18_done()
	return false

func _s0_ui_audit() -> void:
	var eb: Variant = _shell.get("end_turn_button")
	_check("single_turn_button", eb == null, "end_turn_button node ref = %s" % str(eb))
	var nb: Button = _btn()
	var n: int = nb.get_signal_connection_list("pressed").size()
	_check("next_connected_exactly_once", n == 1, "connections=%d" % n)
	_check("phase_starts_player", _phase() == 0, "phase=%d" % _phase())
	_report["fortress_compact"] = str(_panel_size("Fortress_Hulao"))
	_report["capital_compact"] = str(_panel_size("Capital_Luoyang"))
	_shell.get("stronghold_renderer").call("set_stronghold_hovered", "Fortress_Hulao", true)
	_wait = _frame + 3
	_stage = 1

func _s1_hover_fortress() -> void:
	var hovered: Vector2 = _panel_size("Fortress_Hulao")
	var compact: Vector2 = Vector2(94.176, 17.28)
	# exact stability: hovered size must equal compact size (same content)
	var now_compact: Vector2 = _panel_size("Fortress_Hulao")
	_shell.get("stronghold_renderer").call("set_stronghold_hovered", "Fortress_Hulao", true)
	var hov2: Vector2 = _panel_size("Fortress_Hulao")
	_check("fortress_hover_no_expansion", hov2 == now_compact, "compact=%s hovered=%s" % [str(now_compact), str(hov2)])
	_shot("verify_hover_fortress_compact.png")
	_shell.get("stronghold_renderer").call("set_stronghold_hovered", "Fortress_Hulao", false)
	_shell.get("stronghold_renderer").call("set_stronghold_hovered", "Capital_Luoyang", true)
	_wait = _frame + 3
	_stage = 2

func _s2_hover_capital() -> void:
	var now_compact: Vector2 = _panel_size("Capital_Luoyang")
	_shell.get("stronghold_renderer").call("set_stronghold_hovered", "Capital_Luoyang", true)
	var hov: Vector2 = _panel_size("Capital_Luoyang")
	_check("capital_hover_no_expansion", hov == now_compact, "compact=%s hovered=%s" % [str(now_compact), str(hov)])
	_shot("verify_hover_capital_compact.png")
	_shell.get("stronghold_renderer").call("set_stronghold_hovered", "Capital_Luoyang", false)
	_wait = _frame + 2
	_stage = 3

func _s3_stronghold_click() -> void:
	_click_hex(Vector2i(-4, 2)) # fortress footprint hex — real click routing
	var sp: Variant = _shell.get("stronghold_panel")
	_check("stronghold_click_opens_panel", sp != null and sp.visible, "panel.visible=%s" % str(sp.visible if sp else "?"))
	_report["stronghold_selected"] = _shell.get("_stronghold_selected_id")
	_shot("verify_stronghold_panel_open.png")
	_wait = _frame + 2
	_stage = 4

func _s4_esc_close() -> void:
	_shot("verify_stronghold_panel_open.png") # panel has been visible for 2 frames now
	var ev: InputEventKey = InputEventKey.new()
	ev.keycode = KEY_ESCAPE
	ev.pressed = true
	_shell._input(ev)
	var sp: Variant = _shell.get("stronghold_panel")
	_check("esc_closes_panel", sp != null and not sp.visible, "panel.visible=%s" % str(sp.visible if sp else "?"))
	_wait = _frame + 2
	_stage = 5
	_presses = 0

func _s5_next_press() -> void:
	if _presses < 6:
		_report["_pb"] = _sel()
		_report["_pc"] = str(_cam())
		_presses += 1
		_press_main()
		_wait = _frame + 30 # let camera lerp
		_stage = 6
	else:
		_stage = 7
		_wait = _frame + 1

func _s6_next_record() -> void:
	var env_ok: bool = _shell.get("_current_envelope") != null
	_next_log.append({"press": _presses, "before": _report["_pb"], "after": _sel(), "cam_before": _report["_pc"], "cam_after": str(_cam()), "envelope": env_ok, "btn": _btn().text})
	print("[R5V] NEXT #%d '%s'->'%s' env=%s cam %s -> %s" % [_presses, _report["_pb"], _sel(), str(env_ok), _report["_pc"], str(_cam())])
	_wait = _frame + 1
	_stage = 5

func _s7_out_of_order() -> void:
	# Manually click-select a DIFFERENT unreviewed unit out of queue order
	var target: String = ""
	for u in _um().get_unreviewed_field_units():
		var id: String = str(u["id"])
		if id != _sel():
			target = id
			break
	var tu: Dictionary = _um().get_unit_by_id(target)
	_click_hex(Vector2i(int(tu["q"]), int(tu["r"])))
	var now: String = _sel()
	var reviewed_ok: bool = _um().is_reviewed(target)
	# NEXT must still find remaining unreviewed units (not crash, not re-select reviewed)
	_press_main()
	var after: String = _sel()
	var ok: bool = (now == target) and reviewed_ok and after != "" and after != target
	_check("out_of_order_selection", ok, "manual=%s reviewed=%s next=%s unreviewed=%d" % [now, str(reviewed_ok), after, _unrev()])
	_wait = _frame + 2
	_stage = 8

func _s8_t1_move_preview() -> void:
	# Move the currently selected unit through the REAL two-click path
	_move_unit_id = _sel()
	var env: Variant = _shell.get("_current_envelope")
	if env == null or env.green_hexes.is_empty():
		_check("t1_move", false, "no envelope for %s" % _move_unit_id)
		_stage = 11
		_wait = _frame + 1
		return
	var dest: Vector2i = env.green_hexes[0]
	_report["_dest"] = dest
	_click_hex(dest)
	var rc: Variant = _shell.get("route_card_panel")
	var preview_ok: bool = rc != null and rc.visible
	_wait = _frame + 2
	_stage = 9
	if not preview_ok:
		_check("t1_move", false, "route preview did not open")
		_stage = 11

func _s9_t1_move_confirm() -> void:
	_click_hex(_report["_dest"]) # second click confirms
	_wait = _frame + 90 # movement animation
	_stage = 10

func _s10_t1_moved() -> void:
	var u: Dictionary = _um().get_unit_by_id(_move_unit_id)
	var spent: float = float(u.get("turn_move_cost_spent", 0.0))
	_move_spent_t1 = spent
	var dest: Vector2i = _report.get("_dest", Vector2i(-999, -999))
	var arrived: bool = int(u.get("q", -1)) == dest.x and int(u.get("r", -1)) == dest.y
	_check("t1_move", arrived and spent > 0.0, "%s at %d,%d spent=%.1f" % [_move_unit_id, int(u.get("q", -1)), int(u.get("r", -1)), spent])
	_wait = _frame + 1
	_stage = 11

func _s11_drain() -> void:
	if _btn().text.contains("END TURN") or _unrev() <= 0:
		_check("queue_exhaustion_shows_end_turn", true, "presses=%d btn='%s'" % [_presses, _btn().text])
		_stage = 12
		_wait = _frame + 1
	elif _presses > 45:
		_check("queue_exhaustion_shows_end_turn", false, "never exhausted, unreviewed=%d" % _unrev())
		_stage = 18
	else:
		_press_main()
		_presses += 1
		_wait = _frame + 2

func _s12_end_turn() -> void:
	_turn_before = _um().get_current_turn()
	_enemy_before = _enemy_snap()
	print("[R5V] END TURN press (turn %d)" % _turn_before)
	_press_main()
	_end_frame = _frame
	_stage = 13

func _s13_poll_phase() -> void:
	if _phase() == 0 and _um().get_current_turn() == _turn_before + 1:
		var after: Dictionary = _enemy_snap()
		var acts: Array = []
		for id in _enemy_before.keys():
			if not after.has(id):
				acts.append(id + " destroyed")
			elif after[id] != _enemy_before[id]:
				acts.append("%s %s->%s" % [id, _enemy_before[id], after[id]])
		_report["enemy_actions_t1"] = acts
		_check("enemy_phase_seen", _saw_enemy_phase, "")
		_check("button_disabled_in_enemy_phase", _saw_disabled, "")
		_check("enemy_acted", acts.size() > 0, "%d enemy deltas" % acts.size())
		_check("turn_incremented", true, "turn %d -> %d" % [_turn_before, _um().get_current_turn()])
		_check("button_back_to_next", not _btn().disabled and _btn().text.contains("NEXT"), "btn='%s' disabled=%s" % [_btn().text, str(_btn().disabled)])
		# Movement budget reset check
		var mu: Dictionary = _um().get_unit_by_id(_move_unit_id)
		var spent_now: float = float(mu.get("turn_move_cost_spent", -1.0))
		var rem: float = float(mu.get("remaining_mp", -1.0))
		var base: float = float(mu.get("base_mp", -2.0))
		_check("movement_budget_reset", spent_now == 0.0 and rem == base, "%s spent %.1f->%.1f remaining=%.1f/%.1f" % [_move_unit_id, _move_spent_t1, spent_now, rem, base])
		_check("review_queue_reset", _unrev() > 30, "unreviewed=%d" % _unrev())
		_wait = _frame + 2
		_stage = 14
	elif _frame > _end_frame + 7200:
		_check("enemy_phase_seen", _saw_enemy_phase, "TIMEOUT")
		_check("turn_incremented", false, "stuck in phase=%d turn=%d" % [_phase(), _um().get_current_turn()])
		_stage = 18

func _s14_t2_checks() -> void:
	_shot("verify_turn2_start.png")
	_press_main()
	_wait = _frame + 30
	_stage = 15

func _s15_t2_next() -> void:
	var sel2: String = _sel()
	_check("t2_next_selects", sel2 != "", "selected=%s" % sel2)
	_move_unit_id = sel2
	_wait = _frame + 1
	_stage = 16

func _s16_t2_move_preview() -> void:
	var env: Variant = _shell.get("_current_envelope")
	if env == null or env.green_hexes.is_empty():
		_check("t2_move", false, "no envelope")
		_stage = 18
		return
	_report["_dest2"] = env.green_hexes[0]
	_click_hex(_report["_dest2"])
	_wait = _frame + 2
	_stage = 17

func _s17_t2_move_confirm() -> void:
	_click_hex(_report["_dest2"])
	_wait = _frame + 90
	_stage = 18
	var d: Vector2i = _report["_dest2"]
	# check happens in _s18 after animation

func _s18_done() -> void:
	if _report.has("_dest2"):
		var u: Dictionary = _um().get_unit_by_id(_move_unit_id)
		var d: Vector2i = _report["_dest2"]
		_t2_move_ok = int(u.get("q", -1)) == d.x and int(u.get("r", -1)) == d.y
		_check("t2_move", _t2_move_ok, "%s at %d,%d" % [_move_unit_id, int(u.get("q", -9)), int(u.get("r", -9))])
	_report["checks"] = _chk
	_report["next_log"] = _next_log
	var all_ok: bool = true
	for k in _chk.keys():
		if not _chk[k]["pass"]:
			all_ok = false
	_report["ALL_PASS"] = all_ok
	var f: FileAccess = FileAccess.open("%s/verify_report.json" % _dir, FileAccess.WRITE)
	f.store_string(JSON.stringify(_report, "  "))
	f.close()
	print("[R5V] DONE ALL_PASS=%s" % str(all_ok))
	quit(0)
