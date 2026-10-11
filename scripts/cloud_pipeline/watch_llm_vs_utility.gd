extends Node
const CommanderMissionCls = preload("res://scripts/cloud_pipeline/commander_mission.gd")

## DEV INSPECTION: watch LLM (RED) vs generalized Utility (BLUE) play one real EpisodeSpec, live.
##
## RED  = the production full pipeline mounted by Cloud2LiveMount (brain_mode full_pipeline_v0):
##        local Brain S0B (LOCAL_BRAIN_ADAPTER=s0b) with BRAIN_CONTEXT_PACK=v0 -> frozen Hand A -> frozen Hand B.
## BLUE = UtilityLiveController with a GX_* profile (UtilityBotGeneralized), side "blue".
## Board: Step0 sandbox HQ vs HQ. Both sides read one installed rules overlay (movement/attack varied per match).
## This node only sequences phases and shows a small HUD. It decides nothing.
##
## Keys: N next match (next seed, family cycles) | R replay same match | 1/2/3 GX tier BASIC/INTER/ADV |
##       S cycle GX style | Esc back to title.

const SCENE := "res://scenes/watch_llm_vs_utility.tscn"
const TITLE_SCENE := "res://scenes/title_screen.tscn"
const SpecCls = preload("res://scripts/episodes/episode_spec.gd")
const RuntimeCls = preload("res://scripts/episodes/episode_runtime.gd")
const LocalBrainCls = preload("res://scripts/cloud2/cloud2_local_brain_launcher.gd")
const UtilityControllerCls = preload("res://scripts/utility_bot/utility_live_controller.gd")
const CommanderCls = preload("res://scripts/cloud_pipeline/commander_controller.gd")
## Mission maps (2026-10-09): WATCH_MISSION_MAP=<generated map file> plays that map (not the Step0 sandbox); MissionRules
## judges the match (both sides) and the GX sides are the mission-aware GX.
const MissionRulesCls = preload("res://scripts/gx_missions/mission_rules.gd")
const MissionGxCls = preload("res://scripts/gx_missions/mission_gx_controller.gd")
const FAMILIES := ["nominal", "mild", "broad", "counterfactual_valid"]
const TIERS := ["BASIC", "INTER", "ADV"]
const STYLES := ["SPEARHEAD", "BULWARK", "OUTRIDER", "HARRIER"]
const META := "watch_llm_vs_utility"
const LOG_PATH := "user://watch/matches.jsonl"
const PHASE_PAUSE_S := 0.6
## Optional turn cap (env WATCH_TURN_CAP, used by the RL loop); 0/unset = play to the normal terminal result.
var turn_cap := 0
var match_finished := false
## Large battles (user 2026-10-08): with ROUT_MIN_UNITS or more units per side (HQ included) at the start, a side
## also loses at once when ROUT_SHARE of its non-HQ units are destroyed. win_rule = "hq" | "rout" | "".
const ROUT_MIN_UNITS := 17
const ROUT_SHARE := 0.6
var rout_rule := false
var win_rule := ""
var mission_map := ""
var mission_rules: Node = null
var _rout_start := {}
var aborted := false
var capped := false
## Strict Brain-contract fault latched (invalid opening plan or, with WATCH_STRICT_REVIEWS=1, invalid review).
var invalid := false

var shell: Node
var mount: Node
var gx: Node
## COMMANDER mode (env WATCH_RED_MODE=COMMANDER, dev/RL only): the Brain commands RED units directly.
var red_cmd: Node = null
## Dev modes (2026-10-08) for prediction data, both sides recorded:
##   WATCH_RED_MODE=GX        RED is played by the GX Utility bot (match tier; style WATCH_RED_GX_STYLE, default the
##                            match's) instead of the Brain.
##   WATCH_BLUE_MODE=COMMANDER BLUE is a second commander (its own endpoint WATCH_CMD_URL_BLUE) instead of GX.
## GX vs GX = RED GX + BLUE GX; GX vs cloud = RED COMMANDER + BLUE GX; cloud vs cloud = both COMMANDER.
var red_gx: Node = null
## Dev-only, default off: switch before RED acts on this one-based round.
var red_handoff_turn := 0
var red_handoff_actual := 0
var blue_cmd: Node = null
var _prev_env := {}
var _hud: Label
var _stage := "Starting servers..."
var _result_logged := false
var _cfg := {}


