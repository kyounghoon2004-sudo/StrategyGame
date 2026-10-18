class_name Step7DetIntegration
extends Node

## Deterministic Step 7 host (reset milestone).
## Adapter around the accepted Step 2R shell: the shell and UnitManager
## stay authoritative; this node only owns WorldTruth, the deterministic
## ActionService, a DEV-ONLY manual test panel, and a plan preview overlay.
## Zero inference. Zero gameplay MCP. Zero model config. Zero memory files.

const TruthScript = preload("res://scripts/step7/step7_world_truth.gd")
const CommandServiceScript = preload("res://scripts/step7/step7_battle_command_service.gd")
const ProjectorScript = preload("res://scripts/step7/step7_observation_projector.gd")
const BlueServiceScript = preload("res://scripts/step7/step7_blue_knowledge_service.gd")
const RedServiceScript = preload("res://scripts/step7/step7_red_knowledge_service.gd")
const ActionCommandScript = preload("res://scripts/step7/step7_action_command.gd")
const ActionServiceScript = preload("res://scripts/step7/step7_action_service.gd")
const ClustersScript = preload("res://scripts/step7/step7_formation_clusters.gd")
const SectorOverlayScript = preload("res://scripts/step7/step7_sector_overlay.gd")
const DevModeScript = preload("res://scripts/step7/step7_dev_mode.gd")
const AdvisorWindowScript = preload("res://scripts/step7/step7_advisor_window.gd")
const AdvisorAdapterScript = preload("res://scripts/step7/step7_advisor_adapter.gd")
const OrdersPanelScript = preload("res://scripts/step7/step7_orders_panel.gd")
const AISSetupPanelScript = preload("res://scripts/ai/ai_setup_panel.gd")
const AIBackendCfgScript = preload("res://scripts/ai/ai_backend_config.gd")


class PreviewOverlay:
	extends Node2D
	var routes: Array = []
	func set_routes(value: Array) -> void:
		routes = value
		queue_redraw()
	func _draw() -> void:
		var line := Color(0.35, 0.75, 1.0, 0.95)
		var fill := Color(0.35, 0.75, 1.0, 0.35)
		for r_val in routes:
			if not r_val is Dictionary:
				continue
			var cells: Array = (r_val as Dictionary).get("path_cells", [])
			if cells.is_empty():
				continue
			var pts := PackedVector2Array()
			for c in cells:
				if c is Array and (c as Array).size() == 2:
					pts.append(HexUtils.hex_to_pixel(int((c as Array)[0]), int((c as Array)[1])))
			if pts.size() >= 2:
				draw_polyline(pts, line, 3.0, true)
			if not pts.is_empty():
				draw_circle(pts[pts.size() - 1], 9.0, fill)
				draw_arc(pts[pts.size() - 1], 9.0, 0.0, TAU, 20, line, 2.0)


var shell: Node = null
var unit_manager: RefCounted = null
var hex_grid: Node = null
var hud_layer: CanvasLayer = null

var truth: RefCounted = null
var command_service: RefCounted = null
var projector: RefCounted = null
var blue_service: RefCounted = null
var red_service: RefCounted = null
var action_service: RefCounted = null
var overlay: Node2D = null

var ready_for_step7 := false

var _panel: PanelContainer = null
var _panel_body: VBoxContainer = null
var _toggle_button: Button = null
var _status_labels: Dictionary = {}
var _unit_label: Label = null
var _q_edit: LineEdit = null
var _r_edit: LineEdit = null
var _preview_plan_id := ""
var _execute_button: Button = null
var _custom_action: OptionButton = null
var _custom_scope: OptionButton = null
var _custom_scope_value: LineEdit = null
var _custom_dir: OptionButton = null
var _custom_target_kind: OptionButton = null
var _custom_target_value: LineEdit = null
var _panel_root: VBoxContainer = null
var _browser_box: VBoxContainer = null
var _browser_toggle: Button = null
var _cat_scroll: ScrollContainer = null
var _cat_list: VBoxContainer = null
var _cat_expanded: Dictionary = {}
var _cat_body: Dictionary = {}
var _cat_header: Dictionary = {}
var _preset_buttons: Dictionary = {}
var _preset_rows: Dictionary = {}
var _selected_preset_id := ""
var _footer_box: VBoxContainer = null
var _sel_label: Label = null

# Adaptive tactical clusters (DEV): world-anchored band overlay + inspection.
# Geometry freezes at friendly turn start (ensure_turn in _process); units
# move against the frozen map mid-turn. Node name kept for scene compat.
var sector_overlay: Node2D = null
var _sector_toggle_btn: Button = null
var _sector_info: Label = null
var _sector_members: Label = null
var _sector_poll := 0.0
var _cluster_btn_row: HBoxContainer = null
var _cluster_sig_shown := ""

# PLAYER vs DEV (§2): DEV tools stay intact but hidden in PLAYER mode.
# The Advisor window is the player-facing tactical surface in both modes.
var _advisor_toggle_btn: Button = null
var _ai_settings_btn: Button = null
var _ai_setup_panel = null # AISSetupPanel (in-battle adjust mode)
var _advisor_window = null # Step7AdvisorWindow
var _advisor_adapter: Node = null # Step7AdvisorAdapter
var _advisor_last_sel_id := "@@init@@"
var _advisor_last_turn := -9999
# Player docks: orders on the LEFT, advisor on the RIGHT.
var _right_dock: PanelContainer = null
var _left_dock: PanelContainer = null
var _orders_panel = null # Step7OrdersPanel
var _left_tab_btn: Button = null
var _right_tab_btn: Button = null
var _dock_user_closed := {"left": false, "right": false}
var _overlay_dev_on := false
var _overlay_advisor_on := false


func _ready() -> void:
	call_deferred("_bootstrap")


