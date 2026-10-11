class_name Cloud1Dock
extends PanelContainer

## CLOUD STEP 1 -- Tactical Research Console (live human frontend).
##
## Visual answers, in order: SITUATION / COMMAND / COMPILATION / RESULT.
## Raw diagnostics live one tab away (RAW), never competing with the builder.
##
## Data path is unchanged from Step 1B: Cloud1Panel stays the offscreen
## drafting backend (draft_command() is still the single drafting path),
## Cloud1Observation/Table/Compiler/Executor stay the authorities. This file
## owns presentation only: resizable dock, tabs, dynamic builder, Korean
## command summary, grouped preview/result rows, map overlay drawing,
## legacy-panel toggle and map-focus mode. Zero tactical semantics here.

signal dock_ready(dock)

## STEP 2: when true, _build() appends a fifth CLOUD tab (Cloud RED general:
## connection, turn controls, turn inspector). Default false, so the Step-1
## sandbox keeps exactly SITUATION/RAW/RESULT/ROSTER SETUP. The Step-2 mount
## sets this before setup().
var show_cloud_tab := false
## FLOATING LAB: when true, the console is a free in-game tool window
## (draggable title bar, 8-handle resize, minimize, hide) instead of the
## fixed right dock. Default false: Step-1 keeps pixel-identical dock
## behavior. The Step-2 (Human-vs-Cloud) mount sets this before setup().
var floating_mode := false
var _cloud_panel: Control = null
var _trace_panel: Control = null
## Auto-focus: when a Cloud RED phase goes active, show the TRACE tab once so
## the human can watch the pipeline live. Manual tab switches still win.
var _trace_auto_shown := false

const PanelCls = preload("res://scripts/cloud1/cloud1_panel.gd")
const TableCls = preload("res://scripts/cloud1/cloud1_action_table.gd")
const CompilerCls = preload("res://scripts/cloud1/cloud1_compiler.gd")
const InspectorCls = preload("res://scripts/cloud1/cloud1_inspector.gd")
const ExecutorCls = preload("res://scripts/cloud1/cloud1_live_executor.gd")
const OverlayCls = preload("res://scripts/cloud1/cloud1_preview_overlay.gd")
const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")
const ScopeAlgebraCls = preload("res://scripts/step7/step7_scope_algebra.gd")
const SandboxRulesCls = preload("res://scripts/core/sandbox_rules.gd")
const Cloud2PanelCls = preload("res://scripts/cloud2/cloud2_panel.gd")
## STEP 2 Issue 1: turn-observability tab (thinking/decision/execution trace).
const Cloud2TracePanelCls = preload("res://scripts/cloud2/cloud2_trace_panel.gd")

const MIN_W := 320.0
const DEFAULT_W := 462.0
const MAX_FRAC := 0.52
const NARROW_W := 400.0

# Floating-window geometry (floating_mode only; docked Step-1 path untouched).
const FLOAT_MIN_W := 380.0
const FLOAT_MIN_H := 320.0
const FLOAT_EDGE := 8.0 # edge resize hit thickness (px, canvas units)
const FLOAT_CORNER := 14.0 # corner resize hit size
const FLOAT_TITLE_KEEP := 120.0 # min title-bar span kept inside the viewport
const FLOAT_GEOM_PATH := "user://cloud_lab_window.cfg"

# Console surfaces (RGBA). Translucent enough that the battlefield reads through
# the console, dark enough that white text keeps its contrast over any terrain.
const SURFACE_BG := Color(0.045, 0.06, 0.085, 0.58)
const SURFACE_TAB := Color(0.05, 0.065, 0.09, 0.42)
const SURFACE_LIST := Color(0.05, 0.065, 0.09, 0.34)
const SURFACE_TEXTEDIT := Color(0.03, 0.04, 0.055, 0.34)
const SURFACE_BORDER := Color(0.35, 0.75, 1.0, 0.72)

const TONE := {
	"ok": Color(0.55, 0.85, 0.58),
	"hold": Color(0.6, 0.7, 0.82),
	"fail": Color(0.92, 0.5, 0.44),
	"warn": Color(0.92, 0.68, 0.3),
	"dim": Color(0.62, 0.66, 0.7),
}
const TARGETS_FOR_ACTION := {
	"ADVANCE": ["DIRECTION"], "RECON": ["DIRECTION"], "PRESSURE": ["DIRECTION"],
	"FLANK": ["DIRECTION", "FORMATION"], "ATTACK": ["FORMATION"],
	"WITHDRAW": ["ZONE", "HEX", "FORMATION", "OBJECTIVE"],
	"REPOSITION": ["ZONE", "HEX", "FORMATION", "OBJECTIVE"],
	"PURSUE": ["FORMATION", "OBJECTIVE", "HEX"],
	"CONCENTRATE": ["ZONE", "HEX", "FORMATION"],
	"HOLD": ["NONE"], "RESERVE": ["NONE"], "SPREAD": ["NONE"],
}

const SCOPE_MODES := ["ALL", "CLASS", "REGION", "CLASS+REGION", "EXACT UNITS", "ADVANCED"]


## Corner resize grip: three quiet diagonal strokes, drawn not textured, so
## no asset or font glyph is required. Input-transparent; the corner handle
## below it takes the mouse.
class _FloatGrip:
	extends Control

	func _init() -> void:
		name = "FloatGrip"
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
		offset_left = -18.0
		offset_top = -18.0
		offset_right = -4.0
		offset_bottom = -4.0

	func _draw() -> void:
		var c := Color(0.55, 0.8, 1.0, 0.55)
		draw_line(Vector2(1, 11), Vector2(11, 1), c, 1.5)
		draw_line(Vector2(5, 12), Vector2(12, 5), c, 1.5)
		draw_line(Vector2(9, 13), Vector2(13, 9), c, 1.5)

var _bridge: RefCounted = null
var _executor: ExecutorCls = null
var _overlay: OverlayCls = null
var _panel: Control = null
var _left_dock: Control = null
var _advisor_dock: Control = null
var _hud: CanvasLayer = null

var _obs: Dictionary = {}
var _enemy_ids: Array = []
var _own_ids: Array = []

var _gutter: Panel = null
var _body: VBoxContainer = null
var _content: VBoxContainer = null
var _status_main: Label = null
var _status_sub: Label = null
var _btn_legacy: Button = null
var _btn_focus: Button = null
var _btn_collapse: Button = null
var _head_row: HBoxContainer = null
var _head_title: Label = null
var _head_warn: Label = null
var _btn_close: Button = null
# Floating-window state (only used when floating_mode is true).
var _float_drag := false
var _float_drag_last := Vector2.ZERO
var _float_resize := ""
var _float_resize_start_mouse := Vector2.ZERO
var _float_resize_start_rect := Rect2()
var _float_handles: Array = []
var _float_grip: Control = null
var _float_saved_rect := Rect2()
var _float_has_saved := false
var _float_wired_viewport := false
var _tabs: TabContainer = null
var _sit_view: RichTextLabel = null
var _raw_view: TextEdit = null
var _res_summary: Label = null
var _res_list: ItemList = null
var _split: VSplitContainer = null
var _builder_grid: GridContainer = null
var _cmd_summary: Label = null
var _scope_badge: Label = null
var _scope_mode_btns: Dictionary = {}
var _current_scope_mode := "ALL"
var _action_opt: OptionButton = null
var _last_draft_key := ""  # last command key pushed by the builder (spurious-signal guard)
var _scope_stack: VBoxContainer = null
var _class_opt: OptionButton = null
var _region_opt: OptionButton = null
var _formation_opt: OptionButton = null
var _units_edit: LineEdit = null
var _unit_picker_box: VBoxContainer = null
var _unit_picker_scroll: ScrollContainer = null
var _unit_picker_list: VBoxContainer = null
var _unit_checkboxes: Dictionary = {}
var _checked_unit_ids: Array = []
var _sel_hint: Label = null
var _scope_none_hint: Label = null
var _target_type_opt: OptionButton = null
var _target_stack: VBoxContainer = null
var _dir_opt: OptionButton = null
var _hex_row: HBoxContainer = null
var _hex_q: LineEdit = null
var _hex_r: LineEdit = null
var _tunit_opt: OptionButton = null
var _zone_opt: OptionButton = null
var _target_none_hint: Label = null
var _policy_opt: OptionButton = null
var _policy_cell: Control = null
var _stance_opt: OptionButton = null
var _prev_summary: Label = null
var _btn_refresh: Button = null
var _btn_preview: Button = null
var _btn_execute: Button = null
var _btn_cancel: Button = null
var _btn_reset: Button = null
var _status_label: Label = null
var _restore_btn: Button = null

# Dev Setup variables
var _blue_spins: Dictionary = {}
var _red_spins: Dictionary = {}
var _blue_total_lbl: Label = null
var _red_total_lbl: Label = null

var _collapsed := false
var _map_focus := false
var _legacy_hidden := false
var _preview: Dictionary = {}
var _preview_valid := false
var _preview_key := ""
var _preview_fp := ""
var _last_sel := "@@init@@"
var _last_turn := -1
var _resizing := false
var _drag_x := 0.0
var _narrow := false


func setup(bridge: RefCounted, executor: ExecutorCls, overlay: OverlayCls) -> void:
	_bridge = bridge
	_executor = executor
	_overlay = overlay
	_build()
	_panel = PanelCls.new()
	_panel.bind_sim(_bridge)
	_executor.unit_finished.connect(_on_unit_finished)
	_executor.execution_finished.connect(_on_execution_finished)
	_hud = get_parent() as CanvasLayer
	if _hud != null:
		_left_dock = _hud.get_node_or_null("LeftDock") as Control
		# The Step7 player advisor dock sits directly under this console; on a
		# translucent console it would read as an opaque slab, so the sandbox
		# presentation governs it together with the legacy left panel.
		_advisor_dock = _hud.get_node_or_null("RightDock") as Control
		_restore_btn = Button.new()
		_restore_btn.text = "LAB"
		_restore_btn.tooltip_text = "Restore the research console"
		if floating_mode:
			# Top-left, under the debug panel: the old top-right slot sits
			# underneath the Cloud turn bar (layer 40) in Human-vs-Cloud.
			_restore_btn.set_anchors_preset(Control.PRESET_TOP_LEFT)
			_restore_btn.offset_left = 24
			_restore_btn.offset_right = 128
			_restore_btn.offset_top = 56
			_restore_btn.offset_bottom = 92
		else:
			_restore_btn.set_anchors_preset(Control.PRESET_TOP_RIGHT)
			_restore_btn.offset_left = -104
			_restore_btn.offset_right = -8
			_restore_btn.offset_top = 56
			_restore_btn.offset_bottom = 92
		_restore_btn.visible = false
		_restore_btn.pressed.connect(func() -> void: set_map_focus(false))
		_hud.add_child(_restore_btn)
		# DEV research-sandbox presentation: the legacy left "작전 명령" command
		# panel starts HIDDEN — this mode's presentation is the Cloud General
		# console plus an open battlefield. The LEGACY button (and
		# set_legacy_visible) still restores it on demand, and this only runs
		# while the sandbox rules are active, so production UI is untouched.
		if SandboxRulesCls.is_active():
			_legacy_hidden = true
		_apply_legacy()
	refresh_observation()
	_reset_builder_defaults()
	_update_legacy_btn()
	dock_ready.emit(self)