## Start (or restart) a watched match on the Step0 sandbox HQ-vs-HQ field (10v10, flat, full information).
## Track B's sampler is used ONLY for the per-match rule variation: each class's movement (base_mp) and
## attack (class_stats[*].attack). Map, armies, defense, range, matchup and terrain stay stock.
static func start_match(tree: SceneTree, family: String, seed: int, tier: String, style: String) -> void:
	# DEV curriculum: family "fixed" = stock movement/attack (no per-match variation; spec sampled for metadata only).
	var fixed := family == "fixed"
	# The previous match's overlay is still installed here, and the stock-rule readers (base movement) read it:
	# without this, each match re-jittered the last one's rules and a game was not reproducible from its seed.
	RuntimeCls.clear()
	var spec := SpecCls.sample("mild" if fixed else family, "train", seed)
	if spec.is_empty():
		push_error("[Watch] EpisodeSpec.sample failed for %s/%d" % [family, seed])
		return
	var overlay := sandbox_overlay(spec, fixed)
	# WATCH_OVERLAY_FILE (replays): play with the original game's exact rules instead of the sampled ones.
	var replay_file := OS.get_environment("WATCH_OVERLAY_FILE").strip_edges()
	if not replay_file.is_empty():
		var orig: Variant = JSON.parse_string(FileAccess.get_file_as_string(replay_file))
		if orig is Dictionary and not (orig as Dictionary).is_empty():
			overlay = orig
		else:
			push_error("[Watch] replay overlay unreadable: " + replay_file)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://watch"))
	# WATCH_SPEC_TAG (RL arenas): one spec file per window, so request provenance tells the games apart.
	var spec_tag := OS.get_environment("WATCH_SPEC_TAG").strip_edges()
	var path := "user://watch/sandbox_%s_%d%s.json" % [family, seed, ("_" + spec_tag) if not spec_tag.is_empty() else ""]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("[Watch] cannot write " + path)
		return
	f.store_string(JSON.stringify(overlay, "  ", true))
	f.close()
	tree.root.set_meta(META, {"family": family, "seed": seed, "tier": tier, "style": style, "spec_path": path, "overlay": overlay})
	tree.change_scene_to_file(SCENE)  # the driver installs the overlay in _enter_tree


## Sandbox runtime snapshot: stock rules + the sampled spec's movement and attack only.
static func sandbox_overlay(spec: Dictionary, fixed: bool = false) -> Dictionary:
	var rules := SpecCls.base_rules()
	var src: Dictionary = spec["rules"] if not fixed else {"base_mp": {}, "class_stats": {}}
	for cls in rules["base_mp"].keys():
		if (src["base_mp"] as Dictionary).has(cls):
			rules["base_mp"][cls] = float(src["base_mp"][cls])
		if (src["class_stats"] as Dictionary).has(cls):
			rules["class_stats"][cls]["attack"] = float(src["class_stats"][cls]["attack"])
	var out := {
		"episode_id": ("sbxF_" if fixed else "sbx_") + str(spec["episode_id"]), "family": "fixed" if fixed else spec["family"], "split": spec["split"],
		"seeds": (spec.get("seeds", {}) as Dictionary).duplicate(true),
		"objective": (spec["objective"] as Dictionary).duplicate(true),
		"map": {"id": "STEP0_SANDBOX"}, "rules": rules,
		"variation": {"base_mp": rules["base_mp"].duplicate(true),
			"attack": rules["class_stats"].keys().map(func(c): return [c, rules["class_stats"][c]["attack"]])},
	}
	# WATCH_RANDOM_ROSTER=1 (2026-10-08): both sides get the same seeded random army instead of the stock 10v10.
	if OS.get_environment("WATCH_RANDOM_ROSTER") == "1":
		var sizes := OS.get_environment("WATCH_ROSTER_SIZES")
		out["roster"] = random_roster(int((spec.get("seeds", {}) as Dictionary).get("sample", 0)), sizes)
		if sizes.contains("-"):  # a size range (e.g. 3-50): any class mix, the spread layout (no 24-slot limit)
			out["roster_layout"] = "spread"
		out["episode_id"] = str(out["episode_id"]) + "_r" + "".join((out["roster"] as Dictionary).keys().map(
			func(c): return "%s%d" % [str(c).substr(0, 2), int(out["roster"][c])]))
	return out


