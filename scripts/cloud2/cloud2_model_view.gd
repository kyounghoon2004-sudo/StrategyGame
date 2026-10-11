class_name Cloud2ModelView
extends Window

const CoordMenuCls = preload("res://scripts/cloud2/cloud2_coord_menu.gd")

## CLOUD GENERAL — MODEL VIEW (DEV floating window).
##
## Shows exactly what the Cloud General saw and said: the canonical frozen
## request/response snapshot halves captured by Cloud2TurnController, plus a
## one-screen summary of transport facts. Left list = bounded history
## (newest last, auto-selected); right tabs = REQUEST / RESPONSE / SUMMARY.
##
## Presentation only: reads get_general_history()/get_general_flight() and
## never touches config, keys, or battle state. Snapshots are pre-scrubbed
## at capture; this view performs no network or file I/O.

const ControllerCls = preload("res://scripts/cloud2/cloud2_turn_controller.gd")

const WIN_TITLE := "CLOUD GENERAL — MODEL VIEW"
const WIN_SIZE := Vector2i(880, 620)
const WIN_MIN := Vector2i(640, 420)
const TAB_REQUEST := "REQUEST"
const TAB_RESPONSE := "RESPONSE"
const TAB_SUMMARY := "SUMMARY"
const TAB_VICTORY := "VICTORY"
const TAB_TACTICS := "TACTICS"
const EMPTY_HINT := "(no General calls yet — run a hierarchy RED turn)"

var _controller: ControllerCls = null
var _entries: Array = []
var _flight_lbl: Label = null
var _history: ItemList = null
var _tabs: TabContainer = null
var _req_text: TextEdit = null
var _res_text: TextEdit = null
var _sum_text: TextEdit = null
var _vic_text: TextEdit = null
var _tac_text: TextEdit = null
var _refresh_btn: Button = null
var _close_btn: Button = null
var _built := false


func _init() -> void:
	title = WIN_TITLE
	size = WIN_SIZE
	min_size = WIN_MIN
	_build()
	close_requested.connect(_on_close_requested)
	visibility_changed.connect(_on_visibility_changed)


func bind_controller(c: ControllerCls) -> void:
	_controller = c
	refresh()


func is_bound() -> bool:
	return _controller != null


## Rebuild the list from the controller and show the selected (or newest)
## entry. Keeps the current selection when its request_id still exists.
func refresh() -> void:
	if not _built:
		return
	var keep_id := selected_entry_id()
	_entries = _controller.get_general_history() if _controller != null else []
	_history.clear()
	if _entries.is_empty():
		_history.add_item(EMPTY_HINT, null, false)
		_history.set_item_disabled(0, true)
	else:
		for i in range(_entries.size()):
			var e: Dictionary = _entries[i]
			_history.add_item("#%d %s t%d %s" % [i + 1,
				str(e.get("trigger", "?")), int(e.get("turn", 0)),
				str(e.get("outcome", "?"))])
	var sel := _entries.size() - 1
	for i in range(_entries.size()):
		if str((_entries[i] as Dictionary).get("request_id", "")) == keep_id:
			sel = i
			break
	_update_victory()
	_update_tactics()
	if sel >= 0:
		_history.select(sel)
	_update_flight()
	show_entry(sel)


## Render one history entry into the three tabs. idx < 0 clears to hints.
func show_entry(idx: int) -> void:
	if idx < 0 or idx >= _entries.size():
		_req_text.text = EMPTY_HINT
		_res_text.text = EMPTY_HINT
		_sum_text.text = EMPTY_HINT
		return
	var e: Dictionary = _entries[idx]
	_req_text.text = str(e.get("request_text", ""))
	_res_text.text = str(e.get("response_text", ""))
	if _res_text.text.is_empty():
		_res_text.text = "(no response captured — %s)" % str(e.get("outcome", "?"))
	_sum_text.text = render_summary(e)