func _bootstrap() -> void:
	for _i in range(8):
		shell = get_parent()
		if shell and shell.get("unit_manager") != null and shell.get("hud_layer") != null:
			break
		await get_tree().process_frame
	if shell == null:
		return
	unit_manager = shell.get("unit_manager") as RefCounted
	hex_grid = shell.get("hex_grid") as Node
	hud_layer = shell.get("hud_layer") as CanvasLayer
	var fog: RefCounted = shell.get("_fog") as RefCounted
	if unit_manager == null or hex_grid == null or hud_layer == null:
		push_warning("[Step7Det] shell dependencies unavailable; staying disabled")
		return
	truth = TruthScript.new()
	if not truth.configure(shell):
		push_warning("[Step7Det] world truth unavailable; staying disabled")
		return
	command_service = CommandServiceScript.new()
	command_service.configure(shell, unit_manager, hex_grid)
	# The shell's human click handlers use this same service when available.
	shell.set("_battle_command_service", command_service)
	projector = ProjectorScript.new()
	projector.configure(unit_manager, fog, hex_grid.get("cell_data") as Dictionary, null, _projected_strongholds())
	blue_service = BlueServiceScript.new()
	blue_service.configure(projector)
	red_service = RedServiceScript.new()
	red_service.configure(projector)
	command_service.projector = projector
	action_service = ActionServiceScript.new()
	action_service.configure(truth, command_service, unit_manager, Callable(shell, "execute_step7_move"))
	action_service.connect("execution_progress", Callable(self, "_on_execution_progress"))
	action_service.connect("execution_finished", Callable(self, "_on_execution_finished"))
	overlay = PreviewOverlay.new()
	overlay.name = "Step7DetPreviewOverlay"
	overlay.z_index = 20
	shell.add_child(overlay)
	sector_overlay = SectorOverlayScript.new()
	sector_overlay.name = "Step7SectorOverlay"
	sector_overlay.z_index = 16
	shell.add_child(sector_overlay)
	# Manual-backend milestone: direct-scene boots (editor/headless) still
	# get the last safe endpoint/model. In-run values are preserved because
	# the safe file already holds them; the API key is never restored.
	AIBackendCfgScript.ensure_boot_runtime()
	_build_panel()
	_build_right_dock()
	_build_ai_settings_button()
	_apply_dev_visibility()
	ready_for_step7 = true
	print("[Step7Det] deterministic action service ready | version=%d | mode=%s" % [truth.get_version(), DevModeScript.mode_name()])


# --- DEV-ONLY cavalry tactical section (SB-CAVALRY-EVALUATOR pilot) -----------
# Guarded load: headless probes and old scenes boot fine without the panel.
func _build_cavalry_section() -> void:
	if not ResourceLoader.exists("res://scripts/step7/step7_cavalry_panel.gd"):
		return
	var CavPanelScript: Script = load("res://scripts/step7/step7_cavalry_panel.gd")
	var section: VBoxContainer = CavPanelScript.new()
	_cat_list.add_child(HSeparator.new())
	_cat_list.add_child(section)
	section.setup({
		"integration": self, "truth": truth, "command_service": command_service,
		"projector": projector, "action_service": action_service,
		"overlay": overlay, "unit_manager": unit_manager})


func get_blue_knowledge() -> Dictionary:
	if blue_service:
		return blue_service.build(int(truth.get_turn()) if truth else 1)
	return {"side": "blue"}


# --- DEV-ONLY adaptive cluster section (L*/C/R* + macro wings) ---------------
func _build_sector_section() -> void:
	_cat_list.add_child(HSeparator.new())
	var head := Label.new()
	head.text = "TACTICAL CLUSTERS (DEV)"
	head.add_theme_font_size_override("font_size", 13)
	_cat_list.add_child(head)
	_sector_toggle_btn = Button.new()
	_sector_toggle_btn.text = "TACTICAL CLUSTERS: OFF"
	_sector_toggle_btn.pressed.connect(_on_sector_toggle)
	_cat_list.add_child(_sector_toggle_btn)
	var refresh_btn := Button.new()
	refresh_btn.text = "REBUILD CLUSTERS (next-turn geometry)"
	refresh_btn.tooltip_text = "Recompute bands from CURRENT positions. Mid-turn use breaks the freeze contract; it simulates next-turn refresh."
	refresh_btn.pressed.connect(_on_cluster_refresh)
	_cat_list.add_child(refresh_btn)
	_cluster_btn_row = HBoxContainer.new()
	_cluster_btn_row.add_theme_constant_override("separation", 4)
	_cat_list.add_child(_cluster_btn_row)
	_rebuild_cluster_buttons()
	var macro := HBoxContainer.new()
	macro.add_theme_constant_override("separation", 4)
	_cat_list.add_child(macro)
	for w in ["LEFT ALL", "CENTER", "RIGHT ALL", "EXTREME LEFT", "EXTREME RIGHT"]:
		var b := Button.new()
		b.text = w
		b.custom_minimum_size = Vector2(0, 26)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var wing_name: String = w
		b.pressed.connect(func() -> void: _on_wing_inspect(wing_name))
		macro.add_child(b)
	_sector_info = Label.new()
	_sector_info.add_theme_font_size_override("font_size", 11)
	_sector_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_sector_info.text = "Clusters: not built yet."
	_cat_list.add_child(_sector_info)
	_sector_members = Label.new()
	_sector_members.add_theme_font_size_override("font_size", 11)
	_sector_members.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_sector_members.text = "Cavalry membership: press a cluster."
	_cat_list.add_child(_sector_members)


## Dynamic cluster buttons (§20): regenerated when the frozen signature
## changes (turn refresh). Compact; scrolls with the panel.
func _rebuild_cluster_buttons() -> void:
	if _cluster_btn_row == null:
		return
	for c in _cluster_btn_row.get_children():
		c.queue_free()
	for cid in ClustersScript.cluster_ids():
		var b := Button.new()
		b.text = str(cid)
		b.custom_minimum_size = Vector2(0, 26)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var cluster_name: String = str(cid)
		b.pressed.connect(func() -> void: _on_sector_inspect(cluster_name))
		_cluster_btn_row.add_child(b)
	_cluster_sig_shown = ClustersScript.frozen_signature()


func _blue_live_units() -> Array:
	var out: Array = []
	if unit_manager == null or not unit_manager.has_method("get_all_units_including_garrisoned"):
		return out
	for u_val in unit_manager.get_all_units_including_garrisoned():
		if u_val is Dictionary and str((u_val as Dictionary).get("faction", "")) == "blue":
			out.append(u_val)
	return out


func _on_cluster_refresh() -> void:
	if unit_manager == null:
		return
	var turn := 1
	if unit_manager.has_method("get_current_turn"):
		turn = int(unit_manager.get_current_turn())
	ClustersScript.refresh(_blue_live_units(), turn)
	_rebuild_cluster_buttons()
	_refresh_cluster_labels()


func _refresh_cluster_labels() -> void:
	if unit_manager == null:
		return
	var parts: Array = []
	for cid in ClustersScript.cluster_ids():
		var members: Array = ClustersScript.resolve_cluster_class(str(cid), "CAVALRY", "blue", unit_manager)
		parts.append("%s:[%s]" % [str(cid), ",".join(_ids_of(members)) if not members.is_empty() else "—"])
	_sector_members.text = "Cavalry by cluster: " + (" | ".join(parts) if not parts.is_empty() else "(none)")


func _ids_of(members: Array) -> Array:
	var ids: Array = []
	for m in members:
		ids.append(str((m as Dictionary).get("id", "")))
	ids.sort()
	return ids


func _on_sector_toggle() -> void:
	if sector_overlay == null:
		return
	_overlay_dev_on = not (_overlay_dev_on or _overlay_advisor_on)
	_apply_overlay_visibility()


