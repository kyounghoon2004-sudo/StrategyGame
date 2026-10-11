"""Seeded mission battlefield generator (2026-10-09): one seed -> one playable map + scenario for a mission family.

Families (the GX-missions families, judged by scripts/gx_missions/mission_rules.gd):
  M1 village defense   attacker must hold the village (>=2 units, no defender inside) for 2 rounds
  M2 gate fort         a wall line across the map with 1-3 gates and a fortress in it; attacker captures the fort
  M3 field battle      open ground; army collapse (soldiers <= 30% of start) or HQ decides
  M4 occupation        3 sites; a side's HQ builds logistics bases on them; all 3 held for 3 rounds wins
  M5 siege             a walled town (wall ring with 1-3 gates) around a citadel; attacker captures the citadel
Every family: own HQ destroyed = defeat; each HQ must keep a logistics base it can reach (supply).

Output = tutorial_battlefield_v1 JSON (set "mission_gen_v1"), loaded by the game as battlefield id "@<path>".
Maps are hexagons of radius 10-16 around (0, 0); BLUE deploys west (q < 0), RED east. Roles (attacker/defender) are
random per seed for M1/M2/M5. Terrain: plains, forest, swamp, mountains, a river with bridges, roads, walls ("H").

  python tools/battlefields/gen_missions.py --family M5 --seed 7 --out <file.json>
  python tools/battlefields/gen_missions.py --batch 20 --out-dir <dir>      (all families, seeds 1..20)
"""
from __future__ import annotations

import argparse
import heapq
import json
import math
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from bf_lib import fnoise, hex_dist, hexline  # noqa: E402

FAMILIES = ["M1", "M2", "M3", "M4", "M5"]
DIRS = [(1, 0), (1, -1), (0, -1), (-1, 0), (-1, 1), (0, 1)]
COST = {".": 1.0, "M": 3.0, "F": 2.0, "S": 2.0, "V": 1.0, "R": 0.5, "W": 1.0}  # H / X / C impassable
STRENGTH = {"hq": 300, "infantry": 450, "spearman": 380, "archer": 220, "cavalry": 280, "scout": 80, "siege": 100}
CODE = {"infantry": "INF", "spearman": "SPE", "archer": "ARC", "cavalry": "CAV", "scout": "SCT", "siege": "SIG"}
FIELD = ["infantry", "spearman", "archer", "cavalry", "scout"]
FIELD_W = [3, 3, 3, 2, 1]


def neighbors(c):
    return [(c[0] + d[0], c[1] + d[1]) for d in DIRS]


def disk(c, r):
    return [(c[0] + dq, c[1] + dr) for dq in range(-r, r + 1) for dr in range(max(-r, -dq - r), min(r, -dq + r) + 1)]


def ring(c, r):
    return [h for h in disk(c, r) if hex_dist(h, c) == r]


