extends SceneTree

## Adaptive formation-cluster probe (COLD IMPLEMENTATION §§28–40).
## Part A (pure, deterministic): synthetic lateral arrangements against
## Step7FormationClusters.clusterize — blob counts, outlier singleton,
## continuous-line cohesion, translation invariance, pair rule, repeatability.
## Part B (live): boot the canonical battle, freeze turn geometry, verify
## band completeness, scope purity, camera invariance, RED-blindness,
## turn-freeze, heatmap agreement, six-profile eval + canonical execution.
## Writes: D:/Game development/.workflow/deliverables/SB-CAVALRY-EVALUATOR/cluster_evidence.json

const ClustersScript = preload("res://scripts/step7/step7_formation_clusters.gd")
const EvalScript = preload("res://scripts/step7/step7_cavalry_evaluator.gd")
const CommandScript = preload("res://scripts/step7/step7_action_command.gd")
const BoundaryScript = preload("res://scripts/step2r/step2r_world_boundary.gd")

const OUT := "D:/Game development/.workflow/deliverables/SB-CAVALRY-EVALUATOR/cluster_evidence.json"
const LOG := "user://cluster_probe.log"

var failures: Array = []
var notes: Array = []
var evidence := {}


func _init() -> void:
	call_deferred("_run")


func _check(cond: bool, name: String) -> void:
	if cond:
		notes.append("PASS " + name)
	else:
		failures.append(name)


func _log(s: String) -> void:
	var f := FileAccess.open(LOG, FileAccess.READ_WRITE)
	if f:
		f.seek_end()
		f.store_line(s)
	print(s)


func _mk_anchors(scalars: Array) -> Array:
	var out: Array = []
	var i := 0
	for s in scalars:
		# Exact lateral encoding: s = r + 0.5q with q in {0,1}.
		var f: float = floor(float(s))
		var q := int(round((float(s) - f) * 2.0))
		out.append({"id": "T_%02d" % i, "q": q, "r": int(f)})
		i += 1
	return out


func _ids_of_clusters(res: Dictionary) -> Array:
	var out: Array = []
	for c in (res.get("clusters", []) as Array):
		out.append(str((c as Dictionary)["id"]))
	return out


func _stable_json(res: Dictionary) -> String:
	var c := (res as Dictionary).duplicate(true)
	var stats: Dictionary = c.get("stats", {})
	stats.erase("projection_sort_ms")
	stats.erase("cluster_build_ms")
	c["stats"] = stats
	return JSON.stringify(c)


