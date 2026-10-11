extends Node3D

## CLOSEUP PRESENTATION STATE (2.5D): a VISUAL ONLY view of the Step2R battle.
##
## Two clear modes, no morph (switched only by PresentationModeController):
##   HIGH / tactical: the 2D board (PresentationProjection), unchanged.
##   CLOSEUP: this node, the same battle seen from behind the friendly HQ,
##            still as a board game.
##
## The closeup is deliberately 2.5D, not a 3D scene:
##   * the ground is a FLAT painted hex board (no heightfield, no lighting)
##   * everything that stands up (units, trees, houses, mountains,
##     strongholds) is an unlit 2D sprite card turned toward the camera,
##     drawn from the same pixel-art language as the board
##   * units use the board's approved formation art; strongholds/mountains use
##     the approved structure/mountain art; forests use closeup-only tall
##     pixel-art trees (assets/closeup25d, see tools/visual_capture/
##     make_closeup_sprites.py) so a forest reads tall and view-blocking
##   * fog is tactical obscurity: unexplored hexes are flat ink, explored
##     hexes are desaturated memory, and the far distance sinks into the same
##     ink. Known strongholds stay as faint silhouettes. Nothing drifts.
##   * nothing animates except the selected-hex pulse
##
## Hexes are presented larger (HEXR) than on the board; the logical grid, one
## unit per hex and all gameplay are untouched: this node only READS the board
## (cell_data, unit renderer nodes, fog truth) and draws it.
##
## The battle is still simulated, laid out and commanded on the flat 2D hex
## board (world pixels from HexUtils.hex_to_pixel). 2D world visuals are
## hidden with canvas visibility layers only; no gameplay node is hidden,
## freed or altered. Pointer picking is an exact ray / ground-plane hit.
## See docs/visual/VISUAL_DESIGN_LANGUAGE.md.

const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")
const PresentationOrientationCls = preload("res://scripts/core/presentation_orientation.gd")
const ModeControllerCls = preload("res://scripts/visual/presentation_mode_controller.gd")
const VisualContract = preload("res://scripts/visual/visual_contract.gd")
const Registry = preload("res://scripts/visual/hex_native/approved_asset_registry.gd")
const FormationSpriteCompositor = preload("res://scripts/visual/hex_native/formation_sprite_compositor.gd")
const HC01GLBDressing = preload("res://scripts/visual/closeup25d/handcrafted_glb_dressing.gd")
const GroundShader = preload("res://scripts/visual/closeup25d/closeup_ground.gdshader")
const CardShader = preload("res://scripts/visual/closeup25d/closeup_card.gdshader")
const BaseShader = preload("res://scripts/visual/closeup25d/closeup_base.gdshader")
const SPRITES := "res://assets/closeup25d/"

## Closeup hex scale (presentation only): a hex's circumradius in closeup
## units. Larger than the old 1.6 so a stronghold fits one hex naturally and a
## formation has room around it. The logical grid is untouched.
const HEXR: float = VisualContract.CLOSEUP_HEXR
const S: float = HEXR / 24.0 # world px -> closeup units
const HEX_W: float = HEXR * 1.7320508 # flat-to-flat width = hex centre spacing
const HEX_LOCAL_VERTICES: Array[Vector2] = [
	Vector2(-24.0, 0.0), Vector2(-12.0, -21.0), Vector2(12.0, -21.0),
	Vector2(24.0, 0.0), Vector2(12.0, 21.0), Vector2(-12.0, 21.0),
]
const PLAY_R: int = 40
const OUTER_R: int = 85
const GRID_N: int = 171 # cell texture: axial -85..85
const DRESS_R: int = 46 # scenery is placed out to this ring only

## Unit cards nearly fill their hex footprint; only the narrow class/count
## header and a small ground margin remain around each formation.
const CARD_BODY_H: float = 6.6
const CARD_BODY_W: float = 7.7

## Board (top-down / tactical) zoom cap; wheeling in beyond it enters closeup.
const BOARD_MAX_ZOOM: float = 1.1
const ZOOM_HIGH: float = 0.5
const ZOOM_CLOSE: float = 3.0
const FADE_IN: float = 0.16
const FADE_OUT: float = 0.22
const DOLLY_MIN: float = 0.75
const DOLLY_MAX: float = 1.8

## Tactical obscurity ink, shared with the HIGH board fog (one fog language).
const INK: Color = VisualContract.FOG_INK

## BLUE forward (+q): the friendly side is at the bottom of the screen and
## the enemy ahead. Same orientation authority as the HIGH board.
var fwd: Vector3 = _forward3()

static func _forward3() -> Vector3:
	var f: Vector2 = PresentationOrientationCls.friendly_forward_world()
	return Vector3(f.x, 0.0, f.y)

var shell: Node = null
var cam2d: Camera2D = null
var cam: Camera3D = null
var _env: Environment = null

var _terrain: PackedInt32Array = PackedInt32Array()
var _hc_glb: Node3D = null
var strict_transplant: Node3D = null
const StrictTransplant = preload("res://scripts/visual/full_dev_map_transplant.gd")

func _is_strict_map() -> bool:
	return shell != null and not bool(shell.get("is_step0_sandbox")) and (
		(str(shell.get("battlefield_id")) == "" and (shell.get("_battlefield") as Dictionary).is_empty())
		or _is_tutorial_map()
	)

func _is_tutorial_map() -> bool:
	if shell == null:
		return false
	var battlefield: Dictionary = shell.get("_battlefield") as Dictionary
	return bool(battlefield.get("tutorial", false))

func _uses_full_map_camera() -> bool:
	return _is_hc01() or _is_strict_map()


func _is_hc01() -> bool:
	return shell != null and str(shell.get("battlefield_id")) == "HC01"
var _anchors: Array = [] # stronghold anchor hexes (Vector2i)

var mat_ground: ShaderMaterial
var _card_mats: Array = [] # every card material (per-frame uniforms)
var _scenery_mats: Array = [] # scenery subset (line-of-sight clearing)
var mat_base: Dictionary = {}
var _hex_ring: ArrayMesh
var _board_surface_y: float = 0.0

