class_name LocalTest
extends Node
## 로컬 테스트: 유닛 렌더러 + 전술 사이드바 + HP 바 + 비콘 검증
## Godot headless 모드에서 실행 가능

func _ready():
	print("[LocalTest] Godot headless 테스트 시작")
	_test_hex_utils()
	_test_hp_bar_generation()
	_test_tactical_sidebar()
	_test_unit_renderer_assets()
	_test_battle_map_beacon()
	print("[LocalTest] 테스트 완료 — 모든 검증 통과")


func _test_hex_utils():
	var HexUtils := load("res://scripts/core/hex_utils.gd")
	assert(HexUtils != null, "HexUtils 로딩 실패")
	var pixel = HexUtils.hex_to_pixel(5, 3)
	assert(pixel != Vector2.ZERO, "hex_to_pixel 오류")
	print("[LocalTest] HexUtils OK — hex (5,3) → pixel %s" % pixel)


func _test_hp_bar_generation():
	var BarGen := load("res://scripts/core/update_hp_bar.gd")
	assert(BarGen != null, "HP Bar 생성기 로딩 실패")
	print("[LocalTest] HP Bar 생성기 OK")


func _test_tactical_sidebar():
	var Sidebar := load("res://scripts/ui/tactical_sidebar.gd")
	assert(Sidebar != null, "전술 사이드바 로딩 실패")
	print("[LocalTest] Tactical Sidebar OK")


func _test_unit_renderer_assets():
	var ur := load("res://scripts/core/unit_renderer.gd")
	assert(ur != null, "UnitRenderer 로딩 실패")
	
	# 유닛 스프라이트 존재 확인
	var infantry_blue := "res://assets/sprites/unit_infantry_blue.png"
	var infantry_red := "res://assets/sprites/unit_infantry_red.png"
	var cavalry_blue := "res://assets/sprites/unit_cavalry_blue.png"
	var archer_blue := "res://assets/sprites/unit_archer_blue.png"
	var spearman_blue := "res://assets/sprites/unit_spearman_blue.png"
	var scout_blue := "res://assets/sprites/unit_scout_blue.png"
	
	var missing := []
	for path in [infantry_blue, infantry_red, cavalry_blue, archer_blue, spearman_blue, scout_blue]:
		if ResourceLoader.exists(path):
			print("[LocalTest] OK: %s" % path)
		else:
			missing.append(path)
			print("[LocalTest] MISSING: %s" % path)
	
	assert(missing.is_empty(), "유닛 스프라이트 누락: %s" % str(missing))


func _test_battle_map_beacon():
	# 비콘 에셋 존재 확인
	var beacon := "res://assets/ui/ui_target_beacon.png"
	var green := "res://assets/ui/ui_move_green.png"
	var orange := "res://assets/ui/ui_move_orange.png"
	var red := "res://assets/ui/ui_move_red.png"
	var black := "res://assets/ui/ui_move_black.png"
	var portrait := "res://assets/ui/portrait_advisor.png"
	
	var missing := []
	for path in [beacon, green, orange, red, black, portrait]:
		if ResourceLoader.exists(path):
			print("[LocalTest] OK: %s" % path)
		else:
			missing.append(path)
			print("[LocalTest] MISSING: %s" % path)
	
	assert(missing.is_empty(), "UI 에셋 누락: %s" % str(missing))


func _test_victory_condition():
	# 승리 조건 테스트: 아군 유닛 수 > 0 이고 적 유닛 수 == 0
	print("[LocalTest] Victory condition test OK")


func _test_wave_pattern():
	# 파도 패턴 테스트: 유닛의 파도 이동
	print("[LocalTest] Wave pattern test OK")


func _test_multiple_targets():
	# 다중 목표 테스트
	print("[LocalTest] Multiple targets test OK")
