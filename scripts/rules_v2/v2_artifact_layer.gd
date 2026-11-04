class_name V2ArtifactLayer
extends Node3D

## Rules V2 artifacts in the 3D battle view:
##  - 병참기지 3D models (every base, edge bases included) assembled from the existing building assets
##  - ONE unified icon style (owner-coloured disc + glyph) for structures (village / city / fortress) and for the
##    bases the HQ BUILDS (the two fixed edge bases get a model but no icon). Icons are screen-space, in the same
##    layer as the unit badges, and sit SIDE BY SIDE with the unit standing on the hex: [icons] [unit badge].
##  - Enemy artifacts exist only where the fog of war lets you see them.
##  - HP gauges (structure HP when damaged, base HP) and supply lines show only while the artifact is
##    hovered; a click pins them until the next click elsewhere.

const Lib = preload("res://scripts/visual/map_composition_v0/map_composition_library.gd")
const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")
const WorldBoundaryCls = preload("res://scripts/step2r/step2r_world_boundary.gd")

const S: float = 0.1875
const ICON_PX: int = 52
const GAP_PX: int = 4
const ICON_HEIGHT: float = 4.6
const ARRIVE_DIST: float = 0.9   # 3D units: a formation counts as arrived once it is this close to its hex centre
const BADGE_W: float = 36.0       # a unit badge's seal is ~35 px wide at scale 1
const BADGE_CENTER_UP: float = 22.0   # seal centre above the badge anchor (px at scale 1)
const NONE_HEX := Vector2i(-999, -999)

const COL_OWNER := {"blue": Color(0.30, 0.60, 1.0), "red": Color(0.95, 0.30, 0.28), "neutral": Color(0.72, 0.72, 0.72)}

var um: RefCounted = null
var view: Node = null
var shell: Node = null
var _models: Dictionary = {}      # key -> Node3D
var _clusters: Dictionary = {}    # "q,r" -> {"ctrl": TextureRect, "sig": String, "hex": Vector2i, "unit": String}
var _canvas: CanvasLayer = null   # icon layer (same z as the unit badges)
var _png_version: int = 0
var _png_check: float = 0.0
var _artifact_hexes: Dictionary = {}
var _hover: Vector2i = NONE_HEX
var _pin: Vector2i = NONE_HEX
var force_hover: Vector2i = NONE_HEX   # tests / captures: act as if the pointer rests on this hex
var _acc: float = 0.0


func setup(unit_manager: RefCounted, civ_view: Node, p_shell: Node) -> void:
	um = unit_manager
	view = civ_view
	shell = p_shell
	name = "V2ArtifactLayer"
	um.v2_reveal = {"hover": NONE_HEX, "pin": NONE_HEX}
	um.v2_base_changed.connect(func(_i, _h): _acc = 1.0)
	_canvas = CanvasLayer.new()
	_canvas.name = "V2Icons"
	_canvas.layer = 5
	add_child(_canvas)
	_sync()


func is_revealed(hex: Vector2i) -> bool:
	if hex == NONE_HEX:
		return false
	if hex == _hover or hex == _pin:
		return true
	if um != null and um.is_unit_selected():
		var su: Dictionary = um.get_selected_unit()
		return Vector2i(int(su.get("q", 0)), int(su.get("r", 0))) == hex
	return false


## Click on a hex: pin its artifacts' gauges / supply lines (click the same hex again, or an empty one, to unpin).
func click_hex(hex: Vector2i) -> void:
	if _artifact_hexes.has(hex) and hex != _pin:
		_pin = hex
	else:
		_pin = NONE_HEX
	um.v2_reveal["pin"] = _pin


func _process(delta: float) -> void:
	if um == null or shell == null:
		return
	_update_hover()
	_png_check += delta
	if _png_check >= 2.0:
		_png_check = 0.0
		if _png_changed():
			_png_version += 1
			_acc = 1.0
	_acc += delta
	if _acc >= 0.15:
		_acc = 0.0
		_sync()
	_layout_clusters()


## The structure whose banner is under the screen point (NONE_HEX when none): the whole name plate, the seal and the HP arc.
func banner_at(mp: Vector2) -> Vector2i:
	for key in _banners:
		var bn: Banner = _banners[key]
		if not bn.visible:
			continue
		var sc: float = bn.scale.x
		var top_left: Vector2 = bn.position + bn.pivot_offset * (1.0 - sc)
		var r := Rect2(top_left - Vector2(24.0 * sc, 4.0 * sc), bn.size * sc + Vector2(24.0 * sc, 8.0 * sc))
		if r.has_point(mp):
			return bn.hex
	return NONE_HEX


