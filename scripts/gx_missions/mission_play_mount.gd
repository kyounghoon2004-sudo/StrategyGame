extends Node

## Human play on the generated mission maps (2026-10-09): the player is BLUE (the shell's own controls), RED is the
## mission GX. MissionRules judges the match at the end of every round. Fog and morale off, as in the training games.
##   F1..F5  new random map of mission M1..M5        F8  replay this map
##   F6      RED GX tier (BASIC / INTER / ADV)        F7  RED GX style
##   B       BUILD_BASE with your HQ (or the button)
## Maps: artifacts/mission_maps/play/M<n>_s<seed>.json (tools/battlefields/gen_missions.py --batch 20).
## Launch: Godot --path <project> --script res://tools/play_missions.gd [-- M3]
## Tutorial maps (cfg source "tutorial", 2026-10-17): the 5 fixed maps of data/battlefields/tutorial_v1 played the
## same way (MissionRules judges instead of the shell's tutorial runtime; morale on). F1..F5 then pick tutorial M1..M5.
##   Godot --path <project> --script res://tools/play_missions.gd -- T3
## Supply: the yellow line runs from each HQ to its nearest logistics base (display only; supply needs >= 1 base).

const MissionRulesCls = preload("res://scripts/gx_missions/mission_rules.gd")
const MissionGxCls = preload("res://scripts/gx_missions/mission_gx_controller.gd")
const TerrainCls = preload("res://scripts/cloud_pipeline/commander_terrain.gd")

const META := "mission_play"
## Set on the Battle shell: MissionRules judges, the shell skips its tutorial runtime.
const META_RULES_DRIVEN := "mission_rules_driven"
const TITLE_SCENE := "res://scenes/title_screen.tscn"
const WorldBoundaryCls = preload("res://scripts/step2r/step2r_world_boundary.gd")
## Shell._is_click_over_hud treats Controls of CanvasLayers in this group as HUD (no map click under them).
const HUD_GROUP := "battle_hud_layer"
const HUD_POS := Vector2(352, 110)
const Step3ConfigCls = preload("res://scripts/core/step3_config.gd")
const SpecCls = preload("res://scripts/episodes/episode_spec.gd")
const EpisodeRuntimeCls = preload("res://scripts/episodes/episode_runtime.gd")
const WatchCls = preload("res://scripts/cloud_pipeline/watch_llm_vs_utility.gd")
## "sim" source: the collection games' board (watch_llm_vs_utility / tools/cmd_rl/teacher_gx: Step0 sandbox,
## HQ vs HQ 10v10, 60-turn cap) under MissionRules as a field battle with logistics bases and morale.
const SIM_FAMILIES := ["fixed", "mild", "broad", "counterfactual_valid"]
const SIM_MISSION_FAMILY := "M3"
const SIM_MISSION := {"mission_id": "SIM", "family": "M3", "round_limit": 60, "collapse_frac": 0.40, "morale": true}
const BUILD_CODES_KR := {"NOT_HQ": "HQ만 지을 수 있음", "HQ_MOVED_THIS_TURN": "이번 턴에 이미 이동함", "BASE_EXISTS": "이미 기지가 있음",
	"ACTION_ENDED": "행동 종료됨", "COOLDOWN": "쿨타임", "GARRISONED": "주둔 중", "UNIT_GONE": "부대 없음", "BATTLE_OVER": "전투 종료"}
const ROLE_KR := {"attacker": "공격측", "defender": "방어측", "none": "양측 동등"}
const OWNER_KR := {"none": "없음", "blue": "BLUE", "red": "RED"}
const MAP_DIR := "res://artifacts/mission_maps/play"
const SUPPLY_LINE_COLOR := Color(1.0, 0.84, 0.12, 0.95)
const SUPPLY_LINE_WIDTH := 5.0
const LINES3D_WIDTH := 4.0
const LINES3D_Y := 3.0
const BASE_COLORS := {"blue": Color(0.30, 0.60, 1.0, 1.0), "red": Color(1.0, 0.32, 0.28, 1.0)}
const TIERS := ["BASIC", "INTER", "ADV"]
const STYLES := ["BULWARK", "SPEARHEAD", "HARRIER", "OUTRIDER"]
const NAMES := {"M1": "마을 방어/공략", "M2": "성벽 요새", "M3": "야전 (군 붕괴)", "M4": "거점 점령", "M5": "공성 (성채)"}

var cfg := {}
var shell: Node
var rules: Node
var red: Node
var hud: Label
var hud_panel: PanelContainer = null
var _hud_close_btn: Button = null
var _hud_tab_btn: Button = null
var last_round := 0
var result_text := ""
var _keys := {}
var supply_overlay: SupplyOverlay = null
var _hud_layer: CanvasLayer = null
var _result_panel: PanelContainer = null


