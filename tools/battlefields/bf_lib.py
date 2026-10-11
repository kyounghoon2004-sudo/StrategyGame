"""Canonical battlefield authoring library (DATA authoring only).

Maps are painted in SCREEN space as the player sees them in the battle shell:
BLUE near side at the bottom, RED at the top (PresentationOrientation yaw 120 deg,
BLUE forward +q = screen up). Coordinates:

    u : screen right, v : screen up, both normalised so the top corner of the
        R=40 playable hexagon (axial (40, 0), RED side) is v = +1 and the bottom
        corner (axial (-40, 0), BLUE side) is v = -1. One hex step ~ 0.025.

The playable area is the fixed R=40 regular hexagon (Step2RWorldBoundary), so
every map covers the same 4,921 cells. Terrain uses the existing HexCell ids
only (see LEGEND). Nothing here changes how the game interprets a map.
"""
from __future__ import annotations

import heapq
import json
import math
from pathlib import Path

RADIUS = 40
# row alphabet -> HexCell.TerrainType id (mirrors battlefield_catalog.gd)
LEGEND = {".": 0, "M": 1, "F": 2, "S": 3, "V": 5, "R": 6, "B": 6, "W": 7, "X": 9, "C": 11}
# Step3Config.TERRAIN_COSTS_STANDARD (read-only mirror, for reporting only)
STD_COST = {".": 1.0, "M": 3.0, "F": 2.0, "S": 2.0, "V": 1.0, "R": 0.5, "B": 0.5, "W": 1.0}
DIRS = [(1, 0), (1, -1), (0, -1), (-1, 0), (-1, 1), (0, 1)]
_C, _S = math.cos(math.radians(-120)), math.sin(math.radians(-120))
_TOP = 0.0


def world(q, r):
    return 36.0 * q, 42.0 * r + 21.0 * q


def screen_raw(q, r):
    x, y = world(q, r)
    sx = x * _C - y * _S
    sy = x * _S + y * _C
    return sx, -sy  # (right, up)


_TOP = screen_raw(RADIUS, 0)[1]


def uv(q, r):
    sx, up = screen_raw(q, r)
    return sx / _TOP, up / _TOP


def playable(q, r):
    return max(abs(q), abs(r), abs(q + r)) <= RADIUS


CELLS = [(q, r) for q in range(-RADIUS, RADIUS + 1) for r in range(-RADIUS, RADIUS + 1) if playable(q, r)]
UV = {c: uv(*c) for c in CELLS}


def half_width(v):
    """Half width (u) of the playable hexagon at height v."""
    av = abs(v)
    return 0.866 if av <= 0.5 else 0.866 * (1.0 - av) / 0.5


# ---------------------------------------------------------------- noise ---
def _h(ix, iy, seed):
    n = (ix * 374761393 + iy * 668265263 + seed * 2147483647) & 0xFFFFFFFF
    n = ((n ^ (n >> 13)) * 1274126177) & 0xFFFFFFFF
    return ((n ^ (n >> 16)) & 0xFFFF) / 65535.0