## One-screen transport-fact summary (pure; also used by gates).
static func render_summary(e: Dictionary) -> String:
	var dur := int(e.get("ended_ms", 0)) - int(e.get("started_ms", 0))
	if int(e.get("ended_ms", 0)) <= 0:
		dur = -1
	var lines := PackedStringArray([
		"request_id   %s" % str(e.get("request_id", "")),
		"kind         %s  attempt %d  parent %s" % [str(e.get("kind", "")),
			int(e.get("attempt", 0)), str(e.get("parent_request_id", "-"))],
		"trigger      %s" % str(e.get("trigger", "")),
		"reason       %s" % str(e.get("reason", "")),
		"turn         %d  snapshot %s" % [int(e.get("turn", 0)),
			str(e.get("snapshot_id", ""))],
		"battle       %s" % str(e.get("battle_id", "")),
		"provider     %s  model %s" % [str(e.get("provider", "")),
			str(e.get("model", ""))],
		"budget       max_tokens=%d timeout=%ds" % [int(e.get("max_tokens", 0)),
			int(e.get("timeout_sec", 0))],
		"request      %d chars (system %d, packet %d)" % [int(e.get("request_chars", 0)),
			int(e.get("system_chars", 0)), int(e.get("packet_chars", 0))],
		"response     %d chars  http=%s  latency=%dms  finish=%s" % [
			int(e.get("response_chars", 0)), str(e.get("http_status", "?")),
			int(e.get("latency_ms", 0)), str(e.get("finish_reason", "-"))],
		"reasoning    %s (%d chars, metadata only)" % [
			"present" if bool(e.get("reasoning_present", false)) else "none",
			int(e.get("reasoning_chars", 0))],
		"result       ok=%s code=%s" % [str(bool(e.get("ok", false))),
			str(e.get("code", "-"))],
		"detail       %s" % str(e.get("detail", "-")),
		"outcome      %s" % str(e.get("outcome", "?")),
		"wall         %s" % ("in-flight" if dur < 0 else ("%dms" % dur)),
	])
	if e.has("pipeline") and (e.get("pipeline", {}) as Dictionary).size() > 0:
		var pipe: Dictionary = e.get("pipeline", {})
		lines.append("--- POST-TRANSPORT PIPELINE ---")
		lines.append("TRANSPORT    %s" % str(pipe.get("transport", "?")))
		lines.append("PARSE        %s" % str(pipe.get("parse", "?")))
		if pipe.has("contract"):
			lines.append("CONTRACT     %s" % str(pipe.get("contract", "?")))
		lines.append("PLAN         %s" % str(pipe.get("plan", "?")))
		lines.append("ADOPTION     %s" % str(pipe.get("adoption", "?")))
		lines.append("parser_input %d chars match=%s" % [int(e.get("parser_input_chars", 0)),
			str(bool(e.get("parser_input_match", false)))])
	if not str(e.get("coord_kind", "")).is_empty():
		lines.append("--- COORDINATION (%s) ---" % str(e.get("coord_kind", "?")))
		lines.append("review_type  %s" % str(e.get("review_type", "-")))
		lines.append("event_count  %d" % int(e.get("event_count", 0)))
		var event_kinds: Array = []
		for event_val in (e.get("trigger_events", []) as Array):
			if event_val is Dictionary:
				event_kinds.append(str((event_val as Dictionary).get("kind", "?")))
		lines.append("events       %s" % (",".join(event_kinds) if not event_kinds.is_empty() else "none"))
		lines.append("plan_before  v%d" % int(e.get("current_plan_version", 0)))
		var group_assignments: Dictionary = e.get("current_group_assignments", {})
		lines.append("assignments  %s" % (CoordMenuCls.render_choices_text(group_assignments) if not group_assignments.is_empty() else "none"))
		var menu: Dictionary = e.get("menu", {})
		var groups: Array = menu.get("groups", []) as Array
		var opt_count := 0
		for g_val in groups:
			if g_val is Dictionary:
				opt_count += ((g_val as Dictionary).get("options", []) as Array).size()
		lines.append("menu         %d groups %d options (%s, %d chars)" % [groups.size(), opt_count,
			str(menu.get("menu_id", "?")), int(e.get("menu_chars", 0))])
		var sel: Dictionary = e.get("selection", {})
		if sel.has("decision"):
			lines.append("review       %s" % str(sel.get("decision", "?")))
		elif not sel.is_empty():
			lines.append("selected     %s" % CoordMenuCls.render_choices_text(_pairs_to_choices(sel.get("assignments", []))))
		var exp: Dictionary = e.get("expansion", {})
		if not exp.is_empty():
			lines.append("expanded     %s" % CoordMenuCls.render_missions_text(exp.get("missions", [])))
		var warns: Array = e.get("warnings", []) as Array
		if warns.is_empty():
			lines.append("warnings     none")
		else:
			lines.append("warnings     %d: %s" % [warns.size(), str(warns[0]).left(100)])
			for w_val in warns.slice(1, 3):
				lines.append("             %s" % str(w_val).left(100))
	return "\n".join(lines)


