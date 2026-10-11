# Rigs the supplied horse GLB (no skeleton) for the CIV3D cavalry. Visual pipeline only.
#   blender --background --python tools/rig_horse_blender.py -- <in.glb> <out.glb> [target_tris]
# 1. decimate to ~target_tris  2. build a quadruped armature from measured
# landmarks (glTF space: +Y up, horse faces +Z, its left = +X)  3. distance-based
# skin weights with side / region masks (bone heat fails on loose armour and
# tassels)  4. export a skinned glb. Animation is generated in Godot.
import sys

import bmesh
import bpy
import numpy as np
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:]
SRC, OUT = argv[0], argv[1]
TARGET_TRIS = int(argv[2]) if len(argv) > 2 else 14000
# optional separate head + neck model (own scale / position): fitted onto the
# horse, replaces its head and upper neck, and rides RIGIDLY on neck1
HEAD = argv[3] if len(argv) > 3 else ""
HEAD_TRIS = 6000


def g2b(x, y, z):
    """glTF (x, y, z) -> Blender (x, -z, y)."""
    return Vector((x, -z, y))


def to_gltf(mesh):
    return np.array([(v.co.x, v.co.z, -v.co.y) for v in mesh.data.vertices], dtype=np.float64)


def umeyama(src, dst):
    """Similarity (s, R, t) minimising |s R src + t - dst|."""
    mu_s, mu_d = src.mean(0), dst.mean(0)
    xs, xd = src - mu_s, dst - mu_d
    cov = xd.T @ xs / len(src)
    U, S, Vt = np.linalg.svd(cov)
    D = np.eye(3)
    if np.linalg.det(U) * np.linalg.det(Vt) < 0:
        D[2, 2] = -1
    R = U @ D @ Vt
    s = np.trace(np.diag(S) @ D) / xs.var(0).sum()
    return s, R, mu_d - s * R @ mu_s


def replace_head(horse, path):
    from mathutils import kdtree
    H = to_gltf(horse)
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    parts = [o for o in bpy.data.objects if o not in before and o.type == "MESH"]
    bpy.ops.object.select_all(action="DESELECT")
    for o in parts:
        o.select_set(True)
    bpy.context.view_layer.objects.active = parts[0]
    if len(parts) > 1:
        bpy.ops.object.join()
    head = bpy.context.view_layer.objects.active
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    t0 = sum(len(p.vertices) - 2 for p in head.data.polygons)
    dec = head.modifiers.new("dec", "DECIMATE")
    dec.ratio = min(1.0, HEAD_TRIS / max(1, t0))
    bpy.ops.object.modifier_apply(modifier="dec")
    G = to_gltf(head)
    # landmark start: nose tip (max z) and ear top (max y of the front half)
    hh = H[H[:, 2] > 0.30]
    nose_h, ear_h = hh[hh[:, 2].argmax()], hh[hh[:, 1].argmax()]
    gf = G[G[:, 2] > 0.0]
    nose_g, ear_g = G[G[:, 2].argmax()], gf[gf[:, 1].argmax()]
    s = np.linalg.norm(nose_h - ear_h) / np.linalg.norm(nose_g - ear_g)
    R = np.eye(3)
    t = nose_h - s * nose_g
    # trimmed ICP of the head part onto the horse's head + neck surface
    tgt = H[(H[:, 2] > 0.12) & (H[:, 1] > -0.05)]
    kd = kdtree.KDTree(len(tgt))
    for i, c in enumerate(tgt):
        kd.insert(Vector(c), i)
    kd.balance()
    rng = np.random.default_rng(3)
    srcp = gf[rng.choice(len(gf), min(3000, len(gf)), replace=False)]
    for it in range(40):
        P = (s * (R @ srcp.T)).T + t
        nn = np.array([kd.find(Vector(p))[1] for p in P])
        dist = np.linalg.norm(P - tgt[nn], axis=1)
        keep = dist < np.quantile(dist, 0.8)
        s, R, t = umeyama(srcp[keep], tgt[nn][keep])
    rms = float(np.sqrt((dist[keep] ** 2).mean()))
    print("[HORSE] head fit scale %.3f rms %.4f tris %d -> %d" % (s, rms, t0, sum(len(p.vertices) - 2 for p in head.data.polygons)))
    for v in head.data.vertices:
        g = np.array((v.co.x, v.co.z, -v.co.y))
        n = s * (R @ g) + t
        v.co = g2b(*n)
    # drop the horse's own head / upper neck and any surface the new piece covers
    Gn = to_gltf(head)
    kd2 = kdtree.KDTree(len(Gn))
    for i, c in enumerate(Gn):
        kd2.insert(Vector(c), i)
    kd2.balance()
    near = np.array([kd2.find(Vector(c))[2] < 0.012 for c in H])
    gone = (H[:, 2] > 0.30) | (near & (H[:, 2] > 0.10))
    bm = bmesh.new()
    bm.from_mesh(horse.data)
    bm.verts.ensure_lookup_table()
    kill = [f for f in bm.faces if all(gone[v.index] for v in f.verts)]
    bmesh.ops.delete(bm, geom=kill, context="FACES")
    bm.to_mesh(horse.data)
    bm.free()
    print("[HORSE] removed", len(kill), "horse faces under the new head")
    grp = head.vertex_groups.new(name="HEADPART")
    grp.add([v.index for v in head.data.vertices], 1.0, "REPLACE")
    bpy.ops.object.select_all(action="DESELECT")
    head.select_set(True)
    horse.select_set(True)
    bpy.context.view_layer.objects.active = horse
    bpy.ops.object.join()
    return horse


