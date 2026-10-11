class_name BattlefieldHexVisualCompositor
extends Node2D

## BattlefieldHexVisualCompositor — PHASE S/T. ONE authoritative visual
## compositor. Children: BaseTerrain(Z0) Borders(Z1) Routes/Rivers(Z2)
## Transitions(Z3) Macros(Z4) Structures(Z5) Atmosphere(Z6) Feedback(Z10).
## Units (Z50+) and readability UI (Z60+) stay in UnitRenderer. Fog separate.
## Compute-once/cache; no per-frame rebuild; no gameplay mutation.

const Registry = preload("res://scripts/visual/hex_native/approved_asset_registry.gd")
const GrammarCls = preload("res://scripts/visual/hex_native/hex_visual_grammar.gd")
const BaseMeshCls = preload("res://scripts/visual/hex_native/hex_base_terrain_mesh.gd")
const RouteCls = preload("res://scripts/visual/hex_native/hex_route_autotiler.gd")
const RiverCls = preload("res://scripts/visual/hex_native/hex_river_autotiler.gd")
const ForestCls = preload("res://scripts/visual/hex_native/hex_forest_compositor.gd")
const MountainCls = preload("res://scripts/visual/hex_native/hex_mountain_compositor.gd")
const StructCls = preload("res://scripts/visual/hex_native/hex_structure_compositor.gd")
const OccupancyCls = preload("res://scripts/visual/hex_native/visual_occupancy_map.gd")
const FogRendererCls = preload("res://scripts/visual/hex_native/hex_fog_renderer.gd")
const DressingCls = preload("res://scripts/visual/hex_native/hex_dressing_compositor.gd")
const PresentationOrientationCls = preload("res://scripts/core/presentation_orientation.gd")
const VisualContract = preload("res://scripts/visual/visual_contract.gd")
const SemanticZoomCls = preload("res://scripts/step2r/semantic_zoom.gd")

const ROAD_COLOR := Color(0.52, 0.42, 0.30, 0.95)
const PASS_ROAD_COLOR := Color(0.72, 0.62, 0.44, 0.97)
const RIVER_COLOR := Color(0.30, 0.48, 0.55, 0.95)
const BANK_COLOR := Color(0.55, 0.50, 0.38, 0.55)
const HOVER_COLOR := Color(1.0, 0.85, 0.45, 0.92)
const SELECT_COLOR := Color(1.0, 0.75, 0.30, 0.98)
# Known-route exemption (§18): muted dusty path under mist.
const ROUTE_GHOST_COLOR := Color(0.56, 0.58, 0.62, 0.50)
const ROUTE_GHOST_BASE_ALPHA: float = 0.85
# Hex border hierarchy: authoritative dark-umber in visible, cool subdued slate in explored
const VISIBLE_BORDER_DARK := Color(0.18, 0.14, 0.09, 0.62)
const VISIBLE_BORDER_LIGHT := Color(0.85, 0.76, 0.58, 0.52)
const EXPLORED_BORDER_DARK := Color(0.32, 0.35, 0.40, 0.36)
const EXPLORED_BORDER_LIGHT := Color(0.68, 0.72, 0.78, 0.28)

var descriptors: Dictionary = {}
var occupancy = null
var forest_macros: Array = []
var mountain_macros: Array = []
var structure_plan: Array = []
var route_ribbons: Array = []
var river_channels: Array = []

var _base_layer: Node2D
var _border_layer: Node2D
var _route_layer: Node2D
var _trans_layer: Node2D
var _macro_layer: Node2D
var _struct_layer: Node2D
var _feedback_layer: Node2D
var _pass_layer: Node2D = null
var _fog_renderer: Node2D

var _hovered: Vector2i = Vector2i(-999, -999)
var _selected: Vector2i = Vector2i(-999, -999)
var _built: bool = false
var build_ms: float = 0.0
# Selective-fog exemption state (§21): cached road-corridor geometry above
# the fog mask. Rebuilt on build / fog-truth change only, never per frame.
var _known_fog = null
var _route_ghost: MeshInstance2D = null
var _border_ghost: Node2D = null
var _route_contrast: float = 1.0
var _current_zoom: float = 1.15
var _tutorial_ground_variation: bool = false