## Army for both sides: HQ + 5..15 units, at most 4 per class (the Step0 deployment slots never collide then),
## class weights as the stock 10v10 (infantry, spearman, archer, cavalry 2 each, scout 1). Seeded, so a replay
## of the same overlay gets the same army.
## sizes: "6,7,14" = allowed units per side INCLUDING the HQ (empty: any of 6..16); "3-50" = a range (no per-class
## cap: deployed with the shell's spread layout).
static func random_roster(seed: int, sizes: String = "") -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed * 7919 + 17
	var classes := ["infantry", "spearman", "archer", "cavalry", "scout"]
	var weights := [2.0, 2.0, 2.0, 2.0, 1.0]
	var counts := {"hq": 1}
	for c in classes:
		counts[c] = 0
	var n := rng.randi_range(5, 15)
	var allowed: Array = []
	var cap := 4
	for x in sizes.split(",", false):
		var part := x.strip_edges()
		if part.contains("-"):
			var lo := int(part.get_slice("-", 0))
			var hi := int(part.get_slice("-", 1))
			for k in range(maxi(2, lo), mini(100, hi) + 1):
				allowed.append(k - 1)
			cap = 1000
		elif part.is_valid_int() and int(part) >= 6 and int(part) <= 16:
			allowed.append(int(part) - 1)
	if not allowed.is_empty():
		n = int(allowed[rng.randi_range(0, allowed.size() - 1)])
	while n > 0:
		var total := 0.0
		for i in classes.size():
			total += weights[i] if int(counts[classes[i]]) < cap else 0.0
		var roll := rng.randf() * total
		for i in classes.size():
			var w: float = weights[i] if int(counts[classes[i]]) < cap else 0.0
			if roll < w:
				counts[classes[i]] = int(counts[classes[i]]) + 1
				break
			roll -= w
		n -= 1
	return counts


func _enter_tree() -> void:
	# Runs after the previous scene's _exit_tree and before the Battle shell's _ready. The shell keeps its
	# Step0 sandbox default (no episode_spec_path), and every rule accessor reads this installed overlay.
	var cfg: Dictionary = get_tree().root.get_meta(META, {})
	if not (cfg.get("overlay", {}) as Dictionary).is_empty():
		RuntimeCls.install(cfg["overlay"], str(cfg.get("spec_path", "")))
	# Before Cloud2LiveMount boots the local Brain: select S0B and turn the context pack on (restored on exit).
	for k in ["LOCAL_BRAIN_ADAPTER", "BRAIN_CONTEXT_PACK", "BRAIN_STRATEGIC_REPLAN_TURNS"]:
		_prev_env[k] = OS.get_environment(k)
	# WATCH_BRAIN_ADAPTER lets the RL loop point the same scene at its live policy server ("rl_policy").
	var adapter := OS.get_environment("WATCH_BRAIN_ADAPTER").strip_edges()
	OS.set_environment("LOCAL_BRAIN_ADAPTER", adapter if not adapter.is_empty() else "s0b")
	OS.set_environment("BRAIN_CONTEXT_PACK", "v0")
	# Forced strategic replan every 10 turns (user, 2026-10-04); WATCH_STRATEGIC_REPLAN_TURNS overrides (0 = off).
	var every := OS.get_environment("WATCH_STRATEGIC_REPLAN_TURNS").strip_edges()
	OS.set_environment("BRAIN_STRATEGIC_REPLAN_TURNS", every if every.is_valid_int() else "10")
	# DEV watch only: flat top-down board (the tilted, HQ-anchored perspective view only ever frames the
	# area around the own HQ). Set on the Battle node before its _ready reads it; game defaults untouched.
	var battle := get_parent().get_node_or_null("Battle") if get_parent() != null else null
	if battle != null and DisplayServer.get_name() != "headless":
		battle.set("present_perspective", false)
	mission_map = OS.get_environment("WATCH_MISSION_MAP").strip_edges()
	if battle != null and not mission_map.is_empty():  # before the shell's _ready: load the map, not the sandbox
		battle.set("is_step0_sandbox", false)
		battle.set("battlefield_id", "@" + mission_map)
		battle.set("no_fog", true)  # user 2026-10-09: fog and morale off on mission maps


