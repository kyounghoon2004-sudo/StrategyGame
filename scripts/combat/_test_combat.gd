extends SceneTree

## Combat System Test/Showcase
## 이 스크립트는 Godot 4.x에서 다음과 같이 실행한다:
##   godot --headless --script res://scripts/combat/_test_combat.gd
##   (Windows) godot --headless --path "d:/Game development/Demon slayer/StrategyGame" -s scripts/combat/_test_combat.gd
## 샘플 전투 계산 워크쓰루를 stdout에 출력한다.

const UnitTypesScript = preload("res://scripts/combat/unit_types.gd")

func _init() -> void:
	print("=== 오대십국 전투 시스템 테스트 ===\n")

	# ---- 1. 7종 병과 출력 ----
	print("[1] 7개 병과 스탯:")
	var factory := UnitTypesScript.new()
	var types: Array[UnitType] = [
		factory.make_infantry(),
		factory.make_archers(),
		factory.make_cavalry(),
		factory.make_spearmen(),
		factory.make_siege(),
		factory.make_conscripts(),
		factory.make_scouts(),
	]
	for t in types:
		print("  %s [atk=%d def=%d rng=%d mv=%d supply=%.2f/100]" % [
			t.name_kr, t.attack, t.defense, t.attack_range, t.base_movement,
			t.supply_per_100_per_day
		])
	print("")

	# ---- 2. 보병 1000 vs 궁병 800, 평야 ----
	print("[2] 샘플: 보병 1000명 vs 궁병 800명 (모두 평야)")
	var infantry_type: UnitType = factory.make_infantry()
	var archer_type: UnitType = factory.make_archers()
	var u1 := Unit.new(infantry_type, "blue", 1000)
	var u2 := Unit.new(archer_type, "red", 800)
	u1.current_morale = 75.0
	u2.current_morale = 65.0
	var result := CombatCalculator.calculate(u1, u2, HexCell.TerrainType.PLAINS, HexCell.TerrainType.PLAINS)
	print("  %s" % result.summary)
	print("")

	# ---- 3. 삼각 상성 비교 ----
	print("[3] 삼각 상성 (평야, 1000 vs 1000):")
	var cavalry_type: UnitType = factory.make_cavalry()
	var spear_type: UnitType = factory.make_spearmen()
	var pair_tests := [
		[factory.make_cavalry(),  factory.make_archers(), "기병 -> 궁병"],
		[factory.make_archers(),  factory.make_spearmen(), "궁병 -> 창병"],
		[factory.make_spearmen(), factory.make_cavalry(), "창병 -> 기병"],
		[factory.make_cavalry(),  factory.make_spearmen(), "기병 -> 창병 (불리)"],
	]
	for pair in pair_tests:
		var atk_type: UnitType = pair[0]
		var def_type: UnitType = pair[1]
		var label: String = str(pair[2])
		var mult: float = CombatCalculator.get_matchup_mult(atk_type, def_type)
		print("  %s: 상성배율 = %.2f" % [label, mult])
	print("")

	# ---- 4. 군 규모 페널티 비교 ----
	print("[4] 보병 부대 규모별 페널티:")
	var infantry: UnitType = factory.make_infantry()
	for cnt in [100, 200, 500, 1000, 2000, 3000]:
		var mp: int = MovementCalculator.get_movement_points(infantry, cnt)
		print("  보병 %d명 → 이동력 %d 헥스" % [cnt, mp])
	print("")

	# ---- 5. 징집병 페널티 비교 ----
	print("[5] 징집병 부대 (의도적으로 느리게):")
	var conscript: UnitType = factory.make_conscripts()
	for cnt in [500, 1500, 3000]:
		var mp: int = MovementCalculator.get_movement_points(conscript, cnt)
		print("  징집병 %d명 → 이동력 %d 헥스" % [cnt, mp])
	print("")

	# ---- 6. 사기 상태 전이 ----
	print("[6] 사기 상태 전이:")
	for morale in [80.0, 55.0, 35.0, 18.0, 3.0]:
		print("  사기 %.1f → 상태: %s" % [morale, MoraleSystem.get_state_label(morale)])
	print("")

	# ---- 7. 도달 가능 헥스 (5x5 그리드) ----
	print("[7] 도달 가능 헥스 (보병 1000, 5x5 그리드):")
	var grid := {}
	for q in range(-2, 3):
		for r in range(-2, 3):
			var cell := HexCell.new(q, r, HexCell.TerrainType.PLAINS)
			grid["%d,%d" % [q, r]] = cell
	var unit_for_move := Unit.new(infantry, "blue", 1000)
	unit_for_move.hex_q = 0
	unit_for_move.hex_r = 0
	var reachable: Array[Vector2i] = MovementCalculator.get_reachable_hexes(unit_for_move, grid)
	print("  보병 1000명 (0,0)에서 시작, 이동력 %d → 도달 가능 헥스 수: %d (시작 포함)" % [unit_for_move.get_movement_points(), reachable.size()])
	print("")

	# ---- 8. 분할/합치기 ----
	print("[8] 부대 분할:")
	var big_unit := Unit.new(infantry, "blue", 1500)
	print("  원본: %s" % str(big_unit))
	var split_off: Unit = big_unit.split(500)
	print("  분할 후 원본: %s" % str(big_unit))
	print("  분할된 유닛: %s" % str(split_off))
	print("")

	# ---- 9. 보급 소모 시뮬레이션 ----
	print("[9] 보급 부족 시 사기 하락:")
	var hungry := Unit.new(infantry, "blue", 1000)
	hungry.current_supply_days = 30.0
	hungry.current_morale = 70.0
	for d in range(1, 7):
		hungry.consume_supply(d)
		print("  %d일 경과 → 보급=%.1f, 사기=%.1f" % [d, hungry.current_supply_days, hungry.current_morale])
	print("")

	# ---- 10. 전투 후 사기 변화 ----
	print("[10] 전투 후 사기 변화 (1500 보병 vs 1000 창병, 평야):")
	var attacker := Unit.new(infantry, "blue", 1500)
	attacker.current_morale = 75.0
	var defender := Unit.new(spear_type, "red", 1000)
	defender.current_morale = 70.0
	var battle := CombatCalculator.calculate(attacker, defender, HexCell.TerrainType.PLAINS, HexCell.TerrainType.PLAINS)
	print("  전투 결과: %s" % battle.summary)
	# 사기 적용
	var old_atk_morale: float = attacker.current_morale
	var old_def_morale: float = defender.current_morale
	var atk_won: bool = battle.attacker_casualties < battle.defender_casualties
	var own_loss_r: float = float(battle.attacker_casualties) / float(attacker.soldier_count)
	var enemy_loss_r: float = float(battle.defender_casualties) / float(defender.soldier_count)
	attacker.current_morale = MoraleSystem.morale_after_battle(attacker.current_morale, atk_won, own_loss_r, enemy_loss_r)
	defender.current_morale = MoraleSystem.morale_after_battle(defender.current_morale, not atk_won, enemy_loss_r, own_loss_r)
	print("  공격측 사기: %.1f → %.1f" % [old_atk_morale, attacker.current_morale])
	print("  방어측 사기: %.1f → %.1f" % [old_def_morale, defender.current_morale])
	print("")

	print("=== 테스트 완료 ===")
	quit()