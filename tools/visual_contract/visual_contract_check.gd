extends SceneTree

## VISUAL CONTRACT CHECK (frontend-only regression gate).
##
## Enforces docs/visual/VISUAL_DESIGN_LANGUAGE.md with cheap static scans and
## a real boot of the Step2R battle shell. Reads presentation state only;
## never drives gameplay beyond booting the scene.
##
## Headless (safe anywhere, incl. next to training; ~5 s):
##   Godot_v4.2.2-stable_win64_console.exe --headless --path <project> \
##     --script res://tools/visual_contract/visual_contract_check.gd
## Windowed (adds HIGH <-> CLOSEUP mode, camera and one-hex art checks):
##   Godot_v4.2.2-stable_win64_console.exe --path <project> \
##     --script res://tools/visual_contract/visual_contract_check.gd -- --windowed
## Optional: -- --out=<report.json>   Exit code 0 = all PASS, 1 = any FAIL.

const VisualContract = preload("res://scripts/visual/visual_contract.gd")
const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")
const PO = preload("res://scripts/core/presentation_orientation.gd")
const SHELL_SCENE := "res://scenes/step2r_battlefield_shell.tscn"

## Gameplay code must never read presentation state (visual transforms may not
## leak into simulation). These trees are scanned for the names below.
const GAMEPLAY_DIRS: Array[String] = ["res://scripts/combat", "res://scripts/sim", "res://scripts/step5", "res://scripts/step6", "res://scripts/selfplay"]
const GAMEPLAY_FILES: Array[String] = ["res://scripts/step3/step3_unit_manager.gd", "res://scripts/step3/step3_pathfinding.gd", "res://scripts/core/step3_config.gd", "res://scripts/core/stronghold.gd", "res://scripts/core/stronghold_manager.gd", "res://scripts/core/hex_utils.gd", "res://scripts/core/hex_cell.gd"]
const PRESENTATION_NAMES: Array[String] = ["PresentationOrientation", "presentation_orientation.gd", "PresentationProjection", "battlefield_closeup_view", "presentation_mode_controller", "visual_contract.gd"]
## Live presentation code scanned by the static checks.
const VISUAL_DIRS: Array[String] = ["res://scripts/visual", "res://scripts/step2r"]
const VISUAL_FILES: Array[String] = ["res://scripts/core/presentation_orientation.gd", "res://scripts/core/stronghold_renderer.gd", "res://scripts/core/step2r_stronghold_badge.gd", "res://scripts/core/hex_grid.gd", "res://scripts/step3/step3_envelope_renderer.gd"]

var _results: Array = []
var _windowed: bool = false
var _out: String = ""
var _shell: Node = null
var _frame: int = 0
var _stage: int = 0
var _sandbox_pass: bool = true

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a == "--windowed":
			_windowed = true
		elif a.begins_with("--out="):
			_out = a.substr(6)
	if not _windowed and DisplayServer.get_name() != "headless":
		# Plain windowed launch without the flag still runs the headless set.
		pass
	_static_checks()
	root.size = Vector2i(1920, 1080)
	_boot(true)

# ============================================================== reporting

func _check(id: String, ok: bool, detail: String = "") -> void:
	if _bf_i >= 0 and not id.contains(str(_bf_ids[_bf_i])):
		id += "_" + str(_bf_ids[_bf_i])
	_results.append({"id": id, "ok": ok, "detail": detail})
	print("[VISUAL-CONTRACT] %s %s%s" % ["PASS" if ok else "FAIL", id, (" | " + detail) if detail != "" else ""])

func _finish() -> void:
	var fails: int = 0
	for r in _results:
		if not bool(r["ok"]):
			fails += 1
	var rep := {"windowed": _windowed, "checks": _results.size(), "failures": fails, "results": _results}
	if _out != "":
		var f := FileAccess.open(_out, FileAccess.WRITE)
		if f:
			f.store_string(JSON.stringify(rep, "  "))
			f.close()
	print("[VISUAL-CONTRACT] %s: %d checks, %d failures" % ["PASS" if fails == 0 else "FAIL", _results.size(), fails])
	quit(0 if fails == 0 else 1)

# ============================================================ static scans

