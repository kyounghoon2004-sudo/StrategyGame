extends SceneTree

## STEP-04R7.1 Acceptance Test & Evidence Generator
## Validates:
##   1. Unit REST Contract (unit_rest_contract.json)
##   2. Field FORTIFY Construction (field_fortify_contract.json)
##   3. Normal Defense Baseline (normal_defense_baseline.json)
##   4. Fortified Defense Resolution (fortified_defense_modifier.json)
##   5. One-Attack Scale Balance & Leakage (one_attack_scale_balance.json)
##   6. Fortify Eligibility Contract (fortify_eligibility_contract.json)
##   7. NEXT After REST/FORTIFY & Inspection (next_after_rest_fortify.json)
##   8. Turn Persistence & Hex Abandonment (field_fortification_persistence_abandon.json)

const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")
const CombatCalculatorCls = preload("res://scripts/combat/combat_calculator.gd")
const Step3ConfigCls = preload("res://scripts/core/step3_config.gd")

var _shell: Node2D
var _frame_count: int = 0
var _evidence_dir: String = "D:/Game development/Demon slayer/StrategyGame/evidence"

var _results: Dictionary = {}

func _initialize() -> void:
	root.size = Vector2i(1920, 1080)
	root.content_scale_size = Vector2i(1920, 1080)
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP

	var scene_res: PackedScene = load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene
	if scene_res == null:
		push_error("[VERIFY-R7] Failed to load battlefield shell scene")
		quit(1)
		return
	_shell = scene_res.instantiate() as Node2D
	root.add_child(_shell)
	DirAccess.make_dir_recursive_absolute(_evidence_dir)

