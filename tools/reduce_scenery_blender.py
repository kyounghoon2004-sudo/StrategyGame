# Reduces the scenery meshes exported by tools/export_scenery_meshes.gd for the
# strategy camera. Visual pipeline only; reads strategy_lod/src, writes strategy_lod/out.
#   blender --background --python tools/reduce_scenery_blender.py -- <src dir> <out dir>
# Per mesh: merge coincident vertices (AI exports are split per face, which
# blocks simplification), then collapse-decimate: >8k tris -> 20 %, 3k-8k -> 30 %,
# smaller -> 50 %, never below 400 triangles.
import glob
import os
import sys

import bmesh
import bpy

argv = sys.argv[sys.argv.index("--") + 1:]
SRC, OUT = argv[0], argv[1]
os.makedirs(OUT, exist_ok=True)

for src in sorted(glob.glob(os.path.join(SRC, "*.glb"))):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=src)
    rep = []
    for o in [o for o in bpy.data.objects if o.type == "MESH"]:
        t0 = sum(len(p.vertices) - 2 for p in o.data.polygons)
        bm = bmesh.new()
        bm.from_mesh(o.data)
        bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-4)
        bm.to_mesh(o.data)
        bm.free()
        ratio = 0.2 if t0 > 8000 else (0.3 if t0 > 3000 else 0.5)
        ratio = max(ratio, min(1.0, 400.0 / max(1, t0)))
        bpy.context.view_layer.objects.active = o
        mod = o.modifiers.new("dec", "DECIMATE")
        mod.ratio = ratio
        bpy.ops.object.modifier_apply(modifier="dec")
        rep.append("%d->%d" % (t0, sum(len(p.vertices) - 2 for p in o.data.polygons)))
    out = os.path.join(OUT, os.path.basename(src))
    bpy.ops.export_scene.gltf(filepath=out, export_format="GLB", export_animations=False, export_yup=True)
    print("[REDUCE]", os.path.basename(src), " ".join(rep))
