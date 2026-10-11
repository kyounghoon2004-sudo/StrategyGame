extends SceneTree

## GENERALIZATION_INTEGRATION_SMOKE_V0 — setup parity + GX live phases (test-only).
## One EpisodeSpec per launch:
##   godot --headless --path <proj> -s res://tools/generalization_smoke_probe.gd -- \
##     --episode=<abs spec.json> --out=<abs out.json> [--gx=GX_ADV_SPEARHEAD] [--phases=2]
## Loads the REAL utility_bot_battle_test scene unmodified; --episode= makes the
## shell run the episode (EPISODE LAUNCH MODE disables the scene's Step0 sandbox).
## Checks: runtime identity, engine-applied rules, map/army/stronghold parity,
## GX ruleset view parity, Brain context pack values + fog, gate-off identity,
## then runs GX RED phases (BLUE passive) and records integrity + a state hash.

const Spec = preload("res://scripts/episodes/episode_spec.gd")
const Runtime = preload("res://scripts/episodes/episode_runtime.gd")
const Combat = preload("res://scripts/combat/combat_calculator.gd")
const Movement = preload("res://scripts/core/step3_config.gd")
const Catalog = preload("res://scripts/battlefields/battlefield_catalog.gd")
const View = preload("res://scripts/utility_bot/utility_ruleset_view.gd")
const Bridge = preload("res://scripts/cloud1/cloud1_live_bridge.gd")
const Obs = preload("res://scripts/cloud1/cloud1_observation.gd")
const Packet = preload("res://scripts/cloud2/cloud2_general_packet.gd")
const Ctx = preload("res://scripts/cloud2/cloud2_brain_context.gd")
const Scene = preload("res://scenes/utility_bot_battle_test.tscn")

var _checks := {}


func _ok(name: String, cond: bool, detail: Variant = "") -> void:
	_checks[name] = {"ok": cond, "detail": detail}
	print(("PASS " if cond else "FAIL ") + name + ("" if cond else " " + str(detail)))


func _initialize() -> void:
	call_deferred("_run")


func _arg(k: String, d: String) -> String:
	for a in OS.get_cmdline_user_args():
		if str(a).begins_with("--%s=" % k):
			return str(a).substr(k.length() + 3)
	return d


func _near(a: Variant, b: Variant) -> bool:
	return absf(float(a) - float(b)) < 1e-6