func _ready() -> void:
	z_index = -5
	_ensure_layers()

func _ensure_layers() -> void:
	if _base_layer == null:
		_base_layer = Node2D.new()
		_base_layer.name = "BaseTerrain"
		_base_layer.z_index = 0
		add_child(_base_layer)
	if _border_layer == null:
		_border_layer = Node2D.new()
		_border_layer.name = "TerrainEdges"
		_border_layer.z_index = 1
		add_child(_border_layer)
	if _route_layer == null:
		_route_layer = Node2D.new()
		_route_layer.name = "RoutesRivers"
		_route_layer.z_index = 2
		add_child(_route_layer)
	if _trans_layer == null:
		_trans_layer = Node2D.new()
		_trans_layer.name = "Transitions"
		_trans_layer.z_index = 3
		add_child(_trans_layer)
	if _macro_layer == null:
		_macro_layer = Node2D.new()
		_macro_layer.name = "MacroTerrain"
		_macro_layer.z_index = 4
		add_child(_macro_layer)
	if _struct_layer == null:
		_struct_layer = Node2D.new()
		_struct_layer.name = "Structures"
		_struct_layer.z_index = 5
		add_child(_struct_layer)
	if _feedback_layer == null:
		_feedback_layer = Node2D.new()
		_feedback_layer.name = "TacticalFeedback"
		_feedback_layer.z_index = 10
		add_child(_feedback_layer)
	if _pass_layer == null:
		_pass_layer = Node2D.new()
		_pass_layer.name = "PassOverlay"
		_pass_layer.z_index = 9
		add_child(_pass_layer)

## Full build. Call once after battlefield generation; again only when
## terrain/road/river/stronghold sets change. Units/fog update via light paths.
## `stronghold_specs`: the shell's stronghold_visual_specs() (id, role,
## anchor, footprint). The art stands on the anchor hex only.
func build_all(cell_data: Dictionary, river_cells: Dictionary, stronghold_cells: Dictionary, unit_coords: Array = [], fog = null, stronghold_specs: Array = [], tutorial_ground_variation: bool = false) -> Dictionary:
	var t0: int = Time.get_ticks_usec()
	_tutorial_ground_variation = tutorial_ground_variation
	_ensure_layers()
	_clear_layers()
	descriptors = GrammarCls.build_descriptors(cell_data, river_cells, stronghold_cells, unit_coords, fog, tutorial_ground_variation)
	occupancy = OccupancyCls.new()
	var coords: Array = descriptors.keys()
	occupancy.initialize(coords)
	var road_cells: Array[Vector2i] = []
	var river_list: Array[Vector2i] = []
	var mtn_set: Dictionary = {}
	for c in descriptors.keys():
		var d = descriptors[c]
		if bool(d.road_present):
			road_cells.append(c)
		if bool(d.river_present):
			river_list.append(c)
		if int(d.terrain_type) == 1:
			mtn_set[c] = true
			mtn_set["%d,%d" % [c.x, c.y]] = true
	occupancy.reserve_pass_corridors(road_cells, mtn_set, true)
	var clearance_cells: Array[Vector2i] = []
	for u in unit_coords:
		var uc: Vector2i = u if u is Vector2i else Vector2i(int(u.x), int(u.y))
		clearance_cells.append(uc)
	var empty_glades: Array[Vector2i] = []
	occupancy.reserve_unit_clearance(clearance_cells, empty_glades)
	occupancy.reserve_routes(road_cells)
	occupancy.reserve_rivers(river_list)
	# static slots -> geometry
	_build_base(tutorial_ground_variation)
	_build_routes_rivers()
	_build_transitions()
	mountain_macros = MountainCls.plan_macros(descriptors, occupancy, cell_data)
	forest_macros = ForestCls.plan_macros(descriptors, occupancy, cell_data)
	structure_plan = StructCls.plan_structures(descriptors, occupancy, cell_data, stronghold_specs)
	_build_macro_nodes()
	_build_dressing(unit_coords)
	_build_structure_nodes()
	_setup_fog(fog)
	_known_fog = fog
	_rebuild_route_ghost()
	_built = true
	build_ms = float(Time.get_ticks_usec() - t0) / 1000.0
	return stats()

