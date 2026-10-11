class_name CampaignManager
extends Node
## 캠페인 데이터 로더 & 진행 상태 매니저 — 오대십국 로그라이트 장군 시뮬레이션
## - data/campaigns/campaign_01.json / character_profiles.json / events_table.json 파싱
## - current_mission_index (1~4), general_renown(0~100), king_trust(0~100), staff_profile 유지
## - 다음 임무 로드 시 명성 비례 병과 생성 + BattleMap 전달 (맵 크기/지형/적 배치)
## - 일반 병력/군량은 임무 종료 시 왕에게 반환됨(로그라이트 설계) — 다음 임무마다 renown에 비례해 재생성

# ─────────────────────────────────────────────
# 경로 상수
# ─────────────────────────────────────────────
const CAMPAIGN_JSON_PATH := "res://data/campaigns/campaign_01.json"
const CHARACTER_JSON_PATH := "res://data/campaigns/character_profiles.json"
const EVENTS_JSON_PATH := "res://data/campaigns/events_table.json"

const UNIT_TYPE_PATHS: Dictionary = {
	"infantry": "res://data/unit_types/infantry.tres",
	"archers": "res://data/unit_types/archers.tres",
	"cavalry": "res://data/unit_types/cavalry.tres",
	"spearmen": "res://data/unit_types/spearmen.tres",
	"siege": "res://data/unit_types/siege.tres",
	"conscripts": "res://data/unit_types/conscripts.tres",
	"scouts": "res://data/unit_types/scouts.tres",
}

# 지형 이름 → HexCell.TerrainType 매핑
const TERRAIN_NAME_TO_ENUM: Dictionary = {
	"PLAINS": 0, "MOUNTAINS": 1, "FOREST": 2, "SWAMP": 3,
	"FORTRESS": 4, "VILLAGE": 5, "ROAD": 6,
}

# ─────────────────────────────────────────────
# 시그널
# ─────────────────────────────────────────────
signal campaign_loaded(campaign_id: String)
signal mission_prepared(chapter: int, mission_id: String)
signal mission_settled(result: Dictionary)
signal campaign_completed(ending_id: String)
signal game_over_executed(reason: String)

# ─────────────────────────────────────────────
# 상태 — 영구 자산 (Carry-over)
# ─────────────────────────────────────────────
var current_mission_index: int = 1        ## 1~4 (GDD 1장~4장)
var general_renown: int = 50              ## 장군의 명성 — 초기값 50, 임무 성과에 따라 가감
var king_trust: int = 55                  ## 왕의 신임도 0~100 — 초기값 55 (campaign_01 persistent_resources.king_trust.start)
var staff_profile: Dictionary = {}        ## {id, name_kr, name_han, personality, ability, branch}
var consecutive_failures: int = 0
var narrative_flags: Array = []           ## Array[String] — 모든 선택의 기록
var events_drawn_this_run: Array = []     ## Array[String] event id — 중복 방지
var advisor_branch: String = "pragmatic_tactician" ## benevolent_guardian / stern_remonstrator / pragmatic_tactician

# 캠페인 임시 자원 (임무 종료 시 일부는 왕에게 반환되나, 다음 임무에 영향을 주므로 추적)
var supply_days: float = 12.0
var army_morale: float = 70.0
var gold_taels: int = 300
var civilian_trust: int = 50
var initial_ally_total_for_mission: int = 0
var initial_enemy_total_for_mission: int = 0
var selected_siege_approach: String = ""  ## 4장 전용: assault / siege_encirclement / infiltration
var is_game_over: bool = false

# ─────────────────────────────────────────────
# 원본 데이터 캐시
# ─────────────────────────────────────────────
var campaign_data: Dictionary = {}
var character_data: Dictionary = {}
var events_data: Dictionary = {}
var _unit_type_cache: Dictionary = {}  ## id -> UnitType Resource

# ─────────────────────────────────────────────
# 초기화
# ─────────────────────────────────────────────
func _ready() -> void:
	_preload_unit_types()
	var ok := load_campaign_data()
	if not ok:
		push_warning("[CampaignManager] 캠페인 데이터 로드 실패 — 기본값으로 동작")

func _preload_unit_types() -> void:
	for uid in UNIT_TYPE_PATHS.keys():
		var path: String = UNIT_TYPE_PATHS[uid]
		if ResourceLoader.exists(path):
			var res: Resource = load(path)
			if res != null:
				_unit_type_cache[uid] = res
		else:
			push_warning("[CampaignManager] UnitType 리소스 없음: %s" % path)

# ─────────────────────────────────────────────
# JSON 로더
# ─────────────────────────────────────────────
func _load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("[CampaignManager] 파일 없음: %s" % path)
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("[CampaignManager] 파일 열기 실패: %s" % path)
		return {}
	var text: String = file.get_as_text()
	file.close()
	var json := JSON.new()
	var err: int = json.parse(text)
	if err != OK:
		push_error("[CampaignManager] JSON 파싱 실패 %s: %s (at line %d)" % [path, json.get_error_message(), json.get_error_line()])
		return {}
	var data = json.get_data()
	if data is Dictionary:
		return data as Dictionary
	push_error("[CampaignManager] JSON 루트가 Dictionary가 아님: %s" % path)
	return {}

## data/campaigns/*.json 3종을 파싱하고 상태 초기화
func load_campaign_data() -> bool:
	campaign_data = _load_json(CAMPAIGN_JSON_PATH)
	character_data = _load_json(CHARACTER_JSON_PATH)
	events_data = _load_json(EVENTS_JSON_PATH)

	if campaign_data.is_empty():
		push_error("[CampaignManager] campaign_01.json 로드 실패")
		return false

	# persistent_resources 값으로 초기 신임도/보급/사기 등 설정 (원본 구조 완벽 준수)
	var persist: Dictionary = campaign_data.get("persistent_resources", {}) as Dictionary
	if persist.has("king_trust"):
		var kt: Dictionary = persist["king_trust"] as Dictionary
		king_trust = int(kt.get("start", 55))
		king_trust = clampi(king_trust, 0, 100)
	if persist.has("supply_days"):
		var sd: Dictionary = persist["supply_days"] as Dictionary
		supply_days = float(sd.get("start", 12))
	if persist.has("army_morale"):
		var am: Dictionary = persist["army_morale"] as Dictionary
		army_morale = float(am.get("start", 70))
	if persist.has("gold_taels"):
		var gt: Dictionary = persist["gold_taels"] as Dictionary
		gold_taels = int(gt.get("start", 300))
	if persist.has("civilian_trust"):
		var ct: Dictionary = persist["civilian_trust"] as Dictionary
		civilian_trust = int(ct.get("start", 50))

	# staff_profile 초기화 (character_profiles.json → advisor_seo_yuseon)
	_init_staff_profile()

	# 런타임 초기화
	current_mission_index = 1
	general_renown = 50
	consecutive_failures = 0
	narrative_flags.clear()
	events_drawn_this_run.clear()
	advisor_branch = "pragmatic_tactician"
	selected_siege_approach = ""
	is_game_over = false

	var cid: String = str(campaign_data.get("campaign_id", "campaign_01"))
	print("[CampaignManager] 캠페인 로드 완료: %s (%s) — missions=%d, king_trust=%d, renown=%d" % [
		cid, str(campaign_data.get("title_kr", "")), get_mission_count(), king_trust, general_renown
	])
	campaign_loaded.emit(cid)
	return true

