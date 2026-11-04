class_name V2FortLayer
extends Node3D

## 요새화: a hexagonal ring of WOODEN palisade (the existing 01-wooden-palisade-wall asset, not the stone wall)
## around the fortified unit's hex. It rises segment by segment while the soldiers work, loses segments as its
## HP drops and sinks away when it is broken or the unit moves off. Lives under the 3D battle view.

const Lib = preload("res://scripts/visual/map_composition_v0/map_composition_library.gd")
const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")
const PresentationOrientationCls = preload("res://scripts/core/presentation_orientation.gd")

const S: float = 0.1875           # world px -> 3D units (civ view: HEXR 4.5 / 24)
const RING_R: float = 23.0        # ring circumradius in world px (hex circumradius is 24): wall to the hex edge
const WALL_H: float = 1.6         # taller than the asset's native proportion
const PER_SIDE: int = 2
const RISE_TIME: float = 0.55
const STAGGER: float = 0.11

var um: RefCounted = null
var view: Node = null
var artifacts: Node = null          # V2ArtifactLayer: decides when a gauge is shown (hover / click)
var _rings: Dictionary = {}       # unit id -> {"root","node"(ring),"gauge","segs","hp","max","side","sc"}
var _acc: float = 0.0
var _resting: Dictionary = {}     # unit id -> true while its rest visuals are on


func setup(unit_manager: RefCounted, civ_view: Node, artifact_layer: Node = null) -> void:
	um = unit_manager
	view = civ_view
	artifacts = artifact_layer
	name = "V2FortLayer"
	um.v2_fort_changed.connect(func(_id, _hp): _sync(true))


func _process(delta: float) -> void:
	# the palisade's HP gauge shows only while its unit's hex is hovered / pinned / the unit is selected
	if artifacts != null:
		for id in _rings:
			var u: Dictionary = um._units.get(id, {})
			if u.is_empty():
				continue
			var hex := Vector2i(int(u["q"]), int(u["r"]))
			var g: Sprite3D = _rings[id]["gauge"]
			g.visible = artifacts.is_revealed(hex)
	_acc += delta
	if _acc >= 0.25:
		_acc = 0.0
		_sync(false)


func _sync(animate: bool) -> void:
	if um == null:
		return
	for id in um._units:
		var u: Dictionary = um._units[id]
		var hp := int(u.get("fort_hp", 0))
		var alive := int(u.get("soldier_count", 0)) > 0
		if hp > 0 and alive:
			if not _rings.has(id):
				_build(id, u)
			else:
				_update(id, hp)
		elif _rings.has(id):
			_remove(id)
	for id in _rings.keys():
		if not um._units.has(id):
			_remove(id)
	# 휴식 visuals follow the rules flag (cleared at the next turn start)
	if view != null and view.has_method("v2_set_resting"):
		for id in um._units:
			var uu: Dictionary = um._units[id]
			var on: bool = bool(uu.get("rested_this_turn", false)) and int(uu.get("soldier_count", 0)) > 0
			if on and not _resting.has(id):
				_resting[id] = true
				view.call("v2_set_resting", id, true)
			elif not on and _resting.has(id):
				_resting.erase(id)
				view.call("v2_set_resting", id, false)


