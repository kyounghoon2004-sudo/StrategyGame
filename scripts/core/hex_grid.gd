class_name HexGrid
extends Node2D

## HexGrid — 48×42 Sprite2D terrain rendering + overlay system
## Flat-top odd-q (col_step=36, row_step=42, odd_y=21) per docs/art_guide.md

signal cell_clicked(cell, screen_pos: Vector2)
signal cell_hovered(cell)

# Art-guide tile geometry mirrors HexUtils
const TILE_W: int = 48
const TILE_H: int = 42
const COL_STEP: int = 36
const ROW_STEP: int = 42
const ODD_Q_Y_OFFSET: int = 21

# Terrain type enum alias (HexCell.TerrainType)
# 0:PLAINS 1:MOUNTAINS 2:FOREST 3:SWAMP 4:FORTRESS 5:VILLAGE 6:ROAD

var HexCellCls: Script = preload("res://scripts/core/hex_cell.gd")
const SandboxRulesCls = preload("res://scripts/core/sandbox_rules.gd")
var HexUtilsCls: Script = preload("res://scripts/core/hex_utils.gd")

## LEGACY PRESENTATION SWITCH (VISUAL ONLY). true (default) keeps the original
## behaviour for the legacy campaign BattleMap: per-cell terrain Sprite2Ds,
## overlay sprites, brute-force mouse picking and a deferred camera clamp.
## The Step2R battle sets it false in its .tscn: HexGrid is then a pure terrain
## DATA holder (cell_data); HexVisualCompositor draws every playable cell and
## the shell owns input and camera bounds. cell_data is identical either way.
@export var legacy_presentation: bool = true

var cell_data: Dictionary = {}
var hex_nodes: Dictionary = {}        # "q,r" -> Sprite2D (terrain)
var overlay_nodes: Dictionary = {}    # "q,r" -> Sprite2D overlay
var selection_node: Sprite2D = null
var selected_hex: Vector2i = Vector2i(-999, -999)
var hovered_hex: Vector2i = Vector2i(-999, -999)
var grid_size_q: int = 36
var grid_size_r: int = 24

# Overlay layers
var _terrain_layer: Node2D
var _overlay_layer: Node2D

# Preloaded textures
var _terrain_textures: Dictionary = {}
var _ui_move_tex: Texture2D
var _ui_attack_tex: Texture2D
var _ui_selection_tex: Texture2D
var _move_heatmap_textures: Dictionary = {}
var _fog_layer: Node2D
var _fog_nodes: Dictionary = {}
var _ambush_nodes: Dictionary = {}

func _ready() -> void:
	_ensure_layers()
	if not legacy_presentation:
		visible = false
		set_process_unhandled_input(false)
	else:
		_load_textures()
	if cell_data.is_empty():
		create_grid(grid_size_q, grid_size_r, "varied")
		generate_hexes()
	if legacy_presentation:
		call_deferred("_setup_camera_bounds")

func _ensure_layers() -> void:
	if _terrain_layer == null or not is_instance_valid(_terrain_layer):
		_terrain_layer = Node2D.new()
		_terrain_layer.name = "TerrainLayer"
		add_child(_terrain_layer)
	if _fog_layer == null or not is_instance_valid(_fog_layer):
		_fog_layer = Node2D.new()
		_fog_layer.name = "FogLayer"
		add_child(_fog_layer)
	if _overlay_layer == null or not is_instance_valid(_overlay_layer):
		_overlay_layer = Node2D.new()
		_overlay_layer.name = "OverlayLayer"
		add_child(_overlay_layer)
		# selection overlay on top (Selection / Target UI: z=250..300)
		selection_node = Sprite2D.new()
		selection_node.name = "SelectionOverlay"
		selection_node.centered = true
		selection_node.z_index = 250
		selection_node.visible = false
		if _ui_selection_tex:
			selection_node.texture = _ui_selection_tex
		_overlay_layer.add_child(selection_node)

