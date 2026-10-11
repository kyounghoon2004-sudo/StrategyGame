class_name Step7AdvisorViewModel
extends RefCounted

## Deterministic, UI-safe translation over the cavalry OptionPackage.
##
## Owns NO legality, NO scoring, NO movement state, NO hidden truth.
## Input: the exact Dictionary returned by Step7CavalryEvaluator.evaluate()
## (the same package the DEV inspector renders). Output: player-facing
## Korean labels, qualitative levels, and templated summaries.
##
## FOG SAFETY: player text is built ONLY from the option's own
## risk/support/mobility/pressure scalars, destination, status, and the
## evaluator's own reason string. known_ids / stale_ids / contributions /
## weights / utility / latency are never rendered here (DEV-only).

const DoctrineScript = preload("res://scripts/step7/step7_cavalry_doctrine.gd")

## Tokens that must never appear in PLAYER-mode strings. The regression
## probe asserts every window string against this list.
const PLAYER_BANNED_TOKENS: Array = [
	"DEV", "EVALUATE", "EXECUTE PICK", "u=", "state_version",
	"candidate_count", "CLUSTER_PROBE", "LATERAL PROJECTION",
	"MAD", "CACHE HIT", "cache_hit", "utility",
	"contribution", "provenance", "fingerprint",
]

const PROFILE_KR := {
	"SAFE": "안전 기동",
	"SUPPORTED": "지원 유지",
	"BALANCED": "균형 기동",
	"PRESSURE": "압박 기동",
	"DEEP": "심부 기동",
	"MAXIMUM": "최대 기동",
}

## Deterministic short tactical descriptions (UI copy, not model reasoning).
const PROFILE_SUMMARY := {
	"SAFE": "아군 지원과 퇴로를 유지하는 이동입니다.",
	"SUPPORTED": "아군과 보조를 맞추며 전열을 유지하는 이동입니다.",
	"BALANCED": "위험과 진격의 균형을 맞춘 기본 이동입니다.",
	"PRESSURE": "적에게 더 강한 압박을 주지만 노출 위험이 증가합니다.",
	"DEEP": "외곽 깊숙이 기동해 측면 기회를 노립니다. 고립 위험이 높습니다.",
	"MAXIMUM": "가용한 기동력을 최대한 쓰는 전진입니다. 퇴로 여유가 줄어듭니다.",
}

## Which qualitative meters each card shows (risk dict keys + labels).
const CARD_LINES := {
	"SAFE": [["risk", "위험"], ["support", "지원"], ["mobility", "기동성"]],
	"SUPPORTED": [["support", "지원"], ["risk", "위험"], ["mobility", "기동성"]],
	"BALANCED": [["risk", "위험"], ["pressure", "압박"], ["mobility", "기동성"]],
	"PRESSURE": [["pressure", "압박"], ["risk", "위험"], ["mobility", "기동성"]],
	"DEEP": [["risk", "위험"], ["pressure", "압박"], ["support", "지원"]],
	"MAXIMUM": [["pressure", "압박"], ["risk", "위험"], ["mobility", "기동성"]],
}

const CLASS_KR := {
	"CAVALRY": "기병대",
	"INFANTRY": "보병대",
	"SPEARMAN": "창병대",
	"ARCHER": "궁병대",
	"SCOUT": "정찰대",
	"SIEGE": "공성대",
	"CONSCRIPT": "징집대",
	"HQ": "지휘부",
	"SUPPLY": "보급대",
}


static func profile_kr(profile: String) -> String:
	return str(PROFILE_KR.get(profile.strip_edges().to_upper(), profile))


static func profile_summary(profile: String) -> String:
	return str(PROFILE_SUMMARY.get(profile.strip_edges().to_upper(), "전술적 이동안입니다."))


static func class_kr(unit_class: String) -> String:
	return str(CLASS_KR.get(unit_class.strip_edges().to_upper(), unit_class))


static func ordered_profiles() -> Array:
	return (DoctrineScript.PROFILES as Array).duplicate()


## Qualitative level for a 0..1 scalar: risk-style (low is good) and
## meter-style share the same words; the label carries the meaning.
static func level_of(v: float) -> String:
	var c := clampf(v, 0.0, 1.0)
	if c < 0.33:
		return "낮음"
	if c < 0.66:
		return "보통"
	return "높음"


## Dynamic player-facing cluster name. Never hard-codes only five bands:
## C/L1..Ln/R1..Rn with extremes honored, deeper bands fall back to
## "좌익 외곽 N / 우익 외곽 N".
static func cluster_display(cid: String, extreme_left: String = "", extreme_right: String = "") -> String:
	var c := cid.strip_edges().to_upper()
	if c.is_empty():
		return "구역 확인 중"
	if c == "C":
		return "C · 중앙"
	if c.begins_with("L") and c.length() > 1 and c.substr(1).is_valid_int():
		var n := int(c.substr(1))
		if c == extreme_left:
			return "%s · 극좌익" % c
		if n == 1:
			return "%s · 좌익" % c
		return "%s · 좌익 외곽 %d" % [c, n]
	if c.begins_with("R") and c.length() > 1 and c.substr(1).is_valid_int():
		var n2 := int(c.substr(1))
		if c == extreme_right:
			return "%s · 극우익" % c
		if n2 == 1:
			return "%s · 우익" % c
		return "%s · 우익 외곽 %d" % [c, n2]
	return c


