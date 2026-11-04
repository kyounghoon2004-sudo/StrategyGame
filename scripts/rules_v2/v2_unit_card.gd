class_name V2UnitCard
extends VBoxContainer

## Rules V2 unit card (top of the bottom-left action panel), in the game's own parchment look (like the fog of war):
## [unit icon] NAME centred on top, a hex-shaped live 3D portrait and a diagram of strength, morale and supply state.
## The promotion path opens in its own window (button "승진 경로"): hover a possible promotion to see what changes, click to pin it.

const RulesCls = preload("res://scripts/rules_v2/rules_v2.gd")
const BadgeCls = preload("res://scripts/visual/civ3d/civ_unit_badge.gd")
const TipCls = preload("res://scripts/rules_v2/v2_tip.gd")

const FS_NAME := 24
const FS_BODY := 19
const KR := {"conscript": "민병대", "infantry": "일반병", "spearman": "창병", "spear": "창병", "cavalry": "기병",
	"archer": "궁병", "scout": "척후병", "hq": "사령부", "siege": "공성"}
const CLASS_TIP := {
	"conscript": "농민 징집병. 가장 약하지만 경험을 쌓으면 일반병이 됩니다.",
	"infantry": "표준 보병. 경험을 쌓으면 창병, 기병, 궁병 중 하나로 승진합니다.",
	"spear": "창병. 공격력이 가장 높은 근접 병종입니다.",
	"cavalry": "기병. 이동력이 가장 높아 빠르게 치고 빠집니다.",
	"archer": "궁병. 2칸 떨어진 적을 쏠 수 있고, 거리가 2칸이면 반격을 받지 않습니다.",
	"scout": "척후병. 시야가 넓고 이동이 매우 빠르지만 약합니다.",
	"hq": "사령부. 보급기지를 세우고, 주변에 치유와 사기 회복의 반경을 만듭니다.",
}
const ZONE_KR := {"near": "보급 가까움", "normal": "보급 일반", "out": "보급 밖"}
const COL_OK := Color(0.36, 0.64, 0.24)
const COL_WEAK := Color(0.88, 0.68, 0.14)
const COL_BAD := Color(0.78, 0.22, 0.15)
const COL_UP := Color(0.18, 0.50, 0.16)
const COL_DOWN := Color(0.70, 0.18, 0.12)
const GOLD := Color(0.78, 0.64, 0.34)
const PAPER := Color(0.84, 0.78, 0.63)
const PAPER_DARK := Color(0.70, 0.63, 0.48)
const INK := Color(0.22, 0.15, 0.08)
const INK_SOFT := Color(0.42, 0.32, 0.18)
const SEAL_BLUE := Color(0.17, 0.30, 0.55)
const ROW_W := 560.0
const PORTRAIT := 162

const HEX_MASK := """
shader_type canvas_item;
void fragment() {
	vec2 p = abs((UV - vec2(0.5)) * 2.0);
	if (p.y > 0.999 || p.x * 0.866 + p.y * 0.5 > 0.866) { discard; }
	COLOR = texture(TEXTURE, UV);
}
"""

var shell: Node = null
var _portrait_holder: HexPortrait = null
var _portrait_cls: String = ""
var _title: Label
var _title_icon: TitleIcon
var _hp_row: Row
var _morale_row: Row
var _supply_row: Row
var _fort_row: Row
var _stat_row: StatRow
var _promo_btn: ActionBtn
var _promo_win: PanelContainer = null
var _promo_tree: PromoTree = null
var _cur: Dictionary = {}


## Every tooltip of the card and the action bar: see v2_tip.gd (solid black, big white text).
static func make_tip(text: String) -> Control:
	return TipCls.make(text)


## The paper panel look shared by the card, the action bar and the promotion window.
static func paper_style(radius: int = 10) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = PAPER
	sb.border_color = INK_SOFT
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(radius)
	sb.shadow_color = Color(0, 0, 0, 0.35)
	sb.shadow_size = 6
	sb.set_content_margin_all(8)
	return sb