func _files_under(dir: String, exts: Array) -> Array:
	var out: Array = []
	var d := DirAccess.open(dir)
	if d == null:
		return out
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		var p := dir.path_join(n)
		if d.current_is_dir():
			if not n.begins_with("."):
				out.append_array(_files_under(p, exts))
		elif n.get_extension() in exts:
			out.append(p)
		n = d.get_next()
	return out

func _text(p: String) -> String:
	return FileAccess.get_file_as_string(p)

## Shader source reads the TIME built-in (comments ignored).
static func _uses_time(src: String) -> bool:
	var re := RegEx.new()
	re.compile("/\\*[\\s\\S]*?\\*/|//[^\\n]*")
	var code: String = re.sub(src, "", true)
	var tok := RegEx.new()
	tok.compile("\\bTIME\\b")
	return tok.search(code) != null

func _static_checks() -> void:
	# S1 retired visual paths stay retired (files gone, nothing references them).
	var present: Array = []
	for p in VisualContract.RETIRED_SCRIPT_PATHS:
		var ps := str(p)
		if ps.ends_with("/"):
			if DirAccess.dir_exists_absolute(ps):
				present.append(ps)
		elif FileAccess.file_exists(ps):
			present.append(ps)
	_check("S1a_retired_paths_absent", present.is_empty(), str(present))
	var refs: Array = []
	for f in _files_under("res://scripts", ["gd"]) + _files_under("res://scenes", ["tscn"]):
		if str(f).ends_with("visual_contract.gd"):
			continue
		var t := _text(f)
		for p in VisualContract.RETIRED_SCRIPT_PATHS:
			if t.find(str(p)) != -1:
				refs.append("%s -> %s" % [f, p])
	_check("S1b_no_refs_to_retired_paths", refs.is_empty(), str(refs.slice(0, 5)))
	# S2 no continuous shader animation (TIME) and no inline shader strings.
	var visual_files: Array = []
	for d in VISUAL_DIRS:
		visual_files.append_array(_files_under(d, ["gd", "gdshader", "gdshaderinc"]))
	for f in VISUAL_FILES:
		visual_files.append(f)
	var timed: Array = []
	var inline: Array = []
	var forbidden: Array = []
	for f in visual_files:
		var t := _text(f)
		var ext := str(f).get_extension()
		if ext != "gd":
			if _uses_time(t) and not VisualContract.TIME_SHADER_ALLOWLIST.has(f):
				timed.append(f)
			continue
		if t.find("shader_type ") != -1:
			inline.append(f)
		for cls in VisualContract.FORBIDDEN_NODE_CLASSES:
			if t.find(str(cls) + ".new(") != -1:
				forbidden.append("%s: %s" % [f, cls])
	_check("S2a_no_TIME_in_presentation_shaders", timed.is_empty(), str(timed))
	_check("S2b_no_inline_shader_code", inline.is_empty(), str(inline))
	_check("S3_no_forbidden_node_classes_in_visual_code", forbidden.is_empty(), str(forbidden))
	# S4 closeup is 2.5D: every closeup shader is unshaded (no lighting model).
	var lit: Array = []
	for f in _files_under("res://scripts/visual/closeup25d", ["gdshader"]):
		if _text(f).find("unshaded") == -1:
			lit.append(f)
	_check("S4_closeup_shaders_unshaded", lit.is_empty(), str(lit))
	# S5 gameplay never imports presentation state.
	var gp: Array = []
	for d in GAMEPLAY_DIRS:
		gp.append_array(_files_under(d, ["gd"]))
	gp.append_array(GAMEPLAY_FILES)
	var leaks: Array = []
	for f in gp:
		var t := _text(f)
		for nm in PRESENTATION_NAMES:
			if t.find(str(nm)) != -1:
				leaks.append("%s: %s" % [f, nm])
	_check("S5_gameplay_does_not_read_presentation", leaks.is_empty(), str(leaks))

# ============================================================ runtime boot

## Canonical battlefields (res://data/battlefields): each is booted after the
## default checks and gets the same runtime + stronghold-spec checks.
const BattlefieldCatalog = preload("res://scripts/battlefields/battlefield_catalog.gd")
var _bf_ids: Array = []
var _bf_i: int = -1

func _boot_battlefield() -> void:
	_bf_i += 1
	if _shell != null:
		_shell.queue_free()
		_shell = null
	_shell = (load(SHELL_SCENE) as PackedScene).instantiate()
	_shell.set("battlefield_id", str(_bf_ids[_bf_i]))
	root.add_child(_shell)
	_frame = 0
	_stage = 10

