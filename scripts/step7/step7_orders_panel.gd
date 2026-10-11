class_name Step7OrdersPanel
extends PanelContainer

## PLAYER-FACING operation orders panel (game-like conversion of the
## deterministic DEV action browser).
##
## Same engine path as the DEV panel — ActionCommand presets ->
## ActionService.preview_action -> shared overlay -> [실행]/[취소] ->
## execute_plan -> canonical movement. No separate rules, no inference.
## Only the presentation differs: Korean branch/order labels, qualitative
## status, no utility/version/code internals (those stay DEV-only).
##
## Player contract: clicking an order only previews. Nothing executes
## without [실행]. CUSTOM free-form builder stays DEV-only.

const CommandScript = preload("res://scripts/step7/step7_action_command.gd")

## Tokens that must never appear in PLAYER-mode strings (probe-audited).
const PLAYER_BANNED_TOKENS: Array = [
	"DEV", "EVALUATE", "EXECUTE", "u=", "state_version", "candidate_count",
	"MAD", "CACHE", "utility", "contribution", "provenance", "fingerprint",
	"ADVANCE_", "RETREAT_", "WITHDRAW_", "REPOSITION_", "RECON_", "FLANK_",
	"HOLD_", "PROTECT_", "REGROUP_", "MOVE_SELECTED", " selected_unit",
	"*SELECTED*",
]

const GROUP_KR := {
	"GENERAL": "전체 명령",
	"CAVALRY": "기병 명령",
	"SCOUT": "정찰 명령",
	"INFANTRY": "보병 명령",
	"SPEARMAN": "창병 명령",
	"ARCHER": "궁병 명령",
	"SIEGE": "공성 명령",
	"EXACT UNIT": "선택 부대",
}

const CLASS_KR := {
	"cavalry": "기병", "scout": "정찰", "infantry": "보병", "spearman": "창병",
	"archer": "궁병", "siege": "공성", "conscript": "징집", "hq": "사령부",
	"supply": "보급",
}

const PRESET_KR := {
	"ADVANCE_ALL_FORWARD": "전군 전진", "ADVANCE_ALL_BACK": "전군 후진",
	"ADVANCE_ALL_NORTH": "전군 북진", "ADVANCE_ALL_SOUTH": "전군 남진",
	"ADVANCE_ALL_LEFT": "전군 좌측 이동", "ADVANCE_ALL_RIGHT": "전군 우측 이동",
	"HOLD_ALL": "전군 대기", "RETREAT_ALL": "전군 후퇴",
	"REGROUP_ALL_TO_HQ": "전군 사령부 재집결", "WITHDRAW_ALL_TO_HQ": "전군 사령부 철수",
	"ADVANCE_CAVALRY_FORWARD": "기병 전진", "ADVANCE_CAVALRY_LEFT": "기병 좌측 전진",
	"ADVANCE_CAVALRY_RIGHT": "기병 우측 전진", "FLANK_CAVALRY_LEFT": "기병 좌측 우회",
	"FLANK_CAVALRY_RIGHT": "기병 우측 우회", "REPOSITION_CAVALRY_TO_CENTER": "기병 중앙 재배치",
	"RETREAT_CAVALRY": "기병 후퇴", "WITHDRAW_CAVALRY_TO_HQ": "기병 사령부 철수",
	"RECON_SCOUT_FORWARD": "정찰대 전방 정찰", "RECON_SCOUT_NORTH": "정찰대 북방 정찰",
	"RECON_SCOUT_SOUTH": "정찰대 남방 정찰", "RECON_SCOUT_LEFT": "정찰대 좌측 정찰",
	"RECON_SCOUT_RIGHT": "정찰대 우측 정찰", "REPOSITION_SCOUT_TO_CENTER": "정찰대 중앙 재배치",
	"RETREAT_SCOUT": "정찰대 후퇴",
	"ADVANCE_INFANTRY_FORWARD": "보병 전진", "HOLD_INFANTRY": "보병 대기",
	"PROTECT_HQ_INFANTRY": "보병 사령부 엄호", "REPOSITION_INFANTRY_TO_STRONGHOLD": "보병 요새 집결",
	"RETREAT_INFANTRY": "보병 후퇴", "WITHDRAW_INFANTRY_TO_HQ": "보병 사령부 철수",
	"ADVANCE_SPEARMAN_FORWARD": "창병 전진", "HOLD_SPEARMAN": "창병 대기",
	"PROTECT_HQ_SPEARMAN": "창병 사령부 엄호", "REPOSITION_SPEARMAN_TO_CENTER": "창병 중앙 재배치",
	"RETREAT_SPEARMAN": "창병 후퇴",
	"REPOSITION_ARCHER_FORWARD": "궁병 전방 재배치", "REPOSITION_ARCHER_BACK": "궁병 후방 재배치",
	"HOLD_ARCHER": "궁병 대기", "PROTECT_HQ_ARCHER": "궁병 사령부 엄호",
	"RETREAT_ARCHER": "궁병 후퇴",
	"ADVANCE_SIEGE_FORWARD": "공성대 전진", "REPOSITION_SIEGE_TO_STRONGHOLD": "공성대 요새 집결",
	"HOLD_SIEGE": "공성대 대기", "RETREAT_SIEGE": "공성대 후퇴",
	"MOVE_SELECTED_UNIT_TO_HEX": "선택 부대 지정 이동",
	"MOVE_SELECTED_UNIT_TO_HQ": "선택 부대 사령부 철수",
	"MOVE_SELECTED_UNIT_TO_CENTER": "선택 부대 중앙 재배치",
	"HOLD_SELECTED_UNIT": "선택 부대 대기",
	"RETREAT_SELECTED_UNIT": "선택 부대 후퇴",
}

