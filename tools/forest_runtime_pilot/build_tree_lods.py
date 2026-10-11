"""Blender background builder for forest-only runtime GLB derivatives.

Run: blender -b -t 4 --python build_tree_lods.py -- <project> [key]
The source GLBs are imported read-only. Each output is a separate GLB.
"""
import bpy
import hashlib
import json
import sys
from pathlib import Path


FILES = {
    "tall_pine": "01-tall-straight-pine.glb",
    "wind_pine": "02-windswept-mountain-pine.glb",
    "conifer": "03-broad-layered-conifer.glb",
    "compact_pine": "04-compact-hill-pine.glb",
    "dead_tree": "05-sparse-dead-tree.glb",
    "broadleaf": "06-broadleaf-deciduous-tree.glb",
    "cypress": "07-tall-cypress-like-tree.glb",
    "sapling": "08-sapling-cluster.glb",
}
RATIOS = {
    "lod1": {"wood": 0.22, "foliage": 0.075},
    "lod2": {"wood": 0.055, "foliage": 0.012},
}


def triangles():
    return sum(len(o.data.polygons) for o in bpy.data.objects if o.type == "MESH")


def clear():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for mesh in list(bpy.data.meshes):
        if mesh.users == 0:
            bpy.data.meshes.remove(mesh)


def run():
    args = sys.argv[sys.argv.index("--") + 1 :]
    project = Path(args[0])
    chosen = args[1] if len(args) > 1 else None
    source_dir = project / "assets/map_composition_v0/source_glb/trees"
    out_dir = project / "assets/map_composition_v0/forest_runtime_pilot"
    out_dir.mkdir(parents=True, exist_ok=True)
    report = {}
    for key, filename in FILES.items():
        if chosen and key != chosen:
            continue
        source = source_dir / filename
        source_hash = hashlib.sha256(source.read_bytes()).hexdigest()
        report[key] = {"source": str(source), "sha256": source_hash, "lods": {}}
        for lod, ratios in RATIOS.items():
            clear()
            bpy.ops.import_scene.gltf(filepath=str(source))
            before = triangles()
            per_mesh = []
            for obj in list(bpy.data.objects):
                if obj.type != "MESH":
                    continue
                original = len(obj.data.polygons)
                group = "foliage" if "foliage" in obj.name.lower() else "wood"
                if original > 20:
                    bpy.context.view_layer.objects.active = obj
                    obj.select_set(True)
                    mod = obj.modifiers.new("ForestLOD", "DECIMATE")
                    mod.ratio = ratios[group]
                    mod.use_collapse_triangulate = True
                    bpy.ops.object.modifier_apply(modifier=mod.name)
                    obj.select_set(False)
                per_mesh.append({"name": obj.name, "group": group,
                                 "before": original, "after": len(obj.data.polygons)})
            dest = out_dir / f"{key}_{lod}.glb"
            bpy.ops.export_scene.gltf(filepath=str(dest), export_format="GLB",
                                      export_apply=False)
            report[key]["lods"][lod] = {"path": str(dest), "triangles_before": before,
                                           "triangles_after": triangles(), "meshes": per_mesh,
                                           "sha256": hashlib.sha256(dest.read_bytes()).hexdigest()}
            print("FOREST_LOD", key, lod, before, triangles(), flush=True)
    (out_dir / "build_report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")


if __name__ == "__main__":
    run()
