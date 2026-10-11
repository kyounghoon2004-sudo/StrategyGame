class_name Step6SupplyOverlay
extends Node2D

## STEP-06R3 Supply Network & Settler-Lens Coverage Overlay Renderer
## Renders Dijkstra multi-tier reach envelopes (Bright Gold / Light Amber / Muted Fringe)
## and Trader supply NPC routes with 2-hex service corridors.
## Canonical Z-index: 22 (Above base terrain 0 and fog 15, strictly below live units 100-180).

const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")
const S6 = preload("res://scripts/step6/step6_config.gd")

# Settler-lens supply coverage palette (§10) - Historical Antique Gold / Illuminated Veins
const COLOR_TIER_STRONG_FILL: Color = Color(0.88, 0.72, 0.28, 0.38)
const COLOR_TIER_STRONG_BORDER: Color = Color(0.96, 0.86, 0.45, 0.95)

const COLOR_TIER_MODERATE_FILL: Color = Color(0.78, 0.60, 0.24, 0.26)
const COLOR_TIER_MODERATE_BORDER: Color = Color(0.85, 0.70, 0.35, 0.75)

const COLOR_TIER_FRINGE_FILL: Color = Color(0.65, 0.50, 0.22, 0.14)
const COLOR_TIER_FRINGE_BORDER: Color = Color(0.72, 0.58, 0.28, 0.50)

# Mobile hub / corridor palette (§21, §30) - Luminous Antique Gold
const COLOR_HUB_FILL: Color = Color(0.92, 0.78, 0.32, 0.35)
const COLOR_HUB_BORDER: Color = Color(0.98, 0.88, 0.45, 0.95)
const COLOR_HUB_OUTER_RING: Color = Color(0.96, 0.84, 0.38, 0.85)

const COLOR_CORRIDOR_FILL: Color = Color(0.85, 0.70, 0.28, 0.12)
const COLOR_CORRIDOR_BORDER: Color = Color(0.88, 0.76, 0.38, 0.45)
const COLOR_CORRIDOR_SEL_FILL: Color = Color(0.92, 0.78, 0.32, 0.26)
const COLOR_CORRIDOR_SEL_BORDER: Color = Color(0.98, 0.88, 0.45, 0.85)

const COLOR_ROUTE_UNSELECTED: Color = Color(0.85, 0.70, 0.30, 0.55)
const COLOR_ROUTE_SELECTED: Color = Color(0.98, 0.88, 0.45, 0.98)

const COLOR_NODE_PULSE: Color = Color(0.98, 0.90, 0.50, 0.98)

# Coverage data: "q,r" -> { "coord": Vector2i, "tier": int } (0=strong, 1=moderate, 2=fringe)
var _coverage_data: Dictionary = {}
var _routes: Array = [] # Array of { "id": String, "points": PackedVector2Array, "corridor": Dictionary, "selected": bool }
var _preview_route: Dictionary = {} # { "points": PackedVector2Array, "corridor": Dictionary }
var _hub_centers: Array[Vector2i] = []
var _hub_radius_hexes: Dictionary = {} # "q,r" -> Vector2i
var _selected_node_coord: Vector2i = Vector2i(-999, -999)
var _pulse_phase: float = 0.0
var _last_pulse_step: int = -1

func _ready() -> void:
	z_index = 22
	set_process(true)

func _process(delta: float) -> void:
	_pulse_phase += delta * 3.0
	if _pulse_phase > TAU:
		_pulse_phase -= TAU
	if not _coverage_data.is_empty() or not _routes.is_empty() or not _preview_route.is_empty() or not _hub_radius_hexes.is_empty() or _selected_node_coord.x != -999:
		# PERF: all animation derives from _pulse_phase, so sample redraws on
		# phase steps instead of every frame. Same shimmer, ~1/7 the _draw cost.
		var step: int = int(_pulse_phase * 8.0)
		if step != _last_pulse_step:
			_last_pulse_step = step
			queue_redraw()

func clear_all() -> void:
	_coverage_data.clear()
	_routes.clear()
	_preview_route.clear()
	_hub_centers.clear()
	_hub_radius_hexes.clear()
	_selected_node_coord = Vector2i(-999, -999)
	queue_redraw()

