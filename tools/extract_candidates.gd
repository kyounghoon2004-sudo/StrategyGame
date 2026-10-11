extends SceneTree

const SimControllerCls = preload("res://scripts/sim/sim_controller.gd")
const OpportunityCls = preload("res://scripts/cloud2/cloud2_opportunity.gd")

func _init():
	var args = OS.get_cmdline_args()
	var in_file = ""
	var out_file = ""
	for i in range(args.size()):
		if args[i] == "--in" and i + 1 < args.size():
			in_file = args[i + 1]
		if args[i] == "--out" and i + 1 < args.size():
			out_file = args[i + 1]

	if in_file == "":
		print("Missing --in argument")
		quit(1)
		return

	var f = FileAccess.open(in_file, FileAccess.READ)
	if f == null:
		print("Could not open ", in_file)
		quit(1)
		return
		
	var json_str = f.get_as_text()
	f.close()
	var parser = JSON.new()
	var err = parser.parse(json_str)
	if err != OK:
		print("JSON parse error")
		quit(1)
		return
		
	var batch = parser.data
	var results = []
	var sim = SimControllerCls.new()
	
	for req in batch:
		var load_res = sim.load_scenario(req.get("scenario", {}))
		if not load_res.get("ok", false):
			print("Load failed for req ", req.get("id"), ": ", load_res)
			continue
			
		var res_item = {"id": req.get("id"), "sides": {}}
		
		for side in ["red", "blue"]:
			var obs = sim.build_knowledge(side)
			var ready = []
			var own_forces = obs.get("ledger", {}).get("own_forces", [])
			for u in own_forces:
				if str(u.get("status", "")) == "ready" or not u.has("status") or str(u.get("action_ended", false)) == "false":
					# Sometimes status is missing but action_ended is present
					if u.has("action_ended") and bool(u.get("action_ended")): continue
					ready.append(str(u.get("id", u.get("unit_id", ""))))
					
			var attacks_all = OpportunityCls.legal_attacks(sim, ready, obs, side)
			var units_data = []
			
			for u in own_forces:
				if u.has("action_ended") and bool(u.get("action_ended")): continue
				var uid = str(u.get("id", u.get("unit_id", "")))
				var area = OpportunityCls.reachable(sim, uid, "auto", side)
				
				var u_attacks = []
				for a in attacks_all:
					if str(a.get("attacker_id", "")) == uid:
						u_attacks.append(a)
						
				units_data.append({
					"unit_id": uid,
					"unit_class": str(u.get("class", "INFANTRY")).to_upper(),
					"q": u.get("q", 0),
					"r": u.get("r", 0),
					"reachable": area.get("reachable", []),
					"attacks": u_attacks
				})
				
			res_item["sides"][side] = {
				"obs": obs,
				"units": units_data
			}
		results.append(res_item)
		sim.reset_episode()
			
	var fout = FileAccess.open(out_file, FileAccess.WRITE)
	fout.store_string(JSON.stringify(results))
	fout.close()
	quit(0)