## Evaluator DEGRADED reasons are the only sanctioned source for the
## "제한적" note. Maps each known deterministic reason to Korean UI copy.
static func degraded_note(reason: String) -> String:
	var r := reason.strip_edges()
	match r:
		"no favorable target; using positional pressure":
			return "유리한 공격축이 없어 전진 압박으로 대체"
		"safest legal option still faces known counter-risk":
			return "가장 안전한 경로에도 적 대응 위험이 남아 있음"
		"limited disengagement geometry":
			return "퇴로 여유가 제한됨"
		"all advancing options pull away from support":
			return "전진 시 아군 지원에서 이탈"
		"deep maneuver accepted with weak exit/support":
			return "퇴로·지원이 약한 심부 기동"
		"maximal progress crosses poor cavalry ground":
			return "기동 불량 지형을 통과하는 최대 전진"
	if r.is_empty():
		return "조건부 실행 가능"
	return "조건부 실행 가능"


## One UI-safe card per evaluator option slot. Always returns exactly the
## slots present in the package (six for the cavalry pilot).
static func option_cards(pkg: Dictionary) -> Array:
	var out: Array = []
	for o_val in (pkg.get("options", []) as Array):
		if not o_val is Dictionary:
			continue
		var o: Dictionary = o_val
		var profile := str(o.get("profile", "?")).to_upper()
		var status := str(o.get("status", "UNAVAILABLE")).to_upper()
		var card := {
			"slot": int(o.get("slot", 0)),
			"profile": profile,
			"title": profile_kr(profile),
			"status": status,
			"available": status == "AVAILABLE" or status == "DEGRADED",
			"has_destination": o.has("destination"),
			"lines": [],
			"note": "",
			"summary": profile_summary(profile),
		}
		if status == "UNAVAILABLE":
			card["note"] = "현재 실행 가능한 경로 없음"
		else:
			var rk: Dictionary = o.get("risk", {})
			for pair in (CARD_LINES.get(profile, CARD_LINES["BALANCED"]) as Array):
				var key := str((pair as Array)[0])
				var label := str((pair as Array)[1])
				card["lines"].append("%s: %s" % [label, level_of(float(rk.get(key, 0.0)))])
			if status == "DEGRADED":
				card["note"] = "제한적 — " + degraded_note(str(o.get("reason", "")))
		out.append(card)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["slot"]) < int(b["slot"]))
	return out


static func neutral_briefing() -> String:
	return "부대를 선택하시면 전술안을 아뢰겠습니다."


static func unsupported_briefing(class_label: String) -> String:
	return "이 병종(%s)의 전술 평가 모델은 아직 준비되지 않았습니다." % class_label


## Asserts a player-facing string carries no DEV/debug leakage and no
## hidden-actor id. Id matching uses token boundaries so "R_GAR_INF_1"
## never counts as "R_INF_1". Used by the regression probe; "" when clean.
static func audit_player_text(text: String, hidden_ids: Array = []) -> String:
	for tok in PLAYER_BANNED_TOKENS:
		if text.find(str(tok)) >= 0:
			return "banned token '%s' in player text" % str(tok)
	for hid in hidden_ids:
		var h := str(hid).strip_edges()
		if h.is_empty():
			continue
		var re := RegEx.new()
		# Unit/contact ids are [A-Z0-9_]; regex-safe without escaping.
		re.compile("\\b%s\\b" % h)
		if re.search(text) != null:
			return "hidden id '%s' leaked in player text" % h
	return ""


## Identifier-shaped tokens the Advisor model may legitimately emit without
## them being unit/contact ids (doctrine vocabulary, never redacted).
## Includes the class-specific evidence features (scout info, screens,
## denial) so display sanitization never eats tactical reasoning.
const ADVISOR_SAFE_VOCAB := [
	"INFORMATION_GAIN", "SCREEN_PROTECTION", "CAVALRY_DENIAL",
	"SAFE", "SUPPORTED", "BALANCED", "PRESSURE", "DEEP", "MAXIMUM",
	"INTENT_PROGRESS", "MOVEMENT_USE", "OPEN_MANEUVER_SPACE", "MOBILITY_FUTURE",
	"FLANK_VALUE", "MATCHUP_OPPORTUNITY", "ARCHER_ACCESS", "COUNTER_RISK",
	"THREAT_EXPOSURE", "FORMATION_SUPPORT", "ISOLATION_RISK", "RETREAT_SAFETY",
	"TERRAIN_MOBILITY", "ROUTE_COST", "ROUTE_EXPOSURE", "OBJECTIVE_VALUE",
	"PRESSURE_VALUE", "UNCERTAINTY_RISK", "CLUSTER_ALIGNMENT", "CLUSTER_COHESION",
	"HEX", "BLUE", "RED", "ADVANCE", "SEO_YUSEON",
]


## Display sanitizer for model prose: any identifier-shaped token that was
## neither supplied in the tactical snapshot nor doctrine vocabulary is
## replaced with a generic side-appropriate noun. The precise-looking id
## never reaches the player; the redaction count is returned for DEV logs.
## supplied_ids: every BLUE-authorized id the model was allowed to name.
static func sanitize_advisor_text(text: String, supplied_ids: Array) -> Dictionary:
	var allowed := {}
	for v in ADVISOR_SAFE_VOCAB:
		allowed[str(v)] = true
	for s in supplied_ids:
		allowed[str(s)] = true
	var re := RegEx.new()
	re.compile("\\b[A-Z][A-Z0-9]*_[A-Z0-9_]+\\b")
	var redactions: Array = []
	var out := ""
	var pos := 0
	for m in re.search_all(text):
		var tok := m.get_string()
		out += text.substr(pos, m.get_start() - pos)
		if allowed.has(tok):
			out += tok
		else:
			redactions.append(tok)
			if tok.begins_with("B_"):
				out += "아군 부대"
			elif tok.begins_with("R_"):
				out += "적 부대"
			else:
				out += "해당 부대"
		pos = m.get_end()
	out += text.substr(pos)
	return {"text": out, "redactions": redactions}
