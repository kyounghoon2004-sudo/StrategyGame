extends Control
## title_screen.gd — 오대십국 전략 게임 타이틀 화면
##
## 4개 메뉴:
##   1) 새 캠페인 시작 (낙양 탈환 작전) → 메인 씬 진입
##   2) 전술 전투 연습 (BattleMap 단독) → BattleMap 단독 진입
##   3) SLM 인공지능 설정 → Ollama 호스트/모델 설정 다이얼로그
##   4) 게임 종료
##
## 백그라운드: 비네트 효과 + 천천히 움직이는 한국 왕실 패턴(코드로 합성)
## 사운드: AudioManager.connect 후 UI 호버/클릭 SFX 트리거

# ─────────────────────────────────────────────────────────────────────
# 노드 참조 — _ready 에서 캐치
# ─────────────────────────────────────────────────────────────────────
@onready var _btn_campaign: Button = $VBox/Buttons/BtnCampaign
@onready var _btn_battle: Button = $VBox/Buttons/BtnBattle
@onready var _btn_slm: Button = $VBox/Buttons/BtnSLM
@onready var _btn_quit: Button = $VBox/Buttons/BtnQuit
@onready var _slm_panel: Control = $SLMPanel
@onready var _slm_url_edit: LineEdit = $SLMPanel/Panel/Margin/VBox/Row1/UrlEdit
@onready var _slm_model_edit: LineEdit = $SLMPanel/Panel/Margin/VBox/Row2/ModelEdit
@onready var _slm_status: Label = $SLMPanel/Panel/Margin/VBox/StatusLabel
@onready var _slm_save_btn: Button = $SLMPanel/Panel/Margin/VBox/ButtonsRow/SaveBtn
@onready var _slm_cancel_btn: Button = $SLMPanel/Panel/Margin/VBox/ButtonsRow/CancelBtn
@onready var _version_label: Label = $VBox/VersionLabel

const AISSetupPanelScript = preload("res://scripts/ai/ai_setup_panel.gd")
const AIBackendCfgScript = preload("res://scripts/ai/ai_backend_config.gd")
# DEV MAP COLLECTION (additive): a DEV-only window listing non-production map
# sets (today: the 10 RL battlefields). Existing entries are untouched.
const DevMapCollectionScript = preload("res://scripts/ui/dev_map_collection_panel.gd")
const BattlefieldCatalogScript = preload("res://scripts/battlefields/battlefield_catalog.gd")
var _map_collection: Control = null
var _ai_setup: AISSetupPanel = null
var _utility_selector: Control = null
var _utility_difficulty := "V0"

# STEP 1 sandbox DEV entry (additive; production buttons untouched).
const CLOUD1_SANDBOX_SCENE := "res://scenes/cloud1_battle_test.tscn"
# STEP 2 Human-vs-Cloud DEV entry (additive; production + Step-1 untouched).
const CLOUD2_HVC_SCENE := "res://scenes/cloud2_battle_test.tscn"
const LOCAL_HVL_SCENE := "res://scenes/local_brain_battle_test.tscn"
# OPENJEV Human-vs-OpenJEV DEV entry (additive; production + Cloud untouched).
const OPENJEV_HVC_SCENE := "res://scenes/openjev_battle_test.tscn"
# LAYA Human-vs-Laya DEV entry (additive; production + Cloud + OpenJev untouched).
const LAYA_HVC_SCENE := "res://scenes/laya_battle_test.tscn"
# SYMMETRIC V1 Local-vs-Local DEV entry (additive; everything else untouched).
const SYMLOC_SCENE := "res://scenes/symloc_battle_test.tscn"
const UTILITY_HVC_SCENE := "res://scenes/utility_bot_battle_test.tscn"
const BRAIN_UTILITY_SCENE := "res://scenes/brain_utility_battle_test.tscn"


