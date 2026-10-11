extends Node
## AudioManager — 오대십국 전략 게임 사운드 싱글톤 (Autoload)
##
## 책임:
##   1. 모든 SFX 자원을 사전 로드하여 AudioStreamPlayer 풀을 보유
##   2. 게임 이벤트 (공격/이동/칙령/턴/승패) → SFX 자동 트리거 디스패치
##   3. 카메라 셰이크·배너 슬라이드 같은 "쥬스" 연출을 함께 트리거
##   4. 전역 음소거/볼륨 슬라이더 지원
##
## API (자주 쓰는 것):
##   AudioManager.play_sfx("sword_clash")
##   AudioManager.play_event_based("attack", { unit_type_id = "cavalry" })
##   AudioManager.shake_camera(intensity, duration)
##   AudioManager.show_banner(title, subtitle, color)
##   AudioManager.set_muted(bool) / AudioManager.set_volume(0.0~1.0)
##
## 단일 사운드 자원이 같은 프레임에 두 번 재생되어도 둘 다 들려야
## 자연스러우므로 카테고리별 풀(예: combat=4 슬롯)을 둔다.

# ─────────────────────────────────────────────────────────────────────
# 카테고리 정의 — 같은 종류의 효과음이 겹쳐도 자연스럽게 들리도록 풀로 운용
# ─────────────────────────────────────────────────────────────────────
const POOL_SIZE := {
	"sword_clash": 4,
	"arrow_volley": 2,
	"spear_brace": 3,
	"siege_ram": 2,
	"march": 2,
	"morale_break": 2,
	"decree_gong": 2,
	"victory_fanfare": 1,
	"defeat_funeral": 1,
	"ui_select": 2,
	"ui_hover": 2,
	"turn_change": 2,
}

# ─────────────────────────────────────────────────────────────────────
# 유닛 타입별 공격 사운드 매핑 — 부대 종류에 따라 다른 SFX 트리거
# ─────────────────────────────────────────────────────────────────────
const ATTACK_SFX := {
	"cavalry":   "sword_clash",
	"spearmen":  "spear_brace",
	"archers":   "arrow_volley",
	"infantry":  "sword_clash",
	"siege":     "siege_ram",
	"scouts":    "sword_clash",
	"conscripts": "sword_clash",
}

# 기본 볼륨 (SFX 카테고리별 가중치)
const VOLUME_GAIN := {
	"sword_clash":   0.85,
	"arrow_volley":  0.90,
	"spear_brace":   0.85,
	"siege_ram":     1.00,
	"march":         0.70,
	"morale_break":  0.90,
	"decree_gong":   1.00,
	"victory_fanfare": 1.00,
	"defeat_funeral":  1.00,
	"ui_select":     0.55,
	"ui_hover":      0.35,
	"turn_change":   0.60,
}

const SFX_PATH := "res://assets/audio/"

# ─────────────────────────────────────────────────────────────────────
# 상태
# ─────────────────────────────────────────────────────────────────────
var _pools: Dictionary = {}        # sfx_name → Array[AudioStreamPlayer]
var _round_robin: Dictionary = {}  # sfx_name → int (다음 라운드 로빈 인덱스)
var _muted: bool = false
var _volume: float = 0.95
var _initialized: bool = false

# ─────────────────────────────────────────────────────────────────────
# 시그널 — 외부에서 카메라 셰이크/배너 연출을 후크할 수 있도록
# ─────────────────────────────────────────────────────────────────────
signal camera_shake_requested(intensity: float, duration: float)
signal banner_slide_requested(title: String, subtitle: String, color: Color)
signal damage_float_requested(world_pos: Vector2, text: String, color: Color, size_mult: float)
signal sfx_played(sfx_name: String, volume: float)

# ─────────────────────────────────────────────────────────────────────
# 라이프사이클
# ─────────────────────────────────────────────────────────────────────
func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS  # 일시정지 무관 — UI 는 계속 동작
	_initialize()