func _load_textures() -> void:
	# Terrain textures
	var terrain_files: Dictionary = {
		0: "res://assets/tiles/terrain_plains.png",
		1: "res://assets/tiles/terrain_mountains.png",
		2: "res://assets/tiles/terrain_forest.png",
		3: "res://assets/tiles/terrain_swamp.png",
		4: "res://assets/tiles/terrain_fortress.png",
		5: "res://assets/tiles/terrain_village.png",
		6: "res://assets/tiles/terrain_road.png",
		7: "res://assets/tiles/terrain_river.png",
		8: "res://assets/tiles/terrain_wall.png",
	}
	for t in terrain_files.keys():
		var path: String = terrain_files[t]
		if ResourceLoader.exists(path):
			_terrain_textures[t] = load(path) as Texture2D
		elif FileAccess.file_exists(path):
			var img: Image = Image.load_from_file(path)
			if img != null:
				_terrain_textures[t] = ImageTexture.create_from_image(img)
		else:
			push_warning("[HexGrid] missing terrain texture: %s" % path)
	# UI overlays
	if ResourceLoader.exists("res://assets/ui/ui_move_range.png"):
		_ui_move_tex = load("res://assets/ui/ui_move_range.png") as Texture2D
	elif FileAccess.file_exists("res://assets/ui/ui_move_range.png"):
		var img_m: Image = Image.load_from_file("res://assets/ui/ui_move_range.png")
		if img_m: _ui_move_tex = ImageTexture.create_from_image(img_m)
	if ResourceLoader.exists("res://assets/ui/ui_attack_range.png"):
		_ui_attack_tex = load("res://assets/ui/ui_attack_range.png") as Texture2D
	elif FileAccess.file_exists("res://assets/ui/ui_attack_range.png"):
		var img_a: Image = Image.load_from_file("res://assets/ui/ui_attack_range.png")
		if img_a: _ui_attack_tex = ImageTexture.create_from_image(img_a)
	if ResourceLoader.exists("res://assets/ui/ui_selection.png"):
		_ui_selection_tex = load("res://assets/ui/ui_selection.png") as Texture2D
	elif FileAccess.file_exists("res://assets/ui/ui_selection.png"):
		var img_s: Image = Image.load_from_file("res://assets/ui/ui_selection.png")
		if img_s: _ui_selection_tex = ImageTexture.create_from_image(img_s)
	for heatmap_name in ["green", "orange", "red", "black"]:
		var heatmap_path: String = "res://assets/ui/ui_move_%s.png" % heatmap_name
		if ResourceLoader.exists(heatmap_path):
			_move_heatmap_textures[heatmap_name] = load(heatmap_path) as Texture2D
		elif FileAccess.file_exists(heatmap_path):
			var img_h: Image = Image.load_from_file(heatmap_path)
			if img_h: _move_heatmap_textures[heatmap_name] = ImageTexture.create_from_image(img_h)
	if selection_node and _ui_selection_tex:
		selection_node.texture = _ui_selection_tex

## Build HexCell data for rectangular odd-q grid
func create_grid(size_q: int, size_r: int, terrain_pattern: String = "") -> void:
	cell_data.clear()
	grid_size_q = size_q
	grid_size_r = size_r
	for q: int in range(size_q):
		for r: int in range(size_r):
			var key: String = "%d,%d" % [q, r]
			var terrain: int = 0
			if terrain_pattern == "varied":
				var hash_val: int = (q * 7 + r * 13) % 20
				if hash_val == 0:
					terrain = 1 # mountains
				elif hash_val == 1 or hash_val == 2:
					terrain = 2 # forest
				elif hash_val == 3:
					terrain = 3 # swamp
				elif hash_val == 4:
					terrain = 5 # village
				elif hash_val == 5:
					terrain = 6 # road
				elif hash_val == 6 and q > 2 and r > 2 and q < size_q - 2 and r < size_r - 2:
					terrain = 4 # fortress interior
			if q == int(size_q / 2) and r == int(size_r / 2):
				terrain = 4 # deterministic target fortress
			cell_data[key] = HexCellCls.new(q, r, terrain)

