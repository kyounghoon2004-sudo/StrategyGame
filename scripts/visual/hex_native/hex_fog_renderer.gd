class_name HexFogRenderer
extends Node2D

## HexFogRenderer — fog truth stays in Step5FogOfWar; this node only presents
## that truth. Fog is hex-resolution first: each cell gets a quiet inset veil
## with a center-to-edge gradient, never a full-screen wash or random blotch.
##
## TACTICAL OBSCURITY, not weather (visual contract): unexplored = flat ink
## (VisualContract.FOG_INK, same as CLOSEUP), explored = flat cool memory
## tint. Static shaders in scripts/visual/shaders/tactical_fog_*.gdshader: no
## TIME, no noise, no drifting clouds, no frontier wisps. Two shared
## materials per process; meshes rebuild only when the fog key sets change.

const VERTS: Array[Vector2] = [
	Vector2(-24.0, 0.0), Vector2(-12.0, -21.0), Vector2(12.0, -21.0),
	Vector2(24.0, 0.0), Vector2(12.0, 21.0), Vector2(-12.0, 21.0),
]
const UnexploredShader = preload("res://scripts/visual/shaders/tactical_fog_unexplored.gdshader")
const ExploredShader = preload("res://scripts/visual/shaders/tactical_fog_explored.gdshader")
const VisualContract = preload("res://scripts/visual/visual_contract.gd")

# 100% opaque base tones for unexplored terrain (§1, §5, §6).
# Seamless overlap (inset 1.035) prevents any hex cracks or grid leaks.
const UNEXPLORED_TONES: Array[Color] = [
	Color(0.36, 0.38, 0.42, 1.0),
	Color(0.38, 0.40, 0.45, 1.0),
	Color(0.40, 0.42, 0.46, 1.0),
]
const NEB6: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1),
	Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1),
]

var _last_sig: String = ""
var _fog = null
var _descriptors: Dictionary = {}
var _mi_explored: MeshInstance2D = null
var _mi_unexplored: MeshInstance2D = null

static var _unexp_mat: ShaderMaterial = null
static var _exp_mat: ShaderMaterial = null

static func _ensure_materials() -> void:
	if _unexp_mat == null:
		_unexp_mat = ShaderMaterial.new()
		_unexp_mat.shader = UnexploredShader
		_unexp_mat.set_shader_parameter("ink", VisualContract.FOG_INK)
	if _exp_mat == null:
		_exp_mat = ShaderMaterial.new()
		_exp_mat.shader = ExploredShader

func configure(fog, descriptors: Dictionary) -> void:
	_fog = fog
	_descriptors = descriptors
	_ensure_materials()
	rebuild(true)

func set_fog(fog) -> void:
	_fog = fog
	_ensure_materials()
	rebuild(false)

func _dict_signature(data: Dictionary) -> int:
	var result: int = data.size() * 31
	for key in data.keys():
		result = int((result * 33 + hash(str(key))) & 0x7fffffff)
	return result

func fog_signature() -> String:
	if _fog == null:
		return "nofog_%d" % _descriptors.size()
	var visible: Dictionary = _fog.get("visible") if _fog.get("visible") != null else {}
	var explored: Dictionary = _fog.get("explored") if _fog.get("explored") != null else {}
	return "%d_%d_%d_%d_%d" % [
		visible.size(), _dict_signature(visible), explored.size(),
		_dict_signature(explored), _descriptors.size()
	]

