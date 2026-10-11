extends Node

## GX MISSIONS v1 — DEV harness (separate dev mode; never used by the game, the arena or training).
## Boots a Step0 sandbox battle shell under this node, applies a fixture layout, attaches MissionRules
## and one mission GX per side (GX vs GX: BLUE via run_side_phase, RED via the shell's laya_red_controller
## seam), plays rounds and writes outcome + mission_state per round to artifacts/gx_missions_dev/.

const ShellScene := preload("res://scenes/step2r_battlefield_shell.tscn")
const RulesCls = preload("res://scripts/gx_missions/mission_rules.gd")
const CtlCls = preload("res://scripts/gx_missions/mission_gx_controller.gd")
const CfgCls = preload("res://scripts/gx_missions/mission_config.gd")
const OUT_DIR := "res://artifacts/gx_missions_dev"

var shell: Node
var manager: RefCounted
var rules: Node
var blue_ctl: Node
var red_ctl: Node
var fixture: Dictionary = {}
var rows: Array = []
var _dev: Dictionary = {}


static func load_fixture(path_or_family: String) -> Dictionary:
	var p := path_or_family
	var by_family := {"M1": "m1_village", "M2": "m2_fortress", "M3": "m3_field", "M4": "m4_occupation", "M5": "m5_siege",
		"HQ_EXPOSED": "hq_exposed"}
	if by_family.has(p.to_upper()):
		p = "res://tools/gx_missions_dev/fixtures/%s.json" % by_family[p.to_upper()]
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	return parsed if parsed is Dictionary else {}


## opts: {red_profile, blue_profile, red_seed, blue_seed, controllers (bool), morale (optional bool override)}
func boot(fix: Dictionary, opts: Dictionary = {}) -> Dictionary:
	_dev = CfgCls.section("dev")
	fixture = fix.duplicate(true)
	shell = ShellScene.instantiate()
	shell.name = "Battle"
	shell.set("is_step0_sandbox", true)
	shell.set("present_perspective", false)
	add_child(shell)
	var det: Node = shell.get_node_or_null("Step7Integration")
	for _i in range(int(_dev["frame_wait_cap"])):
		if det != null and bool(det.get("ready_for_step7")) and shell.get("unit_manager") != null:
			break
		await get_tree().process_frame
	if det == null or not bool(det.get("ready_for_step7")):
		return {"ok": false, "error": "Step7Integration not ready"}
	manager = shell.get("unit_manager") as RefCounted
	apply_layout()
	var mission: Dictionary = (fixture.get("mission", {}) as Dictionary).duplicate(true)
	if opts.has("morale"):
		mission["morale"] = bool(opts["morale"])
	rules = RulesCls.new()
	rules.name = "MissionRules"
	add_child(rules)
	var setup_res: Dictionary = rules.call("setup", shell, mission)
	if not bool(setup_res.get("ok", false)):
		return {"ok": false, "error": "MissionRules: " + str(setup_res.get("error", "?"))}
	if bool(opts.get("controllers", true)):
		blue_ctl = _make_ctl("blue", str(opts.get("blue_profile", "GX_ADV_SPEARHEAD")), int(opts.get("blue_seed", 1)))
		red_ctl = _make_ctl("red", str(opts.get("red_profile", "GX_ADV_SPEARHEAD")), int(opts.get("red_seed", 2)))
		var bb: Dictionary = blue_ctl.call("bind_live", shell, det, false)
		var rb: Dictionary = red_ctl.call("bind_live", shell, det, true)
		if not bool(bb.get("ok", false)) or not bool(rb.get("ok", false)):
			return {"ok": false, "error": "GX bind failed blue=%s red=%s" % [str(bb.get("error", "")), str(rb.get("error", ""))]}
	return {"ok": true, "mission": rules.get("mission")}


func _make_ctl(side: String, profile: String, seed: int) -> Node:
	var c: Node = CtlCls.new()
	c.name = "MissionGx_" + side
	c.set("auto_mount", false)
	c.set("side", side)
	c.set("dev_difficulty", profile)
	c.set("seed_override", seed)
	c.set("mission_rules", rules)
	add_child(c)
	return c


## Fixture layout: "default_10v10" (the sandbox's own deployment) + optional unit_moves, or "units".
func apply_layout() -> void:
	var renderer: Node = shell.get("unit_renderer")
	if str(fixture.get("layout", "default_10v10")) == "units":
		renderer.call("clear_units")
		for u in (fixture.get("units", []) as Array):
			renderer.call("spawn_unit", str(u["id"]), str(u["class"]), str(u["faction"]), int(u["q"]), int(u["r"]), int(u["soldiers"]))
		manager.call("initialize_from_renderer_units", renderer.call("get_all_units"), false)
	else:
		shell.call("rebuild_step0_roster")
	var moves: Dictionary = fixture.get("unit_moves", {})
	for uid in moves.keys():
		place_unit(str(uid), Vector2i(int(moves[uid][0]), int(moves[uid][1])))
	shell.call("_cache_hq_ids")
	for u in manager.call("get_all_units"):
		if str(u.get("class", "")) == "hq":
			renderer.call("set_unit_hq", str(u["id"]), true)
	var truth: RefCounted = shell.get_node("Step7Integration").get("truth") as RefCounted
	if truth != null:
		truth.call("notify_mutation", "gx_missions_layout")