# ─────────────────────────────────────────────────────────────────────
# 라이프사이클
# ─────────────────────────────────────────────────────────────────────
func _ready() -> void:
	print("[TitleScreen] 타이틀 화면 진입")
	# 버튼 연결
	_btn_campaign.pressed.connect(_on_campaign_pressed)
	_btn_battle.pressed.connect(_on_battle_pressed)
	_btn_slm.pressed.connect(_on_slm_pressed)
	_btn_quit.pressed.connect(_on_quit_pressed)
	# SLM 패널
	_slm_save_btn.pressed.connect(_on_slm_save_pressed)
	_slm_cancel_btn.pressed.connect(_on_slm_cancel_pressed)
	_slm_panel.visible = false
	# Manual-backend milestone: restore last safe endpoint/model/backend
	# into the runtime authority (key is never restored). Then the AI
	# setup panel only collects settings — no auto-start, no warmup,
	# no verification — and enters battle.
	AIBackendCfgScript.ensure_boot_runtime()
	_ai_setup = AISSetupPanelScript.new()
	_ai_setup.name = "AISetupPanel"
	add_child(_ai_setup)
	_ai_setup.launch_started.connect(_on_ai_launch_started)
	_ai_setup.panel_closed.connect(_on_ai_panel_closed)
	# 호버 사운드 — 마우스 들어올 때마다 가벼운 효과음
	for btn in [_btn_campaign, _btn_battle, _btn_slm, _btn_quit, _slm_save_btn, _slm_cancel_btn]:
		btn.mouse_entered.connect(_on_btn_hover)
	# SYMMETRIC V1: the DEV / RESEARCH section exposes EXACTLY two battle
	# entries. Cloud1/OpenJEV/Laya builders below are retained (scenes,
	# scripts, and loaders untouched) but no longer added to the menu.
	_add_dev_section_header()
	_add_cloud2_dev_entry()
	_add_watch_dev_entry()
	_add_local_brain_dev_entry()
	_add_symloc_dev_entry()
	_add_utility_bot_dev_entries()
	_build_utility_selector()
	_add_map_collection_dev_entry()
	# 버전 라벨
	_version_label.text = "오대십국 전략 v%s  ·  Sprint 4 — Polish & Release" % _get_version()
	# 시작 시 1회: 궁중 징 한 번 (분위기)
	var am: Node = get_node_or_null("/root/AudioManager")
	if am != null:
		# 타이틀 입장 시 가벼운 징 한 번
		am.call("play_sfx", "decree_gong")


func _get_version() -> String:
	return "0.4.0"


# ─────────────────────────────────────────────────────────────────────
# 메뉴 핸들러
# ─────────────────────────────────────────────────────────────────────
func _on_campaign_pressed() -> void:
	_click()
	print("[TitleScreen] 새 캠페인 시작 — main.tscn 로드")
	var am: Node = get_node_or_null("/root/AudioManager")
	if am != null:
		am.call("play_sfx", "decree_gong")
	# 씬 전환
	get_tree().change_scene_to_file("res://scenes/main.tscn")


func _on_battle_pressed() -> void:
	_click()
	# Canonical flow: GAME START → AI SETTINGS → canonical Step2R shell.
	# battle_map.tscn is the legacy scene (no Step7 Advisor); do NOT load it.
	print("[TitleScreen] 출정 — AI 설정 패널 경유, Step2R 셸로 진입")
	if _ai_setup != null:
		_ai_setup.open()
		return
	get_tree().change_scene_to_file("res://scenes/step2r_battlefield_shell.tscn")


# CLOUD1-DEV-ENTRY-BEGIN
# STEP 1 sandbox DEV entry (additive, runtime-built so the .tscn is untouched).
# A visually distinct DEV / RESEARCH section with one button that loads the
# existing Step 1 sandbox scene through the same change_scene_to_file
# mechanism as the production buttons. No Cloud/Qwen/RL calls here.
func _add_dev_section_header() -> void:
	var buttons_box: VBoxContainer = $VBox/Buttons
	var sep := HSeparator.new()
	sep.name = "DevSep"
	buttons_box.add_child(sep)
	var dev_label := Label.new()
	dev_label.name = "DevSectionLabel"
	dev_label.text = "DEV / RESEARCH"
	dev_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	dev_label.add_theme_font_size_override("font_size", 14)
	dev_label.add_theme_color_override("font_color", Color(0.55, 0.85, 1.0))
	buttons_box.add_child(dev_label)


# SYMMETRIC V1: hidden from the menu (not called). Scene, script, and
# loader are retained untouched for research reversibility.
func _add_cloud1_dev_entry() -> void:
	var buttons_box: VBoxContainer = $VBox/Buttons
	var dev_btn := Button.new()
	dev_btn.name = "BtnCloud1Sandbox"
	dev_btn.text = "DEV: Cloud General Sandbox"
	dev_btn.tooltip_text = "Developer sandbox: Step 1 shared tactical interface (no Cloud/AI calls)"
	dev_btn.custom_minimum_size = Vector2(440, 50)
	dev_btn.add_theme_font_size_override("font_size", 18)
	dev_btn.add_theme_color_override("font_color", Color(0.55, 0.9, 1.0))
	dev_btn.add_theme_color_override("font_hover_color", Color(0.85, 1.0, 1.0))
	var dev_normal := StyleBoxFlat.new()
	dev_normal.bg_color = Color(0.05, 0.12, 0.16, 0.95)
	dev_normal.border_width_left = 2
	dev_normal.border_width_top = 2
	dev_normal.border_width_right = 2
	dev_normal.border_width_bottom = 2
	dev_normal.border_color = Color(0.35, 0.75, 1.0, 0.9)
	dev_normal.corner_radius_top_left = 4
	dev_normal.corner_radius_top_right = 4
	dev_normal.corner_radius_bottom_right = 4
	dev_normal.corner_radius_bottom_left = 4
	dev_btn.add_theme_stylebox_override("normal", dev_normal)
	var dev_hover := dev_normal.duplicate() as StyleBoxFlat
	dev_hover.bg_color = Color(0.09, 0.2, 0.26, 0.98)
	dev_hover.border_color = Color(0.6, 0.95, 1.0, 1.0)
	dev_btn.add_theme_stylebox_override("hover", dev_hover)
	dev_btn.add_theme_stylebox_override("pressed", dev_hover)
	dev_btn.add_theme_stylebox_override("focus", dev_hover)
	buttons_box.add_child(dev_btn)
	dev_btn.pressed.connect(_on_cloud1_sandbox_pressed)
	dev_btn.mouse_entered.connect(_on_btn_hover)


