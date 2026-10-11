extends SceneTree
## Presentation cost probe (visual frontend): boot cost, node count, per-frame
## process time and static memory of the battle shell. Run headless to see
## what training / self-play pays for the visual layer.
## Boots the production battle shell (sandbox flag like every test scene),
## runs N frames, reports boot time, node counts and per-frame process cost.
## Usage: godot --headless --path <iso> --script res://tools/visual_contract/headless_cost_probe.gd -- <out.json> [sandbox=1]

var _shell: Node
var _frame: int = 0
var _t_boot0: int = 0
var _boot_ms: float = 0.0
var _out: String = ""
var _samples: Array = []
const FRAMES := 240

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	_out = args[0] if args.size() > 0 else "user://probe.json"
	var sandbox: bool = not (args.size() > 1 and args[1] == "0")
	_t_boot0 = Time.get_ticks_usec()
	var ps: PackedScene = load("res://scenes/step2r_battlefield_shell.tscn")
	_shell = ps.instantiate()
	_shell.set("is_step0_sandbox", sandbox)
	root.add_child(_shell)
	_boot_ms = float(Time.get_ticks_usec() - _t_boot0) / 1000.0

func _count(n: Node, acc: Dictionary) -> void:
	acc["total"] = int(acc.get("total", 0)) + 1
	var c := n.get_class()
	var by: Dictionary = acc["by_class"]
	by[c] = int(by.get(c, 0)) + 1
	if n.is_processing():
		acc["processing"] = int(acc.get("processing", 0)) + 1
		var pl: Array = acc["processing_nodes"]
		if pl.size() < 80:
			pl.append(str(n.get_path()).replace("/root/", ""))
	for ch in n.get_children():
		_count(ch, acc)

func _process(_d: float) -> bool:
	_frame += 1
	if _frame > 30:
		_samples.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	if _frame >= FRAMES:
		var acc := {"by_class": {}, "processing_nodes": []}
		_count(_shell, acc)
		var s := 0.0
		for v in _samples:
			s += float(v)
		var by: Dictionary = acc["by_class"]
		var top: Array = []
		for k in by.keys():
			top.append([k, by[k]])
		top.sort_custom(func(a, b): return a[1] > b[1])
		var rep := {
			"boot_ms": _boot_ms,
			"frames": _frame,
			"avg_process_ms": s / maxf(1.0, float(_samples.size())),
			"nodes_total": acc["total"],
			"nodes_processing": acc.get("processing", 0),
			"processing_nodes": acc["processing_nodes"],
			"top_classes": top.slice(0, 18),
			"static_mem_mb": Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
			"objects": Performance.get_monitor(Performance.OBJECT_COUNT),
			"resources": Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT),
			"units": (_shell.get("unit_renderer").call("get_all_units") as Array).size(),
		}
		var f := FileAccess.open(_out, FileAccess.WRITE)
		f.store_string(JSON.stringify(rep, "  "))
		f.close()
		print("[PROBE] ", JSON.stringify(rep))
		return true
	return false
