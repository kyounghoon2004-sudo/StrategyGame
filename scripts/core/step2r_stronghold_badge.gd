class_name Step2RStrongholdBadge
extends Node2D

## Step2RStrongholdBadge — Compact World Strategic Nameplate (STEP-04R5)
## Default state: very compact single-line nameplate ([護] 虎牢關 / ★ 洛陽 ★)
## Hover state: border/text brighten ONLY — no expansion, no detail card (§3-5).
## Selected state: same compact nameplate with modest gold highlight pulse.
## All detail info lives in the dedicated right-side Stronghold panel (shell §6).
## Size Hierarchy: Unit (1.0) < Fortress (≈1.20) < Capital (≈1.38).
## Adaptive zoom scaling with strict min/max clamps.

signal badge_clicked(structure_id: String)
signal badge_hover_changed(is_hovered: bool)

const SemanticZoomCls = preload("res://scripts/step2r/semantic_zoom.gd")

const DEFAULT_ZOOM: float = 1.15
const NORMAL_MIN_ZOOM: float = 0.85
const NORMAL_MAX_ZOOM: float = 8.0
const OVERVIEW_MIN_ZOOM: float = 0.30
const OVERVIEW_CAP_THRESHOLD: float = 0.50

# Prominence scale multipliers (Section 16: Fortress ≈ 1.15-1.30, Capital ≈ 1.30-1.45)
const FORTRESS_BASE_SCALE: float = 1.20
const CAPITAL_BASE_SCALE: float = 1.38
const SCALE_EXPONENT: float = 1.10

const MIN_ADAPTIVE_SCALE: float = 0.35
const MAX_ADAPTIVE_SCALE: float = 1.55
const OVERVIEW_CLAMP_FORTRESS: float = 1.45
const OVERVIEW_CLAMP_CAPITAL: float = 1.65

var structure_id: String = ""
var structure_type: int = 0 # 0=FORTRESS, 1=CAPITAL
var structure_name: String = ""
var owner_faction: String = "red"
var fortification_hp: int = 1000
var fortification_hp_max: int = 1000
var breached: bool = false
var garrison_count: int = 3
var garrison_max: int = 4
var is_objective: bool = false
var is_selected: bool = false
var is_hovered: bool = false

var _current_zoom: float = DEFAULT_ZOOM
var _current_scale: Vector2 = Vector2.ONE

# UI elements
var _panel: PanelContainer
var _vbox: VBoxContainer
var _title_label: Label
var _style_box: StyleBoxFlat
var _pulse_phase: float = 0.0

func _ready() -> void:
	z_index = 32 # Above structure art (5) and normal units (10..28)
	_build_ui()
	update_zoom_scale(_current_zoom, true)
	_refresh_display()
	set_process(true)

func _process(delta: float) -> void:
	if is_selected:
		_pulse_phase += delta * 4.0
		if _pulse_phase > TAU:
			_pulse_phase -= TAU
		var p: float = 0.5 + 0.5 * sin(_pulse_phase)
		if _style_box:
			_style_box.border_color = Color(1.0, 0.85 + 0.15 * p, 0.30, 0.95)
			_style_box.shadow_size = int(3.0 + 3.0 * p)
			queue_redraw()

func setup(
	p_id: String,
	p_type: int,
	p_name: String,
	p_owner: String,
	p_hp: int,
	p_hp_max: int,
	p_garrison: int,
	p_garrison_max: int,
	p_objective: bool = false,
	initial_zoom: float = DEFAULT_ZOOM
) -> void:
	structure_id = p_id
	structure_type = p_type
	structure_name = p_name
	owner_faction = p_owner
	fortification_hp = p_hp
	fortification_hp_max = p_hp_max
	breached = (p_hp <= 0)
	garrison_count = p_garrison
	garrison_max = p_garrison_max
	is_objective = p_objective or (p_type == 1)
	_current_zoom = initial_zoom
	_build_ui()
	update_zoom_scale(_current_zoom, true)
	_refresh_display()

func set_camera_zoom(zoom_val: float) -> void:
	update_zoom_scale(zoom_val, false)

func update_zoom_scale(zoom_val: float, instant: bool = false) -> void:
	# PERF-V1: per-frame zoom echo must not re-scale stronghold badges while idle.
	var cz: float = clampf(zoom_val, 0.25, 8.0)
	if not instant and is_equal_approx(_current_zoom, cz):
		return
	_current_zoom = cz
	var is_capital: bool = (structure_type == 1)
	_current_scale = SemanticZoomCls.objective_badge_scale(cz, is_capital)
	scale = _current_scale
	_refresh_display()

func update_state(p_hp: int, p_breached: bool, p_garrison: int) -> void:
	fortification_hp = p_hp
	breached = p_breached
	garrison_count = p_garrison
	_refresh_display()

func set_selected(selected: bool) -> void:
	is_selected = selected
	if not is_selected and _style_box:
		var is_capital: bool = (structure_type == 1)
		_style_box.border_color = Color(0.92, 0.82, 0.45, 1.0) if is_capital else Color(0.78, 0.65, 0.32, 0.95)
		_style_box.shadow_size = 4
	_apply_hover_style()
	queue_redraw()

func set_hovered(hovered: bool) -> void:
	if is_hovered == hovered:
		return
	is_hovered = hovered
	_apply_hover_style()
	badge_hover_changed.emit(is_hovered)