func _on_cloud1_sandbox_pressed() -> void:
	_click()
	print("[TitleScreen] DEV sandbox — cloud1_battle_test.tscn load")
	get_tree().change_scene_to_file(CLOUD1_SANDBOX_SCENE)
# CLOUD1-DEV-ENTRY-END

# CLOUD2-DEV-ENTRY-BEGIN
# STEP 2 Human-vs-Cloud DEV entry (additive, runtime-built so the .tscn is
# untouched — same mechanism as the Step-1 entry). Loads the Step-2 scene
# where BLUE is human-driven and RED is driven by a Cloud model through the
# shared operational command contract. No model calls happen here.
func _add_cloud2_dev_entry() -> void:
	var buttons_box: VBoxContainer = $VBox/Buttons
	var hvc_btn := Button.new()
	hvc_btn.name = "BtnCloud2HumanVsCloud"
	hvc_btn.text = "DEV: Human vs Cloud General"
	hvc_btn.tooltip_text = "CLOUD FULL PIPELINE V0: human BLUE vs RED = local Qwen3-8B CSFT5 Brain (unalloc_v1) -> frozen Hand A -> frozen Hand B -> Godot (all models start automatically)"
	hvc_btn.custom_minimum_size = Vector2(440, 50)
	hvc_btn.add_theme_font_size_override("font_size", 18)
	hvc_btn.add_theme_color_override("font_color", Color(1.0, 0.72, 0.62))
	hvc_btn.add_theme_color_override("font_hover_color", Color(1.0, 0.9, 0.85))
	var hvc_normal := StyleBoxFlat.new()
	hvc_normal.bg_color = Color(0.16, 0.07, 0.06, 0.95)
	hvc_normal.border_width_left = 2
	hvc_normal.border_width_top = 2
	hvc_normal.border_width_right = 2
	hvc_normal.border_width_bottom = 2
	hvc_normal.border_color = Color(1.0, 0.45, 0.35, 0.9)
	hvc_normal.corner_radius_top_left = 4
	hvc_normal.corner_radius_top_right = 4
	hvc_normal.corner_radius_bottom_right = 4
	hvc_normal.corner_radius_bottom_left = 4
	hvc_btn.add_theme_stylebox_override("normal", hvc_normal)
	var hvc_hover := hvc_normal.duplicate() as StyleBoxFlat
	hvc_hover.bg_color = Color(0.26, 0.11, 0.09, 0.98)
	hvc_hover.border_color = Color(1.0, 0.65, 0.5, 1.0)
	hvc_btn.add_theme_stylebox_override("hover", hvc_hover)
	hvc_btn.add_theme_stylebox_override("pressed", hvc_hover)
	hvc_btn.add_theme_stylebox_override("focus", hvc_hover)
	buttons_box.add_child(hvc_btn)
	hvc_btn.pressed.connect(_on_cloud2_hvc_pressed)
	hvc_btn.mouse_entered.connect(_on_btn_hover)


func _on_cloud2_hvc_pressed() -> void:
	_click()
	print("[TitleScreen] DEV human-vs-cloud — cloud2_battle_test.tscn load")
	get_tree().change_scene_to_file(CLOUD2_HVC_SCENE)
# CLOUD2-DEV-ENTRY-END

# WATCH-DEV-ENTRY-BEGIN
# DEV inspection: LLM (S0B + context pack -> frozen Hand A/B) RED vs generalized GX Utility BLUE, fully automatic.
const WatchCls = preload("res://scripts/cloud_pipeline/watch_llm_vs_utility.gd")