func _update_hover() -> void:
	var h := NONE_HEX
	if force_hover != NONE_HEX:
		h = force_hover
		if h != _hover:
			_hover = h
			um.v2_reveal["hover"] = _hover
			_acc = 1.0
		return
	var vp := get_viewport()
	if vp != null:
		var mp: Vector2 = vp.get_mouse_position()
		var bh: Vector2i = banner_at(mp)
		if bh != NONE_HEX:
			h = bh   # pointing at a banner (its name plate / icon) counts as pointing at the structure
		elif not bool(shell.call("_is_click_over_hud", mp)):
			var w: Vector2 = shell.call("_pointer_world", mp)
			var c: Vector2i = WorldBoundaryCls.world_to_axial(w)
			if _artifact_hexes.has(c):
				h = c
	if h != _hover:
		_hover = h
		um.v2_reveal["hover"] = _hover
		_acc = 1.0


# ------------------------------------------------------------------ sync

## An artifact of `faction` on `hex` exists for the player only if it is theirs or the fog lets them see it.
func _seen(hex: Vector2i, faction: String) -> bool:
	if faction == "blue" or faction == "neutral":
		return true
	var fog: Object = shell.get("_fog")
	return fog == null or bool(fog.call("is_hex_visible", hex.x, hex.y))


func _sync() -> void:
	var items: Dictionary = {}   # Vector2i -> Array of icon dicts
	var wanted_models: Dictionary = {}
	var hoverable: Dictionary = {}
	var banners: Dictionary = {}   # Vector2i -> {kind, owner, hp, max, name}
	for sh in um.get_all_strongholds():
		if not _orig_owner.has(str(sh.structure_id)):
			_orig_owner[str(sh.structure_id)] = str(sh.owner)
		var hex: Vector2i = sh.anchor_hex
		if not _seen(hex, str(sh.owner)):
			continue
		var kind := "fortress"
		if int(sh.structure_type) == 1:
			kind = "city"
		elif str(sh.structure_id).to_upper().contains("VILLAGE"):
			kind = "village"
		# structures get a named banner (see Banner), not a bare icon in the cluster row
		banners[hex] = {"kind": kind, "owner": str(sh.owner), "seal": str(_orig_owner[str(sh.structure_id)]), "hp": int(sh.fortification_hp), "max": int(sh.fortification_hp_max), "name": _structure_name(str(sh.structure_id), kind)}
	var sv = um.supply_v2
	if sv != null:
		for n in sv.nodes:
			var bh := Vector2i(int(n["q"]), int(n["r"]))
			var bf := str(n["faction"])
			if not _seen(bh, bf):
				continue
			# only bases the HQ built get an icon; the model stands wherever it is seen
			_add_item(items, bh, {"kind": "base", "owner": bf, "hp": int(n.get("hp", 0)), "max": int(n.get("hp_max", 1))})
			wanted_models["B:" + str(n["id"])] = {"hex": bh, "faction": bf, "big": false}
		for f in sv.fixed:
			var idx := 0
			for en in sv.fixed[f]["entries"]:
				if _seen(en, f):
					wanted_models["E:%s:%d" % [f, idx]] = {"hex": en, "faction": f, "big": true}
					hoverable[en] = true   # hover / click an edge base to see its supply network (no icon)
				idx += 1
	_artifact_hexes.clear()
	for h in items:
		_artifact_hexes[h] = true
	for h in hoverable:
		_artifact_hexes[h] = true
	for h in banners:
		_artifact_hexes[h] = true
	_sync_models(wanted_models)
	_sync_clusters(items)
	_sync_banners(banners)


## Display name of a structure: the map data's "name_kr" (strongholds[].name_kr), else a generic one by kind.
func _structure_name(structure_id: String, kind: String) -> String:
	var bf: Variant = shell.get("_battlefield")
	if bf is Dictionary:
		for sd in (bf as Dictionary).get("strongholds", []):
			if str(sd.get("id", "")) == structure_id and str(sd.get("name_kr", "")) != "":
				return str(sd["name_kr"])
	return {"village": "마을", "city": "도시", "fortress": "요새"}.get(kind, "거점")


func _add_item(items: Dictionary, hex: Vector2i, item: Dictionary) -> void:
	if not items.has(hex):
		items[hex] = []
	(items[hex] as Array).append(item)


# --------------------------------------------------------------- 3D models

func _sync_models(wanted: Dictionary) -> void:
	for key in wanted:
		if not _models.has(key):
			var w: Dictionary = wanted[key]
			_models[key] = _spawn_model(w["hex"], w["faction"], w["big"])
	for key in _models.keys():
		if not wanted.has(key):
			var node: Node3D = _models[key]
			_models.erase(key)
			if is_instance_valid(node):
				var tw := create_tween()
				tw.tween_property(node, "scale:y", 0.001, 0.4)
				tw.tween_callback(func(): if is_instance_valid(node): node.queue_free())


