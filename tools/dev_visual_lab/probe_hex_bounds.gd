extends SceneTree
const L = preload("res://scripts/visual/map_composition_v0/map_composition_library.gd")
func _initialize():
 for key in L.TREES:
  var b = L.bounds(key)
  var doc = GLTFDocument.new()
  var state = GLTFState.new()
  doc.append_from_file(OS.get_environment("SG_FULL_MAP_OUT").path_join("optimized/"+key+"_far.glb"),state)
  var n = doc.generate_scene(state)
  var stack = [n]
  while not stack.is_empty():
   var a = stack.pop_back()
   if a is MeshInstance3D: print(key," SOURCE ",b["max"]-b["min"]," DERIV ",a.mesh.get_aabb().size)
   stack.append_array(a.get_children())
  n.free()
 quit()