## World-space map overlay on the Battle shell (same hex_to_pixel space as the envelope renderer): the supply
## links of the side being inspected (coloured / thinned by distance), a ring on every base hex (orange when
## damaged), the head bases; the mission objective hexes (M1 village, M4 sites); BLUE's morale zone borders.
class SupplyOverlay extends Node2D:
	const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")
	const DIRS: Array[Vector2i] = [Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1),
		Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1)]
	const CORNERS: Array[Vector2] = [Vector2(24, 0), Vector2(12, 21), Vector2(-12, 21),
		Vector2(-24, 0), Vector2(-12, -21), Vector2(12, -21)]
	var lines: Array = []            # [{path: [[q, r]...], ratio: len / range, live}] (shown side only)
	var heads: Dictionary = {}       # side -> [q, r]
	var offset_fn: Callable          # (path, offset) -> PackedVector2Array (set by the mount)
	var bases: Array = []            # [{owner, hex: [q, r]}]
	var objectives: Array = []       # [{hex: [q, r], owner}] owner "none" | "blue" | "red"
	var zone_center := Vector2i.ZERO
	var playable: Callable = func(_h: Vector2i) -> bool: return true  # ring edges only between playable hexes
	var zone_radii: Array = []       # [near_max, mid_max]; empty = no rings
	var line_color := Color.YELLOW
	var line_width := 4.0
	var base_colors := {}
	var objective_color := Color(1.0, 0.95, 0.6, 0.9)
	var zone_colors: Array = [Color(0.45, 0.95, 0.55, 0.85), Color(1.0, 0.45, 0.35, 0.85)]
	var _sig := ""

	func set_state(new_lines: Array, new_bases: Array, new_objectives: Array, center: Vector2i, radii: Array, new_heads: Dictionary = {}) -> void:
		var sig := JSON.stringify([new_lines, new_bases, new_objectives, [center.x, center.y], radii, new_heads])
		if sig == _sig:
			return
		_sig = sig
		lines = new_lines
		bases = new_bases
		objectives = new_objectives
		heads = new_heads
		zone_center = center
		zone_radii = radii
		queue_redraw()

	static func _dist(a: Vector2i, b: Vector2i) -> int:
		var d := a - b
		return (absi(d.x) + absi(d.y) + absi(d.x + d.y)) / 2

	## Outline of the hex disk of radius `rad` around `c`: every edge between a hex inside and one outside.
	func _draw_disk_border(c: Vector2i, rad: int, col: Color) -> void:
		for dq in range(-rad, rad + 1):
			for dr in range(maxi(-rad, -dq - rad), mini(rad, -dq + rad) + 1):
				var h := c + Vector2i(dq, dr)
				if not bool(playable.call(h)):
					continue
				var hp := HexUtilsCls.hex_to_pixel(h.x, h.y)
				for d in DIRS:
					var n: Vector2i = h + d
					if _dist(n, c) <= rad or not bool(playable.call(n)):
						continue
					var v := HexUtilsCls.hex_to_pixel(n.x, n.y) - hp
					var best: Array = CORNERS.duplicate()
					best.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.dot(v) > b.dot(v))
					draw_line(hp + best[0], hp + best[1], col, 2.5, true)

	func _draw() -> void:
		for i in range(mini(zone_radii.size(), zone_colors.size())):
			_draw_disk_border(zone_center, int(zone_radii[i]), zone_colors[i])
		for o in objectives:
			var oc := HexUtilsCls.hex_to_pixel(int(o["hex"][0]), int(o["hex"][1]))
			var poly := PackedVector2Array()
			for k in CORNERS:
				poly.append(oc + k * 0.92)
			poly.append(poly[0])
			var owner := str(o.get("owner", "none"))
			if owner != "none":
				draw_colored_polygon(poly, Color(base_colors.get(owner, Color.WHITE), 0.28))
			draw_polyline(poly, objective_color, 3.0, true)
		for l in lines:
			var pts: PackedVector2Array = offset_fn.call(l["path"], float(l.get("offset", 0.0)))
			if pts.size() >= 2:
				var w: float = line_width * link_width_scale(float(l["ratio"]), bool(l["live"]))
				draw_polyline(pts, Color(0.08, 0.06, 0.02, 0.75), w + 4.0, true)
				draw_polyline(pts, link_color(float(l["ratio"]), bool(l["live"])), w, true)
		for b in bases:
			var c := HexUtilsCls.hex_to_pixel(int(b["hex"][0]), int(b["hex"][1]))
			var col: Color = base_colors.get(str(b["owner"]), Color.WHITE)
			var damaged := int(b.get("hits_left", 2)) <= 1
			draw_circle(c, 13.0, Color(col, 0.55))
			draw_arc(c, 15.0, 0.0, TAU, 28, Color(0.08, 0.06, 0.02, 0.75), 6.0, true)
			draw_arc(c, 15.0, 0.0, TAU, 28, Color(1.0, 0.42, 0.1) if damaged else line_color, 3.0, true)
		for s in heads.keys():
			var hc := HexUtilsCls.hex_to_pixel(int(heads[s][0]), int(heads[s][1]))
			var hcol: Color = base_colors.get(str(s), Color.WHITE)
			draw_circle(hc, 15.0, Color(hcol, 0.7))
			draw_arc(hc, 17.0, 0.0, TAU, 28, Color(0.08, 0.06, 0.02, 0.85), 6.0, true)
			draw_arc(hc, 17.0, 0.0, TAU, 28, line_color, 3.0, true)

	## Link colour by distance share of the link range: yellow up to half, orange, red at the limit; grey = not
	## linked to the head.
	static func link_color(ratio: float, live: bool) -> Color:
		if not live:
			return Color(0.62, 0.62, 0.6, 0.85)
		var y := Color(1.0, 0.84, 0.12, 0.95)
		var o := Color(1.0, 0.55, 0.10, 0.95)
		var r := Color(0.95, 0.18, 0.14, 0.95)
		if ratio <= 0.5:
			return y
		if ratio <= 0.8:
			return y.lerp(o, (ratio - 0.5) / 0.3)
		return o.lerp(r, clampf((ratio - 0.8) / 0.2, 0.0, 1.0))

	## Width multiplier: thick when close, thin near the range limit.
	static func link_width_scale(ratio: float, live: bool) -> float:
		return 0.55 if not live else lerpf(1.3, 0.4, clampf(ratio, 0.0, 1.0))


static func pick(family: String, prev: Dictionary = {}) -> Dictionary:
	var c := prev.duplicate()
	c["family"] = family
	if str(c.get("source", "")) == "tutorial":
		c["seed"] = 0
		c["map"] = family
	elif str(c.get("source", "")) == "sim":
		# The collection games' board: Step0 flat sandbox, HQ vs HQ 10v10, EpisodeSpec rules of (sim_family, seed).
		c["family"] = SIM_MISSION_FAMILY
		if not c.has("sim_family") or not str(c["sim_family"]) in SIM_FAMILIES:
			c["sim_family"] = "fixed"
		c["seed"] = randi_range(1, 999999)
		c["map"] = "STEP0_SANDBOX"
	else:
		c["seed"] = randi_range(1, 20)
		c["map"] = ProjectSettings.globalize_path("%s/%s_s%d.json" % [MAP_DIR, family, int(c["seed"])])
	if not c.has("tier"):
		c["tier"] = "INTER"
	if not c.has("style"):
		c["style"] = "BULWARK"
	return c


func _enter_tree() -> void:
	randomize()
	cfg = get_tree().root.get_meta(META, {})
	if cfg.is_empty():
		cfg = pick("M3")
		get_tree().root.set_meta(META, cfg)
	var battle := get_parent().get_node_or_null("Battle")
	if _is_sim():
		# Same rule overlay the collection games install (watch_llm_vs_utility.start_match), before the shell's _ready.
		var fixed := str(cfg["sim_family"]) == "fixed"
		var spec := SpecCls.sample("mild" if fixed else str(cfg["sim_family"]), "train", int(cfg["seed"]))
		EpisodeRuntimeCls.install(WatchCls.sandbox_overlay(spec, fixed), "")
		battle.set("is_step0_sandbox", true)
	else:
		battle.set("is_step0_sandbox", false)
		battle.set("battlefield_id", str(cfg["map"]) if _is_tutorial() else "@" + str(cfg["map"]))
	# MissionRules (below) is the only judge: the shell must not run its own tutorial runtime too.
	battle.set_meta(META_RULES_DRIVEN, true)
	# 3D unit overhead UI: the morale gauge only when the mission has morale on.
	battle.set_meta("unit_ui_morale", bool(_mission_morale_hint()))
	battle.set("no_fog", true)
	if OS.get_environment("MP_FLAT") != "":
		battle.set("present_perspective", false)


