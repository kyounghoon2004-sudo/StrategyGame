@tool
class_name UnitTypes
extends Resource

## 7개 병과의 구체적 밸런스 수치 — 이 파일이 .tres 생성/검증용,
## 실제 런타임에서는 res://data/unit_types/*.tres 경로로 로드.
## Godot 4.x 전용 tool 스크립트이므로 에디터에서 실행 가능.


## ===== 공통 시작값 (필요 시 에디터에서 복제 후 수정) =====

func make_infantry() -> UnitType:
	var t := UnitType.new()
	t.id = "infantry"
	t.name_en = "Infantry"
	t.name_kr = "보병"
	t.name_han = "보병"
	t.attack = 10
	t.defense = 10
	t.attack_range = 1
	t.base_movement = 2
	t.supply_per_100_per_day = 1.0
	t.base_morale = 70.0
	t.terrain_passable = 0x7F  ## 모든 지형
	t.terrain_combat_mod = {
		HexCell.TerrainType.FOREST: 0.9,  ## 숲에서는 약간 불리 (엄폐 좋은 쪽은 원거리)
		HexCell.TerrainType.ROAD: 1.1,    ## 도로 위에서는 보병이 유리 (보급 + 기동력)
	}
	t.is_conscript = false
	t.matchup_tag = UnitType.MatchupTag.NEUTRAL
	return t


func make_archers() -> UnitType:
	var t := UnitType.new()
	t.id = "archers"
	t.name_en = "Archers"
	t.name_kr = "궁병"
	t.name_han = "궁병"
	t.attack = 12
	t.defense = 4
	t.attack_range = 3
	t.base_movement = 2
	t.supply_per_100_per_day = 0.9   ## 병종 중 식량 소모 약간 적음
	t.base_morale = 65.0
	t.terrain_passable = 0x7F
	t.terrain_combat_mod = {
		HexCell.TerrainType.MOUNTAINS: 1.25,   ## 고지 사격 유리
		HexCell.TerrainType.FORTRESS:  1.2,    ## 성벽 위 사격 유리
		HexCell.TerrainType.SWAMP:    0.7,     ## 근접 접근은 두려운 지형
		HexCell.TerrainType.FOREST:   0.8,     ## 숲에서는 적 돌격에 취약
	}
	t.is_conscript = false
	t.matchup_tag = UnitType.MatchupTag.ARCHER   ## 기병에게 약, 창병에게 강
	return t


func make_cavalry() -> UnitType:
	var t := UnitType.new()
	t.id = "cavalry"
	t.name_en = "Cavalry"
	t.name_kr = "기병"
	t.name_han = "기병"
	t.attack = 14
	t.defense = 6
	t.attack_range = 1
	t.base_movement = 3
	t.supply_per_100_per_day = 1.3   ## 말 유지비 → 식량 + 약간
	t.base_morale = 72.0
	t.terrain_passable = 0x1D  ## 0b00011101 = 평야+숲+성벽+마을+도로 (산지·습지 제외)
	t.terrain_combat_mod = {
		HexCell.TerrainType.MOUNTAINS: 0.4,  ## 산지에서는 거의 무용지물
		HexCell.TerrainType.FOREST:    0.7,  ## 숲에서 돌격 어려움
		HexCell.TerrainType.SWAMP:    0.4,  ## 습지 통과 불가 → 전투 불가 가정하지만
	                                         ## 방어측이 늪에 있을 때 보너스로 간접 적용
		HexCell.TerrainType.ROAD:     1.2,  ## 도로 위에서는 기동력+공격 위력
	}
	t.is_conscript = false
	t.matchup_tag = UnitType.MatchupTag.CAVALRY  ## 창병에게 약
	return t