func _battlefield_checks() -> void:
	var id: String = str(_bf_ids[_bf_i])
	_check("B1_%s_loaded" % id, str(_shell.get("battlefield_id")) == id and (_shell.get("hex_grid").get("cell_data") as Dictionary).size() == 4921, str(_shell.get("battlefield_id")))
	_runtime_checks(id)
	_stronghold_spec_checks(id)

## Next battlefield, or finish. Returns true when the checker is done.
func _next_battlefield() -> bool:
	if _bf_ids.is_empty() and _bf_i < 0:
		_bf_ids = BattlefieldCatalog.ids()
	if _bf_i + 1 < _bf_ids.size():
		_boot_battlefield()
		return false
	_finish()
	return true

func _boot(sandbox: bool) -> void:
	if _shell != null:
		# Boot the next shell while the old one is still queued for free: the
		# owner token must keep the new shell's presentation state intact.
		_shell.queue_free()
		_shell = null
	var ps: PackedScene = load(SHELL_SCENE)
	_shell = ps.instantiate()
	_shell.set("is_step0_sandbox", sandbox)
	root.add_child(_shell)
	_frame = 0

func _process(_d: float) -> bool:
	_frame += 1
	match _stage:
		0:
			if _frame == 30:
				_runtime_checks("sandbox")
				_stage = 1
				_boot(false)
		1:
			if _frame == 30:
				_runtime_checks("production")
				_stronghold_spec_checks()
				if _windowed and DisplayServer.get_name() != "headless":
					_stage = 2
				else:
					return _next_battlefield()
		2:
			if _frame == 45:
				_windowed_checks_closeup()
				(_shell.get("_mode_controller") as Node).call("set_mode", PO.Mode.HIGH)
				_stage = 3
				_frame = 0
		3:
			if _frame == 20:
				_windowed_checks_high()
				(_shell.get("_mode_controller") as Node).call("set_mode", PO.Mode.CLOSEUP)
				_stage = 4
				_frame = 0
		4:
			if _frame == 10:
				_check("W9_back_to_closeup", PO.mode == PO.Mode.CLOSEUP and bool(_shell.get_node("BattlefieldCloseupView").call("is_active")))
				return _next_battlefield()
		10:
			if _frame == 30:
				_battlefield_checks()
				if _windowed and DisplayServer.get_name() != "headless":
					_stage = 2 # same windowed checks (framing, one-hex structures) per battlefield
				else:
					return _next_battlefield()
	return false

static func _angle_diff(a: float, b: float) -> float:
	return absf(wrapf(a - b, -PI, PI))

