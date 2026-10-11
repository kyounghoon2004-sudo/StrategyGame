extends Node

## CIV3D HUD skin (VISUAL / LAYOUT ONLY): re-lays the battle HUD the shell
## already built into a Civ-style arrangement and one panel style, and adds a
## minimap. It finds the shell's controls by name and only changes their
## anchors, offsets, styles and visibility; every button keeps its signals and
## behaviour, and nothing here touches gameplay.
##
##   top       one full-width bar: status, turn stats, turn label, panel toggles,
##             help ("?" tooltip replaces the bottom hint bar)
##   left      orders dock (collapsible)      right   advisor dock
##   bottom-L  selected unit card             bottom-R  minimap + NEXT button
##   bottom-C  move / attack confirmation cards

const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")

const BAR_H := 40
const M := 8 # screen margin
const PANEL_BG := Color(0.075, 0.085, 0.105, 0.90)
const GOLD := Color(0.78, 0.64, 0.34)
const GOLD_DIM := Color(0.55, 0.45, 0.25)

var shell: Node = null
var view: Node = null
var hud: CanvasLayer = null
var _bar: Panel = null
var _orders_toggle: Button = null
var _minimap: Control = null
var _applied := false

func setup(p_shell: Node, p_view: Node) -> void:
	shell = p_shell
	view = p_view
	hud = shell.get("hud_layer") as CanvasLayer
	if hud == null:
		return
	hud.child_entered_tree.connect(func(_n): call_deferred("_restyle_late"))
	# the side docks and their buttons are created a moment after the battle opens
	get_tree().create_timer(0.6).timeout.connect(_apply)

# ------------------------------------------------------------------ styles

static func panel_style(border: Color = GOLD, radius: int = 6, width: int = 1) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = PANEL_BG
	s.border_color = border
	s.set_border_width_all(width)
	s.set_corner_radius_all(radius)
	s.shadow_color = Color(0, 0, 0, 0.45)
	s.shadow_size = 6
	s.content_margin_left = 6
	s.content_margin_right = 6
	return s

static func clear_style() -> StyleBoxEmpty:
	return StyleBoxEmpty.new()

func _find(name: String) -> Control:
	return hud.get_node_or_null(name) as Control

func _find_button_text(fragment: String) -> Button:
	for c in hud.get_children():
		if c is Button and (c as Button).text.contains(fragment):
			return c
	return null

static func _place(c: Control, preset: int, l: float, t: float, r: float, b: float) -> void:
	if c == null:
		return
	c.set_anchors_preset(preset)
	c.offset_left = l
	c.offset_top = t
	c.offset_right = r
	c.offset_bottom = b

# ------------------------------------------------------------------ layout