func _exit_tree() -> void:
	RuntimeCls.clear()
	for k in _prev_env.keys():
		OS.set_environment(k, str(_prev_env[k]))
	if shell != null and is_instance_valid(shell):
		shell.set("symmetric_auto_lock", false)


func _ready() -> void:
	var tree := get_tree()
	_cfg = tree.root.get_meta(META, {"family": "mild", "seed": 1, "tier": "INTER", "style": "BULWARK", "spec_path": ""})
	call_deferred("_run")


## DEV curriculum tiers below BASIC: STATIC (BLUE never acts) and PASSIVE (BLUE attacks only what is in
## range, never moves). Both run on the GX BASIC profile.
func _profile_id() -> String:
	var t := str(_cfg["tier"])
	return "GX_%s_%s" % ["BASIC" if t in ["STATIC", "PASSIVE"] else t, _cfg["style"]]


func _run() -> void:
	shell = get_parent().get_node_or_null("Battle")
	mount = get_parent().get_node_or_null("Cloud2LiveMount")
	_build_hud()
	_widest_camera()
	call_deferred("_widest_camera")  # the shell may finish its own camera setup a frame later
	if RuntimeCls.episode_id().is_empty():
		_stage = "NO EPISODE INSTALLED (start from the title entry or press N)"
		_abort()
		return
	# Wait for the RED pipeline mount, then both owned model servers (Brain + Hands) to be READY.
	while mount != null and not bool(mount.get("mount_ready")) and str(mount.get("mount_error")).is_empty():
		await get_tree().process_frame
	if mount == null or not bool(mount.get("mount_ready")):
		_stage = "RED pipeline mount failed: %s" % (str(mount.get("mount_error")) if mount != null else "no mount")
		_abort()
		return
	var ctl: Node = mount.get("cloud_controller")
	var boot_deadline := Time.get_ticks_msec() + 360000
	while true:
		if Time.get_ticks_msec() > boot_deadline:
			_stage = "SERVER BOOT TIMEOUT (6 min): " + _stage
			_abort()
			return
		var svc: Dictionary = ((ctl.call("laya_stats") as Dictionary).get("service", {}) as Dictionary)
		var brain_status := str(LocalBrainCls.status_snapshot().get("status", ""))
		var conn := str((mount.get("cloud_config") as Object).get("connection_status"))
		_stage = "Starting servers... Hands=%s Brain=%s/%s" % [str(svc.get("status", "?")), brain_status, conn]
		if brain_status == "DISABLED" or str(svc.get("status", "")) == "DISABLED":
			_stage = "SERVER DISABLED: brain=%s hands=%s" % [str(LocalBrainCls.status_snapshot().get("error", "")), str(svc.get("last_error", ""))]
			_abort()
			return
		if str(svc.get("status", "")) == "READY" and conn == "CONNECTED":
			break
		await get_tree().create_timer(0.5).timeout
	if not mission_map.is_empty():
		var bf: Dictionary = shell.get("_battlefield")
		if bf.is_empty() or not bf.has("mission"):
			_stage = "MISSION MAP failed to load: " + mission_map
			_abort()
			return
		mission_rules = MissionRulesCls.new()
		mission_rules.name = "MissionRules"
		add_child(mission_rules)
		var ms: Dictionary = mission_rules.call("setup", shell, bf["mission"])
		if not bool(ms.get("ok", false)):
			_stage = "MissionRules setup failed: " + str(ms.get("error", "?"))
			_abort()
			return
	# BLUE: generalized Utility (or, WATCH_BLUE_MODE=COMMANDER, a BLUE commander), same live shell / same spec.
	var blue_commander := OS.get_environment("WATCH_BLUE_MODE").strip_edges().to_upper() == "COMMANDER"
	gx = CommanderCls.new() if blue_commander else (MissionGxCls.new() if mission_rules != null else UtilityControllerCls.new())
	gx.set("mission_rules", mission_rules)
	gx.name = "WatchCommanderBlue" if blue_commander else "WatchGxBlue"
	if blue_commander:
		blue_cmd = gx
		var blue_url := OS.get_environment("WATCH_CMD_URL_BLUE").strip_edges()
		if not blue_url.is_empty():
			gx.set("cmd_url", blue_url)
	gx.set("auto_mount", false)
	gx.set("side", "blue")
	gx.set("dev_difficulty", _profile_id())
	gx.set("dev_passive", str(_cfg["tier"]) == "PASSIVE")
	add_child(gx)
	var bound: Dictionary = gx.call("bind_live", shell, shell.get_node("Step7Integration"), false)
	if not bool(bound.get("ok", false)):
		_stage = "BLUE GX bind failed: %s" % str(bound.get("error", "?"))
		_abort()
		return
	if OS.get_environment("WATCH_RED_MODE").strip_edges().to_upper() == "COMMANDER":
		red_cmd = CommanderCls.new()
		red_cmd.name = "WatchCommanderRed"
		red_cmd.set("dev_difficulty", "GX_BASIC_BULWARK")
		red_cmd.set("mission_rules", mission_rules)
		add_child(red_cmd)
		var cb: Dictionary = red_cmd.call("bind_live", shell, shell.get_node("Step7Integration"), true)
		if not bool(cb.get("ok", false)):
			_stage = "COMMANDER bind failed: %s" % str(cb.get("error", "?"))
			_abort()
			return
		red_cmd.set("opponent", gx)  # the Brain's battle history includes the opponent's (seen) actions
	elif OS.get_environment("WATCH_RED_MODE").strip_edges().to_upper() == "GX":
		red_gx = MissionGxCls.new() if mission_rules != null else UtilityControllerCls.new()
		red_gx.set("mission_rules", mission_rules)
		red_gx.name = "WatchGxRed"
		red_gx.set("auto_mount", false)
		# GX vs GX: RED's own style (WATCH_RED_GX_STYLE), same tier as the match.
		var red_style := OS.get_environment("WATCH_RED_GX_STYLE").strip_edges().to_upper()
		# "<TIER>_<STYLE>" (2026-10-09, GX quality ladder): RED's own tier too.
		if "_" in red_style:
			red_gx.set("dev_difficulty", "GX_" + red_style)
		else:
			red_gx.set("dev_difficulty", _profile_id() if red_style.is_empty() else _profile_id().rsplit("_", true, 1)[0] + "_" + red_style)
		add_child(red_gx)
		var rb: Dictionary = red_gx.call("bind_live", shell, shell.get_node("Step7Integration"), true)
		if not bool(rb.get("ok", false)):
			_stage = "RED GX bind failed: %s" % str(rb.get("error", "?"))
			_abort()
			return
	if blue_cmd != null:
		blue_cmd.set("opponent", red_cmd if red_cmd != null else red_gx)
	_init_rout()
	_log_match("START")
	var next_button := shell.get("next_turn_button") as Button
	if next_button != null:
		next_button.disabled = true
	turn_cap = int(OS.get_environment("WATCH_TURN_CAP")) if OS.get_environment("WATCH_TURN_CAP").is_valid_int() else 0
	red_handoff_turn = maxi(0, int(OS.get_environment("WATCH_RED_HANDOFF_TURN")))
	var pause := 0.0 if (turn_cap > 0 and DisplayServer.get_name() == "headless") else PHASE_PAUSE_S
	# RL (dev only): an invalid review ends the game exactly like an invalid opening plan.
	if OS.get_environment("WATCH_STRICT_REVIEWS") == "1":
		ctl.set("strict_latch_reviews", true)
	while not _over():
		_widest_camera()  # re-frame the whole board every round (combat focus pans the camera)
		if _faulted(ctl):
			invalid = true
			break
		if turn_cap > 0 and int((shell.get("unit_manager") as RefCounted).call("get_current_turn")) > turn_cap:
			capped = true
			break
		while not _over() and int(shell.get("_turn_phase")) != 0:
			_stage = "RED (LLM) acting..."
			await get_tree().process_frame
		if _over():
			break
		var round_no := int((shell.get("unit_manager") as RefCounted).call("get_current_turn"))
		_stage = "BLUE (%s) acting..." % ("COMMANDER" if blue_cmd != null else _profile_id())
		if str(_cfg["tier"]) != "STATIC":
			shell.set("symmetric_auto_lock", true)
			await gx.call("run_side_phase")
			shell.set("symmetric_auto_lock", false)
		_check_rout()
		if _over():
			break
		await get_tree().create_timer(maxf(pause, 0.01)).timeout
		_stage = "RED (LLM) acting..."
		if red_cmd != null and red_gx == null and red_handoff_turn > 0 and round_no >= red_handoff_turn:
			# BLUE has finished round N; replacing the shell controller here makes GX's first RED phase N.
			red_gx = UtilityControllerCls.new()
			red_gx.name = "WatchGxRedHandoff"
			red_gx.set("auto_mount", false)
			red_gx.set("dev_difficulty", "GX_INTER_BULWARK")
			add_child(red_gx)
			var hb: Dictionary = red_gx.call("bind_live", shell, shell.get_node("Step7Integration"), true)
			if not bool(hb.get("ok", false)):
				_stage = "RED GX handoff bind failed: " + str(hb.get("error", "?"))
				_abort()
				return
			red_handoff_actual = round_no
		await shell.call("end_player_phase")
		_check_rout()
		if mission_rules != null and not _over():  # end of round: the mission judge (drives the shell's end flags)
			var mo: Dictionary = mission_rules.call("evaluate_round", round_no)
			if not mo.is_empty():
				win_rule = "mission:" + str(mo.get("reason", ""))
				# A decided mission ends the match even without a winner (round-limit stalemate: no shell end flag is
				# set, and the match went on to the arena cap with both sides idle).
				break
		if _faulted(ctl):
			invalid = true
			break
		await get_tree().create_timer(maxf(pause, 0.01)).timeout
	if invalid:
		_stage = "INVALID BRAIN OUTPUT: %s" % JSON.stringify(ctl.call("strict_fault"))
	else:
		_stage = ("TURN CAP %d reached" % turn_cap) if capped else "BATTLE OVER: %s   (N next match, R replay, Esc title)" % _result_text()
	_log_match("END")
	match_finished = true