func _runtime_checks(tag: String) -> void:
	var headless: bool = DisplayServer.get_name() == "headless"
	var cam: Camera2D = _shell.get("camera")
	var ur: Node = _shell.get("unit_renderer")
	var um = _shell.get("unit_manager")
	var hg: Node = _shell.get("hex_grid")
	# R1 explicit presentation mode
	if headless:
		_check("R1a_%s_mode_headless" % tag, PO.mode == PO.Mode.HEADLESS, "mode=%d" % PO.mode)
		_check("R1b_%s_headless_builds_no_scenery" % tag, _shell.get("_projection") == null and _shell.get("_view3d") == null and _shell.get("_mode_controller") == null and (_shell.get("hex_compositor").get("descriptors") as Dictionary).is_empty())
	else:
		_check("R1a_%s_mode_presented" % tag, PO.mode in [PO.Mode.HIGH, PO.Mode.CLOSEUP, PO.Mode.FLAT], "mode=%d" % PO.mode)
	# R2 HexGrid is data-only in the battle
	_check("R2_%s_hexgrid_data_only" % tag, not bool(hg.get("legacy_presentation")) and (hg.get("hex_nodes") as Dictionary).is_empty() and not hg.is_processing_unhandled_input(), "hex_nodes=%d" % (hg.get("hex_nodes") as Dictionary).size())
	# R3 one orientation rule: camera yaw maps BLUE forward (+q) to screen-up
	var yaw: float = PO.yaw_rad
	var up: Vector2 = PO.friendly_forward_world().rotated(-yaw)
	_check("R3a_%s_yaw_is_blue_near_side" % tag, is_equal_approx(yaw, PO.BATTLE_BLUE_NEAR_SIDE_YAW) and is_equal_approx(cam.rotation, yaw), "yaw=%.4f cam=%.4f" % [yaw, cam.rotation])
	_check("R3b_%s_blue_forward_is_screen_up" % tag, absf(up.angle_to(Vector2(0, -1))) < deg_to_rad(1.0), "screen dir=%s" % str(up))
	# R4 upright art: containers cancel the camera yaw and are never mirrored
	var bad_up: Array = []
	for u in ur.call("get_all_units"):
		var n: Node2D = ur.call("get_unit_node", str(u["id"]))
		if n == null:
			continue
		var net: float = _angle_diff(n.global_rotation, cam.rotation)
		if net > 0.01 or n.scale.x <= 0.0 or n.scale.y <= 0.0:
			bad_up.append("%s net_rot=%.3f scale=%s" % [u["id"], net, str(n.scale)])
		for c in n.get_children():
			if c is Sprite2D and ((c as Sprite2D).flip_v or (c as Sprite2D).scale.y < 0.0):
				bad_up.append("%s/%s upside-down" % [u["id"], c.name])
	var sr: Node = _shell.get("stronghold_renderer")
	for b in (sr.call("get_all_badges") as Dictionary).values():
		if b and _angle_diff((b as Node2D).global_rotation, cam.rotation) > 0.01:
			bad_up.append("badge %s rotated" % b.name)
	_check("R4_%s_upright_art_not_rotated_or_flipped" % tag, bad_up.is_empty(), str(bad_up.slice(0, 5)))
	# R5 one unit = one hex (and the visual node sits on its logical hex)
	var seen: Dictionary = {}
	var bad_hex: Array = []
	for u in um.get_all_units():
		var id: String = str(u["id"])
		var c := Vector2i(int(u["q"]), int(u["r"]))
		if seen.has(c):
			bad_hex.append("%s shares %s with %s" % [id, str(c), seen[c]])
		seen[c] = id
		var n2: Node2D = ur.call("get_unit_node", id)
		if n2 != null and n2.position.distance_to(HexUtilsCls.hex_to_pixel(c.x, c.y)) > 0.5:
			bad_hex.append("%s node off its hex" % id)
		if n2 != null:
			var fp: Polygon2D = n2.get_node_or_null("HexFootprint")
			if fp:
				# Inset inside its own hex (the polygon carries the 42/41.569
				# flat-to-flat correction, hence the 2 % tolerance).
				for p in fp.polygon:
					if p.length() > VisualContract.UNIT_FOOTPRINT_RADIUS * 1.02 or absf(p.y) >= VisualContract.HEX_FLAT_H * 0.5:
						bad_hex.append("%s footprint exceeds %s" % [id, VisualContract.UNIT_FOOTPRINT_RADIUS])
						break
	_check("R5_%s_one_unit_one_hex" % tag, bad_hex.is_empty(), str(bad_hex.slice(0, 5)))
	# R6 presentation never changes logical coordinates
	var mismatch: Array = []
	var rdata: Dictionary = {}
	for u in ur.call("get_all_units"):
		rdata[str(u["id"])] = Vector2i(int(u["q"]), int(u["r"]))
	for u in um.get_all_units():
		var id2: String = str(u["id"])
		if rdata.has(id2) and rdata[id2] != Vector2i(int(u["q"]), int(u["r"])):
			mismatch.append(id2)
	var rt_bad: int = 0
	for key in (hg.get("cell_data") as Dictionary).keys():
		var parts: PackedStringArray = str(key).split(",")
		var ax := Vector2i(int(parts[0]), int(parts[1]))
		if HexUtilsCls.world_to_axial(HexUtilsCls.hex_to_pixel(ax.x, ax.y)) != ax:
			rt_bad += 1
	_check("R6_%s_visual_transforms_do_not_leak" % tag, mismatch.is_empty() and rt_bad == 0 and PO.upright_rotation() == yaw, "renderer!=manager: %s, axial round-trip failures: %d" % [str(mismatch), rt_bad])
	# R7 performance budget: node count and per-frame processors
	var counts := {"total": 0, "processing": []}
	_walk(_shell, counts)
	var budget: int = 1600 if headless else 60000
	_check("R7a_%s_node_budget" % tag, int(counts["total"]) <= budget, "nodes=%d budget=%d" % [counts["total"], budget])
	_check("R7b_%s_per_frame_only_allowlisted" % tag, (counts["processing"] as Array).is_empty(), str((counts["processing"] as Array).slice(0, 5)))
	var bad_class: Array = []
	_find_forbidden(root, bad_class)
	_check("R7c_%s_no_lights_particles_physics" % tag, bad_class.is_empty(), str(bad_class.slice(0, 5)))