const PRESET_TIP := {
	"ADVANCE_ALL_FORWARD": "행동 가능한 전 부대가 동쪽으로 전진합니다",
	"ADVANCE_ALL_BACK": "행동 가능한 전 부대가 서쪽으로 물러납니다",
	"ADVANCE_ALL_NORTH": "행동 가능한 전 부대가 북쪽으로 향합니다",
	"ADVANCE_ALL_SOUTH": "행동 가능한 전 부대가 남쪽으로 향합니다",
	"ADVANCE_ALL_LEFT": "행동 가능한 전 부대가 좌측으로 이동합니다",
	"ADVANCE_ALL_RIGHT": "행동 가능한 전 부대가 우측으로 이동합니다",
	"HOLD_ALL": "전 부대가 현재 위치를 지킵니다",
	"RETREAT_ALL": "전 부대가 서쪽으로 후퇴합니다",
	"REGROUP_ALL_TO_HQ": "전 부대가 사령부에 모여 전열을 정비합니다",
	"WITHDRAW_ALL_TO_HQ": "전 부대가 사령부로 철수합니다",
	"REPOSITION_CAVALRY_TO_CENTER": "기병이 전장 중앙으로 재배치됩니다",
	"REPOSITION_SCOUT_TO_CENTER": "정찰대가 전장 중앙으로 재배치됩니다",
	"REPOSITION_INFANTRY_TO_STRONGHOLD": "보병이 아군 요새로 집결합니다",
	"REPOSITION_SPEARMAN_TO_CENTER": "창병이 전장 중앙으로 재배치됩니다",
	"REPOSITION_ARCHER_FORWARD": "궁병이 전방으로 재배치됩니다",
	"REPOSITION_ARCHER_BACK": "궁병이 사령부 측으로 재배치됩니다",
	"REPOSITION_SIEGE_TO_STRONGHOLD": "공성대가 아군 요새로 집결합니다",
	"PROTECT_HQ_INFANTRY": "보병이 사령부를 엄호합니다",
	"PROTECT_HQ_SPEARMAN": "창병이 사령부를 엄호합니다",
	"PROTECT_HQ_ARCHER": "궁병이 사령부를 엄호합니다",
	"MOVE_SELECTED_UNIT_TO_HEX": "선택한 부대가 아래 좌표(또는 지도 지정 지점)로 이동합니다",
	"MOVE_SELECTED_UNIT_TO_HQ": "선택한 부대가 사령부로 철수합니다",
	"MOVE_SELECTED_UNIT_TO_CENTER": "선택한 부대가 전장 중앙으로 재배치됩니다",
	"HOLD_SELECTED_UNIT": "선택한 부대가 현재 위치를 지킵니다",
	"RETREAT_SELECTED_UNIT": "선택한 부대가 서쪽으로 후퇴합니다",
}

