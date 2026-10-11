class_name Cloud1Panel
extends Control

const ObsCls = preload("res://scripts/cloud1/cloud1_observation.gd")
const TableCls = preload("res://scripts/cloud1/cloud1_action_table.gd")
const CompilerCls = preload("res://scripts/cloud1/cloud1_compiler.gd")
const InspectorCls = preload("res://scripts/cloud1/cloud1_inspector.gd")
const ScopeAlgebraCls = preload("res://scripts/step7/step7_scope_algebra.gd")

## CLOUD-GENERAL STEP 1 --Human command UI (developer panel).
##
## The human issues operational commands through the SAME schema the future
## Cloud model will use (TableCls.make_command). Direct unit
## manipulation stays available only for debugging; the benchmark path is
## this shared interface. The panel renders inspector text + raw payload +
## compilation visibility (intent -> units -> per-unit outcomes).
##
## Live-shell wiring: add as a child of the battlefield shell and call bind()
## with the shell's SimController-equivalent authorities. Headless tests
## instantiate it with bind_sim() and drive refresh/preview/execute directly.

var _sim: RefCounted = null
var _selected_unit_id := ""

var _inspector_label: TextEdit
var _payload_label: TextEdit
var _result_label: TextEdit
var _action_opt: OptionButton
var _scope_opt: OptionButton
var _scope_arg: LineEdit
var _target_opt: OptionButton
var _target_arg: LineEdit
var _policy_opt: OptionButton
var _stance_opt: OptionButton
var _root: VBoxContainer
var _cols: HBoxContainer
var _form: GridContainer
var _compact := false
var _live := false
var _btn_preview: Button
var _btn_exec: Button

const PANEL_ACTIONS := ["ADVANCE", "HOLD", "WITHDRAW", "REPOSITION", "ATTACK", "FLANK", "RECON", "CONCENTRATE", "PRESSURE", "PURSUE", "SPREAD", "RESERVE"]
const PANEL_SCOPES := ["ALL_FRIENDLY", "ALL_COMBAT", "CLASS", "REGION", "FORMATION", "SELECTED", "UNITS"]
const PANEL_TARGETS := ["DIRECTION:FORWARD", "DIRECTION:BACKWARD", "DIRECTION:LEFT", "DIRECTION:RIGHT", "DIRECTION:NORTH", "DIRECTION:SOUTH", "DIRECTION:EAST", "DIRECTION:WEST", "ZONE:CENTER", "ZONE:HQ", "OBJECTIVE", "HEX", "FORMATION", "NONE"]
const PANEL_POLICIES := ["STANDARD"]
const PANEL_STANCES := ["CAUTIOUS", "BALANCED", "ASSERTIVE", "AGGRESSIVE"]


func _init() -> void:
	_build_ui()


func bind_sim(sim: RefCounted) -> void:
	_sim = sim
	refresh()


func set_selected_unit(unit_id: String) -> void:
	_selected_unit_id = unit_id.strip_edges().to_upper()


func supported_families() -> Array:
	return PANEL_ACTIONS.duplicate()


func current_observation() -> Dictionary:
	if _sim == null:
		return {}
	return ObsCls.build(_sim)


func current_catalog() -> Array:
	var obs := current_observation()
	if obs.is_empty() or not bool(obs.get("ok", false)):
		return []
	return TableCls.build_catalog(obs)


## Human reads: "what would the Cloud model know right now?"
func refresh() -> void:
	var obs := current_observation()
	if obs.is_empty() or not bool(obs.get("ok", false)):
		_inspector_label.text = "No observation: %s" % str(obs.get("error", "sim unavailable"))
		_payload_label.text = "{}"
		return
	var catalog := TableCls.build_catalog(obs)
	_inspector_label.text = InspectorCls.render_text(obs, catalog)
	_payload_label.text = InspectorCls.render_payload(obs)


var _custom_scope: Dictionary = {}


func set_custom_scope(scope: Dictionary) -> void:
	_custom_scope = scope.duplicate(true)


func clear_custom_scope() -> void:
	_custom_scope = {}