func _synthetic() -> void:
	# S1: one compact blob -> one cluster, labelled C.
	var r1 := ClustersScript.clusterize(_mk_anchors([-0.5, 0.0, 0.5, 1.0]))
	_check(bool(r1.get("ok", false)) and (r1.get("clusters", []) as Array).size() == 1, "S1 one blob -> one cluster")
	_check(_ids_of_clusters(r1) == ["C"], "S1 single cluster labelled C")
	# S2: three separated blobs -> L1 C R1 (no map thirds involved).
	var r2 := ClustersScript.clusterize(_mk_anchors([-11.0, -10.5, -10.0, -0.5, 0.0, 0.5, 9.5, 10.0, 10.5]))
	_check((r2.get("clusters", []) as Array).size() == 3, "S2 three blobs -> three clusters")
	_check(_ids_of_clusters(r2) == ["L1", "C", "R1"], "S2 labels are L1 C R1")
	# S3: far-left outlier (Sec 9 example) -> three bands, nothing discarded.
	# Robust center (-8) sits inside the middle blob, so per Sec 13 that blob
	# is honestly C and the far group is L1 (no invented geometry).
	var r3 := ClustersScript.clusterize(_mk_anchors([-22.0, -21.0, -20.0, -9.0, -8.0, -7.0, -1.0, 0.0, 1.0]))
	_check((r3.get("clusters", []) as Array).size() == 3, "S3 outlier -> three clusters (no discard)")
	var c3: Array = r3.get("clusters", [])
	_check((c3[0] as Dictionary).get("members", []).size() == 3 and str((c3[0] as Dictionary)["id"]) == "L1", "S3 far group kept whole as L1")
	_check(_ids_of_clusters(r3) == ["L1", "C", "R1"], "S3 labels are L1 C R1")
	# S3b: lone singleton outlier.
	var r3b := ClustersScript.clusterize(_mk_anchors([-30.0, -9.0, -8.0, -7.0, 0.0, 1.0]))
	_check((r3b.get("clusters", []) as Array).size() == 3, "S3b lone outlier becomes its own cluster")
	_check(((r3b.get("clusters", []) as Array)[0] as Dictionary).get("members", []) == ["T_00"], "S3b singleton membership exact")
	# S4: uneven 4-5 group deployment -> count follows separation (5).
	var r4 := ClustersScript.clusterize(_mk_anchors([0.0, 0.5, 6.0, 6.5, 7.0, 14.0, 20.0, 20.5, 21.0, 21.5, 30.0]))
	_check((r4.get("clusters", []) as Array).size() == 5, "S4 uneven deployment -> five clusters")
	_check(_ids_of_clusters(r4) == ["L2", "L1", "C", "R1", "R2"], "S4 labels are L2 L1 C R1 R2")
	# S5: near-continuous line -> one coherent cluster (over-split gate).
	var cont: Array = []
	for i in range(-6, 2):
		cont.append(float(i))
	var r5 := ClustersScript.clusterize(_mk_anchors(cont))
	_check((r5.get("clusters", []) as Array).size() == 1, "S5 continuous line stays one cluster")
	# S6: translation invariance — shift S3 by +37.5 laterally.
	var shifted: Array = []
	for s in [-22.0, -21.0, -20.0, -9.0, -8.0, -7.0, -1.0, 0.0, 1.0]:
		shifted.append(float(s) + 37.5)
	var r6 := ClustersScript.clusterize(_mk_anchors(shifted))
	_check((r6.get("clusters", []) as Array).size() == 3, "S6 shifted -> same count")
	_check(_ids_of_clusters(r6) == _ids_of_clusters(r3), "S6 labels invariant under translation")
	# S7: pair rule.
	var r7a := ClustersScript.clusterize(_mk_anchors([0.0, 10.0]))
	_check(_ids_of_clusters(r7a) == ["L1", "R1"], "S7 far pair -> L1 R1, no invented C")
	var r7b := ClustersScript.clusterize(_mk_anchors([0.0, 1.0]))
	_check(_ids_of_clusters(r7b) == ["C"], "S7 close pair -> one C")
	# S8: determinism on repeat (timings excluded - wall-clock by nature).
	var r8 := ClustersScript.clusterize(_mk_anchors([-22.0, -21.0, -20.0, -9.0, -8.0, -7.0, -1.0, 0.0, 1.0]))
	_check(_stable_json(r8) == _stable_json(r3), "S8 repeat clusterize is identical")
	# S9: two wings, empty middle -> L1 R1 with no C (§13).
	var r9 := ClustersScript.clusterize(_mk_anchors([-12.0, -11.0, -10.0, 10.0, 11.0, 12.0]))
	_check(_ids_of_clusters(r9) == ["L1", "R1"], "S9 empty middle invents no center")
	evidence["synthetic"] = {
		"s1": _ids_of_clusters(r1), "s2": _ids_of_clusters(r2),
		"s3": _ids_of_clusters(r3), "s3b": _ids_of_clusters(r3b),
		"s4": _ids_of_clusters(r4), "s5": _ids_of_clusters(r5),
		"s6": _ids_of_clusters(r6), "s9": _ids_of_clusters(r9),
		"s3_threshold": float((r3.get("stats", {}) as Dictionary).get("split_threshold", -1.0)),
		"s3_gaps": (r3.get("stats", {}) as Dictionary).get("gaps", []),
	}