func _spawn_model(hex: Vector2i, faction: String, big: bool) -> Node3D:
	var root_n := Node3D.new()
	root_n.name = "Base_%d_%d" % [hex.x, hex.y]
	var p := HexUtilsCls.hex_to_pixel(hex.x, hex.y)
	root_n.position = Vector3(p.x * S, 0.0, p.y * S)
	add_child(root_n)
	var inner := Node3D.new()
	inner.scale = Vector3.ONE * S
	root_n.add_child(inner)
	# a small depot: raised granary in the middle, two outbuildings, a short fence, a banner in the owner's colour
	_part(inner, "granary", Vector2(0, -2), 0.0, 13.0)
	_part(inner, "small_house", Vector2(-11, 6), 25.0, 9.0)
	_part(inner, "workshop", Vector2(11, 7), -20.0, 10.0)
	for k in range(3):
		var a: float = deg_to_rad(-150.0 + 30.0 * float(k))
		var c := Vector2(cos(a), sin(a)) * 16.0
		_part(inner, "palisade", c, rad_to_deg(-a) + 90.0, 9.0)
	if big:
		# edge base: a timber watchtower beside the depot
		_part(inner, "watchtower", Vector2(-13, -10), 0.0, 9.0)
		_part(inner, "granary", Vector2(12, -8), 40.0, 9.0)
	_banner(inner, Vector2(0, 12), faction)
	root_n.scale = Vector3(1.0, 0.001, 1.0)
	create_tween().tween_property(root_n, "scale:y", 1.0, 0.7).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	return root_n


func _part(parent: Node3D, key: String, pos: Vector2, yaw_deg: float, target_len: float) -> void:
	var b: Dictionary = Lib.bounds(key)
	var native: float = maxf(float(b["half_xz"].x), float(b["half_xz"].y)) * 2.0
	var sc: float = target_len / maxf(native, 0.001)
	var holder := Node3D.new()
	holder.position = Vector3(pos.x, 0.0, pos.y)
	holder.rotation_degrees.y = yaw_deg
	holder.scale = Vector3.ONE * sc
	holder.add_child(Lib.instance_grounded(key))
	parent.add_child(holder)


func _banner(parent: Node3D, pos: Vector2, faction: String) -> void:
	var col: Color = COL_OWNER.get(faction, COL_OWNER["neutral"])
	var pole := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.35
	cyl.bottom_radius = 0.45
	cyl.height = 16.0
	pole.mesh = cyl
	var pm := StandardMaterial3D.new()
	pm.albedo_color = Color(0.36, 0.25, 0.14)
	pole.material_override = pm
	pole.position = Vector3(pos.x, 8.0, pos.y)
	parent.add_child(pole)
	var flag := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(8.0, 5.0)
	flag.mesh = quad
	var fm := StandardMaterial3D.new()
	fm.albedo_color = col
	fm.cull_mode = BaseMaterial3D.CULL_DISABLED
	fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	flag.material_override = fm
	flag.position = Vector3(pos.x + 4.4, 13.0, pos.y)
	parent.add_child(flag)


# ------------------------------------------------------------ icon clusters

func _sync_clusters(items: Dictionary) -> void:
	for hex in items:
		var row: Array = items[hex]
		var rev := is_revealed(hex)
		var sig := ""
		for it in row:
			sig += "%s/%s/%d/%d|" % [it["kind"], it["owner"], int(it.get("hp", 0)), int(it.get("max", 0))]
		sig += ("R" if rev else "-") + str(_png_version)
		var key := "%d,%d" % [hex.x, hex.y]
		if not _clusters.has(key):
			var tr := TextureRect.new()
			tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
			tr.stretch_mode = TextureRect.STRETCH_SCALE
			tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tr.visible = false
			_canvas.add_child(tr)
			_clusters[key] = {"ctrl": tr, "sig": "", "hex": hex, "unit": ""}
		var c: Dictionary = _clusters[key]
		if c["sig"] != sig:
			c["sig"] = sig
			(c["ctrl"] as TextureRect).texture = _cluster_texture(row, rev)
	for key in _clusters.keys():
		var parts: PackedStringArray = key.split(",")
		if not items.has(Vector2i(int(parts[0]), int(parts[1]))):
			(_clusters[key]["ctrl"] as Node).queue_free()
			_clusters.erase(key)


# ------------------------------------------------------------------ structure banners

var _banner_canvas: CanvasLayer = null   # above the unit badges (layer 5): a place banner is always on top
var _orig_owner: Dictionary = {}  # structure id -> owner at the start (the seal colour never changes)
var _banners: Dictionary = {}    # "q,r" -> Banner
var _glyph_tex: Dictionary = {}  # kind -> [png_version, ImageTexture]


func _glyph_texture(kind: String) -> Texture2D:
	var e: Array = _glyph_tex.get(kind, [-1, null])
	if int(e[0]) != _png_version:
		var png: Image = _glyph_png(kind)
		var t: ImageTexture = null
		if png != null:
			var im: Image = png.duplicate()
			im.generate_mipmaps()
			t = ImageTexture.create_from_image(im)
		_glyph_tex[kind] = [_png_version, t]
		return t
	return e[1]


