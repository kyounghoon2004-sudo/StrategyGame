"""Upscale the tutorial maps M1-M5 (data/battlefields/tutorial_v1) to the half-size board: diameter 40
(axial hexagon radius 20, 1261 hexes).

Design rules (2026-10-18, user): only two board sizes exist, 80 and 40; the tutorials use 40.
  * Area terrain (plain, forest, mountain, swamp, ...) is scaled up: every new hex takes the terrain of the
    source hex it shrinks back onto.
  * Local groups keep their shape: an army, a village, a fortress or a logistics site, and everything within
    2 hexes of it, form one group; the group is moved as a whole to its scaled position, so a village stays
    3 hexes and the defenders stay on it, while the distances between groups grow x(20 / source radius).
  * Roads and rivers stay 1 hex wide: they are redrawn as hex lines between the new positions of
    neighbouring source road / river hexes (a road crossing a river is a bridge: road terrain + river cell).
  * Units always end on passable, distinct hexes; every coordinate in the scenario follows the same mapping.

Usage:  python -I tools/battlefields/upscale_tutorial_maps.py [--write]
Without --write it only prints a report. Idempotent guard: maps that already have radius 20 are skipped.
"""
import json
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DATA = os.path.join(ROOT, "data", "battlefields", "tutorial_v1")
FILES = ["m1_village_defense.json", "m2_gate_fort.json", "m3_open_field_battle.json",
         "m4_roads_and_crossings.json", "m5_fortified_assault.json"]
NEW_R = 20
POINT = set("VXC")      # settlements / fortresses: kept at their size, moved with their group
LINE = set("RW")        # roads / rivers: redrawn 1 hex wide
BLOCKED = set("MWXCH")  # where a unit may not stand (own stronghold hexes are set for garrisons separately)
DIRS = [(1, 0), (1, -1), (0, -1), (-1, 0), (-1, 1), (0, 1)]


def hd(a, b):
    dq, dr = a[0] - b[0], a[1] - b[1]
    return max(abs(dq), abs(dr), abs(dq + dr))


def cube_round(q, r):
    s = -q - r
    rq, rr, rs = round(q), round(r), round(s)
    dq, dr, ds = abs(rq - q), abs(rr - r), abs(rs - s)
    if dq > dr and dq > ds:
        rq = -rr - rs
    elif dr > ds:
        rr = -rq - rs
    return (int(rq), int(rr))


def hex_line(a, b):
    n = hd(a, b)
    if n == 0:
        return [a]
    out = []
    for i in range(n + 1):
        t = i / n
        h = cube_round(a[0] + (b[0] - a[0]) * t + 1e-6, a[1] + (b[1] - a[1]) * t + 1e-6)
        if not out or out[-1] != h:
            out.append(h)
    return out


def in_board(h):
    return hd(h, (0, 0)) <= NEW_R


