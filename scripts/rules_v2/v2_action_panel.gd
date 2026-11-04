class_name V2ActionPanel
extends PanelContainer

## Civ 6-style click UI for rules V2: select a unit, the action bar appears at the bottom.
##   HQ            -> place supply base (stock left, why not)
##   on enemy base -> raid (1 extra turn) / destroy
##   on a town     -> plunder (+stock)
##   enough XP     -> promote (one button per branch)

const RulesCls = preload("res://scripts/rules_v2/rules_v2.gd")
const UnitCardCls = preload("res://scripts/rules_v2/v2_unit_card.gd")

const KR := {"conscript": "민병대", "infantry": "일반병", "spearman": "창병", "spear": "창병", "cavalry": "기병",
	"archer": "궁병", "scout": "척후병", "hq": "사령부"}
const ZONE_KR := {"near": "보급 가까움", "normal": "보급 일반", "out": "보급 밖"}

var shell: Node = null
var um: RefCounted = null
var _title: Label
var _card = null
var _stats: Label
var _note: Label
var _actions: HBoxContainer
var _sig: String = ""


func setup(p_shell: Node, unit_manager: RefCounted) -> void:
	shell = p_shell
	um = unit_manager
	name = "V2ActionPanel"
	custom_minimum_size = Vector2(0, 0)
	add_theme_stylebox_override("panel", UnitCardCls.paper_style(12))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	add_child(v)
	_title = Label.new()          # (the card carries the title now; kept so older code paths stay valid)
	_title.visible = false
	v.add_child(_title)
	_card = UnitCardCls.new()
	v.add_child(_card)
	_card.setup(shell)
	_stats = Label.new()          # only the extra remarks (unguarded, why a button is off) go here
	_stats.add_theme_font_size_override("font_size", 19)
	_stats.add_theme_color_override("font_color", UnitCardCls.INK)
	_stats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_stats.custom_minimum_size = Vector2(600, 0)
	v.add_child(_stats)
	_note = _stats   # extra info (xp / why a button is off) is appended to the single stats line
	_actions = HBoxContainer.new()          # the buttons share the full width evenly
	_actions.add_theme_constant_override("separation", 12)
	_actions.custom_minimum_size = Vector2(UnitCardCls.ROW_W, 0)
	v.add_child(_actions)
	anchor_left = 0.0
	anchor_right = 0.0
	anchor_top = 1.0
	anchor_bottom = 1.0
	offset_left = 4.0
	offset_right = 4.0
	offset_top = -100.0
	offset_bottom = -4.0
	grow_horizontal = Control.GROW_DIRECTION_END
	grow_vertical = Control.GROW_DIRECTION_BEGIN
	visible = false
	um.selection_changed.connect(func(_u): _refresh(true))
	um.turn_advanced.connect(func(_t): _refresh(true))
	um.unit_promoted.connect(func(_a, _b): _refresh(true))
	var t := Timer.new()
	t.wait_time = 0.3
	t.autostart = true
	t.timeout.connect(func(): _refresh(false))
	add_child(t)


## True when the point is over a window that floats above the bar (the promotion window).
func covers(pos: Vector2) -> bool:
	return visible and _card != null and _card.has_method("window_has_point") and bool(_card.call("window_has_point", pos))


## Physical size stays fixed: the project stretches the whole UI with the window (canvas_items), so on a bigger screen / in full
## screen the panel would grow. Counter-scale by the stretch factor so it is the same size in real pixels everywhere.
func _process(_d: float) -> void:
	var f: float = maxf(0.1, get_viewport().get_final_transform().get_scale().x)
	var sc := Vector2.ONE / f
	if not scale.is_equal_approx(sc):
		scale = sc
	pivot_offset = Vector2(0.0, size.y)


func _player_phase() -> bool:
	return int(shell.get("_turn_phase")) == 0


