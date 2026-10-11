extends SceneTree

## CONTEXTUAL_BRAIN_S0: sample TRAIN-split EpisodeSpecs with Track B's own sampler.
##   godot --headless --path . -s res://tools/contextual_brain/sample_train_specs.gd -- --out=<dir> --per-family=12
## Only split "train" (maps BF01/02/04/07) is ever requested; validation/test are never touched.

const Spec = preload("res://scripts/episodes/episode_spec.gd")
const FAMILIES := ["nominal", "mild", "broad", "counterfactual_valid"]


func _initialize() -> void:
	var out := ""
	var n := 12
	for a in OS.get_cmdline_user_args():
		if str(a).begins_with("--out="):
			out = str(a).substr(6)
		if str(a).begins_with("--per-family="):
			n = int(str(a).substr(13))
	var ids: Array = []
	for fi in range(FAMILIES.size()):
		for k in range(n):
			var seed := 5000 + fi * 1000 + k
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
	print("S0_SPECS_OK n=%d" % ids.size())
	quit(0)
