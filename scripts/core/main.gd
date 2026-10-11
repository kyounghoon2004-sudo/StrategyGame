extends Node
## Main entry — 캠페인 풀 루프 부트스트랩 (오대십국 전략 게임)
## Sprint 3 #8: 캠페인 시작 → 1장 → 전투 → 결산 → 2장 → ... → 최종 엔딩까지 풀 플로우
## BattleMap / BattleHUD / MissionResultPanel / CampaignManager / GameDirector / SLMClient 을 연결

var campaign_manager: Node = null
var game_director: Node = null
var battle_map: Node = null
var hud: Node = null
var result_panel: Node = null

func _ready() -> void:
	print("[Main] StrategyGame 진입 — 캠페인 부트스트랩 시작")
	call_deferred("_bootstrap")

func _bootstrap() -> void:
	_resolve_nodes()
	_wire_hud()
	if game_director != null and campaign_manager != null:
		print("[Main] CampaignManager & GameDirector 연결 완료 — 캠페인 시작")
		var lbl: Label = get_node_or_null("InfoLabel") as Label
		if lbl:
			lbl.text = "캠페인 로드 중..."
		if game_director.has_method("start_campaign"):
			game_director.call("start_campaign")
	else:
		push_warning("[Main] GameDirector 또는 CampaignManager를 찾지 못함 — 기존 배틀맵 단독 모드로 폴백")
		_fallback_load_battle_map()

func _resolve_nodes() -> void:
	campaign_manager = get_node_or_null("CampaignManager")
	if campaign_manager == null:
		campaign_manager = get_node_or_null("../CampaignManager")
	battle_map = get_node_or_null("BattleMap")
	if battle_map == null:
		battle_map = get_node_or_null("BattleMapRoot/BattleMap")
	hud = get_node_or_null("CanvasLayer/BattleHUD")
	if hud == null:
		hud = get_node_or_null("BattleHUD")
	result_panel = get_node_or_null("CanvasLayer/MissionResultPanel")
	if result_panel == null:
		result_panel = get_node_or_null("MissionResultPanel")
	game_director = get_node_or_null("GameDirector")
	if game_director == null:
		game_director = get_node_or_null("../GameDirector")

	# GameDirector 참조 주입 (에디터에서 미할당 시)
	if game_director != null:
		if campaign_manager != null and game_director.get("campaign_manager") == null:
			game_director.set("campaign_manager", campaign_manager)
		if battle_map != null and game_director.get("battle_map") == null:
			game_director.set("battle_map", battle_map)
		if result_panel != null and game_director.get("mission_result_panel") == null:
			game_director.set("mission_result_panel", result_panel)
		if hud != null and game_director.get("battle_hud") == null:
			game_director.set("battle_hud", hud)

func _wire_hud() -> void:
	if battle_map != null and hud != null:
		var hex_grid: Node = battle_map.get_node_or_null("HexGrid")
		if hex_grid != null and hud.has_method("bind_hex_grid"):
			hud.call("bind_hex_grid", hex_grid)

func _fallback_load_battle_map() -> void:
	var path: String = "res://scenes/battle_map.tscn"
	var scn: PackedScene = load(path) as PackedScene
	if scn == null:
		push_error("[Main] fallback battle map 로드 실패: %s" % path)
		return
	var inst: Node = scn.instantiate()
	if inst == null:
		push_error("[Main] fallback battle map 인스턴스 실패")
		return
	add_child(inst)
	print("[Main] fallback battle map 로드 완료")

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_F5:
			if game_director != null and game_director.has_method("report_battle_result"):
				print("[Main] F5 — 강제 승리 보고")
				game_director.call("report_battle_result", true, {"turn_used": 5})
				get_viewport().set_input_as_handled()
		elif event.keycode == KEY_F6:
			if game_director != null and game_director.has_method("report_battle_result"):
				print("[Main] F6 — 강제 패배 보고")
				game_director.call("report_battle_result", false, {"turn_used": 8})
				get_viewport().set_input_as_handled()