## Build the operational command from the panel selections (same schema).
func draft_command() -> Dictionary:
	var action := _selected(_action_opt, "ADVANCE")
	var scope: Dictionary = {}
	if not _custom_scope.is_empty():
		scope = _custom_scope.duplicate(true)
	else:
		var scope_kind := _selected(_scope_opt, "ALL_COMBAT")
		scope = {"kind": "ALL_COMBAT"}
		match scope_kind:
			"ALL_FRIENDLY":
				scope = TableCls.scope_all_friendly()
			"ALL_COMBAT":
				scope = TableCls.scope_all_combat()
			"CLASS":
				scope = TableCls.scope_class(_scope_arg.text if not _scope_arg.text.strip_edges().is_empty() else "INFANTRY")
			"REGION":
				scope = TableCls.scope_region(_scope_arg.text if not _scope_arg.text.strip_edges().is_empty() else "NORTH")
			"FORMATION":
				scope = TableCls.scope_formation(_scope_arg.text if not _scope_arg.text.strip_edges().is_empty() else "FIELD")
			"SELECTED":
				scope = TableCls.scope_selected()
			"UNITS":
				var ids: Array = []
				for part in _scope_arg.text.split(","):
					if not part.strip_edges().is_empty():
						ids.append(part)
				scope = TableCls.scope_units(ids if not ids.is_empty() else ["B_INF_1"])
	var target := _draft_target()
	# STEP 1 contract: SELECTED is a live map pointer — materialize it into an
	# explicit UNIT/UNITS scope at draft time so the shared representation is a
	# frozen set (changing the map selection cannot silently retarget a draft).
	scope = _materialize_selected(scope)
	return TableCls.make_command(action, scope, target, _selected(_stance_opt, "BALANCED"))


## Freeze any SELECTED atom/kind in the scope to explicit UNIT/UNITS ids using
## the current map selection. Non-SELECTED scopes pass through unchanged.
func _materialize_selected(scope: Dictionary) -> Dictionary:
	if _selected_unit_id.strip_edges().is_empty():
		return scope
	if scope.is_empty():
		return scope
	return ScopeAlgebraCls.bind_selected(scope, _selected_unit_id)


func preview_current() -> Dictionary:
	if _sim == null:
		return {"ok": false, "detail": "Panel is not bound."}
	var cmd := draft_command()
	var res := CompilerCls.plan(_sim, cmd, _selected_unit_id)
	_result_label.text = InspectorCls.render_compilation(res)
	return res


func execute_current() -> Dictionary:
	if _sim == null:
		return {"ok": false, "detail": "Panel is not bound."}
	var cmd := draft_command()
	var res := CompilerCls.execute(_sim, cmd, _selected_unit_id)
	_result_label.text = InspectorCls.render_compilation(res)
	refresh()
	return res


func export_cloud_view() -> String:
	## EXPORT CURRENT CLOUD VIEW --identical tactical content to the inspector.
	var obs := current_observation()
	if obs.is_empty():
		return "{}"
	return ObsCls.to_json(obs, true)


func _draft_target() -> Dictionary:
	var raw := _selected(_target_opt, "DIRECTION:FORWARD")
	if raw == "NONE":
		return {}
	if raw.begins_with("DIRECTION:"):
		return TableCls.target_direction(raw.trim_prefix("DIRECTION:"))
	if raw.begins_with("ZONE:"):
		return TableCls.target_zone(raw.trim_prefix("ZONE:"))
	if raw == "OBJECTIVE":
		return TableCls.target_objective()
	if raw == "HEX":
		var parts := _target_arg.text.split(",")
		if parts.size() >= 2 and parts[0].strip_edges().is_valid_int() and parts[1].strip_edges().is_valid_int():
			return TableCls.target_hex(int(parts[0]), int(parts[1]))
		return TableCls.target_zone("CENTER")
	if raw == "FORMATION":
		var uid := _target_arg.text.strip_edges()
		return TableCls.target_formation(uid if not uid.is_empty() else "R_INF_1")
	return {}


func _selected(opt: OptionButton, fallback: String) -> String:
	if opt == null or opt.item_count == 0:
		return fallback
	return opt.get_item_text(opt.selected)