func _exit_tree() -> void:
	if _is_sim():
		EpisodeRuntimeCls.clear()


func _ready() -> void:
	_build_hud()
	call_deferred("_boot")


func _boot() -> void:
	shell = get_parent().get_node_or_null("Battle")
	var det: Node = null
	for _i in range(900):
		det = shell.get_node_or_null("Step7Integration") if shell != null else null
		if det != null and bool(det.get("ready_for_step7")):
			break
		await get_tree().process_frame
	if det == null or not bool(det.get("ready_for_step7")):
		_fail("shell not ready")
		return
	var bf: Dictionary = shell.get("_battlefield")
	if _is_sim():
		bf = {"mission": SIM_MISSION.duplicate(true)}
	if bf.is_empty() or not bf.has("mission"):
		_fail("map failed to load: " + str(cfg["map"]))
		return
	rules = MissionRulesCls.new()
	rules.name = "MissionRules"
	add_child(rules)
	var ms: Dictionary = rules.call("setup", shell, bf["mission"])
	if not bool(ms.get("ok", false)):
		_fail("MissionRules: " + str(ms.get("error", "?")))
		return
	rules.connect("outcome_decided", _on_outcome)
	# HQ action-row button (shell): legality and execution stay with MissionRules.
	shell.set_meta("build_base_check", _build_check)
	shell.set_meta("build_base_action", _build_base_for)
	red = MissionGxCls.new()
	red.name = "MissionGxRed"
	red.set("auto_mount", false)
	red.set("side", "red")
	red.set("mission_rules", rules)
	red.set("dev_difficulty", "GX_%s_%s" % [cfg["tier"], cfg["style"]])
	add_child(red)
	var rb: Dictionary = red.call("bind_live", shell, det, true)
	if not bool(rb.get("ok", false)):
		_fail("RED GX: " + str(rb.get("error", "?")))
		return
	last_round = int((shell.get("unit_manager") as RefCounted).call("get_current_turn"))
	supply_overlay = SupplyOverlay.new()
	supply_overlay.name = "SupplyLineOverlay"
	supply_overlay.z_index = 9  # above the envelope renderer (8), below units (10)
	supply_overlay.line_color = SUPPLY_LINE_COLOR
	supply_overlay.line_width = SUPPLY_LINE_WIDTH
	supply_overlay.base_colors = BASE_COLORS
	supply_overlay.offset_fn = _offset_points
	supply_overlay.playable = func(h: Vector2i) -> bool: return bool(shell.call("is_playable_hex", h))
	shell.add_child(supply_overlay)
	print("[MissionPlay] %s %s vs GX_%s_%s" % [cfg["family"], _source_label(), cfg["tier"], cfg["style"]])


var _lines3d: MeshInstance3D = null
var _lines3d_sig := ""


## The 3D board (tiles are 3D assets) hides thin 2D drapes under the tile meshes, so the supply network is also built as
## flat ribbons in the 3D scene (dark outline + yellow core, always on top). Hidden with the 3D view in the HIGH view.
func _update_lines3d(sup_lines: Array) -> void:
	var v3: Node = shell.get("_view3d") as Node
	if v3 == null or not (v3 is Node3D):
		return
	var sig := JSON.stringify(sup_lines)
	if _lines3d != null and sig == _lines3d_sig:
		return
	_lines3d_sig = sig
	if _lines3d == null:
		_lines3d = MeshInstance3D.new()
		_lines3d.name = "SupplyLines3D"
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.vertex_color_use_as_albedo = true
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.no_depth_test = true
		mat.render_priority = 100
		_lines3d.material_override = mat
		_lines3d.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		v3.add_child(_lines3d)
	var k3: float = float((v3.call("to3", Vector2(1.0, 0.0)) as Vector3).x)  # closeup units per world px
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var any := false
	for l in sup_lines:
		var pts: Array[Vector3] = []
		for w in _offset_points(l["path"], float(l.get("offset", 0.0))):
			pts.append(v3.call("to3", w) + Vector3(0.0, LINES3D_Y * k3, 0.0))
		var ratio := float(l["ratio"])
		var live := bool(l["live"])
		var wd: float = LINES3D_WIDTH * SupplyOverlay.link_width_scale(ratio, live) * k3
		var col: Color = SupplyOverlay.link_color(ratio, live)
		col.a = 1.0
		for k in range(pts.size() - 1):
			any = true
			_add_ribbon(st, pts[k], pts[k + 1], wd + 3.0 * k3, Color(0.08, 0.06, 0.02, 0.9), 0.0)
			_add_ribbon(st, pts[k], pts[k + 1], wd, col, 0.02 * k3)
	_lines3d.mesh = st.commit() if any else null


static func _add_ribbon(st: SurfaceTool, a: Vector3, b: Vector3, width: float, col: Color, lift: float) -> void:
	var d := b - a
	d.y = 0.0
	if d.length() < 0.001:
		return
	var side := Vector3(-d.z, 0.0, d.x).normalized() * (width * 0.5)
	var up := Vector3(0.0, lift, 0.0)
	var ext := d.normalized() * (width * 0.5)  # round-ish joins: overshoot each end by half the width
	var p0 := a - ext + up
	var p1 := b + ext + up
	st.set_color(col)
	for v in [p0 - side, p0 + side, p1 + side, p0 - side, p1 + side, p1 - side]:
		st.add_vertex(v)


var _village_tokens: Array = []  # Sprite3D per village hex
var _village_tex_cache := {}
var _village_tint3d: MeshInstance3D = null
var _village_tint_sig := ""
const VILLAGE_EMPTY_COLOR := Color(0.55, 0.55, 0.5, 1.0)
const VILLAGE_TOKEN_COLORS := {"none": Color(0.10, 0.30, 0.20), "blue": Color(0.12, 0.30, 0.72), "red": Color(0.66, 0.14, 0.12)}
const VILLAGE_TOKEN_RIMS := {"none": Color(0.55, 0.85, 0.55), "blue": Color(0.62, 0.80, 1.0), "red": Color(1.0, 0.65, 0.55)}
const VILLAGE_TOKEN_PX := 64
const HEX_CORNERS: Array = [Vector2(24, 0), Vector2(12, 21), Vector2(-12, 21), Vector2(-24, 0), Vector2(-12, -21), Vector2(12, -21)]