func _process(_delta: float) -> bool:
	_frame_count += 1

	# Wait until scene nodes and shell _ready() complete
	if _frame_count == 3:
		print("\n==================================================")
		print("STARTING STEP-04R7 VERIFICATION SUITE")
		print("==================================================")

		var um: Step3UnitManager = _shell.get("unit_manager") as Step3UnitManager
		var ur = _shell.get("unit_renderer")

		# -------------------------------------------------------------
		# TEST 1: Unit REST Contract (§3, §4, §23)
		# -------------------------------------------------------------
		print("\n--- TEST 1: Unit REST Contract (§3, §4, §23) ---")
		um.select_unit("B_INF_1")
		var u1_before: Dictionary = um.get_unit_by_id("B_INF_1")
		var pos_before: Vector2i = Vector2i(int(u1_before["q"]), int(u1_before["r"]))
		var troops_before: int = int(u1_before["soldier_count"])
		var morale_before: float = float(u1_before["morale"])

		var can_rest_before: bool = um.can_unit_rest("B_INF_1")

		# Trigger REST through shell method
		_shell.call("_on_rest_button_pressed")

		# Reselect B_INF_1 to inspect unit card UI
		um.select_unit("B_INF_1")

		var u1_after: Dictionary = um.get_unit_by_id("B_INF_1")
		var pos_after: Vector2i = Vector2i(int(u1_after["q"]), int(u1_after["r"]))
		var troops_after: int = int(u1_after["soldier_count"])
		var morale_after: float = float(u1_after["morale"])
		var ended_after: bool = bool(u1_after["action_ended"])
		var rested_after: bool = bool(u1_after["rested_this_turn"])
		var resting_unguarded: bool = bool(u1_after.get("resting_unguarded", false))
		var fortified_after: bool = bool(u1_after["fortified"])
		var field_fort_after: bool = bool(u1_after.get("field_fortified", false))
		var fort_hp_after: int = int(u1_after.get("field_fortification_hp", 0))
		var rem_mp_after: float = float(u1_after["remaining_mp"])
		var card1_status_text: String = _shell.unit_card_status.text if _shell.unit_card_status else ""

		var rest_ok: bool = (
			can_rest_before == true and
			pos_before == pos_after and
			troops_before == troops_after and
			is_equal_approx(morale_before, morale_after) and
			ended_after == true and
			rested_after == true and
			resting_unguarded == true and
			fortified_after == false and
			field_fort_after == false and
			fort_hp_after == 0 and
			rem_mp_after <= 0.001 and
			card1_status_text.contains("무방비 휴식")
		)

		var rest_evidence: Dictionary = {
			"task_id": "STEP-04R7-1-TEMPORARY-FIELD-FORTIFICATION",
			"timestamp": Time.get_datetime_string_from_system(),
			"unit_id": "B_INF_1",
			"can_rest_before": can_rest_before,
			"position_before": {"q": pos_before.x, "r": pos_before.y},
			"position_after": {"q": pos_after.x, "r": pos_after.y},
			"troops_before": troops_before,
			"troops_after": troops_after,
			"morale_before": morale_before,
			"morale_after": morale_after,
			"action_ended": ended_after,
			"rested_this_turn": rested_after,
			"resting_unguarded": resting_unguarded,
			"fortified": fortified_after,
			"field_fortified": field_fort_after,
			"field_fortification_hp": fort_hp_after,
			"remaining_mp": rem_mp_after,
			"card_status_text": card1_status_text,
			"no_movement_allowed": rem_mp_after <= 0.001,
			"no_defensive_bonus": (fort_hp_after == 0 and not field_fort_after),
			"status": "PASS" if rest_ok else "FAIL"
		}
		_save_json("unit_rest_contract.json", rest_evidence)
		_results["test_1_rest"] = rest_evidence["status"]
		print("  Result: %s (pos_same=%s, action_ended=%s, resting_unguarded=%s, fort_hp=%d)" % [
			rest_evidence["status"], str(pos_before == pos_after),
			str(ended_after), str(resting_unguarded), fort_hp_after
		])

		# -------------------------------------------------------------
		# -------------------------------------------------------------
		# TEST 2: Field FORTIFY Construction (§5, §6, §12, §20)
		# -------------------------------------------------------------
		print("\n--- TEST 2: Field FORTIFY Construction (§5, §6, §12, §20) ---")
		um.select_unit("B_INF_2")
		var u2_before: Dictionary = um.get_unit_by_id("B_INF_2")
		var pos2_before: Vector2i = Vector2i(int(u2_before["q"]), int(u2_before["r"]))
		var troops2_before: int = int(u2_before["soldier_count"])
		var morale2_before: float = float(u2_before["morale"])

		var can_fortify_before: bool = um.can_unit_fortify("B_INF_2")

		# Trigger FORTIFY through shell method
		_shell.call("_on_fortify_button_pressed")

		# Reselect B_INF_2 to inspect unit card UI
		um.select_unit("B_INF_2")

		var u2_after: Dictionary = um.get_unit_by_id("B_INF_2")
		var pos2_after: Vector2i = Vector2i(int(u2_after["q"]), int(u2_after["r"]))
		var troops2_after: int = int(u2_after["soldier_count"])
		var morale2_after: float = float(u2_after["morale"])
		var ended2_after: bool = bool(u2_after["action_ended"])
		var fortified2_after: bool = bool(u2_after["fortified"])
		var field_fort2_after: bool = bool(u2_after.get("field_fortified", false))
		var fort_hp2_after: int = int(u2_after.get("field_fortification_hp", 0))
		var fort_max2_after: int = int(u2_after.get("field_fortification_hp_max", 0))
		var rem_mp2_after: float = float(u2_after["remaining_mp"])
		var indicator_visible: bool = bool(ur.call("is_unit_fortified", "B_INF_2"))
		var card2_status_text: String = _shell.unit_card_status.text if _shell.unit_card_status else ""

		var fortify_ok: bool = (
			can_fortify_before == true and
			pos2_before == pos2_after and
			troops2_before == troops2_after and
			is_equal_approx(morale2_before, morale2_after) and
			ended2_after == true and
			fortified2_after == true and
			field_fort2_after == true and
			fort_hp2_after == CombatCalculatorCls.FIELD_FORTIFICATION_DEFAULT_HP and
			fort_max2_after == CombatCalculatorCls.FIELD_FORTIFICATION_DEFAULT_HP and
			rem_mp2_after <= 0.001 and
			indicator_visible == true and
			card2_status_text.contains("임시 진지") and
			card2_status_text.contains("180")
		)

		var fortify_evidence: Dictionary = {
			"task_id": "STEP-04R7-1-TEMPORARY-FIELD-FORTIFICATION",
			"timestamp": Time.get_datetime_string_from_system(),
			"unit_id": "B_INF_2",
			"can_fortify_before": can_fortify_before,
			"position_before": {"q": pos2_before.x, "r": pos2_before.y},
			"position_after": {"q": pos2_after.x, "r": pos2_after.y},
			"troops_before": troops2_before,
			"troops_after": troops2_after,
			"morale_before": morale2_before,
			"morale_after": morale2_after,
			"action_ended": ended2_after,
			"fortified": fortified2_after,
			"field_fortified": field_fort2_after,
			"field_fortification_hp": fort_hp2_after,
			"field_fortification_hp_max": fort_max2_after,
			"card_status_text": card2_status_text,
			"remaining_mp": rem_mp2_after,
			"map_defense_indicator_visible": indicator_visible,
			"status": "PASS" if fortify_ok else "FAIL"
		}
		_save_json("field_fortify_contract.json", fortify_evidence)
		_results["test_2_fortify"] = fortify_evidence["status"]
		print("  Result: %s (pos_same=%s, fort_hp=%d/%d, action_ended=%s, map_indicator=%s)" % [
			fortify_evidence["status"], str(pos2_before == pos2_after), fort_hp2_after, fort_max2_after,
			str(ended2_after), str(indicator_visible)
		])

		# -------------------------------------------------------------
		# TEST 3: Normal Defense Baseline Reciprocal Test (§2, §19)
		# -------------------------------------------------------------
		print("\n--- TEST 3: Normal Defense Baseline Reciprocal Test (§2, §19) ---")
		var normal_atk: Dictionary = {
			"class": "infantry",
			"soldier_count": 1000,
			"morale": 100.0,
			"field_fortified": false,
			"field_fortification_hp": 0
		}
		var normal_def: Dictionary = {
			"class": "infantry",
			"soldier_count": 1000,
			"morale": 100.0,
			"field_fortified": false,
			"field_fortification_hp": 0
		}
		var res_normal_melee: Dictionary = CombatCalculatorCls.calculate_combat(normal_atk, normal_def, 1, 0, {}, 1.0)
		var normal_def_cas: int = int(res_normal_melee["defender_casualties"])
		var normal_atk_cas: int = int(res_normal_melee["attacker_casualties"])

		var normal_baseline_ok: bool = (
			normal_def_cas > 0 and
			normal_atk_cas > 0 and
			res_normal_melee["retaliation_occurred"] == true
		)

		var normal_evidence: Dictionary = {
			"task_id": "STEP-04R7-1-TEMPORARY-FIELD-FORTIFICATION",
			"timestamp": Time.get_datetime_string_from_system(),
			"description": "Baseline prepared defender takes damage and inflicts reciprocal damage on melee attacker",
			"distance": 1,
			"attacker_casualties": normal_atk_cas,
			"defender_casualties": normal_def_cas,
			"retaliation_occurred": res_normal_melee["retaliation_occurred"],
			"reciprocal_combat_verified": normal_baseline_ok,
			"status": "PASS" if normal_baseline_ok else "FAIL"
		}
		_save_json("normal_defense_baseline.json", normal_evidence)
		_results["test_3_normal_defense"] = normal_evidence["status"]
		print("  Result: %s (atk_cas=%d, def_cas=%d, retaliation=%s)" % [
			normal_evidence["status"], normal_atk_cas, normal_def_cas, str(res_normal_melee["retaliation_occurred"])
		])

		# -------------------------------------------------------------
		# TEST 4: Field Fortified Defensive Resolution (§8, §11, §20)
		# -------------------------------------------------------------
		print("\n--- TEST 4: Field Fortified Defensive Resolution (§8, §11, §20) ---")
		var fort_def: Dictionary = {
			"class": "infantry",
			"soldier_count": 1000,
			"morale": 100.0,
			"field_fortified": true,
			"field_fortification_hp": 180,
			"field_fortification_hp_max": 180
		}
		var res_fort_melee: Dictionary = CombatCalculatorCls.calculate_combat(normal_atk, fort_def, 1, 0, {}, 1.0)
		var fort_dmg: int = int(res_fort_melee["field_fortification_damage"])
		var fort_rem_hp: int = int(res_fort_melee["remaining_field_fortification_hp"])
		var fort_def_cas: int = int(res_fort_melee["defender_casualties"])
		var fort_atk_cas: int = int(res_fort_melee["attacker_casualties"])

		# Case C: Artificially fortified attacker has ZERO offensive bonus (§16)
		var mock_atk_fortified: Dictionary = {
			"class": "infantry",
			"soldier_count": 1000,
			"morale": 100.0,
			"field_fortified": true,
			"field_fortification_hp": 180
		}
		var res_atk_fortified: Dictionary = CombatCalculatorCls.calculate_combat(mock_atk_fortified, normal_def, 1, 0, {}, 1.0)
		var cas_against_fortified_atk: int = int(res_atk_fortified["defender_casualties"])
		var no_offensive_bonus: bool = (cas_against_fortified_atk == normal_def_cas)

		# Check that flat 15% reduction is no longer canonical
		var no_flat_15_mult: bool = (float(res_fort_melee.get("fortification_casualty_mult", 1.0)) == 1.0)

		var fortified_defense_ok: bool = (
			fort_dmg > 0 and
			fort_atk_cas > 0 and # Defender remains prepared and inflicts reciprocal damage (§8)
			no_offensive_bonus and
			no_flat_15_mult
		)

		var fortified_evidence: Dictionary = {
			"task_id": "STEP-04R7-1-TEMPORARY-FIELD-FORTIFICATION",
			"timestamp": Time.get_datetime_string_from_system(),
			"canonical_model": "Temporary Field Fortification HP Shield",
			"flat_15_pct_multiplier_removed": no_flat_15_mult,
			"field_fortification_damage": fort_dmg,
			"remaining_field_fortification_hp": fort_rem_hp,
			"defender_troop_casualties": fort_def_cas,
			"attacker_reciprocal_casualties": fort_atk_cas,
			"reciprocal_damage_inflicted": fort_atk_cas > 0,
			"fortified_attacker_test": {
				"attacker_fortified": true,
				"defender_casualties_normal_atk": normal_def_cas,
				"defender_casualties_fortified_atk": cas_against_fortified_atk,
				"offensive_bonus_granted": not no_offensive_bonus
			},
			"status": "PASS" if fortified_defense_ok else "FAIL"
		}
		_save_json("fortified_defense_modifier.json", fortified_evidence)
		_results["test_4_field_fortified_defense"] = fortified_evidence["status"]
		print("  Result: %s (fort_dmg=%d, rem_hp=%d, def_cas=%d, reciprocal_atk_cas=%d, no_atk_bonus=%s)" % [
			fortified_evidence["status"], fort_dmg, fort_rem_hp, fort_def_cas, fort_atk_cas, str(no_offensive_bonus)
		])

		# -------------------------------------------------------------
		# TEST 5: One-Attack Scale Balance & Configurable Leakage (§7, §10, §21)
		# -------------------------------------------------------------
		print("\n--- TEST 5: One-Attack Scale Balance & Damage Leakage (§7, §10, §21) ---")
		# Fixture 1: 1000 vs 1000 Infantry
		# Expected raw attack damage = 200 casualties
		# Field fortification HP = 180 HP
		# Under Model B: Fortification takes 180 dmg -> 0 HP (destroyed). Excess 20 dmg passes to troops.
		var raw_expected_damage_1000: int = normal_def_cas # 200
		var chosen_hp: int = CombatCalculatorCls.FIELD_FORTIFICATION_DEFAULT_HP # 180
		var absorbs_approx_one_attack: bool = (chosen_hp >= 150 and chosen_hp <= 250)

		# Fixture 2: 500 vs 500 Infantry moderate attack
		var med_atk: Dictionary = {"class": "infantry", "soldier_count": 500, "morale": 100.0}
		var med_def_unfort: Dictionary = {"class": "infantry", "soldier_count": 500, "morale": 100.0}
		var med_def_fort: Dictionary = {
			"class": "infantry",
			"soldier_count": 500,
			"morale": 100.0,
			"field_fortified": true,
			"field_fortification_hp": 180,
			"field_fortification_hp_max": 180
		}
		var res_med_unfort: Dictionary = CombatCalculatorCls.calculate_combat(med_atk, med_def_unfort, 1, 0, {}, 1.0)
		var res_med_fort: Dictionary = CombatCalculatorCls.calculate_combat(med_atk, med_def_fort, 1, 0, {}, 1.0)
		var med_raw_damage: int = int(res_med_unfort["defender_casualties"])
		var med_fort_dmg: int = int(res_med_fort["field_fortification_damage"])
		var med_rem_hp: int = int(res_med_fort["remaining_field_fortification_hp"])
		var med_def_cas: int = int(res_med_fort["defender_casualties"])

		# 180 HP fully absorbs the 500-man attack (med_raw_damage ~ 86 <= 180), troop casualties = 0!
		var full_absorption_ok: bool = (med_fort_dmg == med_raw_damage and med_def_cas == 0 and med_rem_hp == (180 - med_raw_damage))

		var scale_ok: bool = (
			absorbs_approx_one_attack and
			full_absorption_ok and
			fort_dmg == chosen_hp and
			fort_rem_hp == 0 and
			fort_def_cas == (raw_expected_damage_1000 - chosen_hp) # Model B: excess = 20
		)

		var scale_evidence: Dictionary = {
			"task_id": "STEP-04R7-1-TEMPORARY-FIELD-FORTIFICATION",
			"timestamp": Time.get_datetime_string_from_system(),
			"damage_leakage_model": "Model B (Excess damage passes through to defending troops)",
			"absorb_excess_damage_flag": CombatCalculatorCls.FIELD_FORTIFICATION_ABSORB_EXCESS_DAMAGE,
			"standard_1000_fixture": {
				"attacker_troops": 1000,
				"defender_troops": 1000,
				"expected_raw_damage": raw_expected_damage_1000,
				"configured_fortification_hp": chosen_hp,
				"fortification_damage_absorbed": fort_dmg,
				"remaining_fortification_hp": fort_rem_hp,
				"fortification_destroyed": bool(res_fort_melee["is_field_fortification_destroyed"]),
				"excess_damage_to_troops": fort_def_cas
			},
			"moderate_500_fixture": {
				"attacker_troops": 500,
				"defender_troops": 500,
				"expected_raw_damage": med_raw_damage,
				"fortification_hp_before": 180,
				"fortification_damage_absorbed": med_fort_dmg,
				"remaining_fortification_hp": med_rem_hp,
				"troop_casualties": med_def_cas,
				"full_protection_achieved": (med_def_cas == 0)
			},
			"rationale": "180 HP perfectly absorbs ~1 normal melee attack from standard field infantry (400-500 men take 0 casualties; 1000-man massive attack is 90% absorbed with 20 excess leakage)",
			"status": "PASS" if scale_ok else "FAIL"
		}
		_save_json("one_attack_scale_balance.json", scale_evidence)
		_results["test_5_one_attack_scale"] = scale_evidence["status"]
		print("  Result: %s (1000-man: raw=%d, fort_abs=%d, rem=%d, cas=%d | 500-man: raw=%d, rem=%d, cas=%d)" % [
			scale_evidence["status"], raw_expected_damage_1000, fort_dmg, fort_rem_hp, fort_def_cas,
			med_raw_damage, med_rem_hp, med_def_cas
		])

		# -------------------------------------------------------------
		# TEST 6: Fortify Eligibility Contract (§12, §17)
		# -------------------------------------------------------------
		print("\n--- TEST 6: Fortify Eligibility Contract (§12, §17) ---")
		# Unit 3 untouched
		var can_fort_u3: bool = um.can_unit_fortify("B_INF_3")

		# Unit 3 moved: simulate legal move cost
		var u3: Dictionary = um.get_unit_by_id("B_INF_3")
		var original_spent: float = float(u3.get("turn_move_cost_spent", 0.0))
		var raw_u3 = um._units["B_INF_3"]
		raw_u3["turn_move_cost_spent"] = 1.0
		var can_fort_moved: bool = um.can_unit_fortify("B_INF_3")
		var move_attempt: Dictionary = um.fortify_unit("B_INF_3")
		raw_u3["turn_move_cost_spent"] = original_spent # restore

		# Unit 4 attacked: simulate attack flag
		var raw_u4 = um._units["B_INF_4"]
		raw_u4["has_attacked"] = true
		var can_fort_attacked: bool = um.can_unit_fortify("B_INF_4")
		var atk_attempt: Dictionary = um.fortify_unit("B_INF_4")
		raw_u4["has_attacked"] = false # restore

		# Unit 1 already action_ended from Test 1
		var can_fort_ended: bool = um.can_unit_fortify("B_INF_1")
		var ended_attempt: Dictionary = um.fortify_unit("B_INF_1")

		# Garrison unit check (§17)
		var can_fort_garrison: bool = um.can_unit_fortify("R_GAR_SPE_1")
		var garrison_attempt: Dictionary = um.fortify_unit("R_GAR_SPE_1")

		var eligibility_ok: bool = (
			can_fort_u3 == true and
			can_fort_moved == false and
			move_attempt["success"] == false and
			can_fort_attacked == false and
			atk_attempt["success"] == false and
			can_fort_ended == false and
			ended_attempt["success"] == false and
			can_fort_garrison == false and
			garrison_attempt["success"] == false
		)

		var eligibility_evidence: Dictionary = {
			"task_id": "STEP-04R7-1-TEMPORARY-FIELD-FORTIFICATION",
			"timestamp": Time.get_datetime_string_from_system(),
			"checks": {
				"untouched_unit": {"eligible": can_fort_u3, "expected": true},
				"moved_unit": {"eligible": can_fort_moved, "attempt_success": move_attempt["success"], "expected": false},
				"attacked_unit": {"eligible": can_fort_attacked, "attempt_success": atk_attempt["success"], "expected": false},
				"action_ended_unit": {"eligible": can_fort_ended, "attempt_success": ended_attempt["success"], "expected": false},
				"garrison_unit": {"eligible": can_fort_garrison, "attempt_success": garrison_attempt["success"], "expected": false}
			},
			"status": "PASS" if eligibility_ok else "FAIL"
		}
		_save_json("fortify_eligibility_contract.json", eligibility_evidence)
		_results["test_6_eligibility"] = eligibility_evidence["status"]
		print("  Result: %s (untouched=%s, moved_blocked=%s, atk_blocked=%s, garrison_blocked=%s)" % [
			eligibility_evidence["status"], str(can_fort_u3), str(not can_fort_moved),
			str(not can_fort_attacked), str(not can_fort_garrison)
		])

		# -------------------------------------------------------------
		# TEST 7: NEXT Selection Cycle & Inspection (§13, §14, §24)
		# -------------------------------------------------------------
		print("\n--- TEST 7: NEXT Selection Cycle & Inspection (§13, §14, §24) ---")
		var units_sequence: Array[String] = []
		um.select_unit("B_INF_3")
		units_sequence.append(um.get_selected_unit_id())

		for i in range(12):
			_shell.call("select_next_friendly_field_unit")
			units_sequence.append(um.get_selected_unit_id())

		var contains_ended_units: bool = false
		for uid in units_sequence:
			if uid == "B_INF_1" or uid == "B_INF_2":
				contains_ended_units = true
				break

		# Manual Reselection of rested unit for inspection (§14)
		um.select_unit("B_INF_1")
		var inspect1_id: String = um.get_selected_unit_id()
		var card1_text: String = _shell.unit_card_status.text if _shell.unit_card_status else ""
		var card1_rest_disabled: bool = (_shell._btn_rest.disabled if _shell._btn_rest else false)
		var card1_fort_disabled: bool = (_shell._btn_fortify.disabled if _shell._btn_fortify else false)

		# Manual Reselection of fortified unit for inspection (§14)
		um.select_unit("B_INF_2")
		var inspect2_id: String = um.get_selected_unit_id()
		var card2_text: String = _shell.unit_card_status.text if _shell.unit_card_status else ""
		var card2_rest_disabled: bool = (_shell._btn_rest.disabled if _shell._btn_rest else false)
		var card2_fort_disabled: bool = (_shell._btn_fortify.disabled if _shell._btn_fortify else false)

		var inspect_ok: bool = (
			inspect1_id == "B_INF_1" and card1_text.contains("무방비 휴식") and card1_rest_disabled and card1_fort_disabled and
			inspect2_id == "B_INF_2" and card2_text.contains("임시 진지") and card2_text.contains("180") and card2_rest_disabled and card2_fort_disabled
		)

		var next_ok: bool = (not contains_ended_units and inspect_ok)

		var next_evidence: Dictionary = {
			"task_id": "STEP-04R7-1-TEMPORARY-FIELD-FORTIFICATION",
			"timestamp": Time.get_datetime_string_from_system(),
			"next_selection_sequence": units_sequence,
			"skipped_rested_unit_b_inf_1": not units_sequence.has("B_INF_1"),
			"skipped_fortified_unit_b_inf_2": not units_sequence.has("B_INF_2"),
			"manual_reselection_inspection": {
				"b_inf_1_status": card1_text,
				"b_inf_1_buttons_disabled": (card1_rest_disabled and card1_fort_disabled),
				"b_inf_2_status": card2_text,
				"b_inf_2_buttons_disabled": (card2_rest_disabled and card2_fort_disabled),
				"inspection_text_verified": inspect_ok
			},
			"status": "PASS" if next_ok else "FAIL"
		}
		_save_json("next_after_rest_fortify.json", next_evidence)
		_results["test_7_next"] = next_evidence["status"]
		print("  Result: %s (skipped_ended=%s, inspect_ok=%s)" % [
			next_evidence["status"], str(not contains_ended_units), str(inspect_ok)
		])

		# -------------------------------------------------------------
		# TEST 8: Turn Persistence & Move Abandonment (§15, §16, §22)
		# -------------------------------------------------------------
		print("\n--- TEST 8: Turn Persistence & Move Abandonment (§15, §16, §22) ---")
		# B_INF_2 is currently fortified at (-22, 0).
		var pos_before_t2: Vector2i = Vector2i(int(u2_after["q"]), int(u2_after["r"]))
		var fort_hp_before_t2: int = int(u2_after["field_fortification_hp"])

		# Advance turn to Turn 2
		var t1: int = um.get_current_turn()
		var t2: int = um.end_turn()
		_shell.call("_on_unit_manager_turn_advanced", t2)

		var u1_t2: Dictionary = um.get_unit_by_id("B_INF_1")
		var u2_t2: Dictionary = um.get_unit_by_id("B_INF_2")

		# §15 Check: Fortification PERSISTS into Turn 2 while unit stays on hex!
		var u2_t2_action_ended: bool = bool(u2_t2["action_ended"])
		var u2_t2_fortified: bool = bool(u2_t2["field_fortified"])
		var u2_t2_hp: int = int(u2_t2["field_fortification_hp"])
		var u2_t2_indicator: bool = bool(ur.call("is_unit_fortified", "B_INF_2"))
		var u1_t2_rest_cleared: bool = (not bool(u1_t2["resting_unguarded"]) and not bool(u1_t2["rested_this_turn"]))

		var persistence_ok: bool = (
			t2 == t1 + 1 and
			u2_t2_action_ended == false and # Unit can act again in Turn 2!
			u2_t2_fortified == true and     # Fortification NOT cleared on turn advance!
			u2_t2_hp == fort_hp_before_t2 and
			u2_t2_indicator == true and
			u1_t2_rest_cleared == true
		)

		# §16 & §22 Check: Move away from hex -> Abandon fortification before movement
		# Move B_INF_2 from (-22, 0) to adjacent unoccupied (-22, 1)
		var dest_hex: Vector2i = Vector2i(-22, 1)
		var move_path: Array[Vector2i] = [pos_before_t2, dest_hex]
		var move_res: Dictionary = um.execute_move("B_INF_2", move_path, 1.0, Step3ConfigCls.MarchClass.GREEN, false)

		var u2_after_move: Dictionary = um.get_unit_by_id("B_INF_2")
		var u2_pos_after_move: Vector2i = Vector2i(int(u2_after_move["q"]), int(u2_after_move["r"]))
		var u2_fort_after_move: bool = bool(u2_after_move.get("field_fortified", false))
		var u2_hp_after_move: int = int(u2_after_move.get("field_fortification_hp", 0))
		var u2_indicator_after_move: bool = bool(ur.call("is_unit_fortified", "B_INF_2"))

		var abandon_ok: bool = (
			move_res.get("success", false) == true and
			u2_pos_after_move == dest_hex and
			u2_fort_after_move == false and # Field fortification removed!
			u2_hp_after_move == 0 and       # HP zeroed!
			u2_indicator_after_move == false # Map indicator cleared!
		)

		var test8_ok: bool = (persistence_ok and abandon_ok)

		var persistence_evidence: Dictionary = {
			"task_id": "STEP-04R7-1-TEMPORARY-FIELD-FORTIFICATION",
			"timestamp": Time.get_datetime_string_from_system(),
			"turn_advance_persistence": {
				"turn_before": t1,
				"turn_after": t2,
				"u2_action_ended": u2_t2_action_ended,
				"u2_field_fortified_preserved": u2_t2_fortified,
				"u2_fortification_hp_preserved": u2_t2_hp,
				"u2_indicator_visible_turn2": u2_t2_indicator,
				"u1_resting_cleared": u1_t2_rest_cleared,
				"status": "PASS" if persistence_ok else "FAIL"
			},
			"hex_abandonment_on_move": {
				"unit_id": "B_INF_2",
				"origin_hex": {"q": pos_before_t2.x, "r": pos_before_t2.y},
				"destination_hex": {"q": dest_hex.x, "r": dest_hex.y},
				"move_successful": move_res.get("success", false),
				"field_fortified_after_move": u2_fort_after_move,
				"field_fortification_hp_after_move": u2_hp_after_move,
				"indicator_visible_after_move": u2_indicator_after_move,
				"fortification_abandoned_cleanly": abandon_ok
			},
			"status": "PASS" if test8_ok else "FAIL"
		}
		_save_json("field_fortification_persistence_abandon.json", persistence_evidence)
		_results["test_8_persistence_abandon"] = persistence_evidence["status"]
		print("  Result: %s (persisted_turn2=%s, hp_t2=%d | moved=%s, abandoned=%s, ind_cleared=%s)" % [
			persistence_evidence["status"], str(u2_t2_fortified), u2_t2_hp,
			str(move_res.get("success", false)), str(not u2_fort_after_move), str(not u2_indicator_after_move)
		])

		print("\n==================================================")
		print("VERIFICATION SUMMARY:")
		var all_passed: bool = true
		for k in _results.keys():
			print("  %s: %s" % [k, _results[k]])
			if _results[k] != "PASS":
				all_passed = false
		print("OVERALL: %s" % ("READY FOR REVIEW" if all_passed else "FAILED"))
		print("==================================================")

		quit(0 if all_passed else 1)
		return true

	return false

func _save_json(filename: String, data: Dictionary) -> void:
	var path: String = _evidence_dir + "/" + filename
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data, "  "))
		file.close()
		print("  [Evidence Saved] -> %s" % path)
	else:
		push_error("Failed to save evidence to %s" % path)