static func _pairs_to_choices(pairs: Array) -> Dictionary:
	var out := {}
	for p_val in pairs:
		if p_val is Dictionary:
			out[str((p_val as Dictionary).get("group", "?"))] = str((p_val as Dictionary).get("choice", "?"))
	return out


# --- test/read hooks -----------------------------------------------------

func entry_count() -> int:
	return _entries.size()


func tab_titles() -> Array:
	var out: Array = []
	for i in range(_tabs.get_tab_count()):
		out.append(_tabs.get_tab_title(i))
	return out


func selected_entry_id() -> String:
	if _history == null or not _history.is_anything_selected():
		return ""
	var sel := _history.get_selected_items()
	if sel.is_empty() or int(sel[0]) >= _entries.size():
		return ""
	return str((_entries[int(sel[0])] as Dictionary).get("request_id", ""))


func selected_index() -> int:
	if _history == null or not _history.is_anything_selected():
		return -1
	var sel := _history.get_selected_items()
	return int(sel[0]) if not sel.is_empty() else -1


func request_text() -> String:
	return _req_text.text


func response_text() -> String:
	return _res_text.text


func summary_text() -> String:
	return _sum_text.text


func flight_text() -> String:
	return _flight_lbl.text


# --- build ---------------------------------------------------------------

func _build() -> void:
	var mono := SystemFont.new()
	mono.font_names = PackedStringArray(["Consolas", "Menlo", "monospace"])
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	add_child(root)
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	root.add_child(top)
	_flight_lbl = Label.new()
	_flight_lbl.add_theme_font_size_override("font_size", 12)
	_flight_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_flight_lbl.text = "idle — no request in flight"
	top.add_child(_flight_lbl)
	_refresh_btn = Button.new()
	_refresh_btn.text = "REFRESH"
	_refresh_btn.tooltip_text = "Re-read history from the controller."
	_refresh_btn.pressed.connect(refresh)
	top.add_child(_refresh_btn)
	_close_btn = Button.new()
	_close_btn.text = "CLOSE"
	_close_btn.tooltip_text = "Hide this window (history is kept)."
	_close_btn.pressed.connect(_on_close_requested)
	top.add_child(_close_btn)
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(split)
	_history = ItemList.new()
	_history.custom_minimum_size = Vector2(250, 0)
	_history.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_history.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_history.add_theme_font_size_override("font_size", 11)
	_history.add_theme_font_override("font", mono)
	_history.item_selected.connect(_on_history_selected)
	split.add_child(_history)
	_tabs = TabContainer.new()
	_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.tab_alignment = TabBar.ALIGNMENT_CENTER
	split.add_child(_tabs)
	_req_text = _make_tab(TAB_REQUEST, mono)
	_res_text = _make_tab(TAB_RESPONSE, mono)
	_sum_text = _make_tab(TAB_SUMMARY, mono)
	_vic_text = _make_tab(TAB_VICTORY, mono)
	_tac_text = _make_tab(TAB_TACTICS, mono)
	_built = true
	refresh()