def convert(doc):
    q0, r0 = doc["q_min"], doc["r_min"]
    src = {}
    for i, row in enumerate(doc["rows"]):
        for j, ch in enumerate(row):
            if ch != "#":
                src[(q0 + i, r0 + j)] = ch
    radius = max(hd(h, (0, 0)) for h in src)
    if radius == NEW_R:
        return None, "already radius %d" % NEW_R
    k = NEW_R / radius
    sc = doc["scenario"]

    # ---- objects: units, point features, stronghold footprints, site hexes, objective hexes ----
    objects = set()
    for u in doc["units"]:
        objects.add((u[3], u[4]))
    for h, ch in src.items():
        if ch in POINT:
            objects.add(h)
    for s in doc.get("strongholds", []):
        for c in s["footprint"]:
            objects.add(tuple(c))
    for cs in sc.get("control_sites", []):
        objects.add(tuple(cs["logistics_base_hex"]))
    for ob in sc.get("objectives", []):
        for c in (ob.get("objective_area", {}) or {}).get("hexes", []):
            objects.add(tuple(c))
    # groups = connected components of objects within 2 hexes
    objects = sorted(objects)
    group_of = {}
    groups = []
    for o in objects:
        if o in group_of:
            continue
        g = [o]
        group_of[o] = len(groups)
        stack = [o]
        while stack:
            cur = stack.pop()
            for p in objects:
                if p not in group_of and hd(cur, p) <= 2:
                    group_of[p] = len(groups)
                    g.append(p)
                    stack.append(p)
        groups.append(g)
    shift = []
    for g in groups:
        cq = sum(p[0] for p in g) / len(g)
        cr = sum(p[1] for p in g) / len(g)
        anchor = min(g, key=lambda p: (abs(p[0] - cq) + abs(p[1] - cr), p))
        na = cube_round(anchor[0] * k, anchor[1] * k)
        # keep the whole group on the board
        while not all(in_board((na[0] + p[0] - anchor[0], na[1] + p[1] - anchor[1])) for p in g):
            na = cube_round(na[0] * 0.95, na[1] * 0.95)
        shift.append((na[0] - anchor[0], na[1] - anchor[1]))

    def mapped(h):
        h = tuple(h)
        if h in group_of:
            s = shift[group_of[h]]
            return (h[0] + s[0], h[1] + s[1])
        return cube_round(h[0] * k, h[1] * k)

    # ---- area terrain ----
    board = [(q, r) for q in range(-NEW_R, NEW_R + 1) for r in range(-NEW_R, NEW_R + 1) if in_board((q, r))]
    area_src = {h: ch for h, ch in src.items()}
    for h, ch in src.items():
        if ch in POINT or ch in LINE:
            # the ground under a point / line feature: the most common area terrain around it, else plain
            around = [src.get((h[0] + d[0], h[1] + d[1])) for d in DIRS]
            around = [a for a in around if a and a not in POINT and a not in LINE]
            area_src[h] = max(set(around), key=around.count) if around else "."
    new = {}
    for h in board:
        s = cube_round(h[0] / k, h[1] / k)
        if s not in area_src:
            s = min(area_src, key=lambda p: (hd(p, s), p))
        new[h] = area_src[s]

    # ---- lines: roads, rivers ----
    river_src = set(tuple(c) for c in doc.get("river_cells", [])) | {h for h, ch in src.items() if ch == "W"}
    road_src = {h for h, ch in src.items() if ch == "R"}
    feature_src = {h for h, ch in src.items() if ch in POINT}

    def draw(cells, joinable):
        out = set()
        for a in cells:
            for d in DIRS:
                b = (a[0] + d[0], a[1] + d[1])
                if b in cells or (b in joinable):
                    for h in hex_line(mapped(a), mapped(b)):
                        if in_board(h):
                            out.add(h)
            if in_board(mapped(a)):
                out.add(mapped(a))
        return out

    river_new = draw(river_src, set())
    road_new = draw(road_src, feature_src)
    for h in river_new:
        new[h] = "W"
    for h in road_new:
        new[h] = "R"  # bridges: road terrain, still a river cell
    river_cells = sorted(h for h in river_new)

    # ---- point features ----
    for h, ch in src.items():
        if ch in POINT:
            new[mapped(h)] = ch
    strongholds = []
    for s in doc.get("strongholds", []):
        s2 = dict(s)
        s2["footprint"] = [list(mapped(c)) for c in s["footprint"]]
        strongholds.append(s2)

    # ---- units ----
    garrison_ids = set(sc.get("deployment", {}).get("garrison_unit_ids", []))
    fort_hexes = {tuple(c) for s in strongholds for c in s["footprint"]}
    taken = set()
    unit_pos = {}
    for u in doc["units"]:
        p = mapped((u[3], u[4]))
        if u[0] not in garrison_ids:
            if p in fort_hexes or p in taken or not in_board(p):
                # nearest free passable hex
                ring = sorted((h for h in board if h not in taken and h not in fort_hexes and new[h] not in BLOCKED),
                              key=lambda h: (hd(h, p), h))
                p = ring[0]
            if new[p] in BLOCKED and new[p] != "R":
                new[p] = "."
        taken.add(p)
        unit_pos[u[0]] = p

    # ---- document ----
    out = json.loads(json.dumps(doc))
    out["q_min"] = -NEW_R
    out["r_min"] = -NEW_R
    out["width_hexes"] = 2 * NEW_R + 1
    out["height_hexes"] = 2 * NEW_R + 1
    rows = []
    for q in range(-NEW_R, NEW_R + 1):
        rows.append("".join(new.get((q, r), "#") if in_board((q, r)) else "#" for r in range(-NEW_R, NEW_R + 1)))
    out["rows"] = rows
    if river_cells:
        out["river_cells"] = [list(h) for h in river_cells]
    else:
        out.pop("river_cells", None)
    out["strongholds"] = strongholds
    for u in out["units"]:
        u[3], u[4] = unit_pos[u[0]]
    sc2 = out["scenario"]
    for side in ("blue", "red"):
        hq = sc2["hq"][side]
        hq["location"] = list(unit_pos[hq["unit_id"]])
    for pl in sc2.get("deployment", {}).get("unit_placements", []):
        pl["location"] = list(unit_pos[pl["unit_id"]])
    for cs in sc2.get("control_sites", []):
        cs["logistics_base_hex"] = list(mapped(cs["logistics_base_hex"]))
        oa = cs.get("objective_area")
        if oa:
            oa["center"] = list(mapped(oa["center"]))
    for ob in sc2.get("objectives", []):
        oa = ob.get("objective_area")
        if not oa:
            continue
        local = tuple(oa["center"]) in group_of
        oa["center"] = list(mapped(oa["center"]))
        if "hexes" in oa:
            oa["hexes"] = [list(mapped(c)) for c in oa["hexes"]]
        if "radius" in oa and not local:
            oa["radius"] = int(round(oa["radius"] * k))
    mm = out.get("map_metadata", {})
    if "objective_locations" in mm:
        def remap(v):
            if isinstance(v, list) and len(v) == 2 and all(isinstance(x, int) for x in v):
                return list(mapped(v))
            if isinstance(v, list):
                return [remap(x) for x in v]
            return v
        mm["objective_locations"] = {key: remap(v) for key, v in mm["objective_locations"].items()}
    if "playable_dimensions" in mm:
        mm["playable_dimensions"] = {"q": 2 * NEW_R + 1, "r": 2 * NEW_R + 1, "hexes": len(board),
                                     "shape": "regular_axial_hexagon", "hex_radius": NEW_R}
    mm["board_size_preset"] = 2 * NEW_R
    # report
    hq_b, hq_r = unit_pos[sc["hq"]["blue"]["unit_id"]], unit_pos[sc["hq"]["red"]["unit_id"]]
    rep = {"src_radius": radius, "scale": round(k, 3), "groups": len(groups), "hexes": len(board),
           "hq_blue": hq_b, "hq_red": hq_r, "hq_dist": hd(hq_b, hq_r),
           "terrain": {ch: sum(1 for v in new.values() if v == ch) for ch in sorted(set(new.values()))},
           "units_on_blocked": [u for u, p in unit_pos.items() if new[p] in "MW" ]}
    return out, rep


def main():
    write = "--write" in sys.argv
    for f in FILES:
        p = os.path.join(DATA, f)
        doc = json.load(open(p, encoding="utf-8"))
        out, rep = convert(doc)
        print(doc["id"], json.dumps(rep, ensure_ascii=False))
        if out is not None and write:
            with open(p, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(json.dumps(out, ensure_ascii=False, indent=2) + "\n")
    if not write:
        print("(dry run; --write to save)")


if __name__ == "__main__":
    main()