func _sync_banners(wanted: Dictionary) -> void:
	for hex in wanted:
		var w: Dictionary = wanted[hex]
		var key := "%d,%d" % [hex.x, hex.y]
		if not _banners.has(key):
			if _banner_canvas == null:
				_banner_canvas = CanvasLayer.new()
				_banner_canvas.name = "V2Banners"
				_banner_canvas.layer = 7
				add_child(_banner_canvas)
			var b := Banner.new()
			b.visible = false
			_banner_canvas.add_child(b)
			_banners[key] = b
		var bn: Banner = _banners[key]
		bn.hex = hex
		bn.set_data(str(w["kind"]), str(w["owner"]), str(w["seal"]), str(w["name"]), int(w["hp"]), int(w["max"]), is_revealed(hex), _glyph_texture(str(w["kind"])))
	for key in _banners.keys():
		var parts: PackedStringArray = key.split(",")
		if not wanted.has(Vector2i(int(parts[0]), int(parts[1]))):
			(_banners[key] as Node).queue_free()
			_banners.erase(key)


## A banner stands on its structure. When a formation has arrived on the hex the banner rises and the unit's badge sinks by
## the same amount (eased, dynamic), so the name plate is never hidden behind the badge.
const BANNER_SHARE: float = 0.25   # share of the overlap the banner rises by (the badge sinks by the rest)
func _layout_banners(cam: Camera3D, bs: float, bm: float, dt: float, shift: Dictionary) -> void:
	var units: Dictionary = view.get("_units")
	for key in _banners:
		var bn: Banner = _banners[key]
		var hp := HexUtilsCls.hex_to_pixel(bn.hex.x, bn.hex.y)
		var hex3 := Vector3(hp.x * S, 1.2, hp.y * S)   # the banner stands ON its structure (hex centre)
		var uid := ""
		var unit_anchor := Vector3.ZERO
		for id in um._units:
			var u: Dictionary = um._units[id]
			if int(u.get("soldier_count", 0)) <= 0 or int(u["q"]) != bn.hex.x or int(u["r"]) != bn.hex.y or not units.has(id):
				continue
			var d: Dictionary = units[id]
			var rn: Node3D = d["root"]
			if not is_instance_valid(rn) or not rn.visible:
				continue
			if Vector2(rn.position.x - hex3.x, rn.position.z - hex3.z).length() > ARRIVE_DIST:
				continue
			uid = id
			unit_anchor = rn.position + Vector3(0.0, float(d["top"]), 0.0)
			break
		bn.split = move_toward(bn.split, 1.0 if uid != "" else 0.0, dt * 4.0)
		var e: float = bn.split * bn.split * (3.0 - 2.0 * bn.split)
		if cam.is_position_behind(hex3):
			bn.visible = false
			continue
		var a: Vector2 = cam.unproject_position(hex3)
		var d_px: float = 0.0
		if uid != "" and not cam.is_position_behind(unit_anchor):
			# Dynamic: measured from the real screen rects (so it follows the zoom), the banner and the badge move apart only by
			# as much as they overlap - the banner rises a quarter of it, the badge sinks the rest. No overlap = no movement.
			var s_b: float = bs * bm                                  # badge scale on screen
			var banner_bottom: float = a.y - 6.0 * bs                 # resting position, standing on the structure
			var badge_top: float = cam.unproject_position(unit_anchor).y - 46.0 * s_b   # outer edge of the morale ring
			var need: float = maxf(0.0, banner_bottom + 3.0 - badge_top)
			d_px = need * BANNER_SHARE * e                 # the banner stays close to its structure ...
			var sh: Vector2 = shift.get(uid, Vector2.ZERO)
			shift[uid] = sh + Vector2(0.0, need * (1.0 - BANNER_SHARE) * e)   # ... the badge does most of the moving
		var sc: float = bs * 1.1
		bn.scale = Vector2(sc, sc)
		bn.pivot_offset = Vector2(bn.size.x * 0.5, bn.size.y)
		var base_pos: Vector2 = a - bn.pivot_offset - Vector2(0.0, 6.0 * bs + d_px)
		bn.position = base_pos   # never slides away: it is drawn above every unit badge instead (own layer, see _banner_canvas)
		bn.visible = true


