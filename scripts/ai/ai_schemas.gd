class_name AISchemas
extends RefCounted
## SLM 구조화된 응답 JSON 스키마 정의 (Godot 4 검증용 상수)
## 각 스키마는 SLM 프롬프트 템플릿과 RuleBasedFallback / SLMParser가 공유한다.
## JSON Schema draft-07 서브셋을 GDScript Dictionary로 표현.

# ─────────────────────────────────────────────
# 1) 참모 조언 (staff_advice.v1)
# ─────────────────────────────────────────────
const STAFF_ADVICE := {
	"$schema": "staff_advice.v1",
	"type": "object",
	"required": ["staff_dialogue", "confidence_level", "staff_personality", "tactical_options"],
	"properties": {
		"staff_dialogue": {"type": "string", "minLength": 20, "maxLength": 400},
		"confidence_level": {"type": "string", "enum": ["high", "medium", "low"]},
		"staff_personality": {"type": "string", "enum": ["신중파", "맹진파", "계략파", "균형파"]},
		"tactical_options": {
			"type": "array", "minItems": 3, "maxItems": 3,
			"items": {
				"type": "object",
				"required": ["id", "title", "risk", "action_type"],
				"properties": {
					"id": {"type": "string", "pattern": "^option_[a-z_]+$"},
					"title": {"type": "string"},
					"risk": {"type": "string", "enum": ["low", "medium", "high"]},
					"action_type": {"type": "string", "enum": ["scout_target", "move_flank", "frontal_assault", "hold_defense", "ambush", "feint_retreat", "siege_prepare", "supply_secure"]},
					"target_coords": {"type": "array", "items": {"type": "integer"}, "minItems": 2, "maxItems": 2},
					"reason": {"type": "string"}
				}
			}
		},
		"estimated_enemy_intent": {"type": "string"},
		"is_fallback": {"type": "boolean"}
	}
}

# ─────────────────────────────────────────────
# 2) 군주 명령 (king_order.v1)
# ─────────────────────────────────────────────
const KING_ORDER := {
	"$schema": "king_order.v1",
	"type": "object",
	"required": ["king_dialogue", "mood"],
	"properties": {
		"king_dialogue": {"type": "string", "minLength": 20, "maxLength": 450},
		"mood": {"type": "string", "enum": ["pleased", "neutral", "angered", "furious"]},
		"king_personality": {"type": "string", "enum": ["현명파", "호전파", "의심파", "변덕파", "인자파"]},
		"mission": {
			"type": "object",
			"required": ["id", "title", "objective", "turn_limit"],
			"properties": {
				"id": {"type": "string", "pattern": "^mission_[a-z0-9_]+$"},
				"title": {"type": "string"},
				"objective": {"type": "string"},
				"target_coords": {"type": "array", "items": {"type": "integer"}, "minItems": 2, "maxItems": 2},
				"turn_limit": {"type": "integer", "minimum": 1, "maximum": 20},
				"reward_hint": {"type": "string"},
				"failure_consequence": {"type": "string", "enum": ["reprimand", "demotion", "execution_risk", "none"]}
			}
		},
		"evaluation": {
			"type": "object",
			"required": ["score", "result", "reward_or_punishment"],
			"properties": {
				"score": {"type": "integer", "minimum": 0, "maximum": 100},
				"result": {"type": "string", "enum": ["대성공", "성공", "보통", "실패", "참패"]},
				"reward_or_punishment": {"type": "string"},
				"fame_delta": {"type": "integer", "minimum": -50, "maximum": 50},
				"detail": {"type": "string"}
			}
		},
		"sudden_order": {
			"type": "object",
			"required": ["order_type", "content"],
			"properties": {
				"order_type": {"type": "string", "enum": ["retreat", "rush_attack", "hold_position", "replace_officer", "secure_supply", "none"]},
				"content": {"type": "string"},
				"urgency": {"type": "string", "enum": ["low", "medium", "high", "immediate"]},
				"disobey_consequence": {"type": "string"}
			}
		},
		"is_fallback": {"type": "boolean"}
	}
}

