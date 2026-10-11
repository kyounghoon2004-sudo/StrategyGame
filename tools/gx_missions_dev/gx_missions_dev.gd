extends SceneTree

## GX MISSIONS v1 — SEPARATE DEV MODE entry (GX vs GX on one mission family).
##   godot [--headless] --path <proj> -s res://tools/gx_missions_dev/gx_missions_dev.gd -- \
##       --mission=M1|M2|M3|M4|M5|HQ_EXPOSED|<fixture.json> [--tier=BASIC|INTER|ADV] [--style=SPEARHEAD|BULWARK|OUTRIDER|HARRIER]
##       [--red=GX_<tier>_<style>] [--blue=GX_<tier>_<style>] [--seed=N] [--rounds=N] [--morale=on|off] [--tag=name]
## Prints outcome + mission_state per round; writes artifacts/gx_missions_dev/<tag>_rounds.jsonl and <tag>_summary.json.
## Touches no arena folder, no port, no server, no training artifact.

const HarnessCls = preload("res://tools/gx_missions_dev/gx_missions_harness.gd")
const CfgCls = preload("res://scripts/gx_missions/mission_config.gd")


func _initialize() -> void:
	call_deferred("_run")


func _args() -> Dictionary:
	var out := {}
	for a in OS.get_cmdline_user_args():
		var s := str(a)
		if s.begins_with("--") and s.contains("="):
			out[s.substr(2, s.find("=") - 2)] = s.substr(s.find("=") + 1)
	return out


func _run() -> void:
	var a := _args()
	var mission := str(a.get("mission", "M3"))
	var tier := str(a.get("tier", "ADV")).to_upper()
	var style := str(a.get("style", "SPEARHEAD")).to_upper()
	var seed := int(a.get("seed", "1"))
	var rounds := int(a.get("rounds", str(int(CfgCls.num("dev", "rounds_cap_default")))))
	var opts := {"blue_profile": str(a.get("blue", "GX_%s_%s" % [tier, style])).to_upper(),
		"red_profile": str(a.get("red", "GX_%s_%s" % [tier, style])).to_upper(),
		"blue_seed": seed, "red_seed": seed + 1}
	if a.has("morale"):
		opts["morale"] = str(a["morale"]).to_lower() == "on"
	var fix: Dictionary = HarnessCls.load_fixture(mission)
	if fix.is_empty():
		print("[GxMissionsDev] FAIL unknown mission/fixture '%s'" % mission)
		quit(2)
		return
	var h: Node = HarnessCls.new()
	h.name = "GxMissionsDev"
	root.add_child(h)
	current_scene = h
	var booted: Dictionary = await h.call("boot", fix, opts)
	if not bool(booted.get("ok", false)):
		print("[GxMissionsDev] FAIL boot: %s" % str(booted.get("error", "?")))
		quit(3)
		return
	print("[GxMissionsDev] START %s" % JSON.stringify({"fixture": fix.get("fixture_id", ""), "mission": booted.get("mission", {}),
		"blue": opts["blue_profile"], "red": opts["red_profile"], "seed": seed, "rounds_cap": rounds}))
	var summ: Dictionary = await h.call("play", rounds)
	var tag := str(a.get("tag", "%s_%s_%s_s%d" % [str(fix.get("fixture_id", mission)), tier, style, seed]))
	var path: String = h.call("write_outputs", tag, summ)
	print("[GxMissionsDev] OUTCOME %s" % JSON.stringify(summ["outcome"]))
	print("[GxMissionsDev] ACTIONS %s" % JSON.stringify(summ["actions"]))
	print("[GxMissionsDev] SUMMARY %s" % path)
	if DisplayServer.get_name() != "headless":
		await create_timer(CfgCls.num("dev", "visible_hold_s")).timeout
	h.queue_free()
	await process_frame
	quit(0)
