# Converts Mixamo FBX clips (skinless) onto the X Bot rig and exports ONE glb
# that carries every clip as a named action. Visual pipeline only.
# Usage:
#   blender --background --python tools/mixamo_pack_to_glb.py -- <xbot.fbx> <out.glb> <clip.fbx> [<clip.fbx> ...]
import os
import sys

import bpy

argv = sys.argv[sys.argv.index("--") + 1:]
XBOT, OUT, CLIPS = argv[0], argv[1], argv[2:]


def armature_of(objs):
    return next(o for o in objs if o.type == "ARMATURE")


bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.fbx(filepath=XBOT)
xbot = armature_of(bpy.data.objects)
if xbot.animation_data and xbot.animation_data.action:
    xbot.animation_data.action = None
xbot.animation_data_create()

done = []
for path in CLIPS:
    before = set(bpy.data.objects)
    bpy.ops.import_scene.fbx(filepath=path)
    new = [o for o in bpy.data.objects if o not in before]
    src = armature_of(new)
    act = src.animation_data.action
    name = os.path.splitext(os.path.basename(path))[0].replace(" ", "_").replace("(", "").replace(")", "")
    act.name = name
    act.use_fake_user = True
    # an NLA strip per action so the exporter writes each one as its own clip
    track = xbot.animation_data.nla_tracks.new()
    track.name = name
    track.strips.new(name, int(act.frame_range[0]), act)
    track.mute = True
    for o in new:
        bpy.data.objects.remove(o, do_unlink=True)
    done.append((name, act.frame_range[:]))

bpy.context.scene.render.fps = 30
bpy.ops.export_scene.gltf(filepath=OUT, export_format="GLB", export_animations=True,
                          export_animation_mode="NLA_TRACKS", export_skins=True,
                          export_apply=False, export_yup=True)
for n, fr in done:
    print("[MIXAMO] clip", n, "frames", fr)
print("[MIXAMO] wrote", OUT)