func _add_watch_dev_entry() -> void:
	var btn := Button.new()
	btn.name = "BtnWatchLlmVsUtility"
	btn.text = "DEV: Watch LLM vs Utility"
	btn.tooltip_text = "Autonomous live battle: RED = S0B Brain (context pack ON) -> frozen Hand A -> frozen Hand B; BLUE = GX Utility. Keys: N next, R replay, 1/2/3 tier, S style, Esc title."
	btn.custom_minimum_size = Vector2(440, 50)
	btn.add_theme_font_size_override("font_size", 18)
	btn.add_theme_color_override("font_color", Color(0.72, 0.9, 1.0))
	btn.add_theme_color_override("font_hover_color", Color(0.9, 0.97, 1.0))
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.05, 0.1, 0.16, 0.95)
	normal.set_border_width_all(2)
	normal.border_color = Color(0.4, 0.7, 1.0, 0.9)
	normal.set_corner_radius_all(4)
	btn.add_theme_stylebox_override("normal", normal)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.08, 0.16, 0.26, 0.98)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("pressed", hover)
	btn.add_theme_stylebox_override("focus", hover)
	$VBox/Buttons.add_child(btn)
	btn.pressed.connect(_on_watch_pressed)
	btn.mouse_entered.connect(_on_btn_hover)


func _on_watch_pressed() -> void:
	_click()
	print("[TitleScreen] DEV watch LLM vs Utility")
	WatchCls.start_match(get_tree(), "mild", 1, "INTER", "BULWARK")
# WATCH-DEV-ENTRY-END

# LOCALBRAIN-DEV-ENTRY-BEGIN
# DEV Human-vs-Local entry: human BLUE vs the local Qwen3-8B Contract-SFT
# Brain (CSFT5) as RED General. The scene starts/owns the local Brain
# server itself; no cloud settings, key, or provider panel needed.
func _add_local_brain_dev_entry() -> void:
	var buttons_box: VBoxContainer = $VBox/Buttons
	var hvl_btn := Button.new()
	hvl_btn.name = "BtnLocalBrainHumanVsLocal"
	hvl_btn.text = "DEV: Human vs Local (Qwen 8B)"
	hvl_btn.tooltip_text = "Developer research: human BLUE vs local Qwen3-8B CSFT5 RED General (starts the local Brain automatically; strict: no repair/retry/fallback)"
	hvl_btn.custom_minimum_size = Vector2(440, 50)
	hvl_btn.add_theme_font_size_override("font_size", 18)
	hvl_btn.add_theme_color_override("font_color", Color(0.62, 0.95, 0.72))
	hvl_btn.add_theme_color_override("font_hover_color", Color(0.85, 1.0, 0.9))
	var hvl_normal := StyleBoxFlat.new()
	hvl_normal.bg_color = Color(0.05, 0.14, 0.08, 0.95)
	hvl_normal.border_width_left = 2
	hvl_normal.border_width_top = 2
	hvl_normal.border_width_right = 2
	hvl_normal.border_width_bottom = 2
	hvl_normal.border_color = Color(0.35, 0.95, 0.55, 0.9)
	hvl_normal.corner_radius_top_left = 4
	hvl_normal.corner_radius_top_right = 4
	hvl_normal.corner_radius_bottom_right = 4
	hvl_normal.corner_radius_bottom_left = 4
	hvl_btn.add_theme_stylebox_override("normal", hvl_normal)
	var hvl_hover := hvl_normal.duplicate() as StyleBoxFlat
	hvl_hover.bg_color = Color(0.08, 0.24, 0.12, 0.98)
	hvl_hover.border_color = Color(0.55, 1.0, 0.7, 1.0)
	hvl_btn.add_theme_stylebox_override("hover", hvl_hover)
	hvl_btn.add_theme_stylebox_override("pressed", hvl_hover)
	hvl_btn.add_theme_stylebox_override("focus", hvl_hover)
	buttons_box.add_child(hvl_btn)
	hvl_btn.pressed.connect(_on_local_brain_hvl_pressed)
	hvl_btn.mouse_entered.connect(_on_btn_hover)


func _on_local_brain_hvl_pressed() -> void:
	_click()
	print("[TitleScreen] DEV human-vs-local (Qwen 8B CSFT5) — local_brain_battle_test.tscn load")
	get_tree().change_scene_to_file(LOCAL_HVL_SCENE)
# LOCALBRAIN-DEV-ENTRY-END


