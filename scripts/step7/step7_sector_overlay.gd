class_name Step7SectorOverlay
extends Node2D

## Player-visible tactical-cluster overlay (adaptive formation clusters, DEV).
## Consumes Step7FormationClusters frozen bands ONLY — never recreates the
## partition math. Map/world anchored (child of the battle shell), so zoom and
## pan never change which hexes carry which band. One hex = one band color.
## File/class name kept stable (scene + probes load by path); the rendered
## authority is now the adaptive cluster map, not fixed sectors.

const ClustersScript = preload("res://scripts/step7/step7_formation_clusters.gd")
const PresentationOrientationCls = preload("res://scripts/core/presentation_orientation.gd")
const HexUtilsScript = preload("res://scripts/core/hex_utils.gd")

const EDGE := Color(1, 1, 1, 0.35)

var _show := false
var _highlight_cluster := ""
var _highlight_cells := {}
var _cache := {} # cluster id -> Array[Vector2i]
var _cache_sig := ""
var _labels: Array = []


func set_show(v: bool) -> void:
	_show = v
	visible = v
	for lab in _labels:
		if is_instance_valid(lab):
			(lab as Label).visible = v
	if v:
		_build_cache()
		_place_labels()
	queue_redraw()


func is_showing() -> bool:
	return _show


func set_highlight(cluster: String, cells: Array) -> void:
	_highlight_cluster = cluster.strip_edges().to_upper()
	_highlight_cells.clear()
	for c in cells:
		if c is Vector2i:
			_highlight_cells["%d,%d" % [(c as Vector2i).x, (c as Vector2i).y]] = true
	queue_redraw()


func cache_signature() -> String:
	return _cache_sig


func _cluster_color(cid: String) -> Color:
	var c := cid.strip_edges().to_upper()
	if c == "C":
		return Color(1.00, 0.90, 0.45, 0.12)
	if c.begins_with("L"):
		var depth := clampi(int(c.substr(1)) if c.length() > 1 and c.substr(1).is_valid_int() else 1, 1, 5)
		return Color(0.30, 0.55, 1.00, 0.10 + 0.03 * float(depth))
	if c.begins_with("R"):
		var depth2 := clampi(int(c.substr(1)) if c.length() > 1 and c.substr(1).is_valid_int() else 1, 1, 5)
		return Color(1.00, 0.45, 0.35, 0.10 + 0.03 * float(depth2))
	return Color(0.7, 0.7, 0.7, 0.10)


func _cluster_label(cid: String) -> String:
	var c := cid.strip_edges().to_upper()
	if c == "C":
		return "C · 중앙"
	if c.begins_with("L"):
		return "%s · %s" % [c, "극좌익" if c == ClustersScript.extreme_left() and not _is_single_left() else "좌익"]
	if c.begins_with("R"):
		return "%s · %s" % [c, "극우익" if c == ClustersScript.extreme_right() and not _is_single_right() else "우익"]
	return c


func _is_single_left() -> bool:
	var n := 0
	for cid in ClustersScript.cluster_ids():
		if str(cid).begins_with("L"):
			n += 1
	return n <= 1


func _is_single_right() -> bool:
	var n := 0
	for cid in ClustersScript.cluster_ids():
		if str(cid).begins_with("R"):
			n += 1
	return n <= 1


func _build_cache() -> void:
	var sig := ClustersScript.frozen_signature() + "|hexes=%d" % ClustersScript.band_map().size()
	if sig == _cache_sig and not _cache.is_empty():
		return
	_cache = {}
	for cid in ClustersScript.cluster_ids():
		_cache[str(cid)] = []
	for key in ClustersScript.band_map().keys():
		var cid := str(ClustersScript.band_map()[key])
		if not _cache.has(cid):
			_cache[cid] = []
		var parts := str(key).split(",")
		(_cache[cid] as Array).append(Vector2i(int(parts[0]), int(parts[1])))
	_cache_sig = sig


func _place_labels() -> void:
	for lab in _labels:
		if is_instance_valid(lab):
			(lab as Label).queue_free()
	_labels.clear()
	for cid in ClustersScript.cluster_ids():
		var info: Dictionary = ClustersScript.cluster_info(str(cid))
		if info.is_empty():
			continue
		var anchor := Vector2i(int(info.get("anchor_q", 0)), int(info.get("anchor_r", 0)))
		var lab := Label.new()
		lab.text = _cluster_label(str(cid))
		lab.add_theme_font_size_override("font_size", 40)
		lab.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
		lab.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
		lab.add_theme_constant_override("shadow_offset_x", 2)
		lab.add_theme_constant_override("shadow_offset_y", 2)
		# Upright under a rotated presentation (DEV sandbox chess-style board);
		# yaw 0 -> the original offset (pivot stays top-left here).
		# Only the SCREEN offset is re-expressed in world space (the anchor
		# itself must not be rotated about the origin).
		lab.position = HexUtilsScript.hex_to_pixel(anchor.x, anchor.y) + PresentationOrientationCls.upright_vector(Vector2(-90, -24))
		lab.rotation = PresentationOrientationCls.upright_rotation()
		lab.scale = PresentationOrientationCls.upright_scale()
		lab.z_index = 15
		lab.visible = _show
		add_child(lab)
		_labels.append(lab)


func _draw() -> void:
	if not _show:
		return
	var cam := get_viewport().get_camera_2d() as Camera2D
	var vis := Rect2(Vector2(-4000, -4000), Vector2(8000, 8000))
	if cam:
		var z := cam.zoom.x if absf(cam.zoom.x) > 0.001 else 1.0
		var size := get_viewport_rect().size / z
		vis = Rect2(cam.get_screen_center_position() - size * 0.6, size * 1.2)
	_build_cache()
	for cid in _cache.keys():
		var fill: Color = _cluster_color(str(cid))
		for c in (_cache[cid] as Array):
			var center: Vector2 = HexUtilsScript.hex_to_pixel((c as Vector2i).x, (c as Vector2i).y)
			if not vis.has_point(center):
				continue
			var poly := _corners(center, 21.0)
			draw_colored_polygon(poly, fill)
			var key := "%d,%d" % [(c as Vector2i).x, (c as Vector2i).y]
			if _wants_highlight(str(cid), key):
				draw_polyline(poly, Color(1, 1, 1, 0.95), 3.0, true)
				draw_circle(center, 6.0, Color(1, 1, 1, 0.9))


## Highlight matches an exact cluster id, or a macro wing (LEFT/CENTER/RIGHT)
## or extreme alias covering that cluster.
func _wants_highlight(cid: String, key: String) -> bool:
	if not _highlight_cells.has(key):
		return false
	if _highlight_cluster.is_empty():
		return true
	if cid == _highlight_cluster:
		return true
	return ClustersScript.wing_of_cluster(cid) == _highlight_cluster


func _corners(center: Vector2, radius: float) -> PackedVector2Array:
	var w: float = radius
	var h: float = radius * 0.866025
	return PackedVector2Array([
		center + Vector2(-w, 0),
		center + Vector2(-w * 0.5, -h),
		center + Vector2(w * 0.5, -h),
		center + Vector2(w, 0),
		center + Vector2(w * 0.5, h),
		center + Vector2(-w * 0.5, h),
		center + Vector2(-w, 0),
	])