## Setup failure: end the match visibly (the RL runner and the HUD both see it) instead of hanging.
func _abort() -> void:
	aborted = true
	push_error("[Watch] " + _stage)
	print("[Watch] ABORT " + _stage)
	match_finished = true


func _faulted(ctl: Node) -> bool:
	if blue_cmd != null and not (blue_cmd.call("strict_fault") as Dictionary).is_empty():
		return true
	if red_cmd != null:
		return not (red_cmd.call("strict_fault") as Dictionary).is_empty()
	if red_gx != null:
		return false
	return ctl != null and ctl.has_method("strict_fault") and not (ctl.call("strict_fault") as Dictionary).is_empty()


func _alive_non_hq() -> Dictionary:
	var out := {"red": 0, "blue": 0}
	for u in (shell.get("unit_manager") as RefCounted).call("get_all_units_including_garrisoned"):
		var f := str(u.get("faction", ""))
		if out.has(f) and str(u.get("class", "")) != "hq" and int(u.get("soldier_count", 0)) > 0:
			out[f] += 1
	return out


func _init_rout() -> void:
	_rout_start = _alive_non_hq()
	var min_units := int(OS.get_environment("WATCH_ROUT_MIN")) if OS.get_environment("WATCH_ROUT_MIN").is_valid_int() else ROUT_MIN_UNITS
	rout_rule = CommanderMissionCls.enabled() or (int(_rout_start["red"]) + 1 >= min_units and int(_rout_start["blue"]) + 1 >= min_units)
	for c in [red_cmd, blue_cmd]:
		if c != null:
			c.set("rout_rule", rout_rule)