func _set_sector_show(v: bool) -> void:
	# DEV-sourced overlay request (toggle button, scope inspection).
	_overlay_dev_on = v
	_apply_overlay_visibility()


## Player overlay contract (§13): the cluster heatmap is OFF by default and
## shows while DEV explicitly enables it OR the Advisor requests it.
## Advisor close/toggle-off clears only the advisor source.
func request_tactical_overlay(want: bool, source: String) -> void:
	if source == "advisor":
		_overlay_advisor_on = want
	else:
		_overlay_dev_on = want
	_apply_overlay_visibility()


func _apply_overlay_visibility() -> void:
	var eff := _overlay_dev_on or _overlay_advisor_on
	if sector_overlay != null:
		sector_overlay.call("set_show", eff)
	if _sector_toggle_btn != null:
		_sector_toggle_btn.text = "TACTICAL CLUSTERS: ON" if eff else "TACTICAL CLUSTERS: OFF"
	if _advisor_window != null and _advisor_window.has_method("set_overlay_state"):
		_advisor_window.set_overlay_state(_overlay_advisor_on)


func _on_sector_inspect(cluster_name: String) -> void:
	if unit_manager == null:
		return
	var members: Array = ClustersScript.resolve_cluster_class(cluster_name, "CAVALRY", "blue", unit_manager)
	_show_members(cluster_name, members)


func _on_wing_inspect(wing_label: String) -> void:
	if unit_manager == null:
		return
	var wing := wing_label.replace(" ALL", "").replace("EXTREME ", "EXTREME_")
	var members: Array = []
	if wing in ["EXTREME_LEFT", "EXTREME_RIGHT"]:
		var extreme := ClustersScript.extreme_left() if wing == "EXTREME_LEFT" else ClustersScript.extreme_right()
		if extreme.is_empty():
			_sector_members.text = "%s: no live band on that side." % wing_label
			return
		members = ClustersScript.resolve_cluster_class(extreme, "CAVALRY", "blue", unit_manager)
		_show_members(extreme, members)
		return
	members = ClustersScript.resolve_wing_class(wing, "CAVALRY", "blue", unit_manager)
	_show_members(wing, members)


func _show_members(scope_name: String, members: Array) -> void:
	var ids: Array = []
	var cells: Array = []
	for m in members:
		ids.append(str((m as Dictionary).get("id", "")))
		cells.append(Vector2i(int((m as Dictionary).get("q", 0)), int((m as Dictionary).get("r", 0))))
	ids.sort()
	_sector_members.text = "%s + CAVALRY -> [%s]" % [scope_name, ", ".join(ids) if not ids.is_empty() else "(empty scope)"]
	if sector_overlay:
		# Pressing a scope shows the heatmap: enable the overlay and
		# highlight that scope's cavalry. Toggle text stays in sync.
		_set_sector_show(true)
		sector_overlay.call("set_highlight", scope_name, cells)


func _process(_delta: float) -> void:
	if _sector_info == null or not ready_for_step7:
		return
	_poll_advisor_selection()
	# Turn-freeze contract (§17): rebuild bands only when the friendly turn
	# advanced (or nothing is frozen yet). Mid-turn moves never rebuild here;
	# membership below always reads CURRENT hexes vs the frozen map.
	if unit_manager != null and unit_manager.has_method("get_current_turn"):
		ClustersScript.ensure_turn(int(unit_manager.get_current_turn()), _blue_live_units())
	if _cluster_sig_shown != ClustersScript.frozen_signature():
		_rebuild_cluster_buttons()
		_refresh_cluster_labels()
	_sector_poll += _delta
	if _sector_poll < 0.25:
		return
	_sector_poll = 0.0
	var snap: Dictionary = ClustersScript.debug_snapshot()
	var stats: Dictionary = snap.get("stats", {})
	var lat: Dictionary = snap.get("latency", {})
	var sel_hex := Vector2i(-999, -999)
	if hex_grid and hex_grid.get("selected_hex") is Vector2i:
		sel_hex = hex_grid.get("selected_hex")
	var hex_txt := "Selected Hex: (—)"
	if sel_hex.x != -999:
		hex_txt = "Selected Hex: (%d,%d) s=%.2f Cluster: %s" % [sel_hex.x, sel_hex.y,
			ClustersScript.lateral_hex(sel_hex.x, sel_hex.y),
			ClustersScript.cluster_of_hex(sel_hex.x, sel_hex.y)]
	var unit_txt := "Selected Unit: (none)"
	if unit_manager and unit_manager.has_method("is_unit_selected") and bool(unit_manager.call("is_unit_selected")):
		var u: Dictionary = unit_manager.call("get_selected_unit")
		unit_txt = "Selected Unit: %s Class: %s Cluster: %s" % [str(u.get("id", "?")),
			str(u.get("class", "?")).to_upper(),
			ClustersScript.cluster_of_unit(u)]
	var cl_parts: Array = []
	for c in (snap.get("clusters", []) as Array):
		cl_parts.append("%s(μ%.1f,n%d)" % [str((c as Dictionary).get("id", "?")),
			float((c as Dictionary).get("centroid", 0.0)),
			((c as Dictionary).get("anchor_ids", []) as Array).size()])
	_sector_info.text = "%s\n%s\nBands T%d [%s] thr=%.2f med=%.2f mad*=%.2f | build %.1fms" % [hex_txt, unit_txt,
		int(snap.get("frozen_turn", -1)), " ".join(cl_parts),
		float(stats.get("split_threshold", 0.0)), float(stats.get("median_gap", 0.0)),
		float(stats.get("mad_scaled", 0.0)), float(lat.get("total_ms", 0.0))]


func _projected_strongholds() -> Array:
	if shell != null and shell.get("_stronghold_cells") is Dictionary:
		return []
	return []


# --- DEV-ONLY manual test panel -------------------------------------------
# Small, right-edge, hidden behind one toggle. Never production UI.

