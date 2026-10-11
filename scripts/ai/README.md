# SLM Intelligence & Narrative AI — README
# Sprint 1/2 #4

## 개요
오대십국 전략 게임의 SLM(소형 언어 모델) 및 내러티브 AI 시스템.
참모/군주/적장/포로 4대 영역에서 SLM이 전략 판단·대화를 담당하고,
SLM 장애 시에도 게임이 멈추지 않도록 규칙 기반 폴백이 즉시 가동된다.

```
SLM (Ollama / LM Studio / OpenAI 호환)
  │  HTTP (JSON)
  ▼
SLMClient (slm_client.gd) ──→ SLMParser (slm_parser.gd) ──→ AISchemas (ai_schemas.gd)
  │  실패 시                                 검증 실패 시
  ▼                                          ▼
RuleBasedFallback (rule_based_fallback.gd) ←┘
  │
  ▼ (동일 시그널)
게임 로직 (TurnManager, Battle, UI)
```

## 파일 구조

```
scripts/ai/
├── prompts/
│   ├── staff_prompt.md        # 참모 — 전황 분석 + 3가지 전술 선택지 + 위험도
│   ├── king_prompt.md         # 군주 — 임무/평가/돌발명령
│   ├── enemy_ai_prompt.md     # 적 지휘관 — 지형·병력비·보급 기반 행동 결정
│   └── prisoner_prompt.md     # 포로 — 심문/회유/거짓정보/전향
├── slm_client.gd              # 비동기 HTTP 클라이언트 (Godot 4 HTTPRequest)
├── slm_parser.gd              # JSON 추출·복구·스키마 검증
├── ai_schemas.gd              # 4종 JSON Schema 상수 정의
├── rule_based_fallback.gd     # 오프라인 규칙 기반 폴백 (핵심)
└── tests/
    ├── mock_dataset.json       # 14 케이스 모의 I/O 데이터세트
    └── test_slm_client.gd     # Headless 통합 테스트 (godot -s)
```

## 빠른 시작

### 1) 에디터에서 SLM 연결 (Ollama 예시)

```gdscript
# battle_map.gd 또는 autoload
var slm := SLMClient.new()
add_child(slm)
slm.configure("http://localhost:11434", "qwen2:7b", SLMClient.Provider.OLLAMA)
slm.debug_log = true

# 참모 조언 요청
slm.staff_advice_received.connect(_on_staff_advice)
slm.slm_error.connect(func(msg, used_fallback): print("SLM 오류: ", msg, " 폴백:", used_fallback))
slm.request_staff_advice({
	"staff_name": "왕박", "staff_personality": "신중파", "staff_ability": 78,
	"friendly_total": 4200, "enemy_estimated_total": 5000,
	"friendly_morale_avg": 62.0, "supply_days": 12.0,
	"terrain_summary": "평야 42%, 숲 30%",
	"fog_hexes": 9, "scout_available": 1,
	"available_coords": [[4,7],[6,3],[5,5]],
	"turn": 4, "phase": "RECON",
	"battlefield_notes": "우익 숲 매복 의심"
})

func _on_staff_advice(result: Dictionary) -> void:
	print(result["staff_dialogue"])           # 내러티브 텍스트
	for opt in result["tactical_options"]:    # 구조화된 액션 데이터
		print(opt["id"], opt["action_type"], opt.get("target_coords", []))
	if result.get("is_fallback", false):
		print("※ 폴백 응답 (SLM 미연결)")
```

### 2) LM Studio (OpenAI 호환)

```gdscript
slm.configure("http://localhost:1234", "qwen2-7b-instruct", SLMClient.Provider.LM_STUDIO)
```

### 3) OpenAI / OpenRouter

```gdscript
slm.configure("https://api.openai.com", "gpt-4o-mini", SLMClient.Provider.OPENAI_COMPATIBLE, "sk-...")
```

### 4) 오프라인 — 폴백 직접 호출 (테스트/오프라인 모드)

```gdscript
# HTTP 없이 즉시 결과
var advice: Dictionary = RuleBasedFallback.get_staff_advice(ctx)
var order: Dictionary  = RuleBasedFallback.get_king_order(ctx)
var enemy: Dictionary  = RuleBasedFallback.get_enemy_decision(ctx)
var pow: Dictionary    = RuleBasedFallback.get_prisoner_response(ctx)
# 또는 SLMClient 정적 헬퍼
var advice2: Dictionary = SLMClient.get_fallback_staff_advice(ctx)
```

## 프롬프트 템플릿