## Who stands on each village hex: [{hex: [q, r], owner: "blue"|"red"|"none", soldiers}] (field units only).
func _village_occupants(hexes: Array) -> Array:
	var at := {}
	for u in (shell.get("unit_manager") as RefCounted).call("get_all_units"):
		if bool(u.get("garrisoned", false)) or int(u.get("soldier_count", 0)) <= 0:
			continue
		at[Vector2i(int(u["q"]), int(u["r"]))] = u
	var out: Array = []
	for h in hexes:
		var u: Dictionary = at.get(Vector2i(int(h[0]), int(h[1])), {})
		out.append({"hex": [int(h[0]), int(h[1])], "owner": str(u.get("faction", "none")) if not u.is_empty() else "none",
			"soldiers": int(u.get("soldier_count", 0))})
	return out


static func _hex_world(h: Array) -> Vector2:
	return Vector2(36.0 * float(h[0]), 42.0 * float(h[1]) + 21.0 * float(h[0]))


## Village UI (M1), Civ-style tile icons: every village hex carries its own village icon (house) in the colour
## of the side standing on it (green = nobody). With a unit on the hex the icons cluster like a Civ tile stack:
## the village icon at the top centre, the unit's badge and morale gauge splitting below it to the left and
## right (the unit side reads shell meta "ui_cluster_hexes"). The hexes are tinted in the same colours.
func _update_village_banner(st: Dictionary) -> void:
	if not st.has("village"):
		return
	var hexes: Array = (st["village"] as Dictionary).get("hexes", [])
	var v3: Node = shell.get("_view3d") as Node
	if hexes.is_empty() or v3 == null or not (v3 is Node3D):
		return
	if not shell.has_meta("ui_cluster_hexes"):
		var set := {}
		for h in hexes:
			set[Vector2i(int(h[0]), int(h[1]))] = true
		shell.set_meta("ui_cluster_hexes", set)
	var occ := _village_occupants(hexes)
	_update_village_tint3d(occ, v3)
	var k3: float = float((v3.call("to3", Vector2(1.0, 0.0)) as Vector3).x)  # closeup units per world px
	var w_in: float = 21.0 * k3  # hex inradius
	var fwd: Vector3 = v3.get("fwd")
	while _village_tokens.size() < occ.size():
		var sp := Sprite3D.new()
		sp.name = "VillageToken%d" % _village_tokens.size()
		sp.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		sp.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		sp.no_depth_test = true
		sp.render_priority = 126
		sp.pixel_size = 1.0 * w_in / float(VILLAGE_TOKEN_PX)
		v3.add_child(sp)
		_village_tokens.append(sp)
	for i in range(occ.size()):
		var o: Dictionary = occ[i]
		var sp: Sprite3D = _village_tokens[i]
		sp.texture = _village_token_tex(str(o["owner"]))
		var c3: Vector3 = v3.call("to3", _hex_world(o["hex"])) + Vector3.UP * 0.6
		# Alone: centred in the badge slot. With a unit: the top of the cluster, above the split badge / morale.
		sp.position = c3 + fwd * ((0.10 if o["owner"] == "none" else 0.48) * w_in)


## Signed distance helpers for the icon (pixels, y down).
static func _sd_box_corners(p: Vector2, half: float, radii: Vector4) -> float:
	# radii: (x>0,y>0), (x>0,y<0), (x<0,y>0), (x<0,y<0)
	var r: float = (radii.x if p.y > 0.0 else radii.y) if p.x > 0.0 else (radii.z if p.y > 0.0 else radii.w)
	var q := Vector2(absf(p.x), absf(p.y)) - Vector2(half - r, half - r)
	return Vector2(maxf(q.x, 0.0), maxf(q.y, 0.0)).length() + minf(maxf(q.x, q.y), 0.0) - r