FX, HX = 0.09, 0.09  # front / hind leg lateral offsets
# name: (head glTF, tail glTF, parent, region)
BONES = {
    "root": ((0, -0.45, 0.0), (0, -0.30, 0.0), None, "body"),
    "hips": ((0, 0.12, -0.20), (0, 0.14, -0.03), "root", "body"),
    "spine": ((0, 0.14, -0.03), (0, 0.13, 0.15), "hips", "body"),
    "saddle": ((0, 0.21, 0.02), (0, 0.30, 0.02), "spine", "none"),
    "neck1": ((0, 0.15, 0.17), (0, 0.27, 0.29), "spine", "neck"),
    "neck2": ((0, 0.27, 0.29), (0, 0.37, 0.39), "neck1", "neck"),
    "head": ((0, 0.37, 0.39), (0, 0.20, 0.50), "neck2", "neck"),
    "tail1": ((0, 0.18, -0.34), (0, 0.02, -0.40), "hips", "tail"),
    "tail2": ((0, 0.02, -0.40), (0, -0.30, -0.43), "tail1", "tail"),
}
for side, sx in (("L", 1.0), ("R", -1.0)):
    fx, hx = FX * sx, HX * sx
    BONES.update({
        f"f_upper.{side}": ((fx, 0.05, 0.23), (fx, -0.09, 0.215), "spine", f"fleg.{side}"),
        f"f_fore.{side}": ((fx, -0.09, 0.215), (fx, -0.25, 0.197), f"f_upper.{side}", f"fleg.{side}"),
        f"f_cannon.{side}": ((fx, -0.25, 0.197), (fx, -0.38, 0.197), f"f_fore.{side}", f"fleg.{side}"),
        f"f_hoof.{side}": ((fx, -0.38, 0.197), (fx, -0.45, 0.215), f"f_cannon.{side}", f"fleg.{side}"),
        f"h_thigh.{side}": ((hx, 0.09, -0.23), (hx, -0.11, -0.20), "hips", f"hleg.{side}"),
        f"h_gaskin.{side}": ((hx, -0.11, -0.20), (hx, -0.25, -0.27), f"h_thigh.{side}", f"hleg.{side}"),
        f"h_cannon.{side}": ((hx, -0.25, -0.27), (hx, -0.38, -0.26), f"h_gaskin.{side}", f"hleg.{side}"),
        f"h_hoof.{side}": ((hx, -0.38, -0.26), (hx, -0.45, -0.24), f"h_cannon.{side}", f"hleg.{side}"),
    })