class Gen:
    def __init__(self, family: str, seed: int):
        self.family, self.seed = family, seed
        self.rng = random.Random(f"{family}:{seed}")
        self.R = self.rng.randint(10, 16)
        self.T = {}  # (q, r) -> glyph
        for q in range(-self.R, self.R + 1):
            for r in range(-self.R, self.R + 1):
                if hex_dist((q, r), (0, 0)) <= self.R:
                    self.T[(q, r)] = "."
        self.river, self.strongholds, self.units, self.keep = set(), [], [], set()
        self.objectives, self.control_sites, self.notes = [], [], []
        self.uid = {"red": {}, "blue": {}}

    # ------------------------------------------------------------- terrain
    def inside(self, c):
        return c in self.T

    def base_terrain(self):
        s = self.seed * 7 + FAMILIES.index(self.family)
        for c in self.T:
            u, v = c[0] / self.R, c[1] / self.R
            if fnoise(u, v, s + 1, 3.0) > 0.38:
                self.T[c] = "F"
            elif fnoise(u, v, s + 2, 3.5) > 0.55:
                self.T[c] = "S"
            if fnoise(u, v, s + 3, 2.6) > 0.58:
                self.T[c] = "M"

    def add_river(self):
        """A meandering north-south river near q ~ 0 with 1-3 bridges (road cells, not river)."""
        # waypoints from the north edge to the south edge, joined hex by hex (a contiguous chain)
        pts, x = [], self.rng.randint(-2, 2)
        for r in range(-self.R, self.R + 1, 4):
            x = max(-4, min(4, x + self.rng.choice([-1, 0, 1])))
            pts.append((x - r // 2, r))
        path = []
        for a, b in zip(pts, pts[1:]):
            for c in hexline(a, b):
                if self.inside(c) and (not path or path[-1] != c):
                    path.append(c)
        for c in path:
            self.T[c] = "W"
            self.river.add(c)
        bridges = self.rng.sample(path[2:-2], k=min(len(path) - 4, self.rng.randint(1, 3))) if len(path) > 6 else []
        for b in bridges:
            self.T[b] = "R"
            self.river.discard(b)
            self.keep.add(b)

    def clear(self, cells, glyph="."):
        for c in cells:
            if self.inside(c) and c not in self.keep:
                self.T[c] = glyph
                self.river.discard(c)

    def road(self, a, b):
        for c in hexline(a, b):
            if self.inside(c) and self.T[c] not in ("H", "X", "C") and c not in self.river:
                self.T[c] = "R"
                self.keep.add(c)

    # ---------------------------------------------------------- structures
    def stronghold(self, sid, name, kind, owner, anchor, hp, slots):
        fp = [anchor, (anchor[0] + 1, anchor[1]), (anchor[0], anchor[1] + 1)]
        self.clear(disk(anchor, 2))
        for c in fp:
            self.T[c] = "X" if kind == "fortress" else "C"
            self.keep.add(c)
        self.strongholds.append({"id": sid, "name": name, "type": kind, "owner": owner,
                                 "footprint": [list(c) for c in fp], "hp": hp, "slots": slots})
        return fp

    def wall_ring(self, center, radius, n_gates, facing):
        """Wall ring ("H") with gates facing `facing` (a hex the attacker comes from)."""
        cells = ring(center, radius)
        cells.sort(key=lambda c: hex_dist(c, facing))
        gates = [cells[0]]
        for c in cells[1:]:
            if len(gates) >= n_gates:
                break
            if all(hex_dist(c, g) >= max(3, radius) for g in gates):
                gates.append(c)
        for c in cells:
            if self.inside(c):
                self.T[c] = "R" if c in gates else "H"
                self.river.discard(c)
                self.keep.add(c)
        self.clear(disk(center, radius - 1))
        for g in gates:  # an open approach on both sides of each gate
            for n in neighbors(g):
                if self.inside(n) and self.T[n] != "H":
                    self.T[n] = "." if self.T[n] not in ("R",) else "R"
                    self.river.discard(n)
        return gates

    def wall_line(self, q0, n_gates):
        """A north-south wall across the map at q ~ q0 with gates; mountains continue it at the map edge."""
        cells = [c for c in self.T if c[0] + c[1] // 2 == q0]
        cells.sort(key=lambda c: c[1])
        k = len(cells)
        gate_idx = sorted(self.rng.sample(range(2, k - 2), k=min(n_gates, max(1, k - 4))))
        gates = [cells[i] for i in gate_idx]
        for c in cells:
            self.T[c] = "R" if c in gates else "H"
            self.river.discard(c)
            self.keep.add(c)
        return cells, gates

    # -------------------------------------------------------------- armies
    def name(self, side, cls):
        n = self.uid[side].get(cls, 0) + 1
        self.uid[side][cls] = n
        return "%s_%s_%d" % ("R" if side == "red" else "B", "HQ" if cls == "hq" else CODE[cls], n)

    def free(self, c):
        return self.inside(c) and self.T[c] in COST and c not in self.river and \
            all(not (u[3] == c[0] and u[4] == c[1]) for u in self.units)

    def place(self, side, cls, around, radius=4, count=None, on=None):
        if on is not None:
            c = on
        else:
            cand = [c for c in disk(around, radius) if self.free(c)]
            if not cand:
                return None
            cand.sort(key=lambda c: (hex_dist(c, around), self.rng.random()))
            c = cand[0] if cls == "hq" else self.rng.choice(cand[:max(3, len(cand) // 3)])
        uid = self.name(side, cls)
        self.units.append([uid, cls, side, c[0], c[1], count or STRENGTH[cls]])
        return c

    def army(self, side, n, around, radius=5, siege=0):
        for _ in range(siege):
            self.place(side, "siege", around, radius)
        for _ in range(n - siege):
            self.place(side, self.rng.choices(FIELD, FIELD_W)[0], around, radius)

    # ----------------------------------------------------------- families
    def build(self):
        f, rng, R = self.family, self.rng, self.R
        self.base_terrain()
        if rng.random() < 0.6 and f != "M5":
            self.add_river()
        west, east = (-(R - 2), 0), (R - 2, 0)
        hq = {"blue": west, "red": east}
        roles = {"blue": "none", "red": "none"}
        if f in ("M1", "M2", "M5"):
            att = rng.choice(["red", "blue"])
            roles = {att: "attacker", ("blue" if att == "red" else "red"): "defender"}
        self.roles = roles
        n = rng.randint(6, 12)  # field units per side (HQ apart)
        if f == "M1":
            dfd = [s for s in roles if roles[s] == "defender"][0]
            sign = -1 if dfd == "blue" else 1
            vc = (sign * rng.randint(2, max(3, R // 3)), rng.randint(-2, 2))
            village = disk(vc, 1)
            self.clear(disk(vc, 2))
            for c in village:
                self.T[c] = "V"
                self.keep.add(c)
            self.objectives = [{"id": "village", "kind": "hold_area_until_round_limit", "target_ref": "village",
                                "objective_area": {"center": list(vc), "radius": 1}}]
            self.road(hq["blue"], vc)
            self.road(hq["red"], vc)
            self.notes.append("village at %s" % (vc,))
            self.limit = math.ceil(hex_dist(hq[[s for s in roles if roles[s] == "attacker"][0]], vc) / 2) + rng.randint(8, 12)
            for s in ("red", "blue"):
                self.place(s, "hq", hq[s], 2)
            self.army(dfd, n, vc, 3)
            self.army([s for s in roles if roles[s] == "attacker"][0], n + rng.randint(1, 3), hq[[s for s in roles if roles[s] == "attacker"][0]], 5)
        elif f == "M2":
            dfd = [s for s in roles if roles[s] == "defender"][0]
            att = [s for s in roles if roles[s] == "attacker"][0]
            sign = -1 if dfd == "blue" else 1
            q0 = sign * rng.randint(1, max(2, R // 4))
            cells, gates = self.wall_line(q0, rng.randint(1, 3))
            mid = min(cells, key=lambda c: abs(c[1]))
            anchor = (mid[0] + sign * 2, mid[1] - 1)
            self.clear([anchor] + neighbors(anchor))
            fp = self.stronghold("gate_fort", "Gate Fort", "fortress", dfd, anchor, rng.choice([420, 520, 620]), 4)
            self.objectives = [{"id": "fort", "kind": "capture_fortified_objective", "target_ref": "gate_fort",
                                "objective_area": {"center": list(anchor), "radius": 2}}]
            for g in gates:
                self.road(hq[att], g)
            self.road(hq[dfd], anchor)
            self.notes.append("wall line q~%d, gates %s, fort %s" % (q0, gates, anchor))
            self.limit = math.ceil(hex_dist(hq[att], anchor) / 2) + rng.randint(12, 18)
            for s in ("red", "blue"):
                self.place(s, "hq", hq[s], 2)
            for c in fp[:rng.randint(2, 3)]:
                self.place(dfd, rng.choice(["spearman", "archer", "infantry"]), None, on=c)
            self.army(dfd, max(3, n - 3), (anchor[0] + sign * 3, anchor[1]), 3)
            self.army(att, n + rng.randint(2, 4), hq[att], 5, siege=rng.randint(1, 2))
        elif f == "M3":
            self.objectives = [{"id": "field", "kind": "field_force_collapse", "target_ref": "enemy_army",
                                "objective_area": {"center": [0, 0], "radius": 3}}]
            self.road(hq["blue"], hq["red"])
            self.limit = math.ceil(2 * R / 2) + rng.randint(15, 22)
            for s in ("red", "blue"):
                self.place(s, "hq", hq[s], 2)
                self.army(s, n, (hq[s][0] + (3 if s == "blue" else -3), 0), 5)
        elif f == "M4":
            span = max(4, R // 2)
            sites = [(0, -span), (0, 0), (0, span)]
            sites = [(c[0] + rng.randint(-2, 2) - c[1] // 2, c[1]) for c in sites]
            for c in sites:
                self.clear(disk(c, 1))
                self.T[c] = "V"
                self.keep.add(c)
            self.control_sites = [{"stronghold_id": "", "logistics_base_hex": list(c),
                                   "objective_area": {"center": list(c), "radius": 1},
                                   "control_truth": "existing_hq_built_logistics_base"} for c in sites]
            self.objectives = [{"id": "sites", "kind": "three_site_logistics_control", "target_ref": "sites",
                                "objective_area": {"center": [0, 0], "radius": span}}]
            for c in sites:
                self.road(hq["blue"], c)
                self.road(hq["red"], c)
            self.notes.append("sites %s" % sites)
            self.limit = math.ceil(R / 2) + rng.randint(22, 30)
            for s in ("red", "blue"):
                self.place(s, "hq", hq[s], 2)
                self.army(s, n, (hq[s][0] + (3 if s == "blue" else -3), 0), 5)
        elif f == "M5":
            dfd = [s for s in roles if roles[s] == "defender"][0]
            att = [s for s in roles if roles[s] == "attacker"][0]
            sign = -1 if dfd == "blue" else 1
            center = (sign * rng.randint(3, max(4, R // 3)), rng.randint(-2, 2))
            rad = rng.randint(3, 4)
            gates = self.wall_ring(center, rad, rng.randint(1, 3), hq[att])
            anchor = (center[0], center[1])
            fp = self.stronghold("citadel", "Inner Citadel", "capital", dfd, anchor, rng.choice([620, 760, 900]), 6)
            self.objectives = [{"id": "citadel", "kind": "capture_fortified_objective", "target_ref": "citadel",
                                "objective_area": {"center": list(center), "radius": rad}}]
            for g in gates:
                self.road(hq[att], g)
            hq[dfd] = (center[0] + sign * (rad + 3), center[1]) if self.inside((center[0] + sign * (rad + 3), center[1])) \
                else hq[dfd]
            self.notes.append("town %s r%d gates %s" % (center, rad, gates))
            self.limit = math.ceil(hex_dist(hq[att], center) / 2) + rng.randint(16, 24)
            for s in ("red", "blue"):
                self.place(s, "hq", hq[s], 2)
            for c in fp[:rng.randint(2, 3)]:
                self.place(dfd, rng.choice(["spearman", "archer", "infantry"]), None, on=c)
            self.army(dfd, max(3, n - 3), center, rad - 1)
            self.army(att, n + rng.randint(3, 5), hq[att], 5, siege=rng.randint(1, 3))
        self.hq = {s: next((u[3], u[4]) for u in self.units if u[2] == s and u[1] == "hq") for s in ("red", "blue")}

    # ---------------------------------------------------------- validation
    def path_cost(self, a, b):
        dist, pq = {a: 0.0}, [(0.0, a)]
        while pq:
            d, c = heapq.heappop(pq)
            if c == b:
                return d
            if d > dist.get(c, 1e9):
                continue
            for n in neighbors(c):
                g = self.T.get(n)
                if g is None or g not in COST:
                    continue
                nd = d + COST[g]
                if nd < dist.get(n, 1e9):
                    dist[n] = nd
                    heapq.heappush(pq, (nd, n))
        return None

    def validate(self):
        errs = []
        for u in self.units:
            c = (u[3], u[4])
            g = self.T.get(c)
            if g is None:
                errs.append("unit %s off map" % u[0])
            elif g in ("H",) or (g in ("X", "C") and not any(c in [tuple(x) for x in s["footprint"]] and s["owner"] == u[2]
                                                                 for s in self.strongholds)):
                errs.append("unit %s on impassable %s" % (u[0], g))
        if len({(u[3], u[4]) for u in self.units}) != len(self.units):
            errs.append("stacked units")
        for s in ("red", "blue"):
            if sum(1 for u in self.units if u[2] == s and u[1] == "hq") != 1:
                errs.append("%s needs exactly one HQ" % s)
        targets = []
        if self.family in ("M2", "M5"):
            fp = [tuple(x) for x in self.strongholds[0]["footprint"]]
            targets = [n for c in fp for n in neighbors(c) if self.T.get(n) in COST]
        elif self.family == "M1":
            targets = [tuple(self.objectives[0]["objective_area"]["center"])]
        elif self.family == "M4":
            targets = [tuple(s["logistics_base_hex"]) for s in self.control_sites]
        else:
            targets = [self.hq["red"]]
        for s in ("red", "blue"):
            for t in targets:
                if self.family in ("M2", "M5") and self.roles.get(s) == "defender":
                    continue
                if self.path_cost(self.hq[s], t) is None and all(self.path_cost(self.hq[s], n) is None for n in neighbors(t)):
                    errs.append("%s HQ cannot reach %s" % (s, t))
        if self.path_cost(self.hq["red"], self.hq["blue"]) is None:
            errs.append("HQs not connected")
        return errs

    # -------------------------------------------------------------- output
    def doc(self):
        R = self.R
        rows = []
        for q in range(-R, R + 1):
            rows.append("".join(self.T.get((q, r), "#") for r in range(-R, R + 1)))
        att = [s for s in self.roles if self.roles[s] == "attacker"]
        scenario = {
            "schema": "tutorial_scenario_v1", "mission_id": self.family, "mission_family": self.family,
            "side_role": dict(self.roles), "objectives": self.objectives, "control_sites": self.control_sites,
            "round_limit": int(self.limit), "round_limit_provisional": False,
            "collapse_withdrawal": {"loss_ratio": 0.30},
            "hq": {s: {"unit_id": next(u[0] for u in self.units if u[2] == s and u[1] == "hq"), "location": list(self.hq[s])}
                   for s in ("red", "blue")},
            "normal_result_rule": "",
        }
        count = {s: sum(1 for u in self.units if u[2] == s) for s in ("red", "blue")}
        return {
            "format": "tutorial_battlefield_v1", "set": "mission_gen_v1",
            "id": "G%s_%d" % (self.family, self.seed), "name": "%s seed %d" % (self.family, self.seed), "name_zh": "",
            "generator": "tools/battlefields/gen_missions.py", "seed": self.seed, "radius": R,
            "q_min": -R, "r_min": -R, "width_hexes": 2 * R + 1, "height_hexes": 2 * R + 1,
            "rows": rows, "river_cells": [list(c) for c in sorted(self.river)],
            "units": self.units, "strongholds": self.strongholds, "scenario": scenario,
            "info": {"tactical": "; ".join(self.notes), "units": count, "attacker": att[0] if att else "none"},
            "map_metadata": {"primary_terrain": [], "radius": R},
        }


def generate(family: str, seed: int, tries: int = 30) -> dict:
    for k in range(tries):
        g = Gen(family, seed * 100 + k)
        g.build()
        errs = g.validate()
        if not errs:
            d = g.doc()
            d["seed"], d["id"], d["name"] = seed, "G%s_%d" % (family, seed), "%s seed %d" % (family, seed)
            d["generator_attempt"] = k
            return d
    raise RuntimeError("no valid %s map for seed %d: %s" % (family, seed, errs))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--family", choices=FAMILIES)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out")
    ap.add_argument("--batch", type=int, default=0, help="seeds 1..N for every family")
    ap.add_argument("--out-dir")
    a = ap.parse_args()
    if a.batch:
        out = Path(a.out_dir)
        out.mkdir(parents=True, exist_ok=True)
        for f in FAMILIES:
            for s in range(1, a.batch + 1):
                d = generate(f, s)
                (out / ("%s_s%d.json" % (f, s))).write_text(json.dumps(d, indent=1), encoding="utf-8")
        print("wrote", a.batch * len(FAMILIES), "maps to", out)
        return
    d = generate(a.family, a.seed)
    text = json.dumps(d, indent=1)
    if a.out:
        Path(a.out).write_text(text, encoding="utf-8")
    print("\n".join(d["rows"]))
    print(d["info"], "round_limit", d["scenario"]["round_limit"], "roles", d["scenario"]["side_role"])


if __name__ == "__main__":
    main()