var _cell_img: Image
var _cell_tex: ImageTexture
var _cell_dirty: bool = false
var _unit_cells: Dictionary = {}
var _fow_sig: int = -1
var _fow_timer: float = 0.0
var _units: Dictionary = {}
var _cards: Dictionary = {}
var _overlay_vp: SubViewport = null
var _saved_msaa: int = 0
## Set by PresentationModeController (the one HIGH <-> CLOSEUP authority).
var mode_controller: Node = null
## Last camera state pushed to the card/ground materials (focus.xy, dolly,
## unused); uniforms are re-sent only when it changes.
var _cam_sig: Vector4 = Vector4.INF
var _occ_sig: int = 0
var _time: float = 0.0
var _active: bool = false
var _dolly: float = 1.0
var _fade_layer: CanvasLayer = null
var _fade: ColorRect = null
var _trans_phase: int = 0 # 0 idle, 1 fading out, 2 fading in
var _trans_t: float = 0.0
var _trans_target: bool = false
var _board_anchor: Callable = Callable()
var _hq_last: Vector2 = Vector2.INF
var _rng := RandomNumberGenerator.new()

const OVERLAY_ORIGIN := Vector2(-1488.0, -1728.0)
const OVERLAY_SIZE := Vector2(2976.0, 3456.0)
const OVERLAY_SCALE: float = 0.75

func _init() -> void:
	name = "BattlefieldCloseupView"

# ======================================================================= setup

func setup(p_shell: Node) -> void:
	shell = p_shell
	cam2d = shell.get("camera") as Camera2D
	_rng.seed = 7331
	var t0: int = Time.get_ticks_msec()
	_build_terrain_grid()
	_build_cell_texture()
	_build_ground()
	if _is_strict_map():
		strict_transplant = StrictTransplant.new()
		add_child(strict_transplant)
		strict_transplant.setup(shell, S)
		# Retain selection and orders over imported ground; unit fog still uses shell truth.
		mat_ground.shader = load("res://scripts/visual/closeup25d/transplant_overlay.gdshader")
		_common(mat_ground)
		mat_ground.set_shader_parameter("assets_ground", true)
		(get_node("Board") as Node3D).position.y = 0.12
	else:
		_build_scenery()
		_build_strongholds()
	_board_surface_y = (get_node("Board") as Node3D).position.y
	if str(shell.get("battlefield_id")) == "HC01":
		_hc_glb = HC01GLBDressing.new()
		add_child(_hc_glb)
		_hc_glb.call("setup", shell, _terrain, GRID_N, OUTER_R)
	_build_camera()
	_build_overlay_viewport()
	var unit_hex_outer_ratio: float = 1.0 if _is_tutorial_map() else 0.93
	var unit_hex_inner_ratio: float = 0.88 if _is_tutorial_map() else 0.82
	_hex_ring = _make_hex_ring(unit_hex_outer_ratio * HEXR, unit_hex_inner_ratio * HEXR)
	_build_base_materials()
	_build_fade()
	# Built inactive. PresentationModeController (the one mode authority)
	# owns canvas layers / cull masks and opens the battle in this view.
	visible = false
	_overlay_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	print("[Closeup25D] built in %d ms | cards=%d materials" % [Time.get_ticks_msec() - t0, _card_mats.size()])

func _exit_tree() -> void:
	if _active:
		apply_active(false)

# ------------------------------------------------------------- terrain / cells

static func axial_dist(q: int, r: int) -> int:
	return (absi(q) + absi(r) + absi(q + r)) / 2

func _tidx(q: int, r: int) -> int:
	return (q + OUTER_R) * GRID_N + (r + OUTER_R)

func terrain_at(q: int, r: int) -> int:
	if absi(q) > OUTER_R or absi(r) > OUTER_R:
		return -1
	return _terrain[_tidx(q, r)]

func _build_terrain_grid() -> void:
	_terrain.resize(GRID_N * GRID_N)
	_terrain.fill(-1)
	var hg: Node = shell.get("hex_grid")
	var cells: Dictionary = hg.get("cell_data") if hg != null and hg.get("cell_data") is Dictionary else {}
	if _is_tutorial_map():
		for key in cells.keys():
			var parts := str(key).split(",")
			if parts.size() != 2:
				continue
			var q := parts[0].to_int()
			var r := parts[1].to_int()
			if absi(q) <= OUTER_R and absi(r) <= OUTER_R:
				_terrain[_tidx(q, r)] = int(cells[key].terrain)
	else:
		for q in range(-OUTER_R, OUTER_R + 1):
			for r in range(-OUTER_R, OUTER_R + 1):
				var d: int = axial_dist(q, r)
				if d <= PLAY_R:
					var c: Variant = cells.get("%d,%d" % [q, r])
					_terrain[_tidx(q, r)] = int(c.terrain) if c != null else 0
				elif d <= OUTER_R:
					_terrain[_tidx(q, r)] = 13

func _build_cell_texture() -> void:
	_cell_img = Image.create(GRID_N, GRID_N, false, Image.FORMAT_RGBA8)
	for q in range(-OUTER_R, OUTER_R + 1):
		for r in range(-OUTER_R, OUTER_R + 1):
			var t: int = terrain_at(q, r)
			var playable: float = 1.0 if axial_dist(q, r) <= PLAY_R else 0.0
			if _is_tutorial_map():
				playable = 1.0 if t >= 0 else 0.0
			_cell_img.set_pixel(q + OUTER_R, r + OUTER_R, Color8(maxi(t, 0), 255, 0, int(playable * 255.0)))
	_cell_tex = ImageTexture.create_from_image(_cell_img)

func _common(m: ShaderMaterial) -> void:
	m.set_shader_parameter("cell_tex", _cell_tex)
	m.set_shader_parameter("hex_px", 1.0 / S)
	m.set_shader_parameter("ink", Vector3(INK.r, INK.g, INK.b))

# ----------------------------------------------------------------- positions

func to3(w: Vector2) -> Vector3:
	return Vector3(w.x * S, 0.0, w.y * S)

func hex3(q: int, r: int) -> Vector3:
	return to3(HexUtilsCls.hex_to_pixel(q, r))

func _scatter_in_hex(q: int, r: int, rmin: float, rmax: float) -> Vector3:
	var a: float = _rng.randf() * TAU
	var rr: float = lerpf(rmin, rmax, sqrt(_rng.randf())) * HEXR
	return hex3(q, r) + Vector3(cos(a) * rr, 0.0, sin(a) * rr)

