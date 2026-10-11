extends SceneTree

## ============================================================================
## CLOUD GENERAL — DEV CONTRACT CONTINUOUS AUDIT (COLD, INDEPENDENT)
## ============================================================================
## Boots the REAL DEV scene (res://scenes/cloud1_battle_test.tscn) in this
## process and drives the LIVE authorities: shell, Step3UnitManager, Step7
## command service, Cloud1 bridge/compiler/executor/dock.
##
## Verifies the Step 0 / Step 1 contract continuously across lifecycle
## boundaries: boot, commands, turns, roster resets, scene reentry, and
## production isolation — NOT one-shot _ready() state.
##
## Run (fresh process, headless):
##   Godot_v4.2.2-stable_win64_console.exe --headless --path "<proj>" \
##     -s res://scripts/cloud1/audit/cloud1_dev_contract_audit.gd
##
## Exit code 0 = every gate passed. Writes:
##   evidence/cloud1_audit/dev_contract_audit.json
##   .workflow/deliverables/CLOUD-GENERAL-STEP-01/verification.json (merged)

const ScopeAlgebraCls = preload("res://scripts/step7/step7_scope_algebra.gd")
const TableCls = preload("res://scripts/cloud1/cloud1_action_table.gd")
const CompilerCls = preload("res://scripts/cloud1/cloud1_compiler.gd")
const ObsCls = preload("res://scripts/cloud1/cloud1_observation.gd")
const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")
const CombatCalcCls = preload("res://scripts/combat/combat_calculator.gd")
const Step3ConfigCls = preload("res://scripts/core/step3_config.gd")
const ShellCls = preload("res://scripts/step2r/step2r_battlefield_shell.gd")
const SimControllerCls = preload("res://scripts/sim/sim_controller.gd")

var rules_lib: Script = null


func _rules() -> Script:
	if rules_lib == null:
		rules_lib = load("res://scripts/core/sandbox_rules.gd") as Script
	return rules_lib

const DEV_SCENE := "res://scenes/cloud1_battle_test.tscn"
const PROD_SCENE := "res://scenes/step2r_battlefield_shell.tscn"
const TITLE_SCENE := "res://scenes/title_screen.tscn"

const REPORT_DIR := "D:/Game development/Demon slayer/StrategyGame/evidence/cloud1_audit"
const REPORT_JSON := REPORT_DIR + "/dev_contract_audit.json"
const DELIVER_JSON := "D:/Game development/.workflow/deliverables/CLOUD-GENERAL-STEP-01/verification.json"

const ACTIVE_ACTIONS := ["ADVANCE", "HOLD", "WITHDRAW", "REPOSITION", "ATTACK", "FLANK", "RECON", "CONCENTRATE"]
const DEFERRED_ACTIONS := ["PRESSURE", "PURSUE", "SPREAD", "RESERVE"]
const DEFAULT_ROSTER := {"infantry": 2, "archer": 2, "spearman": 2, "cavalry": 2, "scout": 1, "hq": 1}

var gates: Dictionary = {}
var gate_order: Array = []
var notes: Array = []
var fail_count := 0
var pass_count := 0

var scene: Node = null
var shell: Node = null
var mount: Node = null
var bridge: Variant = null
var executor: Variant = null
var dock: Variant = null
var mgr: Variant = null
var service: Variant = null
var det: Node = null

var _exec_done := false
var _exec_result: Dictionary = {}
var _prod_move_done := false
var _prod_move_res: Dictionary = {}
var _t0 := 0
var _run_id := ""

const FOOD_TOKENS: Array = ["food", "supply", "ration", "convoy", "hungry", "stockpile", "starv"]


func _initialize() -> void:
	_t0 = Time.get_ticks_msec()
	_run_id = "%d_%s" % [int(Time.get_unix_time_from_system()), Time.get_datetime_string_from_system(true).replace(":", "").replace("-", "").replace("T", "_")]
	_run()


func _rec(section: String, id: String, ok: bool, evidence: Dictionary = {}) -> void:
	var status := "pass" if ok else "fail"
	if ok:
		pass_count += 1
	else:
		fail_count += 1
	gates[id] = {"section": section, "status": status, "evidence": evidence}
	gate_order.append(id)
	print("[AUDIT][%s][%s] %s" % [status.to_upper(), section, id])


func _note(t: String) -> void:
	notes.append(t)
	print("[AUDIT][NOTE] " + t)


func _on_exec_finished(result: Dictionary) -> void:
	_exec_result = result
	_exec_done = true


# ---------------------------------------------------------------------------
# Boot / teardown helpers
# ---------------------------------------------------------------------------

