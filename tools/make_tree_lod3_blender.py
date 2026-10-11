# Bakes a strategy-camera tree LOD (lod3) from each forest pilot LOD2 derivative.
# Visual pipeline only; source GLBs are read, never modified.
#   blender --background --python tools/make_tree_lod3_blender.py -- <dir> <ratio>
# For every <key>_lod2.glb in <dir>: merge coincident vertices (the derivative is
# split per face, which blocks simplification), collapse-decimate every mesh
# to <ratio> of its triangles, write <key>_lod3.glb with the same node layout.
import glob
import os
import sys

import bmesh
import bpy

argv = sys.argv[sys.argv.index("--") + 1:]
DIR, RATIO = argv[0], float(argv[1]) if len(argv) > 1 else 0.25

for src in sorted(glob.glob(os.path.join(DIR, "*_lod2.glb"))):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=src)
    report = []
    for o in [o for o in bpy.data.objects if o.type == "MESH"]:
        t0 = sum(len(p.vertices) - 2 for p in o.data.polygons)
        bm = bmesh.new()
        bm.from_mesh(o.data)
        bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-4)
        bm.to_mesh(o.data)
        bm.free()
        bpy.context.view_layer.objects.active = o
        mod = o.modifiers.new("dec", "DECIMATE")
        mod.ratio = RATIO
        bpy.ops.object.modifier_apply(modifier="dec")
        t1 = sum(len(p.vertices) - 2 for p in o.data.polygons)
        report.append("%s %d->%d" % (o.name, t0, t1))
    out = src.replace("_lod2.glb", "_lod3.glb")
    bpy.ops.export_scene.gltf(filepath=out, export_format="GLB", export_animations=False, export_yup=True)
    print("[LOD3]", os.path.basename(out), "|", ", ".join(report))