func _init_staff_profile() -> void:
	# character_profiles.json 구조: { characters: [ {id, role, name_kr...}, ... ] }
	var chars: Array = character_data.get("characters", []) as Array
	var advisor: Dictionary = {}
	for ch in chars:
		if ch is Dictionary and str(ch.get("role", "")) == "strategist":
			advisor = ch as Dictionary
			break
	# fallback: id가 advisor_seo_yuseon인 캐릭터 탐색
	if advisor.is_empty():
		for ch in chars:
			if ch is Dictionary and str(ch.get("id", "")) == "advisor_seo_yuseon":
				advisor = ch as Dictionary
				break
	if advisor.is_empty():
		push_warning("[CampaignManager] 참모 캐릭터를 찾지 못함 — 기본값 생성")
		staff_profile = {
			"id": "advisor_seo_yuseon",
			"name_kr": "서유선",
			"name_han": "徐有先",
			"personality": "신중",
			"ability": 72,
			"branch": "pragmatic_tactician",
			"title_kr": "군사",
		}
		return

	var traits: Array = advisor.get("personality_traits", ["신중"]) as Array
	var personality: String = str(traits[0]) if traits.size() > 0 else "신중"
	# 능력치는 gameplay_modifiers 또는 고정 추정 — campaign_01은 수치형 ability 없음이므로 보수적 기본값 70
	var ability: int = 70
	var mods: Dictionary = advisor.get("gameplay_modifiers", {}) as Dictionary
	if mods.has("recon_accuracy_bonus"):
		ability = 70 + int(float(mods.get("recon_accuracy_bonus", 0.2)) * 20)
	# advisor_branching 기반 보정 없음 — 초기엔 중립

	staff_profile = {
		"id": str(advisor.get("id", "advisor_seo_yuseon")),
		"name_kr": str(advisor.get("name_kr", "서유선")),
		"name_han": str(advisor.get("name_han", "徐有先")),
		"personality": personality,
		"ability": clampi(ability, 40, 95),
		"branch": "pragmatic_tactician",
		"title_kr": str(advisor.get("title_kr", "군사")),
		"archetype": str(advisor.get("archetype", "신중한 정통 지략가")),
	}

# ─────────────────────────────────────────────
# 미션 접근자
# ─────────────────────────────────────────────
func get_mission_count() -> int:
	var missions: Array = campaign_data.get("missions", []) as Array
	return missions.size()

func get_current_mission() -> Dictionary:
	return get_mission(current_mission_index)

func get_mission(chapter: int) -> Dictionary:
	var missions: Array = campaign_data.get("missions", []) as Array
	if chapter < 1 or chapter > missions.size():
		push_warning("[CampaignManager] 잘못된 chapter: %d (size %d)" % [chapter, missions.size()])
		return {}
	var m = missions[chapter - 1]
	if m is Dictionary:
		# 4장 공성책 선택이 반영된 병합본 반환
		if chapter == 4 and selected_siege_approach != "":
			return _merge_siege_approach(m as Dictionary, selected_siege_approach)
		return m as Dictionary
	return {}

func _merge_siege_approach(mission: Dictionary, approach_id: String) -> Dictionary:
	# siege_approaches 배열에서 approach_id에 해당하는 원소의 map_config/turn_limit/victory 등을 mission 레벨로 병합
	var approaches: Array = mission.get("siege_approaches", []) as Array
	var chosen: Dictionary = {}
	for a in approaches:
		if a is Dictionary and str(a.get("id", "")) == approach_id:
			chosen = a as Dictionary
			break
	if chosen.is_empty():
		return mission
	var merged: Dictionary = mission.duplicate(true)
	# turn_limit 덮어쓰기
	if chosen.has("turn_limit"):
		merged["turn_limit"] = chosen["turn_limit"]
	# map_config 덮어쓰기 — 접근법별 지형/헥스 수가 다름 (문자열 설명이지만 terrain_hex_count가 있으면 덮어쓰기)
	# campaign_01의 siege_approaches는 terrain_hex_count를 map_config_kr 문자열로만 기술하므로,
	# 실제 난도 반영은 후속 prepare_battle_map에서 chosen을 직접 참조하도록 selected_siege_approach를 유지
	merged["_siege_chosen"] = chosen
	return merged

func get_character_by_id(char_id: String) -> Dictionary:
	var chars: Array = character_data.get("characters", []) as Array
	for ch in chars:
		if ch is Dictionary and str(ch.get("id", "")) == char_id:
			return ch as Dictionary
	var sup: Array = character_data.get("supporting_cast", []) as Array
	for ch in sup:
		if ch is Dictionary and str(ch.get("id", "")) == char_id:
			return ch as Dictionary
	return {}

func get_king_profile() -> Dictionary:
	return get_character_by_id("lord_zhuangzong")

func get_advisor_profile() -> Dictionary:
	return get_character_by_id("advisor_seo_yuseon")

func get_events_table() -> Array:
	var evts: Array = events_data.get("events", []) as Array
	return evts

# ─────────────────────────────────────────────
# 맵 크기 파싱: "15×12 헥스" → Vector2i(15,12) / "20×15" → Vector2i(20,15)
# ─────────────────────────────────────────────
func _parse_map_size(size_kr: String) -> Vector2i:
	var s: String = size_kr.strip_edges()
	# 숫자 × 숫자 패턴 추출 (×, x, X 모두 허용)
	var regex := RegEx.new()
	regex.compile("(\\d+)\\s*[×xX]\\s*(\\d+)")
	var m: RegExMatch = regex.search(s)
	if m != null:
		var q: int = int(m.get_string(1))
		var r: int = int(m.get_string(2))
		return Vector2i(q, r)
	# fallback
	return Vector2i(20, 15)