# --------------------------------------------------------------------- ground

func _build_ground() -> void:
	mat_ground = ShaderMaterial.new()
	mat_ground.shader = GroundShader
	_common(mat_ground)
	var plane := PlaneMesh.new()
	plane.size = Vector2(1500.0, 1500.0)
	var mi := MeshInstance3D.new()
	mi.name = "Board"
	mi.mesh = plane
	mi.material_override = mat_ground
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

# -------------------------------------------------------------- card sprites

func _load_png(path: String) -> Texture2D:
	var img := Image.load_from_file(ProjectSettings.globalize_path(path))
	if img == null or img.is_empty():
		push_warning("[Closeup25D] missing sprite " + path)
		return null
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

func _card_mat(tex: Texture2D, uv_rect: Rect2, kind: int) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = CardShader
	_common(m)
	m.set_shader_parameter("tex", tex)
	var ts: Vector2 = tex.get_size()
	m.set_shader_parameter("uv_rect", Vector4(uv_rect.position.x / ts.x, uv_rect.position.y / ts.y, uv_rect.size.x / ts.x, uv_rect.size.y / ts.y))
	m.set_shader_parameter("kind", kind)
	_card_mats.append(m)
	if kind == 0:
		m.set_shader_parameter("flip_by_instance", true)
		_scenery_mats.append(m)
	return m

## Troop cards are a high-contrast gameplay marker layer. They use the same
## approved PNG art, but must not disappear behind decorative 3D scenery.
func _unit_card_mat(tex: Texture2D, uv_rect: Rect2) -> StandardMaterial3D:
	var sprite_tex: Texture2D = tex
	if uv_rect.position != Vector2.ZERO or uv_rect.size != tex.get_size():
		var atlas := AtlasTexture.new()
		atlas.atlas = tex
		atlas.region = uv_rect
		atlas.filter_clip = true
		sprite_tex = atlas
	var m := StandardMaterial3D.new()
	m.albedo_texture = sprite_tex
	# Formation PNGs are pixel art and shrink to only a few screen pixels when
	# the largest tutorial map is shown at full-board zoom. Nearest sampling
	# preserves the soldier silhouettes instead of averaging them into a blur.
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	m.no_depth_test = true
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	m.render_priority = 127
	return m

## One upright card per item: a unit quad (bottom-centre at the origin) is
## scaled per instance to the card's width/height. Buckets are spatial chunks
## so the camera culls them.
const CHUNK: float = 40.0

func _add_cards(mat: ShaderMaterial, aspect: float, items: Array, label: String) -> void:
	if items.is_empty():
		return
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	quad.center_offset = Vector3(0.0, 0.5, 0.0)
	var buckets: Dictionary = {}
	for it in items:
		var p: Vector3 = it[0]
		var key := Vector2i(int(floor(p.x / CHUNK)), int(floor(p.z / CHUNK)))
		if not buckets.has(key):
			buckets[key] = []
		buckets[key].append(it)
	for key in buckets.keys():
		var list: Array = buckets[key]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = quad
		mm.instance_count = list.size()
		for i in range(list.size()):
			var h: float = list[i][1]
			mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3(h * aspect, h, 1.0)), list[i][0]))
			mm.set_instance_custom_data(i, Color(_rng.randf_range(0.88, 1.08), 1.0 if _rng.randf() < 0.5 else 0.0, 0.0, 0.0))
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "%s_%d_%d" % [label, key.x, key.y]
		mmi.multimesh = mm
		mmi.material_override = mat
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# cards are billboards: pad the culling box by their height
		mmi.extra_cull_margin = 12.0
		add_child(mmi)

## Sprite set with its aspect (w/h) and material.
func _sprite(file: String, kind: int = 0) -> Dictionary:
	var tex: Texture2D = _load_png(SPRITES + file)
	if tex == null:
		return {}
	var sz: Vector2 = tex.get_size()
	return {"mat": _card_mat(tex, Rect2(Vector2.ZERO, sz), kind), "aspect": sz.x / sz.y}

## Approved atlas art cropped to its alpha bounds.
func _approved(path: String, kind: int) -> Dictionary:
	var tex: Texture2D = Registry.texture(path)
	var b: Rect2 = Registry.bounds(path)
	return {"mat": _card_mat(tex, b, kind), "aspect": b.size.x / b.size.y}

