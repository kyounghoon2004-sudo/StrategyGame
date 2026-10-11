extends Node2D
## BattleMap — 전투 플레이 루프 통합
## HexGrid + UnitRenderer + BattleHUD + InterviewPanel + MissionResultPanel + SLMClient + TurnManager + AI

# ---- 프리로드 ----
var HexCellCls: Script = preload("res://scripts/core/hex_cell.gd")
var HexUtilsCls: Script = preload("res://scripts/core/hex_utils.gd")
var UnitCls: Script = preload("res://scripts/combat/unit.gd")
var UnitTypeCls: Script = preload("res://scripts/combat/unit_type.gd")
var RuleBasedFallbackCls: Script = preload("res://scripts/ai/rule_based_fallback.gd")
var TerrainModsCls: Script = preload("res://scripts/combat/terrain_mods.gd")
var CombatCalculatorCls: Script = preload("res://scripts/combat/combat_calculator.gd")
var MoraleSystemCls: Script = preload("res://scripts/combat/morale_system.gd")
var movement_calculator_gd: Script = preload("res://scripts/combat/movement_calculator.gd")

# ---- Tactical Sidebar (Sprint 5) ----
var TacticalSidebarCls: Script = preload("res://scripts/ui/tactical_sidebar.gd")
var tactical_sidebar: Node
var target_beacon: Sprite2D
var target_banner: Label

var _sidebar_active := false
var _target_beacon_hex: Vector2i = Vector2i(-999, -999)
var _target_beacon_visible := true
var _pending_tactical_action: StringName = &""
var _prepared_ambushes: Dictionary = {}

# ---- 상태 ----
var hex_grid: Node
var unit_renderer: Node
var battle_hud: Node
var interview_panel: Node
var mission_panel: Node
var slm_client: Node
var camera: Camera2D
var debug_label: Label
var turn_label: Label
var end_turn_btn: Button
var canvas_layer: CanvasLayer
var status_capsule: Panel
var status_label: Label
var player_units: Array = []
var enemy_units: Array = []
var all_units: Array = []
var selected_unit = null
var selected_hex: Vector2i = Vector2i(-999, -999)
var reachable_hexes: Array[Vector2i] = []
var attackable_enemy_hexes: Array[Vector2i] = []
var is_animating: bool = false
var has_acted: Dictionary = {} # ins_id -> bool
var current_phase: int = 0
var _last_staff_result: Dictionary = {}
var _initial_ally_total: int = 0
var _initial_enemy_total: int = 0
var _ally_cas_total: int = 0
var _enemy_cas_total: int = 0

const GRID_Q: int = 36
const GRID_R: int = 24

func _ready() -> void:
	_setup_nodes()
	_setup_audio()
	_setup_camera()
	_create_grid()
	_create_units()
	_setup_hud()
	_setup_interview()
	_setup_mission_panel()
	_setup_slm()
	_setup_end_turn_button()
	_setup_banner()
	_setup_status_capsule()
	_connect_grid_signals()
	_connect_turn_manager()
	_connect_audio_signals()
	_setup_tactical_sidebar()
	_setup_target_beacon()
	_setup_fog_of_war()
	_update_hud_all()
	_enter_recon_phase()

# ─────────────────────────────────────────────────────────────────────
# AudioManager 연결 — 풀 트리거 + 쥬스(셰이크/플로팅/배너) 자동 발행
# ─────────────────────────────────────────────────────────────────────
func _setup_audio() -> void:
	# AudioManager 는 Autoload — 별도 노드 생성 불필요. 시그널 연결은
	# 노드가 트리에 합류된 직후 _connect_audio_signals() 에서.
	pass

func _connect_audio_signals() -> void:
	var am: Node = get_node_or_null("/root/AudioManager")
	if am == null:
		return
	if am.has_signal("camera_shake_requested") and not am.is_connected("camera_shake_requested", _on_am_shake):
		am.connect("camera_shake_requested", _on_am_shake)
	if am.has_signal("banner_slide_requested") and not am.is_connected("banner_slide_requested", _on_am_banner):
		am.connect("banner_slide_requested", _on_am_banner)
	if am.has_signal("damage_float_requested") and not am.is_connected("damage_float_requested", _on_am_damage_float):
		am.connect("damage_float_requested", _on_am_damage_float)


func _on_am_shake(intensity: float, duration: float) -> void:
	_apply_camera_shake(intensity, duration)


func _on_am_banner(title: String, subtitle: String, color: Color) -> void:
	_show_slide_banner(title, subtitle, color)


func _on_am_damage_float(world_pos: Vector2, text: String, color: Color, size_mult: float) -> void:
	_spawn_floating_text_at(world_pos, text, color, size_mult)


# 강한 카메라 셰이크 — 통합 함수 (기존 짧은 트윈과 분리)
func _apply_camera_shake(intensity: float = 0.6, duration: float = 0.25) -> void:
	if camera == null:
		return
	var orig: Vector2 = camera.position
	var steps: int = 6
	var step_dur: float = duration / float(steps)
	var tw: Tween = create_tween()
	var directions: Array[Vector2] = [
		Vector2(1, 0), Vector2(-1, 1), Vector2(0, -1),
		Vector2(1, -1), Vector2(-1, 0), Vector2(0, 0),
	]
	for i in range(steps):
		var d: Vector2 = directions[i % directions.size()] * intensity * 3.0
		tw.tween_property(camera, "position", orig + d, step_dur)
	tw.tween_property(camera, "position", orig, step_dur)


func _spawn_floating_text_at(world_pos: Vector2, text: String, color: Color, size_mult: float = 1.0) -> void:
	var lbl: Label = Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", int(roundi(16.0 * size_mult)))
	lbl.add_theme_color_override("font_color", color)
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.95))
	lbl.add_theme_constant_override("outline_size", int(roundi(2.0 * size_mult)))
	lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	lbl.add_theme_constant_override("shadow_offset_x", 1)
	lbl.add_theme_constant_override("shadow_offset_y", 1)
	lbl.horizontal_alignment = 1
	lbl.position = world_pos + Vector2(-36, -32)
	lbl.z_index = 100
	add_child(lbl)
	var tw: Tween = create_tween().set_parallel(true)
	tw.tween_property(lbl, "position:y", lbl.position.y - 36.0 * size_mult, 1.0).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_property(lbl, "modulate:a", 0.0, 1.0).set_delay(0.4)
	tw.chain().tween_callback(func(): if is_instance_valid(lbl): lbl.queue_free())


# 상단 슬라이드 배너 — 화면 상단에서 -120 → 80 → -120 으로 슬라이드
var _banner_layer: CanvasLayer = null
var _banner_rect: ColorRect = null
var _banner_title: Label = null
var _banner_sub: Label = null

func _setup_banner() -> void:
	# CanvasLayer 가 이미 있다면 재활용, 없으면 새로 생성
	if canvas_layer == null:
		canvas_layer = CanvasLayer.new()
		canvas_layer.layer = 20
		add_child(canvas_layer)
	_banner_layer = canvas_layer
	_banner_rect = ColorRect.new()
	_banner_rect.name = "SlideBanner"
	_banner_rect.color = Color(0.85, 0.65, 0.18, 0.95)
	_banner_rect.size = Vector2(560, 64)
	_banner_rect.position = Vector2((1280 - 560) * 0.5, -120)  # 화면 위쪽 밖에 시작
	_banner_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner_rect.z_index = 200
	_banner_layer.add_child(_banner_rect)
	_banner_title = Label.new()
	_banner_title.text = ""
	_banner_title.add_theme_font_size_override("font_size", 24)
	_banner_title.add_theme_color_override("font_color", Color(0.1, 0.05, 0.0))
	_banner_title.position = Vector2(20, 8)
	_banner_title.size = Vector2(520, 30)
	_banner_rect.add_child(_banner_title)
	_banner_sub = Label.new()
	_banner_sub.text = ""
	_banner_sub.add_theme_font_size_override("font_size", 14)
	_banner_sub.add_theme_color_override("font_color", Color(0.95, 0.9, 0.75))
	_banner_sub.position = Vector2(20, 40)
	_banner_sub.size = Vector2(520, 22)
	_banner_rect.add_child(_banner_sub)


func _setup_status_capsule() -> void:
	if canvas_layer == null:
		return
	status_capsule = Panel.new()
	status_capsule.name = "TopStatusCapsule"
	status_capsule.position = Vector2(338, 8)
	status_capsule.size = Vector2(930, 42)
	status_capsule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var capsule_style: StyleBoxFlat = StyleBoxFlat.new()
	capsule_style.bg_color = Color(0.101961, 0.101961, 0.133333, 0.96) # #1A1A22
	capsule_style.border_color = Color(0.831373, 0.686275, 0.215686, 1) # #D4AF37
	capsule_style.set_border_width_all(2)
	capsule_style.set_corner_radius_all(18)
	capsule_style.shadow_color = Color(0, 0, 0, 0.6)
	capsule_style.shadow_size = 5
	status_capsule.add_theme_stylebox_override("panel", capsule_style)
	canvas_layer.add_child(status_capsule)

	status_label = Label.new()
	status_label.name = "StatusText"
	status_label.position = Vector2(18, 7)
	status_label.size = Vector2(894, 28)
	status_label.text = "턴: 10  |  보급: 18/9일  |  아군: 1000명  |  적군: 130명  |  명성: 350"
	status_label.horizontal_alignment = 1
	status_label.vertical_alignment = 1
	status_label.add_theme_font_size_override("font_size", 14)
	status_label.add_theme_color_override("font_color", Color(0.95, 0.88, 0.63, 1))
	status_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	status_label.add_theme_constant_override("shadow_offset_x", 1)
	status_label.add_theme_constant_override("shadow_offset_y", 1)
	status_capsule.add_child(status_label)


func _show_slide_banner(title: String, subtitle: String, color: Color) -> void:
	if _banner_rect == null:
		return
	_banner_rect.color = color
	_banner_title.text = title
	_banner_sub.text = subtitle
	# 슬라이드: 위쪽 밖 → 화면 안 → 잠시 머무름 → 다시 빠짐
	var tw: Tween = create_tween()
	tw.tween_property(_banner_rect, "position:y", 80.0, 0.32).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_interval(1.5)
	tw.tween_property(_banner_rect, "position:y", -120.0, 0.42).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)