# OPENJEV-DEV-ENTRY-BEGIN
# Human-vs-OpenJEV DEV entry (additive, runtime-built so the .tscn is
# untouched — same mechanism as the Cloud entries). Loads the OpenJev scene
# where BLUE is human-driven and RED is driven by the local frozen OpenJev
# model through direct legal-action scoring. No model calls happen here.
# SYMMETRIC V1: hidden from the menu (not called). Scene, script, and
# loader are retained untouched for research reversibility.
func _add_openjev_dev_entry() -> void:
	var buttons_box: VBoxContainer = $VBox/Buttons
	var oj_btn := Button.new()
	oj_btn.name = "BtnOpenJevHumanVsOpenJev"
	oj_btn.text = "DEV: Human vs OpenJEV"
	oj_btn.tooltip_text = "Human BLUE vs local OpenJev RED (model auto-starts, no setup needed)"
	oj_btn.custom_minimum_size = Vector2(440, 50)
	oj_btn.add_theme_font_size_override("font_size", 18)
	oj_btn.add_theme_color_override("font_color", Color(0.55, 1.0, 0.80))
	oj_btn.add_theme_color_override("font_hover_color", Color(0.85, 1.0, 0.90))
	var oj_normal := StyleBoxFlat.new()
	oj_normal.bg_color = Color(0.05, 0.14, 0.10, 0.95)
	oj_normal.border_width_left = 2
	oj_normal.border_width_top = 2
	oj_normal.border_width_right = 2
	oj_normal.border_width_bottom = 2
	oj_normal.border_color = Color(0.30, 0.85, 0.60, 0.9)
	oj_normal.corner_radius_top_left = 4
	oj_normal.corner_radius_top_right = 4
	oj_normal.corner_radius_bottom_right = 4
	oj_normal.corner_radius_bottom_left = 4
	oj_btn.add_theme_stylebox_override("normal", oj_normal)
	var oj_hover := oj_normal.duplicate() as StyleBoxFlat
	oj_hover.bg_color = Color(0.08, 0.22, 0.15, 0.98)
	oj_hover.border_color = Color(0.50, 1.0, 0.70, 1.0)
	oj_btn.add_theme_stylebox_override("hover", oj_hover)
	oj_btn.add_theme_stylebox_override("pressed", oj_hover)
	oj_btn.add_theme_stylebox_override("focus", oj_hover)
	buttons_box.add_child(oj_btn)
	oj_btn.pressed.connect(_on_openjev_hvc_pressed)
	oj_btn.mouse_entered.connect(_on_btn_hover)


func _on_openjev_hvc_pressed() -> void:
	_click()
	print("[TitleScreen] DEV human-vs-openjev — openjev_battle_test.tscn load")
	get_tree().change_scene_to_file(OPENJEV_HVC_SCENE)
# OPENJEV-DEV-ENTRY-END


# LAYA-DEV-ENTRY-BEGIN
# Human-vs-Laya DEV entry (additive, runtime-built so the .tscn is
# untouched — same mechanism as the Cloud/OpenJev entries). Loads the Laya
# scene where BLUE is human-driven and RED is driven by the local frozen
# Laya model through per-unit sequential legal-action choice. No model
# calls happen here.
# SYMMETRIC V1: hidden from the menu (not called). Scene, script, and
# loader are retained untouched for research reversibility.
func _add_laya_dev_entry() -> void:
	var buttons_box: VBoxContainer = $VBox/Buttons
	var ly_btn := Button.new()
	ly_btn.name = "BtnLayaHumanVsLaya"
	ly_btn.text = "DEV: Human vs Laya"
	ly_btn.tooltip_text = "Human BLUE vs local Laya RED (model auto-starts, no setup needed)"
	ly_btn.custom_minimum_size = Vector2(440, 50)
	ly_btn.add_theme_font_size_override("font_size", 18)
	ly_btn.add_theme_color_override("font_color", Color(0.75, 0.70, 1.0))
	ly_btn.add_theme_color_override("font_hover_color", Color(0.90, 0.87, 1.0))
	var ly_normal := StyleBoxFlat.new()
	ly_normal.bg_color = Color(0.10, 0.06, 0.18, 0.95)
	ly_normal.border_width_left = 2
	ly_normal.border_width_top = 2
	ly_normal.border_width_right = 2
	ly_normal.border_width_bottom = 2
	ly_normal.border_color = Color(0.55, 0.45, 0.95, 0.9)
	ly_normal.corner_radius_top_left = 4
	ly_normal.corner_radius_top_right = 4
	ly_normal.corner_radius_bottom_right = 4
	ly_normal.corner_radius_bottom_left = 4
	ly_btn.add_theme_stylebox_override("normal", ly_normal)
	var ly_hover := ly_normal.duplicate() as StyleBoxFlat
	ly_hover.bg_color = Color(0.16, 0.10, 0.30, 0.98)
	ly_hover.border_color = Color(0.75, 0.68, 1.0, 1.0)
	ly_btn.add_theme_stylebox_override("hover", ly_hover)
	ly_btn.add_theme_stylebox_override("pressed", ly_hover)
	ly_btn.add_theme_stylebox_override("focus", ly_hover)
	buttons_box.add_child(ly_btn)
	ly_btn.pressed.connect(_on_laya_hvc_pressed)
	ly_btn.mouse_entered.connect(_on_btn_hover)