func _apply() -> void:
	# --- top bar -----------------------------------------------------------
	_bar = Panel.new()
	_bar.name = "CivTopBar"
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := panel_style(GOLD_DIM, 0, 0)
	sb.border_width_bottom = 2
	sb.border_color = GOLD
	sb.bg_color = Color(0.06, 0.065, 0.08, 0.94)
	_bar.add_theme_stylebox_override("panel", sb)
	_place(_bar, Control.PRESET_TOP_WIDE, 0, 0, 0, BAR_H)
	hud.add_child(_bar)
	hud.move_child(_bar, 0)

	var dbg := _find("DebugStatusPanel")
	_place(dbg, Control.PRESET_TOP_LEFT, M, 4, 372, BAR_H - 4)
	if dbg:
		dbg.add_theme_stylebox_override("panel", clear_style())
		var lbl := dbg.get_node_or_null("DebugLabel") as Label
		if lbl:
			lbl.add_theme_font_size_override("font_size", 11)
			lbl.add_theme_color_override("font_color", Color(GOLD_DIM, 0.85))

	var stats := _find("TopCommandHudBar")
	_place(stats, Control.PRESET_CENTER_TOP, -330, 0, 330, BAR_H)
	if stats:
		stats.add_theme_stylebox_override("panel", clear_style())
		for l in stats.find_children("*", "Label", true, false):
			var c: Color = (l as Label).get_theme_color("font_color")
			(l as Label).add_theme_color_override("font_color", Color(c.r, c.g, c.b, 1.0))
			(l as Label).add_theme_font_size_override("font_size", 14)

	var turn := _find("TurnPanel")
	_place(turn, Control.PRESET_TOP_RIGHT, -196, 3, -M, BAR_H - 3)
	if turn:
		turn.add_theme_stylebox_override("panel", panel_style(GOLD, 4))

	var advisor_btn := _find_button_text("전술 조언")
	var ai_btn := _find_button_text("AI 설정")
	_style_bar_button(advisor_btn)
	_style_bar_button(ai_btn)
	_place(ai_btn, Control.PRESET_TOP_RIGHT, -300, 6, -206, BAR_H - 6)
	_place(advisor_btn, Control.PRESET_TOP_RIGHT, -404, 6, -308, BAR_H - 6)

	_orders_toggle = Button.new()
	_orders_toggle.name = "CivOrdersToggle"
	_orders_toggle.text = "작전 명령"
	_orders_toggle.focus_mode = Control.FOCUS_NONE
	_orders_toggle.tooltip_text = "작전 명령 창 열기 / 닫기"
	_style_bar_button(_orders_toggle)
	_place(_orders_toggle, Control.PRESET_TOP_RIGHT, -508, 6, -412, BAR_H - 6)
	_orders_toggle.pressed.connect(_toggle_orders)
	hud.add_child(_orders_toggle)

	var help := Label.new()
	help.name = "CivHelp"
	help.text = "?"
	help.mouse_filter = Control.MOUSE_FILTER_STOP
	help.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	help.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	help.add_theme_font_size_override("font_size", 16)
	help.add_theme_color_override("font_color", GOLD)
	var hint := hud.find_child("CameraHint", true, false) as Label
	help.tooltip_text = hint.text.replace("  |  ", "\n") if hint else ""
	_place(help, Control.PRESET_TOP_RIGHT, -540, 6, -514, BAR_H - 6)
	hud.add_child(help)
	var bottom := _find("BottomHintPanel")
	if bottom:
		bottom.visible = false

	# --- side docks ---------------------------------------------------------
	_place(_find("LeftDock"), Control.PRESET_LEFT_WIDE, M, BAR_H + M, 344, -252)
	_place(_find("RightDock"), Control.PRESET_RIGHT_WIDE, -344, BAR_H + M, -M, -330)
	_place(_find("DevActionPanel"), Control.PRESET_RIGHT_WIDE, -336, BAR_H + M, -M, -M)
	for n in ["StrongholdPanel", "EnemyIntelPanel"]:
		var p := _find(n)
		if p:
			var h: float = p.offset_bottom - p.offset_top
			_place(p, Control.PRESET_TOP_RIGHT, -464, BAR_H + M, -M, BAR_H + M + h)
	_place(_find("CombatLogPanel"), Control.PRESET_CENTER_TOP, -340, BAR_H + 6, 340, BAR_H + 50)
	_place(_find("ReconReportPanel"), Control.PRESET_CENTER_TOP, -300, BAR_H + 56, 300, BAR_H + 140)

	# --- bottom row ----------------------------------------------------------
	_place(_find("UnitCardPanel"), Control.PRESET_BOTTOM_LEFT, M, -244, 448, -M)
	_place(_find("RouteCardPanel"), Control.PRESET_BOTTOM_RIGHT, -760, -163, -304, -M)
	_place(_find("AttackCardPanel"), Control.PRESET_BOTTOM_RIGHT, -760, -173, -304, -M)
	var next := _find("NextTurnButton") as Button
	_place(next, Control.PRESET_BOTTOM_RIGHT, -292, -92, -M - 4, -M - 4)
	_style_next(next)
	_minimap = preload("res://scripts/visual/civ3d/civ_minimap.gd").new()
	_minimap.call("setup", shell, view)
	_place(_minimap, Control.PRESET_BOTTOM_RIGHT, -292, -312, -M - 4, -100)
	hud.add_child(_minimap)

	_restyle_panels()
	_applied = true

func _restyle_panels() -> void:
	for n in ["UnitCardPanel", "RouteCardPanel", "StrongholdPanel", "EnemyIntelPanel", "CombatLogPanel", "ReconReportPanel", "PhaseBannerPanel"]:
		var p := _find(n)
		if p:
			p.add_theme_stylebox_override("panel", panel_style(GOLD, 6))
	var atk := _find("AttackCardPanel")
	if atk:
		atk.add_theme_stylebox_override("panel", panel_style(Color(0.72, 0.24, 0.18), 6))
	_skin_dock("LeftDock", "OrdersPanel", 40.0)
	_skin_dock("RightDock", "AdvisorWindow", 76.0)

