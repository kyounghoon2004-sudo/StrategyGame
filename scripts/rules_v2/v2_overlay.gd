class_name V2Overlay
extends Node2D

## Rules V2 map overlay (2D layer over the 3D view):
##  - yellow supply lines along the shortest hex path, tapering with distance from the base
##    (2026-11-01: 10 px where it leaves a base, 3 px after 5 hexes, thinner still beyond)
##  - setup cost heat: while an HQ is selected its influence reads as a morale-delta heatmap
##    and the rest of the battlefield is desaturated (V2HqFocus) so the range reads at a glance
##  - the healing (near) tint for any other selected friendly unit

const WorldBoundaryCls = preload("res://scripts/step2r/step2r_world_boundary.gd")
const V2HqFocusCls = preload("res://scripts/rules_v2/v2_hq_focus.gd")

const COL_SUPPLY := {"blue": Color(1.0, 0.86, 0.2, 0.95), "red": Color(0.98, 0.62, 0.15, 0.95)}
const COL_OWNER := {"blue": Color(0.3, 0.6, 1.0), "red": Color(0.95, 0.3, 0.28), "neutral": Color(0.7, 0.7, 0.7)}
const LINE_W_MAX := 10.0     # thickness where the line leaves a supply base
const LINE_W_KNEE := 3.0     # thickness after KNEE_HEXES
const LINE_W_MIN := 1.2      # floor far down the line
const KNEE_HEXES := 5.0
const HEX_R := 24.0                                    # board hex radius (TILE_W / 2), flat-top
const COL_NEAR := Color(0.30, 0.95, 0.40, 0.40)       # near: morale +10, heals
const COL_NEAR_EDGE := Color(0.30, 0.95, 0.40, 0.32)
const COL_MID := Color(0.95, 0.82, 0.28, 0.17)        # mid: morale held
const COL_NEAR_RING := Color(1.0, 0.85, 0.30, 0.90)   # heal edge
const COL_OUT_RING := Color(1.0, 0.45, 0.25, 0.90)    # last held hex: beyond it morale decays

var um: RefCounted = null
var _near_sig: String = ""
var _near_cache: Dictionary = {}
var _focus = null


var _move_from: Vector2i = Vector2i(-999, -999)
var _move_cells: Array = []


func setup(unit_manager: RefCounted) -> void:
	um = unit_manager
	# Above the unit figures and badges (28-35): the white reach outline must stay
	# readable where a friendly unit stands on it, instead of being hidden by the sprite.
	z_index = 40
	if _focus == null or not is_instance_valid(_focus):
		_focus = V2HqFocusCls.new()
		_focus.name = "V2HqFocus"
		add_child(_focus)


func _process(_delta: float) -> void:
	if um == null:
		return
	queue_redraw()


## Line thickness by distance from the supply base: 10 px at the base, 3 px after five
## hexes, then a slow fade to the floor so a long line still reads as a line.
static func link_width(length: int, _max_len: int = 0) -> float:
	var d := maxf(0.0, float(length))
	if d <= KNEE_HEXES:
		return lerpf(LINE_W_MAX, LINE_W_KNEE, d / KNEE_HEXES)
	return lerpf(LINE_W_KNEE, LINE_W_MIN, clampf((d - KNEE_HEXES) / KNEE_HEXES, 0.0, 1.0))


static func hex_line(a: Vector2i, b: Vector2i) -> Array:
	var n: int = maxi(abs(a.x - b.x), maxi(abs(a.y - b.y), abs((a.x + a.y) - (b.x + b.y))))
	var out: Array = []
	if n == 0:
		return [a]
	for i in range(n + 1):
		var t := float(i) / float(n)
		var fq := lerpf(a.x, b.x, t) + 1e-6
		var fr := lerpf(a.y, b.y, t) + 1e-6
		var fs := -fq - fr
		var rq := roundf(fq)
		var rr := roundf(fr)
		var rs := roundf(fs)
		var dq := absf(rq - fq)
		var dr := absf(rr - fr)
		var ds := absf(rs - fs)
		if dq > dr and dq > ds:
			rq = -rr - rs
		elif dr > ds:
			rr = -rq - rs
		out.append(Vector2i(int(rq), int(rr)))
	return out


## Reachable hexes for the selected field unit, computed by the shell (terrain costs applied).
func set_move_area(origin: Vector2i, cells: Array) -> void:
	_move_from = origin
	_move_cells = cells


func clear_move_area() -> void:
	_move_from = Vector2i(-999, -999)
	_move_cells = []


func _selected_hq() -> Dictionary:
	if not um.is_unit_selected():
		return {}
	var su: Dictionary = um.get_selected_unit()
	if str(su.get("class", "")) == "hq" and int(su.get("soldier_count", 0)) > 0:
		return su
	return {}


func _draw() -> void:
	if um == null:
		return
	var sv = um.supply_v2
	if sv != null:
		_draw_revealed_lines(sv)
	var hq: Dictionary = _selected_hq()
	_update_focus(hq, sv)
	_update_move_ring()