func _refresh(force: bool) -> void:
	if um == null or not um.is_unit_selected():
		visible = false
		_sig = ""
		if _card != null:
			_card.close_promo()
		return
	var id: String = um.get_selected_unit_id()
	var u: Dictionary = um.get_unit_by_id(id)
	if u.is_empty() or str(u.get("faction", "")) != "blue":
		visible = false
		if _card != null:
			_card.close_promo()
		return
	var sig := "%s|%s|%s|%s|%s|%s|%s|%s" % [id, u.get("class"), u.get("soldier_count"), u.get("xp", 0), u.get("action_ended"), u.get("supply_zone", ""), u.get("q"), u.get("r")]
	sig += "|%s|%s|%s|%s|%s|%s" % [um.supply_v2.stock.get("blue", 0), um.supply_v2.nodes.size(), _player_phase(), u.get("fort_hp", 0), u.get("fort_used", false), u.get("rested_this_turn", false)]
	if not force and sig == _sig:
		return
	_sig = sig
	visible = true
	var cls := RulesCls.norm(str(u.get("class", "")))
	var hp := int(u.get("soldier_count", 0))
	var mx := int(u.get("max_count", hp))
	_title.text = "%s  ·  %s" % [KR.get(cls, cls), id]
	var zone_now: String = um.supply_v2.zone_of(um._units, "blue", int(u["q"]), int(u["r"])) if um.supply_v2 != null else "near"
	_card.set_unit(u, zone_now)
	_card.set_stats(RulesCls.attack_of(cls), float(u.get("remaining_mp", 0.0)), float(u.get("base_mp", 0.0)))
	_stats.text = ""      # the remarks that used to sit here are now tooltips of the buttons they belong to
	_stats.visible = false
	for c in _actions.get_children():
		c.queue_free()
	if not _player_phase():
		return
	var rb = _button("휴식 (무방비)", um.can_unit_rest(id), "rest")
	var rest_why: String = um.v2_rest_block(id)
	rb.tooltip_text = "휴식: 병력이 최대 병력의 %d%% 회복됩니다. 대신 이번 적 턴 동안 무방비라서 근접 반격을 하지 못합니다. 파란 반경(HQ 치유 범위) 안에서만 가능합니다." % roundi(RulesCls.REST_HEAL_FRAC * 100.0) if rest_why == "" else "휴식 불가: " + rest_why
	rb.pressed.connect(func(): shell.call("_on_rest_button_pressed"); _refresh(true))
	_actions.add_child(rb)
	var wb = _button("턴 스킵", not bool(u.get("action_ended", false)), "skip")
	wb.tooltip_text = "턴 스킵: 이 부대는 제자리에서 이번 턴을 마칩니다. 방어 태세는 그대로라서 적이 공격하면 정상적으로 반격합니다."
	wb.pressed.connect(func(): shell.call("_on_wait_button_pressed"); _refresh(true))
	_actions.add_child(wb)
	if cls != "hq" and cls != "scout":
		var fwhy: String = um.v2_fortify_block(id)
		var fused := bool(u.get("fort_used", false))
		var fb = _button("요새화 (사용함)" if fused else "요새화 (1회)", fwhy == "", "fortify")
		fb.tooltip_text = "요새화: 나무 방책(체력 %d)을 세워 이 자리를 지킵니다. 부대당 게임 전체에서 1번만 쓸 수 있고, 이동하면 방책은 사라집니다. 마을과 건물 칸에서는 쓸 수 없습니다." % RulesCls.FORT_HP if fwhy == "" else "요새화 불가: " + fwhy
		fb.pressed.connect(func(): _run(um.v2_fortify(id), id, "요새화"))
		_actions.add_child(fb)
	if cls == "hq":
		var why: String = um.supply_v2.place_block_reason(um._units, "blue")
		if why == "" and bool(u.get("action_ended", false)):
			why = "action ended"
		var b = _button("보급기지 (%d)" % int(um.supply_v2.stock.get("blue", 0)), why == "", "build")
		b.tooltip_text = "건설: 사령부가 서 있는 자리에 보급기지를 세웁니다(재고 1 소모). 기지는 주변에 치유와 사기 회복 반경을 만들고, 적이 인접해 공격하면 파괴됩니다." if why == "" else "설치 불가: " + _why_kr(why)
		b.pressed.connect(func(): _run(um.v2_build_base(id), id, "건설"))
		_actions.add_child(b)
	var q := int(u["q"])
	var r := int(u["r"])
	var acted := bool(u.get("action_ended", false))
	# 병참기지: an enemy base on this hex can be raided; one within reach can be attacked (its own HP)
	var enemy_base: Dictionary = um.supply_v2.node_at(q, r)
	if not enemy_base.is_empty() and str(enemy_base["faction"]) != "blue":
		var br = _button("기지 약탈", not acted, "raid")
		br.pressed.connect(func(): _run(um.v2_begin_raid(id, false), id, "약탈 중"))
		_actions.add_child(br)
	for tb in um.v2_attackable_bases(id):
		var nid: String = str(tb["id"])
		var ba = _button("기지 공격 (HP %d)" % int(tb["hp"]), true, "attack")
		ba.pressed.connect(func(): _run(um.v2_attack_base(id, nid), id, "기지 공격"))
		_actions.add_child(ba)
	var terr: int = int(((shell.get("_battlefield") as Dictionary).get("terrain", {}) as Dictionary).get("%d,%d" % [q, r], 0))
	var tk := "%d,%d" % [q, r]
	if terr == 5 and um.supply_v2.towns.has(tk) and int(um.supply_v2.towns[tk]["stock"]) > 0:
		var bt = _button("마을 약탈 +%d" % int(um.supply_v2.towns[tk]["stock"]), not acted, "raid")
		bt.pressed.connect(func(): _run(um.v2_begin_raid(id, true), id, "약탈 중"))
		_actions.add_child(bt)
	if RulesCls.TREE.has(cls):
		var opts: Array = um.v2_promotion_options(id)
		if opts.is_empty():
			if int(u.get("xp", 0)) >= int(RulesCls.PROMOTE_XP[cls]):
				var bx = _button("승진 (보급 필요)", false, "promo")
				_actions.add_child(bx)
		else:
			for o in opts:
				var bp = _button("승진 → %s" % KR.get(str(o), str(o)), true, "promo")
				bp.pressed.connect(func(): _run(um.v2_promote(id, str(o)), id, "승진"))
				_actions.add_child(bp)


func _why_kr(why: String) -> String:
	match why:
		"no base stock": return "기지 재고 없음"
		"base already here": return "이미 기지가 있음"
		"out of link range": return "보급선과 너무 멀음"
	return why


func _button(text: String, enabled: bool, kind: String = "") -> Control:
	var b = UnitCardCls.ActionBtn.new()
	b.setup(kind, text, 18)
	b.custom_minimum_size = Vector2(110, 54)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.set_enabled(enabled)
	return b


func _run(res: Dictionary, uid: String = "", label: String = "") -> void:
	if res.get("success", false):
		if uid != "" and shell.has_method("_v2_after_action"):
			shell.call("_v2_after_action", uid, label)
	elif shell.has_method("_show_combat_log"):
		shell.call("_show_combat_log", "불가: %s" % str(res.get("error", "")))
	_refresh(true)