func generate_hexes() -> void:
	_ensure_layers()
	# clear old
	for node in hex_nodes.values():
		if is_instance_valid(node):
			node.queue_free()
	hex_nodes.clear()
	clear_overlays()
	if not legacy_presentation:
		return # data-only: no per-cell terrain sprites (see legacy_presentation)
	_load_textures()

	for key: String in cell_data.keys():
		var cell: Variant = cell_data[key]
		var pos: Vector2 = HexUtilsCls.hex_to_pixel(cell.q, cell.r)
		var tex: Texture2D = _terrain_textures.get(cell.terrain, null)
		var spr: Sprite2D = Sprite2D.new()
		spr.centered = true
		spr.position = pos
		spr.texture = tex
		spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		# fallback if texture missing: modulate tint
		if tex == null:
			spr.modulate = Color(0.5, 0.5, 0.5, 1)
		_terrain_layer.add_child(spr)
		hex_nodes[key] = spr
	# Move overlay layer on top of terrain
	if _overlay_layer:
		move_child(_overlay_layer, get_child_count() - 1)

func get_cell(q: int, r: int) -> Variant:
	var key: String = "%d,%d" % [q, r]
	if cell_data.has(key):
		return cell_data[key]
	return null

# ------------------------------------------------------------------
# Overlay system
# ------------------------------------------------------------------
func clear_overlays() -> void:
	for n in overlay_nodes.values():
		if is_instance_valid(n):
			n.queue_free()
	overlay_nodes.clear()
	if selection_node:
		selection_node.visible = false
	selected_hex = Vector2i(-999, -999)

func clear_move_attack_overlays() -> void:
	for n in overlay_nodes.values():
		if is_instance_valid(n):
			n.queue_free()
	overlay_nodes.clear()
	# keep selection


# ------------------------------------------------------------------
# Fog of war + ambush markers
# ------------------------------------------------------------------
func _hex_polygon() -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(-24, 0), Vector2(-12, -21), Vector2(12, -21),
		Vector2(24, 0), Vector2(12, 21), Vector2(-12, 21),
	])


func clear_fog() -> void:
	for node in _fog_nodes.values():
		if is_instance_valid(node):
			node.queue_free()
	_fog_nodes.clear()


func set_fog_hexes(hexes: Array) -> void:
	_ensure_layers()
	clear_fog()
	for item in hexes:
		var hex: Vector2i = _variant_to_hex(item)
		if hex.x >= 0 and hex.y >= 0:
			_add_fog_hex(hex)


func _variant_to_hex(value: Variant) -> Vector2i:
	if value is Vector2i:
		return value
	if value is Array and value.size() >= 2:
		return Vector2i(int(value[0]), int(value[1]))
	return Vector2i(-999, -999)


func _add_fog_hex(hex: Vector2i) -> void:
	var key: String = "%d,%d" % [hex.x, hex.y]
	if not cell_data.has(key) or _fog_nodes.has(key):
		return
	var fog: Polygon2D = Polygon2D.new()
	fog.name = "Fog_%s" % key.replace(",", "_")
	fog.position = HexUtilsCls.hex_to_pixel(hex.x, hex.y)
	fog.polygon = _hex_polygon()
	fog.color = Color(0.035, 0.045, 0.075, 0.84)
	fog.z_index = 15 # Below overlays (20) and live units (100+)
	_fog_layer.add_child(fog)
	_fog_nodes[key] = fog


func reveal_hex(q: int, r: int) -> void:
	var key: String = "%d,%d" % [q, r]
	var fog: Polygon2D = _fog_nodes.get(key) as Polygon2D
	if fog != null and is_instance_valid(fog):
		fog.queue_free()
	_fog_nodes.erase(key)


func reveal_hexes(hexes: Array) -> void:
	for item in hexes:
		var hex: Vector2i = _variant_to_hex(item)
		if hex.x >= 0 and hex.y >= 0:
			reveal_hex(hex.x, hex.y)


func reveal_area(center: Vector2i, radius: int = 3) -> void:
	var reveal_radius: int = maxi(0, radius)
	var to_reveal: Array[Vector2i] = []
	for value in cell_data.values():
		var cell: Variant = value
		var hex: Vector2i = Vector2i(int(cell.q), int(cell.r))
		if HexUtilsCls.hex_distance(center, hex) <= reveal_radius:
			to_reveal.append(hex)
	reveal_hexes(to_reveal)


func is_fogged(q: int, r: int) -> bool:
	return _fog_nodes.has("%d,%d" % [q, r])


func get_fog_count() -> int:
	return _fog_nodes.size()