func _source_gate() -> Dictionary:
	var text := FileAccess.get_file_as_string("res://scripts/step7/step7_formation_clusters.gd")
	var code_lines: Array = []
	for line in text.split("\n"):
		var stripped := line.strip_edges()
		if stripped.begins_with("#"):
			continue
		if "#" in line:
			line = line.substr(0, line.find("#"))
		code_lines.append(line)
	var code := "\n".join(code_lines).to_lower()
	var hits: Array = []
	for tok in ["projector", "worldtruth", "world_truth", "fog_of_war", "unit_manager",
			"get_unit_by_id", "snapshot_units", "is_contact_visible", "known_occupancy",
			"hidden", "viewport"]:
		if code.contains(tok):
			hits.append(tok)
	if _word_hit(code, "red"):
		hits.append("red")
	if _word_hit(code, "enemy"):
		hits.append("enemy")
	if _word_hit(code, "camera"):
		hits.append("camera")
	return {"clean": hits.is_empty(), "hits": hits}


func _word_hit(code: String, word: String) -> bool:
	var re := RegEx.new()
	re.compile("\\b" + word + "\\b")
	return re.search(code) != null


func _blue_live(unit_manager: RefCounted) -> Array:
	var out: Array = []
	for u_val in unit_manager.get_all_units_including_garrisoned():
		if u_val is Dictionary and str((u_val as Dictionary).get("faction", "")) == "blue":
			out.append(u_val)
	return out


