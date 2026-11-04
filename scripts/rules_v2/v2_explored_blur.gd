class_name V2ExploredBlur
extends Node2D

## 시야에서 벗어난 "탐사 완료" 지역의 부분 블러 (2026-11-01).
##
## 완전 안개가 아니다: 한 번 본 땅은 형태와 색이 남아 있어야 하므로, 이미 그려진 화면을
## 화면공간에서 흐리게 만든 패치를 헥스 위에 덮는다. 완전 미탐사는 civ_shroud가 맡는다.
## 헥스당 "균일 색" 폴리곤 두 장(바깥/안쪽)만 쓴다 — 정점 알파 팬은 삼각형 쐐기 아티팩트를
## 만들었으므로 쓰지 않는다.

const HEX_R := 24.0
const HEX_W := 36.0
const HEX_H := 42.0
const OUTER_A := 0.30
const INNER_A := 0.88

var _fog: Variant = null
var _hexes: Array = []
var _sig: int = 0
var _poll: float = 0.0


func setup(fog: Variant = null) -> void:
	z_index = 21
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://scripts/visual/shaders/v2_explored_blur.gdshader")
	material = mat
	set_fog(fog)


func _process(delta: float) -> void:
	if _fog != null:
		return
	_poll += delta
	if _poll < 0.25:
		return
	_poll = 0.0
	var p := get_parent()
	if p == null:
		return
	var f = p.get("_fog")
	if f != null:
		set_fog(f)


func set_fog(fog: Variant) -> void:
	_fog = fog
	_rebuild()


func _rebuild() -> void:
	_hexes.clear()
	_sig = 0
	if _fog == null:
		queue_redraw()
		return
	var explored: Dictionary = _fog.get("explored")
	var visible: Dictionary = _fog.get("visible")
	var sig: int = explored.size() * 7919 + visible.size() * 31
	for key in explored.keys():
		sig = sig ^ int(hash(key))
	if sig == _sig:
		return
	_sig = sig
	for key in explored.keys():
		if visible.has(key):
			continue
		var parts: PackedStringArray = str(key).split(",")
		if parts.size() != 2:
			continue
		var q: int = int(parts[0])
		var r: int = int(parts[1])
		_hexes.append(Vector2(HEX_W * float(q), HEX_H * float(r) + 21.0 * float(q)))
	queue_redraw()


func _draw() -> void:
	if _hexes.is_empty():
		return
	for c in _hexes:
		draw_colored_polygon(_ring(c, HEX_R), Color(1, 1, 1, OUTER_A))
		draw_colored_polygon(_ring(c, HEX_R * 0.82), Color(1, 1, 1, INNER_A))


func _ring(c: Vector2, r: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(6):
		var a := deg_to_rad(60.0 * float(i))
		pts.append(c + Vector2(cos(a), sin(a)) * r)
	return pts
