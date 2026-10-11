class_name TerrainMods
extends RefCounted

## 정적 지형 데이터 — HexCell.TerrainType에 대한 전투/이동 수정치.
## 전투 시스템은 HexCell의 enum 값을 직접 사용하지 않고, 이 딕셔너리를 통해
## 지형 효과를 일관되게 참조한다 (테스트 용이성 + 밸런스 변경 단일 지점).

## ===== 지형별 방어 보너스 (방어력 곱셈 계수) =====
## 1.0 = 보정 없음, 1.5 = 방어력 50% 증가.
## 성벽이 압도적인 이유: 2.0 = 방어력 2배
## NOTE: const dict keys as int literals (0..6) to avoid parse-order dependency on HexCell global.
const DEFENSE_BONUS := {
	0:    1.0,  # PLAINS
	1: 1.5,   # MOUNTAINS 고지 + 좁은 통로
	2:    1.3,   # FOREST 매복 + 엄폐
	3:     1.2,   # SWAMP 진입 느림 = 배치 시간
	4:  2.0,   # FORTRESS 성벽 — 공성병 없이는 사실상 막힘
	5:   1.1,   # VILLAGE 가옥 + 보급 거점
	6:      1.0,   # ROAD 도로 위에서는 방어 이점 없음
}

## ===== 궁병 사거리 보너스 (사거리 hex 추가) =====
## 산정에서 사격 시 시야 확보 + 고지 이점.
const ARCHER_RANGE_BONUS := {
	0:    0,
	1: 1,   # MOUNTAINS 고지 = 사거리+1
	2:    0,
	3:     0,
	4:  1,   # FORTRESS 성벽 위 = 사격대 유리
	5:   0,
	6:      0,
}

## ===== 매복 가능 여부 =====
## 정찰병 / 숲·습지의 매복 보너스에 사용.
const CAN_AMBUSH := {
	0:    false,
	1: false,
	2:    true,
	3:     true,
	4:  false,
	5:   false,
	6:      false,
}

## ===== 진입 가능 여부 (UnitType.can_enter로 위임하기 전, 전地形 기준 가드) =====
## 거의 모든 병과가 들어갈 수 있지만, FORTRESS는 일부 병과만.
## (실제 진짜 제한은 UnitType.entry_flags에서 처리 — 이건 UI 힌트용)
const DEFAULT_PASSABLE := {
	0:    true,
	1: true,   # MOUNTAINS 보병/궁병 가능, 기병 불가
	2:    true,
	3:     true,   # SWAMP 기병 불가
	4:  true,   # FORTRESS 공성병/보병만 의미있는 진입
	5:   true,
	6:      true,
}

## ===== 지형 표시 문자열 (UI/로그용) =====
const TERRAIN_NAME := {
	0:    "평야",
	1: "산지",
	2:    "숲",
	3:     "습지",
	4:  "성벽/요새",
	5:   "마을/도시",
	6:      "도로",
}


static func get_defense_bonus(terrain: int) -> float:
	return DEFENSE_BONUS.get(terrain, 1.0)


static func get_archer_range_bonus(terrain: int) -> int:
	return ARCHER_RANGE_BONUS.get(terrain, 0)


static func can_ambush(terrain: int) -> bool:
	return CAN_AMBUSH.get(terrain, false)