func set_coverage_hexes(hexes: Array) -> void:
	_coverage_data.clear()
	for h in hexes:
		var v: Vector2i = h as Vector2i
		_coverage_data["%d,%d" % [v.x, v.y]] = { "coord": v, "tier": 1 }
	queue_redraw()

func add_coverage_hexes(hexes: Array) -> void:
	for h in hexes:
		var v: Vector2i = h as Vector2i
		_coverage_data["%d,%d" % [v.x, v.y]] = { "coord": v, "tier": 1 }
	queue_redraw()

func set_coverage_with_costs(costs: Dictionary, budget: float = S6.COVERAGE_HQ) -> void:
	_coverage_data.clear()
	add_coverage_with_costs(costs, budget)

func add_coverage_with_costs(costs: Dictionary, budget: float = S6.COVERAGE_HQ) -> void:
	var b: float = maxf(1.0, budget)
	for key in costs.keys():
		var cost: float = float(costs[key])
		var ratio: float = cost / b
		var tier: int = 1
		if ratio <= S6.REACH_TIER_STRONG:
			tier = 0 # Strong / Bright Gold
		elif ratio <= S6.REACH_TIER_MODERATE:
			tier = 1 # Moderate / Light Amber
		else:
			tier = 2 # Fringe / Muted
		
		var coord: Vector2i
		if key is Vector2i:
			coord = key
		else:
			var parts: PackedStringArray = str(key).split(",")
			if parts.size() >= 2:
				coord = Vector2i(int(parts[0]), int(parts[1]))
			else:
				continue
		var k_str: String = "%d,%d" % [coord.x, coord.y]
		if _coverage_data.has(k_str):
			var old_tier: int = int(_coverage_data[k_str].get("tier", 2))
			if tier < old_tier:
				_coverage_data[k_str]["tier"] = tier
		else:
			_coverage_data[k_str] = { "coord": coord, "tier": tier }
	queue_redraw()

func set_active_routes(routes_data: Variant) -> void:
	if routes_data is Dictionary:
		var arr: Array = []
		for cid in (routes_data as Dictionary).keys():
			var r: Dictionary = routes_data[cid]
			arr.append({
				"id": cid,
				"path": r.get("full_path", r.get("path", [])),
				"radius": S6.SUPPLY_UNIT_SERVICE_RADIUS
			})
		set_routes(arr)
	elif routes_data is Array:
		set_routes(routes_data)

func preview_candidate_route(path: Array) -> void:
	set_preview_route(path)

func set_mobile_hubs(centers: Array, radius: int = 2, _label_text: String = "") -> void:
	_hub_centers.clear()
	_hub_radius_hexes.clear()
	for c in centers:
		var cv: Vector2i = c as Vector2i
		_hub_centers.append(cv)
		for dq in range(-radius, radius + 1):
			for dr in range(maxi(-radius, -dq - radius), mini(radius, -dq + radius) + 1):
				var h := Vector2i(cv.x + dq, cv.y + dr)
				_hub_radius_hexes["%d,%d" % [h.x, h.y]] = h
	queue_redraw()

func set_single_hub(center: Vector2i, radius: int = 2, _label_text: String = "") -> void:
	_hub_centers = [center]
	_hub_radius_hexes.clear()
	for dq in range(-radius, radius + 1):
		for dr in range(maxi(-radius, -dq - radius), mini(radius, -dq + radius) + 1):
			var h := Vector2i(center.x + dq, center.y + dr)
			_hub_radius_hexes["%d,%d" % [h.x, h.y]] = h
	queue_redraw()

func set_selected_node(coord: Vector2i, _label_text: String = "") -> void:
	_selected_node_coord = coord
	queue_redraw()

