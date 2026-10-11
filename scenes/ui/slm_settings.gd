extends Control
## SLM 설정 모달 — 인게임 어디서나 [SLM 설정]으로 호출 가능.
## Sprint 4 #9: Live SLM Local Connection & Evaluation Testbed.
##
## 책임:
##   - Provider/Endpoint/Model 편집 → SLMClient에 즉시 적용
##   - 자동 감지(SLMLauncher) / 단일 연결 테스트 / 벤치마크 실행 진입점
##   - user://slm_settings.cfg로 영속화 (재접속 시 자동 복원)
##   - 외부 SLMClient 인스턴스를 한 개 참조 (configure 재호출 가능)
##
## 사용법:
##   1) 메인 메뉴/배틀 HUD에서 [SLM 설정] 버튼 누름
##   2) show_modal() 호출 → 모달 팝업
##   3) 사용자가 Provider/엔드포인트/모델 변경 → [연결 테스트]
##   4) [적용] 또는 [닫기] — 적용 시 settings_changed 시그널 발화

const CONFIG_PATH := "user://slm_settings.cfg"

# 런처 명시 preload (class_name 자동 인식 안 되는 컨텍스트 대비)
const SLMLauncherScript := preload("res://scripts/ai/slm_launcher.gd")

# ─────────────────────────────────────────────
# 시그널
# ─────────────────────────────────────────────
signal settings_changed(provider: int, endpoint: String, model: String, api_key: String, use_fallback: bool)
signal auto_detect_requested()
signal benchmark_requested(provider: String, model: String)
signal modal_closed()

# ─────────────────────────────────────────────
# 상태
# ─────────────────────────────────────────────
var _client: Node = null       # 외부 SLMClient 인스턴스 (옵션)
var _launcher: Node = null     # SLMLauncher (preload로 로드)
var _http: HTTPRequest = null  # ping 측정용
var _ping_in_flight: bool = false
var _ping_start_msec: int = 0

# Provider enum (slm_client.gd와 동기화)
const PROVIDER_OLLAMA := 0
const PROVIDER_LM_STUDIO := 1
const PROVIDER_OPENAI_COMPAT := 2
const PROVIDER_OFFLINE_ONLY := 3

# 노드 참조
@onready var _provider_option: OptionButton = $DimBackground/CenterContainer/ModalPanel/Margin/MainVBox/ProviderRow/ProviderOption
@onready var _endpoint_edit: LineEdit = $DimBackground/CenterContainer/ModalPanel/Margin/MainVBox/EndpointRow/EndpointEdit
@onready var _model_edit: LineEdit = $DimBackground/CenterContainer/ModalPanel/Margin/MainVBox/ModelRow/ModelEdit
@onready var _api_key_edit: LineEdit = $DimBackground/CenterContainer/ModalPanel/Margin/MainVBox/ApiKeyRow/ApiKeyEdit
@onready var _status_label: Label = $DimBackground/CenterContainer/ModalPanel/Margin/MainVBox/StatusLabel
@onready var _auto_detect_btn: Button = $DimBackground/CenterContainer/ModalPanel/Margin/MainVBox/BenchmarkRow/AutoDetectBtn
@onready var _test_conn_btn: Button = $DimBackground/CenterContainer/ModalPanel/Margin/MainVBox/BenchmarkRow/TestConnBtn
@onready var _run_bench_btn: Button = $DimBackground/CenterContainer/ModalPanel/Margin/MainVBox/BenchmarkRow/RunBenchBtn
@onready var _use_fallback_check: CheckBox = $DimBackground/CenterContainer/ModalPanel/Margin/MainVBox/FooterRow/UseFallbackCheck
@onready var _close_btn: Button = $DimBackground/CenterContainer/ModalPanel/Margin/MainVBox/FooterRow/CloseBtn
@onready var _dim: ColorRect = $DimBackground