func stats() -> Dictionary:
	var deco: int = 0
	var trans: int = 0
	var road_roles: Dictionary = {}
	var river_roles: Dictionary = {}
	for c in descriptors.keys():
		var d = descriptors[c]
		if int(d.decoration_role) != 0:
			deco += 1
		trans += (d.transition_roles as Array).size()
		road_roles[int(d.route_role)] = int(road_roles.get(int(d.route_role), 0)) + 1
		river_roles[int(d.river_role)] = int(river_roles.get(int(d.river_role), 0)) + 1
	return {
		"cells": descriptors.size(),
		"forest_macros": forest_macros.size(),
		"mountain_macros": mountain_macros.size(),
		"structures": structure_plan.size(),
		"route_polys": route_ribbons.size(),
		"river_polys": river_channels.size(),
		"decorations": deco,
		"transitions": trans,
		"road_roles": road_roles,
		"river_roles": river_roles,
		"build_ms": build_ms,
		"nodes": _count_nodes(),
	}

func _count_nodes() -> int:
	var n: int = 0
	for layer in [_base_layer, _border_layer, _route_layer, _trans_layer, _macro_layer, _struct_layer]:
		if is_instance_valid(layer):
			n += layer.get_child_count()
	return n

## Light path: fog truth changed -> refresh fog overlay + descriptor states only.
func refresh_fog(fog) -> void:
	if not _built:
		return
	if fog != null:
		var vis: Dictionary = fog.get("visible") if fog.get("visible") != null else {}
		var exp: Dictionary = fog.get("explored") if fog.get("explored") != null else {}
		for c in descriptors.keys():
			var skey: String = "%d,%d" % [c.x, c.y]
			descriptors[c].fog_state = 2 if (vis.has(skey) or vis.has(c)) else (1 if (exp.has(skey) or exp.has(c)) else 0)
	if is_instance_valid(_fog_renderer) and _fog_renderer.has_method("set_fog"):
		_fog_renderer.call("set_fog", fog)
	_known_fog = fog

	# Refresh mountain and forest owned cells to skip unexplored and modulate explored
	if is_instance_valid(_macro_layer):
		for child in _macro_layer.get_children():
			if child.has_method("refresh_fog"):
				child.call("refresh_fog", descriptors)

	# Subdue/hide non-objective structures in unexplored fog (§13, §17)
	if is_instance_valid(_struct_layer):
		for child in _struct_layer.get_children():
			var is_stronghold: bool = child.name.contains("Fortress") or child.name.contains("Capital")
			var fp = child.get_meta("logical_footprint", null)
			var fs: int = 0
			if fp is Array and not fp.is_empty():
				for fc in fp:
					if descriptors.has(fc):
						fs = maxi(fs, int(descriptors[fc].fog_state))
			if not is_stronghold:
				child.visible = (fs > 0)
				if fs == 1:
					child.modulate = Color(0.80, 0.82, 0.86, 0.90) # Muted memory
				elif fs == 2:
					child.modulate = Color.WHITE

	_rebuild_route_ghost()
	_rebuild_borders()

## Light path: unit moved -> update clearance flags only (no terrain rebuild).
func refresh_units(unit_coords: Array) -> void:
	if not _built:
		return
	var s: Dictionary = {}
	for u in unit_coords:
		s[u] = true
	for c in descriptors.keys():
		descriptors[c].unit_present = s.has(c)

func set_hovered(coord: Vector2i) -> void:
	_hovered = coord
	_draw_feedback()

func set_selected(coord: Vector2i) -> void:
	_selected = coord
	_draw_feedback()

func _clear_layers() -> void:
	for layer in [_base_layer, _border_layer, _route_layer, _trans_layer, _macro_layer, _struct_layer, _feedback_layer, _pass_layer]:
		if is_instance_valid(layer):
			for ch in layer.get_children():
				ch.queue_free()
	var ghost: Node = get_node_or_null("BorderGhostAboveFog")
	if is_instance_valid(ghost):
		ghost.queue_free()
	_border_ghost = null
	if is_instance_valid(_route_ghost):
		_route_ghost.queue_free()
		_route_ghost = null
	if is_instance_valid(_fog_renderer):
		_fog_renderer.queue_free()
		_fog_renderer = null
	_hover_line = null
	_select_line = null
	forest_macros = []
	mountain_macros = []
	structure_plan = []
	route_ribbons = []
	river_channels = []