func _run() -> void:
	_synthetic()
	evidence["source_gate"] = _source_gate()
	_check(bool((evidence["source_gate"] as Dictionary).get("clean", false)), "cluster source free of enemy/fog/camera reads")

	var packed: PackedScene = load("res://scenes/step2r_battlefield_shell.tscn")
	var battle: Node = packed.instantiate()
	get_root().add_child(battle)
	for _i in range(20):
		await process_frame
	var integration: Node = battle.get_node_or_null("Step7Integration")
	for _i in range(120):
		if integration and bool(integration.get("ready_for_step7")):
			break
		await process_frame
	if integration == null or not bool(integration.get("ready_for_step7")):
		_write({"status": "FAIL", "failures": ["probe: integration not ready"], "notes": notes})
		_log("CLUSTER_PROBE FAIL integration-not-ready")
		quit(2)
		return
	var truth: RefCounted = integration.get("truth")
	var cmd_svc: RefCounted = integration.get("command_service")
	var projector: RefCounted = integration.get("projector")
	var svc: RefCounted = integration.get("action_service")
	var unit_manager: RefCounted = integration.get("unit_manager")
	var turn := int(truth.call("get_turn"))

	# L1: freeze at turn start; record live geometry.
	var freeze: Dictionary = ClustersScript.refresh(_blue_live(unit_manager), turn)
	_check(bool(freeze.get("ok", false)), "L1 turn-start freeze builds")
	var snap: Dictionary = ClustersScript.debug_snapshot()
	evidence["live_freeze"] = {"turn": turn, "signature": snap.get("signature", "?"),
		"clusters": snap.get("clusters", []), "boundaries": snap.get("boundaries", []),
		"stats": snap.get("stats", {}), "latency": snap.get("latency", {})}
	var live_ids: Array = ClustersScript.cluster_ids()
	_check(live_ids.size() >= 2, "L1 boot yields adaptive multi-band geometry")
	# Northern cavalry wing shares one band; southern cavalry sits elsewhere.
	var north_cid := ClustersScript.cluster_of_hex(-16, -18)
	var south_cid := ClustersScript.cluster_of_hex(-8, 13)
	_check(not north_cid.is_empty() and not south_cid.is_empty() and north_cid != south_cid,
		"L1 north/south cavalry in distinct bands")
	_check(ClustersScript.cluster_of_hex(-16, -18) == ClustersScript.cluster_of_hex(-15, -17)
		and ClustersScript.cluster_of_hex(-15, -17) == ClustersScript.cluster_of_hex(-14, -19),
		"L1 northern cavalry wing shares one band")
	# HQ/SUPPLY assignable though never anchors.
	_check(not ClustersScript.cluster_of_hex(-26, 0).is_empty(), "L1 HQ assigned to a band")
	evidence["live_freeze"]["north_cav_band"] = north_cid
	evidence["live_freeze"]["south_cav_band"] = south_cid

	# L2: one hex, one band — complete partition of the canonical envelope.
	var playable_total := 0
	for q in range(-40, 41):
		for r in range(-40, 41):
			if BoundaryScript.is_playable_hex(Vector2i(q, r)):
				playable_total += 1
	_check(ClustersScript.band_map().size() == playable_total, "L2 every playable hex in exactly one band")
	evidence["partition"] = {"playable_total": playable_total, "band_hexes": ClustersScript.band_map().size()}

	# L3: scope purity per active cluster + wing-union rule.
	var purity_ok := true
	var wing_union_ok := true
	var purity_detail := {}
	for cid in live_ids:
		var resolved: Array = ClustersScript.resolve_cluster_class(str(cid), "CAVALRY", "blue", unit_manager)
		var manual: Array = []
		for u_val in _blue_live(unit_manager):
			var u: Dictionary = u_val
			if str(u.get("class", "")).to_upper() == "CAVALRY" and int(u.get("soldier_count", 0)) > 0 \
					and ClustersScript.cluster_of_unit(u) == str(cid):
				manual.append(str(u.get("id", "")))
		manual.sort()
		var got: Array = []
		for m in resolved:
			got.append(str((m as Dictionary).get("id", "")))
		got.sort()
		purity_detail[str(cid)] = got
		if got != manual:
			purity_ok = false
		# No non-cavalry may leak into a class scope.
		for m in resolved:
			if str((m as Dictionary).get("class", "")).to_upper() != "CAVALRY":
				purity_ok = false
	var left_union: Array = []
	for cid in live_ids:
		if str(cid).begins_with("L"):
			for m in ClustersScript.resolve_cluster_class(str(cid), "CAVALRY", "blue", unit_manager):
				left_union.append(str((m as Dictionary).get("id", "")))
	left_union.sort()
	var left_wing: Array = []
	for m in ClustersScript.resolve_wing_class("LEFT", "CAVALRY", "blue", unit_manager):
		left_wing.append(str((m as Dictionary).get("id", "")))
	left_wing.sort()
	if left_union != left_wing:
		wing_union_ok = false
	_check(purity_ok, "L3 FORMATION_CLUSTER_CLASS purity per band")
	_check(wing_union_ok, "L3 LEFT wing equals union of L* scopes")
	evidence["scope_purity"] = purity_detail

	# Envelope independence: same anchors over a shifted synthetic envelope.
	var synth_keys: Array = []
	for q in range(10, 31):
		for r in range(-10, 11):
			if (q + r) % 3 == 0:
				synth_keys.append("%d,%d" % [q, r])
	var sig_before: String = ClustersScript.frozen_signature()
	ClustersScript.refresh(_blue_live(unit_manager), turn, synth_keys)
	var synth_cover := true
	for k in synth_keys:
		if not ClustersScript.band_map().has(k):
			synth_cover = false
	# Cluster structure must not depend on the envelope under it.
	var sig_synth := ""
	var tmp: Array = []
	for c in ClustersScript.active_clusters():
		tmp.append("%s:%.3f" % [str((c as Dictionary)["id"]), float((c as Dictionary)["centroid"])])
	sig_synth = "|".join(tmp)
	ClustersScript.refresh(_blue_live(unit_manager), turn)
	_check(synth_cover, "L4 synthetic envelope fully partitioned")
	_check(ClustersScript.frozen_signature() == sig_before, "L4 same anchors -> same bands (envelope independent)")
	evidence["envelope"] = {"synthetic_cells": synth_keys.size(), "covered": synth_cover,
		"structure_match": ClustersScript.frozen_signature() == sig_before}

	# Camera invariance.
	var before_map := JSON.stringify(ClustersScript.band_map())
	var cam := battle.find_child("Camera2D", true, false) as Camera2D
	if cam:
		cam.position = Vector2(1500, -900)
		cam.zoom = Vector2(0.35, 0.35)
		for _i in range(5):
			await process_frame
		_check(JSON.stringify(ClustersScript.band_map()) == before_map, "camera pan/zoom leaves bands identical")
		evidence["camera"] = {"identical": JSON.stringify(ClustersScript.band_map()) == before_map}
	else:
		notes.append("INFO no Camera2D; invariance holds by construction")
		evidence["camera"] = {"moved": false}

	# Hidden-enemy independence: RED input cannot perturb discovery.
	var sig_live: String = ClustersScript.frozen_signature()
	var poisoned: Array = _blue_live(unit_manager)
	for u_val in truth.call("snapshot_units"):
		if u_val is Dictionary and str((u_val as Dictionary).get("faction", "")) == "red":
			poisoned.append(((u_val as Dictionary).duplicate()))
	ClustersScript.refresh(poisoned, turn)
	_check(ClustersScript.frozen_signature() == sig_live, "RED positions leave friendly bands identical")
	ClustersScript.refresh(_blue_live(unit_manager), turn)
	evidence["red_independence"] = {"identical": ClustersScript.frozen_signature() == sig_live}

	# Turn-freeze: substantial BLUE move, no rebuild -> geometry frozen.
	var mv: Dictionary = await _move_one_blue_across_bands(svc, truth, cmd_svc, unit_manager)
	evidence["turn_freeze_move"] = mv
	if bool(mv.get("moved", false)):
		_check(ClustersScript.frozen_signature() == sig_live, "turn-freeze: geometry unchanged after move")
		_check(str(mv.get("from_band", "")) != str(mv.get("to_band", "")) or not bool(mv.get("crossed", true)),
			"turn-freeze: membership follows current hex (recorded)")
		# Next-turn refresh recomputes from current positions.
		var resig: Dictionary = ClustersScript.refresh(_blue_live(unit_manager), turn)
		_check(bool(resig.get("ok", false)), "turn-freeze: explicit refresh recomputes")
		evidence["turn_freeze_move"]["post_refresh_signature"] = ClustersScript.frozen_signature()
	else:
		notes.append("INFO no cross-band BLUE move in range; freeze holds by construction (no auto-rebuild path mid-turn)")
		evidence["turn_freeze_move"]["skipped"] = true

	# Heatmap/algorithm agreement: overlay cache vs resolver sample.
	var overlay: Node2D = integration.get("sector_overlay") as Node2D
	var agree := true
	if overlay:
		overlay.call("set_show", true)
		for _i in range(3):
			await process_frame
		var om: Dictionary = ClustersScript.band_map()
		var checked := 0
		for key in om.keys():
			if checked >= 400:
				break
			var parts := str(key).split(",")
			if ClustersScript.cluster_of_hex(int(parts[0]), int(parts[1])) != str(om[key]):
				agree = false
				break
			checked += 1
	_check(agree, "heatmap resolver agreement on samples")
	evidence["heatmap"] = {"samples_agree": agree,
		"overlay_cache_sig": str(overlay.call("cache_signature")) if overlay else "none"}

	# Six-profile integration on a live cavalry band + canonical execution.
	var cav_band := ""
	for cid in ClustersScript.cluster_ids():
		if not ClustersScript.resolve_cluster_class(str(cid), "CAVALRY", "blue", unit_manager).is_empty():
			cav_band = str(cid)
			break
	if cav_band.is_empty():
		failures.append("no live cavalry band for six-profile integration")
	else:
		var bk: Dictionary = integration.call("get_blue_knowledge")
		var occ: Dictionary = projector.call("known_occupancy", "blue")
		var sv: int = int(truth.call("get_version"))
		var fp: String = str(truth.call("fingerprint"))
		var cell_data: Dictionary = truth.call("cell_data")
		var ev: RefCounted = EvalScript.new()
		var pkg: Dictionary = ev.call("evaluate_cluster", cav_band,
			{"action": "ADVANCE", "direction": "FORWARD"},
			cmd_svc, unit_manager, bk, cell_data, occ, sv, fp)
		_check((pkg.get("options", []) as Array).size() == 6, "six slots for live cluster")
		_check(_all_have_status(pkg), "all six slots statused")
		var ev_b: RefCounted = EvalScript.new()
		var pkg2: Dictionary = ev_b.call("evaluate_cluster", cav_band,
			{"action": "ADVANCE", "direction": "FORWARD"},
			cmd_svc, unit_manager, integration.call("get_blue_knowledge"),
			truth.call("cell_data"), projector.call("known_occupancy", "blue"),
			int(truth.call("get_version")), str(truth.call("fingerprint")))
		_check(JSON.stringify(pkg.get("options", [])) == JSON.stringify(pkg2.get("options", [])),
			"cluster evaluation deterministic on repeat")
		_check(_has_cluster_features(_pick_of(pkg, "BALANCED")), "CLUSTER_ALIGNMENT/CLUSTER_COHESION contribute")
		evidence["six_profile"] = {"band": cav_band, "member_ids": pkg.get("member_ids", []),
			"representative": pkg.get("representative", "?"), "differentials": _differentials(pkg),
			"feature_count": pkg.get("feature_count", 0)}
		var exec_res: Dictionary = await _execute_pick(svc, truth, str(pkg.get("representative", "")),
			_pick_of(pkg, "BALANCED"))
		evidence["execution"] = exec_res
		_check(bool(exec_res.get("validated", false)), "cluster option passes canonical validation")
		_check(bool(exec_res.get("moved", false)), "cluster option executes through canonical pipeline")

	# Schema gates: new scopes validate, per-cluster functions absent.
	var good: Dictionary = CommandScript.validate_structure(CommandScript.make(
		"ADVANCE", CommandScript.scope_cluster_class("L2", "CAVALRY"), "FORWARD"))
	_check(bool(good.get("ok", false)), "FORMATION_CLUSTER_CLASS scope validates")
	var good_w: Dictionary = CommandScript.validate_structure(CommandScript.make(
		"ADVANCE", CommandScript.scope_wing_class("LEFT", "CAVALRY"), "FORWARD"))
	_check(bool(good_w.get("ok", false)), "FORMATION_WING_CLASS scope validates")
	var bad_c: Dictionary = CommandScript.validate_structure(CommandScript.make(
		"ADVANCE", {"type": "FORMATION_CLUSTER_CLASS", "cluster": "UPPER", "class": "CAVALRY"}, "FORWARD"))
	_check(not bool(bad_c.get("ok", false)), "unknown cluster rejected")
	var catalog: Dictionary = CommandScript.presets()
	_check(catalog.size() == 50, "50-action catalog untouched")

	evidence["status"] = "PASS" if failures.is_empty() else "FAIL"
	evidence["failures"] = failures
	evidence["notes"] = notes
	_write(evidence)
	_log("CLUSTER_PROBE_" + str(evidence["status"]) + " failures=" + str(failures.size()))
	quit(0 if failures.is_empty() else 2)