func setup(p_shell: Node) -> void:
	shell = p_shell
	add_theme_constant_override("separation", 6)
	# the hex runs up beside the title: [big hex] [title over the stat rows]
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 4)
	add_child(body)
	_portrait_holder = HexPortrait.new()
	_portrait_holder.custom_minimum_size = Vector2(PORTRAIT + 8, PORTRAIT * 0.866 + 8)
	body.add_child(_portrait_holder)
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 6)
	rows.alignment = BoxContainer.ALIGNMENT_CENTER
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(rows)
	var head := HBoxContainer.new()
	head.alignment = BoxContainer.ALIGNMENT_CENTER
	head.add_theme_constant_override("separation", 10)
	rows.add_child(head)
	_title_icon = TitleIcon.new()
	_title_icon.custom_minimum_size = Vector2(38, 38)
	head.add_child(_title_icon)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", FS_NAME)
	_title.add_theme_color_override("font_color", INK)
	head.add_child(_title)
	_hp_row = _add_row(rows, "shield")
	_morale_row = _add_row(rows, "flag")
	_supply_row = _add_row(rows, "crate")
	_fort_row = _add_row(rows, "stake")
	var stat_line := HBoxContainer.new()      # attack / move and the small promotion button share one line
	stat_line.add_theme_constant_override("separation", 6)
	rows.add_child(stat_line)
	_stat_row = StatRow.new()
	_stat_row.custom_minimum_size = Vector2(262, 38)
	_stat_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stat_line.add_child(_stat_row)
	_promo_btn = ActionBtn.new()
	_promo_btn.setup("promo", "승진", 18)
	_promo_btn.tooltip_text = "승진 경로: 이 병종이 승진할 수 있는 병종과, 승진하면 달라지는 점을 보여 줍니다."
	_promo_btn.custom_minimum_size = Vector2(108, 38)
	_promo_btn.pressed.connect(_toggle_promo)
	stat_line.add_child(_promo_btn)


func _add_row(parent: Control, icon: String) -> Row:
	var r := Row.new()
	r.icon_kind = icon
	r.custom_minimum_size = Vector2(ROW_W - PORTRAIT - 14, 30)
	parent.add_child(r)
	return r


func _set_portrait(cls: String) -> void:
	if cls == _portrait_cls:
		return
	_portrait_cls = cls
	_portrait_holder.clear()
	var view: Node = shell.get("_view3d") if shell != null else null
	if view != null and view.has_method("build_portrait"):
		var p: Control = view.call("build_portrait", cls, "blue", Vector2i(PORTRAIT, int(PORTRAIT * 0.866)))
		if p != null:
			var mat := ShaderMaterial.new()
			var sh := Shader.new()
			sh.code = HEX_MASK
			mat.shader = sh
			p.material = mat
			_portrait_holder.set_portrait(p)


## Attack and movement, as big icon + number pairs (replaces the small text line).
func set_stats(attack: float, mp: float, base_mp: float) -> void:
	var cls := RulesCls.norm(str(_cur.get("class", "")))
	_stat_row.tip_attack = "공격력 %.0f: 한 번 공격할 때 주는 피해의 기준입니다. 피해 = 공격력 x %.1f (병력과 사기가 낮으면 감소).\n사거리 %d칸. 인접한 적을 치면 상대도 반격하고, 2칸 거리의 사격은 반격을 받지 않습니다.\n방어력과 병종 상성은 없습니다." % [attack, RulesCls.DAMAGE_SCALE, RulesCls.range_of(cls)]
	_stat_row.tip_move = "이동력 %.0f / %.0f: 이번 턴에 남은 이동 / 기본 이동력.\n평지 1, 숲 2 같은 지형 비용만큼 소모합니다. 산은 지나갈 수 없고, 강은 기본 이동력 전부를 써서 건널 수 있습니다(강 위에 멈출 수는 없습니다)." % [mp, base_mp]
	_stat_row.set_stats(attack, mp, base_mp)