static func _sd_tri(p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> float:
	# negative inside (convex, any winding)
	var d := -INF
	var s: float = signf((b - a).cross(c - a))
	for e in [[a, b], [b, c], [c, a]]:
		var n: Vector2 = (e[1] - e[0]).orthogonal().normalized() * -s
		d = maxf(d, (p - e[0]).dot(n))
	return d


static func _sd_rect(p: Vector2, lo: Vector2, hi: Vector2) -> float:
	var c := (lo + hi) * 0.5
	var h := (hi - lo) * 0.5
	var q := Vector2(absf(p.x - c.x), absf(p.y - c.y)) - h
	return Vector2(maxf(q.x, 0.0), maxf(q.y, 0.0)).length() + minf(maxf(q.x, q.y), 0.0)


## 64x64 Civ-style tile icon, antialiased: a rounded diamond (square turned 45 deg) whose top corner is a point,
## dark outline + light rim + owner-coloured face, and a house emblem (pitched roof with eaves, chimney, walls,
## door, window).
func _village_token_tex(owner: String) -> Texture2D:
	return _token_tex(owner, "house")


func _token_tex(owner: String, emblem_kind: String) -> Texture2D:
	var cache_key := owner + "|" + emblem_kind
	if _village_tex_cache.has(cache_key):
		return _village_tex_cache[cache_key]
	var n := VILLAGE_TOKEN_PX
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var face: Color = VILLAGE_TOKEN_COLORS.get(owner, VILLAGE_TOKEN_COLORS["none"])
	var rim: Color = VILLAGE_TOKEN_RIMS.get(owner, VILLAGE_TOKEN_RIMS["none"])
	var ink := Color(0.03, 0.04, 0.05, 1.0)
	var emblem := Color(0.97, 0.94, 0.84, 1.0)
	var ss := 4  # supersamples per axis
	var ctr := Vector2(n * 0.5, n * 0.54)
	var half := 21.5
	var radii := Vector4(9.0, 9.0, 9.0, 0.0)  # sharp corner -> the top point after the 45 deg turn
	for y in range(n):
		for x in range(n):
			var acc := Color(0, 0, 0, 0)
			for sy in range(ss):
				for sx in range(ss):
					var p := Vector2(x + (sx + 0.5) / ss, y + (sy + 0.5) / ss)
					var d := p - ctr
					# turn 45 deg so the sharp (-,-) corner points straight up
					var u := Vector2((d.x + d.y) * 0.70710678, (d.y - d.x) * 0.70710678)
					var sd := _sd_box_corners(u, half, radii)
					var col := Color(0, 0, 0, 0)
					if sd <= 0.0:
						col = ink
						if sd <= -2.0:
							col = rim
						if sd <= -4.5:
							var shade := 1.0 - 0.22 * clampf((p.y - 8.0) / 50.0, 0.0, 1.0)
							col = Color(face.r * shade + 0.04, face.g * shade + 0.04, face.b * shade + 0.04, 1.0)
							if emblem_kind == "crate":
								# supply crate: box with a lid line and cross straps
								var box := _sd_rect(p, Vector2(20, 22), Vector2(44, 46))
								var lid := absf(p.y - 27.0) - 1.0
								var d1 := absf((p.x - 20.0) - (p.y - 27.0) * 24.0 / 19.0) / 1.6 - 1.2
								var d2 := absf((44.0 - p.x) - (p.y - 27.0) * 24.0 / 19.0) / 1.6 - 1.2
								if box <= 0.0:
									col = emblem
									if (lid <= 0.0 or (p.y > 27.0 and (d1 <= 0.0 or d2 <= 0.0))) and box <= -0.5:
										col = face.darkened(0.25)
							else:
								# house emblem (centred a little low in the face)
								var roof := _sd_tri(p, Vector2(32, 17), Vector2(17, 31), Vector2(47, 31))
								var chimney := _sd_rect(p, Vector2(39, 20), Vector2(43, 28))
								var walls := _sd_rect(p, Vector2(21, 30), Vector2(43, 45))
								var door := _sd_rect(p, Vector2(29.5, 36), Vector2(34.5, 45))
								var window := _sd_rect(p, Vector2(36.5, 33.5), Vector2(40.5, 37.5))
								var house := minf(minf(roof, chimney), walls)
								if house <= 0.0 and door > 0.0 and window > 0.0:
									col = emblem
								elif house <= 0.0:
									col = face.darkened(0.35)
					acc += col
			acc /= float(ss * ss)
			if acc.a > 0.0:
				acc = Color(acc.r / acc.a, acc.g / acc.a, acc.b / acc.a, acc.a)
			img.set_pixel(x, y, acc)
	img.generate_mipmaps()
	var t := ImageTexture.create_from_image(img)
	_village_tex_cache[cache_key] = t
	return t


## Village hexes tinted on the 3D board in the colour of whoever stands there (grey outline when empty).
func _update_village_tint3d(occ: Array, v3: Node) -> void:
	if v3 == null or not (v3 is Node3D):
		return
	var sig := JSON.stringify(occ.map(func(o): return [o["hex"], o["owner"]]))
	if _village_tint3d != null and sig == _village_tint_sig:
		return
	_village_tint_sig = sig
	if _village_tint3d == null:
		_village_tint3d = MeshInstance3D.new()
		_village_tint3d.name = "VillageTint3D"
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.vertex_color_use_as_albedo = true
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.no_depth_test = true
		mat.render_priority = 10
		_village_tint3d.material_override = mat
		_village_tint3d.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		v3.add_child(_village_tint3d)
	var k3: float = float((v3.call("to3", Vector2(1.0, 0.0)) as Vector3).x)
	var up := Vector3(0.0, 0.4 * k3, 0.0)
	var stl := SurfaceTool.new()
	stl.begin(Mesh.PRIMITIVE_TRIANGLES)
	for o in occ:
		var hc := _hex_world(o["hex"])
		var col: Color = BASE_COLORS.get(o["owner"], VILLAGE_EMPTY_COLOR)
		var c3: Vector3 = v3.call("to3", hc) + up
		for i in range(6):
			var a: Vector3 = v3.call("to3", hc + HEX_CORNERS[i] * 0.97) + up
			var bb: Vector3 = v3.call("to3", hc + HEX_CORNERS[(i + 1) % 6] * 0.97) + up
			if o["owner"] != "none":
				stl.set_color(Color(col, 0.30))
				for p in [c3, a, bb]:
					stl.add_vertex(p)
			var ai: Vector3 = v3.call("to3", hc + HEX_CORNERS[i] * 0.84) + up
			var bi: Vector3 = v3.call("to3", hc + HEX_CORNERS[(i + 1) % 6] * 0.84) + up
			stl.set_color(Color(col, 0.9))
			for p in [ai, a, bb, ai, bb, bi]:
				stl.add_vertex(p)
	_village_tint3d.mesh = stl.commit()


const LINK_OFFSET_STEP := 5.0  # world px between parallel links sharing hexes


## Links that share a hex step get distinct sideways slots so every one stays visible.
static func _assign_link_offsets(links: Array) -> void:
	var used := {}  # undirected hex step -> slots taken
	for l in links:
		var steps: Array = []
		var p: Array = l["path"]
		for i in range(p.size() - 1):
			var a := "%d,%d" % [int(p[i][0]), int(p[i][1])]
			var c := "%d,%d" % [int(p[i + 1][0]), int(p[i + 1][1])]
			steps.append(a + "|" + c if a < c else c + "|" + a)
		var slot := 0
		while true:
			var free := true
			for s in steps:
				if (used.get(s, []) as Array).has(slot):
					free = false
					break
			if free:
				break
			slot = -slot if slot > 0 else -slot + 1  # 0, 1, -1, 2, -2, ...
		for s in steps:
			if not used.has(s):
				used[s] = []
			used[s].append(slot)
		l["offset"] = float(slot) * LINK_OFFSET_STEP


## Hex path -> world points shifted sideways by `offset` (vertex normals averaged over adjacent steps).
static func _offset_points(path: Array, offset: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for h in path:
		pts.append(Vector2(36.0 * int(h[0]), 42.0 * int(h[1]) + 21.0 * int(h[0])))
	if is_zero_approx(offset) or pts.size() < 2:
		return pts
	var out := PackedVector2Array()
	for i in range(pts.size()):
		var n := Vector2.ZERO
		if i > 0:
			n += (pts[i] - pts[i - 1]).orthogonal().normalized()
		if i < pts.size() - 1:
			n += (pts[i + 1] - pts[i]).orthogonal().normalized()
		out.append(pts[i] + n.normalized() * offset)
	return out


var _net_focus_side := ""
var _lmb_was_down := false
var _head_tokens := {}  # side -> Sprite3D


## Which side's supply network is drawn: the side of the selected HQ, else the side whose base / head was
## clicked last ("" = none: the lines stay hidden so the board stays readable).
func _net_shown_side() -> String:
	var mgr: RefCounted = shell.get("unit_manager")
	if mgr != null and bool(mgr.call("is_unit_selected")):
		var u: Dictionary = mgr.call("get_selected_unit")
		if str(u.get("class", "")) == "hq":
			return str(u.get("faction", ""))
	return _net_focus_side


## Left-click watcher (polled, so it sees clicks the shell consumes): a click on a base hex or a head base
## shows that side's network; any other board click clears it.
func _poll_net_click() -> void:
	var down := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	if _lmb_was_down and not down and rules != null:
		var mp := get_viewport().get_mouse_position()
		if not bool(shell.call("_is_click_over_hud", mp)):
			var w: Vector2 = shell.call("_pointer_world", mp)
			var hex: Vector2i = WorldBoundaryCls.world_to_axial(w)
			var b: Dictionary = rules.call("base_at", hex)
			_net_focus_side = ""
			if not b.is_empty():
				_net_focus_side = str(b["owner"])
			else:
				var hs: Dictionary = rules.get("heads")
				for s in hs.keys():
					if hs[s] == hex:
						_net_focus_side = str(s)
	_lmb_was_down = down


## Head bases on the 3D board: a supply-crate icon in the side's colour, always shown.
func _update_head_tokens(hs: Dictionary) -> void:
	var v3: Node = shell.get("_view3d") as Node
	if v3 == null or not (v3 is Node3D):
		return
	var k3: float = float((v3.call("to3", Vector2(1.0, 0.0)) as Vector3).x)
	for s in hs.keys():
		if not _head_tokens.has(s):
			var sp := Sprite3D.new()
			sp.name = "HeadBase_%s" % s
			sp.texture = _token_tex(str(s), "crate")
			sp.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
			sp.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			sp.no_depth_test = true
			sp.render_priority = 126
			sp.pixel_size = 1.15 * 21.0 * k3 / float(VILLAGE_TOKEN_PX)
			v3.add_child(sp)
			_head_tokens[s] = sp
		var h: Array = hs[s]
		(_head_tokens[s] as Sprite3D).position = v3.call("to3", _hex_world(h)) + Vector3.UP * 0.6


## BUILD_BASE check for the HQ action button: the rules' answer plus a Korean reason / cooldown count.
func _build_check(uid: String) -> Dictionary:
	var chk: Dictionary = rules.call("can_build_base", uid)
	var code := str(chk.get("code", ""))
	chk["text"] = ("쿨타임 %d턴" % int(chk.get("turns_left", 0))) if code == "COOLDOWN" else BUILD_CODES_KR.get(code, code)
	return chk


## Before the mission dict exists (shell setup): every mission played here has morale on.
func _mission_morale_hint() -> bool:
	return true


func _is_tutorial() -> bool:
	return str(cfg.get("source", "")) == "tutorial"


func _is_sim() -> bool:
	return str(cfg.get("source", "")) == "sim"


func _source_label() -> String:
	if _is_tutorial():
		return "튜토리얼"
	if _is_sim():
		return "시뮬레이션 맵 %s seed %d" % [str(cfg.get("sim_family", "")), int(cfg.get("seed", 0))]
	return "seed %s" % str(cfg.get("seed", "?"))


func _process(_d: float) -> void:
	for k in [KEY_F1, KEY_F2, KEY_F3, KEY_F4, KEY_F5]:
		if _pressed(k):
			if _is_sim():
				if k - KEY_F1 < SIM_FAMILIES.size():
					var c2 := cfg.duplicate()
					c2["sim_family"] = SIM_FAMILIES[k - KEY_F1]
					_restart(pick(SIM_MISSION_FAMILY, c2))
			else:
				_restart(pick("M%d" % (k - KEY_F1 + 1), cfg))
			return
	if _pressed(KEY_F8):
		_restart(cfg)
		return
	if _pressed(KEY_F6):
		cfg["tier"] = TIERS[(TIERS.find(cfg["tier"]) + 1) % TIERS.size()]
		_restart(cfg)
		return
	if _pressed(KEY_F7):
		cfg["style"] = STYLES[(STYLES.find(cfg["style"]) + 1) % STYLES.size()]
		_restart(cfg)
		return
	if _pressed(KEY_B):
		_build_base()
	if shell != null:
		_poll_net_click()
	if rules == null or shell == null:
		return
	# End of round = the turn counter moved on and BLUE's phase is open again: judge the completed round.
	var cur := int((shell.get("unit_manager") as RefCounted).call("get_current_turn"))
	if cur > last_round and int(shell.get("_turn_phase")) == 0 and (rules.get("outcome") as Dictionary).is_empty():
		for r in range(last_round, cur):
			rules.call("evaluate_round", r)
			if not (rules.get("outcome") as Dictionary).is_empty():
				break
		last_round = cur
	_refresh()


func _restart(c: Dictionary) -> void:
	get_tree().root.set_meta(META, c)
	get_tree().reload_current_scene()


func _pressed(k: Key) -> bool:
	var down := Input.is_key_pressed(k)
	var was: bool = _keys.get(k, false)
	_keys[k] = down
	return down and not was


func _blue_hq() -> String:
	var hq: Dictionary = rules.call("hq_of", "blue") if rules != null else {}
	return str(hq.get("unit_id", hq.get("id", "")))


func _build_base() -> void:
	if rules != null:
		_build_base_for(_blue_hq())


## BUILD_BASE for one of BLUE's units (the HQ action button and the B key); MissionRules decides legality.
func _build_base_for(uid: String) -> Dictionary:
	if rules == null:
		return {"success": false, "code": "NO_RULES"}
	var res: Dictionary = rules.call("build_base", uid)
	var msg: String = ("병참기지 건설: %s" % str(res.get("hex", ""))) if bool(res.get("success", false)) else ("병참기지 건설 불가: " + BUILD_CODES_KR.get(str(res.get("code", "")), str(res.get("code", ""))))
	if shell.has_method("_show_combat_log"):
		shell.call("_show_combat_log", "[%s] %s" % [uid, msg])
	print("[MissionPlay] " + msg)
	return res


func _on_outcome(o: Dictionary) -> void:
	var w := str(o.get("winner", "none"))
	result_text = ("승리" if w == "blue" else ("패배" if w == "red" else "무승부")) + " — %s (라운드 %s)" % [
		_reason_text(o), str(o.get("round", ""))]
	var nb := shell.get("next_turn_button") as Button
	if nb != null:
		nb.disabled = true
	# The shell's own end panel only knows "HQ destroyed"; MissionRules' result panel replaces it.
	var shell_panel: Variant = shell.get("_battle_panel")
	if shell_panel is Control:
		(shell_panel as Control).visible = false
	if shell.has_method("_show_combat_log"):
		shell.call("_show_combat_log", result_text)
	_show_result_panel(w)


func _fail(msg: String) -> void:
	push_error("[MissionPlay] " + msg)
	result_text = "ERROR: " + msg


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 50
	# The shell takes left clicks as map clicks in _input unless they land on its HUD; this group marks our layer as HUD.
	layer.add_to_group(HUD_GROUP)
	add_child(layer)
	_hud_layer = layer
	var panel := PanelContainer.new()
	panel.position = HUD_POS  # right of the left command dock, below the top bar: covers no other panel's X
	panel.custom_minimum_size = Vector2(430, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.06, 0.09, 0.82)
	sb.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", sb)
	hud_panel = panel
	layer.add_child(panel)
	var box := VBoxContainer.new()
	panel.add_child(box)
	var head := HBoxContainer.new()
	box.add_child(head)
	var head_lbl := Label.new()
	head_lbl.text = "임무 정보"
	head_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head_lbl.add_theme_font_size_override("font_size", 14)
	head_lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.35))
	head.add_child(head_lbl)
	hud = Label.new()
	hud.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hud.custom_minimum_size = Vector2(410, 0)
	hud.add_theme_font_size_override("font_size", 13)
	box.add_child(hud)
	_hud_close_btn = Button.new()
	_hud_close_btn.name = "MissionHudCloseBtn"
	_hud_close_btn.text = "X"
	_hud_close_btn.focus_mode = Control.FOCUS_NONE
	_hud_close_btn.tooltip_text = "임무 설명 닫기"
	_hud_close_btn.custom_minimum_size = Vector2(28, 26)
	_hud_close_btn.pressed.connect(_on_hud_close)
	head.add_child(_hud_close_btn)
	_hud_tab_btn = Button.new()
	_hud_tab_btn.name = "MissionHudTabBtn"
	_hud_tab_btn.text = "+ 임무"
	_hud_tab_btn.focus_mode = Control.FOCUS_NONE
	_hud_tab_btn.tooltip_text = "임무 설명 열기"
	_hud_tab_btn.position = HUD_POS
	_hud_tab_btn.size = Vector2(120, 28)
	_hud_tab_btn.visible = false
	_hud_tab_btn.pressed.connect(_on_hud_tab)
	layer.add_child(_hud_tab_btn)


