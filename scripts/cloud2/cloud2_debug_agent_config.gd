class_name Cloud2DebugAgentConfig
extends RefCounted

## AGENT-AS-GENERAL DEBUG HARNESS — backend + blindness configuration.
##
## Pure resolution, no game state, no network. Follows project conventions:
##   1. Environment: GENERAL_BACKEND / GENERAL_BLINDNESS / GENERAL_TIMEOUT_SEC
##   2. Command line: --general-backend= / --general-blindness= / --general-timeout=
##   3. ProjectSettings: strategy_game/general_backend (default PROVIDER)
##
## Backend identities (this gate):
##   REAL_PROVIDER — the existing cloud/provider path (alias of PROVIDER).
##   DEBUG_AGENT   — the local coding/debug agent acts as RED General through
##                   the file debug transport (alias of EXTERNAL_AGENT).
## Production default is unchanged: PROVIDER.
##
## Blindness classification (interface-level contract):
##   SYSTEM_DEBUG  — wiring/schema/execution debugging. May expose world truth
##                   sidecars. Results are NON_BLIND and must never count as
##                   General-reasoning evidence.
##   BLIND_GENERAL — Brain-quality evaluation. The General-facing interface
##                   exposes ONLY the RED-authorized packet that the production
##                   General sees. Truth sidecars exist for the orchestrator
##                   but are refused by the General-facing commands.
##   CONTAMINATED  — a BLIND_GENERAL run in which world truth was exposed to
##                   the General context (same session saw truth). Never valid
##                   as blind evidence. The harness marks this, never hides it.

const BACKEND_REAL_PROVIDER := "REAL_PROVIDER"
const BACKEND_DEBUG_AGENT := "DEBUG_AGENT"
## Canonical controller values these alias to (Cloud2TurnController).
const PROVIDER_CANONICAL := "PROVIDER"
const AGENT_CANONICAL := "EXTERNAL_AGENT"

const BLIND_SYSTEM_DEBUG := "SYSTEM_DEBUG"
const BLIND_BLIND_GENERAL := "BLIND_GENERAL"
const BLIND_CONTAMINATED := "CONTAMINATED"
const BLIND_NON_BLIND := "NON_BLIND"

const SETTING_BACKEND := "strategy_game/general_backend"

const PROTOCOL_VERSION := "debug_agent_protocol_v1"

## Harness exit codes (distinct from gate pass/fail so automation can tell
## a timeout from a crash from a completed battle).
const EXIT_DONE := 0
const EXIT_GATE_FAIL := 1
const EXIT_TIMEOUT := 3
const EXIT_ERROR := 4


static func canonical_backend(name: String) -> String:
	var want := name.strip_edges().to_upper()
	if want == BACKEND_DEBUG_AGENT or want == AGENT_CANONICAL:
		return AGENT_CANONICAL
	if want == BACKEND_REAL_PROVIDER or want == PROVIDER_CANONICAL:
		return PROVIDER_CANONICAL
	if want == "MOCK":
		return "MOCK"
	return ""


static func display_backend(name: String) -> String:
	var want := name.strip_edges().to_upper()
	if want == BACKEND_DEBUG_AGENT or want == AGENT_CANONICAL:
		return BACKEND_DEBUG_AGENT
	if want == BACKEND_REAL_PROVIDER or want == PROVIDER_CANONICAL:
		return BACKEND_REAL_PROVIDER
	return want


static func is_agent_backend(name: String) -> bool:
	return canonical_backend(name) == AGENT_CANONICAL


static func is_provider_backend(name: String) -> bool:
	return canonical_backend(name) == PROVIDER_CANONICAL


## Resolve the requested backend name. Sources (highest priority first):
## explicit arg > GENERAL_BACKEND env > --general-backend= cmdline >
## ProjectSettings > PROVIDER default. Returns "" when nothing is set and
## no default is wanted (caller decides); resolve_or_default() never does.
static func resolve_backend(explicit: String = "") -> String:
	if not explicit.strip_edges().is_empty():
		return explicit.strip_edges().to_upper()
	var env := OS.get_environment("GENERAL_BACKEND").strip_edges().to_upper()
	if not env.is_empty():
		return env
	for a in OS.get_cmdline_user_args():
		var s := str(a).strip_edges()
		if s.begins_with("--general-backend="):
			return s.get_slice("=", 1).strip_edges().to_upper()
	for a2 in OS.get_cmdline_args():
		var s2 := str(a2).strip_edges()
		if s2.begins_with("--general-backend="):
			return s2.get_slice("=", 1).strip_edges().to_upper()
	var ps := str(ProjectSettings.get_setting(SETTING_BACKEND, "")).strip_edges().to_upper()
	if not ps.is_empty():
		return ps
	return ""


static func resolve_or_default(explicit: String = "") -> String:
	var r := resolve_backend(explicit)
	return r if not r.is_empty() else PROVIDER_CANONICAL


static func resolve_blindness(explicit: String = "") -> String:
	if not explicit.strip_edges().is_empty():
		return explicit.strip_edges().to_upper()
	var env := OS.get_environment("GENERAL_BLINDNESS").strip_edges().to_upper()
	if not env.is_empty():
		return env
	for a in OS.get_cmdline_user_args():
		var s := str(a).strip_edges()
		if s.begins_with("--general-blindness="):
			return s.get_slice("=", 1).strip_edges().to_upper()
	return BLIND_SYSTEM_DEBUG


static func resolve_timeout_sec(explicit: float = 0.0, fallback: float = 600.0) -> float:
	if explicit > 0.0:
		return explicit
	var env := OS.get_environment("GENERAL_TIMEOUT_SEC").strip_edges()
	if env.is_valid_float() and float(env) > 0.0:
		return float(env)
	for a in OS.get_cmdline_user_args():
		var s := str(a).strip_edges()
		if s.begins_with("--general-timeout="):
			var v := s.get_slice("=", 1).strip_edges()
			if v.is_valid_float() and float(v) > 0.0:
				return float(v)
	return fallback


## Classify a run for evidence purposes. truth_exposed must be true when the
## General-serving context ever displayed world-truth fields.
static func classify_run(blindness: String, truth_exposed: bool) -> Dictionary:
	var mode := blindness.strip_edges().to_upper()
	if mode == BLIND_BLIND_GENERAL and truth_exposed:
		return {"classification": BLIND_CONTAMINATED,
			"evidence_valid": false,
			"detail": "BLIND_GENERAL run exposed world truth to the General context; marked CONTAMINATED, not blind evidence."}
	if mode == BLIND_BLIND_GENERAL:
		return {"classification": BLIND_BLIND_GENERAL,
			"evidence_valid": true,
			"detail": "General interface exposed only the RED-authorized packet."}
	return {"classification": BLIND_NON_BLIND,
		"evidence_valid": false,
		"detail": "SYSTEM_DEBUG run; valid for wiring/schema evidence only (NON_BLIND)."}
