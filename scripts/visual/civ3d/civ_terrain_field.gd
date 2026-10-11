extends RefCounted

## CIV3D terrain field (VISUAL ONLY): one continuous lit heightfield built from
## the live terrain ids. Each hex has a base height by terrain; hex centres
## stay flat (units stand there) and the slopes live near the hex borders, so
## the board reads as a Civ-style tile diorama while every hex stays exactly
## where the logical grid puts it. Reads cell_data once; never writes it.
##
## Units: 3D units (world px * S). height_at() takes WORLD PX.

const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")

## Terrain ids (HexCell.TerrainType) -> base height in 3D units.
const BASE_HEIGHT := {
	0: 0.0,    # plains
	1: 0.85,   # mountains (the GLB massif stands on this plinth)
	2: 0.06,   # forest
	3: -0.22,  # swamp
	4: 0.16,   # fortress
	5: 0.04,   # village
	6: 0.0,    # road
	7: -0.42,  # river
	8: 0.16, 9: 0.16, 10: 0.16, 11: 0.16, 12: 0.16, # stronghold / capital
	13: 1.3,   # outer country
}
const OFF_MAP_TERRAIN: int = 13
## Flat plateau share of the circumradius; blending reaches 1.2 R.
const PLATEAU: float = 0.52
const REACH: float = 1.22
const GRID_STEP: float = 1.25   # mesh spacing, 3D units
const CHUNK_CELLS: int = 48     # grid cells per mesh chunk side

var S: float = 1.0
var play_r: int = 40
var mesh_r: int = 47
var _terrain: Dictionary = {}   # Vector2i -> int
var _noise := FastNoiseLite.new()
var _rough := FastNoiseLite.new()

func setup(cells: Dictionary, p_s: float, p_play_r: int) -> void:
	S = p_s
	play_r = p_play_r
	mesh_r = play_r + 7
	for c in cells.values():
		_terrain[Vector2i(int(c.q), int(c.r))] = int(c.terrain)
	_noise.seed = 20261007
	_noise.frequency = 0.012
	_noise.fractal_octaves = 3
	_rough.seed = 7
	_rough.frequency = 0.05
	_rough.fractal_octaves = 4

static func axial_dist(q: int, r: int) -> int:
	return (absi(q) + absi(r) + absi(q + r)) / 2

func terrain_at(h: Vector2i) -> int:
	if _terrain.has(h):
		return _terrain[h]
	return OFF_MAP_TERRAIN

func hex_height(h: Vector2i) -> float:
	return float(BASE_HEIGHT.get(terrain_at(h), 0.0))

## Height (3D units) of the ground under a world-px point.
func height_at(wp: Vector2) -> float:
	var h0: Vector2i = HexUtilsCls.pixel_to_hex(wp)
	var sum_w: float = 0.0
	var sum_h: float = 0.0
	var mountain_w: float = 0.0
	for k in range(7):
		var h: Vector2i = h0 if k == 0 else h0 + HexUtilsCls.DIRECTIONS[k - 1]
		var d: float = wp.distance_to(HexUtilsCls.hex_to_pixel(h.x, h.y)) / 24.0
		var w: float = 1.0 - smoothstep(PLATEAU, REACH, d)
		if w <= 0.0:
			continue
		var t: int = terrain_at(h)
		sum_w += w
		sum_h += w * float(BASE_HEIGHT.get(t, 0.0))
		if t == 1 or t == OFF_MAP_TERRAIN:
			mountain_w += w
	var base: float = sum_h / maxf(sum_w, 0.0001)
	var y: float = base + _noise.get_noise_2d(wp.x, wp.y) * 0.07
	if mountain_w > 0.0:
		y += (_rough.get_noise_2d(wp.x, wp.y) * 0.5 + 0.35) * 0.55 * (mountain_w / maxf(sum_w, 0.0001))
	return y

## Builds the ground as culled chunks under `parent` with `mat`.
func build_mesh(parent: Node3D, mat: Material) -> int:
	# Board bounds in world px for the hexes within mesh_r, padded.
	var ext_x: float = (mesh_r + 1) * 36.0
	var ext_y: float = (mesh_r + 1) * 42.0
	var x0: float = -ext_x * S
	var z0: float = -ext_y * S
	var nx: int = int(ceil(2.0 * ext_x * S / GRID_STEP)) + 1
	var nz: int = int(ceil(2.0 * ext_y * S / GRID_STEP)) + 1
	# Heights once for the whole grid (shared chunk borders stay seamless).
	var hgrid := PackedFloat32Array()
	hgrid.resize(nx * nz)
	var inside := PackedByteArray()
	inside.resize(nx * nz)
	for j in range(nz):
		for i in range(nx):
			var wp := Vector2((x0 + i * GRID_STEP) / S, (z0 + j * GRID_STEP) / S)
			var hx: Vector2i = HexUtilsCls.pixel_to_hex(wp)
			inside[j * nx + i] = 1 if axial_dist(hx.x, hx.y) <= mesh_r else 0
			hgrid[j * nx + i] = height_at(wp)
	var tris: int = 0
	var cj: int = 0
	while cj < nz - 1:
		var ci: int = 0
		while ci < nx - 1:
			tris += _build_chunk(parent, mat, hgrid, inside, nx, nz, ci, cj, x0, z0)
			ci += CHUNK_CELLS
		cj += CHUNK_CELLS
	return tris

func _build_chunk(parent: Node3D, mat: Material, hgrid: PackedFloat32Array, inside: PackedByteArray,
		nx: int, nz: int, ci: int, cj: int, x0: float, z0: float) -> int:
	var i1: int = mini(ci + CHUNK_CELLS, nx - 1)
	var j1: int = mini(cj + CHUNK_CELLS, nz - 1)
	var w: int = i1 - ci + 1
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var idx := PackedInt32Array()
	var any_inside := false
	for j in range(cj, j1 + 1):
		for i in range(ci, i1 + 1):
			var y: float = hgrid[j * nx + i]
			verts.append(Vector3(x0 + i * GRID_STEP, y, z0 + j * GRID_STEP))
			var hl: float = hgrid[j * nx + maxi(i - 1, 0)]
			var hr: float = hgrid[j * nx + mini(i + 1, nx - 1)]
			var hd: float = hgrid[maxi(j - 1, 0) * nx + i]
			var hu: float = hgrid[mini(j + 1, nz - 1) * nx + i]
			norms.append(Vector3(hl - hr, 2.0 * GRID_STEP, hd - hu).normalized())
			if inside[j * nx + i] == 1:
				any_inside = true
	if not any_inside:
		return 0
	for j in range(j1 - cj):
		for i in range(i1 - ci):
			var a: int = j * w + i
			idx.append_array(PackedInt32Array([a, a + 1, a + w, a + 1, a + w + 1, a + w]))
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_INDEX] = idx
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.name = "Ground_%d_%d" % [ci, cj]
	mi.mesh = am
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(mi)
	return idx.size() / 3