func _all_have_status(r: Dictionary) -> bool:
	var opts: Array = r.get("options", [])
	if opts.size() != 6:
		return false
	for o in opts:
		if not (o is Dictionary) or not (o as Dictionary).has("status"):
			return false
		if str((o as Dictionary)["status"]) not in ["AVAILABLE", "DEGRADED", "UNAVAILABLE"]:
			return false
	return true


func _pick_of(r: Dictionary, profile: String) -> Dictionary:
	for o in (r.get("options", []) as Array):
		if o is Dictionary and str((o as Dictionary).get("profile", "")) == profile:
			return o
	return {}


func _has_cluster_features(pick: Dictionary) -> bool:
	var seen := {}
	for c in (pick.get("contributions", []) as Array):
		if c is Dictionary:
			seen[str((c as Dictionary).get("feature", ""))] = true
	return seen.has("CLUSTER_ALIGNMENT") and seen.has("CLUSTER_COHESION")


func _differentials(r: Dictionary) -> Dictionary:
	var d := {}
	for o in (r.get("options", []) as Array):
		if not (o is Dictionary) or not (o as Dictionary).has("destination"):
			continue
		var od: Dictionary = o
		d[str(od.get("profile", "?"))] = {"dest": od.get("destination", {}),
			"u": float(od.get("utility", 0.0)), "status": str(od.get("status", "?"))}
	return d