# ─────────────────────────────────────────────
# 명성 비례 아군 초기 병과 생성
# - general_renown 0→0.6배, 50→1.0배, 100→1.45배 선형 보간
# - king_trust 80+ 시 정예 보병 +100 (GDD 규칙)
# - 참모 분기 보너스 반영 가능성
# 반환: Array[Dictionary] {unit_type, count, morale}
# ─────────────────────────────────────────────
func generate_initial_forces_for_current_mission() -> Array:
	var mission: Dictionary = get_current_mission()
	if mission.is_empty():
		return []
	# 원본 forces 키 우선순위: player_starting → player_starting_estimate → forces estimates
	var forces: Dictionary = mission.get("forces", {}) as Dictionary
	var base_array: Array = []
	if forces.has("player_starting"):
		base_array = forces["player_starting"] as Array
	elif forces.has("player_starting_estimate"):
		base_array = forces["player_starting_estimate"] as Array
	else:
		# GDD상에 별도 표기가 없는 경우 — 빈 배열이 아니라면 경고
		push_warning("[CampaignManager] player_starting 배열 없음 (mission %s)" % str(mission.get("id", "")))
		return []

	var scale: float = 0.60 + (float(general_renown) / 100.0) * 0.85  # 0.6~1.45
	var result: Array = []
	var total: int = 0
	for entry in base_array:
		if not (entry is Dictionary):
			continue
		var e: Dictionary = entry as Dictionary
		var utype: String = str(e.get("unit_type", ""))
		if utype == "" or not _unit_type_cache.has(utype):
			push_warning("[CampaignManager] 알 수 없는 unit_type: %s" % utype)
			continue
		var base_cnt: int = int(e.get("count", 100))
		var base_morale: float = float(e.get("morale", _unit_type_cache[utype].base_morale if _unit_type_cache.has(utype) else 70.0))
		var scaled_cnt: int = int(round(float(base_cnt) * scale))
		# 최소 병력 보장 (징집병 제외 최소 20)
		if utype != "conscripts":
			scaled_cnt = maxi(scaled_cnt, 20)
		else:
			scaled_cnt = maxi(scaled_cnt, 10)
		# 사기 소폭 보정: 명성 높을수록 사기 +5, 낮을수록 -5
		var morale_adj: float = (scale - 1.0) * 12.0  # -4.8 ~ +5.4
		var adj_morale: float = clampf(base_morale + morale_adj, 40.0, 92.0)
		# 참모 분기: 인자한 수호자 → 사기 +5
		if advisor_branch == "benevolent_guardian":
			adj_morale = minf(adj_morale + 3.0, 92.0)

		result.append({
			"unit_type": utype,
			"count": scaled_cnt,
			"morale": adj_morale,
			"original_count": base_cnt,
		})
		total += scaled_cnt

	# king_trust 80 이상 — 정예 보병 +100 (character_profiles king_trust_system.thresholds 80~100)
	if king_trust >= 80:
		var bonus_added: bool = false
		for r in result:
			if r is Dictionary and str(r.get("unit_type", "")) == "infantry":
				r["count"] = int(r["count"]) + 100
				total += 100
				bonus_added = true
				break
		if not bonus_added:
			result.append({"unit_type": "infantry", "count": 100, "morale": 78.0, "original_count": 100})
			total += 100

	initial_ally_total_for_mission = total
	# 적 총수 캐시
	initial_enemy_total_for_mission = _calc_enemy_total(mission)
	return result

func _calc_enemy_total(mission: Dictionary) -> int:
	var forces: Dictionary = mission.get("forces", {}) as Dictionary
	var arr: Array = forces.get("enemy", []) as Array
	var sum: int = 0
	for e in arr:
		if e is Dictionary:
			sum += int(e.get("count", 0))
	return sum

func get_enemy_forces_for_current_mission() -> Array:
	var mission: Dictionary = get_current_mission()
	if mission.is_empty():
		return []
	var forces: Dictionary = mission.get("forces", {}) as Dictionary
	var arr: Array = forces.get("enemy", []) as Array
	var result: Array = []
	for e in arr:
		if e is Dictionary:
			result.append(e.duplicate(true))
	return result

# ─────────────────────────────────────────────
# BattleMap 전달 — 전장 초기화
# battle_map: Node2D (BattleMap.tscn 인스턴스) — 내부에 HexGrid(Camera2D) 구조를 가정
# 반환: 성공 여부
# ─────────────────────────────────────────────
func prepare_battle_map(battle_map: Node) -> bool:
	if battle_map == null:
		push_error("[CampaignManager] battle_map이 null")
		return false
	var mission: Dictionary = get_current_mission()
	if mission.is_empty():
		push_error("[CampaignManager] current mission이 비어있음 (index %d)" % current_mission_index)
		return false

	# 1) 맵 크기 결정
	var map_cfg: Dictionary = mission.get("map_config", {}) as Dictionary
	var size_str: String = str(map_cfg.get("size_kr", "20×15"))
	var map_size: Vector2i = _parse_map_size(size_str)
	# BattleMap의 전술 캔버스 크기를 우선한다. 캠페인 JSON의 15x12는
	# 서사 데이터용 기본값이며, 현재 전술 화면은 36x24를 고정으로 사용한다.
	if battle_map.has_method("get_tactical_grid_size"):
		var tactical_size: Variant = battle_map.call("get_tactical_grid_size")
		if tactical_size is Vector2i:
			map_size = tactical_size
	# 4장 공성책 선택 시 map_size 조정 (siege_approach별 크기는 동일하나 turn_limit/특수 규칙은 다름)
	var siege_chosen: Dictionary = mission.get("_siege_chosen", {}) as Dictionary
	if not siege_chosen.is_empty() and siege_chosen.has("map_config_kr"):
		# map_config_kr은 문자열 설명이므로 size는 유지, turn_limit만 siege_chosen 값으로 이미 병합됨
		pass

	# 2) HexGrid 노드 찾기
	var hex_grid: Node = battle_map.get_node_or_null("HexGrid")
	if hex_grid == null:
		# 최상위가 HexGrid인 경우도 허용
		if battle_map.has_method("create_grid"):
			hex_grid = battle_map
		else:
			push_error("[CampaignManager] BattleMap에서 HexGrid 노드를 찾지 못함")
			return false

	# 3) 지형 생성
	_create_terrain_on_grid(hex_grid, map_size, mission)

	# 4) 아군/적군 Unit 배치
	var ally_forces: Array = generate_initial_forces_for_current_mission()
	var enemy_forces: Array = get_enemy_forces_for_current_mission()
	_place_units_on_grid(hex_grid, map_size, ally_forces, enemy_forces, mission)

	# 5) HUD 갱신 (BattleHUD가 있으면)
	_refresh_hud()

	print("[CampaignManager] 전장 초기화 완료 — %s (chapter %d) size=%dx%d ally=%d enemy=%d renown=%d trust=%d" % [
		str(mission.get("title_kr", mission.get("id", ""))),
		current_mission_index, map_size.x, map_size.y,
		initial_ally_total_for_mission, initial_enemy_total_for_mission,
		general_renown, king_trust,
	])
	mission_prepared.emit(current_mission_index, str(mission.get("id", "")))
	return true