## A routed side loses: the shell's own end flags (BLUE point of view: _battle_won = BLUE wins).
func _check_rout() -> void:
	if _over():
		win_rule = "hq" if win_rule.is_empty() else win_rule
		return
	if not rout_rule:
		return
	var alive := _alive_non_hq()
	for side in ["blue", "red"]:
		var start := int(_rout_start[side])
		if start > 0 and start - int(alive[side]) >= int(ceil(CommanderMissionCls.share(ROUT_SHARE) * start)):
			win_rule = "rout"
			shell.set("_battle_lost" if side == "blue" else "_battle_won", true)
			print("[Watch] ROUT: %s lost %d of %d units" % [side, start - int(alive[side]), start])
			return


func _over() -> bool:
	return shell != null and shell.has_method("_battle_over") and bool(shell.call("_battle_over"))


func _result_text() -> String:
	if not _over():
		return "ongoing"
	# Shell flags are from the BLUE (player) point of view.
	if bool(shell.get("_battle_won")):
		return "BLUE (GX Utility) WINS"
	if bool(shell.get("_battle_lost")):
		return "RED (LLM) WINS"
	return "ended"


func _log_match(event: String) -> void:
	var row := {"event": event, "at": Time.get_datetime_string_from_system(), "result": _result_text(),
		"turn": int((shell.get("unit_manager") as RefCounted).call("get_current_turn")),
		"episode": RuntimeCls.launch_record(), "spec_path_abs": ProjectSettings.globalize_path(str(_cfg.get("spec_path", ""))),
		"gx_profile": (gx.get("bot") as RefCounted).call("profile") if gx != null else {},
		"brain": LocalBrainCls.status_snapshot(),
		"hands": ((mount.get("cloud_controller").call("laya_stats") as Dictionary).get("service", {}) as Dictionary).get("worker_identity", {})}
	var f := FileAccess.open(LOG_PATH, FileAccess.READ_WRITE if FileAccess.file_exists(LOG_PATH) else FileAccess.WRITE)
	if f != null:
		f.seek_end()
		f.store_line(JSON.stringify(row))
		f.close()
	print("[Watch] %s %s" % [event, JSON.stringify(row)])


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var k := (event as InputEventKey).keycode
	var fam_i := FAMILIES.find(str(_cfg["family"]))
	match k:
		KEY_N:
			start_match(get_tree(), FAMILIES[(fam_i + 1) % FAMILIES.size()], int(_cfg["seed"]) + 1, str(_cfg["tier"]), str(_cfg["style"]))
		KEY_R:
			start_match(get_tree(), str(_cfg["family"]), int(_cfg["seed"]), str(_cfg["tier"]), str(_cfg["style"]))
		KEY_1, KEY_2, KEY_3:
			_cfg["tier"] = TIERS[k - KEY_1]
			_stage = "GX tier set to %s for the NEXT match (press N or R)" % _cfg["tier"]
		KEY_S:
			_cfg["style"] = STYLES[(STYLES.find(str(_cfg["style"])) + 1) % STYLES.size()]
			_stage = "GX style set to %s for the NEXT match (press N or R)" % _cfg["style"]
		KEY_ESCAPE:
			get_tree().change_scene_to_file(TITLE_SCENE)


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 50
	add_child(layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(8, 8)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.06, 0.08, 0.82)
	style.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", style)
	_hud = Label.new()
	_hud.add_theme_font_size_override("font_size", 13)
	_hud.add_theme_color_override("font_color", Color(0.88, 0.92, 0.9))
	panel.add_child(_hud)
	layer.add_child(panel)
	var timer := Timer.new()
	timer.wait_time = 0.5
	timer.autostart = true
	timer.timeout.connect(_refresh_hud)
	add_child(timer)
	_refresh_hud()