func mark_ambush_hex(q: int, r: int) -> void:
	_ensure_layers()
	var key: String = "%d,%d" % [q, r]
	if not cell_data.has(key) or _ambush_nodes.has(key):
		return
	var marker: Polygon2D = Polygon2D.new()
	marker.name = "Ambush_%s" % key.replace(",", "_")
	marker.position = HexUtilsCls.hex_to_pixel(q, r)
	marker.polygon = _hex_polygon()
	marker.color = Color(0.72, 0.16, 0.10, 0.38)
	marker.z_index = 6
	_overlay_layer.add_child(marker)
	_ambush_nodes[key] = marker


func clear_ambush_hex(q: int, r: int) -> void:
	var key: String = "%d,%d" % [q, r]
	var marker: Polygon2D = _ambush_nodes.get(key) as Polygon2D
	if marker != null and is_instance_valid(marker):
		marker.queue_free()
	_ambush_nodes.erase(key)


func is_ambush_marked(q: int, r: int) -> bool:
	return _ambush_nodes.has("%d,%d" % [q, r])

func show_selection(q: int, r: int) -> void:
	if selection_node == null:
		_ensure_layers()
	selected_hex = Vector2i(q, r)
	var pos: Vector2 = HexUtilsCls.hex_to_pixel(q, r)
	selection_node.position = pos
	selection_node.texture = _ui_selection_tex
	selection_node.visible = true
	selection_node.z_index = 250
	# pulse
	var tw := create_tween().set_loops()
	tw.tween_property(selection_node, "modulate:a", 0.75, 0.45)
	tw.tween_property(selection_node, "modulate:a", 1.0, 0.45)

func hide_selection() -> void:
	if selection_node:
		selection_node.visible = false
	selected_hex = Vector2i(-999, -999)

func highlight_hexes(hexes: Array, texture: Texture2D, z: int = 5) -> void:
	if texture == null:
		return
	for h in hexes:
		var q: int = int(h.x)
		var r: int = int(h.y)
		var key: String = "%d,%d" % [q, r]
		if not cell_data.has(key):
			continue
		# skip if already has overlay (keep first)
		if overlay_nodes.has(key):
			continue
		var spr: Sprite2D = Sprite2D.new()
		spr.centered = true
		spr.position = HexUtilsCls.hex_to_pixel(q, r)
		spr.texture = texture
		spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		spr.z_index = z
		_overlay_layer.add_child(spr)
		overlay_nodes[key] = spr

func _heatmap_key(q: int, r: int) -> String:
	var cell: Variant = get_cell(q, r)
	var terrain_cost: int = 1
	if cell != null:
		match int(cell.terrain):
			1, 2: terrain_cost = 2
			3: terrain_cost = 3
			_: terrain_cost = 1
	var distance: int = 0
	if selected_hex.x != -999:
		distance = int(HexUtilsCls.hex_distance(selected_hex, Vector2i(q, r)))
	var fatigue_score: int = distance + terrain_cost - 1
	if fatigue_score <= 1:
		return "green"
	if fatigue_score <= 2:
		return "orange"
	if fatigue_score <= 3:
		return "red"
	return "black"


func show_move_heatmap(hexes: Array[Vector2i]) -> void:
	for hex in hexes:
		var key: String = _heatmap_key(hex.x, hex.y)
		var texture: Texture2D = _move_heatmap_textures.get(key, _ui_move_tex) as Texture2D
		highlight_hexes([hex], texture, 5)


func show_move_range(hexes: Array[Vector2i]) -> void:
	clear_move_attack_overlays()
	show_move_heatmap(hexes)


func show_attack_range(hexes: Array[Vector2i]) -> void:
	highlight_hexes(hexes, _ui_attack_tex, 6)


func show_ranges(move_hexes: Array[Vector2i], attack_hexes: Array[Vector2i]) -> void:
	clear_move_attack_overlays()
	show_move_heatmap(move_hexes)
	highlight_hexes(attack_hexes, _ui_attack_tex, 6)