func set_unit(u: Dictionary, zone: String) -> void:
	_cur = u
	var cls := RulesCls.norm(str(u.get("class", "")))
	_set_portrait(cls)
	_title.text = KR.get(cls, cls)
	_title_icon.set_class(cls)
	_title_icon.tooltip_text = KR.get(cls, cls) + ": " + str(CLASS_TIP.get(cls, ""))
	_portrait_holder.tooltip_text = KR.get(cls, cls) + ": " + str(CLASS_TIP.get(cls, ""))
	var hp := int(u.get("soldier_count", 0))
	var mx := maxi(1, int(u.get("max_count", hp)))
	var f := clampf(float(hp) / float(mx), 0.0, 1.0)
	_hp_row.tooltip_text = "병력: 살아 있는 병사 수 / 최대.\n병력이 줄면 이 부대의 공격도 약해집니다(최대 -60%%).\n방어력은 따로 없고, 맞으면 이 병력이 그대로 줄어듭니다.\n보급 가까움 구역에서는 턴마다 최대 병력의 %d%%가 회복됩니다." % roundi(RulesCls.NEAR_HEAL_FRAC * 100.0)
	_hp_row.set_row("병력", f, COL_OK.lerp(COL_BAD, clampf((0.7 - f) / 0.5, 0.0, 1.0)), "%d/%d" % [hp, mx], 0)
	var m := float(u.get("morale", 100.0))
	var mc: Color = COL_OK if m > RulesCls.MORALE_WEAK else (COL_WEAK if m > RulesCls.MORALE_BROKEN else COL_BAD)
	_morale_row.tooltip_text = "사기: 0~100.\n%d 이하: 공격과 이동이 30%% 약해집니다.\n%d 이하: 턴마다 일부 병사가 이탈합니다.\n보급 구역에 따라 턴마다 오르거나 내립니다." % [int(RulesCls.MORALE_WEAK), int(RulesCls.MORALE_BROKEN)]
	_morale_row.set_row("사기", m / 100.0, mc, "%d" % roundi(m), 3)
	var fx := ""
	var zc: Color = COL_OK
	match zone:
		"near":
			fx = "사기 +%d · 병력 +%d%%" % [int(RulesCls.NEAR_MORALE), roundi(RulesCls.NEAR_HEAL_FRAC * 100.0)]
		"normal":
			fx = "사기 +%d" % int(RulesCls.NORMAL_MORALE)
			zc = COL_WEAK
		_:
			fx = "사기 %d" % int(RulesCls.OUT_MORALE)
			zc = COL_BAD
	var zone_tip := {
		"near": "보급 가까움(파란 반경 안): 병력이 회복되고 사기가 크게 오릅니다. 휴식도 이 안에서만 가능합니다.",
		"normal": "보급 일반: 사기가 조금 오르지만 병력은 회복되지 않습니다.",
		"out": "보급 밖: 턴마다 사기가 %d 떨어집니다. 사기가 낮아지면 약화되고 이탈이 생깁니다. 승진도 불가능합니다." % int(-RulesCls.OUT_MORALE),
	}
	_supply_row.tooltip_text = "다음 턴 변화: " + fx + "\n" + str(zone_tip.get(zone, ""))
	_supply_row.set_chip(ZONE_KR.get(zone, "보급"), zc, fx)
	var fh := int(u.get("fort_hp", 0))
	_fort_row.visible = fh > 0
	_fort_row.tooltip_text = "목책: 요새화로 세운 방책의 체력입니다. 맞으면 목책이 먼저 상당 부분을 받아 내고, 이동하면 사라집니다."
	if fh > 0:
		var fm := maxi(1, int(u.get("fort_hp_max", RulesCls.FORT_HP)))
		_fort_row.set_row("목책", clampf(float(fh) / float(fm), 0.0, 1.0), Color(0.55, 0.38, 0.18), "%d/%d" % [fh, fm], 0)
	var in_tree: bool = RulesCls.TREE.has(cls) or cls in ["spear", "cavalry", "archer"]
	_promo_btn.visible = in_tree
	if _promo_tree != null:
		_promo_tree.set_unit(u, zone)
	if not in_tree and _promo_win != null:
		_promo_win.visible = false


## The promotion path lives in a window of its own (click the button again, or "닫기", to close it).
func _toggle_promo() -> void:
	if _promo_win == null:
		_promo_win = PanelContainer.new()
		_promo_win.top_level = true
		_promo_win.add_theme_stylebox_override("panel", paper_style(12))
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 8)
		_promo_win.add_child(v)
		var head := HBoxContainer.new()
		v.add_child(head)
		var t := Label.new()
		t.text = "승진 경로"
		t.add_theme_font_size_override("font_size", FS_NAME - 2)
		t.add_theme_color_override("font_color", INK)
		t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		head.add_child(t)
		var x := ActionBtn.new()
		x.setup("close", "닫기", 17)
		x.custom_minimum_size = Vector2(104, 36)
		x.pressed.connect(func(): _promo_win.visible = false)
		head.add_child(x)
		_promo_tree = PromoTree.new()
		_promo_tree.custom_minimum_size = Vector2(600, 560)
		v.add_child(_promo_tree)
		_promo_win.visible = false
		add_child(_promo_win)
	_promo_win.visible = not _promo_win.visible
	if _promo_win.visible:
		_promo_tree.set_unit(_cur, str(_cur.get("supply_zone", "near")))
		var f: float = maxf(0.1, get_viewport().get_final_transform().get_scale().x)
		_promo_win.scale = Vector2.ONE / f            # same fixed physical size as the bar
		_promo_win.pivot_offset = Vector2.ZERO
		var anchor: Vector2 = (_promo_btn.get_global_transform() * Vector2.ZERO)
		_promo_win.reset_size()
		_promo_win.global_position = Vector2(anchor.x, maxf(8.0, anchor.y - _promo_win.size.y / f - 12.0))


func window_has_point(pos: Vector2) -> bool:
	return _promo_win != null and _promo_win.is_visible_in_tree() and (_promo_win.get_global_transform() * Rect2(Vector2.ZERO, _promo_win.size)).has_point(pos)


## Closes the promotion window (selection cleared / another unit chosen): a stale window must never swallow map clicks.
func close_promo() -> void:
	if _promo_win != null:
		_promo_win.visible = false


func _exit_tree() -> void:
	if _promo_win != null and is_instance_valid(_promo_win):
		_promo_win.visible = false


## ------------------------------------------------------------------------------------------------ portrait