# ------------------------------------------------------------------
# Tactical Sidebar (Sprint 5)
# ------------------------------------------------------------------
func _setup_tactical_sidebar() -> void:
	if tactical_sidebar == null:
		# main.tscn에 이미 배치된 사이드바가 있으면 재사용
		tactical_sidebar = get_node_or_null("../TacticalSidebar")
	if tactical_sidebar == null:
		var sidebar_scene: PackedScene = load("res://scenes/ui/tactical_sidebar.tscn") as PackedScene
		if sidebar_scene != null:
			tactical_sidebar = sidebar_scene.instantiate()
			tactical_sidebar.name = "TacticalSidebar"
			add_child(tactical_sidebar)
	if tactical_sidebar == null:
		return

	if tactical_sidebar.has_signal("button_pressed") and not tactical_sidebar.is_connected("button_pressed", _on_tactical_button_pressed):
		tactical_sidebar.connect("button_pressed", _on_tactical_button_pressed)
	if tactical_sidebar.has_signal("command_entered") and not tactical_sidebar.is_connected("command_entered", _on_tactical_command_entered):
		tactical_sidebar.connect("command_entered", _on_tactical_command_entered)
	if tactical_sidebar.has_method("set_dialogue"):
		tactical_sidebar.call("set_dialogue", "주공, 전황을 아뢰옵니다.\n적의 보급로가 노출되어 있사오니,\n지금 결단의 시점이옵니다.")
	if tactical_sidebar.has_method("focus_input"):
		tactical_sidebar.call("focus_input")


func _on_tactical_button_pressed(button_id: StringName) -> void:
	_pending_tactical_action = button_id
	push_log("[BattleMap] Tactical button: %s" % button_id)
	# 맵 타겟 비콘 점멸
	if target_beacon:
		pulse_target_beacon()
	# 선택지 패널 표시
	if interview_panel:
		var options = _get_tactical_options(button_id)
		var dialogue = _get_tactical_dialogue(button_id)
		interview_panel.set_briefing(dialogue, options)
		if not interview_panel.visible:
			interview_panel.show_interview()


func _on_tactical_command_entered(command: String) -> void:
	push_log("[BattleMap] Command entered: %s" % command)
	if tactical_sidebar == null:
		return
	command = command.strip_edges()
	if command.is_empty():
		return
	# 키워드 분석 (간단한 예시)
	var lower_cmd := command.to_lower()
	if lower_cmd.begins_with("보조") or lower_cmd.begins_with("정보") or lower_cmd.begins_with("분석"):
		var ally_total := _sum_troops(player_units)
		var enemy_total := _sum_troops(enemy_units)
		var desc := "전황 분석:\n아군 %d명 / 적군 %d명\n턴 %d — 정찰 단계\n보급: 18일 남음\n목표: 북부 요새 함락"
		tactical_sidebar.set_dialogue(desc % [ally_total, enemy_total, TurnManager.get("current_turn")])
	elif lower_cmd.begins_with("후퇴") or lower_cmd.begins_with("전열"):
		tactical_sidebar.set_dialogue("전열을 재정비하시려면 배치 단계에서 유닛을 이동하십시오.\n공격 명령을 내려 적을 격퇴할 수 있습니다.")
	elif lower_cmd.begins_with("도움") or lower_cmd.begins_with("설명서"):
		tactical_sidebar.set_dialogue("명령어 목록:\n보조 - 전황 분석\n공격 - 적 유닛 공격\n후퇴 - 유닛 후퇴\n정찰 - 정찰대 파견\n턴종료 - 적 턴 진행\n도움말 - 이 도움말")
	else:
		tactical_sidebar.set_dialogue("알 수 없는 명령입니다.\n'도움'을 입력하여 명령어 목록을 확인하세요.")


func _get_tactical_options(button_id: StringName) -> Array:
	if button_id == "advance":
		return [
			{"id": "advance_confirm", "text": "전진 — 적 보급로 차단", "tooltip": "사기 +5, 보급 -2일"},
			{"id": "advance_cautious", "text": "신중한 전진 — 정찰 병행", "tooltip": "정찰병 선행, 사기 영향 없음"},
		]
	elif button_id == "defense":
		return [
			{"id": "defense_form", "text": "방어 진형 — 방패벽 전개", "tooltip": "방어력 +30%, 이동력 -1"},
			{"id": "defense_wait", "text": "대기 — 적 공격을 기다림", "tooltip": "사기 +3, 적 사기 -5"},
		]
	elif button_id == "scout":
		return [
			{"id": "scout_recon", "text": "정찰대 파견 — 적 위치 파악", "tooltip": "적 위치 정보 획득, 정찰병 1-hit 취약"},
			{"id": "scout_ambush", "text": "매복 — 숲/습지에서 기습", "tooltip": "적 선제타격, 사기 -10"},
		]
	return []


func _get_tactical_dialogue(button_id: StringName) -> String:
	if button_id == "advance":
		return "주공, 전군 전진을 아뢰옵니다.\n적 보급로를 차단하여 적의 사기를 꺾으오리다.\n좌측 중앙 헥스로 진격하시면 되옵니다."
	elif button_id == "defense":
		return "주공, 방어 진형을 아뢰옵니다.\n방패벽을 전개하여 적의 공격을 막아내오리다.\n사기 저하를 최소화하며 전열을 재정비하리이다."
	elif button_id == "scout":
		return "주공, 정찰대를 파견하리이다.\n적의 배치와 지형을 파악하여 최적의 공격로를 찾겠사옵니다.\n매복 위험도 있사오니 신중히 결정하소서."
	return "참모, 명령을 받들었사옵니다."


func _setup_fog_of_war() -> void:
	if hex_grid == null or not hex_grid.has_method("set_fog_hexes"):
		return
	# 전군의 시야 밖에 있는 8개 셀. 목표 비콘은 이 영역과 별도 z-order로 표시된다.
	var initial_fog: Array[Vector2i] = [
		Vector2i(6, 6), Vector2i(6, 7), Vector2i(6, 8),
		Vector2i(7, 6), Vector2i(7, 7),
		Vector2i(8, 6), Vector2i(8, 7), Vector2i(8, 8),
	]
	hex_grid.call("set_fog_hexes", initial_fog)


func _find_scout_unit():
	for unit in player_units:
		if unit != null and unit.unit_type != null and String(unit.unit_type.id) == "scouts":
			return unit
	return null


func _reveal_scout_area() -> void:
	var scout = _find_scout_unit()
	if scout == null or hex_grid == null or not hex_grid.has_method("reveal_area"):
		push_log("[BattleMap] 정찰병을 찾지 못했습니다.")
		return
	var scout_hex: Vector2i = Vector2i(int(scout.get("hex_q")), int(scout.get("hex_r")))
	hex_grid.call("reveal_area", scout_hex, 4)
	push_log("[BattleMap] 정찰 공개: %s 반경 4칸" % str(scout_hex))


func _prepare_scout_ambush() -> void:
	var scout = _find_scout_unit()
	if scout == null or hex_grid == null:
		push_log("[BattleMap] 매복 가능한 정찰병이 없습니다.")
		return
	var scout_hex: Vector2i = Vector2i(int(scout.get("hex_q")), int(scout.get("hex_r")))
	var best_hex: Vector2i = Vector2i(-999, -999)
	var best_distance: int = 9999
	for value in hex_grid.cell_data.values():
		var cell: Variant = value
		if cell.occupying_unit != null and cell.occupying_unit != scout:
			continue
		if not TerrainModsCls.can_ambush(int(cell.terrain)):
			continue
		var candidate: Vector2i = Vector2i(int(cell.q), int(cell.r))
		var distance: int = HexUtilsCls.hex_distance(scout_hex, candidate)
		if distance <= 4 and distance < best_distance:
			best_distance = distance
			best_hex = candidate
	if best_hex.x == -999:
		push_log("[BattleMap] 반경 4칸 안에 숲/습지 매복 지점이 없습니다.")
		return
	var key: String = "%d,%d" % [best_hex.x, best_hex.y]
	_prepared_ambushes[key] = true
	if hex_grid.has_method("mark_ambush_hex"):
		hex_grid.call("mark_ambush_hex", best_hex.x, best_hex.y)
	push_log("[BattleMap] 매복 준비: %s — 첫 공격에 기습 보정" % str(best_hex))



func _setup_target_beacon() -> void:
	target_beacon = Sprite2D.new()
	target_beacon.name = "TargetBeacon"
	var beacon_path: String = "res://assets/ui/ui_target_beacon.png"
	if ResourceLoader.exists(beacon_path):
		target_beacon.texture = load(beacon_path) as Texture2D
	else:
		push_warning("[BattleMap] target beacon texture not found: %s" % beacon_path)
	target_beacon.centered = true
	target_beacon.z_index = 80
	target_beacon.scale = Vector2(2.0, 2.0)
	target_beacon.modulate = Color(1, 1, 0.6, 1)
	target_beacon.visible = true
	add_child(target_beacon)

	# 목표 배너
	target_banner = Label.new()
	target_banner.name = "TargetBanner"
	target_banner.text = "목표: 북부 요새 함락"
	target_banner.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	target_banner.add_theme_font_size_override("font_size", 14)
	target_banner.add_theme_color_override("font_color", Color(1, 0.95, 0.6, 1))
	target_banner.add_theme_color_override("font_shadow_color", Color(0.2, 0.15, 0.05, 1))
	target_banner.add_theme_constant_override("shadow_offset_x", 2)
	target_banner.add_theme_constant_override("shadow_offset_y", 2)
	target_banner.horizontal_alignment = 1
	target_banner.z_index = 80
	target_banner.visible = true
	add_child(target_banner)

	# 초기 위치 — 맵 중앙 상단
	if hex_grid:
		var center_hex: Vector2 = HexUtilsCls.hex_to_pixel(GRID_Q / 2, GRID_R / 2)
		if hex_grid and camera and camera.has_method("set_map_bounds"):
			var min_pos: Vector2 = HexUtilsCls.hex_to_pixel(0, 0)
			var max_pos: Vector2 = HexUtilsCls.hex_to_pixel(GRID_Q - 1, GRID_R - 1)
			camera.set_map_bounds(min_pos - Vector2(48, 42), max_pos + Vector2(72, 72))
			camera.focus_on((min_pos + max_pos) * 0.5)
		target_beacon.position = center_hex + Vector2(0, -240)
		target_banner.position = center_hex + Vector2(0, -260)
		target_banner.size = Vector2(250, 30)
		target_banner.horizontal_alignment = 1