func _on_laya_hvc_pressed() -> void:
	_click()
	print("[TitleScreen] DEV human-vs-laya — laya_battle_test.tscn load")
	get_tree().change_scene_to_file(LAYA_HVC_SCENE)
# LAYA-DEV-ENTRY-END


# SYMLOC-DEV-ENTRY-BEGIN
# SYMMETRIC V1 Local-vs-Local DEV entry (additive, runtime-built so the
# .tscn is untouched — same mechanism as the other DEV entries). Loads
# the symmetric sandbox where LOCAL Brain + Laya RED plays LOCAL Brain +
# Laya BLUE autonomously. No model calls happen here.
func _add_symloc_dev_entry() -> void:
	var buttons_box: VBoxContainer = $VBox/Buttons
	var sl_btn := Button.new()
	sl_btn.name = "BtnSymLocLocalVsLocal"
	sl_btn.text = "DEV: Local vs Local"
	sl_btn.tooltip_text = "Symmetric sandbox: local Brain + Laya RED vs local Brain + Laya BLUE (autonomous)"
	sl_btn.custom_minimum_size = Vector2(440, 50)
	sl_btn.add_theme_font_size_override("font_size", 18)
	sl_btn.add_theme_color_override("font_color", Color(0.62, 0.88, 1.0))
	sl_btn.add_theme_color_override("font_hover_color", Color(0.88, 1.0, 1.0))
	var sl_normal := StyleBoxFlat.new()
	sl_normal.bg_color = Color(0.06, 0.11, 0.17, 0.95)
	sl_normal.border_width_left = 2
	sl_normal.border_width_top = 2
	sl_normal.border_width_right = 2
	sl_normal.border_width_bottom = 2
	sl_normal.border_color = Color(0.40, 0.72, 1.0, 0.9)
	sl_normal.corner_radius_top_left = 4
	sl_normal.corner_radius_top_right = 4
	sl_normal.corner_radius_bottom_right = 4
	sl_normal.corner_radius_bottom_left = 4
	sl_btn.add_theme_stylebox_override("normal", sl_normal)
	var sl_hover := sl_normal.duplicate() as StyleBoxFlat
	sl_hover.bg_color = Color(0.10, 0.19, 0.28, 0.98)
	sl_hover.border_color = Color(0.65, 0.92, 1.0, 1.0)
	sl_btn.add_theme_stylebox_override("hover", sl_hover)
	sl_btn.add_theme_stylebox_override("pressed", sl_hover)
	sl_btn.add_theme_stylebox_override("focus", sl_hover)
	buttons_box.add_child(sl_btn)
	sl_btn.pressed.connect(_on_symloc_pressed)
	sl_btn.mouse_entered.connect(_on_btn_hover)


# MAP-COLLECTION-DEV-ENTRY-BEGIN
# DEV map collection (additive, runtime-built). Every title entry clears a
# map picked earlier in the window, so the production battle button and the
# other DEV entries keep the default map.
func _add_map_collection_dev_entry() -> void:
	BattlefieldCatalogScript.pending_id = ""
	var buttons_box: VBoxContainer = $VBox/Buttons
	var mc_btn := Button.new()
	mc_btn.name = "BtnDevMapCollection"
	mc_btn.text = "DEV: 맵 모음 (Map Collection)"
	mc_btn.tooltip_text = "RL battlefield set (10 maps) and future non-production maps"
	mc_btn.custom_minimum_size = Vector2(440, 50)
	mc_btn.add_theme_font_size_override("font_size", 18)
	mc_btn.add_theme_color_override("font_color", Color(0.62, 0.88, 1.0))
	mc_btn.add_theme_color_override("font_hover_color", Color(0.88, 1.0, 1.0))
	var mc_normal := StyleBoxFlat.new()
	mc_normal.bg_color = Color(0.06, 0.11, 0.17, 0.95)
	mc_normal.border_width_left = 2
	mc_normal.border_width_top = 2
	mc_normal.border_width_right = 2
	mc_normal.border_width_bottom = 2
	mc_normal.border_color = Color(0.40, 0.72, 1.0, 0.9)
	mc_normal.corner_radius_top_left = 4
	mc_normal.corner_radius_top_right = 4
	mc_normal.corner_radius_bottom_right = 4
	mc_normal.corner_radius_bottom_left = 4
	mc_btn.add_theme_stylebox_override("normal", mc_normal)
	var mc_hover := mc_normal.duplicate() as StyleBoxFlat
	mc_hover.bg_color = Color(0.10, 0.19, 0.28, 0.98)
	mc_hover.border_color = Color(0.65, 0.92, 1.0, 1.0)
	mc_btn.add_theme_stylebox_override("hover", mc_hover)
	mc_btn.add_theme_stylebox_override("pressed", mc_hover)
	mc_btn.add_theme_stylebox_override("focus", mc_hover)
	buttons_box.add_child(mc_btn)
	_map_collection = DevMapCollectionScript.new()
	add_child(_map_collection)
	mc_btn.pressed.connect(_on_map_collection_pressed)
	mc_btn.mouse_entered.connect(_on_btn_hover)