## DEV/test setup only: relocate a unit in the live roster (occupancy + renderer kept consistent).
func place_unit(uid: String, hex: Vector2i) -> void:
	var units: Dictionary = manager.get("_units")  # live row (get_unit_by_id returns a copy)
	if not units.has(uid):
		return
	var u: Dictionary = units[uid]
	var occ: Dictionary = manager.get("_occupied_map")
	occ.erase("%d,%d" % [int(u["q"]), int(u["r"])])
	u["q"] = hex.x
	u["r"] = hex.y
	occ["%d,%d" % [hex.x, hex.y]] = uid
	var renderer: Node = shell.get("unit_renderer")
	if renderer != null and renderer.has_method("update_unit_position"):
		renderer.call("update_unit_position", uid, hex.x, hex.y)


func over() -> bool:
	return not (rules.get("outcome") as Dictionary).is_empty() or bool(shell.call("_battle_over"))


## One full round: BLUE phase, then the shell's authoritative end_player_phase (RED phase + end_turn),
## then MissionRules end-of-round evaluation.
func play_round() -> Dictionary:
	var turn := int(manager.call("get_current_turn"))
	if not over():
		shell.set("symmetric_auto_lock", true)
		await blue_ctl.call("run_side_phase")
		shell.set("symmetric_auto_lock", false)
	if not bool(shell.call("_battle_over")):
		await shell.call("end_player_phase")
	var out: Dictionary = rules.call("evaluate_round", turn)
	var row := {"round": turn, "outcome": out if not out.is_empty() else null,
		"mission_state": (rules.get("mission_state") as Dictionary).duplicate(true),
		"actions": {"blue": (blue_ctl.get("action_counts") as Dictionary).duplicate(),
			"red": (red_ctl.get("action_counts") as Dictionary).duplicate()}}
	rows.append(row)
	print("[GxMissionsDev] ROUND %s" % JSON.stringify({"round": turn, "outcome": row["outcome"],
		"soldiers": row["mission_state"].get("soldiers", {}), "supply": _supply_brief(row["mission_state"]),
		"village": row["mission_state"].get("village", null), "sites": row["mission_state"].get("sites", null),
		"stronghold": _sh_brief(row["mission_state"]), "actions": row["actions"]}))
	return row


func _supply_brief(ms: Dictionary) -> Dictionary:
	var out := {}
	for s in ["red", "blue"]:
		var r: Dictionary = (ms.get("supply", {}) as Dictionary).get(s, {})
		out[s] = {"connected": r.get("connected", null), "turns_left": r.get("turns_left", null), "reason": r.get("reason", "")}
	return out


func _sh_brief(ms: Dictionary) -> Variant:
	var s: Dictionary = ms.get("stronghold", {})
	if s.is_empty():
		return null
	return {"owner": s["owner"], "wall_hp": s["wall_hp"], "breached": s["breached"], "garrison": s["garrison"]}


func play(rounds_cap: int) -> Dictionary:
	var pause := 0.0 if DisplayServer.get_name() == "headless" else float(_dev["phase_pause_visible_s"])
	var nb := shell.get("next_turn_button") as Button
	if nb != null:
		nb.disabled = true
	while not over() and int(manager.call("get_current_turn")) <= rounds_cap:
		await play_round()
		if pause > 0.0:
			await get_tree().create_timer(pause).timeout
	return summary(rounds_cap)


func summary(rounds_cap: int) -> Dictionary:
	var out: Dictionary = rules.get("outcome")
	return {"fixture": str(fixture.get("fixture_id", "")), "mission": rules.get("mission"),
		"outcome": out if not out.is_empty() else {"winner": "none", "reason": "dev_round_cap_%d" % rounds_cap},
		"rounds_played": rows.size(),
		"profiles": {"blue": (blue_ctl.get("bot") as RefCounted).call("profile").get("profile_id", ""),
			"red": (red_ctl.get("bot") as RefCounted).call("profile").get("profile_id", "")},
		"actions": {"blue": blue_ctl.get("action_counts"), "red": red_ctl.get("action_counts")},
		"intents": {"blue": (blue_ctl.get("bot") as RefCounted).get("intent_counts"),
			"red": (red_ctl.get("bot") as RefCounted).get("intent_counts")},
		"hq_strike_turns": {"blue": (blue_ctl.get("bot") as RefCounted).get("hq_strike_turns"),
			"red": (red_ctl.get("bot") as RefCounted).get("hq_strike_turns")},
		"hq_opportunity_max": {"blue": (blue_ctl.get("bot") as RefCounted).get("hq_opportunity_max"),
			"red": (red_ctl.get("bot") as RefCounted).get("hq_opportunity_max")},
		"events": rules.get("events"),
		"final_mission_state": rules.get("mission_state")}


func write_outputs(tag: String, summ: Dictionary) -> String:
	var dir := ProjectSettings.globalize_path(OUT_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open("%s/%s_rounds.jsonl" % [dir, tag], FileAccess.WRITE)
	if f != null:
		for r in rows:
			f.store_line(JSON.stringify(r))
		f.close()
	var g := FileAccess.open("%s/%s_summary.json" % [dir, tag], FileAccess.WRITE)
	if g != null:
		g.store_string(JSON.stringify(summ, "  ", true))
		g.close()
	return "%s/%s_summary.json" % [dir, tag]
