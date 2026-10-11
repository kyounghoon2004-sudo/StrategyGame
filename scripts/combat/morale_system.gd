class_name MoraleSystem
extends RefCounted

## 사기 수치 관리 + 전투 후 사기 변화 계산.
## 임계값: 정상 → 동요 → 패주 → 항복

# ---- 사기 임계값 (0~100 스케일) ----
const STATE_STEADY := 60.0     ## 정상 하한
const STATE_WAVERING := 40.0   ## 동요
const STATE_PANIC := 20.0      ## 패주 (부대가 명령 거부 시작)
const STATE_BREAK := 5.0       ## 사실상 항복

# ---- 사기 상태 라벨 ----
static func get_state_label(morale: float) -> String:
	if morale >= STATE_STEADY: return "정상"
	elif morale >= STATE_WAVERING: return "동요"
	elif morale >= STATE_PANIC: return "패주"
	elif morale >= STATE_BREAK: return "붕괴"
	else: return "항복"

# ---- 전투 후 사기 변화 ----
## won: 해당 부대가 승리한 경우 true
## own_loss_ratio: 본 부대가 잃은 병력 비율 (0~1)
## enemy_loss_ratio: 적이 잃은 병력 비율 (0~1)
static func morale_after_battle(current_morale: float, won: bool, own_loss_ratio: float, enemy_loss_ratio: float) -> float:
	var delta := 0.0
	if won:
		# 승리 시: 잃은 비율만큼 일부는 회복, 대신 승리 보너스
		delta += 2.0
		delta -= own_loss_ratio * 8.0    # 큰 승리는 적 손실로 인한 모멘텀
		# 압승은 사기 보너스
		if enemy_loss_ratio > 0.3 and own_loss_ratio < 0.2:
			delta += 4.0
	else:
		# 패배 시: 큰 손실 + 손실 비율에 비례
		delta -= 6.0
		delta -= own_loss_ratio * 12.0
		# 적이 거의 안 죽었는데 우리가 많이 잃은 경우 더 큰 하락
		if own_loss_ratio > 0.2 and enemy_loss_ratio < 0.1:
			delta -= 4.0

	return clampf(current_morale + delta, 0.0, 100.0)


# ---- 보급 기반 사기 감소 ----
## current_supply_days: 남은 보급 일수 (음수면 부족)
## daily_consumption: 1일 식량 소모량
static func morale_after_supply(current_morale: float, current_supply_days: float, daily_consumption: float) -> float:
	if current_supply_days >= 0:
		return current_morale
	# 부족한 경우: 1일 부족당 사기 -3, 큰 부족 시 더 큰 감소
	var days_short := -current_supply_days
	var penalty := days_short * 3.0
	# 식량 부족이 절대적인 경우(즉, 보급 끊김) 추가 페널티
	if daily_consumption <= 0:
		penalty += 2.0
	return clampf(current_morale - penalty, 0.0, 100.0)


# ---- 지휘관 존재 효과 ----
## commander_bonus: 1.0 = 없음, 1.1~1.3 = 능력 있는 지휘관
## 사기 하락폭을 줄이거나 상승폭을 늘림
static func apply_commander_effect(morale_change: float, commander_bonus: float) -> float:
	if morale_change >= 0:
		return morale_change * commander_bonus
	else:
		# 하락은 보너스가 클수록 완만해짐 (예: -10 * 1.2 = -8.33)
		return morale_change / commander_bonus


# ---- 징집병 비율 효과 ----
## 부대 내 징집병 비율이 높을수록 사기 변동성이 커짐 (좋을 때 덜 오르고, 나쁠 때 더 떨어짐)
## 변경된 사기값 자체를 반환
static func apply_conscript_effect(base_morale: float, conscript_ratio: float) -> float:
	if conscript_ratio <= 0:
		return base_morale
	# 징집병 100% = 사기 변동 ±20% 가중 (불안정)
	# 50% = ±10%, 25% = ±5%
	var variance: float = conscript_ratio * 0.4
	# 사기가 50을 기준으로 멀어질수록 더 불안정해짐 (양쪽 모두)
	var distance_from_neutral: float = absf(base_morale - 50.0)
	var normalized_distance: float = distance_from_neutral / 50.0  # 0~1
	# 사기가 비정상적일수록 징집병 부대는 더 큰 폭으로 변동
	var multiplier: float = 1.0 + (normalized_distance * variance * 2.0)
	# 50에서 멀어지는 방향으로 적용
	var pulled: float = 50.0 + (base_morale - 50.0) * multiplier
	return clampf(pulled, 0.0, 100.0)


# ---- 참모 제거 효과 ----
## staff_grade: 참모 등급 (1.0~3.0) — 제거 시 단발성 사기 하락
static func staff_loss_penalty(staff_grade: float) -> float:
	return -1.0 * staff_grade * 4.0   # 등급 1 = -4, 등급 2 = -8


# ---- 사기 강제 패주 체크 ----
## 부대가 다음 명령을 따를지 말지 (패주 = false)
static func will_obey(morale: float) -> bool:
	return morale >= STATE_PANIC


# ---- 사기 → 전투 배율 (Unit.get_morale_modifier() 호환) ----
## 사기 0 → 0.5배, 사기 50 → 0.85배, 사기 100 → 1.1배
## (전투에서 사기는 전반적으로 위력에 +0~+10% 보너스를 주는 형태로 설계)
static func get_modifier_from_morale(morale: float) -> float:
	return 0.5 + clampf(morale, 0.0, 100.0) / 200.0  # 0.5 ~ 1.0 (50->0.75, 70->0.85, 100->1.0)


# ---- 사기 강제 항복 체크 ----
static func will_capitulate(morale: float) -> bool:
	return morale < STATE_BREAK