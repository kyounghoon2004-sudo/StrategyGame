extends MultiMeshInstance2D

## One batched MultiMesh of presentation-only scenery (dressing / in-hex
## forest trees), owned per hex so it follows fog truth exactly like the
## approved terrain layers: UNEXPLORED owners are skipped (no silhouette
## leaks), EXPLORED owners are tinted as remembered terrain. Instances are
## rebuilt only on fog change; the upright frame (pitch / stretch / lean) is
## evaluated per vertex by presentation_billboard.gdshader from live view
## uniforms, so zoom-driven camera changes need no CPU work here.

const DressingCls = preload("res://scripts/visual/hex_native/hex_dressing_compositor.gd")

var items: Array = []
var is_upright: bool = true
var _descriptors: Dictionary = {}

func configure(p_items: Array, p_upright: bool, descriptors: Dictionary) -> void:
	items = p_items
	is_upright = p_upright
	_descriptors = descriptors
	_rebuild()

func refresh_fog(descriptors: Dictionary) -> void:
	_descriptors = descriptors
	_rebuild()

func _rebuild() -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = quad
	var keep: Array = []
	for it in items:
		var fs: int = 2
		var owner: Vector2i = it["owner"]
		if _descriptors.has(owner):
			fs = int(_descriptors[owner].fog_state)
		if fs != 0:
			keep.append([it, fs])
	mm.instance_count = keep.size()
	for i in range(keep.size()):
		var it: Dictionary = keep[i][0]
		var fs: int = keep[i][1]
		# Items may carry their own atlas info (e.g. the mountain relief atlas).
		var info: Dictionary = it["info"] if it.has("info") else DressingCls.sprite_info(str(it["name"]))
		var ws: Vector2 = (info["world_size"] as Vector2) * float(it["scale"])
		var flip: float = -1.0 if bool(it["flip"]) else 1.0
		mm.set_instance_transform_2d(i, Transform2D(Vector2(ws.x * flip, 0.0), Vector2(0.0, ws.y), it["anchor"]))
		mm.set_instance_custom_data(i, info["region_uv"])
		mm.set_instance_color(i, Color.WHITE if fs == 2 else Color(0.84, 0.86, 0.90, 0.88))
	multimesh = mm