## Flat-top hex frame: dark seal-blue field, the masked 3D view on top, gold outline above it.
class HexPortrait extends Control:
	func _make_custom_tooltip(for_text: String) -> Object:
		return TipCls.make(for_text)

	var _pc: Control = null
	var _outline: Control = null

	static func hex_pts(c: Vector2, rx: float) -> PackedVector2Array:
		var pts := PackedVector2Array()
		for i in 6:
			var a: float = deg_to_rad(60.0 * float(i))
			pts.append(c + Vector2(cos(a) * rx, sin(a) * rx))
		return pts

	func clear() -> void:
		if _pc != null and is_instance_valid(_pc):
			_pc.queue_free()
		_pc = null

	func set_portrait(c: Control) -> void:
		_pc = c
		add_child(c)
		var pw: float = size.x - 8.0
		c.position = Vector2(4.0, (size.y - pw * 0.866) * 0.5)
		if _outline == null:
			_outline = HexOutline.new()
			_outline.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_outline.set_anchors_preset(Control.PRESET_FULL_RECT)
			add_child(_outline)
		move_child(_outline, get_child_count() - 1)
		queue_redraw()

	func _draw() -> void:
		var c: Vector2 = size * 0.5
		var rx: float = (size.x - 8.0) * 0.5
		draw_colored_polygon(hex_pts(c + Vector2(2.0, 3.0), rx + 3.0), Color(0, 0, 0, 0.25))
		draw_colored_polygon(hex_pts(c, rx), Color(0.93, 0.90, 0.80))


class HexOutline extends Control:
	func _draw() -> void:
		var c: Vector2 = size * 0.5
		var rx: float = (size.x - 8.0) * 0.5
		var pts: PackedVector2Array = HexPortrait.hex_pts(c, rx)
		pts.append(pts[0])
		draw_polyline(pts, GOLD, 4.0, true)


## The unit's icon on its blue seal, as on the map badge.
class TitleIcon extends Control:
	func _make_custom_tooltip(for_text: String) -> Object:
		return TipCls.make(for_text)

	var klass: String = "infantry"

	func set_class(c: String) -> void:
		klass = c
		queue_redraw()

	func _draw() -> void:
		var c: Vector2 = size * 0.5
		var r: float = minf(size.x, size.y) * 0.5 - 2.0
		draw_circle(c + Vector2(1.5, 2.0), r + 2.0, Color(0, 0, 0, 0.3))
		draw_circle(c, r, GOLD)
		draw_circle(c, r - 3.0, SEAL_BLUE.darkened(0.25))
		draw_circle(c, r - 4.5, SEAL_BLUE)
		var tex: Texture2D = BadgeCls._icon_for(klass)
		if tex != null:
			var q: float = r - 7.0
			draw_texture_rect(tex, Rect2(c - Vector2(q, q), Vector2(q * 2.0, q * 2.0)), false)


## ------------------------------------------------------------------------------------------------ rows