각 `prompts/*.md`는 3층 구조:
1. **System Prompt** — SLM 역할·말투·불확실성 원칙·출력 스키마 정의
2. **User Prompt 템플릿** — `{{변수}}` 플레이스홀더를 `slm_client.gd`가 context로 치환
3. **Few-shot 예시** — SLM이 JSON 형식을 학습하도록 2~3개 예시 포함

성향 프리셋:
- 참모: 신중파 / 맹진파 / 계략파 / 균형파
- 군주: 현명파 / 호전파 / 의심파 / 변덕파 / 인자파
- 적장: 맹장형 / 지장형 / 수성형 / 교활형 / 냉정형
- 포로: 충의파 / 현실파 / 교활파 / 겁약파 / 원한파

## 구조화된 응답 스키마 (요약)

### 참모 (`staff_advice.v1`)
```json
{
  "staff_dialogue": "주공, ...",
  "confidence_level": "medium",
  "staff_personality": "신중파",
  "tactical_options": [
	{"id": "option_recon_forest", "title": "숲 정찰 우선", "risk": "low", "action_type": "scout_target", "target_coords": [4,7]}
  ],
  "estimated_enemy_intent": "숲 매복 후 측면 기습으로 추정",
  "is_fallback": false
}
```

### 군주 (`king_order.v1`)
```json
{
  "king_dialogue": "짐이 명하노니 ...",
  "mood": "neutral",
  "mission": {"id": "mission_secure_fortress", "title": "요새 확보", "turn_limit": 5},
  "evaluation": {"score": 68, "result": "성공", "fame_delta": 8},
  "sudden_order": {"order_type": "retreat", "urgency": "immediate"}
}
```

### 적장 (`enemy_decision.v1`)
```json
{
  "enemy_dialogue": "숲에 숨겨둔 병력을 ...",
  "commander_thought": "아군이 ...",
  "decision": {"action_type": "ambush", "target_coords": [5,8], "aggression": 0.35, "risk": "medium"},
  "unit_orders": [{"unit_id": "enemy_scout_1", "order": "ambush", "target": [5,8]}],
  "staff_control_modifier": 0.92
}
```

### 포로 (`prisoner_dialogue.v1`)
```json
{
  "prisoner_dialogue": "흥, 관직을 준다 한들 ...",
  "attitude": "defiant",
  "truthfulness": "false",
  "revealed_info": {"enemy_total_claimed": 8000, "supply_days_claimed": 30},
  "surrender_will": 0.05,
  "action_hint": "keep_interrogating"
}
```

전체 스키마는 `ai_schemas.gd` 참조.

## 폴백 로직 상세

`rule_based_fallback.gd`는 외부 의존성 없이 동작:

| 영역 | 핵심 분기 |
|------|-----------|
| **참모** | 병력비·보급·지형·안개·정찰병·성향으로 3옵션 생성. 저능력(≤40)은 confidence 강제 low + 불확실성 문구 |
| **군주** | 성향·신뢰·사기·전과로 mood/평가/돌발명령 결정. 변덕파 33% 돌발회군, 현명파 보급 <4일 시에만 |
| **적장** | 포위→탈출/항복 > 보급부족→후퇴/기습 > 사기붕괴→후퇴 > 지형/성향→매복/돌격/농성. 참모사망 시 30% 명령 왜곡 |
| **포로** | 성향·충성·처우·심문방식으로 attitude/truthfulness/surrender_will 결정. 교활파 거짓투항, 충의파 defiant |

## 테스트

```bash
# Headless 통합 테스트 (14 케이스 + 파서 + 스키마 + 엣지)
godot --headless --path "D:/Game development/Demon slayer/StrategyGame" -s res://scripts/ai/tests/test_slm_client.gd

# 또는 Python으로 JSON 데이터세트 검증
python -m json.tool scripts/ai/tests/mock_dataset.json
```

## SLM 권장 모델

- **로컬 (Ollama)**: `qwen2:7b`, `exaone3.5:7.8b`, `gemma2:9b` — 한국어 강점
- **LM Studio**: Qwen2-7B-Instruct-GGUF, EXAONE-3.5-7.8B-GGUF
- **클라우드**: `gpt-4o-mini`, `claude-3-haiku` (OpenAI 호환)

프롬프트는 800 토큰 내외, temperature 0.7 권장.

## 확장 가이드

- 새 참모/군주 추가: `rule_based_fallback.gd`의 `match personality` 분기에 케이스 추가
- 새 전술 타입: `ai_schemas.gd`의 `STAFF_ACTION_TYPES`/`ENEMY_ACTION_TYPES`와 프롬프트 허용 목록에 추가
- 엔진 연동: `result["tactical_options"][i]["action_type"]` → `HexUtils.find_path` / `CombatCalculator` / `TurnManager`로 연결