func set_routes(routes_data: Array) -> void:
	_routes.clear()
	for rd in routes_data:
		var rdict: Dictionary = rd as Dictionary
		var path: Array = rdict.get("path", [])
		if path.size() < 2:
			continue
		var pts: PackedVector2Array = PackedVector2Array()
		var corridor: Dictionary = {}
		var rad: int = int(rdict.get("radius", S6.SUPPLY_UNIT_SERVICE_RADIUS))
		for p in path:
			var pv: Vector2i = p as Vector2i
			pts.append(HexUtilsCls.hex_to_pixel(pv.x, pv.y))
			for dq in range(-rad, rad + 1):
				for dr in range(maxi(-rad, -dq - rad), mini(rad, -dq + rad) + 1):
					var h := Vector2i(pv.x + dq, pv.y + dr)
					corridor["%d,%d" % [h.x, h.y]] = h
		_routes.append({
			"id": str(rdict.get("id", "")),
			"points": pts,
			"corridor": corridor,
			"selected": bool(rdict.get("selected", false))
		})
	queue_redraw()

func set_preview_route(path: Array, radius: int = 2) -> void:
	_preview_route.clear()
	if path.size() < 2:
		queue_redraw()
		return
	var pts: PackedVector2Array = PackedVector2Array()
	var corridor: Dictionary = {}
	for p in path:
		var pv: Vector2i = p as Vector2i
		pts.append(HexUtilsCls.hex_to_pixel(pv.x, pv.y))
		for dq in range(-radius, radius + 1):
			for dr in range(maxi(-radius, -dq - radius), mini(radius, -dq + radius) + 1):
				var h := Vector2i(pv.x + dq, pv.y + dr)
				corridor["%d,%d" % [h.x, h.y]] = h
	_preview_route = {
		"points": pts,
		"corridor": corridor
	}
	queue_redraw()

func clear_preview_route() -> void:
	_preview_route.clear()
	queue_redraw()

func clear_routes() -> void:
	_routes.clear()
	queue_redraw()

