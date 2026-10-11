extends SceneTree

## STEP 7 catalog validator: EXACTLY 50 canonical DATA presets (§38).
## Structural only — no scene boot, no execution, no inference.
## Evidence: evidence/step7_catalog_50.json

const AC = preload("res://scripts/step7/step7_action_command.gd")
const Planner = preload("res://scripts/step7/step7_operation_planner.gd")
const OUT := "D:/Game development/Demon slayer/StrategyGame/evidence/step7_catalog_50.json"

var failures: Array = []
var notes: Array = []


func _init() -> void:
	call_deferred("_run")


func _check(cond: bool, name: String) -> void:
	if cond:
		notes.append("PASS " + name)
	else:
		failures.append(name)


func _run() -> void:
	var presets: Dictionary = AC.presets()
	var order: Array = AC.PRESET_ORDER
	var groups: Array = AC.preset_groups()
	_check(presets.size() == 50, "count == 50 (got %d)" % presets.size())
	_check(order.size() == 50, "order == 50 (got %d)" % order.size())
	var key_set := {}
	for k in presets.keys():
		key_set[str(k)] = true
	var order_ok := order.size() == presets.size()
	if order_ok:
		for pid in order:
			if not key_set.has(str(pid)):
				order_ok = false
		for k in key_set.keys():
			if not order.has(k):
				order_ok = false
	_check(order_ok, "PRESET_ORDER matches presets() keys 1:1")
	var group_count := {}
	var seen_norm := {}
	var dupe_norm: Array = []
	var invalid: Array = []
	var unsupported: Array = []
	for pid in order:
		if not presets.has(pid):
			invalid.append("%s: missing row" % str(pid))
			continue
		var row: Variant = presets[pid]
		if not row is Dictionary:
			invalid.append("%s: row not a Dictionary" % str(pid))
			continue
		var r: Dictionary = row
		if str(r.get("label", "")) != str(pid):
			invalid.append("%s: label mismatch" % str(pid))
			continue
		var g := str(r.get("group", ""))
		if not g in groups:
			invalid.append("%s: bad group '%s'" % [str(pid), g])
			continue
		group_count[g] = int(group_count.get(g, 0)) + 1
		if not r.has("command") or not (r.get("command") is Dictionary):
			invalid.append("%s: missing command dict" % str(pid))
			continue
		var cmd: Dictionary = r["command"]
		var action := str(cmd.get("action", "")).to_upper()
		if not action in AC.VALID_ACTIONS:
			invalid.append("%s: unknown action '%s'" % [str(pid), action])
			continue
		var scope: Dictionary = cmd.get("scope", {})
		var stype := str(scope.get("type", "")).to_upper()
		if not stype in AC.VALID_SCOPE_TYPES:
			invalid.append("%s: bad scope type" % str(pid))
			continue
		if stype == "CLASS" and not str(scope.get("class", "")).to_upper() in AC.VALID_CLASSES:
			invalid.append("%s: bad class scope" % str(pid))
			continue
		if stype == "UNIT_ID" and str(scope.get("unit_id", "")).strip_edges().is_empty():
			invalid.append("%s: empty unit_id scope" % str(pid))
			continue
		var dir := str(cmd.get("direction", "")).to_upper()
		if action in AC.DIRECTION_REQUIRED and not dir in AC.VALID_DIRECTIONS:
			invalid.append("%s: %s needs a valid direction" % [str(pid), action])
			continue
		if not dir.is_empty() and not dir in AC.VALID_DIRECTIONS:
			invalid.append("%s: bad direction '%s'" % [str(pid), dir])
			continue
		if action in ["REPOSITION", "WITHDRAW", "REGROUP", "PROTECT", "SCREEN"]:
			var tres: Dictionary = AC.validate_target(cmd.get("target", {}))
			if not bool(tres.get("ok", false)):
				invalid.append("%s: bad target (%s)" % [str(pid), str(tres.get("code", "?"))])
				continue
		if action == "MOVE":
			var t: Variant = cmd.get("target", {})
			if not t is Dictionary or str((t as Dictionary).get("type", "")).to_upper() != "HEX":
				invalid.append("%s: MOVE needs HEX target" % str(pid))
				continue
		var structural: Dictionary = AC.validate_structure(cmd)
		if not bool(structural.get("ok", false)):
			invalid.append("%s: structural reject (%s)" % [str(pid), str(structural.get("code", "?"))])
			continue
		# Deterministic capability status is always computable from the
		# centralized planner matrix (verbs absent there admit every class).
		var cap := true
		if stype == "CLASS":
			cap = Planner._class_allowed_for_action(action, str(scope.get("class", "")).to_upper())
		if not cap:
			unsupported.append("%s: class not allowed for %s" % [str(pid), action])
		var norm := JSON.stringify([action, scope, dir, cmd.get("target", {})])
		if seen_norm.has(norm):
			dupe_norm.append("%s ~= %s" % [str(pid), str(seen_norm[norm])])
		else:
			seen_norm[norm] = str(pid)
	_check(invalid.is_empty(), "0 invalid presets (%d)" % invalid.size())
	for bad in invalid:
		failures.append(str(bad))
	_check(dupe_norm.is_empty(), "0 duplicate normalized presets (%d)" % dupe_norm.size())
	for d in dupe_norm:
		failures.append("DUPE " + str(d))
	_check(unsupported.is_empty(), "0 capability-unsupported presets (%d)" % unsupported.size())
	for u in unsupported:
		failures.append("UNSUP " + str(u))
	var expect := {"GENERAL": 10, "CAVALRY": 8, "SCOUT": 7, "INFANTRY": 6, "SPEARMAN": 5, "ARCHER": 5, "SIEGE": 4, "EXACT UNIT": 5}
	for g in expect.keys():
		_check(int(group_count.get(g, 0)) == int(expect[g]), "group %s == %d (got %d)" % [str(g), int(expect[g]), int(group_count.get(g, 0))])
	_write({"count": presets.size(), "groups": group_count})
	print("CATALOG_" + ("PASS" if failures.is_empty() else "FAIL") + " (%d/%d)" % [notes.size(), notes.size() + failures.size()])
	quit(0 if failures.is_empty() else 2)


func _write(extra: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute((OUT as String).get_base_dir())
	var file := FileAccess.open(OUT, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify({"status": "PASS" if failures.is_empty() else "FAIL", "failures": failures, "notes": notes, "extra": extra}, "  "))