func _build_panel() -> void:
	_toggle_button = Button.new()
	_toggle_button.text = "DEV ACTIONS"
	_toggle_button.add_theme_font_size_override("font_size", 12)
	_toggle_button.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_toggle_button.position = Vector2(-120, 40)
	_toggle_button.custom_minimum_size = Vector2(112, 28)
	_toggle_button.pressed.connect(_on_dev_panel_toggle)
	hud_layer.add_child(_toggle_button)
	_panel = PanelContainer.new()
	_panel.name = "DevActionPanel"
	# Responsive right-edge dock: pinned to the right viewport edge, spanning
	# full height. Containers + ScrollContainer absorb resizing; no fixed rect.
	_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_panel.anchor_bottom = 1.0
	_panel.offset_left = -336
	_panel.offset_right = -8
	_panel.offset_top = 64
	_panel.offset_bottom = -8
	_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_panel.custom_minimum_size = Vector2(288, 0)
	# PLAYER-mode boot (§4): the DEV panel starts closed in every mode.
	# DEV users reopen it via the DEV toggle (or F9); the toggle itself is
	# hidden in PLAYER mode by _apply_dev_visibility().
	_panel.visible = false
	hud_layer.add_child(_panel)
	_panel_root = VBoxContainer.new()
	_panel_root.add_theme_constant_override("separation", 4)
	_panel_root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_panel.add_child(_panel_root)
	# Keep the legacy alias alive for historical probes.
	_panel_body = _panel_root
	var header_row := HBoxContainer.new()
	header_row.add_theme_constant_override("separation", 4)
	_panel_root.add_child(header_row)
	var title := Label.new()
	title.text = "DEV ACTION PANEL (deterministic)"
	title.add_theme_font_size_override("font_size", 13)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.add_child(title)
	_browser_toggle = Button.new()
	_browser_toggle.text = "[–]"
	_browser_toggle.add_theme_font_size_override("font_size", 12)
	_browser_toggle.tooltip_text = "Collapse/expand the action browser"
	_browser_toggle.pressed.connect(_on_browser_toggle)
	header_row.add_child(_browser_toggle)
	# Scrollable middle: the only region allowed to grow. One vertical scroll
	# for all categories; no nested per-category scrolling.
	_browser_box = VBoxContainer.new()
	_browser_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_panel_root.add_child(_browser_box)
	_cat_scroll = ScrollContainer.new()
	_cat_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_cat_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cat_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_browser_box.add_child(_cat_scroll)
	_cat_list = VBoxContainer.new()
	_cat_list.add_theme_constant_override("separation", 2)
	_cat_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cat_scroll.add_child(_cat_list)
	var presets_by_group := {}
	for row in action_service.get_manual_presets():
		_preset_rows[str(row.get("id", "?"))] = row
		var g := str(row.get("group", "GENERAL"))
		if not presets_by_group.has(g):
			presets_by_group[g] = []
		(presets_by_group[g] as Array).append(row)
	for g in ActionCommandScript.preset_groups():
		if not presets_by_group.has(g):
			continue
		_add_category(g, presets_by_group[g])
	_add_category("CUSTOM", [])
	_build_cavalry_section()
	_build_sector_section()
	_panel_root.add_child(HSeparator.new())
	# Fixed footer: status diagnostics + shared execution controls.
	_footer_box = VBoxContainer.new()
	_footer_box.add_theme_constant_override("separation", 2)
	_panel_root.add_child(_footer_box)
	_sel_label = Label.new()
	_sel_label.text = "Selected: (none)"
	_sel_label.add_theme_font_size_override("font_size", 12)
	_footer_box.add_child(_sel_label)
	for key in ["action", "version", "validation", "resolved", "plan"]:
		var lab := Label.new()
		lab.add_theme_font_size_override("font_size", 12)
		lab.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_footer_box.add_child(lab)
		_status_labels[key] = lab
	var exec_row := HBoxContainer.new()
	exec_row.add_theme_constant_override("separation", 6)
	_footer_box.add_child(exec_row)
	_execute_button = Button.new()
	_execute_button.text = "[EXECUTE]"
	_execute_button.pressed.connect(_on_execute)
	exec_row.add_child(_execute_button)
	var cancel_btn := Button.new()
	cancel_btn.text = "[CANCEL]"
	cancel_btn.pressed.connect(_on_cancel)
	exec_row.add_child(cancel_btn)
	_set_status("action", "Action: (none)")
	_set_status("version", "State version: %d" % truth.get_version())
	_set_status("validation", "Validation: (none)")
	_set_status("resolved", "Resolved: (none)")
	_set_status("plan", "Plan: (none)")


## PLAYER vs DEV gate: exactly one policy source (Step7DevMode).
## PLAYER: DEV toggle + DEV panel stay hidden, player right dock shown.
## DEV: toggle visible; raw panel and player right dock are mutually
## exclusive (the dock cancels the orders armed plan when hidden).
func _apply_dev_visibility() -> void:
	var dev := DevModeScript.is_dev_mode()
	if _advisor_window != null and _advisor_window.has_method("refresh_mode"):
		_advisor_window.refresh_mode()
	if _toggle_button != null:
		_toggle_button.visible = dev
		_toggle_button.tooltip_text = "Deterministic DEV tools (F9: PLAYER/DEV 전환)"
	if not dev:
		if _panel != null:
			_panel.visible = false
		_set_player_docks_open(true)
	else:
		if _panel != null and bool(_panel.visible):
			_set_player_docks_open(false)
		else:
			_set_player_docks_open(true)


func _set_player_docks_open(open: bool) -> void:
	if _right_dock == null or _left_dock == null:
		return
	if not open and _orders_panel != null and _orders_panel.has_method("cancel_current"):
		_orders_panel.cancel_current()
	_right_dock.visible = open and not bool(_dock_user_closed.get("right", false))
	_left_dock.visible = open and not bool(_dock_user_closed.get("left", false))


## DEV toggle enforces mutual exclusivity with the player docks.
func _on_dev_panel_toggle() -> void:
	if _panel == null:
		return
	_panel.visible = not _panel.visible
	_set_player_docks_open(not bool(_panel.visible))


## Deliberate DEV path (§20): F9 flips PLAYER/DEV at runtime. Normal
## players never encounter it accidentally; no visible DEV affordance
## exists in PLAYER mode.
func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	if k.keycode == KEY_F9:
		var dev := DevModeScript.toggle()
		_apply_dev_visibility()
		print("[Step7Det] UI mode -> %s (F9)" % ("DEV" if dev else "PLAYER"))
		get_viewport().set_input_as_handled()


## Player docks: LEFT = orders (command panel), RIGHT = advisor.
## The left dock clears the top-left debug panel + advisor toggle
## (top 92) and the bottom-left unit card (bottom -300). The right dock
## keeps its top-64 / -120 strip and stays below gameplay popups.
func _build_right_dock() -> void:
	_advisor_toggle_btn = Button.new()
	_advisor_toggle_btn.text = "전술 조언"
	_advisor_toggle_btn.tooltip_text = "참모 전술 조언창 열기/닫기"
	_advisor_toggle_btn.add_theme_font_size_override("font_size", 12)
	_advisor_toggle_btn.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_advisor_toggle_btn.offset_left = 24
	_advisor_toggle_btn.offset_right = 164
	_advisor_toggle_btn.offset_top = 56
	_advisor_toggle_btn.offset_bottom = 84
	_advisor_toggle_btn.pressed.connect(_on_advisor_toggle)
	hud_layer.add_child(_advisor_toggle_btn)

	_left_dock = _make_side_dock("LeftDock", Control.PRESET_TOP_LEFT, 8, 344, 92, -300)
	_orders_panel = OrdersPanelScript.new()
	_orders_panel.embedded = true
	_left_dock.add_child(_orders_panel)
	_orders_panel.setup({
		"action_service": action_service, "unit_manager": unit_manager,
		"overlay": overlay, "shell": shell})

	_right_dock = _make_side_dock("RightDock", Control.PRESET_TOP_RIGHT, -344, -8, 64, -120)
	_advisor_window = AdvisorWindowScript.new()
	_advisor_window.embedded = true
	_advisor_window.visible = true
	_right_dock.add_child(_advisor_window)
	_lower_dock_below_popups()

	_advisor_adapter = AdvisorAdapterScript.new()
	add_child(_advisor_adapter)
	_advisor_adapter.setup({
		"integration": self, "truth": truth, "command_service": command_service,
		"projector": projector, "action_service": action_service,
		"overlay": overlay, "unit_manager": unit_manager, "window": _advisor_window})
	_advisor_window.bind(_advisor_adapter)
	_build_dock_tabs()
	_advisor_adapter.refresh_from_current_selection()
	_advisor_last_sel_id = _current_canonical_sel_id()
	_advisor_last_turn = _current_canonical_turn()