func _create_terrain_on_grid(hex_grid: Node, map_size: Vector2i, mission: Dictionary) -> void:
	# 기존 지형 제거 후 재생성
	if hex_grid.has_method("create_grid"):
		hex_grid.call("create_grid", map_size.x, map_size.y, "")

	# terrain_hex_count 파싱
	var map_cfg: Dictionary = mission.get("map_config", {}) as Dictionary
	var hex_cnt: Dictionary = map_cfg.get("terrain_hex_count", {}) as Dictionary
	if hex_cfg_is_empty(hex_cnt):
		# count가 없으면 varied 패턴으로 대체
		if hex_grid.has_method("create_grid"):
			hex_grid.call("create_grid", map_size.x, map_size.y, "varied")
		if hex_grid.has_method("generate_hexes"):
			hex_grid.call("generate_hexes")
		return

	# 총 셀 수 검증
	var total_cells: int = map_size.x * map_size.y
	var sum_counts: int = 0
	for v in hex_cnt.values():
		sum_counts += int(v)
	# PLAINS가 비어있는 경우 나머지를 PLAINS로
	var plains_extra: int = total_cells - sum_counts
	if plains_extra > 0:
		var current_plains: int = int(hex_cnt.get("PLAINS", 0))
		hex_cnt["PLAINS"] = current_plains + plains_extra

	# HexCell enum 매핑을 이용해 cell_data terrain 재할당
	if not hex_grid.get("cell_data") is Dictionary:
		push_warning("[CampaignManager] HexGrid.cell_data 접근 불가 — 기본 지형으로 진행")
		if hex_grid.has_method("generate_hexes"):
			hex_grid.call("generate_hexes")
		return

	var cell_data: Dictionary = hex_grid.get("cell_data") as Dictionary
	# 모든 키를 수집하여 무작위 배정 풀 생성
	var keys: Array = cell_data.keys()
	keys.shuffle() # RNG — deterministic 필요 시 seed 고정 가능

	# 지형별 카운터
	var terrain_pool: Array = [] # Array[int enum]
	for tname in hex_cnt.keys():
		var enum_val: Variant = TERRAIN_NAME_TO_ENUM.get(str(tname), null)
		if enum_val == null:
			push_warning("[CampaignManager] 알 수 없는 지형 키: %s" % str(tname))
			continue
		var cnt: int = int(hex_cnt[tname])
		for i in range(cnt):
			terrain_pool.append(int(enum_val))

	# pool이 cell 수보다 많으면 자르고, 적으면 PLAINS로 메움
	if terrain_pool.size() > keys.size():
		terrain_pool.resize(keys.size())
	elif terrain_pool.size() < keys.size():
		for i in range(keys.size() - terrain_pool.size()):
			terrain_pool.append(TERRAIN_NAME_TO_ENUM["PLAINS"])

	terrain_pool.shuffle()

	# FORTRESS/성벽 클러스터 보정: campaign 맵은 중앙에 요새가 모여야 하므로, FORTRESS는 중앙 영역에 재배치
	# 간단 보정 — FORTRESS 개수(3~6개)는 중앙 4x4 영역에 먼저 할당
	var fortress_count: int = int(hex_cnt.get("FORTRESS", 0))
	if fortress_count > 0:
		var cx: int = map_size.x / 2
		var cy: int = map_size.y / 2
		var center_keys: Array = []
		for k in keys:
			var parts: PackedStringArray = str(k).split(",")
			if parts.size() != 2:
				continue
			var q: int = int(parts[0])
			var r: int = int(parts[1])
			if absi(q - cx) <= 2 and absi(r - cy) <= 2:
				center_keys.append(k)
		center_keys.shuffle()
		# 중앙 키 중 fortress_count만큼은 FORTRESS로 강제, 나머지는 pool에서 제거된 FORTRESS만큼 랜덤 재배치
		# 구현 단순화: center_keys 앞 fortress_count개를 FORTRESS로, terrain_pool에서 해당 수만큼 FORTRESS 제거 후 PLAINS로 교체
		var fortress_placed: int = 0
		var fortress_indices_in_pool: Array = []
		for i in range(terrain_pool.size()):
			if int(terrain_pool[i]) == TERRAIN_NAME_TO_ENUM["FORTRESS"]:
				fortress_indices_in_pool.append(i)
		# center에 배치
		for i in range(mini(fortress_count, center_keys.size())):
			var ck: String = center_keys[i]
			var cell = cell_data.get(ck)
			if cell != null and cell.has_method("set") or cell.get("terrain") != null:
				cell.terrain = TERRAIN_NAME_TO_ENUM["FORTRESS"]
				fortress_placed += 1
		# 남은 pool의 FORTRESS를 PLAINS로 교체 (이미 중앙에 배치했으므로 중복 방지)
		var to_replace: int = fortress_count - fortress_placed
		# pool에서 FORTRESS 제거는 뒤에서부터
		var replaced: int = 0
		for idx in range(terrain_pool.size() - 1, -1, -1):
			if replaced >= fortress_count:
				break
			if int(terrain_pool[idx]) == TERRAIN_NAME_TO_ENUM["FORTRESS"]:
				# 이미 중앙에 배치된 수만큼은 제거하지 않고, 초과분만 PLAINS로 교체? 단순화: 전부 유지하고 중앙 덮어쓰기므로 pool에서는 중복 제거 필요 없음
				# 대신 키-순차 할당 시 중앙 키는 건너뛰도록 처리
				pass
		# 키-순차 할당 시 중앙 fortress 키는 건너뛰는 방식으로 할당
		var pool_idx: int = 0
		for k in keys:
			# 중앙에 이미 fortress로 지정된 키는 건너뜀
			if fortress_placed > 0 and center_keys.has(k) and center_keys.find(k) < fortress_count:
				continue
			# pool에서 다음 지형 가져오기 — 단 pool 내에서 FORTRESS는 건너뛰기 (이미 배치됨)
			while pool_idx < terrain_pool.size() and int(terrain_pool[pool_idx]) == TERRAIN_NAME_TO_ENUM["FORTRESS"] and fortress_count > 0:
				pool_idx += 1
				if pool_idx >= terrain_pool.size():
					break
			if pool_idx >= terrain_pool.size():
				break
			var cell2 = cell_data.get(k)
			if cell2 != null:
				cell2.terrain = int(terrain_pool[pool_idx])
			pool_idx += 1
		# 남은 셀은 이미 설정됨
		if hex_grid.has_method("generate_hexes"):
			hex_grid.call("generate_hexes")
		return
	else:
		# FORTRESS 없음 — 단순 순차 할당
		for i in range(mini(keys.size(), terrain_pool.size())):
			var k: String = keys[i]
			var cell = cell_data.get(k)
			if cell != null:
				cell.terrain = int(terrain_pool[i])

	if hex_grid.has_method("generate_hexes"):
		hex_grid.call("generate_hexes")