func update_target_beacon(hex_pos: Vector2i) -> void:
	_target_beacon_hex = hex_pos
	if hex_grid and target_beacon:
		var world_pos: Vector2 = HexUtilsCls.hex_to_pixel(hex_pos.x, hex_pos.y)
		target_beacon.position = world_pos + Vector2(0, -48)
		target_banner.position = world_pos + Vector2(0, -60)


func pulse_target_beacon() -> void:
	if target_beacon == null:
		return
	var pulse_tween: Tween = create_tween()
	pulse_tween.tween_property(target_beacon, "modulate:a", 0.5, 0.18)
	pulse_tween.tween_property(target_beacon, "modulate:a", 1.0, 0.18)
	if target_banner:
		var banner_tween: Tween = create_tween()
		banner_tween.tween_property(target_banner, "modulate:a", 0.5, 0.18)
		banner_tween.tween_property(target_banner, "modulate:a", 1.0, 0.18)


func _setup_nodes() -> void:
	debug_label = get_node_or_null("DebugLabel") as Label
	turn_label = get_node_or_null("TurnLabel") as Label
	hex_grid = get_node_or_null("HexGrid")
	camera = get_node_or_null("Camera2D") as Camera2D
	canvas_layer = get_node_or_null("CanvasLayer") as CanvasLayer

	if canvas_layer == null:
		canvas_layer = CanvasLayer.new()
		canvas_layer.name = "CanvasLayer"
		canvas_layer.layer = 10
		add_child(canvas_layer)

	unit_renderer = get_node_or_null("UnitRenderer")
	if unit_renderer == null:
		var renderer_script: Script = load("res://scripts/core/unit_renderer.gd") as Script
		var renderer_node: Node2D = Node2D.new()
		renderer_node.name = "UnitRenderer"
		if renderer_script != null:
			renderer_node.set_script(renderer_script)
		add_child(renderer_node)
		unit_renderer = renderer_node

	if hex_grid == null:
		var grid_script: Script = load("res://scripts/core/hex_grid.gd") as Script
		var grid_node: Node2D = Node2D.new()
		grid_node.name = "HexGrid"
		if grid_script != null:
			grid_node.set_script(grid_script)
		add_child(grid_node)
		hex_grid = grid_node
	if camera == null:
		camera = Camera2D.new()
		camera.name = "Camera2D"
		camera.current = true
		add_child(camera)


func push_log(message: String) -> void:
	print(message)


func _setup_camera() -> void:
	if camera and camera.has_method("set_map_bounds"):
		# 36x24 전장을 고정 320px 사이드바 오른쪽에 맞춘 기본 뷰.
		camera.zoom = Vector2(0.62, 0.62)
		camera.set("target_zoom_level", 0.62)
		call_deferred("_update_camera_bounds")

func _update_camera_bounds() -> void:
	if hex_grid and camera and camera.has_method("set_map_bounds"):
		var min_pos: Vector2 = HexUtilsCls.hex_to_pixel(0, 0)
		var max_pos: Vector2 = HexUtilsCls.hex_to_pixel(GRID_Q - 1, GRID_R - 1)
		camera.set_map_bounds(min_pos - Vector2(48, 42), max_pos + Vector2(72, 72))
		if camera.has_method("focus_on"):
			camera.focus_on((min_pos + max_pos) * 0.5)

func _create_grid() -> void:
	if hex_grid.cell_data.is_empty() or int(hex_grid.get("grid_size_q")) != GRID_Q or int(hex_grid.get("grid_size_r")) != GRID_R:
		hex_grid.create_grid(GRID_Q, GRID_R, "varied")
	hex_grid.generate_hexes()

func get_tactical_grid_size() -> Vector2i:
	return Vector2i(GRID_Q, GRID_R)

func _create_units() -> void:
	# Clean previous
	for u in all_units:
		if hex_grid:
			var old_key: String = "%d,%d" % [int(u.get("hex_q")), int(u.get("hex_r"))]
			var cell: Variant = hex_grid.cell_data.get(old_key)
			if cell and cell.get("occupying_unit") == u:
				cell.occupying_unit = null
	player_units.clear()
	enemy_units.clear()
	all_units.clear()
	has_acted.clear()

	var types: Dictionary = {}
	var paths: Dictionary = {
		"infantry": "res://data/unit_types/infantry.tres",
		"archers": "res://data/unit_types/archers.tres",
		"cavalry": "res://data/unit_types/cavalry.tres",
		"spearmen": "res://data/unit_types/spearmen.tres",
		"siege": "res://data/unit_types/siege.tres",
		"conscripts": "res://data/unit_types/conscripts.tres",
		"scouts": "res://data/unit_types/scouts.tres",
	}
	for k in paths.keys():
		var p: String = paths[k]
		if ResourceLoader.exists(p):
			types[k] = load(p)

	# Player units (blue) — left flank
	var p_defs: Array = [
		{"type": "infantry", "cnt": 420, "q": 2, "r": 4},
		{"type": "archers", "cnt": 180, "q": 2, "r": 6},
		{"type": "cavalry", "cnt": 240, "q": 3, "r": 5},
		{"type": "spearmen", "cnt": 300, "q": 3, "r": 7},
		{"type": "scouts", "cnt": 80, "q": 2, "r": 8},
		{"type": "conscripts", "cnt": 550, "q": 4, "r": 6},
	]
	for d in p_defs:
		var ut = types.get(d["type"])
		if ut == null: continue
		var unit = UnitCls.new(ut, "player", int(d["cnt"]))
		unit.hex_q = int(d["q"])
		unit.hex_r = int(d["r"])
		var key: String = "%d,%d" % [unit.hex_q, unit.hex_r]
		var cell: Variant = hex_grid.get_cell(unit.hex_q, unit.hex_r)
		if cell:
			# If occupied, find nearby empty
			if cell.occupying_unit != null:
				var found: bool = false
				for off in HexUtilsCls.get_all_neighbors_offset(unit.hex_q, unit.hex_r):
					var c2: Variant = hex_grid.get_cell(off.x, off.y)
					if c2 and c2.occupying_unit == null and ut.can_enter(c2.terrain):
						unit.hex_q = off.x
						unit.hex_r = off.y
						cell = c2
						found = true
						break
				if not found:
					continue
			cell.occupying_unit = unit
		player_units.append(unit)
		all_units.append(unit)
		unit_renderer.spawn_unit(unit, unit.hex_q, unit.hex_r)

	# Enemy units (red) — right flank
	var e_defs: Array = [
		{"type": "infantry", "cnt": 380, "q": 14, "r": 4},
		{"type": "spearmen", "cnt": 320, "q": 15, "r": 5},
		{"type": "cavalry", "cnt": 200, "q": 14, "r": 6},
		{"type": "archers", "cnt": 160, "q": 15, "r": 7},
		{"type": "conscripts", "cnt": 480, "q": 13, "r": 5},
		{"type": "siege", "cnt": 90, "q": 15, "r": 3},
	]
	for d in e_defs:
		var ut = types.get(d["type"])
		if ut == null: continue
		var unit = UnitCls.new(ut, "enemy", int(d["cnt"]))
		unit.hex_q = int(d["q"])
		unit.hex_r = int(d["r"])
		var key: String = "%d,%d" % [unit.hex_q, unit.hex_r]
		var cell: Variant = hex_grid.get_cell(unit.hex_q, unit.hex_r)
		if cell:
			if cell.occupying_unit != null:
				var found: bool = false
				for off in HexUtilsCls.get_all_neighbors_offset(unit.hex_q, unit.hex_r):
					var c2: Variant = hex_grid.get_cell(off.x, off.y)
					if c2 and c2.occupying_unit == null and ut.can_enter(c2.terrain):
						unit.hex_q = off.x
						unit.hex_r = off.y
						cell = c2
						found = true
						break
				if not found:
					continue
			cell.occupying_unit = unit
		enemy_units.append(unit)
		all_units.append(unit)
		unit_renderer.spawn_unit(unit, unit.hex_q, unit.hex_r)

	_initial_ally_total = _sum_troops(player_units)
	_initial_enemy_total = _sum_troops(enemy_units)

func _sum_troops(arr: Array) -> int:
	var s: int = 0
	for u in arr:
		s += int(u.get("soldier_count"))
	return s

func _avg_morale(arr: Array) -> float:
	if arr.is_empty(): return 0.0
	var sum: float = 0.0
	for u in arr:
		sum += float(u.get("current_morale"))
	return sum / float(arr.size())

func _setup_hud() -> void:
	# Try find existing BattleHUD under CanvasLayer or root
	battle_hud = get_node_or_null("CanvasLayer/BattleHUD")
	if battle_hud == null:
		battle_hud = get_node_or_null("BattleHUD")
	if battle_hud == null:
		# Instance from tscn
		var hud_scn_path: String = "res://scenes/ui/battle_hud.tscn"
		if ResourceLoader.exists(hud_scn_path):
			var scn: PackedScene = load(hud_scn_path) as PackedScene
			if scn:
				battle_hud = scn.instantiate()
				canvas_layer.add_child(battle_hud)
		else:
			push_warning("[BattleMap] battle_hud.tscn not found")
	if battle_hud:
		if battle_hud.has_signal("action_requested"):
			if not battle_hud.is_connected("action_requested", _on_hud_action):
				battle_hud.connect("action_requested", _on_hud_action)

func _setup_interview() -> void:
	interview_panel = get_node_or_null("CanvasLayer/InterviewPanel")
	if interview_panel == null:
		interview_panel = get_node_or_null("InterviewPanel")
	if interview_panel == null:
		var ip_path: String = "res://scenes/ui/interview_panel.tscn"
		if ResourceLoader.exists(ip_path):
			var scn: PackedScene = load(ip_path) as PackedScene
			if scn:
				interview_panel = scn.instantiate()
				canvas_layer.add_child(interview_panel)
	if interview_panel:
		if interview_panel.has_signal("option_selected"):
			if not interview_panel.is_connected("option_selected", _on_tactical_option_selected):
				interview_panel.connect("option_selected", _on_tactical_option_selected)

