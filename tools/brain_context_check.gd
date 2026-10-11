extends SceneTree

## CONTEXTUAL BRAIN V0 self-check. Exit 0 = all asserts hold.
##   godot --headless --path <project> -s res://tools/brain_context_check.gd

const SimControllerCls = preload("res://scripts/sim/sim_controller.gd")
const ObsCls = preload("res://scripts/cloud1/cloud1_observation.gd")
const PacketCls = preload("res://scripts/cloud2/cloud2_general_packet.gd")
const CtxCls = preload("res://scripts/cloud2/cloud2_brain_context.gd")
const Step3ConfigCls = preload("res://scripts/core/step3_config.gd")
const EpisodeSpecCls = preload("res://scripts/episodes/episode_spec.gd")
const EpisodeRuntimeCls = preload("res://scripts/episodes/episode_runtime.gd")

var _fails := 0


func _ok(cond: bool, what: String) -> void:
	print(("PASS " if cond else "FAIL ") + what)
	if not cond:
		_fails += 1


func _sim(red_q: int, blue_q: int) -> RefCounted:
	var forces := [
		{"id": "R_HQ_1", "class": "hq", "faction": "red", "q": 8, "r": 0, "soldiers": 300},
		{"id": "R_CAV_1", "class": "cavalry", "faction": "red", "q": red_q, "r": 1, "soldiers": 300},
		{"id": "R_INF_1", "class": "infantry", "faction": "red", "q": red_q, "r": -1, "soldiers": 400},
		{"id": "B_HQ_1", "class": "hq", "faction": "blue", "q": -8, "r": 0, "soldiers": 300},
		{"id": "B_ARC_1", "class": "archer", "faction": "blue", "q": blue_q, "r": 0, "soldiers": 250},
	]
	var sim: RefCounted = SimControllerCls.new()
	sim.load_scenario({"scenario_id": "ctx_check", "scenario_version": "1.0.0", "seed": 1,
		"mission_contract": {"primary_objective": "destroy_all_red", "turn_limit": 10},
		"map": {"bounds": {"q_min": -12, "q_max": 12, "r_min": -6, "r_max": 6}, "default_terrain": 0,
			"terrain_overrides": {}, "river_cells": []},
		"forces": forces, "start_turn": 1})
	return sim


func _flat() -> Dictionary:
	var t := {}
	for q in range(-12, 13):
		for r in range(-6, 7):
			t["%d,%d" % [q, r]] = 0
	return t


func _init() -> void:
	# 1. Gate off -> no context key (production packet unchanged).
	OS.set_environment(CtxCls.ENV, "")
	var obs: Dictionary = ObsCls.build(_sim(3, -3), "red")
	_ok(not PacketCls.build_victory_initial(obs, "red").has("context"), "gate off: packet has no context")
	OS.set_environment(CtxCls.ENV, "v0")
	_ok(PacketCls.build_victory_initial(obs, "red").has("context"), "gate on: packet has context")

	# 2. Rules come from the engine accessors; an episode delta moves engine AND pack.
	var c0 := CtxCls.build(obs, "red", _flat())
	var cls0: Dictionary = c0["rules"]["classes"]
	_ok(int(cls0["CAVALRY"]["mp_rank"]) == 1, "stock: cavalry is fastest present class")
	var rules := EpisodeSpecCls.base_rules()
	rules["base_mp"]["cavalry"] = 1.0
	rules["base_mp"]["infantry"] = 4.0
	EpisodeRuntimeCls.install({"episode_id": "chk", "family": "probe", "split": "probe", "map": {"id": ""}, "rules": rules, "objective": {}})
	var c1 := CtxCls.build(obs, "red", _flat())
	_ok(Step3ConfigCls.get_base_movement("cavalry") == 1.0, "engine reads episode base_mp")
	_ok(float(c1["rules"]["classes"]["CAVALRY"]["mp"]) == 1.0 and int(c1["rules"]["classes"]["INFANTRY"]["mp_rank"]) == 1,
		"pack mirrors episode rules (infantry now fastest)")
	EpisodeRuntimeCls.clear()

	# 3. Terrain: a wall through CENTER shows up as blocked cells and a detour.
	var walled := _flat()
	for r in range(-6, 6):  # single gap at r=6
		walled["0,%d" % r] = 8
	var cw := CtxCls.build(obs, "red", walled)
	_ok(float(cw["map"]["sectors"]["CENTER"]["passable"]) < 1.0, "wall lowers CENTER passable fraction")
	var west_flat := int(c0["map"]["travel_from_own_hq"]["WEST"]["path_cost_std_terrain"])
	var west_wall := int(cw["map"]["travel_from_own_hq"]["WEST"]["path_cost_std_terrain"])
	_ok(west_wall > west_flat, "wall lengthens path to WEST (%d > %d)" % [west_wall, west_flat])

	# 4. Catalog path: episode map id -> public catalog terrain.
	var obs_bf := obs.duplicate(true)
	obs_bf["episode_context"] = {"episode_id": "x", "family": "nominal", "map": {"id": "BF04"}}
	var cb := CtxCls.build(obs_bf, "red")
	_ok(str(cb["map"]["terrain_source"]) == "episode_map" and float(cb["map"]["sectors"]["CENTER"]["mean_cost_infantry"]) > 1.0,
		"BF04 catalog terrain loaded (mountain wall raises CENTER cost: %s)" % str(cb["map"]["sectors"]["CENTER"]))
	_ok(str(CtxCls.build(obs, "red")["map"]["terrain_source"]) == "none", "no episode map -> terrain_source none")

	# 5. Fog boundary: a far, unseen enemy is not counted or named.
	var obs_far: Dictionary = ObsCls.build(_sim(3, -11), "red")
	var visible := (obs_far["known_enemy_units"] as Array).filter(func(e): return str(e["contact_state"]) == "current_visible").size()
	var cf := CtxCls.build(obs_far, "red", _flat())
	_ok(int(cf["forces"]["enemy_visible"]["formations"]) == visible, "enemy_visible == fog-visible contacts (%d)" % visible)
	var text := JSON.stringify(cf)
	_ok(visible > 0 or not text.contains("ARCHER"), "unseen enemy class absent from pack")

	# 6. Mode is side-relative.
	_ok(str(CtxCls.build(obs, "blue")["mode"]["at_turn_limit"]) == "DRAW_EXPIRED", "mode: destroy_all_red expires as draw")
	OS.set_environment(CtxCls.ENV, "")
	print("BRAIN_CONTEXT_CHECK fails=%d" % _fails)
	quit(1 if _fails > 0 else 0)
