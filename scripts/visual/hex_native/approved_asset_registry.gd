class_name ApprovedAssetRegistry
extends RefCounted

## One presentation-only resource registry. Original PNG pixels are immutable.
## Metadata is measured offline; textures, atlas regions and materials cache once.
const ROOTS := {
	"ground": "res://assets/terrain/cohesion/approved_v1/",
	"mountain": "res://assets/terrain/mountains/approved_v1/",
	"forest": "res://assets/vegetation/approved_v1/",
	"unit": "res://assets/units/formations/approved_v1/",
	"fort": "res://assets/structures/fortifications/approved_v1/",
	"settlement": "res://assets/structures/settlements/approved_v1/",
	"prop": "res://assets/props/approved_v1/",
}
const BASE := ["plain_parchment_earth_A", "plain_loess_A", "plain_grass_faded_A", "plain_battlefield_worn_A", "plain_lowland_green_A", "ground_foothill_adjacent_A", "pass_floor_compacted_A", "plain_lowland_green_A"]
## Terrain language v2 (canonical battlefield QA): the cohesion_v1 ground and
## route sources above are unfinished placeholder gradients (every role reads
## as the same green), so the HIGH board samples these small house-style
## tiles instead (tools/battlefields/gen_terrain_language_v2.py). Indexed by
## HexBaseTerrainMesh.BaseRole; "" = no texture (river channel colour).
const GROUND_V2_ROOT := "res://assets/terrain/ground_v2/"
const BASE_V2 := ["plain_parchment_v2", "plain_loess_v2", "plain_grass_faded_v2", "plain_battlefield_worn_v2", "plain_lowland_green_v2", "ground_foothill_v2", "pass_floor_v2", "marsh_ground_v2", "", "rock_ground_v2"]
const ROUTE_V2 := {"road": "road_dirt_v2", "pass": "road_pass_v2", "bridge": "bridge_deck_v2"}

static func base_path(role: int) -> String:
	if role < 0 or role >= BASE_V2.size() or str(BASE_V2[role]).is_empty():
		return ""
	return GROUND_V2_ROOT + str(BASE_V2[role]) + ".png"

static func route_path(kind: String) -> String:
	return GROUND_V2_ROOT + str(ROUTE_V2.get(kind, "road_dirt_v2")) + ".png"
const MOUNTAIN := {1:"high_peak", 2:"ridge_pass", 3:"rough_mountain", 4:"low_foothill", 5:"rough_mountain", 6:"ridge_pass", 7:"rough_mountain", 8:"rough_mountain"}
const FOREST := {5:"sparse_pine_cluster", 6:"forest_edge", 7:"mixed_woodland", 8:"roadside_tree_patch", 9:"foothill_pine_cluster", 10:"bamboo_grove", 11:"pine_small"}
const UNIT := {"infantry":"infantry_formation", "spearman":"spear_formation", "spearmen":"spear_formation", "spear":"spear_formation", "archer":"archer_formation", "archers":"archer_formation", "cavalry":"cavalry_formation", "scout":"scout_formation", "scouts":"scout_formation", "conscript":"conscript_formation", "conscripts":"conscript_formation", "siege":"siege_formation", "hq":"command_group"}
static var _bounds: Dictionary = {}
static var _textures: Dictionary = {}
static var _atlases: Dictionary = {}
static var _materials: Dictionary = {}

static func path_for(family: String, stem: String) -> String:
	return str(ROOTS[family]) + stem + ".png"

static func metadata(path: String) -> Dictionary:
	if _bounds.is_empty():
		_bounds = JSON.parse_string(FileAccess.get_file_as_string("res://assets/production_ingestion_v1/alpha_bounds.json"))
	assert(_bounds.has(path), "Unregistered approved asset: " + path)
	return _bounds.get(path, {})

static func texture(path: String) -> Texture2D:
	if not _textures.has(path):
		_textures[path] = load(path) as Texture2D
	return _textures[path]

static func bounds(path: String) -> Rect2:
	var b: Array = metadata(path)["bounds"]
	return Rect2(float(b[0]), float(b[1]), float(b[2]), float(b[3]))

## Dense-body rect (visual-only unit fill pass): the opaque soldier cluster
## inside the art, excluding sparse banner/spear pixels. Falls back to bounds.
static func body(path: String) -> Rect2:
	var m: Dictionary = metadata(path)
	var b: Array = m.get("dense", m["bounds"])
	return Rect2(float(b[0]), float(b[1]), float(b[2]), float(b[3]))

static func cropped(path: String) -> Texture2D:
	if not _atlases.has(path):
		var atlas := AtlasTexture.new()
		atlas.atlas = texture(path)
		atlas.region = bounds(path)
		atlas.filter_clip = true
		_atlases[path] = atlas
	return _atlases[path]

static func variant(coord: Vector2i) -> String:
	return "A" if absi(coord.x * 73856093 ^ coord.y * 19349663) % 2 == 0 else "B"

static func mountain(role: int, coord: Vector2i) -> String:
	return path_for("mountain", str(MOUNTAIN.get(role, "rough_mountain")) + "_" + variant(coord))