func _setup_mission_panel() -> void:
	mission_panel = get_node_or_null("CanvasLayer/MissionResultPanel")
	if mission_panel == null:
		mission_panel = get_node_or_null("MissionResultPanel")
	if mission_panel == null:
		var mp_path: String = "res://scenes/ui/mission_result_panel.tscn"
		if ResourceLoader.exists(mp_path):
			var scn: PackedScene = load(mp_path) as PackedScene
			if scn:
				mission_panel = scn.instantiate()
				canvas_layer.add_child(mission_panel)
	if mission_panel:
		if mission_panel.has_signal("confirmed"):
			if not mission_panel.is_connected("confirmed", _on_mission_confirmed):
				mission_panel.connect("confirmed", _on_mission_confirmed)

func _setup_slm() -> void:
	slm_client = get_node_or_null("SLMClient")
	if slm_client == null:
		slm_client = load("res://scripts/ai/slm_client.gd").new()
		slm_client.name = "SLMClient"
		add_child(slm_client)
		slm_client.configure("http://localhost:11434", "qwen2:7b", 0)
		slm_client.set_timeout(4.0)
		slm_client.use_fallback_on_error = true
	if slm_client and slm_client.has_signal("staff_advice_received"):
		if not slm_client.is_connected("staff_advice_received", _on_staff_advice):
			slm_client.connect("staff_advice_received", _on_staff_advice)

func _setup_end_turn_button() -> void:
	end_turn_btn = canvas_layer.get_node_or_null("EndTurnBtn") as Button
	if end_turn_btn == null:
		end_turn_btn = Button.new()
		end_turn_btn.name = "EndTurnBtn"
		end_turn_btn.text = "턴 종료"
		end_turn_btn.custom_minimum_size = Vector2(140, 44)
		end_turn_btn.position = Vector2(1280 - 160, 720 - 70)
		end_turn_btn.size = Vector2(140, 44)
		# Style: anchor bottom right via manual position
		end_turn_btn.add_theme_font_size_override("font_size", 14)
		end_turn_btn.tooltip_text = "아군 행동을 마치고 적 턴으로 진행 (Enter)"
		canvas_layer.add_child(end_turn_btn)
		# Ensure it stays bottom-right on resize (use anchors via Control parent? Keep simple)
		end_turn_btn.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
		end_turn_btn.position = Vector2.ZERO
		end_turn_btn.offset_left = -160
		end_turn_btn.offset_top = -70
		end_turn_btn.offset_right = -20
		end_turn_btn.offset_bottom = -20
		end_turn_btn.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		end_turn_btn.grow_vertical = Control.GROW_DIRECTION_BEGIN
	# Move to front
	canvas_layer.move_child(end_turn_btn, canvas_layer.get_child_count() - 1)
	if not end_turn_btn.pressed.is_connected(_on_end_turn_pressed):
		end_turn_btn.pressed.connect(_on_end_turn_pressed)
	end_turn_btn.visible = false

func _connect_grid_signals() -> void:
	if hex_grid:
		if hex_grid.has_signal("cell_clicked"):
			if not hex_grid.is_connected("cell_clicked", _on_hex_clicked):
				hex_grid.connect("cell_clicked", _on_hex_clicked)
		if hex_grid.has_signal("cell_hovered"):
			if not hex_grid.is_connected("cell_hovered", _on_hex_hovered):
				hex_grid.connect("cell_hovered", _on_hex_hovered)

func _connect_turn_manager() -> void:
	var tm: Node = get_node_or_null("/root/TurnManager")
	if tm:
		if tm.has_signal("phase_changed"):
			if not tm.is_connected("phase_changed", _on_tm_phase_changed):
				tm.connect("phase_changed", _on_tm_phase_changed)
		if tm.has_signal("turn_count_changed"):
			if not tm.is_connected("turn_count_changed", _on_tm_turn_changed):
				tm.connect("turn_count_changed", _on_tm_turn_changed)

func _on_tm_phase_changed(_old: int, new_phase: int, _faction: StringName) -> void:
	current_phase = new_phase
	_update_turn_label()

func _on_tm_turn_changed(turn: int) -> void:
	_update_turn_label()
	# 턴 카운터 변화 → 배너 슬라이드 (첫 턴 제외)
	if turn > 1:
		var am: Node = get_node_or_null("/root/AudioManager")
		if am != null:
			am.call("play_sfx", "turn_change")
			am.call("show_banner", "제 %d턴" % turn, "새로운 턴이 시작되었습니다", Color(0.85, 0.65, 0.18, 0.95))

func _update_turn_label() -> void:
	var tm: Node = get_node_or_null("/root/TurnManager")
	var turn: int = 1
	var phase: int = current_phase
	if tm:
		turn = int(tm.get("current_turn"))
		phase = int(tm.get("current_phase"))
	var label: String = "Turn %d  Phase: %s" % [turn, _phase_label(phase)]
	if turn_label:
		turn_label.text = label
	if debug_label:
		debug_label.text = "Hex: (%d,%d)  Phase: %s" % [selected_hex.x, selected_hex.y, _phase_label(phase)] if selected_hex.x != -999 else "Hex: --  Phase: %s" % _phase_label(phase)

func _phase_label(p: int) -> String:
	match p:
		0: return "정찰/참모"
		1: return "배치"
		2: return "교전"
		3: return "종결"
		_: return str(p)

# ------------------------------------------------------------------
# Phase 1: RECON
# ------------------------------------------------------------------
func _enter_recon_phase() -> void:
	current_phase = 0 # RECON
	var tm: Node = get_node_or_null("/root/TurnManager")
	if tm and tm.has_method("set_phase"):
		tm.set_phase(0)
	_update_turn_label()
	end_turn_btn.visible = false
	deselect_unit()
	# Build context
	var ctx: Dictionary = _build_staff_context()
	# Show loading interview while waiting
	if interview_panel:
		interview_panel.set_staff_info("참모", "병조참의", null)
		interview_panel.set_briefing("전황을 분석 중이옵니다... (SLM 연결 시도)", [])
		interview_panel.show_interview()
	# Request SLM
	if slm_client:
		var err: int = slm_client.request_staff_advice(ctx)
		if err != OK:
			# Busy or fail -> immediate fallback
			var fb: Dictionary = RuleBasedFallbackCls.get_staff_advice(ctx)
			_on_staff_advice(fb)
	else:
		var fb2: Dictionary = RuleBasedFallbackCls.get_staff_advice(ctx)
		_on_staff_advice(fb2)
	# Safety timeout: if no response in 5s, force fallback
	await get_tree().create_timer(5.0).timeout
	if _last_staff_result.is_empty() and interview_panel and interview_panel.visible:
		var fb3: Dictionary = RuleBasedFallbackCls.get_staff_advice(ctx)
		_on_staff_advice(fb3)

func _build_staff_context() -> Dictionary:
	var ally_total: int = _sum_troops(player_units)
	var enemy_total: int = _sum_troops(enemy_units)
	var ally_morale: float = _avg_morale(player_units)
	# Terrain summary
	var counts: Dictionary = {0:0,1:0,2:0,3:0,4:0,5:0,6:0}
	for k in hex_grid.cell_data.keys():
		var c: Variant = hex_grid.cell_data[k]
		counts[c.terrain] = counts.get(c.terrain, 0) + 1
	var total_cells: int = hex_grid.cell_data.size()
	var plains_pct: int = int(float(counts.get(0,0)) / float(max(1,total_cells)) * 100)
	var forest_pct: int = int(float(counts.get(2,0)) / float(max(1,total_cells)) * 100)
	var mountain_pct: int = int(float(counts.get(1,0)) / float(max(1,total_cells)) * 100)
	var terrain_summary: String = "평야 %d%%, 숲 %d%%, 산지 %d%%" % [plains_pct, forest_pct, mountain_pct]
	var fog_hexes: int = 8
	var scouts: int = 0
	for u in player_units:
		var ut = u.get("unit_type")
		if ut and bool(ut.get("can_scout")):
			scouts += 1
	# Available coords: 3 empty hexes near center
	var avail: Array = []
	var center_q: int = GRID_Q / 2
	var center_r: int = GRID_R / 2
	for dq in range(-2, 3):
		for dr in range(-2, 3):
			var q: int = center_q + dq
			var r: int = center_r + dr
			var cell: Variant = hex_grid.get_cell(q, r)
			if cell and cell.occupying_unit == null:
				avail.append([q, r])
				if avail.size() >= 6:
					break
		if avail.size() >= 6:
			break
	if avail.is_empty():
		avail = [[5,5],[6,6],[7,5]]
	var tm: Node = get_node_or_null("/root/TurnManager")
	var turn: int = 1
	if tm:
		turn = int(tm.get("current_turn"))
	return {
		"friendly_total": ally_total,
		"enemy_estimated_total": enemy_total,
		"enemy_est_accuracy": 65,
		"friendly_morale_avg": ally_morale,
		"terrain_summary": terrain_summary,
		"fog_hexes": fog_hexes,
		"scout_available": scouts,
		"staff_ability": 68,
		"staff_personality": "균형파",
		"staff_name": "제갈량",
		"staff_courtesy": "공명",
		"available_coords": avail,
		"turn": turn,
		"phase": "RECON",
		"infantry_cnt": _count_type(player_units, "infantry"),
		"archer_cnt": _count_type(player_units, "archers"),
		"cavalry_cnt": _count_type(player_units, "cavalry"),
		"spearmen_cnt": _count_type(player_units, "spearmen"),
		"battlefield_notes": "전선 중앙에 요새 1개체 존재",
	}

func _count_type(arr: Array, type_id: String) -> int:
	var c: int = 0
	for u in arr:
		var ut = u.get("unit_type")
		if ut and str(ut.get("id")) == type_id:
			c += 1
	return c

