extends SceneTree

## Audit probe: dump the live BLUE roster, adaptive clusters, wings per
## class, and a friendly_layout sample. No LLM. Evidence JSON to stdout.
## Usage: Godot --headless --path <proj> -s tools/step7_audit_roster.gd

func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed: PackedScene = load("res://scenes/step2r_battlefield_shell.tscn")
	if packed == null:
		print("AUDIT_ROSTER: scene load FAILED")
		quit(2)
		return
	var battle: Node = packed.instantiate()
	get_root().add_child(battle)
	for _i in range(20):
		await process_frame
	var integration: Node = battle.get_node_or_null("Step7Integration")
	for _i in range(180):
		if integration and bool(integration.get("ready_for_step7")):
			break
		await process_frame
	if integration == null or not bool(integration.get("ready_for_step7")):
		print("AUDIT_ROSTER: integration not ready")
		quit(2)
		return
	var um: RefCounted = integration.get("unit_manager")
	var ClustersScript = load("res://scripts/step7/step7_formation_clusters.gd")
	var ResolverScript = load("res://scripts/step7/step7_scope_resolver.gd")
	var out := {}
	var roster: Array = []
	for u in um.call("get_all_units_including_garrisoned"):
		if u is Dictionary and str((u as Dictionary).get("faction", "")) == "blue":
			var d: Dictionary = u
			roster.append({"id": str(d.get("id", "")), "class": str(d.get("class", "")),
				"q": int(d.get("q", 0)), "r": int(d.get("r", 0)),
				"cluster": str(ClustersScript.cluster_of_unit(d)),
				"soldiers": int(d.get("soldiers", d.get("soldier_count", 0)))})
	roster.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["id"]) < str(b["id"]))
	out["blue_roster"] = roster
	out["cluster_ids"] = ClustersScript.cluster_ids()
	out["frozen_sig"] = ClustersScript.frozen_signature()
	out["extreme_left"] = ClustersScript.extreme_left()
	out["extreme_right"] = ClustersScript.extreme_right()
	var per_class := {}
	for cls in ["CAVALRY", "INFANTRY", "ARCHER", "SPEARMAN", "SCOUT", "SIEGE", "CONSCRIPT", "HQ", "SUPPLY"]:
		var units: Array = ResolverScript.units_of_class(cls, um)
		var ids: Array = []
		for u in units:
			ids.append(str((u as Dictionary).get("id", "")))
		ids.sort()
		per_class[cls] = {"ids": ids, "wings": ResolverScript.wings_of(units)}
	out["per_class"] = per_class
	print("AUDIT_ROSTER_BEGIN")
	print(JSON.stringify(out))
	print("AUDIT_ROSTER_END")
	quit(0)