func _refresh_hud() -> void:
	if _hud == null:
		return
	var b := LocalBrainCls.status_snapshot()
	var ep := RuntimeCls.launch_record()
	var lines: Array = ["DEV WATCH — LLM vs Utility   [N next · R replay · 1/2/3 tier · S style · Esc title]"]
	lines.append("RED  = LLM %s (adapter %s…) · context pack %s → Hand A → Hand B" % [str(b.get("label", "?")),
		str(b.get("adapter_sha256", "")).left(8), "ON" if OS.get_environment("BRAIN_CONTEXT_PACK") == "v0" else "OFF"])
	var prof: Dictionary = (gx.get("bot") as RefCounted).call("profile") if gx != null else {}
	lines.append("BLUE = GX Utility %s · seed %s" % [str(prof.get("profile_id", _profile_id())), str(prof.get("seed", "?"))])
	lines.append("Episode %s · %s/%s · map %s · seed %s" % [str(ep.get("episode_id", "-")).left(12), str(ep.get("family", "?")),
		str(ep.get("split", "?")), str(ep.get("map", "?")), str(_cfg.get("seed", "?"))])
	var rr := RuntimeCls.rules()
	if not rr.is_empty():
		var parts: Array = []
		for c in ["infantry", "spear", "archer", "cavalry", "scout"]:
			if (rr["base_mp"] as Dictionary).has(c):
				parts.append("%s mv%d atk%d" % [c, int(rr["base_mp"][c]), int(rr["class_stats"][c]["attack"])])
		lines.append("Rules: " + " · ".join(PackedStringArray(parts)))
	if shell != null and shell.get("unit_manager") != null:
		lines.append("Turn %d" % int((shell.get("unit_manager") as RefCounted).call("get_current_turn")))
	var ctl: Node = mount.get("cloud_controller") if mount != null else null
	var mgr: RefCounted = ctl.get("_manager") if ctl != null else null
	if mgr != null and mgr.has_method("vp_get_plan"):
		var vp: Dictionary = mgr.call("vp_get_plan")
		if not vp.is_empty() and vp.has("phases"):
			lines.append("LLM plan v%d · phase %s" % [int(vp.get("revision", 0)), str(vp.get("current_phase_id", "?"))])
			for ph in vp.get("phases", []):
				if str((ph as Dictionary).get("phase_id", "")) == str(vp.get("current_phase_id", "")):
					for m in (ph as Dictionary).get("missions", []):
						var o: Dictionary = (m as Dictionary).get("objective", {})
						lines.append("   %s %s %s %s" % [str(m.get("mission_id", "")), str(m.get("task", "")), str(m.get("area", "")),
							("vs " + str(o.get("class", ""))) if str(o.get("class", "")) != "" else ""])
		else:
			lines.append("LLM plan: (being drafted)")
	if gx != null:
		lines.append("Last GX action: %s" % str(gx.get("last_action")))
	lines.append(_stage if not _over() else "RESULT: " + _result_text())
	_hud.text = "\n".join(lines)


