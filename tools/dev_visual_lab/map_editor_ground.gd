extends RefCounted
## Ground paint for the map editor: a flat coloured hex plus a few scattered library ground details
## (grass clumps, dry tufts, earth patches, pebble clusters from base-ground-kit), exactly the colour sets the
## asset library's base ground uses (base_ground_world.gd variant_palettes). Shared by the editor and the
## thumbnail builder.
const Paths = preload("res://tools/dev_visual_lab/visual_output_paths.gd")

## id -> [label, grass, accent, soil, {detail family: count}]
const VARIANTS := {
	"base_grassland": ["초원", "82975b", "768c50", "988864", {"grass_clump": 6, "pebble_cluster": 2}],
	"grass_clump": ["짙은 풀밭", "6a8447", "5d773d", "897c5d", {"grass_clump": 12}],
	"dry_grassland": ["마른 풀밭", "a2955b", "b0a163", "859358", {"dry_tuft": 10, "pebble_cluster": 1}],
	"earth_plain": ["흙 평지", "86945a", "9e8c67", "ab9870", {"earth_patch": 3, "dry_tuft": 4, "pebble_cluster": 2}],
	"pebble_grassland": ["자갈 풀밭", "7c8c57", "8e897a", "999383", {"pebble_cluster": 10, "grass_clump": 3}],
}
const DETAIL_SIZE := {"grass_clump": 3.6, "dry_tuft": 3.6, "earth_patch": 9.0, "pebble_cluster": 3.4}
static var _details := {}


static func ids() -> Array:
	return VARIANTS.keys()


## One painted ground hex at the origin (flat-top hex of radius r), seeded so the same hex always looks the same.
static func build_hex(variant: String, r: float, seed_value: int) -> Node3D:
	var v: Array = VARIANTS.get(variant, VARIANTS["base_grassland"])
	var grass := Color(v[1]); var accent := Color(v[2]); var soil := Color(v[3])
	var root := Node3D.new()
	var rng := RandomNumberGenerator.new(); rng.seed = seed_value
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var ring: Array = []
	for i in range(6):
		var a := PI / 3.0 * float(i)
		ring.append([Vector3(cos(a), 0, sin(a)) * r, [grass, accent, soil][rng.randi_range(0, 2)].lerp(grass, 0.45)])
	var mid := [Vector3.ZERO, grass.lerp(accent, rng.randf_range(0.0, 0.4))]
	for i in range(6):
		var p0: Array = ring[i]; var p1: Array = ring[(i + 1) % 6]
		for pc in [mid, p1, p0]:
			st.set_color(pc[1]); st.set_normal(Vector3.UP); st.add_vertex(pc[0] + Vector3.UP * 0.05)
	var mi := MeshInstance3D.new(); mi.mesh = st.commit()
	var mat := StandardMaterial3D.new(); mat.vertex_color_use_as_albedo = true; mat.vertex_color_is_srgb = true; mat.roughness = 1.0; mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat; mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mi)
	var counts: Dictionary = v[4]
	for fam in counts.keys():
		var src := _detail(fam)
		if src == null: continue
		for _i in range(int(counts[fam])):
			var d := src.duplicate() as Node3D
			var ang := rng.randf() * TAU; var dist := sqrt(rng.randf()) * r * 0.78
			d.position = Vector3(cos(ang), 0, sin(ang)) * dist + Vector3.UP * 0.05
			d.rotation.y = rng.randf() * TAU
			d.scale *= rng.randf_range(0.8, 1.25)
			root.add_child(d)
	return root


## Library detail model, sized to DETAIL_SIZE (widest side) and standing on y = 0.
static func _detail(fam: String) -> Node3D:
	if _details.has(fam): return _details[fam]
	var path := Paths.output("base-ground-kit/exports/ground_detail_%s_lod0.glb" % fam)
	var doc := GLTFDocument.new(); var st := GLTFState.new()
	if not FileAccess.file_exists(path) or doc.append_from_file(path, st) != OK:
		_details[fam] = null; return null
	var model := doc.generate_scene(st) as Node3D
	var lo := Vector3.INF; var hi := -Vector3.INF
	for m in model.find_children("*", "MeshInstance3D", true, false):
		var xf := Transform3D.IDENTITY; var n: Node = m
		while n != null and n != model:
			if n is Node3D: xf = (n as Node3D).transform * xf
			n = n.get_parent()
		var box: AABB = xf * (m as MeshInstance3D).mesh.get_aabb()
		lo = Vector3(minf(lo.x, box.position.x), minf(lo.y, box.position.y), minf(lo.z, box.position.z))
		hi = Vector3(maxf(hi.x, box.end.x), maxf(hi.y, box.end.y), maxf(hi.z, box.end.z))
		(m as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var sc := float(DETAIL_SIZE[fam]) / maxf(0.001, maxf(hi.x - lo.x, hi.z - lo.z))
	var holder := Node3D.new(); holder.add_child(model)
	model.scale = Vector3.ONE * sc
	model.position = Vector3(-(lo.x + hi.x) * 0.5 * sc, -lo.y * sc, -(lo.z + hi.z) * 0.5 * sc)
	_details[fam] = holder
	return holder
