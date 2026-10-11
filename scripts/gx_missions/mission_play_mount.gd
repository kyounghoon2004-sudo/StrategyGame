extends Node

## Human play on the generated mission maps (2026-10-09): the player is BLUE (the shell's own controls), RED is the
## mission GX. MissionRules judges the match at the end of every round. Fog and morale off, as in the training games.
##   F1..F5  new random map of mission M1..M5        F8  replay this map
##   F6      RED GX tier (BASIC / INTER / ADV)        F7  RED GX style
##   B       BUILD_BASE with your HQ (or the button)
## Maps: artifacts/mission_maps/play/M<n>_s<seed>.json (tools/battlefields/gen_missions.py --batch 20).
## Launch: Godot --path <project> --script res://tools/play_missions.gd [-- M3]

const MissionRulesCls = preload("res://scripts/gx_missions/mission_rules.gd")
const MissionGxCls = preload("res://scripts/gx_missions/mission_gx_controller.gd")
const TerrainCls = preload("res://scripts/cloud_pipeline/commander_terrain.gd")

const META := "mission_play"
const MAP_DIR := "res://artifacts/mission_maps/play"
const TIERS := ["BASIC", "INTER", "ADV"]
const STYLES := ["BULWARK", "SPEARHEAD", "HARRIER", "OUTRIDER"]
const NAMES := {"M1": "마을 방어/공략", "M2": "성벽 요새", "M3": "야전 (군 붕괴)", "M4": "거점 점령", "M5": "공성 (성채)"}

var cfg := {}
var shell: Node
var rules: Node
var red: Node
var hud: Label
var build_btn: Button
var last_round := 0
var result_text := ""
var _keys := {}


static func pick(family: String, prev: Dictionary = {}) -> Dictionary:
	var c := prev.duplicate()
	c["family"] = family
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
	battle.set("is_step0_sandbox", false)
	battle.set("battlefield_id", "@" + str(cfg["map"]))
	battle.set("no_fog", true)
	battle.set("present_perspective", false)


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
	print("[MissionPlay] %s seed %d vs GX_%s_%s" % [cfg["family"], cfg["seed"], cfg["tier"], cfg["style"]])


func _process(_d: float) -> void:
	for k in [KEY_F1, KEY_F2, KEY_F3, KEY_F4, KEY_F5]:
		if _pressed(k):
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
	if rules == null:
		return
	var res: Dictionary = rules.call("build_base", _blue_hq())
	var msg := ("기지 건설: %s" % str(res.get("hex", ""))) if bool(res.get("success", false)) else ("기지 건설 불가: " + str(res.get("code", "")))
	if shell.has_method("_show_combat_log"):
		shell.call("_show_combat_log", "[BLUE HQ] " + msg)
	print("[MissionPlay] " + msg)


func _on_outcome(o: Dictionary) -> void:
	var w := str(o.get("winner", "none"))
	result_text = ("승리" if w == "blue" else ("패배" if w == "red" else "무승부")) + " (%s, round %s)" % [str(o.get("reason", "")), str(o.get("round", ""))]
	var nb := shell.get("next_turn_button") as Button
	if nb != null:
		nb.disabled = true


func _fail(msg: String) -> void:
	push_error("[MissionPlay] " + msg)
	result_text = "ERROR: " + msg


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 50
	add_child(layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(12, 12)
	panel.custom_minimum_size = Vector2(430, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.06, 0.09, 0.82)
	sb.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", sb)
	layer.add_child(panel)
	var box := VBoxContainer.new()
	panel.add_child(box)
	hud = Label.new()
	hud.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hud.custom_minimum_size = Vector2(410, 0)
	hud.add_theme_font_size_override("font_size", 13)
	box.add_child(hud)
	build_btn = Button.new()
	build_btn.text = "BUILD BASE (HQ, B)"
	build_btn.focus_mode = Control.FOCUS_NONE
	build_btn.pressed.connect(_build_base)
	box.add_child(build_btn)


func _refresh() -> void:
	if hud == null:
		return
	var lines: Array = ["%s %s  |  seed %s  |  RED = GX_%s_%s" % [cfg.get("family", "?"), NAMES.get(cfg.get("family", ""), ""),
		str(cfg.get("seed", "?")), cfg.get("tier", "?"), cfg.get("style", "?")]]
	if not result_text.is_empty():
		lines.append(">>> " + result_text)
	if rules != null:
		var st: Dictionary = rules.call("publish")
		var m: Dictionary = rules.get("mission")
		var v: Dictionary = TerrainCls.mission_view(st, "blue")
		lines.append("역할: %s   라운드 %s / %s (남은 %s)" % [v["role"], str(v["round"]), str(v["round_limit"]), str(v["rounds_left"])])
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
			lines.append("거점: %s  연속 %s" % [JSON.stringify(v["sites"]), JSON.stringify(v["site_streak"])])
		lines.append("")
		lines.append(TerrainCls.mission_prompt(m, "blue").replace("BLUE", "RED"))
	lines.append("")
	lines.append("F1-F5 미션 새 맵 · F8 같은 맵 다시 · F6 GX 티어 · F7 GX 스타일 · B 기지 건설")
	hud.text = "\n".join(lines)