func _on_staff_advice(result: Dictionary) -> void:
	if not result.is_empty() and result.has("staff_dialogue"):
		_last_staff_result = result
	else:
		# invalid -> fallback
		var ctx: Dictionary = _build_staff_context()
		_last_staff_result = RuleBasedFallbackCls.get_staff_advice(ctx)
		result = _last_staff_result
	var staff_name: String = str(result.get("staff_personality", "참모"))
	# Use staff_name from context? result has staff_personality
	var dialogue: String = str(result.get("staff_dialogue", "주공, 신중히 살피시옵소서."))
	var options: Array = result.get("tactical_options", []) as Array
	# Transform options to interview_panel format: id, text, tooltip
	var ip_opts: Array = []
	for opt in options:
		if opt is Dictionary:
			var oid: String = str(opt.get("id", "option_unknown"))
			var title: String = str(opt.get("title", "전술"))
			var risk: String = str(opt.get("risk", "medium"))
			var reason: String = str(opt.get("reason", opt.get("tooltip", "")))
			ip_opts.append({"id": StringName(oid), "text": "%s [%s]" % [title, risk], "tooltip": reason})
	if interview_panel:
		interview_panel.set_staff_info("제갈량", "군사 · %s" % staff_name, null)
		interview_panel.set_briefing(dialogue, ip_opts)
		if not interview_panel.visible:
			interview_panel.show_interview()
	# Also print for verification
	print("[BattleMap] Staff advice: %s | options=%d fallback=%s" % [dialogue.left(60), ip_opts.size(), str(result.get("is_fallback", false))])

func _on_tactical_option_selected(option_id: StringName) -> void:
	var tactical_action: StringName = _pending_tactical_action
	_pending_tactical_action = &""
	if String(tactical_action) == "scout":
		if String(option_id) == "scout_ambush":
			_prepare_scout_ambush()
		else:
			_reveal_scout_area()
		if interview_panel:
			interview_panel.hide_interview()
		_enter_deploy_phase()
		return
	if _last_staff_result.is_empty():
		_enter_deploy_phase()
		return
	var opts: Array = _last_staff_result.get("tactical_options", []) as Array
	var chosen: Dictionary = {}
	for o in opts:
		if o is Dictionary and StringName(o.get("id", "")) == option_id:
			chosen = o
			break
	if chosen.is_empty() and not opts.is_empty():
		chosen = opts[0] as Dictionary
	var target = chosen.get("target_coords", null)
	var target_hex: Vector2i = Vector2i(-999, -999)
	if target is Array and target.size() >= 2:
		target_hex = Vector2i(int(target[0]), int(target[1]))
	elif target is Vector2i:
		target_hex = target as Vector2i
	print("[BattleMap] Tactical choice: %s -> target %s" % [option_id, str(target_hex)])
	# Blink highlight on map
	if target_hex.x != -999 and hex_grid.get_cell(target_hex.x, target_hex.y) != null:
		hex_grid.blink_hex(target_hex, 1.6, 4)
		# Camera focus
		if camera and camera.has_method("focus_on"):
			var world: Vector2 = HexUtilsCls.hex_to_pixel(target_hex.x, target_hex.y)
			camera.focus_on(world)
	if interview_panel:
		interview_panel.hide_interview()
		# small delay then enter deploy
	await get_tree().create_timer(1.2).timeout
	_enter_deploy_phase()

func _enter_deploy_phase() -> void:
	current_phase = 2 # ENGAGE (player action)
	var tm: Node = get_node_or_null("/root/TurnManager")
	if tm and tm.has_method("set_phase"):
		tm.set_phase(2)
	_update_turn_label()
	end_turn_btn.visible = true
	end_turn_btn.disabled = false
	has_acted.clear()
	deselect_unit()
	_update_hud_all()
	print("[BattleMap] Phase 2 DEPLOY/ENGAGE — 부대 조작 가능. 아군 선택 후 이동/공격, 턴 종료 버튼으로 적 턴.")

# ------------------------------------------------------------------
# Selection / Interaction
# ------------------------------------------------------------------
func _on_hex_clicked(cell, _screen_pos: Vector2) -> void:
	if is_animating:
		return
	if current_phase != 2 and current_phase != 1:
		# Allow inspection but not action outside deploy
		if cell.occupying_unit != null and battle_hud:
			battle_hud.show_unit(cell.occupying_unit, int(cell.q), int(cell.r))
		return
	var clicked_unit = cell.get("occupying_unit")
	var clicked_hex: Vector2i = Vector2i(int(cell.q), int(cell.r))

	# If animating or no selection yet
	if selected_unit != null:
		# Try move
		if clicked_hex in reachable_hexes and _is_player_faction(selected_unit) and clicked_unit == null:
			# Check terrain passable already filtered, but double-check
			var target_cell: Variant = hex_grid.get_cell(clicked_hex.x, clicked_hex.y)
			if target_cell and selected_unit.unit_type.can_enter(target_cell.terrain):
				# Check not already acted? allow one move per turn
				var iid: int = selected_unit.get_instance_id()
				if has_acted.get(iid, false):
					spawn_floating_text(selected_hex, "행동 완료", Color(0.9, 0.9, 0.9, 1))
					return
				_execute_move(selected_unit, selected_hex, clicked_hex)
				return
			else:
				spawn_floating_text(clicked_hex, "진입 불가", Color(1, 0.4, 0.2, 1))
				return
		# Try attack
		if clicked_hex in attackable_enemy_hexes and _is_player_faction(selected_unit) and clicked_unit != null and not _is_player_faction(clicked_unit):
			var dist: int = HexUtilsCls.hex_distance(selected_hex, clicked_hex)
			var rng: int = int(selected_unit.unit_type.attack_range)
			# Archer range bonus from terrain?
			var sel_cell: Variant = hex_grid.get_cell(selected_hex.x, selected_hex.y)
			var sel_terrain: int = sel_cell.terrain if sel_cell else 0
			if selected_unit.unit_type.id == "archers" or selected_unit.unit_type.id == "siege":
				var bonus: int = TerrainModsCls.get_archer_range_bonus(sel_terrain)
				rng += bonus
			if dist <= rng and dist > 0:
				var iid2: int = selected_unit.get_instance_id()
				if has_acted.get(iid2, false):
					spawn_floating_text(selected_hex, "행동 완료", Color(0.9, 0.9, 0.9, 1))
					return
				_execute_attack(selected_unit, clicked_unit)
				return
			else:
				spawn_floating_text(clicked_hex, "사거리 밖", Color(1, 1, 0.4, 1))
				return
		# Click on another ally -> switch selection
		if clicked_unit != null and _is_player_faction(clicked_unit):
			_select_unit(clicked_unit, clicked_hex)
			return
		# Click on enemy for info (outside attack range)
		if clicked_unit != null and not _is_player_faction(clicked_unit):
			if battle_hud:
				battle_hud.show_unit(clicked_unit, clicked_hex.x, clicked_hex.y)
			# Keep selection? deselect to avoid confusion? Keep but clear move overlays?
			# We'll keep selection but show enemy info as well
			# For clarity, deselect if clicking enemy outside attack range?
			# Let's keep selection, but also highlight enemy
			# Optionally blink enemy?
			return
		# Click empty non-reachable -> deselect
		if clicked_unit == null:
			deselect_unit()
			if battle_hud:
				battle_hud.hide_unit_card()
			return
	else:
		# No selection
		if clicked_unit != null and _is_player_faction(clicked_unit):
			_select_unit(clicked_unit, clicked_hex)
		elif clicked_unit != null:
			# enemy inspect
			if battle_hud:
				battle_hud.show_unit(clicked_unit, clicked_hex.x, clicked_hex.y)
			# Highlight its position? selection visual but not as active
			hex_grid.show_selection(clicked_hex.x, clicked_hex.y)
		else:
			deselect_unit()
			if battle_hud:
				battle_hud.hide_unit_card()

func _is_player_faction(unit) -> bool:
	var f: String = str(unit.get("faction"))
	return f == "player" or f == "blue"

func _select_unit(unit, hex: Vector2i) -> void:
	var iid: int = unit.get_instance_id()
	if has_acted.get(iid, false):
		spawn_floating_text(hex, "이미 행동", Color(0.85, 0.85, 0.85, 1))
		if battle_hud:
			battle_hud.show_unit(unit, hex.x, hex.y)
		hex_grid.show_selection(hex.x, hex.y)
		selected_unit = unit
		selected_hex = hex
		reachable_hexes.clear()
		attackable_enemy_hexes.clear()
		return

	selected_unit = unit
	selected_hex = hex
	hex_grid.show_selection(hex.x, hex.y)
	if battle_hud:
		battle_hud.show_unit(unit, hex.x, hex.y)

	# Compute reachable hexes
	var raw_reachable: Array[Vector2i] = movement_calculator_gd.get_reachable_hexes(unit, hex_grid.cell_data)
	# Filter occupied hexes for movement (can't move onto ally or enemy)
	var filtered: Array[Vector2i] = []
	for h in raw_reachable:
		if h == hex:
			filtered.append(h)
			continue
		var cell: Variant = hex_grid.get_cell(h.x, h.y)
		if cell == null:
			continue
		if cell.occupying_unit != null:
			continue
		filtered.append(h)
	reachable_hexes = filtered

	# Compute attackable enemies within range
	attackable_enemy_hexes.clear()
	var rng: int = int(unit.unit_type.attack_range)
	var sel_cell: Variant = hex_grid.get_cell(hex.x, hex.y)
	var sel_terrain: int = sel_cell.terrain if sel_cell else 0
	if unit.unit_type.id == "archers" or unit.unit_type.id == "siege":
		rng += TerrainModsCls.get_archer_range_bonus(sel_terrain)
	var in_range: Array[Vector2i] = HexUtilsCls.hexes_in_range(hex, rng)
	var attack_hexes_for_overlay: Array[Vector2i] = []
	for eh in enemy_units:
		var eh_hex: Vector2i = Vector2i(int(eh.get("hex_q")), int(eh.get("hex_r")))
		if eh_hex in in_range:
			attackable_enemy_hexes.append(eh_hex)
			attack_hexes_for_overlay.append(eh_hex)
	# For overlay, show move range + attack range (attack hexes are enemy positions only spec says, but also show surrounding?
	# Spec: "사거리 내 적군 부대 존재 시: ui_attack_range.png 하이라이트" — highlight enemy hexes
	hex_grid.show_ranges(reachable_hexes, attack_hexes_for_overlay)
	print("[BattleMap] Select %s at (%d,%d) MP=%d reachable=%d attackable=%d" % [unit.unit_type.name_kr, hex.x, hex.y, unit.get_movement_points(), reachable_hexes.size(), attackable_enemy_hexes.size()])

func deselect_unit() -> void:
	selected_unit = null
	selected_hex = Vector2i(-999, -999)
	reachable_hexes.clear()
	attackable_enemy_hexes.clear()
	hex_grid.clear_move_attack_overlays()
	hex_grid.hide_selection()

