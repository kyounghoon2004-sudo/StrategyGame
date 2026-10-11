class_name HexDressingCompositor
extends RefCounted

## Battlefield dressing (VISUAL ONLY): grass tufts, flowers, bushes, rocks,
## in-hex forest trees and flat dirt / worn-earth decals from the dressing_v2
## atlas (tools/visual/gen_dressing_v2.py). No gameplay meaning, no
## collision, no occupancy. Built once per battlefield build as two batched
## meshes:
##   decals  — flat ground patches, drawn under hex borders
##   upright — depth-sorted standing scenery, drawn under trees and units
##
## Readability rules:
##   * every item stays inside its own hex (radius <= 15 of a 24px hex), so
##     nothing ever straddles a border or suggests a multi-hex footprint;
##   * tall items (bushes, rocks) sit in the FAR half of a hex, so a unit
##     that later enters is drawn in front of them;
##   * roads, rivers and structures stay clean (tactical routes readable);
##   * the central play area is sparse; richness grows toward the map edge
##     and forest margins;
##   * no trees on open ground (that would misread as forest terrain);
##   * FOREST hexes (perspective presentation) get compact in-hex trees on
##     the hex's back arc instead of the multi-hex cluster art, leaving the
##     unit standing spot clear: forests read as volume, never as a
##     footprint larger than one hex.

const ATLAS_PNG := "res://assets/vegetation/dressing_v2/dressing_atlas.png"
const ATLAS_JSON := "res://assets/vegetation/dressing_v2/dressing_atlas.json"
const PresentationOrientationCls = preload("res://scripts/core/presentation_orientation.gd")
const BillboardShader = preload("res://scripts/visual/shaders/presentation_billboard.gdshader")
const QuadLayerScript = preload("res://scripts/visual/hex_native/hex_quad_layer.gd")
## Tree slots inside a forest hex (screen frame, ground offsets): back arc
## and flanks only; the front-center standing spot stays open.
const TREE_SLOTS: Array[Vector2] = [Vector2(-9, -9), Vector2(1, -12), Vector2(10, -8), Vector2(-13, 1), Vector2(13, 2), Vector2(-4, -4), Vector2(6, -2)]

const T_PLAINS := 0
const T_MOUNTAIN := 1
const T_FOREST := 2
const T_SWAMP := 3
const T_VILLAGE := 5
const T_ROAD := 6
const T_RIVER := 7
const MAP_RADIUS := 40
const DIRS: Array[Vector2i] = [Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1), Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1)]

static var _meta: Dictionary = {}
static var _tex: Texture2D = null


static func _load() -> bool:
	if _tex != null and not _meta.is_empty():
		return true
	if ResourceLoader.exists(ATLAS_PNG):
		_tex = load(ATLAS_PNG) as Texture2D
	elif FileAccess.file_exists(ATLAS_PNG):
		var img := Image.load_from_file(ProjectSettings.globalize_path(ATLAS_PNG))
		if img != null:
			img.generate_mipmaps()
			_tex = ImageTexture.create_from_image(img)
	var f := FileAccess.open(ATLAS_JSON, FileAccess.READ)
	if f != null:
		_meta = JSON.parse_string(f.get_as_text())
	return _tex != null and not _meta.is_empty()


static func _hash(q: int, r: int, salt: int) -> float:
	var h: int = (q * 73856093) ^ (r * 19349663) ^ (salt * 83492791)
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return float(h & 0xFFFFFF) / float(0xFFFFFF)


static func _names_of(kind: String) -> Array:
	var out: Array = []
	for n in (_meta["sprites"] as Dictionary).keys():
		if str(_meta["sprites"][n]["kind"]) == kind:
			out.append(n)
	out.sort()
	return out


