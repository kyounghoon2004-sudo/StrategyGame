extends SceneTree

## GX MISSIONS v1 — minimal tests 3 + 4 (deterministic seeds, isolated fixtures).
##   3. Mission GX per family on the same normal 10v10 start: one short GX-vs-GX run each, action mix + intents.
##   4. HQ opportunity: exposed reachable HQ -> GX takes it; normal start in all five families -> no HQ race.
## godot --headless --path <proj> -s res://tools/gx_missions_dev/test_gx_missions.gd [-- --rounds=N --profile=GX_ADV_SPEARHEAD]

const HarnessCls = preload("res://tools/gx_missions_dev/gx_missions_harness.gd")

const FAMILY_INTENTS := {"M1": ["TAKE_AREA", "DEFEND_AREA"], "M2": ["HOLD_FORTRESS", "SIEGE_WALL", "EXPLOIT_BREACH"],
	"M3": ["FIELD_CONCENTRATE", "ELIMINATE_HIGH_VALUE", "BREAK_SCREEN"], "M4": ["BUILD_BASE", "CONTEST_SITE", "RAID_BASE"],
	"M5": ["HOLD_FORTRESS", "SIEGE_WALL", "EXPLOIT_BREACH"]}

var results: Array = []


func _initialize() -> void:
	call_deferred("_run")


func _arg(name: String, dflt: String) -> String:
	for a in OS.get_cmdline_user_args():
		if str(a).begins_with("--%s=" % name):
			return str(a).substr(name.length() + 3)
	return dflt


func _check(name: String, ok: bool, detail: Variant = "") -> void:
	results.append({"test": name, "pass": ok, "detail": detail})
	print("[GxMissionsTest] %s %s %s" % ["PASS" if ok else "FAIL", name, JSON.stringify(detail)])


func _play(fixture_key: String, profile: String, rounds: int, seed: int) -> Dictionary:
	var h: Node = HarnessCls.new()
	h.name = "GxTest_" + fixture_key
	root.add_child(h)
	current_scene = h
	var booted: Dictionary = await h.call("boot", HarnessCls.load_fixture(fixture_key),
		{"blue_profile": profile, "red_profile": profile, "blue_seed": seed, "red_seed": seed + 1})
	var summ: Dictionary = {}
	if bool(booted.get("ok", false)):
		summ = await h.call("play", rounds)
		h.call("write_outputs", "test_%s" % fixture_key.to_lower(), summ)
	else:
		summ = {"error": booted.get("error", "?")}
	h.queue_free()
	for _i in range(4):
		await process_frame
	return summ


func _mix(actions: Dictionary) -> Dictionary:
	var total := 0
	for k in actions.keys():
		if str(k) != "ATTACK_HQ":
			total += int(actions[k])
	var out := {}
	for k in actions.keys():
		if str(k) != "ATTACK_HQ":
			out[k] = snappedf(float(actions[k]) / float(maxi(1, total)), 0.01)
	return out


func _run() -> void:
	var rounds := int(_arg("rounds", "8"))
	var profile := _arg("profile", "GX_ADV_SPEARHEAD").to_upper()
	var seed := int(_arg("seed", "7"))
	var per_family := {}
	var sigs := {}
	var no_race := true
	var race_detail := {}
	for fam in ["M1", "M2", "M3", "M4", "M5"]:
		var s: Dictionary = await _play(fam, profile, rounds, seed)
		if s.has("error"):
			_check("gx_family_%s" % fam, false, s)
			continue
		var acts: Dictionary = s["actions"]
		var intents: Dictionary = s["intents"]
		var mix := {"blue": _mix(acts["blue"]), "red": _mix(acts["red"])}
		per_family[fam] = {"actions": acts, "mix": mix, "intents": intents, "outcome": s["outcome"]}
		sigs[fam] = JSON.stringify(mix)
		# Mission intents present, HQ-race intents (PRESSURE_HQ / CONVERT_ADVANTAGE / EXPLOIT_FLANK) absent.
		var seen := false
		for side in ["blue", "red"]:
			for t in (intents[side] as Dictionary).keys():
				if str(t) in FAMILY_INTENTS[fam]:
					seen = true
				if str(t) in ["PRESSURE_HQ", "CONVERT_ADVANTAGE", "EXPLOIT_FLANK"]:
					seen = false
					break
		_check("gx_family_%s_mission_intents" % fam, seen, {"intents": intents, "mix": mix})
		var hq_turns := {"blue": (s["hq_strike_turns"]["blue"] as Dictionary).size(), "red": (s["hq_strike_turns"]["red"] as Dictionary).size()}
		var hq_atk := int((acts["blue"] as Dictionary).get("ATTACK_HQ", 0)) + int((acts["red"] as Dictionary).get("ATTACK_HQ", 0))
		race_detail[fam] = {"hq_strike_turns": hq_turns, "hq_attacks": hq_atk, "opp_max": s["hq_opportunity_max"]}
		if hq_turns["blue"] + hq_turns["red"] > 0 or hq_atk > 0:
			no_race = false
	var distinct := {}
	for f in sigs.keys():
		distinct[sigs[f]] = true
	_check("gx_families_behave_differently", per_family.size() == 5 and distinct.size() >= 4,
		{"distinct_mixes": distinct.size(), "per_family": per_family})
	_check("hq_no_race_normal_start", per_family.size() == 5 and no_race, race_detail)
	var ex: Dictionary = await _play("HQ_EXPOSED", profile, int(_arg("exposed_rounds", "4")), seed)
	var ok := false
	var det := {}
	if not ex.has("error"):
		var blue_open := (ex["hq_strike_turns"]["blue"] as Dictionary).size()
		var blue_hq_atk := int((ex["actions"]["blue"] as Dictionary).get("ATTACK_HQ", 0))
		var o: Dictionary = ex["outcome"]
		ok = blue_open > 0 and (blue_hq_atk > 0 or (str(o.get("winner", "")) == "blue" and str(o.get("reason", "")) == "hq_destroyed"))
		det = {"blue_hq_strike_turns": ex["hq_strike_turns"]["blue"], "blue_hq_attacks": blue_hq_atk, "outcome": o,
			"opp_max": ex["hq_opportunity_max"], "actions": ex["actions"]}
	else:
		det = ex
	_check("hq_exposed_taken", ok, det)
	var all_ok := true
	for r in results:
		all_ok = all_ok and bool(r["pass"])
	var out := {"suite": "gx_missions_gx_behaviour", "pass": all_ok, "profile": profile, "seed": seed, "rounds": rounds, "results": results}
	var dir := ProjectSettings.globalize_path("res://artifacts/gx_missions_dev")
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir + "/test_gx_missions.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(out, "  ", true))
		f.close()
	print("[GxMissionsTest] SUITE %s" % ("PASS" if all_ok else "FAIL"))
	quit(0 if all_ok else 1)