func hex_cfg_is_empty(d: Dictionary) -> bool:
	return d.is_empty()

func _place_units_on_grid(hex_grid: Node, map_size: Vector2i, ally_forces: Array, enemy_forces: Array, mission: Dictionary) -> void:
	if not hex_grid.get("cell_data") is Dictionary:
		push_warning("[CampaignManager] cell_data 없음 — 유닛 배치 스킵")
		return
	var cell_data: Dictionary = hex_grid.get("cell_data") as Dictionary

	# 기존 occupying_unit 초기화
	for key in cell_data.keys():
		var cell = cell_data[key]
		if cell != null:
			cell.occupying_unit = null

	# 아군 배치: 북쪽 30% 영역 (r < size_r * 0.3), ROAD/PLAINS/VILLAGE 우선
	var ally_cells: Array = []
	var enemy_cells: Array = []
	for key in cell_data.keys():
		var cell = cell_data[key]
		if cell == null:
			continue
		var r: int = int(cell.r)
		# FORTRESS는 배치 제외 (요새는 적 전용)
		if int(cell.terrain) == TERRAIN_NAME_TO_ENUM["FORTRESS"]:
			enemy_cells.append(cell) # 요새는 적 전용 후보
			continue
		if r < int(float(map_size.y) * 0.35):
			ally_cells.append(cell)
		elif r > int(float(map_size.y) * 0.55):
			enemy_cells.append(cell)
		else:
			# 중앙 완충 — 양측 모두 후보이나 50% 확률로 적/아군 분리
			if r < map_size.y / 2:
				ally_cells.append(cell)
			else:
				enemy_cells.append(cell)

	ally_cells.shuffle()
	enemy_cells.shuffle()

	# FORTRESS 셀을 적 요새 보병 우선 배치용으로 별도 확보
	var fortress_cells: Array = []
	for key in cell_data.keys():
		var cell = cell_data[key]
		if cell != null and int(cell.terrain) == TERRAIN_NAME_TO_ENUM["FORTRESS"]:
			fortress_cells.append(cell)

	# 아군 Unit 생성 & 배치
	var ally_idx: int = 0
	for entry in ally_forces:
		if not (entry is Dictionary):
			continue
		var utype: String = str(entry.get("unit_type", ""))
		var cnt: int = int(entry.get("count", 100))
		var mor: float = float(entry.get("morale", 70.0))
		if not _unit_type_cache.has(utype):
			continue
		var ut: Resource = _unit_type_cache[utype]
		var unit = _create_unit(ut, &"player", cnt, mor)
		if unit == null:
			continue
		var placed: bool = false
		# 적정 지형에 배치 시도 — can_enter 체크
		for attempt in range(20):
			if ally_idx >= ally_cells.size():
				break
			var cell = ally_cells[ally_idx]
			ally_idx += 1
			if cell.occupying_unit != null:
				continue
			# can_enter 검증
			if ut.has_method("can_enter"):
				if not ut.can_enter(int(cell.terrain)):
					continue
			# 배치
			cell.occupying_unit = unit
			unit.hex_q = int(cell.q)
			unit.hex_r = int(cell.r)
			placed = true
			break
		if not placed:
			# 폴백: 첫 빈 셀에 배치
			for cell in ally_cells:
				if cell.occupying_unit == null:
					cell.occupying_unit = unit
					unit.hex_q = int(cell.q)
					unit.hex_r = int(cell.r)
					break

	# 적군 Unit 생성 & 배치
	var enemy_idx: int = 0
	# 요새 보병/궁병은 fortress_cells에 우선 배치
	var fortress_unit_types: Array = ["infantry", "archers", "spearmen"]
	for entry in enemy_forces:
		if not (entry is Dictionary):
			continue
		var utype: String = str(entry.get("unit_type", ""))
		var cnt: int = int(entry.get("count", 100))
		var mor: float = float(entry.get("morale", 65.0))
		var is_fortress_unit: bool = fortress_unit_types.has(utype) and fortress_cells.size() > 0
		if not _unit_type_cache.has(utype):
			continue
		var ut2: Resource = _unit_type_cache[utype]
		var unit2 = _create_unit(ut2, &"enemy", cnt, mor)
		if unit2 == null:
			continue
		var placed2: bool = false
		if is_fortress_unit and fortress_cells.size() > 0:
			# 요새 셀에서 빈 곳 찾기
			for fc in fortress_cells:
				if fc.occupying_unit == null:
					if ut2.has_method("can_enter"):
						# FORTRESS는 대부분 진입 가능하나, 기병 제외
						if not ut2.can_enter(int(fc.terrain)):
							continue
					fc.occupying_unit = unit2
					unit2.hex_q = int(fc.q)
					unit2.hex_r = int(fc.r)
					placed2 = true
					break
		if not placed2:
			for attempt in range(20):
				if enemy_idx >= enemy_cells.size():
					break
				var cell = enemy_cells[enemy_idx]
				enemy_idx += 1
				if cell.occupying_unit != null:
					continue
				if ut2.has_method("can_enter"):
					if not ut2.can_enter(int(cell.terrain)):
						continue
				cell.occupying_unit = unit2
				unit2.hex_q = int(cell.q)
				unit2.hex_r = int(cell.r)
				placed2 = true
				break
		if not placed2:
			for cell in enemy_cells:
				if cell.occupying_unit == null:
					cell.occupying_unit = unit2
					unit2.hex_q = int(cell.q)
					unit2.hex_r = int(cell.r)
					break