const ERROR_KR := {
	"UNIT_NOT_READY": "이미 행동을 마친 부대",
	"NO_VALID_UNITS": "해당 부대가 없음",
	"TARGET_UNREACHABLE": "목표에 도달할 수 없음",
	"NO_LEGAL_DESTINATION": "이동 가능한 칸이 없음",
	"OCCUPIED": "목적지가 점유됨",
	"INSUFFICIENT_MOVEMENT": "이동력 부족",
	"STALE_STATE": "전황이 바뀌어 다시 지정 필요",
	"UNIT_NOT_FOUND": "부대를 찾을 수 없음",
	"INVALID_TARGET": "잘못된 목표",
	"INVALID_DIRECTION": "잘못된 방향",
	"ACTION_NOT_SUPPORTED_FOR_CLASS": "이 병종은 해당 명령 불가",
	"EXECUTION_IN_PROGRESS": "부대 이동 중",
	"UNKNOWN_ACTION": "알 수 없는 명령",
}

var _action_service: RefCounted = null
var _unit_manager: RefCounted = null
var _overlay: Node2D = null
var _shell: Node = null

var _body: VBoxContainer = null
var _collapse_btn: Button = null
var _collapsed := false
var _sel_label: Label = null
var _state_label: Label = null
var _result_label: Label = null
var _exec_btn: Button = null
var _cancel_btn: Button = null
var _q_edit: LineEdit = null
var _r_edit: LineEdit = null
var _preset_btns: Dictionary = {} # pid -> Button
var _selected_pid := ""
var _preview_plan_id := ""
var _built := false
## Embedded mode: fill the parent right-dock section instead of
## self-anchoring as a standalone dock (geometry owned by the dock).
var embedded := false


func setup(deps: Dictionary) -> void:
	_action_service = deps.get("action_service") as RefCounted
	_unit_manager = deps.get("unit_manager") as RefCounted
	_overlay = deps.get("overlay") as Node2D
	_shell = deps.get("shell") as Node
	if _action_service != null and _action_service.has_signal("execution_finished"):
		_action_service.connect("execution_finished", Callable(self, "_on_execution_finished"))
	_maybe_build()


func is_ready() -> bool:
	return _action_service != null and _unit_manager != null


func _ready() -> void:
	_maybe_build()


func _maybe_build() -> void:
	if _built or not is_ready() or not is_inside_tree():
		return
	_built = true
	_build()


func _lacquer() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.065, 0.075, 0.095, 0.95)
	sb.border_color = Color(0.72, 0.60, 0.30, 0.9)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	sb.shadow_color = Color(0, 0, 0, 0.7)
	sb.shadow_size = 6
	return sb


func _build() -> void:
	if embedded:
		size_flags_vertical = Control.SIZE_EXPAND_FILL
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
	else:
		# Standalone right dock: the game-like successor of the DEV browser.
		set_anchors_preset(Control.PRESET_TOP_RIGHT)
		anchor_bottom = 1.0
		offset_left = -336
		offset_right = -8
		offset_top = 64
		offset_bottom = -8
		grow_horizontal = Control.GROW_DIRECTION_BEGIN
	custom_minimum_size = Vector2(288, 200)
	add_theme_stylebox_override("panel", _lacquer())
	name = "OrdersPanel"

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 4)
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(root)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 4)
	root.add_child(header)
	var title := Label.new()
	title.text = "작전 명령"
	title.add_theme_font_size_override("font_size", 14)
	title.add_theme_color_override("font_color", Color(0.92, 0.82, 0.45, 1.0))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_collapse_btn = Button.new()
	_collapse_btn.text = "[–]"
	_collapse_btn.focus_mode = Control.FOCUS_NONE
	_collapse_btn.tooltip_text = "명령창 접기/펼치기"
	_collapse_btn.pressed.connect(_on_collapse)
	header.add_child(_collapse_btn)

	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 4)
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_body)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_child(scroll)
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 2)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)

	var rows_by_group := {}
	for row in _action_service.get_manual_presets():
		var g := str(row.get("group", "GENERAL"))
		if not rows_by_group.has(g):
			rows_by_group[g] = []
		(rows_by_group[g] as Array).append(row)
	for g in CommandScript.preset_groups():
		if not rows_by_group.has(g):
			continue
		_add_group(list, str(g), rows_by_group[g])
	_build_hex_row(list)

	_body.add_child(HSeparator.new())
	_sel_label = _mk_footer_label(12)
	_body.add_child(_sel_label)
	_state_label = _mk_footer_label(12)
	_body.add_child(_state_label)
	_result_label = _mk_footer_label(12)
	_body.add_child(_result_label)
	var exec_row := HBoxContainer.new()
	exec_row.add_theme_constant_override("separation", 6)
	_body.add_child(exec_row)
	_exec_btn = Button.new()
	_exec_btn.text = "실행"
	_exec_btn.focus_mode = Control.FOCUS_NONE
	_exec_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_exec_btn.disabled = true
	_exec_btn.pressed.connect(_on_execute_btn)
	exec_row.add_child(_exec_btn)
	_cancel_btn = Button.new()
	_cancel_btn.text = "취소"
	_cancel_btn.focus_mode = Control.FOCUS_NONE
	_cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cancel_btn.disabled = true
	_cancel_btn.pressed.connect(_on_cancel_btn)
	exec_row.add_child(_cancel_btn)
	_reset_footer()