func _run() -> void:
	var path := _arg("episode", "")
	var out := _arg("out", "")
	var gx := _arg("gx", "GX_ADV_SPEARHEAD")
	var phases := int(_arg("phases", "2"))
	var spec := Spec.load(path)
	_ok("spec_valid", not spec.is_empty(), path)
	if spec.is_empty():
		_finish(out, {})
		return
	var rules: Dictionary = spec["rules"]
	root.set_meta("utility_bot_dev_difficulty", gx)
	var scene: Node = Scene.instantiate()
	root.add_child(scene)
	current_scene = scene
	var shell: Node = scene.get_node("Battle")
	var ctl: Node = null
	var deadline := Time.get_ticks_msec() + 90000
	while Time.get_ticks_msec() < deadline:
		var m := scene.get_node_or_null("UtilityBotMount")
		ctl = m.get_node_or_null("UtilityBotLiveController") if m != null else null
		if ctl != null and bool(ctl.get("mount_ready")):
			break
		await process_frame
	_ok("gx_mounted", ctl != null and bool(ctl.get("mount_ready")), "mount timeout")
	if ctl == null or not bool(ctl.get("mount_ready")):
		_finish(out, {})
		return

	# 1. Identity: one installed episode, same rules/objective everywhere.
	_ok("runtime_episode_id", Runtime.episode_id() == str(spec["episode_id"]), Runtime.episode_id())
	_ok("runtime_rules_equal_spec", Spec.canonical(Runtime.rules()) == Spec.canonical(rules))
	_ok("sandbox_off", not bool(shell.get("is_step0_sandbox")))
	var launch: Dictionary = Runtime.launch_record()
	_ok("launch_telemetry", str(launch.get("episode_id", "")) == str(spec["episode_id"]) and str(launch.get("spec_path", "")) == path, launch)

	# 2. Engine applies the sampled rules (the accessors combat/movement call).
	var bad: Array = []
	for cls in Spec.CLASSES:
		var st: Dictionary = rules["class_stats"][cls]
		if not _near(Movement.get_base_movement(cls), rules["base_mp"][cls]):
			bad.append("mp:" + cls)
		if Combat.get_attack_range(cls) != int(st["range"]):
			bad.append("rng:" + cls)
		var eff: Variant = Combat.calculate_combat({"class": cls, "soldier_count": 100, "morale": 100.0},
			{"class": cls, "soldier_count": 100, "morale": 100.0}, 1).get("effective_attack", null)
		if eff == null or not _near(eff, st["attack"]):
			bad.append("atk:%s=%s" % [cls, str(eff)])
	for key in Spec.MATCHUP_KEYS:
		var parts: PackedStringArray = str(key).split("_vs_")
		if parts[1] != "regular" and not _near(Combat.get_matchup_mult(parts[0], parts[1]), rules["matchup"][key]):
			bad.append("matchup:" + key)
	for t in [1, 2, 3]:
		for pair in [["terrain_standard", "infantry"], ["terrain_scout", "scout"]]:
			var tbl: Dictionary = rules[pair[0]]
			if not _near(Movement.get_terrain_cost(t, pair[1]), tbl.get(str(t), tbl.get(t, -1))):
				bad.append("%s:%d" % [pair[0], t])
	_ok("engine_applies_rules", bad.is_empty(), bad)

	# 3. Map / army / stronghold parity with the pinned catalog + spec.
	var cat: Dictionary = Catalog.load_battlefield(str(spec["map"]["id"]))
	var cells: Dictionary = (shell.get("hex_grid") as Node).get("cell_data")
	var tmis := 0
	for k in (cat["terrain"] as Dictionary).keys():
		if not cells.has(k) or int(cells[k].terrain) != int(cat["terrain"][k]):
			tmis += 1
	_ok("map_terrain_parity", tmis == 0 and cells.size() == (cat["terrain"] as Dictionary).size(), {"mismatch": tmis, "cells": cells.size()})
	var mgr: RefCounted = shell.get("unit_manager")
	var live := {}
	for u in mgr.get_all_units_including_garrisoned():
		live[str(u["id"])] = [Combat.normalize_class_name(str(u["class"])), str(u["faction"]), int(u["q"]), int(u["r"]), int(u["soldier_count"])]
	var amis: Array = []
	for u in spec["armies"]:
		var want := [str(u["class"]), str(u["faction"]), int(u["q"]), int(u["r"]), int(u["count"])]
		if live.get(str(u["id"]), []) != want:
			amis.append([u["id"], want, live.get(str(u["id"]), null)])
	_ok("army_parity", amis.is_empty() and live.size() == (spec["armies"] as Array).size(), {"mismatch": amis.slice(0, 5), "live": live.size()})
	var shmis: Array = []
	for sh in mgr.get_all_strongholds():
		if int(sh.fortification_hp_max) != int(spec["map"]["stronghold_hp"].get(str(sh.structure_id), -1)):
			shmis.append(str(sh.structure_id))
	_ok("stronghold_hp_parity", shmis.is_empty(), shmis)

	# 4. GX sees the same public rules through its live observation.
	var gx_obs: Dictionary = ctl.call("_build_observation")
	var view := View.build(gx_obs)
	var vbad: Array = []
	for cls in Spec.CLASSES:
		var row: Dictionary = (view["class_table"] as Dictionary).get(cls, {})
		var st: Dictionary = rules["class_stats"][cls]
		if row.is_empty() or not _near(row["attack"], st["attack"]) or not _near(row["defense"], st["defense"]) \
				or int(row["range"]) != int(st["range"]) or not _near(row["base_mp"], rules["base_mp"][cls]):
			vbad.append([cls, row, st, rules["base_mp"][cls]])
	_ok("gx_view_rules_parity", vbad.is_empty() and str(gx_obs.get("episode_id", "")) == str(spec["episode_id"]), vbad)
	var gx_profile: Dictionary = ctl.call("profile") if ctl.has_method("profile") else ((ctl.get("bot") as RefCounted).call("profile") as Dictionary)
	_ok("gx_profile_and_seed", str(gx_profile).contains(gx) and int(ctl.get("bot_seed")) == int(spec["seeds"]["utility"]), {"profile": gx_profile, "seed": ctl.get("bot_seed")})

	# 5. Brain context pack (RED, live bridge) carries the spec's public values; fog holds.
	var bridge := Bridge.new()
	_ok("brain_bridge_bound", bridge.bind(shell, shell.get_node_or_null("Step7Integration")))
	var obs: Dictionary = Obs.build(bridge, "red")
	OS.set_environment(Ctx.ENV, "")
	var off_packet := Packet.build_victory_initial(obs, "red")
	OS.set_environment(Ctx.ENV, "v0")
	var packet := Packet.build_victory_initial(obs, "red")
	OS.set_environment(Ctx.ENV, "")
	var on_minus := packet.duplicate(true)
	on_minus.erase("context")
	_ok("context_off_path_unchanged", not off_packet.has("context") and Spec.canonical(on_minus) == Spec.canonical(off_packet))
	var pack: Dictionary = packet.get("context", {})
	var pbad := check_pack(pack, obs, spec)
	_ok("brain_pack_public_values", pbad.is_empty(), pbad)
	var leak := hidden_leaks(packet, obs, spec)
	_ok("no_hidden_enemy_leak", leak.is_empty(), leak)

	# 6. GX RED phases on the live scene (BLUE passive), integrity after each.
	var phase_rows: Array = []
	for i in range(phases):
		if bool(shell.call("_battle_over")):
			break
		shell.call("end_player_phase")
		var t_end := Time.get_ticks_msec() + 180000
		var saw := false
		while Time.get_ticks_msec() < t_end:
			saw = saw or bool(ctl.get("_busy"))
			if saw and not bool(ctl.get("_busy")) and int(shell.get("_turn_phase")) == 0:
				break
			await process_frame
		var res: Dictionary = (ctl.get("last_phase_result") as Dictionary).duplicate(true)
		res["integrity"] = integrity(shell, mgr)
		phase_rows.append(res)
	var gx_ok := phase_rows.size() == phases
	for r in phase_rows:
		gx_ok = gx_ok and bool(r.get("ok", false)) and int(r.get("actions", 0)) > 0 \
			and (r["integrity"]["oob"] as Array).is_empty() and (r["integrity"]["dup"] as Array).is_empty()
	_ok("gx_phases_legal", gx_ok, phase_rows)

	_finish(out, {"episode_id": spec["episode_id"], "family": spec["family"], "split": spec["split"],
		"map": spec["map"]["id"], "gx": gx, "gx_profile": gx_profile, "gx_phases": phase_rows,
		"pack": pack, "pack_hash": Spec.canonical(pack).sha256_text(),
		"state_hash_after_gx": state_hash(mgr), "map_units": live.size()})