func _restyle_late() -> void:
	# panels the shell creates later (battle / supply / trader) get the style too
	if not _applied:
		return
	for c in hud.get_children():
		if c is Panel and c != _bar and not String(c.name).begins_with("Civ") and c.get_theme_stylebox("panel") is StyleBoxFlat:
			var s := c.get_theme_stylebox("panel") as StyleBoxFlat
			if s.bg_color != PANEL_BG and c.name != "BottomHintPanel":
				c.add_theme_stylebox_override("panel", panel_style(GOLD, 6))
	var bottom := _find("BottomHintPanel")
	if bottom:
		bottom.visible = false

# ------------------------------------------------------------------ docks
## Orders / advisor docks: lacquer-and-gold look, and a real minimize - the
## panel's own collapse button now also shrinks the dock to its title row.

const LACQUER_RED := Color(0.42, 0.10, 0.08)
var _dock_full: Dictionary = {} # dock name -> [anchor_bottom, offset_bottom]

func _dock_theme() -> Theme:
	var t := Theme.new()
	var row := StyleBoxFlat.new()
	row.bg_color = Color(0, 0, 0, 0)
	row.content_margin_left = 8
	row.content_margin_top = 3
	row.content_margin_bottom = 3
	var row_h := row.duplicate() as StyleBoxFlat
	row_h.bg_color = Color(0.78, 0.64, 0.34, 0.14)
	row_h.border_color = GOLD
	row_h.border_width_bottom = 1
	var row_p := row_h.duplicate() as StyleBoxFlat
	row_p.bg_color = Color(0.42, 0.10, 0.08, 0.55)
	var row_d := row.duplicate() as StyleBoxFlat
	t.set_stylebox("normal", "Button", row)
	t.set_stylebox("hover", "Button", row_h)
	t.set_stylebox("pressed", "Button", row_p)
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	t.set_stylebox("disabled", "Button", row_d)
	t.set_color("font_color", "Button", Color(0.90, 0.86, 0.74))
	t.set_color("font_hover_color", "Button", Color(1.0, 0.92, 0.62))
	t.set_color("font_pressed_color", "Button", Color(1.0, 0.92, 0.62))
	t.set_color("font_disabled_color", "Button", Color(0.55, 0.52, 0.45))
	t.set_font_size("font_size", "Button", 13)
	t.set_color("font_color", "Label", Color(0.90, 0.86, 0.74))
	var field := StyleBoxFlat.new()
	field.bg_color = Color(0.04, 0.045, 0.05, 0.9)
	field.border_color = GOLD_DIM
	field.set_border_width_all(1)
	field.set_corner_radius_all(3)
	field.content_margin_left = 6
	t.set_stylebox("normal", "LineEdit", field)
	t.set_stylebox("normal", "TextEdit", field)
	var sep := StyleBoxLine.new()
	sep.color = Color(GOLD_DIM, 0.7)
	sep.thickness = 1
	t.set_stylebox("separator", "HSeparator", sep)
	return t

func _skin_dock(dock_name: String, panel_name: String, collapsed_h: float) -> void:
	var dock := _find(dock_name)
	if dock == null:
		return
	var frame := StyleBoxFlat.new()
	frame.bg_color = Color(0.055, 0.06, 0.07, 0.93)
	frame.border_color = GOLD
	frame.set_border_width_all(1)
	frame.border_width_top = 3 # lacquer-red title band edge reads as a seal ribbon
	frame.set_corner_radius_all(4)
	frame.shadow_color = Color(0, 0, 0, 0.5)
	frame.shadow_size = 8
	frame.expand_margin_left = 1
	frame.expand_margin_right = 1
	dock.add_theme_stylebox_override("panel", frame)
	dock.theme = _dock_theme()
	var panel := dock.find_child(panel_name, true, false) as Control
	if panel == null:
		return
	var inner := StyleBoxFlat.new()
	inner.bg_color = Color(0, 0, 0, 0)
	inner.border_color = Color(GOLD_DIM, 0.6)
	inner.set_border_width_all(1)
	inner.set_corner_radius_all(3)
	inner.content_margin_left = 8
	inner.content_margin_right = 8
	inner.content_margin_top = 6
	inner.content_margin_bottom = 6
	panel.add_theme_stylebox_override("panel", inner)
	var btn: Button = panel.get("_collapse_btn")
	if btn == null:
		return
	# the collapse control reads as a small seal button
	var seal := StyleBoxFlat.new()
	seal.bg_color = LACQUER_RED
	seal.border_color = GOLD
	seal.set_border_width_all(1)
	seal.set_corner_radius_all(3)
	seal.content_margin_left = 7
	seal.content_margin_right = 7
	var seal_h := seal.duplicate() as StyleBoxFlat
	seal_h.bg_color = Color(0.58, 0.16, 0.12)
	btn.add_theme_stylebox_override("normal", seal)
	btn.add_theme_stylebox_override("hover", seal_h)
	btn.add_theme_stylebox_override("pressed", seal_h)
	btn.add_theme_color_override("font_color", Color(1.0, 0.92, 0.70))
	btn.tooltip_text = "창 최소화 / 펼치기"
	_dock_full[dock_name] = [dock.anchor_bottom, dock.offset_bottom, panel.custom_minimum_size]
	btn.pressed.connect(_on_dock_collapse.bind(dock_name, panel_name, collapsed_h), CONNECT_DEFERRED)
	_sync_dock(dock_name, panel_name, collapsed_h)