func _create_unit(unit_type: Resource, faction: StringName, count: int, morale: float):
	# Unit.gd는 class_name Unit, RefCounted — new() 시그니처: _init(t: UnitType, faction_: String, count_: int)
	var UnitCls: Script = load("res://scripts/combat/unit.gd") as Script
	if UnitCls == null:
		push_error("[CampaignManager] Unit.gd 로드 실패")
		return null
	var unit = UnitCls.new(unit_type, String(faction), count)
	if unit != null:
		unit.current_morale = morale
		unit.faction = faction
	return unit

func _refresh_hud() -> void:
	# BattleHUD가 씬에 있으면 갱신 (GameDirector가 별도로 해도 되나 편의상)
	var hud: Node = get_tree().current_scene.get_node_or_null("BattleHUD") if get_tree().current_scene else null
	if hud == null:
		hud = get_tree().root.get_node_or_null("Main/BattleHUD")
	if hud == null:
		hud = get_node_or_null("../BattleHUD")
	if hud != null and hud.has_method("update_supply"):
		hud.call("update_supply", supply_days)
		hud.call("update_troops", initial_ally_total_for_mission, initial_enemy_total_for_mission)
		hud.call("update_morale", army_morale)

# ─────────────────────────────────────────────
# 임무 결산 — 명성/신임도 계산 + 처형 판정
# result: {is_victory: bool, ally_casualties: int, enemy_casualties: int, turn_used: int, turn_limit: int, ...}
# 반환: {is_victory, renown_delta, new_renown, king_trust_delta, new_king_trust, next_action, reason, casualty_rate}
# next_action: "next_mission" | "retry" | "execution" | "campaign_complete" | "ending"
# ─────────────────────────────────────────────
func settle_mission(battle_result: Dictionary) -> Dictionary:
	var is_victory: bool = bool(battle_result.get("is_victory", false))
	var ally_cas: int = int(battle_result.get("ally_casualties", battle_result.get("ally_cas", 0)))
	var enemy_cas: int = int(battle_result.get("enemy_casualties", battle_result.get("enemy_cas", 0)))
	var turn_used: int = int(battle_result.get("turn_used", battle_result.get("turn", 0)))
	var turn_limit: int = int(battle_result.get("turn_limit", get_current_mission().get("turn_limit", 8)))

	var ally_initial: int = initial_ally_total_for_mission if initial_ally_total_for_mission > 0 else maxi(ally_cas + 100, 100)
	var casualty_rate: float = float(ally_cas) / float(maxi(ally_initial, 1))
	casualty_rate = clampf(casualty_rate, 0.0, 1.0)

	var renown_delta: int = 0
	var trust_delta: int = 0

	if is_victory:
		# 사상률에 따른 명성 차등 (GDD 핵심)
		if casualty_rate <= 0.15:
			renown_delta = 15 # 대폭 상승
			trust_delta = 10
		elif casualty_rate <= 0.20:
			renown_delta = 12
			trust_delta = 8
		elif casualty_rate <= 0.25:
			renown_delta = 8
			trust_delta = 6
		elif casualty_rate <= 0.35:
			renown_delta = 4 # 소폭 상승/정체 하한
			trust_delta = 3
		elif casualty_rate <= 0.45:
			renown_delta = 1 # 갈아넣은 승리 — 정체
			trust_delta = 1
		else:
			renown_delta = -2 # 피로스 승리 — 오히려 명성 정체/소폭 하락
			trust_delta = -1

		# 턴 제한 내 빠른 승리 보너스
		if turn_used > 0 and turn_limit > 0 and turn_used <= int(float(turn_limit) * 0.5):
			renown_delta += 2
			trust_delta += 2
		# 턴 초과 페널티 (이미 승리라도 지연)
		elif turn_used > turn_limit:
			trust_delta -= 4

		consecutive_failures = 0
		# 참모 분기 갱신
		_update_advisor_branch(casualty_rate)
		# narrative flag 기록 (low_casualty 등)
		if casualty_rate <= 0.20:
			_add_narrative_flag("low_casualty_%02d" % current_mission_index)
		elif casualty_rate >= 0.35:
			_add_narrative_flag("high_casualty_%02d" % current_mission_index)
	else:
		# 실패 시 — 명성 하락, 신임도 하락
		renown_delta = -6
		trust_delta = -10
		if turn_used > turn_limit:
			trust_delta -= 4 # 턴 초과
		if casualty_rate >= 0.5:
			renown_delta -= 4
		consecutive_failures += 1
		_add_narrative_flag("mission_failed_%02d" % current_mission_index)

	# 2장 보급 수레 이벤트 반영: 보급량 결과 보너스/페널티
	if battle_result.has("supply_bonus_days"):
		supply_days += float(battle_result["supply_bonus_days"])
	if battle_result.has("supply_days_delta"):
		supply_days += float(battle_result["supply_days_delta"])

	# 적용 및 클램프
	var old_renown: int = general_renown
	var old_trust: int = king_trust
	general_renown = clampi(general_renown + renown_delta, 0, 100)
	king_trust = clampi(king_trust + trust_delta, 0, 100)
	supply_days = clampf(supply_days, -5.0, 20.0)

	# 보급 고갈 시 사기 하락 (MoraleSystem 규칙)
	if supply_days < 0:
		army_morale = clampf(army_morale - 5.0, 0.0, 100.0)

	# 다음 행동 결정
	var next_action: String = "next_mission"
	var reason: String = ""
	var ending_id: String = ""

	if is_victory:
		if current_mission_index >= get_mission_count():
			# 최종 임무 승리 — 엔딩 판정
			ending_id = _determine_ending(casualty_rate)
			next_action = "campaign_complete"
			reason = "캠페인 완주 — 엔딩: %s" % ending_id
		else:
			next_action = "next_mission"
			reason = "승리 — 다음 장으로 진행"
	else:
		# 실패 — 처형 판정 알고리즘 (GDD 확정 규칙)
		if consecutive_failures >= 2 or general_renown < 20 or king_trust < 15:
			next_action = "execution"
			reason = "2회 연속 실패 또는 명성 매우 낮음(%d) / 신임도 %d — 참수" % [general_renown, king_trust]
			is_game_over = true
		elif general_renown >= 30 or king_trust >= 30:
			next_action = "retry"
			# 명성에 따른 경고 vs 강등 구분
			if general_renown >= 55 and king_trust >= 40:
				reason = "명성 유지(%d) — 1회 재기회 부여 (경고)" % general_renown
			else:
				reason = "명성 보통(%d) — 1회 재기회 부여 (강등)" % general_renown
		else:
			next_action = "execution"
			reason = "명성 매우 낮음(%d) — 재기회 없음, 처형" % general_renown
			is_game_over = true

	var out: Dictionary = {
		"is_victory": is_victory,
		"casualty_rate": casualty_rate,
		"ally_casualties": ally_cas,
		"enemy_casualties": enemy_cas,
		"ally_initial": ally_initial,
		"turn_used": turn_used,
		"turn_limit": turn_limit,
		"renown_delta": renown_delta,
		"old_renown": old_renown,
		"new_renown": general_renown,
		"king_trust_delta": trust_delta,
		"old_king_trust": old_trust,
		"new_king_trust": king_trust,
		"consecutive_failures": consecutive_failures,
		"next_action": next_action,
		"reason": reason,
		"ending_id": ending_id,
		"narrative_flags": narrative_flags.duplicate(),
	}
	mission_settled.emit(out)
	if next_action == "execution":
		game_over_executed.emit(reason)
	elif next_action == "campaign_complete":
		campaign_completed.emit(ending_id)

	print("[CampaignManager] 결산 %s — 사상률 %.1f%% renown %+d(%d→%d) trust %+d(%d→%d) → %s" % [
		"승리" if is_victory else "패배", casualty_rate*100.0, renown_delta, old_renown, general_renown,
		trust_delta, old_trust, king_trust, next_action
	])
	return out