func _build_base(tutorial_ground_variation: bool) -> void:
	var meshes: Array = BaseMeshCls.build_base_terrain(descriptors, tutorial_ground_variation)
	for mi in meshes:
		_base_layer.add_child(mi)
	_rebuild_borders()

func _build_routes_rivers() -> void:
	route_ribbons = RouteCls.build_ribbons(descriptors)
	river_channels = RiverCls.build_channels(descriptors)
	var groups: Dictionary = {}
	for item in river_channels:
		var d = descriptors[item.coord]
		var stem: String = "ford_edge_shallow_A" if int(d.river_role) == 4 else "riverbank_shallow_A"
		var key: String = Registry.path_for("ground", stem)
		if not groups.has(key):
			groups[key] = []
		var poly: PackedVector2Array = item.poly
		var expanded := PackedVector2Array()
		for v in poly:
			expanded.append(d.world_pos + (v - d.world_pos) * 1.27)
		var hex := PackedVector2Array()
		for v in BaseMeshCls.CANONICAL_VERTICES:
			hex.append(d.world_pos + v)
		for clipped in Geometry2D.intersect_polygons(expanded, hex):
			groups[key].append({"coord":item.coord, "poly":clipped})
	for key in groups:
		_add_surface_mesh(groups[key], key, _route_layer, "ApprovedRiverbanks", 0)
	_add_surface_mesh(river_channels, "", _route_layer, "RiverChannels", 1)
	groups.clear()
	for item in route_ribbons:
		# Terrain language v2: one dirt surface for every road role (the ribbon
		# polygon carries the shape), a stony one into passes, planks on bridges.
		var kind: String = "road"
		match int(item.role):
			7: kind = "pass"
			8: kind = "bridge"
		var key: String = Registry.route_path(kind)
		if not groups.has(key):
			groups[key] = []
		groups[key].append(item)
	for key in groups:
		var is_pass: bool = str(key).contains("road_pass")
		_add_surface_mesh(groups[key], key, _pass_layer if is_pass else _route_layer, "ApprovedRoad", 0 if is_pass else 2)

func _add_surface_mesh(items: Array, path: String, parent: Node2D, label: String, depth: int) -> void:
	var verts := PackedVector2Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	for item in items:
		var poly: PackedVector2Array = item.poly
		if poly.size() < 3:
			continue
		var triangles: PackedInt32Array = Geometry2D.triangulate_polygon(poly)
		var base: int = verts.size()
		var center: Vector2 = descriptors[item.coord].world_pos
		for v in poly:
			verts.append(v)
			uvs.append(Vector2(0.5,0.5) + (v-center)/Vector2(48,42))
		for idx in triangles:
			indices.append(base+idx)
	if verts.is_empty():
		return
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, Mesh.ARRAY_FLAG_USE_2D_VERTICES)
	var mi := MeshInstance2D.new()
	mi.name = label + ("_"+path.get_file().get_basename() if not path.is_empty() else "")
	mi.mesh = mesh
	mi.z_index = depth
	if not path.is_empty():
		mi.material = Registry.surface(path)
		mi.set_meta("approved_resource", path)
	else:
		mi.modulate = RIVER_COLOR
	parent.add_child(mi)

func _build_transitions() -> void:
	# Retire 4,238 generic rectangular stains. Approved ground and bank materials
	# supply the surface transition; the descriptor and topology remain unchanged.
	pass

func _build_macro_nodes() -> void:
	for n in MountainCls.build_nodes(mountain_macros, descriptors):
		_macro_layer.add_child(n)
	for n in ForestCls.build_nodes(forest_macros, descriptors):
		# Perspective presentation: forest volume comes from compact in-hex
		# trees (HexDressingCompositor); the multi-hex cluster sprites are
		# retired there, the forest understory hex stays.
		if _perspective():
			n.set("draw_sprites", false)
		_macro_layer.add_child(n)