def vnoise(u, v, seed, scale=6.0):
    """Smooth value noise in [-1, 1]."""
    x, y = u * scale, v * scale
    ix, iy = math.floor(x), math.floor(y)
    fx, fy = x - ix, y - iy
    fx, fy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
    a, b = _h(ix, iy, seed), _h(ix + 1, iy, seed)
    c, d = _h(ix, iy + 1, seed), _h(ix + 1, iy + 1, seed)
    return 2.0 * ((a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy) - 1.0


def fnoise(u, v, seed, scale=5.0):
    return 0.65 * vnoise(u, v, seed, scale) + 0.35 * vnoise(u, v, seed + 17, scale * 2.3)


def hrand(q, r, seed):
    return _h(q, r, seed)


# ------------------------------------------------------------ geometry ---
def nearest(u, v):
    best, bd = None, 1e9
    for c, (cu, cv) in UV.items():
        d = (cu - u) ** 2 + (cv - v) ** 2
        if d < bd:
            best, bd = c, d
    return best


def hex_dist(a, b):
    return max(abs(a[0] - b[0]), abs(a[1] - b[1]), abs((a[0] + a[1]) - (b[0] + b[1])))


def _cube_round(x, z):
    y = -x - z
    rx, ry, rz = round(x), round(y), round(z)
    dx, dy, dz = abs(rx - x), abs(ry - y), abs(rz - z)
    if dx > dy and dx > dz:
        rx = -ry - rz
    elif dy > dz:
        ry = -rx - rz
    else:
        rz = -rx - ry
    return int(rx), int(rz)


def hexline(a, b):
    n = hex_dist(a, b)
    if n == 0:
        return [a]
    out = []
    for i in range(n + 1):
        t = i / n
        out.append(_cube_round(a[0] + (b[0] - a[0]) * t + 1e-6, a[1] + (b[1] - a[1]) * t + 1e-6))
    return out


def seg_dist(pu, pv, a, b):
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    L = dx * dx + dy * dy
    t = 0.0 if L == 0 else max(0.0, min(1.0, ((pu - ax) * dx + (pv - ay) * dy) / L))
    return math.hypot(pu - (ax + t * dx), pv - (ay + t * dy))


def poly_dist(pu, pv, pts):
    return min(seg_dist(pu, pv, pts[i], pts[i + 1]) for i in range(len(pts) - 1))


def chain(points, wiggle=0.0, seed=0, wscale=4.0):
    """Connected hex chain following a uv polyline (optionally meandering)."""
    dense = []
    for i in range(len(points) - 1):
        (au, av), (bu, bv) = points[i], points[i + 1]
        n = max(2, int(math.hypot(bu - au, bv - av) / 0.008))
        for k in range(n):
            t = k / n
            u, v = au + (bu - au) * t, av + (bv - av) * t
            if wiggle:
                L = math.hypot(bu - au, bv - av) or 1.0
                nu, nv = -(bv - av) / L, (bu - au) / L
                w = wiggle * vnoise(u, v, seed, wscale)
                u, v = u + nu * w, v + nv * w
            dense.append((u, v))
    dense.append(points[-1])
    dense = [(u, v) for u, v in dense if abs(v) < 0.985 and abs(u) < half_width(v) - 0.008]
    snapped = []
    for u, v in dense:
        c = nearest(u, v)
        if not snapped or snapped[-1] != c:
            snapped.append(c)
    out = []
    for c in snapped:
        seg = hexline(out[-1], c)[1:] if out else [c]
        for s in seg:
            if s in out:  # cut loops
                out = out[: out.index(s) + 1]
            else:
                out.append(s)
    out = [c for c in out if playable(*c)]
    return simplify(out)


def simplify(ch):
    """Remove corner-cutting kinks: if chain cells i and i+2 already touch,
    cell i+1 is redundant and would make the adjacency autotiler draw a
    triangle / ladder. Keeps the chain connected."""
    changed = True
    while changed:
        changed = False
        for i in range(len(ch) - 2):
            if hex_dist(ch[i], ch[i + 2]) == 1:
                del ch[i + 1]
                changed = True
                break
    return ch


# ------------------------------------------------------------- the map ---
class Map:
    def __init__(self, mid, slug, name, name_zh, seed, base="."):
        self.id, self.slug, self.name, self.name_zh, self.seed = mid, slug, name, name_zh, seed
        self.T = {c: base for c in CELLS}
        self.rivers = []  # chains
        self.roads = []
        self.strongholds = []
        self.units = []
        self._counters = {}
        self.meta = {}

    # painting ------------------------------------------------------------
    def paint(self, fn, ch, only=None):
        for c, (u, v) in UV.items():
            if only is not None and self.T[c] not in only:
                continue
            if fn(u, v, c):
                self.T[c] = ch

    def blob(self, cu, cv, ru, rv, ch, rough=0.25, rot=0.0, seed=0, only=None, nscale=7.0):
        cs, sn = math.cos(math.radians(rot)), math.sin(math.radians(rot))
        s = self.seed + seed

        def f(u, v, c):
            du, dv = u - cu, v - cv
            x, y = du * cs + dv * sn, -du * sn + dv * cs
            d = math.hypot(x / ru, y / rv)
            return d < 1.0 + rough * fnoise(u, v, s, nscale)
        self.paint(f, ch, only)

    def band(self, pts, width, ch, rough=0.3, seed=0, only=None, nscale=7.0, taper=False):
        s = self.seed + seed

        def f(u, v, c):
            return poly_dist(u, v, pts) < width * (1.0 + rough * fnoise(u, v, s, nscale))
        self.paint(f, ch, only)

    def scatter(self, ch, density, region=lambda u, v: True, only=(".",), seed=0, cluster=0.0):
        s = self.seed + seed
        for c, (u, v) in UV.items():
            if self.T[c] not in only or not region(u, v):
                continue
            p = density * (1.0 + cluster * fnoise(u, v, s + 3, 9.0))
            if hrand(c[0], c[1], s) < p:
                self.T[c] = ch

    def set(self, cells, ch):
        for c in cells:
            if c in self.T:
                self.T[c] = ch

    def at(self, u, v):
        return nearest(u, v)

    def disc(self, c, radius):
        return [d for d in CELLS if hex_dist(c, d) <= radius]

    # linear features -------------------------------------------------------
    def river(self, points, wiggle=0.03, seed=0, wscale=4.0):
        ch = chain(points, wiggle, self.seed + 500 + seed, wscale)
        self.rivers.append(ch)
        for c in ch:
            self.T[c] = "W"
        return ch

    def road(self, points, wiggle=0.0, seed=0, wscale=4.0):
        ch = chain(points, wiggle, self.seed + 700 + seed, wscale)
        self.roads.append(ch)
        for c in ch:
            self.T[c] = "B" if self.T[c] in ("W", "B") else "R"
        return ch

    def road_cells(self, cells):
        self.roads.append(list(cells))
        for c in cells:
            self.T[c] = "B" if self.T[c] in ("W", "B") else "R"

    def village(self, u, v):
        """One village hex at the nearest open cell (never on a road, river or
        stronghold, so road ribbons stay continuous past it)."""
        c0 = nearest(u, v)
        c = min((d for d in CELLS if self.T[d] in (".", "F", "S") and hex_dist(c0, d) <= 4),
                key=lambda d: (hex_dist(c0, d), 0 if self.T[d] == "." else 1, hrand(d[0], d[1], self.seed)))
        self.T[c] = "V"
        return c

    def village_at(self, c):
        self.T[c] = "V"
        return c

    def stronghold(self, sid, name, kind, owner, u, v, hp=None, slots=None):
        a = nearest(u, v)
        fp = [a, (a[0] + 1, a[1]), (a[0], a[1] + 1)]
        ch = "C" if kind == "capital" else "X"
        for c in fp:
            self.T[c] = ch
        self.strongholds.append({
            "id": sid, "name": name, "type": kind, "owner": owner,
            "footprint": [list(c) for c in fp],
            "hp": hp or (1500 if kind == "capital" else 1000),
            "slots": slots or (6 if kind == "capital" else 4),
        })
        return fp

    def tidy_roads(self):
        """Remove redundant corner cells where roads meet, so no three road
        cells are mutually adjacent (the route autotiler would draw a ladder).
        A cell is only removed when every other road neighbour it has is
        adjacent to one of the two cells that remain, so the network stays
        connected. Bridges are never removed."""
        def nb(c):
            return [(c[0] + d[0], c[1] + d[1]) for d in DIRS]
        changed = True
        while changed:
            changed = False
            rs = {c for c, t in self.T.items() if t in ("R", "B")}
            for c in sorted(rs):
                for i in range(6):
                    a = (c[0] + DIRS[i][0], c[1] + DIRS[i][1])
                    b = (c[0] + DIRS[(i + 1) % 6][0], c[1] + DIRS[(i + 1) % 6][1])
                    if a not in rs or b not in rs:
                        continue
                    tri = [c, a, b]
                    for v in sorted(tri, key=lambda x: sum(1 for n in nb(x) if n in rs)):
                        if self.T[v] != "R":
                            continue
                        others = [x for x in tri if x != v]
                        outside = [n for n in nb(v) if n in rs and n not in others]
                        if all(any(hex_dist(n, o) <= 1 for o in others) for n in outside):
                            self.T[v] = "."
                            changed = True
                            break
                    if changed:
                        break
                if changed:
                    break

    # deployment ------------------------------------------------------------
    COUNTS = {"hq": 300, "infantry": 430, "spearman": 380, "archer": 215, "cavalry": 270,
              "scout": 78, "siege": 105, "conscript": 590}
    ABBR = {"hq": "HQ", "infantry": "INF", "spearman": "SPE", "archer": "ARC", "cavalry": "CAV",
            "scout": "SCT", "siege": "SIG", "conscript": "CON"}

    def _occupied(self):
        return {(u["q"], u["r"]) for u in self.units}

    def _uid(self, faction, cls):
        k = (faction, cls)
        self._counters[k] = self._counters.get(k, 0) + 1
        return "%s_%s_%d" % ("B" if faction == "blue" else "R", self.ABBR[cls], self._counters[k])

    def unit_at(self, faction, cls, c, count=None):
        occ = self._occupied()
        assert c not in occ, (self.id, c)
        n = count or self.COUNTS[cls]
        n = int(n * (0.93 + 0.14 * hrand(c[0], c[1], self.seed + 91)))
        n = n - n % 5 if cls not in ("hq",) else self.COUNTS["hq"]
        self.units.append({"id": self._uid(faction, cls), "class": cls, "faction": faction,
                           "q": c[0], "r": c[1], "count": n})
        return c

    def group(self, faction, u, v, classes, allow=(".", "R", "F", "V"), spread=1):
        """Place `classes` on the nearest free allowed cells around (u, v)."""
        center = nearest(u, v)
        occ = self._occupied()
        cand = sorted(
            (d for d in CELLS if self.T[d] in allow and d not in occ and hex_dist(center, d) <= 7),
            key=lambda d: (hex_dist(center, d), hrand(d[0], d[1], self.seed + 5)))
        placed = []
        for cls in classes:
            pick = None
            for d in cand:
                if d in occ:
                    continue
                if spread > 1 and any(hex_dist(d, p) < spread for p in placed):
                    continue
                pick = d
                break
            if pick is None:
                for d in cand:
                    if d not in occ:
                        pick = d
                        break
            assert pick is not None, (self.id, u, v, cls)
            self.unit_at(faction, cls, pick)
            occ.add(pick)
            placed.append(pick)
        return placed

    def garrison(self, sid, classes):
        sh = next(s for s in self.strongholds if s["id"] == sid)
        for cls, c in zip(classes, sh["footprint"]):
            self.unit_at(sh["owner"], cls, tuple(c))

    # export ----------------------------------------------------------------
    def rows(self):
        out = []
        for q in range(-RADIUS, RADIUS + 1):
            row = []
            for r in range(-RADIUS, RADIUS + 1):
                row.append(self.T[(q, r)] if playable(q, r) else " ")
            out.append("".join(row))
        return out

    def to_json(self, info):
        return {
            "format": "canonical_battlefield_v1",
            "set": "rl_canonical_v1",
            "purpose": "rl",
            "id": self.id, "slug": self.slug, "name": self.name, "name_zh": self.name_zh,
            "generator": "tools/battlefields/build_canonical_battlefields.py",
            "seed": self.seed,
            "info": info,
            "q_min": -RADIUS, "r_min": -RADIUS,
            "legend": {k: v for k, v in LEGEND.items()},
            "rows": self.rows(),
            "strongholds": self.strongholds,
            "units": [[u["id"], u["class"], u["faction"], u["q"], u["r"], u["count"]] for u in self.units],
        }


# ------------------------------------------------------------ validation ---
def validate(m: Map):
    errs = []
    fp = {tuple(c): s["id"] for s in m.strongholds for c in s["footprint"]}
    for s in m.strongholds:
        for c in s["footprint"]:
            c = tuple(c)
            if not playable(*c):
                errs.append("footprint off-map %s" % (c,))
            if m.T[c] not in ("X", "C"):
                errs.append("footprint cell %s overwritten (%s)" % (c, m.T[c]))
    for ch in m.rivers:
        for a, b in zip(ch, ch[1:]):
            if hex_dist(a, b) != 1:
                errs.append("broken chain %s-%s" % (a, b))
    rs = {c for c, t in m.T.items() if t in ("R", "B")}
    for c in rs:
        if not any((c[0] + d[0], c[1] + d[1]) in rs for d in DIRS):
            errs.append("isolated road cell %s" % (c,))
    seen, comps = set(), 0
    for c in rs:
        if c in seen:
            continue
        comps += 1
        stack = [c]
        seen.add(c)
        while stack:
            x = stack.pop()
            for d in DIRS:
                n = (x[0] + d[0], x[1] + d[1])
                if n in rs and n not in seen:
                    seen.add(n)
                    stack.append(n)
    if comps > max(1, len(m.roads)):
        errs.append("road network broken into %d pieces" % comps)
    for s_ in m.strongholds:
        for c in s_["footprint"]:
            if tuple(c) in rs:
                errs.append("road through stronghold footprint %s" % (tuple(c),))
    for ch in m.rivers:
        for c in ch:
            if m.T[c] not in ("W", "B"):
                errs.append("river cell %s overwritten -> %s" % (c, m.T[c]))
    # bridges must be real crossings: river on 2 sides, road continues
    for c, t in m.T.items():
        if t == "B":
            rn = sum(1 for d in DIRS if m.T.get((c[0] + d[0], c[1] + d[1])) in ("W", "B"))
            if rn < 1:
                errs.append("bridge %s has no river neighbour" % (c,))
    # road clusters: three mutually adjacent road cells draw as a ladder
    rs = {c for c, t in m.T.items() if t in ("R", "B")}
    tri = 0
    for c in rs:
        for i in range(6):
            a = (c[0] + DIRS[i][0], c[1] + DIRS[i][1])
            b = (c[0] + DIRS[(i + 1) % 6][0], c[1] + DIRS[(i + 1) % 6][1])
            if a in rs and b in rs:
                degs = [sum(1 for d in DIRS if (x[0] + d[0], x[1] + d[1]) in rs) for x in (c, a, b)]
                if degs != [3, 3, 3]:  # a 3-arm Y fork is fine; anything else is a ladder / corner cut
                    tri += 1
    if tri:
        errs.append("road triangles: %d (ladder artefacts)" % (tri // 3))
    ids, pos = set(), set()
    garrisoned = 0
    for u in m.units:
        c = (u["q"], u["r"])
        if u["id"] in ids:
            errs.append("dup id " + u["id"])
        ids.add(u["id"])
        if c in pos:
            errs.append("stacked units at %s" % (c,))
        pos.add(c)
        if not playable(*c):
            errs.append("unit off-map " + u["id"])
        if c in fp:
            owner = next(s["owner"] for s in m.strongholds if s["id"] == fp[c])
            if owner != u["faction"]:
                errs.append("enemy unit on footprint " + u["id"])
            garrisoned += 1
        elif m.T[c] in ("W", "X", "C"):
            errs.append("unit %s on %s" % (u["id"], m.T[c]))
    for f in ("blue", "red"):
        hqs = [u for u in m.units if u["faction"] == f and u["class"] == "hq"]
        if len(hqs) != 1:
            errs.append("%s needs exactly one HQ" % f)
    bhq = next(u for u in m.units if u["faction"] == "blue" and u["class"] == "hq")
    bu, bv = uv(bhq["q"], bhq["r"])
    if bv > -0.2 or abs(bu) > 0.25:
        errs.append("blue HQ not bottom-centre: u=%.2f v=%.2f" % (bu, bv))
    return errs


def route_cost(m: Map, a, b):
    """Cheapest standard-cost route (reporting only; the game's own
    pathfinding is authoritative). Stronghold footprints are impassable."""
    dist = {a: 0.0}
    pq = [(0.0, a)]
    prev = {}
    while pq:
        d, c = heapq.heappop(pq)
        if c == b:
            break
        if d > dist.get(c, 1e18):
            continue
        for dq, dr in DIRS:
            n = (c[0] + dq, c[1] + dr)
            if n not in m.T or m.T[n] in ("X", "C"):
                continue
            nd = d + STD_COST[m.T[n]]
            if nd < dist.get(n, 1e18):
                dist[n] = nd
                prev[n] = c
                heapq.heappush(pq, (nd, n))
    path = [b]
    while path[-1] in prev:
        path.append(prev[path[-1]])
    return dist.get(b, float("inf")), path[::-1]


def composition(m: Map):
    tot = len(CELLS)
    cnt = {}
    for t in m.T.values():
        cnt[t] = cnt.get(t, 0) + 1
    names = {".": "plain", "M": "mountain", "F": "forest", "S": "marsh", "V": "village",
             "R": "road", "B": "bridge", "W": "river", "X": "fortress", "C": "capital"}
    return {names[k]: round(100.0 * v / tot, 1) for k, v in sorted(cnt.items(), key=lambda x: -x[1])}


# --------------------------------------------------------------- preview ---
COLORS = {".": (205, 191, 138), "M": (122, 104, 88), "F": (63, 107, 58), "S": (104, 138, 118),
          "V": (201, 128, 63), "R": (150, 112, 62), "B": (226, 176, 80), "W": (63, 127, 154),
          "X": (160, 32, 32), "C": (212, 170, 42)}


def render_preview(m: Map, path: Path, s=440.0, route=None):
    from PIL import Image, ImageDraw
    # s: pixels per uv unit
    Wpx, Hpx = int(1.85 * s), int(2.1 * s)
    img = Image.new("RGB", (Wpx, Hpx), (38, 40, 46))
    dr = ImageDraw.Draw(img)
    ox, oy = Wpx / 2, Hpx / 2
    corner = []
    for k in range(6):
        ang = math.radians(60 * k)
        wx, wy = 24 * math.cos(ang), 24 * math.sin(ang) * (42 / 41.57)
        sx = wx * _C - wy * _S
        up = -(wx * _S + wy * _C)
        corner.append((sx / _TOP, up / _TOP))

    def P(u, v):
        return ox + u * s, oy - v * s
    for c, (u, v) in UV.items():
        col = COLORS[m.T[c]]
        pts = [P(u + cu * 0.97, v + cv * 0.97) for cu, cv in corner]
        dr.polygon(pts, fill=col)
    if route:
        for a, b in zip(route, route[1:]):
            dr.line([P(*UV[a]), P(*UV[b])], fill=(250, 250, 250), width=2)
    for un in m.units:
        u, v = UV[(un["q"], un["r"])]
        x, y = P(u, v)
        col = (40, 90, 220) if un["faction"] == "blue" else (220, 45, 40)
        rr = 0.011 * s
        if un["class"] == "hq":
            dr.ellipse([x - rr * 1.6, y - rr * 1.6, x + rr * 1.6, y + rr * 1.6], fill=(240, 200, 60))
        dr.ellipse([x - rr, y - rr, x + rr, y + rr], fill=col, outline=(15, 15, 15))
    dr.text((12, 10), "%s  %s  %s" % (m.id, m.name, m.name_zh), fill=(240, 235, 220))
    dr.text((12, Hpx - 22), "RED (top)  /  BLUE (bottom)", fill=(200, 200, 200))
    img.save(path)
    return img
