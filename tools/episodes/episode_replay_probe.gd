extends SceneTree

const Spec = preload("res://scripts/episodes/episode_spec.gd")
const Runtime = preload("res://scripts/episodes/episode_runtime.gd")
const Combat = preload("res://scripts/combat/combat_calculator.gd")
const Movement = preload("res://scripts/core/step3_config.gd")
const Utility = preload("res://scripts/utility_bot/utility_bot_v2.gd")
const UtilityView = preload("res://scripts/utility_bot/utility_ruleset_view.gd")
const Bridge = preload("res://scripts/cloud1/cloud1_live_bridge.gd")
const BrainObservation = preload("res://scripts/cloud1/cloud1_observation.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var out := ""
	var path := ""
	var make := false
	for arg in args:
		if str(arg).begins_with("--out="): out = str(arg).substr(6)
		if str(arg).begins_with("--episode="): path = str(arg).substr(10)
		if arg == "--make": make = true
	if out.is_empty():
		printerr("missing --out")
		quit(1)
		return
	if make:
		if not Spec.sample("held_out", "train", 46).is_empty():
			printerr("held-out split leaked into train")
			quit(1)
			return
		var specs := [
			Spec.sample("nominal", "train", 42),
			Spec.sample("mild", "train", 43),
			Spec.sample("broad", "validation", 44),
			Spec.sample("counterfactual_valid", "train", 45),
			Spec.sample("held_out", "test", 46),
		]
		for i in range(specs.size()):
			if specs[i].is_empty():
				printerr("sample failed ", i)
				quit(1)
				return
			if Spec.sample(str(specs[i]["family"]), str(specs[i]["split"]), int(specs[i]["seeds"]["sample"]))["episode_id"] != specs[i]["episode_id"]:
				printerr("sampler nondeterministic ", i)
				quit(1)
				return
			var target := out.get_basename() + "_%d.json" % i
			if not Spec.save(specs[i], target):
				printerr("save failed ", target)
				quit(1)
				return
		var tampered: Dictionary = specs[1].duplicate(true)
		tampered["armies"][0]["count"] = 9999
		if bool(Spec.validate(tampered).get("ok", false)):
			printerr("tampered spec accepted")
			quit(1)
			return
		var f := FileAccess.open(out, FileAccess.WRITE)
		f.store_string(JSON.stringify({"ok": true, "ids": specs.map(func(s): return s["episode_id"])}, "  "))
		f.close()
		quit(0)
		return
	var spec := Spec.load(path)
	if spec.is_empty():
		var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		printerr("spec rejected: ", Spec.validate(raw) if raw is Dictionary else "parse error")
		quit(1)
		return
	var scene: PackedScene = load("res://scenes/step2r_battlefield_shell.tscn")
	var shell: Node = scene.instantiate()
	shell.set("episode_spec_path", path)
	root.add_child(shell)
	await process_frame
	if Runtime.episode_id() != str(spec["episode_id"]):
		printerr("runtime episode mismatch")
		quit(1)
		return
	var grid: Node = shell.get("hex_grid")
	var cells: Dictionary = grid.get("cell_data")
	var map_rows: Dictionary = {}
	for key in cells.keys():
		map_rows[key] = int(cells[key].terrain)
	var manager: RefCounted = shell.get("unit_manager")
	var army: Array = []
	for u in manager.get_all_units_including_garrisoned():
		army.append({"id": u.get("id"), "class": u.get("class"), "faction": u.get("faction"), "q": u.get("q"), "r": u.get("r"), "count": u.get("soldier_count"), "garrisoned": u.get("garrisoned", false)})
	army.sort_custom(func(a, b): return str(a["id"]) < str(b["id"]))
	var bot := Utility.new()
	bot.configure(int(spec["seeds"]["utility"]), "")
	var rules := Runtime.rules()
	var view := UtilityView.build({"episode_id": spec["episode_id"], "ruleset_override": rules, "friendly_units": army, "known_enemy_units": [], "board": {"dimensions": shell.map_bounds()}})
	var stronghold_hp := {}
	for sh in manager.get_all_strongholds():
		stronghold_hp[str(sh.structure_id)] = int(sh.fortification_hp_max)
	var bridge := Bridge.new()
	var det: Node = shell.get_node_or_null("Step7Integration")
	if not bridge.bind(shell, det):
		printerr("Brain bridge unavailable")
		quit(1)
		return
	var brain_observation := BrainObservation.build(bridge, "blue")
	var brain_wire: Dictionary = JSON.parse_string(BrainObservation.to_json(brain_observation, false))
	var red_observation := BrainObservation.build(bridge, "red")
	var red_wire: Dictionary = JSON.parse_string(BrainObservation.to_json(red_observation, false))
	var brain_episode: Dictionary = brain_wire.get("episode_context", {})
	if str(brain_episode.get("episode_id", "")) != str(spec["episode_id"]) or brain_episode.has("armies"):
		printerr("Brain context episode mismatch or hidden roster leak")
		quit(1)
		return
	if str((brain_wire.get("mission", {}) as Dictionary).get("type", "")) != str(spec["objective"]["blue"]):
		printerr("Brain mission differs from native episode objective")
		quit(1)
		return
	if str((red_wire.get("mission", {}) as Dictionary).get("type", "")) != str(spec["objective"]["red"]) or Spec.canonical((red_wire.get("episode_context", {}) as Dictionary).get("rules", {})) != Spec.canonical(rules):
		printerr("RED Brain context objective or rules mismatch")
		quit(1)
		return
	if Spec.canonical(brain_episode.get("rules", {})) != Spec.canonical(rules) or Spec.canonical(view.get("matchup", {})) != Spec.canonical(rules["matchup"]):
		printerr("Brain or Utility rule mismatch")
		quit(1)
		return
	var record := {
		"episode_id": Runtime.episode_id(),
		"map_hash": Spec.canonical(map_rows).sha256_text(),
		"map_cells": cells.size(),
		"stronghold_hp": stronghold_hp,
		"rules_hash": Spec.canonical(rules).sha256_text(),
		"army_hash": Spec.canonical(army).sha256_text(),
		"objective": spec["objective"],
		"utility_seed": spec["seeds"]["utility"],
		"utility_profile": bot.profile(),
		"utility_view_hash": Spec.canonical(view).sha256_text(),
		"brain_public_rules_hash": Spec.canonical(brain_episode.get("rules", {})).sha256_text(),
		"brain_context_hash": Spec.canonical(brain_episode).sha256_text(),
		"telemetry_rules_fingerprint": str((bridge.rules_fingerprint() as Dictionary).get("fingerprint", "")),
		"live_attack": Combat.calculate_combat({"class": "infantry", "soldier_count": 100}, {"class": "spear", "soldier_count": 100}, 1).get("effective_attack", null),
		"live_move": Movement.get_base_movement("cavalry"),
		"live_terrain": Movement.get_terrain_cost(2, "infantry"),
	}
	var f := FileAccess.open(out, FileAccess.WRITE)
	if f == null:
		printerr("cannot write probe")
		quit(1)
		return
	f.store_string(JSON.stringify(record, "  ") + "\n")
	f.close()
	print("EPISODE_REPLAY_PROBE_OK ", record["episode_id"])
	quit(0)