## Civ-style place banner: [seal with the structure icon] [name plate]. The PLATE takes the colour of whoever holds the place now;
## the SEAL keeps the colour of the side it was built for. Structure HP is a grey ring round the seal (only while damaged or while
## the structure is hovered / pinned).
class Banner extends Control:
	const GOLD := Color(0.78, 0.64, 0.34)
	const INK := Color(0.08, 0.07, 0.06, 0.9)
	const SEAL := {"blue": Color(0.17, 0.30, 0.55), "red": Color(0.58, 0.16, 0.12), "neutral": Color(0.30, 0.30, 0.32)}
	const HP_GREY := Color(0.80, 0.82, 0.84)
	var hex: Vector2i = Vector2i.ZERO
	var kind: String = "village"
	var owner_id: String = "neutral"   # current holder -> plate
	var seal_id: String = "neutral"    # original owner -> seal
	var title: String = ""
	var hp: int = 0
	var hp_max: int = 1
	var reveal: bool = false
	var glyph: Texture2D = null
	var split: float = 0.0   # 0..1: a formation stands on the hex (banner up, badge down)
	var grow: float = 0.0    # 0 = folded preview, 1 = unfolded detail (hover / pinned)

	func _process(delta: float) -> void:
		var target: float = 1.0 if reveal else 0.0
		if not is_equal_approx(grow, target):
			grow = move_toward(grow, target, delta * 6.0)
			queue_redraw()

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS

	func set_data(p_kind: String, p_owner: String, p_seal: String, p_title: String, p_hp: int, p_max: int, p_reveal: bool, p_glyph: Texture2D) -> void:
		if p_kind == kind and p_owner == owner_id and p_seal == seal_id and p_title == title and p_hp == hp and p_max == hp_max and p_reveal == reveal and p_glyph == glyph and size.x > 0.0:
			return
		kind = p_kind
		owner_id = p_owner
		seal_id = p_seal
		title = p_title
		hp = p_hp
		hp_max = maxi(1, p_max)
		reveal = p_reveal
		glyph = p_glyph
		var font: Font = ThemeDB.fallback_font
		var tw: float = font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x
		size = Vector2(46.0 + tw + 14.0, 48.0)
		queue_redraw()

	func _draw() -> void:
		var plate_col: Color = SEAL.get(owner_id, SEAL["neutral"])
		var seal_col: Color = SEAL.get(seal_id, SEAL["neutral"])
		var font: Font = ThemeDB.fallback_font
		# name plate (colour = current holder)
		var plate := Rect2(18.0, 11.0, size.x - 18.0, 26.0)
		var sb := StyleBoxFlat.new()
		sb.bg_color = plate_col.darkened(0.12)
		sb.border_color = GOLD
		sb.set_border_width_all(2)
		sb.set_corner_radius_all(13)
		sb.shadow_color = Color(0, 0, 0, 0.4)
		sb.shadow_size = 3
		draw_style_box(sb, plate)
		var fs := 15
		var tpos := Vector2(46.0, 11.0 + 26.0 * 0.5 + fs * 0.36)
		draw_string_outline(font, tpos, title, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 4, INK)
		draw_string(font, tpos, title, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.97, 0.94, 0.84))
		# seal with the structure icon (colour = original owner)
		var c := Vector2(22.0, 24.0)
		draw_circle(c + Vector2(1.5, 2.0), 17.0, Color(0, 0, 0, 0.35))
		draw_circle(c, 16.0, GOLD)
		draw_circle(c, 13.5, seal_col.darkened(0.25))
		draw_circle(c, 12.0, seal_col)
		if glyph != null:
			draw_texture_rect(glyph, Rect2(c - Vector2(10.5, 10.5), Vector2(21.0, 21.0)), false)
		# HP: a grey arc on the LEFT of the seal, drawn outside the banner so nothing shifts. Always there as a slim PREVIEW hugging the
		# rim; hovering / pinning unfolds it (wider, thicker, with quarter marks and the numbers). Empties from the top downwards.
		var g: float = grow * grow * (3.0 - 2.0 * grow)
		var frac: float = clampf(float(hp) / float(hp_max), 0.0, 1.0)
		var span: float = deg_to_rad(lerpf(150.0, 196.0, g))
		var a0: float = PI - span * 0.5        # bottom-left end
		var rr: float = lerpf(18.2, 21.8, g)
		draw_arc(c, rr, a0, a0 + span, 24, INK, lerpf(3.6, 8.0, g), true)
		if frac > 0.0:
			draw_arc(c, rr, a0, a0 + span * frac, 24, HP_GREY, lerpf(2.4, 5.0, g), true)
		if g > 0.05:
			for k in range(1, 4):   # quarter marks
				var ang: float = a0 + span * float(k) / 4.0
				var dir := Vector2(cos(ang), sin(ang))
				draw_line(c + dir * (rr - 4.5), c + dir * (rr + 4.5), Color(INK.r, INK.g, INK.b, g), 1.5, true)
			var txt: String = "%d / %d" % [hp, hp_max]
			var tw2: float = font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
			var tp := Vector2(c.x - tw2 * 0.5 + 18.0, 11.0 + 26.0 + 16.0)
			draw_string_outline(font, tp, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, 4, Color(INK.r, INK.g, INK.b, g))
			draw_string(font, tp, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(HP_GREY.r, HP_GREY.g, HP_GREY.b, g))