func is_live() -> bool:
	return _bridge != null and _bridge.is_loaded()


func get_panel() -> Control:
	return _panel


func get_preview() -> Dictionary:
	return _preview


func is_preview_valid() -> bool:
	return _preview_valid


func get_draft_key() -> String:
	if _panel == null:
		return ""
	return JSON.stringify(_panel.draft_command())


func get_result_unit_ids() -> Array:
	var out: Array = []
	for i in range(_res_list.item_count):
		out.append(str(_res_list.get_item_metadata(i)))
	return out


func get_cloud_panel() -> Control:
	return _cloud_panel


func get_trace_panel() -> Control:
	return _trace_panel


## One-shot TRACE tab focus when a Cloud RED phase goes active. Never steals
## focus from a human tab click: only fires when the phase starts.
func show_trace_for_phase(active: bool) -> void:
	if not floating_mode or _trace_panel == null or _tabs == null:
		return
	if active:
		if not _trace_auto_shown and _tabs.get_tab_count() > 5:
			_trace_auto_shown = true
			_tabs.set_current_tab(5)
	else:
		_trace_auto_shown = false


func get_tab() -> String:
	match _tabs.get_current_tab():
		0:
			return "SITUATION"
		1:
			return "RAW"
		2:
			return "RESULT"
		3:
			return "ROSTER"
		4:
			return "CLOUD" if _cloud_panel != null else "RESULT"
		5:
			return "TRACE" if _trace_panel != null else "RESULT"
	return "RESULT"


func set_tab(want: String) -> void:
	match want.strip_edges().to_upper():
		"SITUATION":
			_tabs.set_current_tab(0)
		"RAW":
			_tabs.set_current_tab(1)
		"RESULT":
			_tabs.set_current_tab(2)
		"ROSTER", "DEV SETUP", "DEV_SETUP":
			_tabs.set_current_tab(3)
		"CLOUD":
			if _cloud_panel != null and _tabs.get_tab_count() > 4:
				_tabs.set_current_tab(4)
		"TRACE":
			if _trace_panel != null and _tabs.get_tab_count() > 5:
				_tabs.set_current_tab(5)


func get_dock_width() -> float:
	return float(offset_right - offset_left)


func set_dock_width(w: float) -> void:
	if floating_mode:
		# Floating window: width-only change, left edge stays, user position kept.
		var vw := _float_visible_rect().size.x
		var maxw := maxf(vw - 32.0, FLOAT_MIN_W)
		size = Vector2(clampf(w, FLOAT_MIN_W, maxw), size.y)
		position = _float_clamp_pos(position, size)
		return
	var vw := 1280.0
	if is_inside_tree() and get_viewport() != null:
		vw = get_viewport_rect().size.x
	var maxw := maxf(vw * MAX_FRAC, 420.0)
	offset_left = offset_right - clampf(w, MIN_W, maxw)


func is_legacy_visible() -> bool:
	return not _legacy_hidden


func set_legacy_visible(v: bool) -> void:
	_legacy_hidden = not v
	_apply_legacy()
	_update_legacy_btn()


func is_map_focus() -> bool:
	return _map_focus


func set_map_focus(on: bool) -> void:
	_map_focus = on
	visible = not on
	if _restore_btn != null:
		_restore_btn.visible = on
	_apply_legacy()
	_float_save_geometry() # no-op unless floating_mode; hide keeps geometry
	_status("Map focus ON -- press LAB to restore." if on else "Console restored.")


func focus_result_unit(uid: String) -> bool:
	if _bridge == null:
		return false
	var mgr: RefCounted = _bridge.get_manager()
	if mgr == null:
		return false
	var u: Dictionary = mgr.get_unit_by_id(uid)
	if u.is_empty():
		return false
	var cell := [int(u.get("q", 0)), int(u.get("r", 0))]
	_overlay.set_focus(cell)
	_status("Focused %s @ (%d,%d) -- double-click row to center camera." % [uid, cell[0], cell[1]])
	return true


func refresh_observation() -> void:
	if _panel == null or _bridge == null or not _bridge.is_loaded():
		return
	var obs: Dictionary = _panel.current_observation()
	if obs.is_empty() or not bool(obs.get("ok", false)):
		_status_main.text = "No observation."
		return
	_obs = obs
	_sit_view.text = InspectorCls.render_situation_bbcode(obs)
	_raw_view.text = InspectorCls.render_payload(obs)
	_update_header(obs)
	_refresh_builder_options(obs)
	var fp := str((obs.get("parity", {}) as Dictionary).get("fingerprint", ""))
	if _preview_valid and fp != _preview_fp:
		_invalidate_preview("state_changed")
	_preview_fp = fp


# --- live command path (same authorities as Step 1B) ---

func preview_command() -> Dictionary:
	if _executor != null and _executor.is_busy():
		_status("Execution in progress -- Cancel first.")
		return {}
	if not is_live():
		_status("Live battle not ready.")
		return {}
	var cmd: Dictionary = _panel.draft_command()
	var plan: Dictionary = CompilerCls.plan(_bridge, cmd, _panel.get_selected_id())
	_preview = plan
	_preview_key = JSON.stringify(cmd)
	_last_draft_key = _preview_key
	var mgr: RefCounted = _bridge.get_manager()
	_preview_fp = str((_panel.current_observation().get("parity", {}) as Dictionary).get("fingerprint", "")) if mgr != null else ""
	_preview_valid = bool(plan.get("ok", false))
	_show_plan_result(plan)
	_draw_plan_overlay(plan)
	_btn_execute.disabled = not _preview_valid
	if _preview_valid:
		_status("Preview OK -- review RESULT, then Execute.")
	else:
		_status("Preview: NO PLAN -- %s" % str(plan.get("detail", "")))
	return plan


func execute_command() -> Dictionary:
	if _executor != null and _executor.is_busy():
		_status("Execution already in progress.")
		return {"accepted": false}
	if not is_live():
		_status("Live battle not ready.")
		return {"accepted": false}
	if not _preview_valid or JSON.stringify(_panel.draft_command()) != _preview_key:
		_invalidate_preview("Command changed -- Preview again.")
		_status("Stale preview -- press Preview first.")
		return {"accepted": false}
	var res: Dictionary = _executor.execute(_panel.draft_command(), _panel.get_selected_id())
	if not bool(res.get("accepted", false)):
		_status("Execute refused: %s" % str(res.get("detail", "")))
		return res
	_status("Executing %d unit(s)..." % int(res.get("planned_count", 0)))
	return res


func cancel_command() -> void:
	if _executor != null and _executor.is_busy():
		_executor.cancel()
		_status("Cancelling after the current unit...")
	else:
		_overlay.clear_preview()
		_invalidate_preview("")
		_res_summary.text = "Preview cleared."
		_res_list.clear()
		_status("Preview cleared.")


func reset_console() -> void:
	_overlay.clear_preview()
	_reset_builder_defaults()
	_invalidate_preview("")
	_res_summary.text = "No preview yet -- draft a command and press PREVIEW."
	_res_list.clear()
	_preview_fp = str((_obs.get("parity", {}) as Dictionary).get("fingerprint", "")) if not _obs.is_empty() else ""
	set_tab("SITUATION")
	_status("Console reset (simulation untouched).")


# --- construction ---