func _mk_footer_label(fs: int) -> Label:
	var lab := Label.new()
	lab.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lab.add_theme_font_size_override("font_size", fs)
	lab.add_theme_color_override("font_color", Color(0.92, 0.90, 0.84, 1.0))
	return lab


func _on_collapse() -> void:
	_collapsed = not _collapsed
	_body.visible = not _collapsed
	_collapse_btn.text = "[+]" if _collapsed else "[–]"


func show_panel() -> void:
	visible = true


func hide_panel() -> void:
	cancel_current()
	visible = false


func is_open() -> bool:
	return visible


## Test/DEV helper: press a preset by id (same path as the button).
func arm_preset(pid: String) -> void:
	_on_preset_id(pid)


func has_plan() -> bool:
	return not _preview_plan_id.is_empty()


func selected_preset() -> String:
	return _selected_pid


func _add_group(list: VBoxContainer, group: String, rows: Array) -> void:
	var head := Label.new()
	head.text = "%s (%d)" % [str(GROUP_KR.get(group, group)), rows.size()]
	head.add_theme_font_size_override("font_size", 12)
	head.add_theme_color_override("font_color", Color(0.78, 0.65, 0.32, 1.0))
	list.add_child(head)
	# Stable canonical order, not alphabetical id order.
	var order: Array = CommandScript.PRESET_ORDER
	var sorted_rows: Array = rows.duplicate()
	sorted_rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return order.find(str(a.get("id", ""))) < order.find(str(b.get("id", ""))))
	for row in sorted_rows:
		if not row is Dictionary:
			continue
		var pid := str((row as Dictionary).get("id", "?"))
		var b := Button.new()
		b.text = str(PRESET_KR.get(pid, pid))
		b.tooltip_text = str(PRESET_TIP.get(pid, "명령 미리보기 — 실행은 아래 [실행]"))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", 12)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(_on_preset_id.bind(pid))
		list.add_child(b)
		_preset_btns[pid] = b


func _build_hex_row(list: VBoxContainer) -> void:
	var head := Label.new()
	head.text = "지정 이동 좌표"
	head.add_theme_font_size_override("font_size", 12)
	head.add_theme_color_override("font_color", Color(0.78, 0.65, 0.32, 1.0))
	list.add_child(head)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	list.add_child(row)
	_q_edit = LineEdit.new()
	_q_edit.placeholder_text = "Q"
	_q_edit.custom_minimum_size = Vector2(56, 0)
	row.add_child(_q_edit)
	_r_edit = LineEdit.new()
	_r_edit.placeholder_text = "R"
	_r_edit.custom_minimum_size = Vector2(56, 0)
	row.add_child(_r_edit)
	var map_btn := Button.new()
	map_btn.text = "지도 지정"
	map_btn.focus_mode = Control.FOCUS_NONE
	map_btn.tooltip_text = "지도에 표시된 목표 지점을 좌표에 복사"
	map_btn.pressed.connect(_on_use_map_target)
	row.add_child(map_btn)