## Screen layout, every frame: the icon row sits beside the unit's badge on the same hex ([icons] [unit badge]),
## or centred alone when the hex is empty. The unit's badge is pushed sideways through view.v2_badge_shift.
func _layout_clusters() -> void:
	if view == null:
		return
	var cam: Camera3D = view.get("cam")
	var cam2d: Camera2D = view.get("cam2d")
	if cam == null or cam2d == null:
		return
	_canvas.visible = bool(view.get("_active"))
	if _banner_canvas != null:
		_banner_canvas.visible = bool(view.get("_active"))
	var dt: float = get_process_delta_time()
	var z: float = cam2d.zoom.x
	var bs: float = clampf(0.62 + 0.38 * (z - 0.3) / 1.7, 0.62, 1.0)
	var bm: float = float(view.get("badge_mult")) if view.get("badge_mult") != null else 1.0   # unit badges are drawn bigger than the structure icons
	var shift: Dictionary = {}
	var units: Dictionary = view.get("_units")
	for key in _clusters:
		var c: Dictionary = _clusters[key]
		var hex: Vector2i = c["hex"]
		var tr: TextureRect = c["ctrl"]
		var tex: Texture2D = tr.texture
		if tex == null:
			continue
		var hp := HexUtilsCls.hex_to_pixel(hex.x, hex.y)
		var hex3 := Vector3(hp.x * S, 0.0, hp.y * S)
		# the unit that LOGICALLY stands here AND whose formation has VISUALLY arrived (centred on the hex)
		var uid := ""
		var anchor3 := Vector3.ZERO
		for id in um._units:
			var u: Dictionary = um._units[id]
			if int(u.get("soldier_count", 0)) <= 0 or int(u["q"]) != hex.x or int(u["r"]) != hex.y or not units.has(id):
				continue
			var d: Dictionary = units[id]
			var rn: Node3D = d["root"]
			if not is_instance_valid(rn) or not rn.visible or not (d["badge"] as Control).visible:
				continue
			if Vector2(rn.position.x - hex3.x, rn.position.z - hex3.z).length() > ARRIVE_DIST:
				continue   # still walking in: the icon stays where it is
			uid = id
			anchor3 = rn.position + Vector3(0.0, float(d["top"]), 0.0)
			break
		var target: float = 1.0 if uid != "" else 0.0
		c["blend"] = move_toward(float(c.get("blend", 0.0)), target, dt * 5.0)
		var blend: float = c["blend"]
		if uid == "":
			anchor3 = Vector3(hex3.x, ICON_HEIGHT, hex3.z)
		if cam.is_position_behind(anchor3):
			tr.visible = false
			continue
		var a: Vector2 = cam.unproject_position(anchor3)
		var k: float = bs * 0.85
		var wc: float = float(tex.get_width()) * k
		var hc: float = float(tex.get_height()) * k
		var gap: float = 4.0 * bs
		var wb: float = BADGE_W * bs * bm
		var total: float = wc + gap + wb
		var left_alone: float = a.x - wc * 0.5
		var left_pair: float = a.x - total * 0.5
		var left: float = lerpf(left_alone, left_pair, blend)
		if uid != "":
			shift[uid] = Vector2((left_pair + wc + gap + wb * 0.5 - a.x) * blend, 0.0)
		var cy: float = a.y - BADGE_CENTER_UP * bs * bm * blend
		tr.position = Vector2(left, cy - float(ICON_PX) * k * 0.5)
		tr.size = Vector2(wc, hc)
		tr.visible = true
		c["unit"] = uid
	_layout_banners(cam, bs, bm, dt, shift)
	view.set("v2_badge_shift", shift)