func _on_hud_close() -> void:
	if hud_panel != null:
		hud_panel.visible = false
	if _hud_tab_btn != null:
		_hud_tab_btn.visible = true


func _on_hud_tab() -> void:
	if hud_panel != null:
		hud_panel.visible = true
	if _hud_tab_btn != null:
		_hud_tab_btn.visible = false


func _refresh() -> void:
	if hud == null:
		return
	var lines: Array = ["%s %s  |  %s  |  RED = GX_%s_%s" % [cfg.get("family", "?"), NAMES.get(cfg.get("family", ""), ""),
		_source_label(), cfg.get("tier", "?"), cfg.get("style", "?")]]
	if not result_text.is_empty():
		lines.append(">>> " + result_text)
	if rules != null:
		var st: Dictionary = rules.call("publish")
		if supply_overlay != null:
			var shown := _net_shown_side()
			var sup_lines: Array = []
			if shown != "":
				var net: Dictionary = (((st.get("supply", {}) as Dictionary).get(shown, {}) as Dictionary).get("net", {}))
				var rng := float(maxi(1, int(net.get("range", 6))))
				# Along the hex paths; links sharing hexes are spread sideways (offset slots 0, +1, -1, +2, ...).
				for l in (net.get("links", []) as Array):
					sup_lines.append({"path": l["path"], "ratio": float(l["len"]) / rng, "live": bool(l["live"])})
				var hl: Dictionary = net.get("hq_link", {})
				if not hl.is_empty() and int(hl["len"]) > 0:
					sup_lines.append({"path": hl["path"], "ratio": float(hl["len"]) / rng, "live": true})
				_assign_link_offsets(sup_lines)
			supply_overlay.set_state(sup_lines, st.get("bases", []), _objective_marks(st), _blue_hq_hex(), _zone_radii(),
				st.get("heads", {}))
			_update_lines3d(sup_lines)
			_update_head_tokens(st.get("heads", {}))
		_update_village_banner(st)
		var m: Dictionary = rules.get("mission")
		var v: Dictionary = TerrainCls.mission_view(st, "blue")
		lines.append("역할: %s   라운드 %s / %s (남은 %s)" % [ROLE_KR.get(str(v["role"]), str(v["role"])), str(v["round"]),
			str(v["round_limit"]), str(v["rounds_left"])])
		lines.append("병력: %s (붕괴선 %s)" % [str(v["my_soldiers"]["now"]), str(v["my_soldiers"]["collapse_at"])])
		var ms: Dictionary = v["my_supply"]
		lines.append("보급: %s%s, 기지 %d개" % ["연결" if bool(ms["connected"]) else "끊김",
			(" (남은 %s)" % str(ms["cut_rounds_left"])) if ms.has("cut_rounds_left") else "", rules.call("bases_of", "blue").size()])
		if v.has("village"):
			lines.append("마을: 공격 %s / 방어 %s, 연속 점유 %s" % [str(v["village"]["attacker_units"]), str(v["village"]["defender_units"]), str(v["village"]["hold_streak"])])
		if v.has("stronghold"):
			var s: Dictionary = v["stronghold"]
			lines.append("요새 %s: 소유 %s, 성벽 %s/%s%s, 수비대 %s" % [s["id"], s["owner"], str(s["walls"]), str(s["walls_max"]),
				" (돌파)" if bool(s["breached"]) else "", str(s["garrison"])])
		if v.has("sites"):
			var site_txt: Array = []
			for s2 in (v["sites"] as Array):
				site_txt.append("(%s) %s" % [", ".join((s2["hex"] as Array).map(func(x): return str(x))), OWNER_KR.get(str(s2["owner"]), str(s2["owner"]))])
			lines.append("거점: %s  |  3곳 연속 유지 BLUE %s / RED %s" % [" · ".join(site_txt),
				str((v["site_streak"] as Dictionary).get("blue", 0)), str((v["site_streak"] as Dictionary).get("red", 0))])
		lines.append("")
		lines.append(_rules_text(m))
	lines.append("")
	lines.append("%s · F8 같은 맵 다시 · F6 GX 티어 · F7 GX 스타일 · HQ 선택 → ⚑ 병참기지 (또는 B)" % (
		"F1-F5 튜토리얼 M1-M5" if _is_tutorial() else ("F1-F4 시뮬레이션 맵 fixed/mild/broad/counterfactual" if _is_sim() else "F1-F5 미션 새 맵")))
	hud.text = "\n".join(lines)