func _build_dock_tabs() -> void:
	_left_tab_btn = _make_dock_tab("LeftDockTabBtn", "+ 명령", Control.PRESET_TOP_LEFT, 8, 128, 92, 120, "left")
	_right_tab_btn = _make_dock_tab("RightDockTabBtn", "+ 조언", Control.PRESET_TOP_RIGHT, -128, -8, 64, 92, "right")
	if _orders_panel != null and _orders_panel.has_signal("close_requested"):
		_orders_panel.connect("close_requested", _on_left_dock_close_requested)
	if _advisor_window != null and _advisor_window.has_signal("close_requested"):
		_advisor_window.connect("close_requested", _on_right_dock_close_requested)


func _make_dock_tab(tab_name: String, text: String, preset: int, off_l: int, off_r: int, off_t: int, off_b: int, side: String) -> Button:
	var tab := Button.new()
	tab.name = tab_name
	tab.text = text
	tab.focus_mode = Control.FOCUS_NONE
	tab.set_anchors_preset(preset)
	tab.offset_left = off_l
	tab.offset_right = off_r
	tab.offset_top = off_t
	tab.offset_bottom = off_b
	tab.visible = false
	tab.pressed.connect(_on_dock_tab_pressed.bind(side))
	hud_layer.add_child(tab)
	return tab


func _on_left_dock_close_requested() -> void:
	set_left_dock_open(false)


func _on_right_dock_close_requested() -> void:
	set_right_dock_open(false)


func _on_dock_tab_pressed(side: String) -> void:
	if side == "left":
		set_left_dock_open(true)
	else:
		set_right_dock_open(true)


func set_left_dock_open(open: bool) -> void:
	if _left_dock == null:
		return
	if not open and _orders_panel != null and _orders_panel.has_method("cancel_current"):
		_orders_panel.cancel_current()
	_dock_user_closed["left"] = not open
	_left_dock.visible = open
	if _left_tab_btn != null:
		_left_tab_btn.visible = not open


func set_right_dock_open(open: bool) -> void:
	if _right_dock == null:
		return
	_dock_user_closed["right"] = not open
	_right_dock.visible = open
	if _right_tab_btn != null:
		_right_tab_btn.visible = not open


func _make_side_dock(dock_name: String, preset: int, off_l: int, off_r: int, off_t: int, off_b: int) -> PanelContainer:
	var dock := PanelContainer.new()
	dock.name = dock_name
	dock.set_anchors_preset(preset)
	if preset == Control.PRESET_TOP_RIGHT:
		dock.anchor_bottom = 1.0
		dock.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	else:
		dock.anchor_bottom = 1.0
		dock.grow_horizontal = Control.GROW_DIRECTION_END
	dock.offset_left = off_l
	dock.offset_right = off_r
	dock.offset_top = off_t
	dock.offset_bottom = off_b
	var dock_style := StyleBoxFlat.new()
	dock_style.bg_color = Color(0.05, 0.055, 0.07, 0.92)
	dock.add_theme_stylebox_override("panel", dock_style)
	hud_layer.add_child(dock)
	return dock


## Z-order: the player dock stays ABOVE the static bottom hint bar (so its
## footer buttons stay clickable) but BELOW gameplay popups that share the
## right strip — NEXT/END-TURN, route/attack cards, intel, stronghold,
## trader, combat banners. Those open above the dock instead of under it.
func _lower_dock_below_popups() -> void:
	if _right_dock == null or hud_layer == null:
		return
	var hint_idx := -1
	for i in range(hud_layer.get_child_count()):
		var ch := hud_layer.get_child(i)
		if ch is Control and str((ch as Control).name) == "BottomHintPanel":
			hint_idx = i
			break
	if hint_idx < 0:
		return
	hud_layer.move_child(_right_dock, hint_idx + 1)


func _current_canonical_sel_id() -> String:
	if unit_manager != null and unit_manager.has_method("is_unit_selected") \
		and bool(unit_manager.is_unit_selected()) \
		and unit_manager.has_method("get_selected_unit_id"):
		return str(unit_manager.get_selected_unit_id())
	return ""


func _current_canonical_turn() -> int:
	if unit_manager != null and unit_manager.has_method("get_current_turn"):
		return int(unit_manager.get_current_turn())
	return -1


## ONE SELECTION AUTHORITY (§3): the Advisor never owns selection. Every
## frame the canonical UnitManager selection id + turn is compared against
## the last Advisor state; any drift (click, deselect, NEXT, enemy phase,
## post-move auto-clear) refreshes the Advisor from current state. This
## cannot miss a transition the way a signal subscription can, and it
## costs one string/int compare per frame. Evaluation itself runs only on
## actual change while the window is open.
func _poll_advisor_selection() -> void:
	if _advisor_adapter == null or _advisor_window == null:
		return
	var cur := _current_canonical_sel_id()
	var turn := _current_canonical_turn()
	var turn_changed := turn != _advisor_last_turn
	var changed := cur != _advisor_last_sel_id or turn_changed
	_advisor_last_sel_id = cur
	_advisor_last_turn = turn
	if not changed:
		return
	# Embedded section: honor the dock chain too (dock hidden in DEV mode).
	if not bool(_advisor_window.is_visible_in_tree()):
		return
	if turn_changed:
		_advisor_adapter.notify_turn()
	else:
		_advisor_adapter.refresh_from_current_selection()