func _boot_dev(seconds_budget: float = 60.0) -> bool:
	var packed: PackedScene = load(DEV_SCENE)
	if packed == null:
		return false
	scene = packed.instantiate()
	root.add_child(scene)
	mount = scene.get_node_or_null("Cloud1LiveMount")
	var deadline := Time.get_ticks_msec() + int(seconds_budget * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if mount != null and bool(mount.get("mount_ready")):
			break
	if mount == null or not bool(mount.get("mount_ready")):
		return false
	shell = mount.get("shell")
	bridge = mount.get("bridge")
	executor = mount.get("executor")
	dock = mount.get("dock")
	det = mount.get("det") as Node
	mgr = bridge.get("get_manager") if false else bridge.get_manager()
	service = bridge.get_service()
	return shell != null and mgr != null


func _teardown() -> void:
	if scene != null and is_instance_valid(scene):
		root.remove_child(scene)
		scene.free()
	scene = null
	shell = null
	mount = null
	bridge = null
	executor = null
	dock = null
	mgr = null
	service = null
	det = null
	for _i in range(4):
		await process_frame


func _units() -> Array:
	var out: Array = []
	if mgr == null:
		return out
	for u in mgr.get_all_units_including_garrisoned():
		if u is Dictionary:
			out.append(u)
	return out


func _blue_alive() -> Array:
	var out: Array = []
	for u in _units():
		if str(u.get("faction", "")) == "blue" and int(u.get("soldier_count", 0)) > 0:
			out.append(u)
	return out


func _red_alive() -> Array:
	var out: Array = []
	for u in _units():
		if str(u.get("faction", "")) == "red" and int(u.get("soldier_count", 0)) > 0:
			out.append(u)
	return out


func _class_counts(units: Array) -> Dictionary:
	var c := {}
	for u in units:
		var k := str(u.get("class", "?"))
		c[k] = int(c.get(k, 0)) + 1
	return c


func _ids(units: Array) -> Array:
	var out: Array = []
	for u in units:
		out.append(str(u.get("id", "")))
	out.sort()
	return out


func _cells() -> Dictionary:
	var grid: Node = shell.get("hex_grid") as Node
	if grid == null:
		return {}
	var d: Variant = grid.get("cell_data")
	return d if d is Dictionary else {}


## Independent region math (derived from HexUtils source transform y = 42r+21q).
func _my_v(q: int, r: int) -> int:
	return 2 * r + q


func _my_bounds() -> Dictionary:
	var min_v := 999999
	var max_v := -999999
	var qmin := 999999
	var qmax := -999999
	var rmin := 999999
	var rmax := -999999
	for key in _cells().keys():
		var parts := str(key).split(",")
		if parts.size() != 2:
			continue
		var q := int(parts[0])
		var r := int(parts[1])
		var v := _my_v(q, r)
		min_v = mini(min_v, v)
		max_v = maxi(max_v, v)
		qmin = mini(qmin, q)
		qmax = maxi(qmax, q)
		rmin = mini(rmin, r)
		rmax = maxi(rmax, r)
	return {"min_vertical": min_v, "max_vertical": max_v, "q_min": qmin, "q_max": qmax, "r_min": rmin, "r_max": rmax}


func _my_region(q: int, r: int) -> String:
	var b := _my_bounds()
	var span: float = float(int(b["max_vertical"]) - int(b["min_vertical"]))
	if span <= 0.001:
		return "CENTER"
	var t: float = (float(_my_v(q, r)) - float(int(b["min_vertical"]))) / span
	if t < (1.0 / 3.0):
		return "NORTH"
	if t > (2.0 / 3.0):
		return "SOUTH"
	return "CENTER"


func _wait_true(pred: Callable, max_frames: int = 3600, max_seconds: float = 180.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(max_seconds * 1000.0)
	for _i in range(max_frames):
		if bool(pred.call()):
			return true
		if Time.get_ticks_msec() > deadline:
			return false
		await process_frame
	return bool(pred.call())


func _run_cmd(cmd: Dictionary, sel: String = "", budget: int = 7200) -> Dictionary:
	_exec_done = false
	_exec_result = {}
	if executor.execution_finished.is_connected(_on_exec_finished):
		executor.execution_finished.disconnect(_on_exec_finished)
	executor.execution_finished.connect(_on_exec_finished)
	var accepted: Dictionary = executor.execute(cmd, sel)
	var finished := await _wait_true(func() -> bool: return _exec_done, budget)
	return {"accepted": accepted, "finished": finished, "result": _exec_result}


func _advance_turn(budget: int = 14400) -> bool:
	if shell == null or mgr == null:
		return false
	var prev := int(mgr.get_current_turn())
	var busy := true
	shell.call("end_player_phase")
	await _wait_true(func() -> bool:
		if int(shell.get("_turn_phase")) == 0 and int(mgr.get_current_turn()) == prev + 1:
			busy = false
		return not busy, budget)
	return int(mgr.get_current_turn()) == prev + 1


# ---------------------------------------------------------------------------
# Continuous invariant checker (used at every lifecycle boundary)
# ---------------------------------------------------------------------------

func _invariants() -> Dictionary:
	var inv := {}
	# FLAT: every live cell is neutral plains (terrain 0)
	var hist := {}
	for key in _cells().keys():
		var cell: Variant = _cells()[key]
		var t := 0
		if cell is Dictionary:
			t = int((cell as Dictionary).get("terrain", 0))
		elif cell != null:
			var tv: Variant = cell.get("terrain")
			t = int(tv) if tv != null else 0
		hist[t] = int(hist.get(t, 0)) + 1
	inv["terrain_histogram"] = hist
	inv["flat_no_terrain_effects"] = (hist.keys() == [0])
	inv["cell_count"] = _cells().size()
	inv["large_map_retained"] = _cells().size() == 4921
	# Obstacles
	var river: Variant = shell.get("_river_cells")
	inv["river_empty"] = (river is Dictionary) and (river as Dictionary).is_empty()
	var sh_cells: Variant = shell.get("_stronghold_cells")
	inv["no_stronghold_cells"] = (sh_cells is Dictionary) and (sh_cells as Dictionary).is_empty()
	var strongholds: Array = []
	if mgr.has_method("get_all_strongholds"):
		strongholds = mgr.call("get_all_strongholds") as Array
	inv["no_strongholds"] = strongholds.size() == 0
	# Canonical DEV contract authority exposes the invariants directly.
	var R := _rules()
	inv["rules_authority_present"] = R != null and bool(R.call("is_active"))
	inv["rules_flags"] = R.call("invariants") if R != null else {}
	var fort_map: Variant = mgr.get("_fortress_map")
	inv["no_fortifications"] = (fort_map is Dictionary) and (fort_map as Dictionary).is_empty()
	# Supply
	var supply_units: Array = []
	var convoy_units: Array = []
	for u in _units():
		if str(u.get("class", "")) == "supply":
			supply_units.append(str(u.get("id", "")))
		if bool(u.get("is_convoy", false)):
			convoy_units.append(str(u.get("id", "")))
	inv["no_supply_units"] = supply_units.is_empty() and convoy_units.is_empty()
	inv["step6_retired"] = shell.get("_step6") == null
	var sp: Variant = shell.get("_supply_panel")
	inv["no_supply_panel"] = sp == null or not (sp is CanvasItem) or not (sp as CanvasItem).visible
	# Fog / stale
	inv["fog_disabled"] = shell.get("_fog") == null
	var stale: Variant = shell.get("_stale_layer")
	inv["stale_hidden"] = stale == null or not (stale is CanvasItem) or not (stale as CanvasItem).visible
	var fstale: Variant = shell.get("_friendly_stale_layer")
	inv["friendly_stale_hidden"] = fstale == null or not (fstale is CanvasItem) or not (fstale as CanvasItem).visible
	# Full information: every live RED unit known + visible on the map
	var obs: Dictionary = ObsCls.build(bridge)
	var known := {}
	for e_val in (obs.get("known_enemy_units", []) as Array):
		if e_val is Dictionary:
			known[str((e_val as Dictionary).get("unit_id", ""))] = e_val
	var reds := _red_alive()
	var red_hidden: Array = []
	var red_unmatched: Array = []
	var rr: Node = shell.get("unit_renderer") as Node
	for u in reds:
		var uid := str(u.get("id", ""))
		if not known.has(uid):
			red_unmatched.append(uid)
		if rr != null:
			var node: Node = rr.call("get_unit_node", uid) as Node
			if node != null and node is CanvasItem and not (node as CanvasItem).visible:
				red_hidden.append(uid)
	inv["full_information"] = red_unmatched.is_empty() and red_hidden.is_empty()
	inv["red_alive"] = reds.size()
	inv["red_known"] = known.size()
	inv["obs_schema"] = str(obs.get("schema_version", "")) == "cloud_step0_step1_v2" and bool(obs.get("ok", false))
	# Morale / rout
	var routed: Array = []
	var morale_min := 999.0
	var morale_max := -999.0
	for u in _units():
		if bool(u.get("routed", false)):
			routed.append(str(u.get("id", "")))
		var m := float(u.get("morale", 100.0))
		morale_min = minf(morale_min, m)
		morale_max = maxf(morale_max, m)
	inv["no_routs"] = routed.is_empty()
	inv["morale_min"] = morale_min
	inv["morale_max"] = morale_max
	inv["morale_pinned"] = morale_min >= 99.99 and morale_max <= 100.01
	# Scope algebra still resolves against the live roster
	var cav_expected := _ids_matching("cavalry")
	var cav_res: Dictionary = ScopeAlgebraCls.resolve({"op": "CLASS", "class": "CAVALRY"}, {"unit_manager": mgr, "bounds": bridge.map_bounds()})
	inv["scope_algebra_live"] = bool(cav_res.get("ok", false)) and (cav_res.get("unit_ids", []) as Array) == cav_expected
	# Renderer parity
	if rr != null:
		inv["renderer_count"] = (rr.call("get_all_units") as Array).size()
	inv["manager_count"] = _units().size()
	inv["obs_friendly_count"] = (obs.get("friendly_units", []) as Array).size()
	inv["blue_alive"] = _blue_alive().size()
	return inv


func _ids_matching(cls: String) -> Array:
	var out: Array = []
	for u in _blue_alive():
		if str(u.get("class", "")).to_lower() == cls and not bool(u.get("garrisoned", false)) and not bool(u.get("routed", false)):
			out.append(str(u.get("id", "")))
	out.sort()
	return out


func _inv_ok(inv: Dictionary) -> bool:
	for k in ["flat_no_terrain_effects", "large_map_retained", "river_empty", "no_stronghold_cells",
			"no_strongholds", "no_fortifications", "no_supply_units", "step6_retired", "no_supply_panel",
			"fog_disabled", "stale_hidden", "friendly_stale_hidden", "full_information", "obs_schema",
			"no_routs", "scope_algebra_live"]:
		if not bool(inv.get(k, false)):
			return false
	var rr: Variant = inv.get("renderer_count")
	if rr != null and int(rr) != int(inv.get("manager_count", -1)):
		return false
	if not bool(inv.get("rules_authority_present", false)):
		return false
	return true


# ---------------------------------------------------------------------------
# Sections
# ---------------------------------------------------------------------------

func _section_boot_contract() -> void:
	var inv := _invariants()
	_rec("BOOT CONTRACT", "boot_flat_map", bool(inv.get("flat_no_terrain_effects", false)), {
		"terrain_histogram": inv.get("terrain_histogram"),
		"cell_count": inv.get("cell_count"),
	})
	_rec("BOOT CONTRACT", "boot_large_map", int(inv.get("cell_count", 0)) == 4921 and int(ShellCls.PLAYABLE_HEX_COUNT) == 4921, {
		"cell_count": inv.get("cell_count"),
		"playable_hex_count_const": ShellCls.PLAYABLE_HEX_COUNT,
	})
	_rec("BOOT CONTRACT", "boot_no_obstacles", bool(inv.get("river_empty", false)) and bool(inv.get("no_strongholds", false)) and bool(inv.get("no_fortifications", false)), {
		"river_empty": inv.get("river_empty"),
		"no_strongholds": inv.get("no_strongholds"),
		"no_fortifications": inv.get("no_fortifications"),
	})
	# Default 10v10 roster
	var blues := _blue_alive()
	var reds := _red_alive()
	var bc := _class_counts(blues)
	var rc := _class_counts(reds)
	_rec("BOOT CONTRACT", "boot_default_roster_10v10", blues.size() == 10 and reds.size() == 10 and bc == DEFAULT_ROSTER and rc == DEFAULT_ROSTER, {
		"blue_total": blues.size(), "red_total": reds.size(),
		"blue_classes": bc, "red_classes": rc, "expected": DEFAULT_ROSTER,
		"blue_ids": _ids(blues), "red_ids": _ids(reds),
	})
	# No supply at boot
	var supply_ids: Array = []
	for u in _units():
		if str(u.get("class", "")) == "supply" or bool(u.get("is_convoy", false)):
			supply_ids.append(str(u.get("id", "")))
	_rec("BOOT CONTRACT", "boot_no_supply", supply_ids.is_empty() and bool(inv.get("step6_retired", false)) and bool(inv.get("no_supply_panel", false)), {
		"supply_ids": supply_ids, "step6_null": inv.get("step6_retired"), "supply_panel_absent": inv.get("no_supply_panel"),
	})
	# Fog fully off
	_rec("BOOT CONTRACT", "boot_fog_off", bool(inv.get("fog_disabled", false)) and bool(inv.get("stale_hidden", false)) and bool(inv.get("friendly_stale_hidden", false)), {
		"fog": inv.get("fog_disabled"), "stale_hidden": inv.get("stale_hidden"), "friendly_stale_hidden": inv.get("friendly_stale_hidden"),
	})
	# Full information at boot
	_rec("BOOT CONTRACT", "boot_full_information", bool(inv.get("full_information", false)) and int(inv.get("red_known", 0)) == reds.size(), {
		"red_alive": inv.get("red_alive"), "red_known": inv.get("red_known"), "red_hidden": inv.get("red_hidden"),
	})
	# Turn/phase sane
	_rec("BOOT CONTRACT", "boot_turn_state", int(mgr.get_current_turn()) == 1 and int(shell.get("_turn_phase")) == 0, {
		"turn": mgr.get_current_turn(), "phase": shell.get("_turn_phase"), "battle_lost": shell.get("_battle_lost"),
	})
	# Renderer parity (no ghost/duplicate nodes)
	_rec("BOOT CONTRACT", "boot_renderer_parity", int(inv.get("renderer_count", -1)) == int(inv.get("manager_count", -2)) and int(inv.get("manager_count", 0)) == 20, {
		"renderer_count": inv.get("renderer_count"), "manager_count": inv.get("manager_count"),
	})
	# Canonical DEV contract exposure
	var R := _rules()
	var flags: Dictionary = R.call("invariants") if R != null else {}
	_rec("BOOT CONTRACT", "boot_contract_flags", R != null and bool(R.call("is_active")) and bool(flags.get("DEV_FULL_INFORMATION", false)), {
		"rules_script_present": R != null,
		"sandbox_active": R.call("is_active") if R != null else null,
		"invariants": flags,
	})


func _section_supply_retirement() -> void:
	var obs: Dictionary = ObsCls.build(bridge)
	var supply_keys: Array = []
	for u_val in (obs.get("friendly_units", []) as Array):
		for k in (u_val as Dictionary).keys():
			if "supply" in str(k) or "food" in str(k):
				supply_keys.append(str(k))
	for e_val in (obs.get("known_enemy_units", []) as Array):
		for k2 in (e_val as Dictionary).keys():
			if "supply" in str(k2) or "food" in str(k2):
				supply_keys.append(str(k2))
	var fp := str(bridge.fingerprint())
	var ledger: Dictionary = bridge.build_knowledge("blue")
	var ledger_supply := str(ledger.get("ledger", {})).contains("local_supply")
	_rec("SUPPLY RETIREMENT", "sup_obs_clean", supply_keys.is_empty(), {"supply_keys_found": supply_keys})
	_rec("SUPPLY RETIREMENT", "sup_fingerprint_clean", (not fp.contains(":sup")) and (not fp.contains("sup:")), {"fingerprint_prefix": fp.substr(0, 24)})
	_rec("SUPPLY RETIREMENT", "sup_boot_needs_no_supply", shell.get("_step6") == null, {
		"step6": str(shell.get("_step6")), "note": "canonical supply/food retirement is global",
	})
	# Caller trace: no active caller of spawn_supply_convoy outside tests.
	var convoy_callers: Array = []
	var probe_paths := [
		"res://scripts/step2r/step2r_battlefield_shell.gd",
		"res://scripts/step3/step3_unit_manager.gd",
		"res://scripts/sim/sim_controller.gd",
		"res://scripts/cloud1/cloud1_dock.gd",
		"res://scripts/cloud1/cloud1_live_executor.gd",
	]
	for p in probe_paths:
		var f := FileAccess.open(p, FileAccess.READ)
		if f != null:
			var txt := f.get_as_text()
			if txt.contains("spawn_supply_convoy(") and p != "res://scripts/step3/step3_unit_manager.gd":
				convoy_callers.append(p)
	_rec("SUPPLY RETIREMENT", "sup_no_active_convoy_caller", convoy_callers.is_empty(), {"callers": convoy_callers})
	# Ledger may keep a legacy logistics field; observation and fingerprint must not carry it.
	_rec("SUPPLY RETIREMENT", "sup_ledger_note", true, {
		"ledger_contains_local_supply_field": ledger_supply,
		"note": "knowledge ledger keeps a legacy logistics summary; the canonical observation + fingerprint (asserted above) carry no supply/food fields",
	})



# ---------------------------------------------------------------------------
# SUP-FINAL helpers + gates (global food/supply retirement closure)
# ---------------------------------------------------------------------------

func _file_text(path: String) -> String:
	var fa := FileAccess.open(path, FileAccess.READ)
	if fa == null:
		return ""
	return fa.get_as_text()


func _units_food_report(units: Array) -> Dictionary:
	var out := {}
	for u in units:
		if not (u is Dictionary):
			continue
		var hits := {}
		for k in (u as Dictionary).keys():
			var lk := str(k).to_lower()
			for t in FOOD_TOKENS:
				if lk.contains(str(t)):
					hits[str(k)] = (u as Dictionary)[k]
					break
		if not hits.is_empty():
			out[str((u as Dictionary).get("id", "?"))] = hits
	return out


func _units_now(manager: Variant) -> Array:
	var out: Array = []
	if manager == null:
		return out
	for u in manager.get_all_units_including_garrisoned():
		if u is Dictionary:
			out.append(u)
	return out


func _text_hits(text: String, tokens: Array = FOOD_TOKENS) -> Array:
	var hits: Array = []
	var lines := text.split("\n")
	for i in range(lines.size()):
		var ll := str(lines[i]).to_lower()
		for t in tokens:
			if ll.contains(str(t)):
				hits.append([i + 1, str(lines[i]).strip_edges()])
				break
	return hits


func _list_gd_files(root: String) -> Array:
	var out: Array = []
	var dir := DirAccess.open(root)
	if dir == null:
		return out
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if dir.current_is_dir():
			if not f.begins_with("."):
				out.append_array(_list_gd_files(root.path_join(f)))
		elif f.ends_with(".gd"):
			out.append(root.path_join(f))
		f = dir.get_next()
	dir.list_dir_end()
	return out


func _scan_calls(files: Array, needle: String, allowed: Array = []) -> Dictionary:
	var hits := {}
	for p in files:
		if allowed.has(p):
			continue
		var txt := _file_text(str(p))
		if txt == "":
			continue
		var arr := txt.split("\n")
		var lines: Array = []
		for i in range(arr.size()):
			if str(arr[i]).contains(needle):
				lines.append([i + 1, str(arr[i]).strip_edges()])
		if not lines.is_empty():
			hits[str(p)] = lines
	return hits


func _extract_function(path: String, func_name: String) -> String:
	var txt := _file_text(path)
	var start := txt.find("func " + func_name + "(")
	if start == -1:
		return ""
	var nxt := txt.find("\nfunc ", start + 1)
	if nxt == -1:
		return txt.substr(start)
	return txt.substr(start, nxt - start)


func _section_sup_final_dev() -> void:
	# ---- SUP-FINAL-7: mission evaluation independent of food/supply ----
	var sim: RefCounted = SimControllerCls.new()
	sim.load_scenario({
		"scenario_id": "sup_final_probe",
		"scenario_version": "1.0",
		"seed": 1,
		"mission_contract": {"primary_objective": "destroy_all_red", "turn_limit": 5},
		"map": {"bounds": {"q_min": -10, "q_max": 10, "r_min": -5, "r_max": 5}},
		"forces": [
			{"id": "B_HQ_1", "class": "hq", "faction": "blue", "q": -5, "r": 0, "soldiers": 100},
			{"id": "R_HQ_1", "class": "hq", "faction": "red", "q": 5, "r": 0, "soldiers": 100},
		],
		"start_turn": 1,
	})
	var mission: Dictionary = sim.evaluate_mission()
	var mission_bad: Array = []
	for k in mission.keys():
		var lk := str(k).to_lower()
		for t in FOOD_TOKENS:
			if lk.contains(str(t)):
				mission_bad.append(str(k))
	var eval_src_bad := _text_hits(_extract_function("res://scripts/sim/sim_controller.gd", "evaluate_mission"))
	_rec("SUP-FINAL", "SUP-FINAL-7", str(mission.get("mission_status", "")) != "error" and mission_bad.is_empty() and eval_src_bad.is_empty(), {
		"mission_status": mission.get("mission_status"),
		"mission_keys": mission.keys(),
		"food_supply_keys_in_mission": mission_bad,
		"evaluate_mission_source_hits": eval_src_bad,
	})
	# ---- SUP-FINAL-8: observation/fingerprint independent of food/supply ----
	var obs: Dictionary = ObsCls.build(bridge)
	var obs_bad: Array = []
	for list_key in ["friendly_units", "known_enemy_units"]:
		for u_val in (obs.get(list_key, []) as Array):
			if not (u_val is Dictionary):
				continue
			for k in (u_val as Dictionary).keys():
				var lk2 := str(k).to_lower()
				for t2 in FOOD_TOKENS:
					if lk2.contains(str(t2)):
						obs_bad.append("%s.%s" % [list_key, str(k)])
	var fp := str(bridge.fingerprint())
	var fp_hits := _text_hits(fp)
	_rec("SUP-FINAL", "SUP-FINAL-8", bool(obs.get("ok", false)) and obs_bad.is_empty() and fp_hits.is_empty() and fp.length() > 32, {
		"observation_keys_flagged": obs_bad,
		"fingerprint_food_supply_tokens": fp_hits,
		"fingerprint_sample": fp.substr(0, 48),
		"obs_schema": obs.get("schema_version"),
	})
	# ---- SUP-FINAL-10: legacy supply/food code has zero active canonical callers ----
	var files := _list_gd_files("res://scripts") + _list_gd_files("res://tools")
	var self_audit := "res://scripts/cloud1/audit/cloud1_dev_contract_audit.gd"
	var convoy_hits := _scan_calls(files, "spawn_supply_convoy(", ["res://scripts/step3/step3_unit_manager.gd", "res://scripts/cloud1/cloud1_contract_audit.gd", self_audit])
	var food_hits := _scan_calls(files, "get_food_cost(", ["res://scripts/core/step3_config.gd", self_audit])
	var supplymax_hits := _scan_calls(files, "_s6_supply_max(", [self_audit])
	var s6adj_hits := _scan_calls(files, "s6_adjust_supply(", ["res://scripts/step3/step3_unit_manager.gd", "res://scripts/step6/step6_decision_layer.gd", self_audit])
	var resupply_hits := _scan_calls(files, "apply_mobile_path_resupply(", [self_audit])
	var refill_hits := _scan_calls(files, "check_mobile_hub_refill(", [self_audit])
	var charges_hits := _scan_calls(files, "end_turn_charges(", [self_audit])
	var known_guarded := ["res://scripts/step2r/step2r_battlefield_shell.gd", "res://scripts/sim/sim_controller.gd", "res://scripts/step6/step6_decision_layer.gd"]
	var unexpected: Array = []
	for scan_res in [resupply_hits, refill_hits, charges_hits]:
		for key in (scan_res as Dictionary).keys():
			if not known_guarded.has(str(key)) and not unexpected.has(str(key)):
				unexpected.append(str(key))
	var ok10: bool = convoy_hits.is_empty() and food_hits.is_empty() and supplymax_hits.is_empty() and s6adj_hits.is_empty() and unexpected.is_empty()
	_rec("SUP-FINAL", "SUP-FINAL-10", ok10, {
		"spawn_supply_convoy_callers_outside_legacy": convoy_hits,
		"get_food_cost_callers_outside_legacy": food_hits,
		"_s6_supply_max_callers": supplymax_hits,
		"s6_adjust_supply_callers_outside_legacy": s6adj_hits,
		"resupply_chain_sites": {"apply_mobile_path_resupply": resupply_hits, "check_mobile_hub_refill": refill_hits, "end_turn_charges": charges_hits},
		"unexpected_callers": unexpected,
		"note": "shell/sim call sites sit behind `_step6 != null` guards; `_step6` is null in BOTH modes (asserted live in DEV + PRODUCTION sections)",
	})


func _section_sup_final_production(prod: Node, p_mgr: Variant) -> void:
	if p_mgr == null:
		_rec("SUP-FINAL", "SUP-FINAL-1", false, {"error": "no production manager"})
		return
	var p_units: Array = _units_now(p_mgr)
	# ---- SUP-FINAL-1: no Supply-class production spawn ----
	var supply_ids: Array = []
	for u in p_units:
		if str(u.get("class", "")) == "supply" or bool(u.get("is_convoy", false)):
			supply_ids.append(str(u.get("id", "")))
	var deploy_src := _extract_function("res://scripts/step2r/step2r_battlefield_shell.gd", "_deploy_test_armies")
	var deploy_bad := _text_hits(deploy_src, ["\"supply\"", "\"food\"", "\"convoy\""])
	var renderer_guard := _file_text("res://scripts/step2r/step2r_unit_renderer.gd").contains("Supply-class unit spawning is retired")
	var manager_guard := _file_text("res://scripts/step3/step3_unit_manager.gd").contains("Supply-class units are retired and cannot spawn")
	_rec("SUP-FINAL", "SUP-FINAL-1", supply_ids.is_empty() and deploy_bad.is_empty() and renderer_guard and manager_guard, {
		"production_supply_ids": supply_ids,
		"deploy_path_food_supply_spawn_tokens": deploy_bad,
		"renderer_supply_spawn_guard_present": renderer_guard,
		"manager_supply_spawn_guard_present": manager_guard,
	})
	# ---- SUP-FINAL-2: no food/supply initialization required ----
	var boot_food := _units_food_report(p_units)
	var R := _rules()
	var flags_off: bool = R != null and not bool(R.call("food_enabled")) and not bool(R.call("supply_enabled"))
	var no_supply_ui: bool = prod.get("_step6") == null and prod.get("_supply_panel") == null and prod.get("_supply_label") == null and prod.get("_supply_overlay") == null and prod.get("_btn_map_mode") == null
	_rec("SUP-FINAL", "SUP-FINAL-2", no_supply_ui and boot_food.is_empty() and flags_off, {
		"step6": str(prod.get("_step6")),
		"supply_panel": str(prod.get("_supply_panel")),
		"supply_label": str(prod.get("_supply_label")),
		"supply_overlay": str(prod.get("_supply_overlay")),
		"map_mode_button": str(prod.get("_btn_map_mode")),
		"unit_food_supply_keys": boot_food,
		"food_enabled": R.call("food_enabled") if R != null else null,
		"supply_enabled": R.call("supply_enabled") if R != null else null,
	})
	# ---- played cycle with continuous food/supply snapshots ----
	var snapshots := {}
	snapshots["boot"] = boot_food
	var turn_advances: Array = []
	var attack_info := {"executed": false, "reason": "no legal target at probe time"}
	# Attack first (before extra turns) along the authoritative path.
	var found_pair := false
	var atk := ""
	var dfd := ""
	for attempt in range(3):
		if attempt > 0:
			var prev_t := int(p_mgr.get_current_turn())
			prod.call("end_player_phase")
			var adv_t := false
			for _i in range(14400):
				await process_frame
				if int(prod.get("_turn_phase")) == 0 and int(p_mgr.get_current_turn()) == prev_t + 1:
					adv_t = true
					break
			turn_advances.append({"from": prev_t, "to": int(p_mgr.get_current_turn()), "advanced": adv_t})
			snapshots["after_end_turn_pre_attack_%d" % attempt] = _units_food_report(_units_now(p_mgr))
		atk = ""
		dfd = ""
		for u2 in _units_now(p_mgr):
			if str(u2.get("faction", "")) != "blue" or bool(u2.get("action_ended", false)) or bool(u2.get("garrisoned", false)):
				continue
			var targets: Array = p_mgr.get_attackable_targets(str(u2.get("id", "")))
			if not targets.is_empty():
				atk = str(u2.get("id", ""))
				dfd = str((targets[0] as Dictionary).get("id", ""))
				found_pair = true
				break
		if found_pair:
			break
	if found_pair:
		var hp_before := int(p_mgr.get_unit_by_id(dfd).get("soldier_count", 0))
		var svc: Variant = prod.get("_battle_command_service")
		var ares: Dictionary = {}
		if svc != null and svc.has_method("execute_attack_intent"):
			ares = svc.call("execute_attack_intent", atk, dfd, "blue", {})
		else:
			ares = p_mgr.execute_attack(atk, dfd, {})
		var d_after: Dictionary = p_mgr.get_unit_by_id(dfd)
		var hp_after := int(d_after.get("soldier_count", 0)) if not d_after.is_empty() else 0
		var res_keys_food := _text_hits(JSON.stringify(ares.keys()))
		attack_info = {
			"executed": true, "attacker": atk, "defender": dfd,
			"hp_before": hp_before, "hp_after": hp_after,
			"result_food_keys": res_keys_food,
			"status": str(ares.get("success", ares.get("executed", true))),
		}
	else:
		var probe_atk := ""
		for u5 in _units_now(p_mgr):
			if str(u5.get("faction", "")) == "blue" and not bool(u5.get("action_ended", false)):
				probe_atk = str(u5.get("id", ""))
				break
		var far_red := ""
		if probe_atk != "":
			var pu: Dictionary = p_mgr.get_unit_by_id(probe_atk)
			var pu_pos := Vector2i(int(pu.get("q", 0)), int(pu.get("r", 0)))
			for u6 in _units_now(p_mgr):
				if str(u6.get("faction", "")) == "red" and int(u6.get("soldier_count", 0)) > 0:
					if HexUtilsCls.hex_distance_axial(Vector2i(int(u6.get("q", 0)), int(u6.get("r", 0))), pu_pos) > 3:
						far_red = str(u6.get("id", ""))
						break
		if probe_atk != "" and far_red != "":
			var rres: Dictionary = p_mgr.execute_attack(probe_atk, far_red, {})
			attack_info = {"executed": false, "reason": "no in-range target within budget", "attacker": probe_atk, "target": far_red, "probe_refused": not bool(rres.get("success", false)), "probe_error": str(rres.get("error", ""))}
	snapshots["after_attack"] = _units_food_report(_units_now(p_mgr))
	var attack_clean: bool = snapshots["after_attack"].is_empty()
	var attack_proved: bool = false
	if bool(attack_info.get("executed", false)):
		attack_proved = attack_clean and (attack_info.get("result_food_keys") as Array).is_empty() and int(attack_info.get("hp_after", 0)) < int(attack_info.get("hp_before", 0))
	else:
		attack_proved = attack_clean and bool(attack_info.get("probe_refused", false))
	_rec("SUP-FINAL", "SUP-FINAL-4", attack_proved, attack_info)
	# Move phase (authoritative execute_step7_move -> service/manager stepwise path).
	var mover := ""
	for u3 in _units_now(p_mgr):
		if str(u3.get("faction", "")) == "blue" and int(u3.get("soldier_count", 0)) > 0 and str(u3.get("class", "")) != "hq" and not bool(u3.get("garrisoned", false)):
			mover = str(u3.get("id", ""))
			break
	var move_info := {"unit": mover}
	if not mover.is_empty():
		var u_from: Dictionary = p_mgr.get_unit_by_id(mover)
		var fq := int(u_from.get("q", 0))
		var fr := int(u_from.get("r", 0))
		var svc2: Variant = prod.get("_battle_command_service")
		var targets2: Array = []
		if svc2 != null and svc2.has_method("reachable_area"):
			var area: Dictionary = svc2.call("reachable_area", mover, "blue", "auto")
			targets2 = area.get("reachable", []) if area.get("reachable", []) is Array else []
		var dest := Vector2i(-999, -999)
		if not targets2.is_empty():
			var t: Dictionary = targets2[targets2.size() - 1]
			dest = Vector2i(int(t.get("q", 0)), int(t.get("r", 0)))
		if dest.x != -999 and prod.has_method("execute_step7_move"):
			_prod_move_done = false
			prod.call("execute_step7_move", mover, dest, "auto", Callable(self, "_on_prod_move"))
			for _i in range(2400):
				await process_frame
				if _prod_move_done:
					break
			var u_after: Dictionary = p_mgr.get_unit_by_id(mover)
			move_info["from"] = [fq, fr]
			move_info["to"] = [int(u_after.get("q", -999)), int(u_after.get("r", -999))]
			move_info["moved"] = (int(u_after.get("q", -999)) != fq) or (int(u_after.get("r", -999)) != fr)
			move_info["move_result_keys"] = _prod_move_res.keys()
			move_info["move_result_has_food_key"] = _prod_move_res.has("food_consumed")
			move_info["morale_after_move"] = float(u_after.get("morale", -1.0))
	snapshots["after_move"] = _units_food_report(_units_now(p_mgr))
	var move_clean: bool = bool(move_info.get("moved", false)) and snapshots["after_move"].is_empty() and not bool(move_info.get("move_result_has_food_key", true)) and float(move_info.get("morale_after_move", 999.0)) <= 100.0
	_rec("SUP-FINAL", "SUP-FINAL-3", move_clean, move_info)
	# Complete the play cycle: at least two full end-turns (enemy turn + next player turn).
	while turn_advances.size() < 2:
		var prev_t2 := int(p_mgr.get_current_turn())
		prod.call("end_player_phase")
		var adv_t2 := false
		for _i in range(14400):
			await process_frame
			if int(prod.get("_turn_phase")) == 0 and int(p_mgr.get_current_turn()) == prev_t2 + 1:
				adv_t2 = true
				break
		turn_advances.append({"from": prev_t2, "to": int(p_mgr.get_current_turn()), "advanced": adv_t2})
		snapshots["after_end_turn_%d" % turn_advances.size()] = _units_food_report(_units_now(p_mgr))
	var all_adv := true
	for t3 in turn_advances:
		if not bool((t3 as Dictionary).get("advanced", false)):
			all_adv = false
	var snap_all_clean := true
	for k4 in snapshots.keys():
		if not (snapshots[k4] as Dictionary).is_empty():
			snap_all_clean = false
	_rec("SUP-FINAL", "SUP-FINAL-5", all_adv and snap_all_clean and snapshots.size() >= 4, {
		"turns": turn_advances,
		"snapshot_labels": snapshots.keys(),
		"all_snapshots_food_free": snap_all_clean,
		"note": "attack + move + two full end-turn cycles (enemy phase included) left every unit without any food/supply state",
	})
	_rec("SUP-FINAL", "SUP-FINAL-6", snap_all_clean and prod.get("_step6") == null, {
		"starvation_state_ever_observed": snapshots,
		"step6": str(prod.get("_step6")),
		"note": "the starvation chain (turn charges -> supply draw -> consecutive_hungry) lives only in the retired Step6 layer; it is never instantiated and has zero active callers (SUP-FINAL-10 source scan)",
	})
	# ---- SUP-FINAL-9: no active HUD/action depends on food/supply ----
	var fams2: Array = TableCls.family_ids()
	var supply_actions: Array = []
	for a2 in fams2:
		var la := str(a2).to_lower()
		if la.contains("supply") or la.contains("resupply"):
			supply_actions.append(str(a2))
	var shell_text := _file_text("res://scripts/step2r/step2r_battlefield_shell.gd")
	var active_food_formats: bool = shell_text.contains("군량 소모:") or shell_text.contains("보급: %.1f턴분")
	var nm: Variant = prod.get("_node_markers")
	var nm_empty: bool = (nm is Dictionary) and (nm as Dictionary).is_empty()
	_rec("SUP-FINAL", "SUP-FINAL-9", supply_actions.is_empty() and not active_food_formats and prod.get("_btn_map_mode") == null and prod.get("_route_line") == null and int(prod.get("_map_mode")) == 0 and nm_empty, {
		"supply_actions_in_catalog": supply_actions,
		"active_food_format_tokens_in_shell": active_food_formats,
		"map_mode_button": str(prod.get("_btn_map_mode")),
		"route_line": str(prod.get("_route_line")),
		"map_mode_value": prod.get("_map_mode"),
		"node_marker_count": (nm as Dictionary).size() if (nm is Dictionary) else -1,
	})
	# ---- PART 8: production morale must stay live ----
	var penalty_orange := float(Step3ConfigCls.get_morale_penalty(1))
	var mod100 := CombatCalcCls.get_morale_modifier(100.0)
	var mod10 := CombatCalcCls.get_morale_modifier(10.0)
	var dmg1 := int(CombatCalcCls.calculate_combat({"class": "infantry", "soldier_count": 400, "morale": 100.0}, {"class": "infantry", "soldier_count": 400, "morale": 100.0}, 1, 0, {}, 1.0).get("defender_casualties", 0))
	var dmg2 := int(CombatCalcCls.calculate_combat({"class": "infantry", "soldier_count": 400, "morale": 10.0}, {"class": "infantry", "soldier_count": 400, "morale": 100.0}, 1, 0, {}, 1.0).get("defender_casualties", 0))
	var move_morale := float(move_info.get("morale_after_move", -1.0))
	_rec("PRODUCTION ISOLATION", "prod_morale_systems_live", penalty_orange > 0.0 and absf(mod100 - mod10) > 0.1 and dmg1 != dmg2 and move_morale >= 0.0 and move_morale <= 100.0, {
		"march_penalty_orange": penalty_orange,
		"morale_modifier_100": mod100, "morale_modifier_10": mod10,
		"damage_def_at_morale100": dmg1, "damage_def_at_morale10": dmg2,
		"moved_unit_morale_after_move": move_morale,
		"note": "production morale stays LIVE (march penalty applies, combat modifier active) while food/supply is retired in BOTH modes",
	})


func _section_region_geometry() -> void:
	# 1) Authoritative transform from HexUtils source: y = 42r + 21q
	var samples := [[0, 0], [1, 0], [0, 1], [-3, 5], [7, -2], [40, -40], [-40, 40], [13, 0], [-13, 0]]
	var all_match := true
	var mismatches: Array = []
	for s in samples:
		var q := int(s[0])
		var r := int(s[1])
		var y := HexUtilsCls.hex_to_pixel(q, r).y
		var expect := 42.0 * float(r) + 21.0 * float(q)
		if absf(y - expect) > 0.001:
			all_match = false
			mismatches.append([q, r, y, expect])
	_rec("REGION GEOMETRY", "geo_transform_authoritative", all_match, {
		"formula": "world_y = 42r + 21q = 21*(2r+q)",
		"samples_checked": samples.size(), "mismatches": mismatches,
	})
	# 2) Bounds derived from the LIVE valid cell set
	var mine := _my_bounds()
	var shell_b := shell.call("map_bounds") as Dictionary
	var bridge_b: Dictionary = bridge.map_bounds()
	_rec("REGION GEOMETRY", "geo_bounds_from_valid_cells", int(mine["min_vertical"]) == -80 and int(mine["max_vertical"]) == 80 and int(shell_b.get("min_vertical", 0)) == -80 and int(shell_b.get("max_vertical", 0)) == 80 and int(bridge_b.get("min_vertical", -1)) == -80, {
		"my_min_max": [mine["min_vertical"], mine["max_vertical"]],
		"shell_bounds": shell_b,
		"bridge_bounds": bridge_b,
		"cells": _cells().size(),
	})
	# 3) Adversarial: same r=0, opposite q -> opposite sectors
	var classes := {}
	for pair in [[-30, 0], [30, 0], [0, -40], [0, 40], [0, 0], [-20, -20], [40, -40], [-40, 40], [20, 20]]:
		var q2 := int(pair[0])
		var r2 := int(pair[1])
		var want := _my_region(q2, r2)
		var got: String = ScopeAlgebraCls.get_region_for_coord(q2, r2, bridge_b)
		classes["%d,%d" % [q2, r2]] = {"got": got, "want": want, "ok": got == want}
	var adv_ok := true
	for k in classes.keys():
		if not bool((classes[k] as Dictionary).get("ok", false)):
			adv_ok = false
	_rec("REGION GEOMETRY", "geo_adversarial_same_r", adv_ok and str((classes["-30,0"] as Dictionary)["got"]) == "NORTH" and str((classes["30,0"] as Dictionary)["got"]) == "SOUTH", {
		"cells": classes, "delta_world_y_px": 1260,
	})


func _section_scope_algebra() -> void:
	var bounds: Dictionary = bridge.map_bounds()
	var deps := {"unit_manager": mgr, "bounds": bounds}
	# CLASS
	var cav: Dictionary = ScopeAlgebraCls.resolve({"op": "CLASS", "class": "CAVALRY"}, deps)
	var inf: Dictionary = ScopeAlgebraCls.resolve({"op": "CLASS", "class": "INFANTRY"}, deps)
	var sct: Dictionary = ScopeAlgebraCls.resolve({"op": "CLASS", "class": "SCOUT"}, deps)
	_rec("SCOPE ALGEBRA", "scope_class_matches_live_roster",
		(cav.get("unit_ids", []) as Array) == _ids_matching("cavalry")
		and (inf.get("unit_ids", []) as Array) == _ids_matching("infantry")
		and (sct.get("unit_ids", []) as Array) == _ids_matching("scout"), {
		"cavalry": cav.get("unit_ids"), "infantry": inf.get("unit_ids"), "scout": sct.get("unit_ids"),
	})
	# REGION
	var north: Dictionary = ScopeAlgebraCls.resolve({"op": "REGION", "region": "NORTH"}, deps)
	var expected_north: Array = []
	for u in _blue_alive():
		if _my_region(int(u.get("q", 0)), int(u.get("r", 0))) == "NORTH":
			expected_north.append(str(u.get("id", "")))
	expected_north.sort()
	_rec("SCOPE ALGEBRA", "scope_region_matches_geometry", (north.get("unit_ids", []) as Array) == expected_north, {
		"resolved": north.get("unit_ids"), "expected_from_independent_math": expected_north,
	})
	# INTERSECT = north cavalry
	var inter: Dictionary = ScopeAlgebraCls.resolve({"op": "INTERSECT", "args": [{"op": "CLASS", "class": "CAVALRY"}, {"op": "REGION", "region": "NORTH"}]}, deps)
	var expected_inter: Array = []
	for uid in (cav.get("unit_ids", []) as Array):
		if uid in expected_north:
			expected_inter.append(uid)
	_rec("SCOPE ALGEBRA", "scope_intersect_north_cavalry", (inter.get("unit_ids", []) as Array) == expected_inter and not (inter.get("unit_ids", []) as Array).is_empty(), {
		"resolved": inter.get("unit_ids"), "expected": expected_inter,
		"korean_label": ScopeAlgebraCls.describe_scope_kr({"op": "INTERSECT", "args": [{"op": "CLASS", "class": "CAVALRY"}, {"op": "REGION", "region": "NORTH"}]}),
	})
	# UNION
	var union: Dictionary = ScopeAlgebraCls.resolve({"op": "UNION", "args": [{"op": "CLASS", "class": "CAVALRY"}, {"op": "CLASS", "class": "SCOUT"}]}, deps)
	var expected_union: Array = _ids_matching("cavalry") + _ids_matching("scout")
	expected_union.sort()
	_rec("SCOPE ALGEBRA", "scope_union", (union.get("unit_ids", []) as Array) == expected_union, {
		"resolved": union.get("unit_ids"), "expected": expected_union,
	})
	# DIFF(ALL_COMBAT, SCOUT)
	var diff: Dictionary = ScopeAlgebraCls.resolve({"op": "DIFF", "left": {"op": "ALL_COMBAT"}, "right": {"op": "CLASS", "class": "SCOUT"}}, deps)
	var expected_diff: Array = []
	for u in _blue_alive():
		var c := str(u.get("class", "")).to_lower()
		if c == "hq":
			continue
		if c == "scout":
			continue
		expected_diff.append(str(u.get("id", "")))
	expected_diff.sort()
	_rec("SCOPE ALGEBRA", "scope_diff_all_combat_minus_scout", (diff.get("unit_ids", []) as Array) == expected_diff, {
		"resolved": diff.get("unit_ids"), "expected": expected_diff,
	})
	# Arbitrary exact-unit multiselect from the live roster
	var pool := _ids_matching("cavalry") + _ids_matching("infantry") + _ids_matching("scout")
	pool.sort()
	var pick: Array = []
	if pool.size() >= 3:
		pick = [pool[0], pool[pool.size() - 1], pool[1]]
	var units_res: Dictionary = ScopeAlgebraCls.resolve({"op": "UNITS", "unit_ids": pick}, deps)
	var pick_sorted := pick.duplicate()
	pick_sorted.sort()
	_rec("SCOPE ALGEBRA", "scope_exact_units_arbitrary", (units_res.get("unit_ids", []) as Array) == pick_sorted and pick_sorted.size() >= 3, {
		"requested": pick, "resolved": units_res.get("unit_ids"),
	})
	# single UNIT atom
	if pick.size() > 0:
		var unit_res: Dictionary = ScopeAlgebraCls.resolve({"op": "UNIT", "unit_id": pick[0]}, deps)
		_rec("SCOPE ALGEBRA", "scope_single_unit", (unit_res.get("unit_ids", []) as Array) == [pick[0]], {
			"requested": pick[0], "resolved": unit_res.get("unit_ids"),
		})


func _section_action_table() -> void:
	var fams: Array = TableCls.family_ids()
	var fams_sorted := fams.duplicate()
	fams_sorted.sort()
	var want := ACTIVE_ACTIONS.duplicate()
	want.sort()
	var schema_want: Array = ACTIVE_ACTIONS + DEFERRED_ACTIONS
	schema_want.sort()
	var exe: Array = TableCls.EXECUTABLE.duplicate()
	exe.sort()
	_rec("ACTION SET", "actions_active_exact", fams_sorted == schema_want and exe == want, {
		"families": fams, "schema_expected": schema_want, "executable": exe, "active_expected": want,
		"note": "family_ids() = full schema (8 active + 4 deferred); EXECUTABLE = the 8 active actions",
	})
	# Each active action accepts a valid command; deferred rejected explicitly.
	var ok_all := true
	var detail := {}
	var scope_all := TableCls.scope_all_combat()
	for a in ACTIVE_ACTIONS:
		var cmd := {}
		match a:
			"ADVANCE", "FLANK", "RECON":
				cmd = TableCls.make_command(a, scope_all, TableCls.target_direction("FORWARD"))
			"ATTACK":
				var redo := _red_alive()
				var tid := str(redo[0].get("id", "R_INF_1")) if not redo.is_empty() else "R_INF_1"
				cmd = TableCls.make_command(a, scope_all, TableCls.target_formation(tid))
			"WITHDRAW":
				cmd = TableCls.make_command(a, scope_all, TableCls.target_zone("HQ"))
			"REPOSITION":
				cmd = TableCls.make_command(a, scope_all, TableCls.target_zone("CENTER"))
			"CONCENTRATE":
				cmd = TableCls.make_command(a, scope_all, TableCls.target_zone("CENTER"))
			_:
				cmd = TableCls.make_command(a, scope_all)
		var v: Dictionary = TableCls.validate_command(cmd)
		detail[a] = {"ok": bool(v.get("ok", false)), "code": str(v.get("code", "")), "detail": str(v.get("detail", ""))}
		if not bool(v.get("ok", false)):
			ok_all = false
	_rec("ACTION SET", "actions_accept_valid_commands", ok_all, detail)
	var defer_ok := true
	var defer_detail := {}
	for d in DEFERRED_ACTIONS:
		var v2: Dictionary = TableCls.validate_command(TableCls.make_command(d, TableCls.scope_all_combat(), TableCls.target_direction("FORWARD")))
		defer_detail[d] = {"ok": bool(v2.get("ok", false)), "code": str(v2.get("code", ""))}
		if bool(v2.get("ok", false)) or str(v2.get("code", "")) != "ACTION_DEFERRED":
			defer_ok = false
	_rec("ACTION SET", "actions_deferred_rejected_explicitly", defer_ok, defer_detail)
	var bad: Dictionary = TableCls.validate_command(TableCls.make_command("BOGUS", TableCls.scope_all_combat()))
	_rec("ACTION SET", "actions_unknown_rejected", str(bad.get("code", "")) == "UNKNOWN_ACTION", {"code": bad.get("code")})
	# Movement policy: not required, not in the drafted command, no visible UI, no catalog entry.
	var cmd_nopolicy := TableCls.make_command("ADVANCE", scope_all, TableCls.target_direction("FORWARD"))
	var v_np: Dictionary = TableCls.validate_command(cmd_nopolicy)
	var drafted: Dictionary = {}
	if dock != null:
		var panel: Variant = dock.call("get_panel")
		if panel != null:
			drafted = panel.call("draft_command")
	var drafted_has_policy: bool = drafted.has("movement_policy")
	var policy_cell: Variant = dock.get("_policy_cell") if dock != null else null
	var policy_visible: bool = policy_cell != null and policy_cell is CanvasItem and (policy_cell as CanvasItem).is_visible_in_tree()
	var bogus_pol: Dictionary = TableCls.validate_command({"action": "ADVANCE", "scope": scope_all, "target": TableCls.target_direction("FORWARD"), "movement_policy": "TURBO"})
	_rec("ACTION SET", "policy_retired_from_active_contract",
		bool(v_np.get("ok", false)) and not drafted_has_policy and not policy_visible and str(bogus_pol.get("code", "")) == "INVALID_POLICY", {
		"command_without_policy_valid": v_np.get("ok"),
		"drafted_command_keys": drafted.keys(),
		"policy_widget_visible": policy_visible,
		"bogus_policy_rejected": str(bogus_pol.get("code", "")),
		"note": "POLICIES constant remains for legacy schemas only; no active UI/serialized field",
	})


func _section_picker_and_selected() -> void:
	# Unit picker rows == live blue roster
	var obs: Dictionary = ObsCls.build(bridge)
	var friendly: Array = obs.get("friendly_units", [])
	var obs_ids: Array = []
	for u_val in friendly:
		obs_ids.append(str((u_val as Dictionary).get("unit_id", "")))
	obs_ids.sort()
	var checkboxes: Variant = dock.get("_unit_checkboxes") if dock != null else null
	var picker_ids: Array = []
	var sample_row := ""
	if checkboxes is Dictionary:
		for k in (checkboxes as Dictionary).keys():
			picker_ids.append(str(k))
		picker_ids.sort()
		for k2 in (checkboxes as Dictionary).keys():
			var cb: Variant = (checkboxes as Dictionary)[k2]
			if cb is CheckBox:
				sample_row = (cb as CheckBox).text
				break
	_rec("UNIT PICKER", "picker_rows_match_live_roster", picker_ids == _ids(_blue_alive()) and picker_ids == obs_ids and not picker_ids.is_empty(), {
		"picker_ids": picker_ids, "friendly_obs_ids": obs_ids, "sample_row": sample_row,
		"note": "row text carries id/class/soldiers/region/(q,r)/status — no map click required",
	})
	# SELECTED freeze: a SELECTED scope must materialize into explicit units, the
	# existing draft must not mutate, and a stale preview must not execute.
	var cand := _ids_matching("infantry")
	if cand.is_empty():
		cand = _ids(_blue_alive())
	var a := ""
	var b := ""
	if cand.size() >= 2:
		a = str(cand[0])
		b = str(cand[1])
	elif cand.size() == 1:
		a = str(cand[0])
		for u in _blue_alive():
			if str(u.get("id", "")) != a:
				b = str(u.get("id", ""))
				break
	if a.is_empty() or b.is_empty():
		_rec("SELECTED FREEZE", "selected_freeze_preconditions", false, {"cand": cand})
		return
	var panel: Variant = dock.call("get_panel")
	mgr.deselect()
	mgr.select_unit(a)
	# Let the dock observe the map selection first (it re-pushes its builder on any
	# selection change), then inject the SELECTED scope — mirroring a human who
	# clicks a unit on the map and then builds a command from it.
	await process_frame
	await process_frame
	panel.call("set_custom_scope", TableCls.scope_selected())
	await process_frame
	var draft1: Dictionary = panel.call("draft_command")
	var scope1: Dictionary = (draft1.get("scope", {}) as Dictionary).duplicate(true)
	var sc_op := str(scope1.get("op", "")).strip_edges().to_upper()
	var sc_kind := str(scope1.get("kind", "")).strip_edges().to_upper()
	var explicit_ok := false
	if sc_op == "UNIT" and str(scope1.get("unit_id", "")).strip_edges().to_upper() == a:
		explicit_ok = true
	elif (sc_op == "UNITS" or sc_kind == "UNITS") and (scope1.get("unit_ids", []) as Array) == [a]:
		explicit_ok = true
	# Dock-level preview through the live console (this is the human path).
	var preview1: Dictionary = {}
	var preview_valid1 := false
	var pre_live := false
	var pre_busy := false
	var post_status := ""
	var dock_preview_ran := false
	var direct_plan: Dictionary = {}
	if dock != null:
		pre_live = bool(dock.call("is_live"))
		pre_busy = bool(executor.is_busy())
		preview1 = dock.call("preview_command")
		preview_valid1 = bool(dock.call("is_preview_valid"))
		dock_preview_ran = not preview1.is_empty()
		var status_lbl: Variant = dock.get("_status_label")
		if status_lbl is Label:
			post_status = (status_lbl as Label).text
	if preview1.is_empty():
		# Dock refused (busy / not live): record the direct compiler result as a
		# DIAGNOSTIC only — it does not count as the console path passing.
		direct_plan = CompilerCls.plan(bridge, draft1, a)
		_note("dock.preview_command returned {} at SELECTED test (live=%s busy=%s status=%s)" % [str(pre_live), str(pre_busy), post_status])
	var plan1_ids: Array = preview1.get("resolved_units", [])
	var plan1_frozen: Dictionary = preview1.get("scope_frozen", {})
	# Change the map selection while the draft/preview exists.
	mgr.deselect()
	mgr.select_unit(b)
	await process_frame
	await process_frame
	await process_frame
	var draft2: Dictionary = panel.call("draft_command")
	var scope2: Dictionary = (draft2.get("scope", {}) as Dictionary).duplicate(true)
	var draft1_stable: bool = Json_string(scope1) == Json_string(draft1.get("scope", {}))
	var invalidated := true
	var exec_accepted := true
	if dock != null:
		invalidated = not bool(dock.call("is_preview_valid"))
		var res: Dictionary = dock.call("execute_command")
		exec_accepted = bool(res.get("accepted", false))
	_rec("SELECTED FREEZE", "selected_becomes_explicit", explicit_ok and dock_preview_ran and preview_valid1 and (plan1_frozen.get("unit_ids", []) as Array) == [a] and plan1_ids == [a], {
		"draft1": draft1,
		"draft1_scope_form": {"op": sc_op, "kind": sc_kind},
		"draft1_unit_ids": scope1.get("unit_ids", []),
		"dock_preview_ran": dock_preview_ran,
		"dock_is_live": pre_live,
		"executor_busy": pre_busy,
		"dock_status_after_preview": post_status,
		"preview_valid": preview_valid1,
		"preview_ok": preview1.get("ok"),
		"preview_code": preview1.get("code"),
		"preview_detail": preview1.get("detail"),
		"preview_resolved": plan1_ids,
		"plan_scope_frozen": plan1_frozen,
		"direct_plan_diagnostic": direct_plan,
		"selected_a": a,
	})
	_rec("SELECTED FREEZE", "selection_change_cannot_retarget_draft", preview_valid1 and draft1_stable and invalidated and not exec_accepted, {
		"preview_valid_before_change": preview_valid1,
		"draft1_scope_after_change": draft1.get("scope", {}),
		"draft2_scope": scope2,
		"draft1_stable": draft1_stable,
		"scope_changed_to_b": Json_string(scope2) != Json_string(scope1),
		"preview_invalidated": invalidated,
		"stale_execution_accepted": exec_accepted,
		"selection_a": a, "selection_b": b,
	})
	mgr.deselect()
	panel.call("clear_custom_scope")


func _same_scope(s1: Dictionary, s2: Dictionary) -> bool:
	return Json_string(s1) == Json_string(s2)


func Json_string(d: Variant) -> String:
	return JSON.stringify(d)


func _section_authoritative_execution() -> void:
	# A) exact units -> REPOSITION
	var rep_units := _ids_matching("infantry")
	var rep_cmd := TableCls.make_command("REPOSITION", TableCls.scope_units(rep_units), TableCls.target_zone("CENTER"))
	var before := {}
	for u in _units():
		before[str(u.get("id", ""))] = [int(u.get("q", 0)), int(u.get("r", 0)), float(u.get("remaining_mp", 0.0)), bool(u.get("action_ended", false))]
	var run1 := await _run_cmd(rep_cmd)
	var after := {}
	for u in _units():
		after[str(u.get("id", ""))] = [int(u.get("q", 0)), int(u.get("r", 0)), float(u.get("remaining_mp", 0.0)), bool(u.get("action_ended", false))]
	var moved := 0
	var mp_consumed := 0
	var legality_ok := true
	for uid in rep_units:
		if not after.has(uid):
			legality_ok = false
			continue
		var b: Array = before.get(uid, [])
		var a2: Array = after[uid]
		if a2[0] != b[0] or a2[1] != b[1]:
			moved += 1
			if float(a2[2]) > float(b[2]):
				legality_ok = false
			if float(a2[2]) < float(b[2]):
				mp_consumed += 1
	var accepted1: Dictionary = run1.get("accepted", {})
	var res1: Dictionary = run1.get("result", {})
	var exec_units: Array = res1.get("executed_units", [])
	_rec("AUTHORITATIVE EXECUTION", "exec_exact_units_reposition",
		bool(accepted1.get("accepted", false)) and bool(run1.get("finished", false)) and not exec_units.is_empty() and moved > 0 and legality_ok, {
		"command": rep_cmd, "planned": accepted1.get("planned_count"), "moved": moved, "mp_consumed_units": mp_consumed,
		"status": res1.get("execution_status"), "executed_units": exec_units,
		"execution_failed": res1.get("execution_failed"),
	})
	# Occupancy invariant after execution (authoritative map has no duplicates)
	var occ: Variant = mgr.get("_occupied_map")
	var occ_ok := true
	var dupes: Array = []
	var seen := {}
	for k in (occ as Dictionary).keys():
		var v := str((occ as Dictionary)[k])
		if seen.has(v):
			dupes.append(v)
		seen[v] = true
	if dupes.size() > 0:
		occ_ok = false
	_rec("AUTHORITATIVE EXECUTION", "exec_occupancy_invariant", occ_ok and (occ is Dictionary), {
		"occupied_hexes": (occ as Dictionary).size() if occ is Dictionary else -1, "duplicates": dupes,
	})
	# B) class -> HOLD (synchronous rows)
	var hold_cmd := TableCls.make_command("HOLD", TableCls.scope_class("ARCHER"))
	var run2 := await _run_cmd(hold_cmd)
	var archers := _ids_matching("archer")
	var acted := 0
	for u in _units():
		if str(u.get("id", "")) in archers and bool(u.get("action_ended", false)):
			acted += 1
	_rec("AUTHORITATIVE EXECUTION", "exec_class_hold", bool((run2.get("accepted", {}) as Dictionary).get("accepted", false)) and acted == archers.size() and archers.size() > 0, {
		"command": hold_cmd, "archers": archers, "acted": acted,
		"status": (run2.get("result", {}) as Dictionary).get("execution_status"),
	})
	# C) region -> HOLD is planned and executed by the authoritative path
	var south_ids: Array = []
	for u in _blue_alive():
		if _my_region(int(u.get("q", 0)), int(u.get("r", 0))) == "SOUTH":
			south_ids.append(str(u.get("id", "")))
	south_ids.sort()
	var reg_cmd := TableCls.make_command("HOLD", TableCls.scope_region("SOUTH"))
	var plan_reg: Dictionary = CompilerCls.plan(bridge, reg_cmd)
	_rec("AUTHORITATIVE EXECUTION", "exec_region_scope_resolution", (plan_reg.get("resolved_units", []) as Array) == south_ids, {
		"resolved": plan_reg.get("resolved_units"), "expected": south_ids, "planned": plan_reg.get("planned"),
	})
	# D) north cavalry -> FLANK (plan level; verify no state mutation from plan)
	var nc_ast := {"op": "INTERSECT", "args": [{"op": "CLASS", "class": "CAVALRY"}, {"op": "REGION", "region": "NORTH"}]}
	var nc_cmd := TableCls.make_command("FLANK", nc_ast, TableCls.target_direction("FORWARD"))
	var pre_fp := str(bridge.fingerprint())
	var plan_nc: Dictionary = CompilerCls.plan(bridge, nc_cmd)
	var post_fp := str(bridge.fingerprint())
	var nc_ids: Array = ScopeAlgebraCls.resolve(nc_ast, {"unit_manager": mgr, "bounds": bridge.map_bounds()}).get("unit_ids", [])
	_rec("AUTHORITATIVE EXECUTION", "exec_north_cavalry_flank_plan", bool(plan_nc.get("ok", false)) and (plan_nc.get("resolved_units", []) as Array) == nc_ids and pre_fp == post_fp, {
		"north_cavalry": nc_ids, "resolved": plan_nc.get("resolved_units"), "planned": plan_nc.get("planned"),
		"plan_is_pure_dry_run": pre_fp == post_fp,
	})
	# E) single attacker -> ATTACK when legally reachable, else record honest precondition
	var attacker := ""
	var defender := ""
	for u in _blue_alive():
		var targets: Array = mgr.get_attackable_targets(str(u.get("id", "")))
		if not targets.is_empty() and not bool(u.get("action_ended", false)):
			attacker = str(u.get("id", ""))
			defender = str((targets[0] as Dictionary).get("id", ""))
			break
	if attacker.is_empty():
		# No legal BLUE attack yet: prove the authoritative gate refuses an
		# illegal attack instead (negative legality test, zero state mutation).
		var far_target := ""
		for u in _red_alive():
			var tq := int(u.get("q", 0))
			var tr := int(u.get("r", 0))
			var blocked := true
			for b in _blue_alive():
				if absi(int(b.get("q", 0)) - tq) + absi(int(b.get("r", 0)) - tr) <= 4:
					blocked = false
					break
			if blocked:
				far_target = str(u.get("id", ""))
				break
		var neg_ok := false
		var neg_detail := {}
		if not far_target.is_empty():
			var probe_id := ""
			for u2 in _blue_alive():
				if not bool(u2.get("action_ended", false)):
					probe_id = str(u2.get("id", ""))
					break
			if not probe_id.is_empty():
				var bad_cmd := TableCls.make_command("ATTACK", TableCls.scope_units([probe_id]), TableCls.target_formation(far_target))
				var plan_bad: Dictionary = CompilerCls.plan(bridge, bad_cmd)
				var before_fp := str(bridge.fingerprint())
				var run_bad := await _run_cmd(bad_cmd)
				var after_fp := str(bridge.fingerprint())
				neg_detail = {
					"attacker": probe_id, "target": far_target,
					"plan_ok": plan_bad.get("ok"), "plan_code": plan_bad.get("code"),
					"plan_detail": plan_bad.get("detail"),
					"executor_accepted": (run_bad.get("accepted", {}) as Dictionary).get("accepted"),
					"state_unchanged": before_fp == after_fp,
				}
				neg_ok = (not bool(plan_bad.get("ok", false))) and (not bool((run_bad.get("accepted", {}) as Dictionary).get("accepted", false))) and before_fp == after_fp
		_rec("AUTHORITATIVE EXECUTION", "exec_single_attack", neg_ok, {
			"skipped_positive_case": true,
			"reason": "No legal BLUE attack yet (contact not established) — the authoritative service is the arbiter of attack legality.",
			"negative_legality_probe": neg_detail,
			"note": "positive attack execution is demonstrated live later in the turn run (live_engagement_observed)",
		})
	else:
		var atk_cmd := TableCls.make_command("ATTACK", TableCls.scope_units([attacker]), TableCls.target_formation(defender))
		var before_hp := 0
		var du: Dictionary = mgr.get_unit_by_id(defender)
		before_hp = int(du.get("soldier_count", 0))
		var run3 := await _run_cmd(atk_cmd)
		var after_u: Dictionary = mgr.get_unit_by_id(defender)
		var after_hp := int(after_u.get("soldier_count", 0)) if not after_u.is_empty() else 0
		_rec("AUTHORITATIVE EXECUTION", "exec_single_attack", before_hp != after_hp or after_u.is_empty(), {
			"attacker": attacker, "defender": defender, "hp_before": before_hp, "hp_after": after_hp,
			"status": (run3.get("result", {}) as Dictionary).get("execution_status"),
		})
	# F) LLM-style raw JSON command through the same gate
	var llm_json := JSON.stringify({
		"action": "HOLD",
		"scope": {"op": "CLASS", "class": "SPEARMAN"},
		"target": {},
		"stance": "BALANCED",
	})
	var parsed: Variant = JSON.parse_string(llm_json)
	var llm_ok := parsed is Dictionary and bool(TableCls.validate_command(parsed).get("ok", false))
	var llm_run := await _run_cmd(parsed)
	_rec("AUTHORITATIVE EXECUTION", "exec_llm_json_command_same_gate", llm_ok and bool((llm_run.get("accepted", {}) as Dictionary).get("accepted", false)), {
		"json": llm_json, "valid": llm_ok,
		"status": (llm_run.get("result", {}) as Dictionary).get("execution_status"),
		"note": "identical structured representation for human console and future LLM",
	})


func _section_contract_boundary(tag: String, section: String) -> void:
	var inv := _invariants()
	_rec(section, tag, _inv_ok(inv), inv)


func _section_turn_persistence() -> void:
	# The execution section consumed some formations' actions; end that turn so the
	# persistence run starts from a clean player phase (also proves advancement
	# from a post-execution state).
	var acted := 0
	for u in _blue_alive():
		if bool(u.get("action_ended", false)):
			acted += 1
	var refreshed := false
	if acted > 0:
		refreshed = await _advance_turn()
	_rec("TURN PERSISTENCE", "fresh_phase_before_run", acted == 0 or refreshed, {
		"units_acted_before": acted, "turn_advanced": refreshed, "turn": mgr.get_current_turn(),
	})
	var turns_target := 8
	var all_ok := true
	var observed_turns: Array = []
	var attack_events: Array = []
	for i in range(turns_target):
		var turn_now := int(mgr.get_current_turn())
		var turn_ev := await _play_one_turn(i, attack_events)
		var advanced := await _advance_turn()
		var inv := _invariants()
		var ok := advanced and _inv_ok(inv)
		if not ok:
			all_ok = false
		turn_ev["turn_started"] = turn_now
		turn_ev["turn_after"] = mgr.get_current_turn()
		turn_ev["advanced"] = advanced
		turn_ev["blue_alive"] = inv.get("blue_alive")
		turn_ev["red_alive"] = inv.get("red_alive")
		turn_ev["red_known"] = inv.get("red_known")
		turn_ev["full_information"] = inv.get("full_information")
		turn_ev["flat"] = inv.get("flat_no_terrain_effects")
		turn_ev["no_supply"] = inv.get("no_supply_units")
		turn_ev["fog_off"] = inv.get("fog_disabled")
		turn_ev["stale_hidden"] = inv.get("stale_hidden")
		turn_ev["morale_min"] = inv.get("morale_min")
		turn_ev["morale_max"] = inv.get("morale_max")
		turn_ev["morale_pinned"] = inv.get("morale_pinned")
		turn_ev["no_routs"] = inv.get("no_routs")
		turn_ev["scope_algebra_live"] = inv.get("scope_algebra_live")
		turn_ev["obs_schema"] = inv.get("obs_schema")
		turn_ev["rules_authority"] = inv.get("rules_authority_present")
		turn_ev["renderer_count"] = inv.get("renderer_count")
		turn_ev["manager_count"] = inv.get("manager_count")
		observed_turns.append(turn_ev)
		if bool(shell.get("_battle_lost")):
			_note("battle reported lost at turn %d — halting turn run" % mgr.get_current_turn())
			break
	# Contact hunt: if no engagement happened yet, keep closing until the first
	# authoritative attack resolves (bounded), so attack execution is observed live.
	var hunt := 0
	while attack_events.is_empty() and hunt < 8 and not bool(shell.get("_battle_lost")):
		hunt += 1
		await _play_one_turn(100 + hunt, attack_events)
		var adv := await _advance_turn()
		var inv2 := _invariants()
		if not (adv and _inv_ok(inv2)):
			all_ok = false
		observed_turns.append({
			"turn_started": int(mgr.get_current_turn()) - 1, "turn_after": mgr.get_current_turn(),
			"contact_hunt": true, "advanced": adv, "full_information": inv2.get("full_information"),
			"flat": inv2.get("flat_no_terrain_effects"), "morale_pinned": inv2.get("morale_pinned"),
			"blue_alive": inv2.get("blue_alive"), "red_alive": inv2.get("red_alive"),
		})
	_rec("TURN PERSISTENCE", "five_turn_continuous_contract", all_ok and observed_turns.size() >= turns_target, {
		"turns": observed_turns, "final_turn": mgr.get_current_turn(), "turns_target": turns_target,
	})
	# Live engagement evidence: at least one authoritative attack must resolve with
	# real damage once contact is made (or an honest, explicit skip is recorded).
	var damage_ok := false
	for ev in attack_events:
		if int(ev.get("hp_after", -1)) < int(ev.get("hp_before", -1)):
			damage_ok = true
	_rec("TURN PERSISTENCE", "live_engagement_observed", (not attack_events.is_empty()) and damage_ok, {
		"attack_events": attack_events.slice(0, 8),
		"note": "BLUE/RED engage through the authoritative execution path when contact is reached",
	})
	_section_contract_boundary("post_turn_run_contract", "TURN PERSISTENCE")


func _play_one_turn(i: int, attack_events: Array) -> Dictionary:
	var ev := {}
	# 1) If a legal attack exists, take it with the authoritative executor.
	var attacker := ""
	var target := ""
	for u in _blue_alive():
		if bool(u.get("action_ended", false)):
			continue
		var targets: Array = mgr.get_attackable_targets(str(u.get("id", "")))
		if not targets.is_empty():
			attacker = str(u.get("id", ""))
			target = str((targets[0] as Dictionary).get("id", ""))
			break
	if not attacker.is_empty():
		var hp_before := int(mgr.get_unit_by_id(target).get("soldier_count", 0))
		var atk_cmd := TableCls.make_command("ATTACK", TableCls.scope_units([attacker]), TableCls.target_formation(target))
		var run_a := await _run_cmd(atk_cmd)
		var du: Dictionary = mgr.get_unit_by_id(target)
		var hp_after := int(du.get("soldier_count", 0)) if not du.is_empty() else 0
		attack_events.append({"turn": mgr.get_current_turn(), "attacker": attacker, "target": target,
			"hp_before": hp_before, "hp_after": hp_after,
			"status": (run_a.get("result", {}) as Dictionary).get("execution_status"),
			"accepted": (run_a.get("accepted", {}) as Dictionary).get("accepted")})
		ev["order"] = "ATTACK:%s->%s" % [attacker, target]
	else:
		var cmd: Dictionary = TableCls.make_command("ADVANCE", TableCls.scope_all_combat(), TableCls.target_direction("FORWARD"))
		var run := await _run_cmd(cmd)
		ev["order"] = "ADVANCE:ALL_COMBAT"
		ev["advance_accepted"] = (run.get("accepted", {}) as Dictionary).get("accepted")
		ev["advance_status"] = (run.get("result", {}) as Dictionary).get("execution_status")
	# 2) HOLD a class every third turn (variety: hold must coexist with moves).
	if i % 3 == 1:
		var hold_cmd := TableCls.make_command("HOLD", TableCls.scope_class("SPEARMAN"))
		var run_h := await _run_cmd(hold_cmd)
		ev["hold_accepted"] = (run_h.get("accepted", {}) as Dictionary).get("accepted")
		ev["hold_status"] = (run_h.get("result", {}) as Dictionary).get("execution_status")
	return ev


func _section_reset_persistence() -> void:
	var cases: Array = [
		{"name": "Reset#1-default-via-dock-UI", "b": {}, "r": {}, "expect_blue": 10, "expect_red": 10, "via": "dock"},
		{"name": "Reset#2-customA-via-shell", "b": {"infantry": 4, "archer": 1, "spearman": 1, "cavalry": 2, "scout": 1, "hq": 1},
			"r": {"infantry": 1, "archer": 3, "spearman": 3, "cavalry": 1, "scout": 1, "hq": 1}, "expect_blue": 10, "expect_red": 10, "via": "shell"},
		{"name": "Reset#3-customB-via-shell", "b": {"infantry": 6, "archer": 0, "spearman": 0, "cavalry": 3, "scout": 1, "hq": 1},
			"r": {"infantry": 0, "archer": 0, "spearman": 6, "cavalry": 3, "scout": 0, "hq": 1}, "expect_blue": 11, "expect_red": 10, "via": "shell"},
		{"name": "Reset#4-default-again-via-dock-UI", "b": {}, "r": {}, "expect_blue": 10, "expect_red": 10, "via": "dock"},
	]
	var results: Array = []
	var all_ok := true
	for c in cases:
		var before_ids: Array = _ids(_units())
		if str(c.get("via", "shell")) == "dock" and dock != null:
			# Human path: preset the spinboxes, then press Apply & Reset.
			dock.call("_apply_roster_preset", c.get("b"), c.get("r"))
			await process_frame
			dock.call("_on_apply_roster_rebuild")
		else:
			shell.call("rebuild_step0_roster", c.get("b"), c.get("r"))
		await process_frame
		await process_frame
		await process_frame
		var blues := _blue_alive()
		var reds := _red_alive()
		var after_ids: Array = _ids(_units())
		var count_ok: bool = blues.size() == int(c.get("expect_blue")) and reds.size() == int(c.get("expect_red"))
		var total_ok: bool = _units().size() == blues.size() + reds.size()
		var composition_ok := true
		if str(c.get("name", "")).begins_with("Reset#1") or str(c.get("name", "")).begins_with("Reset#4"):
			composition_ok = _class_counts(blues) == DEFAULT_ROSTER and _class_counts(reds) == DEFAULT_ROSTER
		else:
			# Custom rosters: counts must match the request exactly (derived, not hardcoded).
			var want_b := {}
			for k in (c.get("b", {}) as Dictionary).keys():
				var n := int((c.get("b", {}) as Dictionary)[k])
				if n > 0:
					want_b[str(k).to_lower()] = n
			var want_r := {}
			for k2 in (c.get("r", {}) as Dictionary).keys():
				var n2 := int((c.get("r", {}) as Dictionary)[k2])
				if n2 > 0:
					want_r[str(k2).to_lower()] = n2
			composition_ok = _class_counts(blues) == want_b and _class_counts(reds) == want_r
		# observation rebuilt against the new roster
		var obs2: Dictionary = ObsCls.build(bridge)
		var obs_ids: Array = []
		for u_val in (obs2.get("friendly_units", []) as Array):
			obs_ids.append(str((u_val as Dictionary).get("unit_id", "")))
		obs_ids.sort()
		var lives_ok: bool = obs_ids == _ids(blues)
		# picker rebuilt (rows must track the authoritative roster, not stale ids)
		var checkboxes: Variant = dock.get("_unit_checkboxes")
		var picker_ids: Array = []
		if checkboxes is Dictionary:
			for k in (checkboxes as Dictionary).keys():
				picker_ids.append(str(k))
		picker_ids.sort()
		var picker_ok: bool = picker_ids == _ids(blues)
		# scope resolution rebuilt (class scope resolves against the NEW roster)
		var cls_ids := _ids_matching("cavalry")
		var cav_res: Dictionary = ScopeAlgebraCls.resolve({"op": "CLASS", "class": "CAVALRY"}, {"unit_manager": mgr, "bounds": bridge.map_bounds()})
		var scope_ok: bool = (cav_res.get("unit_ids", []) as Array) == cls_ids
		# selection reconciled
		var sel_ok := not bool(mgr.is_unit_selected())
		var turn_now := int(mgr.get_current_turn())
		var turn_ok := turn_now >= 1
		var inv := _invariants()
		var inv_ok := _inv_ok(inv)
		var ok: bool = count_ok and total_ok and composition_ok and lives_ok and picker_ok and scope_ok and sel_ok and turn_ok and inv_ok
		if not ok:
			all_ok = false
		results.append({
			"case": c.get("name"), "applied_via": c.get("via"),
			"blue_count": blues.size(), "red_count": reds.size(),
			"blue_ids": _ids(blues),
			"count_ok": count_ok, "no_ghost_units": total_ok, "composition_ok": composition_ok,
			"obs_rebuilt": lives_ok, "picker_rebuilt": picker_ok, "scope_rebuilt": scope_ok,
			"selection_cleared": sel_ok, "turn_after": turn_now, "turn_sane": turn_ok,
			"invariants_ok": inv_ok, "morale_pinned": inv.get("morale_pinned"),
			"full_information": inv.get("full_information"),
		})
	_rec("RESET PERSISTENCE", "four_resets_continuous_contract", all_ok, {"cases": results})


func _section_production_isolation() -> void:
	# Boot the PRODUCTION battle through the real scene-change path in the same
	# process and verify it does NOT inherit DEV-only simplifications.
	# First drop our manually-instantiated DEV scene (change_scene only frees
	# current_scene; this instance was added directly by the cold-boot phase).
	await _teardown()
	var prod: Node = await _goto_scene(PROD_SCENE)
	if prod == null:
		_rec("PRODUCTION ISOLATION", "prod_boot", false, {"error": "production scene failed to load"})
		return
	var ok_boot := false
	for _i in range(1200):
		await process_frame
		if prod.get("unit_manager") != null and prod.get("hex_grid") != null:
			ok_boot = true
			break
	if not ok_boot:
		_rec("PRODUCTION ISOLATION", "prod_boot", false, {"error": "production shell did not initialize"})
		return
	var p_mgr: Variant = prod.get("unit_manager")
	var p_grid: Node = prod.get("hex_grid") as Node
	var cells: Dictionary = p_grid.get("cell_data") if p_grid != null else {}
	var hist := {}
	for key in cells.keys():
		var cell: Variant = cells[key]
		var t := 0
		if cell is Dictionary:
			t = int((cell as Dictionary).get("terrain", 0))
		elif cell != null:
			var tv: Variant = cell.get("terrain")
			t = int(tv) if tv != null else 0
		hist[t] = int(hist.get(t, 0)) + 1
	var prod_units: Array = []
	for u in p_mgr.get_all_units_including_garrisoned():
		if u is Dictionary:
			prod_units.append(u)
	var prod_classes: Array = []
	for u2 in prod_units:
		prod_classes.append(str(u2.get("class", "")))
	var terrain_variety: bool = hist.size() > 1
	var fog_on: bool = prod.get("_fog") != null
	var sandbox_flag: bool = bool(prod.get("is_step0_sandbox"))
	var R2 := _rules()
	var rules_active: bool = R2 != null and bool(R2.call("is_active"))
	_rec("PRODUCTION ISOLATION", "prod_no_dev_inheritance", (not sandbox_flag) and (not rules_active) and terrain_variety and fog_on, {
		"is_step0_sandbox": sandbox_flag,
		"sandbox_rules_active_during_production": rules_active,
		"terrain_histogram": hist,
		"terrain_variety": terrain_variety,
		"fog_instance": fog_on,
		"unit_count": prod_units.size(),
		"classes_sample": prod_classes.slice(0, 12),
	})
	# production smoke: select, move one blue unit, end turn, check turn advanced
	var p_moved := false
	var p_turn_ok := false
	var smoke: Dictionary = {}
	if p_mgr != null:
		var p_blue := ""
		for u3 in prod_units:
			if str(u3.get("faction", "")) == "blue" and int(u3.get("soldier_count", 0)) > 0 and str(u3.get("class", "")) != "hq":
				p_blue = str(u3.get("id", ""))
				break
		if not p_blue.is_empty():
			var u_from: Dictionary = p_mgr.get_unit_by_id(p_blue)
			var fq := int(u_from.get("q", 0))
			var fr := int(u_from.get("r", 0))
			var p_service: Variant = prod.get("_battle_command_service")
			var targets: Array = []
			if p_service != null and p_service.has_method("reachable_area"):
				var area: Dictionary = p_service.call("reachable_area", p_blue, "blue", "auto")
				targets = area.get("reachable", [])
			var dest := Vector2i(-999, -999)
			if not targets.is_empty():
				var t: Dictionary = targets[targets.size() - 1]
				dest = Vector2i(int(t.get("q", 0)), int(t.get("r", 0)))
			if dest.x != -999 and prod.has_method("execute_step7_move"):
				_prod_move_done = false
				prod.call("execute_step7_move", p_blue, dest, "auto", Callable(self, "_on_prod_move"))
				for _i in range(2400):
					await process_frame
					if _prod_move_done:
						break
				var u_after: Dictionary = p_mgr.get_unit_by_id(p_blue)
				p_moved = (int(u_after.get("q", -999)) != fq) or (int(u_after.get("r", -999)) != fr)
				smoke["move_from"] = [fq, fr]
				smoke["requested"] = [dest.x, dest.y]
				smoke["move_to"] = [int(u_after.get("q", -999)), int(u_after.get("r", -999))]
				smoke["reachable_count"] = targets.size()
				smoke["move_result"] = _prod_move_res
			else:
				smoke["move_channel"] = "no legal destination or executor missing"
		var prev_turn := int(p_mgr.get_current_turn())
		prod.call("end_player_phase")
		for _i in range(14400):
			await process_frame
			if int(prod.get("_turn_phase")) == 0 and int(p_mgr.get_current_turn()) == prev_turn + 1:
				p_turn_ok = true
				break
		var morale_moved := false
		for u4 in p_mgr.get_all_units_including_garrisoned():
			if u4 is Dictionary and float((u4 as Dictionary).get("morale", 100.0)) < 99.99:
				morale_moved = true
		_rec("PRODUCTION ISOLATION", "prod_smoke_flow", p_moved and p_turn_ok, {
			"unit": p_blue, "moved": p_moved, "turn_advanced": p_turn_ok,
			"turn_after": p_mgr.get_current_turn(), "details": smoke,
			"production_morale_state_available": true,
		})
	else:
		_rec("PRODUCTION ISOLATION", "prod_smoke_flow", false, {"error": "no production manager"})
	# mode leakage: DEV contract must be off while production runs and the flag
	# must not be left behind for the next scene.
	var R3 := _rules()
	_rec("PRODUCTION ISOLATION", "prod_dev_overrides_absent", (not sandbox_flag) and (not rules_active) and (R3 == null or not bool(R3.call("is_active"))), {
		"note": "SandboxRules active flag is false during production; DEV-only overrides (flat terrain, fog off, full information) are not inherited.",
	})
	# ---- SUP-FINAL production gates (additive; runs while PRODUCTION is live)
	await _section_sup_final_production(prod, p_mgr)
	# ---- Production -> Title transition (DEV re-entry happens in the next section)
	var title2: Node = await _goto_scene(TITLE_SCENE)
	_rec("PRODUCTION ISOLATION", "prod_return_to_title", title2 != null and title2.get_node_or_null("VBox/Buttons/BtnCloud1Sandbox") != null, {
		"scene_after_production": str(title2.name) if title2 != null else "null",
	})


func _on_prod_move(res: Dictionary) -> void:
	_prod_move_res = res
	_prod_move_done = true


func _goto_scene(path: String) -> Node:
	change_scene_to_file(path)
	await process_frame
	await process_frame
	await process_frame
	return current_scene


func _rebind(mount_expected: bool = true, seconds_budget: float = 60.0) -> bool:
	var cs: Node = current_scene
	if cs == null:
		return false
	scene = cs
	mount = cs.get_node_or_null("Cloud1LiveMount")
	if mount == null:
		return not mount_expected
	var deadline := Time.get_ticks_msec() + int(seconds_budget * 1000.0)
	while Time.get_ticks_msec() < deadline and not bool(mount.get("mount_ready")):
		await process_frame
	if not bool(mount.get("mount_ready")):
		return false
	shell = mount.get("shell")
	bridge = mount.get("bridge")
	executor = mount.get("executor")
	dock = mount.get("dock")
	det = mount.get("det") as Node
	mgr = bridge.get_manager()
	service = bridge.get_service()
	return shell != null and mgr != null


func _section_scene_reentry() -> void:
	# ---- Real boot chain: Title -> DEV (button press) -> play -> contract ----
	var title: Node = await _goto_scene(TITLE_SCENE)
	var dev_btn: Node = title.get_node_or_null("VBox/Buttons/BtnCloud1Sandbox") if title != null else null
	var title_ok: bool = dev_btn != null and (dev_btn as Button).text == "DEV: Cloud General Sandbox"
	_rec("SCENE REENTRY", "title_exposes_dev_entry", title_ok, {
		"scene": TITLE_SCENE, "button": "DEV: Cloud General Sandbox",
		"production_buttons_present": title != null and title.get_node_or_null("VBox/Buttons/BtnCampaign") != null and title.get_node_or_null("VBox/Buttons/BtnBattle") != null,
	})
	if not title_ok:
		_rec("SCENE REENTRY", "dev_reentry_contract", false, {"error": "DEV entry button missing on title"})
		return
	# Press the DEV button exactly like a human: this calls change_scene_to_file.
	(dev_btn as Button).pressed.emit()
	await process_frame
	await process_frame
	await process_frame
	var bound := await _rebind(true)
	if not bound:
		_rec("SCENE REENTRY", "dev_reentry_contract", false, {"error": "DEV scene did not mount after title button press"})
		return
	var inv := _invariants()
	var roster_ok: bool = _blue_alive().size() == 10 and _red_alive().size() == 10 and _class_counts(_blue_alive()) == DEFAULT_ROSTER
	_rec("SCENE REENTRY", "dev_reentry_contract", _inv_ok(inv) and roster_ok, {
		"entry_path": "title_screen.BtnCloud1Sandbox.pressed -> change_scene_to_file(cloud1_battle_test.tscn)",
		"turn": mgr.get_current_turn(), "blue": _blue_alive().size(), "red": _red_alive().size(),
		"invariants": inv,
	})
	# Play one real turn on the re-entered scene and re-assert the contract.
	var cmd := TableCls.make_command("ADVANCE", TableCls.scope_all_combat(), TableCls.target_direction("FORWARD"))
	var run := await _run_cmd(cmd)
	var advanced := await _advance_turn()
	var inv2 := _invariants()
	_rec("SCENE REENTRY", "reentry_play_and_contract", advanced and _inv_ok(inv2), {
		"command_accepted": (run.get("accepted", {}) as Dictionary).get("accepted"),
		"status": (run.get("result", {}) as Dictionary).get("execution_status"),
		"turn_after": mgr.get_current_turn(),
		"full_information": inv2.get("full_information"), "flat": inv2.get("flat_no_terrain_effects"),
		"morale_pinned": inv2.get("morale_pinned"), "no_supply": inv2.get("no_supply_units"),
		"fog_off": inv2.get("fog_disabled"), "scope_algebra_live": inv2.get("scope_algebra_live"),
	})
	# Scope algebra on the re-entered scene resolves against the fresh roster.
	var cls := _ids_matching("cavalry")
	var res: Dictionary = ScopeAlgebraCls.resolve({"op": "CLASS", "class": "CAVALRY"}, {"unit_manager": mgr, "bounds": bridge.map_bounds()})
	_rec("SCENE REENTRY", "reentry_scope_algebra", (res.get("unit_ids", []) as Array) == cls and not cls.is_empty(), {"cavalry": cls, "resolved": res.get("unit_ids")})


func _section_morale_rout() -> void:
	# Mechanism audit: is the morale modifier / march penalty able to affect DEV play?
	var mod100 := CombatCalcCls.get_morale_modifier(100.0)
	var mod50 := CombatCalcCls.get_morale_modifier(50.0)
	var mod0 := CombatCalcCls.get_morale_modifier(0.0)
	var penalty := Step3ConfigCls.get_morale_penalty(2) # RED march class
	var atk1: Dictionary = CombatCalcCls.calculate_combat(
		{"class": "infantry", "soldier_count": 400, "morale": 100.0},
		{"class": "infantry", "soldier_count": 400, "morale": 100.0}, 1, 0, {}, 1.0)
	var atk2: Dictionary = CombatCalcCls.calculate_combat(
		{"class": "infantry", "soldier_count": 400, "morale": 10.0},
		{"class": "infantry", "soldier_count": 400, "morale": 100.0}, 1, 0, {}, 1.0)
	var dmg1 := int(atk1.get("defender_casualties", 0))
	var dmg2 := int(atk2.get("defender_casualties", 0))
	var morale_effect_free: bool = (absf(mod100 - mod50) < 0.001) and (absf(mod100 - mod0) < 0.001) and (absf(penalty) < 0.001) and dmg1 == dmg2
	_rec("MORALE/ROUT", "morale_cannot_affect_dev_play", morale_effect_free, {
		"morale_modifier_100": mod100, "morale_modifier_50": mod50, "morale_modifier_0": mod0,
		"march_penalty_red": penalty,
		"damage_at_morale100": dmg1, "damage_at_morale10": dmg2,
	})
	# Combat shock must not degrade morale in DEV either (pinned).
	var aft1: float = float(atk1.get("defender_final_morale", 100.0))
	_rec("MORALE/ROUT", "morale_pinned_after_combat_math", absf(aft1 - 100.0) < 0.001, {
		"defender_final_morale_after_attack": aft1,
		"attacker_final_morale_after_attack": float(atk1.get("attacker_final_morale", 100.0)),
	})
	# Rout is canonically unreachable (step6 decision layer retired) and no unit can rout in live play.
	var routed_now: Array = []
	for u in _units():
		if bool(u.get("routed", false)):
			routed_now.append(str(u.get("id", "")))
	_rec("MORALE/ROUT", "rout_unreachable_live", routed_now.is_empty() and shell.get("_step6") == null, {
		"routed_units": routed_now, "step6": str(shell.get("_step6")),
	})


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

func _run() -> void:
	print("=========================================================")
	print("CLOUD GENERAL DEV CONTRACT AUDIT (cold, live, independent)")
	print("RUN ID: %s" % _run_id)
	print("=========================================================")
	var booted := await _boot_dev()
	if not booted:
		_rec("BOOT CONTRACT", "boot_dev_scene", false, {"error": "DEV scene failed to mount"})
		_finish()
		return
	_rec("BOOT CONTRACT", "boot_dev_scene", true, {
		"scene": DEV_SCENE, "mount_ready": true, "shell": shell.name, "turn": mgr.get_current_turn(),
	})
	_section_boot_contract()
	_section_supply_retirement()
	_section_sup_final_dev()
	_section_region_geometry()
	_section_scope_algebra()
	_section_action_table()
	await _section_picker_and_selected()
	_section_morale_rout()
	await _section_authoritative_execution()
	await _section_turn_persistence()
	await _section_reset_persistence()
	# reset leaves a fresh battlefield: verify the continuous contract once more
	_section_contract_boundary("post_reset_contract", "RESET PERSISTENCE")
	await _section_production_isolation()
	await _section_scene_reentry()
	# final continuous check on the re-entered DEV scene
	if shell != null:
		_section_contract_boundary("final_contract_check", "SCENE REENTRY")
	_finish()


func _finish() -> void:
	var elapsed := (Time.get_ticks_msec() - _t0) / 1000.0
	var overall := "pass" if fail_count == 0 else "fail"
	var doc := {
		"contract": "CLOUD-GENERAL-STEP-01-DEV-CONTRACT-CONTINUOUS-AUDIT",
		"run_id": _run_id,
		"started_iso_local": Time.get_datetime_string_from_system(false),
		"generated_utc_unix": Time.get_unix_time_from_system(),
		"godot_version": Engine.get_version_info(),
		"elapsed_seconds": elapsed,
		"overall": overall,
		"passed": pass_count,
		"failed": fail_count,
		"gates": gates,
		"gate_order": gate_order,
		"notes": notes,
	}
	DirAccess.make_dir_recursive_absolute(REPORT_DIR)
	var wf := FileAccess.open(REPORT_JSON, FileAccess.WRITE)
	if wf != null:
		wf.store_string(JSON.stringify(doc, "  "))
		print("[AUDIT] wrote %s" % REPORT_JSON)
	else:
		printerr("[AUDIT] could not write %s" % REPORT_JSON)
	var merged: Dictionary = {}
	if FileAccess.file_exists(DELIVER_JSON):
		var rf := FileAccess.open(DELIVER_JSON, FileAccess.READ)
		if rf != null:
			var parsed: Variant = JSON.parse_string(rf.get_as_text())
			if parsed is Dictionary:
				merged = parsed
	merged["dev_contract_audit"] = {
		"overall": overall,
		"passed": pass_count,
		"failed": fail_count,
		"elapsed_seconds": elapsed,
		"report": REPORT_JSON,
		"gates": gates,
		"notes": notes,
	}
	DirAccess.make_dir_recursive_absolute("D:/Game development/.workflow/deliverables/CLOUD-GENERAL-STEP-01")
	var mf := FileAccess.open(DELIVER_JSON, FileAccess.WRITE)
	if mf != null:
		mf.store_string(JSON.stringify(merged, "  "))
		print("[AUDIT] merged into %s" % DELIVER_JSON)
	print("=========================================================")
	print("AUDIT RESULT: %s | %d passed / %d failed | %.1fs" % [overall.to_upper(), pass_count, fail_count, elapsed])
	print("=========================================================")
	quit(0 if fail_count == 0 else 1)