func _on_use_map_target() -> void:
	if _shell != null and _shell.get("_preview_target_hex") is Vector2i:
		var hex: Vector2i = _shell.get("_preview_target_hex")
		if hex.x != -999:
			_q_edit.text = str(hex.x)
			_r_edit.text = str(hex.y)


func _preset_row(pid: String) -> Dictionary:
	for row in _action_service.get_manual_presets():
		if str((row as Dictionary).get("id", "")) == pid:
			return row
	return {}


func _selected_unit_id() -> String:
	if _unit_manager != null and _unit_manager.has_method("is_unit_selected") \
		and bool(_unit_manager.is_unit_selected()):
		return str((_unit_manager.get_selected_unit() as Dictionary).get("id", ""))
	return ""


func _on_preset_id(pid: String) -> void:
	if not is_ready():
		return
	if _action_service.is_executing():
		_state_label.text = "상태: 부대 이동 중 — 잠시 후 다시 시도하십시오."
		return
	var row := _preset_row(pid)
	if row.is_empty():
		return
	var cmd := {}
	if CommandScript.is_template_preset(row):
		var uid := _selected_unit_id()
		if uid.is_empty():
			_begin("선택 부대 명령")
			_state_label.text = "상태: 지도의 아군 부대를 먼저 선택하십시오."
			_result_label.text = "결과: 없음"
			_selected_pid = pid
			_refresh_highlight()
			return
		if str(row.get("binding", "")) == "selected_unit_hex":
			if _q_edit == null or _r_edit == null \
				or not _q_edit.text.is_valid_int() or not _r_edit.text.is_valid_int():
				_begin(str(PRESET_KR.get(pid, pid)))
				_state_label.text = "상태: Q와 R 좌표를 숫자로 입력하거나 [지도 지정]을 누르십시오."
				_result_label.text = "결과: 없음"
				_selected_pid = pid
				_refresh_highlight()
				return
			cmd = CommandScript.bind_preset(row, uid, int(_q_edit.text), int(_r_edit.text))
		else:
			cmd = CommandScript.bind_preset(row, uid)
	else:
		cmd = (row.get("command", {}) as Dictionary).duplicate(true)
	_begin(str(PRESET_KR.get(pid, pid)))
	var result: Dictionary = _action_service.preview_action(cmd, "blue")
	_show_preview(result)
	_selected_pid = pid
	_refresh_highlight()


func _refresh_highlight() -> void:
	for pid in _preset_btns:
		(_preset_btns[pid] as Button).modulate = \
			Color(1.0, 0.88, 0.55) if pid == _selected_pid else Color.WHITE


## One press = one transaction: stale plan/routes first, always.
func _begin(label: String) -> void:
	_preview_plan_id = ""
	if _overlay != null and _overlay.has_method("set_routes"):
		_overlay.set_routes([])
	_sel_label.text = "선택: %s" % label
	_state_label.text = "상태: 확인 중…"
	_result_label.text = "결과: 없음"
	_exec_btn.disabled = true
	_cancel_btn.disabled = true


func cancel_current() -> void:
	if _action_service != null and _action_service.has_method("is_executing") \
		and bool(_action_service.is_executing()):
		return
	# Our own armed plan only; the shared overlay is left alone so an
	# Advisor preview is never wiped by hiding this panel.
	if not _preview_plan_id.is_empty() and _action_service != null:
		_action_service.cancel_plan(_preview_plan_id)
		_preview_plan_id = ""
	_selected_pid = ""
	_refresh_highlight()
	if _exec_btn != null:
		_reset_footer()


func _reset_footer() -> void:
	_sel_label.text = "선택: 없음"
	_state_label.text = "상태: 명령을 고르면 지도에 미리 표시됩니다."
	_result_label.text = "결과: 없음"
	_exec_btn.disabled = true
	_cancel_btn.disabled = true


func _on_cancel_btn() -> void:
	if _action_service.is_executing():
		_state_label.text = "상태: 이동 중에는 취소할 수 없습니다."
		return
	cancel_current()
	_state_label.text = "상태: 취소했습니다."