## Blink tactical target hex (for RECON choice)
func blink_hex(hex: Vector2i, duration: float = 1.6, loops: int = 4) -> void:
	var q: int = hex.x
	var r: int = hex.y
	var pos: Vector2 = HexUtilsCls.hex_to_pixel(q, r)
	var spr: Sprite2D = Sprite2D.new()
	spr.centered = true
	spr.position = pos
	spr.texture = _ui_selection_tex if _ui_selection_tex else _ui_move_tex
	spr.z_index = 15
	spr.modulate = Color(1, 1, 0.6, 1)
	_overlay_layer.add_child(spr)
	var tw := create_tween()
	tw.set_loops(loops)
	tw.tween_property(spr, "modulate:a", 0.2, duration / float(loops * 2))
	tw.tween_property(spr, "modulate:a", 1.0, duration / float(loops * 2))
	tw.tween_callback(func(): if is_instance_valid(spr): spr.queue_free())

# ------------------------------------------------------------------
# Legacy highlight compatibility (Polygon2D modulate -> kept for tests)
# ------------------------------------------------------------------
func highlight_hex(q: int, r: int, do_highlight: bool) -> void:
	var key: String = "%d,%d" % [q, r]
	var node: Sprite2D = hex_nodes.get(key)
	if node == null:
		return
	if do_highlight:
		node.modulate = Color(1.0, 1.0, 0.5, 1.0)
	else:
		node.modulate = Color(1, 1, 1, 1)

func select_hex(q: int, r: int) -> void:
	if selected_hex.x != -999:
		highlight_hex(selected_hex.x, selected_hex.y, false)
	selected_hex = Vector2i(q, r)
	highlight_hex(q, r, true)
	show_selection(q, r)

# ------------------------------------------------------------------
# Coordinate helpers
# ------------------------------------------------------------------
func screen_to_hex(screen_pos: Vector2) -> Vector2i:
	# Brute nearest-cell among data for robust odd-q picking
	var best: Vector2i = Vector2i(-999, -999)
	var best_dist: float = 1e9
	for key: String in cell_data.keys():
		var cell: Variant = cell_data[key]
		var cpos: Vector2 = HexUtilsCls.hex_to_pixel(cell.q, cell.r)
		var d: float = cpos.distance_squared_to(screen_pos)
		if d < best_dist:
			best_dist = d
			best = Vector2i(cell.q, cell.r)
	# threshold: if closest center > hex radius ~24*sqrt approx, might be out of bounds
	# Return -999 if far outside map (e.g., > 60px from center)
	if best_dist > 2500.0: # 50px^2
		return Vector2i(-999, -999)
	return best

func _setup_camera_bounds() -> void:
	# DEV research sandbox: the shell owns the camera bounds for the R=40 board
	# (this deferred legacy call would clamp the research camera to the retired
	# 36x24 box, pushing the sandbox's opening frame off-centre). Production keeps
	# the legacy behaviour unchanged.
	if SandboxRulesCls.is_active():
		return
	var cam: Node = get_parent().get_node_or_null("Camera2D")
	if cam != null and cam.has_method("set_map_bounds"):
		var min_pos: Vector2 = HexUtilsCls.hex_to_pixel(0, 0)
		var max_pos: Vector2 = HexUtilsCls.hex_to_pixel(grid_size_q - 1, grid_size_r - 1)
		cam.set_map_bounds(min_pos - Vector2(TILE_W, TILE_H), max_pos + Vector2(TILE_W, TILE_H))

# ------------------------------------------------------------------
# Input
# ------------------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			var world_pos: Vector2 = get_global_mouse_position()
			var hex: Vector2i = screen_to_hex(world_pos)
			if hex.x == -999:
				return
			var cell: Variant = get_cell(hex.x, hex.y)
			if cell != null:
				# Don't auto select here if battle_map handles — still emit
				# Keep selection visual for standalone scene without battle_map
				if get_parent() and get_parent().has_method("_on_hex_clicked"):
					# battle_map will handle selection
					pass
				else:
					select_hex(hex.x, hex.y)
				cell_clicked.emit(cell, world_pos)
			get_viewport().set_input_as_handled()
	if event is InputEventMouseMotion:
		var world_pos2: Vector2 = get_global_mouse_position()
		var hex2: Vector2i = screen_to_hex(world_pos2)
		if hex2.x == -999:
			return
		if hex2 != hovered_hex:
			hovered_hex = hex2
			var cell2: Variant = get_cell(hex2.x, hex2.y)
			if cell2 != null:
				cell_hovered.emit(cell2)