func _draw() -> void:
	# 1. Draw multi-tier Dijkstra supply coverage
	for key in _coverage_data.keys():
		var entry: Dictionary = _coverage_data[key]
		var h: Vector2i = entry.get("coord", Vector2i.ZERO)
		var tier: int = int(entry.get("tier", 1))
		var center: Vector2 = HexUtilsCls.hex_to_pixel(h.x, h.y)
		var corners: PackedVector2Array = _get_hex_corners(center, 21.0)
		
		var fill_col: Color
		var border_col: Color
		var border_w: float = 1.4
		if tier == 0:
			fill_col = COLOR_TIER_STRONG_FILL
			border_col = COLOR_TIER_STRONG_BORDER
			border_w = 2.2
		elif tier == 1:
			fill_col = COLOR_TIER_MODERATE_FILL
			border_col = COLOR_TIER_MODERATE_BORDER
			border_w = 1.8
		else:
			fill_col = COLOR_TIER_FRINGE_FILL
			border_col = COLOR_TIER_FRINGE_BORDER
			border_w = 1.4
			
		draw_colored_polygon(corners, fill_col)
		draw_polyline(corners, border_col, border_w, true)

	# 2. Draw mobile hub radius hexes (Vivid Yellow)
	for key in _hub_radius_hexes.keys():
		var h: Vector2i = _hub_radius_hexes[key]
		var center: Vector2 = HexUtilsCls.hex_to_pixel(h.x, h.y)
		var corners: PackedVector2Array = _get_hex_corners(center, 21.0)
		draw_colored_polygon(corners, COLOR_HUB_FILL)
		draw_polyline(corners, COLOR_HUB_BORDER, 2.2, true)

	# 2-1. Draw animated outer radius boundary rings for mobile hubs (2-hex perimeter)
	for c in _hub_centers:
		var c_pos: Vector2 = HexUtilsCls.hex_to_pixel(c.x, c.y)
		var pulse_hub: float = 0.5 + 0.5 * sin(_pulse_phase * 2.5)
		var ring_rad: float = 72.0 + 3.0 * pulse_hub
		draw_arc(c_pos, ring_rad, 0.0, TAU, 48, Color(COLOR_HUB_OUTER_RING.r, COLOR_HUB_OUTER_RING.g, COLOR_HUB_OUTER_RING.b, 0.70 + 0.30 * pulse_hub), 2.2, true)
		draw_arc(c_pos, ring_rad - 4.0, 0.0, TAU, 48, Color(COLOR_HUB_OUTER_RING.r, COLOR_HUB_OUTER_RING.g, COLOR_HUB_OUTER_RING.b, 0.35 * pulse_hub), 1.2, true)

	# 3. Draw active supply routes & corridors
	for r in _routes:
		var is_sel: bool = bool(r.get("selected", false))
		var corridor: Dictionary = r.get("corridor", {})
		var c_fill: Color = COLOR_CORRIDOR_SEL_FILL if is_sel else COLOR_CORRIDOR_FILL
		var c_border: Color = COLOR_CORRIDOR_SEL_BORDER if is_sel else COLOR_CORRIDOR_BORDER
		
		# Draw subtle corridor boundary
		for ckey in corridor.keys():
			var ch: Vector2i = corridor[ckey]
			var center: Vector2 = HexUtilsCls.hex_to_pixel(ch.x, ch.y)
			var corners: PackedVector2Array = _get_hex_corners(center, 20.0)
			draw_colored_polygon(corners, c_fill)
			draw_polyline(corners, c_border, 1.4, true)
			
		# Draw segmented route line
		var pts: PackedVector2Array = r.get("points", PackedVector2Array())
		if pts.size() >= 2:
			var line_col: Color = COLOR_ROUTE_SELECTED if is_sel else COLOR_ROUTE_UNSELECTED
			var line_w: float = 3.5 if is_sel else 2.0
			_draw_segmented_route(pts, line_col, line_w, is_sel)

	# 4. Draw preview route if active
	if not _preview_route.is_empty():
		var p_corridor: Dictionary = _preview_route.get("corridor", {})
		for ckey in p_corridor.keys():
			var ch: Vector2i = p_corridor[ckey]
			var center: Vector2 = HexUtilsCls.hex_to_pixel(ch.x, ch.y)
			var corners: PackedVector2Array = _get_hex_corners(center, 20.0)
			draw_colored_polygon(corners, Color(1.0, 0.85, 0.25, 0.25))
			draw_polyline(corners, Color(1.0, 0.95, 0.40, 0.85), 1.8, true)
		var p_pts: PackedVector2Array = _preview_route.get("points", PackedVector2Array())
		if p_pts.size() >= 2:
			_draw_segmented_route(p_pts, Color(1.0, 0.95, 0.50, 0.95), 3.2, true)

	# 5. Draw pulse on selected node
	if _selected_node_coord.x != -999:
		var center: Vector2 = HexUtilsCls.hex_to_pixel(_selected_node_coord.x, _selected_node_coord.y)
		var pulse: float = 0.5 + 0.5 * sin(_pulse_phase * 2.0)
		var r: float = 23.0 + 3.0 * pulse
		var corners: PackedVector2Array = _get_hex_corners(center, r)
		draw_polyline(corners, Color(COLOR_NODE_PULSE.r, COLOR_NODE_PULSE.g, COLOR_NODE_PULSE.b, 0.75 + 0.25 * pulse), 2.8, true)
		var corners_inner: PackedVector2Array = _get_hex_corners(center, r - 5.0)
		draw_polyline(corners_inner, Color(1.0, 1.0, 0.60, 0.45 + 0.35 * pulse), 1.5, true)

func _draw_segmented_route(pts: PackedVector2Array, color: Color, width: float, animate_pulse: bool) -> void:
	draw_polyline(pts, color, width, false)
	# Draw node beads along the line
	for i in range(pts.size()):
		var p: Vector2 = pts[i]
		var dot_rad: float = 3.5 if (i == 0 or i == pts.size() - 1) else 2.2
		if animate_pulse and (i == 0 or i == pts.size() - 1):
			dot_rad += 1.0 * (0.5 + 0.5 * sin(_pulse_phase * 3.0))
		draw_circle(p, dot_rad, color)

func _get_hex_corners(center: Vector2, radius: float) -> PackedVector2Array:
	var w: float = radius
	var h: float = radius * 0.866025
	return PackedVector2Array([
		center + Vector2(-w, 0),
		center + Vector2(-w * 0.5, -h),
		center + Vector2(w * 0.5, -h),
		center + Vector2(w, 0),
		center + Vector2(w * 0.5, h),
		center + Vector2(-w * 0.5, h),
		center + Vector2(-w, 0)
	])