def main():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=SRC)
    meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    bpy.context.view_layer.objects.active = meshes[0]
    for o in meshes:
        o.select_set(True)
    if len(meshes) > 1:
        bpy.ops.object.join()
    mesh = bpy.context.view_layer.objects.active
    # bake the node transform into the vertices so mesh space == glTF space
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    # NOTE: merging the split source before decimating collapses the layered
    # armour into shards; decimate the source as-is and build connectivity from
    # spatial proximity instead (see below).
    tris0 = sum(len(p.vertices) - 2 for p in mesh.data.polygons)
    ratio = min(1.0, TARGET_TRIS / max(1, tris0))
    # The tail hair is thin strands: decimated as hard as the body it turns into
    # flat shards when it streams at the gallop. Split it off, keep 2.5x more of it.
    bm = bmesh.new()
    bm.from_mesh(mesh.data)
    tail_faces = []
    for f in bm.faces:
        c = f.calc_center_median()  # Blender (x, -z_gltf, y_gltf)
        if -c.y < -0.34 and abs(c.x) < 0.07 and c.z < 0.22:
            tail_faces.append(f.index)
    print("[HORSE] tail faces", len(tail_faces))
    bm.free()
    tail = None
    if tail_faces:
        bpy.ops.object.mode_set(mode="EDIT")
        bpy.ops.mesh.select_all(action="DESELECT")
        bpy.ops.object.mode_set(mode="OBJECT")
        tail_idx = set(tail_faces)
        for p in mesh.data.polygons:
            p.select = p.index in tail_idx
        bpy.ops.object.mode_set(mode="EDIT")
        bpy.ops.mesh.separate(type="SELECTED")
        bpy.ops.object.mode_set(mode="OBJECT")
        tail = [o for o in bpy.data.objects if o.type == "MESH" and o.name != mesh.name][0]
        print("[HORSE] tail object", tail.name, tail.type, len(tail.data.polygons), "body", mesh.name, len(mesh.data.polygons))
    dec = mesh.modifiers.new("dec", "DECIMATE")
    dec.ratio = ratio
    bpy.context.view_layer.objects.active = mesh
    bpy.ops.object.modifier_apply(modifier="dec")
    if tail is not None:
        bpy.context.view_layer.objects.active = tail
        tdec = tail.modifiers.new("dec", "DECIMATE")
        tdec.ratio = min(1.0, ratio * 2.5)
        bpy.ops.object.modifier_apply(modifier="dec")
        bpy.ops.object.select_all(action="DESELECT")
        tail.select_set(True)
        mesh.select_set(True)
        bpy.context.view_layer.objects.active = mesh
        bpy.ops.object.join()
    tris1 = sum(len(p.vertices) - 2 for p in mesh.data.polygons)
    print("[HORSE] tris", tris0, "->", tris1)
    if HEAD:
        mesh = replace_head(mesh, HEAD)

    # armature
    bpy.ops.object.armature_add(location=(0, 0, 0))
    arm = bpy.context.object
    arm.name = "HorseRig"
    bpy.ops.object.mode_set(mode="EDIT")
    eb = arm.data.edit_bones
    for b in list(eb):
        eb.remove(b)
    for name, (h, t, parent, _r) in BONES.items():
        b = eb.new(name)
        b.head = g2b(*h)
        b.tail = g2b(*t)
        b.roll = 0.0
    for name, (_h, _t, parent, _r) in BONES.items():
        if parent:
            eb[name].parent = eb[parent]
            eb[name].use_connect = False
    bpy.ops.object.mode_set(mode="OBJECT")

    # distance-based weights (glTF space)
    names = [n for n in BONES if BONES[n][3] != "none"]
    heads = np.array([BONES[n][0] for n in names], dtype=np.float64)
    tails = np.array([BONES[n][1] for n in names], dtype=np.float64)
    regions = [BONES[n][3] for n in names]
    co_v = np.array([(v.co.x, v.co.z, -v.co.y) for v in mesh.data.vertices], dtype=np.float64)  # -> glTF
    # The source is a triangle soup (vertices split at every UV seam). Weld
    # coincident vertices for CONNECTIVITY only (UVs stay untouched): islands,
    # smoothing and weights live on welded nodes, so seam twins always share
    # one weight set and can never tear apart.
    keys = np.round(co_v / 2e-5).astype(np.int64)
    _, first, wid = np.unique(keys, axis=0, return_index=True, return_inverse=True)
    wid = wid.reshape(-1)
    co = co_v[first]
    print("[HORSE] welded", len(co_v), "->", len(co))
    ab = tails - heads
    ap = co[:, None, :] - heads[None, :, :]
    t = np.clip((ap * ab[None]).sum(-1) / (ab * ab).sum(-1)[None], 0.0, 1.0)
    closest = heads[None] + t[..., None] * ab[None]
    d = np.linalg.norm(co[:, None, :] - closest, axis=-1)
    x, y, z = co[:, 0], co[:, 1], co[:, 2]
    # Region factors (0..1) instead of hard cuts, so borders blend.
    fac = np.ones_like(d)
    for j, reg in enumerate(regions):
        if reg.startswith("fleg") or reg.startswith("hleg"):
            side = 1.0 if reg.endswith("L") else -1.0
            front = reg.startswith("fleg")
            own_side = x * side > 0.005
            near_z = (z > 0.08) if front else (z < -0.08)
            # leg influence fades in from the belly line down to the elbow / stifle
            ramp = np.clip((0.02 - y) / 0.10, 0.0, 1.0)
            # hanging caparison / flank armour (outside the leg), chest plate in
            # front of the forelegs and croup armour behind the hind legs follow
            # the BODY only: they hang from it and must never stretch with a leg
            # (skirt height only: below it the outer edge is hoof / leg wrap)
            outer = (np.abs(x) > 0.125) & (y > -0.20)
            chest = front & (z > 0.265) & (y > -0.16)
            croup = (not front) & (z < -0.31)
            fac[:, j] = np.where(own_side & near_z & ~outer & ~chest & ~croup, ramp, 0.0)
        elif reg == "neck":
            fac[:, j] = np.clip((z - 0.10) / 0.06, 0.0, 1.0)
        elif reg == "tail":
            # the hair only: the rear caparison hangs just beside / in front of it
            fac[:, j] = np.where((z < -0.34) & (np.abs(x) < 0.045), 1.0, 0.0)
    w = fac / np.power(d + 0.01, 4)
    w = w / np.maximum(w.sum(1, keepdims=True), 1e-12)

    # mesh adjacency + connected islands
    # connectivity = mesh edges + every node within PROX of another: the split
    # soup and touching parts become one graph for smoothing and islands
    from mathutils import kdtree
    PROX = 0.006
    kd = kdtree.KDTree(len(co))
    for i, c in enumerate(co):
        kd.insert(Vector(c), i)
    kd.balance()
    near = []
    for i, c in enumerate(co):
        for (_p, j, _dist) in kd.find_range(Vector(c), PROX):
            if j > i:
                near.append((i, j))
    mesh_edges = wid[np.array([e.vertices[:] for e in mesh.data.edges], dtype=np.int64)]
    edges = np.concatenate([mesh_edges, np.array(near, dtype=np.int64).reshape(-1, 2)])
    edges = np.unique(np.sort(edges[edges[:, 0] != edges[:, 1]], axis=1), axis=0)
    print("[HORSE] graph edges", len(edges), "(proximity", len(near), ")")
    nv = len(co)
    parent = np.arange(nv)

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    for a, b in edges:
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[ra] = rb
    roots = np.array([find(i) for i in range(nv)])
    uniq, island, counts = np.unique(roots, return_inverse=True, return_counts=True)
    main_island = counts.argmax()
    print("[HORSE] islands", len(uniq), "main", counts.max(), "of", nv)

    # smooth weights across the surface (Laplacian), keeping the region factors
    deg = np.zeros(nv)
    np.add.at(deg, edges[:, 0], 1.0)
    np.add.at(deg, edges[:, 1], 1.0)
    deg = np.maximum(deg, 1.0)[:, None]
    for _ in range(8):
        acc = np.zeros_like(w)
        np.add.at(acc, edges[:, 0], w[edges[:, 1]])
        np.add.at(acc, edges[:, 1], w[edges[:, 0]])
        w = 0.5 * w + 0.5 * acc / deg
        w = w * (fac > 0.0)
        w = w / np.maximum(w.sum(1, keepdims=True), 1e-12)

    # every island except the horse body moves rigidly with ONE bone: tassels,
    # armour plates, saddle parts and skirt pieces never stretch or tear
    rigid = 0
    for k in range(len(uniq)):
        if k == main_island:
            continue
        vs = np.where(island == k)[0]
        mass = w[vs].sum(0)
        bone = int(mass.argmax())
        size = np.linalg.norm(co[vs].max(0) - co[vs].min(0))
        # pin small parts and parts one bone already dominates; a big part that
        # spans several bones (e.g. a separate leg) keeps its smooth weights
        if size > 0.10 and mass[bone] < 0.65 * mass.sum():
            continue
        w[vs] = 0.0
        w[vs, bone] = 1.0
        rigid += 1
    print("[HORSE] rigid islands", rigid)

    # the separate head + neck piece moves rigidly with neck1 (nods, never tears)
    hg = mesh.vertex_groups.get("HEADPART")
    if hg is not None:
        hv = np.array([v.index for v in mesh.data.vertices if any(g.group == hg.index for g in v.groups)], dtype=np.int64)
        hn = np.unique(wid[hv])
        w[hn] = 0.0
        w[hn, names.index("neck1")] = 1.0
        print("[HORSE] head piece nodes pinned to neck1:", len(hn))

    # the tail never sways: all of it rides rigidly on the hips (no stretch, no tear)
    tail_nodes = np.where((co[:, 2] < -0.33) & (np.abs(co[:, 0]) < 0.08) & (co[:, 1] < 0.24))[0]
    w[tail_nodes] = 0.0
    w[tail_nodes, names.index("hips")] = 1.0
    print("[HORSE] tail nodes pinned to hips:", len(tail_nodes))

    # keep the 4 strongest influences
    idx = np.argsort(-w, axis=1)[:, :4]
    top = np.take_along_axis(w, idx, axis=1)
    top = top / np.maximum(top.sum(1, keepdims=True), 1e-12)
    groups = {n: mesh.vertex_groups.new(name=n) for n in names}
    for vi in range(len(co_v)):
        node = wid[vi]
        for k in range(4):
            if top[node, k] > 0.01:
                groups[names[idx[node, k]]].add([vi], float(top[node, k]), "REPLACE")
    mod = mesh.modifiers.new("Armature", "ARMATURE")
    mod.object = arm
    mesh.parent = arm

    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.export_scene.gltf(filepath=OUT, export_format="GLB", export_skins=True,
                              export_animations=False, export_yup=True, use_selection=False)
    print("[HORSE] bones", len(BONES), "wrote", OUT)


main()