## Rebuild only when the actual visible/explored key sets change.
func rebuild(force: bool = false) -> bool:
	var sig: String = fog_signature()
	if not force and sig == _last_sig:
		return false
	_last_sig = sig
	_ensure_materials()

	var exp_cells: Array = []
	var unexp_cells: Array = []

	if _fog != null:
		var vis: Dictionary = _fog.get("visible") if _fog.get("visible") != null else {}
		var exp: Dictionary = _fog.get("explored") if _fog.get("explored") != null else {}

		for coord in _descriptors.keys():
			var skey: String = "%d,%d" % [coord.x, coord.y]
			if vis.has(skey) or vis.has(coord):
				continue # CURRENTLY_VISIBLE: crystal clear, zero fog!

			var d = _descriptors[coord]
			if exp.has(skey) or exp.has(coord):
				# EXPLORED_PAST: remembered terrain under the flat memory tint
				exp_cells.append([d.world_pos, 1.0])
			else:
				# UNEXPLORED: completely opaque flat ink (§1, §5, §6).
				# Compute frontier feathering based on neighbor states:
				var tone: Color = UNEXPLORED_TONES[absi((coord.x * 83492791) ^ (coord.y * 2971215073)) % 3]
				var ring_alphas: Array[float] = [1.0, 1.0, 1.0, 1.0, 1.0, 1.0]
				for k in range(6):
					var nc: Vector2i = coord + NEB6[k]
					var is_open: bool = false
					if _descriptors.has(nc):
						var n_skey: String = "%d,%d" % [nc.x, nc.y]
						if vis.has(n_skey) or vis.has(nc) or exp.has(n_skey) or exp.has(nc):
							is_open = true
					if is_open:
						ring_alphas[k] = 0.90
						ring_alphas[(k + 1) % 6] = 0.90

				unexp_cells.append({
					"pos": d.world_pos,
					"tone": tone,
					"ring_alphas": ring_alphas,
					"center_alpha": 1.0,
					"inset": 1.035 # Overlapping hex geometry eliminates cracks/seams
				})

	_build_explored_surface(exp_cells)
	_build_unexplored_surface(unexp_cells)
	return true

func _build_unexplored_surface(cells: Array) -> void:
	if _mi_unexplored == null:
		_mi_unexplored = MeshInstance2D.new()
		_mi_unexplored.name = "UnexploredFog"
		_mi_unexplored.z_index = 0
		_mi_unexplored.material = _unexp_mat
		add_child(_mi_unexplored)

	if cells.is_empty():
		_mi_unexplored.mesh = null
		return

	var n: int = cells.size()
	var verts := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	verts.resize(n * 7)
	colors.resize(n * 7)
	indices.resize(n * 18)

	for i in range(n):
		var item: Dictionary = cells[i]
		var center: Vector2 = item["pos"]
		var tone: Color = item["tone"]
		var ring_alphas: Array[float] = item["ring_alphas"]
		var center_alpha: float = item["center_alpha"]
		var inset: float = item["inset"]

		var vb: int = i * 7
		verts[vb] = center
		colors[vb] = Color(tone.r, tone.g, tone.b, center_alpha)

		for k in range(6):
			verts[vb + 1 + k] = center + VERTS[k] * inset
			colors[vb + 1 + k] = Color(tone.r, tone.g, tone.b, ring_alphas[k])

		var ib: int = i * 18
		for k in range(6):
			var k2: int = 1 + ((k + 1) % 6)
			indices[ib + k * 3] = vb
			indices[ib + k * 3 + 1] = vb + 1 + k
			indices[ib + k * 3 + 2] = vb + k2

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, Mesh.ARRAY_FLAG_USE_2D_VERTICES)
	_mi_unexplored.mesh = mesh

func _build_explored_surface(cells: Array) -> void:
	if _mi_explored == null:
		_mi_explored = MeshInstance2D.new()
		_mi_explored.name = "ExploredFog"
		_mi_explored.z_index = 0
		_mi_explored.material = _exp_mat
		add_child(_mi_explored)

	if cells.is_empty():
		_mi_explored.mesh = null
		return

	var n: int = cells.size()
	var verts := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	verts.resize(n * 7)
	colors.resize(n * 7)
	indices.resize(n * 18)

	var tint := Color(0.55, 0.60, 0.68)
	var inset: float = 1.00

	for i in range(n):
		var item: Array = cells[i]
		var center: Vector2 = item[0]
		var ring_alpha: float = float(item[1])
		var center_alpha: float = ring_alpha * 0.85

		var vb: int = i * 7
		verts[vb] = center
		colors[vb] = Color(tint.r, tint.g, tint.b, center_alpha)

		for k in range(6):
			verts[vb + 1 + k] = center + VERTS[k] * inset
			colors[vb + 1 + k] = Color(tint.r, tint.g, tint.b, ring_alpha)

		var ib: int = i * 18
		for k in range(6):
			var k2: int = 1 + ((k + 1) % 6)
			indices[ib + k * 3] = vb
			indices[ib + k * 3 + 1] = vb + 1 + k
			indices[ib + k * 3 + 2] = vb + k2

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, Mesh.ARRAY_FLAG_USE_2D_VERTICES)
	_mi_explored.mesh = mesh