## The healing radius of the selected unit's side, tinted green (unchanged behaviour).
## Every non-HQ unit shows the SAME white movement outline; the coloured supply tints are gone.
func _update_move_ring() -> void:
	if _focus == null or not is_instance_valid(_focus):
		return
	if not um.is_unit_selected():
		_focus.clear_move_ring()
		return
	var su: Dictionary = um.get_selected_unit()
	if str(su.get("faction", "")) != "blue" or int(su.get("soldier_count", 0)) <= 0:
		_focus.clear_move_ring()
		return
	if _move_from.x == -999 or _move_cells.is_empty():
		_focus.clear_move_ring()
		return
	_focus.show_move_area(_move_from, _move_cells)

func _draw_morale_heat(_sv, _hq: Dictionary) -> void:
	pass

func _draw_hex(c: Vector2, r: float, fill: Color, line: Color, width: float) -> void:
	var pts := PackedVector2Array()
	for i in range(6):
		var a := deg_to_rad(60.0 * i)
		pts.append(c + Vector2(cos(a), sin(a)) * r)
	if fill.a > 0.001:
		draw_colored_polygon(pts, fill)
	if width > 0.0 and line.a > 0.001:
		var closed := pts.duplicate()
		closed.append(pts[0])
		draw_polyline(closed, line, width, true)


## Centre + radius of the selected HQ in viewport pixels, handed to the desaturation layer.
## Turns the blur/mute pass on while an HQ is selected; the bands themselves are drawn above it.
## Hands the selected HQ to the focus layer; it projects the bands through the 3D camera itself.
## The pulse is passive: it always runs from the player's HQ, even with nothing selected.
## Selection only switches the blur/mute backing on (and the supply lines follow it).
func _update_focus(hq: Dictionary, sv) -> void:
	if _focus == null or not is_instance_valid(_focus):
		return
	if sv == null:
		_focus.clear()
		return
	var bhq: Vector2i = sv.hq_hex(um._units, "blue")
	if bhq.x > 9000 or bhq.y > 9000:
		_focus.clear()
		return
	_focus.show_bands(bhq, int(sv.near_r), int(sv.normal_r))
	_focus.set_blur(false)   # 2026-11-01: HQ-click blur removed)

## The supply lines follow where the HQ is VISUALLY (the hex under its walking formation), not where the order put it: no line is
## laid ahead of an HQ that has not arrived.
func _visual_units() -> Dictionary:
	var out: Dictionary = um._units
	var shell: Node = get_parent()
	var view: Variant = shell.get("_view3d") if shell != null else null
	if view == null:
		return out
	var vu: Dictionary = view.get("_units")
	var copied := false
	for id in um._units:
		var u: Dictionary = um._units[id]
		if str(u.get("class", "")) != "hq" or str(u.get("faction", "")) != "blue" or not vu.has(id):
			continue
		var rn: Node3D = (vu[id] as Dictionary)["root"]
		if not is_instance_valid(rn):
			continue
		var hx: Vector2i = preload("res://scripts/core/hex_utils.gd").pixel_to_hex(Vector2(rn.position.x / 0.1875, rn.position.z / 0.1875))
		if not copied:
			out = out.duplicate()
			copied = true
		var v: Dictionary = u.duplicate()
		v["q"] = hx.x
		v["r"] = hx.y
		out[id] = v
	return out


func _draw_revealed_lines(sv) -> void:
	var units: Dictionary = _visual_units()
	var full: Dictionary = {}     # faction -> true
	var chains: Array = []        # [faction, node]
	var rv: Dictionary = um.v2_reveal
	for key in ["hover", "pin"]:
		var hx: Vector2i = rv.get(key, Vector2i(-999, -999))
		if hx.x == -999:
			continue
		var n: Dictionary = sv.node_at(hx.x, hx.y)
		if not n.is_empty():
			chains.append([str(n["faction"]), n])
			continue
		for f in sv.fixed:
			for en in sv.fixed[f]["entries"]:
				if en == hx:
					full[f] = true
	if um.is_unit_selected():
		var su: Dictionary = um.get_selected_unit()
		if str(su.get("class", "")) == "hq":
			full[str(su.get("faction", "blue"))] = true
	for f in full:
		_draw_net(sv, f, sv.fixed_paths(f, units), sv.link_edges(units, f))
	for c in chains:
		var ch: Dictionary = sv.chain_to(units, c[0], c[1])
		_draw_net(sv, c[0], ch["fixed"], ch["edges"])


func _draw_net(sv, f: String, fixed_paths: Array, edges: Array) -> void:
	var col: Color = COL_SUPPLY.get(f, COL_SUPPLY["blue"])
	for path in fixed_paths:
		_draw_tapered(path, col)
	for e in edges:
		var path: Array = hex_line(e["from"], e["to"])
		_draw_tapered(path, col)


## Segment-by-segment width: thin as the line gets further from its source.
func _draw_tapered(path: Array, col: Color) -> void:
	if path.size() < 2:
		return
	# the line follows the hexes along their shortest route (hex_line: the straightest of the equally short hex paths)
	for i in range(path.size() - 1):
		draw_line(WorldBoundaryCls.axial_to_world(path[i]), WorldBoundaryCls.axial_to_world(path[i + 1]), col, link_width(i), true)