func _on_dock_collapse(dock_name: String, panel_name: String, collapsed_h: float) -> void:
	_sync_dock(dock_name, panel_name, collapsed_h)

## Shrinks the dock to the title row while its panel is collapsed.
func _sync_dock(dock_name: String, panel_name: String, collapsed_h: float) -> void:
	var dock := _find(dock_name)
	if dock == null:
		return
	var panel := dock.find_child(panel_name, true, false) as Control
	var collapsed: bool = bool(panel.get("_collapsed")) if panel else false
	var btn: Button = panel.get("_collapse_btn") if panel else null
	if btn:
		btn.text = "▸" if collapsed else "▾"
	var full: Array = _dock_full.get(dock_name, [1.0, dock.offset_bottom, Vector2.ZERO])
	if collapsed:
		# the panel's own minimum height would hold the dock open
		if panel:
			panel.custom_minimum_size = Vector2((full[2] as Vector2).x, 0.0)
		dock.anchor_bottom = 0.0
		dock.offset_bottom = dock.offset_top + collapsed_h
	else:
		if panel:
			panel.custom_minimum_size = full[2]
		dock.anchor_bottom = full[0]
		dock.offset_bottom = full[1]

func _style_bar_button(b: Button) -> void:
	if b == null:
		return
	var n := panel_style(GOLD_DIM, 4)
	n.shadow_size = 0
	var h := n.duplicate() as StyleBoxFlat
	h.border_color = GOLD
	h.bg_color = Color(0.14, 0.13, 0.11, 0.95)
	b.add_theme_stylebox_override("normal", n)
	b.add_theme_stylebox_override("hover", h)
	b.add_theme_stylebox_override("pressed", h)
	b.add_theme_font_size_override("font_size", 13)
	b.add_theme_color_override("font_color", Color(0.93, 0.88, 0.74))

func _style_next(b: Button) -> void:
	if b == null:
		return
	var n := StyleBoxFlat.new()
	n.bg_color = Color(0.34, 0.24, 0.10, 0.96)
	n.border_color = Color(0.95, 0.80, 0.42)
	n.set_border_width_all(2)
	n.set_corner_radius_all(14)
	n.shadow_color = Color(0, 0, 0, 0.5)
	n.shadow_size = 8
	var h := n.duplicate() as StyleBoxFlat
	h.bg_color = Color(0.46, 0.33, 0.13, 1.0)
	var d := n.duplicate() as StyleBoxFlat
	d.bg_color = Color(0.18, 0.16, 0.13, 0.9)
	d.border_color = GOLD_DIM
	b.add_theme_stylebox_override("normal", n)
	b.add_theme_stylebox_override("hover", h)
	b.add_theme_stylebox_override("pressed", h)
	b.add_theme_stylebox_override("disabled", d)
	b.add_theme_font_size_override("font_size", 17)
	b.add_theme_color_override("font_color", Color(1.0, 0.94, 0.78))

func _toggle_orders() -> void:
	var d := _find("LeftDock")
	if d:
		d.visible = not d.visible

func set_active(on: bool) -> void:
	if _bar:
		_bar.visible = on
	if _minimap:
		_minimap.visible = on
