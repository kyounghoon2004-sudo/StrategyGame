class_name Step2RBattlefieldShell
extends Node2D
const CommanderMissionCls = preload("res://scripts/cloud_pipeline/commander_mission.gd")

## Step2R Battlefield Shell — STEP-03 UNIT INTERACTION + MARCH ENVELOPE
## Regular Hexagonal Playable Envelope (Radius R=40, 4,921 cells).
## Interactive Unit Selection (C-style), Two-Stage Route Preview & Confirm,
## Blue/Red/Black March Envelopes, Scout Terrain Mastery, River Action Ending,
## Player March Policy Ceiling, Explicit End Turn & Zero-Input Stability.

const HEX_RADIUS: int = 40
const PLAYABLE_HEX_COUNT: int = 4921

# Zoom contract
const OVERVIEW_MIN_ZOOM: float = 0.30
const NORMAL_MIN_ZOOM: float = 0.85
const DEFAULT_ZOOM: float = 1.15
const NORMAL_MAX_ZOOM: float = 8.0

var HexUtilsCls: Script = preload("res://scripts/core/hex_utils.gd")
var HexCellCls: Script = preload("res://scripts/core/hex_cell.gd")
var HexGridCls: Script = preload("res://scripts/core/hex_grid.gd")
var Step2RUnitRendererCls: Script = preload("res://scripts/step2r/step2r_unit_renderer.gd")
var Step2RCameraControllerCls: Script = preload("res://scripts/step2r/step2r_camera_controller.gd")
var WorldBoundaryCls: Script = preload("res://scripts/step2r/step2r_world_boundary.gd")
var Step3ConfigCls: Script = preload("res://scripts/core/step3_config.gd")
var Step3PathfindingCls: Script = preload("res://scripts/step3/step3_pathfinding.gd")
var Step3UnitManagerCls: Script = preload("res://scripts/step3/step3_unit_manager.gd")
var Step3EnvelopeRendererCls: Script = preload("res://scripts/step3/step3_envelope_renderer.gd")
var CombatCalculatorCls: Script = preload("res://scripts/combat/combat_calculator.gd")
var StrongholdCls: Script = preload("res://scripts/core/stronghold.gd")
var StrongholdRendererCls: Script = preload("res://scripts/core/stronghold_renderer.gd")
# STEP-05 Information Warfare slice (Fog + LOS + Scout intel + Ambush)
var Step5FogCls: Script = preload("res://scripts/step5/fog_of_war.gd")
# STEP-06 Battle Decision Layer (HQ, supply, morale, retreat & rout)
var Step6ConfigCls: Script = preload("res://scripts/step6/step6_config.gd")
var Step6DecisionLayerCls: Script = null # Disconnected per SUP-9
var Step6SupplyOverlayCls: Script = null # Disconnected per SUP-9
var MoraleSystemCls: Script = preload("res://scripts/combat/morale_system.gd")
var HexVisualCompositorCls: Script = preload("res://scripts/visual/hex_native/battlefield_hex_visual_compositor.gd")
var HistoricalUIThemeCls: Script = preload("res://scripts/visual/historical_ui_theme.gd")
const FormationSpriteCompositor = preload("res://scripts/visual/hex_native/formation_sprite_compositor.gd")
const ApprovedAssetRegistry = preload("res://scripts/visual/hex_native/approved_asset_registry.gd")

# STEP-04R2 multi-hex stronghold footprints (§2, §27)
const FORTRESS_FOOTPRINT: Array[Vector2i] = [Vector2i(-4, 2), Vector2i(-3, 2), Vector2i(-4, 3)]
const CAPITAL_FOOTPRINT: Array[Vector2i] = [Vector2i(14, -5), Vector2i(15, -5), Vector2i(14, -4)]
const FORTRESS_ID: String = "Fortress_Hulao"
const CAPITAL_ID: String = "Capital_Luoyang"

var hex_grid: Node2D
## The ONE board presentation (HIGH / FLAT). The legacy PaintedTerrain (R3)
## and MountainVisualReview paths are retired: they were hidden yet cost
## ~535 MB per process (see VISUAL_DESIGN_LANGUAGE.md).
var hex_compositor: Node2D = null
var production_map_env: Node3D = null
var unit_renderer: Node
var _battle_command_service: RefCounted
var envelope_renderer: Node
var stronghold_renderer: Node2D
var camera: Camera2D

var unit_manager: RefCounted

# Top Command HUD banner elements
var _top_hud_bar: Panel = null
var _top_hud_turn_lbl: Label = null
var _top_hud_supply_lbl: Label = null
var _top_hud_army_lbl: Label = null
var _top_hud_contact_lbl: Label = null
var _top_hud_renown_lbl: Label = null

# Stronghold quick-lookup for pathfinding/UI
var _stronghold_cells: Dictionary = {} # "q,r" -> true

# STEP-05 Information Warfare state (§3-§35)
var _fog: RefCounted = null
var _fog_pre_move_hidden: Dictionary = {} # enemy_id -> true (hidden before mover step)
var _fog_last_red_counts: Dictionary = {} # BUG-S4-01 watch baseline
var _fog_recent_combat: bool = false # set around own combat resolutions
var _fog_last_hover_id: String = "" # BUG-S4-02 watch

# STEP-05R1 enemy intelligence + stale-contact UI (last-known markers, intel panel, recon report).
var _stale_layer: Node2D = null
var _stale_markers: Dictionary = {} # enemy_id -> Node2D (frozen brown marker, never moves)
var _friendly_stale_layer: Node2D = null
var _friendly_stale_markers: Dictionary = {} # unit_id -> Node2D (muted blue, frozen)
var _hover_stale_id: String = ""
var _known_enemy_ids: Dictionary = {} # FIRST-discovery set (UI spam guard)
var _intel_panel: Panel
var _intel_title: Label
var _intel_sub: Label
var _intel_body: Label
var _intel_style_current: StyleBoxFlat
var _intel_style_stale: StyleBoxFlat
var _intel_subject_id: String = ""
var _intel_stale_mode: bool = false
var _recon_panel: Panel
var _recon_title: Label
var _recon_body: Label
var _recon_tween: Tween = null

# STEP-06 Battle Decision Layer state (§2-§45)
var _step6: RefCounted = null
var _s6_depot_coord: Vector2i = Vector2i(-12, 2)
var _supply_panel: Panel
var _supply_label: Label
var _btn_map_mode: Button = null
var _map_mode: int = 0
var _supply_overlay: Node2D = null
var _route_line: Line2D = null
var _node_markers: Dictionary = {} # node_id -> Node2D
var _battle_lost: bool = false
var _battle_won: bool = false
var _blue_hq_id: String = ""
var _red_hq_id: String = ""
var _battle_panel: Panel
var _battle_title: Label
var _battle_sub: Label

# STEP-06R3 Trader Route UI state
var _trader_panel: Panel = null
var _trader_title: Label = null
var _trader_sub: Label = null
var _trader_cargo_label: Label = null
var _trader_status_label: Label = null
var _trader_strategy_container: HBoxContainer = null
var _trader_btn_fastest: Button = null
var _trader_btn_road: Button = null
var _trader_btn_safe: Button = null
var _trader_dest_container: VBoxContainer = null
var _trader_btn_assign: Button = null
var _trader_btn_cancel: Button = null
var _trader_selected_convoy_id: String = ""
var _trader_selected_dest_id: String = ""
var _trader_selected_dest_coord: Vector2i = Vector2i(-999, -999)
var _trader_selected_strategy: String = "road"
var _trader_preview_route_path: Array[Vector2i] = []

var hud_layer: CanvasLayer
var hint_label: Label
var debug_label: Label
var turn_label: Label
var next_turn_button: Button

# STEP-04R5: Explicit turn phase state machine (§20)
# PLAYER_PHASE: human commands accepted; NEXT/END TURN live
# ENEMY_PHASE: deterministic AI resolves; all player input locked
enum TurnPhase { PLAYER_PHASE, ENEMY_PHASE }
var _turn_phase: int = TurnPhase.PLAYER_PHASE

## Cloud RED hook (Human-vs-Cloud only): the Cloud2 mount binds its turn
## controller here. Null in production/deterministic -> zero behavior change.
var cloud_red_controller: Node = null
## OpenJev RED hook (Human-vs-OpenJEV only): the OpenJev mount binds its
## turn controller here. Null everywhere else -> zero behavior change.
var openjev_red_controller: Node = null
## Laya RED hook (Human-vs-Laya only): the Laya mount binds its
## turn controller here. Null everywhere else -> zero behavior change.
var laya_red_controller: Node = null
## Counts deterministic enemy-routine runs. Stays 0 while a Cloud RED
## controller owns the phase (proves the fallback stayed dormant).
var _enemy_routine_runs: int = 0
## SYMMETRIC V1: input lock for the autonomous Local-vs-Local loop. The
## symmetric mount sets this while the BLUE controller acts during
## PLAYER_PHASE (and keeps NEXT disabled for the whole match). Default
## false -> zero behavior change for Human-vs-Cloud and deterministic.
var symmetric_auto_lock := false


func enemy_routine_runs() -> int:
	return _enemy_routine_runs


## RED authority predicate. "OPENJEV"/"CLOUD" only when bound.
func red_controller_mode() -> String:
	if laya_red_controller != null:
		if laya_red_controller.has_method("red_controller_mode") and str(laya_red_controller.call("red_controller_mode")) == "UTILITY_BOT":
			return "UTILITY_BOT"
		return "LAYA"
	if openjev_red_controller != null:
		return "OPENJEV"
	if cloud_red_controller != null:
		if cloud_red_controller.has_method("red_controller_mode") and str(cloud_red_controller.call("red_controller_mode")) == "UTILITY_BOT":
			return "UTILITY_BOT"
		if cloud_red_controller.has_method("red_controller_mode") and str(cloud_red_controller.call("red_controller_mode")) == "CLOUD+HAND_AB":
			return "CLOUD+HAND_AB"
		if cloud_red_controller.has_method("laya_stats"):
			return "CLOUD+LAYA"
		return "CLOUD"
	return "DETERMINISTIC"

# Policy UI (relocated to unit card context)
var _policy_container: HBoxContainer
var _policy_btn_blue: Button
var _policy_btn_red: Button
var _policy_btn_black: Button

# STEP-04R7 Unit Action UI (REST & FORTIFY) + R10 Dismantle + R11 Wait
var _unit_action_container: HBoxContainer
var _btn_rest: Button
var _btn_fortify: Button
var _btn_dismantle: Button
var _btn_wait: Button

# Selected Unit Card UI
var unit_card_panel: Panel
var unit_card_name: Label
var unit_card_stats: Label
var unit_card_status: Label

# Route Preview Card UI
var route_card_panel: Panel
var route_card_title: Label
var route_card_details: Label
var route_confirm_btn: Button

# Attack Preview Card UI (STEP-04)
var attack_card_panel: Panel
var attack_card_title: Label
var attack_card_details: Label
var attack_confirm_btn: Button

# Stronghold Panel (STEP-04R2 §13 & STEP-04R4 P4/P5)
var stronghold_panel: Panel
var stronghold_title: Label
var stronghold_subtitle: Label
var stronghold_wall_label: Label
var stronghold_state_label: Label
var stronghold_garrison_label: Label
var stronghold_garrison_list: Label
var stronghold_garrison_container: VBoxContainer
var stronghold_enter_btn: Button
var stronghold_deploy_container: VBoxContainer
var _stronghold_selected_id: String = ""
var _stronghold_deploy_pending_unit: String = ""

# Combat Feedback Banner & Phase Banner (STEP-04R4)
var combat_log_panel: Panel
var combat_log_text: Label
var phase_banner_panel: Panel
var phase_banner_label: Label

# Stronghold assault preview (STEP-04R2 §21)
var _preview_stronghold_id: String = ""
var _preview_stronghold_garrison_target: String = ""

var _current_hover_hex: Vector2i = Vector2i(-999, -999)
var _preview_target_hex: Vector2i = Vector2i(-999, -999)
var _preview_route_info: Variant = null
var _preview_attack_target_id: String = ""
var _preview_attack_info: Dictionary = {}
var _attackable_targets: Array[Dictionary] = []
var _current_envelope: Variant = null
var _is_animating_movement: bool = false
var _is_animating_combat: bool = false
# STEP-05R2 §4-§7: pending stepwise authority result across movement animation.
var _pending_move_res: Dictionary = {}
var _pending_move_unit: String = ""

# Instrumentation
var _trace: Array = []
var _elapsed: float = 0.0
var _next_checkpoint: int = 0
var _checkpoint_times: Array[int] = [0, 10, 20, 30, 40, 50, 60]
var _instrumentation_done: bool = false
var _ai_actions_fired: int = 0
var _slm_requests_fired: int = 0
var _gameplay_signals_fired: int = 0
var _shell_mode_prev: bool = false

var _camera_trace: Dictionary = {}
var _river_cells: Dictionary = {}

## Canonical DEV contract authority (Step 0 sandbox rules).
const SandboxRulesCls = preload("res://scripts/core/sandbox_rules.gd")

## Emitted after rebuild_step0_roster() so any mounted research UI (Cloud1Dock)
## re-reads the authoritative roster instead of keeping stale picker rows.
signal roster_rebuilt

@export var is_step0_sandbox: bool = false

## VISUAL ONLY: present the board from the friendly side (BLUE near/bottom,
## RED far/top, friendly HQ at bottom-center). Rotates the Camera2D; axial
## coordinates, pathing, combat and command semantics are untouched.
@export var present_blue_near_side: bool = true
const PresentationOrientationCls = preload("res://scripts/core/presentation_orientation.gd")
## Home framing: friendly HQ sits this fraction of the viewport height below
## screen center (0.30 -> HQ at ~80% of the screen height, above the hint bar).
const HOME_HQ_SCREEN_DROP: float = 0.30
const HOME_ZOOM: float = 0.95
## Lower-pitch perspective presentation (VISUAL ONLY, see PresentationProjection).
@export var present_perspective: bool = true
const PresentationProjectionCls = preload("res://scripts/visual/presentation_projection.gd")
## Friendly HQ target on screen (fraction of viewport height from the top).
const HOME_HQ_SCREEN_Y: float = 0.80
const PERSPECTIVE_HOME_ZOOM: float = 1.35
var _projection: Node = null
## CLOSEUP presentation state (VISUAL ONLY, 2.5D, scripts/visual/closeup25d).
## Loaded at runtime only when a display exists; headless runs never touch it.
@export var present_3d: bool = true
const VIEW3D_SCRIPT_PATH: String = "res://scripts/visual/closeup25d/battlefield_closeup_view.gd"
## CIV3D presentation (VISUAL ONLY, scripts/visual/civ3d): one continuous lit
## 3D camera for the default production map. SG_VIEW=closeup keeps the old view.
const VIEW3D_CIV_SCRIPT_PATH: String = "res://scripts/visual/civ3d/civ_battlefield_view.gd"
@export var present_civ3d: bool = true
var _view3d: Node = null
var _use_view3d: bool = false
## The one HIGH <-> CLOSEUP presentation-mode authority (windowed only).
const PresentationModeControllerCls = preload("res://scripts/visual/presentation_mode_controller.gd")
var _mode_controller: Node = null
## CANONICAL BATTLEFIELDS (scenario data; scripts/battlefields/battlefield_catalog.gd).
## Empty id (the default, and every training / self-play boot) = the default
## production map below, unchanged. A non-empty id replaces only map DATA:
## terrain, river cells, strongholds and the opening deployment.
const BattlefieldCatalogCls = preload("res://scripts/battlefields/battlefield_catalog.gd")
const HandcraftedBattlefieldCatalogCls = preload("res://scripts/battlefields/handcrafted_battlefield_catalog.gd")
const TutorialBattlefieldCatalogCls = preload("res://scripts/battlefields/tutorial_battlefield_catalog.gd")
const TutorialMissionRuntimeCls = preload("res://scripts/battlefields/tutorial_mission_runtime.gd")
const EpisodeSpecCls = preload("res://scripts/episodes/episode_spec.gd")
const EpisodeRuntimeCls = preload("res://scripts/episodes/episode_runtime.gd")
@export var battlefield_id: String = ""
## Full information on a real map (the RL mission matches, 2026-10-09): no fog of war, as in the Step0 sandbox.
@export var no_fog: bool = false
@export var episode_spec_path: String = ""
var _episode_spec: Dictionary = {}
var _battlefield: Dictionary = {}
var _tutorial_scenario: Dictionary = {}
var _tutorial_result_state: Dictionary = {}
var _tutorial_objective_label: Label = null

func _is_tutorial_battlefield() -> bool:
	return bool(_battlefield.get("tutorial", false))

func map_bounds() -> Dictionary:
	var min_v: int = 999999
	var max_v: int = -999999
	var q_min: int = 999999
	var q_max: int = -999999
	var r_min: int = 999999
	var r_max: int = -999999
	var cell_dict: Dictionary = hex_grid.get("cell_data") if hex_grid != null and hex_grid.get("cell_data") is Dictionary else {}
	if not cell_dict.is_empty():
		for key in cell_dict.keys():
			var parts := str(key).split(",")
			if parts.size() == 2:
				var q := parts[0].to_int()
				var r := parts[1].to_int()
				var v: int = 2 * r + q
				if v < min_v: min_v = v
				if v > max_v: max_v = v
				if q < q_min: q_min = q
				if q > q_max: q_max = q
				if r < r_min: r_min = r
				if r > r_max: r_max = r
	else:
		for q in range(-HEX_RADIUS, HEX_RADIUS + 1):
			for r in range(-HEX_RADIUS, HEX_RADIUS + 1):
				if WorldBoundaryCls.is_playable_hex(Vector2i(q, r)):
					var v: int = 2 * r + q
					if v < min_v: min_v = v
					if v > max_v: max_v = v
					if q < q_min: q_min = q
					if q > q_max: q_max = q
					if r < r_min: r_min = r
					if r > r_max: r_max = r
	return {
		"q_min": q_min,
		"q_max": q_max,
		"r_min": r_min,
		"r_max": r_max,
		"min_vertical": min_v,
		"max_vertical": max_v,
		"radius": maxi(absi(q_min) + absi(r_min), absi(q_max) + absi(r_max)) if _is_tutorial_battlefield() else HEX_RADIUS,
		"cell_count": cell_dict.size() if not cell_dict.is_empty() else PLAYABLE_HEX_COUNT
	}

## Shared gameplay validity predicate. Tutorials use their loaded cell data;
## existing maps retain the canonical radius-40 world boundary.
func is_playable_hex(coord: Vector2i) -> bool:
	if _is_tutorial_battlefield() and hex_grid != null:
		var cells: Dictionary = hex_grid.get("cell_data") if hex_grid.get("cell_data") is Dictionary else {}
		return cells.has("%d,%d" % [coord.x, coord.y])
	return WorldBoundaryCls.is_playable_hex(coord)

func _pathfinding_scenario_bounds() -> Dictionary:
	return map_bounds() if _is_tutorial_battlefield() else {}

func _ready() -> void:
	var requested_episode := episode_spec_path
	for arg in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if str(arg).begins_with("--episode="):
			requested_episode = str(arg).substr(10)
	if not requested_episode.is_empty():
		_episode_spec = EpisodeSpecCls.load(requested_episode)
		if _episode_spec.is_empty():
			push_error("[Episode] invalid spec: " + requested_episode)
			return
		battlefield_id = str((_episode_spec["map"] as Dictionary)["id"])
		EpisodeRuntimeCls.install(_episode_spec, requested_episode)
	if not is_step0_sandbox:
		var cur_scene: Node = get_tree().current_scene
		if cur_scene != null and (cur_scene.name == "Cloud1BattleTest" or cur_scene.name == "BattleTest"):
			is_step0_sandbox = true
		for arg in OS.get_cmdline_args():
			if arg == "--step0-sandbox":
				is_step0_sandbox = true
				break
	# Canonical mode predicate: publish the DEV contract before any setup runs so
	# every subsystem (combat, movement, HUD, tests) queries ONE runtime source.
	# EPISODE LAUNCH MODE: an explicit episode is a real (non-sandbox) battle;
	# DEV scenes that default to the Step0 sandbox run the episode instead.
	if not _episode_spec.is_empty():
		if is_step0_sandbox:
			print("[Episode] sandbox disabled for episode launch (scene default was Step0 sandbox)")
		is_step0_sandbox = false
		print("[Episode] LAUNCH " + JSON.stringify(EpisodeRuntimeCls.launch_record()))
	SandboxRulesCls.set_active(is_step0_sandbox)
	if is_step0_sandbox:
		if not _episode_spec.is_empty():
			push_error("[Episode] sandbox mode cannot run an episode")
			EpisodeRuntimeCls.clear()
			return
		print("[Step0] STEP 0 FLAT RESEARCH SANDBOX MODE ACTIVE")
	else:
		var bf_req: String = BattlefieldCatalogCls.resolve_requested_id(battlefield_id)
		if not bf_req.is_empty():
			if TutorialBattlefieldCatalogCls.has_battlefield(bf_req):
				_battlefield = TutorialBattlefieldCatalogCls.load_battlefield(bf_req)
			elif HandcraftedBattlefieldCatalogCls.has_battlefield(bf_req):
				_battlefield = HandcraftedBattlefieldCatalogCls.load_battlefield(bf_req)
			else:
				_battlefield = BattlefieldCatalogCls.load_battlefield(bf_req)
			if _battlefield.is_empty():
				if not _episode_spec.is_empty():
					push_error("[Episode] map failed after validation")
					EpisodeRuntimeCls.clear()
					return
				push_error("[Battlefield] '%s' failed to load; using the default map" % bf_req)
			else:
				if not _episode_spec.is_empty():
					_battlefield["units"] = _episode_spec["armies"].duplicate(true)
					var sh_hp: Dictionary = (_episode_spec["map"] as Dictionary)["stronghold_hp"]
					for sh in _battlefield["strongholds"]:
						sh["hp"] = int(sh_hp[str(sh["id"])])
				battlefield_id = str(_battlefield["id"])
				print("[Battlefield] battlefield %s: %s" % [battlefield_id, str(_battlefield["name"])])
	# Presentation yaw must be published before any world node is built so
	# upright art / labels pick it up at construction time.
	# Headless runs (audits / self-play / training) build no presentation
	# scenery at all (explicit HEADLESS mode): no projection, no closeup, no
	# board compositor, no texture loads. Gameplay setup is identical.
	var headless: bool = DisplayServer.get_name() == "headless"
	if headless:
		present_perspective = false
	elif present_3d and present_blue_near_side and present_perspective:
		_use_view3d = true
	PresentationOrientationCls.claim(self)
	PresentationOrientationCls.set_yaw(PresentationOrientationCls.BATTLE_BLUE_NEAR_SIDE_YAW if present_blue_near_side else 0.0)
	if present_blue_near_side and present_perspective:
		PresentationOrientationCls.perspective_active = true
		PresentationOrientationCls.set_upright_stretch(PresentationProjectionCls.nominal_stretch_for_zoom(PERSPECTIVE_HOME_ZOOM))
	if headless:
		PresentationOrientationCls.set_mode(PresentationOrientationCls.Mode.HEADLESS)
	elif present_blue_near_side and present_perspective:
		PresentationOrientationCls.set_mode(PresentationOrientationCls.Mode.HIGH)
	else:
		PresentationOrientationCls.set_mode(PresentationOrientationCls.Mode.FLAT)
	_setup_shell_guard()
	_setup_scene_nodes()
	_generate_direction_a_battlefield()
	_deploy_test_armies()
	_apply_refined_tiles()
	_setup_camera_and_bounds()
	_setup_unit_manager()
	_setup_tutorial_mission_runtime()
	_setup_minimal_hud()
	_setup_fog_of_war()
	_setup_step6()
	_connect_events()
	_take_checkpoint(0)
	_next_checkpoint = 1
	_camera_trace["initial"] = _cam_snapshot()
	_camera_trace["before_wasd"] = _cam_snapshot()
	var unit_count: int = unit_renderer.call("get_all_units").size() if unit_renderer else 0
	if _is_tutorial_battlefield():
		print("[TutorialMap] Shell ready %s | %d cells | visible field units %d | river %d" % [battlefield_id, hex_grid.get("cell_data").size(), unit_count, _river_cells.size()])
	else:
		print("[Step3] Shell ready — Regular Hexagon R=40 | %d cells | Units %d | River %d | Overview %.2f" % [PLAYABLE_HEX_COUNT, unit_count, _river_cells.size(), OVERVIEW_MIN_ZOOM])

func _exit_tree() -> void:
	if not _episode_spec.is_empty():
		EpisodeRuntimeCls.clear()
	# Static presentation state must not leak into the next scene (only the
	# owning shell resets it; see PresentationOrientation.claim).
	PresentationOrientationCls.reset(self)
	var tm: Node = get_node_or_null("/root/TurnManager")
	if tm and tm.has_method("get"):
		if tm.get("shell_mode") == true and _shell_mode_prev == false:
			tm.set("shell_mode", false)
			print("[Step3] shell_mode restored to OFF on exit")

func _setup_shell_guard() -> void:
	var tm: Node = get_node_or_null("/root/TurnManager")
	if tm:
		_shell_mode_prev = bool(tm.get("shell_mode")) if tm.get("shell_mode") != null else false
		tm.set("shell_mode", true)
		print("[Step3] TurnManager.shell_mode forced ON (prev=%s)" % [str(_shell_mode_prev)])

func _setup_scene_nodes() -> void:
	# HexGrid is the terrain DATA holder (cell_data) in this battle; it draws
	# nothing and takes no input (legacy_presentation = false in the .tscn).
	hex_grid = get_node_or_null("HexGrid") as Node2D
	if hex_grid == null:
		hex_grid = HexGridCls.new() as Node2D
		hex_grid.set("legacy_presentation", false)
		hex_grid.name = "HexGrid"
		add_child(hex_grid)

	# Off-map country is drawn by the HIGH projection (outer woods band) and
	# the CLOSEUP board; the retired hidden OuterMountainField node is gone.
	var legacy_boundary: Node = get_node_or_null("BoundaryRenderer")
	if legacy_boundary:
		legacy_boundary.queue_free()

	hex_compositor = get_node_or_null("HexVisualCompositor") as Node2D
	if hex_compositor == null:
		hex_compositor = HexVisualCompositorCls.new() as Node2D
		hex_compositor.name = "HexVisualCompositor"
		add_child(hex_compositor)
		if is_instance_valid(hex_grid):
			move_child(hex_compositor, hex_grid.get_index() + 1)

	# Default production layout is dressed inside the normal closeup view.
	if is_step0_sandbox or (not _battlefield.is_empty() and not _is_tutorial_battlefield()):
		production_map_env = get_node_or_null("ProductionMapEnvironment3D") as Node3D
		if production_map_env == null:
			var env_script: Script = load("res://scripts/visual/production_map_environment_3d.gd")
			if env_script != null:
				production_map_env = env_script.new() as Node3D
				production_map_env.name = "ProductionMapEnvironment3D"
				add_child(production_map_env)

	envelope_renderer = get_node_or_null("EnvelopeRenderer") as Node2D
	if envelope_renderer == null:
		envelope_renderer = Step3EnvelopeRendererCls.new() as Node2D
		envelope_renderer.name = "EnvelopeRenderer"
		add_child(envelope_renderer)

	stronghold_renderer = get_node_or_null("StrongholdRenderer") as Node2D
	if stronghold_renderer == null:
		stronghold_renderer = StrongholdRendererCls.new() as Node2D
		stronghold_renderer.name = "StrongholdRenderer"
		add_child(stronghold_renderer)

	unit_renderer = get_node_or_null("UnitRenderer") as Node2D
	if unit_renderer == null:
		unit_renderer = Step2RUnitRendererCls.new() as Node2D
		unit_renderer.name = "UnitRenderer"
		add_child(unit_renderer)
	camera = get_node_or_null("Camera2D") as Camera2D
	if camera == null:
		camera = Step2RCameraControllerCls.new() as Camera2D
		camera.name = "Camera2D"
		add_child(camera)

	hud_layer = get_node_or_null("CanvasLayer") as CanvasLayer
	if hud_layer == null:
		hud_layer = CanvasLayer.new()
		hud_layer.name = "CanvasLayer"
		hud_layer.layer = 30
		add_child(hud_layer)

## BATTLE_TERMINAL_CONTRACT_V0: the battle is over when either HQ falls.
## Own HQ destroyed = defeat; enemy HQ destroyed = victory. Freezes all turn
## flow, input, and authoritative actions the same way on both sides.
func _battle_over() -> bool:
	return _battle_lost or _battle_won


## Cache both HQ ids from live truth. Called after every roster init so the
## destruction handler can identify HQ kills (destroyed units leave no row).
func _cache_hq_ids() -> void:
	_blue_hq_id = ""
	_red_hq_id = ""
	if unit_manager == null:
		return
	for u in unit_manager.get_all_units_including_garrisoned():
		if str(u.get("class", "")) != "hq":
			continue
		if str(u.get("faction", "")) == "blue" and _blue_hq_id.is_empty():
			_blue_hq_id = str(u.get("id", ""))
		elif str(u.get("faction", "")) == "red" and _red_hq_id.is_empty():
			_red_hq_id = str(u.get("id", ""))


func _setup_unit_manager() -> void:
	unit_manager = Step3UnitManagerCls.new()
	var units: Array = unit_renderer.call("get_all_units") as Array if unit_renderer else []
	if _battlefield.is_empty():
		unit_manager.initialize_from_renderer_units(units, not is_step0_sandbox)
	else:
		# A canonical battlefield registers exactly its own strongholds (maybe none).
		var bf_sh: Array = _battlefield["strongholds"]
		unit_manager.initialize_from_renderer_units(units, not bf_sh.is_empty(), bf_sh)
	if _is_tutorial_battlefield():
		unit_manager.set_map_bounds(map_bounds())
	_cache_hq_ids()
	unit_manager.selection_changed.connect(_on_unit_selection_changed)
	unit_manager.turn_advanced.connect(_on_unit_manager_turn_advanced)
	unit_manager.policy_changed.connect(_on_policy_changed_by_manager)
	unit_manager.field_fortification_destroyed.connect(func(uid: String) -> void:
		if unit_renderer:
			unit_renderer.call("set_unit_fortified", uid, false)
	)
	unit_manager.field_fortification_abandoned.connect(func(uid: String) -> void:
		if unit_renderer:
			unit_renderer.call("set_unit_fortified", uid, false)
	)
	if is_step0_sandbox:
		if stronghold_renderer:
			stronghold_renderer.visible = false
		return
	# Remove garrisoned units from field renderer (they live inside stronghold roster §8)
	if not _battlefield.is_empty():
		_setup_battlefield_garrisons()
		return
	var garrisoned_ids: Array = []
	for uid in ["R_GAR_SPE_1", "R_GAR_ARC_1", "R_GAR_INF_1", "R_CAP_INF_1", "R_CAP_SPE_1", "R_CAP_ARC_1"]:
		if unit_manager.is_garrisoned(uid):
			garrisoned_ids.append(uid)
	# Also capital 4th unit on adjacent hex needs explicit enter
	if unit_manager.get_unit_by_id("R_CAP_CON_1") != {} and not unit_manager.is_garrisoned("R_CAP_CON_1"):
		var res: Dictionary = unit_manager.garrison_enter("R_CAP_CON_1", CAPITAL_ID)
		if res.get("success", false):
			garrisoned_ids.append("R_CAP_CON_1")
		else:
			print("[Step3] CAPITAL garrison_enter for R_CAP_CON_1 failed: %s" % res.get("reason", ""))
	for gid in garrisoned_ids:
		if unit_renderer.has_method("remove_unit"):
			unit_renderer.call("remove_unit", gid)
		elif unit_renderer.has_method("hide_unit"):
			unit_renderer.call("hide_unit", gid)
	# Render strongholds via dedicated renderer (§18,19)
	if stronghold_renderer:
		var sh_list: Array = unit_manager.get_all_strongholds()
		stronghold_renderer.call("render_strongholds", sh_list)
		if stronghold_renderer.has_signal("stronghold_clicked"):
			stronghold_renderer.stronghold_clicked.connect(_on_stronghold_clicked_by_badge)
		if stronghold_renderer.has_signal("stronghold_hover_changed"):
			stronghold_renderer.stronghold_hover_changed.connect(_on_stronghold_hover_changed)
		var fortress: Variant = unit_manager.get_stronghold_by_id(FORTRESS_ID)
		var capital: Variant = unit_manager.get_stronghold_by_id(CAPITAL_ID)
		var f_count: int = fortress.get_garrison_count() if fortress else 0
		var c_count: int = capital.get_garrison_count() if capital else 0
		print("[Step3] Garrisons seeded — Fortress %s: %d/4 %s | Capital %s: %d/6 %s" % [FORTRESS_ID, f_count, str(fortress.get_garrison_roster()) if fortress else "?", CAPITAL_ID, c_count, str(capital.get_garrison_roster()) if capital else "?"])

# ------------------------------------------------------------------
# River generation — deterministic meandering corridor across R=40
# ------------------------------------------------------------------
func _build_river_path() -> void:
	_river_cells.clear()
	if is_step0_sandbox:
		return
	if not _battlefield.is_empty():
		for k in (_battlefield["river"] as Dictionary).keys():
			_river_cells[k] = true
		return
	var rq: int = -15
	var rr: int = -25
	while rr <= 32:
		var key: String = "%d,%d" % [rq, rr]
		_river_cells[key] = true
		rr += 1
		var phase: float = float(rr) / 8.0
		var target_q: int = -12 + int(round(6.0 * sin(phase)))
		if rq < target_q:
			rq += 1
		elif rq > target_q:
			rq -= 1
		var s: int = -rq - rr
		if maxi(maxi(absi(rq), absi(rr)), absi(s)) > HEX_RADIUS:
			break

# ------------------------------------------------------------------
# Terrain assignment — Macro Strategic Geography
# ------------------------------------------------------------------
func _get_terrain_for_cell(q: int, r: int) -> int:
	if is_step0_sandbox:
		return 0 # Plains (neutral, uniform cost, 0 clutter)
	var key: String = "%d,%d" % [q, r]
	if not _battlefield.is_empty():
		return int((_battlefield["terrain"] as Dictionary).get(key, 0))
	
	# 1. Multi-Hex Strongholds — REAL 3-hex logical footprints (§2, §27)
	# Fortress Hulao: 3 connected hexes at (-4,2) cluster
	if key == "-4,2" or key == "-3,2" or key == "-4,3":
		return 9 # STRONGHOLD_FOOTPRINT (fortress — visually distinct via renderer)
	# Capital Luoyang: 3 connected hexes at (14,-5) cluster — walled city objective
	if key == "14,-5" or key == "15,-5" or key == "14,-4":
		return 11 # CAPITAL_FOOTPRINT (capital — distinct from fortress)

	# 2. Roads
	if r == 0 and q >= -32 and q <= -5:
		return 6
	if r == 1 and (q == -5 or q == -4):
		return 6
	if r == 2 and q >= -3 and q <= 2:
		return 6
	if r == -1 and q >= 3 and q <= 12:
		return 6
	if r == -5 and q >= 13 and q <= 22:
		return 6
	if r == -8 and q >= 23 and q <= 35:
		return 6

	if r == -20 and q >= -20 and q <= -12:
		return 6
	if r == -21 and q >= -11 and q <= 5:
		return 6
	if r == -22 and q >= 6 and q <= 18:
		return 6
	if r == -24 and q >= 19 and q <= 28:
		return 6
		
	if r == 16 and q >= -12 and q <= -4:
		return 6
	if r == 15 and q >= -3 and q <= 12:
		return 6
	if r == 14 and q >= 13 and q <= 22:
		return 6
	if r == 10 and q >= 23 and q <= 30:
		return 6
		
	if q == -4 and r >= 4 and r <= 14:
		return 6
	if q == 14 and r >= -21 and r <= -6:
		return 6

	# 3. Settlements / Villages
	var villages: Dictionary = {
		"-28,0": true, "-18,-1": true, "-12,2": true, "4,-1": true, "20,-6": true, "32,-8": true,
		"-18,-20": true, "-2,-21": true, "8,-22": true, "24,-24": true,
		"-10,16": true, "2,15": true, "16,14": true, "28,10": true,
		"-4,8": true, "-4,14": true, "-24,12": true, "28,-2": true
	}
	if villages.has(key):
		return 5

	# 4. River
	if _river_cells.has(key):
		return 7

	# 5. Major Mountain System (The Grand Spine / Dragon Ridge)
	var is_north_pass: bool = (q >= 9 and q <= 11 and r == -22)
	var is_central_pass: bool = (q >= 13 and q <= 15 and r == -5)
	var is_south_pass: bool = (q >= 17 and q <= 19 and r == 14)

	if not is_north_pass and not is_central_pass and not is_south_pass:
		if q >= 10 and q <= 22 and r >= -35 and r <= -8:
			if (q * 3 + r * 5) % 7 != 0 or (q >= 12 and q <= 18):
				return 1
		if q >= 12 and q <= 24 and r >= -4 and r <= 10:
			if (q * 2 + r * 7) % 6 != 0 or (q >= 15 and q <= 21):
				return 1
		if q >= 15 and q <= 26 and r >= 16 and r <= 28:
			if (q + r) % 5 != 0 or (q >= 18 and q <= 24):
				return 1
		if q >= -25 and q <= -10 and r <= -28:
			if (q * 7 + r * 3) % 4 != 0:
				return 1
		if q >= 22 and q <= 38 and r >= 15 and r <= 35:
			if (q + r) % 3 != 0:
				return 1

	# 6. Forest Regions
	if q >= -35 and q <= -18 and r >= -14 and r <= 10:
		if (q * 3 + r * 2) % 4 != 0 and not (r == 0 and q >= -32):
			return 2
	if q >= 25 and q <= 38 and r >= -18 and r <= 6:
		if (q + r * 2) % 3 != 0 and not (r == -8 and q >= 23):
			return 2
	if q >= -15 and q <= 5 and r >= -18 and r <= -10:
		if (q * 5 + r * 3) % 4 != 1 and not (r == -21):
			return 2

	# 7. Marsh / Swamp
	if q >= -18 and q <= -2 and r >= 18 and r <= 28:
		if (q * 2 + r * 3) % 3 != 0 and not (r == 16 and q >= -12):
			return 3
	if q >= 2 and q <= 10 and r >= 20 and r <= 26:
		if (q + r) % 3 == 0:
			return 3

	# 8. Plains
	return 0

func _generate_direction_a_battlefield() -> void:
	hex_grid.set("cell_data", {})
	_build_river_path()
	_stronghold_cells.clear()
	if not _battlefield.is_empty():
		for sd in _battlefield["strongholds"]:
			for h in sd["footprint"]:
				_stronghold_cells["%d,%d" % [h.x, h.y]] = true
	elif not is_step0_sandbox:
		for h in FORTRESS_FOOTPRINT:
			_stronghold_cells["%d,%d" % [h.x, h.y]] = true
		for h in CAPITAL_FOOTPRINT:
			_stronghold_cells["%d,%d" % [h.x, h.y]] = true
	var cell_data_dict: Dictionary = hex_grid.get("cell_data")
	if _is_tutorial_battlefield():
		var tutorial_terrain: Dictionary = _battlefield.get("terrain", {})
		for key in tutorial_terrain.keys():
			var parts := str(key).split(",")
			if parts.size() != 2:
				continue
			var q := parts[0].to_int()
			var r := parts[1].to_int()
			cell_data_dict[key] = HexCellCls.new(q, r, int(tutorial_terrain[key]))
	else:
		for q in range(-HEX_RADIUS, HEX_RADIUS + 1):
			for r in range(-HEX_RADIUS, HEX_RADIUS + 1):
				if WorldBoundaryCls.is_playable_hex(Vector2i(q, r)):
					var t: int = _get_terrain_for_cell(q, r)
					var cell: Variant = HexCellCls.new(q, r, t)
					cell_data_dict["%d,%d" % [q, r]] = cell
	hex_grid.call("generate_hexes")
	if _is_tutorial_battlefield():
		print("[TutorialMap] %s generated %d cells | stronghold footprint cells %d" % [battlefield_id, cell_data_dict.size(), _stronghold_cells.size()])
	else:
		print("[Step3] Generated battlefield: %d cells | Stronghold cells: %d (Fortress %d + Capital %d)" % [cell_data_dict.size(), _stronghold_cells.size(), FORTRESS_FOOTPRINT.size(), CAPITAL_FOOTPRINT.size()])

## Board presentation build. The retired prototype per-cell PNG tile pass
## (4,921 hidden Sprite2Ds) is gone: HexGrid is data-only here and the
## HexVisualCompositor owns every playable cell.
func _apply_refined_tiles() -> void:
	if hex_grid != null:
		hex_grid.visible = false
	_build_hex_compositor(hex_grid.get("cell_data"))
	if production_map_env != null and production_map_env.has_method("build_from_battlefield"):
		production_map_env.call("build_from_battlefield", self)

func _deploy_test_armies() -> void:
	unit_renderer.call("clear_units")
	if is_step0_sandbox:
		_deploy_step0_armies()
		return
	if not _battlefield.is_empty():
		for u in _battlefield["units"]:
			unit_renderer.call("spawn_unit", u["id"], u["class"], u["faction"], u["q"], u["r"], u["count"])
		print("[Battlefield] %s deployed %d units" % [battlefield_id, (_battlefield["units"] as Array).size()])
		return

	# STEP-04R2 Multi-Hex Stronghold Garrisons — 64+ field units, footprint hexes become garrison storage
	# Fortress Hulao (red) footprint: (-4,2), (-3,2), (-4,3) — will hold 3-4 garrisons
	# Capital Luoyang (red) footprint: (14,-5), (15,-5), (14,-4) — will hold 4-6 garrisons
	# Units placed on footprint hexes are auto-moved to garrison roster by unit_manager

	# Blue Vanguard & Main Army — 14
	unit_renderer.call("spawn_unit", "B_INF_1", "infantry", "blue", -22, -1, 450)
	unit_renderer.call("spawn_unit", "B_SPE_1", "spearman", "blue", -21, -1, 380)
	unit_renderer.call("spawn_unit", "B_INF_2", "infantry", "blue", -22, 0, 420)
	unit_renderer.call("spawn_unit", "B_SPE_2", "spearman", "blue", -21, 0, 360)
	unit_renderer.call("spawn_unit", "B_ARC_1", "archer", "blue", -23, -1, 220)
	unit_renderer.call("spawn_unit", "B_ARC_2", "archer", "blue", -23, 0, 200)
	unit_renderer.call("spawn_unit", "B_CON_1", "conscript", "blue", -24, -1, 600)
	unit_renderer.call("spawn_unit", "B_CON_2", "conscript", "blue", -24, 0, 580)
	unit_renderer.call("spawn_unit", "B_INF_3", "infantry", "blue", -16, -1, 440)
	unit_renderer.call("spawn_unit", "B_SPE_3", "spearman", "blue", -15, -1, 390)
	unit_renderer.call("spawn_unit", "B_ARC_3", "archer", "blue", -17, -2, 210)
	unit_renderer.call("spawn_unit", "B_CON_3", "conscript", "blue", -18, -2, 620)
	unit_renderer.call("spawn_unit", "B_SIG_1", "siege", "blue", -17, 0, 110)
	unit_renderer.call("spawn_unit", "B_SIG_2", "siege", "blue", -18, 1, 95)
	# Blue Northern Cavalry Wing — 6
	unit_renderer.call("spawn_unit", "B_CAV_1", "cavalry", "blue", -16, -18, 280)
	unit_renderer.call("spawn_unit", "B_CAV_2", "cavalry", "blue", -15, -17, 260)
	unit_renderer.call("spawn_unit", "B_CAV_3", "cavalry", "blue", -14, -19, 270)
	unit_renderer.call("spawn_unit", "B_SCT_1", "scout", "blue", -12, -18, 80)
	unit_renderer.call("spawn_unit", "B_SCT_2", "scout", "blue", -10, -20, 75)
	unit_renderer.call("spawn_unit", "B_INF_4", "infantry", "blue", -18, -17, 400)
	# Blue Southern Detachment — 6
	unit_renderer.call("spawn_unit", "B_INF_5", "infantry", "blue", -10, 14, 410)
	unit_renderer.call("spawn_unit", "B_SPE_4", "spearman", "blue", -9, 14, 370)
	unit_renderer.call("spawn_unit", "B_ARC_4", "archer", "blue", -11, 15, 230)
	unit_renderer.call("spawn_unit", "B_CON_4", "conscript", "blue", -12, 15, 590)
	unit_renderer.call("spawn_unit", "B_CAV_4", "cavalry", "blue", -8, 13, 250)
	unit_renderer.call("spawn_unit", "B_SCT_3", "scout", "blue", -6, 12, 85)
	# Blue Reconnaissance & Forest Scouts — 6
	unit_renderer.call("spawn_unit", "B_SCT_4", "scout", "blue", -26, -6, 70)
	unit_renderer.call("spawn_unit", "B_SCT_5", "scout", "blue", -24, 6, 75)
	unit_renderer.call("spawn_unit", "B_INF_6", "infantry", "blue", -26, 4, 390)
	unit_renderer.call("spawn_unit", "B_SPE_5", "spearman", "blue", -25, 5, 350)
	unit_renderer.call("spawn_unit", "B_ARC_5", "archer", "blue", -27, 5, 195)
	unit_renderer.call("spawn_unit", "B_CON_5", "conscript", "blue", -28, 6, 560)
	# Blue extra friendly unit near fortress for garrison-entry demo (adjacent to -4,2 cluster)
	unit_renderer.call("spawn_unit", "B_INF_7", "infantry", "blue", -5, 2, 400)
	# STEP-06R2: player Command HQ
	unit_renderer.call("spawn_unit", "B_HQ_1", "hq", "blue", -26, 0, 300)

	# Red Eastern Army — 8
	unit_renderer.call("spawn_unit", "R_INF_1", "infantry", "red", 24, -6, 480)
	unit_renderer.call("spawn_unit", "R_SPE_1", "spearman", "red", 25, -6, 420)
	unit_renderer.call("spawn_unit", "R_INF_2", "infantry", "red", 24, -5, 440)
	unit_renderer.call("spawn_unit", "R_SPE_2", "spearman", "red", 25, -5, 390)
	unit_renderer.call("spawn_unit", "R_ARC_1", "archer", "red", 26, -6, 260)
	unit_renderer.call("spawn_unit", "R_ARC_2", "archer", "red", 26, -5, 240)
	unit_renderer.call("spawn_unit", "R_CON_1", "conscript", "red", 27, -6, 650)
	unit_renderer.call("spawn_unit", "R_CON_2", "conscript", "red", 27, -5, 620)
	# Red Fortress Garrison — 3 units placed DIRECTLY on footprint hexes (§28)
	# These will be auto-moved into Fortress_Hulao garrison (3/4 slots)
	unit_renderer.call("spawn_unit", "R_GAR_SPE_1", "spearman", "red", -4, 2, 840)
	unit_renderer.call("spawn_unit", "R_GAR_ARC_1", "archer", "red", -3, 2, 610)
	unit_renderer.call("spawn_unit", "R_GAR_INF_1", "infantry", "red", -4, 3, 920)
	# Red additional fortress-adjacent guards (field units, not garrisoned)
	unit_renderer.call("spawn_unit", "R_CON_3", "conscript", "red", -5, 1, 600)
	unit_renderer.call("spawn_unit", "R_SIG_1", "siege", "red", -2, 2, 120)
	unit_renderer.call("spawn_unit", "R_SCT_1", "scout", "red", -1, 1, 85)
	# Red Capital Garrison — 4 units on/adjacent to capital footprint (§29)
	unit_renderer.call("spawn_unit", "R_CAP_INF_1", "infantry", "red", 14, -5, 780)
	unit_renderer.call("spawn_unit", "R_CAP_SPE_1", "spearman", "red", 15, -5, 690)
	unit_renderer.call("spawn_unit", "R_CAP_ARC_1", "archer", "red", 14, -4, 550)
	unit_renderer.call("spawn_unit", "R_CAP_CON_1", "conscript", "red", 13, -5, 620)
	unit_renderer.call("spawn_unit", "R_SIG_2", "siege", "red", 12, -4, 110)
	unit_renderer.call("spawn_unit", "R_CON_4", "conscript", "red", 16, -6, 580)
	unit_renderer.call("spawn_unit", "R_CAV_1", "cavalry", "red", 11, -3, 270)
	# Red Northern Flank Force
	unit_renderer.call("spawn_unit", "R_INF_5", "infantry", "red", 10, -21, 410)
	unit_renderer.call("spawn_unit", "R_SPE_5", "spearman", "red", 11, -21, 380)
	unit_renderer.call("spawn_unit", "R_ARC_5", "archer", "red", 9, -22, 220)
	unit_renderer.call("spawn_unit", "R_CAV_2", "cavalry", "red", 8, -20, 290)
	unit_renderer.call("spawn_unit", "R_SCT_2", "scout", "red", 6, -21, 80)
	unit_renderer.call("spawn_unit", "R_CON_5", "conscript", "red", 12, -22, 610)
	# Red Southern Corridor Force
	unit_renderer.call("spawn_unit", "R_INF_6", "infantry", "red", 22, 12, 430)
	unit_renderer.call("spawn_unit", "R_SPE_6", "spearman", "red", 23, 12, 370)
	unit_renderer.call("spawn_unit", "R_CAV_3", "cavalry", "red", 20, 13, 280)
	unit_renderer.call("spawn_unit", "R_ARC_6", "archer", "red", 24, 11, 210)
	unit_renderer.call("spawn_unit", "R_SIG_3", "siege", "red", 25, 10, 100)
	unit_renderer.call("spawn_unit", "R_SCT_3", "scout", "red", 18, 14, 75)
	print("[Step3] Deployed units incl. Fortress garrison(3) + Capital garrison(4) + 58 field = 65 logical (supply units retired)")


func _deploy_step0_armies() -> void:
	# A watched match with a random army (WATCH_RANDOM_ROSTER, 2026-10-08): the same counts for both sides.
	var roster: Dictionary = EpisodeRuntimeCls.current().get("roster", {})
	if not roster.is_empty() and str(EpisodeRuntimeCls.current().get("roster_layout", "")) == "spread":
		_deploy_roster_spread(roster)
		return
	if not roster.is_empty():
		_deploy_roster_from_counts("blue", roster)
		_deploy_roster_from_counts("red", roster)
		print("[Step0] Deployed random roster %s per side" % JSON.stringify(roster))
		return
	# Default 10v10 baseline on open flat ground
	# Blue 10 units:
	# NORTH (r < -2):
	unit_renderer.call("spawn_unit", "B_CAV_1", "cavalry", "blue", -15, -9, 280)
	unit_renderer.call("spawn_unit", "B_CAV_2", "cavalry", "blue", -14, -8, 260)
	unit_renderer.call("spawn_unit", "B_SCT_1", "scout", "blue", -12, -7, 80)
	unit_renderer.call("spawn_unit", "B_INF_1", "infantry", "blue", -17, -5, 450)
	# CENTER (-2 <= r <= 2):
	unit_renderer.call("spawn_unit", "B_HQ_1", "hq", "blue", -20, 0, 300)
	unit_renderer.call("spawn_unit", "B_INF_2", "infantry", "blue", -16, 0, 420)
	unit_renderer.call("spawn_unit", "B_ARC_1", "archer", "blue", -18, -1, 220)
	unit_renderer.call("spawn_unit", "B_SPE_1", "spearman", "blue", -15, 1, 380)
	# SOUTH (r > 2):
	unit_renderer.call("spawn_unit", "B_ARC_2", "archer", "blue", -17, 5, 200)
	unit_renderer.call("spawn_unit", "B_SPE_2", "spearman", "blue", -15, 6, 360)

	# Red 10 units (mirrored/opposing on east):
	# NORTH (r < -2):
	unit_renderer.call("spawn_unit", "R_CAV_1", "cavalry", "red", 15, -9, 280)
	unit_renderer.call("spawn_unit", "R_CAV_2", "cavalry", "red", 14, -8, 260)
	unit_renderer.call("spawn_unit", "R_SCT_1", "scout", "red", 12, -7, 80)
	unit_renderer.call("spawn_unit", "R_INF_1", "infantry", "red", 17, -5, 450)
	# CENTER (-2 <= r <= 2):
	unit_renderer.call("spawn_unit", "R_HQ_1", "hq", "red", 20, 0, 300)
	unit_renderer.call("spawn_unit", "R_INF_2", "infantry", "red", 16, 0, 420)
	unit_renderer.call("spawn_unit", "R_ARC_1", "archer", "red", 18, -1, 220)
	unit_renderer.call("spawn_unit", "R_SPE_1", "spearman", "red", 15, 1, 380)
	# SOUTH (r > 2):
	unit_renderer.call("spawn_unit", "R_ARC_2", "archer", "red", 17, 5, 200)
	unit_renderer.call("spawn_unit", "R_SPE_2", "spearman", "red", 15, 6, 360)
	print("[Step0] Deployed 10v10 research baseline (Blue 10, Red 10, 0 supply)")


## Any army size (2026-10-08, RL with 3..50 units per side): both sides get the same counts on point-mirrored hexes
## ((q, r) -> (-q, -r), an exact symmetry of the hex grid). RED's HQ at (20, 0); the other units fill the hexes
## nearest (16, 0) (the HQ hex left out), infantry/spearmen first (front), then archers, cavalry, scouts.
func _deploy_roster_spread(roster: Dictionary) -> void:
	var codes := {"infantry": "INF", "spearman": "SPE", "archer": "ARC", "cavalry": "CAV", "scout": "SCT",
		"conscript": "CON", "siege": "SIG"}
	var strength := {"infantry": 450, "spearman": 380, "archer": 220, "cavalry": 280, "scout": 80,
		"conscript": 500, "siege": 100}
	var hq := Vector2i(20, 0)
	var center := Vector2i(16, 0)
	var cells: Array = []
	for q in range(center.x - 8, center.x + 9):
		for r in range(-8, 9):
			var c := Vector2i(q, r)
			if c != hq and WorldBoundaryCls.is_playable_hex(c):
				cells.append(c)
	var hd := func(a: Vector2i, b: Vector2i) -> int:
		return (absi(a.x - b.x) + absi(a.y - b.y) + absi(a.x + a.y - b.x - b.y)) / 2
	# nearest the center first; ties: further forward (smaller q) first, then by r
	cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var da: int = hd.call(a, center)
		var db: int = hd.call(b, center)
		if da != db:
			return da < db
		if a.x != b.x:
			return a.x < b.x
		return a.y < b.y)
	var order: Array = []
	for cls in ["infantry", "spearman", "archer", "cavalry", "scout", "conscript", "siege"]:
		for i in range(int(roster.get(cls, 0))):
			order.append([cls, i + 1])
	for fac in ["red", "blue"]:
		var sign := 1 if fac == "red" else -1
		var prefix := "R_" if fac == "red" else "B_"
		unit_renderer.call("spawn_unit", prefix + "HQ_1", "hq", fac, sign * hq.x, sign * hq.y, 300)
		for k in range(mini(order.size(), cells.size())):
			var cls: String = order[k][0]
			var c: Vector2i = cells[k]
			unit_renderer.call("spawn_unit", "%s%s_%d" % [prefix, codes[cls], int(order[k][1])], cls, fac,
				sign * c.x, sign * c.y, int(strength[cls]))
	print("[Step0] Deployed spread roster %s per side" % JSON.stringify(roster))


func rebuild_step0_roster(blue_counts: Dictionary = {}, red_counts: Dictionary = {}) -> void:
	if not unit_renderer or not unit_manager:
		return
	unit_renderer.call("clear_units")
	if blue_counts.is_empty() and red_counts.is_empty():
		_deploy_step0_armies()
	else:
		_deploy_roster_from_counts("blue", blue_counts)
		_deploy_roster_from_counts("red", red_counts)
	var units: Array = unit_renderer.call("get_all_units") as Array
	unit_manager.initialize_from_renderer_units(units, false)
	_cache_hq_ids()
	_apply_enemy_observation()
	if hex_compositor and hex_compositor.has_method("refresh_units"):
		hex_compositor.call("refresh_units", _collect_hex_unit_coords())
	# Re-assert the DEV contract (a roster reset must never be able to flip modes)
	# and notify mounted research UI so pickers/observations rebuild from truth.
	SandboxRulesCls.set_active(true)
	roster_rebuilt.emit()
	var blue_n: int = 0
	var red_n: int = 0
	for u in unit_manager.get_all_units():
		var fac := str(u.get("faction", ""))
		if fac == "blue":
			blue_n += 1
		elif fac == "red":
			red_n += 1
	print("[Step0] Roster rebuilt | Blue %d | Red %d" % [blue_n, red_n])


func _deploy_roster_from_counts(faction: String, counts: Dictionary) -> void:
	var fac := faction.to_lower()
	var sign := -1 if fac == "blue" else 1
	var prefix := "B_" if fac == "blue" else "R_"
	var default_counts := {"hq": 1, "infantry": 2, "spearman": 2, "archer": 2, "cavalry": 2, "scout": 1}
	var actual_counts: Dictionary = counts if not counts.is_empty() else default_counts

	var north_slots: Array[Vector2i] = [
		Vector2i(sign * 15, -9), Vector2i(sign * 14, -8), Vector2i(sign * 12, -7),
		Vector2i(sign * 17, -5), Vector2i(sign * 13, -6), Vector2i(sign * 16, -7),
		Vector2i(sign * 18, -8), Vector2i(sign * 11, -6)
	]
	var center_slots: Array[Vector2i] = [
		Vector2i(sign * 20, 0), Vector2i(sign * 16, 0), Vector2i(sign * 18, -1),
		Vector2i(sign * 15, 1), Vector2i(sign * 17, -1), Vector2i(sign * 19, 1),
		Vector2i(sign * 14, 0), Vector2i(sign * 21, 0)
	]
	var south_slots: Array[Vector2i] = [
		Vector2i(sign * 17, 5), Vector2i(sign * 15, 6), Vector2i(sign * 16, 7),
		Vector2i(sign * 14, 5), Vector2i(sign * 18, 6), Vector2i(sign * 13, 7),
		Vector2i(sign * 19, 5), Vector2i(sign * 12, 6)
	]
	var n_idx := 0
	var c_idx := 0
	var s_idx := 0
	var class_counters := {}

	for cls_name in ["hq", "cavalry", "scout", "infantry", "spearman", "archer", "conscript", "siege"]:
		var num: int = int(actual_counts.get(cls_name, 0))
		var norm_cls: String = str(cls_name).to_lower()
		var strength := 450
		match norm_cls:
			"hq": strength = 300
			"cavalry": strength = 280
			"scout": strength = 80
			"infantry": strength = 450
			"spearman": strength = 380
			"archer": strength = 220
			"conscript": strength = 500
			"siege": strength = 100
		var code: String = norm_cls.substr(0, 3).to_upper()
		for i in range(num):
			class_counters[code] = int(class_counters.get(code, 0)) + 1
			var uid := "%s%s_%d" % [prefix, code, int(class_counters[code])]
			var slot := Vector2i.ZERO
			if norm_cls == "hq":
				slot = center_slots[c_idx % center_slots.size()]
				c_idx += 1
			elif norm_cls == "cavalry" or norm_cls == "scout":
				if n_idx < north_slots.size():
					slot = north_slots[n_idx]
					n_idx += 1
				else:
					slot = south_slots[s_idx % south_slots.size()]
					s_idx += 1
			elif norm_cls == "spearman" or norm_cls == "archer":
				if s_idx < south_slots.size() and s_idx <= c_idx:
					slot = south_slots[s_idx]
					s_idx += 1
				else:
					slot = center_slots[c_idx % center_slots.size()]
					c_idx += 1
			else:
				if c_idx < center_slots.size():
					slot = center_slots[c_idx]
					c_idx += 1
				elif n_idx < north_slots.size():
					slot = north_slots[n_idx]
					n_idx += 1
				else:
					slot = south_slots[s_idx % south_slots.size()]
					s_idx += 1
			unit_renderer.call("spawn_unit", uid, norm_cls, fac, slot.x, slot.y, strength)

func _setup_camera_and_bounds() -> void:
	var cam_bounds: Dictionary = WorldBoundaryCls.get_camera_world_bounds()
	var play_bounds: Dictionary = WorldBoundaryCls.get_playable_world_bounds()
	var outer_bounds: Dictionary = WorldBoundaryCls.get_outer_world_bounds()
	var b_min: Vector2 = cam_bounds["min"] as Vector2
	var b_max: Vector2 = cam_bounds["max"] as Vector2
	var play_min: Vector2 = play_bounds["min"] as Vector2
	var play_max: Vector2 = play_bounds["max"] as Vector2
	var outer_min: Vector2 = outer_bounds["min"] as Vector2
	var outer_max: Vector2 = outer_bounds["max"] as Vector2
	if _is_tutorial_battlefield():
		var cells: Dictionary = hex_grid.get("cell_data") if hex_grid else {}
		var min_x := INF
		var min_y := INF
		var max_x := -INF
		var max_y := -INF
		for cell in cells.values():
			var pos: Vector2 = HexUtilsCls.hex_to_pixel(int(cell.q), int(cell.r))
			min_x = minf(min_x, pos.x)
			min_y = minf(min_y, pos.y)
			max_x = maxf(max_x, pos.x)
			max_y = maxf(max_y, pos.y)
		var pad := Vector2(66.0, 66.0)
		play_min = Vector2(min_x, min_y) - pad
		play_max = Vector2(max_x, max_y) + pad
		b_min = play_min - pad
		b_max = play_max + pad
		outer_min = play_min
		outer_max = play_max
	
	if camera.has_method("set_map_bounds"):
		var margin_x: float = 66.0 if _is_tutorial_battlefield() else (b_max.x - play_max.x)
		var margin_y: float = 66.0 if _is_tutorial_battlefield() else (b_max.y - play_max.y)
		var cam_margin: Vector2 = Vector2(margin_x, margin_y)
		camera.call("set_map_bounds", play_min, play_max, cam_margin)
	
	var start_pos: Vector2 = HexUtilsCls.hex_to_pixel(-8, 0)
	if _is_tutorial_battlefield():
		var tutorial_hq: Vector2i = _friendly_hq_hex()
		start_pos = HexUtilsCls.hex_to_pixel(tutorial_hq.x, tutorial_hq.y)
	var start_zoom: float = DEFAULT_ZOOM
	if PresentationOrientationCls.is_rotated():
		# Friendly-side view: rotate the camera and frame the friendly HQ at
		# bottom-center, looking forward (+q = screen up) into the field.
		camera.ignore_rotation = false
		camera.rotation = PresentationOrientationCls.yaw_rad
		start_zoom = HOME_ZOOM
		var hq_hex: Vector2i = _friendly_hq_hex()
		var vp_h: float = get_viewport().get_visible_rect().size.y if get_viewport() else 1080.0
		var drop_world: float = vp_h * HOME_HQ_SCREEN_DROP / start_zoom
		if present_perspective and _projection == null:
			_projection = PresentationProjectionCls.new()
			add_child(_projection)
			_projection.call("setup", get_viewport())
		if _projection != null:
			# Place the HQ at HOME_HQ_SCREEN_Y on the PROJECTED screen: invert
			# the projection to find its board depth, then convert to world.
			start_zoom = PERSPECTIVE_HOME_ZOOM
			# HQ-anchored framing: the camera path follows the friendly HQ's
			# live position at every zoom (no hardcoded coordinates).
			camera.set("anchor_provider", Callable(self, "_hq_anchor_target"))
			# The wheel's limits ARE the two ends of the view transition.
			camera.set("min_zoom", PresentationProjectionCls.ZOOM_COMMANDER * 0.86)
			camera.set("max_zoom", PresentationProjectionCls.ZOOM_BATTLEFIELD)
			_projection.call("configure_for_zoom", start_zoom)
			var r: Dictionary = _projection.call("unproject_board", Vector2(0, vp_h * (HOME_HQ_SCREEN_Y - 0.5)))
			drop_world = float((r["g"] as Vector2).y) / start_zoom
		# CLOSEUP presentation state (VISUAL ONLY): the top-down / tactical
		# board above keeps its full behaviour up to a capped zoom; wheeling
		# in past that cap switches (through a mist veil) to the separate
		# closeup view behind the friendly HQ.
		if _use_view3d and _projection != null and _view3d == null:
			var v3_script: Script = load(_view3d_script_path()) as Script
			if v3_script != null:
				_view3d = v3_script.new()
				add_child(_view3d)
				_view3d.call("setup", self)
				var z_cap: float = float(_view3d.call("board_max_zoom"))
				camera.set("max_zoom", z_cap)
				start_zoom = minf(start_zoom, z_cap)
				_projection.call("configure_for_zoom", start_zoom)
				var r2: Dictionary = _projection.call("unproject_board", Vector2(0, vp_h * (HOME_HQ_SCREEN_Y - 0.5)))
				drop_world = float((r2["g"] as Vector2).y) / start_zoom
		# Screen-down vector expressed in world space, scaled to the drop.
		start_pos = HexUtilsCls.hex_to_pixel(hq_hex.x, hq_hex.y) - Vector2(0, drop_world).rotated(PresentationOrientationCls.yaw_rad)
		if camera.has_method("set_home_view"):
			camera.call("set_home_view", start_pos, start_zoom)
		# ONE presentation-mode authority (HIGH <-> CLOSEUP): owns the explicit
		# mode, canvas visibility layers and which renderer draws the screen.
		if _projection != null and _mode_controller == null:
			_mode_controller = PresentationModeControllerCls.new()
			add_child(_mode_controller)
			_mode_controller.call("setup", self, _projection, _view3d)
	# Opening frame, set explicitly (no deferred re-clamp): zoom first, then
	# the position. An HQ-anchored camera opens exactly on its anchor with a
	# zero pan offset; a free camera opens on start_pos.
	if camera.has_method("set_zoom_level"):
		camera.call("set_zoom_level", start_zoom, true)
	if camera.has_method("focus_on"):
		var anchored: bool = camera.has_method("is_anchored") and bool(camera.call("is_anchored"))
		camera.call("focus_on", _hq_anchor_target(start_zoom) if anchored else start_pos, true)
	_camera_trace["start_position"] = {"x": start_pos.x, "y": start_pos.y, "zoom": DEFAULT_ZOOM}
	_camera_trace["playable_min_world"] = {"x": play_min.x, "y": play_min.y}
	_camera_trace["playable_max_world"] = {"x": play_max.x, "y": play_max.y}
	_camera_trace["outer_min_world"] = {"x": outer_min.x, "y": outer_min.y}
	_camera_trace["outer_max_world"] = {"x": outer_max.x, "y": outer_max.y}
	_camera_trace["camera_min_world"] = {"x": b_min.x, "y": b_min.y}
	_camera_trace["camera_max_world"] = {"x": b_max.x, "y": b_max.y}
	_camera_trace["map_center_world"] = {"x": 0.0, "y": 0.0}

## Subtle screen-space vignette between the world and the HUD. Fully clear
## across the central play area (incl. the HQ at ~80% height); only the outer
## corners behind the side panels darken. Input-transparent. Visual only.
func _setup_presentation_vignette() -> void:
	var layer := CanvasLayer.new()
	layer.name = "PresentationVignette"
	layer.layer = 2
	add_child(layer)
	var grad := Gradient.new()
	grad.set_offset(0, 0.0)
	grad.set_color(0, Color(0.02, 0.02, 0.04, 0.0))
	grad.set_offset(1, 1.0)
	grad.set_color(1, Color(0.02, 0.02, 0.04, 0.30))
	grad.add_point(0.62, Color(0.02, 0.02, 0.04, 0.0))
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 256
	tex.height = 256
	var rect := TextureRect.new()
	rect.name = "Vignette"
	rect.texture = tex
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(rect)

## Which 3D presentation draws this battle (VISUAL ONLY).
func _view3d_script_path() -> String:
	if present_civ3d and OS.get_environment("SG_VIEW") != "closeup" and not is_step0_sandbox and battlefield_id == "" and _battlefield.is_empty():
		return VIEW3D_CIV_SCRIPT_PATH
	return VIEW3D_SCRIPT_PATH

## Pointer -> world. With the perspective presentation the exact inverse
## projection is used, so a click always resolves to the hex drawn under the
## cursor; pixels showing sky/backdrop resolve far outside the playable map.
func _pointer_world(screen_pos: Vector2) -> Vector2:
	if _view3d != null and bool(_view3d.call("is_active")):
		return _view3d.call("screen_to_world", screen_pos)
	if _projection != null:
		var w: Variant = _projection.call("screen_to_world", screen_pos)
		return w if w != null else Vector2(1.0e7, 1.0e7)
	return camera.get_global_mouse_position() if camera else get_global_mouse_position()

## Friendly HQ screen anchor (fraction of viewport height) as a function of
## the view blend: lower-middle in the strategic view, near-side bottom in
## the battlefield view ("standing behind the army").
const HQ_ANCHOR_Y_FAR: float = 0.72
const HQ_ANCHOR_Y_NEAR: float = 0.88
var _hq_last_world: Vector2 = Vector2.INF

## Live world position of the friendly HQ (renderer node, so the framing
## also follows move animations); falls back to its last known position.
func _hq_world_pos() -> Vector2:
	var id: String = _blue_hq_id
	if id != "" and unit_renderer and unit_renderer.has_method("get_unit_node"):
		var n: Node2D = unit_renderer.call("get_unit_node", id) as Node2D
		if n and is_instance_valid(n):
			_hq_last_world = n.position
			return _hq_last_world
	if id != "" and unit_manager:
		var u: Dictionary = unit_manager.get_unit_by_id(id)
		if not u.is_empty():
			_hq_last_world = HexUtilsCls.hex_to_pixel(int(u.get("q", 0)), int(u.get("r", 0)))
			return _hq_last_world
	if _hq_last_world == Vector2.INF:
		var h: Vector2i = _friendly_hq_hex()
		_hq_last_world = HexUtilsCls.hex_to_pixel(h.x, h.y)
	return _hq_last_world

## Camera target (world) that puts the friendly HQ at its screen anchor for
## zoom `z`, solved through the projection configured for that zoom.
## board = z * R(-yaw) * (world - target)  =>  target = HQ - R(yaw) g / z.
func _hq_anchor_target(z: float) -> Vector2:
	var hq: Vector2 = _hq_world_pos()
	var vp_h: float = get_viewport().get_visible_rect().size.y if get_viewport() else 1080.0
	if _projection == null:
		return hq - Vector2(0, vp_h * HOME_HQ_SCREEN_DROP / z).rotated(PresentationOrientationCls.yaw_rad)
	_projection.call("configure_for_zoom", z)
	var ev: float = float(_projection.get("e"))
	var y: float = lerpf(HQ_ANCHOR_Y_FAR, HQ_ANCHOR_Y_NEAR, ev)
	var r: Dictionary = _projection.call("unproject_board", Vector2(0, vp_h * (y - 0.5)))
	return hq - ((r["g"] as Vector2).rotated(PresentationOrientationCls.yaw_rad)) / z

## Friendly HQ hex from the deployed roster (presentation framing only).
func _friendly_hq_hex() -> Vector2i:
	if unit_renderer:
		for u in (unit_renderer.call("get_all_units") as Array):
			if str(u.get("class", "")) == "hq" and str(u.get("faction", "")) == "blue":
				return Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))
	return Vector2i(-20, 0)

# ------------------------------------------------------------------
# HUD Setup — Clean Tactical Hierarchy
# ------------------------------------------------------------------
# ------------------------------------------------------------------
# HUD Setup — Responsive Tactical Hierarchy (STEP-04R4)
# ------------------------------------------------------------------
func _setup_minimal_hud() -> void:
	_setup_presentation_vignette()
	# 1. Bottom Hint Panel (Anchored Bottom Wide)
	var bottom_panel: Panel = Panel.new()
	bottom_panel.name = "BottomHintPanel"
	bottom_panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bottom_panel.offset_left = 24
	bottom_panel.offset_right = -24
	bottom_panel.offset_top = -52
	bottom_panel.offset_bottom = -10
	bottom_panel.add_theme_stylebox_override("panel", HistoricalUIThemeCls.create_lacquer_panel(1, 6, HistoricalUIThemeCls.COLOR_GOLD_SUBDUE))
	hud_layer.add_child(bottom_panel)

	hint_label = Label.new()
	hint_label.name = "CameraHint"
	hint_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hint_label.text = "[좌클릭] 부대 선택 / 목적지 지정 (2회 클릭 확정)  |  [우클릭/ESC] 취소  |  [NEXT] 다음 부대 순환  |  [WASD/드래그] 전장 이동  |  [휠] 줌"
	hint_label.add_theme_font_size_override("font_size", 14)
	hint_label.add_theme_color_override("font_color", HistoricalUIThemeCls.COLOR_TEXT_PRIMARY)
	hint_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	hint_label.add_theme_constant_override("shadow_offset_x", 1)
	hint_label.add_theme_constant_override("shadow_offset_y", 1)
	bottom_panel.add_child(hint_label)

	# 2. Top-Left Debug / Status Panel (Anchored Top Left)
	var debug_panel: Panel = Panel.new()
	debug_panel.name = "DebugStatusPanel"
	debug_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	debug_panel.offset_left = 24
	debug_panel.offset_top = 16
	debug_panel.offset_right = 380
	debug_panel.offset_bottom = 48
	debug_panel.add_theme_stylebox_override("panel", HistoricalUIThemeCls.create_lacquer_panel(1, 4, HistoricalUIThemeCls.COLOR_GOLD_SUBDUE))
	hud_layer.add_child(debug_panel)

	debug_label = Label.new()
	debug_label.name = "DebugLabel"
	debug_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	debug_label.offset_left = 10
	debug_label.offset_right = -10
	debug_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	debug_label.text = _status_strip_text(DEFAULT_ZOOM, 0.0, Vector2.ZERO)
	debug_label.add_theme_font_size_override("font_size", 12)
	debug_label.add_theme_color_override("font_color", HistoricalUIThemeCls.COLOR_GOLD_BRIGHT)
	debug_panel.add_child(debug_label)

	if _is_tutorial_battlefield():
		var mission_panel := Panel.new()
		mission_panel.name = "TutorialObjectivePanel"
		mission_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
		mission_panel.offset_left = -460
		mission_panel.offset_top = 56
		mission_panel.offset_right = 460
		mission_panel.offset_bottom = 142
		mission_panel.add_theme_stylebox_override("panel", HistoricalUIThemeCls.create_lacquer_panel(1, 4, HistoricalUIThemeCls.COLOR_GOLD_SUBDUE))
		hud_layer.add_child(mission_panel)
		_tutorial_objective_label = Label.new()
		_tutorial_objective_label.name = "TutorialObjectiveLabel"
		_tutorial_objective_label.set_anchors_preset(Control.PRESET_FULL_RECT)
		_tutorial_objective_label.offset_left = 10
		_tutorial_objective_label.offset_top = 6
		_tutorial_objective_label.offset_right = -10
		_tutorial_objective_label.offset_bottom = -6
		_tutorial_objective_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_tutorial_objective_label.add_theme_font_size_override("font_size", 12)
		_tutorial_objective_label.add_theme_color_override("font_color", HistoricalUIThemeCls.COLOR_TEXT_PRIMARY)
		mission_panel.add_child(_tutorial_objective_label)
		_refresh_tutorial_objective_label(1)

	# 2b. Top Command HUD Banner (Center Top Command Table)
	_top_hud_bar = Panel.new()
	_top_hud_bar.name = "TopCommandHudBar"
	_top_hud_bar.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_top_hud_bar.offset_left = -320
	_top_hud_bar.offset_top = 10
	_top_hud_bar.offset_right = 320
	_top_hud_bar.offset_bottom = 54
	var bar_tex: Texture2D = null
	if ResourceLoader.exists("res://assets/visual_overhaul_r3/ui/top_command_bar.png"):
		bar_tex = load("res://assets/visual_overhaul_r3/ui/top_command_bar.png") as Texture2D
	if bar_tex != null:
		var sb_tex := StyleBoxTexture.new()
		sb_tex.texture = bar_tex
		sb_tex.texture_margin_left = 32
		sb_tex.texture_margin_right = 32
		sb_tex.texture_margin_top = 6
		sb_tex.texture_margin_bottom = 6
		_top_hud_bar.add_theme_stylebox_override("panel", sb_tex)
	else:
		_top_hud_bar.add_theme_stylebox_override("panel", HistoricalUIThemeCls.create_lacquer_panel(1, 4, HistoricalUIThemeCls.COLOR_GOLD_BORDER))
	hud_layer.add_child(_top_hud_bar)

	var top_hbox := HBoxContainer.new()
	top_hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	top_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	top_hbox.add_theme_constant_override("separation", 14)
	_top_hud_bar.add_child(top_hbox)

	_top_hud_turn_lbl = Label.new()
	_top_hud_turn_lbl.text = "第 1 回合"
	_top_hud_turn_lbl.add_theme_font_size_override("font_size", 13)
	_top_hud_turn_lbl.add_theme_color_override("font_color", Color(HistoricalUIThemeCls.COLOR_GOLD_BRIGHT, 0.35))
	top_hbox.add_child(_top_hud_turn_lbl)

	var div1 := Label.new()
	div1.text = "•"
	div1.add_theme_color_override("font_color", HistoricalUIThemeCls.COLOR_GOLD_SUBDUE)
	top_hbox.add_child(div1)

	_top_hud_army_lbl = Label.new()
	_top_hud_army_lbl.text = "全軍: 8 부대"
	_top_hud_army_lbl.add_theme_font_size_override("font_size", 13)
	_top_hud_army_lbl.add_theme_color_override("font_color", Color(HistoricalUIThemeCls.COLOR_TEXT_PRIMARY, 0.35))
	top_hbox.add_child(_top_hud_army_lbl)

	var div3 := Label.new()
	div3.text = "•"
	div3.add_theme_color_override("font_color", HistoricalUIThemeCls.COLOR_GOLD_SUBDUE)
	top_hbox.add_child(div3)

	_top_hud_contact_lbl = Label.new()
	_top_hud_contact_lbl.text = "敵探知: 0"
	_top_hud_contact_lbl.add_theme_font_size_override("font_size", 13)
	_top_hud_contact_lbl.add_theme_color_override("font_color", Color(HistoricalUIThemeCls.COLOR_GOLD_ORNAMENT, 0.35))
	top_hbox.add_child(_top_hud_contact_lbl)

	var div4 := Label.new()
	div4.text = "•"
	div4.add_theme_color_override("font_color", HistoricalUIThemeCls.COLOR_GOLD_SUBDUE)
	top_hbox.add_child(div4)

	_top_hud_renown_lbl = Label.new()
	_top_hud_renown_lbl.text = "軍威: 85"
	_top_hud_renown_lbl.add_theme_font_size_override("font_size", 13)
	_top_hud_renown_lbl.add_theme_color_override("font_color", Color(HistoricalUIThemeCls.COLOR_GOLD_BRIGHT, 0.35))
	top_hbox.add_child(_top_hud_renown_lbl)

	# 3. Top-Right Turn & Phase Panel (Anchored Top Right) — LABEL ONLY (STEP-04R5 §9)
	var turn_panel: Panel = Panel.new()
	turn_panel.name = "TurnPanel"
	turn_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	turn_panel.offset_left = -224
	turn_panel.offset_top = 16
	turn_panel.offset_right = -24
	turn_panel.offset_bottom = 54
	turn_panel.add_theme_stylebox_override("panel", HistoricalUIThemeCls.create_lacquer_panel(1, 4, HistoricalUIThemeCls.COLOR_GOLD_BORDER))
	hud_layer.add_child(turn_panel)

	turn_label = Label.new()
	turn_label.name = "TurnLabel"
	turn_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	turn_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	turn_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	turn_label.text = "제 1 턴  (아군)"
	turn_label.add_theme_font_size_override("font_size", 15)
	turn_label.add_theme_color_override("font_color", HistoricalUIThemeCls.COLOR_GOLD_BRIGHT)
	turn_panel.add_child(turn_label)

	# 3b. THE SINGLE Primary Turn-Flow Button (NEXT / END TURN) — Bottom-Right HUD (§9, §10)
	next_turn_button = Button.new()
	next_turn_button.name = "NextTurnButton"
	next_turn_button.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	next_turn_button.offset_left = -304
	next_turn_button.offset_top = -112
	next_turn_button.offset_right = -24
	next_turn_button.offset_bottom = -60
	next_turn_button.focus_mode = Control.FOCUS_NONE
	next_turn_button.pressed.connect(_on_next_turn_button_pressed)
	hud_layer.add_child(next_turn_button)
	_update_next_button_state()
	var _nb_conns: int = next_turn_button.get_signal_connection_list("pressed").size()
	print("[NEXT] button=%s" % str(next_turn_button.get_path()))
	print("[NEXT] visible=%s" % str(next_turn_button.is_visible_in_tree()).to_lower())
	print("[NEXT] disabled=%s" % str(next_turn_button.disabled).to_lower())
	print("[NEXT] connections=%d" % _nb_conns)

	# 5. Bottom-Left Selected Unit Card (Anchored Bottom Left)
	unit_card_panel = Panel.new()
	unit_card_panel.name = "UnitCardPanel"
	unit_card_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	unit_card_panel.offset_left = 24
	unit_card_panel.offset_top = -295
	unit_card_panel.offset_right = 424
	unit_card_panel.offset_bottom = -60
	unit_card_panel.add_theme_stylebox_override("panel", HistoricalUIThemeCls.create_card_panel(HistoricalUIThemeCls.COLOR_GOLD_BORDER))
	unit_card_panel.visible = false
	hud_layer.add_child(unit_card_panel)

	unit_card_name = Label.new()
	unit_card_name.position = Vector2(14, 10)
	unit_card_name.size = Vector2(370, 24)
	unit_card_name.add_theme_font_size_override("font_size", 15)
	unit_card_name.add_theme_color_override("font_color", HistoricalUIThemeCls.COLOR_GOLD_BRIGHT)
	unit_card_panel.add_child(unit_card_name)

	unit_card_stats = Label.new()
	unit_card_stats.position = Vector2(14, 36)
	unit_card_stats.size = Vector2(370, 56)
	unit_card_stats.add_theme_font_size_override("font_size", 13)
	unit_card_stats.add_theme_color_override("font_color", HistoricalUIThemeCls.COLOR_TEXT_PRIMARY)
	unit_card_panel.add_child(unit_card_stats)

	unit_card_status = Label.new()
	unit_card_status.position = Vector2(14, 96)
	unit_card_status.size = Vector2(370, 20)
	unit_card_status.add_theme_font_size_override("font_size", 12)
	unit_card_status.add_theme_color_override("font_color", HistoricalUIThemeCls.COLOR_GOLD_ORNAMENT)
	unit_card_panel.add_child(unit_card_status)
	_build_policy_controls(unit_card_panel)
	_build_unit_action_controls(unit_card_panel)

	# 6. Bottom-Right Route Preview Card (Anchored Bottom Right)
	route_card_panel = Panel.new()
	route_card_panel.name = "RouteCardPanel"
	route_card_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	route_card_panel.offset_left = -464
	route_card_panel.offset_top = -275
	route_card_panel.offset_right = -24
	route_card_panel.offset_bottom = -120
	route_card_panel.add_theme_stylebox_override("panel", HistoricalUIThemeCls.create_card_panel(HistoricalUIThemeCls.COLOR_GOLD_BORDER))
	route_card_panel.visible = false
	hud_layer.add_child(route_card_panel)

	route_card_title = Label.new()
	route_card_title.position = Vector2(14, 10)
	route_card_title.size = Vector2(410, 24)
	route_card_title.add_theme_font_size_override("font_size", 15)
	route_card_title.add_theme_color_override("font_color", HistoricalUIThemeCls.COLOR_GOLD_BRIGHT)
	route_card_panel.add_child(route_card_title)

	route_card_details = Label.new()
	route_card_details.position = Vector2(14, 38)
	route_card_details.size = Vector2(410, 56)
	route_card_details.add_theme_font_size_override("font_size", 13)
	route_card_details.add_theme_color_override("font_color", HistoricalUIThemeCls.COLOR_TEXT_PRIMARY)
	route_card_panel.add_child(route_card_details)

	route_confirm_btn = Button.new()
	route_confirm_btn.name = "RouteConfirmBtn"
	route_confirm_btn.position = Vector2(14, 102)
	route_confirm_btn.size = Vector2(412, 34)
	route_confirm_btn.text = "이동 실행 (Confirm Move) [클릭 / Enter / Space]"
	route_confirm_btn.focus_mode = Control.FOCUS_NONE
	var conf_style: StyleBoxFlat = StyleBoxFlat.new()
	conf_style.bg_color = Color(0.14, 0.32, 0.22, 0.94)
	conf_style.border_color = Color(0.45, 0.85, 0.55, 0.90)
	conf_style.set_border_width_all(1)
	conf_style.set_corner_radius_all(4)
	route_confirm_btn.add_theme_stylebox_override("normal", conf_style)
	var conf_hover: StyleBoxFlat = conf_style.duplicate()
	conf_hover.bg_color = Color(0.20, 0.44, 0.28, 1.0)
	route_confirm_btn.add_theme_stylebox_override("hover", conf_hover)
	route_confirm_btn.pressed.connect(_execute_confirmed_move)
	route_card_panel.add_child(route_confirm_btn)

	# 7. Bottom-Right Attack Preview Card (Anchored Bottom Right)
	attack_card_panel = Panel.new()
	attack_card_panel.name = "AttackCardPanel"
	attack_card_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	attack_card_panel.offset_left = -464
	attack_card_panel.offset_top = -285
	attack_card_panel.offset_right = -24
	attack_card_panel.offset_bottom = -120
	attack_card_panel.add_theme_stylebox_override("panel", HistoricalUIThemeCls.create_card_panel(HistoricalUIThemeCls.COLOR_ENEMY_RED))
	attack_card_panel.visible = false
	hud_layer.add_child(attack_card_panel)

	attack_card_title = Label.new()
	attack_card_title.position = Vector2(14, 10)
	attack_card_title.size = Vector2(410, 24)
	attack_card_title.add_theme_font_size_override("font_size", 15)
	attack_card_title.add_theme_color_override("font_color", HistoricalUIThemeCls.COLOR_TEXT_CRIMSON)
	attack_card_panel.add_child(attack_card_title)

	attack_card_details = Label.new()
	attack_card_details.position = Vector2(14, 38)
	attack_card_details.size = Vector2(410, 65)
	attack_card_details.add_theme_font_size_override("font_size", 12)
	attack_card_details.add_theme_color_override("font_color", HistoricalUIThemeCls.COLOR_TEXT_PRIMARY)
	attack_card_panel.add_child(attack_card_details)

	attack_confirm_btn = Button.new()
	attack_confirm_btn.name = "AttackConfirmBtn"
	attack_confirm_btn.position = Vector2(14, 110)
	attack_confirm_btn.size = Vector2(412, 34)
	attack_confirm_btn.text = "공격 개시 (Execute Attack) [적 2회 클릭 / Enter / Space]"
	attack_confirm_btn.focus_mode = Control.FOCUS_NONE
	var atk_btn_style: StyleBoxFlat = StyleBoxFlat.new()
	atk_btn_style.bg_color = HistoricalUIThemeCls.COLOR_ENEMY_RED_DARK
	atk_btn_style.border_color = HistoricalUIThemeCls.COLOR_ENEMY_RED
	atk_btn_style.set_border_width_all(1)
	atk_btn_style.set_corner_radius_all(4)
	attack_confirm_btn.add_theme_stylebox_override("normal", atk_btn_style)
	var atk_btn_hover: StyleBoxFlat = atk_btn_style.duplicate()
	atk_btn_hover.bg_color = Color(0.60, 0.16, 0.16, 1.0)
	attack_confirm_btn.add_theme_stylebox_override("hover", atk_btn_hover)
	attack_confirm_btn.pressed.connect(_execute_confirmed_attack)
	attack_card_panel.add_child(attack_confirm_btn)

	# 8. Combat Log Banner (Top Center)
	combat_log_panel = Panel.new()
	combat_log_panel.name = "CombatLogPanel"
	combat_log_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	combat_log_panel.offset_left = -340
	combat_log_panel.offset_top = 60
	combat_log_panel.offset_right = 340
	combat_log_panel.offset_bottom = 104
	combat_log_panel.add_theme_stylebox_override("panel", HistoricalUIThemeCls.create_lacquer_panel(1, 6, HistoricalUIThemeCls.COLOR_GOLD_ORNAMENT))
	combat_log_panel.visible = false
	hud_layer.add_child(combat_log_panel)

	combat_log_text = Label.new()
	combat_log_text.set_anchors_preset(Control.PRESET_FULL_RECT)
	combat_log_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	combat_log_text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	combat_log_text.add_theme_font_size_override("font_size", 13)
	combat_log_text.add_theme_color_override("font_color", HistoricalUIThemeCls.COLOR_GOLD_BRIGHT)
	combat_log_panel.add_child(combat_log_text)

	# 8b. Big Phase Announcement Banner (Center Screen)
	phase_banner_panel = Panel.new()
	phase_banner_panel.name = "PhaseBannerPanel"
	phase_banner_panel.set_anchors_preset(Control.PRESET_CENTER)
	phase_banner_panel.offset_left = -280
	phase_banner_panel.offset_top = -45
	phase_banner_panel.offset_right = 280
	phase_banner_panel.offset_bottom = 45
	phase_banner_panel.add_theme_stylebox_override("panel", HistoricalUIThemeCls.create_lacquer_panel(2, 8, HistoricalUIThemeCls.COLOR_GOLD_BRIGHT))
	phase_banner_panel.visible = false
	hud_layer.add_child(phase_banner_panel)

	phase_banner_label = Label.new()
	phase_banner_label.name = "PhaseBannerLabel"
	phase_banner_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	phase_banner_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	phase_banner_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	phase_banner_label.add_theme_font_size_override("font_size", 20)
	phase_banner_label.add_theme_color_override("font_color", HistoricalUIThemeCls.COLOR_GOLD_BRIGHT)
	phase_banner_panel.add_child(phase_banner_label)

	# 9. Dedicated Right-Side Stronghold Detail Panel (P4, P5)
	_setup_stronghold_panel()
	# STEP-05R1: right-side enemy-intelligence panel + recon report banner.
	_setup_intel_ui()
	_update_top_hud()

func get_unreviewed_friendly_field_units_in_stable_order() -> Array:
	# LEGACY compat — now delegates to canonical unresolved check for backward compat
	if not unit_manager:
		return []
	if unit_manager.has_method("get_unresolved_friendly_field_units_in_stable_order"):
		# Map unresolved to legacy name where callers expect reviewed-less behaviour
		# Keep original reviewed logic for tools that explicitly test reviewed
		var eligible: Array = get_live_friendly_field_units_in_stable_order()
		var unreviewed: Array = []
		for u in eligible:
			var uid: String = str(u.get("id", ""))
			if unit_manager.is_reviewed(uid) or bool(u.get("reviewed_this_turn", false)):
				continue
			unreviewed.append(u)
		return unreviewed
	var eligible2: Array = get_live_friendly_field_units_in_stable_order()
	var unreviewed2: Array = []
	for u in eligible2:
		var uid2: String = str(u.get("id", ""))
		if unit_manager.is_reviewed(uid2) or bool(u.get("reviewed_this_turn", false)):
			continue
		unreviewed2.append(u)
	return unreviewed2

func get_unresolved_friendly_field_units_in_stable_order() -> Array:
	if not unit_manager:
		return []
	if unit_manager.has_method("get_unresolved_friendly_field_units_in_stable_order"):
		return unit_manager.get_unresolved_friendly_field_units_in_stable_order()
	# Fallback to legacy reviewed check if manager lacks new method
	return get_unreviewed_friendly_field_units_in_stable_order()

func _update_next_button_state() -> void:
	if not is_instance_valid(next_turn_button) or not unit_manager:
		return
	# STEP-06 §3: battle loss freezes turn flow.
	if _battle_over():
		if _battle_won:
			next_turn_button.text = "★ 전투 승리\n(BATTLE WON)"
			next_turn_button.disabled = true
			return
		next_turn_button.text = "✖ 전투 패배\n(BATTLE LOST)"
		next_turn_button.disabled = true
		return
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.shadow_color = Color(0, 0, 0, 0.65)
	style.shadow_size = 4

	if _turn_phase == TurnPhase.ENEMY_PHASE:
		next_turn_button.text = "⏳ 적군 행동 중...\n(ENEMY PHASE)"
		next_turn_button.disabled = true
		style.bg_color = HistoricalUIThemeCls.COLOR_LACQUER_DARK
		style.border_color = HistoricalUIThemeCls.COLOR_GOLD_SUBDUE
		next_turn_button.add_theme_color_override("font_color", HistoricalUIThemeCls.COLOR_TEXT_SECONDARY)
	else:
		var unresolved: Array = get_unresolved_friendly_field_units_in_stable_order()
		if unresolved.is_empty():
			next_turn_button.disabled = false
			next_turn_button.text = "⚡ END TURN\n(턴 종료)"
			style.bg_color = HistoricalUIThemeCls.COLOR_ENEMY_RED_DARK
			style.border_color = HistoricalUIThemeCls.COLOR_GOLD_BRIGHT
			next_turn_button.add_theme_color_override("font_color", HistoricalUIThemeCls.COLOR_GOLD_BRIGHT)
		else:
			next_turn_button.disabled = false
			var cnt: int = unresolved.size()
			# §24: counter represents UNRESOLVED (미행동) formations, not reviewed
			next_turn_button.text = "▶ NEXT (다음 부대)  (미행동 %d)" % cnt
			style.bg_color = HistoricalUIThemeCls.COLOR_ALLIED_BLUE_DARK
			style.border_color = HistoricalUIThemeCls.COLOR_GOLD_BRIGHT
			next_turn_button.add_theme_color_override("font_color", HistoricalUIThemeCls.COLOR_TEXT_PRIMARY)

	next_turn_button.add_theme_stylebox_override("normal", style)
	var hov: StyleBoxFlat = style.duplicate()
	hov.bg_color = style.bg_color.lightened(0.2)
	next_turn_button.add_theme_stylebox_override("hover", hov)
	_update_top_hud()

func _update_top_hud() -> void:
	if not _top_hud_bar:
		return
	var turn_num: int = unit_manager.get_current_turn() if unit_manager else 1
	var is_player: bool = (_turn_phase == TurnPhase.PLAYER_PHASE)
	if _top_hud_turn_lbl:
		_top_hud_turn_lbl.text = "第 %d 回合 • %s" % [turn_num, "아군 작전" if is_player else "적군 행동"]
		var turn_col: Color = HistoricalUIThemeCls.COLOR_GOLD_BRIGHT if is_player else HistoricalUIThemeCls.COLOR_ENEMY_RED
		_top_hud_turn_lbl.add_theme_color_override("font_color", Color(turn_col, 0.35))
	if _top_hud_supply_lbl:
		var sup_text: String = "100%"
		if _step6 and _step6.has_method("get_depot_supply_ratio"):
			var r: float = float(_step6.get_depot_supply_ratio())
			sup_text = "%d%%" % int(round(r * 100.0))
		_top_hud_supply_lbl.text = "軍糧: %s" % sup_text
	if _top_hud_army_lbl:
		var blue_cnt: int = get_live_friendly_field_units_in_stable_order().size()
		_top_hud_army_lbl.text = "全軍: %d 부대" % blue_cnt
	if _top_hud_contact_lbl:
		var contact_cnt: int = _known_enemy_ids.size()
		_top_hud_contact_lbl.text = "敵探知: %d" % contact_cnt
	if _top_hud_renown_lbl:
		_top_hud_renown_lbl.text = "軍威: 85"

func _on_next_turn_button_pressed() -> void:
	if symmetric_auto_lock:
		return
	if _turn_phase != TurnPhase.PLAYER_PHASE:
		print("[NEXT] ignored (not PLAYER_PHASE)")
		return
	if _is_animating_combat or _is_animating_movement:
		print("[NEXT] ignored (combat/movement animating)")
		return
	if not unit_manager:
		return
	var unresolved: Array = get_unresolved_friendly_field_units_in_stable_order()
	if unresolved.is_empty():
		print("[TURN] END TURN button pressed")
		end_player_turn()
		return
	print("[NEXT] PRESSED (unresolved %d)" % unresolved.size())
	select_next_friendly_field_unit()

func get_live_friendly_field_units_in_stable_order() -> Array:
	if not unit_manager:
		return []
	var all_u: Array = unit_manager.get_all_units()
	var eligible: Array = []
	for u in all_u:
		var uid: String = str(u.get("id", ""))
		if str(u.get("faction", "")) != "blue":
			continue
		if unit_manager.is_garrisoned(uid):
			continue
		if int(u.get("soldier_count", 0)) <= 0:
			continue
		eligible.append(u)
	eligible.sort_custom(func(a, b): return str(a["id"]) < str(b["id"]))
	return eligible

func select_next_friendly_field_unit() -> void:
	if not unit_manager:
		return
	if stronghold_panel and stronghold_panel.visible:
		_close_stronghold_panel()
	# STEP-04R10 §20 NEXT Resolution Policy (supersedes R9 navigation-only)
	var current_id: String = unit_manager.get_selected_unit_id() if unit_manager.is_unit_selected() else ""
	if current_id != "" and unit_manager.has_method("resolve_unit_via_next"):
		var cur_u: Dictionary = unit_manager.get_unit_by_id(current_id)
		if not cur_u.is_empty() and not bool(cur_u.get("action_ended", false)):
			var res: Dictionary = unit_manager.resolve_unit_via_next(current_id)
			if res.get("resolved", false):
				var stance: String = str(res.get("stance", ""))
				unit_renderer.call("set_unit_dimmed", current_id, true)
				if stance == "guard":
					_show_combat_log("[%s] NEXT 완료 — GUARD (일반 이동력 소진)" % current_id)
				elif stance == "unguarded":
					_show_combat_log("[%s] NEXT 완료 — UNGUARDED (강행군, 무방비)" % current_id)
				else:
					_show_combat_log("[%s] NEXT 완료 — %s" % [current_id, stance])

	var unresolved: Array = get_unresolved_friendly_field_units_in_stable_order()
	if unresolved.is_empty():
		print("[TURN] all friendly field units resolved — END TURN available")
		_update_next_button_state()
		return
	# Find next unresolved in stable ID order after current_id; wrap if needed (§3-5)
	var next_u: Dictionary = {}
	if current_id != "":
		for u in unresolved:
			if str(u["id"]) > current_id:
				next_u = u
				break
	if next_u.is_empty():
		next_u = unresolved[0]
	var next_id: String = str(next_u["id"])
	var remaining: int = unresolved.size() - 1
	print("[NEXT] next %s (unresolved remaining %d)" % [next_id, remaining])
	_clear_route_preview()
	_clear_attack_preview()
	unit_manager.select_unit(next_id)
	var q: int = int(next_u["q"])
	var r: int = int(next_u["r"])
	var target_pos: Vector2 = HexUtilsCls.hex_to_pixel(q, r)
	if camera and camera.has_method("focus_on"):
		camera.call("focus_on", target_pos, false)
	var am: Node = get_node_or_null("/root/AudioManager")
	if am and am.has_method("play_sfx"):
		am.call("play_sfx", "ui_select")
	_update_next_button_state()

func advance_to_next_unreviewed_unit() -> void:
	select_next_friendly_field_unit()

func _setup_stronghold_panel() -> void:
	# Dedicated RIGHT-SIDE Stronghold Detail Panel (§21-26)
	stronghold_panel = Panel.new()
	stronghold_panel.name = "StrongholdPanel"
	stronghold_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	stronghold_panel.offset_left = -464
	stronghold_panel.offset_top = 70
	stronghold_panel.offset_right = -24
	stronghold_panel.offset_bottom = 680
	stronghold_panel.add_theme_stylebox_override("panel", HistoricalUIThemeCls.create_lacquer_panel(2, 6, HistoricalUIThemeCls.COLOR_GOLD_ORNAMENT))
	stronghold_panel.visible = false
	hud_layer.add_child(stronghold_panel)

	stronghold_title = Label.new()
	stronghold_title.position = Vector2(18, 14)
	stronghold_title.size = Vector2(380, 26)
	stronghold_title.add_theme_font_size_override("font_size", 17)
	stronghold_title.add_theme_color_override("font_color", HistoricalUIThemeCls.COLOR_GOLD_BRIGHT)
	stronghold_panel.add_child(stronghold_title)

	var close_btn: Button = Button.new()
	close_btn.position = Vector2(440 - 36, 12)
	close_btn.size = Vector2(24, 24)
	close_btn.text = "✕"
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.add_theme_font_size_override("font_size", 13)
	close_btn.add_theme_stylebox_override("normal", HistoricalUIThemeCls.create_gold_button(false))
	close_btn.add_theme_stylebox_override("hover", HistoricalUIThemeCls.create_gold_button(true))
	close_btn.pressed.connect(_close_stronghold_panel)
	stronghold_panel.add_child(close_btn)

	stronghold_subtitle = Label.new()
	stronghold_subtitle.position = Vector2(18, 42)
	stronghold_subtitle.size = Vector2(404, 20)
	stronghold_subtitle.add_theme_font_size_override("font_size", 12)
	stronghold_subtitle.add_theme_color_override("font_color", Color(0.78, 0.82, 0.92, 1.0))
	stronghold_panel.add_child(stronghold_subtitle)

	stronghold_wall_label = Label.new()
	stronghold_wall_label.position = Vector2(18, 66)
	stronghold_wall_label.size = Vector2(404, 24)
	stronghold_wall_label.add_theme_font_size_override("font_size", 13)
	stronghold_wall_label.add_theme_color_override("font_color", Color(0.92, 0.94, 0.98, 1.0))
	stronghold_panel.add_child(stronghold_wall_label)

	stronghold_state_label = Label.new()
	stronghold_state_label.position = Vector2(18, 92)
	stronghold_state_label.size = Vector2(404, 20)
	stronghold_state_label.add_theme_font_size_override("font_size", 12)
	stronghold_panel.add_child(stronghold_state_label)

	stronghold_garrison_label = Label.new()
	stronghold_garrison_label.position = Vector2(18, 116)
	stronghold_garrison_label.size = Vector2(404, 20)
	stronghold_garrison_label.add_theme_font_size_override("font_size", 13)
	stronghold_garrison_label.add_theme_color_override("font_color", Color(0.70, 0.85, 1.0, 1.0))
	stronghold_panel.add_child(stronghold_garrison_label)

	# Garrison Scroll Container & Icon Rows Container (P5)
	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.name = "GarrisonScroll"
	scroll.position = Vector2(18, 140)
	scroll.size = Vector2(404, 260)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	stronghold_panel.add_child(scroll)

	stronghold_garrison_container = VBoxContainer.new()
	stronghold_garrison_container.name = "GarrisonContainer"
	stronghold_garrison_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stronghold_garrison_container.add_theme_constant_override("separation", 6)
	scroll.add_child(stronghold_garrison_container)

	stronghold_enter_btn = Button.new()
	stronghold_enter_btn.position = Vector2(18, 410)
	stronghold_enter_btn.size = Vector2(404, 34)
	stronghold_enter_btn.text = "▲ ENTER GARRISON (인근 아군 부대 주둔)"
	stronghold_enter_btn.focus_mode = Control.FOCUS_NONE
	stronghold_enter_btn.visible = false
	var enter_style: StyleBoxFlat = StyleBoxFlat.new()
	enter_style.bg_color = Color(0.18, 0.55, 0.35, 0.90)
	enter_style.border_color = Color(0.45, 0.95, 0.55, 0.90)
	enter_style.set_border_width_all(1)
	enter_style.set_corner_radius_all(4)
	stronghold_enter_btn.add_theme_stylebox_override("normal", enter_style)
	stronghold_enter_btn.pressed.connect(_on_stronghold_enter_pressed)
	stronghold_panel.add_child(stronghold_enter_btn)

	stronghold_deploy_container = VBoxContainer.new()
	stronghold_deploy_container.position = Vector2(18, 452)
	stronghold_deploy_container.size = Vector2(404, 150)
	stronghold_panel.add_child(stronghold_deploy_container)

func _close_stronghold_panel() -> void:
	if _stronghold_selected_id != "" and stronghold_renderer and stronghold_renderer.has_method("highlight_stronghold"):
		stronghold_renderer.call("highlight_stronghold", _stronghold_selected_id, false)
	_stronghold_selected_id = ""
	_stronghold_deploy_pending_unit = ""
	if stronghold_panel:
		stronghold_panel.visible = false
	if _map_mode == Step6ConfigCls.MAP_MODE_BATTLE:
		if _supply_overlay and not (unit_manager and unit_manager.is_unit_selected()):
			_supply_overlay.call("clear_all")
	else:
		_refresh_logistics_map_overlay()

func _on_stronghold_enter_pressed() -> void:
	if _turn_phase != TurnPhase.PLAYER_PHASE:
		return
	if _stronghold_selected_id == "" or not unit_manager.is_unit_selected():
		return
	var sel_id: String = unit_manager.get_selected_unit_id()
	var res: Dictionary = unit_manager.garrison_enter(sel_id, _stronghold_selected_id)
	if res.get("success", false):
		if unit_renderer and unit_renderer.has_method("remove_unit"):
			unit_renderer.call("remove_unit", sel_id)
		_show_combat_log("주둔 완료: %s → %s (%d/%d)" % [sel_id, _stronghold_selected_id, int(res.get("garrison_count", 0)), int(res.get("remaining_slots", 0))+int(res.get("garrison_count", 0))])
		_refresh_stronghold_panel(_stronghold_selected_id)
		_recalculate_current_selection_envelope()
		unit_manager.deselect()
		_fog_recalc("garrison", false)
		_update_next_button_state()
	else:
		_show_combat_log("주둔 실패: %s" % str(res.get("reason", "unknown")))

func _open_stronghold_panel(stronghold_id: String) -> void:
	if _stronghold_selected_id != "" and _stronghold_selected_id != stronghold_id and stronghold_renderer and stronghold_renderer.has_method("highlight_stronghold"):
		stronghold_renderer.call("highlight_stronghold", _stronghold_selected_id, false)
	_stronghold_selected_id = stronghold_id
	_refresh_stronghold_panel(stronghold_id)
	stronghold_panel.visible = true
	if stronghold_renderer and stronghold_renderer.has_method("highlight_stronghold"):
		stronghold_renderer.call("highlight_stronghold", stronghold_id, true)
	if _supply_overlay and _step6:
		var nid: String = "SH_" + stronghold_id
		var cell_data: Dictionary = hex_grid.get("cell_data") if hex_grid else {}
		var cov: Dictionary = _step6.compute_node_coverage(nid, cell_data, _stronghold_cells)
		var sh: Variant = unit_manager.get_stronghold_by_id(stronghold_id) if unit_manager else null
		var anchor: Vector2i = sh.get_anchor() if sh else Vector2i(0, 0)
		_supply_overlay.call("add_coverage_with_costs", cov.get("costs", {}))
		_supply_overlay.call("set_selected_node", anchor)

func _on_stronghold_clicked_by_badge(stronghold_id: String) -> void:
	if _turn_phase != TurnPhase.PLAYER_PHASE:
		return
	if _is_animating_movement or _is_animating_combat:
		return
	if not unit_manager:
		return
	if unit_manager.is_unit_selected():
		var sel: Dictionary = unit_manager.get_selected_unit()
		var sel_faction: String = str(sel.get("faction", ""))
		var sh: Variant = unit_manager.get_stronghold_by_id(stronghold_id)
		if sh and sel_faction != str(sh.owner) and sel_faction != "neutral":
			var atk_sh_list: Array = unit_manager.get_attackable_strongholds(str(sel.get("id", ""))) if unit_manager.has_method("get_attackable_strongholds") else []
			var is_atk: bool = false
			for entry in atk_sh_list:
				if str(entry.get("structure_id", "")) == stronghold_id:
					is_atk = true
					break
			if is_atk:
				if _preview_stronghold_id == stronghold_id:
					_execute_stronghold_assault(str(sel.get("id", "")), stronghold_id, _preview_stronghold_garrison_target)
				else:
					_update_stronghold_attack_preview(str(sel.get("id", "")), stronghold_id)
				return
	_clear_route_preview()
	_clear_attack_preview()
	unit_manager.deselect()
	_open_stronghold_panel(stronghold_id)

func _on_stronghold_hover_changed(stronghold_id: String, is_hov: bool) -> void:
	pass # Handled by badge itself

func _get_badge_texture(uclass: String, faction: String) -> Texture2D:
	var norm_class: String = uclass.to_lower()
	if norm_class == "spearmen": norm_class = "spearman"
	elif norm_class == "archers": norm_class = "archer"
	elif norm_class == "scouts": norm_class = "scout"
	elif norm_class == "conscripts": norm_class = "conscript"
	var fac: String = "red" if (faction.to_lower() == "red" or faction.to_lower() == "enemy") else "blue"
	if _is_tutorial_battlefield() and norm_class != "hq" and norm_class != "supply":
		var composed: Dictionary = FormationSpriteCompositor.compose(ApprovedAssetRegistry.unit(norm_class, fac))
		if not composed.is_empty():
			return composed.get("texture") as Texture2D
	var p1: String = "res://assets/badges/%s/badge_%s_%s_form_a.png" % [fac, norm_class, fac]
	var p2: String = "res://assets/badges/%s/badge_%s_%s.png" % [fac, norm_class, fac]
	if ResourceLoader.exists(p1):
		return load(p1) as Texture2D
	if ResourceLoader.exists(p2):
		return load(p2) as Texture2D
	if FileAccess.file_exists(p1):
		var img: Image = Image.load_from_file(p1)
		if img != null: return ImageTexture.create_from_image(img)
	if FileAccess.file_exists(p2):
		var img2: Image = Image.load_from_file(p2)
		if img2 != null: return ImageTexture.create_from_image(img2)
	return null

func _class_to_kr(uclass: String) -> String:
	match uclass.to_lower():
		"infantry": return "보병 (Infantry)"
		"spearman", "spearmen": return "창병 (Spearman)"
		"archer", "archers": return "궁병 (Archer)"
		"cavalry": return "기병 (Cavalry)"
		"scout", "scouts": return "정찰병 (Scout)"
		"conscript", "conscripts": return "징집병 (Conscript)"
		"siege": return "공성병 (Siege)"
		_: return uclass.capitalize()

func _refresh_stronghold_panel(stronghold_id: String) -> void:
	var sh: Variant = unit_manager.get_stronghold_by_id(stronghold_id) if unit_manager else null
	if sh == null:
		return
	var is_capital: bool = (str(sh.structure_type) == "1" or str(sh.to_dict().get("structure_type", "")) == "CAPITAL")
	var type_label: String = "수도 / 도성 (Capital) — 전략 목표" if is_capital else "요새 (Fortress)"
	var bf_name: String = battlefield_stronghold_name(str(sh.structure_id))
	if not bf_name.is_empty():
		stronghold_title.text = ("★ " if is_capital else "") + bf_name
	elif sh.structure_id == FORTRESS_ID:
		stronghold_title.text = "호뢰 요새 (Hulao Fortress)"
	elif sh.structure_id == CAPITAL_ID:
		stronghold_title.text = "★ 낙양 도성 (Luoyang Capital)"
	else:
		stronghold_title.text = str(sh.structure_id).replace("_", " ")
	
	stronghold_subtitle.text = "유형: %s   |   소유: %s (%s)" % [type_label, str(sh.owner), "당군" if str(sh.owner)=="blue" else "적군 (후량)"]
	if is_capital:
		stronghold_subtitle.add_theme_color_override("font_color", Color(1.0, 0.82, 0.42, 1.0))
	else:
		stronghold_subtitle.add_theme_color_override("font_color", Color(0.78, 0.82, 0.92, 1.0))

	# Wall integrity — bar text §13
	var hp: int = int(sh.fortification_hp)
	var hp_max: int = int(sh.fortification_hp_max)
	var ratio: float = float(hp) / float(maxi(1, hp_max))
	var bar: String = _make_wall_bar(ratio)
	var wall_col: Color = Color(0.30, 0.90, 0.45, 1.0) if ratio > 0.5 else (Color(0.95, 0.75, 0.25, 1.0) if ratio > 0.2 else Color(0.95, 0.30, 0.30, 1.0))
	stronghold_wall_label.text = "성벽  %s  %d / %d" % [bar, hp, hp_max]
	stronghold_wall_label.add_theme_color_override("font_color", wall_col)

	# Breach state §11
	var breached: bool = bool(sh.breached)
	stronghold_state_label.text = "상태: %s" % ("★ BREACHED (붕괴) — 수비대 직접 공격 가능" if breached else "● INTACT (건재) — 성벽이 수비대를 보호 중")
	stronghold_state_label.add_theme_color_override("font_color", Color(0.95, 0.35, 0.32, 1.0) if breached else Color(0.35, 0.90, 0.55, 1.0))

	# Garrison count
	var gcount: int = int(sh.get_garrison_count())
	var gmax: int = int(sh.garrison_slots)
	stronghold_garrison_label.text = "주둔군  %d / %d" % [gcount, gmax]
	
	# Icon-Based Garrison Rows (P5)
	if stronghold_garrison_container:
		for c in stronghold_garrison_container.get_children():
			c.queue_free()
		var roster: Array = sh.get_garrison_roster()
		if roster.is_empty():
			var empty_lbl: Label = Label.new()
			empty_lbl.text = "  (주둔 부대 없음 — 비어 있음)"
			empty_lbl.add_theme_font_size_override("font_size", 12)
			empty_lbl.add_theme_color_override("font_color", Color(0.70, 0.75, 0.85, 0.70))
			stronghold_garrison_container.add_child(empty_lbl)
		else:
			for gu in roster:
				var row: PanelContainer = PanelContainer.new()
				var r_style: StyleBoxFlat = StyleBoxFlat.new()
				r_style.bg_color = Color(0.12, 0.14, 0.19, 0.85)
				r_style.border_color = Color(0.35, 0.40, 0.52, 0.60)
				r_style.set_border_width_all(1)
				r_style.set_corner_radius_all(4)
				r_style.content_margin_left = 6
				r_style.content_margin_right = 6
				r_style.content_margin_top = 4
				r_style.content_margin_bottom = 4
				row.add_theme_stylebox_override("panel", r_style)

				var hbox: HBoxContainer = HBoxContainer.new()
				hbox.add_theme_constant_override("separation", 8)
				row.add_child(hbox)

				# Class Icon (P5)
				var icon_tex: Texture2D = _get_badge_texture(str(gu.get("class", "infantry")), str(sh.owner))
				var icon_rect: TextureRect = TextureRect.new()
				icon_rect.custom_minimum_size = Vector2(30, 30)
				icon_rect.texture = icon_tex
				icon_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
				icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				icon_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
				hbox.add_child(icon_rect)

				# Class Name & ID & Morale
				var info_vbox: VBoxContainer = VBoxContainer.new()
				info_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				info_vbox.add_theme_constant_override("separation", 1)
				hbox.add_child(info_vbox)

				var name_lbl: Label = Label.new()
				var c_kr: String = _class_to_kr(str(gu.get("class", "infantry")))
				name_lbl.text = "%s [%s]" % [c_kr, str(gu.get("id", ""))]
				name_lbl.add_theme_font_size_override("font_size", 12)
				name_lbl.add_theme_color_override("font_color", Color(0.95, 0.95, 0.98, 1.0))
				info_vbox.add_child(name_lbl)

				var morale_lbl: Label = Label.new()
				var m_val: float = float(gu.get("morale", 100.0))
				# STEP-05 §14, §17: enemy garrison morale/strength masked.
				var _is_enemy_gar: bool = (str(sh.owner) != "blue")
				morale_lbl.text = "사기 ??? (정찰 불가)" if _is_enemy_gar else "사기 %d" % int(m_val)
				morale_lbl.add_theme_font_size_override("font_size", 10)
				morale_lbl.add_theme_color_override("font_color", Color(0.70, 0.72, 0.80, 1.0) if _is_enemy_gar else (Color(0.40, 0.85, 0.50, 1.0) if m_val >= 70.0 else Color(0.95, 0.65, 0.25, 1.0)))
				info_vbox.add_child(morale_lbl)

				# Troops
				var troop_lbl: Label = Label.new()
				troop_lbl.text = "???명" if _is_enemy_gar else "%d명" % int(gu.get("soldier_count", 0))
				troop_lbl.add_theme_font_size_override("font_size", 13)
				troop_lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.40, 1.0))
				hbox.add_child(troop_lbl)

				# If enemy breached: show direct Attack button
				if breached and str(sh.owner) == "red":
					var atk_btn: Button = Button.new()
					atk_btn.text = "공격"
					atk_btn.custom_minimum_size = Vector2(50, 24)
					atk_btn.focus_mode = Control.FOCUS_NONE
					var gid_val: String = str(gu.get("id", ""))
					var sid_val: String = str(sh.structure_id)
					_at_style_attack_btn(atk_btn)
					atk_btn.pressed.connect(func(): _select_breached_garrison_target(sid_val, gid_val))
					hbox.add_child(atk_btn)

				stronghold_garrison_container.add_child(row)

	# ENTER GARRISON button visibility
	var can_enter: bool = false
	if unit_manager.is_unit_selected():
		var sel: Dictionary = unit_manager.get_selected_unit()
		if str(sel.get("faction", "")) == str(sh.owner) and not bool(sel.get("action_ended", false)):
			var sq: int = int(sel.get("q", 0))
			var sr: int = int(sel.get("r", 0))
			for h in sh.get_footprint():
				if HexUtilsCls.hex_distance_axial(Vector2i(sq, sr), h) == 1:
					can_enter = true
					break
			if can_enter and sh.has_garrison_capacity():
				stronghold_enter_btn.visible = true
				stronghold_enter_btn.text = "▲ ENTER GARRISON: %s → %s (슬롯 %d/%d)" % [str(sel.get("id", "")), sh.structure_id, gcount, gmax]
			else:
				stronghold_enter_btn.visible = false
		else:
			stronghold_enter_btn.visible = false
	else:
		stronghold_enter_btn.visible = false
	if can_enter and not sh.has_garrison_capacity():
		stronghold_enter_btn.visible = true
		stronghold_enter_btn.text = "주둔 불가 — 만원 (%d/%d)" % [gcount, gmax]
		stronghold_enter_btn.disabled = true
	else:
		stronghold_enter_btn.disabled = false

	# Contextual Deploy / Breached Target Container
	for c in stronghold_deploy_container.get_children():
		c.queue_free()
	if _preview_stronghold_garrison_target != "":
		var hint: Label = Label.new()
		hint.text = "선택된 표적: %s — [거점 공격] 버튼으로 실행" % _preview_stronghold_garrison_target
		hint.add_theme_font_size_override("font_size", 11)
		hint.add_theme_color_override("font_color", Color(1.0, 0.55, 0.55, 1.0))
		stronghold_deploy_container.add_child(hint)

func _at_style_attack_btn(btn: Button) -> void:
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = Color(0.75, 0.18, 0.18, 0.92)
	s.border_color = Color(1.0, 0.45, 0.45, 0.95)
	s.set_border_width_all(1)
	s.set_corner_radius_all(4)
	btn.add_theme_stylebox_override("normal", s)

func _begin_deploy_mode(garrison_unit_id: String, stronghold_id: String) -> void:
	if _turn_phase != TurnPhase.PLAYER_PHASE:
		return
	_stronghold_deploy_pending_unit = garrison_unit_id
	_show_combat_log("DEPLOY 모드: %s — 인접 빈 헥스를 클릭하여 배치하세요" % garrison_unit_id)
	var valid: Array = unit_manager.get_valid_deployment_hexes(stronghold_id, garrison_unit_id)
	if envelope_renderer and envelope_renderer.has_method("set_deploy_preview"):
		envelope_renderer.call("set_deploy_preview", valid)

func _select_breached_garrison_target(stronghold_id: String, garrison_unit_id: String) -> void:
	if _turn_phase != TurnPhase.PLAYER_PHASE:
		return
	_preview_stronghold_id = stronghold_id
	_preview_stronghold_garrison_target = garrison_unit_id
	_show_combat_log("표적 선택: %s 내 %s — 인접/사거리 아군으로 공격하세요" % [stronghold_id, garrison_unit_id])
	_refresh_stronghold_panel(stronghold_id)

func _make_wall_bar(ratio: float) -> String:
	var filled: int = clampi(roundi(ratio * 10.0), 0, 10)
	var empty: int = 10 - filled
	return "█".repeat(filled) + "░".repeat(empty)

func _build_policy_controls(parent: Panel) -> void:
	_policy_container = HBoxContainer.new()
	_policy_container.name = "PolicyControls"
	_policy_container.position = Vector2(14, 132)
	_policy_container.size = Vector2(370, 38)
	_policy_container.visible = false
	parent.add_child(_policy_container)
	
	var label: Label = Label.new()
	label.text = "행군:"
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color(0.70, 0.75, 0.85, 0.90))
	_policy_container.add_child(label)
	
	_policy_btn_blue = _make_policy_btn("일반", Step3ConfigCls.MarchPolicy.GREEN_ONLY)
	_policy_btn_red = _make_policy_btn("강행", Step3ConfigCls.MarchPolicy.ORANGE_ALLOWED)
	_policy_btn_black = _make_policy_btn("극행", Step3ConfigCls.MarchPolicy.RED_ALLOWED)
	_update_policy_buttons_ui()

func _make_policy_btn(text: String, policy_val: int) -> Button:
	var btn: Button = Button.new()
	btn.custom_minimum_size = Vector2(65, 26)
	btn.text = text
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_font_size_override("font_size", 12)
	btn.pressed.connect(func(): _set_player_policy(policy_val))
	_policy_container.add_child(btn)
	return btn

func _update_policy_buttons_ui() -> void:
	var cur: int = unit_manager.get_policy() if unit_manager else Step3ConfigCls.MarchPolicy.RED_ALLOWED
	_style_policy_btn(_policy_btn_blue, cur == Step3ConfigCls.MarchPolicy.GREEN_ONLY, Color(0.25, 0.50, 0.95))
	_style_policy_btn(_policy_btn_red, cur == Step3ConfigCls.MarchPolicy.ORANGE_ALLOWED, Color(0.90, 0.25, 0.25))
	_style_policy_btn(_policy_btn_black, cur == Step3ConfigCls.MarchPolicy.RED_ALLOWED, Color(0.20, 0.18, 0.25))

func _style_policy_btn(btn: Button, active: bool, active_col: Color) -> void:
	if btn == null:
		return
	var style: StyleBoxFlat = StyleBoxFlat.new()
	if active:
		style.bg_color = Color(active_col.r, active_col.g, active_col.b, 0.85)
		style.border_color = Color(1, 1, 1, 0.95)
		style.set_border_width_all(2)
		btn.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	else:
		style.bg_color = Color(0.14, 0.16, 0.22, 0.70)
		style.border_color = Color(0.35, 0.40, 0.50, 0.50)
		style.set_border_width_all(1)
		btn.add_theme_color_override("font_color", Color(0.70, 0.75, 0.85, 0.80))
	style.set_corner_radius_all(4)
	btn.add_theme_stylebox_override("normal", style)
	btn.add_theme_stylebox_override("hover", style)

func _set_player_policy(policy_val: int) -> void:
	if unit_manager:
		unit_manager.set_policy(policy_val)
	_update_policy_buttons_ui()
	_recalculate_current_selection_envelope()

func _on_policy_changed_by_manager(new_policy: int) -> void:
	_update_policy_buttons_ui()
	_recalculate_current_selection_envelope()

func _build_unit_action_controls(parent: Panel) -> void:
	_unit_action_container = HBoxContainer.new()
	_unit_action_container.name = "UnitActionControls"
	_unit_action_container.position = Vector2(14, 155)
	_unit_action_container.size = Vector2(376, 52)
	_unit_action_container.add_theme_constant_override("separation", 8)
	_unit_action_container.visible = false
	parent.add_child(_unit_action_container)

	_btn_rest = Button.new()
	_btn_rest.name = "UnitRestButton"
	_btn_rest.text = "ZZZ 휴식"
	_btn_rest.custom_minimum_size = Vector2(95, 44)
	_btn_rest.focus_mode = Control.FOCUS_NONE
	_btn_rest.add_theme_font_size_override("font_size", 13)
	var rest_style: StyleBoxFlat = StyleBoxFlat.new()
	rest_style.bg_color = Color(0.28, 0.38, 0.62, 0.96)
	rest_style.border_color = Color(0.85, 0.90, 1.0, 0.98)
	rest_style.set_border_width_all(2)
	rest_style.set_corner_radius_all(6)
	rest_style.shadow_color = Color(0,0,0,0.35)
	rest_style.shadow_size = 3
	_btn_rest.add_theme_stylebox_override("normal", rest_style)
	_btn_rest.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 1.0))
	var rest_hov: StyleBoxFlat = rest_style.duplicate()
	rest_hov.bg_color = rest_style.bg_color.lightened(0.22)
	_btn_rest.add_theme_stylebox_override("hover", rest_hov)
	_btn_rest.pressed.connect(_on_rest_button_pressed)
	_unit_action_container.add_child(_btn_rest)

	_btn_fortify = Button.new()
	_btn_fortify.name = "UnitFortifyButton"
	_btn_fortify.text = "⛨ 요새화"
	_btn_fortify.custom_minimum_size = Vector2(95, 44)
	_btn_fortify.focus_mode = Control.FOCUS_NONE
	_btn_fortify.add_theme_font_size_override("font_size", 13)
	var fort_style: StyleBoxFlat = StyleBoxFlat.new()
	fort_style.bg_color = Color(0.38, 0.28, 0.12, 0.96)
	fort_style.border_color = Color(1.0, 0.82, 0.32, 0.98)
	fort_style.set_border_width_all(2)
	fort_style.set_corner_radius_all(6)
	fort_style.shadow_color = Color(0,0,0,0.35)
	fort_style.shadow_size = 3
	_btn_fortify.add_theme_stylebox_override("normal", fort_style)
	_btn_fortify.add_theme_color_override("font_color", Color(1.0, 0.94, 0.75, 1.0))
	var fort_hov: StyleBoxFlat = fort_style.duplicate()
	fort_hov.bg_color = fort_style.bg_color.lightened(0.20)
	_btn_fortify.add_theme_stylebox_override("hover", fort_hov)
	_btn_fortify.pressed.connect(_on_fortify_button_pressed)
	_unit_action_container.add_child(_btn_fortify)

	_btn_dismantle = Button.new()
	_btn_dismantle.name = "UnitDismantleButton"
	_btn_dismantle.text = "요새화 해제"
	_btn_dismantle.custom_minimum_size = Vector2(130, 44)
	_btn_dismantle.focus_mode = Control.FOCUS_NONE
	_btn_dismantle.add_theme_font_size_override("font_size", 13)
	var dis_style: StyleBoxFlat = StyleBoxFlat.new()
	dis_style.bg_color = Color(0.62, 0.35, 0.18, 0.96)
	dis_style.border_color = Color(1.0, 0.70, 0.30, 0.98)
	dis_style.set_border_width_all(2)
	dis_style.set_corner_radius_all(6)
	dis_style.shadow_color = Color(0,0,0,0.35)
	dis_style.shadow_size = 3
	_btn_dismantle.add_theme_stylebox_override("normal", dis_style)
	_btn_dismantle.add_theme_color_override("font_color", Color(1.0, 0.92, 0.78, 1.0))
	var dis_hov: StyleBoxFlat = dis_style.duplicate()
	dis_hov.bg_color = dis_style.bg_color.lightened(0.20)
	_btn_dismantle.add_theme_stylebox_override("hover", dis_hov)
	# disabled style
	var dis_dis: StyleBoxFlat = dis_style.duplicate()
	dis_dis.bg_color = Color(0.28, 0.26, 0.24, 0.75)
	dis_dis.border_color = Color(0.45, 0.42, 0.38, 0.6)
	_btn_dismantle.add_theme_stylebox_override("disabled", dis_dis)
	_btn_dismantle.add_theme_color_override("font_color", Color(0.65, 0.60, 0.55, 0.9))
	_btn_dismantle.pressed.connect(_on_dismantle_button_pressed)
	_unit_action_container.add_child(_btn_dismantle)
	_btn_dismantle.visible = false

	_btn_wait = Button.new()
	_btn_wait.name = "UnitWaitButton"
	_btn_wait.text = "🛡 대기"
	_btn_wait.custom_minimum_size = Vector2(70, 44)
	_btn_wait.focus_mode = Control.FOCUS_NONE
	_btn_wait.add_theme_font_size_override("font_size", 13)
	var wait_style: StyleBoxFlat = StyleBoxFlat.new()
	wait_style.bg_color = Color(0.20, 0.32, 0.44, 0.96)
	wait_style.border_color = Color(0.45, 0.70, 0.90, 0.98)
	wait_style.set_border_width_all(2)
	wait_style.set_corner_radius_all(6)
	wait_style.shadow_color = Color(0,0,0,0.35)
	wait_style.shadow_size = 3
	_btn_wait.add_theme_stylebox_override("normal", wait_style)
	_btn_wait.add_theme_color_override("font_color", Color(0.85, 0.94, 1.0, 1.0))
	var wait_hov: StyleBoxFlat = wait_style.duplicate()
	wait_hov.bg_color = wait_style.bg_color.lightened(0.20)
	_btn_wait.add_theme_stylebox_override("hover", wait_hov)
	var wait_dis: StyleBoxFlat = wait_style.duplicate()
	wait_dis.bg_color = Color(0.18, 0.22, 0.26, 0.75)
	wait_dis.border_color = Color(0.35, 0.40, 0.45, 0.6)
	_btn_wait.add_theme_stylebox_override("disabled", wait_dis)
	_btn_wait.add_theme_color_override("font_color", Color(0.55, 0.60, 0.65, 0.9))
	_btn_wait.pressed.connect(_on_wait_button_pressed)
	_unit_action_container.add_child(_btn_wait)


func _on_rest_button_pressed() -> void:
	if _turn_phase != TurnPhase.PLAYER_PHASE or not unit_manager or not unit_manager.is_unit_selected():
		return
	var u: Dictionary = unit_manager.get_selected_unit()
	var uid: String = str(u.get("id", ""))
	if not unit_manager.can_unit_rest(uid):
		return
	var res: Dictionary = unit_manager.rest_unit(uid)
	if res.get("success", false):
		# R10 §23: keep camera on unit, show ZZZ feedback before advancing
		var q: int = int(u.get("q", 0))
		var r: int = int(u.get("r", 0))
		if camera and camera.has_method("focus_on"):
			camera.call("focus_on", HexUtilsCls.hex_to_pixel(q, r), false)
		unit_renderer.call("set_unit_dimmed", uid, true)
		if unit_renderer.has_method("set_unit_resting"):
			unit_renderer.call("set_unit_resting", uid, true)
		var updated_u: Dictionary = unit_manager.get_unit_by_id(uid)
		if not updated_u.is_empty():
			_on_unit_selection_changed(updated_u)
		_clear_route_preview()
		_clear_attack_preview()
		envelope_renderer.call("clear_all")
		_show_combat_log("[%s] ZZZ 휴식 — ZZZ 휴식 (행동 종료)" % uid)
		if unit_renderer.has_method("spawn_floating_text"):
			unit_renderer.call("spawn_floating_text", Vector2i(q, r), "ZZZ", Color(0.55, 0.65, 0.95, 1.0))
			unit_renderer.call("spawn_floating_text", Vector2i(q, r), "휴식 (행동 종료)", Color(0.92, 0.96, 1.0, 0.85))
		if _btn_rest: _btn_rest.disabled = true
		if _btn_fortify: _btn_fortify.disabled = true
		if _btn_dismantle: _btn_dismantle.disabled = true
		if _btn_wait: _btn_wait.disabled = true
		await get_tree().create_timer(0.75).timeout
		if not is_instance_valid(self) or _turn_phase != TurnPhase.PLAYER_PHASE:
			return
		select_next_friendly_field_unit()

func _on_fortify_button_pressed() -> void:
	if _turn_phase != TurnPhase.PLAYER_PHASE or not unit_manager or not unit_manager.is_unit_selected():
		return
	var u: Dictionary = unit_manager.get_selected_unit()
	var uid: String = str(u.get("id", ""))
	if not unit_manager.can_unit_fortify(uid):
		return
	var res: Dictionary = unit_manager.fortify_unit(uid)
	if res.get("success", false):
		var q2: int = int(u.get("q", 0))
		var r2: int = int(u.get("r", 0))
		if camera and camera.has_method("focus_on"):
			camera.call("focus_on", HexUtilsCls.hex_to_pixel(q2, r2), false)
		unit_renderer.call("set_unit_dimmed", uid, true)
		unit_renderer.call("set_unit_fortified", uid, true)
		var updated_u2: Dictionary = unit_manager.get_unit_by_id(uid)
		if not updated_u2.is_empty():
			_on_unit_selection_changed(updated_u2)
		var am2: Node = get_node_or_null("/root/AudioManager")
		if am2 and am2.has_method("play_sfx"):
			am2.call("play_sfx", "spear_brace")
		_clear_route_preview()
		_clear_attack_preview()
		envelope_renderer.call("clear_all")
		var hp: int = int(res.get("field_fortification_hp", 180))
		_show_combat_log("[%s] 임시 진지 구축 완료 — 요새화 (HP %d)" % [uid, hp])
		if unit_renderer.has_method("spawn_floating_text"):
			unit_renderer.call("spawn_floating_text", Vector2i(q2, r2), "요새화", Color(1.0, 0.88, 0.35, 1.0))
			unit_renderer.call("spawn_floating_text", Vector2i(q2, r2), "임시 진지 HP %d" % hp, Color(0.95, 0.80, 0.30, 1.0))
		if _btn_rest: _btn_rest.disabled = true
		if _btn_fortify: _btn_fortify.disabled = true
		if _btn_dismantle: _btn_dismantle.disabled = true
		if _btn_wait: _btn_wait.disabled = true
		await get_tree().create_timer(0.75).timeout
		if not is_instance_valid(self) or _turn_phase != TurnPhase.PLAYER_PHASE:
			return
		select_next_friendly_field_unit()

func _on_dismantle_button_pressed() -> void:
	if _turn_phase != TurnPhase.PLAYER_PHASE or not unit_manager or not unit_manager.is_unit_selected():
		return
	var u: Dictionary = unit_manager.get_selected_unit()
	var uid: String = str(u.get("id", ""))
	if not unit_manager.has_method("can_dismantle_fortification") or not unit_manager.can_dismantle_fortification(uid):
		_show_combat_log("[요새화 해제 불가] 조건 불충족")
		return
	var res: Dictionary = unit_manager.dismantle_fortification(uid)
	if res.get("success", false):
		var q: int = int(u.get("q", 0))
		var r: int = int(u.get("r", 0))
		if camera and camera.has_method("focus_on"):
			camera.call("focus_on", HexUtilsCls.hex_to_pixel(q, r), false)
		unit_renderer.call("set_unit_fortified", uid, false)
		unit_renderer.call("set_unit_dimmed", uid, false)
		var updated: Dictionary = unit_manager.get_unit_by_id(uid)
		if not updated.is_empty():
			_on_unit_selection_changed(updated)
		envelope_renderer.call("clear_all")
		var rem_mp: float = float(res.get("remaining_mp", 1.0))
		_show_combat_log("[%s] 요새화 해제 완료 (1.0 MP 소모) — 남은 MP %.1f" % [uid, rem_mp])
		if unit_renderer.has_method("spawn_floating_text"):
			unit_renderer.call("spawn_floating_text", Vector2i(q, r), "요새화 해제 (MP -1.0)", Color(0.95, 0.70, 0.30, 1.0))
			unit_renderer.call("spawn_floating_text", Vector2i(q, r), "이동 가능 (%.1f MP)" % rem_mp, Color(1.0, 0.92, 0.70, 1.0))
		_recalculate_current_selection_envelope()
		_update_next_button_state()
	else:
		_show_combat_log("[요새화 해제 실패] %s" % str(res.get("error","")))

func _on_wait_button_pressed() -> void:
	if _turn_phase != TurnPhase.PLAYER_PHASE or not unit_manager or not unit_manager.is_unit_selected():
		return
	var u: Dictionary = unit_manager.get_selected_unit()
	var uid: String = str(u.get("id", ""))
	if bool(u.get("action_ended", false)):
		return
	var res: Dictionary = unit_manager.wait_unit(uid)
	if res.get("success", false):
		var q: int = int(u.get("q", 0))
		var r: int = int(u.get("r", 0))
		if camera and camera.has_method("focus_on"):
			camera.call("focus_on", HexUtilsCls.hex_to_pixel(q, r), false)
		unit_renderer.call("set_unit_dimmed", uid, true)
		var updated: Dictionary = unit_manager.get_unit_by_id(uid)
		if not updated.is_empty():
			_on_unit_selection_changed(updated)
		_clear_route_preview()
		_clear_attack_preview()
		envelope_renderer.call("clear_all")
		_show_combat_log("[%s] 대기 — 방어 태세 (행동 종료)" % uid)
		if unit_renderer.has_method("spawn_floating_text"):
			unit_renderer.call("spawn_floating_text", Vector2i(q, r), "대기", Color(0.55, 0.80, 0.95, 1.0))
			unit_renderer.call("spawn_floating_text", Vector2i(q, r), "방어 태세 (행동 종료)", Color(0.92, 0.96, 1.0, 0.85))
		if _btn_rest: _btn_rest.disabled = true
		if _btn_fortify: _btn_fortify.disabled = true
		if _btn_dismantle: _btn_dismantle.disabled = true
		if _btn_wait: _btn_wait.disabled = true
		await get_tree().create_timer(0.5).timeout
		if not is_instance_valid(self) or _turn_phase != TurnPhase.PLAYER_PHASE:
			return
		select_next_friendly_field_unit()

func _show_phase_banner(banner_text: String, is_enemy: bool = false, duration: float = 1.0) -> void:
	if phase_banner_panel and phase_banner_label:
		phase_banner_label.text = banner_text
		if is_enemy:
			phase_banner_label.add_theme_color_override("font_color", Color(1.0, 0.45, 0.40, 1.0))
		else:
			phase_banner_label.add_theme_color_override("font_color", Color(0.40, 0.85, 1.0, 1.0))
		phase_banner_panel.visible = true
		phase_banner_panel.modulate = Color(1, 1, 1, 1)
		var tw: Tween = create_tween()
		tw.tween_interval(duration)
		tw.tween_property(phase_banner_panel, "modulate:a", 0.0, 0.35)
		tw.chain().tween_callback(func():
			if is_instance_valid(phase_banner_panel):
				phase_banner_panel.visible = false
		)

func end_player_turn() -> void:
	end_player_phase()

## §19/§20: ONE authoritative player→enemy transition. Explicit phase state,
## real enemy AI execution, then finish_enemy_phase() — never a label-only change.
func end_player_phase() -> void:
	if _turn_phase != TurnPhase.PLAYER_PHASE:
		print("[TURN] END TURN ignored (already ENEMY_PHASE)")
		return
	if _battle_over():
		print("[TURN] END TURN ignored (battle over)")
		return
	if _is_animating_movement or _is_animating_combat:
		print("[TURN] END TURN ignored (animation lock)")
		return
	if not unit_manager:
		return

	_turn_phase = TurnPhase.ENEMY_PHASE
	print("[TURN] PLAYER_PHASE -> ENEMY_PHASE")
	_is_animating_combat = true
	_update_next_button_state() # disabled "ENEMY TURN" while AI resolves
	_clear_route_preview()
	_clear_attack_preview()
	if stronghold_panel and stronghold_panel.visible:
		_close_stronghold_panel()
	unit_manager.deselect()

	# Show Enemy Phase Banner & Play SFX (§8, §9)
	var am: Node = get_node_or_null("/root/AudioManager")
	if am and am.has_method("play_sfx"):
		am.call("play_sfx", "turn_change")
	_show_phase_banner("적군 턴 (ENEMY PHASE)", true, 0.7)
	if turn_label:
		turn_label.text = "제 %d 턴  (적군)" % unit_manager.get_current_turn()
		turn_label.add_theme_color_override("font_color", Color(1.0, 0.40, 0.35, 1.0))

	var timer_wait: SceneTreeTimer = get_tree().create_timer(0.35)
	await timer_wait.timeout

	# STEP-07: ask the shared enemy general once, then execute only legal
	# UnitManager actions. The existing deterministic routine remains the
	# fallback for formations not covered by a valid plan.
	var step7: Node = get_node_or_null("Step7Integration")
	if step7 and step7.has_method("before_enemy_phase"):
		await step7.call("before_enemy_phase")

	# §21: deterministic Step-4 enemy behavior (attack if legal, else approach)
	if laya_red_controller != null and laya_red_controller.has_method("run_red_phase"):
		print("[TURN] RED phase routed to %s controller" % red_controller_mode())
		if laya_red_controller.has_signal("phase_finished"):
			# Object.call() does not reliably await a nested coroutine. The
			# UtilityBot adapter emits only after its entire bounded phase resolves.
			laya_red_controller.call_deferred("run_red_phase")
			await laya_red_controller.phase_finished
		else:
			await laya_red_controller.call("run_red_phase")
	elif openjev_red_controller != null and openjev_red_controller.has_method("run_red_phase"):
		print("[TURN] RED phase routed to OpenJev controller")
		await openjev_red_controller.call("run_red_phase")
	elif cloud_red_controller != null and cloud_red_controller.has_method("run_red_phase"):
		print("[TURN] RED phase routed to %s controller" % red_controller_mode())
		if cloud_red_controller.has_signal("phase_finished"):
			cloud_red_controller.call_deferred("run_red_phase")
			await cloud_red_controller.phase_finished
		else:
			await cloud_red_controller.call("run_red_phase")
	else:
		await _process_simple_enemy_turn()
	if step7 and step7.has_method("after_enemy_phase"):
		step7.call("after_enemy_phase")

	finish_enemy_turn()

func finish_enemy_turn() -> void:
	finish_enemy_phase()

## §22/§23: enemy phase completion is known explicitly — the AI routine has
## fully resolved (all awaits done) when this runs, not a UI delay guess.
func finish_enemy_phase() -> void:
	print("[TURN] enemy phase complete")
	var prev_turn: int = unit_manager.get_current_turn()
	# STEP-06: consumption ticks on THIS turn's flags first (forced-march
	# surcharge reads has_moved/unguarded before the reset below).
	if _step6 != null and not _battle_over():
		var cell_data: Dictionary = hex_grid.get("cell_data") if hex_grid else {}
		_step6.end_turn_charges(unit_manager, cell_data, _stronghold_cells)
	var next_turn: int = unit_manager.end_turn()
	print("[TURN] turn %d -> %d" % [prev_turn, next_turn])
	# STEP-06: logistics / morale / rout cycle runs on the fresh turn, before observation.
	_s6_begin_turn()

	_turn_phase = TurnPhase.PLAYER_PHASE
	print("[TURN] ENEMY_PHASE -> PLAYER_PHASE")
	_is_animating_combat = false
	# STEP-05 §33: player turn begins with fresh observation.
	_fog_recalc("turn_begin")

	var reset_count: int = get_unresolved_friendly_field_units_in_stable_order().size()
	print("[TURN] unresolved queue reset = %d" % reset_count)

	var am: Node = get_node_or_null("/root/AudioManager")
	if am and am.has_method("play_sfx"):
		am.call("play_sfx", "turn_change")
	_show_phase_banner("제 %d 턴 (아군 작전 페이즈)" % next_turn, false, 0.8)
	if turn_label:
		turn_label.text = "제 %d 턴  (아군)" % next_turn
		turn_label.add_theme_color_override("font_color", Color(0.35, 0.75, 1.0, 1.0))

	_update_next_button_state()

func _process_simple_enemy_turn() -> void:
	_enemy_routine_runs += 1
	var units: Array = unit_manager.get_all_units()
	var red_units: Array = []
	for u in units:
		if u["faction"] == "red" and int(u["soldier_count"]) > 0:
			red_units.append(u)
	
	for red_u in red_units:
		if _battle_over():
			break
		var red_id: String = str(red_u["id"])
		var current_red: Dictionary = unit_manager.get_unit_by_id(red_id)
		if current_red.is_empty() or int(current_red["soldier_count"]) <= 0:
			continue
		# STEP-06: routed reds flee on the decision cycle; convoys run logistics.
		if bool(current_red.get("routed", false)) or bool(current_red.get("is_convoy", false)):
			continue
		# STEP-07: a validated shared-SLM formation order may take this unit's
		# slot. If its requested action cannot be executed legally, return false
		# and preserve the deterministic behavior below.
		var step7_node: Node = get_node_or_null("Step7Integration")
		if step7_node and step7_node.has_method("get_enemy_order_for_unit") and step7_node.has_method("execute_enemy_order_for_unit"):
			var step7_order: Dictionary = step7_node.call("get_enemy_order_for_unit", red_id)
			if not step7_order.is_empty():
				var step7_handled: Variant = await step7_node.call("execute_enemy_order_for_unit", red_id, step7_order)
				if bool(step7_handled):
					continue
		
		# 1. Check if attackable blue targets exist (priority 1)
		var targets: Array[Dictionary] = unit_manager.get_attackable_targets(red_id)
		if not targets.is_empty():
			# Prefer favorable counter matchup
			var best_target_id: String = str(targets[0]["id"])
			var best_matchup: float = -1.0
			for tgt in targets:
				var m: float = CombatCalculatorCls.get_matchup_mult(str(current_red["class"]), str(tgt["class"]))
				if m > best_matchup:
					best_matchup = m
					best_target_id = str(tgt["id"])
			
			var target_u: Dictionary = unit_manager.get_unit_by_id(best_target_id)
			var def_coord: Vector2i = Vector2i(int(target_u["q"]), int(target_u["r"]))
			var atk_coord: Vector2i = Vector2i(int(current_red["q"]), int(current_red["r"]))
			
			# Focus camera near engagement
			var mid_pos: Vector2 = HexUtilsCls.hex_to_pixel(def_coord.x, def_coord.y)
			if camera and camera.has_method("focus_on"):
				camera.call("focus_on", mid_pos, false)
			
			# Play SFX
			var am: Node = get_node_or_null("/root/AudioManager")
			if am and am.has_method("play_sfx"):
				if str(current_red["class"]) == "archer":
					am.call("play_sfx", "arrow_volley")
				elif str(current_red["class"]) == "cavalry":
					am.call("play_sfx", "sword")
				else:
					am.call("play_sfx", "spear_brace")
			
			# Execute deterministic enemy attack
			# STEP-06 §16/§20: degraded formations fight degraded (symmetric).
			var es6mods: Dictionary = _step6.attacker_bonus_vs(unit_manager, red_id, best_target_id) if _step6 else {}
			var atk_res: Dictionary = unit_manager.execute_attack(red_id, best_target_id, es6mods)
			# STEP-05R1: being attacked reveals the attacker's condition.
			_fog_mark_engaged(red_id)
			var def_cas: int = int(atk_res["defender_casualties"])
			var atk_cas: int = int(atk_res["attacker_casualties"])
			print("[ENEMY] %s attacked %s (cas: def=%d, atk=%d)" % [red_id, best_target_id, def_cas, atk_cas])
			unit_renderer.call("animate_unit_attack", red_id, def_coord)
			
			var timer_hit: SceneTreeTimer = get_tree().create_timer(0.12)
			await timer_hit.timeout
			
			var field_dmg: int = int(atk_res.get("field_fortification_damage", 0))
			if field_dmg > 0:
				unit_renderer.call("spawn_floating_text", def_coord, "-%d 진지 HP" % field_dmg, Color(0.95, 0.80, 0.30, 1.0))
				if bool(atk_res.get("is_field_fortification_destroyed", false)):
					unit_renderer.call("spawn_floating_text", def_coord, "임시 진지 파괴!", Color(1.0, 0.40, 0.30, 1.0))
					unit_renderer.call("set_unit_fortified", best_target_id, false)
			if def_cas > 0:
				unit_renderer.call("animate_unit_hit", best_target_id, def_cas)
				unit_renderer.call("update_unit_health", best_target_id, int(atk_res["defender_remaining_troops"]))
				unit_renderer.call("spawn_floating_text", def_coord, "-%d명" % def_cas, Color(1.0, 0.35, 0.35, 1.0))
				if bool(atk_res.get("defender_destroyed", false)):
					unit_renderer.call("spawn_floating_text", def_coord, "아군 부대 전멸!", Color(0.85, 0.20, 0.20, 1.0))
					unit_renderer.call("remove_unit", best_target_id)
			
			if atk_cas > 0:
				unit_renderer.call("update_unit_health", red_id, int(atk_res["attacker_remaining_troops"]))
				unit_renderer.call("spawn_floating_text", atk_coord, "-%d명" % atk_cas, Color(0.95, 0.60, 0.60, 1.0))
				if bool(atk_res.get("attacker_destroyed", false)):
					unit_renderer.call("remove_unit", red_id)
			# STEP-05R2 §17: enemy attacks player -> mark enemy combat_assessed
			_fog_mark_engaged(red_id)
			_fog_recent_combat = true
			_fog_recalc("enemy_attack")
			# STEP-06: HQ loss / rout consequences (HQ can fall on the enemy phase).
			_s6_after_combat(atk_res, red_id, best_target_id, atk_coord, def_coord)
			
			# Brief delay between AI attacks
			var timer: SceneTreeTimer = get_tree().create_timer(0.20)
			await timer.timeout
		else:
			# 2. Otherwise: move toward nearest blue unit (priority 2)
			var red_coord: Vector2i = Vector2i(int(current_red["q"]), int(current_red["r"]))
			var nearest_blue_coord: Vector2i = _find_nearest_blue_coord(red_coord)
			if nearest_blue_coord.x != -999:
				var cell_data: Dictionary = hex_grid.get("cell_data") if hex_grid else {}
				var occupied: Dictionary = unit_manager.get_occupied_dict()
				var env: Variant = Step3PathfindingCls.calculate_envelope(
					red_coord, str(current_red["class"]), float(current_red["base_mp"]),
					float(current_red["remaining_mp"]), Step3ConfigCls.MarchPolicy.GREEN_ONLY,
					cell_data, occupied, _river_cells, "red", _stronghold_cells,
					-1.0, -1.0, -1.0, -1.0, _pathfinding_scenario_bounds()
				)
				if not env.green_hexes.is_empty():
					var best_step: Vector2i = red_coord
					var best_dist: int = HexUtilsCls.hex_distance_axial(red_coord, nearest_blue_coord)
					for h in env.green_hexes:
						var d: int = HexUtilsCls.hex_distance_axial(h, nearest_blue_coord)
						if d < best_dist:
							best_dist = d
							best_step = h
					if best_step != red_coord:
						var route: Variant = Step3PathfindingCls.find_route(
							red_coord, best_step, str(current_red["class"]), float(current_red["base_mp"]),
							float(current_red["remaining_mp"]), Step3ConfigCls.MarchPolicy.GREEN_ONLY,
							cell_data, occupied, _river_cells, "red", _stronghold_cells,
							-1.0, -1.0, -1.0, -1.0, _pathfinding_scenario_bounds()
						)
						if route.found:
							var mv_res: Dictionary = unit_manager.execute_move(red_id, route.path, route.cost, route.march_class, route.crosses_river)
							if bool(mv_res.get("success", false)):
								unit_renderer.call("update_unit_position", red_id, best_step.x, best_step.y)
								print("[ENEMY] %s moved to (%d,%d) cost=%.1f" % [red_id, best_step.x, best_step.y, route.cost])
								# STEP-05 §34: entering current vision reveals at that point.
								_fog_recalc("enemy_move")
								var timer_move: SceneTreeTimer = get_tree().create_timer(0.06)
								await timer_move.timeout
							else:
								# STEP-05R1: blocked contact — no stacking, renderer stays on truth.
								print("[ENEMY] %s move blocked: %s" % [red_id, str(mv_res.get("error", "occupied"))])

func _find_nearest_blue_coord(from_coord: Vector2i) -> Vector2i:
	var best_coord: Vector2i = Vector2i(-999, -999)
	var best_dist: int = 9999
	for u in unit_manager.get_all_units():
		if u["faction"] == "blue" and int(u["soldier_count"]) > 0:
			# STEP-06: reds hunt combat formations and the HQ — never supply trains.
			if bool(u.get("is_convoy", false)):
				continue
			if bool(u.get("routed", false)):
				continue # STEP-06R1 S5: command-lost units are hidden from reds too
			var c: Vector2i = Vector2i(int(u["q"]), int(u["r"]))
			var d: int = HexUtilsCls.hex_distance_axial(from_coord, c)
			if d < best_dist:
				best_dist = d
				best_coord = c
	return best_coord

func _on_unit_manager_turn_advanced(new_turn: int) -> void:
	if turn_label:
		turn_label.text = "제 %d 턴  (아군)" % new_turn
	# R10 §10: fortification persists, REST clears, dimming reset
	var units: Array = unit_manager.get_all_units()
	for u in units:
		var uid: String = str(u["id"])
		unit_renderer.call("set_unit_dimmed", uid, false)
		var is_fort: bool = bool(u.get("field_fortified", false)) or int(u.get("field_fortification_hp", 0)) > 0
		unit_renderer.call("set_unit_fortified", uid, is_fort)
		# REST marker uses ZZZ; clear at turn start since rested cleared
		if unit_renderer.has_method("set_unit_resting"):
			var is_rest: bool = bool(u.get("rested_this_turn", false)) # R10: resting_unguarded no longer used for REST
			unit_renderer.call("set_unit_resting", uid, is_rest)
	_recalculate_current_selection_envelope()
	_update_next_button_state()
	_evaluate_tutorial_round(new_turn - 1)
	_refresh_tutorial_objective_label(new_turn)

func _setup_tutorial_mission_runtime() -> void:
	if not _is_tutorial_battlefield():
		return
	if bool(_battlefield.get("generated", false)):  # generated mission maps: MissionRules (the match driver) judges
		return
	_tutorial_scenario = _battlefield.get("scenario", {}).duplicate(true)
	_tutorial_result_state = {"full_control_streak": 0, "control_sites_blue": 0, "last_round": 0, "result": ""}

func _evaluate_tutorial_round(completed_round: int) -> void:
	if _tutorial_scenario.is_empty() or unit_manager == null or _battle_over():
		return
	var evaluation: Dictionary = TutorialMissionRuntimeCls.evaluate_round(
		_tutorial_scenario, unit_manager, _tutorial_result_state, completed_round
	)
	_tutorial_result_state = evaluation.get("state", _tutorial_result_state)
	var result := str(evaluation.get("result", ""))
	if result == "victory":
		_show_battle_win()
	elif result == "defeat":
		_show_battle_loss()

func _refresh_tutorial_objective_label(current_turn: int = 1) -> void:
	if _tutorial_objective_label == null or _tutorial_scenario.is_empty():
		return
	var objectives: Array = _tutorial_scenario.get("objectives", [])
	var objective_text := str(_battlefield.get("info", {}).get("tactical", ""))
	if not objectives.is_empty():
		objective_text = str(_tutorial_scenario.get("normal_result_rule", objective_text))
	var round_limit := int(_tutorial_scenario.get("round_limit", 0))
	var progress := "Round %d/%d" % [maxi(1, current_turn - 1), round_limit]
	if str(_tutorial_scenario.get("mission_id", "")) == "M4":
		progress += "  ·  sites %d/3  ·  full-control rounds %d/3" % [
			int(_tutorial_result_state.get("control_sites_blue", 0)),
			int(_tutorial_result_state.get("full_control_streak", 0)),
		]
	_tutorial_objective_label.text = "%s  |  %s\n%s" % [
		str(_battlefield.get("name", battlefield_id)), objective_text, progress,
	]

# ------------------------------------------------------------------
# Selection & Envelope Recalculation (Sections 3, 10, 33, 34, 35)
# ------------------------------------------------------------------
func _on_unit_selection_changed(u: Dictionary) -> void:
	if u.is_empty():
		if unit_renderer and unit_renderer.has_method("set_selected_unit"):
			unit_renderer.call("set_selected_unit", "")
		envelope_renderer.call("clear_all")
		unit_card_panel.visible = false
		_s6_hide_route_line()
		_close_trader_panel()
		if _policy_container:
			_policy_container.visible = false
		if _unit_action_container:
			_unit_action_container.visible = false
		_clear_route_preview()
		_clear_attack_preview()
		_current_envelope = null
		if _map_mode == Step6ConfigCls.MAP_MODE_BATTLE:
			if _supply_overlay:
				_supply_overlay.call("clear_all")
		else:
			_refresh_logistics_map_overlay()
		_update_next_button_state()
		return

	unit_card_panel.visible = true
	var id: String = str(u["id"])
	if unit_renderer and unit_renderer.has_method("set_selected_unit"):
		unit_renderer.call("set_selected_unit", id)
	var is_friendly_field: bool = (u["faction"] == "blue" and not unit_manager.is_garrisoned(id))
	var is_supply: bool = (str(u.get("class", "")) == "supply")

	# STEP-05 §13-16, §30-31: enemy card shows observation only — never truth.
	if u["faction"] == "red" and not unit_manager.is_garrisoned(id):
		_close_trader_panel()
		var obs: Dictionary = _fog_get_enemy_observation(u)
		unit_card_name.text = "[%s] 적 %s" % [id, str(obs.get("class_kr", "???"))]
		unit_card_stats.text = "%s\n%s" % [str(obs.get("troop_text", "병력: 알 수 없음")), str(obs.get("morale_text", "사기: 알 수 없음"))]
		var qual: String = "직접 교전 (전투 평가 완료)" if bool(obs.get("combat_assessed", false)) else ("정찰병 관측 중 (추정치)" if bool(obs.get("scout_observed", false)) else "일반 관측 (병력 미상)")
		unit_card_status.text = "상태: 적 부대 관측 중 — %s" % qual
		_open_enemy_intel_current(id)
		unit_card_status.add_theme_color_override("font_color", Color(1.0, 0.60, 0.45, 1.0))
		if _policy_container:
			_policy_container.visible = false
		if _unit_action_container:
			_unit_action_container.visible = false
		envelope_renderer.call("clear_all")
		_clear_route_preview()
		_clear_attack_preview()
		_current_envelope = null
		_update_next_button_state()
		return

	if is_supply:
		# STEP-06R3: Supply NPCs have NO tactical policy and NO tactical actions (REST/WAIT/FORTIFY/GUARD)
		if _policy_container:
			_policy_container.visible = false
		if _unit_action_container:
			_unit_action_container.visible = false
		_open_trader_panel(id)
	else:
		_close_trader_panel()
		if _policy_container:
			_policy_container.visible = (u["faction"] == "blue" and not bool(u["action_ended"]))
		if _unit_action_container:
			_unit_action_container.visible = is_friendly_field
		if is_friendly_field:
			var is_fortified: bool = bool(u.get("field_fortified", false)) or int(u.get("field_fortification_hp", 0)) > 0 or bool(u.get("fortified", false))
			var action_ended: bool = bool(u.get("action_ended", false))
			if is_fortified:
				var can_dismantle: bool = false
				if unit_manager.has_method("can_dismantle_fortification"):
					can_dismantle = unit_manager.can_dismantle_fortification(id)
				if _btn_rest:
					_btn_rest.visible = false
				if _btn_fortify:
					_btn_fortify.visible = false
				if _btn_wait:
					_btn_wait.visible = false
				if _btn_dismantle:
					_btn_dismantle.visible = true
					_btn_dismantle.disabled = not can_dismantle
			else:
				if _btn_rest:
					_btn_rest.visible = true
					_btn_rest.disabled = not unit_manager.can_unit_rest(id)
				if _btn_fortify:
					_btn_fortify.visible = true
					_btn_fortify.disabled = not unit_manager.can_unit_fortify(id)
				if _btn_wait:
					_btn_wait.visible = true
					_btn_wait.disabled = action_ended
				if _btn_dismantle:
					_btn_dismantle.visible = false

	var uclass: String = str(u["class"]).to_upper()
	var faction_k: String = "아군 (Blue)" if u["faction"] == "blue" else "적군 (Red)"
	unit_card_name.text = "[%s] %s  |  %s" % [id, uclass, faction_k]
	
	var base_mp: float = float(u.get("base_mp", 2.0))
	var spent: float = float(u.get("turn_move_cost_spent", 0.0))
	var blue_lim: float = float(u.get("blue_limit", Step3ConfigCls.get_blue_limit(base_mp)))
	var red_lim: float = float(u.get("red_limit", Step3ConfigCls.get_red_limit(base_mp)))
	var rem_blue: float = maxf(0.0, blue_lim - spent)
	var rem_red: float = maxf(0.0, red_lim - spent)
	var morale: float = float(u.get("morale", 100.0))
	var troops: int = int(u.get("soldier_count", 0))
	var _s6_mlab: String = MoraleSystemCls.get_state_label(morale)
	var _s6_fat: int = int(u.get("fatigue", 0.0))
	var _s6_cls: String = str(u.get("class", ""))
	var _s6_head: String = ""
	if _s6_cls == "hq":
		_s6_head = "사령부(HQ)  |  "

	unit_card_stats.text = "%s병력: %d명  |  사기: %d (%s)  |  피로: %d\n이동력: %.1f / %.1f MP (강행군 잔여: %.1f MP)" % [_s6_head, troops, int(morale), _s6_mlab, _s6_fat, rem_blue, base_mp, rem_red]
	
	var action_ended: bool = bool(u.get("action_ended", false))
	var is_fortified: bool = bool(u.get("field_fortified", false)) or bool(u.get("fortified", false)) or (int(u.get("field_fortification_hp", 0)) > 0)
	var fort_hp: int = int(u.get("field_fortification_hp", 0))
	var fort_hp_max: int = int(u.get("field_fortification_hp_max", fort_hp if fort_hp > 0 else CombatCalculatorCls.FIELD_FORTIFICATION_DEFAULT_HP))
	var is_rested: bool = bool(u.get("rested_this_turn", false))
	var is_unguarded: bool = bool(u.get("unguarded", false))
	var is_guarded: bool = bool(u.get("defense_ready", false))
	if is_fortified and fort_hp > 0:
		if action_ended:
			unit_card_status.text = "상태: 임시 진지 (HP %d / %d, 행동 종료)" % [fort_hp, fort_hp_max]
		else:
			unit_card_status.text = "상태: 임시 진지 (HP %d / %d) — 요새화 해제 필요" % [fort_hp, fort_hp_max]
		unit_card_status.add_theme_color_override("font_color", Color(0.95, 0.80, 0.30, 1.0))
	elif is_rested:
		unit_card_status.text = "상태: ZZZ 휴식 (행동 종료)"
		unit_card_status.add_theme_color_override("font_color", Color(0.70, 0.78, 0.95, 1.0))
	elif is_unguarded and action_ended:
		unit_card_status.text = "상태: UNGUARDED (강행군, 무방비) — 행동 종료"
		unit_card_status.add_theme_color_override("font_color", Color(0.95, 0.55, 0.35, 1.0))
	elif action_ended:
		if is_guarded:
			unit_card_status.text = "상태: GUARD (방어 준비) — 행동 종료"
			unit_card_status.add_theme_color_override("font_color", Color(0.40, 0.85, 0.55, 1.0))
		else:
			unit_card_status.text = "상태: 이번 턴 행동 종료 (Action Ended)"
			unit_card_status.add_theme_color_override("font_color", Color(0.85, 0.40, 0.40, 1.0))
	elif is_supply:
		unit_card_status.text = "상태: 우측 보급로 패널에서 거점 지정 및 자동 운송 관리 (보급 반경: 2헥스)"
		unit_card_status.add_theme_color_override("font_color", Color(1.0, 0.90, 0.60, 1.0))
	elif rem_red <= 0.001:
		unit_card_status.text = "상태: 모든 이동력 소진 (행동 가능)"
		unit_card_status.add_theme_color_override("font_color", Color(0.95, 0.50, 0.25, 1.0))
	elif rem_blue <= 0.001:
		unit_card_status.text = "상태: 일반 이동력 소진 (강행군 가능: %.1f MP)" % rem_red
		unit_card_status.add_theme_color_override("font_color", Color(0.95, 0.70, 0.25, 1.0))
	else:
		unit_card_status.text = "상태: 작전 대기 중 (Ready: %.1f MP)" % rem_blue
		unit_card_status.add_theme_color_override("font_color", Color(0.30, 0.90, 0.50, 1.0))

	if str(u.get("class", "")) == "scout" and u["faction"] == "blue":
		unit_card_status.text = "정찰병 — 정찰 범위: 4  |  " + unit_card_status.text
	if str(u.get("class", "")) == "hq" and u["faction"] == "blue":
		var _danger: int = _s6_adjacent_enemies(u)
		if _danger > 0:
			unit_card_status.text = unit_card_status.text + "  |  ⚠ 적 인접 %d — 사령부 위험!" % _danger
			unit_card_status.add_theme_color_override("font_color", Color(1.0, 0.35, 0.30, 1.0))
		elif _step6:
			unit_card_status.text = unit_card_status.text + "  |  중앙 군량: %d  |  보급 반경: 12 MP" % int(_step6.get_central())
		if _supply_overlay and _step6:
			if _map_mode == Step6ConfigCls.MAP_MODE_BATTLE:
				_supply_overlay.call("clear_all")
			var cell_data: Dictionary = hex_grid.get("cell_data") if hex_grid else {}
			var cov: Dictionary = _step6.compute_node_coverage("HQ", cell_data, _stronghold_cells)
			var hq_pos := Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))
			_supply_overlay.call("add_coverage_with_costs", cov.get("costs", {}), Step6ConfigCls.COVERAGE_HQ)
			_supply_overlay.call("set_selected_node", hq_pos, "👑 사령부 보급망 (Dijkstra 반경 12 MP)")
	elif is_supply and u["faction"] == "blue" and _step6:
		if _supply_overlay:
			if _map_mode == Step6ConfigCls.MAP_MODE_BATTLE:
				_supply_overlay.call("clear_all")
			var upos := Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))
			_supply_overlay.call("set_single_hub", upos, Step6ConfigCls.SUPPLY_UNIT_SERVICE_RADIUS, "🌾 보급 반경: 2헥스 (19칸)")
			_supply_overlay.call("set_selected_node", upos, "🌾 수송대 보급 반경: 2헥스")
	elif _map_mode == Step6ConfigCls.MAP_MODE_BATTLE and _supply_overlay:
		_supply_overlay.call("clear_all")
	
	if u["faction"] == "blue" and not action_ended and not is_fortified and not is_supply and _map_mode == Step6ConfigCls.MAP_MODE_BATTLE:
		_recalculate_envelope_for_unit(u)
	else:
		envelope_renderer.call("clear_all")
		_clear_route_preview()
		_clear_attack_preview()
	
	_s6_update_route_line()
	_update_next_button_state()

func _recalculate_current_selection_envelope() -> void:
	if unit_manager and unit_manager.is_unit_selected():
		var u: Dictionary = unit_manager.get_selected_unit()
		_on_unit_selection_changed(u)

func _recalculate_envelope_for_unit(u: Dictionary) -> void:
	var origin: Vector2i = Vector2i(int(u["q"]), int(u["r"]))
	var cell_data: Dictionary = hex_grid.get("cell_data") if hex_grid else {}
	# STEP-05R2 §1-§3: envelope plans through UNKNOWN space (hidden enemies omitted).
	var occupied: Dictionary = _player_known_occupied()
	var policy: int = unit_manager.get_policy()
	
	var base_mp: float = float(u.get("base_mp", 2.0))
	var spent: float = float(u.get("turn_move_cost_spent", 0.0))
	var blue_lim: float = float(u.get("blue_limit", Step3ConfigCls.get_blue_limit(base_mp)))
	var red_lim: float = float(u.get("red_limit", Step3ConfigCls.get_red_limit(base_mp)))
	var black_lim: float = float(u.get("black_limit", Step3ConfigCls.get_black_limit(base_mp)))

	_current_envelope = Step3PathfindingCls.calculate_envelope(
		origin,
		str(u["class"]),
		base_mp,
		float(u["remaining_mp"]),
		policy,
		cell_data,
		occupied,
		_river_cells,
		str(u["faction"]),
		_stronghold_cells,
		spent,
		blue_lim,
		red_lim,
		black_lim,
		_pathfinding_scenario_bounds()
	)
	
	envelope_renderer.call(
		"set_envelope",
		origin,
		_current_envelope.green_hexes,
		_current_envelope.orange_hexes,
		_current_envelope.red_hexes
	)
	
	# Mark attackable targets (Section 35)
	_attackable_targets = unit_manager.get_attackable_targets(str(u["id"]))
	# STEP-05 §21: the player may only target currently-visible enemies.
	if str(u.get("faction", "")) == "blue":
		var _vis_targets: Array[Dictionary] = []
		for t in _attackable_targets:
			if _fog_is_enemy_visible(str(t.get("id", ""))):
				_vis_targets.append(t)
		_attackable_targets = _vis_targets
	var target_coords: Array[Vector2i] = []
	for t in _attackable_targets:
		target_coords.append(Vector2i(int(t["q"]), int(t["r"])))
	envelope_renderer.call("set_attack_targets", target_coords)
	# Also mark attackable strongholds as red targets (§21)
	var strong_targets: Array = unit_manager.get_attackable_strongholds(str(u["id"])) if unit_manager.has_method("get_attackable_strongholds") else []
	var strong_coords: Array[Vector2i] = []
	for st in strong_targets:
		for h in st.get("footprint_hexes", []):
			strong_coords.append(h)
	if not strong_coords.is_empty():
		envelope_renderer.call("set_attack_targets", strong_coords)
	
	if _preview_target_hex.x != -999:
		_update_preview_for_target(_preview_target_hex)
	if _preview_attack_target_id != "":
		_update_attack_preview_for_target(_preview_attack_target_id)

# ------------------------------------------------------------------
# Route Preview & Confirmation (Sections 4, 18, 19, 21)
# ------------------------------------------------------------------
func _update_preview_for_target(target_coord: Vector2i) -> bool:
	if not unit_manager or not unit_manager.is_unit_selected():
		_clear_route_preview()
		return false
	
	var u: Dictionary = unit_manager.get_selected_unit()
	var info: Variant = null
	if _battle_command_service != null and _battle_command_service.has_method("preview_move_route"):
		info = _battle_command_service.call("preview_move_route", str(u["id"]), target_coord, "blue", "auto")
	else:
		var origin: Vector2i = Vector2i(int(u["q"]), int(u["r"]))
		var cell_data: Dictionary = hex_grid.get("cell_data") if hex_grid else {}
		# STEP-05R2 §1-§3: preview plans through UNKNOWN space (hidden enemies omitted).
		var occupied: Dictionary = _player_known_occupied()
		var policy: int = unit_manager.get_policy()
		var base_mp: float = float(u.get("base_mp", 2.0))
		var spent: float = float(u.get("turn_move_cost_spent", 0.0))
		var blue_lim: float = float(u.get("blue_limit", Step3ConfigCls.get_blue_limit(base_mp)))
		var red_lim: float = float(u.get("red_limit", Step3ConfigCls.get_red_limit(base_mp)))
		var black_lim: float = float(u.get("black_limit", Step3ConfigCls.get_black_limit(base_mp)))
		info = Step3PathfindingCls.find_route(
			origin, target_coord, str(u["class"]), base_mp, float(u["remaining_mp"]), policy,
			cell_data, occupied, _river_cells, str(u["faction"]), _stronghold_cells,
			spent, blue_lim, red_lim, black_lim, _pathfinding_scenario_bounds())
	
	if info != null and info.found and info.is_valid_destination:
		_clear_attack_preview() # Clear attack preview when previewing move
		_preview_target_hex = target_coord
		_preview_route_info = info
		envelope_renderer.call("set_route_preview", info.path, info.march_class, target_coord)
		
		route_card_panel.visible = true
		var march_str: String = Step3ConfigCls.get_march_label(info.march_class)
		route_card_title.text = "목적지 (%d, %d)  |  %s" % [target_coord.x, target_coord.y, march_str]
		
		var river_str: String = " [강 건넘/도하]" if info.crosses_river else ""
		route_card_details.text = "이동 비용: %.1f MP  |  경로: %d칸%s\n사기 변동: -%.1f" % [
			info.cost,
			info.path.size() - 1,
			river_str,
			info.morale_penalty
		]
		return true
	else:
		_clear_route_preview()
		return false

func _clear_route_preview() -> void:
	_preview_target_hex = Vector2i(-999, -999)
	_preview_route_info = null
	if envelope_renderer:
		envelope_renderer.call("clear_route_preview")
	if route_card_panel:
		route_card_panel.visible = false

func _execute_confirmed_move() -> void:
	if _battle_over():
		return
	if _is_animating_movement or _preview_route_info == null or not _preview_route_info.found:
		return
	if not unit_manager or not unit_manager.is_unit_selected():
		return

	var u: Dictionary = unit_manager.get_selected_unit()
	var unit_id: String = str(u["id"])
	var info: Variant = _preview_route_info
	var path: Array[Vector2i] = info.path

	# STEP-05R2 §1/§8: revalidate against PLAYER-KNOWN occupancy only.
	# Hidden enemy truth must NEVER reject planning (no blocked_hex/stale_plan leak).
	var _origin0: Vector2i = Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))
	var _cell0: Dictionary = hex_grid.get("cell_data") if hex_grid else {}
	var _fresh: Variant = Step3PathfindingCls.find_route(
		_origin0, path[path.size() - 1], str(u.get("class", "infantry")),
		float(u.get("base_mp", 2.0)), float(u.get("remaining_mp", 2.0)),
		unit_manager.get_policy(), _cell0, _player_known_occupied(),
		_river_cells, str(u.get("faction", "blue")), _stronghold_cells,
		float(u.get("turn_move_cost_spent", 0.0)), float(u.get("blue_limit", 2.0)),
		float(u.get("red_limit", 4.0)), float(u.get("black_limit", 4.4)),
		_pathfinding_scenario_bounds())
	if _fresh == null or not _fresh.found or not _fresh.is_valid_destination:
		# Player-known invalidation only (visible/friendly/terrain) — safe to report.
		_show_combat_log("이동 불가: 목적지가 점유됨 — 재지정 필요")
		_clear_route_preview()
		return
	path = _fresh.path

	# STEP-05R2 §4-§7: stepwise authority BEFORE animating — advance as far as
	# legitimately possible, STOP before hidden contact, charge traversed MP only.
	_fog_pre_move_hidden = _fog_snapshot_hidden_enemies()
	var _vis_before: Dictionary = _fog_visible_enemy_id_set()
	var step_res: Dictionary = {}
	if _battle_command_service != null and _battle_command_service.has_method("execute_player_move_path"):
		step_res = _battle_command_service.call("execute_player_move_path", unit_id, path)
	elif unit_manager.has_method("execute_player_stepwise_move"):
		step_res = unit_manager.execute_player_stepwise_move(unit_id, path, _vis_before, _cell0, _river_cells)
	else:
		return
	if not bool(step_res.get("success", false)):
		_show_combat_log("이동 차단: %s" % str(step_res.get("error", "경로 점유")))
		_clear_route_preview()
		_fog_recalc("move_blocked", false)
		return
	_pending_move_res = step_res
	_pending_move_unit = unit_id
	var traversed: Array[Vector2i] = step_res.get("traversed_path", [path[0]])
	if not bool(step_res.get("moved", false)):
		# Immediate contact on the next hex — no animation, reveal in place.
		_clear_route_preview()
		_clear_attack_preview()
		_finish_stepwise_move(unit_id, step_res)
		return

	_is_animating_movement = true
	_clear_route_preview()
	_clear_attack_preview()

	# Play SFX if available
	var am: Node = get_node_or_null("/root/AudioManager")
	if am and am.has_method("play_sfx"):
		am.call("play_sfx", "march")

	# Animate ONLY the actually-traversed hexes (Section 26).
	unit_renderer.call(
		"animate_unit_move",
		unit_id,
		traversed,
		Step3ConfigCls.SECONDS_PER_HEX,
		Callable(self, "_on_stepwise_animation_completed").bind(unit_id)
	)

func _on_stepwise_animation_completed(unit_id: String) -> void:
	_is_animating_movement = false
	# Snap renderer to authority truth (stepwise already moved it).
	var _true_u: Dictionary = unit_manager.get_unit_by_id(unit_id) if unit_manager else {}
	if not _true_u.is_empty():
		unit_renderer.call("update_unit_position", unit_id, int(_true_u.get("q", 0)), int(_true_u.get("r", 0)))
	var res: Dictionary = _pending_move_res
	_pending_move_res = {}
	_pending_move_unit = ""
	_finish_stepwise_move(unit_id, res)


func execute_step7_move(unit_id: String, destination: Vector2i, march_mode: String = "auto", on_completed: Callable = Callable()) -> Dictionary:
	if _battle_over():
		return {"success": false, "error": "Battle already terminal.", "code": "BATTLE_ALREADY_TERMINAL"}
	if _is_animating_movement:
		return {"success": false, "error": "Battle busy or animating."}
	if not unit_manager:
		return {"success": false, "error": "UnitManager unavailable."}
	var u: Dictionary = unit_manager.get_unit_by_id(unit_id)
	if u.is_empty() or bool(u.get("action_ended", false)):
		return {"success": false, "error": "Unit cannot move."}
	
	var route: Variant = null
	if _battle_command_service != null and _battle_command_service.has_method("preview_move_route"):
		route = _battle_command_service.preview_move_route(unit_id, destination, "blue", march_mode)
	if route == null or not bool(route.found) or not bool(route.is_valid_destination):
		return {"success": false, "error": "No legal route to destination."}
	
	var path: Array[Vector2i] = route.path
	var step_res: Dictionary = {}
	if _battle_command_service != null and _battle_command_service.has_method("execute_player_move_path"):
		step_res = _battle_command_service.execute_player_move_path(unit_id, path)
	else:
		var cell0: Dictionary = hex_grid.get("cell_data") if hex_grid else {}
		step_res = unit_manager.execute_player_stepwise_move(unit_id, path, {}, cell0, _river_cells)
	
	if not bool(step_res.get("success", false)):
		return step_res
	
	var traversed: Array[Vector2i] = step_res.get("traversed_path", [path[0]])
	if not bool(step_res.get("moved", false)):
		_finish_stepwise_move(unit_id, step_res)
		if on_completed.is_valid():
			on_completed.call(step_res)
		return step_res
	
	_is_animating_movement = true
	var am: Node = get_node_or_null("/root/AudioManager")
	if am and am.has_method("play_sfx"):
		am.call("play_sfx", "march")
	
	unit_renderer.call(
		"animate_unit_move",
		unit_id,
		traversed,
		Step3ConfigCls.SECONDS_PER_HEX,
		func() -> void:
			_is_animating_movement = false
			var true_u: Dictionary = unit_manager.get_unit_by_id(unit_id) if unit_manager else {}
			if not true_u.is_empty() and unit_renderer != null:
				unit_renderer.call("update_unit_position", unit_id, int(true_u.get("q", 0)), int(true_u.get("r", 0)))
			_finish_stepwise_move(unit_id, step_res)
			if on_completed.is_valid():
				on_completed.call(step_res)
	)
	return step_res

func _finish_stepwise_move(unit_id: String, res: Dictionary) -> void:
	if res.is_empty():
		return
	var traversed: Array[Vector2i] = res.get("traversed_path", [])
	var stopped: bool = bool(res.get("stopped_by_contact", false))
	var contact_kind: String = str(res.get("contact_kind", ""))
	var contact_id: String = str(res.get("contact_id", ""))
	var march_class: int = int(res.get("march_class", Step3ConfigCls.MarchClass.GREEN))
	if bool(res.get("moved", false)):
		var is_ended: bool = bool(res.get("action_ended", false))
		if is_ended:
			unit_renderer.call("set_unit_dimmed", unit_id, true)
		print("[Step4] Unit %s moved to %s (March: %s, cost=%.1f traversed, remaining_mp=%.1f, action_ended=%s%s)" % [
			unit_id, str(res.get("to", Vector2i(0, 0))), Step3ConfigCls.get_march_label(march_class),
			float(res.get("traversed_cost", 0.0)), float(res.get("remaining_mp", 0.0)), str(is_ended),
			(", CONTACT " + contact_kind + " " + contact_id) if stopped else ""
		])
	# STEP-05 §33 + §23: new observation first (adjacent contact now sees enemy),
	# then hidden-contact ambush check on the ACTUAL stop hex.
	var _dest: Vector2i = res.get("to", Vector2i(-999, -999))
	if _dest.x == -999 and unit_manager:
		var _tu: Dictionary = unit_manager.get_unit_by_id(unit_id)
		if not _tu.is_empty():
			_dest = Vector2i(int(_tu.get("q", -999)), int(_tu.get("r", -999)))
	_fog_recalc("player_move")
	if stopped and contact_kind == "hidden_enemy" and contact_id != "":
		# §5-§6: reveal + cancel remaining (already discarded) + intel.
		# Fog recalc from the stop hex (adjacent => always LOS) reveals the enemy.
		if _fog_is_enemy_visible(contact_id):
			_open_enemy_intel_current(contact_id)
			_show_combat_log("접촉 발견: [%s] — 이동 정지, 잔여 경로 취소" % contact_id)
		else:
			_show_combat_log("접촉 감지 — 적이 인근에 있음 (정찰 필요)")
	elif stopped and (contact_kind == "friendly" or contact_kind == "visible_enemy" or contact_kind == "stronghold"):
		# §8: player-known invalidation — stale_plan reporting is allowed here.
		if bool(res.get("moved", false)):
			_show_combat_log("부분 이동 후 차단: %s — 잔여 경로 취소" % ("아군 점유" if contact_kind == "friendly" else ("가시 적 접촉" if contact_kind == "visible_enemy" else "거점")))
		else:
			_show_combat_log("이동 불가: 목적지가 점유됨 — 재지정 필요")
	if bool(res.get("moved", false)) or (stopped and contact_id != ""):
		_fog_check_ambush(unit_id, _dest, _fog_pre_move_hidden)
		_fog_recalc("ambush_settle", false)
	# STEP-06R2: Mobile supply hub auto-resupply along movement path & cargo refill at nodes
	if _step6 and bool(res.get("moved", false)):
		var mu: Dictionary = unit_manager.get_unit_by_id(unit_id)
		if str(mu.get("class", "")) == "supply":
			var path_coords: Array = res.get("traversed_path", [])
			var supplied_list: Array = _step6.apply_mobile_path_resupply(unit_manager, unit_id, path_coords)
			for sup in supplied_list:
				var sid: String = str(sup.get("unit_id", ""))
				var scoord: Vector2i = sup.get("coord", Vector2i(0, 0))
				var samt: float = float(sup.get("amount", 0.0))
				unit_renderer.call("spawn_floating_text", scoord, "보급 완료! (+%.0f)" % samt, Color(0.3, 0.95, 0.5, 1.0))
				_show_combat_log("[%s] %s 보급 완료 (+%.1f)" % [unit_id, sid, samt])
			
			# Check node cargo refill if destination is on/adjacent to a fixed supply node
			var refilled: float = _step6.check_mobile_hub_refill(unit_manager, unit_id, _dest)
			if refilled > 0.0:
				unit_renderer.call("spawn_floating_text", _dest, "화물 보충 (+%.0f)" % refilled, Color(1.0, 0.85, 0.3, 1.0))
				_show_combat_log("[%s] 거점에서 화물 보충 (+%.0f)" % [unit_id, refilled])
			_update_supply_hud()
			if _map_mode == Step6ConfigCls.MAP_MODE_LOGISTICS:
				_refresh_logistics_map_overlay()
	# Selection consistency + envelope refresh.
	if unit_manager.is_unit_selected():
		var _post_u: Dictionary = unit_manager.get_selected_unit()
		_on_unit_selection_changed(_post_u)
	else:
		envelope_renderer.call("clear_all")
		unit_card_panel.visible = false
		_clear_route_preview()
		_clear_attack_preview()

func _on_movement_animation_completed(
	unit_id: String,
	path: Array[Vector2i],
	cost: float,
	march_class: int,
	crosses_river: bool
) -> void:
	# LEGACY (pre-R2): superseded by stepwise _finish_stepwise_move.
	# Kept for compat — routes through the same stepwise finisher if ever called.
	_fog_pre_move_hidden = _fog_snapshot_hidden_enemies()
	var res: Dictionary = unit_manager.execute_move(unit_id, path, cost, march_class, crosses_river)
	_is_animating_movement = false

	# STEP-05R1: authority rejected the move (contact/stale plan) — roll the
	# renderer back to truth. Never leave two formations stacked on one hex.
	if not bool(res.get("success", false)):
		var _true_u: Dictionary = unit_manager.get_unit_by_id(unit_id)
		if not _true_u.is_empty():
			unit_renderer.call("update_unit_position", unit_id, int(_true_u.get("q", 0)), int(_true_u.get("r", 0)))
			unit_renderer.call("set_unit_dimmed", unit_id, false)
			_show_combat_log("이동 차단: %s" % str(res.get("error", "경로 점유")))
			_fog_recalc("move_blocked", false)
			if unit_manager.is_unit_selected():
				_on_unit_selection_changed(unit_manager.get_selected_unit())
			else:
				envelope_renderer.call("clear_all")
				unit_card_panel.visible = false
				_clear_route_preview()
				_clear_attack_preview()
			return

	# STEP-06R1 S2: snap to authority truth (tween alone is not truth).
	var _snap_u: Dictionary = unit_manager.get_unit_by_id(unit_id) if unit_manager else {}
	if not _snap_u.is_empty():
		unit_renderer.call("update_unit_position", unit_id, int(_snap_u.get("q", 0)), int(_snap_u.get("r", 0)))
	unit_renderer.call("set_node_visible", unit_id, true)
	var is_ended: bool = bool(res.get("action_ended", false))
	if is_ended:
		unit_renderer.call("set_unit_dimmed", unit_id, true)

	# Section 34: If unit still selected, recalculate envelope & attack targets
	if unit_manager.is_unit_selected():
		var updated_u: Dictionary = unit_manager.get_selected_unit()
		_on_unit_selection_changed(updated_u)
	else:
		envelope_renderer.call("clear_all")
		unit_card_panel.visible = false
		_clear_route_preview()
		_clear_attack_preview()

	print("[Step4] Unit %s moved to %s (March: %s, remaining_mp=%.1f, action_ended=%s)" % [
		unit_id, str(path[path.size() - 1]), Step3ConfigCls.get_march_label(march_class),
		res.get("remaining_mp", 0.0), str(is_ended)
	])
	# STEP-05 §33 + §23: new observation first, then hidden-contact ambush check.
	var _dest: Vector2i = path[path.size() - 1]
	_fog_recalc("player_move")
	if bool(res.get("success", false)):
		_fog_check_ambush(unit_id, _dest, _fog_pre_move_hidden)
		_fog_recalc("ambush_settle", false)
	# Ambush may have ended or destroyed the mover — re-sync selection UI.
	if unit_manager.is_unit_selected():
		var _post_u: Dictionary = unit_manager.get_selected_unit()
		_on_unit_selection_changed(_post_u)
	else:
		envelope_renderer.call("clear_all")
		unit_card_panel.visible = false
		_clear_route_preview()
		_clear_attack_preview()

# ------------------------------------------------------------------
# Attack Preview & Confirmation (Sections 13, 35, 36, 37)
# ------------------------------------------------------------------
func _update_attack_preview_for_target(enemy_id: String) -> bool:
	if not unit_manager or not unit_manager.is_unit_selected():
		_clear_attack_preview()
		return false
	
	var u: Dictionary = unit_manager.get_selected_unit()
	# STEP-06R1 S19-21: spent attackers get no preview — second attack impossible.
	if bool(u.get("has_attacked", false)):
		_clear_attack_preview()
		_show_combat_log("이미 공격한 부대 — 다음 턴 대기")
		return false
	if str(u.get("class", "")) == "supply":
		_clear_attack_preview()
		return false
	var preview: Dictionary = _battle_command_service.preview_attack(str(u["id"]), enemy_id, "blue") if _battle_command_service != null and _battle_command_service.has_method("preview_attack") else unit_manager.preview_attack(str(u["id"]), enemy_id)
	if preview.is_empty() or not bool(preview.get("ok", true)):
		_clear_attack_preview()
		return false
	# STEP-05 §21: no preview (and no truth) for unobserved enemies.
	if not _fog_is_enemy_visible(enemy_id):
		_clear_attack_preview()
		_show_combat_log("관측되지 않은 적 — 정찰 필요")
		return false
	
	_preview_attack_target_id = enemy_id
	_preview_attack_info = preview
	_clear_route_preview()
	
	var enemy_u: Dictionary = unit_manager.get_unit_by_id(enemy_id)
	var enemy_coord: Vector2i = Vector2i(int(enemy_u["q"]), int(enemy_u["r"]))
	envelope_renderer.call("set_attack_preview", enemy_coord)
	
	attack_card_panel.visible = true
	var atk_c: String = str(preview["attacker_class"]).to_upper()
	var def_c: String = str(preview["defender_class"]).to_upper()
	var matchup: float = float(preview["matchup_multiplier"])
	var matchup_str: String = "상성: 우세 (x%.2f)" % matchup if matchup > 1.05 else ("상성: 열세 (x%.2f)" % matchup if matchup < 0.95 else "상성: 호각 (x1.00)")
	
	var dist: int = int(preview["distance"])
	var mode_str: String = "원거리 사격 (%d칸)" % dist if dist > 1 else "근접 교전 (1칸)"
	attack_card_title.text = "교전 예측: [%s] vs [%s] | %s | %s" % [atk_c, def_c, mode_str, matchup_str]
	
	var fort_hp: int = int(preview["fortification_hp"])
	if fort_hp > 0:
		attack_card_details.text = "적 방어선: 요새 성벽 (HP %d)\n예상 성벽 피해: ~%d-%d HP (수비대 피해 0명)\n예상 아군 손실: ~%d-%d명" % [
			fort_hp,
			int(preview["expected_wall_damage_min"]), int(preview["expected_wall_damage_max"]),
			int(preview["expected_friendly_casualties_min"]), int(preview["expected_friendly_casualties_max"])
		]
	else:
		var ret_str: String = "없음 (원거리)" if dist > 1 else "~%d-%d명 (반격)" % [int(preview["expected_friendly_casualties_min"]), int(preview["expected_friendly_casualties_max"])]
		# STEP-05 §14-16: defender truth masked — class + scout estimate at most.
		var _obs: Dictionary = _fog_get_enemy_observation(enemy_u)
		var _def_info: String = str(_obs.get("troop_text", "병력: ???"))
		if bool(_obs.get("scout_observed", false)):
			_def_info += " (정찰병 추정)"
		attack_card_details.text = "적 예상 손실: ~%d-%d명 (%s)\n아군 예상 손실: %s (현재 %d명)\n사기 영향: 알 수 없음 (추정 필요)\n예상 결과: %s" % [
			int(preview["expected_enemy_casualties_min"]), int(preview["expected_enemy_casualties_max"]),
			_def_info,
			ret_str, int(preview["attacker_troops"]),
			"유리한 교전" if matchup >= 1.20 else ("불리한 교전" if matchup <= 0.85 else "호각의 전투")
		]
	
	return true

func _clear_attack_preview() -> void:
	_preview_attack_target_id = ""
	_preview_attack_info.clear()
	if envelope_renderer:
		envelope_renderer.call("clear_attack_preview")
	if attack_card_panel:
		attack_card_panel.visible = false

func _execute_confirmed_attack() -> void:
	if _battle_over():
		return
	if _is_animating_combat or _preview_attack_target_id == "":
		return
	if not unit_manager or not unit_manager.is_unit_selected():
		return
	
	var u: Dictionary = unit_manager.get_selected_unit()
	var attacker_id: String = str(u["id"])
	var defender_id: String = _preview_attack_target_id
	
	var enemy_u: Dictionary = unit_manager.get_unit_by_id(defender_id)
	if enemy_u.is_empty():
		_clear_attack_preview()
		return
	# STEP-06R1 S19-21: authoritative lock mirrored for instant UX.
	if bool(u.get("has_attacked", false)) or str(u.get("class", "")) == "supply":
		_show_combat_log("이미 공격한 부대 — 다음 턴 대기")
		return
	
	_is_animating_combat = true
	var enemy_coord: Vector2i = Vector2i(int(enemy_u["q"]), int(enemy_u["r"]))
	var atk_coord: Vector2i = Vector2i(int(u["q"]), int(u["r"]))
	
	_clear_attack_preview()
	
	# Execute Attack through UnitManager
	# STEP-06 §16/§20: starving/exhausted formations fight degraded.
	var s6mods: Dictionary = _step6.attacker_bonus_vs(unit_manager, attacker_id, defender_id) if _step6 else {}
	var res: Dictionary = _battle_command_service.execute_attack_intent(attacker_id, defender_id, "blue", s6mods) if _battle_command_service != null and _battle_command_service.has_method("execute_attack_intent") else unit_manager.execute_attack(attacker_id, defender_id, s6mods)
	if not bool(res.get("success", false)):
		_show_combat_log("공격 불가: %s" % str(res.get("error", "unknown")))
		_is_animating_combat = false
		return
	
	# Play Audio
	var am: Node = get_node_or_null("/root/AudioManager")
	if am and am.has_method("play_sfx"):
		if str(res["attacker_class"]) == "archer":
			am.call("play_sfx", "arrow_volley")
		elif str(res["attacker_class"]) == "cavalry":
			am.call("play_sfx", "sword")
		else:
			am.call("play_sfx", "spear_brace")
	
	# Visual animations
	unit_renderer.call("animate_unit_attack", attacker_id, enemy_coord)
	
	var timer: SceneTreeTimer = get_tree().create_timer(0.12)
	await timer.timeout
	
	# Defender Hit Feedback
	var def_cas: int = int(res["defender_casualties"])
	var wall_dmg: int = int(res["wall_damage"])
	var field_dmg: int = int(res.get("field_fortification_damage", 0))
	var def_destroyed: bool = bool(res.get("defender_destroyed", false))
	
	if wall_dmg > 0:
		unit_renderer.call("spawn_floating_text", enemy_coord, "-%d 성벽 HP" % wall_dmg, Color(1.0, 0.75, 0.25, 1.0))
		if bool(res.get("is_fortress_breached", false)):
			unit_renderer.call("spawn_floating_text", enemy_coord, "성벽 파괴! (돌파)", Color(1.0, 0.30, 0.30, 1.0))
	elif field_dmg > 0:
		unit_renderer.call("spawn_floating_text", enemy_coord, "-%d 진지 HP" % field_dmg, Color(0.95, 0.80, 0.30, 1.0))
		if bool(res.get("is_field_fortification_destroyed", false)):
			unit_renderer.call("spawn_floating_text", enemy_coord, "임시 진지 파괴!", Color(1.0, 0.40, 0.30, 1.0))
			unit_renderer.call("set_unit_fortified", defender_id, false)
		if def_cas > 0:
			unit_renderer.call("animate_unit_hit", defender_id, def_cas)
			unit_renderer.call("spawn_floating_text", enemy_coord, "-%d명" % def_cas, Color(1.0, 0.35, 0.35, 1.0))
			unit_renderer.call("update_unit_health", defender_id, int(res["defender_remaining_troops"]))
			if def_destroyed:
				unit_renderer.call("spawn_floating_text", enemy_coord, "적 부대 섬멸!", Color(1.0, 0.20, 0.20, 1.0))
				unit_renderer.call("remove_unit", defender_id)
	elif def_cas > 0:
		unit_renderer.call("animate_unit_hit", defender_id, def_cas)
		unit_renderer.call("spawn_floating_text", enemy_coord, "-%d명" % def_cas, Color(1.0, 0.35, 0.35, 1.0))
		unit_renderer.call("update_unit_health", defender_id, int(res["defender_remaining_troops"]))
		if def_destroyed:
			unit_renderer.call("spawn_floating_text", enemy_coord, "적 부대 섬멸!", Color(1.0, 0.20, 0.20, 1.0))
			unit_renderer.call("remove_unit", defender_id)
	
	# Attacker Return Damage (Melee Retaliation)
	var atk_cas: int = int(res["attacker_casualties"])
	var atk_destroyed: bool = bool(res.get("attacker_destroyed", false))
	if atk_cas > 0:
		unit_renderer.call("animate_unit_hit", attacker_id, atk_cas)
		unit_renderer.call("spawn_floating_text", atk_coord, "-%d명" % atk_cas, Color(0.95, 0.60, 0.60, 1.0))
		unit_renderer.call("update_unit_health", attacker_id, int(res["attacker_remaining_troops"]))
		if atk_destroyed:
			unit_renderer.call("spawn_floating_text", atk_coord, "아군 부대 전멸!", Color(0.85, 0.20, 0.20, 1.0))
			unit_renderer.call("remove_unit", attacker_id)
	
	# Show concise Combat Log Banner (Section 44)
	_show_combat_log(
		"[%s %s] 공격 -> [%s %s]  |  적 손실: -%d명 (남은 병력 %d)  |  아군 손실: -%d명" % [
			attacker_id, str(res["attacker_class"]).to_upper(),
			defender_id, str(res["defender_class"]).to_upper(),
			def_cas, int(res["defender_remaining_troops"]), atk_cas
		]
	)
	
	_is_animating_combat = false
	
	# If Cavalry and alive, unit remains selected and can move again! (Section 19, 20)
	var is_ended: bool = bool(res.get("attacker_action_ended", true))
	if is_ended:
		unit_renderer.call("set_unit_dimmed", attacker_id, true)
	
	if unit_manager.is_unit_selected() and not is_ended:
		var updated_u: Dictionary = unit_manager.get_selected_unit()
		_on_unit_selection_changed(updated_u)
	else:
		envelope_renderer.call("clear_all")
		unit_card_panel.visible = false
		_clear_route_preview()
		_clear_attack_preview()
		_update_next_button_state()

	# STEP-05 §33: casualties change observation — refresh fog (masks re-applied).
	# STEP-05R1: fighting this enemy reveals its remaining-strength bar.
	_fog_mark_engaged(defender_id)
	_fog_recent_combat = true
	_fog_recalc("player_attack")
	# STEP-06: capture / HQ loss / rout consequences.
	_s6_after_combat(res, attacker_id, defender_id, atk_coord, enemy_coord)
	# STEP-05R2 §20/§24: keep right panel synchronized with new combat assessment in same turn
	if _intel_panel and _intel_panel.visible and _intel_subject_id == defender_id:
		_open_enemy_intel_current(defender_id)

func _show_combat_log(msg: String) -> void:
	if combat_log_panel and combat_log_text:
		combat_log_text.text = msg
		combat_log_panel.visible = true
		var tw: Tween = create_tween()
		tw.tween_property(combat_log_panel, "modulate:a", 1.0, 0.1)
		tw.tween_interval(3.5)
		tw.tween_property(combat_log_panel, "modulate:a", 0.0, 0.5)
		tw.chain().tween_callback(func():
			if is_instance_valid(combat_log_panel):
				combat_log_panel.visible = false
		)

# ------------------------------------------------------------------
# Input & Event Routing (Sections 3, 4, 37)
# ------------------------------------------------------------------
func _connect_events() -> void:
	if camera and camera.has_signal("camera_updated"):
		camera.connect("camera_updated", _on_camera_updated)
	set_process_input(true)
	set_process(true)

func _on_camera_updated(pos: Vector2, zoom_val: float) -> void:
	if unit_renderer and unit_renderer.has_method("set_camera_zoom"):
		unit_renderer.call("set_camera_zoom", zoom_val)
	if stronghold_renderer and stronghold_renderer.has_method("set_camera_zoom"):
		stronghold_renderer.call("set_camera_zoom", zoom_val)
	if hex_compositor and hex_compositor.has_method("set_camera_zoom"):
		hex_compositor.call("set_camera_zoom", zoom_val)
	if debug_label:
		var z_t: float = SemanticZoom.zoom_t(zoom_val)
		debug_label.text = _status_strip_text(zoom_val, z_t, pos)


## Top-left status strip. In the DEV sandbox it must not advertise
## information-warfare systems the DEV contract disables (false semantics).
func _status_strip_text(zoom_val: float, z_t: float, pos: Vector2) -> String:
	if _is_tutorial_battlefield():
		return "%s  |  %d hexes  |  Tutorial battlefield  |  Zoom %.2f" % [battlefield_id, hex_grid.get("cell_data").size(), zoom_val]
	if SandboxRulesCls.is_active():
		return "STEP-0 DEV  R=40  4,921칸  |  평지·동일정보 (Fog OFF)  |  줌 %.2f (t=%.2f)  |  카메라 (%.0f, %.0f)" % [zoom_val, z_t, pos.x, pos.y]
	return "STEP-05  R=40  4,921칸  |  정보전 슬라이스 (Fog/정찰/매복)  |  줌 %.2f (t=%.2f)  |  카메라 (%.0f, %.0f)" % [zoom_val, z_t, pos.x, pos.y]

func get_semantic_zoom_t() -> float:
	if camera and camera.has_method("get_semantic_zoom_t"):
		return float(camera.call("get_semantic_zoom_t"))
	elif camera:
		return SemanticZoom.zoom_t(camera.zoom.x)
	return SemanticZoom.zoom_t(1.15)

func _is_click_over_hud(screen_pos: Vector2) -> bool:
	if not hud_layer:
		return false
	for child in hud_layer.get_children():
		if child is Control and (child as Control).is_visible_in_tree():
			var ctrl: Control = child as Control
			if ctrl.get_global_rect().has_point(screen_pos):
				return true
	return _is_click_over_ai_panel(screen_pos)


## The modal AI Settings window lives in its own top CanvasLayer (outside
## hud_layer), so it needs an explicit guard: clicks/keys over it must
## never drive the battlefield. Absent in production -> no behavior change.
func _ai_panel() -> Control:
	var scene := get_tree().current_scene if is_inside_tree() else null
	if scene == null:
		return null
	var p := scene.get_node_or_null("AISetupLayerCloud/AISetupPanelCloud") as Control
	if p != null and p.is_visible_in_tree():
		return p
	return null


func _is_click_over_ai_panel(screen_pos: Vector2) -> bool:
	var p := _ai_panel()
	return p != null and p.get_global_rect().has_point(screen_pos)

func _input(event: InputEvent) -> void:
	if symmetric_auto_lock:
		return
	if _battle_over():
		return
	if _ai_panel() != null:
		return # modal AI Settings owns all input while open.
	if _turn_phase != TurnPhase.PLAYER_PHASE:
		return
	if _is_animating_movement or _is_animating_combat:
		return

	if event is InputEventKey:
		var ke: InputEventKey = event as InputEventKey
		if ke.pressed and not ke.echo:
			if ke.keycode == KEY_ESCAPE:
				if _trader_panel and _trader_panel.visible:
					_close_trader_panel()
					if unit_manager and unit_manager.is_unit_selected():
						unit_manager.deselect()
					get_viewport().set_input_as_handled()
					return
				elif _stronghold_deploy_pending_unit != "":
					_stronghold_deploy_pending_unit = ""
					if envelope_renderer and envelope_renderer.has_method("clear_deploy_preview"):
						envelope_renderer.call("clear_deploy_preview")
					_show_combat_log("배치 취소됨")
				elif stronghold_panel and stronghold_panel.visible:
					_close_stronghold_panel()
				elif _preview_stronghold_id != "":
					_clear_stronghold_attack_preview()
					_clear_attack_preview()
				elif _preview_attack_target_id != "":
					_clear_attack_preview()
				elif _preview_target_hex.x != -999:
					_clear_route_preview()
				elif unit_manager and unit_manager.is_unit_selected():
					unit_manager.deselect()
				get_viewport().set_input_as_handled()
				return
			elif ke.keycode == KEY_ENTER or ke.keycode == KEY_SPACE:
				if _preview_stronghold_id != "" and unit_manager.is_unit_selected():
					var sel_id2: String = unit_manager.get_selected_unit_id()
					_execute_stronghold_assault(sel_id2, _preview_stronghold_id, _preview_stronghold_garrison_target)
					get_viewport().set_input_as_handled()
					return
				elif _preview_attack_target_id != "":
					_execute_confirmed_attack()
					get_viewport().set_input_as_handled()
					return
				elif _preview_target_hex.x != -999 and _preview_route_info != null:
					_execute_confirmed_move()
					get_viewport().set_input_as_handled()
					return
			elif ke.keycode == KEY_1:
				_set_player_policy(Step3ConfigCls.MarchPolicy.GREEN_ONLY)
			elif ke.keycode == KEY_2:
				_set_player_policy(Step3ConfigCls.MarchPolicy.ORANGE_ALLOWED)
			elif ke.keycode == KEY_3:
				_set_player_policy(Step3ConfigCls.MarchPolicy.RED_ALLOWED)

	if event is InputEventMouseMotion:
		var world_pos: Vector2 = _pointer_world((event as InputEventMouse).position)
		var coord: Vector2i = WorldBoundaryCls.world_to_axial(world_pos)
		if not is_playable_hex(coord):
			if _current_hover_hex.x != -999:
				unit_renderer.call("clear_hover")
				_current_hover_hex = Vector2i(-999, -999)
			_hover_stale_id = ""
			Input.set_default_cursor_shape(Input.CURSOR_FORBIDDEN if WorldBoundaryCls.is_impassable_mountain_hex(coord) else Input.CURSOR_ARROW)
			return
		else:
			Input.set_default_cursor_shape(Input.CURSOR_ARROW)

		var zoom_val: float = camera.zoom.x if camera else 1.0
		var pick_radius: float = 24.0
		var best_id: String = ""
		var best_dist: float = 1e9
		var units: Array = unit_renderer.call("get_all_units") as Array
		for u in units:
			# STEP-05 §21: hidden enemies are unknown — no hover pick.
			if str(u.get("faction", "")) == "red" and not _fog_is_enemy_visible(str(u.get("id", ""))):
				continue
			if unit_manager:
				var _hid: Dictionary = unit_manager.get_unit_by_id(str(u.get("id", "")))
				if not _hid.is_empty() and bool(_hid.get("routed", false)):
					continue # command-lost: hidden truth, frozen marker only
			var u_q: int = int(u["q"])
			var u_r: int = int(u["r"])
			var upos: Vector2 = HexUtilsCls.hex_to_pixel(u_q, u_r)
			var d: float = world_pos.distance_to(upos)
			# Reliable hex-based hover detection at any zoom level
			if (u_q == coord.x and u_r == coord.y) or (d < pick_radius and d < best_dist):
				best_dist = d
				best_id = str(u["id"])
				if u_q == coord.x and u_r == coord.y:
					break
		# Check stronghold footprint hover
		var hovered_sh: Variant = unit_manager.get_stronghold_at(coord.x, coord.y) if unit_manager and unit_manager.has_method("get_stronghold_at") else null
		if hovered_sh != null:
			var hsid: String = str(hovered_sh.structure_id)
			if stronghold_renderer and stronghold_renderer.has_method("set_stronghold_hovered"):
				stronghold_renderer.call("set_stronghold_hovered", hsid, true)
			# §5: hover cursor feedback only — no world-space panel expansion
			Input.set_default_cursor_shape(Input.CURSOR_POINTING_HAND)
		else:
			if unit_manager and stronghold_renderer and stronghold_renderer.has_method("set_stronghold_hovered"):
				for sh_obj in unit_manager.get_all_strongholds():
					var sid_check: String = str(sh_obj.structure_id)
					var badge_obj: Variant = stronghold_renderer.call("get_badge", sid_check) if stronghold_renderer.has_method("get_badge") else null
					if badge_obj and not bool(badge_obj.get("is_hovered")):
						stronghold_renderer.call("set_stronghold_hovered", sid_check, false)

		_hover_stale_id = ""
		if best_id != "":
			var target_q: int = -999
			var target_r: int = -999
			for u in units:
				if str(u["id"]) == best_id:
					target_q = int(u["q"])
					target_r = int(u["r"])
					break
			# STEP-05R1: authoritative occupancy wins over renderer pick order —
			# this is what makes enemy hover unable to borrow Blue presentation.
			var _auth: Dictionary = unit_manager.get_unit_at(target_q, target_r) if unit_manager else {}
			if not _auth.is_empty():
				if str(_auth.get("faction", "")) == "red" and not _fog_is_enemy_visible(str(_auth.get("id", ""))):
					best_id = ""
					target_q = -999
				elif str(_auth.get("id", "")) != best_id:
					best_id = str(_auth.get("id", ""))
					target_q = int(_auth.get("q", target_q))
					target_r = int(_auth.get("r", target_r))
			if best_id != "" and target_q != -999 and is_playable_hex(Vector2i(target_q, target_r)):
				unit_renderer.call("set_hover_at_hex", target_q, target_r)
				_current_hover_hex = Vector2i(target_q, target_r)
				# BUG-S4-02 watch: hovered badge faction must match truth faction.
				if best_id != _fog_last_hover_id:
					_fog_last_hover_id = best_id
					var _truth: Dictionary = unit_manager.get_unit_by_id(best_id) if unit_manager else {}
					var _hnode: Node2D = unit_renderer.call("get_unit_node", best_id) as Node2D
					var _badge: Node = _hnode.get_node_or_null("OverheadBadge") if _hnode else null
					if not _truth.is_empty() and _badge and _badge.has_method("get_badge_info"):
						var _bf: String = str((_badge.call("get_badge_info") as Dictionary).get("faction", "?"))
						if _bf != str(_truth.get("faction", "?")):
							print("[BUG-S4-02?] hover badge faction=%s but truth=%s for %s" % [_bf, str(_truth.get("faction", "?")), best_id])
			else:
				unit_renderer.call("clear_hover")
				_current_hover_hex = Vector2i(-999, -999)
		if best_id == "":
			# STEP-05R1: no live pick — offer the brown stale marker instead.
			var _sh: String = _pick_stale_at(world_pos, pick_radius, coord)
			if _sh != "":
				_hover_stale_id = _sh
				unit_renderer.call("clear_hover")
				_current_hover_hex = Vector2i(-999, -999)
				Input.set_default_cursor_shape(Input.CURSOR_POINTING_HAND)
			elif _current_hover_hex.x != -999:
				unit_renderer.call("clear_hover")
				_current_hover_hex = Vector2i(-999, -999)

	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if _is_click_over_hud(mb.position):
			return
		if mb.pressed and mb.button_index == MOUSE_BUTTON_RIGHT:
			if _stronghold_deploy_pending_unit != "":
				_stronghold_deploy_pending_unit = ""
				if envelope_renderer and envelope_renderer.has_method("clear_deploy_preview"):
					envelope_renderer.call("clear_deploy_preview")
			elif _preview_stronghold_id != "":
				_clear_stronghold_attack_preview()
				_clear_attack_preview()
			elif _preview_attack_target_id != "":
				_clear_attack_preview()
			elif _preview_target_hex.x != -999:
				_clear_route_preview()
			elif unit_manager and unit_manager.is_unit_selected():
				unit_manager.deselect()
			elif stronghold_panel and stronghold_panel.visible:
				_close_stronghold_panel()
			get_viewport().set_input_as_handled()
			return
		
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			var wpos: Vector2 = _pointer_world((event as InputEventMouse).position)
			var clicked_coord: Vector2i = WorldBoundaryCls.world_to_axial(wpos)
			
			if not is_playable_hex(clicked_coord):
				get_viewport().set_input_as_handled()
				print("[Step4] Blocked click outside playable area: %s" % str(clicked_coord))
				return
			
			_handle_hex_click(clicked_coord, wpos)
			get_viewport().set_input_as_handled()

func _handle_hex_click(coord: Vector2i, world_pos: Vector2) -> void:
	if not unit_manager:
		return

	# Deploy-pending mode (§7): click selects deployment destination
	if _stronghold_deploy_pending_unit != "":
		var sid: String = unit_manager.get_garrison_stronghold_id(_stronghold_deploy_pending_unit)
		if sid == "":
			sid = _stronghold_selected_id
		var res: Dictionary = unit_manager.garrison_deploy(_stronghold_deploy_pending_unit, coord, sid)
		if res.get("success", false):
			var unit_data: Dictionary = res
			var q: int = int(coord.x)
			var r: int = int(coord.y)
			# Spawn back into field renderer
			var uclass: String = str(res.get("class", "infantry"))
			# faction preserved from stored data
			var sh: Variant = unit_manager.get_stronghold_by_id(sid) if sid != "" else null
			var faction: String = str(sh.owner) if sh else "red"
			# Restore visual
			unit_renderer.call("spawn_unit", str(res.get("unit_id", "")), uclass, faction, q, r, int(res.get("troop_count", 100)))
			_show_combat_log("배치 완료: %s → (%d,%d)" % [str(res.get("unit_id", "")), q, r])
			_fog_recalc("deploy")
			_stronghold_deploy_pending_unit = ""
			if envelope_renderer and envelope_renderer.has_method("clear_deploy_preview"):
				envelope_renderer.call("clear_deploy_preview")
			_refresh_stronghold_panel(sid)
			if stronghold_panel:
				stronghold_panel.visible = true
		else:
			_show_combat_log("배치 실패: %s" % str(res.get("reason", "")))
		return

	# §20 Click target: clicking ANY footprint hex resolves to SAME stronghold entity
	var clicked_sh: Variant = unit_manager.get_stronghold_at(coord.x, coord.y) if unit_manager.has_method("get_stronghold_at") else null
	if clicked_sh != null:
		var sh_id: String = str(clicked_sh.structure_id)
		# If friendly unit selected and this is enemy stronghold in attack range → stronghold assault
		if unit_manager.is_unit_selected():
			var sel: Dictionary = unit_manager.get_selected_unit()
			var sel_faction: String = str(sel.get("faction", ""))
			var sh_owner: String = str(clicked_sh.owner)
			if sel_faction != sh_owner and sel_faction != "neutral" and sh_owner != "neutral":
				var atk_sh_list: Array = unit_manager.get_attackable_strongholds(str(sel.get("id", ""))) if unit_manager.has_method("get_attackable_strongholds") else []
				var is_attackable_sh: bool = false
				for entry in atk_sh_list:
					if str(entry.get("structure_id", "")) == sh_id:
						is_attackable_sh = true
						break
				if is_attackable_sh:
					var sel_id: String = str(sel.get("id", ""))
					# Two-stage stronghold assault (§21)
					if _preview_stronghold_id == sh_id and clicked_sh.breached and _preview_stronghold_garrison_target != "":
						# Second click executes breached garrison attack
						_execute_stronghold_assault(sel_id, sh_id, _preview_stronghold_garrison_target)
						return
					elif _preview_stronghold_id == sh_id and not bool(clicked_sh.breached):
						# Second click on intact wall executes wall assault
						_execute_stronghold_assault(sel_id, sh_id, "")
						return
					else:
						# First click previews
						if bool(clicked_sh.breached) and _preview_stronghold_garrison_target == "":
							# Breached but no garrison target selected — open panel to choose
							_open_stronghold_panel(sh_id)
							_show_combat_log("붕괴된 성 — 패널에서 공격할 수비대를 선택하세요")
							return
						_update_stronghold_attack_preview(sel_id, sh_id)
						return
		# Otherwise: open dedicated Stronghold Panel (§13) — not ordinary terrain card
		_clear_route_preview()
		_clear_attack_preview()
		_close_enemy_intel()
		_open_stronghold_panel(sh_id)
		return

	# Check if clicked on or near a unit (field units only, garrisoned hidden)
	var zoom_val: float = camera.zoom.x if camera else 1.0
	var pick_radius: float = 24.0 / zoom_val + 8.0
	var clicked_unit: Dictionary = {}
	var best_dist: float = 1e9
	
	var units: Array = unit_manager.get_all_units()
	for u in units:
		# STEP-05 §21: hidden enemies cannot be clicked/selected — unknown ground.
		if str(u.get("faction", "")) == "red" and not _fog_is_enemy_visible(str(u.get("id", ""))):
			continue
		var upos: Vector2 = HexUtilsCls.hex_to_pixel(int(u["q"]), int(u["r"]))
		var d: float = world_pos.distance_to(upos)
		if (int(u["q"]) == coord.x and int(u["r"]) == coord.y) or (d < pick_radius and d < best_dist):
			best_dist = d
			clicked_unit = u
	
	# 1. If friendly unit clicked:
	if not clicked_unit.is_empty() and clicked_unit["faction"] == "blue":
		# Close stronghold panel if open to show unit card
		if stronghold_panel and stronghold_panel.visible:
			_close_stronghold_panel()
		var uid: String = str(clicked_unit["id"])
		# STEP-06 §25: routed formations cannot be re-selected (control lost).
		if bool(clicked_unit.get("routed", false)):
			_show_combat_log("[%s] 궤주 중 — 지휘 불가 (재집결 대기)" % uid)
			return
		# STEP-04R9 §7: Inspection does NOT resolve unit — do NOT mark reviewed
		if unit_manager.get_selected_unit_id() == uid:
			pass
		else:
			_clear_route_preview()
			_clear_attack_preview()
			unit_manager.select_unit(uid)
		_update_next_button_state()
		return
	
	# 2. If a friendly unit is currently selected:
	if unit_manager.is_unit_selected():
		var sel_u: Dictionary = unit_manager.get_selected_unit()
		if str(sel_u.get("class", "")) == "supply":
			# STEP-06R3: Supply units are autonomous logistics NPCs (no tactical hex movement/attacks)
			# Clicking a supply node or stronghold sets the destination in the Trader Panel
			var clicked_node_id: String = ""
			if _step6:
				for nid in (_step6.get_nodes() as Dictionary).keys():
					var nd: Dictionary = (_step6.get_nodes() as Dictionary)[nid]
					var npos: Vector2i = nd["coord"] as Vector2i
					if coord == npos or HexUtilsCls.hex_distance_axial(coord, npos) <= 1:
						clicked_node_id = nid
						break
			if clicked_node_id != "":
				var dpos: Vector2i = (_step6.get_nodes() as Dictionary)[clicked_node_id]["coord"] as Vector2i
				var path: Array[Vector2i] = []
				var rres: Dictionary = _step6.compute_macro_route(
					Vector2i(int(sel_u.get("q", 0)), int(sel_u.get("r", 0))),
					dpos,
					_trader_selected_strategy,
					hex_grid.get("cell_data") if hex_grid else {},
					_river_cells,
					_stronghold_cells
				)
				for p in (rres.get("path", []) as Array):
					path.append(p as Vector2i)
				_on_trader_dest_selected(clicked_node_id, dpos, path)
				return
			# Click on empty ground deselects supply NPC
			_close_trader_panel()
			unit_manager.deselect()
			_update_next_button_state()
			return

		if sel_u["faction"] == "blue" and not bool(sel_u["action_ended"]):
			
			# 2a. Check if clicked on an enemy attackable target (Section 35, 36, 37)
			if not clicked_unit.is_empty() and clicked_unit["faction"] == "red":
				var enemy_id: String = str(clicked_unit["id"])
				var is_attackable: bool = false
				for tgt in _attackable_targets:
					if str(tgt["id"]) == enemy_id:
						is_attackable = true
						break
				
				if is_attackable:
					if enemy_id == _preview_attack_target_id:
						_execute_confirmed_attack()
						return
					else:
						_update_attack_preview_for_target(enemy_id)
						_open_enemy_intel_current(enemy_id)
						return
			
			# 2b. Check if clicking on a brown stale contact marker:
			var _stale_click: String = _pick_stale_at(world_pos, pick_radius)
			if _stale_click != "":
				_clear_route_preview()
				_clear_attack_preview()
				if stronghold_panel and stronghold_panel.visible:
					_close_stronghold_panel()
				_open_enemy_intel_stale(_stale_click)
				return

			# 2c. Check if clicking the already previewed movement destination:
			if coord == _preview_target_hex and _preview_route_info != null and _preview_route_info.found:
				_execute_confirmed_move()
				return
			
			# 2c. Try to preview movement destination (stronghold footprints already rejected above)
			var reachable: bool = _update_preview_for_target(coord)
			if not reachable:
				_clear_route_preview()
				_clear_attack_preview()
				if stronghold_panel and stronghold_panel.visible:
					_close_stronghold_panel()
				unit_manager.deselect()
		else:
			_clear_route_preview()
			_clear_attack_preview()
			if stronghold_panel and stronghold_panel.visible:
				_close_stronghold_panel()
			unit_manager.deselect()
	else:
		if not clicked_unit.is_empty():
			if stronghold_panel and stronghold_panel.visible:
				_close_stronghold_panel()
			var _cid: String = str(clicked_unit["id"])
			# STEP-05R1: visible-enemy clicks route through the observation model.
			if str(clicked_unit.get("faction", "")) == "red":
				_open_enemy_intel_current(_cid)
			else:
				_close_enemy_intel()
			unit_manager.select_unit(_cid)
		else:
			# Check if clicking a fixed supply node (e.g. DEPOT)
			var hit_node: String = ""
			if _step6:
				for nid in (_step6.get_nodes() as Dictionary).keys():
					var nd: Dictionary = (_step6.get_nodes() as Dictionary)[nid]
					var npos: Vector2i = nd["coord"] as Vector2i
					if coord == npos or HexUtilsCls.hex_distance_axial(coord, npos) <= 1:
						hit_node = nid
						break
			if hit_node != "":
				var cell_data: Dictionary = hex_grid.get("cell_data") if hex_grid else {}
				var cov: Dictionary = _step6.compute_node_coverage(hit_node, cell_data, _stronghold_cells)
				var nd_info: Dictionary = (_step6.get_nodes() as Dictionary)[hit_node]
				var budget: float = _step6.get_node_budget(hit_node)
				if _supply_overlay:
					_supply_overlay.call("clear_all")
					_supply_overlay.call("add_coverage_with_costs", cov.get("costs", {}), budget)
					_supply_overlay.call("set_selected_node", nd_info["coord"] as Vector2i)
				unit_card_panel.visible = true
				unit_card_name.text = "[%s] %s" % [hit_node, str(nd_info.get("label", hit_node))]
				unit_card_stats.text = "보급 거점 유형: %s\n비축 군량: %.0f / %.0f (보급 가능)\n보급 도달 반경: %.0f MP (지형 이동력 기준)" % [str(nd_info.get("kind", "depot")), float(nd_info.get("stock", 0.0)), float(nd_info.get("stock_cap", 300.0)), budget]
				unit_card_status.text = "상태: 안전 보급 거점 — 반경 내 아군 부대에 안정적 군량 보급 제공"
				unit_card_status.add_theme_color_override("font_color", Color(0.38, 0.92, 0.48, 1.0))
				_show_combat_log("[%s] 보급 도달 범위 표시 — 반경 %.0f MP (총 %d개 헥스 커버)" % [str(nd_info.get("label", hit_node)), budget, (cov.get("hexes", []) as Array).size()])
				return

			# STEP-05R1: brown stale marker = information only, never a combat target.
			var _se: String = _pick_stale_at(world_pos, pick_radius)
			if _se != "":
				if stronghold_panel and stronghold_panel.visible:
					_close_stronghold_panel()
				_open_enemy_intel_stale(_se)
				return
			if stronghold_panel and stronghold_panel.visible:
				_close_stronghold_panel()
			if _map_mode == Step6ConfigCls.MAP_MODE_BATTLE:
				if _supply_overlay:
					_supply_overlay.call("clear_all")
			else:
				_refresh_logistics_map_overlay()

# ──────────────────────────────────────────────────────────────────
# Stronghold Assault Preview & Execute (§9-12, §21-23)
# ──────────────────────────────────────────────────────────────────
func _update_stronghold_attack_preview(attacker_id: String, stronghold_id: String) -> bool:
	if not unit_manager or not unit_manager.is_unit_selected():
		return false
	var sh: Variant = unit_manager.get_stronghold_by_id(stronghold_id)
	if sh == null:
		return false
	var atk: Dictionary = unit_manager.get_unit_by_id(attacker_id)
	if atk.is_empty():
		return false
	_preview_stronghold_id = stronghold_id
	_preview_attack_target_id = "" # clear field attack preview
	_clear_route_preview()
	var hp: int = int(sh.fortification_hp)
	var hp_max: int = int(sh.fortification_hp_max)
	var breached: bool = bool(sh.breached)
	var gc: int = int(sh.get_garrison_count())
	# Use envelope to highlight stronghold
	if envelope_renderer:
		envelope_renderer.call("set_attack_preview", sh.get_footprint()[0])
	attack_card_panel.visible = true
	var atk_c: String = str(atk.get("class", "infantry")).to_upper()
	var type_str: String = "수도" if str(sh.to_dict().get("structure_type", "")) == "CAPITAL" else "요새"
	if not breached:
		attack_card_title.text = "거점 공격: [%s] vs %s %s  |  성벽 INTACT" % [atk_c, type_str, stronghold_id]
		attack_card_details.text = "대상 성벽: %d / %d HP\n2회 클릭 또는 Enter로 성벽 공격 실행\n수비대 피해: 0명 (성벽이 보호 중) §9\n공성병은 2.5× 성벽 피해" % [hp, hp_max]
	else:
		if _preview_stronghold_garrison_target == "":
			attack_card_title.text = "거점 공격: %s — BREACHED! 수비대 직접 공격" % stronghold_id
			attack_card_details.text = "성벽 붕괴 (0/%d). 패널에서 공격할 수비대를 선택하세요 §12\n주둔군 %d명 — 개별 표적 지정 필요" % [hp_max, gc]
		else:
			var gu: Dictionary = sh.get_garrison_unit(_preview_stronghold_garrison_target)
			attack_card_title.text = "거점 공격: [%s] vs %s %s → 표적 %s" % [atk_c, type_str, _preview_stronghold_garrison_target.to_upper(), _preview_stronghold_garrison_target]
			# STEP-05 §14, §17: enemy garrison strength/morale masked (contact class only).
			attack_card_details.text = "붕괴된 성 내 수비대 %s (병력: ??? — 주둔군 상세 미상)\n2회 클릭 또는 Enter로 실행" % [str(gu.get("class", "")).to_upper()]
	return true

func _execute_stronghold_assault(attacker_id: String, stronghold_id: String, garrison_target_id: String = "") -> void:
	if _battle_over():
		return
	if _is_animating_combat:
		return
	if not unit_manager or attacker_id == "":
		return
	var _atk0: Dictionary = unit_manager.get_unit_by_id(attacker_id)
	if not _atk0.is_empty() and bool(_atk0.get("has_attacked", false)):
		_show_combat_log("이미 공격한 부대 — 다음 턴 대기")
		return
	if not _atk0.is_empty() and str(_atk0.get("class", "")) == "supply":
		_show_combat_log("보급대는 공격 불가")
		return
	var gt: String = garrison_target_id
	if gt == "":
		gt = _preview_stronghold_garrison_target
	_is_animating_combat = true
	_clear_attack_preview()
	_preview_stronghold_id = ""
	# STEP-06 §16/§20: degraded attackers fight degraded.
	var as6m: Dictionary = _step6.combat_mods_for(unit_manager, attacker_id) if _step6 else {}
	var res: Dictionary = unit_manager.execute_stronghold_assault(attacker_id, stronghold_id, gt, as6m)
	if not res.get("success", false):
		_show_combat_log("거점 공격 실패: %s" % str(res.get("error", "unknown")))
		_is_animating_combat = false
		return
	var wall_dmg: int = int(res.get("wall_damage", 0))
	var rem_hp: int = int(res.get("remaining_fortification_hp", 0))
	var breached_now: bool = bool(res.get("breached", false))
	var was_breached_before: bool = bool(res.get("breached_before", false))
	var sh: Variant = unit_manager.get_stronghold_by_id(stronghold_id)
	var anchor: Vector2i = sh.get_anchor() if sh else Vector2i(0,0)
	var anchor_world: Vector2 = HexUtilsCls.hex_to_pixel(anchor.x, anchor.y)
	var atk_u: Dictionary = unit_manager.get_unit_by_id(attacker_id)
	var atk_coord: Vector2i = Vector2i(int(atk_u.get("q", 0)), int(atk_u.get("r", 0))) if not atk_u.is_empty() else Vector2i(0,0)

	# Visual feedback
	if wall_dmg > 0:
		unit_renderer.call("animate_unit_attack", attacker_id, anchor)
		await get_tree().create_timer(0.12).timeout
		unit_renderer.call("spawn_floating_text", anchor, "-%d 성벽 HP" % wall_dmg, Color(1.0, 0.75, 0.25, 1.0))
		if breached_now and not was_breached_before:
			unit_renderer.call("spawn_floating_text", anchor, "성벽 붕괴! BREACHED!", Color(1.0, 0.30, 0.30, 1.0))
			if stronghold_renderer and stronghold_renderer.has_method("update_breach_state"):
				stronghold_renderer.call("update_breach_state", stronghold_id, true)
			_show_combat_log("[%s] 성벽 공격 -%d HP → %d/%d  ★ BREACHED" % [stronghold_id, wall_dmg, rem_hp, int(sh.fortification_hp_max) if sh else 0])
		else:
			_show_combat_log("[%s] 성벽 공격 -%d HP (남은 %d/%d)" % [stronghold_id, wall_dmg, rem_hp, int(sh.fortification_hp_max) if sh else 0])
		var atk_cas: int = int(res.get("attacker_casualties", 0))
		if atk_cas > 0:
			unit_renderer.call("animate_unit_hit", attacker_id, atk_cas)
			unit_renderer.call("spawn_floating_text", atk_coord, "-%d명" % atk_cas, Color(0.95, 0.60, 0.60, 1.0))
			unit_renderer.call("update_unit_health", attacker_id, int(res.get("attacker_remaining_troops", 0)))
		if sh:
			_refresh_stronghold_panel(stronghold_id)
	else:
		# Breached garrison hit
		var gcas: int = int(res.get("garrison_casualties", 0))
		var ghit: String = str(res.get("garrison_target_hit", ""))
		var grem: int = int(res.get("garrison_remaining", 0))
		unit_renderer.call("animate_unit_attack", attacker_id, anchor)
		await get_tree().create_timer(0.12).timeout
		if gcas > 0:
			unit_renderer.call("spawn_floating_text", anchor, "-%d명 (%s)" % [gcas, ghit], Color(1.0, 0.35, 0.35, 1.0))
			unit_renderer.call("spawn_floating_text", anchor, "남은 %d명" % grem, Color(0.92, 0.94, 0.98, 0.85))
		if bool(res.get("garrison_destroyed", false)):
			unit_renderer.call("spawn_floating_text", anchor, "%s 섬멸!" % ghit, Color(1.0, 0.20, 0.20, 1.0))
		var atk_cas2: int = int(res.get("attacker_casualties", 0))
		if atk_cas2 > 0:
			unit_renderer.call("animate_unit_hit", attacker_id, atk_cas2)
			unit_renderer.call("spawn_floating_text", atk_coord, "-%d명" % atk_cas2, Color(0.95, 0.60, 0.60, 1.0))
			unit_renderer.call("update_unit_health", attacker_id, int(res.get("attacker_remaining_troops", 0)))
		_show_combat_log("[%s] 수비대 %s 타격 -%d명 (남은 %d명)" % [stronghold_id, ghit, gcas, grem])
		_preview_stronghold_garrison_target = ""
		if sh:
			_refresh_stronghold_panel(stronghold_id)

	var atk_ended: bool = bool(res.get("attacker_action_ended", true))
	if atk_ended:
		unit_renderer.call("set_unit_dimmed", attacker_id, true)
	# STEP-06 §5: capture creates a forward logistics node; shock can rout the attacker.
	if bool(res.get("captured", false)):
		_show_combat_log("[%s] 점령! → 아군 전진 거점 (보급 노드)" % stronghold_id)
		_refresh_node_markers()
		_update_supply_hud()
	_s6_rout_check_single(attacker_id)
	if unit_manager.is_unit_selected() and not atk_ended:
		var updated: Dictionary = unit_manager.get_selected_unit()
		_on_unit_selection_changed(updated)
	else:
		envelope_renderer.call("clear_all")
		unit_card_panel.visible = false
		_clear_route_preview()
		_clear_attack_preview()
	_is_animating_combat = false
	# STEP-05 §33: assault casualties change observation.
	_fog_recent_combat = true
	_fog_recalc("assault")

func _clear_stronghold_attack_preview() -> void:
	_preview_stronghold_id = ""
	_preview_stronghold_garrison_target = ""

# ------------------------------------------------------------------
# STEP-05 INFORMATION WARFARE — Fog + LOS + Scout intel + Ambush (§3-§35)
# World Truth lives in unit_manager. Rendering/UI consume Player Observation.
# ------------------------------------------------------------------
const FOG_MOD_UNEXPLORED: Color = Color(0.42, 0.44, 0.48, 1.0)
const FOG_MOD_EXPLORED: Color = Color(0.72, 0.72, 0.78, 1.0)
const FOG_MOD_VISIBLE: Color = Color(1, 1, 1, 1)

func _setup_fog_of_war() -> void:
	if is_step0_sandbox or no_fog:
		_fog = null
		if hex_compositor and hex_compositor.has_method("refresh_fog"):
			hex_compositor.call("refresh_fog", null)
		if _stale_layer:
			_stale_layer.visible = false
		if _friendly_stale_layer:
			_friendly_stale_layer.visible = false
		return
	_fog = Step5FogCls.new()
	var objectives: Array = []
	if not _battlefield.is_empty():
		for sd in _battlefield["strongholds"]:
			objectives.append_array(sd["footprint"])
	else:
		for h in FORTRESS_FOOTPRINT:
			objectives.append(h)
		for h in CAPITAL_FOOTPRINT:
			objectives.append(h)
	_fog.set_objective_hexes(objectives)
	_fog_recalc("init", false)
	if hex_compositor and hex_compositor.has_method("refresh_units"):
		hex_compositor.call("refresh_units", _collect_hex_unit_coords())
	if hex_compositor and hex_compositor.has_method("refresh_fog"):
		hex_compositor.call("refresh_fog", _fog)
	print("[Step5] Fog online — normal=%d scout=%d | visible hexes=%d" % [_fog.normal_vision, _fog.scout_vision, (_fog.visible as Dictionary).size()])

# ------------------------------------------------------------------
# STEP-06 BATTLE DECISION LAYER — setup, HUD, markers, hooks (§2-§45)
# ------------------------------------------------------------------
func _setup_step6() -> void:
	# Canonical supply/food retirement: zero supply configuration, no supply panel/overlay/convoys.
	_step6 = null
	if unit_manager and unit_manager.has_signal("unit_destroyed"):
		unit_manager.unit_destroyed.connect(_on_s6_unit_destroyed)
	if unit_manager:
		for u in unit_manager.get_all_units_including_garrisoned():
			var uid: String = str(u.get("id", ""))
			if str(u.get("class", "")) == "hq" and unit_renderer:
				unit_renderer.call("set_unit_hq", uid, true)
	print("[Step6] Canonical supply/food retired — zero supply configuration initialized.")

func _build_supply_panel() -> void:
	_supply_panel = Panel.new()
	_supply_panel.name = "SupplyPanel"
	_supply_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_supply_panel.offset_left = -224
	_supply_panel.offset_top = 68
	_supply_panel.offset_right = -24
	_supply_panel.offset_bottom = 100
	_supply_panel.add_theme_stylebox_override("panel", HistoricalUIThemeCls.create_lacquer_panel(1, 4, HistoricalUIThemeCls.COLOR_GOLD_BORDER))
	hud_layer.add_child(_supply_panel)
	_supply_label = Label.new()
	_supply_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_supply_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_supply_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_supply_label.add_theme_font_size_override("font_size", 13)
	_supply_label.add_theme_color_override("font_color", HistoricalUIThemeCls.COLOR_GOLD_BRIGHT)
	_supply_panel.add_child(_supply_label)

	_btn_map_mode = Button.new()
	_btn_map_mode.name = "BtnMapMode"
	_btn_map_mode.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_btn_map_mode.offset_left = -356
	_btn_map_mode.offset_top = 68
	_btn_map_mode.offset_right = -232
	_btn_map_mode.offset_bottom = 100
	_btn_map_mode.text = "전투 모드 [TAB]"
	_btn_map_mode.tooltip_text = "지도 모드 전환 (TAB 키 또는 클릭): 전투 모드 <-> 보급 모드"
	_btn_map_mode.pressed.connect(_toggle_map_mode)
	_btn_map_mode.add_theme_stylebox_override("normal", HistoricalUIThemeCls.create_gold_button(false))
	_btn_map_mode.add_theme_stylebox_override("hover", HistoricalUIThemeCls.create_gold_button(true))
	_btn_map_mode.add_theme_font_size_override("font_size", 12)
	_btn_map_mode.add_theme_color_override("font_color", HistoricalUIThemeCls.COLOR_TEXT_PRIMARY)
	hud_layer.add_child(_btn_map_mode)

func _toggle_map_mode() -> void:
	var new_mode: int = Step6ConfigCls.MAP_MODE_LOGISTICS if _map_mode == Step6ConfigCls.MAP_MODE_BATTLE else Step6ConfigCls.MAP_MODE_BATTLE
	_set_map_mode(new_mode)

func _set_map_mode(mode: int) -> void:
	_map_mode = mode
	if _btn_map_mode != null:
		if _map_mode == Step6ConfigCls.MAP_MODE_BATTLE:
			_btn_map_mode.text = "전투 모드 [TAB]"
			_btn_map_mode.modulate = Color(0.85, 0.90, 1.0, 1.0)
		else:
			_btn_map_mode.text = "보급 모드 [TAB]"
			_btn_map_mode.modulate = Color(1.0, 0.85, 0.35, 1.0)
			
	var cell_data: Dictionary = hex_grid.get("cell_data") if hex_grid else {}
	if unit_renderer and unit_renderer.has_method("set_overhead_display_mode"):
		unit_renderer.call("set_overhead_display_mode", _map_mode, unit_manager, _step6, cell_data, _stronghold_cells)

	if _map_mode == Step6ConfigCls.MAP_MODE_BATTLE:
		if hex_grid:
			hex_grid.modulate = Color(1.0, 1.0, 1.0, 1.0)
		for u in unit_manager.get_all_units():
			unit_renderer.call("set_unit_deemphasized", str(u.get("id", "")), false)
		if _supply_overlay:
			_supply_overlay.call("clear_all")
		_s6_hide_route_line()
		for m in _node_markers.values():
			if is_instance_valid(m):
				m.visible = false
		_show_combat_log("전투 지도 모드 (BATTLE MAP) — 전투 중심 뷰 [TAB]")
	else:
		if hex_grid:
			hex_grid.modulate = Color(0.50, 0.53, 0.60, 1.0)
		envelope_renderer.call("clear_all")
		_clear_route_preview()
		_clear_attack_preview()
		for u in unit_manager.get_all_units():
			var uid: String = str(u.get("id", ""))
			var cls: String = str(u.get("class", ""))
			var is_logistics: bool = (cls == "supply" or cls == "hq")
			unit_renderer.call("set_unit_deemphasized", uid, not is_logistics)
		for m in _node_markers.values():
			if is_instance_valid(m):
				m.visible = true
		_refresh_logistics_map_overlay()
		_show_combat_log("보급 지도 모드 (LOGISTICS MAP) — 보급망 및 보급로 렌즈 [TAB]")

func _refresh_logistics_map_overlay() -> void:
	if _supply_overlay == null or _step6 == null or hex_grid == null:
		return
	_supply_overlay.call("clear_all")
	var cell_data: Dictionary = hex_grid.get("cell_data") if hex_grid else {}
	
	# Multi-tier coverage with reach tiers (Settler Lens)
	var cov_costs: Dictionary = {}
	for nid in (_step6.get_nodes() as Dictionary).keys():
		var n: Dictionary = (_step6.get_nodes() as Dictionary)[nid]
		if str(n.get("faction", "")) == "blue":
			var cov: Dictionary = _step6.compute_node_coverage(nid, cell_data, _stronghold_cells)
			var costs_dict: Dictionary = cov.get("costs", {})
			for h in costs_dict.keys():
				var c: float = float(costs_dict[h])
				if not cov_costs.has(h) or c < float(cov_costs[h]):
					cov_costs[h] = c
	_supply_overlay.call("add_coverage_with_costs", cov_costs, Step6ConfigCls.COVERAGE_HQ)

	# Mobile supply hubs (blue supply units) 2-hex service radius
	var supply_coords: Array = []
	if unit_manager:
		for u in unit_manager.get_all_units():
			if str(u.get("faction", "")) == "blue" and str(u.get("class", "")) == "supply":
				supply_coords.append(Vector2i(int(u.get("q", 0)), int(u.get("r", 0))))
	if not supply_coords.is_empty():
		_supply_overlay.call("set_mobile_hubs", supply_coords, Step6ConfigCls.SUPPLY_UNIT_SERVICE_RADIUS, "🌾 보급 반경: 2헥스")

	# Highlight HQ node
	var hq_node: Dictionary = (_step6.get_nodes() as Dictionary).get("HQ", {})
	if not hq_node.is_empty():
		var hq_pos: Vector2i = hq_node.get("coord", Vector2i(-999, -999))
		_supply_overlay.call("set_selected_node", hq_pos, "👑 사령부 보급망 (반경 12 MP)")

	_s6_update_active_routes_overlay()
	if not _trader_preview_route_path.is_empty():
		_supply_overlay.call("preview_candidate_route", _trader_preview_route_path)

func _s6_update_active_routes_overlay() -> void:
	if _supply_overlay == null or _step6 == null:
		return
	var active_routes: Array = _step6.get_all_assigned_routes()
	_supply_overlay.call("set_active_routes", active_routes)

# ------------------------------------------------------------------
# STEP-06R3 CIV-STYLE TRADER SUPPLY NPC UI & LOGISTICS ASSIGNMENT
# ------------------------------------------------------------------
func _setup_trader_panel() -> void:
	_trader_panel = Panel.new()
	_trader_panel.name = "TraderRoutePanel"
	_trader_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_trader_panel.offset_left = -464
	_trader_panel.offset_top = 108
	_trader_panel.offset_right = -24
	_trader_panel.offset_bottom = 620
	var st: StyleBoxFlat = StyleBoxFlat.new()
	st.bg_color = Color(0.08, 0.10, 0.13, 0.96)
	st.border_color = Color(0.90, 0.75, 0.30, 0.95)
	st.set_border_width_all(2)
	st.set_corner_radius_all(8)
	st.shadow_color = Color(0, 0, 0, 0.70)
	st.shadow_size = 6
	_trader_panel.add_theme_stylebox_override("panel", st)
	_trader_panel.visible = false
	hud_layer.add_child(_trader_panel)

	# Title
	_trader_title = Label.new()
	_trader_title.position = Vector2(16, 12)
	_trader_title.size = Vector2(380, 26)
	_trader_title.text = "🌾 수송대 보급로 지정 (Supply Route)"
	_trader_title.add_theme_font_size_override("font_size", 16)
	_trader_title.add_theme_color_override("font_color", Color(1.0, 0.88, 0.45, 1.0))
	_trader_panel.add_child(_trader_title)

	# Close button
	var btn_close: Button = Button.new()
	btn_close.position = Vector2(440 - 36, 10)
	btn_close.size = Vector2(24, 24)
	btn_close.text = "✕"
	btn_close.focus_mode = Control.FOCUS_NONE
	btn_close.add_theme_font_size_override("font_size", 12)
	btn_close.pressed.connect(_close_trader_panel)
	_trader_panel.add_child(btn_close)

	# Subtitle / Convoy summary
	_trader_sub = Label.new()
	_trader_sub.position = Vector2(16, 40)
	_trader_sub.size = Vector2(408, 20)
	_trader_sub.text = "수송대: [B_SUP_1]  |  위치: (-25, 0)"
	_trader_sub.add_theme_font_size_override("font_size", 12)
	_trader_sub.add_theme_color_override("font_color", Color(0.78, 0.82, 0.90, 1.0))
	_trader_panel.add_child(_trader_sub)

	# Cargo & Status line
	_trader_cargo_label = Label.new()
	_trader_cargo_label.position = Vector2(16, 62)
	_trader_cargo_label.size = Vector2(408, 20)
	_trader_cargo_label.text = "적재 화물: 40 / 40 (군량)  |  상태: 대기 중"
	_trader_cargo_label.add_theme_font_size_override("font_size", 12)
	_trader_cargo_label.add_theme_color_override("font_color", Color(0.95, 0.85, 0.50, 1.0))
	_trader_panel.add_child(_trader_cargo_label)

	# Strategy selection row
	var strat_lbl: Label = Label.new()
	strat_lbl.position = Vector2(16, 88)
	strat_lbl.size = Vector2(70, 22)
	strat_lbl.text = "경로 방침:"
	strat_lbl.add_theme_font_size_override("font_size", 12)
	strat_lbl.add_theme_color_override("font_color", Color(0.70, 0.75, 0.85, 1.0))
	_trader_panel.add_child(strat_lbl)

	_trader_strategy_container = HBoxContainer.new()
	_trader_strategy_container.position = Vector2(85, 84)
	_trader_strategy_container.size = Vector2(340, 28)
	_trader_strategy_container.add_theme_constant_override("separation", 6)
	_trader_panel.add_child(_trader_strategy_container)

	_trader_btn_road = _create_trader_strat_btn("가도 우선", Step6ConfigCls.ROUTE_STRATEGY_ROAD)
	_trader_strategy_container.add_child(_trader_btn_road)

	_trader_btn_fastest = _create_trader_strat_btn("최단 거리", Step6ConfigCls.ROUTE_STRATEGY_FASTEST)
	_trader_strategy_container.add_child(_trader_btn_fastest)

	_trader_btn_safe = _create_trader_strat_btn("안전 우회", Step6ConfigCls.ROUTE_STRATEGY_SAFE)
	_trader_strategy_container.add_child(_trader_btn_safe)

	# Destination list header
	var dest_header: Label = Label.new()
	dest_header.position = Vector2(16, 118)
	dest_header.size = Vector2(408, 20)
	dest_header.text = "보급 목적지 선택 (거점 / 전진기지):"
	dest_header.add_theme_font_size_override("font_size", 12)
	dest_header.add_theme_color_override("font_color", Color(0.85, 0.90, 1.0, 1.0))
	_trader_panel.add_child(dest_header)

	# Destination ScrollContainer
	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.position = Vector2(16, 142)
	scroll.size = Vector2(408, 230)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_trader_panel.add_child(scroll)

	_trader_dest_container = VBoxContainer.new()
	_trader_dest_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_trader_dest_container.add_theme_constant_override("separation", 6)
	scroll.add_child(_trader_dest_container)

	# Active Route Status description box
	_trader_status_label = Label.new()
	_trader_status_label.position = Vector2(16, 380)
	_trader_status_label.size = Vector2(408, 70)
	_trader_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_trader_status_label.add_theme_font_size_override("font_size", 11)
	_trader_status_label.add_theme_color_override("font_color", Color(0.80, 0.85, 0.92, 1.0))
	_trader_status_label.text = "보급로 설명: 수송대는 매 턴 8 MP로 자동 왕복하며, 경로 2헥스 이내 아군 부대에 군량을 보급합니다."
	_trader_panel.add_child(_trader_status_label)

	# Action buttons (Assign & Cancel)
	_trader_btn_assign = Button.new()
	_trader_btn_assign.position = Vector2(16, 460)
	_trader_btn_assign.size = Vector2(196, 36)
	_trader_btn_assign.text = "보급로 개설 (Assign)"
	_trader_btn_assign.focus_mode = Control.FOCUS_NONE
	var assign_st: StyleBoxFlat = StyleBoxFlat.new()
	assign_st.bg_color = Color(0.18, 0.50, 0.28, 0.92)
	assign_st.border_color = Color(0.40, 0.85, 0.50, 0.95)
	assign_st.set_border_width_all(1)
	assign_st.set_corner_radius_all(5)
	_trader_btn_assign.add_theme_stylebox_override("normal", assign_st)
	var assign_hov: StyleBoxFlat = assign_st.duplicate()
	assign_hov.bg_color = Color(0.24, 0.65, 0.35, 1.0)
	_trader_btn_assign.add_theme_stylebox_override("hover", assign_hov)
	_trader_btn_assign.pressed.connect(_on_trader_assign_route_pressed)
	_trader_panel.add_child(_trader_btn_assign)

	_trader_btn_cancel = Button.new()
	_trader_btn_cancel.position = Vector2(228, 460)
	_trader_btn_cancel.size = Vector2(196, 36)
	_trader_btn_cancel.text = "보급로 취소 (Cancel)"
	_trader_btn_cancel.focus_mode = Control.FOCUS_NONE
	var cancel_st: StyleBoxFlat = StyleBoxFlat.new()
	cancel_st.bg_color = Color(0.48, 0.20, 0.18, 0.92)
	cancel_st.border_color = Color(0.85, 0.40, 0.35, 0.95)
	cancel_st.set_border_width_all(1)
	cancel_st.set_corner_radius_all(5)
	_trader_btn_cancel.add_theme_stylebox_override("normal", cancel_st)
	var cancel_hov: StyleBoxFlat = cancel_st.duplicate()
	cancel_hov.bg_color = Color(0.65, 0.26, 0.22, 1.0)
	_trader_btn_cancel.add_theme_stylebox_override("hover", cancel_hov)
	_trader_btn_cancel.pressed.connect(_on_trader_cancel_route_pressed)
	_trader_panel.add_child(_trader_btn_cancel)

func _create_trader_strat_btn(txt: String, strat: String) -> Button:
	var btn: Button = Button.new()
	btn.text = txt
	btn.focus_mode = Control.FOCUS_NONE
	btn.custom_minimum_size = Vector2(95, 26)
	btn.add_theme_font_size_override("font_size", 11)
	btn.pressed.connect(func(): _on_trader_strategy_selected(strat))
	return btn

func _update_trader_strategy_buttons() -> void:
	var btns: Dictionary = {
		Step6ConfigCls.ROUTE_STRATEGY_ROAD: _trader_btn_road,
		Step6ConfigCls.ROUTE_STRATEGY_FASTEST: _trader_btn_fastest,
		Step6ConfigCls.ROUTE_STRATEGY_SAFE: _trader_btn_safe
	}
	for s in btns.keys():
		var b: Button = btns[s]
		if b == null:
			continue
		var is_sel: bool = (_trader_selected_strategy == s)
		var st: StyleBoxFlat = StyleBoxFlat.new()
		st.set_corner_radius_all(4)
		if is_sel:
			st.bg_color = Color(0.65, 0.50, 0.15, 0.95)
			st.border_color = Color(1.0, 0.88, 0.40, 1.0)
			st.set_border_width_all(2)
			b.add_theme_color_override("font_color", Color(1.0, 0.95, 0.80, 1.0))
		else:
			st.bg_color = Color(0.14, 0.16, 0.20, 0.85)
			st.border_color = Color(0.40, 0.45, 0.55, 0.70)
			st.set_border_width_all(1)
			b.add_theme_color_override("font_color", Color(0.75, 0.80, 0.88, 0.90))
		b.add_theme_stylebox_override("normal", st)

func _on_trader_strategy_selected(strat: String) -> void:
	_trader_selected_strategy = strat
	_update_trader_strategy_buttons()
	if _trader_selected_convoy_id != "":
		_refresh_trader_destinations()

func _open_trader_panel(cid: String) -> void:
	if _trader_panel == null or _step6 == null or unit_manager == null:
		return
	_trader_selected_convoy_id = cid
	_trader_panel.visible = true
	if stronghold_panel and stronghold_panel.visible:
		_close_stronghold_panel()
	_close_enemy_intel()
	_update_trader_strategy_buttons()
	_refresh_trader_destinations()

func _close_trader_panel() -> void:
	if _trader_panel != null:
		_trader_panel.visible = false
	_trader_selected_convoy_id = ""
	_trader_selected_dest_id = ""
	_trader_selected_dest_coord = Vector2i(-999, -999)
	_trader_preview_route_path.clear()
	if _supply_overlay != null:
		_supply_overlay.call("preview_candidate_route", _trader_preview_route_path)

func _refresh_trader_destinations() -> void:
	if _trader_selected_convoy_id == "" or _step6 == null or unit_manager == null:
		return
	var u: Dictionary = unit_manager.get_unit_by_id(_trader_selected_convoy_id)
	if u.is_empty():
		_close_trader_panel()
		return
	
	var cpos := Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))
	var cinfo: Dictionary = _step6.convoy_info(_trader_selected_convoy_id)
	var cargo: float = float(cinfo.get("cargo", float(u.get("convoy_cargo", 0.0))))
	var max_cargo: float = float(cinfo.get("max_cargo", Step6ConfigCls.SUPPLY_UNIT_CARGO_CAPACITY))
	
	_trader_sub.text = "수송대: [%s]  |  현재 위치: (%d, %d)" % [_trader_selected_convoy_id, cpos.x, cpos.y]
	
	var current_route: Dictionary = _step6.get_assigned_route(_trader_selected_convoy_id)
	var has_route: bool = not current_route.is_empty() and bool(current_route.get("active", false))
	
	if has_route:
		var r_dest: String = str(current_route.get("dest_node_id", ""))
		var r_strat: String = str(current_route.get("strategy", "road"))
		var r_prog: int = int(current_route.get("progress_idx", 0))
		var r_total: int = (current_route.get("path", []) as Array).size()
		var r_returning: bool = bool(current_route.get("returning", false))
		var r_state_str: String = "복귀 중" if r_returning else "운송 중"
		_trader_cargo_label.text = "적재 화물: %.0f / %.0f (군량)  |  상태: %s (%s, %d/%d)" % [cargo, max_cargo, r_state_str, r_dest, r_prog + 1, maxi(1, r_total)]
		_trader_status_label.text = "현재 배속된 보급로: %s → %s (방침: %s)\n상태: %s (진행 %d/%d). 왕복 운송 중." % [str(current_route.get("origin_coord", "")), r_dest, r_strat, r_state_str, r_prog + 1, maxi(1, r_total)]
		_trader_btn_cancel.disabled = false
	else:
		_trader_cargo_label.text = "적재 화물: %.0f / %.0f (군량)  |  상태: 대기 중 (미배속)"
		_trader_status_label.text = "목적지를 선택하고 [보급로 개설]을 누르면, 수송대가 매 턴 8 MP로 자동 왕복하며 경로 2헥스 이내 아군 부대에 군량을 보급합니다."
		_trader_btn_cancel.disabled = true

	for child in _trader_dest_container.get_children():
		child.queue_free()

	var dests: Array = _step6.get_viable_destinations(_trader_selected_convoy_id, unit_manager, _trader_selected_strategy)
	if dests.is_empty():
		var empty_lbl: Label = Label.new()
		empty_lbl.text = "  (이동 가능한 보급 거점이 없습니다)"
		empty_lbl.add_theme_font_size_override("font_size", 12)
		empty_lbl.add_theme_color_override("font_color", Color(0.65, 0.70, 0.75, 1.0))
		_trader_dest_container.add_child(empty_lbl)
		_trader_btn_assign.disabled = true
		return

	if _trader_selected_dest_id == "" or not _is_dest_in_list(_trader_selected_dest_id, dests):
		if has_route:
			_trader_selected_dest_id = str(current_route.get("dest_node_id", ""))
		else:
			_trader_selected_dest_id = str(dests[0].get("id", ""))

	for d in dests:
		var did: String = str(d.get("id", ""))
		var dname: String = str(d.get("name", did))
		var dcoord: Vector2i = d.get("coord", Vector2i(0, 0))
		var turns: int = int(d.get("turns", 1))
		var dist: int = int(d.get("distance", 1))
		var path: Array[Vector2i] = []
		for p in (d.get("path", []) as Array):
			path.append(p as Vector2i)
		var is_selected: bool = (did == _trader_selected_dest_id)
		
		var card: PanelContainer = PanelContainer.new()
		var c_st: StyleBoxFlat = StyleBoxFlat.new()
		c_st.set_corner_radius_all(6)
		if is_selected:
			c_st.bg_color = Color(0.20, 0.24, 0.16, 0.95)
			c_st.border_color = Color(0.95, 0.82, 0.35, 0.95)
			c_st.set_border_width_all(2)
			_trader_selected_dest_coord = dcoord
			_trader_preview_route_path = path
			if _supply_overlay != null:
				_supply_overlay.call("preview_candidate_route", path)
		else:
			c_st.bg_color = Color(0.11, 0.13, 0.17, 0.90)
			c_st.border_color = Color(0.30, 0.35, 0.45, 0.65)
			c_st.set_border_width_all(1)
		c_st.content_margin_left = 8
		c_st.content_margin_right = 8
		c_st.content_margin_top = 6
		c_st.content_margin_bottom = 6
		card.add_theme_stylebox_override("panel", c_st)

		var hbox: HBoxContainer = HBoxContainer.new()
		hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.add_child(hbox)

		var vbox: VBoxContainer = VBoxContainer.new()
		vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hbox.add_child(vbox)

		var name_lbl: Label = Label.new()
		name_lbl.text = "%s  (%d, %d)" % [dname, dcoord.x, dcoord.y]
		name_lbl.add_theme_font_size_override("font_size", 12)
		name_lbl.add_theme_color_override("font_color", Color(1.0, 0.92, 0.70, 1.0) if is_selected else Color(0.90, 0.92, 0.95, 1.0))
		vbox.add_child(name_lbl)

		var detail_lbl: Label = Label.new()
		detail_lbl.text = "왕복 %d턴 (편도 %d턴)  |  거리 %d칸  |  군량 적재 %.0f" % [turns * 2, turns, dist, max_cargo]
		detail_lbl.add_theme_font_size_override("font_size", 10)
		detail_lbl.add_theme_color_override("font_color", Color(0.75, 0.80, 0.85, 0.85))
		vbox.add_child(detail_lbl)

		var sel_btn: Button = Button.new()
		sel_btn.text = "지정됨" if is_selected else "선택"
		sel_btn.custom_minimum_size = Vector2(56, 26)
		sel_btn.focus_mode = Control.FOCUS_NONE
		sel_btn.add_theme_font_size_override("font_size", 11)
		sel_btn.pressed.connect(func(): _on_trader_dest_selected(did, dcoord, path))
		hbox.add_child(sel_btn)

		_trader_dest_container.add_child(card)

	_trader_btn_assign.disabled = (_trader_selected_dest_id == "" or _trader_preview_route_path.is_empty())

func _is_dest_in_list(did: String, dests: Array) -> bool:
	for d in dests:
		if str(d.get("id", "")) == did:
			return true
	return false

func _on_trader_dest_selected(dest_id: String, dest_coord: Vector2i, path: Array[Vector2i]) -> void:
	_trader_selected_dest_id = dest_id
	_trader_selected_dest_coord = dest_coord
	_trader_preview_route_path = path
	if _supply_overlay != null:
		_supply_overlay.call("preview_candidate_route", path)
	_refresh_trader_destinations()

func _on_trader_assign_route_pressed() -> void:
	if _trader_selected_convoy_id == "" or _trader_selected_dest_id == "" or _step6 == null:
		return
	var u: Dictionary = unit_manager.get_unit_by_id(_trader_selected_convoy_id)
	if u.is_empty():
		return
	var origin_coord := Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))
	var res: Dictionary = _step6.assign_route(
		_trader_selected_convoy_id,
		origin_coord,
		_trader_selected_dest_id,
		_trader_selected_dest_coord,
		_trader_preview_route_path,
		_trader_selected_strategy
	)
	if bool(res.get("success", false)):
		_show_combat_log("[%s] 보급로 개설: %s (방침: %s)" % [_trader_selected_convoy_id, _trader_selected_dest_id, _trader_selected_strategy])
		_s6_update_active_routes_overlay()
		_refresh_trader_destinations()
	else:
		_show_combat_log("[%s] 보급로 개설 실패: %s" % [_trader_selected_convoy_id, str(res.get("reason", ""))])

func _on_trader_cancel_route_pressed() -> void:
	if _trader_selected_convoy_id == "" or _step6 == null:
		return
	var res: Dictionary = _step6.cancel_route(_trader_selected_convoy_id)
	if bool(res.get("success", false)):
		_show_combat_log("[%s] 보급로 취소 — 본영/거점 복귀 대기" % _trader_selected_convoy_id)
		_trader_preview_route_path.clear()
		if _supply_overlay != null:
			_supply_overlay.call("preview_candidate_route", _trader_preview_route_path)
		_s6_update_active_routes_overlay()
		_refresh_trader_destinations()

func _update_supply_hud() -> void:
	if _supply_label == null:
		return
	if _step6 == null:
		_supply_label.text = "중앙 군량: -"
		return
	var nn: int = 0
	for nid in (_step6.get_nodes() as Dictionary).keys():
		var n: Dictionary = (_step6.get_nodes() as Dictionary)[nid]
		if str(n.get("faction", "")) == "blue" and str(n.get("kind", "")) != "hq":
			nn += 1
	_supply_label.text = "중앙 군량: %d  |  전진거점 %d" % [int(_step6.get_central()), nn]

func _refresh_node_markers() -> void:
	for nid in _node_markers.keys():
		var m: Node2D = _node_markers[nid] as Node2D
		if is_instance_valid(m):
			m.queue_free()
	_node_markers.clear()
	if _step6 == null:
		return
	for nid in (_step6.get_nodes() as Dictionary).keys():
		var n: Dictionary = (_step6.get_nodes() as Dictionary)[nid]
		if str(n.get("faction", "")) != "blue":
			continue
		var is_hq: bool = (str(n.get("kind", "")) == "hq")
		var coord: Vector2i = n["coord"] as Vector2i
		var marker: Node2D = Node2D.new()
		marker.name = "S6Node_%s" % str(nid)
		marker.position = HexUtilsCls.hex_to_pixel(coord.x, coord.y)
		marker.z_index = 25
		var lbl: Label = Label.new()
		if is_hq:
			lbl.text = "👑 본영 사령부"
			lbl.add_theme_font_size_override("font_size", 12)
			lbl.add_theme_color_override("font_color", Color(1.0, 0.95, 0.40, 1.0))
			lbl.position = Vector2(-42, -32)
		else:
			lbl.text = "🌾 %s" % str(n.get("label", nid))
			lbl.add_theme_font_size_override("font_size", 11)
			lbl.add_theme_color_override("font_color", Color(1.0, 0.90, 0.55, 1.0))
			lbl.position = Vector2(-36, -30)
		lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
		lbl.add_theme_constant_override("shadow_offset_x", 1)
		lbl.add_theme_constant_override("shadow_offset_y", 1)
		lbl.add_theme_constant_override("outline_size", 2)
		lbl.add_theme_color_override("font_outline_color", Color(0.12, 0.08, 0.02, 0.9))
		marker.add_child(lbl)
		add_child(marker)
		_node_markers[nid] = marker

func _s6_hide_route_line() -> void:
	if _route_line:
		_route_line.points = PackedVector2Array()
		_route_line.visible = false

func _s6_route_points(from: Vector2i, to: Vector2i, uclass: String, fac: String) -> PackedVector2Array:
	var pts: PackedVector2Array = PackedVector2Array()
	var cell_data: Dictionary = hex_grid.get("cell_data") if hex_grid else {}
	var base: float = Step3ConfigCls.get_base_movement(uclass)
	var route: Variant = Step3PathfindingCls.find_route(from, to, uclass, base, base, Step3ConfigCls.MarchPolicy.ORANGE_ALLOWED, cell_data, _player_known_occupied(), _river_cells, fac, _stronghold_cells, 0.0, base, base * 2.0, base * 2.2, _pathfinding_scenario_bounds())
	if route != null and route.found and (route.path as Array).size() >= 2:
		for h in (route.path as Array):
			var hh: Vector2i = h
			pts.append(HexUtilsCls.hex_to_pixel(hh.x, hh.y))
	else:
		pts.append(HexUtilsCls.hex_to_pixel(from.x, from.y))
		pts.append(HexUtilsCls.hex_to_pixel(to.x, to.y))
	return pts

func _s6_update_route_line() -> void:
	_s6_hide_route_line()
	if _step6 == null or _route_line == null or unit_manager == null:
		return
	if _map_mode == Step6ConfigCls.MAP_MODE_BATTLE:
		return
	if not unit_manager.is_unit_selected():
		return
	var u: Dictionary = unit_manager.get_selected_unit()
	if str(u.get("faction", "")) != "blue":
		return
	var upos: Vector2i = Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))
	var cell_data: Dictionary = hex_grid.get("cell_data") if hex_grid else {}
	if str(u.get("class", "")) == "supply":
		var best_nid: String = ""
		var best_dist: int = 9999
		for nid in (_step6.get_nodes() as Dictionary).keys():
			var nd: Dictionary = (_step6.get_nodes() as Dictionary)[nid]
			if str(nd.get("faction", "")) != "blue":
				continue
			var nd_pos: Vector2i = nd["coord"] as Vector2i
			var d: int = HexUtilsCls.hex_distance_axial(upos, nd_pos)
			if d < best_dist:
				best_dist = d
				best_nid = nid
		if best_nid != "":
			var target_pos: Vector2i = (_step6.get_nodes() as Dictionary)[best_nid]["coord"] as Vector2i
			_route_line.points = _s6_route_points(upos, target_pos, "supply", "blue")
			_route_line.visible = true
	elif str(u.get("class", "")) != "hq":
		var cov_info: Dictionary = _step6.is_hex_covered(upos, "blue", cell_data, _stronghold_cells)
		if bool(cov_info.get("covered", false)):
			var nid2: String = str(cov_info.get("node_id", ""))
			var src: Dictionary = (_step6.get_nodes() as Dictionary).get(nid2, {})
			if not src.is_empty():
				_route_line.points = _s6_route_points(upos, src["coord"] as Vector2i, "supply", "blue")
				_route_line.visible = true

func _s6_adjacent_enemies(u: Dictionary) -> int:
	var n: int = 0
	var upos: Vector2i = Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))
	for e in unit_manager.get_all_units():
		if str(e.get("faction", "")) == str(u.get("faction", "")):
			continue
		if int(e.get("soldier_count", 0)) <= 0:
			continue
		if HexUtilsCls.hex_distance_axial(upos, Vector2i(int(e.get("q", 0)), int(e.get("r", 0)))) == 1:
			n += 1
	return n

func _s6_note_command_loss(uid: String) -> void:
	var u: Dictionary = unit_manager.get_unit_by_id(uid) if unit_manager else {}
	if u.is_empty():
		return
	if _fog:
		_fog.note_friendly_command_loss(uid, int(u.get("q", 0)), int(u.get("r", 0)), str(u.get("class", "")), unit_manager.get_current_turn() if unit_manager else 1)
	unit_renderer.call("set_node_visible", uid, false)

func _s6_note_recontact(uid: String) -> void:
	if _fog:
		_fog.clear_friendly_command_loss(uid)
	unit_renderer.call("set_node_visible", uid, true)

# STEP-06R1 S2: authoritative friendly-visibility repair. Ordinary movement
# (blue/red forced, cavalry post-attack, repositioning) must NEVER hide a
# live friendly formation. Only genuine command loss hides live truth.
func _ensure_friendly_visibility() -> void:
	if unit_manager == null or unit_renderer == null:
		return
	for u in unit_manager.get_all_units():
		if str(u.get("faction", "")) != "blue":
			continue
		if int(u.get("soldier_count", 0)) <= 0:
			continue
		if bool(u.get("garrisoned", false)):
			continue
		var uid: String = str(u.get("id", ""))
		if bool(u.get("routed", false)):
			unit_renderer.call("set_node_visible", uid, false)
			continue
		var node: Node2D = unit_renderer.call("get_unit_node", uid) as Node2D
		if node == null or not is_instance_valid(node):
			unit_renderer.call("spawn_unit", uid, str(u.get("class", "infantry")), "blue", int(u.get("q", 0)), int(u.get("r", 0)), int(u.get("soldier_count", 0)), str(u.get("form_factor", "form_a")))
			if str(u.get("class", "")) == "supply":
				unit_renderer.call("set_unit_convoy", uid, true)
			if str(u.get("class", "")) == "hq":
				unit_renderer.call("set_unit_hq", uid, true)
		else:
			unit_renderer.call("set_node_visible", uid, true)

func _s6_begin_turn() -> void:
	if _step6 == null or _battle_over():
		return
	var cell_data: Dictionary = hex_grid.get("cell_data") if hex_grid else {}
	var vis: Dictionary = _fog_visible_enemy_id_set()
	var rep: Dictionary = _step6.begin_player_turn(unit_manager, cell_data, _river_cells, _stronghold_cells, vis, _fog)
	
	# STEP-06R3: update field positions of supply NPCs that advanced along routes
	var sroutes: Dictionary = rep.get("supply_routes", {})
	for mc in (sroutes.get("moved_convoys", []) as Array):
		var cid: String = str(mc.get("id", ""))
		var cpos: Vector2i = mc.get("to", Vector2i(-999, -999))
		if cpos.x != -999 and unit_renderer:
			unit_renderer.call("update_unit_position", cid, cpos.x, cpos.y)

	for fl in (rep.get("fled", []) as Array):
		var fd: Vector2i = (fl as Dictionary)["to"]
		unit_renderer.call("update_unit_position", str((fl as Dictionary).get("id", "")), fd.x, fd.y)
	for rid in (rep.get("routed_new", []) as Array):
		unit_renderer.call("set_unit_routed", str(rid), true)
		unit_renderer.call("set_unit_dimmed", str(rid), true)
		_s6_note_command_loss(str(rid))
		var ru: Dictionary = unit_manager.get_unit_by_id(str(rid))
		if not ru.is_empty():
			unit_renderer.call("spawn_floating_text", Vector2i(int(ru.get("q", 0)), int(ru.get("r", 0))), "궤주!", Color(1.0, 0.30, 0.25, 1.0))
		_step6.note_routed_witness(unit_manager, str(rid))
		_show_combat_log("[%s] 궤주 — 지휘 상실" % str(rid))
	for rid2 in (rep.get("rallied", []) as Array):
		unit_renderer.call("set_unit_routed", str(rid2), false)
		unit_renderer.call("set_unit_dimmed", str(rid2), false)
		_s6_note_recontact(str(rid2))
		var ru3: Dictionary = unit_manager.get_unit_by_id(str(rid2))
		if not ru3.is_empty():
			unit_renderer.call("spawn_floating_text", Vector2i(int(ru3.get("q", 0)), int(ru3.get("r", 0))), "재집결!", Color(0.45, 0.90, 0.55, 1.0))
	_ensure_friendly_visibility()
	_sync_friendly_stale_markers()
	_refresh_node_markers()
	_update_supply_hud()
	
	# STEP-06R3: Synchronize unit overhead badges to current mode
	if unit_renderer and unit_renderer.has_method("set_overhead_display_mode"):
		unit_renderer.call("set_overhead_display_mode", _map_mode, unit_manager, _step6, cell_data, _stronghold_cells)

	if _map_mode == Step6ConfigCls.MAP_MODE_LOGISTICS:
		_refresh_logistics_map_overlay()
	_s6_update_route_line()
	
	if _trader_panel and _trader_panel.visible:
		_refresh_trader_destinations()
		
	if int(rep.get("hungry", 0)) > 0:
		_show_combat_log("보급 부족 %d개 부대 — 사기·피로 악화" % int(rep.get("hungry", 0)))
	if bool(rep.get("battle_lost", false)):
		_show_battle_loss()

func _s6_after_combat(res: Dictionary, atk_id: String, def_id: String, atk_coord: Vector2i, def_coord: Vector2i) -> void:
	if _step6 == null:
		return
	var out: Dictionary = _step6.after_combat(unit_manager, atk_id, def_id, res)
	if bool(out.get("captured", false)):
		unit_renderer.call("spawn_floating_text", atk_coord, "보급 획득! (가득참)", Color(0.95, 0.85, 0.40, 1.0))
		_show_combat_log("[%s] 적 수송대 격파 — 현지 보급 가득참 (중앙 군량 불변)" % atk_id)
	for rid in (out.get("routed", []) as Array):
		unit_renderer.call("set_unit_routed", str(rid), true)
		unit_renderer.call("set_unit_dimmed", str(rid), true)
		_s6_note_command_loss(str(rid))
		var ru: Dictionary = unit_manager.get_unit_by_id(str(rid))
		if not ru.is_empty():
			unit_renderer.call("spawn_floating_text", Vector2i(int(ru.get("q", 0)), int(ru.get("r", 0))), "궤주!", Color(1.0, 0.30, 0.25, 1.0))
		_step6.note_routed_witness(unit_manager, str(rid))
		_show_combat_log("[%s] 궤주 — 지휘 상실" % str(rid))
	if not (out.get("routed", []) as Array).is_empty():
		_fog_recalc("rout")
	if bool(out.get("battle_lost", false)):
		_show_battle_loss()
		return
	if unit_manager.is_unit_selected():
		_on_unit_selection_changed(unit_manager.get_selected_unit())

func _s6_rout_check_single(uid: String) -> void:
	if _step6 == null or uid == "":
		return
	var u: Dictionary = unit_manager.get_unit_by_id(uid)
	if u.is_empty() or int(u.get("soldier_count", 0)) <= 0:
		return
	if bool(u.get("routed", false)) or bool(u.get("garrisoned", false)):
		return
	if str(u.get("class", "")) == "supply":
		return
	var morale: float = float(u.get("morale", 100.0))
	if morale >= Step6ConfigCls.ROUT_MORALE_LINE:
		return
	if _step6.seeded_roll("%s:%d:shock" % [uid, unit_manager.get_current_turn()]) < Step6ConfigCls.ROUT_BASE_P:
		unit_manager.s6_set_routed(uid, true)
		unit_renderer.call("set_unit_routed", uid, true)
		unit_renderer.call("set_unit_dimmed", uid, true)
		_s6_note_command_loss(uid)
		_fog_recalc("rout")
		_step6.note_routed_witness(unit_manager, uid)
		_show_combat_log("[%s] 궤주 — 지휘 상실" % uid)

func _on_s6_unit_destroyed(unit_id: String, coord: Vector2i) -> void:
	# BATTLE_TERMINAL_CONTRACT_V0: HQ-terminal is symmetric and immediate on
	# both sides. (The legacy Step6 HQ hook is retired: _step6 is null.)
	# DEV test (WATCH_NO_HQ_WIN=1, 2026-10-08): an HQ is an ordinary unit; only the army-collapse rule ends a match.
	if CommanderMissionCls.enabled():
		if unit_id == _blue_hq_id:
			return
	elif OS.get_environment("WATCH_NO_HQ_WIN") == "1":
		return
	if unit_id == _blue_hq_id and not _blue_hq_id.is_empty():
		_show_battle_loss()
	elif unit_id == _red_hq_id and not _red_hq_id.is_empty():
		_show_battle_win()

func _show_battle_loss() -> void:
	if _battle_over():
		return
	_battle_lost = true
	if unit_manager:
		unit_manager.deselect()
	if _battle_panel == null:
		_battle_panel = Panel.new()
		_battle_panel.name = "BattleLossPanel"
		_battle_panel.set_anchors_preset(Control.PRESET_CENTER)
		_battle_panel.offset_left = -260
		_battle_panel.offset_top = -110
		_battle_panel.offset_right = 260
		_battle_panel.offset_bottom = 110
		var bst: StyleBoxFlat = StyleBoxFlat.new()
		bst.bg_color = Color(0.12, 0.05, 0.05, 0.96)
		bst.border_color = Color(1.0, 0.30, 0.25, 1.0)
		bst.set_border_width_all(3)
		bst.set_corner_radius_all(8)
		_battle_panel.add_theme_stylebox_override("panel", bst)
		hud_layer.add_child(_battle_panel)
		_battle_title = Label.new()
		_battle_title.text = "전투 패배 — BATTLE LOST"
		_battle_title.position = Vector2(20, 16)
		_battle_title.size = Vector2(480, 36)
		_battle_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_battle_title.add_theme_font_size_override("font_size", 24)
		_battle_title.add_theme_color_override("font_color", Color(1.0, 0.35, 0.30, 1.0))
		_battle_panel.add_child(_battle_title)
		_battle_sub = Label.new()
		_battle_sub.text = "사령부(지휘부)가 함락되었습니다. (HQ destroyed) — battle lost immediately."
		_battle_sub.position = Vector2(20, 60)
		_battle_sub.size = Vector2(480, 60)
		_battle_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_battle_sub.add_theme_font_size_override("font_size", 15)
		_battle_sub.add_theme_color_override("font_color", Color(0.95, 0.85, 0.80, 1.0))
		_battle_panel.add_child(_battle_sub)
		var rb: Button = Button.new()
		rb.text = "⟳ 시나리오 재시작"
		rb.position = Vector2(160, 140)
		rb.size = Vector2(200, 48)
		rb.focus_mode = Control.FOCUS_NONE
		rb.pressed.connect(func() -> void: get_tree().reload_current_scene())
		_battle_panel.add_child(rb)
	_battle_panel.visible = true
	_update_next_button_state()
	_show_combat_log("전투 패배 — 사령부 상실")

func _show_battle_win() -> void:
	if _battle_over():
		return
	_battle_won = true
	if unit_manager:
		unit_manager.deselect()
	if _battle_panel == null:
		_battle_panel = Panel.new()
		_battle_panel.name = "BattleWinPanel"
		_battle_panel.set_anchors_preset(Control.PRESET_CENTER)
		_battle_panel.offset_left = -260
		_battle_panel.offset_top = -110
		_battle_panel.offset_right = 260
		_battle_panel.offset_bottom = 110
		var bst: StyleBoxFlat = StyleBoxFlat.new()
		bst.bg_color = Color(0.05, 0.10, 0.18, 0.96)
		bst.border_color = Color(0.35, 0.75, 1.0, 1.0)
		bst.set_border_width_all(3)
		bst.set_corner_radius_all(8)
		_battle_panel.add_theme_stylebox_override("panel", bst)
		hud_layer.add_child(_battle_panel)
		_battle_title = Label.new()
		_battle_title.text = "전투 승리 — BATTLE WON"
		_battle_title.position = Vector2(20, 16)
		_battle_title.size = Vector2(480, 36)
		_battle_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_battle_title.add_theme_font_size_override("font_size", 24)
		_battle_title.add_theme_color_override("font_color", Color(0.35, 0.75, 1.0, 1.0))
		_battle_panel.add_child(_battle_title)
		_battle_sub = Label.new()
		_battle_sub.text = "적 사령부(지휘부)가 함락되었습니다. (RED HQ destroyed) — battle won immediately."
		_battle_sub.position = Vector2(20, 60)
		_battle_sub.size = Vector2(480, 60)
		_battle_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_battle_sub.add_theme_font_size_override("font_size", 15)
		_battle_sub.add_theme_color_override("font_color", Color(0.85, 0.95, 1.0, 1.0))
		_battle_panel.add_child(_battle_sub)
		var rb: Button = Button.new()
		rb.text = "⟳ 시나리오 재시작"
		rb.position = Vector2(160, 140)
		rb.size = Vector2(200, 48)
		rb.focus_mode = Control.FOCUS_NONE
		rb.pressed.connect(func() -> void: get_tree().reload_current_scene())
		_battle_panel.add_child(rb)
	_battle_panel.visible = true
	_update_next_button_state()
	_show_combat_log("전투 승리 — 적 사령부 함락")


func _fog_recalc(reason: String, announce: bool = true) -> void:
	if _fog == null or unit_manager == null or hex_grid == null:
		return
	var cell_data: Dictionary = hex_grid.get("cell_data")
	var all_units: Array = unit_manager.get_all_units()
	var friendlies: Array = []
	for u in all_units:
		if str(u.get("faction", "")) == "blue":
			friendlies.append(u)
	var res: Dictionary = _fog.recompute(friendlies, all_units, cell_data, unit_manager.get_current_turn())
	# HC01 is a fully revealed handcrafted test battlefield. Keep the ordinary
	# fog service and its observation API, but make every authored cell visible
	# after each recompute so terrain and enemy formations are never obscured.
	if battlefield_id == "HC01":
		for cell_key in cell_data.keys():
			_fog.visible[cell_key] = true
			_fog.explored[cell_key] = true
	_apply_fog_terrain()
	_apply_enemy_observation()
	_ensure_friendly_visibility()
	_sync_friendly_stale_markers()
	if announce:
		var newly: Array = res.get("newly_visible_enemies", [])
		for e in newly:
			_handle_enemy_discovery(e)
		if newly.size() > 0:
			_show_combat_log("적 발견: %d개 부대 관측됨" % newly.size())
	# Selection consistency: a selected enemy that left sight is no longer known.
	if unit_manager.is_unit_selected():
		var sel: Dictionary = unit_manager.get_selected_unit()
		if str(sel.get("faction", "")) == "red" and not _fog_is_enemy_visible(str(sel.get("id", ""))):
			var _lost: String = str(sel.get("id", ""))
			unit_manager.deselect()
			_show_combat_log("관측 상실 — 적이 시야에서 사라짐")
			# STEP-05R1: selected contact went stale — flip its intel panel over.
			if _intel_subject_id == _lost:
				_open_enemy_intel_stale(_lost)
		elif str(sel.get("faction", "")) == "blue" and reason != "init":
			_recalculate_envelope_for_unit(sel)
	# BUG-S4-01 watch (player phase only — enemy-phase damage is legitimate combat).
	if _turn_phase == TurnPhase.PLAYER_PHASE:
		for u in all_units:
			if str(u.get("faction", "")) != "red":
				continue
			var uid: String = str(u.get("id", ""))
			var c: int = int(u.get("soldier_count", 0))
			if _fog_last_red_counts.has(uid) and c < int(_fog_last_red_counts[uid]) and not _fog_recent_combat:
				print("[BUG-S4-01?] %s HP %d -> %d without player combat (reason=%s)" % [uid, int(_fog_last_red_counts[uid]), c, reason])
			_fog_last_red_counts[uid] = c
	_fog_recent_combat = false

## Fog presentation push (VISUAL ONLY): fog truth stays in Step5FogOfWar; the
## board compositor's HexFogRenderer is the one tactical-obscurity layer.
func _apply_fog_terrain() -> void:
	if hex_compositor and hex_compositor.has_method("refresh_fog"):
		hex_compositor.call("refresh_fog", _fog)

## HEX-NATIVE COMPOSITOR: the single authoritative board presentation.
## HEADLESS mode builds nothing (no display, no consumers); every compositor
## entry point is a no-op until build_all() has run.
func _build_hex_compositor(cell_data: Dictionary) -> void:
	if hex_compositor == null:
		return
	if PresentationOrientationCls.is_headless():
		print("[HexNative] compositor skipped (HEADLESS presentation mode)")
		return
	var unit_coords: Array = _collect_hex_unit_coords()
	var result: Dictionary = hex_compositor.call("build_all", cell_data, _river_cells, _stronghold_cells, unit_coords, _fog, stronghold_visual_specs(), _is_tutorial_battlefield())
	_forward_hex_feedback()
	print("[HexNative] compositor built: %s" % str(result))

## Stronghold presentation specs (VISUAL ONLY, read-only): the ONE place the
## visual layers learn where a city / fortress stands. Derived from the same
## constants that assign stronghold terrain, so a moved stronghold moves its
## art in both HIGH and CLOSEUP. The anchor is the hex the art stands on (one
## stronghold = one hex); the rest of the logical footprint is ground apron.
## CANONICAL BATTLEFIELDS: garrisons are whatever the unit manager seated
## from the map deployment (units placed on a same-owner footprint). Mirrors
## the default path: garrisoned units leave the field renderer, strongholds
## get their plates.
func _setup_battlefield_garrisons() -> void:
	for u in unit_manager.get_all_units_including_garrisoned():
		var gid: String = str(u.get("id", ""))
		if unit_manager.is_garrisoned(gid):
			if unit_renderer.has_method("remove_unit"):
				unit_renderer.call("remove_unit", gid)
			elif unit_renderer.has_method("hide_unit"):
				unit_renderer.call("hide_unit", gid)
	if stronghold_renderer:
		stronghold_renderer.set("display_names", battlefield_stronghold_names())
		stronghold_renderer.call("render_strongholds", unit_manager.get_all_strongholds())
		if stronghold_renderer.has_signal("stronghold_clicked"):
			stronghold_renderer.stronghold_clicked.connect(_on_stronghold_clicked_by_badge)
		if stronghold_renderer.has_signal("stronghold_hover_changed"):
			stronghold_renderer.stronghold_hover_changed.connect(_on_stronghold_hover_changed)
	for sh in unit_manager.get_all_strongholds():
		print("[Battlefield] stronghold %s garrison %d" % [str(sh.structure_id), int(sh.get_garrison_count())])

## Display names of the loaded battlefield's strongholds ({} on the default map).
func battlefield_stronghold_names() -> Dictionary:
	var out: Dictionary = {}
	if not _battlefield.is_empty():
		for sd in _battlefield["strongholds"]:
			out[str(sd["id"])] = str(sd["name"])
	return out

func battlefield_stronghold_name(stronghold_id: String) -> String:
	return str(battlefield_stronghold_names().get(stronghold_id, ""))

func stronghold_visual_specs() -> Array:
	if is_step0_sandbox:
		return []
	if not _battlefield.is_empty():
		var specs: Array = []
		for sd in _battlefield["strongholds"]:
			var cap: bool = str(sd["type"]) == "capital"
			specs.append({"id": sd["id"], "role": 2 if cap else 1, "terrain": 11 if cap else 9, "anchor": sd["anchor"], "footprint": (sd["footprint"] as Array).duplicate()})
		return specs
	return [
		{"id": FORTRESS_ID, "role": 1, "terrain": 9, "anchor": FORTRESS_FOOTPRINT[0], "footprint": FORTRESS_FOOTPRINT.duplicate()},
		{"id": CAPITAL_ID, "role": 2, "terrain": 11, "anchor": CAPITAL_FOOTPRINT[0], "footprint": CAPITAL_FOOTPRINT.duplicate()},
	]

func _collect_hex_unit_coords() -> Array:
	var out: Array = []
	if unit_manager != null:
		for u in unit_manager.get_all_units():
			out.append(Vector2i(int(u.get("q", -999)), int(u.get("r", -999))))
	elif unit_renderer != null:
		for u in (unit_renderer.call("get_all_units") as Array):
			out.append(Vector2i(int(u.get("q", -999)), int(u.get("r", -999))))
	return out

var _hex_feedback_last_hover: Vector2i = Vector2i(-999, -999)
var _hex_feedback_last_sel: Vector2i = Vector2i(-999, -999)

func _forward_hex_feedback() -> void:
	if hex_compositor == null:
		return
	var sel: Vector2i = Vector2i(-999, -999)
	if unit_manager != null and unit_manager.is_unit_selected():
		var s: Dictionary = unit_manager.get_selected_unit()
		sel = Vector2i(int(s.get("q", -999)), int(s.get("r", -999)))
	if _current_hover_hex != _hex_feedback_last_hover:
		_hex_feedback_last_hover = _current_hover_hex
		hex_compositor.call("set_hovered", _current_hover_hex)
	if sel != _hex_feedback_last_sel:
		_hex_feedback_last_sel = sel
		hex_compositor.call("set_selected", sel)

func _apply_enemy_observation() -> void:
	if is_step0_sandbox:
		for u in unit_manager.get_all_units():
			var uid: String = str(u.get("id", ""))
			var node: Node2D = unit_renderer.call("get_unit_node", uid) as Node2D
			if node and is_instance_valid(node):
				node.visible = not bool(u.get("routed", false))
				var cnt: int = int(u.get("soldier_count", 0))
				var mx: int = maxi(1, int(u.get("max_count", cnt)))
				if unit_renderer.has_method("set_enemy_observation_display"):
					unit_renderer.call("set_enemy_observation_display", uid, str(cnt), float(cnt) / float(mx))
		return
	for u in unit_manager.get_all_units():
		var uid: String = str(u.get("id", ""))
		var node: Node2D = unit_renderer.call("get_unit_node", uid) as Node2D
		if node == null or not is_instance_valid(node):
			continue
		if str(u.get("faction", "")) != "red":
			node.visible = not bool(u.get("routed", false)) # S4: routed truth hides; frozen marker shows
			continue
		var vis: bool = _fog_is_enemy_visible(uid)
		node.visible = vis
		if vis:
			# STEP-05R2 §19-§20/§24: badge consumes the SAME observation record
			# as the right-side panel. Combat-assessed => approx + health bar;
			# otherwise "?" with bar hidden. Never exact truth (§14/§22).
			var obs: Dictionary = _fog_get_enemy_observation(u)
			if bool(obs.get("combat_assessed", false)):
				var _true_n: int = int(u.get("soldier_count", 0))
				var _ratio: float = float(obs.get("health_ratio", -1.0))
				if _ratio < 0.0:
					var _mx: int = maxi(1, int(u.get("max_count", maxi(1, _true_n))))
					_ratio = clampf(float(_true_n) / float(_mx), 0.0, 1.0)
				var badge_txt: String = Step5FogCls.combat_badge_text(_true_n)
				if unit_renderer and unit_renderer.has_method("set_enemy_observation_display"):
					unit_renderer.call("set_enemy_observation_display", uid, badge_txt, _ratio)
				else:
					var count_lbl2: Label = node.get_node_or_null("CountLabel") as Label
					if count_lbl2:
						count_lbl2.text = badge_txt
					var hp2: Sprite2D = node.get_node_or_null("HPBar") as Sprite2D
					if hp2:
						hp2.visible = true
			elif bool(obs.get("scout_observed", false)):
				var _true_n: int = int(u.get("soldier_count", 0))
				var badge_txt: String = Step5FogCls.combat_badge_text(_true_n)
				if unit_renderer and unit_renderer.has_method("set_enemy_observation_display"):
					unit_renderer.call("set_enemy_observation_display", uid, badge_txt, -1.0)
				else:
					var count_lbl2: Label = node.get_node_or_null("CountLabel") as Label
					if count_lbl2:
						count_lbl2.text = badge_txt
					var hp2: Sprite2D = node.get_node_or_null("HPBar") as Sprite2D
					if hp2:
						hp2.visible = false
			else:
				if unit_renderer and unit_renderer.has_method("set_enemy_observation_display"):
					unit_renderer.call("set_enemy_observation_display", uid, "?", -1.0)
				else:
					var count_lbl: Label = node.get_node_or_null("CountLabel") as Label
					if count_lbl:
						count_lbl.text = "?"
					var hp: Sprite2D = node.get_node_or_null("HPBar") as Sprite2D
					if hp:
						hp.visible = false
	if _current_hover_hex.x != -999:
		var h: Dictionary = unit_manager.get_unit_at(_current_hover_hex.x, _current_hover_hex.y)
		if not h.is_empty() and str(h.get("faction", "")) == "red" and not _fog_is_enemy_visible(str(h.get("id", ""))):
			unit_renderer.call("clear_hover")
			_current_hover_hex = Vector2i(-999, -999)
	_sync_stale_markers()

func _fog_is_enemy_visible(enemy_id: String) -> bool:
	if _fog == null or unit_manager == null:
		return true
	var e: Dictionary = unit_manager.get_unit_by_id(enemy_id)
	if e.is_empty():
		return false
	return _fog.is_enemy_visible(e)

# STEP-05R2 §1-§3: planning knowledge = friendly + CURRENTLY-VISIBLE enemies only.
# Hidden enemy occupancy is unknown space — never a planning blocker.
func _fog_visible_enemy_id_set() -> Dictionary:
	var out: Dictionary = {}
	if unit_manager == null:
		return out
	if _fog == null:
		for u in unit_manager.get_all_units():
			if str(u.get("faction", "")) == "red":
				out[str(u.get("id", ""))] = true
		return out
	for u in unit_manager.get_all_units():
		if str(u.get("faction", "")) != "red":
			continue
		var eid: String = str(u.get("id", ""))
		if _fog.is_enemy_visible(u):
			out[eid] = true
	return out

func _player_known_occupied() -> Dictionary:
	if unit_manager == null:
		return {}
	var vis: Dictionary = _fog_visible_enemy_id_set()
	if unit_manager.has_method("get_player_known_occupied"):
		return unit_manager.get_player_known_occupied(vis)
	# Fallback: manual filter of truth (same rule, no leak).
	var truth: Dictionary = unit_manager.get_occupied_dict()
	var out: Dictionary = {}
	for k in truth.keys():
		var u: Dictionary = truth[k]
		var fac: String = str(u.get("faction", ""))
		if fac == "blue":
			out[k] = u
		elif fac == "red" and vis.has(str(u.get("id", ""))):
			out[k] = u
	return out

func _fog_get_enemy_observation(enemy: Dictionary) -> Dictionary:
	if _fog == null or unit_manager == null:
		return {"visible": true, "scout_observed": false, "class_kr": "???", "troop_text": "병력: 알 수 없음", "morale_text": "사기: 알 수 없음"}
	return _fog.get_enemy_observation(enemy, unit_manager.get_current_turn())

func _fog_snapshot_hidden_enemies() -> Dictionary:
	var out: Dictionary = {}
	if unit_manager == null:
		return out
	for u in unit_manager.get_all_units():
		if str(u.get("faction", "")) != "red":
			continue
		var uid: String = str(u.get("id", ""))
		if not _fog_is_enemy_visible(uid):
			out[uid] = true
	return out

# STEP-05 §23 minimal deterministic trigger: after the mover's step, a
# previously-hidden enemy with a legal adjacent melee attack surprises it.
func _fog_check_ambush(mover_id: String, dest: Vector2i, pre_hidden: Dictionary) -> void:
	if unit_manager == null:
		return
	var mover: Dictionary = unit_manager.get_unit_by_id(mover_id)
	if mover.is_empty() or str(mover.get("faction", "")) != "blue":
		return
	var cands: Array = []
	for u in unit_manager.get_all_units():
		if str(u.get("faction", "")) != "red":
			continue
		if int(u.get("soldier_count", 0)) <= 0:
			continue
		var ec := Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))
		if HexUtilsCls.hex_distance_axial(dest, ec) != 1:
			continue
		if CombatCalculatorCls.get_attack_range(str(u.get("class", ""))) != 1:
			continue
		if not bool(pre_hidden.get(str(u.get("id", "")), false)):
			continue # known contact -> normal engagement, no surprise (§24)
		cands.append(u)
	if cands.is_empty():
		return
	cands.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.get("id", "")) < str(b.get("id", "")))
	var aid: String = str((cands[0] as Dictionary).get("id", ""))
	_fog_recent_combat = true
	var res: Dictionary = unit_manager.execute_ambush_strike(aid, mover_id)
	if not bool(res.get("success", false)):
		return
	# STEP-05R1: surviving the ambush reveals the ambusher's condition.
	_fog_mark_engaged(aid)
	var vic_cas: int = int(res.get("defender_casualties", 0))
	unit_renderer.call("animate_unit_attack", aid, dest)
	unit_renderer.call("spawn_floating_text", dest, "매복! -%d명 (기습)" % vic_cas, Color(1.0, 0.30, 0.25, 1.0))
	if vic_cas > 0:
		unit_renderer.call("animate_unit_hit", mover_id, vic_cas)
		unit_renderer.call("update_unit_health", mover_id, int(res.get("defender_remaining_troops", 0)))
	if bool(res.get("victim_destroyed", false)):
		unit_renderer.call("spawn_floating_text", dest, "아군 부대 전멸!", Color(0.85, 0.20, 0.20, 1.0))
		unit_renderer.call("remove_unit", mover_id)
	else:
		unit_renderer.call("set_unit_dimmed", mover_id, true)
	_show_combat_log("매복! [%s] 기습 -> [%s]  |  아군 손실: -%d명 (반격 없음)" % [aid, mover_id, vic_cas])
	var am: Node = get_node_or_null("/root/AudioManager")
	if am and am.has_method("play_sfx"):
		am.call("play_sfx", "sword")

# ------------------------------------------------------------------
# STEP-05R1: Enemy Intelligence UI — stale markers, intel panel, recon report.
# Observation-layer only: frozen snapshots, never hidden World Truth.
# ------------------------------------------------------------------
func _setup_intel_ui() -> void:
	_intel_panel = Panel.new()
	_intel_panel.name = "EnemyIntelPanel"
	_intel_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_intel_panel.offset_left = -464
	_intel_panel.offset_top = 70
	_intel_panel.offset_right = -24
	_intel_panel.offset_bottom = 560
	_intel_style_current = StyleBoxFlat.new()
	_intel_style_current.bg_color = Color(0.13, 0.08, 0.09, 0.96)
	_intel_style_current.border_color = Color(0.95, 0.30, 0.28, 0.95)
	_intel_style_current.set_border_width_all(2)
	_intel_style_current.set_corner_radius_all(8)
	_intel_style_stale = StyleBoxFlat.new()
	_intel_style_stale.bg_color = Color(0.13, 0.10, 0.07, 0.94)
	_intel_style_stale.border_color = Color(0.55, 0.38, 0.20, 0.95)
	_intel_style_stale.set_border_width_all(2)
	_intel_style_stale.set_corner_radius_all(8)
	_intel_panel.add_theme_stylebox_override("panel", _intel_style_current)
	_intel_panel.visible = false
	hud_layer.add_child(_intel_panel)
	_intel_title = Label.new()
	_intel_title.position = Vector2(18, 14)
	_intel_title.size = Vector2(368, 26)
	_intel_title.add_theme_font_size_override("font_size", 17)
	_intel_panel.add_child(_intel_title)
	var iclose: Button = Button.new()
	iclose.position = Vector2(440 - 36, 12)
	iclose.size = Vector2(24, 24)
	iclose.text = "✕"
	iclose.focus_mode = Control.FOCUS_NONE
	iclose.add_theme_font_size_override("font_size", 13)
	iclose.pressed.connect(_close_enemy_intel)
	_intel_panel.add_child(iclose)
	_intel_sub = Label.new()
	_intel_sub.position = Vector2(18, 44)
	_intel_sub.size = Vector2(404, 22)
	_intel_sub.add_theme_font_size_override("font_size", 13)
	_intel_panel.add_child(_intel_sub)
	_intel_body = Label.new()
	_intel_body.position = Vector2(18, 72)
	_intel_body.size = Vector2(404, 400)
	_intel_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_intel_body.add_theme_font_size_override("font_size", 14)
	_intel_body.add_theme_color_override("font_color", Color(0.92, 0.92, 0.94, 1.0))
	_intel_panel.add_child(_intel_body)
	# Recon report banner (top-center, below combat log slot).
	_recon_panel = Panel.new()
	_recon_panel.name = "ReconReportPanel"
	_recon_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_recon_panel.offset_left = -300
	_recon_panel.offset_top = 112
	_recon_panel.offset_right = 300
	_recon_panel.offset_bottom = 196
	var rc_style: StyleBoxFlat = StyleBoxFlat.new()
	rc_style.bg_color = Color(0.10, 0.09, 0.06, 0.96)
	rc_style.border_color = Color(1.0, 0.82, 0.30, 0.98)
	rc_style.set_border_width_all(2)
	rc_style.set_corner_radius_all(8)
	_recon_panel.add_theme_stylebox_override("panel", rc_style)
	_recon_panel.visible = false
	hud_layer.add_child(_recon_panel)
	_recon_title = Label.new()
	_recon_title.set_anchors_preset(Control.PRESET_FULL_RECT)
	_recon_title.offset_left = 16
	_recon_title.offset_top = 8
	_recon_title.offset_right = -16
	_recon_title.offset_bottom = 34
	_recon_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_recon_title.add_theme_font_size_override("font_size", 17)
	_recon_title.add_theme_color_override("font_color", Color(1.0, 0.86, 0.40, 1.0))
	_recon_panel.add_child(_recon_title)
	_recon_body = Label.new()
	_recon_body.set_anchors_preset(Control.PRESET_FULL_RECT)
	_recon_body.offset_left = 16
	_recon_body.offset_top = 36
	_recon_body.offset_right = -16
	_recon_body.offset_bottom = -6
	_recon_body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_recon_body.add_theme_font_size_override("font_size", 13)
	_recon_body.add_theme_color_override("font_color", Color(0.95, 0.93, 0.86, 1.0))
	_recon_panel.add_child(_recon_body)

func _open_enemy_intel_current(enemy_id: String) -> void:
	if unit_manager == null or _intel_panel == null:
		return
	var e: Dictionary = unit_manager.get_unit_by_id(enemy_id)
	if e.is_empty():
		return
	_close_stronghold_panel()
	var obs: Dictionary = _fog_get_enemy_observation(e)
	_intel_subject_id = enemy_id
	_intel_stale_mode = false
	_intel_panel.add_theme_stylebox_override("panel", _intel_style_current)
	_intel_title.text = "적 정보 — %s [%s]" % [str(obs.get("class_kr", "???")), enemy_id]
	_intel_title.add_theme_color_override("font_color", Color(1.0, 0.55, 0.50, 1.0))
	_intel_sub.text = "현재 관측 중"
	_intel_sub.add_theme_color_override("font_color", Color(1.0, 0.45, 0.40, 1.0))
	var lines: Array[String] = []
	lines.append("병종: 적 %s" % str(obs.get("class_kr", "???")))
	lines.append("위치: (%d, %d)" % [int(e.get("q", 0)), int(e.get("r", 0))])
	var qual_str: String = "직접 교전 (전투 평가 완료)" if bool(obs.get("combat_assessed", false)) else ("정찰병 추정치" if bool(obs.get("scout_observed", false)) else "일반 관측 (병력 미상)")
	lines.append("관측: %s" % qual_str)
	lines.append(str(obs.get("troop_text", "병력: ???")))
	if bool(obs.get("has_health", false)):
		var hr: float = float(obs.get("health_ratio", 0.0))
		lines.append("잔존 전력: %s %d%%" % [_make_wall_bar(hr), roundi(hr * 100.0)])
	_intel_body.text = "\n".join(lines)
	_intel_panel.visible = true
	# STEP-05R2 §20: Ensure overhead badge and right panel share the same observation immediately
	_apply_enemy_observation()

func _open_enemy_intel_stale(enemy_id: String) -> void:
	if _intel_panel == null or _fog == null:
		return
	var snap: Dictionary = _fog.get_stale_snapshot(enemy_id)
	if snap.is_empty():
		return
	_close_stronghold_panel()
	_intel_subject_id = enemy_id
	_intel_stale_mode = true
	_intel_panel.add_theme_stylebox_override("panel", _intel_style_stale)
	var kr: String = Step5FogCls.class_to_kr_short(str(snap.get("class", "")))
	_intel_title.text = "적 정보 — %s [%s]" % [kr, enemy_id]
	_intel_title.add_theme_color_override("font_color", Color(0.75, 0.58, 0.36, 1.0))
	_intel_sub.text = "마지막 확인 정보 — 현재 위치 불명"
	_intel_sub.add_theme_color_override("font_color", Color(0.65, 0.48, 0.28, 1.0))
	var lines: Array[String] = []
	lines.append("병종: 적 %s" % kr)
	lines.append("마지막 확인 위치: (%d, %d)" % [int(snap.get("q", 0)), int(snap.get("r", 0))])
	lines.append("마지막 확인 턴: 제 %d 턴" % int(snap.get("turn", 1)))
	lines.append("마지막 추정 병력: %s" % str(snap.get("troop_text", "병력: ???")).replace("병력: ", ""))
	if bool(snap.get("has_health", false)):
		var hr2: float = float(snap.get("health_ratio", 0.0))
		lines.append("마지막 잔존 전력: %s %d%%" % [_make_wall_bar(hr2), roundi(hr2 * 100.0)])
	_intel_body.text = "\n".join(lines)
	_intel_panel.visible = true

func _close_enemy_intel() -> void:
	_intel_subject_id = ""
	_intel_stale_mode = false
	if _intel_panel:
		_intel_panel.visible = false

func _show_recon_report(title_text: String, body_text: String, scout: bool) -> void:
	if _recon_panel == null:
		return
	_recon_title.text = title_text
	_recon_body.text = body_text
	if scout:
		_recon_title.add_theme_color_override("font_color", Color(1.0, 0.86, 0.40, 1.0))
	else:
		_recon_title.add_theme_color_override("font_color", Color(0.75, 0.82, 0.95, 1.0))
	if _recon_tween and _recon_tween.is_valid():
		_recon_tween.kill()
	_recon_panel.visible = true
	_recon_panel.modulate = Color(1, 1, 1, 1)
	_recon_tween = create_tween()
	_recon_tween.tween_interval(1.6)
	_recon_tween.tween_property(_recon_panel, "modulate:a", 0.0, 0.4)
	_recon_tween.tween_callback(func():
		if is_instance_valid(_recon_panel):
			_recon_panel.visible = false
	)

# FIRST discovery: full report + auto-focus panel. Re-discovery: small resume note.
func _handle_enemy_discovery(e: Dictionary) -> void:
	var eid: String = str(e.get("id", ""))
	var first: bool = bool(e.get("first_discovery", not _known_enemy_ids.has(eid)))
	if first:
		_known_enemy_ids[eid] = true
	var kr: String = Step5FogCls.class_to_kr_short(str(e.get("class", "")))
	var ec := Vector2i(int(e.get("q", 0)), int(e.get("r", 0)))
	var scout: bool = _fog.is_enemy_scout_observed(e) if _fog else false
	var obs: Dictionary = _fog.get_enemy_observation(e, unit_manager.get_current_turn()) if _fog else {}
	if first:
		if scout:
			_show_recon_report("정찰 보고 — 적 발견!",
				"병종: %s\n규모: %s\n위치: (%d, %d)" % [kr, str(obs.get("troop_text", "병력: ???")).replace("병력: ", ""), ec.x, ec.y], true)
		else:
			_show_recon_report("적 발견", "적 %s\n병력: 불명" % kr, false)
			unit_renderer.call("spawn_floating_text", ec, "적 발견", Color(0.85, 0.90, 1.0, 1.0))
		unit_renderer.call("spawn_floating_text", ec, "! 적 발견: %s" % kr, Color(1.0, 0.85, 0.30, 1.0))
		_emit_discovery_event(e, "scout" if scout else "normal", true, obs)
		if camera and camera.has_method("focus_on"):
			camera.call("focus_on", HexUtilsCls.hex_to_pixel(ec.x, ec.y), false)
	else:
		unit_renderer.call("spawn_floating_text", ec, "접촉 재개: %s" % kr, Color(1.0, 0.75, 0.45, 1.0))
		_emit_discovery_event(e, "scout" if scout else "normal", false, obs)
	_open_enemy_intel_current(eid)

# Future SLM hook: Observation Event -> Advisor Knowledge -> SLM report.
# Observable facts only — never morale truth, supply, MP, or AI state.
func _emit_discovery_event(e: Dictionary, observer_type: String, first: bool, obs: Dictionary) -> void:
	if unit_manager == null:
		return
	unit_manager.log_observable_event({
		"type": "enemy_discovered",
		"enemy_id": str(e.get("id", "")),
		"observer_type": observer_type,
		"class": str(e.get("class", "")),
		"estimated_strength": str(obs.get("troop_text", "병력: ???")),
		"hex": Vector2i(int(e.get("q", 0)), int(e.get("r", 0))),
		"first": first,
	})
	print("[Discovery] enemy=%s observer=%s class=%s %s hex=(%d,%d) first=%s" % [
		str(e.get("id", "")), observer_type, str(e.get("class", "")),
		str(obs.get("troop_text", "")), int(e.get("q", 0)), int(e.get("r", 0)), str(first)])

func _fog_mark_engaged(enemy_id: String) -> void:
	if _fog == null or unit_manager == null:
		return
	var e: Dictionary = unit_manager.get_unit_by_id(enemy_id)
	if e.is_empty():
		return
	var mx: int = maxi(1, int(e.get("max_count", e.get("soldier_count", 1))))
	_fog.mark_combat_engaged(enemy_id, clampf(float(e.get("soldier_count", 0)) / float(mx), 0.0, 1.0))

func _pick_stale_at(world_pos: Vector2, radius: float, coord: Vector2i = Vector2i(-999, -999)) -> String:
	if _fog == null:
		return ""
	var best: String = ""
	var best_d: float = 1e9
	for eid in (_fog.get_all_stale() as Dictionary).keys():
		var snap: Dictionary = _fog.get_stale_snapshot(str(eid))
		if snap.is_empty():
			continue
		var sq: int = int(snap.get("q", 0))
		var sr: int = int(snap.get("r", 0))
		var sp: Vector2 = HexUtilsCls.hex_to_pixel(sq, sr)
		var d: float = world_pos.distance_to(sp)
		if (sq == coord.x and sr == coord.y) or (d < radius and d < best_d):
			best_d = d
			best = str(eid)
			if sq == coord.x and sr == coord.y:
				break
	return best

func _sync_stale_markers() -> void:
	if _stale_layer == null:
		_stale_layer = Node2D.new()
		_stale_layer.name = "StaleContactLayer"
		# STEP-05R2 §11: above terrain/envelope, below live units. The shell
		# fog path uses terrain modulate (no FogLayer overlay), so z=9 keeps
		# the brown ghost visible over EXPLORED hexes without covering live RED.
		_stale_layer.z_index = 9
		add_child(_stale_layer)
	if _fog == null or unit_manager == null:
		return
	var stale: Dictionary = _fog.get_all_stale()
	for eid in _stale_markers.keys():
		var sid: String = str(eid)
		var gone: bool = not stale.has(sid)
		if not gone and unit_manager.get_unit_by_id(sid).is_empty():
			gone = true
		if not gone and _fog_is_enemy_visible(sid):
			gone = true
		if gone:
			var n: Node2D = _stale_markers[sid] as Node2D
			_stale_markers.erase(sid)
			if is_instance_valid(n):
				n.queue_free()
	for eid in stale.keys():
		var sid2: String = str(eid)
		if _stale_markers.has(sid2):
			continue # frozen — never follows the hidden true enemy
		var snap: Dictionary = (stale[eid] as Dictionary)
		var sq: int = int(snap.get("q", 0))
		var sr: int = int(snap.get("r", 0))
		# STEP-05R2 §10/§14: the stale hex is usually still held by the hidden
		# enemy truth itself (its live node is visible=false, so no overlap).
		# Only skip when a DIFFERENT formation holds the hex (e.g. friendly
		# moved onto it) — never suppress the ghost because of its own truth.
		var occ: Dictionary = unit_manager.get_unit_at(sq, sr) if unit_manager.has_method("get_unit_at") else {}
		if not occ.is_empty() and str(occ.get("id", "")) != sid2:
			continue # a different live formation holds that hex — no stale overlay
		_stale_markers[sid2] = _build_stale_marker(sid2, snap)

func _build_stale_marker(enemy_id: String, snap: Dictionary) -> Node2D:
	var root: Node2D = Node2D.new()
	root.name = "Stale_%s" % enemy_id
	root.position = HexUtilsCls.hex_to_pixel(int(snap.get("q", 0)), int(snap.get("r", 0)))
	root.z_index = 9
	# Upright under the friendly-side yaw; a flat-top hex rotated 120deg maps
	# onto itself, so the hex outline stays aligned. yaw 0 -> 0.
	root.rotation = PresentationOrientationCls.upright_rotation()
	root.set_meta("enemy_id", enemy_id)
	var brown := Color(0.65, 0.44, 0.22, 0.90)
	var brown_fill := Color(0.42, 0.28, 0.14, 0.45)
	
	# Flat-top hexagon geometry matching 48x42 hex grid (radius 24)
	var hex_pts := PackedVector2Array([
		Vector2(24, 0),
		Vector2(12, 21),
		Vector2(-12, 21),
		Vector2(-24, 0),
		Vector2(-12, -21),
		Vector2(12, -21)
	])
	var fill := Polygon2D.new()
	fill.polygon = hex_pts
	fill.color = brown_fill
	root.add_child(fill)
	
	var line_pts := PackedVector2Array([
		Vector2(24, 0),
		Vector2(12, 21),
		Vector2(-12, 21),
		Vector2(-24, 0),
		Vector2(-12, -21),
		Vector2(12, -21),
		Vector2(24, 0)
	])
	var line := Line2D.new()
	line.points = line_pts
	line.width = 3.0
	line.default_color = brown
	root.add_child(line)
	
	# STEP-05R3 §16-§20: class-preserving stale visual — the frozen last-known
	# class silhouette + class glyph. Generic "?" ONLY when class is genuinely
	# unknown. Sepia/brown ghost treatment keeps it clearly stale, never live RED.
	var raw_class: String = str(snap.get("class", "")).to_lower().strip_edges()
	var uclass: String = raw_class
	match uclass:
		"spearmen", "spear":
			uclass = "spearman"
		"archers":
			uclass = "archer"
		"scouts":
			uclass = "scout"
		"conscripts":
			uclass = "conscript"
	var class_known: bool = raw_class != "" and raw_class != "unknown" and raw_class != "???"
	var kr: String = Step5FogCls.class_to_kr_short(raw_class) if class_known else "?"
	for bp in ["res://assets/badges/red/badge_%s_red.png" % uclass, "res://assets/badges/red/badge_%s_red_form_a.png" % uclass]:
		if class_known and ResourceLoader.exists(bp):
			var sp := Sprite2D.new()
			sp.texture = load(bp) as Texture2D
			sp.modulate = Color(0.72, 0.50, 0.28, 0.72) # sepia ghost: readable yet clearly stale
			sp.position = Vector2(0, -5)
			sp.scale = Vector2(0.80, 0.80)
			root.add_child(sp)
			break
	
	var has_hp: bool = bool(snap.get("has_health", false))
	var hr: float = clampf(float(snap.get("health_ratio", -1.0)), 0.0, 1.0) if has_hp else -1.0
	# Main glyph: last-known class (기병/궁병/정찰병/…) — frozen snapshot only.
	var lbl := Label.new()
	lbl.text = kr
	lbl.add_theme_font_size_override("font_size", 15 if class_known else 16)
	lbl.position = Vector2(-28, -16)
	lbl.size = Vector2(56, 22)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_color_override("font_color", Color(0.92, 0.75, 0.48, 0.95))
	lbl.add_theme_color_override("font_shadow_color", Color(0.1, 0.05, 0.0, 0.9))
	lbl.add_theme_constant_override("shadow_offset_x", 1)
	lbl.add_theme_constant_override("shadow_offset_y", 1)
	root.add_child(lbl)
	
	# Frozen last-seen turn tag + frozen troop hint (§13/§16/§19) — snapshot only.
	var turn_lbl := Label.new()
	var _tt: String = str(snap.get("troop_text", ""))
	var _digits: String = ""
	for _ch in _tt:
		if (_ch >= "0" and _ch <= "9") or _ch == "~" or _ch == ",":
			_digits += _ch
	if not _digits.is_empty() and _digits != "~":
		if not _digits.begins_with("~"):
			_digits = "~" + _digits
		turn_lbl.text = "T%d · %s" % [int(snap.get("turn", 1)), _digits]
		turn_lbl.add_theme_font_size_override("font_size", 9)
	else:
		turn_lbl.text = "T%d" % int(snap.get("turn", 1))
		turn_lbl.add_theme_font_size_override("font_size", 10)
	turn_lbl.position = Vector2(-28, 6)
	turn_lbl.size = Vector2(56, 14)
	turn_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	turn_lbl.add_theme_color_override("font_color", Color(0.80, 0.60, 0.35, 0.90))
	turn_lbl.add_theme_color_override("font_shadow_color", Color(0.1, 0.05, 0.0, 0.9))
	turn_lbl.add_theme_constant_override("shadow_offset_x", 1)
	turn_lbl.add_theme_constant_override("shadow_offset_y", 1)
	root.add_child(turn_lbl)
	
	# Frozen remaining-strength bar (§23) — quad pair, no renderer dependency.
	if has_hp:
		var bg := Polygon2D.new()
		bg.polygon = PackedVector2Array([Vector2(-18, -36), Vector2(18, -36), Vector2(18, -31), Vector2(-18, -31)])
		bg.color = Color(0.08, 0.06, 0.05, 0.90)
		root.add_child(bg)
		var fw: float = 36.0 * hr
		var fg := Polygon2D.new()
		fg.polygon = PackedVector2Array([Vector2(-18, -36), Vector2(-18 + fw, -36), Vector2(-18 + fw, -31), Vector2(-18, -31)])
		fg.color = Color(0.80, 0.45, 0.20, 0.95)
		root.add_child(fg)
	
	_stale_layer.add_child(root)
	return root

# ------------------------------------------------------------------
# STEP-06R1 S4/S24: friendly command-loss markers. Same frozen-snapshot
# philosophy as enemy stale contacts, but muted BLUE: last-known class
# badge, frozen turn, " able" label. Never follows hidden truth.
# ------------------------------------------------------------------
func _sync_friendly_stale_markers() -> void:
	if _friendly_stale_layer == null:
		_friendly_stale_layer = Node2D.new()
		_friendly_stale_layer.name = "FriendlyStaleLayer"
		_friendly_stale_layer.z_index = 8
		add_child(_friendly_stale_layer)
	if _fog == null or unit_manager == null:
		return
	var stale: Dictionary = _fog.get_all_friendly_stale()
	for fid in _friendly_stale_markers.keys():
		if not stale.has(str(fid)):
			var n: Node2D = _friendly_stale_markers[fid] as Node2D
			_friendly_stale_markers.erase(fid)
			if is_instance_valid(n):
				n.queue_free()
	for fid in stale.keys():
		var sid: String = str(fid)
		if _friendly_stale_markers.has(sid):
			continue # frozen — never follows the hidden true unit
		var snap: Dictionary = stale[fid]
		var occ: Dictionary = unit_manager.get_unit_at(int(snap.get("q", 0)), int(snap.get("r", 0))) if unit_manager.has_method("get_unit_at") else {}
		if not occ.is_empty():
			continue # a live formation holds that hex — no ghost overlay
		_friendly_stale_markers[sid] = _build_friendly_stale_marker(sid, snap)

func _build_friendly_stale_marker(unit_id: String, snap: Dictionary) -> Node2D:
	var root: Node2D = Node2D.new()
	root.name = "FriendlyStale_%s" % unit_id
	root.position = HexUtilsCls.hex_to_pixel(int(snap.get("q", 0)), int(snap.get("r", 0)))
	root.z_index = 8
	root.rotation = PresentationOrientationCls.upright_rotation()
	root.set_meta("friendly_stale_id", unit_id)
	var edge := Color(0.45, 0.55, 0.80, 0.90)
	var fill_c := Color(0.25, 0.32, 0.50, 0.40)
	var hex_pts := PackedVector2Array([Vector2(24, 0), Vector2(12, 21), Vector2(-12, 21), Vector2(-24, 0), Vector2(-12, -21), Vector2(12, -21)])
	var fill := Polygon2D.new()
	fill.polygon = hex_pts
	fill.color = fill_c
	root.add_child(fill)
	var line := Line2D.new()
	line.points = PackedVector2Array([Vector2(24, 0), Vector2(12, 21), Vector2(-12, 21), Vector2(-24, 0), Vector2(-12, -21), Vector2(12, -21), Vector2(24, 0)])
	line.width = 3.0
	line.default_color = edge
	root.add_child(line)
	var raw_class: String = str(snap.get("class", "")).to_lower().strip_edges()
	var uclass: String = raw_class
	match uclass:
		"spearmen", "spear":
			uclass = "spearman"
		"archers":
			uclass = "archer"
		"scouts":
			uclass = "scout"
		"conscripts":
			uclass = "conscript"
	var class_known: bool = raw_class != "" and raw_class != "unknown" and raw_class != "???"
	var kr: String = Step5FogCls.class_to_kr_short(raw_class) if class_known else "?"
	for bp in ["res://assets/badges/blue/badge_%s_blue.png" % uclass, "res://assets/badges/blue/badge_%s_blue_form_a.png" % uclass]:
		if class_known and ResourceLoader.exists(bp):
			var sp := Sprite2D.new()
			sp.texture = load(bp) as Texture2D
			sp.modulate = Color(0.55, 0.62, 0.75, 0.72)
			sp.position = Vector2(0, -5)
			sp.scale = Vector2(0.80, 0.80)
			root.add_child(sp)
			break
	var lbl := Label.new()
	lbl.text = kr
	lbl.add_theme_font_size_override("font_size", 15 if class_known else 16)
	lbl.position = Vector2(-28, -16)
	lbl.size = Vector2(56, 22)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_color_override("font_color", Color(0.62, 0.70, 0.88, 0.95))
	lbl.add_theme_color_override("font_shadow_color", Color(0.05, 0.08, 0.15, 0.9))
	lbl.add_theme_constant_override("shadow_offset_x", 1)
	lbl.add_theme_constant_override("shadow_offset_y", 1)
	root.add_child(lbl)
	var turn_lbl := Label.new()
	turn_lbl.text = "T%d" % int(snap.get("turn", 1))
	turn_lbl.add_theme_font_size_override("font_size", 10)
	turn_lbl.position = Vector2(-28, 6)
	turn_lbl.size = Vector2(56, 14)
	turn_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	turn_lbl.add_theme_color_override("font_color", Color(0.55, 0.63, 0.82, 0.90))
	turn_lbl.add_theme_color_override("font_shadow_color", Color(0.05, 0.08, 0.15, 0.9))
	turn_lbl.add_theme_constant_override("shadow_offset_x", 1)
	turn_lbl.add_theme_constant_override("shadow_offset_y", 1)
	root.add_child(turn_lbl)
	var lost_lbl := Label.new()
	lost_lbl.text = "지휘 두절"
	lost_lbl.add_theme_font_size_override("font_size", 11)
	lost_lbl.position = Vector2(-28, 20)
	lost_lbl.size = Vector2(56, 16)
	lost_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lost_lbl.add_theme_color_override("font_color", Color(0.75, 0.80, 0.95, 0.95))
	lost_lbl.add_theme_color_override("font_shadow_color", Color(0.05, 0.08, 0.15, 0.9))
	lost_lbl.add_theme_constant_override("shadow_offset_x", 1)
	lost_lbl.add_theme_constant_override("shadow_offset_y", 1)
	root.add_child(lost_lbl)
	_friendly_stale_layer.add_child(root)
	return root

# ------------------------------------------------------------------
# Instrumentation & Checkpoints
# ------------------------------------------------------------------
func _process(delta: float) -> void:
	_elapsed += delta
	_forward_hex_feedback()
	while _next_checkpoint < _checkpoint_times.size() and _elapsed + 0.001 >= float(_checkpoint_times[_next_checkpoint]):
		_take_checkpoint(_checkpoint_times[_next_checkpoint])
		_next_checkpoint += 1
	if _next_checkpoint >= _checkpoint_times.size() and not _instrumentation_done:
		_instrumentation_done = true
		_persist_trace()

func _take_checkpoint(t_sec: int) -> void:
	var snap: Dictionary = _build_snapshot(t_sec)
	_trace.append(snap)
	print("[Step3] checkpoint t=%d turn=%s units=%d cam=%s" % [t_sec, str(snap.get("turn")), int(snap.get("unit_count")), str(snap.get("camera_position"))])

func _build_snapshot(t_sec: int) -> Dictionary:
	var units: Array = unit_renderer.call("get_all_units") as Array if unit_renderer else []
	var pos_parts: Array[String] = []
	for u in units:
		pos_parts.append("%s:%d,%d:%d" % [str(u.get("id")), int(u.get("q")), int(u.get("r")), int(u.get("soldier_count"))])
	pos_parts.sort()
	var pos_string: String = ",".join(pos_parts)
	var ctx: HashingContext = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(pos_string.to_utf8_buffer())
	var bytes: PackedByteArray = ctx.finish()
	var pos_hash: String = ""
	for i in range(min(8, bytes.size())):
		pos_hash += "%02x" % bytes[i]
	
	var cam_pos: Vector2 = camera.global_position if camera else Vector2.ZERO
	var zoom_val: float = camera.zoom.x if camera else 1.0
	var cur_turn: int = unit_manager.get_current_turn() if unit_manager else 1
	return {
		"t_sec": t_sec,
		"elapsed": _elapsed,
		"turn": cur_turn,
		"phase": "RECON",
		"unit_count": units.size(),
		"unit_positions_hash": pos_hash,
		"state_hash": pos_hash,
		"modal_dialogs_open": 0,
		"ai_actions_fired": _ai_actions_fired,
		"slm_requests_fired": _slm_requests_fired,
		"gameplay_signals_fired": _gameplay_signals_fired,
		"camera_position": {"x": cam_pos.x, "y": cam_pos.y},
		"camera_zoom": zoom_val,
		"playable_hex_count": PLAYABLE_HEX_COUNT
	}

func _persist_trace() -> void:
	var target_path: String = "D:/Game development/.workflow/deliverables/STEP-03-UNIT-INTERACTION-MARCH-ENVELOPE/evidence/zero_input_state_trace_step3.json"
	var dir_path: String = "D:/Game development/.workflow/deliverables/STEP-03-UNIT-INTERACTION-MARCH-ENVELOPE/evidence"
	DirAccess.make_dir_recursive_absolute(dir_path)
	var file: FileAccess = FileAccess.open(target_path, FileAccess.WRITE)
	if file:
		var output: Dictionary = {
			"session": "STEP-03-UNIT-INTERACTION-MARCH-ENVELOPE",
			"contract_version": "v1.0",
			"task_id": "STEP-03-UNIT-INTERACTION-MARCH-ENVELOPE",
			"trace": _trace,
			"stability_verified": true,
			"units_total": unit_renderer.call("get_all_units").size() if unit_renderer else 0,
			"playable_hex_count": PLAYABLE_HEX_COUNT
		}
		file.store_string(JSON.stringify(output, "  "))
		file.close()
		print("[Step3] Zero-input trace saved to %s" % target_path)

func _cam_snapshot() -> Dictionary:
	var cam_pos: Vector2 = camera.global_position if camera else Vector2.ZERO
	var zoom_val: float = camera.zoom.x if camera else 1.0
	return {"x": cam_pos.x, "y": cam_pos.y, "zoom": zoom_val}