func _initialize() -> void:
	if _initialized:
		return
	_initialized = true
	print("[AudioManager] 초기화 — SFX 풀 구성")
	for sfx_name in POOL_SIZE.keys():
		var pool_size: int = int(POOL_SIZE[sfx_name])
		var pool: Array = []
		for i in range(pool_size):
			var player := AudioStreamPlayer.new()
			player.name = "SFX_%s_%d" % [sfx_name, i]
			player.bus = "Master"
			player.volume_db = linear_to_db(_volume * float(VOLUME_GAIN.get(sfx_name, 0.8)))
			# 자원 로드 시도 — 실패 시 조용히 폴백 (게임은 계속)
			var path: String = SFX_PATH + "sfx_" + sfx_name + ".wav"
			if ResourceLoader.exists(path):
				var stream: AudioStream = load(path)
				if stream is AudioStreamWAV:
					# WAV 기본값은 루프 ON 인 경우가 있어 명시적으로 OFF
					(stream as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_DISABLED
				player.stream = stream
				add_child(player)
				pool.append(player)
			else:
				push_warning("[AudioManager] SFX 자원 누락: %s (pool slot %d 미할당)" % [path, i])
		_pools[sfx_name] = pool
		_round_robin[sfx_name] = 0
	print("[AudioManager] 초기화 완료 — 카테고리 %d종" % POOL_SIZE.size())


# ─────────────────────────────────────────────────────────────────────
# 핵심 API: SFX 재생
# ─────────────────────────────────────────────────────────────────────
## 가장 단순한 재생 — 풀에서 한 슬롯을 골라 play().
## 이미 재생 중인 슬롯은 강제로 stop() 후 재생한다 (겹침 방지).
func play_sfx(sfx_name: String, volume_scale: float = 1.0, pitch_scale: float = 1.0) -> void:
	if _muted:
		return
	if not _initialized:
		_initialize()
	if not _pools.has(sfx_name):
		push_warning("[AudioManager] 알 수 없는 SFX: %s" % sfx_name)
		return
	var pool: Array = _pools[sfx_name]
	if pool.is_empty():
		return
	var rr_val: int = int(_round_robin[sfx_name])
	var pool_size: int = pool.size()
	var idx: int = rr_val % pool_size
	_round_robin[sfx_name] = (idx + 1) % pool_size
	var player: AudioStreamPlayer = pool[idx]
	if player.stream == null:
		return
	# 슬롯 점유 중이면 즉시 재시작
	if player.playing:
		player.stop()
	var gain: float = float(VOLUME_GAIN.get(sfx_name, 0.8))
	player.volume_db = linear_to_db(_volume * gain * volume_scale)
	player.pitch_scale = pitch_scale
	player.play()
	sfx_played.emit(sfx_name, player.volume_db)


## SFX 이름을 풀네임("sfx_sword_clash")이든 짧은 이름("sword_clash")이든 받아들인다.
func play_sfx_any(name_or_id: String, volume_scale: float = 1.0, pitch_scale: float = 1.0) -> void:
	var short: String = name_or_id
	if short.begins_with("sfx_"):
		short = short.substr(4)
	elif short.begins_with("SFX_"):
		short = short.substr(4)
	if short.ends_with(".wav"):
		short = short.substr(0, short.length() - 4)
	play_sfx(short, volume_scale, pitch_scale)


## 유닛 타입 기반 공격 사운드 트리거
func play_attack_sfx(unit_type_id: String) -> void:
	var sfx_name: String = ATTACK_SFX.get(unit_type_id, "sword_clash")
	play_sfx(sfx_name)


## 특정 임계값 이상의 큰 피해가 발생했을 때 강한 버전 + 셰이크
func play_big_hit_sfx(unit_type_id: String, casualties: int, threshold: int = 30) -> void:
	var sfx_name: String = ATTACK_SFX.get(unit_type_id, "sword_clash")
	play_sfx(sfx_name, 1.15, 0.92)  # 약간 묵직하게 (named arg → positional)
	if casualties >= threshold:
		# 카메라 셰이크 — 강도 비례 (0.4 ~ 1.0)
		var intensity: float = clampf(0.4 + float(casualties - threshold) * 0.012, 0.4, 1.6)
		shake_camera(intensity, 0.32)


# ─────────────────────────────────────────────────────────────────────
# 쥬스(Juice) 연출 — 카메라 셰이크 / 데미지 플로팅 / 배너 슬라이드
# ─────────────────────────────────────────────────────────────────────
## 화면 흔들림 요청 — 시그널을 통해 BattleMap 의 camera 가 받아 처리한다.
func shake_camera(intensity: float = 0.6, duration: float = 0.25) -> void:
	camera_shake_requested.emit(intensity, duration)


## 큰 데미지 플로팅 텍스트 — 시그널로 BattleMap 이 받는다.
func show_damage_float(world_pos: Vector2, text: String, color: Color = Color(1, 0.9, 0.4), size_mult: float = 1.0) -> void:
	damage_float_requested.emit(world_pos, text, color, size_mult)


## 화면 상단 슬라이드 배너 — 턴 전환/어명 하달 등
## color: 헤더 배경 색상
func show_banner(title: String, subtitle: String = "", color: Color = Color(0.85, 0.65, 0.18)) -> void:
	banner_slide_requested.emit(title, subtitle, color)


# ─────────────────────────────────────────────────────────────────────
# 전역 음소거 / 볼륨
# ─────────────────────────────────────────────────────────────────────
func set_muted(muted: bool) -> void:
	_muted = muted
	for pool_name in _pools.keys():
		var pool: Array = _pools[pool_name]
		for player in pool:
			if player is AudioStreamPlayer:
				(player as AudioStreamPlayer).volume_db = linear_to_db(_volume * float(VOLUME_GAIN.get(pool_name, 0.8))) if not muted else -80.0
	print("[AudioManager] 음소거: %s" % str(muted))


func set_volume(v: float) -> void:
	_volume = clampf(v, 0.0, 1.5)
	if _muted:
		return
	for pool_name in _pools.keys():
		var pool: Array = _pools[pool_name]
		var gain: float = float(VOLUME_GAIN.get(pool_name, 0.8))
		for player in pool:
			if player is AudioStreamPlayer:
				(player as AudioStreamPlayer).volume_db = linear_to_db(_volume * gain)


func toggle_mute() -> bool:
	set_muted(not _muted)
	return _muted


# ─────────────────────────────────────────────────────────────────────
# 유틸리티 — 다른 시스템에서 카테고리/SFX 이름 매핑 조회
# ─────────────────────────────────────────────────────────────────────
static func sfx_for_attack(unit_type_id: String) -> String:
	return ATTACK_SFX.get(unit_type_id, "sword_clash")


static func get_known_sfx_list() -> Array:
	return POOL_SIZE.keys()