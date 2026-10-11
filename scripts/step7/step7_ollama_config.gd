class_name Step7OllamaConfig
extends RefCounted

## Single source of Ollama configuration for the Step 7 tactical Advisor
## pilot (single local LLM, end-to-end). No provider abstraction, no router,
## no fallback chain: Godot <-> Ollama HTTP API <-> ONE local model.
##
## Sources (highest priority first):
##   1. ProjectSettings "strategy_game/ollama/*" (set at runtime or in editor).
##   2. Defaults below (local pilot values).
##
## Do NOT scatter the endpoint URL or the model name through other scripts.
##
## WRITE AUTHORITY: AIBackendConfig (res://scripts/ai/ai_backend_config.gd)
## is the ONLY writer of the SETTING_* keys below (via apply_runtime()).
## This class is a read-through view over those keys plus the frozen
## generation defaults. The runtime model is whatever the player selected
## in AI Settings — never the DEFAULT_MODEL fallback below (used only
## before the first apply_runtime / when no value is stored).

const SETTING_BASE := "strategy_game/ollama/base_url"
const SETTING_MODEL := "strategy_game/ollama/model"
const SETTING_TIMEOUT := "strategy_game/ollama/timeout_seconds"
## Semantic-role tag (tiny Qwen3-0.6B frontend). Tactical role keeps MODEL.
const SETTING_SEMANTIC_MODEL := "strategy_game/ollama/semantic_model"
const DEFAULT_SEMANTIC_MODEL := "strategy-game-semantic-qwen06:latest"
## Compact budgets for the semantic frontend (small prompts, JSON-only).
const SEMANTIC_NUM_PREDICT := 1024
const SEMANTIC_NUM_CTX := 4096
const SEMANTIC_TIMEOUT_SECONDS := 60.0

const DEFAULT_BASE_URL := "http://127.0.0.1:11434"
## Exact Ollama model tag used for the whole pilot (verified installed).
const DEFAULT_MODEL := "qwen38-jrell-mtp-256k:latest"
## Whole-request deadline in seconds. Failures degrade to deterministic play.
const DEFAULT_TIMEOUT_SECONDS := 120.0

## Stable generation settings for tactical selection: consistency and
## structured output over creative prose. Recorded in evidence.
## Default sampling temperature (selection/advice judgment + repair
## second chances). Phase-1 intent does NOT use this: the commander pins
## 0.0 there (deterministic scope semantics — measured 2026-09-15: at 0.2
## the same order sampled different scope shapes across runs; at 0.0 runs
## are bit-identical). Selection keeps 0.2 (judgment variance across legal
## realizations is benign, and greedy deliberation overran the token
## budget on 8-unit packages while 0.2 fits).
const DEFAULT_TEMPERATURE := 0.2
## Token budget for one advisor call. The configured advisor model is a
## thinking model: its deliberation shares this budget with the answer, and
## 768 truncated ~2/3 of live Phase-1 commands into empty MALFORMED
## responses (done_reason=length, proven 2026-09-15). Phase-1 fits 4096
## easily; Phase-2 selection over 8-unit packages deliberates up to
## ~14000 chars (measured worst case, substantive per-unit comparison),
## so 6144 covers every phase with margin. A full-budget call runs ~100s
## worst case, inside the 120s deadline. Calls that stop early cost
## nothing extra (a cap, not a target).
const DEFAULT_NUM_PREDICT := 6144
const DEFAULT_NUM_CTX := 12288
## Qwen "thinking" mode: disabled for the pilot so the model returns the
## decision JSON directly (concise rationale lives in the contract fields,
## no long hidden trace is sent to the UI).
const DEFAULT_THINK := false


static func base_url() -> String:
	return str(ProjectSettings.get_setting(SETTING_BASE, DEFAULT_BASE_URL)).strip_edges()


static func model() -> String:
	return str(ProjectSettings.get_setting(SETTING_MODEL, DEFAULT_MODEL)).strip_edges()


static func semantic_model() -> String:
	return str(ProjectSettings.get_setting(SETTING_SEMANTIC_MODEL, DEFAULT_SEMANTIC_MODEL)).strip_edges()


static func timeout_seconds() -> float:
	return maxf(5.0, float(ProjectSettings.get_setting(SETTING_TIMEOUT, DEFAULT_TIMEOUT_SECONDS)))


static func generation_options(temp_override: float = -1.0) -> Dictionary:
	var temp := DEFAULT_TEMPERATURE
	if temp_override >= 0.0:
		temp = clampf(temp_override, 0.0, 2.0)
	return {
		"temperature": temp,
		"num_predict": DEFAULT_NUM_PREDICT,
		"num_ctx": DEFAULT_NUM_CTX,
		"think": DEFAULT_THINK,
	}


static func chat_endpoint() -> String:
	return base_url().trim_suffix("/") + "/api/chat"


static func tags_endpoint() -> String:
	return base_url().trim_suffix("/") + "/api/tags"


## Live configuration identity for stale-response validation. Mirrors
## AIBackendConfig.config_identity() without creating a load dependency.
static func config_identity() -> String:
	var b := str(ProjectSettings.get_setting("strategy_game/ai/backend_type", "LOCAL_OLLAMA")).strip_edges().to_upper()
	var r := int(ProjectSettings.get_setting("strategy_game/ai/config_revision", 0))
	return "%s|%s|%s|r%d" % [b, base_url(), model(), r]


## Evidence helper: exact effective configuration for one request.
## (Key presence lives in AIBackendConfig.current()["api_key_present"];
## the secret itself is never placed in any Dictionary.)
static func describe(temp_override: float = -1.0) -> Dictionary:
	return {
		"base_url": base_url(),
		"endpoint": chat_endpoint(),
		"model": model(),
		"role": "TACTICAL_MODEL",
		"backend_type": str(ProjectSettings.get_setting("strategy_game/ai/backend_type", "LOCAL_OLLAMA")),
		"config_identity": config_identity(),
		"timeout_seconds": timeout_seconds(),
		"options": generation_options(temp_override),
		"stream": false,
		"format": "json",
	}


## Semantic-role request description: tiny tag, compact budgets, greedy
## decoding. Used ONLY by the semantic frontend fast path.
static func describe_semantic(temp_override: float = 0.0) -> Dictionary:
	var temp := 0.0
	if temp_override >= 0.0:
		temp = clampf(temp_override, 0.0, 2.0)
	return {
		"base_url": base_url(),
		"endpoint": chat_endpoint(),
		"model": semantic_model(),
		"role": "SEMANTIC_MODEL",
		"backend_type": str(ProjectSettings.get_setting("strategy_game/ai/backend_type", "LOCAL_OLLAMA")),
		"config_identity": config_identity(),
		"timeout_seconds": SEMANTIC_TIMEOUT_SECONDS,
		"options": {
			"temperature": temp,
			"num_predict": SEMANTIC_NUM_PREDICT,
			"num_ctx": SEMANTIC_NUM_CTX,
			"think": false,
		},
		"stream": false,
		"format": "json",
	}
