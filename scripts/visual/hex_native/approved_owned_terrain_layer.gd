extends Node2D

## Static draw commands, one cached composition per owning cell; no per-frame work.
const Registry = preload("res://scripts/visual/hex_native/approved_asset_registry.gd")
const PresentationOrientationCls = preload("res://scripts/core/presentation_orientation.gd")

var placements: Array = []
var understory_polys: Array = []
var family: int = 0
## false: draw only the understory (perspective presentation replaces the
## cluster sprites with compact in-hex trees).
var draw_sprites: bool = true
var approved_resources: Array[String] = []
var _descriptors: Dictionary = {}

func configure(p_family: int, entries: Array, descriptors: Dictionary) -> void:
	family = p_family
	_descriptors = descriptors
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	material = _art_grade_material()
	if family == 1:
		_configure_forest(entries, descriptors)
	else:
		_configure_mountain(entries, descriptors)
	_under_mesh = null
	queue_redraw()

## Upright peaks are drawn with the nominal perspective stretch; the dynamic
## (zoom-driven) view changes it continuously, so redraw when it drifts.
var _drawn_stretch: float = -1.0

var _drawn_presence: float = -1.0
var _drawn_xf: Transform2D = Transform2D()
const MOUNTAIN_PRESENCE: float = 1.9

func _presence() -> float:
	if family == 1 or not PresentationOrientationCls.perspective_active:
		return 1.0
	return lerpf(1.0, MOUNTAIN_PRESENCE, smoothstep(0.45, 1.0, PresentationOrientationCls.view_e))

func _process(_delta: float) -> void:
	if not draw_sprites or placements.is_empty() or not PresentationOrientationCls.board_presented():
		return
	if PresentationOrientationCls.frame_provider.is_valid():
		# Per-position height: redraw whenever the view moves.
		var xf: Transform2D = get_viewport().get_canvas_transform()
		if not xf.is_equal_approx(_drawn_xf) or absf(_presence() - _drawn_presence) > 0.015:
			queue_redraw()
	elif absf(PresentationOrientationCls.upright_stretch - _drawn_stretch) > 0.015 or absf(_presence() - _drawn_presence) > 0.015:
		queue_redraw()

static var _art_grade: ShaderMaterial = null

## Shared presentation grade (see terrain_art_grade.gdshader). Visual only.
static func _art_grade_material() -> ShaderMaterial:
	if _art_grade == null:
		_art_grade = ShaderMaterial.new()
		_art_grade.shader = preload("res://scripts/visual/shaders/terrain_art_grade.gdshader")
	return _art_grade

func refresh_fog(descriptors: Dictionary) -> void:
	_descriptors = descriptors
	_under_mesh = null
	queue_redraw()

## Understory as ONE vertex-coloured mesh (one draw call). Drawing each
## hex's polygons separately cost ~7,800 unbatched canvas commands on an
## all-forest map (~43 ms/frame when fully explored). Rebuilt on fog change.
var _under_mesh: ArrayMesh = null

func _build_under_mesh() -> void:
	var verts := PackedVector2Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	for under in understory_polys:
		var owner_coord: Vector2i = under.get("owner", Vector2i(-999, -999))
		var fs: int = 2
		if _descriptors.has(owner_coord):
			fs = int(_descriptors[owner_coord].fog_state)
		if fs == 0:
			continue # UNEXPLORED: no understory (no silhouette leaks)
		var col: Color = under["color"]
		var inner_col: Color = under.get("inner_color", Color.BLACK)
		if fs == 1:
			col = Color(col.r * 0.82 + 0.08, col.g * 0.82 + 0.08, col.b * 0.82 + 0.10, col.a * 0.85)
			inner_col = Color(inner_col.r * 0.82 + 0.08, inner_col.g * 0.82 + 0.08, inner_col.b * 0.82 + 0.10, inner_col.a * 0.85)
		_append_poly(under["poly"], col, verts, cols, idx)
		if under.has("inner_poly"):
			_append_poly(under["inner_poly"], inner_col, verts, cols, idx)
	_under_mesh = ArrayMesh.new()
	if verts.is_empty():
		return
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = idx
	_under_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, Mesh.ARRAY_FLAG_USE_2D_VERTICES)

static func _append_poly(poly: PackedVector2Array, col: Color, verts: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array) -> void:
	var tris: PackedInt32Array = Geometry2D.triangulate_polygon(poly)
	if tris.is_empty():
		return
	var base: int = verts.size()
	for v in poly:
		verts.append(v)
		cols.append(col)
	for t in tris:
		idx.append(base + t)