## Short Korean rule summary for BLUE (numbers from the live mission block / gx_missions_config.json).
func _rules_text(m: Dictionary) -> String:
	var rc: Dictionary = rules.get("rules_cfg")
	var role := str((m.get("roles", {}) as Dictionary).get("blue", "none"))
	var goal := ""
	match str(m.get("family", "")):
		"M1":
			goal = "BLUE가 마을 3칸을 지키고 시작. RED: 마을 칸에 부대 %d개 이상 + BLUE 0개를 %d라운드 연속 만들면 승리. BLUE: 마을 칸에 한 부대라도 남겨 라운드 제한까지 버티면 승리." % [
				int(rc["m1_area_units"]), int(rc["m1_area_hold"])]
		"M2", "M5":
			goal = "공격측: 요새/성채를 점령하면 승리. 방어측: 라운드 제한까지 지키면 승리."
		"M3":
			goal = "상대 병력이 시작의 %d%% 이하가 되면(군 붕괴) 승리." % int(round(float(m.get("collapse_frac", 0.3)) * 100.0))
		"M4":
			goal = "거점 %d곳 모두에 기지를 두고 %d라운드 유지하면 승리. 제한 시 %d곳 이상 보유측 승리." % [
				int(rc["m4_n_sites"]), int(rc["m4_full_hold"]), int(rc["m4_majority"])]
	var out: Array = ["목표 (BLUE = %s): %s" % [ROLE_KR.get(role, role), goal],
		"공통: 내 HQ 파괴 = 패배, 적 HQ 파괴 = 승리. 병력 %d%% 이하 = 군 붕괴 패배." % int(round(float(m.get("collapse_frac", 0.3)) * 100.0)),
		("보급: 맵 뒤쪽 head 기지(파괴 불가)에서 시작. 병참기지는 HQ가 ⚑ 버튼/B로 자기 칸에 건설(그 턴 이동 전, 쿨타임 %d턴). " +
		"노드끼리 경로 %d칸 이내면 자동 연결, head와 이어진 노드가 HQ에서 %d칸 이내면 보급 연결, 아니면 %d라운드 뒤 패배. " +
		"적이 기지 칸에 2번 들어오면 파괴(1번째는 막힘). 선은 HQ/기지 클릭 시만 표시, 멀수록 주황→빨강·가늘게.") % [
			int(rc["base_build_cooldown"]), int(rc["supply_link_range"]), int(rc["supply_link_range"]), int(rc["supply_cut_turns"])]]
	if bool(m.get("morale", false)):
		out.append("사기 (HQ 거리): %d칸 이내 회복(+%d부터 라운드마다 +%d, 최대 +%d, 보급 연결 시), %d~%d칸 유지, %d칸 넘으면 -%d/라운드." % [
			int(rc["morale_zone_near_max"]), int(rc["morale_recover_base"]), int(rc["morale_recover_step"]), int(rc["morale_recover_cap"]),
			int(rc["morale_zone_near_max"]) + 1, int(rc["morale_zone_mid_max"]), int(rc["morale_zone_mid_max"]), int(rc["morale_far_loss"])])
	return "\n".join(out)