static func check_pack(pack: Dictionary, obs: Dictionary, spec: Dictionary) -> Array:
	var bad: Array = []
	var rules: Dictionary = spec["rules"]
	if pack.is_empty():
		return ["no pack"]
	if str((pack.get("episode", {}) as Dictionary).get("map", "")) != str(spec["map"]["id"]) \
			or not str(spec["episode_id"]).begins_with(str((pack.get("episode", {}) as Dictionary).get("id", "?"))):
		bad.append(["episode", pack.get("episode")])
	if str((pack.get("map", {}) as Dictionary).get("terrain_source", "")) != "episode_map":
		bad.append("terrain_source")
	for label in (pack["rules"]["classes"] as Dictionary).keys():
		var cls := Combat.normalize_class_name(str(label))
		var row: Dictionary = pack["rules"]["classes"][label]
		var st: Dictionary = rules["class_stats"][cls]
		if not _near_s(row["mp"], rules["base_mp"][cls]) or not _near_s(row["atk"], st["attack"]) \
				or not _near_s(row["def"], st["defense"]) or int(row["rng"]) != int(st["range"]):
			bad.append([label, row, st])
	for m in pack["rules"]["matchups"]:
		if absf(float(m[2]) - Combat.get_matchup_mult(str(m[0]).to_lower(), str(m[1]).to_lower())) > 0.006:
			bad.append(["matchup", m])
	if str(pack["mode"]["objective_code"]) != str(spec["objective"]["red"]) or str(pack["mode"]["episode_mode"]) != str(spec["objective"]["mode"]):
		bad.append(["mode", pack["mode"]])
	var vis := 0
	for e in obs["known_enemy_units"]:
		if str(e["contact_state"]) == "current_visible":
			vis += 1
	if int(pack["forces"]["enemy_visible"]["formations"]) != vis:
		bad.append(["enemy_visible", pack["forces"]["enemy_visible"]["formations"], vis])
	if int(pack["forces"]["friendly"]["formations"]) != (obs["friendly_units"] as Array).size():
		bad.append("friendly_formations")
	return bad