func _walk(n: Node, acc: Dictionary) -> void:
	acc["total"] = int(acc["total"]) + 1
	if n.is_processing() and n.get_script() != null:
		var path: String = (n.get_script() as Script).resource_path
		var is_visual: bool = path.find("/visual/") != -1 or VISUAL_FILES.has(path) or path.find("/step2r/step2r_unit") != -1 or path.find("step2r_outer") != -1
		if is_visual and not VisualContract.PER_FRAME_ALLOWLIST.has(path):
			(acc["processing"] as Array).append("%s (%s)" % [n.name, path])
	for c in n.get_children():
		_walk(c, acc)

func _find_forbidden(n: Node, out: Array) -> void:
	if VisualContract.FORBIDDEN_NODE_CLASSES.has(n.get_class()):
		out.append("%s:%s" % [n.get_path(), n.get_class()])
	for c in n.get_children():
		_find_forbidden(c, out)

## Stronghold specs (the one visual source) must agree with gameplay truth.
func _stronghold_spec_checks(tag: String = "") -> void:
	var specs: Array = _shell.call("stronghold_visual_specs")
	var um = _shell.get("unit_manager")
	var cells: Dictionary = _shell.get("hex_grid").get("cell_data")
	var bad: Array = []
	var gp_ids: Array = []
	for sh in um.get_all_strongholds():
		gp_ids.append(str(sh.structure_id))
	for sp in specs:
		var sh = um.get_stronghold_by_id(str(sp["id"]))
		if sh == null:
			bad.append("%s missing in gameplay" % sp["id"])
			continue
		if sh.get_anchor() != sp["anchor"]:
			bad.append("%s anchor %s != gameplay %s" % [sp["id"], str(sp["anchor"]), str(sh.get_anchor())])
		for c in sp["footprint"]:
			var cell = cells.get("%d,%d" % [c.x, c.y])
			if cell == null or int(cell.terrain) != int(sp["terrain"]):
				bad.append("%s footprint %s not stronghold terrain" % [sp["id"], str(c)])
	_check("R8_stronghold_specs_match_gameplay" + ("" if tag.is_empty() else "_" + tag), bad.is_empty() and specs.size() == gp_ids.size(), "%s | specs=%d gameplay=%d" % [str(bad), specs.size(), gp_ids.size()])

# ======================================================== windowed checks

const LAYER_MASK: int = 2 | 4

func _windowed_checks_closeup() -> void:
	var ctl: Node = _shell.get("_mode_controller")
	var v: Node = _shell.get_node_or_null("BattlefieldCloseupView")
	var proj: Node = _shell.get("_projection")
	var cam2d: Camera2D = _shell.get("camera")
	_check("W1_controller_and_views_exist", ctl != null and v != null and proj != null)
	if ctl == null or v == null or proj == null:
		return
	_check("W2_opens_in_closeup", PO.mode == PO.Mode.CLOSEUP and bool(v.call("is_active")), "mode=%d" % PO.mode)
	_check("W3_closeup_hides_2d_world_and_projection", (root.canvas_cull_mask & LAYER_MASK) == 0 and not (proj.get("_layer") as CanvasLayer).visible and (proj.get("_sub") as SubViewport).render_target_update_mode == SubViewport.UPDATE_DISABLED)
	var anchor: Callable = cam2d.get("anchor_provider")
	_check("W4_closeup_camera_anchored_on_hq", anchor.is_valid() and anchor.get_method() == &"_hq_anchor" and (v.get("cam") as Camera3D).is_current())
	var hq: Vector2 = _shell.call("_hq_world_pos")
	var sp: Vector2 = v.call("world_to_screen", hq)
	_check("W5_hq_framed_bottom_center_in_closeup", absf(sp.x - 960.0) < 960.0 * 0.15 and sp.y > 1080.0 * 0.55 and sp.y < 1080.0, "hq screen=%s" % str(sp))
	# 2.5D, never full 3D: unshaded cards, no 3D lights, flat colour background
	var lit: Array = []
	_collect_3d(v, lit)
	_check("W6_closeup_is_25d_cards_only", lit.is_empty(), str(lit.slice(0, 5)))
	# one stronghold = one hex in the closeup
	var specs: Array = _shell.call("stronghold_visual_specs")
	var bad: Array = []
	var max_w: float = VisualContract.CLOSEUP_STRONGHOLD_WIDTH_OF_HEX * VisualContract.CLOSEUP_HEXR * 1.7320508 + 0.01
	for s in specs:
		var mi: MeshInstance3D = v.get_node_or_null(str(s["id"]))
		if mi == null:
			bad.append("%s card missing" % s["id"])
			continue
		var w: float = (mi.mesh as QuadMesh).size.x
		var a: Vector2i = s["anchor"]
		var c3: Vector3 = v.call("hex3", a.x, a.y)
		if w > max_w or Vector2(mi.position.x - c3.x, mi.position.z - c3.z).length() > VisualContract.CLOSEUP_HEXR:
			bad.append("%s w=%.2f max=%.2f" % [s["id"], w, max_w])
	_check("W7_closeup_one_stronghold_card_per_hex", bad.is_empty(), str(bad))