func _on_hex_hovered(cell) -> void:
	if debug_label:
		var u = cell.get("occupying_unit")
		var occ: String = ""
		if u != null:
			occ = " [%s %d명]" % [u.unit_type.name_kr, int(u.get("soldier_count"))]
		debug_label.text = "Hex (%d,%d) %s%s" % [int(cell.q), int(cell.r), cell.get_terrain_name(), occ]
	_update_turn_label()

# ------------------------------------------------------------------
# Move / Attack execution
# ------------------------------------------------------------------
func _execute_move(unit, from_hex: Vector2i, to_hex: Vector2i) -> void:
	if is_animating:
		return
	is_animating = true
	hex_grid.clear_move_attack_overlays()
	hex_grid.hide_selection()
	# Find path with MovementCalculator cost
	var cost_callable: Callable = func(t: int): return movement_calculator_gd.get_terrain_cost(t)
	var path: Array[Vector2i] = HexUtilsCls.find_path(hex_grid.cell_data, from_hex, to_hex, Callable(), cost_callable)
	if path.is_empty():
		# fallback direct
		path = [from_hex, to_hex]
	print("[BattleMap] Move %s %s -> %s path=%s" % [unit.unit_type.name_kr, str(from_hex), str(to_hex), str(path)])
	# Update cell occupying refs preemptively? Do after animation to avoid double occupy
	var from_cell: Variant = hex_grid.get_cell(from_hex.x, from_hex.y)
	var to_cell: Variant = hex_grid.get_cell(to_hex.x, to_hex.y)
	if to_cell and to_cell.occupying_unit != null:
		spawn_floating_text(to_hex, "점유됨", Color(1, 0.4, 0.2, 1))
		is_animating = false
		deselect_unit()
		return
	# Animate
		unit_renderer.move_unit_along_path(unit, path)
		var steps: int = path.size() - 1
		var dur: float = steps * 0.18 + 0.08
		# 행군 SFX — 이동 시작 시 한 번 트리거
		var am: Node = get_node_or_null("/root/AudioManager")
		if am != null:
			am.call("play_sfx", "march")
		await get_tree().create_timer(dur).timeout
	# Commit grid
	if from_cell:
		from_cell.occupying_unit = null
	if to_cell:
		to_cell.occupying_unit = unit
	unit.hex_q = to_hex.x
	unit.hex_r = to_hex.y
	unit_renderer.update_unit_position(unit, to_hex.x, to_hex.y, true)
	has_acted[unit.get_instance_id()] = true
	is_animating = false
	deselect_unit()
	_update_hud_all()
	# Check if moved onto enemy? shouldn't happen
	_check_battle_end()

func _execute_attack(attacker, defender) -> void:
	if is_animating:
		return
	is_animating = true
	hex_grid.clear_move_attack_overlays()
	var atk_hex: Vector2i = Vector2i(int(attacker.get("hex_q")), int(attacker.get("hex_r")))
	var def_hex: Vector2i = Vector2i(int(defender.get("hex_q")), int(defender.get("hex_r")))
	var atk_cell: Variant = hex_grid.get_cell(atk_hex.x, atk_hex.y)
	var def_cell: Variant = hex_grid.get_cell(def_hex.x, def_hex.y)
	var atk_terrain: int = atk_cell.terrain if atk_cell else 0
	var def_terrain: int = def_cell.terrain if def_cell else 0

	var result: Dictionary = CombatCalculatorCls.calculate(attacker, defender, atk_terrain, def_terrain)
	var atk_cas: int = int(result.get("attacker_casualties", 0))
	var def_cas: int = int(result.get("defender_casualties", 0))
	var rout_chance: float = float(result.get("defender_rout_chance", 0.0))
	var ambush_key: String = "%d,%d" % [atk_hex.x, atk_hex.y]
	if _prepared_ambushes.has(ambush_key) and TerrainModsCls.can_ambush(atk_terrain):
		def_cas = int(round(float(def_cas) * 1.35))
		atk_cas = int(round(float(atk_cas) * 0.75))
		_prepared_ambushes.erase(ambush_key)
		if hex_grid.has_method("clear_ambush_hex"):
			hex_grid.call("clear_ambush_hex", atk_hex.x, atk_hex.y)
		print("[BattleMap] Ambush triggered at %s: defender damage +35%%" % str(atk_hex))
	print("[BattleMap] Combat %s vs %s => atkCas %d defCas %d rout %.1f%% | %s" % [
		attacker.unit_type.name_kr, defender.unit_type.name_kr, atk_cas, def_cas, rout_chance*100.0, str(result.get("summary",""))
	])
	# Apply casualties
	var atk_before: int = int(attacker.get("soldier_count"))
	var def_before: int = int(defender.get("soldier_count"))
	attacker.take_casualties(atk_cas)
	defender.take_casualties(def_cas)
	_ally_cas_total += atk_cas if _is_player_faction(attacker) else def_cas
	_enemy_cas_total += def_cas if not _is_player_faction(defender) else atk_cas
	if _is_player_faction(attacker):
		_ally_cas_total += atk_cas
		_enemy_cas_total += def_cas
	else:
		_ally_cas_total += def_cas
		_enemy_cas_total += atk_cas

	# Morale
	var atk_loss_ratio: float = float(atk_cas) / float(max(1, atk_before))
	var def_loss_ratio: float = float(def_cas) / float(max(1, def_before))
	var atk_won: bool = def_cas > atk_cas
	attacker.current_morale = MoraleSystemCls.morale_after_battle(float(attacker.get("current_morale")), atk_won, atk_loss_ratio, def_loss_ratio)
	defender.current_morale = MoraleSystemCls.morale_after_battle(float(defender.get("current_morale")), not atk_won, def_loss_ratio, atk_loss_ratio)

	# ─── AudioManager 트리거: 공격 SFX + 큰 피해 셰이크 + 강한 플로팅 ───
	var am: Node = get_node_or_null("/root/AudioManager")
	if am != null:
		# 공격자 유닛 타입에 따른 SFX (cavalry=sword, spearmen=spear_brace 등)
		var atk_type_id: String = String(attacker.unit_type.id)
		var max_cas: int = max(atk_cas, def_cas)
		am.call("play_attack_sfx", atk_type_id)
		# 큰 피해면 묵직한 버전 + 셰이크
		if max_cas >= 25:
			am.call("play_big_hit_sfx", atk_type_id, max_cas, 25)

	# ─── 쥬스: 플로팅 데미지 (적: 황금색, 아군: 붉은색, 큰 피해: 1.6× 크기) ───
	var atk_is_player: bool = _is_player_faction(attacker)
	var max_loss: int = max(atk_cas, def_cas)
	var size_mult: float = 1.0
	if max_loss >= 25:
		size_mult = 1.6
	elif max_loss >= 10:
		size_mult = 1.25
	spawn_floating_text(atk_hex, "-%d" % atk_cas, Color(1, 0.55, 0.55, 1))
	spawn_floating_text(def_hex, "-%d" % def_cas, Color(1, 0.95, 0.55, 1))
	if max_loss >= 15:
		# 강한 셰이크 직접 호출 (positional arg)
		var shake_intensity: float = clampf(0.4 + float(max_loss) * 0.012, 0.4, 1.2)
		_apply_camera_shake(shake_intensity, 0.28)
	# Small camera shake? simple tween (기존) — 큰 피해는 위에서 별도로 처리하므로 가벼운 효과만
	if camera and max_loss < 15:
		var orig: Vector2 = camera.position
		var tw: Tween = create_tween()
		tw.tween_property(camera, "position", orig + Vector2(2, 0), 0.04)
		tw.tween_property(camera, "position", orig + Vector2(-2, 0), 0.04)
		tw.tween_property(camera, "position", orig, 0.04)

	await get_tree().create_timer(0.35).timeout

	# Rout check
	var defender_routed: bool = false
	var should_rout: bool = false
	if float(defender.get("current_morale")) < 20.0:
		should_rout = true
	elif randf() < rout_chance:
		should_rout = true
	if should_rout:
		# 패주 SFX
		if am != null:
			am.call("play_sfx", "morale_break")
		if int(defender.get("soldier_count")) <= 0 or float(defender.get("current_morale")) < 5.0:
			# Annihilated
			spawn_floating_text(def_hex, "소멸!", Color(1, 0.2, 0.2, 1))
			_remove_unit(defender, def_hex)
		else:
			spawn_floating_text(def_hex, "패주!", Color(1, 0.35, 0.2, 1))
			defender_routed = true
			# Try retreat to nearest empty neighbor
			var retreat_hex: Vector2i = _find_retreat_hex(defender, def_hex)
			if retreat_hex.x != -999:
				var retreat_cell: Variant = hex_grid.get_cell(retreat_hex.x, retreat_hex.y)
				var cur_cell: Variant = hex_grid.get_cell(def_hex.x, def_hex.y)
				if retreat_cell and retreat_cell.occupying_unit == null and defender.unit_type.can_enter(retreat_cell.terrain):
					# animate retreat
					var p: Array[Vector2i] = [def_hex, retreat_hex]
					unit_renderer.move_unit_along_path(defender, p)
					await get_tree().create_timer(0.32).timeout
					if cur_cell:
						cur_cell.occupying_unit = null
					retreat_cell.occupying_unit = defender
					defender.hex_q = retreat_hex.x
					defender.hex_r = retreat_hex.y
					unit_renderer.update_unit_position(defender, retreat_hex.x, retreat_hex.y, true)
				else:
					# remove if no retreat
					pass
			else:
				# no retreat hex -> remove? For demo keep but mark
				pass
		# Attacker morale bonus on rout
		if defender_routed:
			attacker.current_morale = clampf(float(attacker.get("current_morale")) + 3.0, 0, 100)
	else:
		# Check death without rout
		if int(defender.get("soldier_count")) <= 0:
			spawn_floating_text(def_hex, "섬멸!", Color(1, 0.2, 0.2, 1))
			_remove_unit(defender, def_hex)
		if int(attacker.get("soldier_count")) <= 0:
			spawn_floating_text(atk_hex, "섬멸!", Color(1, 0.2, 0.2, 1))
			_remove_unit(attacker, atk_hex)

	unit_renderer.update_unit_visual(attacker)
	unit_renderer.update_unit_visual(defender)
	if battle_hud:
		battle_hud.show_unit(attacker, atk_hex.x, atk_hex.y)
	has_acted[attacker.get_instance_id()] = true
	is_animating = false
	deselect_unit()
	_update_hud_all()
	_check_battle_end()
	await get_tree().create_timer(0.2).timeout