func _on_execute_btn() -> void:
	if _action_service.is_executing():
		_state_label.text = "상태: 부대 이동 중 — 끝날 때까지 기다리십시오."
		return
	if _preview_plan_id.is_empty():
		_state_label.text = "상태: 실행할 명령이 없습니다."
		return
	var result: Dictionary = _action_service.execute_plan(_preview_plan_id)
	_preview_plan_id = ""
	if _overlay != null and _overlay.has_method("set_routes"):
		_overlay.set_routes([])
	if str(result.get("execution_status", "")) == "IN_PROGRESS":
		_state_label.text = "상태: 부대 이동 중…"
		_set_busy(true)
		return
	_after_execution(result)


func _on_execution_finished(result: Dictionary) -> void:
	_set_busy(false)
	_after_execution(result)


func _set_busy(b: bool) -> void:
	_exec_btn.disabled = b
	_cancel_btn.disabled = b
	for pid in _preset_btns:
		(_preset_btns[pid] as Button).disabled = b


func _after_execution(result: Dictionary) -> void:
	var ok_count := (result.get("executed_units", []) as Array).size()
	var fail_count := (result.get("failed_units", []) as Array).size()
	if str(result.get("execution_status", "")) == "EXECUTED" and fail_count == 0:
		_result_label.text = "결과: 완료 (%d개 부대)" % ok_count
	elif fail_count > 0:
		_result_label.text = "결과: 일부 실패 (성공 %d / 실패 %d)" % [ok_count, fail_count]
	else:
		_result_label.text = "결과: %s" % str(result.get("execution_status", "?"))
	_state_label.text = "상태: 없음"
	_selected_pid = ""
	_refresh_highlight()
	_exec_btn.disabled = true
	_cancel_btn.disabled = true


func _show_preview(result: Dictionary) -> void:
	_preview_plan_id = str(result.get("plan_id", ""))
	if _overlay != null and _overlay.has_method("set_routes"):
		_overlay.set_routes((result.get("routes", []) as Array).duplicate(true))
	if bool(result.get("ok", false)):
		var resolved: Array = result.get("resolved_units", [])
		var rejected: Array = result.get("rejected_units", [])
		_state_label.text = "상태: 실행 가능 — 지도에 표시 중"
		_result_label.text = "결과: %s / 제외 %d" % [_summarize(resolved), rejected.size()]
		_exec_btn.disabled = false
		_cancel_btn.disabled = false
	else:
		_state_label.text = "상태: 실행 불가 — %s" % _first_error_kr(result)
		_result_label.text = "결과: 없음"
		_preview_plan_id = ""


func _summarize(resolved: Array) -> String:
	var counts := {}
	for a in resolved:
		if a is Dictionary:
			var c := str((a as Dictionary).get("class", "?")).to_lower()
			counts[c] = int(counts.get(c, 0)) + 1
	var parts: Array = []
	for c in counts.keys():
		parts.append("%s %d" % [str(CLASS_KR.get(str(c), str(c))), int(counts[c])])
	if parts.is_empty():
		return "해당 부대 없음"
	return "%s — 총 %d개 부대" % [" · ".join(parts), resolved.size()]


func _first_error_kr(result: Dictionary) -> String:
	for e in result.get("validation_errors", []):
		if e is Dictionary:
			var code := str((e as Dictionary).get("code", ""))
			if str(ERROR_KR.get(code, "")).length() > 0:
				return str(ERROR_KR[code])
			return "조건 불충족"
	for r in result.get("rejected_units", []):
		if r is Dictionary:
			var code2 := str((r as Dictionary).get("code", ""))
			if str(ERROR_KR.get(code2, "")).length() > 0:
				return str(ERROR_KR[code2])
	return "조건 불충족"


## Audit helper: every player-visible string in the panel.
func player_texts() -> Array:
	var out: Array = ["작전 명령"]
	for s in [_sel_label, _state_label, _result_label]:
		if s != null:
			out.append(str((s as Label).text))
	for pid in _preset_btns:
		var b: Button = _preset_btns[pid]
		out.append(str(b.text))
		out.append(str(b.tooltip_text))
	if _q_edit != null:
		out.append(str(_q_edit.placeholder_text))
	if _r_edit != null:
		out.append(str(_r_edit.placeholder_text))
	return out


static func audit_player_text(text: String) -> String:
	for tok in PLAYER_BANNED_TOKENS:
		if text.find(str(tok)) >= 0:
			return "banned token '%s' in: %s" % [str(tok), text.left(80)]
	return ""