func _on_map_collection_pressed() -> void:
	_click()
	print("[TitleScreen] DEV map collection window")
	_map_collection.call("open")
# MAP-COLLECTION-DEV-ENTRY-END


func _on_symloc_pressed() -> void:
	_click()
	print("[TitleScreen] DEV local-vs-local — symloc_battle_test.tscn load")
	get_tree().change_scene_to_file(SYMLOC_SCENE)
# SYMLOC-DEV-ENTRY-END


func _add_utility_bot_dev_entries() -> void:
	var buttons_box: VBoxContainer = $VBox/Buttons
	for spec in [
		{"name": "BtnHumanVsUtilityBot", "text": "DEV: Human vs Utility Bot", "target": UTILITY_HVC_SCENE},
		{"name": "BtnBrainVsUtilityBot", "text": "DEV: Brain BLUE vs Utility Bot RED", "target": BRAIN_UTILITY_SCENE},
	]:
		var btn := Button.new()
		btn.name = str(spec["name"])
		btn.text = str(spec["text"])
		btn.tooltip_text = "Plain dev battlefield: same map and roster; seeded Utility Bot controls RED."
		btn.custom_minimum_size = Vector2(440, 50)
		btn.add_theme_font_size_override("font_size", 18)
		btn.add_theme_color_override("font_color", Color(0.76, 0.94, 0.84))
		btn.add_theme_color_override("font_hover_color", Color(0.90, 1.0, 0.94))
		var normal := StyleBoxFlat.new()
		normal.bg_color = Color(0.05, 0.14, 0.10, 0.95)
		normal.border_width_left = 2
		normal.border_width_top = 2
		normal.border_width_right = 2
		normal.border_width_bottom = 2
		normal.border_color = Color(0.30, 0.78, 0.55, 0.9)
		normal.corner_radius_top_left = 4
		normal.corner_radius_top_right = 4
		normal.corner_radius_bottom_right = 4
		normal.corner_radius_bottom_left = 4
		btn.add_theme_stylebox_override("normal", normal)
		var hover := normal.duplicate() as StyleBoxFlat
		hover.bg_color = Color(0.08, 0.22, 0.15, 0.98)
		hover.border_color = Color(0.50, 1.0, 0.70, 1.0)
		btn.add_theme_stylebox_override("hover", hover)
		btn.add_theme_stylebox_override("pressed", hover)
		btn.add_theme_stylebox_override("focus", hover)
		buttons_box.add_child(btn)
		var scene_path := str(spec["target"])
		btn.pressed.connect(func() -> void:
			_click()
			if scene_path == UTILITY_HVC_SCENE:
				_utility_difficulty = "V0"
				_refresh_utility_selector()
				_utility_selector.show()
			else:
				print("[TitleScreen] dev utility matchup load: " + scene_path)
				get_tree().change_scene_to_file(scene_path))
		btn.mouse_entered.connect(_on_btn_hover)


func _build_utility_selector() -> void:
	_utility_selector = Control.new()
	_utility_selector.name = "UtilityDifficultySelector"
	_utility_selector.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_utility_selector.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_utility_selector)
	var shade := ColorRect.new()
	shade.name = "Shade"
	shade.color = Color(0.0, 0.02, 0.04, 0.82)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_utility_selector.add_child(shade)
	var center := CenterContainer.new()
	center.name = "CenterContainer"
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_utility_selector.add_child(center)
	var panel := PanelContainer.new()
	panel.name = "DifficultyPanel"
	panel.custom_minimum_size = Vector2(420, 360)
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.name = "Choices"
	box.add_theme_constant_override("separation", 12)
	panel.add_child(box)
	var heading := Label.new()
	heading.name = "Heading"
	heading.text = "UTILITY BOT DIFFICULTY"
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(heading)
	for tier in ["V0", "V1", "V2"]:
		var option := Button.new()
		option.name = tier + "Option"
		option.custom_minimum_size = Vector2(380, 56)
		box.add_child(option)
		option.pressed.connect(func() -> void:
			_utility_difficulty = tier
			_refresh_utility_selector())
	var start := Button.new()
	start.name = "StartBattle"
	start.text = "START BATTLE"
	start.custom_minimum_size = Vector2(380, 56)
	box.add_child(start)
	start.pressed.connect(func() -> void:
		get_tree().root.set_meta("utility_bot_dev_difficulty", _utility_difficulty)
		print("[TitleScreen] dev utility battle difficulty=" + _utility_difficulty)
		get_tree().change_scene_to_file(UTILITY_HVC_SCENE))
	var back := Button.new()
	back.name = "Back"
	back.text = "BACK"
	box.add_child(back)
	back.pressed.connect(func() -> void: _utility_selector.hide())
	_utility_selector.hide()
	_refresh_utility_selector()