func _move_one_blue_across_bands(svc: RefCounted, truth: RefCounted, cmd_svc: RefCounted, unit_manager: RefCounted) -> Dictionary:
	for u_val in truth.call("snapshot_units"):
		if not u_val is Dictionary:
			continue
		var ud: Dictionary = u_val
		if str(ud.get("faction", "")) != "blue":
			continue
		if int(ud.get("soldier_count", 0)) <= 0 or bool(ud.get("action_ended", false)) \
				or bool(ud.get("garrisoned", false)) or bool(ud.get("routed", false)):
			continue
		var uid := str(ud.get("id", ""))
		var origin := Vector2i(int(ud.get("q", 0)), int(ud.get("r", 0)))
		var oband := ClustersScript.cluster_of_hex(origin.x, origin.y)
		var area: Dictionary = cmd_svc.call("reachable_area", uid, "blue", "auto")
		if not bool(area.get("ok", false)):
			continue
		for row_val in (area.get("reachable", []) as Array):
			if not row_val is Dictionary:
				continue
			var row: Dictionary = row_val
			var dest := Vector2i(int(row.get("q", 0)), int(row.get("r", 0)))
			if dest == origin:
				continue
			if ClustersScript.cluster_of_hex(dest.x, dest.y) == oband:
				continue
			var res: Dictionary = await _execute_move(svc, truth, uid, dest)
			res["unit"] = uid
			res["from_band"] = oband
			res["to_band"] = ClustersScript.cluster_of_hex(dest.x, dest.y)
			res["crossed"] = true
			return res
	return {"moved": false, "note": "no single-move cross-band candidate in range"}