func _find_retreat_hex(unit, from_hex: Vector2i) -> Vector2i:
	var best: Vector2i = Vector2i(-999, -999)
	var best_dist: int = -1
	var enemy_avg: Vector2 = Vector2.ZERO
	var cnt: int = 0
	for p in player_units:
		if int(p.get("soldier_count")) <= 0: continue
		enemy_avg += Vector2(int(p.get("hex_q")), int(p.get("hex_r")))
		cnt += 1
	if cnt == 0:
		enemy_avg = Vector2(from_hex.x, from_hex.y)
	else:
		enemy_avg /= float(cnt)
	var candidates: Array[Vector2i] = HexUtilsCls.get_all_neighbors_offset(from_hex.x, from_hex.y)
	candidates.shuffle()
	for nb in candidates:
		var cell: Variant = hex_grid.get_cell(nb.x, nb.y)
		if cell == null: continue
		if cell.occupying_unit != null: continue
		if not unit.unit_type.can_enter(cell.terrain): continue
		# Prefer farthest from enemy avg
		var d: float = Vector2(nb.x, nb.y).distance_to(enemy_avg)
		if d > float(best_dist):
			best_dist = int(d)
			best = nb
	return best

func _remove_unit(unit, hex: Vector2i) -> void:
	var cell: Variant = hex_grid.get_cell(hex.x, hex.y)
	if cell and cell.occupying_unit == unit:
		cell.occupying_unit = null
	unit_renderer.remove_unit(unit)
	if _is_player_faction(unit):
		player_units.erase(unit)
	else:
		enemy_units.erase(unit)
	all_units.erase(unit)

func spawn_floating_text(hex: Vector2i, text: String, color: Color) -> void:
	var world: Vector2 = HexUtilsCls.hex_to_pixel(hex.x, hex.y)
	var lbl: Label = Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", color)
	lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
	lbl.add_theme_constant_override("shadow_offset_x", 1)
	lbl.add_theme_constant_override("shadow_offset_y", 1)
	lbl.horizontal_alignment = 1
	lbl.position = world + Vector2(-30, -28)
	lbl.z_index = 100
	# outline via modulate? use shadow already
	add_child(lbl)
	var tw: Tween = create_tween().set_parallel(true)
	tw.tween_property(lbl, "position:y", lbl.position.y - 28, 0.9).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_property(lbl, "modulate:a", 0.0, 0.9).set_delay(0.35)
	tw.chain().tween_callback(func(): if is_instance_valid(lbl): lbl.queue_free())

# ------------------------------------------------------------------
# HUD & End Turn
# ------------------------------------------------------------------
func _update_hud_all() -> void:
	if battle_hud == null:
		return
	var ally: int = _sum_troops(player_units)
	var enemy: int = _sum_troops(enemy_units)
	battle_hud.update_troops(ally, enemy)
	var morale_avg: float = _avg_morale(player_units)
	battle_hud.update_morale(morale_avg)
	_update_turn_label()

func _on_hud_action(action_id: StringName, unit) -> void:
	print("[BattleMap] HUD action %s" % action_id)
	match action_id:
		&"wait":
			if selected_unit:
				has_acted[selected_unit.get_instance_id()] = true
				spawn_floating_text(selected_hex, "대기", Color(0.8,0.8,0.8,1))
				deselect_unit()
		&"confirm_move":
			# already handled via click; treat as wait
			if selected_unit:
				has_acted[selected_unit.get_instance_id()] = true
				deselect_unit()
		&"retreat":
			if selected_unit:
				var retreat_hex: Vector2i = _find_retreat_hex(selected_unit, selected_hex)
				if retreat_hex.x != -999:
					_execute_move(selected_unit, selected_hex, retreat_hex)
		_:
			pass

func _on_end_turn_pressed() -> void:
	if is_animating or current_phase != 2:
		return
	print("[BattleMap] End Turner pressed — enemy turn")
	# 턴 종료 시 배너 + 사운드
	var am: Node = get_node_or_null("/root/AudioManager")
	if am != null:
		am.call("show_banner", "적의 턴", "적이 진형을 재배치합니다", Color(0.6, 0.2, 0.2, 0.92))
		am.call("play_sfx", "turn_change")
	end_turn_btn.disabled = true
	deselect_unit()
	await _process_enemy_turn()
	# After enemy, check again
	if _check_battle_end():
		return
	# Next player turn
	var tm: Node = get_node_or_null("/root/TurnManager")
	if tm and tm.has_method("advance_to_player_turn"):
		# We are still player faction in TurnManager sense; advance cycles?
		# For demo, just increment turn and go recon again
		if tm.has_method("next_phase"):
			tm.next_phase()
	# Reset for next turn
	await get_tree().create_timer(0.6).timeout
	_enter_recon_phase()

func _process_enemy_turn() -> void:
	current_phase = 99 # enemy processing
	is_animating = true
	_update_turn_label()
	if debug_label:
		debug_label.text = "적 턴 진행 중..."
	# Build enemy decision context via RuleBasedFallback for overall?
	var ctx: Dictionary = _build_enemy_context()
	var decision: Dictionary = RuleBasedFallbackCls.get_enemy_decision(ctx)
	print("[BattleMap] Enemy AI decision: %s" % str(decision.get("decision", {})))
	if debug_label:
		debug_label.text = "적 결정: %s" % str(decision.get("decision", {}).get("action_type", ""))

	# Simple per-unit AI: each enemy moves toward nearest player then attacks
	# Sort enemies by nearest distance
	var enemies_sorted: Array = enemy_units.duplicate()
	enemies_sorted.sort_custom(func(a,b):
		var da: int = _nearest_player_distance(a)
		var db: int = _nearest_player_distance(b)
		return da < db
	)
	for eu in enemies_sorted:
		if int(eu.get("soldier_count")) <= 0:
			continue
		if float(eu.get("current_morale")) < 12:
			# panic — try retreat
			var e_hex: Vector2i = Vector2i(int(eu.get("hex_q")), int(eu.get("hex_r")))
			var retreat: Vector2i = _find_retreat_hex(eu, e_hex)
			if retreat.x != -999:
				var p: Array[Vector2i] = [e_hex, retreat]
				var from_cell: Variant = hex_grid.get_cell(e_hex.x, e_hex.y)
				var to_cell: Variant = hex_grid.get_cell(retreat.x, retreat.y)
				if to_cell and to_cell.occupying_unit == null:
					unit_renderer.move_unit_along_path(eu, p)
					await get_tree().create_timer(0.32).timeout
					if from_cell: from_cell.occupying_unit = null
					to_cell.occupying_unit = eu
					eu.hex_q = retreat.x
					eu.hex_r = retreat.y
					unit_renderer.update_unit_position(eu, retreat.x, retreat.y, true)
					spawn_floating_text(retreat, "후퇴", Color(1,0.6,0.3,1))
			continue

		var e_hex2: Vector2i = Vector2i(int(eu.get("hex_q")), int(eu.get("hex_r")))
		var reachable: Array[Vector2i] = movement_calculator_gd.get_reachable_hexes(eu, hex_grid.cell_data)
		# Filter occupied
		var free_reachable: Array[Vector2i] = []
		for h in reachable:
			var c: Variant = hex_grid.get_cell(h.x, h.y)
			if c == null: continue
			if c.occupying_unit != null and h != e_hex2: continue
			free_reachable.append(h)
		# Find nearest player hex
		var nearest_player_hex: Vector2i = _nearest_player_hex(e_hex2)
		if nearest_player_hex.x == -999:
			continue
		# Find best reachable hex closest to player
		var best_hex: Vector2i = e_hex2
		var best_dist: int = HexUtilsCls.hex_distance(e_hex2, nearest_player_hex)
		for h in free_reachable:
			var d: int = HexUtilsCls.hex_distance(h, nearest_player_hex)
			if d < best_dist:
				best_dist = d
				best_hex = h
		# Move if not staying
		if best_hex != e_hex2:
			var path: Array[Vector2i] = HexUtilsCls.find_path(hex_grid.cell_data, e_hex2, best_hex, Callable(), func(t): return movement_calculator_gd.get_terrain_cost(t))
			if path.is_empty():
				path = [e_hex2, best_hex]
			var from_c: Variant = hex_grid.get_cell(e_hex2.x, e_hex2.y)
			var to_c: Variant = hex_grid.get_cell(best_hex.x, best_hex.y)
			if to_c and to_c.occupying_unit == null:
				print("[BattleMap] Enemy %s move %s -> %s" % [eu.unit_type.name_kr, str(e_hex2), str(best_hex)])
				unit_renderer.move_unit_along_path(eu, path)
				await get_tree().create_timer(float(path.size())*0.18 + 0.1).timeout
				if from_c: from_c.occupying_unit = null
				to_c.occupying_unit = eu
				eu.hex_q = best_hex.x
				eu.hex_r = best_hex.y
				unit_renderer.update_unit_position(eu, best_hex.x, best_hex.y, true)
		# After move, try attack nearest player within range
		var post_hex: Vector2i = Vector2i(int(eu.get("hex_q")), int(eu.get("hex_r")))
		var rng: int = int(eu.unit_type.attack_range)
		var cell_post: Variant = hex_grid.get_cell(post_hex.x, post_hex.y)
		var t_post: int = cell_post.terrain if cell_post else 0
		if eu.unit_type.id == "archers" or eu.unit_type.id == "siege":
			rng += TerrainModsCls.get_archer_range_bonus(t_post)
		var targets: Array = []
		for pu in player_units:
			if int(pu.get("soldier_count")) <= 0: continue
			var ph: Vector2i = Vector2i(int(pu.get("hex_q")), int(pu.get("hex_r")))
			var d: int = HexUtilsCls.hex_distance(post_hex, ph)
			if d <= rng and d > 0:
				targets.append({"unit": pu, "hex": ph, "dist": d})
		if not targets.is_empty():
			targets.sort_custom(func(a,b): return a["dist"] < b["dist"])
			var tgt = targets[0]
			var pu_target = tgt["unit"]
			print("[BattleMap] Enemy %s attacks %s at %s" % [eu.unit_type.name_kr, pu_target.unit_type.name_kr, str(tgt["hex"])])
			await _enemy_execute_attack(eu, pu_target)
			if _check_battle_end():
				is_animating = false
				return
			await get_tree().create_timer(0.2).timeout

	is_animating = false
	has_acted.clear()
	print("[BattleMap] Enemy turn complete")