## Presentation-only scenery (see HexDressingCompositor). Decals go in the
## base layer (under hex borders); standing dressing (incl. in-hex forest
## trees) is the LAST macro child; units always draw over it.
func _build_dressing(unit_coords: Array) -> void:
	for n in DressingCls.build_nodes(descriptors, unit_coords, _perspective()):
		if n.name == "DressingDecals":
			_base_layer.add_child(n)
		else:
			# After forest understory / peaks so in-hex trees sit on top of
			# the forest ground; still below structures and every unit.
			_macro_layer.add_child(n)

## Dynamic view: keep upright building sprites at the live nominal stretch.
var _struct_stretch: float = -1.0
var _struct_e: float = -1.0
var _struct_xf: Transform2D = Transform2D()

## Upright structure art grows a little as the view flattens (1 = top-down
## size) but ONE structure always stays inside ONE hex: the growth is capped
## per sprite so its drawn width never exceeds
## VisualContract.ONE_HEX_ART_MAX_WIDTH (see _structure_presence).
func _process(_delta: float) -> void:
	if not PresentationOrientationCls.perspective_active or not PresentationOrientationCls.board_presented() or not is_instance_valid(_struct_layer):
		return
	var st: float = PresentationOrientationCls.upright_stretch
	var ev: float = PresentationOrientationCls.view_e
	var xf: Transform2D = get_viewport().get_canvas_transform()
	if absf(ev - _struct_e) < 0.004 and xf.is_equal_approx(_struct_xf):
		return
	_struct_stretch = st
	_struct_e = ev
	_struct_xf = xf
	var per_pos: bool = PresentationOrientationCls.frame_provider.is_valid()
	var k: float = smoothstep(0.45, 1.0, ev)
	for g in _struct_layer.get_children():
		var is_fort: bool = str(g.name).contains("Fortress") or str(g.name).contains("Capital")
		if is_fort:
			# Objectives stay readable above terrain dressing, below units.
			(g as Node2D).z_as_relative = false
			(g as Node2D).z_index = 99
		for sp in g.get_children():
			if sp is Sprite2D and sp.has_meta("upright_base_y"):
				var s2 := sp as Sprite2D
				if not s2.has_meta("upright_base_x"):
					s2.set_meta("upright_base_x", s2.scale.x)
				var pres: float = lerpf(1.0, _structure_presence(s2), k)
				var st_here: float = PresentationOrientationCls.stretch_at_world(s2.global_position) if per_pos else st
				s2.scale = Vector2(float(s2.get_meta("upright_base_x")) * pres, float(s2.get_meta("upright_base_y")) * st_here * pres)

## Largest presence this sprite may take and still fit ONE hex.
static func _structure_presence(s2: Sprite2D) -> float:
	var w: float = float(s2.get_meta("content_width_world", VisualContract.ONE_HEX_ART_MAX_WIDTH))
	return clampf(VisualContract.ONE_HEX_ART_MAX_WIDTH / maxf(w, 1.0), 1.0, VisualContract.STRUCTURE_PRESENCE_MAX)

static func _perspective() -> bool:
	return PresentationOrientationCls.perspective_active

func _build_structure_nodes() -> void:
	for n in StructCls.build_nodes(structure_plan, descriptors):
		_struct_layer.add_child(n)

func _setup_fog(fog) -> void:
	_fog_renderer = FogRendererCls.new()
	_fog_renderer.name = "HexFog"
	# Global canvas order must be: structures < fog < feedback < units-sibling.
	# Compositor sits at z=-5 and child z chains are relative, so macros land
	# near global +3 and structures near +5; z=11 puts fog at global +6.
	_fog_renderer.z_index = 11
	add_child(_fog_renderer)
	_fog_renderer.call("configure", fog, descriptors)
	_rebuild_borders()

## Semantic zoom for the exemption layer (§15): contrast breathes, geometry
## never widens. Epsilon-gated; no rebuild.
func set_camera_zoom(zoom_val: float) -> void:
	if is_equal_approx(_current_zoom, zoom_val):
		return
	_current_zoom = zoom_val
	_route_contrast = SemanticZoomCls.route_contrast(SemanticZoomCls.zoom_t(zoom_val))
	_apply_route_contrast()