## Objective hexes for the overlay: M1 village hexes, M4 sites (tinted by base owner).
func _objective_marks(st: Dictionary) -> Array:
	var out: Array = []
	for o in _village_occupants((rules.get("mission") as Dictionary).get("village_hexes", [])):
		out.append(o)
	for s in (st.get("sites", []) as Array):
		out.append({"hex": s["hex"], "owner": str(s.get("owner", "none"))})
	return out


func _blue_hq_hex() -> Vector2i:
	var hq: Dictionary = rules.call("hq_of", "blue")
	return Vector2i(int(hq.get("q", 0)), int(hq.get("r", 0)))


## Morale zone borders around BLUE's HQ (only when the mission has morale on).
func _zone_radii() -> Array:
	if not bool((rules.get("mission") as Dictionary).get("morale", false)) or (rules.call("hq_of", "blue") as Dictionary).is_empty():
		return []
	var rc: Dictionary = rules.get("rules_cfg")
	return [int(rc["morale_zone_near_max"]), int(rc["morale_zone_mid_max"])]


const REASONS := {
	"collapse_red": "RED 군 붕괴", "collapse_blue": "BLUE 군 붕괴", "mutual_collapse": "양군 동시 붕괴",
	"supply_cut_red": "RED 보급 두절", "supply_cut_blue": "BLUE 보급 두절",
	"mutual_supply_cut": "양군 보급 두절", "village_occupied": "마을 점령", "stronghold_captured": "요새 점령",
	"sites_full_hold": "거점 3곳 유지", "sites_majority_at_limit": "제한 라운드 거점 다수 보유",
	"round_limit_defender_holds": "제한 라운드까지 방어 성공", "round_limit_stalemate": "제한 라운드 도달 (승부 없음)",
}


func _reason_text(o: Dictionary) -> String:
	var reason := str(o.get("reason", ""))
	if reason == "hq_destroyed":
		return "적 HQ 파괴" if str(o.get("winner", "")) == "blue" else "아군 HQ 파괴"
	return str(REASONS.get(reason, reason))


func _next_family() -> String:
	var fams := ["M1", "M2", "M3", "M4", "M5"]
	return fams[(fams.find(str(cfg.get("family", "M1"))) + 1) % fams.size()]


## Result panel (win / loss / draw) with the three ways on: retry, next mission, title.
func _show_result_panel(winner: String) -> void:
	if _hud_layer == null:
		return
	if _result_panel != null:
		_result_panel.queue_free()
	var col := Color(0.35, 0.75, 1.0) if winner == "blue" else (Color(1.0, 0.4, 0.35) if winner == "red" else Color(0.85, 0.8, 0.6))
	var p := PanelContainer.new()
	p.name = "MissionResultPanel"
	p.set_anchors_preset(Control.PRESET_CENTER)
	p.offset_left = -300
	p.offset_right = 300
	p.offset_top = -120
	p.offset_bottom = 120
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.07, 0.11, 0.97)
	sb.border_color = col
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(18)
	p.add_theme_stylebox_override("panel", sb)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	p.add_child(box)
	var title := Label.new()
	title.text = "승리" if winner == "blue" else ("패배" if winner == "red" else "무승부")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", col)
	box.add_child(title)
	var sub := Label.new()
	var head: String = _source_label() if _is_sim() else "%s %s" % [str(cfg.get("family", "")), NAMES.get(str(cfg.get("family", "")), "")]
	sub.text = "%s\n%s" % [head, result_text]
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sub.add_theme_font_size_override("font_size", 16)
	box.add_child(sub)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	box.add_child(row)
	var nxt := _next_family()
	for spec in [["다시 하기", func() -> void: _restart(cfg)],
			[("새 시드 (%s)" % str(cfg.get("sim_family", ""))) if _is_sim() else "다음: %s %s" % [nxt, NAMES.get(nxt, "")],
				func() -> void: _restart(pick(SIM_MISSION_FAMILY if _is_sim() else nxt, cfg))],
			["타이틀로", func() -> void: get_tree().change_scene_to_file(TITLE_SCENE)]]:
		var b := Button.new()
		b.text = spec[0]
		b.custom_minimum_size = Vector2(170, 44)
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(spec[1])
		row.add_child(b)
	_hud_layer.add_child(p)
	_result_panel = p


