extends SceneTree

## Doctrine sanity: for one live unit per combat class, evaluate ADVANCE
## and report per-profile status/utility + top drivers. Human judges
## whether behavior differs SENSIBLY per doctrine (mission quality gate).

const EvaluatorScript = preload("res://scripts/step7/step7_cavalry_evaluator.gd")

const UNITS := {"CAVALRY": "B_CAV_2", "INFANTRY": "B_INF_1",
	"ARCHER": "B_ARC_1", "SPEARMAN": "B_SPE_1", "SCOUT": "B_SCT_1",
	"SIEGE": "B_SIG_1", "CONSCRIPT": "B_CON_1"}

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var packed: PackedScene = load("res://scenes/step2r_battlefield_shell.tscn")
	var battle: Node = packed.instantiate()
	get_root().add_child(battle)
	for _i in range(20):
		await process_frame
	var integration: Node = battle.get_node_or_null("Step7Integration")
	for _i in range(240):
		if integration and bool(integration.get("ready_for_step7")):
			break
		await process_frame
	for _i in range(30):
		await process_frame
	var command_service: RefCounted = integration.get("command_service")
	var projector: RefCounted = integration.get("projector")
	var truth: RefCounted = integration.get("truth")
	var bk: Dictionary = integration.call("get_blue_knowledge")
	var occ: Dictionary = projector.known_occupancy("blue")
	var grid: Node = integration.get("hex_grid") as Node
	var cell_data: Dictionary = grid.get("cell_data") as Dictionary if grid else {}
	var evaluator: RefCounted = EvaluatorScript.new()
	for cls in UNITS.keys():
		var uid := str(UNITS[cls])
		var pkg: Dictionary = evaluator.evaluate(uid,
			{"action": "ADVANCE", "direction": "FORWARD"},
			command_service, bk, cell_data, occ,
			int(truth.call("get_version")), str(truth.call("fingerprint")))
		if not bool(pkg.get("ok", false)):
			print("DOCTRINE %s %s: EVALUATE FAILED %s" % [cls, uid, str(pkg.get("error", "?"))])
			continue
		var line := "DOCTRINE %s %s [%s]: " % [cls, uid, str(pkg.get("doctrine", "?"))]
		var bits: Array = []
		for o in (pkg.get("options", []) as Array):
			var od: Dictionary = o
			bits.append("%s:%s/%s" % [str(od.get("profile", "?")).left(4),
				str(od.get("status", "?")).left(4),
				str(snappedf(float(od.get("utility", 0.0)), 0.01))])
		print(line + " ".join(bits))
		# Top-utility AVAILABLE pick + its drivers.
		var best := {}
		var best_u := -1e30
		for o in (pkg.get("options", []) as Array):
			var od2: Dictionary = o
			if not str(od2.get("status", "")).to_upper() in ["AVAILABLE", "DEGRADED"]:
				continue
			if float(od2.get("utility", 0.0)) > best_u:
				best_u = float(od2.get("utility", 0.0))
				best = od2
		if not best.is_empty():
			print("  PICK %s dest=%s top+=%s top-=%s" % [str(best.get("profile", "?")),
				JSON.stringify(best.get("destination", {})),
				JSON.stringify(best.get("top_positive", [])).left(160),
				JSON.stringify(best.get("top_negative", [])).left(160)])
	quit(0)