func _apply_route_contrast() -> void:
	if is_instance_valid(_route_ghost):
		_route_ghost.modulate = Color(1, 1, 1, ROUTE_GHOST_BASE_ALPHA * _route_contrast)
	if is_instance_valid(_route_layer):
		var base_a: float = clampf(0.95 * _route_contrast, 0.78, 1.12)
		_route_layer.modulate = Color(1, 1, 1, base_a)

## Known-route exemption (§3, §9): roads are remembered navigation info for
## EXPLORED_PAST only. In UNEXPLORED, road corridors are strictly concealed.
## Rebuilt on build / fog-truth change only.
func _rebuild_route_ghost() -> void:
	if is_instance_valid(_route_ghost):
		_route_ghost.queue_free()
		_route_ghost = null
	if route_ribbons.is_empty() or descriptors.is_empty():
		return
	if _known_fog == null:
		return # No fog mask active: normal roads suffice.
	var verts := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	for item in route_ribbons:
		var coord = item.coord
		if not descriptors.has(coord):
			continue
		# CRITICAL (§3): Only render route memory over EXPLORED_PAST (fog_state == 1)!
		# VISIBLE cells (fog_state == 2) have their textured road on base layer.
		# UNEXPLORED cells (fog_state == 0) must NEVER reveal roads or corridors!
		if int(descriptors[coord].fog_state) != 1:
			continue
		var poly: PackedVector2Array = item.poly
		if poly.size() < 3:
			continue
		var tris: PackedInt32Array = Geometry2D.triangulate_polygon(poly)
		if tris.is_empty():
			continue
		var base: int = verts.size()
		for v in poly:
			verts.append(v)
			colors.append(ROUTE_GHOST_COLOR)
		for idx in tris:
			indices.append(base + idx)
	if verts.is_empty():
		return
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, Mesh.ARRAY_FLAG_USE_2D_VERTICES)
	_route_ghost = MeshInstance2D.new()
	_route_ghost.name = "KnownRoutesAboveFog"
	_route_ghost.mesh = mesh
	_route_ghost.z_index = 10 # Under HexFog (Z11) so routes are unified under mist
	add_child(_route_ghost)
	_apply_route_contrast()

## Hex border policy:
## Keep the playable perimeter and fog-state transitions defined; omit internal
## same-state edges so neighboring ground cells read as one continuous field.
## UNEXPLORED interiors remain hidden.
## Rebuilt on build / fog-truth change only.
func _rebuild_borders() -> void:
	if is_instance_valid(_border_ghost):
		_border_ghost.queue_free()
		_border_ghost = null
	if not is_instance_valid(_border_layer):
		return
	for ch in _border_layer.get_children():
		ch.queue_free()
	if descriptors.is_empty():
		return

	var vis_descs: Dictionary = {}
	var exp_descs: Dictionary = {}
	for coord in descriptors.keys():
		var fs: int = int(descriptors[coord].fog_state)
		if fs == 2:
			vis_descs[coord] = descriptors[coord]
		elif fs == 1:
			exp_descs[coord] = descriptors[coord]

	# 1. Authoritative, high-contrast borders for CURRENTLY_VISIBLE
	if not vis_descs.is_empty():
		_build_state_border_meshes(_border_layer, vis_descs, VISIBLE_BORDER_DARK, VISIBLE_BORDER_LIGHT, "BordersVisible", false)

	# 2. Subdued, cool slate borders for EXPLORED_PAST (under morning haze)
	if not exp_descs.is_empty():
		_build_state_border_meshes(_border_layer, exp_descs, EXPLORED_BORDER_DARK, EXPLORED_BORDER_LIGHT, "BordersExplored", false)