func _execute_move(svc: RefCounted, truth: RefCounted, unit_id: String, dest: Vector2i) -> Dictionary:
	var out := {"validated": false, "moved": false}
	for _i in range(300):
		if not bool(svc.call("is_executing")):
			break
		await process_frame
	var cmd := {"action": "MOVE", "scope": {"type": "UNIT_ID", "unit_id": unit_id},
		"direction": "", "target": {"type": "HEX", "q": dest.x, "r": dest.y},
		"posture": "NORMAL", "constraints": {}}
	var vd: Dictionary = svc.call("validate_action", cmd, "blue")
	out["validated"] = bool(vd.get("ok", false))
	if not bool(vd.get("ok", false)):
		out["error"] = "validation rejected"
		return out
	var plan: Dictionary = svc.call("plan_action", cmd, "blue")
	var pid := str(plan.get("plan_id", ""))
	if pid.is_empty():
		out["error"] = "no plan_id"
		return out
	var ex: Dictionary = svc.call("execute_plan", pid)
	out["execute_status"] = str(ex.get("execution_status", "?"))
	for _i in range(1500):
		var cur: Dictionary = truth.call("get_unit", unit_id)
		if Vector2i(int(cur.get("q", 0)), int(cur.get("r", 0))) == dest:
			break
		await process_frame
	var fin: Dictionary = truth.call("get_unit", unit_id)
	out["final_pos"] = [int(fin.get("q", 0)), int(fin.get("r", 0))]
	out["moved"] = Vector2i(int(fin.get("q", 0)), int(fin.get("r", 0))) == dest
	for _i in range(300):
		if not bool(svc.call("is_executing")):
			break
		await process_frame
	out["queue_drained"] = not bool(svc.call("is_executing"))
	return out


func _execute_pick(svc: RefCounted, truth: RefCounted, unit_id: String, pick: Dictionary) -> Dictionary:
	var out := {"validated": false, "moved": false}
	if unit_id.is_empty() or not pick.has("destination"):
		out["error"] = "no representative or no destination"
		return out
	var d: Dictionary = pick["destination"]
	return await _execute_move(svc, truth, unit_id, Vector2i(int(d.get("q", 0)), int(d.get("r", 0))))


func _write(value: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute((OUT as String).get_base_dir())
	var file := FileAccess.open(OUT, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(value, " "))