class Row extends Control:
	func _make_custom_tooltip(for_text: String) -> Object:
		return TipCls.make(for_text)

	var icon_kind: String = "shield"
	var label: String = ""
	var frac: float = 1.0
	var col: Color = Color.WHITE
	var value: String = ""
	var segments: int = 0
	var chip_mode: bool = false
	var chip_text: String = ""
	var chip_note: String = ""

	func set_row(p_label: String, p_frac: float, p_col: Color, p_value: String, p_segments: int) -> void:
		chip_mode = false
		label = p_label
		frac = p_frac
		col = p_col
		value = p_value
		segments = p_segments
		queue_redraw()

	func set_chip(p_text: String, p_col: Color, p_note: String) -> void:
		chip_mode = true
		chip_text = p_text
		col = p_col
		chip_note = p_note
		queue_redraw()

	func _draw_icon(c: Vector2) -> void:
		var w: Color = INK
		match icon_kind:
			"shield":
				draw_colored_polygon(PackedVector2Array([c + Vector2(-8, -9), c + Vector2(8, -9), c + Vector2(8, 1), c + Vector2(0, 10), c + Vector2(-8, 1)]), w)
			"flag":
				draw_rect(Rect2(c + Vector2(-8, -10), Vector2(3, 20)), w)
				draw_colored_polygon(PackedVector2Array([c + Vector2(-5, -10), c + Vector2(9, -5), c + Vector2(-5, 0)]), w)
			"crate":
				draw_rect(Rect2(c + Vector2(-9, -7), Vector2(18, 15)), w)
				draw_rect(Rect2(c + Vector2(-9, -1), Vector2(18, 3)), PAPER)
			"stake":
				for k in 3:
					draw_colored_polygon(PackedVector2Array([c + Vector2(-9 + k * 6, 9), c + Vector2(-9 + k * 6, -3), c + Vector2(-6 + k * 6, -10), c + Vector2(-3 + k * 6, -3), c + Vector2(-3 + k * 6, 9)]), w)

	func _text(font: Font, pos: Vector2, s: String, fs: int, c: Color) -> void:
		draw_string_outline(font, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 3, Color(PAPER.r, PAPER.g, PAPER.b, 0.9))
		draw_string(font, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, c)

	func _draw() -> void:
		var font: Font = ThemeDB.fallback_font
		var h: float = size.y
		var fs := 18
		var base_y: float = h * 0.5 + fs * 0.36
		_draw_icon(Vector2(12.0, h * 0.5))
		if chip_mode:
			draw_circle(Vector2(36.0, h * 0.5), 6.0, col)
			draw_arc(Vector2(36.0, h * 0.5), 6.0, 0.0, TAU, 16, INK, 1.5, true)
			_text(font, Vector2(48.0, base_y), chip_text, fs, INK)
			var tw: float = font.get_string_size(chip_text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			_text(font, Vector2(48.0 + tw + 8.0, base_y), chip_note, 15, col.darkened(0.25))
			return
		_text(font, Vector2(28.0, base_y), label, fs, INK)
		var bar := Rect2(72.0, h * 0.5 - 7.0, size.x - 72.0 - 78.0, 14.0)
		draw_rect(bar.grow(2.0), INK)
		if segments > 1:
			var gap := 4.0
			var sw: float = (bar.size.x - gap * float(segments - 1)) / float(segments)
			for i in segments:
				var r := Rect2(bar.position.x + float(i) * (sw + gap), bar.position.y, sw, bar.size.y)
				draw_rect(r, PAPER_DARK)
				var seg_f: float = clampf(frac * float(segments) - float(i), 0.0, 1.0)
				if seg_f > 0.0:
					draw_rect(Rect2(r.position, Vector2(r.size.x * seg_f, r.size.y)), col)
		else:
			draw_rect(bar, PAPER_DARK)
			draw_rect(Rect2(bar.position, Vector2(bar.size.x * clampf(frac, 0.0, 1.0), bar.size.y)), col)
		_text(font, Vector2(bar.end.x + 8.0, base_y), value, fs, INK)


class StatRow extends Control:
	var attack: float = 0.0
	var mp: float = 0.0
	var base_mp: float = 0.0
	var tip_attack: String = ""
	var tip_move: String = ""

	func _get_tooltip(at: Vector2) -> String:
		return tip_attack if at.x < 140.0 else tip_move

	func _make_custom_tooltip(for_text: String) -> Object:
		return TipCls.make(for_text)

	func set_stats(a: float, m: float, b: float) -> void:
		attack = a
		mp = m
		base_mp = b
		queue_redraw()

	func _text(font: Font, pos: Vector2, s: String, fs: int, c: Color) -> void:
		draw_string_outline(font, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 3, Color(PAPER.r, PAPER.g, PAPER.b, 0.9))
		draw_string(font, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, c)

	func _draw() -> void:
		var font: Font = ThemeDB.fallback_font
		var cy: float = size.y * 0.5
		var fs := 24
		var by: float = cy + fs * 0.36
		# attack: crossed blades on a small seal
		var c1 := Vector2(18.0, cy)
		draw_circle(c1, 18.0, INK_SOFT)
		draw_circle(c1, 15.5, PAPER_DARK)
		draw_line(c1 + Vector2(-8, 8), c1 + Vector2(8, -8), INK, 3.5, true)
		draw_line(c1 + Vector2(-8, -8), c1 + Vector2(8, 8), INK, 3.5, true)
		draw_line(c1 + Vector2(-10, 5), c1 + Vector2(-5, 10), INK, 3.0, true)
		draw_line(c1 + Vector2(10, 5), c1 + Vector2(5, 10), INK, 3.0, true)
		_text(font, Vector2(40.0, by), "공격", 18, INK_SOFT)
		_text(font, Vector2(84.0, by), "%.0f" % attack, fs, INK)
		# move: a boot print / stride arrows on a small seal
		var c2 := Vector2(138.0, cy)
		draw_circle(c2, 18.0, INK_SOFT)
		draw_circle(c2, 15.5, PAPER_DARK)
		draw_polyline(PackedVector2Array([c2 + Vector2(-9, -8), c2 + Vector2(0, 0), c2 + Vector2(-9, 8)]), INK, 3.5, true)
		draw_polyline(PackedVector2Array([c2 + Vector2(1, -8), c2 + Vector2(10, 0), c2 + Vector2(1, 8)]), INK, 3.5, true)
		_text(font, Vector2(160.0, by), "이동", 18, INK_SOFT)
		_text(font, Vector2(204.0, by), "%.0f/%.0f" % [mp, base_mp], fs, INK)


## ------------------------------------------------------------------------------------------------ action buttons

## A dedicated action control: a parchment plate with its own drawn icon (rest, skip, fortify, build, raid, promote ...) and a label.
class ActionBtn extends Control:
	func _make_custom_tooltip(for_text: String) -> Object:
		return TipCls.make(for_text)

	signal pressed
	var kind: String = ""
	var text: String = ""
	var fs: int = 20
	var enabled: bool = true
	var _hover: bool = false
	var _down: bool = false

	func setup(p_kind: String, p_text: String, p_fs: int = 20) -> void:
		kind = p_kind
		text = p_text
		fs = p_fs
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		queue_redraw()

	func set_enabled(on: bool) -> void:
		enabled = on
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if on else Control.CURSOR_ARROW
		queue_redraw()

	func _gui_input(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			_down = (ev as InputEventMouseButton).pressed and enabled
			queue_redraw()
			if not (ev as InputEventMouseButton).pressed and enabled and Rect2(Vector2.ZERO, size).has_point((ev as InputEventMouseButton).position):
				pressed.emit()
			accept_event()

	func _notification(what: int) -> void:
		if what == NOTIFICATION_MOUSE_ENTER:
			_hover = true
			queue_redraw()
		elif what == NOTIFICATION_MOUSE_EXIT:
			_hover = false
			_down = false
			queue_redraw()

	func _icon(c: Vector2, col: Color) -> void:
		var paper: Color = PAPER_DARK.lerp(PAPER, 0.5)
		match kind:
			"rest":     # a crescent moon and two Z's
				draw_circle(c + Vector2(-4, 2), 11.0, col)
				draw_circle(c + Vector2(0, -1), 10.0, paper)
				var f: Font = ThemeDB.fallback_font
				draw_string(f, c + Vector2(6, -2), "z", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, col)
				draw_string(f, c + Vector2(12, -10), "z", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, col)
			"skip":     # an hourglass
				draw_colored_polygon(PackedVector2Array([c + Vector2(-9, -11), c + Vector2(9, -11), c + Vector2(0, 0)]), col)
				draw_colored_polygon(PackedVector2Array([c + Vector2(-9, 11), c + Vector2(9, 11), c + Vector2(0, 0)]), col)
				draw_rect(Rect2(c + Vector2(-11, -13), Vector2(22, 3)), col)
				draw_rect(Rect2(c + Vector2(-11, 10), Vector2(22, 3)), col)
			"fortify":  # a palisade
				for k in 4:
					var x: float = -12.0 + float(k) * 8.0
					draw_colored_polygon(PackedVector2Array([c + Vector2(x - 3.5, 11), c + Vector2(x - 3.5, -4), c + Vector2(x, -12), c + Vector2(x + 3.5, -4), c + Vector2(x + 3.5, 11)]), col)
				draw_rect(Rect2(c + Vector2(-14, 2), Vector2(28, 3)), paper)
			"build":    # a supply depot: crates and a pennant
				draw_rect(Rect2(c + Vector2(-12, -2), Vector2(14, 13)), col)
				draw_rect(Rect2(c + Vector2(2, -7), Vector2(11, 18)), col)
				draw_rect(Rect2(c + Vector2(-12, 3), Vector2(25, 2)), paper)
				draw_rect(Rect2(c + Vector2(4, -17), Vector2(2, 11)), col)
				draw_colored_polygon(PackedVector2Array([c + Vector2(6, -17), c + Vector2(14, -14), c + Vector2(6, -11)]), col)
			"raid":     # a torch
				draw_line(c + Vector2(-8, 11), c + Vector2(3, -3), col, 4.0, true)
				draw_colored_polygon(PackedVector2Array([c + Vector2(0, -2), c + Vector2(10, -4), c + Vector2(6, -14), c + Vector2(-2, -9)]), Color(0.85, 0.42, 0.1) if enabled else col)
			"attack":   # crossed blades
				draw_line(c + Vector2(-11, 11), c + Vector2(11, -11), col, 4.0, true)
				draw_line(c + Vector2(-11, -11), c + Vector2(11, 11), col, 4.0, true)
			"promo":    # a rank chevron
				draw_polyline(PackedVector2Array([c + Vector2(-10, 3), c + Vector2(0, -7), c + Vector2(10, 3)]), col, 4.0, true)
				draw_polyline(PackedVector2Array([c + Vector2(-10, 11), c + Vector2(0, 1), c + Vector2(10, 11)]), col, 4.0, true)
			"close":
				draw_line(c + Vector2(-7, -7), c + Vector2(7, 7), col, 4.0, true)
				draw_line(c + Vector2(-7, 7), c + Vector2(7, -7), col, 4.0, true)

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		var sb := StyleBoxFlat.new()
		var base: Color = PAPER_DARK.lerp(PAPER, 0.5)
		if not enabled:
			base = base.darkened(0.12)
		elif _down:
			base = base.darkened(0.12)
		elif _hover:
			base = base.lightened(0.10)
		sb.bg_color = base
		sb.border_color = INK_SOFT if enabled else INK_SOFT.lerp(PAPER, 0.5)
		sb.set_border_width_all(3 if _hover and enabled else 2)
		sb.set_corner_radius_all(9)
		draw_style_box(sb, r)
		var ink: Color = INK if enabled else INK.lerp(PAPER, 0.55)
		var font: Font = ThemeDB.fallback_font
		_icon(Vector2(26.0, size.y * 0.5), ink)
		var tx: float = 52.0
		draw_string(font, Vector2(tx, size.y * 0.5 + fs * 0.36), text, HORIZONTAL_ALIGNMENT_LEFT, size.x - tx - 8.0, fs, ink)


## ------------------------------------------------------------------------------------------------ promotion window

## The class tree. Hover a possible promotion (or click it to pin it) to see exactly what changes.
class PromoTree extends Control:
	const NODES := {
		"conscript": Vector2(70, 112), "infantry": Vector2(230, 112),
		"spear": Vector2(400, 34), "cavalry": Vector2(400, 112), "archer": Vector2(400, 190),
	}
	const EDGES := [["conscript", "infantry"], ["infantry", "spear"], ["infantry", "cavalry"], ["infantry", "archer"]]
	const NAMES := {"conscript": "민병대", "infantry": "일반병", "spear": "창병", "cavalry": "기병", "archer": "궁병"}
	const R := 26.0
	var cls: String = "infantry"
	var u: Dictionary = {}
	var zone: String = "near"
	var hovered: String = ""
	var pinned: String = ""

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP

	func set_unit(p_u: Dictionary, p_zone: String) -> void:
		var c: String = RulesCls.norm(str(p_u.get("class", "")))
		if c != cls:
			pinned = ""
		cls = c
		u = p_u
		zone = p_zone
		queue_redraw()

	func _targets() -> Array:
		return RulesCls.TREE.get(cls, [])

	func _node_at(pos: Vector2) -> String:
		for k in NODES:
			if (NODES[k] as Vector2).distance_to(pos) <= R + 6.0:
				return k
		return ""

	func _gui_input(ev: InputEvent) -> void:
		if ev is InputEventMouseMotion:
			var h: String = _node_at((ev as InputEventMouseMotion).position)
			if h != hovered:
				hovered = h
				queue_redraw()
		elif ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			var k: String = _node_at((ev as InputEventMouseButton).position)
			pinned = "" if (k == "" or k == pinned) else k
			queue_redraw()
			accept_event()

	func _notification(what: int) -> void:
		if what == NOTIFICATION_MOUSE_EXIT and hovered != "":
			hovered = ""
			queue_redraw()

	func _text(font: Font, pos: Vector2, s: String, fs: int, c: Color) -> void:
		draw_string_outline(font, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 3, Color(PAPER.r, PAPER.g, PAPER.b, 0.9))
		draw_string(font, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, c)

	func _draw() -> void:
		var font: Font = ThemeDB.fallback_font
		var shown: String = pinned if pinned != "" else hovered
		var targets: Array = _targets()
		for e in EDGES:
			var a: Vector2 = NODES[e[0]]
			var b: Vector2 = NODES[e[1]]
			var d: Vector2 = (b - a).normalized()
			var on_path: bool = e[0] == cls and targets.has(e[1])
			draw_line(a + d * R, b - d * R, INK if on_path else INK_SOFT, 4.0 if on_path else 3.0, true)   # lines stop at the nodes
		for k in NODES:
			var p: Vector2 = NODES[k]
			var here: bool = k == cls
			var can: bool = targets.has(k)
			var emph: bool = k == shown and can
			draw_circle(p, R + 2.0, Color(0, 0, 0, 0.25))
			draw_circle(p, R + (4.0 if emph else 0.0), GOLD if (here or emph) else INK_SOFT)
			draw_circle(p, R - 3.0, SEAL_BLUE if (here or can) else SEAL_BLUE.lerp(PAPER_DARK, 0.55))
			var tex: Texture2D = BadgeCls._icon_for(k)
			if tex != null:
				draw_texture_rect(tex, Rect2(p - Vector2(19.0, 19.0), Vector2(38.0, 38.0)), false, Color(1, 1, 1, 1.0 if (here or can) else 0.65))
			var nm: String = NAMES[k]
			var tw: float = font.get_string_size(nm, HORIZONTAL_ALIGNMENT_LEFT, -1, 19).x
			var tcol: Color = INK if (here or can) else INK_SOFT
			if k == "conscript" or k == "infantry":
				_text(font, Vector2(p.x - tw * 0.5, p.y + R + 24.0), nm, 19, tcol)
			else:
				_text(font, Vector2(p.x + R + 10.0, p.y + 7.0), nm, 19, tcol)
		# detail panel
		var top: float = 250.0
		var panel := Rect2(8.0, top, size.x - 16.0, size.y - top - 6.0)
		var sb := StyleBoxFlat.new()
		sb.bg_color = PAPER.lightened(0.07)
		sb.border_color = INK_SOFT
		sb.set_border_width_all(2)
		sb.set_corner_radius_all(8)
		draw_style_box(sb, panel)
		var x0: float = panel.position.x + 14.0
		var y: float = panel.position.y + 32.0
		if shown != "" and targets.has(shown):
			_draw_preview(font, shown, x0, y)
		elif shown != "":
			_draw_class_stats(font, shown, x0, y)
		else:
			_draw_class_stats(font, cls, x0, y)

	## The stats of one class (hover any node; with no hover, the unit's own class with its real values).
	func _draw_class_stats(font: Font, k: String, x0: float, y: float) -> void:
		var R2 = RulesCls
		var own: bool = k == cls
		_text(font, Vector2(x0, y), "%s%s" % [NAMES.get(k, k), "  (현재)" if own else ""], 22, INK)
		var rows := []
		rows.append(["공격", "%.0f" % R2.attack_of(k)])
		rows.append(["이동", "%.0f" % R2.move_of(k)])
		if own:
			rows.append(["병력", "%d / %d" % [int(u.get("soldier_count", 0)), int(u.get("max_count", u.get("soldier_count", 0)))]])
			rows.append(["사기", "%d" % roundi(float(u.get("morale", 100.0)))])
		elif R2.TREE.has(cls) and R2.TREE[cls].has(k):
			rows.append(["병력", "승진 시 최대 +%d" % R2.PROMOTE_HP_BONUS])
		var yy: float = y + 32.0
		for r in rows:
			_text(font, Vector2(x0, yy), r[0], 19, INK)
			_text(font, Vector2(x0 + 150.0, yy), r[1], 19, INK_SOFT)
			yy += 27.0
		if own and R2.PROMOTE_XP.has(cls):
			_draw_status(font, x0, yy + 24.0)
		elif own:
			_text(font, Vector2(x0, yy + 6.0), "최종 병종입니다. 더 이상 승진하지 않습니다.", 17, INK_SOFT)
		else:
			_text(font, Vector2(x0, yy + 6.0), "이 병종으로는 승진할 수 없습니다.", 17, INK_SOFT)

	func _draw_status(font: Font, x0: float, y: float) -> void:
		if RulesCls.PROMOTE_XP.has(cls):
			var need: int = int(RulesCls.PROMOTE_XP[cls])
			var xp: int = int(u.get("xp", 0))
			var bar := Rect2(x0, y - 14.0, 280.0, 14.0)
			draw_rect(bar.grow(2.0), INK)
			draw_rect(bar, PAPER_DARK)
			draw_rect(Rect2(bar.position, Vector2(bar.size.x * clampf(float(xp) / float(need), 0.0, 1.0), bar.size.y)), COL_WEAK if xp < need else COL_OK)
			_text(font, Vector2(x0 + 296.0, y), "경험 %d / %d" % [xp, need], 19, INK)
			_text(font, Vector2(x0, y + 36.0), "승진할 병종에 마우스를 올리면 달라지는 점이 보입니다.", 17, INK_SOFT)
		else:
			_text(font, Vector2(x0, y), "최종 병종입니다. 더 이상 승진하지 않습니다.", 19, INK)

	func _draw_preview(font: Font, target: String, x0: float, y: float) -> void:
		var R2 = RulesCls
		var nm: String = NAMES[target]
		_text(font, Vector2(x0, y), "%s  →  %s" % [NAMES.get(cls, cls), nm], 22, INK)
		var rows := []
		var a0: float = R2.attack_of(cls)
		var a1: float = R2.attack_of(target)
		var m0: float = R2.move_of(cls)
		var m1: float = R2.move_of(target)
		var hp0: int = int(u.get("soldier_count", 0))
		var mx0: int = int(u.get("max_count", hp0))
		var mx1: int = mx0 + R2.PROMOTE_HP_BONUS
		var mor: float = float(u.get("morale", 100.0))
		rows.append(["공격", "%.0f" % a0, "%.0f" % a1, a1 - a0])
		rows.append(["이동", "%.0f" % m0, "%.0f" % m1, m1 - m0])
		rows.append(["최대 병력", "%d" % mx0, "%d" % mx1, float(mx1 - mx0)])
		rows.append(["현재 병력", "%d" % hp0, "%d (전부 회복)" % mx1, float(mx1 - hp0)])
		rows.append(["사기", "%d" % roundi(mor), "100", 100.0 - mor])
		var yy: float = y + 34.0
		for r in rows:
			_text(font, Vector2(x0, yy), r[0], 19, INK)
			_text(font, Vector2(x0 + 140.0, yy), r[1], 19, INK_SOFT)
			_text(font, Vector2(x0 + 196.0, yy), "→", 19, INK_SOFT)
			var dcol: Color = INK if absf(float(r[3])) < 0.01 else (COL_UP if float(r[3]) > 0.0 else COL_DOWN)
			_text(font, Vector2(x0 + 226.0, yy), r[2], 19, dcol)
			yy += 27.0
		var need: int = int(R2.PROMOTE_XP.get(cls, 0))
		var xp: int = int(u.get("xp", 0))
		_text(font, Vector2(x0, yy + 6.0), "경험 -%d (현재 %d) · 승진한 턴에는 더 행동하지 못함" % [need, xp], 17, INK_SOFT)
		var ok: bool = xp >= need and zone != "out"
		var why: String = "경험 부족" if xp < need else "보급 밖에서는 승진 불가"
		_text(font, Vector2(x0, yy + 34.0), "지금 승진 가능" if ok else "지금은 승진 불가: %s" % why, 19, COL_UP if ok else COL_DOWN)