func _build_scenery() -> void:
	if str(shell.get("battlefield_id")) == "HC01":
		return # Supplied GLB assets replace the closeup scenery cards on HC01.
	var pines: Array = [_sprite("pine_0.png"), _sprite("pine_1.png"), _sprite("pine_2.png"), _sprite("pine_3.png")]
	var broad: Array = [_sprite("broad_0.png"), _sprite("broad_1.png")]
	var shrubs: Array = [_sprite("shrub_0.png"), _sprite("shrub_1.png")]
	var houses: Array = [_sprite("house_0.png"), _sprite("house_1.png")]
	var peaks: Array = []
	for stem in ["high_peak_A", "high_peak_B", "rough_mountain_A", "rough_mountain_B"]:
		peaks.append(_approved(Registry.path_for("mountain", stem), 2))
	var pine_items: Array = [[], [], [], []]
	var broad_items: Array = [[], []]
	var shrub_items: Array = [[], []]
	var house_items: Array = [[], []]
	var peak_items: Array = [[], [], [], []]
	var back: Vector3 = -fwd * 0.35 * HEXR # footprint art: front edge toward the viewer
	var n_forest: int = 0
	for q in range(-DRESS_R, DRESS_R + 1):
		for r in range(-DRESS_R, DRESS_R + 1):
			var d: int = axial_dist(q, r)
			if d > DRESS_R:
				continue
			var t: int = terrain_at(q, r)
			match t:
				2: # forest: tall, dense, around a clear centre so a unit stays visible
					n_forest += 1
					for k in range(16):
						var h: float = _rng.randf_range(5.2, 8.0)
						if _rng.randf() < 0.14:
							broad_items[0].append([_scatter_in_hex(q, r, 0.4, 0.98), h * 0.55])
						else:
							pine_items[_rng.randi() % 4].append([_scatter_in_hex(q, r, 0.4, 0.98), h])
					for k in range(4):
						shrub_items[0].append([_scatter_in_hex(q, r, 0.35, 0.95), _rng.randf_range(0.8, 1.2)])
				0:
					if _rng.randf() < 0.06:
						var h0: float = _rng.randf_range(4.2, 6.0)
						if _rng.randf() < 0.5:
							pine_items[_rng.randi() % 4].append([_scatter_in_hex(q, r, 0.55, 0.95), h0])
						else:
							broad_items[1 if _rng.randf() < 0.25 else 0].append([_scatter_in_hex(q, r, 0.55, 0.95), h0 * 0.6])
					if _rng.randf() < 0.6:
						shrub_items[1 if _rng.randf() < 0.12 else 0].append([_scatter_in_hex(q, r, 0.5, 0.95), _rng.randf_range(0.7, 1.1)])
				1: # mountain hex: one approved peak card, wide enough to form a range
					var pi: int = absi(q * 73856093 ^ r * 19349663) % 4
					peak_items[pi].append([hex3(q, r) + back, 2.0 * HEXR / float(peaks[pi]["aspect"])])
				3:
					for k in range(3):
						shrub_items[0].append([_scatter_in_hex(q, r, 0.2, 0.95), _rng.randf_range(0.7, 1.0)])
				5: # village: a few houses around the yard
					for k in range(_rng.randi_range(3, 5)):
						var hi: int = _rng.randi() % 2
						house_items[hi].append([_scatter_in_hex(q, r, 0.3, 0.8), _rng.randf_range(2.0, 2.5)])
				7:
					if _rng.randf() < 0.35:
						shrub_items[0].append([_scatter_in_hex(q, r, 0.8, 1.0), _rng.randf_range(0.7, 1.0)])
				13: # outer country: a wall of forest, sunk in obscurity anyway
					if d <= PLAY_R + 4:
						for k in range(3):
							pine_items[_rng.randi() % 4].append([_scatter_in_hex(q, r, 0.0, 1.0), _rng.randf_range(5.5, 8.0)])
	for i in range(4):
		_add_cards(pines[i]["mat"], pines[i]["aspect"], pine_items[i], "Pines%d" % i)
		_add_cards(peaks[i]["mat"], peaks[i]["aspect"], peak_items[i], "Peaks%d" % i)
	for i in range(2):
		_add_cards(broad[i]["mat"], broad[i]["aspect"], broad_items[i], "Broad%d" % i)
		_add_cards(shrubs[i]["mat"], shrubs[i]["aspect"], shrub_items[i], "Shrubs%d" % i)
		_add_cards(houses[i]["mat"], houses[i]["aspect"], house_items[i], "Houses%d" % i)
	print("[Closeup25D] forest hexes=%d pines=%d broad=%d" % [n_forest, pine_items[0].size() + pine_items[1].size() + pine_items[2].size() + pine_items[3].size(), broad_items[0].size() + broad_items[1].size()])

## Closeup art per stronghold role (1 fortress, 2 capital).
const STRONGHOLD_CARD_STEM := {1: "fortress_keep_A", 2: "stronghold_cluster_A"}

## Each stronghold is drawn as ONE card sized to ONE hex, standing on its
## anchor hex (the logical footprint cells around it are painted as a stone
## apron by the ground shader). Locations come from the shell's
## stronghold_visual_specs(), the same source the HIGH board uses.
func _build_strongholds() -> void:
	var specs: Array = shell.call("stronghold_visual_specs") if shell.has_method("stronghold_visual_specs") else []
	for sp in specs:
		var h: Vector2i = sp["anchor"]
		if terrain_at(h.x, h.y) != int(sp["terrain"]):
			push_warning("[Closeup25D] stronghold %s anchor %s is not stronghold terrain" % [str(sp["id"]), str(h)])
			continue
		_anchors.append(h)
		if str(shell.get("battlefield_id")) == "HC01":
			continue # The same anchors receive their real fort/stronghold GLBs.
		var art: Dictionary = _approved(Registry.path_for("fort", str(STRONGHOLD_CARD_STEM.get(int(sp["role"]), "fortress_keep_A"))), 2)
		# The whole stronghold stands INSIDE its hex: narrower than the hex's
		# flat-to-flat width (1.73 * HEXR), base just in front of the centre.
		var w: float = VisualContract.CLOSEUP_STRONGHOLD_WIDTH_OF_HEX * HEX_W
		var q := QuadMesh.new()
		q.size = Vector2(w, w / float(art["aspect"]))
		q.center_offset = Vector3(0.0, q.size.y * 0.5, 0.0)
		var mi := MeshInstance3D.new()
		mi.name = str(sp["id"])
		mi.mesh = q
		mi.material_override = art["mat"]
		mi.position = hex3(h.x, h.y) - fwd * 0.3 * HEXR
		add_child(mi)
	mat_ground.set_shader_parameter("anchor_a", Vector2(_anchors[0]) if _anchors.size() > 0 else Vector2(9999, 9999))
	mat_ground.set_shader_parameter("anchor_b", Vector2(_anchors[1]) if _anchors.size() > 1 else Vector2(9999, 9999))

# ------------------------------------------------------------------ unit parts

