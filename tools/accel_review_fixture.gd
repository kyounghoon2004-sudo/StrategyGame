extends SceneTree

## STAGE 2.5 — authoritative VICTORY_REVIEW fixture builder (static, offline).
##
## No live review fired in any real match (0 across real_e1..e5 + accel_long8),
## so no genuine review prompt was ever captured. This probe replays the
## PRODUCTION review path with a REAL adopted plan (real_e5 RED, first-try
## adopted) at turn 5:
##   parse_initial (authoring -> canonical) -> vp_apply_initial ->
##   build_victory_review_packet(PERIODIC_HORIZON) -> review_prompt_for(red)
##
## Provenance (see HANDOFF for the full table):
##   REAL: adopted plan body, mission contract, battle/scenario ids, roster,
##         friendly units, validator, packet builder v2, system prompt, budget.
##   DERIVED: turn-5 snapshot id, PERIODIC_HORIZON trigger (exact review_due
##         shape), turn-1 unit positions reused (quiet game, no combat).
##   EMPTY (authentic for the observed quiet games): events_since_review,
##         opponent_hypotheses (the adopted plan carried none).
##
## Usage (Windows):
##   Godot_v4.2.2-stable_win64_console.exe --headless --path "D:\Game development\Demon slayer\StrategyGame" -s res://tools/accel_review_fixture.gd
##
## Exit code 0 = fixture written, 1 = failure. No network is ever attempted.

const ManagerCls = preload("res://scripts/cloud2/cloud2_mission_manager.gd")
const ResponseCls = preload("res://scripts/cloud2/cloud2_victory_response.gd")

const IN_PLAN := "D:/StrategyAI/selfplay/artifacts/qwen35_inference_accel_v1/raw/accel_plan_red_e5.json"
const IN_INPUTS := "D:/StrategyAI/selfplay/artifacts/qwen35_inference_accel_v1/raw/accel_review_inputs.json"
const OUT_REQ := "D:/StrategyAI/selfplay/artifacts/qwen35_inference_accel_v1/raw/bench_prompt_B.json"
## Mirrors cloud2_turn_controller.VICTORY_REVIEW_MAX_TOKENS (const, 16384).
const REVIEW_MAX_TOKENS := 16384


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var plan_text := FileAccess.get_file_as_string(IN_PLAN)
	var inputs_text := FileAccess.get_file_as_string(IN_INPUTS)
	if plan_text.is_empty() or inputs_text.is_empty():
		printerr("[AccelFixture] missing input files")
		quit(1)
		return
	var inputs: Dictionary = JSON.parse_string(inputs_text)
	var roster: Array = inputs.get("roster", [])
	var mission: Dictionary = inputs.get("mission", {})
	var battle_id := str(inputs.get("battle_id", ""))
	var scenario_id := str(inputs.get("scenario_id", ""))

	# Production INITIAL adoption of the real model-authored body.
	var mgr: RefCounted = ManagerCls.new()
	var parsed: Dictionary = ResponseCls.parse_initial(plan_text, {"turn": 1, "roster": roster})
	if not bool(parsed.get("ok", false)):
		printerr("[AccelFixture] parse_initial failed: %s %s" % [str(parsed.get("code", "")), str(parsed.get("detail", ""))])
		quit(1)
		return
	var applied: Dictionary = mgr.vp_apply_initial(parsed.get("plan", {}), 1,
		"accel25_review_base_t1_RED", battle_id, "accel25/fixture")
	if not bool(applied.get("ok", false)):
		printerr("[AccelFixture] vp_apply_initial failed: %s" % str(applied.get("detail", "")))
		quit(1)
		return

	# Turn-5 review observation: real contract + real force, derived clock.
	var obs := {
		"ok": true, "turn": 5,
		"snapshot_id": "accel25_cloud_step1_neutral_skirmish_t5_RED_v0_derived",
		"battle_id": battle_id, "scenario_id": scenario_id, "side": "red",
		"mission": mission,
		"friendly_units": inputs.get("friendly_units", []),
		"known_enemy_units": inputs.get("known_enemy_units", []),
		"parity": {"state_version": 5, "acting_side": "RED"},
	}
	# Exact review_due() PERIODIC_HORIZON shape (cadence 4 from the plan).
	var trigger := {"trigger": "PERIODIC_HORIZON",
		"reason": "Review horizon reached (4 turns).", "turn": 5}
	var packet: Dictionary = mgr.build_victory_review_packet(obs, trigger)
	var sys_prompt := ResponseCls.review_prompt_for("red")
	var req := {
		"max_tokens": REVIEW_MAX_TOKENS,
		"messages": [
			{"role": "system", "content": sys_prompt},
			{"role": "user", "content": JSON.stringify(packet)},
		],
		"model": "Qwen/Qwen3.5-9B",
		"response_format": {"type": "json_object"},
		"stream": false,
		"temperature": 0.2,
		"_accel25_provenance": {
			"builder": "cloud2_general_packet.build_victory_review (production)",
			"packet_version": str(packet.get("packet_version", "")),
			"plan": "real_e5 RED adopted (first-try, cadence 4)",
			"trigger": "PERIODIC_HORIZON (exact review_due shape)",
			"snapshot_id": "DERIVED (no live turn-5 snapshot exists)",
			"events_since_review": "EMPTY (observed games are quiet)",
		},
	}
	var f := FileAccess.open(OUT_REQ, FileAccess.WRITE)
	if f == null:
		printerr("[AccelFixture] cannot write %s" % OUT_REQ)
		quit(1)
		return
	f.store_string(JSON.stringify(req, "\t"))
	f.close()
	print("[AccelFixture] OK packet_version=%s request=%s user_chars=%d phases_live=%d" % [
		str(packet.get("packet_version", "")), str(packet.get("request", "")),
		(JSON.stringify(packet) as String).length(),
		((packet.get("plan_live", {}) as Dictionary).get("mission_statuses", []) as Array).size()])
	quit(0)
