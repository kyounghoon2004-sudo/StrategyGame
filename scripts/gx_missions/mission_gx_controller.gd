extends "res://scripts/utility_bot/utility_live_controller.gd"

## GX MISSIONS v1 — live controller for the mission-conditioned GX (subclass; base file untouched).
##   * bind_live: base bind, then swaps in MissionLegalEnumerator (+BUILD_BASE) and MissionGxBot
##     (same seed / same GX profile);
##   * _build_observation: real mission block + read-only mission_state + turn limit replace the
##     hard-coded destroy_<foe>_hq mission;
##   * _execute: BUILD_BASE goes to MissionRules (the authority); everything else is the base executor.

const MissionEnumCls = preload("res://scripts/gx_missions/mission_legal_enumerator.gd")
const MissionBotCls = preload("res://scripts/gx_missions/mission_gx_bot.gd")

var mission_rules: Node = null
var action_counts: Dictionary = {}
## DEV: per-side bot seed (-1 = the base resolution: episode seeds / UTILITY_BOT_SEED / 1).
var seed_override := -1


func bind_live(host_shell: Node, step7_node: Node, bind_as_red_controller: bool = false) -> Dictionary:
	var res: Dictionary = super.bind_live(host_shell, step7_node, bind_as_red_controller)
	if not bool(res.get("ok", false)):
		return res
	var en: RefCounted = MissionEnumCls.new()
	en.call("set_side", side)
	en.set("mission_rules", mission_rules)
	var err: String = en.call("configure", manager, service, projector, shell.get("hex_grid") as Node,
		shell.call("map_bounds") if shell.has_method("map_bounds") else {}, Callable(shell, "_battle_over"),
		shell.get("_river_cells") as Dictionary, shell.get("_stronghold_cells") as Dictionary)
	if not err.is_empty():
		mount_ready = false
		return {"ok": false, "error": "Mission enumerator: " + err}
	enumerator = en
	if seed_override >= 0:
		bot_seed = seed_override
		res["seed"] = bot_seed
	bot = MissionBotCls.new()
	bot.call("configure", bot_seed, str(dev_difficulty))
	res["profile"] = bot.call("profile")
	return res


func _build_observation() -> Dictionary:
	var obs: Dictionary = super._build_observation()
	if mission_rules == null:
		return obs
	var m: Dictionary = mission_rules.call("mission_for_side", side)
	obs["mission"] = m
	obs["mission_state"] = (mission_rules.get("mission_state") as Dictionary).duplicate(true)
	obs["turn_limit"] = int(m.get("turn_limit", 0))
	var st: Dictionary = obs["mission_state"].get("stronghold", {})
	obs["strongholds"] = [st] if not st.is_empty() else []
	# Garrisoned flag for friendly rows (MissionPolicy ignores units inside walls as field movers).
	for row in obs.get("friendly_units", []):
		var u: Dictionary = manager.call("get_unit_by_id", str(row.get("unit_id", "")))
		row["garrisoned"] = bool(u.get("garrisoned", false))
	return obs


func _execute(candidate: Dictionary) -> Dictionary:
	var kind := str(candidate.get("action_type", ""))
	var result: Dictionary
	if kind == "BUILD_BASE":
		result = mission_rules.call("build_base", str(candidate.get("unit_id", ""))) if mission_rules != null \
			else {"success": false, "code": "NO_MISSION_RULES"}
		if bool(result.get("success", false)):
			shell.call("_show_combat_log", "[%s] GX BUILD_BASE %s" % [str(candidate.get("unit_id", "")), str(result.get("base_id", ""))])
	else:
		result = await super._execute(candidate)
	if bool(result.get("success", false)):
		action_counts[kind] = int(action_counts.get(kind, 0)) + 1
		if kind == "ATTACK" and str(candidate.get("target_class", "")) == "hq":
			action_counts["ATTACK_HQ"] = int(action_counts.get("ATTACK_HQ", 0)) + 1
	return result