func _build_ui() -> void:
	custom_minimum_size = Vector2(1280, 720)
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)
	_root = root
	var top := Label.new()
	top.text = "CLOUD STEP 1 --SHARED OBSERVATION + OPERATIONAL COMMAND (Human == Cloud interface)"
	root.add_child(top)
	var cols := HBoxContainer.new()
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(cols)
	_cols = cols
	_inspector_label = TextEdit.new()
	_inspector_label.custom_minimum_size = Vector2(620, 420)
	_inspector_label.editable = false
	_inspector_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(_inspector_label)
	_payload_label = TextEdit.new()
	_payload_label.custom_minimum_size = Vector2(620, 420)
	_payload_label.editable = false
	_payload_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(_payload_label)
	var form := GridContainer.new()
	form.columns = 8
	root.add_child(form)
	_form = form
	_action_opt = _make_opt(form, PANEL_ACTIONS)
	_scope_opt = _make_opt(form, PANEL_SCOPES)
	_scope_arg = LineEdit.new()
	_scope_arg.placeholder_text = "CLASS/FORMATION/UNITS arg"
	form.add_child(_scope_arg)
	_target_opt = _make_opt(form, PANEL_TARGETS)
	_target_arg = LineEdit.new()
	_target_arg.placeholder_text = "HEX q,r / FORMATION id"
	form.add_child(_target_arg)
	_policy_opt = _make_opt(form, PANEL_POLICIES)
	_policy_opt.visible = false
	_stance_opt = _make_opt(form, PANEL_STANCES)
	var btn_preview := Button.new()
	btn_preview.text = "Preview"
	btn_preview.pressed.connect(preview_current)
	form.add_child(btn_preview)
	_btn_preview = btn_preview
	var btn_exec := Button.new()
	btn_exec.text = "Execute"
	btn_exec.pressed.connect(execute_current)
	form.add_child(btn_exec)
	_btn_exec = btn_exec
	_result_label = TextEdit.new()
	_result_label.custom_minimum_size = Vector2(1280, 200)
	_result_label.editable = false
	root.add_child(_result_label)


func _make_opt(parent: Control, items: Array) -> OptionButton:
	var opt := OptionButton.new()
	for it in items:
		opt.add_item(str(it))
	parent.add_child(opt)
	return opt


## STEP 1B additive: compact dock layout for the live right-side panel.
## Default (headless-verified) layout is untouched unless this is called.
func set_compact(enabled: bool) -> void:
	_compact = enabled
	if not enabled:
		return
	custom_minimum_size = Vector2(0, 0)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_inspector_label.custom_minimum_size = Vector2(520, 300)
	_inspector_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_inspector_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_payload_label.custom_minimum_size = Vector2(520, 170)
	_payload_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_result_label.custom_minimum_size = Vector2(520, 240)
	_result_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_form.columns = 2
	# Stack the payload view under the inspector (narrow dock has no room
	# for side-by-side panes).
	if _payload_label.get_parent() == _cols:
		_cols.remove_child(_payload_label)
		_root.add_child(_payload_label)
		_root.move_child(_payload_label, 2)


func is_compact() -> bool:
	return _compact


## STEP 1B additive: live mode hides this panel's own synchronous
## Preview/Execute buttons. The live dock drives preview through
## Cloud1Compiler.plan and execution through the animated Cloud1LiveExecutor,
## so the sync headless path can never fire against the live battle.
func set_live_mode(enabled: bool) -> void:
	_live = enabled
	if _btn_preview != null:
		_btn_preview.visible = not enabled
	if _btn_exec != null:
		_btn_exec.visible = not enabled


func is_live_mode() -> bool:
	return _live


func get_selected_id() -> String:
	return _selected_unit_id


## Additive setters for the research-console dock: the dock owns its own
## builder widgets and mirrors values here so draft_command() remains the
## single drafting path. Headless defaults and behavior are unchanged.
func set_action(a: String) -> void:
	_pick_opt(_action_opt, a.strip_edges().to_upper())

func set_scope_kind(s: String) -> void:
	_pick_opt(_scope_opt, s.strip_edges().to_upper())

func set_scope_arg(t: String) -> void:
	_scope_arg.text = t

func set_target_kind(t: String) -> void:
	_pick_opt(_target_opt, t.strip_edges().to_upper())

func set_target_arg(t: String) -> void:
	_target_arg.text = t

func set_policy(p: String) -> void:
	_pick_opt(_policy_opt, p.strip_edges().to_upper())

func set_stance(s: String) -> void:
	_pick_opt(_stance_opt, s.strip_edges().to_upper())

func get_builder_state() -> Dictionary:
	return {
		"action": _selected(_action_opt, "ADVANCE"),
		"scope": _selected(_scope_opt, "ALL_COMBAT"),
		"scope_arg": _scope_arg.text,
		"target": _selected(_target_opt, "DIRECTION:FORWARD"),
		"target_arg": _target_arg.text,
		"policy": _selected(_policy_opt, "STANDARD"),
		"stance": _selected(_stance_opt, "BALANCED"),
	}

func _pick_opt(opt: OptionButton, want: String) -> void:
	if opt == null:
		return
	for i in range(opt.item_count):
		if opt.get_item_text(i) == want:
			opt.select(i)
			return


## Let the live dock drive preview/execute through the animated live path
## while reusing this panel's views and command drafting.
func show_result_text(t: String) -> void:
	_result_label.text = t


func get_result_view() -> TextEdit:
	return _result_label


func get_inspector_view() -> TextEdit:
	return _inspector_label


func get_payload_view() -> TextEdit:
	return _payload_label