func _collect_3d(n: Node, out: Array) -> void:
	if n is Light3D:
		out.append("light %s" % n.name)
	if n is GeometryInstance3D:
		var m: Material = (n as GeometryInstance3D).material_override
		if m != null and not (m is ShaderMaterial):
			out.append("non-shader material %s" % n.name)
		elif m is ShaderMaterial and (m as ShaderMaterial).shader != null and (m as ShaderMaterial).shader.code.find("unshaded") == -1:
			out.append("lit shader %s" % n.name)
	for c in n.get_children():
		_collect_3d(c, out)

func _windowed_checks_high() -> void:
	var v: Node = _shell.get_node_or_null("BattlefieldCloseupView")
	var proj: Node = _shell.get("_projection")
	var cam2d: Camera2D = _shell.get("camera")
	_check("W8a_high_mode_state", PO.mode == PO.Mode.HIGH and not bool(v.call("is_active")) and (proj.get("_layer") as CanvasLayer).visible and (proj.get("_sub") as SubViewport).render_target_update_mode == SubViewport.UPDATE_ALWAYS, "mode=%d" % PO.mode)
	_check("W8b_high_main_viewport_skips_hidden_world", (root.canvas_cull_mask & LAYER_MASK) == 0)
	var anchor: Callable = cam2d.get("anchor_provider")
	_check("W8c_high_camera_anchored_on_hq", anchor.is_valid() and anchor.get_method() == &"_hq_anchor_target")
	# one structure = one sprite = one hex on the HIGH board
	var comp: Node = _shell.get("hex_compositor")
	var sl: Node = comp.get("_struct_layer")
	var bad: Array = []
	for g in sl.get_children():
		var sprites: Array = []
		for c in g.get_children():
			if c is Sprite2D:
				sprites.append(c)
		if sprites.size() != 1:
			bad.append("%s has %d sprites" % [g.name, sprites.size()])
			continue
		var s2: Sprite2D = sprites[0]
		if not s2.has_meta("upright_base_y"):
			continue # ground-plane art (bridge deck)
		var drawn_w: float = float(s2.get_meta("content_width_world", 0.0)) * s2.scale.x / maxf(float(s2.get_meta("upright_base_x", s2.scale.x)), 1e-6)
		var fp: Array = g.get_meta("logical_footprint", [])
		var anchor_px: Vector2 = HexUtilsCls.hex_to_pixel(fp[0].x, fp[0].y) if not fp.is_empty() else s2.position
		if drawn_w > VisualContract.ONE_HEX_ART_MAX_WIDTH + 0.5 or s2.position.distance_to(anchor_px) > VisualContract.HEX_CIRCUMRADIUS:
			bad.append("%s drawn_w=%.1f dist=%.1f" % [g.name, drawn_w, s2.position.distance_to(anchor_px)])
	_check("W8d_high_one_structure_sprite_inside_one_hex", bad.is_empty(), str(bad.slice(0, 5)))