## In-battle AI settings (manual-backend milestone): the same AI
## configuration panel in adjust mode — endpoint/model/key editable without
## source changes or scene reload. Applying bumps the config identity, so
## in-flight old-config responses are discarded and new requests use the
## newly selected model.
func _build_ai_settings_button() -> void:
	_ai_settings_btn = Button.new()
	_ai_settings_btn.text = "AI 설정"
	_ai_settings_btn.tooltip_text = "AI 주소·모델·키 설정 (전투 중 변경 가능)"
	_ai_settings_btn.add_theme_font_size_override("font_size", 12)
	_ai_settings_btn.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_ai_settings_btn.offset_left = 172
	_ai_settings_btn.offset_right = 280
	_ai_settings_btn.offset_top = 56
	_ai_settings_btn.offset_bottom = 84
	_ai_settings_btn.pressed.connect(_on_ai_settings_pressed)
	hud_layer.add_child(_ai_settings_btn)


func _on_ai_settings_pressed() -> void:
	if _ai_setup_panel == null:
		_ai_setup_panel = AISSetupPanelScript.new()
		_ai_setup_panel.name = "AISetupPanelBattle"
		_ai_setup_panel.adjust_mode = true
		hud_layer.add_child(_ai_setup_panel)
		_ai_setup_panel.config_applied.connect(_on_ai_config_applied)
		_ai_setup_panel.panel_closed.connect(_on_ai_panel_closed)
	_ai_setup_panel.adjust_mode = true
	_ai_setup_panel.open()


func _on_ai_config_applied() -> void:
	if _advisor_adapter != null and _advisor_adapter.has_method("notify_ai_config_changed"):
		_advisor_adapter.notify_ai_config_changed()


func _on_ai_panel_closed() -> void:
	pass


func _on_advisor_toggle() -> void:
	if _advisor_window == null or _advisor_adapter == null:
		return
	_advisor_window.visible = not _advisor_window.visible
	# Open-after-selection (§4): always pull the CURRENT canonical
	# selection on open — never require another click to trigger a signal.
	if _advisor_window.visible:
		_advisor_last_sel_id = _current_canonical_sel_id()
		_advisor_last_turn = _current_canonical_turn()
		_advisor_adapter.refresh_from_current_selection()
	else:
		_advisor_adapter.notify_closed()


func _set_status(key: String, text: String) -> void:
	if _status_labels.has(key):
		(_status_labels[key] as Label).text = text


## Collapsible action browser (ChatGPT-sidebar interaction, DEV aesthetic).
## One vertical ScrollContainer for all categories; headers toggle only.

func _on_browser_toggle() -> void:
	_browser_box.visible = not _browser_box.visible
	_browser_toggle.text = "[+]" if not _browser_box.visible else "[–]"


func _add_category(group: String, rows: Array) -> void:
	var expanded: bool = group == "GENERAL"
	_cat_expanded[group] = expanded
	var head := Button.new()
	head.alignment = HORIZONTAL_ALIGNMENT_LEFT
	head.add_theme_font_size_override("font_size", 12)
	head.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.set_meta("preset_count", rows.size())
	head.tooltip_text = "Expand/collapse — never triggers an action"
	head.pressed.connect(_on_category_toggle.bind(group))
	_cat_header[group] = head
	_cat_list.add_child(head)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 2)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.visible = expanded
	_cat_body[group] = body
	_cat_list.add_child(body)
	for row in rows:
		if row is Dictionary:
			_add_preset_row(body, row)
	if group == "EXACT UNIT":
		_build_exact_unit_body(body)
	if group == "CUSTOM":
		_build_custom_body(body)
	_refresh_category_header(group)


func _refresh_category_header(group: String) -> void:
	if not _cat_header.has(group):
		return
	var mark := "▾" if bool(_cat_expanded.get(group, false)) else "▸"
	(_cat_header[group] as Button).text = "%s %s (%d)" % [mark, group, int((_cat_header[group] as Button).get_meta("preset_count", 0))]


func _on_category_toggle(group: String) -> void:
	if not _cat_body.has(group):
		return
	_cat_expanded[group] = not bool(_cat_expanded.get(group, false))
	(_cat_body[group] as VBoxContainer).visible = bool(_cat_expanded[group])
	_refresh_category_header(group)


func _add_preset_row(body: VBoxContainer, row: Dictionary) -> void:
	var pid := str(row.get("id", "?"))
	var b := Button.new()
	b.text = "    " + pid
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.add_theme_font_size_override("font_size", 11)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.tooltip_text = "Preview only — press [EXECUTE] below to run"
	b.pressed.connect(_on_preset_id.bind(pid))
	body.add_child(b)
	_preset_buttons[pid] = b


## Click row = preview/arm only. Template rows bind the live map selection
## (plus Q/R for the HEX template); nothing here executes.
func _on_preset_id(preset_id: String) -> void:
	if action_service != null and action_service.has_method("is_executing") and bool(action_service.is_executing()):
		_set_status("plan", "Plan: execution already in progress.")
		return
	if not _preset_rows.has(preset_id):
		return
	var row: Dictionary = _preset_rows[preset_id]
	var cmd := {}
	if ActionCommandScript.is_template_preset(row):
		var uid := ""
		if unit_manager != null and unit_manager.has_method("is_unit_selected") and bool(unit_manager.is_unit_selected()):
			uid = str((unit_manager.get_selected_unit() as Dictionary).get("id", ""))
		if uid.is_empty():
			_begin_ui_action(preset_id)
			_refresh_selected_label()
			_set_status("validation", "Validation: INVALID — select a friendly formation on the map first.")
			_set_status("resolved", "Resolved: 0")
			_set_status("plan", "Plan: NO_PLAN")
			_selected_preset_id = preset_id
			_refresh_preset_highlight()
			return
		if str(row.get("binding", "")) == "selected_unit_hex":
			if _q_edit == null or _r_edit == null or not _q_edit.text.is_valid_int() or not _r_edit.text.is_valid_int():
				_begin_ui_action(preset_id)
				_refresh_selected_label()
				_set_status("validation", "Validation: INVALID — Q and R must be integers.")
				_set_status("resolved", "Resolved: 0")
				_set_status("plan", "Plan: NO_PLAN")
				_selected_preset_id = preset_id
				_refresh_preset_highlight()
				return
			cmd = ActionCommandScript.bind_preset(row, uid, int(_q_edit.text), int(_r_edit.text))
		else:
			cmd = ActionCommandScript.bind_preset(row, uid)
	else:
		cmd = (row.get("command", {}) as Dictionary).duplicate(true)
	_on_preset(cmd)
	_selected_preset_id = preset_id
	_refresh_preset_highlight()


func _refresh_preset_highlight() -> void:
	for pid in _preset_buttons:
		(_preset_buttons[pid] as Button).modulate = Color(1.0, 0.88, 0.55) if pid == _selected_preset_id else Color.WHITE
	if _sel_label != null:
		_sel_label.text = "Selected: %s" % _selected_preset_id if not _selected_preset_id.is_empty() else "Selected: (none)"