# ─────────────────────────────────────────────
# 라이프사이클
# ─────────────────────────────────────────────
func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = 6
	add_child(_http)
	_http.request_completed.connect(_on_ping_completed)

	if _launcher == null:
		_launcher = SLMLauncherScript.new()
		add_child(_launcher)
		_launcher.health_check_completed.connect(_on_health_check_completed)
		_launcher.detection_finished.connect(_on_detection_finished)

	# 시그널 연결
	_provider_option.item_selected.connect(_on_provider_changed)
	_endpoint_edit.text_changed.connect(_on_field_changed)
	_model_edit.text_changed.connect(_on_field_changed)
	_use_fallback_check.toggled.connect(_on_field_changed)
	_auto_detect_btn.pressed.connect(_on_auto_detect_pressed)
	_test_conn_btn.pressed.connect(_on_test_conn_pressed)
	_run_bench_btn.pressed.connect(_on_run_bench_pressed)
	_close_btn.pressed.connect(_on_close_pressed)
	_dim.gui_input.connect(_on_dim_input)

	# 영속화된 설정 복원
	_load_settings()
	_update_status_label("상태: 미연결 — Provider 선택 후 [자동 감지] 또는 [연결 테스트]")

	# 기본 비표시 (호출 시 show_modal())
	hide()


# ─────────────────────────────────────────────
# 공개 API
# ─────────────────────────────────────────────
## 외부에서 SLMClient 인스턴스 주입 (옵션).
func bind_client(client: Node) -> void:
	_client = client
	if _client != null and is_instance_valid(_client):
		_endpoint_edit.text = str(_client.endpoint)
		_model_edit.text = str(_client.model)
		_use_fallback_check.button_pressed = bool(_client.use_fallback_on_error)


## 모달 표시
func show_modal() -> void:
	show()
	_populate_from_client()


## 모달 숨김 (외부에서 강제 종료할 때)
func hide_modal() -> void:
	hide()
	modal_closed.emit()


# ─────────────────────────────────────────────
# 시그널 핸들러
# ─────────────────────────────────────────────
func _on_provider_changed(_idx: int) -> void:
	# Provider 변경 시 기본 엔드포인트/모델 자동 채움 (비어 있을 때만)
	var pid: int = _provider_option.selected
	var default_ep: String = SLMLauncherScript.get_default_endpoint(_provider_string(pid))
	if _endpoint_edit.text.strip_edges() == "" or _is_default_endpoint(_endpoint_edit.text):
		_endpoint_edit.text = default_ep
	match pid:
		PROVIDER_OLLAMA:
			if _model_edit.text.strip_edges() == "":
				_model_edit.text = "qwen2.5:1.5b"
		PROVIDER_LM_STUDIO:
			if _model_edit.text.strip_edges() == "":
				_model_edit.text = "qwen2.5-3b-instruct"
		PROVIDER_OPENAI_COMPAT:
			if _model_edit.text.strip_edges() == "":
				_model_edit.text = "gpt-4o-mini"
		PROVIDER_OFFLINE_ONLY:
			_model_edit.text = "(사용 안 함)"
	_update_status_label("Provider 변경됨 — [연결 테스트] 또는 [자동 감지] 권장")


func _on_field_changed(_new_text: String = "") -> void:
	# 텍스트 변경 시 저장 (실시간)
	pass  # 닫을 때 일괄 저장


func _on_auto_detect_pressed() -> void:
	_update_status_label("🔍 자동 감지 중...")
	_auto_detect_btn.disabled = true
	_test_conn_btn.disabled = true
	auto_detect_requested.emit()
	# 런처 실행 (별도 await는 시그널로 받음)
	_launcher.run_autodetect()


func _on_test_conn_pressed() -> void:
	var pid: int = _provider_option.selected
	if pid == PROVIDER_OFFLINE_ONLY:
		_update_status_label("오프라인 전용 모드 — SLM을 사용하지 않습니다.")
		return
	var endpoint: String = _endpoint_edit.text.strip_edges()
	if endpoint == "":
		_update_status_label("⚠ 엔드포인트를 입력하세요.")
		return
	_update_status_label("📡 연결 테스트 중: %s" % endpoint)
	_test_conn_btn.disabled = true
	_ping_in_flight = true
	_ping_start_msec = Time.get_ticks_msec()
	var url: String = "%s/%s" % [endpoint, _ping_path(pid)]
	var headers: PackedStringArray = PackedStringArray(["Accept: application/json"])
	_http.request(url, headers, HTTPClient.METHOD_GET)


