class_name UnitType
extends Resource

## 병과 정의 리소스 — 7종 모두 이 클래스의 인스턴스로 .tres에 저장된다.
## 밸런스 수치는 여기 한 군데에서만 바꾸면 모든 시스템에 자동 반영.

## ===== 기본 스탯 (병과별 권장 값 — 아래 _make_default_* 참고) =====
@export var id: StringName = &""            ## 내부 ID ("infantry", "cavalry" …)
@export var name_en: String = ""             ## 영어 표기
@export var name_kr: String = ""             ## 한국어
@export var name_han: String = ""            ## 한자

@export var attack: int = 10                 ## 기본 공격력 (병력 1인당 효과 반영은 Unit에서)
@export var defense: int = 10                ## 기본 방어력
@export var attack_range: int = 1            ## 사거리 (헥스). 1=근접, 2+=원거리
@export var base_movement: int = 2           ## 기본 이동력 (헥스)

## ===== 식량/사기 =====
@export var supply_per_100_per_day: float = 1.0  ## 100명/일 식량 소비
@export var base_morale: float = 70.0            ## 신병 사기 기본값 (0~100)

## ===== 지형 진입 가능 여부 (벡터 마스킹) =====
## bit mask: PLAINS=1<<0, MOUNTAINS=1<<1, FOREST=1<<2, SWAMP=1<<3,
##          FORTRESS=1<<4, VILLAGE=1<<5, ROAD=1<<6
## HexCell.TerrainType 값을 그대로 OR한 비트값으로 저장.
@export_flags(
	"Plains:1", "Mountains:2", "Forest:4", "Swamp:8",
	"Fortress:16", "Village:32", "Road:64"
) var terrain_passable: int = 0x7F  ## 기본 = 모든 지형 통과

## ===== 지형별 전투 보너스 (방어 시 적용되는 보너스에 가산) =====
## dict[TerrainType -> float]. 비어있으면 보정 없음.
## 예: 기병이 숲에서 -0.2 = 효과 80%
@export var terrain_combat_mod: Dictionary = {}

## ===== 특수 플래그 =====
@export var can_siege: bool = false         ## 성벽 공격 가능
@export var can_scout: bool = false         ## 정찰 능력 (정보 시스템 연동)
@export var can_ambush: bool = false        ## 매복 가능 (숲/습지에서만 발동)
@export var is_conscript: bool = false      ## 징집병 — 통제 어려움, 이동 페널티

## ===== 상성 분류 (삼각 상성용) =====
## MATCHUP_TAG로 사용 — 같은 그룹 안에서 순환 상성.
## 예: CAVALRY > ARCHER > SPEARMAN > CAVALRY
enum MatchupTag { NEUTRAL, CAVALRY, ARCHER, SPEARMAN }

@export var matchup_tag: MatchupTag = MatchupTag.NEUTRAL


## ===== 정적 헬퍼 =====

## 어떤 지형에 진입 가능한가?
func can_enter(terrain: int) -> bool:
	return (terrain_passable & (1 << terrain)) != 0


## 해당 지형에서 전투 시 추가 보너스(또는 페널티)를 반환.
## 예: 숲 속 기병은 0.8 (20% 약화).
func get_terrain_combat_mod(terrain: int) -> float:
	return terrain_combat_mod.get(terrain, 1.0)


## 디버그/UI용 한 줄 요약.
func _to_string() -> String:
	return "UnitType(%s, atk=%d, def=%d, rng=%d, mv=%d)" % [
		id, attack, defense, attack_range, base_movement
	]


## ===== 밸런스 표 (참고용 — 실제 값은 .tres에서 설정) =====
## 이 표는 7개 .tres 파일에 들어가는 권장 수치를 코멘트로 보존한다.
## 디자인 의도:
##   보병  : 균형 (atk=10, def=10, mv=2, rng=1)  — 전선의 앵커
##   궁병  : 원거리 강/근접 약 (atk=12, def=4,  mv=2, rng=3)
##   기병  : 평지 압도 (atk=14, def=6,  mv=3, rng=1) — 산지/습지 불가
##   창병  : 기병 카운터 (atk=8,  def=14, mv=2, rng=1) — 기병에 강함
##   공성병: 성벽 필수 (atk=18, def=2,  mv=1, rng=2) — 이동 느림, 방어 최약
##   징집병: 대량/저전투력 (atk=5, def=5,  mv=1, rng=1) — 통제 난이도
##   정찰병: 정보 특화 (atk=2,  def=3,  mv=3, rng=1) — 전투 비의무