func _configure_forest(entries: Array, descriptors: Dictionary) -> void:
	placements.clear()
	understory_polys.clear()
	for entry in entries:
		var coord: Vector2i = entry.anchor
		var d = descriptors.get(coord, null)
		if d == null:
			continue
		var role: int = int(entry.role)
		var cell_plan: Dictionary = HexForestCompositor.plan_cell_composition(coord, role, d, descriptors)
		if cell_plan.has("understory"):
			var under: Dictionary = cell_plan["understory"].duplicate()
			under["owner"] = coord
			understory_polys.append(under)
		for sp in cell_plan.get("sprites", []):
			var path: String = sp["path"]
			if not approved_resources.has(path):
				approved_resources.append(path)
			placements.append({
				"texture": Registry.cropped(path),
				"rect": sp["rect"],
				"owner": coord,
				"resource": path,
				"flip": sp.get("flip", false),
				"contact_y": sp.get("contact_y", sp["rect"].position.y + sp["rect"].size.y)
			})
	_upright_placements()
	# Global 2.5D depth sort across all forest cells
	placements.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["contact_y"] < b["contact_y"]
	)

func _configure_mountain(entries: Array, descriptors: Dictionary) -> void:
	placements.clear()
	understory_polys.clear()
	var sorted: Array = entries.duplicate()
	sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return descriptors[a.anchor].world_pos.y < descriptors[b.anchor].world_pos.y)
	for entry in sorted:
		var coord: Vector2i = entry.anchor
		var d = descriptors[coord]
		var role: int = int(entry.role)
		var path: String = Registry.mountain(role, coord)
		var width: float = 37.0
		var height: float = 38.0
		_place(path, d.world_pos + Vector2(0, 13), width, height, coord)
	if PresentationOrientationCls.is_rotated():
		_upright_placements()
		placements.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return a["contact_y"] < b["contact_y"]
		)

## Friendly-side yaw (camera rotated): each tree / peak stands upright about
## its own ground-contact point instead of tilting with the world. The contact
## stays inside its owning hex (hexes are 120deg-symmetric), so occupancy is
## unchanged; depth sort switches to screen-space depth. No-op at yaw 0.
func _upright_placements() -> void:
	if not PresentationOrientationCls.is_rotated():
		return
	for p in placements:
		if p.has("pivot"):
			continue
		var r: Rect2 = p["rect"]
		var pivot := Vector2(r.position.x + r.size.x * 0.5, float(p["contact_y"]))
		p["pivot"] = pivot
		p["contact_y"] = PresentationOrientationCls.screen_depth(pivot)

func _place(path: String, contact: Vector2, width: float, height: float, coord: Vector2i) -> void:
	var b: Rect2 = Registry.bounds(path)
	var factor: float = minf(width / b.size.x, height / b.size.y)
	var size: Vector2 = b.size * factor
	placements.append({
		"texture": Registry.cropped(path),
		"rect": Rect2(contact - Vector2(size.x * 0.5, size.y), size),
		"owner": coord,
		"resource": path,
		"flip": false,
		"contact_y": contact.y
	})
	if not approved_resources.has(path):
		approved_resources.append(path)

func _draw() -> void:
	if not understory_polys.is_empty():
		if _under_mesh == null:
			_build_under_mesh()
		if _under_mesh.get_surface_count() > 0:
			draw_mesh(_under_mesh, null)
	if not draw_sprites:
		return
	_drawn_stretch = PresentationOrientationCls.upright_stretch
	_drawn_presence = _presence()
	var per_pos: bool = PresentationOrientationCls.frame_provider.is_valid()
	if per_pos:
		_drawn_xf = get_viewport().get_canvas_transform()
	for p in placements:
		var owner_coord: Vector2i = p.get("owner", Vector2i(-999, -999))
		var fs: int = 2
		if _descriptors.has(owner_coord):
			fs = int(_descriptors[owner_coord].fog_state)
		if fs == 0:
			continue # UNEXPLORED: completely skip mountain / tree sprite
		var mod_col: Color = Color.WHITE
		if fs == 1:
			# EXPLORED_PAST: crisp remembered terrain under morning haze
			mod_col = Color(0.84, 0.86, 0.90, 0.88)
		if p.has("pivot"):
			var pv: Vector2 = p["pivot"]
			# Exact upright height for THIS peak's distance (no far squash).
			var st: float = PresentationOrientationCls.stretch_at_world(pv) if per_pos else PresentationOrientationCls.upright_stretch
			draw_set_transform(pv, PresentationOrientationCls.upright_rotation(), Vector2((-1.0 if p.get("flip", false) else 1.0) * _drawn_presence, st * _drawn_presence))
			draw_texture_rect(p.texture, Rect2(p.rect.position - pv, p.rect.size), false, mod_col)
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		elif p.get("flip", false):
			draw_set_transform(Vector2(p.rect.position.x + p.rect.size.x, p.rect.position.y), 0.0, Vector2(-1.0, 1.0))
			draw_texture_rect(p.texture, Rect2(0, 0, p.rect.size.x, p.rect.size.y), false, mod_col)
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		else:
			draw_texture_rect(p.texture, p.rect, false, mod_col)