func _build(id: String, u: Dictionary) -> void:
	var root_n := Node3D.new()
	root_n.name = "Fort_" + id
	var p := HexUtilsCls.hex_to_pixel(int(u["q"]), int(u["r"]))
	root_n.position = Vector3(p.x * S, 0.0, p.y * S)
	add_child(root_n)
	var node := Node3D.new()
	node.name = "Ring"
	node.scale = Vector3.ONE * S
	root_n.add_child(node)
	var b: Dictionary = Lib.bounds("palisade")
	var native_len: float = maxf(float(b["half_xz"].x), float(b["half_xz"].y)) * 2.0
	var native_h: float = float(b["max"].y) - float(b["min"].y)
	var seg_len: float = RING_R / float(PER_SIDE)
	var sc: float = seg_len / maxf(native_len, 0.001)
	var segs: Array = []
	var k := 0
	for i in range(6):
		var theta: float = deg_to_rad(30.0 + 60.0 * float(i))
		var n := Vector2(cos(theta), sin(theta))
		var tangent := Vector2(-sin(theta), cos(theta))
		for slot in range(PER_SIDE):
			var off: float = (float(slot) - float(PER_SIDE - 1) * 0.5) * (RING_R / float(PER_SIDE))
			var c: Vector2 = n * (RING_R * 0.8660254) + tangent * off
			var holder := Node3D.new()
			holder.position = Vector3(c.x, 0.0, c.y)
			holder.rotation_degrees.y = rad_to_deg(atan2(-tangent.y, tangent.x))
			var seg := Lib.instance_grounded("palisade")
			holder.add_child(seg)
			holder.scale = Vector3(sc, 0.001, sc)       # rises from the ground
			node.add_child(holder)
			segs.append(holder)
			var tw := create_tween()
			tw.tween_interval(0.15 + STAGGER * float(k))
			tw.tween_property(holder, "scale", Vector3(sc, sc * WALL_H, sc), RISE_TIME).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
			k += 1
	# its own icon + HP gauge floating above the wall (billboard), separate from the unit's badge
	var wall_h: float = native_h * sc * WALL_H * S
	var gauge := Sprite3D.new()
	gauge.name = "Gauge"
	gauge.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	gauge.shaded = false
	gauge.no_depth_test = true
	gauge.render_priority = 30
	gauge.pixel_size = 0.06
	# in front of the wall (toward the player), so it never sits behind the unit's own badge
	var f2: Vector2 = PresentationOrientationCls.friendly_forward_world().normalized()
	gauge.position = Vector3(-f2.x, 0.0, -f2.y) * 4.6 + Vector3(0.0, 0.9, 0.0)
	root_n.add_child(gauge)
	var side := str(u.get("faction", "blue"))
	gauge.texture = _gauge_texture(1.0, side)
	_rings[id] = {"root": root_n, "node": node, "gauge": gauge, "segs": segs, "hp": int(u.get("fort_hp", 0)), "max": int(u.get("fort_hp_max", 1)), "sc": sc, "side": side}
	if view != null and view.has_method("v2_play_work"):
		view.call("v2_play_work", id, 4)
	if view != null and view.has_method("v2_fortify_dust"):
		view.call("v2_fortify_dust", id, RING_R)


## Palisade badge: owner-coloured disc with a fence glyph + its own HP gauge (drawn into one small texture).
func _gauge_texture(frac: float, side: String) -> ImageTexture:
	var W := 132
	var H := 44
	var img := Image.create(W, H, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var owner_col := Color(0.30, 0.60, 1.0) if side == "blue" else Color(0.95, 0.30, 0.28)
	var cx := 22.0
	var cy := 22.0
	for y in range(H):
		for x in range(W):
			var d := Vector2(float(x) - cx, float(y) - cy).length()
			if d <= 21.0:
				img.set_pixel(x, y, owner_col if d > 17.0 else Color(0.10, 0.10, 0.13, 0.96))
	# fence glyph: five pointed wooden stakes
	for k in range(5):
		var sx := 11 + k * 5
		for y in range(15, 31):
			for x in range(sx, sx + 3):
				img.set_pixel(x, y, Color(0.72, 0.52, 0.30))
		for t in range(3):
			img.set_pixel(sx + 1, 14 - t + 1, Color(0.72, 0.52, 0.30))
	for x in range(10, 35):
		img.set_pixel(x, 20, Color(0.45, 0.30, 0.16))
		img.set_pixel(x, 26, Color(0.45, 0.30, 0.16))
	# HP gauge
	var gx := 50
	var gw := 78
	var gy := 14
	var gh := 16
	for y in range(gy - 2, gy + gh + 2):
		for x in range(gx - 2, gx + gw + 2):
			img.set_pixel(x, y, Color(0.05, 0.05, 0.06, 0.92))
	for y in range(gy, gy + gh):
		for x in range(gx, gx + gw):
			var on: bool = float(x - gx) < float(gw) * clampf(frac, 0.0, 1.0)
			img.set_pixel(x, y, Color(0.86, 0.62, 0.28) if on else Color(0.22, 0.20, 0.18))
	return ImageTexture.create_from_image(img)


## Fewer segments stand as the palisade's HP drops.
func _update(id: String, hp: int) -> void:
	var r: Dictionary = _rings[id]
	if int(r["hp"]) == hp:
		return
	r["hp"] = hp
	(r["gauge"] as Sprite3D).texture = _gauge_texture(float(hp) / float(maxi(1, int(r["max"]))), str(r["side"]))
	var segs: Array = r["segs"]
	var standing: int = ceili(float(segs.size()) * float(hp) / float(maxi(1, int(r["max"]))))
	for i in range(segs.size()):
		var h: Node3D = segs[i]
		if i >= standing and h.visible:
			var tw := create_tween()
			tw.tween_property(h, "scale:y", 0.001, 0.25)
			tw.tween_callback(func(): if is_instance_valid(h): h.visible = false)


func _remove(id: String) -> void:
	var r: Dictionary = _rings[id]
	_rings.erase(id)
	var node: Node3D = r["node"]
	var root_n: Node3D = r["root"]
	if not is_instance_valid(root_n):
		return
	(r["gauge"] as Sprite3D).visible = false
	var tw := create_tween()
	tw.tween_property(node, "scale:y", 0.001, 0.45).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_callback(func(): if is_instance_valid(root_n): root_n.queue_free())