## EXACT UNIT section body: map selection + Q/R target + template rows above.
## Q/R validation stays isolated to exact HEX movement.
func _build_exact_unit_body(body: VBoxContainer) -> void:
	_unit_label = Label.new()
	_unit_label.text = "Selected: (none)"
	_unit_label.add_theme_font_size_override("font_size", 12)
	body.add_child(_unit_label)
	var move_row := HBoxContainer.new()
	move_row.add_theme_constant_override("separation", 4)
	body.add_child(move_row)
	_q_edit = LineEdit.new()
	_q_edit.placeholder_text = "Q"
	_q_edit.custom_minimum_size = Vector2(56, 0)
	move_row.add_child(_q_edit)
	_r_edit = LineEdit.new()
	_r_edit.placeholder_text = "R"
	_r_edit.custom_minimum_size = Vector2(56, 0)
	move_row.add_child(_r_edit)
	var map_btn := Button.new()
	map_btn.text = "MAP"
	map_btn.tooltip_text = "Copy the shell map-click target hex into Q/R"
	map_btn.pressed.connect(_on_use_map_target)
	move_row.add_child(map_btn)
	var arm_btn := Button.new()
	arm_btn.text = "MOVE UNIT"
	arm_btn.pressed.connect(_on_arm_move)
	move_row.add_child(arm_btn)


## One button press = one panel transaction. Clear transient state first so a
## failed attempt can never leave a stale READY plan / armed plan id behind.
func _begin_ui_action(attempt_label: String) -> void:
	_preview_plan_id = ""
	if overlay != null:
		(overlay as PreviewOverlay).set_routes([])
	_set_status("action", "Action: %s" % attempt_label)
	_set_status("validation", "Validation: (working…)")
	_set_status("resolved", "Resolved: (working…)")
	_set_status("plan", "Plan: NO_PLAN")


func _on_preset(cmd: Dictionary) -> void:
	if action_service != null and action_service.has_method("is_executing") and bool(action_service.is_executing()):
		_set_status("plan", "Plan: execution already in progress.")
		return
	_begin_ui_action(ActionCommandScript.describe(cmd))
	_refresh_selected_label()
	var result: Dictionary = action_service.preview_action(cmd, "blue")
	_show_preview(cmd, result)


func _build_custom_body(body: VBoxContainer) -> void:
	_custom_action = OptionButton.new()
	for a in ["ADVANCE", "REPOSITION", "RETREAT", "WITHDRAW", "REGROUP", "PROTECT", "SCREEN", "RECON", "FLANK", "HOLD"]:
		_custom_action.add_item(a)
	body.add_child(_custom_action)
	var scope_row := HBoxContainer.new()
	scope_row.add_theme_constant_override("separation", 4)
	body.add_child(scope_row)
	_custom_scope = OptionButton.new()
	for sc in ["ALL", "CLASS", "UNIT"]:
		_custom_scope.add_item(sc)
	scope_row.add_child(_custom_scope)
	_custom_scope_value = LineEdit.new()
	_custom_scope_value.placeholder_text = "class or unit id"
	_custom_scope_value.custom_minimum_size = Vector2(140, 0)
	scope_row.add_child(_custom_scope_value)
	var dir_row := HBoxContainer.new()
	dir_row.add_theme_constant_override("separation", 4)
	body.add_child(dir_row)
	_custom_dir = OptionButton.new()
	for d in ["-", "NORTH", "SOUTH", "EAST", "WEST", "FORWARD", "BACK", "LEFT", "RIGHT", "NORTHEAST", "NORTHWEST", "SOUTHEAST", "SOUTHWEST", "CENTER", "HQ"]:
		_custom_dir.add_item(d)
	dir_row.add_child(_custom_dir)
	_custom_target_kind = OptionButton.new()
	for t in ["NONE", "HEX", "FORMATION", "HQ", "SUPPLY", "STRONGHOLD", "CENTER"]:
		_custom_target_kind.add_item(t)
	dir_row.add_child(_custom_target_kind)
	_custom_target_value = LineEdit.new()
	_custom_target_value.placeholder_text = "q,r or id (empty ok)"
	_custom_target_value.custom_minimum_size = Vector2(140, 0)
	body.add_child(_custom_target_value)
	var apply_btn := Button.new()
	apply_btn.text = "APPLY CUSTOM"
	apply_btn.pressed.connect(_on_apply_custom)
	body.add_child(apply_btn)


func _on_apply_custom() -> void:
	if action_service != null and action_service.has_method("is_executing") and bool(action_service.is_executing()):
		_set_status("plan", "Plan: execution already in progress.")
		return
	var action := str(_custom_action.get_item_text(_custom_action.selected))
	var scope := {"type": "ALL_AVAILABLE"}
	match str(_custom_scope.get_item_text(_custom_scope.selected)):
		"CLASS":
			scope = ActionCommandScript.scope_class(_custom_scope_value.text)
		"UNIT":
			scope = ActionCommandScript.scope_unit(_custom_scope_value.text)
	var dir := str(_custom_dir.get_item_text(_custom_dir.selected))
	if dir == "-":
		dir = ""
	var target := {}
	match str(_custom_target_kind.get_item_text(_custom_target_kind.selected)):
		"HEX":
			var parts := _custom_target_value.text.split(",")
			if parts.size() >= 2 and parts[0].strip_edges().is_valid_int() and parts[1].strip_edges().is_valid_int():
				target = ActionCommandScript.target_hex(int(parts[0].strip_edges()), int(parts[1].strip_edges()))
			else:
				target = {"type": "HEX"}
		"FORMATION":
			target = ActionCommandScript.target_formation(_custom_target_value.text)
		"HQ":
			target = ActionCommandScript.target_hq()
		"SUPPLY":
			target = ActionCommandScript.target_supply(_custom_target_value.text)
		"STRONGHOLD":
			target = ActionCommandScript.target_stronghold(_custom_target_value.text)
		"CENTER":
			target = ActionCommandScript.target_center()
	_begin_ui_action("CUSTOM %s" % action)
	_refresh_selected_label()
	var cmd := ActionCommandScript.make(action, scope, dir, target)
	var result: Dictionary = action_service.preview_action(cmd, "blue")
	_show_preview(cmd, result)


func _on_use_map_target() -> void:
	if shell != null and shell.get("_preview_target_hex") is Vector2i:
		var hex: Vector2i = shell.get("_preview_target_hex")
		if hex.x != -999:
			_q_edit.text = str(hex.x)
			_r_edit.text = str(hex.y)