## One texture per hex: the artifacts' icons in a row (structure first, then bases, then the occupier badge).
func _cluster_texture(row: Array, reveal: bool) -> ImageTexture:
	var n: int = row.size()
	var W: int = n * (ICON_PX + GAP_PX)
	var any_bar := false
	for it in row:
		if _bar_visible(it, reveal):
			any_bar = true
	var H: int = ICON_PX + (14 if any_bar else 2)
	var img := Image.create(W, H, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for i in range(n):
		var it: Dictionary = row[i]
		var x0: int = i * (ICON_PX + GAP_PX)
		var owner_col: Color = COL_OWNER.get(str(it["owner"]), COL_OWNER["neutral"])
		_icon(img, x0, it["kind"], owner_col)
		if _bar_visible(it, reveal):
			_bar(img, x0 + 2, ICON_PX + 3, ICON_PX - 4, 8, float(it["hp"]) / float(maxi(1, int(it["max"]))))
	return ImageTexture.create_from_image(img)


func _bar_visible(it: Dictionary, reveal: bool) -> bool:
	if not it.has("hp"):
		return false
	if int(it["hp"]) <= 0 and str(it["kind"]) == "edge":
		return false
	if str(it["kind"]) == "edge":
		return false   # edge bases cannot be touched: nothing to gauge
	if reveal:
		return true
	return bool(it.get("bar_always_if_damaged", false)) and int(it["hp"]) < int(it["max"])


func _icon(img: Image, x0: int, kind: String, owner_col: Color) -> void:
	var cx: float = float(x0) + float(ICON_PX) * 0.5
	var cy: float = float(ICON_PX) * 0.5
	var r: float = float(ICON_PX) * 0.5 - 1.0
	var small: bool = kind == "occupier"
	var rr: float = r * (0.62 if small else 1.0)
	var seal: Color = Color(0.17, 0.30, 0.55) if owner_col == COL_OWNER["blue"] else (Color(0.58, 0.16, 0.12) if owner_col == COL_OWNER["red"] else Color(0.30, 0.30, 0.32))
	for y in range(ICON_PX):
		for x in range(x0, x0 + ICON_PX):
			var d: float = Vector2(float(x) - cx, float(y) - cy).length()
			if d <= rr:
				# same look as the unit badge: gold rim, faction-coloured seal (blue / red), darker toward the rim
				if d > rr - 3.5:
					img.set_pixel(x, y, Color(0.78, 0.64, 0.34))
				elif d > rr - 6.5:
					img.set_pixel(x, y, seal.darkened(0.25))
				else:
					img.set_pixel(x, y, seal)
	var g := Color(0.92, 0.88, 0.75)
	var gx: int = int(cx)
	var gy: int = int(cy)
	var png: Image = _glyph_png(kind)
	if png != null:
		_blit_glyph(img, gx, gy, png, int(float(ICON_PX) * (0.40 if small else 0.66)), rr - 6.0)
		return
	match kind:
		"village":
			_rect(img, gx - 9, gy - 1, 18, 10, g)
			_tri(img, gx - 12, gy - 1, gx, gy - 11, gx + 12, gy - 1, g.darkened(0.2))
		"city":
			_rect(img, gx - 7, gy - 7, 14, 16, g)
			_rect(img, gx - 9, gy - 11, 5, 6, g)
			_rect(img, gx + 4, gy - 11, 5, 6, g)
			_rect(img, gx - 2, gy + 1, 4, 8, Color(0.1, 0.1, 0.13))
		"fortress":
			_rect(img, gx - 11, gy - 4, 22, 14, g)
			for k in range(3):
				_rect(img, gx - 11 + k * 8, gy - 10, 5, 7, g)
		"base", "edge":
			var crate := Color(0.78, 0.62, 0.34)
			_rect(img, gx - 11, gy + 1, 11, 9, crate)
			_rect(img, gx, gy - 4, 11, 14, crate.darkened(0.15))
			_rect(img, gx - 11, gy + 5, 22, 2, Color(0.4, 0.28, 0.14))
			_rect(img, gx + 5, gy - 12, 2, 9, Color(0.4, 0.28, 0.14))
			_rect(img, gx + 7, gy - 12, 7, 5, owner_col)
			if kind == "edge":
				_tri(img, gx - 4, gy - 8, gx - 11, gy - 14, gx + 3, gy - 14, Color(1.0, 0.86, 0.3))
		"occupier":
			_rect(img, gx - 4, gy - 6, 8, 12, owner_col.lightened(0.15))


## Hand-drawn glyph PNGs (assets/ui/v2_icons/<name>.png, see V2_ICON_COLD_PROMPT.md) replace the procedural
## fallback glyphs once they exist. #FF00FF backgrounds are keyed out; the owner ring is always drawn by code.
const ICON_DIR := "res://assets/ui/v2_icons/"
const ICON_FILE := {"village": "village", "city": "city", "fortress": "fortress", "base": "supply_base",
	"edge": "edge_base", "occupier": "occupier"}
static var _png_cache: Dictionary = {}   # kind -> Image (RGBA8, keyed) or null


static var _png_mtime: Dictionary = {}   # kind -> modified time of the file when it was loaded


static func _png_path(kind: String) -> String:
	return ICON_DIR + str(ICON_FILE.get(kind, kind)) + ".png"


## True when any icon PNG was added / replaced / removed since it was last loaded (hot reload while playing).
func _png_changed() -> bool:
	var changed := false
	for kind in ICON_FILE:
		var path: String = _png_path(kind)
		var m: int = int(FileAccess.get_modified_time(path)) if FileAccess.file_exists(path) else 0
		if int(_png_mtime.get(kind, -1)) != m:
			_png_cache.erase(kind)
			_png_mtime.erase(kind)
			changed = true
	return changed


## Loads assets/ui/v2_icons/<name>.png ready for use even if it was cropped by hand: #FF00FF and a flat
## background colour touching the corners are keyed out, the empty margins are trimmed and the glyph is
## padded to a square.
static func _glyph_png(kind: String) -> Image:
	if _png_cache.has(kind):
		return _png_cache[kind]
	var img: Image = null
	var path: String = _png_path(kind)
	_png_mtime[kind] = int(FileAccess.get_modified_time(path)) if FileAccess.file_exists(path) else 0
	if FileAccess.file_exists(path):
		var raw := Image.load_from_file(ProjectSettings.globalize_path(path))
		if raw != null and not raw.is_empty():
			raw.convert(Image.FORMAT_RGBA8)
			_key_background(raw)
			var used: Rect2i = raw.get_used_rect()
			if used.size.x > 0 and used.size.y > 0:
				raw = raw.get_region(used)
				var side: int = maxi(raw.get_width(), raw.get_height())
				var sq := Image.create(side, side, false, Image.FORMAT_RGBA8)
				sq.fill(Color(0, 0, 0, 0))
				sq.blit_rect(raw, Rect2i(Vector2i.ZERO, raw.get_size()), Vector2i((side - raw.get_width()) / 2, (side - raw.get_height()) / 2))
				img = sq
	_png_cache[kind] = img
	return img


static func _key_background(raw: Image) -> void:
	var w: int = raw.get_width()
	var h: int = raw.get_height()
	# 1) pure magenta
	for y in range(h):
		for x in range(w):
			var c: Color = raw.get_pixel(x, y)
			if c.r > 0.94 and c.g < 0.08 and c.b > 0.94:
				raw.set_pixel(x, y, Color(0, 0, 0, 0))
	# 2) an opaque flat background reaching the corners (a hand crop out of a contact sheet): flood it away
	var corners: Array = [Vector2i(0, 0), Vector2i(w - 1, 0), Vector2i(0, h - 1), Vector2i(w - 1, h - 1)]
	var bg: Color = raw.get_pixel(0, 0)
	if bg.a < 0.95:
		return
	for cn in corners:
		var cc: Color = raw.get_pixel(cn.x, cn.y)
		if cc.a < 0.95 or absf(cc.r - bg.r) + absf(cc.g - bg.g) + absf(cc.b - bg.b) > 0.12:
			return
	var seen := PackedByteArray()
	seen.resize(w * h)
	var stack: Array = corners.duplicate()
	while not stack.is_empty():
		var p: Vector2i = stack.pop_back()
		if p.x < 0 or p.y < 0 or p.x >= w or p.y >= h:
			continue
		var idx: int = p.y * w + p.x
		if seen[idx] == 1:
			continue
		seen[idx] = 1
		var c2: Color = raw.get_pixel(p.x, p.y)
		if c2.a < 0.05 or absf(c2.r - bg.r) + absf(c2.g - bg.g) + absf(c2.b - bg.b) <= 0.20:
			raw.set_pixel(p.x, p.y, Color(0, 0, 0, 0))
			stack.append(Vector2i(p.x + 1, p.y))
			stack.append(Vector2i(p.x - 1, p.y))
			stack.append(Vector2i(p.x, p.y + 1))
			stack.append(Vector2i(p.x, p.y - 1))


## Alpha-blends the PNG glyph, scaled to `px`, centred on (cx, cy).
func _blit_glyph(img: Image, cx: int, cy: int, glyph: Image, px: int, clip_r: float = 1e9) -> void:
	var g: Image = glyph.duplicate()
	g.resize(px, px, Image.INTERPOLATE_LANCZOS)
	var x0: int = cx - px / 2
	var y0: int = cy - px / 2
	for y in range(px):
		for x in range(px):
			var sc: Color = g.get_pixel(x, y)
			if sc.a <= 0.0:
				continue
			var tx: int = x0 + x
			var ty: int = y0 + y
			if Vector2(float(tx - cx), float(ty - cy)).length() > clip_r:
				continue   # never paint over the gold rim
			if tx < 0 or ty < 0 or tx >= img.get_width() or ty >= img.get_height():
				continue
			var dc: Color = img.get_pixel(tx, ty)
			var a: float = sc.a
			img.set_pixel(tx, ty, Color(sc.r * a + dc.r * (1.0 - a), sc.g * a + dc.g * (1.0 - a), sc.b * a + dc.b * (1.0 - a), maxf(dc.a, a)))


func _rect(img: Image, x: int, y: int, w: int, h: int, col: Color) -> void:
	for yy in range(maxi(0, y), mini(img.get_height(), y + h)):
		for xx in range(maxi(0, x), mini(img.get_width(), x + w)):
			img.set_pixel(xx, yy, col)


func _tri(img: Image, x1: int, y1: int, x2: int, y2: int, x3: int, y3: int, col: Color) -> void:
	var minx: int = mini(x1, mini(x2, x3))
	var maxx: int = maxi(x1, maxi(x2, x3))
	var miny: int = mini(y1, mini(y2, y3))
	var maxy: int = maxi(y1, maxi(y2, y3))
	for y in range(maxi(0, miny), mini(img.get_height(), maxy + 1)):
		for x in range(maxi(0, minx), mini(img.get_width(), maxx + 1)):
			var d1: float = float((x - x2) * (y1 - y2) - (x1 - x2) * (y - y2))
			var d2: float = float((x - x3) * (y2 - y3) - (x2 - x3) * (y - y3))
			var d3: float = float((x - x1) * (y3 - y1) - (x3 - x1) * (y - y1))
			var neg: bool = d1 < 0.0 or d2 < 0.0 or d3 < 0.0
			var pos: bool = d1 > 0.0 or d2 > 0.0 or d3 > 0.0
			if not (neg and pos):
				img.set_pixel(x, y, col)


func _bar(img: Image, x: int, y: int, w: int, h: int, frac: float) -> void:
	_rect(img, x - 1, y - 1, w + 2, h + 2, Color(0.05, 0.05, 0.06, 0.92))
	_rect(img, x, y, w, h, Color(0.22, 0.20, 0.18))
	var col := Color(0.45, 0.85, 0.40) if frac > 0.5 else (Color(0.90, 0.70, 0.25) if frac > 0.25 else Color(0.90, 0.30, 0.25))
	_rect(img, x, y, int(float(w) * clampf(frac, 0.0, 1.0)), h, col)