## Hover feedback is limited to border/text brightening (STEP-04R5 §5).
## Never resizes the panel, never adds content, never creates new Controls.
## Director request: the nameplate is nearly invisible (0.12) until the
## stronghold is hovered or selected, then firms up to full presence.
const IDLE_ALPHA: float = 0.12
const ACTIVE_ALPHA: float = 0.95

func _apply_hover_style() -> void:
	var is_capital: bool = (structure_type == 1)
	var active: bool = (is_hovered or is_selected)
	modulate = Color(1, 1, 1, ACTIVE_ALPHA if active else IDLE_ALPHA)
	if _style_box and not is_selected:
		if is_hovered:
			_style_box.border_color = Color(1.0, 0.95, 0.65, 1.0) if is_capital else Color(0.95, 0.85, 0.45, 1.0)
		else:
			_style_box.border_color = Color(0.92, 0.82, 0.45, 1.0) if is_capital else Color(0.78, 0.65, 0.32, 0.95)
	if _title_label:
		if is_hovered:
			_title_label.add_theme_color_override("font_color", Color(1.0, 0.98, 0.85, 1.0) if is_capital else Color(1.0, 0.95, 0.70, 1.0))
		else:
			_title_label.add_theme_color_override("font_color", Color(0.96, 0.90, 0.65, 1.0) if is_capital else Color(0.92, 0.90, 0.84, 1.0))

func _build_ui() -> void:
	if _panel != null and is_instance_valid(_panel):
		_panel.queue_free()

	var is_capital: bool = (structure_type == 1)
	_panel = PanelContainer.new()
	_panel.name = "BadgePanel"
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.mouse_entered.connect(func(): set_hovered(true))
	_panel.mouse_exited.connect(func(): set_hovered(false))
	_panel.gui_input.connect(_on_panel_gui_input)
	
	_style_box = StyleBoxFlat.new()
	if is_capital:
		_style_box.bg_color = Color(0.065, 0.040, 0.050, 0.82) # Imperial lacquer shadow
		_style_box.border_color = Color(0.92, 0.82, 0.45, 0.90) # Bright gold border
		_style_box.set_border_width_all(2)
		_style_box.set_corner_radius_all(4)
	else:
		_style_box.bg_color = Color(0.065, 0.075, 0.095, 0.78) # Charcoal lacquer
		_style_box.border_color = Color(0.78, 0.65, 0.32, 0.85) # Antique gold/bronze border
		_style_box.set_border_width_all(2)
		_style_box.set_corner_radius_all(4)
	
	_style_box.shadow_color = Color(0, 0, 0, 0.35)
	_style_box.shadow_size = 4
	_style_box.content_margin_left = 8
	_style_box.content_margin_right = 8
	_style_box.content_margin_top = 3
	_style_box.content_margin_bottom = 3
	_panel.add_theme_stylebox_override("panel", _style_box)

	_vbox = VBoxContainer.new()
	_vbox.add_theme_constant_override("separation", 2)
	_vbox.mouse_filter = Control.MOUSE_FILTER_PASS
	_panel.add_child(_vbox)

	# Title / Compact Nameplate (only content — no hover detail rows, STEP-04R5 §4)
	_title_label = Label.new()
	_title_label.add_theme_font_size_override("font_size", 12 if is_capital else 11)
	_title_label.add_theme_color_override("font_color", Color(1.0, 0.92, 0.65, 1.0) if is_capital else Color(0.92, 0.94, 0.98, 1.0))
	_title_label.add_theme_color_override("font_shadow_color", Color(0,0,0,0.95))
	_title_label.add_theme_constant_override("shadow_offset_x", 1)
	_title_label.add_theme_constant_override("shadow_offset_y", 1)
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_vbox.add_child(_title_label)

	add_child(_panel)
	_update_panel_position()

func _on_panel_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			badge_clicked.emit(structure_id)

func _update_panel_position() -> void:
	if _panel == null or not is_instance_valid(_panel):
		return
	var is_capital: bool = (structure_type == 1)
	# Always the compact nameplate anchor — hover must not move/resize it (§5)
	_panel.position = Vector2(-55 if not is_capital else -65, -34 if not is_capital else -38)

func _refresh_display() -> void:
	var is_capital: bool = (structure_type == 1)
	var sname: String = structure_name if structure_name != "" else (structure_id.replace("_", " "))
	if _title_label:
		var z_t: float = SemanticZoomCls.zoom_t(_current_zoom)
		_title_label.text = SemanticZoomCls.objective_label_text(sname, is_capital, z_t)
	_apply_hover_style()
	_update_panel_position()

func get_badge_info() -> Dictionary:
	return {
		"structure_id": structure_id,
		"structure_type": "CAPITAL" if structure_type == 1 else "FORTRESS",
		"structure_name": structure_name,
		"owner": owner_faction,
		"fortification_hp": fortification_hp,
		"fortification_hp_max": fortification_hp_max,
		"breached": breached,
		"garrison_count": garrison_count,
		"garrison_max": garrison_max,
		"is_objective": is_objective,
		"current_zoom": _current_zoom,
		"badge_scale": _current_scale.x,
		"is_selected": is_selected,
		"is_hovered": is_hovered
	}