func _on_arm_move() -> void:
	if action_service != null and action_service.has_method("is_executing") and bool(action_service.is_executing()):
		_set_status("plan", "Plan: execution already in progress.")
		return
	_begin_ui_action("MOVE (exact unit)")
	_refresh_selected_label()
	var uid := ""
	if unit_manager != null and unit_manager.has_method("is_unit_selected") and bool(unit_manager.is_unit_selected()):
		uid = str((unit_manager.get_selected_unit() as Dictionary).get("id", ""))
	if uid.is_empty():
		_set_status("validation", "Validation: INVALID — select a friendly formation on the map first.")
		_set_status("resolved", "Resolved: 0")
		_set_status("plan", "Plan: NO_PLAN")
		return
	if not _q_edit.text.is_valid_int() or not _r_edit.text.is_valid_int():
		_set_status("validation", "Validation: INVALID — Q and R must be integers.")
		_set_status("resolved", "Resolved: 0")
		_set_status("plan", "Plan: NO_PLAN")
		return
	var cmd := ActionCommandScript.move_preset(uid, int(_q_edit.text), int(_r_edit.text))
	var result: Dictionary = action_service.preview_action(cmd, "blue")
	_show_preview(cmd, result)


func _on_execute() -> void:
	if action_service != null and action_service.has_method("is_executing") and bool(action_service.is_executing()):
		_set_status("plan", "Exec: IN_PROGRESS — wait for the current formation queue.")
		return
	if _preview_plan_id.is_empty():
		_set_status("plan", "Plan: nothing to execute.")
		return
	_execute_armed_plan()


func _execute_armed_plan() -> void:
	var result: Dictionary = action_service.execute_plan(_preview_plan_id)
	_preview_plan_id = ""
	(overlay as PreviewOverlay).set_routes([])
	_render_execution_result(result)
	if str(result.get("execution_status", "")) == "IN_PROGRESS":
		if _execute_button:
			_execute_button.disabled = true
		_set_status("plan", "Exec: IN_PROGRESS — sequential formation queue active.")
		return
	_refresh_selected_label()


func _render_execution_result(result: Dictionary) -> void:
	var lines: Array = []
	lines.append("Exec: %s (replanned=%s)" % [str(result.get("execution_status", "?")), str(result.get("replanned", false))])
	lines.append("Version %s -> %s" % [str(result.get("previous_state_version", "?")), str(result.get("resulting_state_version", "?"))])
	lines.append("Executed %d / failed %d" % [(result.get("executed_units", []) as Array).size(), (result.get("failed_units", []) as Array).size()])
	for f in result.get("failed_units", []):
		if f is Dictionary:
			lines.append("FAIL %s — %s" % [str((f as Dictionary).get("unit_id", "?")), str((f as Dictionary).get("code", "?"))])
	_set_status("plan", "\n".join(lines))
	_set_status("version", "State version: %d" % truth.get_version())


func _on_execution_progress(progress: Dictionary) -> void:
	var row: Dictionary = progress.get("row", {}) as Dictionary
	_set_status("plan", "Exec: IN_PROGRESS — %d/%d %s %s" % [
		int(progress.get("completed_count", 0)),
		int(progress.get("candidate_count", 0)),
		str(progress.get("unit_id", "?")),
		str(progress.get("status", "?")),
	])
	if not row.is_empty() and str(row.get("code", "")).is_empty() == false:
		_set_status("resolved", "Last rejection: %s — %s" % [str(row.get("unit_id", "?")), str(row.get("code", "?"))])
	_set_status("version", "State version: %d" % int(progress.get("state_version", truth.get_version())))


func _on_execution_finished(result: Dictionary) -> void:
	if _execute_button:
		_execute_button.disabled = false
	_render_execution_result(result)
	_refresh_selected_label()


func _on_cancel() -> void:
	if action_service != null and action_service.has_method("is_executing") and bool(action_service.is_executing()):
		_set_status("plan", "Plan: execution is in progress and cannot be cancelled here.")
		return
	if not _preview_plan_id.is_empty():
		action_service.cancel_plan(_preview_plan_id)
		_preview_plan_id = ""
	(overlay as PreviewOverlay).set_routes([])
	_set_status("plan", "Plan: CANCELLED")


func _show_preview(cmd: Dictionary, result: Dictionary) -> void:
	_preview_plan_id = str(result.get("plan_id", ""))
	(overlay as PreviewOverlay).set_routes((result.get("routes", []) as Array).duplicate(true))
	_set_status("action", "Action: %s" % ActionCommandScript.describe(cmd))
	_set_status("version", "State version: %d" % int(result.get("state_version", -1)))
	if bool(result.get("ok", false)):
		var resolved: Array = result.get("resolved_units", [])
		var rejected: Array = result.get("rejected_units", [])
		_set_status("validation", "Validation: VALID")
		var class_count := {}
		for a in resolved:
			if a is Dictionary:
				var c := str((a as Dictionary).get("class", "?"))
				class_count[c] = int(class_count.get(c, 0)) + 1
		var names: Array = []
		for c in class_count.keys():
			names.append("%d %s" % [int(class_count[c]), str(c).to_lower()])
		_set_status("resolved", "Resolved: %d (%s) / Rejected: %d" % [resolved.size(), ", ".join(names), rejected.size()])
		var rej_lines: Array = []
		for r in rejected.slice(0, 6):
			if r is Dictionary:
				rej_lines.append("%s — %s" % [str((r as Dictionary).get("unit_id", "?")), str((r as Dictionary).get("code", "?"))])
		var plan_text := "Plan: READY (%s, %d routes)" % [str(result.get("plan_id", "?")), (result.get("routes", []) as Array).size()]
		if not rej_lines.is_empty():
			plan_text += "\n" + "\n".join(rej_lines)
		_set_status("plan", plan_text + "\n[PREVIEW on map] [EXECUTE] or [CANCEL]")
	else:
		var errs: Array = []
		for e in result.get("validation_errors", []):
			if e is Dictionary:
				errs.append("%s: %s" % [str((e as Dictionary).get("code", "?")), str((e as Dictionary).get("detail", ""))])
		_set_status("validation", "Validation: INVALID\n" + "\n".join(errs))
		var rej_lines: Array = []
		for r in (result.get("rejected_units", []) as Array).slice(0, 4):
			if r is Dictionary:
				rej_lines.append("%s — %s" % [str((r as Dictionary).get("unit_id", "?")), str((r as Dictionary).get("code", "?"))])
		_set_status("resolved", "Resolved: 0 / Rejected: %d" % (result.get("rejected_units", []) as Array).size())
		var plan_text := "Plan: NO_PLAN"
		if not rej_lines.is_empty():
			plan_text += "\n" + "\n".join(rej_lines)
		_set_status("plan", plan_text)


func _refresh_selected_label() -> void:
	var txt := "Selected: (none)"
	if unit_manager != null and unit_manager.has_method("is_unit_selected") and bool(unit_manager.is_unit_selected()):
		var u: Dictionary = unit_manager.get_selected_unit()
		txt = "Selected: %s (%s @ %d,%d)" % [str(u.get("id", "?")), str(u.get("class", "?")), int(u.get("q", 0)), int(u.get("r", 0))]
	_unit_label.text = txt
