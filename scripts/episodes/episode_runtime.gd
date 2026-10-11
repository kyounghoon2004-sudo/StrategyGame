extends RefCounted

## One immutable-by-convention snapshot, installed before a shell creates its map.
## Reset on shell exit so consecutive local matches cannot inherit balance.
static var _spec: Dictionary = {}
static var _path: String = ""

static func install(spec: Dictionary, path: String = "") -> void:
	_spec = spec.duplicate(true)
	_path = path

static func clear() -> void:
	_spec = {}
	_path = ""

## Launch telemetry (not part of the spec): which exact file was installed.
static func launch_record() -> Dictionary:
	if _spec.is_empty():
		return {}
	return {"episode_id": _spec["episode_id"], "spec_path": _path, "family": _spec["family"],
		"split": _spec["split"], "map": _spec["map"]["id"]}

static func current() -> Dictionary:
	return _spec.duplicate(true)

static func rules() -> Dictionary:
	return _spec.get("rules", {})

static func episode_id() -> String:
	return str(_spec.get("episode_id", ""))

## Provenance headers for localhost learned-stack calls (Brain server, Hands
## worker); empty without an episode, so legacy requests are unchanged.
static func provenance_headers() -> PackedStringArray:
	if _spec.is_empty():
		return PackedStringArray()
	return PackedStringArray(["X-Episode-Id: " + str(_spec["episode_id"]),
		"X-Episode-Spec-Path: " + _path.uri_encode()])

static func public_context() -> Dictionary:
	if _spec.is_empty():
		return {}
	return {
		"episode_id": _spec["episode_id"],
		"family": _spec["family"], "split": _spec["split"],
		"map": _spec["map"].duplicate(true),
		"rules": _spec["rules"].duplicate(true),
		"objective": _spec["objective"].duplicate(true),
	}