func _build() -> void:
	name = "Cloud1Dock"
	if floating_mode:
		# Free window: TOP_LEFT anchors, explicit rect. No anchor owns the
		# position afterwards — the user does. Initial rect is applied at
		# the end of _build() once the viewport is known.
		set_anchors_preset(Control.PRESET_TOP_LEFT)
		grow_horizontal = Control.GROW_DIRECTION_END
		grow_vertical = Control.GROW_DIRECTION_END
	else:
		set_anchors_preset(Control.PRESET_TOP_RIGHT)
		anchor_bottom = 1.0
		grow_horizontal = Control.GROW_DIRECTION_BEGIN
		offset_left = -8.0 - DEFAULT_W
		offset_right = -8
		offset_top = 56
		offset_bottom = -8
	var style := StyleBoxFlat.new()
	style.bg_color = SURFACE_BG
	style.border_color = SURFACE_BORDER
	style.set_border_width_all(1)
	add_theme_stylebox_override("panel", style)
	var root := HBoxContainer.new()
	root.add_theme_constant_override("separation", 0)
	add_child(root)
	_gutter = Panel.new()
	_gutter.name = "ResizeGutter"
	_gutter.custom_minimum_size = Vector2(10, 0)
	_gutter.mouse_filter = Control.MOUSE_FILTER_STOP
	_gutter.mouse_default_cursor_shape = Control.CURSOR_HSPLIT
	_gutter.tooltip_text = "Drag to resize the console"
	var gstyle := StyleBoxFlat.new()
	gstyle.bg_color = Color(0.1, 0.16, 0.22, 1.0)
	_gutter.add_theme_stylebox_override("panel", gstyle)
	_gutter.gui_input.connect(_on_gutter_input)
	root.add_child(_gutter)
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 6)
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(_body)
	_build_header()
	_content = VBoxContainer.new()
	_content.add_theme_constant_override("separation", 6)
	_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_child(_content)
	_split = VSplitContainer.new()
	_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.add_child(_split)
	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var tab_style := StyleBoxFlat.new()
	tab_style.bg_color = SURFACE_TAB
	_tabs.add_theme_stylebox_override("panel", tab_style)
	_split.add_child(_tabs)
	_sit_view = RichTextLabel.new()
	_sit_view.name = "SituationView"
	_sit_view.bbcode_enabled = true
	_sit_view.scroll_active = true
	_sit_view.selection_enabled = true
	_sit_view.add_theme_font_size_override("normal_font_size", 13)
	_sit_view.add_theme_font_size_override("bold_font_size", 13)
	_sit_view.add_theme_font_size_override("mono_font_size", 12)
	_tabs.add_child(_sit_view)
	_tabs.set_tab_title(0, "SITUATION")
	_raw_view = TextEdit.new()
	_raw_view.name = "RawView"
	_raw_view.editable = false
	_raw_view.add_theme_font_size_override("font_size", 12)
	var raw_style := StyleBoxFlat.new()
	raw_style.bg_color = SURFACE_TEXTEDIT
	_raw_view.add_theme_stylebox_override("normal", raw_style)
	var mono := SystemFont.new()
	mono.font_names = PackedStringArray(["Consolas", "Menlo", "monospace"])
	_raw_view.add_theme_font_override("font", mono)
	_tabs.add_child(_raw_view)
	_tabs.set_tab_title(1, "RAW")
	var res_box := VBoxContainer.new()
	res_box.name = "ResultBox"
	res_box.add_theme_constant_override("separation", 4)
	_tabs.add_child(res_box)
	_tabs.set_tab_title(2, "RESULT")
	_res_summary = Label.new()
	_res_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_res_summary.add_theme_font_size_override("font_size", 12)
	_res_summary.text = "No preview yet -- draft a command and press PREVIEW."
	res_box.add_child(_res_summary)
	_res_list = ItemList.new()
	_res_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var list_style := StyleBoxFlat.new()
	list_style.bg_color = SURFACE_LIST
	_res_list.add_theme_stylebox_override("panel", list_style)
	_res_list.item_selected.connect(_on_result_row_selected)
	_res_list.item_activated.connect(_on_result_row_activated)
	res_box.add_child(_res_list)
	_build_dev_setup_tab()
	if show_cloud_tab:
		_build_cloud_tab()
	_build_command_box()
	_build_action_bar()
	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.add_theme_font_size_override("font_size", 11)
	_status_label.add_theme_color_override("font_color", Color(0.62, 0.66, 0.7))
	_status_label.text = "Ready."
	_content.add_child(_status_label)
	if floating_mode:
		_float_setup_window()


func _build_dev_setup_tab() -> void:
	var dev_box := VBoxContainer.new()
	dev_box.name = "DevSetupBox"
	dev_box.add_theme_constant_override("separation", 6)
	_tabs.add_child(dev_box)
	_tabs.set_tab_title(3, "ROSTER SETUP")

	var title := Label.new()
	title.text = "Step 0 Flat Battlefield — Army Roster Rebuild"
	title.add_theme_font_size_override("font_size", 13)
	title.add_theme_color_override("font_color", Color(0.5, 0.83, 1.0))
	dev_box.add_child(title)

	var desc := Label.new()
	desc.text = "Reconfigures the neutral 10v10 battlefield without altering R=40 dimensions or flat terrain."
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.add_theme_font_size_override("font_size", 11)
	desc.add_theme_color_override("font_color", Color(0.62, 0.66, 0.7))
	dev_box.add_child(desc)

	var preset_row := HBoxContainer.new()
	preset_row.add_theme_constant_override("separation", 4)
	dev_box.add_child(preset_row)

	var presets := [
		{"name": "10v10 Standard", "blue": SandboxRulesCls.default_roster(), "red": SandboxRulesCls.default_roster()},
		{"name": "Infantry Clash", "blue": {"infantry": 6, "spearman": 2, "archer": 1, "cavalry": 0, "scout": 0, "hq": 1}, "red": {"infantry": 6, "spearman": 2, "archer": 1, "cavalry": 0, "scout": 0, "hq": 1}},
		{"name": "Cavalry Wings", "blue": {"infantry": 2, "spearman": 2, "archer": 2, "cavalry": 3, "scout": 0, "hq": 1}, "red": {"infantry": 2, "spearman": 2, "archer": 2, "cavalry": 3, "scout": 0, "hq": 1}},
		{"name": "Archer Duel", "blue": {"infantry": 2, "spearman": 2, "archer": 5, "cavalry": 0, "scout": 0, "hq": 1}, "red": {"infantry": 2, "spearman": 2, "archer": 5, "cavalry": 0, "scout": 0, "hq": 1}},
		{"name": "Asymmetric", "blue": {"infantry": 4, "spearman": 0, "archer": 0, "cavalry": 5, "scout": 0, "hq": 1}, "red": {"infantry": 0, "spearman": 6, "archer": 3, "cavalry": 0, "scout": 0, "hq": 1}},
	]
	for p in presets:
		var pbtn := Button.new()
		pbtn.text = str(p["name"])
		pbtn.add_theme_font_size_override("font_size", 10)
		var b_cfg: Dictionary = p["blue"]
		var r_cfg: Dictionary = p["red"]
		pbtn.pressed.connect(func() -> void: _apply_roster_preset(b_cfg, r_cfg))
		preset_row.add_child(pbtn)

	var roster_grid := GridContainer.new()
	roster_grid.columns = 2
	roster_grid.add_theme_constant_override("h_separation", 16)
	roster_grid.add_theme_constant_override("v_separation", 4)
	dev_box.add_child(roster_grid)

	var blue_col := VBoxContainer.new()
	blue_col.add_theme_constant_override("separation", 2)
	roster_grid.add_child(blue_col)
	var blue_hdr := Label.new()
	blue_hdr.text = "-- BLUE ROSTER --"
	blue_hdr.add_theme_color_override("font_color", Color(0.4, 0.7, 1.0))
	blue_hdr.add_theme_font_size_override("font_size", 11)
	blue_col.add_child(blue_hdr)

	var red_col := VBoxContainer.new()
	red_col.add_theme_constant_override("separation", 2)
	roster_grid.add_child(red_col)
	var red_hdr := Label.new()
	red_hdr.text = "-- RED ROSTER --"
	red_hdr.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
	red_hdr.add_theme_font_size_override("font_size", 11)
	red_col.add_child(red_hdr)

	var classes := ["infantry", "spearman", "archer", "cavalry", "scout", "hq", "siege", "conscript"]
	var default_blue: Dictionary = SandboxRulesCls.default_roster()
	var default_red: Dictionary = SandboxRulesCls.default_roster()

	for c in classes:
		var brow := HBoxContainer.new()
		blue_col.add_child(brow)
		var blbl := Label.new()
		blbl.text = c.capitalize() + ":"
		blbl.custom_minimum_size = Vector2(70, 0)
		blbl.add_theme_font_size_override("font_size", 11)
		brow.add_child(blbl)
		var bspin := SpinBox.new()
		bspin.min_value = 0
		bspin.max_value = 20
		bspin.value = default_blue.get(c, 0)
		bspin.value_changed.connect(func(_val: float) -> void: _update_roster_totals())
		brow.add_child(bspin)
		_blue_spins[c] = bspin

		var rrow := HBoxContainer.new()
		red_col.add_child(rrow)
		var rlbl := Label.new()
		rlbl.text = c.capitalize() + ":"
		rlbl.custom_minimum_size = Vector2(70, 0)
		rlbl.add_theme_font_size_override("font_size", 11)
		rrow.add_child(rlbl)
		var rspin := SpinBox.new()
		rspin.min_value = 0
		rspin.max_value = 20
		rspin.value = default_red.get(c, 0)
		rspin.value_changed.connect(func(_val: float) -> void: _update_roster_totals())
		rrow.add_child(rspin)
		_red_spins[c] = rspin

	_blue_total_lbl = Label.new()
	_blue_total_lbl.add_theme_font_size_override("font_size", 11)
	blue_col.add_child(_blue_total_lbl)

	_red_total_lbl = Label.new()
	_red_total_lbl.add_theme_font_size_override("font_size", 11)
	red_col.add_child(_red_total_lbl)
	_update_roster_totals()

	var btn_apply := Button.new()
	btn_apply.text = "Apply & Reset Battlefield Roster"
	btn_apply.custom_minimum_size = Vector2(0, 32)
	btn_apply.add_theme_font_size_override("font_size", 12)
	btn_apply.pressed.connect(_on_apply_roster_rebuild)
	dev_box.add_child(btn_apply)


## STEP 2 CLOUD tab: instantiation only — Cloud2Panel owns its content and
## talks to the Cloud2TurnController the Step-2 mount binds afterwards.
## The TRACE tab (Issue 1 observability) rides along in the same Lab.
func _build_cloud_tab() -> void:
	_cloud_panel = Cloud2PanelCls.new()
	_cloud_panel.name = "Cloud2Panel"
	_cloud_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.add_child(_cloud_panel)
	_tabs.set_tab_title(_tabs.get_tab_count() - 1, "CLOUD")
	_trace_panel = Cloud2TracePanelCls.new()
	_trace_panel.name = "Cloud2TracePanel"
	_trace_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.add_child(_trace_panel)
	_tabs.set_tab_title(_tabs.get_tab_count() - 1, "TRACE")


func _apply_roster_preset(b_cfg: Dictionary, r_cfg: Dictionary) -> void:
	for c in b_cfg.keys():
		if _blue_spins.has(c):
			(_blue_spins[c] as SpinBox).value = b_cfg[c]
	for c2 in r_cfg.keys():
		if _red_spins.has(c2):
			(_red_spins[c2] as SpinBox).value = r_cfg[c2]
	_update_roster_totals()


func _update_roster_totals() -> void:
	var bt := 0
	for sp in _blue_spins.values():
		bt += int((sp as SpinBox).value)
	var rt := 0
	for sp2 in _red_spins.values():
		rt += int((sp2 as SpinBox).value)
	if _blue_total_lbl != null:
		_blue_total_lbl.text = "Blue Total: %d units" % bt
	if _red_total_lbl != null:
		_red_total_lbl.text = "Red Total: %d units" % rt