func _on_run_bench_pressed() -> void:
	var pid: int = _provider_option.selected
	var prov_str: String = _provider_string(pid)
	var model_str: String = _model_edit.text.strip_edges()
	if pid == PROVIDER_OFFLINE_ONLY:
		_update_status_label("벤치마크는 SLM 모드에서만 실행 가능 — Provider를 변경하세요.")
		return
	if model_str == "" or model_str == "(사용 안 함)":
		_update_status_label("⚠ 모델명을 입력하세요.")
		return
	_update_status_label("📊 벤치마크 실행 요청 — 콘솔 로그 확인: %s / %s" % [prov_str, model_str])
	benchmark_requested.emit(prov_str, model_str)


func _on_close_pressed() -> void:
	_apply_to_client()
	_save_settings()
	hide_modal()


func _on_dim_input(event: InputEvent) -> void:
	# 딤 배경 클릭 시 닫기
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_on_close_pressed()


# ─────────────────────────────────────────────
# 자동 감지 시그널
# ─────────────────────────────────────────────
func _on_health_check_completed(cand: Dictionary) -> void:
	# 후보가 발견되면 상태바 업데이트
	if bool(cand.get("ok", false)):
		var tps: float = float(cand.get("tps", 0.0))
		_update_status_label(
			"후보: %s @ %s — TPS %.1f, %dms" % [
				str(cand.get("model", "?")),
				str(cand.get("endpoint", "?")),
				tps,
				int(cand.get("ping_ms", 0))
			]
		)


func _on_detection_finished(status: Dictionary) -> void:
	_auto_detect_btn.disabled = false
	_test_conn_btn.disabled = false
	if not bool(status.get("ok", false)):
		_update_status_label("❌ 자동 감지 실패: %s" % str(status.get("message", "?")))
		return
	# 성공 시 폼에 채움
	var prov_str: String = str(status.get("provider", "OLLAMA"))
	_provider_option.select(_provider_id_from_string(prov_str))
	_endpoint_edit.text = str(status.get("endpoint", ""))
	_model_edit.text = str(status.get("model", ""))
	_update_status_label(
		"✅ 감지 성공: %s @ %s — TPS %.1f, %dms" % [
			str(status.get("model", "?")),
			str(status.get("endpoint", "?")),
			float(status.get("tps", 0.0)),
			int(status.get("ping_ms", 0))
		]
	)
	_apply_to_client()


# ─────────────────────────────────────────────
# 핑 콜백
# ─────────────────────────────────────────────
func _on_ping_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_ping_in_flight = false
	_test_conn_btn.disabled = false
	if result != HTTPRequest.RESULT_SUCCESS or code < 200 or code >= 300:
		_update_status_label("❌ 연결 실패: HTTP %d (result=%d)" % [code, result])
		return
	var elapsed: int = Time.get_ticks_msec() - _ping_start_msec
	# 모델 풀 확인
	var pid: int = _provider_option.selected
	var avail_models: Array = _parse_models(pid, body.get_string_from_utf8())
	if avail_models.size() > 0:
		var pool_str: String = ", ".join(avail_models.slice(0, 5))
		_update_status_label("✅ 연결 성공 (%dms) — 가용 모델: %s" % [elapsed, pool_str])
	else:
		_update_status_label("✅ 연결 성공 (%dms)" % elapsed)


# ─────────────────────────────────────────────
# 유틸
# ─────────────────────────────────────────────
func _ping_path(pid: int) -> String:
	match pid:
		PROVIDER_OLLAMA: return "api/tags"
		PROVIDER_LM_STUDIO, PROVIDER_OPENAI_COMPAT: return "v1/models"
		_: return ""


func _parse_models(pid: int, body: String) -> Array[String]:
	var out: Array[String] = []
	var json := JSON.new()
	if json.parse(body) != OK:
		return out
	var data = json.get_data()
	if not (data is Dictionary):
		return out
	var d: Dictionary = data
	if pid == PROVIDER_OLLAMA and d.has("models") and d["models"] is Array:
		for m in (d["models"] as Array):
			if m is Dictionary and (m as Dictionary).has("name"):
				out.append(str((m as Dictionary)["name"]))
	elif (pid == PROVIDER_LM_STUDIO or pid == PROVIDER_OPENAI_COMPAT) and d.has("data") and d["data"] is Array:
		for m in (d["data"] as Array):
			if m is Dictionary and (m as Dictionary).has("id"):
				out.append(str((m as Dictionary)["id"]))
	return out


