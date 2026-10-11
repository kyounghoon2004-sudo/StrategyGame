class_name Unit
extends RefCounted

## 전장 위 단일 부대 인스턴스.
## UnitType(병과 정의) + 병력 수 + 상태(사기/보급/위치/진영)를 묶는다.
## Godot 4.x RefCounted — 풀링 없이 생성/소멸.

# Preloads to avoid global-class parse-order issues during --import
const _UnitTypeGD = preload("res://scripts/combat/unit_type.gd")
const _HexCellGD = preload("res://scripts/core/hex_cell.gd")
const _TerrainModsGD = preload("res://scripts/combat/terrain_mods.gd")
const _MovementCalcGD = preload("res://scripts/combat/movement_calculator.gd")
const _MoraleSystemGD = preload("res://scripts/combat/morale_system.gd")

## ===== 초기화 =====
var unit_type  # : UnitType (untyped to avoid global parse order)
var soldier_count: int = 100
var current_morale: float = 70.0
var current_supply_days: float = 30.0
var hex_q: int = 0
var hex_r: int = 0
var faction: StringName = &"neutral"


## 지휘관 존재 시 게인 배수. 밸런스 조정은 MoraleSystem에서 통제.
var commander_bonus: float = 1.0   ## 1.0 = 무, >1 = 사기 이득


## ===== 파생 초기화 (편의 생성자 유사) =====
func _init(t, faction_: String = "neutral", count_: int = 100):
	unit_type = t
	faction = StringName(faction_) if faction_ != "" else &"neutral"
	soldier_count = count_
	current_morale = float(t.get("base_morale")) if t != null else 70.0
	current_supply_days = 30.0
	hex_q = 0
	hex_r = 0


## ===== 효과적인 전투 스탯 =====

## 유효 공격력 = 기본 공격 × (병력 가중치) × (사기 보정) × (지형 보정)
func get_effective_attack(terrain: int = 0) -> float:
	# 0 == HexCell.TerrainType.PLAINS (avoid global HexCell in default)
	var base = int(unit_type.get("attack")) if unit_type else 10
	var log_scale: float = log(float(soldier_count) / 100.0 + 1.0) * 0.6 + 0.5
	var morale_factor: float = get_morale_modifier()
	var terrain_factor: float = float(unit_type.get("terrain_combat_mod").get(terrain, 1.0)) if unit_type and unit_type.get("terrain_combat_mod") else 1.0
	# fallback to UnitType.get_terrain_combat_mod if available
	if unit_type and unit_type.has_method("get_terrain_combat_mod"):
		terrain_factor = float(unit_type.get_terrain_combat_mod(terrain))
	var conscript_factor: float = 1.0 - (soldier_count * float(unit_type.get("supply_per_100_per_day")) * 0.00002) if unit_type else 1.0
	return float(base) * float(soldier_count) / 100.0 * morale_factor * terrain_factor * maxf(0.1, conscript_factor)


## 유효 방어력 = 기본 방어 × (병력 가중치 적음) × 사기 보정 × 지형 방어 보너스
func get_effective_defense(terrain: int = 0) -> float:
	var base = int(unit_type.get("defense")) if unit_type else 10
	var size_factor: float = 1.0 + log(float(soldier_count) / 100.0 + 1.0) * 0.25
	var morale_factor: float = get_morale_modifier()
	var terrain_factor: float = float(_TerrainModsGD.get_defense_bonus(terrain))
	var unit_terrain_mod: float = 1.0
	if unit_type and unit_type.has_method("get_terrain_combat_mod"):
		unit_terrain_mod = float(unit_type.get_terrain_combat_mod(terrain))
	return float(base) * size_factor * morale_factor * terrain_factor * unit_terrain_mod


## ===== 이동력 =====
func get_movement_points() -> int:
	return int(_MovementCalcGD.get_movement_points(unit_type, soldier_count))


## ===== 사상 =====
## amount: 감소하는 병사 수
func take_casualties(amount: int) -> int:
	var actual: int = mini(amount, soldier_count)
	soldier_count -= actual
	var _death_ratio: float = float(actual) / float(maxi(1, soldier_count + actual))
	## 사망 비율에 따른 즉각 사기 하락
	current_morale -= float(amount) / float(maxi(1, soldier_count + amount)) * 8.0
	current_morale = clampf(current_morale, 0.0, 100.0)
	return actual


## ===== 보급 =====
func consume_supply(days: int) -> float:
	## days일 동안 식량 소모 → 남은 식량일 수 감소, 부족 시 사기 하락
	var daily_use: float = float(unit_type.get("supply_per_100_per_day")) * float(soldier_count) / 100.0 if unit_type else 1.0
	var used: float = daily_use * float(days)
	current_supply_days -= used
	var shortage_ratio: float = maxf(0.0, -current_supply_days) / maxf(1.0, daily_use)  ## 부족 일수
	if shortage_ratio > 0.0:
		var penalty: float = minf(30.0, shortage_ratio * 15.0)
		current_morale -= penalty
		current_morale = clampf(current_morale, 0.0, 100.0)
	return maxf(0.0, current_supply_days)


## ===== 부대 분할 =====
func split(amount: int):
	amount = clampi(amount, 1, soldier_count - 1)
	var new_unit = Unit.new(unit_type, faction)
	new_unit.soldier_count = amount
	new_unit.current_morale = current_morale
	new_unit.current_supply_days = current_supply_days
	var self_share: float = float(new_unit.soldier_count) / float(maxi(1, soldier_count + new_unit.soldier_count))
	new_unit.current_supply_days *= self_share
	current_supply_days *= (1.0 - self_share)
	soldier_count -= amount
	return new_unit


## ===== 부대 합치기 =====
func merge(other) -> void:
	#(추후 디버깅 참고) 같은 병과·같은 진영이 아니면 무시.
	if other == null:
		return
	var other_type = other.get("unit_type")
	var self_type = unit_type
	if other_type == null or self_type == null:
		return
	if String(other_type.get("id")) != String(self_type.get("id")):
		push_warning("Unit.merge: 다른 병과 결합 시도 무시됨 (%s vs %s)" % [other_type.get("id"), self_type.get("id")])
		return
	if other.get("faction") != faction:
		push_warning("Unit.merge: 다른 진영 결합 시도 무시됨 (%s vs %s)" % [other.get("faction"), faction])
		return
	## self ← self + other (병력·사기·보급 합치고 평균 사기 계산)
	soldier_count += int(other.get("soldier_count"))
	var other_morale: float = float(other.get("current_morale"))
	var other_cnt: int = int(other.get("soldier_count"))
	var avg_morale: float = (current_morale * float(soldier_count - other_cnt) + other_morale * float(other_cnt)) / float(maxi(1, soldier_count))
	current_morale = avg_morale
	current_supply_days += float(other.get("current_supply_days"))
	other.set("current_supply_days", 0.0)
	other.set("soldier_count", 0)


## ===== 사기 보정 (전투용 곱셈 계수) =====
func get_morale_modifier() -> float:
	return float(_MoraleSystemGD.get_modifier_from_morale(current_morale))



## ===== 디버깅 문자열 =====
func _to_string() -> String:
	var tname: String = ""
	if unit_type:
		tname = String(unit_type.get("name_kr"))
		if tname == "":
			tname = String(unit_type.get("name_en"))
	return "%s [%s] %d명 사기=%.1f 보급=%.1f일" % [
		tname, faction, soldier_count, current_morale, current_supply_days
	]