func _make_tab(tab_title: String, mono: Font) -> TextEdit:
	var te := TextEdit.new()
	te.name = tab_title
	te.editable = false
	te.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	te.size_flags_vertical = Control.SIZE_EXPAND_FILL
	te.add_theme_font_size_override("font_size", 11)
	te.add_theme_font_override("font", mono)
	te.text = EMPTY_HINT
	_tabs.add_child(te)
	return te


## VICTORY PLAN V0 (additive): read-only VictoryPlan + revision/audit
## view. Updated on every refresh; independent of history selection.
func _update_victory() -> void:
	if _vic_text == null:
		return
	if _controller == null or not _controller.has_method("get_victory_plan_view"):
		_vic_text.text = "(VictoryPlan view unavailable)"
		return
	_vic_text.text = str((_controller.get_victory_plan_view() as Dictionary).get("text", "(no VictoryPlan)"))


func victory_text() -> String:
	return _vic_text.text if _vic_text != null else ""


## LIBERATION V1 (additive): read-only tactical layer view — group
## coordinator runs + per-mission blackboards (intent, plan, commitments,
## open needs, risks, invalidations). Laya controllers only.
func _update_tactics() -> void:
	if _tac_text == null:
		return
	if _controller == null or not _controller.has_method("laya_tactics_view"):
		_tac_text.text = "(tactics view needs a Laya controller)"
		return
	var tv: Dictionary = _controller.laya_tactics_view()
	var lines := PackedStringArray()
	var runs: Array = tv.get("coordinator_runs", [])
	if runs.is_empty():
		lines.append("(no coordinator runs this phase — single-unit groups or legacy path)")
	else:
		for r_val in runs:
			var r: Dictionary = r_val
			lines.append("COORD %s t%d cands=%d sel=%s forced=%s err=%s %dms" % [
				str(r.get("mission_id", "?")), int(r.get("turn", 0)),
				int(r.get("candidates", 0)), str(r.get("selected", "-")),
				str(bool(r.get("forced", false))), str(r.get("error", "-")),
				int(r.get("ms", 0))])
	var boards: Dictionary = tv.get("blackboards", {})
	for mid in boards.keys():
		var b: Dictionary = boards[mid]
		lines.append("--- %s intent=%s" % [str(mid), str(b.get("intent", "-")).left(120)])
		if not str(((b.get("group_plan", {}) as Dictionary).get("text", ""))).is_empty():
			lines.append("PLAN %s" % str((b.get("group_plan", {}) as Dictionary).get("text", "")).left(160))
		for c_val in (b.get("commitments", []) as Array):
			var c: Dictionary = c_val
			lines.append("  [%s] %s %s %s :: %s" % [str(c.get("status", "?")),
				str(c.get("unit", "?")), str(c.get("kind", "?")), str(c.get("ref", "")),
				str(c.get("effect", "")).left(100)])
		for n in (b.get("open_needs", []) as Array):
			lines.append("  NEED %s" % str(n).left(120))
		for r2 in (b.get("risks", []) as Array):
			lines.append("  RISK %s" % str(r2).left(120))
		for iv in (b.get("invalidated", []) as Array):
			lines.append("  DROP %s" % str(iv).left(120))
	_tac_text.text = "\n".join(lines)


func tactics_text() -> String:
	return _tac_text.text if _tac_text != null else ""


func _update_flight() -> void:
	if _controller == null:
		_flight_lbl.text = "idle — no request in flight"
		return
	var f: Dictionary = _controller.get_general_flight()
	if f.is_empty():
		_flight_lbl.text = "idle — no request in flight"
	else:
		_flight_lbl.text = "IN FLIGHT: %s (%s t%d)" % [str(f.get("request_id", "?")),
			str(f.get("trigger", "?")), int(f.get("turn", 0))]


func _on_history_selected(idx: int) -> void:
	show_entry(idx)


func _on_close_requested() -> void:
	hide()


func _on_visibility_changed() -> void:
	if visible:
		refresh()