func _provider_string(pid: int) -> String:
	match pid:
		PROVIDER_OLLAMA: return "OLLAMA"
		PROVIDER_LM_STUDIO: return "LM_STUDIO"
		PROVIDER_OPENAI_COMPAT: return "OPENAI_COMPATIBLE"
		PROVIDER_OFFLINE_ONLY: return "OFFLINE_ONLY"
		_: return "OLLAMA"


func _provider_id_from_string(p: String) -> int:
	match p:
		"OLLAMA": return PROVIDER_OLLAMA
		"LM_STUDIO": return PROVIDER_LM_STUDIO
		"OPENAI_COMPATIBLE": return PROVIDER_OPENAI_COMPAT
		"OFFLINE_ONLY": return PROVIDER_OFFLINE_ONLY
		_: return PROVIDER_OLLAMA


func _is_default_endpoint(ep: String) -> bool:
	for d in [
		"http://localhost:11434",
		"http://localhost:1234",
		"https://api.openai.com"
	]:
		if ep == d:
			return true
	return false


func _update_status_label(text: String) -> void:
	_status_label.text = text


func _populate_from_client() -> void:
	if _client == null or not is_instance_valid(_client):
		return
	# 클라이언트의 현재 설정 → 폼
	var prov_str: String = "OLLAMA"
	# _client.provider는 enum 정수값
	if _client.has_method("get") or "provider" in _client:
		var pid: int = int(_client.provider)
		_provider_option.select(pid)
	_endpoint_edit.text = str(_client.endpoint)
	_model_edit.text = str(_client.model)
	_use_fallback_check.button_pressed = bool(_client.use_fallback_on_error)


func _apply_to_client() -> void:
	var pid: int = _provider_option.selected
	var endpoint: String = _endpoint_edit.text.strip_edges()
	var model: String = _model_edit.text.strip_edges()
	var api_key: String = _api_key_edit.text
	var use_fallback: bool = _use_fallback_check.button_pressed

	# OFFLINE_ONLY는 클라이언트에 적용하지 않음 — 그냥 규칙만 사용
	if pid == PROVIDER_OFFLINE_ONLY:
		_update_status_label("ℹ 오프라인 전용 모드 — SLM을 사용하지 않고 규칙 기반으로 동작합니다.")
		settings_changed.emit(pid, "", "", "", use_fallback)
		return

	# SLMClient에 적용
	if _client != null and is_instance_valid(_client):
		_client.configure(endpoint, model, pid, api_key)
		_client.use_fallback_on_error = use_fallback

	settings_changed.emit(pid, endpoint, model, api_key, use_fallback)


# ─────────────────────────────────────────────
# 영속화 (ConfigFile)
# ─────────────────────────────────────────────
func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("slm", "provider_id", _provider_option.selected)
	cfg.set_value("slm", "endpoint", _endpoint_edit.text)
	cfg.set_value("slm", "model", _model_edit.text)
	# api_key는 보안상 저장하지 않음 (재입력 필요)
	cfg.set_value("slm", "use_fallback", _use_fallback_check.button_pressed)
	var err: int = cfg.save(CONFIG_PATH)
	if err != OK:
		push_warning("[SLMSettings] 설정 저장 실패: %d" % err)


func _load_settings() -> void:
	var cfg := ConfigFile.new()
	var err: int = cfg.load(CONFIG_PATH)
	if err != OK:
		# 기본값 적용
		_provider_option.select(PROVIDER_OLLAMA)
		_endpoint_edit.text = "http://localhost:11434"
		_model_edit.text = "qwen2.5:1.5b"
		_use_fallback_check.button_pressed = true
		return
	var pid: int = int(cfg.get_value("slm", "provider_id", PROVIDER_OLLAMA))
	_provider_option.select(pid)
	_endpoint_edit.text = str(cfg.get_value("slm", "endpoint", "http://localhost:11434"))
	_model_edit.text = str(cfg.get_value("slm", "model", "qwen2.5:1.5b"))
	_use_fallback_check.button_pressed = bool(cfg.get_value("slm", "use_fallback", true))