# ─────────────────────────────────────────────
# 3) 적 지휘관 결정 (enemy_decision.v1)
# ─────────────────────────────────────────────
const ENEMY_DECISION := {
	"$schema": "enemy_decision.v1",
	"type": "object",
	"required": ["enemy_dialogue", "commander_thought", "decision"],
	"properties": {
		"enemy_dialogue": {"type": "string", "minLength": 10, "maxLength": 300},
		"commander_thought": {"type": "string", "minLength": 10, "maxLength": 350},
		"decision": {
			"type": "object",
			"required": ["action_type", "aggression", "risk"],
			"properties": {
				"action_type": {"type": "string", "enum": ["frontal_assault", "flank_attack", "ambush", "feint_retreat", "hold_fortify", "retreat", "breakout", "supply_raid", "siege_assault", "scout_probe", "surrender"]},
				"target_coords": {"type": "array", "items": {"type": "integer"}, "minItems": 2, "maxItems": 2},
				"target_coords_alt": {"type": "array", "items": {"type": "integer"}, "minItems": 2, "maxItems": 2},
				"aggression": {"type": "number", "minimum": 0.0, "maximum": 1.0},
				"risk": {"type": "string", "enum": ["low", "medium", "high"]},
				"reasoning": {"type": "string"}
			}
		},
		"unit_orders": {
			"type": "array",
			"items": {
				"type": "object",
				"required": ["unit_id", "order"],
				"properties": {
					"unit_id": {"type": "string"},
					"order": {"type": "string", "enum": ["advance", "hold", "retreat", "flank", "ambush", "scout", "siege"]},
					"target": {"type": "array", "items": {"type": "integer"}, "minItems": 2, "maxItems": 2}
				}
			}
		},
		"staff_control_modifier": {"type": "number", "minimum": 0.0, "maximum": 1.0},
		"is_fallback": {"type": "boolean"}
	}
}

# ─────────────────────────────────────────────
# 4) 포로 심문 (prisoner_dialogue.v1)
# ─────────────────────────────────────────────
const PRISONER_DIALOGUE := {
	"$schema": "prisoner_dialogue.v1",
	"type": "object",
	"required": ["prisoner_dialogue", "attitude", "truthfulness"],
	"properties": {
		"prisoner_dialogue": {"type": "string", "minLength": 20, "maxLength": 500},
		"attitude": {"type": "string", "enum": ["defiant", "evasive", "cooperative", "deceptive", "broken", "conditional"]},
		"truthfulness": {"type": "string", "enum": ["true", "partial", "false"]},
		"wants": {"type": "string"},
		"revealed_info": {
			"type": "object",
			"properties": {
				"enemy_total_claimed": {"type": "integer"},
				"supply_days_claimed": {"type": "number"},
				"commander_claimed": {"type": "string"},
				"extra_claim": {"type": "string"}
			}
		},
		"surrender_will": {"type": "number", "minimum": 0.0, "maximum": 1.0},
		"action_hint": {"type": "string", "enum": ["keep_interrogating", "offer_terms", "execute_risk", "release", "recruit", "deceive_detected"]},
		"is_fallback": {"type": "boolean"}
	}
}

# ─────────────────────────────────────────────
# 레지스트리
# ─────────────────────────────────────────────
const ALL_SCHEMAS := {
	"staff": STAFF_ADVICE,
	"king": KING_ORDER,
	"enemy": ENEMY_DECISION,
	"prisoner": PRISONER_DIALOGUE,
}

## 스키마 키로 정의 반환
static func get_schema(type: String) -> Dictionary:
	return ALL_SCHEMAS.get(type, {}) as Dictionary

## 모든 action_type 허용 목록 (엔진에서 이동/전투 연동 시 참조)
const STAFF_ACTION_TYPES := ["scout_target", "move_flank", "frontal_assault", "hold_defense", "ambush", "feint_retreat", "siege_prepare", "supply_secure"]
const ENEMY_ACTION_TYPES := ["frontal_assault", "flank_attack", "ambush", "feint_retreat", "hold_fortify", "retreat", "breakout", "supply_raid", "siege_assault", "scout_probe", "surrender"]

## 간단 런타임 검증 — 필수 키 존재 및 enum 범위 체크
static func quick_validate(data: Dictionary, type: String) -> Array:
	var schema: Dictionary = get_schema(type)
	if schema.is_empty():
		return ["unknown schema: %s" % type]
	var errors: Array = []
	var required: Array = schema.get("required", []) as Array
	for key in required:
		if not data.has(key):
			errors.append("missing required: %s" % key)
	# enum 체크 (1단계만)
	var props: Dictionary = schema.get("properties", {}) as Dictionary
	for key in props:
		if data.has(key) and (props[key] as Dictionary).has("enum"):
			var allowed: Array = (props[key] as Dictionary)["enum"] as Array
			if str(data[key]) not in allowed.map(func(x): return str(x)):
				errors.append("invalid enum %s=%s not in %s" % [key, str(data[key]), str(allowed)])
	return errors