func _update_advisor_branch(casualty_rate: float) -> void:
	# 누적 저손실/고손실에 따라 분기 이동 (단순 모델 — 매 임무 갱신)
	if casualty_rate <= 0.15:
		advisor_branch = "benevolent_guardian"
		staff_profile["branch"] = advisor_branch
	elif casualty_rate >= 0.35:
		advisor_branch = "stern_remonstrator"
		staff_profile["branch"] = advisor_branch
	else:
		advisor_branch = "pragmatic_tactician"
		staff_profile["branch"] = advisor_branch

func _add_narrative_flag(flag: String) -> void:
	if not narrative_flags.has(flag):
		narrative_flags.append(flag)

func add_narrative_flag(flag: String) -> void:
	_add_narrative_flag(flag)

func _determine_ending(casualty_rate: float) -> String:
	# 4장 엔딩 5분기 — ending_triumph / ending_bittersweet / ending_bloodless / ending_execution / ending_retreat_rebuild
	# bloodless는 내통 성공 시에만 — infiltration + civilian_trust 높을 때
	var has_infiltration_success: bool = narrative_flags.has("infiltration_success") or selected_siege_approach == "infiltration"
	var total_loss: float = casualty_rate # 근사
	# 이미 실패 후 처형/퇴각은 settle에서 execution으로 분기되므로 여기서는 승리 후 엔딩만
	if has_infiltration_success and civilian_trust >= 65:
		return "ending_bloodless"
	elif king_trust >= 60 and total_loss <= 0.30:
		return "ending_triumph"
	elif total_loss >= 0.40 or king_trust < 40:
		return "ending_bittersweet"
	else:
		return "ending_triumph"

# ─────────────────────────────────────────────
# 진행 제어
# ─────────────────────────────────────────────
func advance_to_next_mission() -> bool:
	if is_game_over:
		push_warning("[CampaignManager] 게임 오버 상태 — 진행 불가")
		return false
	if current_mission_index >= get_mission_count():
		push_warning("[CampaignManager] 이미 마지막 장 — 캠페인 완료")
		return false
	current_mission_index += 1
	selected_siege_approach = "" # 4장 아니면 리셋, 4장 진입 시 GameDirector가 설정
	# 일반 병력/군량은 왕에게 반환됨 — supply/army_morale은 부분 초기화(왕의 하사)
	# 명성 80+이면 보급 +5일 (GDD), 아니면 기본 10~12일 재정비
	supply_days = 10.0
	if king_trust >= 80:
		supply_days += 5.0
	elif king_trust >= 60:
		supply_days += 2.0
	# 사기 소폭 회복
	army_morale = clampf(army_morale + 5.0, 0.0, 92.0)
	print("[CampaignManager] 다음 장으로 전이: chapter %d" % current_mission_index)
	return true

func set_siege_approach(approach_id: String) -> void:
	# 4장 전용 — approach_id: assault / siege_encirclement / infiltration
	if current_mission_index != 4:
		push_warning("[CampaignManager] 4장이 아닌데 공성책 설정 시도")
		return
	if not ["assault", "siege_encirclement", "infiltration"].has(approach_id):
		push_warning("[CampaignManager] 알 수 없는 공성책: %s" % approach_id)
		return
	selected_siege_approach = approach_id
	_add_narrative_flag("siege_choice_%s" % approach_id)
	print("[CampaignManager] 공성책 선택: %s" % approach_id)

func retry_current_mission() -> void:
	# 재시도 — 같은 장을 다시 준비 (consecutive_failures 유지, 페널티 적용)
	supply_days = maxf(supply_days - 1.0, -2.0)
	army_morale = clampf(army_morale - 3.0, 5.0, 100.0)
	print("[CampaignManager] 임무 재시도: chapter %d" % current_mission_index)

func get_save_data() -> Dictionary:
	return {
		"campaign_id": str(campaign_data.get("campaign_id", "campaign_01_luoyang")),
		"current_chapter": current_mission_index,
		"king_trust": king_trust,
		"general_renown": general_renown,
		"army_morale": army_morale,
		"supply_days": supply_days,
		"gold": gold_taels,
		"civilian_trust": civilian_trust,
		"narrative_flags": narrative_flags.duplicate(),
		"advisor_branch": advisor_branch,
		"events_drawn_this_run": events_drawn_this_run.duplicate(),
		"consecutive_failures": consecutive_failures,
		"selected_siege_approach": selected_siege_approach,
		"staff_profile": staff_profile.duplicate(true),
	}

