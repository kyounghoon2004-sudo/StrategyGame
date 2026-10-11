class_name Step7SemanticModel
extends RefCounted

## Semantic-frontend model identity (ZERO manual setup).
##
## The tiny Qwen3-0.6B-class checkpoint owns FAST INTENT ROUTING +
## COMMAND SEMANTIC COMPILATION only. It is NEVER the tactical brain.
## The large tactical/advisor model keeps its existing role and tag.
##
## Source (tuned) repo : distil-labs/distil-home-assistant-qwen3
##   Qwen3-0.6B -> domain fine-tune for structured intent/slot/function
##   calling. ~596,049,920 params. Tuning language: English.
## Runtime GGUF repo  : distil-labs/distil-home-assistant-qwen3-gguf
##   NOTE: the GGUF repo publishes EXACTLY ONE artifact (verified
##   2026-09-16 via the HF API): a full-precision F16 GGUF. There are NO
##   Q4/Q5/Q8 published quants to choose from, so "highest practical
##   quant" == the published F16 until we self-quantize (out of scope:
##   no quantize toolchain in this repo; correctness has priority and
##   ~1.2 GB is affordable inside the total budget for a 0.6B model).
##
## Cache lives OUTSIDE the Git repo (persistent local dir, never committed).

const HF_SOURCE_REPO := "distil-labs/distil-home-assistant-qwen3"
const HF_GGUF_REPO := "distil-labs/distil-home-assistant-qwen3-gguf"
const HF_FILE := "distil-home-assistant-qwen3.gguf"
const HF_BRANCH := "main"
const PARAM_COUNT := 596049920
const QUANT_LABEL := "F16 (sole published artifact; no Q4/Q6/Q8 published)"
const CONTEXT_LENGTH := 40960

## Upstream byte size from the HF API (gguf.totalFileSize). Used as the
## integrity gate: a cached file must be within tolerance of this size.
const EXPECTED_BYTES := 1198182624
const SIZE_TOLERANCE_BYTES := 8388608 # 8 MiB slack for header/tooling drift.

## Ollama tag the game registers from the cached GGUF (role SEMANTIC).
const OLLAMA_TAG := "strategy-game-semantic-qwen06:latest"

## Role names (model ROLE separation; never swap tags globally).
const ROLE_SEMANTIC := "SEMANTIC_MODEL"
const ROLE_TACTICAL := "TACTICAL_MODEL"


static func hf_url() -> String:
	return "https://huggingface.co/%s/resolve/%s/%s" % [HF_GGUF_REPO, HF_BRANCH, HF_FILE]


static func cache_dir() -> String:
	var local := OS.get_environment("LOCALAPPDATA").strip_edges()
	if not local.is_empty():
		return local + "/StrategyGame/models"
	var ud := OS.get_user_data_dir().strip_edges()
	if not ud.is_empty():
		return ud + "/models"
	return "user://models"


static func gguf_path() -> String:
	return cache_dir() + "/" + HF_FILE


static func part_path() -> String:
	return cache_dir() + "/" + HF_FILE + ".part"


static func modelfile_path() -> String:
	return cache_dir() + "/Modelfile.semantic-qwen06"


static func gguf_path_global() -> String:
	return ProjectSettings.globalize_path(gguf_path())


static func modelfile_path_global() -> String:
	return ProjectSettings.globalize_path(modelfile_path())


## Minimal Ollama Modelfile for the semantic role. Tiny context (semantic
## prompts are compact by design), greedy decoding default; per-request
## options still override. No SYSTEM here: the frontend sends its compact
## contract per call.
##
## TEMPLATE replicates the fine-tune's native chat template (no-tools
## branch, thinking DISABLED via the empty <think></think> block) in
## Ollama Go-template syntax. Without it Ollama falls back to a raw
## "{{ .Prompt }}" template and the checkpoint degenerates into think-tag
## spew (measured 2026-09-16). Stops mirror the native turn boundary.
static func modelfile_text() -> String:
	var lines: Array = []
	lines.append("FROM \"%s\"" % gguf_path_global().replace("\\", "/"))
	lines.append("TEMPLATE \"\"\"{{- range $i, $m := .Messages -}}<|im_start|>{{ $m.Role }}\n{{ $m.Content }}<|im_end|>\n{{ end -}}<|im_start|>assistant\n<think>\n\n</think>\n\n\"\"\"")
	lines.append("PARAMETER temperature 0.0")
	lines.append("PARAMETER num_ctx 4096")
	lines.append("PARAMETER num_predict 1024")
	lines.append("PARAMETER stop \"<|im_end|>\"")
	lines.append("PARAMETER stop \"<|im_start|>\"")
	return "\n".join(lines) + "\n"


static func expected_mb() -> float:
	return float(EXPECTED_BYTES) / 1048576.0


static func download_mb() -> float:
	return expected_mb()


static func describe() -> Dictionary:
	return {
		"source_repo": HF_SOURCE_REPO,
		"gguf_repo": HF_GGUF_REPO,
		"artifact": HF_FILE,
		"url": hf_url(),
		"quant": QUANT_LABEL,
		"params": PARAM_COUNT,
		"context_length": CONTEXT_LENGTH,
		"expected_bytes": EXPECTED_BYTES,
		"ollama_tag": OLLAMA_TAG,
		"cache_dir": cache_dir(),
		"gguf_path": gguf_path(),
	}