static func forest(role: int, coord: Vector2i) -> String:
	return path_for("forest", str(FOREST.get(role, "forest_edge")) + "_" + ("A" if role in [8,11] else variant(coord)))

# Complete catalog of all 26 approved vegetation assets
const VEGETATION_ALL := [
	"bamboo_cluster_A", "bamboo_cluster_B", "bamboo_edge_A", "bamboo_grove_A", "bamboo_grove_B",
	"deciduous_A", "deciduous_B", "deciduous_sparse_A", "dry_shrub_A", "dry_shrub_B",
	"foothill_pine_cluster_A", "foothill_pine_cluster_B", "forest_edge_A", "forest_edge_B",
	"grass_clump_A", "grass_clump_B", "mixed_woodland_A", "mixed_woodland_B",
	"pine_A", "pine_B", "pine_C", "pine_old_twisted_A", "pine_small_A",
	"roadside_tree_patch_A", "sparse_pine_cluster_A", "sparse_pine_cluster_B"
]
const VEGETATION_CANOPY_LARGE := [
	"deciduous_A", "deciduous_B", "pine_A", "pine_B", "pine_C", "mixed_woodland_A", "mixed_woodland_B"
]
const VEGETATION_CANOPY_SMALL := [
	"deciduous_sparse_A", "pine_small_A", "pine_old_twisted_A", "bamboo_cluster_A", "bamboo_cluster_B", "bamboo_edge_A"
]
const VEGETATION_SHRUBS := [
	"dry_shrub_A", "dry_shrub_B", "grass_clump_A", "grass_clump_B"
]
const VEGETATION_FOOTHILL := [
	"foothill_pine_cluster_A", "foothill_pine_cluster_B", "pine_A", "pine_B", "pine_C", "pine_old_twisted_A", "pine_small_A", "sparse_pine_cluster_A", "sparse_pine_cluster_B"
]
const VEGETATION_BAMBOO := [
	"bamboo_grove_A", "bamboo_grove_B", "bamboo_cluster_A", "bamboo_cluster_B", "bamboo_edge_A"
]
const VEGETATION_ROADSIDE := [
	"roadside_tree_patch_A", "deciduous_A", "deciduous_B", "pine_C"
]
const VEGETATION_EDGE := [
	"forest_edge_A", "forest_edge_B", "deciduous_A", "mixed_woodland_B"
]

static func vegetation_path(stem: String) -> String:
	return path_for("forest", stem)

static func anchor_contact(path: String) -> Vector2:
	var m: Dictionary = metadata(path)
	var b: Rect2 = bounds(path)
	var bottom: Array = m.get("bottom_contact", [b.position.x + b.size.x * 0.5, b.position.y + b.size.y])
	return Vector2(float(bottom[0]) - b.position.x, float(bottom[1]) - b.position.y)


static func unit(unit_class: String, faction: String, choice: String = "A") -> String:
	if unit_class == "supply":
		return path_for("prop", "supply_cart_A")
	assert(UNIT.has(unit_class), "Missing class mapping: " + unit_class)
	var suffix: String = "A" if unit_class in ["conscript","conscripts","scout","scouts"] else choice
	return str(ROOTS["unit"]) + ("enemy/" if faction == "red" else "") + str(UNIT[unit_class]) + "_" + suffix + ".png"

static func unit_width(unit_class: String) -> float:
	# Flat-to-flat = 42 world units. Width remains independent of camera zoom.
	return 23.1 if unit_class == "siege" else (21.0 if unit_class in ["cavalry","hq"] else 19.3)

static func sprite(path: String, contact: Vector2, width: float, max_height: float = 40.0) -> Sprite2D:
	var sp := Sprite2D.new()
	sp.texture = cropped(path)
	sp.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	var b: Rect2 = bounds(path)
	var factor: float = minf(width / b.size.x, max_height / b.size.y)
	var bottom: Array = metadata(path)["bottom_contact"]
	sp.centered = false
	sp.offset = -Vector2(float(bottom[0]) - b.position.x, b.size.y)
	sp.scale = Vector2.ONE * factor
	sp.position = contact
	sp.set_meta("approved_resource", path)
	sp.set_meta("content_width_world", b.size.x * factor)
	return sp

static func surface(path: String) -> ShaderMaterial:
	if not _materials.has(path):
		var mat := ShaderMaterial.new()
		mat.shader = preload("res://scripts/visual/shaders/approved_hex_surface.gdshader")
		mat.set_shader_parameter("art", texture(path))
		var b: Rect2 = bounds(path)
		var canvas: Array = metadata(path)["canvas"]
		var size := Vector2(float(canvas[0]),float(canvas[1]))
		# Sample the painted interior, avoiding alpha fringes and decal silhouettes.
		mat.set_shader_parameter("content_uv", Vector4((b.position.x + b.size.x * 0.23)/size.x, (b.position.y + b.size.y * 0.23)/size.y, b.size.x * 0.54/size.x, b.size.y * 0.54/size.y))
		var stem: String = path.get_file().get_basename()
		if stem.begins_with("plain_") or stem.begins_with("ground_"):
			mat.set_shader_parameter("detail_mix", 0.40)
			mat.set_shader_parameter("grain_strength", 0.16)
		_materials[path] = mat
	return _materials[path]