func make_spearmen() -> UnitType:
	var t := UnitType.new()
	t.id = "spearmen"
	t.name_en = "Spearmen"
	t.name_kr = "창병"
	t.name_han = "창병"
	t.attack = 8
	t.defense = 14
	t.attack_range = 1
	t.base_movement = 2
	t.supply_per_100_per_day = 1.0
	t.base_morale = 68.0
	t.terrain_passable = 0x7F
	t.terrain_combat_mod = {
		HexCell.TerrainType.FOREST:     1.2,  ## 숲 방어에서 긴 창 유리
		HexCell.TerrainType.MOUNTAINS:  1.15, ## 산지에서는 보폭 느려도 방어력 유지
	}
	t.is_conscript = false
	t.matchup_tag = UnitType.MatchupTag.SPEARMAN  ## 기병에게 강
	return t


func make_siege() -> UnitType:
	var t := UnitType.new()
	t.id = "siege"
	t.name_en = "Siege Engines"
	t.name_kr = "공성병"
	t.name_han = "공성병"
	t.attack = 18
	t.defense = 2
	t.attack_range = 2   ## 공성 병기로 2 hex 간접 타격 가능 (예: 투석기 화망)
	t.base_movement = 1
	t.supply_per_100_per_day = 1.4   ## 장비 식량 + 목재 소모 큼
	t.base_morale = 62.0
	t.terrain_passable = 0x7F
	t.terrain_combat_mod = {
		HexCell.TerrainType.ROAD:      1.2,    ## 도로 위에서는 이동 가능 범위 확대
		HexCell.TerrainType.FOREST:    0.7,    ## 숲/산지에서는 장비 운용 곤란
		HexCell.TerrainType.MOUNTAINS: 0.7,
	}
	t.can_siege = true
	t.is_conscript = false
	t.matchup_tag = UnitType.MatchupTag.NEUTRAL
	return t


func make_conscripts() -> UnitType:
	var t := UnitType.new()
	t.id = "conscripts"
	t.name_en = "Conscripts"
	t.name_kr = "징집병"
	t.name_han = "징집병"
	t.attack = 5
	t.defense = 5
	t.attack_range = 1
	t.base_movement = 1
	t.supply_per_100_per_day = 0.5   ## 그래도 싸긴 쌈 — 대규모 병력용
	t.base_morale = 45.0   ## 사기 불안정
	t.terrain_passable = 0x7F
	t.is_conscript = true
	t.matchup_tag = UnitType.MatchupTag.NEUTRAL
	return t


func make_scouts() -> UnitType:
	var t := UnitType.new()
	t.id = "scouts"
	t.name_en = "Scouts"
	t.name_kr = "정찰병"
	t.name_han = "정찰병"
	t.attack = 2
	t.defense = 3
	t.attack_range = 1
	t.base_movement = 3   ## 정찰병은 빠르고 먼 곳까지
	t.supply_per_100_per_day = 0.6
	t.base_morale = 68.0
	t.terrain_passable = 0x7F
	t.can_scout = true
	t.terrain_combat_mod = {
		HexCell.TerrainType.FOREST: 1.25,   ## 숲에서 은밀 이동 + 매복
		HexCell.TerrainType.SWAMP:  1.1,    ## 습지 이동 가능하나 보병보다는 나음
	}
	t.is_conscript = false
	t.matchup_tag = UnitType.MatchupTag.NEUTRAL
	return t


## ===== 팩토리로부터 .tres 저장 예시 (에디터 테스트용) =====
## 아래 주석을 해제하면 에디터에서 실행하여 data/unit_types/ 폴더에
## 모든 병과 .tres 파일을 생성한다. 런타임 코드 아님 — 에디터 편의용.

# func _enter_tree() -> void:
# 	var dir_path := "res://data/unit_types"
# 	DirAccess.make_dir_recursive_absolute(dir_path)
# 	var types := [
# 		make_infantry(),
# 		make_archers(),
# 		make_cavalry(),
# 		make_spearmen(),
# 		make_siege(),
# 		make_conscripts(),
# 		make_scouts(),
# 	]
# 	for t in types:
# 		var p := "%s/%s.tres" % [dir_path, t.id]
# 		t.save(p)
# 		print("Wrote: %s" % p)