## Returns [decal_layer, upright_layer] (fog-aware quad layers).
## forest_trees: place the in-hex tree set in forest hexes.
static func build_nodes(descriptors: Dictionary, unit_coords: Array, forest_trees: bool = false) -> Array[Node2D]:
	var out: Array[Node2D] = []
	if not _load():
		push_warning("[Dressing] atlas missing: %s" % ATLAS_PNG)
		return out
	var units: Dictionary = {}
	for u in unit_coords:
		units[Vector2i(int(u.x), int(u.y))] = true
	var decals: Array = []
	var upright: Array = []
	var tufts: Array = _names_of("tuft")
	var flowers: Array = _names_of("flower")
	var bushes: Array = _names_of("bush")
	var rocks: Array = _names_of("rock")
	var pines: Array = _names_of("forest_pine")
	var broads: Array = _names_of("forest_broad")
	var dirt: Array = _names_of("decal")
	# Low-frequency fields cluster the scenery into meadows / thickets /
	# worn patches instead of an even per-hex sprinkle.
	var meadow := FastNoiseLite.new()
	meadow.seed = 907
	meadow.frequency = 0.0042
	var bloom := FastNoiseLite.new()
	bloom.seed = 923
	bloom.frequency = 0.0065
	var wear := FastNoiseLite.new()
	wear.seed = 951
	wear.frequency = 0.0035
	for c in descriptors.keys():
		var coord: Vector2i = c
		var d = descriptors[coord]
		var t: int = int(d.terrain_type)
		if bool(d.road_present) or bool(d.river_present) or int(d.structure_role) != 0:
			continue
		if t == T_ROAD or t == T_RIVER or t == T_VILLAGE or t >= 8:
			continue
		var q: int = coord.x
		var r: int = coord.y
		var dist: int = maxi(maxi(absi(q), absi(r)), absi(q + r))
		var edge: float = smoothstep(24.0, 38.0, float(dist))
		var dens: float = 0.25 + 0.75 * edge
		var near_forest: bool = false
		var near_open: bool = false
		for dv in DIRS:
			var n = descriptors.get(coord + dv, null)
			if n == null:
				continue
			var nt: int = int(n.terrain_type)
			if nt == T_FOREST or nt == T_MOUNTAIN:
				near_forest = true
			if nt == T_PLAINS:
				near_open = true
		var occupied: bool = units.has(coord)
		var wp: Vector2 = d.world_pos
		var m: float = meadow.get_noise_2dv(wp) * 0.5 + 0.5
		var fl: float = bloom.get_noise_2dv(wp) * 0.5 + 0.5
		var wr: float = wear.get_noise_2dv(wp) * 0.5 + 0.5
		if t == T_PLAINS or t == T_SWAMP:
			if _hash(q, r, 1) < smoothstep(0.55, 0.85, wr) * 0.8:
				decals.append(_item(dirt[int(_hash(q, r, 2) * dirt.size()) % dirt.size()], wp, _ring(q, r, 3, 0.0, 5.0), 0.78, _hash(q, r, 4) < 0.5, 0, coord))
			var cluster: float = smoothstep(0.42, 0.78, m)
			var n_tuft: int = int(round((0.3 + 4.0 * cluster) * dens * (0.6 + 0.8 * _hash(q, r, 5))))
			for i in range(n_tuft):
				upright.append(_item(tufts[int(_hash(q, r, 10 + i) * tufts.size()) % tufts.size()], wp, _ring(q, r, 20 + i, 5.0, 14.0), 0.75 + 0.35 * _hash(q, r, 30 + i), _hash(q, r, 40 + i) < 0.5, 1, coord))
			if _hash(q, r, 6) < smoothstep(0.62, 0.86, fl) * (0.5 + 0.5 * edge) * 1.3:
				upright.append(_item(flowers[int(_hash(q, r, 7) * flowers.size()) % flowers.size()], wp, _ring(q, r, 8, 3.0, 13.0), 0.8 + 0.3 * _hash(q, r, 9), false, 1, coord))
			if not occupied:
				var bush_p: float = ((0.35 if near_forest else 0.0) + 0.28 * edge) * (0.35 + 0.65 * cluster)
				if _hash(q, r, 11) < bush_p:
					var nb: int = 1 + int(_hash(q, r, 12) * 2.0 * (0.5 + edge))
					for i in range(nb):
						var bname: String = bushes[int(_hash(q, r, 50 + i) * bushes.size()) % bushes.size()]
						upright.append(_item(bname, wp, _far_half(q, r, 60 + i), 0.75 + 0.3 * _hash(q, r, 70 + i), _hash(q, r, 80 + i) < 0.5, 1, coord))
				if _hash(q, r, 13) < 0.01 + 0.06 * edge:
					upright.append(_item(rocks[int(_hash(q, r, 14) * rocks.size()) % rocks.size()], wp, _far_half(q, r, 15), 0.8 + 0.4 * _hash(q, r, 16), _hash(q, r, 17) < 0.5, 1, coord))
		elif t == T_FOREST:
			if forest_trees:
				# 3-5 compact trees on the back arc / flanks, owned by this hex.
				var n_trees: int = 3 + int(_hash(q, r, 31) * 2.99)
				var start: int = int(_hash(q, r, 32) * 7.0)
				var pine_bias: float = 0.35 + 0.5 * wr
				for i in range(n_trees):
					var slot: Vector2 = TREE_SLOTS[(start + i * 3) % TREE_SLOTS.size()]
					slot += Vector2(_hash(q, r, 33 + i) - 0.5, _hash(q, r, 43 + i) - 0.5) * 3.0
					var tree_set: Array = pines if _hash(q, r, 53 + i) < pine_bias else broads
					upright.append(_item(tree_set[int(_hash(q, r, 63 + i) * tree_set.size()) % tree_set.size()], wp, slot, 0.85 + 0.25 * _hash(q, r, 73 + i), _hash(q, r, 83 + i) < 0.5, 1, coord))
			for i in range(2):
				upright.append(_item(tufts[int(_hash(q, r, 90 + i) * tufts.size()) % tufts.size()], wp, _ring(q, r, 95 + i, 4.0, 13.0), 0.8, _hash(q, r, 97 + i) < 0.5, 1, coord))
		elif t == T_MOUNTAIN:
			if _hash(q, r, 24) < 0.5:
				upright.append(_item(rocks[int(_hash(q, r, 25) * rocks.size()) % rocks.size()], wp, _ring(q, r, 26, 6.0, 13.0), 1.0 + 0.4 * _hash(q, r, 27), false, 1, coord))
	upright.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["depth"] < b["depth"])
	# Small ground cover (tufts / flowers) in its own layer so it can fade
	# with the view; bushes, rocks and trees stay fully present.
	var small: Array = []
	var tall: Array = []
	for it in upright:
		var k: String = str(_meta["sprites"][it["name"]]["kind"])
		if k == "tuft" or k == "flower":
			small.append(it)
		else:
			tall.append(it)
	out.append(_layer(decals, false, "DressingDecals", descriptors))
	out.append(_layer(small, true, "DressingSmall", descriptors, true))
	out.append(_layer(tall, true, "DressingUpright", descriptors))
	print("[Dressing] decals %d | upright %d" % [decals.size(), upright.size()])
	return out