func _build_state_border_meshes(parent: Node, cells: Dictionary, col_dark: Color, col_light: Color, group_name: String, continuous_tutorial_ground: bool) -> void:
	var dark_lines := PackedVector2Array()
	var light_lines := PackedVector2Array()

	for coord: Vector2i in cells:
		var desc = cells[coord]
		var role: int = int(desc.base_role) if ("base_role" in desc) else 0
		var use_light: bool = BaseMeshCls.DARK_GROUND_ROLES.has(role)
		var world_center: Vector2 = desc.world_pos

		for dir_idx in range(6):
			var neighbor_coord: Vector2i = coord + BaseMeshCls.DIRECTIONS[dir_idx]
			if not continuous_tutorial_ground:
				if not cells.has(neighbor_coord) or (coord.x < neighbor_coord.x or (coord.x == neighbor_coord.x and coord.y < neighbor_coord.y)):
					var legacy_edge: Vector2i = BaseMeshCls.DIR_EDGE_VERTICES[dir_idx]
					var legacy_p1: Vector2 = desc.world_pos + BaseMeshCls.CANONICAL_VERTICES[legacy_edge.x]
					var legacy_p2: Vector2 = desc.world_pos + BaseMeshCls.CANONICAL_VERTICES[legacy_edge.y]
					if use_light:
						light_lines.append(legacy_p1)
						light_lines.append(legacy_p2)
					else:
						dark_lines.append(legacy_p1)
						dark_lines.append(legacy_p2)
				continue
			if cells.has(neighbor_coord):
				continue
			# Edges against another fog state are emitted once; void-facing edges
			# define the outer hex map perimeter.
			var neighbor_on_map: bool = descriptors.has(neighbor_coord)
			if neighbor_on_map and int(descriptors[neighbor_coord].fog_state) > 0 and (coord.x > neighbor_coord.x or (coord.x == neighbor_coord.x and coord.y > neighbor_coord.y)):
				continue
			var edge_verts: Vector2i = BaseMeshCls.DIR_EDGE_VERTICES[dir_idx]
			var p1: Vector2 = world_center + BaseMeshCls.CANONICAL_VERTICES[edge_verts.x]
			var p2: Vector2 = world_center + BaseMeshCls.CANONICAL_VERTICES[edge_verts.y]
			if use_light:
				light_lines.append(p1)
				light_lines.append(p2)
			else:
				dark_lines.append(p1)
				dark_lines.append(p2)

	var group_node := Node2D.new()
	group_node.name = group_name
	_append_border_line_mesh(group_node, dark_lines, col_dark, group_name + "Dark")
	_append_border_line_mesh(group_node, light_lines, col_light, group_name + "Light")
	parent.add_child(group_node)

func _append_border_line_mesh(parent: Node, verts: PackedVector2Array, color: Color, mesh_name: String) -> void:
	if verts.is_empty():
		return
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts

	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays, [], {}, Mesh.ARRAY_FLAG_USE_2D_VERTICES)

	var border_instance := MeshInstance2D.new()
	border_instance.name = mesh_name
	border_instance.mesh = array_mesh
	border_instance.modulate = color
	parent.add_child(border_instance)

## Hover / selection outlines: two persistent Line2Ds moved on change (no
## node churn per hover). Corners are the canonical flat-top hex.
var _hover_line: Line2D = null
var _select_line: Line2D = null
const OUTLINE_VERTS: Array[Vector2] = [
	Vector2(-24.0, 0.0), Vector2(-12.0, -21.0), Vector2(12.0, -21.0),
	Vector2(24.0, 0.0), Vector2(12.0, 21.0), Vector2(-12.0, 21.0), Vector2(-24.0, 0.0),
]

func _draw_feedback() -> void:
	if not is_instance_valid(_feedback_layer):
		return
	if not is_instance_valid(_hover_line):
		_hover_line = _hex_outline(HOVER_COLOR, 2.0)
		_select_line = _hex_outline(SELECT_COLOR, 2.8)
	_hover_line.visible = descriptors.has(_hovered)
	if _hover_line.visible:
		_hover_line.position = descriptors[_hovered].world_pos
	_select_line.visible = descriptors.has(_selected) and _selected != _hovered
	if _select_line.visible:
		_select_line.position = descriptors[_selected].world_pos

func _hex_outline(color: Color, width: float) -> Line2D:
	var line := Line2D.new()
	line.width = width
	line.default_color = color
	line.antialiased = true
	line.z_index = 10
	for v in OUTLINE_VERTS:
		line.add_point(v)
	line.visible = false
	_feedback_layer.add_child(line)
	return line