func _make_hex_ring(r_out: float, r_in: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for k in range(6):
		# Match the 48x42 flat-top vertices used by the board ground assets.
		var p0: Vector2 = HEX_LOCAL_VERTICES[k]
		var p1: Vector2 = HEX_LOCAL_VERTICES[(k + 1) % 6]
		var o0 := Vector3(p0.x, 0.0, p0.y) * (r_out / 24.0)
		var o1 := Vector3(p1.x, 0.0, p1.y) * (r_out / 24.0)
		var i0 := Vector3(p0.x, 0.0, p0.y) * (r_in / 24.0)
		var i1 := Vector3(p1.x, 0.0, p1.y) * (r_in / 24.0)
		for v in [[Vector3.ZERO, 0.0], [i0, 0.0], [i1, 0.0],
				[i0, 1.0], [o0, 1.0], [o1, 1.0],
				[i0, 1.0], [o1, 1.0], [i1, 1.0]]:
			st.set_uv(Vector2(v[1], 0.0))
			st.add_vertex(v[0])
	return st.commit()

func _build_base_materials() -> void:
	for key in ["blue", "red", "blue_sel", "red_sel", "blue_hov", "red_hov"]:
		var m := ShaderMaterial.new()
		m.shader = BaseShader
		m.render_priority = 2
		var col: Color = Color(0.32, 0.58, 1.0) if key.begins_with("blue") else Color(1.0, 0.34, 0.24)
		if key.ends_with("_sel"):
			col = Color(1.0, 0.82, 0.35)
			m.set_shader_parameter("fill_alpha", 0.26)
		if key.ends_with("_hov"):
			m.set_shader_parameter("fill_alpha", 0.24)
		m.set_shader_parameter("base_color", col)
		mat_base[key] = m

# ----------------------------------------------------------------------- camera

func _build_camera() -> void:
	cam = Camera3D.new()
	cam.name = "Camera3D"
	cam.near = 0.5
	cam.far = maxf(3600.0, _tutorial_full_camera_height(deg_to_rad(62.0)) * 2.5) if _is_tutorial_map() else (1600.0 if _uses_full_map_camera() else 560.0)
	cam.fov = 40.0
	if _uses_full_map_camera():
		cam.projection = Camera3D.PROJECTION_ORTHOGONAL
		cam.size = _tutorial_full_camera_height(deg_to_rad(62.0)) if _is_tutorial_map() else 700.0
	add_child(cam)
	_env = Environment.new()
	_env.background_mode = Environment.BG_COLOR
	_env.background_color = Color("d9d5cb") if _is_strict_map() else INK
	if _is_strict_map():
		_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		_env.ambient_light_color = Color("f2ecde")
		_env.ambient_light_energy = 0.85
	_env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = _env
	add_child(we)

func _hq_world() -> Vector2:
	var ur: Node = shell.get("unit_renderer")
	var id: String = str(shell.get("_blue_hq_id"))
	if id != "" and ur and ur.has_method("get_unit_node"):
		var n: Node2D = ur.call("get_unit_node", id) as Node2D
		if n and is_instance_valid(n):
			_hq_last = n.position
			return _hq_last
	if _hq_last == Vector2.INF and ur:
		for u in (ur.call("get_all_units") as Array):
			if str(u.get("class", "")) == "hq" and str(u.get("faction", "")) == "blue":
				_hq_last = HexUtilsCls.hex_to_pixel(int(u.get("q", 0)), int(u.get("r", 0)))
	return _hq_last if _hq_last != Vector2.INF else Vector2.ZERO

var _cam_pos: Vector3 = Vector3.ZERO
var _focus: Vector3 = Vector3.ZERO

func _update_camera() -> void:
	# While active the Camera2D is anchored on the HQ itself, so its position
	# is HQ + pan (NEXT focus / reset / WASD all land where expected).
	var f2: Vector2 = cam2d.global_position
	# The selected-hex pulse is the only per-frame animation in the closeup.
	mat_ground.set_shader_parameter("select_pulse", 0.75 + 0.25 * sin(_time * 4.0))
	if _uses_full_map_camera():
		# Test map: the same native 3D view covers the whole radius-40 board and
		# every playable zoom. Camera2D supplies existing pan, zoom and reset input.
		var z: float = maxf(0.3, cam2d.zoom.x)
		var full_sig := Vector4(f2.x, f2.y, z, 1.0)
		if full_sig.is_equal_approx(_cam_sig):
			return
		_cam_sig = full_sig
		_focus = to3(f2)
		var pitch_full := deg_to_rad(lerpf(62.0, 40.0, clampf((z - 0.30) / 2.70, 0.0, 1.0)) if _is_strict_map() else 62.0)
		var distance_full := 720.0
		_cam_pos = _focus - fwd * cos(pitch_full) * distance_full + Vector3.UP * sin(pitch_full) * distance_full
		var base_height: float = _tutorial_full_camera_height(pitch_full) if _is_tutorial_map() else 700.0
		cam.size = base_height * (0.30 / z)
		cam.look_at_from_position(_cam_pos, _focus, Vector3.UP)
		if _is_strict_map() and strict_transplant != null:
			strict_transplant.call("update_lod_for_camera", cam)
		_occ_sig = 0
		mat_ground.set_shader_parameter("focus_xz", Vector2(_focus.x, _focus.z))
		mat_ground.set_shader_parameter("mask_start", 100000.0)
		mat_ground.set_shader_parameter("mask_end", 100001.0)
		for card_mat in _card_mats:
			card_mat.set_shader_parameter("focus_xz", Vector2(_focus.x, _focus.z))
			card_mat.set_shader_parameter("mask_start", 100000.0)
			card_mat.set_shader_parameter("mask_end", 100001.0)
		return
	# Everything else is re-sent only when the camera actually moved.
	var sig := Vector4(f2.x, f2.y, _dolly, 0.0)
	if sig.is_equal_approx(_cam_sig):
		return
	_cam_sig = sig
	_focus = Vector3(f2.x * S, 0.0, f2.y * S)
	var rise: float = clampf((_dolly - DOLLY_MIN) / (DOLLY_MAX - DOLLY_MIN), 0.0, 1.0)
	var pitch: float = deg_to_rad(lerpf(22.0, 46.0, rise))
	var dist: float = 50.0 * _dolly
	var target: Vector3 = _focus + fwd * 2.5 * HEX_W
	var dir: Vector3 = (fwd * cos(pitch) - Vector3.UP * sin(pitch)).normalized()
	_cam_pos = target - dir * dist
	cam.look_at_from_position(_cam_pos, target, Vector3.UP)
	_occ_sig = 0 # the line-of-sight corridors depend on the lens position
	var reach: float = maxf(1.0, _dolly)
	var fx := Vector2(target.x, target.z)
	mat_ground.set_shader_parameter("focus_xz", fx)
	mat_ground.set_shader_parameter("mask_start", 4.5 * HEX_W * reach)
	mat_ground.set_shader_parameter("mask_end", 9.5 * HEX_W * reach)
	for m in _card_mats:
		m.set_shader_parameter("focus_xz", fx)
		m.set_shader_parameter("mask_start", 4.5 * HEX_W * reach)
		m.set_shader_parameter("mask_end", 9.5 * HEX_W * reach)
	for m in _scenery_mats:
		m.set_shader_parameter("cam_world", _cam_pos)
		m.set_shader_parameter("near_fade_start", dist * 0.42)
		m.set_shader_parameter("near_fade_end", dist * 0.6)

func _tutorial_full_camera_height(pitch: float) -> float:
	if not _is_tutorial_map():
		return 700.0
	var cells: Dictionary = shell.get("hex_grid").get("cell_data")
	if cells.is_empty():
		return 700.0
	var forward := Vector2(fwd.x, fwd.z).normalized()
	var across := Vector2(-forward.y, forward.x)
	var min_forward := INF
	var max_forward := -INF
	var min_across := INF
	var max_across := -INF
	for cell in cells.values():
		var p: Vector2 = HexUtilsCls.hex_to_pixel(int(cell.q), int(cell.r)) * S
		var along_value := p.dot(forward)
		var across_value := p.dot(across)
		min_forward = minf(min_forward, along_value)
		max_forward = maxf(max_forward, along_value)
		min_across = minf(min_across, across_value)
		max_across = maxf(max_across, across_value)
	var projected_height := (max_forward - min_forward) * sin(pitch)
	var projected_width := max_across - min_across
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	var aspect := viewport_size.x / maxf(viewport_size.y, 1.0)
	return maxf(projected_height, projected_width / maxf(aspect, 0.1)) + HEXR * S * 2.0

# ----------------------------------------------------------- 2D layer handling
# Canvas visibility layers / the main viewport cull mask are owned by
# PresentationModeController (LAYER_WORLD / LAYER_OVERLAY live there too).

## Called by the mode controller for nodes added under a 2D world visual
## while this view is active: floating combat text on the 2D board is
## mirrored as a camera-facing label here.
func on_world_node_added(n: Node) -> void:
	var ur: Node = shell.get("unit_renderer")
	if _active and n is Label and n.get_parent() == ur:
		call_deferred("_mirror_floating_text", n)

func _mirror_floating_text(lbl: Label) -> void:
	if not is_instance_valid(lbl):
		return
	var w: Vector2 = lbl.position + lbl.pivot_offset
	var l3 := Label3D.new()
	l3.text = lbl.text
	l3.modulate = lbl.get_theme_color("font_color")
	l3.outline_modulate = Color(0, 0, 0, 1)
	l3.font_size = 40
	l3.outline_size = 10
	l3.pixel_size = 0.0012
	l3.fixed_size = true
	l3.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l3.no_depth_test = true
	l3.render_priority = 5
	var p: Vector3 = to3(w) + Vector3(0, CARD_BODY_H * 1.4, 0)
	l3.position = p
	add_child(l3)
	var tw: Tween = create_tween().set_parallel(true)
	tw.tween_property(l3, "position", p + Vector3(0, 1.5, 0), 0.9).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_property(l3, "modulate:a", 0.0, 0.6).set_delay(0.35)
	tw.chain().tween_callback(l3.queue_free)

func _build_overlay_viewport() -> void:
	_overlay_vp = SubViewport.new()
	_overlay_vp.name = "CloseupOverlay"
	_overlay_vp.world_2d = get_viewport().world_2d
	_overlay_vp.transparent_bg = true
	_overlay_vp.disable_3d = true
	_overlay_vp.size = Vector2i(int(OVERLAY_SIZE.x * OVERLAY_SCALE), int(OVERLAY_SIZE.y * OVERLAY_SCALE))
	_overlay_vp.canvas_cull_mask = ModeControllerCls.LAYER_OVERLAY
	_overlay_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_overlay_vp.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_LINEAR
	_overlay_vp.canvas_transform = Transform2D(0.0, Vector2(OVERLAY_SCALE, OVERLAY_SCALE), 0.0, -OVERLAY_ORIGIN * OVERLAY_SCALE)
	add_child(_overlay_vp)
	mat_ground.set_shader_parameter("overlay_tex", _overlay_vp.get_texture())
	mat_ground.set_shader_parameter("overlay_origin", OVERLAY_ORIGIN)
	mat_ground.set_shader_parameter("overlay_size", OVERLAY_SIZE)

## Visible world rect for 2D overlay culling: the whole board.
func visible_world_rect() -> Rect2:
	return Rect2(OVERLAY_ORIGIN, OVERLAY_SIZE)

# ------------------------------------------------------------------------ units

func _make_unit(u: Dictionary) -> Dictionary:
	var cls: String = str(u.get("class", "infantry"))
	var faction: String = str(u.get("faction", "blue"))
	var root := Node3D.new()
	root.name = "U_" + str(u.get("id", ""))
	add_child(root)
	var card: Dictionary = _unit_card(cls, faction)
	var fig := MeshInstance3D.new()
	fig.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	fig.mesh = card["mesh"]
	fig.material_override = card["mat"]
	# Lower only this camera-facing presentation card, leaving header room for
	# a readable strength count while keeping the soldiers inside their hex.
	fig.position.y = -2.0
	root.add_child(fig)
	var base := MeshInstance3D.new()
	base.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	base.mesh = _hex_ring
	base.material_override = mat_base[faction]
	# Tutorial ground is raised to y=0.12 so the imported presentation hides its
	# source seams. Put the faction ring on that same logical ground plane; a
	# lower ring is projected at a different screen position by the oblique view.
	base.position.y = _board_surface_y + 0.01 if _is_strict_map() else 0.03
	root.add_child(base)
	var lbl := Label3D.new()
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.fixed_size = true
	lbl.pixel_size = 0.0012
	lbl.font_size = 32
	lbl.outline_size = 7
	lbl.no_depth_test = true
	lbl.render_priority = 127
	lbl.modulate = Color(0.80, 0.90, 1.0) if faction == "blue" else Color(1.0, 0.80, 0.74)
	lbl.outline_modulate = Color(0.02, 0.03, 0.06, 0.95)
	lbl.position = Vector3(0.0, float(card["top"]) - 0.5, 0)
	root.add_child(lbl)
	return {"root": root, "base": base, "label": lbl, "faction": faction, "state": ""}

## Quad + material for one approved formation sprite: feet (body bottom) at
## the origin; the body fits a CARD_BODY_W x CARD_BODY_H box so every
## formation reads at the same size (same fit rule as the board markers).
func _unit_card(cls: String, faction: String) -> Dictionary:
	var key: String = cls + "|" + faction
	if _cards.has(key):
		return _cards[key]
	var res: String = Registry.unit(cls, faction)
	var tex: Texture2D
	var body: Rect2
	var bounds: Rect2
	if cls != "hq" and cls != "supply":
		var formation: Dictionary = FormationSpriteCompositor.compose(res)
		tex = formation.get("texture") as Texture2D
		body = formation.get("body", Registry.body(res))
		bounds = formation.get("bounds", Registry.bounds(res))
	else:
		tex = Registry.texture(res)
		body = Registry.body(res)
		bounds = Registry.bounds(res)
	var pix: float = minf(CARD_BODY_H / maxf(body.size.y, 1.0), CARD_BODY_W / maxf(body.size.x, 1.0))
	var w: float = bounds.size.x * pix
	var h: float = bounds.size.y * pix
	var feet_y: float = body.end.y - bounds.position.y
	var bcx: float = (body.position.x + body.end.x) * 0.5 - bounds.position.x
	var q := QuadMesh.new()
	q.size = Vector2(w, h)
	q.center_offset = Vector3((bounds.size.x * 0.5 - bcx) * pix, (feet_y - bounds.size.y * 0.5) * pix, 0.0)
	var m: StandardMaterial3D = _unit_card_mat(tex, bounds)
	var c: Dictionary = {"mesh": q, "mat": m, "top": q.center_offset.y + h * 0.5}
	_cards[key] = c
	return c

func _sync_units() -> void:
	var ur: Node = shell.get("unit_renderer")
	if ur == null:
		return
	var list: Array = ur.call("get_all_units")
	var seen: Dictionary = {}
	var sel_id: String = str(ur.call("get_selected_unit_id")) if ur.has_method("get_selected_unit_id") else ""
	var hov_id: String = str(ur.call("get_hovered_unit_id")) if ur.has_method("get_hovered_unit_id") else ""
	var cells: Dictionary = {}
	var occ_list: Array = []
	var sel_hex := Vector2(9999, 9999)
	for u in list:
		var id: String = str(u.get("id", ""))
		var n2: Node2D = ur.call("get_unit_node", id) as Node2D
		if n2 == null or not is_instance_valid(n2):
			continue
		seen[id] = true
		if not _units.has(id):
			_units[id] = _make_unit(u)
		var d: Dictionary = _units[id]
		var vis: bool = n2.is_visible_in_tree() and n2.modulate.a > 0.05
		var root: Node3D = d["root"]
		root.visible = vis
		if not vis:
			continue
		var p: Vector3 = to3(n2.position)
		root.position = p
		occ_list.append(p + Vector3(0, CARD_BODY_H * 0.5 - 2.0, 0))
		var faction: String = d["faction"]
		var state: String = faction
		if id == sel_id:
			state = faction + "_sel"
		elif id == hov_id:
			state = faction + "_hov"
		if state != d["state"]:
			d["state"] = state
			(d["base"] as MeshInstance3D).material_override = mat_base[state]
		var count_txt: String = str(int(u.get("soldier_count", 0)))
		if (d["label"] as Label3D).text != count_txt:
			(d["label"] as Label3D).text = count_txt
		var q: int = int(u.get("q", 0))
		var r: int = int(u.get("r", 0))
		cells[Vector2i(q, r)] = 1 if faction == "blue" else 2
		if id == sel_id:
			sel_hex = Vector2(q, r)
	for id in _units.keys():
		if not seen.has(id):
			(_units[id]["root"] as Node3D).queue_free()
			_units.erase(id)
	_push_occluders(occ_list)
	mat_ground.set_shader_parameter("select_hex", sel_hex)
	var hov: Variant = shell.get("_current_hover_hex")
	mat_ground.set_shader_parameter("hover_hex", Vector2(hov.x, hov.y) if hov is Vector2i else Vector2(9999, 9999))
	if not _dict_equal(cells, _unit_cells):
		for c in _unit_cells.keys():
			_set_cell_b(c, 0)
		for c in cells.keys():
			_set_cell_b(c, cells[c])
		_unit_cells = cells
		_cell_dirty = true

## The nearest visible units clear a see-through corridor in the scenery
## between them and the lens; the forest stays dense everywhere else.
func _push_occluders(pts: Array) -> void:
	# Re-sent only when a unit moved or the lens moved (_update_camera resets
	# _occ_sig); idle frames cost nothing.
	var sig: int = hash(pts)
	if sig == _occ_sig:
		return
	_occ_sig = sig
	var cp: Vector3 = _cam_pos
	pts.sort_custom(func(a, c): return a.distance_squared_to(cp) < c.distance_squared_to(cp))
	var n: int = mini(pts.size(), 16)
	var arr := PackedFloat32Array()
	arr.resize(64)
	for i in range(n):
		var p: Vector3 = pts[i]
		arr[i * 4] = p.x; arr[i * 4 + 1] = p.y; arr[i * 4 + 2] = p.z; arr[i * 4 + 3] = 2.4
	for m in _scenery_mats:
		m.set_shader_parameter("occ", arr)
		m.set_shader_parameter("occ_count", n)

func _set_cell_b(c: Vector2i, v: int) -> void:
	if absi(c.x) > OUTER_R or absi(c.y) > OUTER_R:
		return
	var px: Color = _cell_img.get_pixel(c.x + OUTER_R, c.y + OUTER_R)
	px.b8 = v
	_cell_img.set_pixel(c.x + OUTER_R, c.y + OUTER_R, px)

static func _dict_equal(a: Dictionary, c: Dictionary) -> bool:
	if a.size() != c.size():
		return false
	for k in a.keys():
		if not c.has(k) or c[k] != a[k]:
			return false
	return true

func _sync_fog_of_war(delta: float) -> void:
	_fow_timer -= delta
	if _fow_timer > 0.0:
		return
	_fow_timer = 0.25
	var fog: Variant = shell.get("_fog")
	var sig: int = 0
	if fog != null:
		var vis: Dictionary = fog.get("visible")
		var exp_d: Dictionary = fog.get("explored")
		sig = vis.size() * 7919 + exp_d.size() * 31 + hash(vis.keys()) % 100003
	if sig == _fow_sig:
		return
	_fow_sig = sig
	for q in range(-PLAY_R, PLAY_R + 1):
		for r in range(-PLAY_R, PLAY_R + 1):
			if axial_dist(q, r) > PLAY_R:
				continue
			var g: int = 255
			if fog != null:
				var st: int = int(fog.call("get_fog_state", q, r))
				g = 255 if st == 2 else (128 if st == 1 else 0)
			var px: Color = _cell_img.get_pixel(q + OUTER_R, r + OUTER_R)
			px.g8 = g
			_cell_img.set_pixel(q + OUTER_R, r + OUTER_R, px)
	_cell_dirty = true

# ---------------------------------------------------------------------- picking

## Exact pointer inverse: screen pixel -> battlefield world px (the board is
## the flat y = 0 plane).
func screen_to_world(screen_pos: Vector2) -> Vector2:
	if cam == null:
		return Vector2(1.0e7, 1.0e7)
	var o: Vector3 = cam.project_ray_origin(screen_pos)
	var dv: Vector3 = cam.project_ray_normal(screen_pos)
	if dv.y > -0.0001:
		return Vector2(1.0e7, 1.0e7)
	var p: Vector3 = o + dv * (-o.y / dv.y)
	return Vector2(p.x / S, p.z / S)

func world_to_screen(w: Vector2) -> Vector2:
	return cam.unproject_position(to3(w))

# ------------------------------------------------------------------------ frame

func _process(delta: float) -> void:
	_time += delta
	_update_transition(delta)
	if cam2d == null or shell == null or not _active:
		return
	_update_camera()
	_sync_units()
	_sync_fog_of_war(delta)
	if _cell_dirty:
		_cell_tex.update(_cell_img)
		_cell_dirty = false

func zoom_close() -> float:
	return ZOOM_CLOSE

func zoom_high() -> float:
	return ZOOM_HIGH

func _hq_anchor(_z: float) -> Vector2:
	return _hq_world()

func board_max_zoom() -> float:
	return 3.0 if _uses_full_map_camera() else BOARD_MAX_ZOOM

func is_active() -> bool:
	return _active

# ------------------------------------------------------------ state switching

## Closeup-local activation. Called ONLY by PresentationModeController, the
## one mode authority (it also switches the projection and the viewport cull
## mask). Nothing gameplay-side changes; only what the main viewport draws.
func apply_active(on: bool) -> void:
	_active = on
	visible = on
	var vp: Viewport = get_viewport()
	if on:
		_saved_msaa = vp.msaa_3d
		vp.msaa_3d = Viewport.MSAA_2X
		cam.make_current()
		if cam2d:
			_board_anchor = cam2d.get("anchor_provider")
			if _uses_full_map_camera():
				cam2d.set("anchor_provider", Callable())
				cam2d.set("zoom_anchor_solver", Callable())
				cam2d.set("min_zoom", 0.30)
				cam2d.set("max_zoom", 3.0)
				cam2d.call("set_home_view", Vector2.ZERO, 0.30)
				cam2d.call("set_zoom_level", 0.30, true)
				cam2d.call("focus_on", Vector2.ZERO, true)
			else:
				var pan_now: Vector2 = cam2d.get("pan_offset")
				cam2d.set("anchor_provider", Callable(self, "_hq_anchor"))
				cam2d.global_position = _hq_world() + pan_now
		_overlay_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		_dolly = 1.0
		_fow_sig = -1
		_cam_sig = Vector4.INF
		_update_camera()
		_sync_units()
	else:
		vp.msaa_3d = _saved_msaa
		if cam:
			cam.clear_current(false)
		if cam2d and _board_anchor.is_valid():
			cam2d.set("anchor_provider", _board_anchor)
		if _overlay_vp:
			_overlay_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED

## Mode switch through a short flat ink fade (no animated weather veil).
func request_mode(closeup: bool) -> void:
	if _uses_full_map_camera():
		return # HC01 uses the native 3D camera at every map zoom.
	if _trans_phase != 0 or closeup == _active:
		return
	_trans_target = closeup
	_trans_phase = 1
	_trans_t = 0.0
	_fade_layer.visible = true

func _update_transition(delta: float) -> void:
	if _trans_phase == 0:
		return
	_trans_t += delta
	if _trans_phase == 1:
		var k: float = clampf(_trans_t / FADE_IN, 0.0, 1.0)
		_fade.color.a = k
		if k >= 1.0:
			if not _trans_target and cam2d:
				cam2d.call("set_zoom_level", BOARD_MAX_ZOOM, true)
			if mode_controller != null:
				mode_controller.call("set_mode", PresentationOrientationCls.Mode.CLOSEUP if _trans_target else PresentationOrientationCls.Mode.HIGH)
			_trans_phase = 2
			_trans_t = 0.0
	else:
		var k2: float = clampf(_trans_t / FADE_OUT, 0.0, 1.0)
		_fade.color.a = 1.0 - k2
		if k2 >= 1.0:
			_trans_phase = 0
			_fade_layer.visible = false

## Wheel at the board's zoom cap enters the closeup; in the closeup the wheel
## dollies a little and backs out to the board. Runs before the Camera2D's
## own wheel handling (later sibling in the tree).
func _unhandled_input(event: InputEvent) -> void:
	if _uses_full_map_camera():
		return # The Camera2D's ordinary wheel handler controls 3D map zoom.
	if not (event is InputEventMouseButton) or not (event as InputEventMouseButton).pressed or cam2d == null:
		return
	var mb: InputEventMouseButton = event
	if mb.button_index != MOUSE_BUTTON_WHEEL_UP and mb.button_index != MOUSE_BUTTON_WHEEL_DOWN:
		return
	var up: bool = mb.button_index == MOUSE_BUTTON_WHEEL_UP
	if _trans_phase != 0:
		get_viewport().set_input_as_handled()
		return
	if _active:
		if up:
			_dolly = maxf(DOLLY_MIN, _dolly / 1.12)
		elif _dolly < DOLLY_MAX - 0.001:
			_dolly = minf(DOLLY_MAX, _dolly * 1.12)
		else:
			request_mode(false)
		get_viewport().set_input_as_handled()
	elif up and float(cam2d.get("target_zoom")) >= BOARD_MAX_ZOOM - 0.001:
		request_mode(true)
		get_viewport().set_input_as_handled()

func _build_fade() -> void:
	_fade_layer = CanvasLayer.new()
	_fade_layer.name = "CloseupFade"
	_fade_layer.layer = 29
	_fade_layer.visible = false
	add_child(_fade_layer)
	_fade = ColorRect.new()
	_fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade.color = Color(INK.r, INK.g, INK.b, 0.0)
	_fade_layer.add_child(_fade)