## Screen-frame ground offset on a ring inside the hex.
static func _ring(q: int, r: int, salt: int, rmin: float, rmax: float) -> Vector2:
	var a: float = _hash(q, r, salt) * TAU
	var rr: float = lerpf(rmin, rmax, sqrt(_hash(q, r, salt + 101)))
	return Vector2(cos(a) * rr, sin(a) * rr * 0.85)


## Screen-frame ground offset in the far (screen-up) half of the hex.
static func _far_half(q: int, r: int, salt: int) -> Vector2:
	return Vector2(lerpf(-12.0, 12.0, _hash(q, r, salt)), lerpf(-14.0, -5.0, _hash(q, r, salt + 7)))


static func _item(name: String, world_center: Vector2, screen_offset: Vector2, scale: float, flip: bool, kind: int, owner: Vector2i = Vector2i(-999, -999)) -> Dictionary:
	# Ground offsets live on the ground plane: rotate with the yaw, no stretch.
	var anchor: Vector2 = world_center + PresentationOrientationCls.upright_vector(screen_offset, 1.0)
	return {"name": name, "anchor": anchor, "scale": scale, "flip": flip, "kind": kind, "owner": owner,
		"depth": PresentationOrientationCls.screen_depth(anchor)}


static func _layer(items: Array, is_upright: bool, label: String, descriptors: Dictionary, small: bool = false) -> Node2D:
	var mi: MultiMeshInstance2D = QuadLayerScript.new()
	mi.name = label
	mi.texture = _tex
	mi.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	mi.material = small_material() if small else billboard_material(is_upright)
	mi.set_meta("presentation_only", true)
	mi.call("configure", items, is_upright, descriptors)
	return mi


## Atlas lookup for one sprite: world size (px) + UV region as a Color
## (u, v, du, dv) for the MultiMesh custom-data channel.
static func sprite_info(name: String) -> Dictionary:
	var sp: Dictionary = _meta["sprites"][name]
	var reg: Array = sp["region"]
	var asz := Vector2(float(_meta["size"][0]), float(_meta["size"][1]))
	return {
		"world_size": Vector2(float(sp["world_size"][0]), float(sp["world_size"][1])),
		"region_uv": Color(float(reg[0]) / asz.x, float(reg[1]) / asz.y, float(reg[2]) / asz.x, float(reg[3]) / asz.y),
	}


## Shared billboard materials. The projection pushes live view uniforms into
## the upright one every frame (see PresentationProjection._push_view).
static var _upright_mat: ShaderMaterial = null
static var _decal_mat: ShaderMaterial = null

static func billboard_material(is_upright: bool) -> ShaderMaterial:
	if is_upright and _upright_mat == null:
		_upright_mat = _new_billboard(true)
	elif not is_upright and _decal_mat == null:
		_decal_mat = _new_billboard(false)
	var m: ShaderMaterial = _upright_mat if is_upright else _decal_mat
	# Yaw can differ per battle scene (static state), refresh on every build.
	m.set_shader_parameter("yaw", PresentationOrientationCls.yaw_rad)
	if not PresentationOrientationCls.frame_provider.is_valid():
		m.set_shader_parameter("perspective", false)
	return m

static var _small_mat: ShaderMaterial = null

## Ground-cover variant of the upright material (its own opacity uniform).
static func small_material() -> ShaderMaterial:
	if _small_mat == null:
		_small_mat = _new_billboard(true)
	_small_mat.set_shader_parameter("yaw", PresentationOrientationCls.yaw_rad)
	if not PresentationOrientationCls.frame_provider.is_valid():
		_small_mat.set_shader_parameter("perspective", false)
	return _small_mat

static func _new_billboard(is_upright: bool) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = BillboardShader
	mat.set_shader_parameter("upright", is_upright)
	mat.set_shader_parameter("perspective", false)
	return mat