func _on_apply_roster_rebuild() -> void:
	if _bridge == null:
		_status("Bridge not ready.")
		return
	var shell: Node = _bridge.get_shell()
	if shell == null or not shell.has_method("rebuild_step0_roster"):
		_status("Shell does not support rebuild_step0_roster.")
		return
	var b_counts := {}
	for c in _blue_spins.keys():
		b_counts[c] = int((_blue_spins[c] as SpinBox).value)
	var r_counts := {}
	for c in _red_spins.keys():
		r_counts[c] = int((_red_spins[c] as SpinBox).value)
	shell.call("rebuild_step0_roster", b_counts, r_counts)
	_overlay.clear_preview()
	_invalidate_preview("")
	refresh_observation()
	set_tab("SITUATION")
	_status("Roster rebuilt successfully!")


func _section(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", Color(0.5, 0.83, 1.0))
	return l


func _mini_btn(parent: Control, text: String, tip: String) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.add_theme_font_size_override("font_size", 11)
	parent.add_child(b)
	return b


func _build_header() -> void:
	var head := VBoxContainer.new()
	head.add_theme_constant_override("separation", 2)
	_body.add_child(head)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	head.add_child(row)
	_head_row = row
	var title := Label.new()
	title.text = "CLOUD GENERAL LAB"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", 15)
	title.add_theme_color_override("font_color", Color(0.88, 0.95, 1.0))
	row.add_child(title)
	_head_title = title
	_btn_legacy = _mini_btn(row, "LEGACY", "Show/hide the step7 player docks (left command panel + advisor) — DEV sandbox only")
	_btn_legacy.pressed.connect(_on_legacy_toggle)
	_btn_focus = _mini_btn(row, "MAP", "Map focus: hide panels for maximum battlefield view")
	_btn_focus.pressed.connect(func() -> void: set_map_focus(true))
	_btn_collapse = _mini_btn(row, "-", "Collapse / expand the console (width preserved)")
	_btn_collapse.pressed.connect(_on_collapse_toggle)
	if floating_mode:
		# The header row + title are the drag handle; buttons on it still
		# consume their own clicks (Button accepts the press first).
		row.mouse_filter = Control.MOUSE_FILTER_STOP
		row.tooltip_text = "Drag to move the Lab window"
		title.mouse_filter = Control.MOUSE_FILTER_STOP
		title.tooltip_text = "Drag to move the Lab window"
		row.gui_input.connect(_on_float_title_input)
		title.gui_input.connect(_on_float_title_input)
		_btn_collapse.tooltip_text = "Minimize / restore the window (geometry preserved)"
		_btn_close = _mini_btn(row, "X", "Hide the Lab (UI only — Cloud backend keeps running; LAB reopens)")
		_btn_close.pressed.connect(func() -> void: set_map_focus(true))
	_status_main = Label.new()
	_status_main.add_theme_font_size_override("font_size", 12)
	head.add_child(_status_main)
	_status_sub = Label.new()
	_status_sub.add_theme_font_size_override("font_size", 11)
	_status_sub.add_theme_color_override("font_color", Color(0.62, 0.66, 0.7))
	_status_sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	head.add_child(_status_sub)
	var warn := Label.new()
	warn.text = "STANCE schema-only | SPREAD deferred"
	warn.tooltip_text = "STANCE is recorded for intent; movement legality is stance-independent in Step 1. SPREAD has no neutral-board mechanic: Preview explains, Execute refuses."
	warn.add_theme_font_size_override("font_size", 10)
	warn.add_theme_color_override("font_color", Color(0.92, 0.68, 0.3))
	head.add_child(warn)
	_head_warn = warn


func _build_command_box() -> void:
	var box := VBoxContainer.new()
	box.name = "CommandBox"
	box.add_theme_constant_override("separation", 4)
	if floating_mode:
		# The floating window can shrink vertically: the builder scrolls
		# instead of clipping, so every control stays reachable.
		var scroll := ScrollContainer.new()
		scroll.name = "CommandScroll"
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.add_child(box)
		_split.add_child(scroll)
	else:
		_split.add_child(box)
	box.add_child(_section("COMMAND"))
	_cmd_summary = Label.new()
	_cmd_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_cmd_summary.add_theme_font_size_override("font_size", 13)
	box.add_child(_cmd_summary)

	var scope_mode_hdr := HBoxContainer.new()
	scope_mode_hdr.add_theme_constant_override("separation", 6)
	box.add_child(scope_mode_hdr)
	var sm_lbl := Label.new()
	sm_lbl.text = "SCOPE MODE:"
	sm_lbl.add_theme_font_size_override("font_size", 11)
	sm_lbl.add_theme_color_override("font_color", Color(0.62, 0.66, 0.7))
	scope_mode_hdr.add_child(sm_lbl)

	_scope_badge = Label.new()
	_scope_badge.text = "선택: 0개 부대"
	_scope_badge.add_theme_font_size_override("font_size", 11)
	_scope_badge.add_theme_color_override("font_color", Color(0.4, 0.85, 1.0))
	_scope_badge.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scope_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	scope_mode_hdr.add_child(_scope_badge)

	var mode_bar := HBoxContainer.new()
	mode_bar.add_theme_constant_override("separation", 2)
	box.add_child(mode_bar)
	for m in SCOPE_MODES:
		var b := Button.new()
		b.text = m
		b.add_theme_font_size_override("font_size", 10)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var cap_m: String = str(m)
		b.pressed.connect(func() -> void: _set_scope_mode(cap_m))
		mode_bar.add_child(b)
		_scope_mode_btns[m] = b

	_builder_grid = GridContainer.new()
	_builder_grid.columns = 2
	_builder_grid.add_theme_constant_override("h_separation", 8)
	_builder_grid.add_theme_constant_override("v_separation", 4)
	_builder_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(_builder_grid)

	var action_items: Array = TableCls.ACTIVE_ACTIONS.duplicate()
	for def_act in TableCls.DEFERRED_ACTIONS:
		action_items.append("[DEFERRED] " + def_act)
	_action_opt = _labeled_opt("ACTION", action_items)

	var scope_cell := VBoxContainer.new()
	scope_cell.add_theme_constant_override("separation", 1)
	_builder_grid.add_child(scope_cell)
	var slbl := Label.new()
	slbl.text = "SCOPE TARGET"
	slbl.add_theme_font_size_override("font_size", 11)
	slbl.add_theme_color_override("font_color", Color(0.62, 0.66, 0.7))
	scope_cell.add_child(slbl)

	_scope_stack = VBoxContainer.new()
	_scope_stack.add_theme_constant_override("separation", 2)
	scope_cell.add_child(_scope_stack)

	_scope_none_hint = Label.new()
	_scope_none_hint.add_theme_font_size_override("font_size", 11)
	_scope_none_hint.add_theme_color_override("font_color", Color(0.62, 0.66, 0.7))
	_scope_stack.add_child(_scope_none_hint)

	_class_opt = _plain_opt(TableCls.KNOWN_CLASSES)
	_scope_stack.add_child(_class_opt)

	_region_opt = _plain_opt(ScopeAlgebraCls.REGIONS)
	_scope_stack.add_child(_region_opt)

	_unit_picker_box = VBoxContainer.new()
	_unit_picker_box.add_theme_constant_override("separation", 2)
	_scope_stack.add_child(_unit_picker_box)

	var picker_btns := HBoxContainer.new()
	picker_btns.add_theme_constant_override("separation", 4)
	_unit_picker_box.add_child(picker_btns)
	var btn_all := Button.new()
	btn_all.text = "Select All"
	btn_all.add_theme_font_size_override("font_size", 10)
	btn_all.pressed.connect(_select_all_units)
	picker_btns.add_child(btn_all)
	var btn_clr := Button.new()
	btn_clr.text = "Clear"
	btn_clr.add_theme_font_size_override("font_size", 10)
	btn_clr.pressed.connect(_clear_all_units)
	picker_btns.add_child(btn_clr)

	_unit_picker_scroll = ScrollContainer.new()
	_unit_picker_scroll.custom_minimum_size = Vector2(0, 110)
	_unit_picker_box.add_child(_unit_picker_scroll)
	_unit_picker_list = VBoxContainer.new()
	_unit_picker_list.add_theme_constant_override("separation", 1)
	_unit_picker_scroll.add_child(_unit_picker_list)

	_units_edit = LineEdit.new()
	_units_edit.placeholder_text = "e.g. INTERSECT(CLASS:CAVALRY, REGION:NORTH)"
	_scope_stack.add_child(_units_edit)

	_formation_opt = _plain_opt(["FIELD"])
	_formation_opt.visible = false
	_scope_stack.add_child(_formation_opt)

	_sel_hint = Label.new()
	_sel_hint.visible = false
	_scope_stack.add_child(_sel_hint)

	_target_type_opt = _labeled_opt("TARGET", ["DIRECTION"])
	_target_stack = VBoxContainer.new()
	_target_stack.add_theme_constant_override("separation", 2)
	_builder_grid.add_child(_target_stack)
	_dir_opt = _plain_opt(TableCls.DIRECTIONS)
	_target_stack.add_child(_dir_opt)
	_hex_row = HBoxContainer.new()
	_hex_row.add_theme_constant_override("separation", 4)
	_target_stack.add_child(_hex_row)
	_hex_q = _small_edit(_hex_row, "q")
	_hex_r = _small_edit(_hex_row, "r")
	_tunit_opt = _plain_opt(["R_INF_1"])
	_target_stack.add_child(_tunit_opt)
	_zone_opt = _plain_opt(TableCls.ZONES)
	_target_stack.add_child(_zone_opt)
	_target_none_hint = Label.new()
	_target_none_hint.add_theme_font_size_override("font_size", 11)
	_target_none_hint.add_theme_color_override("font_color", Color(0.62, 0.66, 0.7))
	_target_none_hint.text = "no target for this action"
	_target_stack.add_child(_target_none_hint)

	_policy_opt = _labeled_opt("POLICY", TableCls.POLICIES)
	_policy_cell = _policy_opt.get_parent()
	_policy_cell.visible = false

	_labeled_stance()

	_prev_summary = Label.new()
	_prev_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_prev_summary.add_theme_font_size_override("font_size", 12)
	_prev_summary.text = "No valid preview -- press PREVIEW."
	box.add_child(_prev_summary)

	_action_opt.item_selected.connect(func(_i: int) -> void: _on_action_changed())
	_class_opt.item_selected.connect(func(_i: int) -> void: _update_scope_badge(); _on_builder_changed())
	_region_opt.item_selected.connect(func(_i: int) -> void: _update_scope_badge(); _on_builder_changed())
	_units_edit.text_changed.connect(func(_t: String) -> void: _on_builder_changed())
	_target_type_opt.item_selected.connect(func(_i: int) -> void: _on_builder_changed())
	_dir_opt.item_selected.connect(func(_i: int) -> void: _on_builder_changed())
	_hex_q.text_changed.connect(func(_t: String) -> void: _on_builder_changed())
	_hex_r.text_changed.connect(func(_t: String) -> void: _on_builder_changed())
	_tunit_opt.item_selected.connect(func(_i: int) -> void: _on_builder_changed())
	_zone_opt.item_selected.connect(func(_i: int) -> void: _on_builder_changed())
	_stance_opt.item_selected.connect(func(_i: int) -> void: _on_builder_changed())

	_set_scope_mode("ALL")


func _labeled_opt(label_text: String, items: Array) -> OptionButton:
	var cell := VBoxContainer.new()
	cell.add_theme_constant_override("separation", 1)
	_builder_grid.add_child(cell)
	var l := Label.new()
	l.text = label_text
	l.add_theme_font_size_override("font_size", 11)
	l.add_theme_color_override("font_color", Color(0.62, 0.66, 0.7))
	cell.add_child(l)
	return _plain_opt_into(cell, items)


func _labeled_stance() -> void:
	var cell := VBoxContainer.new()
	cell.add_theme_constant_override("separation", 1)
	_builder_grid.add_child(cell)
	var l := Label.new()
	l.text = "STANCE"
	l.add_theme_font_size_override("font_size", 11)
	l.add_theme_color_override("font_color", Color(0.62, 0.66, 0.7))
	cell.add_child(l)
	_stance_opt = _plain_opt_into(cell, TableCls.STANCES)
	var note := Label.new()
	note.text = "(i) behavior not active in Step 1"
	note.add_theme_font_size_override("font_size", 10)
	note.add_theme_color_override("font_color", Color(0.92, 0.68, 0.3))
	cell.add_child(note)


func _plain_opt(items: Array) -> OptionButton:
	var o := OptionButton.new()
	for it in items:
		o.add_item(str(it))
	return o


func _plain_opt_into(parent: Control, items: Array) -> OptionButton:
	var o := _plain_opt(items)
	parent.add_child(o)
	return o


func _small_edit(parent: Control, hint: String) -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = hint
	e.custom_minimum_size = Vector2(64, 0)
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(e)
	return e


func _build_action_bar() -> void:
	var bar := HBoxContainer.new()
	bar.name = "ActionBar"
	bar.add_theme_constant_override("separation", 6)
	_content.add_child(bar)
	_btn_refresh = _bar_btn(bar, "Refresh")
	_btn_refresh.tooltip_text = "Re-read the live observation"
	_btn_refresh.pressed.connect(_on_refresh)
	_btn_preview = _bar_btn(bar, "PREVIEW")
	_btn_preview.tooltip_text = "Compile the drafted command (safe, no state change)"
	_btn_preview.pressed.connect(func() -> void: preview_command())
	_btn_execute = _bar_btn(bar, "EXECUTE")
	_btn_execute.tooltip_text = "Execute the previewed plan through the authoritative path"
	_btn_execute.disabled = true
	_btn_execute.pressed.connect(func() -> void: execute_command())
	_btn_cancel = _bar_btn(bar, "Cancel")
	_btn_cancel.tooltip_text = "Cancel execution, or clear the preview"
	_btn_cancel.pressed.connect(cancel_command)
	_btn_reset = _bar_btn(bar, "Reset")
	_btn_reset.tooltip_text = "Clear preview and reset the builder (simulation untouched)"
	_btn_reset.pressed.connect(reset_console)


func _bar_btn(parent: Control, text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_font_size_override("font_size", 13)
	parent.add_child(b)
	return b


# --- builder logic ---

func _opt_text(opt: OptionButton) -> String:
	if opt == null or opt.item_count == 0:
		return ""
	return opt.get_item_text(opt.selected)


func _pick(opt: OptionButton, want: String) -> void:
	for i in range(opt.item_count):
		if opt.get_item_text(i) == want:
			opt.select(i)
			return
	if opt.item_count > 0:
		opt.select(0)


func _rebuild_opt(opt: OptionButton, items: Array, keep: String) -> void:
	opt.clear()
	for it in items:
		opt.add_item(str(it))
	_pick(opt, keep)


func set_action(a: String) -> void:
	var raw := a.strip_edges().to_upper()
	for i in range(_action_opt.item_count):
		var it := _action_opt.get_item_text(i).trim_prefix("[DEFERRED] ").strip_edges()
		if it == raw:
			_action_opt.select(i)
			_on_action_changed()
			return
	_pick(_action_opt, raw)
	_on_action_changed()


func set_scope(s: String, arg: String = "") -> void:
	var mode := s.strip_edges().to_upper()
	if mode in ["ALL_COMBAT", "ALL_FRIENDLY"]:
		mode = "ALL"
	if mode in SCOPE_MODES:
		_set_scope_mode(mode)
	if mode == "CLASS":
		_pick(_class_opt, arg.strip_edges().to_upper() if not arg.is_empty() else _opt_text(_class_opt))
	elif mode == "REGION":
		_pick(_region_opt, arg.strip_edges().to_upper() if not arg.is_empty() else _opt_text(_region_opt))
	elif mode == "CLASS+REGION":
		var parts := arg.split(",")
		if parts.size() >= 1 and not parts[0].strip_edges().is_empty():
			_pick(_class_opt, parts[0].strip_edges().to_upper())
		if parts.size() >= 2 and not parts[1].strip_edges().is_empty():
			_pick(_region_opt, parts[1].strip_edges().to_upper())
	elif mode in ["UNITS", "EXACT UNITS"]:
		_set_scope_mode("EXACT UNITS")
		if not arg.is_empty():
			_checked_unit_ids.clear()
			for uid in arg.split(","):
				var tid := uid.strip_edges().to_upper()
				if not tid.is_empty():
					_checked_unit_ids.append(tid)
			_sync_unit_picker_checkboxes()
	elif mode == "ADVANCED":
		_units_edit.text = arg
	_update_scope_badge()
	_on_builder_changed()


func set_target(t: String, arg: String = "") -> void:
	_pick(_target_type_opt, t.strip_edges().to_upper())
	_refresh_target_widgets()
	match _opt_text(_target_type_opt):
		"DIRECTION":
			if not arg.is_empty():
				_pick(_dir_opt, arg.strip_edges().to_upper())
		"HEX":
			if arg.contains(","):
				var parts := arg.split(",")
				_hex_q.text = parts[0].strip_edges()
				_hex_r.text = parts[1].strip_edges()
		"FORMATION":
			if not arg.is_empty():
				_pick(_tunit_opt, arg.strip_edges().to_upper())
		"ZONE":
			if not arg.is_empty():
				_pick(_zone_opt, arg.strip_edges().to_upper())
	_on_builder_changed()


func set_policy(_p: String) -> void:
	pass


func set_stance(s: String) -> void:
	_pick(_stance_opt, s.strip_edges().to_upper())
	_on_builder_changed()


func _reset_builder_defaults() -> void:
	_last_draft_key = ""
	_pick(_action_opt, "ADVANCE")
	_on_action_changed()
	_set_scope_mode("ALL")
	_pick(_stance_opt, "BALANCED")
	_units_edit.text = ""
	_hex_q.text = ""
	_hex_r.text = ""
	_refresh_scope_widgets()
	_on_builder_changed()


func _set_scope_mode(mode: String) -> void:
	_current_scope_mode = mode
	for m in _scope_mode_btns.keys():
		var btn: Button = _scope_mode_btns[m]
		if m == mode:
			btn.add_theme_color_override("font_color", Color(0.4, 0.9, 1.0))
		else:
			btn.remove_theme_color_override("font_color")
	_refresh_scope_widgets()
	_update_scope_badge()
	_on_builder_changed()


func _on_action_changed() -> void:
	var raw_action := _opt_text(_action_opt)
	var action := raw_action.trim_prefix("[DEFERRED] ").strip_edges()
	var keep := _opt_text(_target_type_opt)
	var allowed: Array = TARGETS_FOR_ACTION.get(action, ["NONE"])
	_rebuild_opt(_target_type_opt, allowed, keep if keep in allowed else str(allowed[0]))
	match action:
		"WITHDRAW":
			_pick(_zone_opt, "HQ")
		"REPOSITION", "CONCENTRATE":
			_pick(_zone_opt, "CENTER")
		"FLANK", "ADVANCE", "RECON", "PRESSURE":
			_pick(_dir_opt, "FORWARD" if _opt_text(_dir_opt).is_empty() else _opt_text(_dir_opt))
	_refresh_target_widgets()
	_on_builder_changed()


func _refresh_scope_widgets() -> void:
	var mode := _current_scope_mode
	_class_opt.visible = mode in ["CLASS", "CLASS+REGION"]
	_region_opt.visible = mode in ["REGION", "CLASS+REGION"]
	_unit_picker_box.visible = mode == "EXACT UNITS"
	_units_edit.visible = mode == "ADVANCED"
	_formation_opt.visible = false
	_sel_hint.visible = false
	_scope_none_hint.visible = mode == "ALL"
	if mode == "ALL":
		_scope_none_hint.text = "전투군 (Blue 전투 부대 전체)"


func _refresh_target_widgets() -> void:
	var kind := _opt_text(_target_type_opt)
	_dir_opt.visible = kind == "DIRECTION"
	_hex_row.visible = kind == "HEX"
	_tunit_opt.visible = kind == "FORMATION"
	_zone_opt.visible = kind == "ZONE"
	_target_none_hint.visible = kind == "NONE" or kind == "OBJECTIVE"
	if kind == "OBJECTIVE":
		_target_none_hint.text = "nearest visible contact"
	elif kind == "NONE":
		_target_none_hint.text = "no target for this action"


func _select_all_units() -> void:
	_checked_unit_ids.clear()
	for uid in _unit_checkboxes.keys():
		_checked_unit_ids.append(uid)
		(_unit_checkboxes[uid] as CheckBox).button_pressed = true
	_checked_unit_ids.sort()
	_update_scope_badge()
	_on_builder_changed()


func _clear_all_units() -> void:
	_checked_unit_ids.clear()
	for uid in _unit_checkboxes.keys():
		(_unit_checkboxes[uid] as CheckBox).button_pressed = false
	_update_scope_badge()
	_on_builder_changed()


func _sync_unit_picker_checkboxes() -> void:
	for uid in _unit_checkboxes.keys():
		(_unit_checkboxes[uid] as CheckBox).button_pressed = uid in _checked_unit_ids


func _update_scope_badge() -> void:
	if _scope_badge == null:
		return
	var count := 0
	var friendlies: Array = _obs.get("friendly_units", []) if not _obs.is_empty() else []
	match _current_scope_mode:
		"ALL":
			for u in friendlies:
				if str(u.get("class", "")).to_upper() != "HQ":
					count += 1
		"CLASS":
			var c := _opt_text(_class_opt).to_lower()
			for u in friendlies:
				if str(u.get("class", "")).to_lower() == c:
					count += 1
		"REGION":
			var r := _opt_text(_region_opt).to_upper()
			for u in friendlies:
				if str(u.get("region", "")).to_upper() == r:
					count += 1
		"CLASS+REGION":
			var c2 := _opt_text(_class_opt).to_lower()
			var r2 := _opt_text(_region_opt).to_upper()
			for u in friendlies:
				if str(u.get("class", "")).to_lower() == c2 and str(u.get("region", "")).to_upper() == r2:
					count += 1
		"EXACT UNITS":
			count = _checked_unit_ids.size()
		"ADVANCED":
			count = -1
	if count >= 0:
		_scope_badge.text = "선택: %d개 부대" % count
	else:
		_scope_badge.text = "선택: (수식)"


func _push_to_panel() -> void:
	if _panel == null:
		return
	var raw_act := _opt_text(_action_opt)
	var act := raw_act.trim_prefix("[DEFERRED] ").strip_edges()
	_panel.set_action(act)
	_panel.set_stance(_opt_text(_stance_opt))

	var scope: Dictionary = {}
	match _current_scope_mode:
		"ALL":
			scope = TableCls.scope_all_combat()
		"CLASS":
			scope = TableCls.scope_class(_opt_text(_class_opt))
		"REGION":
			scope = TableCls.scope_region(_opt_text(_region_opt))
		"CLASS+REGION":
			scope = {
				"op": "INTERSECT",
				"args": [
					TableCls.scope_class(_opt_text(_class_opt)),
					TableCls.scope_region(_opt_text(_region_opt))
				]
			}
		"EXACT UNITS":
			var uids := _checked_unit_ids.duplicate()
			if uids.is_empty():
				if not _own_ids.is_empty():
					uids = [_own_ids[0]]
				else:
					uids = ["B_INF_1"]
			scope = TableCls.scope_units(uids)
		"ADVANCED":
			var raw_expr := _units_edit.text.strip_edges()
			if raw_expr.is_empty():
				scope = TableCls.scope_all_combat()
			elif raw_expr.begins_with("{"):
				var parsed: Variant = JSON.parse_string(raw_expr)
				if parsed is Dictionary:
					scope = parsed
				else:
					scope = TableCls.scope_all_combat()
			elif raw_expr.to_upper().begins_with("INTERSECT"):
				scope = {
					"op": "INTERSECT",
					"args": [
						TableCls.scope_class(_opt_text(_class_opt)),
						TableCls.scope_region(_opt_text(_region_opt))
					]
				}
			elif raw_expr.to_upper().begins_with("UNION"):
				scope = {
					"op": "UNION",
					"args": [
						TableCls.scope_class(_opt_text(_class_opt)),
						TableCls.scope_region(_opt_text(_region_opt))
					]
				}
			else:
				var ids: Array = []
				for part in raw_expr.split(","):
					var pid: String = str(part).strip_edges().to_upper()
					if not pid.is_empty():
						ids.append(pid)
				scope = TableCls.scope_units(ids if not ids.is_empty() else ["B_INF_1"])
	_panel.set_custom_scope(scope)

	var tkind := _opt_text(_target_type_opt)
	match tkind:
		"DIRECTION":
			_panel.set_target_kind("DIRECTION:" + _opt_text(_dir_opt))
		"HEX":
			_panel.set_target_kind("HEX")
			_panel.set_target_arg(_hex_q.text.strip_edges() + "," + _hex_r.text.strip_edges())
		"FORMATION":
			_panel.set_target_kind("FORMATION")
			_panel.set_target_arg(_opt_text(_tunit_opt))
		"ZONE":
			_panel.set_target_kind("ZONE:" + _opt_text(_zone_opt))
		"OBJECTIVE":
			_panel.set_target_kind("OBJECTIVE")
		_:
			_panel.set_target_kind("NONE")


func _on_builder_changed() -> void:
	if _panel == null:
		return
	_push_to_panel()
	var cmd: Dictionary = _panel.draft_command()
	# Spurious-signal guard: OptionButton item rebuilds re-emit item_selected with
	# unchanged values. Re-pushing the same command must NOT invalidate a valid
	# preview (only an actual command change does).
	var key := JSON.stringify(cmd)
	if key == _last_draft_key:
		return
	_last_draft_key = key
	var txt := InspectorCls.summarize_command_kr(cmd, _panel.get_selected_id())
	var act := str(cmd.get("action", ""))
	if act in TableCls.DEFERRED_ACTIONS:
		txt += "  (%s는 1단계에서 실행 유예됨 — 미리보기에서 설명, 실행 불가)" % act
	_cmd_summary.text = txt
	_update_sel_hint()
	_invalidate_preview("")


func _refresh_unit_picker_from_obs(obs: Dictionary) -> void:
	if _unit_picker_list == null:
		return
	for ch in _unit_picker_list.get_children():
		ch.queue_free()
	_unit_checkboxes.clear()
	var friendlies: Array = obs.get("friendly_units", [])
	for u_val in friendlies:
		var u: Dictionary = u_val
		var uid := str(u.get("unit_id", ""))
		var uclass := str(u.get("class", ""))
		var sol := int(u.get("soldiers", 0))
		var ureg := str(u.get("region", ""))
		var uq := int(u.get("q", 0))
		var ur := int(u.get("r", 0))
		var ustatus := str(u.get("status", "ready"))

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		_unit_picker_list.add_child(row)

		var cb := CheckBox.new()
		cb.text = "%s  %-8s %3d sol  [%s] (%d,%d) %s" % [uid, uclass, sol, ureg, uq, ur, ustatus]
		cb.add_theme_font_size_override("font_size", 11)
		cb.button_pressed = uid in _checked_unit_ids
		var captured_id := uid
		cb.toggled.connect(func(checked: bool) -> void:
			if checked:
				if not captured_id in _checked_unit_ids:
					_checked_unit_ids.append(captured_id)
			else:
				_checked_unit_ids.erase(captured_id)
			_checked_unit_ids.sort()
			_update_scope_badge()
			_on_builder_changed()
		)
		row.add_child(cb)
		_unit_checkboxes[uid] = cb
	_update_scope_badge()
	_invalidate_preview("")


func _update_sel_hint() -> void:
	var sel: String = _panel.get_selected_id() if _panel != null else ""
	_sel_hint.text = ("selected: " + sel) if not sel.is_empty() else "(none -- click a BLUE unit)"


func _invalidate_preview(reason: String) -> void:
	_preview_valid = false
	_btn_execute.disabled = true
	_prev_summary.text = "No valid preview -- press PREVIEW."
	if not reason.is_empty():
		_status(reason)


# --- observation / header ---

func _update_header(obs: Dictionary) -> void:
	var mission: Dictionary = obs.get("mission", {})
	_status_main.text = "%s | TURN %d | %s | %s" % [
		str(obs.get("side", "?")), int(obs.get("turn", 0)),
		str(obs.get("phase", "?")), InspectorCls.mission_short(str(mission.get("type", "?")))]
	var parity: Dictionary = obs.get("parity", {})
	var sel: String = _panel.get_selected_id() if _panel != null else ""
	_status_sub.text = "Sel: %s | State v%s | fp %s" % [
		sel if not sel.is_empty() else "(none)",
		str(parity.get("state_version", "?")),
		str(parity.get("fingerprint", "?")).left(12)]


func _refresh_builder_options(obs: Dictionary) -> void:
	var formations := {}
	for u_val in (obs.get("friendly_units", []) as Array):
		formations[str((u_val as Dictionary).get("formation", "FIELD")).strip_edges().to_upper()] = true
	var flist: Array = formations.keys()
	flist.sort()
	if flist.is_empty():
		flist = ["FIELD"]
	_rebuild_opt(_formation_opt, flist, _opt_text(_formation_opt))
	_enemy_ids = []
	_own_ids = []
	for u2_val in (obs.get("friendly_units", []) as Array):
		_own_ids.append(str((u2_val as Dictionary).get("unit_id", "")))
	for e_val in (obs.get("known_enemy_units", []) as Array):
		if str((e_val as Dictionary).get("contact_state", "")) == "current_visible":
			_enemy_ids.append(str((e_val as Dictionary).get("unit_id", "")))
	_enemy_ids.sort()
	_own_ids.sort()
	_rebuild_opt(_tunit_opt, _enemy_ids + _own_ids, _opt_text(_tunit_opt))
	_refresh_unit_picker_from_obs(obs)


# --- preview / result presentation ---

func _show_plan_result(plan: Dictionary) -> void:
	var s: Dictionary = InspectorCls.preview_summary(plan)
	if not bool(s.get("ok", false)):
		_prev_summary.text = "NO PLAN -- %s" % str(s.get("detail", ""))
		_res_summary.text = "NO PLAN -- %s %s" % [str(s.get("code", "")), str(s.get("detail", ""))]
		_res_list.clear()
		for f_val in (plan.get("failed", []) as Array):
			_add_row(InspectorCls.format_failed_row(f_val))
		set_tab("RESULT")
		return
	_prev_summary.text = "Resolved %d | Planned %d (M%d/H%d/A%d) | Blocked %d" % [
		int(s.get("resolved", 0)), int(s.get("planned", 0)),
		int(s.get("moves", 0)), int(s.get("holds", 0)), int(s.get("attacks", 0)),
		int(s.get("failed", 0))]
	_res_summary.text = "PREVIEW -- Resolved %d | Planned %d | Blocked %d (map shows routes)" % [
		int(s.get("resolved", 0)), int(s.get("planned", 0)), int(s.get("failed", 0))]
	_res_list.clear()
	for p_val in (plan.get("planned", []) as Array):
		_add_row(InspectorCls.format_preview_row(p_val))
	for f2_val in (plan.get("failed", []) as Array):
		_add_row(InspectorCls.format_failed_row(f2_val))


func _add_row(row: Dictionary) -> void:
	var idx := _res_list.add_item(str(row.get("text", "?")), null, false)
	_res_list.set_item_metadata(idx, str(row.get("unit_id", "")))
	_res_list.set_item_custom_fg_color(idx, TONE.get(str(row.get("tone", "dim")), TONE["dim"]))


func _show_exec_result(result: Dictionary) -> void:
	var n_ok := (result.get("executed_units", []) as Array).size()
	var n_fail := (result.get("execution_failed", []) as Array).size() + (result.get("plan_failed", []) as Array).size()
	_res_summary.text = "%s -- %d executed / %d failed" % [str(result.get("execution_status", "?")), n_ok, n_fail]
	_res_list.clear()
	for x_val in (result.get("executed_units", []) as Array):
		_add_row(InspectorCls.format_exec_row("executed", x_val))
	for y_val in (result.get("plan_failed", []) as Array):
		_add_row(InspectorCls.format_failed_row(y_val))
	for z_val in (result.get("execution_failed", []) as Array):
		_add_row(InspectorCls.format_failed_row(z_val))


func _draw_plan_overlay(plan: Dictionary) -> void:
	_overlay.clear_preview()
	if not bool(plan.get("ok", false)):
		return
	var svc: RefCounted = _bridge.get_service()
	var mgr: RefCounted = _bridge.get_manager()
	var routes: Array = []
	var sources: Array = []
	var failed_cells: Array = []
	for p_val in (plan.get("planned", []) as Array):
		var p: Dictionary = p_val
		var kind := str(p.get("action", ""))
		if kind == "MOVE":
			var to_arr: Array = p.get("to", [])
			var prev: Dictionary = svc.preview_move(str(p.get("unit_id", "")), Vector2i(int(to_arr[0]), int(to_arr[1])), "blue", str(p.get("march_mode", "auto")))
			routes.append({"kind": "move", "unit_id": str(p.get("unit_id", "")),
				"path_cells": prev.get("path_cells", [])})
			sources.append((p.get("from", []) as Array).duplicate())
		elif kind == "ATTACK":
			var a: Dictionary = mgr.get_unit_by_id(str(p.get("unit_id", "")))
			var b: Dictionary = mgr.get_unit_by_id(str(p.get("target_unit_id", "")))
			if not a.is_empty() and not b.is_empty():
				routes.append({"kind": "attack", "unit_id": str(p.get("unit_id", "")),
					"from_cell": [int(a.get("q", 0)), int(a.get("r", 0))],
					"to_cell": [int(b.get("q", 0)), int(b.get("r", 0))]})
				sources.append([int(a.get("q", 0)), int(a.get("r", 0))])
		elif kind == "HOLD":
			routes.append({"kind": "hold", "unit_id": str(p.get("unit_id", "")),
				"at_cell": (p.get("to", p.get("from", [])) as Array).duplicate()})
			sources.append((p.get("from", []) as Array).duplicate())
	for f_val in (plan.get("failed", []) as Array):
		var uid := str((f_val as Dictionary).get("unit_id", ""))
		if uid.is_empty():
			continue
		var u: Dictionary = mgr.get_unit_by_id(uid)
		if not u.is_empty():
			failed_cells.append([int(u.get("q", 0)), int(u.get("r", 0))])
	_overlay.set_preview(routes, failed_cells, sources)


# --- events ---

func _on_refresh() -> void:
	_overlay.clear_preview()
	refresh_observation()
	_status("Observation refreshed.")


func _on_unit_finished(row: Dictionary, succeeded: bool) -> void:
	_status("...%s %s" % [str(row.get("unit_id", "?")), "OK" if succeeded else "FAIL " + str(row.get("code", ""))])


func _on_execution_finished(result: Dictionary) -> void:
	_overlay.clear_preview()
	_show_exec_result(result)
	refresh_observation()
	set_tab("RESULT")
	_status("Done: %s -- %d executed / %d failed." % [
		str(result.get("execution_status", "?")),
		(result.get("executed_units", []) as Array).size(),
		(result.get("execution_failed", []) as Array).size()])


func _on_legacy_toggle() -> void:
	set_legacy_visible(_legacy_hidden)


func _on_collapse_toggle() -> void:
	_collapsed = not _collapsed
	_content.visible = not _collapsed
	_btn_collapse.text = "+" if _collapsed else "-"
	if floating_mode:
		_float_apply_minimized(_collapsed)


## Floating window subsystem (floating_mode only). In-game Control window:
## draggable title bar, 8 resize handles, minimize/restore with geometry
## memory, viewport clamping, UI-only hide. No native OS window: battle
## interaction, CanvasLayer z-order, and game focus stay trivial.

func is_window_minimized() -> bool:
	return _collapsed


func get_window_rect() -> Rect2:
	return Rect2(position, size)


func set_window_rect(r: Rect2) -> void:
	# Test/driver hook: move + resize through the same clamp path as the mouse.
	if not floating_mode:
		return
	if _collapsed:
		position = _float_clamp_pos(r.position, size)
	else:
		size = _float_clamp_size(r.size)
		position = _float_clamp_pos(r.position, size)
	_float_save_geometry()


func _input(event: InputEvent) -> void:
	if not floating_mode or not is_visible_in_tree():
		return
	if event is InputEventMouseMotion:
		if _float_drag:
			# Delta of canvas-space mouse positions: exact under any stretch
			# (no scale factor needed — both ends live in HUD layer space),
			# and the grab offset is preserved by construction.
			var m := get_global_mouse_position()
			position = _float_clamp_pos(position + (m - _float_drag_last), size)
			_float_drag_last = m
			accept_event()
		elif _float_resize != "":
			_float_resize_to(get_global_mouse_position())
			accept_event()
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			if _float_drag or _float_resize != "":
				_float_drag = false
				_float_resize = ""
				_float_save_geometry()
				accept_event()


func _on_float_title_input(event: InputEvent) -> void:
	if not floating_mode:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_float_drag = true
			_float_resize = ""
			_float_drag_last = get_global_mouse_position()
			accept_event()


func _on_float_handle_input(event: InputEvent, mode: String) -> void:
	if not floating_mode or _collapsed:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_float_resize = mode
			_float_drag = false
			_float_resize_start_mouse = get_global_mouse_position()
			_float_resize_start_rect = Rect2(position, size)
			accept_event()


func _float_setup_window() -> void:
	# The left gutter is replaced by the full 8-handle resize set; the node
	# stays (Step-1 UX probes read it) but is hidden in floating mode.
	if _gutter != null:
		_gutter.visible = false
	_float_build_handles()
	_float_apply_initial_geometry()
	if not _float_wired_viewport and is_inside_tree():
		get_tree().root.size_changed.connect(_on_float_viewport_resized)
		_float_wired_viewport = true


func _float_build_handles() -> void:
	# Internal children: Container layout ignores them, anchors still work,
	# so every handle tracks its edge/corner with zero per-frame code.
	var specs: Array = [
		["l", 0.0, 0.0, 0.0, 1.0, 0.0, FLOAT_CORNER, FLOAT_EDGE, -FLOAT_CORNER, Control.CURSOR_HSIZE],
		["r", 1.0, 0.0, 1.0, 1.0, -FLOAT_EDGE, FLOAT_CORNER, 0.0, -FLOAT_CORNER, Control.CURSOR_HSIZE],
		["t", 0.0, 0.0, 1.0, 0.0, FLOAT_CORNER, 0.0, -FLOAT_CORNER, FLOAT_EDGE, Control.CURSOR_VSIZE],
		["b", 0.0, 1.0, 1.0, 1.0, FLOAT_CORNER, -FLOAT_EDGE, -FLOAT_CORNER, 0.0, Control.CURSOR_VSIZE],
		["tl", 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, FLOAT_CORNER, FLOAT_CORNER, Control.CURSOR_FDIAGSIZE],
		["br", 1.0, 1.0, 1.0, 1.0, -FLOAT_CORNER, -FLOAT_CORNER, 0.0, 0.0, Control.CURSOR_FDIAGSIZE],
		["tr", 1.0, 0.0, 1.0, 0.0, -FLOAT_CORNER, 0.0, 0.0, FLOAT_CORNER, Control.CURSOR_BDIAGSIZE],
		["bl", 0.0, 1.0, 0.0, 1.0, 0.0, -FLOAT_CORNER, FLOAT_CORNER, 0.0, Control.CURSOR_BDIAGSIZE],
	]
	for s in specs:
		var h := Control.new()
		h.name = "FloatResize_%s" % str(s[0])
		h.mouse_filter = Control.MOUSE_FILTER_STOP
		h.mouse_default_cursor_shape = s[9]
		h.tooltip_text = "Drag to resize"
		h.set_anchor(SIDE_LEFT, float(s[1]))
		h.set_anchor(SIDE_TOP, float(s[2]))
		h.set_anchor(SIDE_RIGHT, float(s[3]))
		h.set_anchor(SIDE_BOTTOM, float(s[4]))
		h.offset_left = float(s[5])
		h.offset_top = float(s[6])
		h.offset_right = float(s[7])
		h.offset_bottom = float(s[8])
		var mode := str(s[0])
		h.gui_input.connect(func(ev: InputEvent) -> void: _on_float_handle_input(ev, mode))
		add_child(h, false, Node.INTERNAL_MODE_FRONT)
		_float_handles.append(h)
	_float_grip = _FloatGrip.new()
	add_child(_float_grip, false, Node.INTERNAL_MODE_FRONT)


func _float_apply_initial_geometry() -> void:
	var vis := _float_visible_rect()
	var r := _float_default_rect(vis)
	var minimized := false
	var loaded := _float_load_geometry()
	if (loaded.get("rect", Rect2()) as Rect2).has_area():
		r = loaded["rect"]
		minimized = bool(loaded.get("minimized", false))
	size = _float_clamp_size_for(r.size, vis)
	position = _float_clamp_pos_for(r.position, size, vis)
	_float_drag = false
	_float_resize = ""
	if minimized:
		_collapsed = true
		_content.visible = false
		_btn_collapse.text = "+"
		_float_apply_minimized(true)


func _float_default_rect(vis: Rect2) -> Rect2:
	# Right column between the always-visible controls: below the turn bar
	# (bottom ~224) and above END TURN (top at vh-112). Never covers them.
	var w := DEFAULT_W
	var top := 232.0
	if vis.size.y < 680.0:
		top = 60.0
	var bottom_margin := 128.0
	var h := vis.size.y - top - bottom_margin
	h = clampf(h, FLOAT_MIN_H, 900.0)
	var x := vis.position.x + vis.size.x - w - 8.0
	var y := vis.position.y + top
	if y + h + bottom_margin > vis.position.y + vis.size.y:
		y = maxf(vis.position.y + 56.0, vis.position.y + vis.size.y - bottom_margin - h)
	return Rect2(x, y, w, h)


func _float_resize_to(mouse_canvas: Vector2) -> void:
	if _float_resize.is_empty():
		return
	var d := mouse_canvas - _float_resize_start_mouse
	var start := _float_resize_start_rect
	var pos := start.position
	var sz := start.size
	var vis := _float_visible_rect()
	var max_sz := Vector2(maxf(vis.size.x - 32.0, FLOAT_MIN_W), maxf(vis.size.y - 32.0, FLOAT_MIN_H))
	if _float_resize.contains("l"):
		var w := clampf(start.size.x - d.x, FLOAT_MIN_W, max_sz.x)
		pos.x = start.position.x + start.size.x - w
		sz.x = w
	if _float_resize.contains("r"):
		sz.x = clampf(start.size.x + d.x, FLOAT_MIN_W, max_sz.x)
	if _float_resize.contains("t"):
		var h := clampf(start.size.y - d.y, FLOAT_MIN_H, max_sz.y)
		pos.y = start.position.y + start.size.y - h
		sz.y = h
	if _float_resize.contains("b"):
		sz.y = clampf(start.size.y + d.y, FLOAT_MIN_H, max_sz.y)
	size = sz
	position = _float_clamp_pos_for(pos, sz, vis)


func _float_apply_minimized(m: bool) -> void:
	for h in _float_handles:
		(h as Control).visible = not m
	if _float_grip != null:
		_float_grip.visible = not m
	if m:
		_float_saved_rect = Rect2(position, size)
		_float_has_saved = true
		_status_main.visible = false
		_status_sub.visible = false
		if _head_warn != null:
			_head_warn.visible = false
		var hh := 44.0
		if _head_row != null:
			hh = maxf(_head_row.get_combined_minimum_size().y + 12.0, 40.0)
		size = Vector2(size.x, hh)
		position = _float_clamp_pos(position, size)
	else:
		_status_main.visible = true
		_status_sub.visible = true
		if _head_warn != null:
			_head_warn.visible = true
		if _float_has_saved:
			size = _float_clamp_size(_float_saved_rect.size)
			position = _float_clamp_pos(_float_saved_rect.position, size)
	_float_save_geometry()


func _on_float_viewport_resized() -> void:
	if not floating_mode:
		return
	# Never re-snap to the default: only clamp the user's rect into view.
	if _collapsed:
		position = _float_clamp_pos(position, size)
	else:
		size = _float_clamp_size(size)
		position = _float_clamp_pos(position, size)
	_float_save_geometry()


func _float_visible_rect() -> Rect2:
	# Clamp region in HUD-layer Control space. The Lab lives on a CanvasLayer
	# that does NOT follow the viewport, so the battlefield camera (zoom/pan)
	# must never enter this math: only the stretch canvas does. With the
	# project's canvas_items/keep stretch, Control layout units are exactly
	# the configured viewport size at any window size or aspect (letterbox
	# bars fall outside it, which is what we want to clamp against).
	# NOTE: get_viewport().get_canvas_transform() is deliberately NOT used —
	# it carries the camera and would drag the window around with the battle.
	var w := float(ProjectSettings.get_setting("window/size/viewport_width", 1920))
	var h := float(ProjectSettings.get_setting("window/size/viewport_height", 1080))
	if w <= 0.0 or h <= 0.0:
		w = 1920.0
		h = 1080.0
	return Rect2(Vector2.ZERO, Vector2(w, h))


func _float_clamp_size(sz: Vector2) -> Vector2:
	return _float_clamp_size_for(sz, _float_visible_rect())


func _float_clamp_size_for(sz: Vector2, vis: Rect2) -> Vector2:
	var max_sz := Vector2(maxf(vis.size.x - 32.0, FLOAT_MIN_W), maxf(vis.size.y - 32.0, FLOAT_MIN_H))
	return Vector2(clampf(sz.x, FLOAT_MIN_W, max_sz.x), clampf(sz.y, FLOAT_MIN_H, max_sz.y))


func _float_clamp_pos(p: Vector2, sz: Vector2) -> Vector2:
	return _float_clamp_pos_for(p, sz, _float_visible_rect())


func _float_clamp_pos_for(p: Vector2, sz: Vector2, vis: Rect2) -> Vector2:
	# Free movement, but the title bar can never be lost: keep a grabbable
	# span of it inside the viewport (full containment would feel sticky).
	var min_x := vis.position.x - (sz.x - FLOAT_TITLE_KEEP)
	var max_x := vis.position.x + vis.size.x - FLOAT_TITLE_KEEP
	var min_y := vis.position.y
	var max_y := vis.position.y + vis.size.y - 64.0
	if max_x < min_x:
		max_x = min_x
	if max_y < min_y:
		max_y = min_y
	return Vector2(clampf(p.x, min_x, max_x), clampf(p.y, min_y, max_y))


func _float_save_geometry() -> void:
	if not floating_mode or not is_inside_tree():
		return
	var cfg := ConfigFile.new()
	var full := Rect2(position, size)
	if _collapsed and _float_has_saved:
		full = _float_saved_rect
	cfg.set_value("lab", "x", full.position.x)
	cfg.set_value("lab", "y", full.position.y)
	cfg.set_value("lab", "w", full.size.x)
	cfg.set_value("lab", "h", full.size.y)
	cfg.set_value("lab", "minimized", _collapsed)
	cfg.save(FLOAT_GEOM_PATH)


func _float_load_geometry() -> Dictionary:
	var out := {"rect": Rect2(), "minimized": false}
	if not floating_mode:
		return out
	var cfg := ConfigFile.new()
	if cfg.load(FLOAT_GEOM_PATH) != OK:
		return out
	var nums: Array = []
	for k in ["x", "y", "w", "h"]:
		var v: Variant = cfg.get_value("lab", k, null)
		if not (v is float or v is int):
			return out
		nums.append(float(v))
	if nums[2] < FLOAT_MIN_W or nums[3] < FLOAT_MIN_H:
		return out
	out["rect"] = Rect2(nums[0], nums[1], nums[2], nums[3])
	out["minimized"] = bool(cfg.get_value("lab", "minimized", false))
	return out


func _on_result_row_selected(idx: int) -> void:
	var uid := str(_res_list.get_item_metadata(idx))
	if not uid.is_empty():
		focus_result_unit(uid)


func _on_result_row_activated(idx: int) -> void:
	var uid := str(_res_list.get_item_metadata(idx))
	if uid.is_empty() or _bridge == null:
		return
	var mgr: RefCounted = _bridge.get_manager()
	var u: Dictionary = mgr.get_unit_by_id(uid) if mgr != null else {}
	if u.is_empty():
		return
	focus_result_unit(uid)
	var shell: Node = _bridge.get_shell()
	var cam: Variant = shell.get("camera") if shell != null else null
	if cam is Node and (cam as Node).has_method("focus_on"):
		(cam as Node).call("focus_on", HexUtilsCls.hex_to_pixel(int(u.get("q", 0)), int(u.get("r", 0))), false)


func _on_gutter_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_resizing = mb.pressed
			if mb.pressed:
				_drag_x = mb.global_position.x
			accept_event()
	elif event is InputEventMouseMotion and _resizing:
		var mm := event as InputEventMouseMotion
		set_dock_width(size.x + (_drag_x - mm.global_position.x))
		_drag_x = mm.global_position.x
		accept_event()


func _process(_delta: float) -> void:
	if _bridge == null:
		return
	var narrow := visible and size.x < NARROW_W
	if narrow != _narrow:
		_narrow = narrow
		_builder_grid.columns = 1 if narrow else 2
	var mgr: RefCounted = _bridge.get_manager()
	if mgr == null:
		return
	var cur := ""
	if mgr.has_method("is_unit_selected") and bool(mgr.is_unit_selected()):
		cur = str(mgr.get_selected_unit_id())
	if cur != _last_sel:
		_last_sel = cur
		_panel.set_selected_unit(cur)
		_update_sel_hint()
		_update_header(_obs)
		# Any map selection change can retarget a SELECTED-derived draft: re-push
		# the builder (materializes explicit UNITS ids) and invalidate the preview
		# so a stale plan can never execute against a different unit set.
		_on_builder_changed()
	var turn := int(mgr.get_current_turn()) if mgr.has_method("get_current_turn") else -1
	if turn != _last_turn:
		_last_turn = turn
		if not _obs.is_empty():
			_update_header(_obs)


func _apply_legacy() -> void:
	var show_player := (not _legacy_hidden) and (not _map_focus)
	if _left_dock != null and is_instance_valid(_left_dock):
		_left_dock.visible = show_player
	if _advisor_dock != null and is_instance_valid(_advisor_dock):
		# Kept invisible so this console's translucency shows the battlefield,
		# not the step7 advisor slab stacked underneath it.
		_advisor_dock.visible = show_player


func _update_legacy_btn() -> void:
	if _btn_legacy != null:
		_btn_legacy.text = "LEGACY: OFF" if _legacy_hidden else "LEGACY: ON"


func _status(t: String) -> void:
	_status_label.text = t
