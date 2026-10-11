extends SceneTree

## CONTEXTUAL_BRAIN_S0C: sample 96 NEW TRAIN-split EpisodeSpecs with Track B's sampler.
##   godot --headless --path . -s res://tools/contextual_brain/sample_s0c_specs.gd -- --out=<dir> --per-family=24
## Seeds: 5100..5123, 6100..6123, 7100..7123, 8100..8123 (completely disjoint from S0/S0B).
## Only split "train" (maps BF01/02/04/07) is ever requested; validation/test are never touched.

const Spec = preload("res://scripts/episodes/episode_spec.gd")
const FAMILIES := ["nominal", "mild", "broad", "counterfactual_valid"]


func _initialize() -> void:
	var out := ""
	var n := 24
	for a in OS.get_cmdline_user_args():
		if str(a).begins_with("--out="):
			out = str(a).substr(6)
		if str(a).begins_with("--per-family="):
			n = int(str(a).substr(13))
	if out.is_empty():
		printerr("need --out=<dir>")
		quit(1)
		return
	var ids: Array = []
	for fi in range(FAMILIES.size()):
		for k in range(n):
			var seed := 5100 + fi * 1000 + k
			var spec := Spec.sample(FAMILIES[fi], "train", seed)
			if spec.is_empty() or str(spec["split"]) != "train" or not (Spec.SPLIT_MAPS["train"] as Array).has(spec["map"]["id"]):
				printerr("sample failed or not train: ", FAMILIES[fi], " ", seed)
				quit(1)
				return
			var path := "%s/%s_%d.json" % [out, FAMILIES[fi], seed]
			if not Spec.save(spec, path):
				printerr("save failed ", path)
				quit(1)
				return
			ids.append(spec["episode_id"])
	print("S0C_SPECS_OK n=%d" % ids.size())
	quit(0)
