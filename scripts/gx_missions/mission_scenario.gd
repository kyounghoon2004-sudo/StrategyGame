extends RefCounted

## GX MISSIONS v1 — scenario seam (data only, no scene-name checks).
## A scenario supplies a `mission` block:
##   {mission_id, family M1..M5, roles {red, blue} (attacker/defender/none), village_hexes (M1),
##    stronghold_id + optional stronghold def (M2/M5), site_hexes x3 (M4), round_limit, collapse_frac, morale}
## Sources, first hit wins: explicit override (DEV fixture / sandbox overlay) -> battlefield data
## (shell._battlefield.mission) -> installed episode (EpisodeRuntime.current().mission).

const CfgCls = preload("res://scripts/gx_missions/mission_config.gd")
const EpisodeRuntimeCls = preload("res://scripts/episodes/episode_runtime.gd")

const FAMILIES := ["M1", "M2", "M3", "M4", "M5"]
const FAMILY_NAMES := {"M1": "DEFENSE_DELAY", "M2": "FORTRESS_DEFENSE", "M3": "FIELD_BATTLE",
	"M4": "OCCUPATION", "M5": "SIEGE"}


static func resolve(shell: Node, override: Dictionary = {}) -> Dictionary:
	if not override.is_empty():
		return normalize(override)
	if shell != null:
		var bf: Variant = shell.get("_battlefield")
		if bf is Dictionary and (bf as Dictionary).has("mission"):
			return normalize((bf as Dictionary)["mission"])
	var ep: Dictionary = EpisodeRuntimeCls.current()
	if ep.has("mission"):
		return normalize(ep["mission"])
	return {}


## Returns the normalized block, or {"error": ...}.
static func normalize(raw: Dictionary) -> Dictionary:
	var rules := CfgCls.section("rules")
	var m := raw.duplicate(true)
	var fam := str(m.get("family", "")).to_upper()
	if not fam in FAMILIES:
		return {"error": "unknown mission family '%s'" % fam}
	m["family"] = fam
	m["family_name"] = FAMILY_NAMES[fam]
	m["mission_id"] = str(m.get("mission_id", fam))
	var roles: Dictionary = m.get("roles", {})
	if fam in ["M3", "M4"]:
		roles = {"red": "none", "blue": "none"}
	elif not (str(roles.get("red", "")) in ["attacker", "defender"] and str(roles.get("blue", "")) in ["attacker", "defender"] \
			and str(roles["red"]) != str(roles["blue"])):
		return {"error": "family %s needs roles {red, blue} = one attacker + one defender" % fam}
	m["roles"] = roles
	m["round_limit"] = int(m.get("round_limit", rules.get("round_limit_default", 30)))
	m["collapse_frac"] = float(m.get("collapse_frac", rules.get("collapse_frac_default", 0.30)))
	m["morale"] = bool(m.get("morale", false))
	if fam == "M1" and (m.get("village_hexes", []) as Array).is_empty():
		return {"error": "M1 needs village_hexes"}
	if fam in ["M2", "M5"] and str(m.get("stronghold_id", "")).is_empty():
		return {"error": "%s needs stronghold_id" % fam}
	if fam == "M4" and (m.get("site_hexes", []) as Array).size() != int(rules.get("m4_n_sites", 3)):
		return {"error": "M4 needs exactly %d site_hexes" % int(rules.get("m4_n_sites", 3))}
	return m


static func hexes(m: Dictionary, key: String) -> Array:
	var out: Array = []
	for h in (m.get(key, []) as Array):
		out.append(Vector2i(int(h[0]), int(h[1])))
	return out


static func attacker_of(m: Dictionary) -> String:
	for s in ["red", "blue"]:
		if str((m.get("roles", {}) as Dictionary).get(s, "")) == "attacker":
			return s
	return ""


static func defender_of(m: Dictionary) -> String:
	for s in ["red", "blue"]:
		if str((m.get("roles", {}) as Dictionary).get(s, "")) == "defender":
			return s
	return ""
