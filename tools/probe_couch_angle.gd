extends Node3D

## Measures the couched spear during the cavalry charge (MEASUREMENT ONLY):
## pitch (+ up) and yaw (+ to the horse's left) of each rider's spear relative
## to his horse's heading, so the couch pose can be set to point dead ahead.
##   Godot --path <project> --headless res://tools/probe_couch_angle.tscn

const Cavalry3D = preload("res://scripts/visual/civ3d/civ_cavalry3d.gd")
var _g: Node3D
var _t := 0.0
var _done := false

func _ready() -> void:
	_g = Cavalry3D.new()
	add_child(_g)
	_g.call("setup", "cavalry", "blue", 3, 2.6, Vector3(0, 0, -1), 42)
	_g.call("place", [Vector3(-1.5, 0, 0), Vector3(0, 0, 0), Vector3(1.5, 0, 0)])
	_g.call("play_attack")

func _process(delta: float) -> void:
	_t += delta
	if _done or _t < 0.8:
		return
	_done = true
	for att in _g.find_children("*", "BoneAttachment3D", true, false):
		var b := att as BoneAttachment3D
		if b.bone_name != "joint_0":
			continue
		var w: MeshInstance3D = b.get_child(0) as MeshInstance3D
		var d: Vector3 = -w.global_transform.basis.z.normalized() # spear runs along the fist's -Z
		var holder: Node3D = b
		while holder.get_parent() != _g:
			holder = holder.get_parent()
		var fwd: Vector3 = holder.global_transform.basis.z.normalized() # the horse looks down +Z
		var fwd_h := Vector3(fwd.x, 0, fwd.z).normalized()
		var left := Vector3.UP.cross(fwd_h)
		var pitch := rad_to_deg(asin(clampf(d.y, -1.0, 1.0)))
		var yaw := rad_to_deg(atan2(d.dot(left), d.dot(fwd_h)))
		print("[Couch] pitch %.1f deg  yaw %.1f deg" % [pitch, yaw])
	get_tree().quit()