func load_save_data(data: Dictionary) -> void:
	current_mission_index = int(data.get("current_chapter", 1))
	king_trust = clampi(int(data.get("king_trust", 55)), 0, 100)
	general_renown = clampi(int(data.get("general_renown", 50)), 0, 100)
	army_morale = clampf(float(data.get("army_morale", 70.0)), 0.0, 100.0)
	supply_days = clampf(float(data.get("supply_days", 12.0)), -5.0, 20.0)
	gold_taels = int(data.get("gold", 300))
	civilian_trust = clampi(int(data.get("civilian_trust", 50)), 0, 100)
	narrative_flags = (data.get("narrative_flags", []) as Array).duplicate()
	advisor_branch = str(data.get("advisor_branch", "pragmatic_tactician"))
	events_drawn_this_run = (data.get("events_drawn_this_run", []) as Array).duplicate()
	consecutive_failures = int(data.get("consecutive_failures", 0))
	selected_siege_approach = str(data.get("selected_siege_approach", ""))
	var sp: Dictionary = data.get("staff_profile", {}) as Dictionary
	if not sp.is_empty():
		staff_profile = sp.duplicate(true)

# ─────────────────────────────────────────────
# 돌발 이벤트 추첨 — events_table.json 기반
# ─────────────────────────────────────────────
func draw_crisis_events(trigger_when: String, count: int = 1) -> Array:
	var pool: Array = events_data.get("events", []) as Array
	if pool.is_empty():
		return []
	var candidates: Array = []
	for evt in pool:
		if not (evt is Dictionary):
			continue
		var e: Dictionary = evt as Dictionary
		var eid: String = str(e.get("id", ""))
		if events_drawn_this_run.has(eid):
			continue # 중복 방지
		var trigger: Dictionary = e.get("trigger", {}) as Dictionary
		var when_arr: Array = trigger.get("when", []) as Array
		if not when_arr.has(trigger_when):
			continue
		# prerequisite 무시 — 추후 narrative_flag 조건으로 확장 가능
		var w: int = int(trigger.get("weight", 5))
		# 신임도 가중치
		if king_trust < 40 and trigger.has("weight_if_trust_below_40"):
			w = int(trigger["weight_if_trust_below_40"])
		if (trigger.has("weight_if_morale_below_40") and army_morale < 40):
			w = int(trigger["weight_if_morale_below_40"])
		if w <= 0:
			continue
		candidates.append({"event": e, "weight": w})
	if candidates.is_empty():
		return []

	# 가중 무작위 추첨 (중복 없음)
	var result: Array = []
	var temp_pool: Array = candidates.duplicate()
	for i in range(mini(count, temp_pool.size())):
		var total_w: int = 0
		for c in temp_pool:
			total_w += int(c["weight"])
		if total_w <= 0:
			break
		var r: int = randi() % total_w
		var accum: int = 0
		var picked_idx: int = -1
		for idx in range(temp_pool.size()):
			accum += int(temp_pool[idx]["weight"])
			if r < accum:
				picked_idx = idx
				break
		if picked_idx >= 0:
			var picked = temp_pool[picked_idx]
			result.append(picked["event"])
			events_drawn_this_run.append(str(picked["event"].get("id", "")))
			temp_pool.remove_at(picked_idx)
	return result

func get_event_by_id(event_id: String) -> Dictionary:
	var pool: Array = events_data.get("events", []) as Array
	for e in pool:
		if e is Dictionary and str(e.get("id", "")) == event_id:
			return e as Dictionary
	return {}

## 선택지 효과를 즉시 persistent_resources에 적용 (금/보급/사기/신임도)
func apply_event_choice(event_id: String, choice_id: String) -> Dictionary:
	var evt: Dictionary = get_event_by_id(event_id)
	if evt.is_empty():
		push_warning("[CampaignManager] 이벤트 없음: %s" % event_id)
		return {}
	var choices: Array = evt.get("choices", []) as Array
	var chosen: Dictionary = {}
	for c in choices:
		if c is Dictionary and str(c.get("id", "")) == choice_id:
			chosen = c as Dictionary
			break
	if chosen.is_empty():
		push_warning("[CampaignManager] 선택지 없음: %s/%s" % [event_id, choice_id])
		return {}

	var effect: Dictionary = chosen.get("immediate_effect", {}) as Dictionary
	var flag: String = str(chosen.get("narrative_flag", ""))
	if flag != "":
		_add_narrative_flag(flag)

	# 분기형 effect (branch_true_defection 등) — 확률적 분기는 GameDirector에서 처리, 여기선 단순 수치만 적용
	# immediate_effect에 직접 수치가 있으면 적용
	if effect.has("supply_days"):
		supply_days += float(effect["supply_days"])
		supply_days = clampf(supply_days, -5.0, 20.0)
	if effect.has("king_trust"):
		king_trust += int(effect["king_trust"])
		king_trust = clampi(king_trust, 0, 100)
	if effect.has("morale"):
		army_morale += float(effect["morale"])
		army_morale = clampf(army_morale, 0.0, 100.0)
	if effect.has("civilian_trust"):
		civilian_trust += int(effect["civilian_trust"])
		civilian_trust = clampi(civilian_trust, 0, 100)
	if effect.has("gold_cost"):
		gold_taels -= int(effect["gold_cost"])
		gold_taels = maxi(gold_taels, 0)
	if effect.has("supply_days_delta"):
		supply_days += float(effect["supply_days_delta"])
	if effect.has("turn_delay"):
		# 턴 지연은 GameDirector에서 턴 카운터로 처리 — 여기선 기록만
		pass

	print("[CampaignManager] 이벤트 선택 적용: %s/%s → supply=%.1f trust=%d morale=%.1f flag=%s" % [
		event_id, choice_id, supply_days, king_trust, army_morale, flag
	])
	return {"effect": effect, "flag": flag, "advisor_comment": str(chosen.get("advisor_comment_kr", ""))}

# ─────────────────────────────────────────────
# 유틸
# ─────────────────────────────────────────────
func is_campaign_complete() -> bool:
	return current_mission_index > get_mission_count() or is_game_over

func get_renown_label() -> String:
	if general_renown >= 80: return "전설"
	elif general_renown >= 60: return "명장"
	elif general_renown >= 40: return "신임"
	elif general_renown >= 20: return "주시"
	else: return "미천"

func get_trust_label() -> String:
	if king_trust >= 80: return "총애"
	elif king_trust >= 60: return "신임"
	elif king_trust >= 40: return "주시"
	elif king_trust >= 20: return "의심"
	else: return "진노"