static func _near_s(a: Variant, b: Variant) -> bool:
	return absf(float(a) - float(b)) < 0.006  # pack rounds to 0.01


## Any BLUE (enemy) id or class that is in the spec but not in RED's fog view
## must not appear anywhere in the packet (incl. the context pack).
static func hidden_leaks(packet: Dictionary, obs: Dictionary, spec: Dictionary) -> Array:
	var known := {}
	var known_cls := {}
	for e in obs["known_enemy_units"]:
		known[str(e["unit_id"])] = true
		known_cls[Combat.normalize_class_name(str(e["class"]))] = true
	for u in obs["friendly_units"]:
		known_cls[Combat.normalize_class_name(str(u["class"]))] = true
	var text := JSON.stringify(packet)
	var out: Array = []
	for u in spec["armies"]:
		if str(u["faction"]) == "blue" and not known.has(str(u["id"])):
			var rx := RegEx.create_from_string("\\b%s\\b" % str(u["id"]))
			if rx.search(text) != null:
				out.append(str(u["id"]))
	if packet.has("armies") or (packet.get("context", {}) as Dictionary).has("armies"):
		out.append("armies_field")
	for label in ((packet.get("context", {}) as Dictionary).get("rules", {}).get("classes", {}) as Dictionary).keys():
		if not known_cls.has(Combat.normalize_class_name(str(label))):
			out.append("class:" + str(label))
	return out


static func integrity(shell: Node, mgr: RefCounted) -> Dictionary:
	var cells: Dictionary = (shell.get("hex_grid") as Node).get("cell_data")
	var occ := {}
	var oob: Array = []
	var dup: Array = []
	for u in mgr.get_all_units():
		if bool(u.get("garrisoned", false)):
			continue
		var key := "%d,%d" % [int(u["q"]), int(u["r"])]
		if not cells.has(key) or Movement.is_impassable(int(cells[key].terrain)):
			oob.append(str(u["id"]))
		if occ.has(key):
			dup.append([occ[key], str(u["id"])])
		occ[key] = str(u["id"])
	return {"oob": oob, "dup": dup, "turn": int(mgr.get_current_turn())}


static func state_hash(mgr: RefCounted) -> String:
	var rows: Array = []
	for u in mgr.get_all_units_including_garrisoned():
		rows.append([str(u["id"]), int(u["q"]), int(u["r"]), int(u["soldier_count"]), snappedf(float(u.get("morale", 0.0)), 0.01)])
	rows.sort_custom(func(a, b): return a[0] < b[0])
	return Spec.canonical(rows).sha256_text()


func _finish(out: String, record: Dictionary) -> void:
	var fails := 0
	for k in _checks.keys():
		if not bool(_checks[k]["ok"]):
			fails += 1
	record["checks"] = _checks
	record["fails"] = fails
	var f := FileAccess.open(out, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(record, "  ", true) + "\n")
		f.close()
	print("GX_SMOKE fails=%d" % fails)
	for c in root.get_children():
		c.queue_free()
	await process_frame
	quit(1 if fails > 0 else 0)