## DEV watch only: every match opens at the WIDEST view of the whole board (the user inspects the full
## game without scrolling out each round). The game's own camera defaults are untouched.
func _widest_camera() -> void:
	var cam: Camera2D = shell.get("camera") as Camera2D if shell != null and is_instance_valid(shell) else null
	if cam == null:
		return
	var m: Vector2 = cam.get("_bounds_margin")  # bounds include the pan margin: fit the board itself
	var lo: Vector2 = cam.get("_map_min") + m
	var hi: Vector2 = cam.get("_map_max") - m
	if hi.x <= lo.x or hi.y <= lo.y:  # no bounds yet: plain widest zoom
		cam.call("set_zoom_level", float(cam.get("min_zoom")), true)
		cam.call("focus_on", Vector2.ZERO, true)
		return
	# Fit the whole (possibly rotated) board into the window.
	var size := hi - lo
	var rot := cam.rotation if not cam.ignore_rotation else 0.0
	var w := absf(size.x * cos(rot)) + absf(size.y * sin(rot))
	var h := absf(size.x * sin(rot)) + absf(size.y * cos(rot))
	var vp := get_viewport().get_visible_rect().size
	var fit := minf(vp.x / w, vp.y / h)
	cam.set("min_zoom", minf(float(cam.get("min_zoom")), fit))
	cam.call("set_zoom_level", fit, true)
	cam.call("focus_on", (lo + hi) * 0.5, true)
