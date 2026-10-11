class_name Cloud1LiveMount
extends Node

## CLOUD STEP 1B — Live mount (additive; zero changes to canonical scenes).
##
## Sits beside the instanced Step2R battlefield in the Step-1 test scene,
## waits for the shell + Step7Integration bootstrap, then mounts:
##   Cloud1LiveBridge  (same live authorities, no duplicate simulation)
##   Cloud1PreviewOverlay (child of the shell, world space)
##   Cloud1LiveExecutor   (sequential animated execution)
##   Cloud1Dock           (right-side panel in the shell's hud_layer)
## Input coexistence comes free: the shell's _is_click_over_hud() ignores any
## click whose screen position falls inside a visible hud_layer Control, which
## includes this dock.

const BridgeCls = preload("res://scripts/cloud1/cloud1_live_bridge.gd")
const ExecutorCls = preload("res://scripts/cloud1/cloud1_live_executor.gd")
const DockCls = preload("res://scripts/cloud1/cloud1_dock.gd")
const OverlayCls = preload("res://scripts/cloud1/cloud1_preview_overlay.gd")

var shell: Node = null
var det: Node = null
var bridge: RefCounted = null
var executor: ExecutorCls = null
var overlay: OverlayCls = null
var dock: DockCls = null

var mount_ready := false
var mount_error := ""


func _ready() -> void:
	print("[Cloud1Mount] _ready called")
	call_deferred("_bootstrap")


func is_ready() -> bool:
	return mount_ready and dock != null and bridge != null and bridge.is_loaded()


func _bootstrap() -> void:
	print("[Cloud1Mount] _bootstrap starting")
	for _i in range(600):
		shell = get_parent().get_node_or_null("Battle")
		if shell != null and shell.get("unit_manager") != null and shell.get("hud_layer") != null:
			break
		await get_tree().process_frame
	print("[Cloud1Mount] shell wait done, shell=%s" % [str(shell != null)])
	if shell == null or shell.get("unit_manager") == null or shell.get("hud_layer") == null:
		mount_error = "Battle dependencies not found."
		push_warning("[Cloud1Mount] %s" % mount_error)
		print("[Cloud1Mount] %s" % mount_error)
		return
	det = shell.get_node_or_null("Step7Integration")
	for _j in range(600):
		if det != null and bool(det.get("ready_for_step7")):
			break
		await get_tree().process_frame
	print("[Cloud1Mount] det wait done, det=%s, ready=%s" % [str(det != null), str(bool(det.get("ready_for_step7"))) if det != null else "false"])
	if det == null or not bool(det.get("ready_for_step7")):
		mount_error = "Step7Integration not ready."
		push_warning("[Cloud1Mount] %s" % mount_error)
		print("[Cloud1Mount] %s" % mount_error)
		return
	bridge = BridgeCls.new()
	if not bridge.bind(shell, det):
		mount_error = "Bridge binding failed."
		push_warning("[Cloud1Mount] %s" % mount_error)
		print("[Cloud1Mount] %s" % mount_error)
		return
	overlay = OverlayCls.new()
	overlay.name = "Cloud1PreviewOverlay"
	overlay.z_index = 22
	shell.add_child(overlay)
	executor = ExecutorCls.new()
	executor.name = "Cloud1LiveExecutor"
	add_child(executor)
	executor.bind(bridge)
	dock = DockCls.new()
	var hud: CanvasLayer = shell.get("hud_layer") as CanvasLayer
	hud.add_child(dock)
	print("[Cloud1Mount] calling dock.setup")
	dock.setup(bridge, executor, overlay)
	# A roster reset (dock Apply button, script, or a future model-issued reset)
	# must rebuild the console pickers from authoritative truth — never leave
	# stale rows behind in the research UI.
	if shell.has_signal("roster_rebuilt"):
		shell.connect("roster_rebuilt", Callable(dock, "refresh_observation"))
	print("[Cloud1Mount] dock.setup finished")
	mount_ready = true
	print("[Cloud1Mount] shared interface mounted | live=%s | turn=%d" % [str(bridge.scenario_id()), int(bridge.get_manager().get_current_turn())])