func _nearest_player_hex(from_hex: Vector2i) -> Vector2i:
	var best: Vector2i = Vector2i(-999, -999)
	var best_d: int = 9999
	for pu in player_units:
		if int(pu.get("soldier_count")) <= 0: continue
		var ph: Vector2i = Vector2i(int(pu.get("hex_q")), int(pu.get("hex_r")))
		var d: int = HexUtilsCls.hex_distance(from_hex, ph)
		if d < best_d:
			best_d = d
			best = ph
	return best

func _nearest_player_distance(eu) -> int:
	var eh: Vector2i = Vector2i(int(eu.get("hex_q")), int(eu.get("hex_r")))
	var ph: Vector2i = _nearest_player_hex(eh)
	if ph.x == -999:
		return 9999
	return HexUtilsCls.hex_distance(eh, ph)

func _enemy_execute_attack(attacker, defender) -> void:
	var atk_hex: Vector2i = Vector2i(int(attacker.get("hex_q")), int(attacker.get("hex_r")))
	var def_hex: Vector2i = Vector2i(int(defender.get("hex_q")), int(defender.get("hex_r")))
	var atk_cell: Variant = hex_grid.get_cell(atk_hex.x, atk_hex.y)
	var def_cell: Variant = hex_grid.get_cell(def_hex.x, def_hex.y)
	var atk_terrain: int = atk_cell.terrain if atk_cell else 0
	var def_terrain: int = def_cell.terrain if def_cell else 0
	var result: Dictionary = CombatCalculatorCls.calculate(attacker, defender, atk_terrain, def_terrain)
	var atk_cas: int = int(result.get("attacker_casualties", 0))
	var def_cas: int = int(result.get("defender_casualties", 0))
	var rout_chance: float = float(result.get("defender_rout_chance", 0))
	print("[BattleMap][Enemy] %s vs %s atkCas %d defCas %d rout %.0f%%" % [attacker.unit_type.name_kr, defender.unit_type.name_kr, atk_cas, def_cas, rout_chance*100])
	attacker.take_casualties(atk_cas)
	defender.take_casualties(def_cas)
	var atk_before_morale: float = float(attacker.get("current_morale"))
	var def_before_morale: float = float(defender.get("current_morale"))
	var atk_loss_ratio: float = float(atk_cas) / float(max(1, int(attacker.get("soldier_count"))+atk_cas))
	var def_loss_ratio: float = float(def_cas) / float(max(1, int(defender.get("soldier_count"))+def_cas))
	var atk_won: bool = def_cas > atk_cas
	attacker.current_morale = MoraleSystemCls.morale_after_battle(atk_before_morale, atk_won, atk_loss_ratio, def_loss_ratio)
	defender.current_morale = MoraleSystemCls.morale_after_battle(def_before_morale, not atk_won, def_loss_ratio, atk_loss_ratio)
	spawn_floating_text(atk_hex, "-%d" % atk_cas, Color(1,0.55,0.55,1))
	spawn_floating_text(def_hex, "-%d" % def_cas, Color(1,0.95,0.55,1))
	await get_tree().create_timer(0.35).timeout
	if float(defender.get("current_morale")) < 20 or randf() < rout_chance:
		if int(defender.get("soldier_count")) <= 0 or float(defender.get("current_morale")) < 5:
			spawn_floating_text(def_hex, "소멸!", Color(1,0.2,0.2,1))
			_remove_unit(defender, def_hex)
		else:
			spawn_floating_text(def_hex, "패주!", Color(1,0.35,0.2,1))
	else:
		if int(defender.get("soldier_count")) <= 0:
			_remove_unit(defender, def_hex)
		if int(attacker.get("soldier_count")) <= 0:
			_remove_unit(attacker, atk_hex)
	unit_renderer.update_unit_visual(attacker)
	unit_renderer.update_unit_visual(defender)
	_update_hud_all()

func _build_enemy_context() -> Dictionary:
	var enemy_total: int = _sum_troops(enemy_units)
	var enemy_morale: float = _avg_morale(enemy_units)
	var ally_total: int = _sum_troops(player_units)
	# supply naive
	var enemy_supply: float = 10.0
	var terrain_summary: String = "평야 40%, 숲 20%"
	var avail: Array = []
	for q in range(GRID_Q):
		for r in range(GRID_R):
			var c: Variant = hex_grid.get_cell(q, r)
			if c and c.occupying_unit == null:
				avail.append([q, r])
				if avail.size() >= 5:
					break
		if avail.size() >= 5:
			break
	return {
		"enemy_total": enemy_total,
		"enemy_morale": enemy_morale,
		"enemy_supply_days": enemy_supply,
		"enemy_personality": "냉정형",
		"enemy_ability": 62,
		"enemy_staff_alive": true,
		"staff_control": 0.85,
		"encircled": false,
		"terrain_summary": terrain_summary,
		"friendly_est_total": ally_total,
		"friendly_est_accuracy": 60,
		"available_coords": avail,
		"escape_routes": [],
		"turn": 1,
		"phase": "ENGAGE",
	}

# ------------------------------------------------------------------
# Resolve / Victory
# ------------------------------------------------------------------
func _check_battle_end() -> bool:
	var ally_alive: int = _sum_troops(player_units)
	var enemy_alive: int = _sum_troops(enemy_units)
	var ally_routed: bool = false
	if not player_units.is_empty():
		var avg_mor: float = _avg_morale(player_units)
		if avg_mor < 15 and ally_alive < _initial_ally_total * 0.3:
			ally_routed = true
	if enemy_alive <= 0:
		_enter_resolve_phase(true)
		return true
	if ally_alive <= 0 or ally_routed:
		_enter_resolve_phase(false)
		return true
	return false

func _enter_resolve_phase(is_victory: bool) -> void:
	current_phase = 3
	var tm: Node = get_node_or_null("/root/TurnManager")
	if tm and tm.has_method("set_phase"):
		tm.set_phase(3)
	end_turn_btn.visible = false
	deselect_unit()
	# 승패 팡파르 / 장송의 선율 — 가장 임팩트 있는 SFX 트리거
	var am: Node = get_node_or_null("/root/AudioManager")
	if am != null:
		if is_victory:
			am.call("play_sfx", "decree_gong")  # 승전 보고 — 큰 징 한 번
			am.call("show_banner", "대 승", "적의 방어선을 돌파하였습니다!", Color(0.85, 0.65, 0.18, 0.95))
			# 0.8초 후 팡파르 (징과 안 겹치도록)
			var tree: SceneTree = get_tree()
			if tree:
				var t: SceneTreeTimer = tree.create_timer(0.8)
				await t.timeout
				if is_instance_valid(am):
					am.call("play_sfx", "victory_fanfare")
		else:
			am.call("play_sfx", "defeat_funeral")
			am.call("show_banner", "패 퇴", "전열이 와해되었습니다...", Color(0.45, 0.15, 0.15, 0.92))
	am.call("shake_camera", 1.2 if is_victory else 1.5, 0.5 if is_victory else 0.7)
	var ally_cas: int = _initial_ally_total - _sum_troops(player_units)
	var enemy_cas: int = _initial_enemy_total - _sum_troops(enemy_units)
	# prisoners naive: 10% of enemy cas if victory
	var prisoners: int = int(enemy_cas * 0.12) if is_victory else 0
	var loot: String = "군량 420석 · 병기 60벌" if is_victory else "없음"
	var fame: int = 18 if is_victory else -12
	var rep: int = 12 if is_victory else -8
	var data: Dictionary = {
		"is_victory": is_victory,
		"ally_casualties": ally_cas,
		"enemy_casualties": enemy_cas,
		"prisoners": prisoners,
		"loot": loot,
		"fame_delta": fame,
		"reputation_delta": rep,
		"extra": "전투 종료 — %s" % ("대승" if is_victory else "패퇴"),
	}
	if mission_panel:
		mission_panel.show_result(data)
	else:
		print("[BattleMap] RESOLVE %s allyCas %d enemyCas %d" % ["Victory" if is_victory else "Defeat", ally_cas, enemy_cas])
	print("[BattleMap] Mission result: %s" % str(data))

func _on_mission_confirmed() -> void:
	# For demo, reset battle
	print("[BattleMap] Mission confirmed — resetting battle")
	_create_units()
	_update_hud_all()
	var tm: Node = get_node_or_null("/root/TurnManager")
	if tm and tm.has_method("reset_turn_state"):
		tm.reset_turn_state()
	_enter_recon_phase()

# ------------------------------------------------------------------
# Input shortcuts
# ------------------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_ESCAPE:
			deselect_unit()
			if battle_hud:
				battle_hud.hide_unit_card()
			if interview_panel and interview_panel.visible:
				interview_panel.hide_interview()
				_enter_deploy_phase()
		elif event.keycode == KEY_ENTER or event.keycode == KEY_SPACE:
			if end_turn_btn and end_turn_btn.visible and not end_turn_btn.disabled and current_phase == 2:
				_on_end_turn_pressed()
				get_viewport().set_input_as_handled()
		elif event.keycode == KEY_R and event.ctrl_pressed:
			_create_units()
			_update_hud_all()

# ------------------------------------------------------------------
# Campaign Runner interface point (next sprint)
# ------------------------------------------------------------------
func get_battle_result() -> Dictionary:
	return {
		"ally_total_start": _initial_ally_total,
		"enemy_total_start": _initial_enemy_total,
		"ally_alive": _sum_troops(player_units),
		"enemy_alive": _sum_troops(enemy_units),
		"ally_casualties": _initial_ally_total - _sum_troops(player_units),
		"enemy_casualties": _initial_enemy_total - _sum_troops(enemy_units),
		"turn": get_node_or_null("/root/TurnManager").get("current_turn") if get_node_or_null("/root/TurnManager") else 1,
		"phase": current_phase,
	}

func get_interface_points() -> Dictionary:
	return {
		"get_battle_result": "전투 결산 데이터 반환 — 캠페인 러너가 호출",
		"get_unit_state": "모든 유닛 상태 배열 반환",
		"set_campaign_context": "캠페인 맵에서 전달한 보급/지형/임무 컨텍스트 주입 예정",
	}