func _refresh_utility_selector() -> void:
	if _utility_selector == null:
		return
	var box := _utility_selector.get_node("CenterContainer/DifficultyPanel/Choices")
	(box.get_node("V0Option") as Button).text = ("● " if _utility_difficulty == "V0" else "○ ") + "[ V0 — NOVICE ]"
	(box.get_node("V1Option") as Button).text = ("● " if _utility_difficulty == "V1" else "○ ") + "[ V1 — INTERMEDIATE ]"
	(box.get_node("V2Option") as Button).text = ("● " if _utility_difficulty == "V2" else "○ ") + "[ V2 — ADVANCED ]"


func _on_slm_pressed() -> void:
	_click()
	# Preferred path: game-owned AI setup (auto start/warmup, one-button game start).
	if _ai_setup != null:
		_ai_setup.open()
		return
	# Legacy fallback (panel construction failed): old manual host/model dialog.
	var defaults: Dictionary = _load_slm_settings()
	_slm_url_edit.text = defaults.get("url", "http://127.0.0.1:11434")
	_slm_model_edit.text = defaults.get("model", "qwen38-jrell-mtp-256k:latest")
	_slm_status.text = ""
	_slm_panel.visible = true


func _on_ai_launch_started(_ai_enabled: bool) -> void:
	_click()


func _on_ai_panel_closed() -> void:
	_click()


func _on_quit_pressed() -> void:
	_click()
	print("[TitleScreen] 게임 종료")
	get_tree().quit()


# ─────────────────────────────────────────────────────────────────────
# SLM 다이얼로그
# ─────────────────────────────────────────────────────────────────────
func _on_slm_save_pressed() -> void:
	_click()
	var url: String = _slm_url_edit.text.strip_edges()
	var model: String = _slm_model_edit.text.strip_edges()
	if url == "" or model == "":
		_slm_status.text = "URL 과 모델을 모두 입력하세요"
		_slm_status.add_theme_color_override("font_color", Color(1, 0.5, 0.4))
		return
	_save_slm_settings(url, model)
	_slm_status.text = "저장 완료: %s (%s)" % [url, model]
	_slm_status.add_theme_color_override("font_color", Color(0.6, 1, 0.6))
	# 0.8 초 후 패널 닫기
	await get_tree().create_timer(0.8).timeout
	_slm_panel.visible = false


func _on_slm_cancel_pressed() -> void:
	_click()
	_slm_panel.visible = false


func _load_slm_settings() -> Dictionary:
	var path: String = "user://slm_settings.cfg"
	var cfg: ConfigFile = ConfigFile.new()
	if cfg.load(path) == OK:
		return {
			"url": cfg.get_value("slm", "url", "http://127.0.0.1:11434"),
			"model": cfg.get_value("slm", "model", "qwen38-jrell-mtp-256k:latest"),
		}
	return {"url": "http://127.0.0.1:11434", "model": "qwen38-jrell-mtp-256k:latest"}


func _save_slm_settings(url: String, model: String) -> void:
	var path: String = "user://slm_settings.cfg"
	var cfg: ConfigFile = ConfigFile.new()
	cfg.set_value("slm", "url", url)
	cfg.set_value("slm", "model", model)
	cfg.save(path)
	print("[TitleScreen] SLM 설정 저장: %s / %s" % [url, model])


# ─────────────────────────────────────────────────────────────────────
# 사운드 헬퍼
# ─────────────────────────────────────────────────────────────────────
func _click() -> void:
	var am: Node = get_node_or_null("/root/AudioManager")
	if am != null:
		am.call("play_sfx", "ui_select")


func _on_btn_hover() -> void:
	var am: Node = get_node_or_null("/root/AudioManager")
	if am != null:
		am.call("play_sfx", "ui_hover")


# ─────────────────────────────────────────────────────────────────────
# 입력 — ESC 로 SLM 패널 닫기
# ─────────────────────────────────────────────────────────────────────
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if _slm_panel.visible:
			_slm_panel.visible = false
			get_viewport().set_input_as_handled()
			return
		if _ai_setup != null and _ai_setup.visible:
			if not _ai_setup.is_preparing():
				_ai_setup.close()
				get_viewport().set_input_as_handled()
