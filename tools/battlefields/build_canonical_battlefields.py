"""Builds the 10 canonical battlefields (scenario DATA only).

    python tools/battlefields/build_canonical_battlefields.py [--preview-dir DIR] [IDS...]

Writes res://data/battlefields/rl_canonical_v1/<id>_<slug>.json (the RL set) (loaded by
scripts/battlefields/battlefield_catalog.gd) and optional preview PNGs.
Maps are painted in screen space (BLUE bottom, RED top); see bf_lib.py.
Every map uses existing terrain ids and existing FORTRESS / CAPITAL types only.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from bf_lib import (Map, UV, CELLS, nearest, hex_dist, poly_dist, fnoise, hrand, half_width,  # noqa: E402
                    validate, route_cost, composition, render_preview, DIRS)

ROOT = Path(__file__).resolve().parents[2]
# RL set: these ten are the reinforcement-learning battlefield set (kept apart
# from future hand-built "real" battlefields). Selected in-game only from the
# DEV map collection window.
SET_ID = "rl_canonical_v1"
DATA = ROOT / "data" / "battlefields" / SET_ID
LINE = ("infantry", "spearman", "archer")


# ======================================================================
# BF01 OPEN PLAIN
# ======================================================================
def bf01():
    m = Map("BF01", "open_plain", "Open Plain", "河北平原", 101)
    copses = [(-0.56, -0.04), (-0.27, 0.22), (0.34, 0.11), (0.59, -0.22), (-0.13, -0.19),
              (0.13, 0.41), (-0.60, 0.31), (0.64, 0.29), (-0.42, -0.44), (0.46, -0.46), (0.02, 0.62)]
    for i, (u, v) in enumerate(copses):
        m.blob(u, v, 0.026, 0.022, "F", rough=0.55, seed=i)
    m.blob(-0.36, 0.04, 0.026, 0.02, "M", rough=0.25, seed=40)     # low knoll, west
    m.blob(0.41, -0.07, 0.02, 0.018, "M", rough=0.25, seed=41)     # low knoll, east
    m.road([(-0.84, -0.30), (-0.30, -0.12), (0.20, 0.08), (0.84, 0.30)], wiggle=0.012, seed=1)
    m.road([(0.0, -0.95), (-0.08, -0.55), (-0.26, -0.13)], wiggle=0.01, seed=2)
    m.road([(0.0, 0.95), (0.08, 0.5), (0.14, 0.05)], wiggle=0.01, seed=3)
    for u, v in [(-0.52, -0.21), (0.55, 0.20), (0.15, 0.07), (-0.26, -0.13), (-0.22, 0.36), (0.30, -0.36)]:
        m.village(u, v)
    b, r = "blue", "red"
    m.group(b, 0.0, -0.62, ["hq"])
    m.group(b, -0.46, -0.30, ["cavalry", "cavalry", "cavalry", "scout"])
    m.group(b, -0.18, -0.32, ["infantry", "spearman", "archer"])
    m.group(b, 0.10, -0.32, ["infantry", "spearman", "archer", "conscript"])
    m.group(b, 0.42, -0.28, ["cavalry", "cavalry", "cavalry", "scout"])
    m.group(b, 0.0, -0.48, ["siege", "conscript", "archer"])
    m.group(r, 0.0, 0.62, ["hq"])
    m.group(r, -0.40, 0.30, ["infantry", "spearman", "archer"])
    m.group(r, -0.10, 0.31, ["infantry", "spearman", "spearman", "archer"])
    m.group(r, 0.20, 0.30, ["infantry", "spearman", "archer", "conscript"])
    m.group(r, 0.48, 0.28, ["cavalry", "cavalry", "scout"])
    m.group(r, 0.0, 0.46, ["conscript", "siege", "archer", "infantry"])
    return m, {
        "terrain": "Open plain (~96% plain): sparse 2-4 hex copses, two low knolls off-centre, one diagonal imperial road with two feeder roads, six hamlets.",
        "tactical": "Wide frontage and long sight lines; almost no natural defence. Flanks are open everywhere, so formation, reserves and cavalry timing decide the battle. No single hex dominates.",
        "asymmetry": "Terrain is near-neutral (knolls and hamlets are deliberately not mirrored). Force mix is not: BLUE is cavalry-heavy (6 CAV, 2 SCT), RED is infantry-heavy with a spear screen - mobility vs. mass.",
    }


# ======================================================================
# BF02 FOREST EDGE
# ======================================================================
def _edge_u(v, m):
    import math
    return -0.08 + 0.14 * math.sin(2.3 * v + 0.4)


def bf02():
    import math
    m = Map("BF02", "forest_edge", "Forest Edge", "松林緣", 202)
    s = m.seed
    m.paint(lambda u, v, c: u < _edge_u(v, m) + 0.05 * fnoise(u, v, s, 9.0), "F")
    # tongues of wood pushing into the open, and a few outliers
    for i, v in enumerate((-0.42, 0.30, 0.62)):
        m.blob(_edge_u(v, m) + 0.06, v, 0.05, 0.03, "F", rough=0.45, seed=10 + i)
    m.scatter("F", 0.012, region=lambda u, v: u > _edge_u(v, m) + 0.12, seed=3)
    # clearings inside the forest mass, linked by a hidden forest track
    for i, (u, v, rr) in enumerate([(-0.52, -0.26, 0.055), (-0.47, 0.20, 0.05), (-0.62, 0.02, 0.035)]):
        m.blob(u, v, rr, rr * 0.85, ".", rough=0.35, seed=20 + i, only=("F",))
    track = [(-0.30, -0.66), (-0.44, -0.44), (-0.52, -0.26), (-0.66, -0.10), (-0.62, 0.02), (-0.47, 0.20), (-0.42, 0.40), (-0.30, 0.58)]
    from bf_lib import chain
    m.set(chain(track, 0.035, s + 7, 9.0), ".")
    # edge road on the open side (the obvious axis) and a notch village at the edge
    m.road([(_edge_u(v / 20.0, m) + 0.075, v / 20.0) for v in range(-17, 18)], wiggle=0.006, seed=1)
    notch = (_edge_u(0.02, m) - 0.015, 0.02)
    m.blob(notch[0], notch[1], 0.035, 0.03, ".", rough=0.3, seed=30, only=("F",))
    m.village(*notch)
    m.village(0.45, -0.25)
    m.village(0.30, 0.48)
    m.village(-0.47, 0.20)
    m.blob(0.56, 0.04, 0.03, 0.022, "M", rough=0.3, seed=41)
    b, r = "blue", "red"
    m.group(b, 0.06, -0.62, ["hq"])
    m.group(b, 0.24, -0.33, ["infantry", "spearman", "archer", "spearman", "conscript"])
    m.group(b, 0.55, -0.32, ["cavalry", "cavalry", "scout"])
    m.group(b, -0.52, -0.26, ["scout", "archer", "infantry", "spearman"])
    m.group(b, -0.01, -0.34, ["infantry", "archer"])
    m.group(b, 0.15, -0.48, ["siege", "conscript"])
    m.group(r, 0.10, 0.62, ["hq"])
    m.group(r, notch[0] + 0.03, 0.05, ["infantry", "spearman", "archer"])
    m.group(r, 0.30, 0.30, ["infantry", "spearman", "archer", "conscript", "spearman"])
    m.group(r, 0.60, 0.22, ["cavalry", "cavalry", "cavalry"])
    m.group(r, -0.47, 0.20, ["scout", "archer", "infantry"], allow=(".", "F", "V"))
    m.group(r, 0.20, 0.47, ["siege", "conscript"])
    return m, {
        "terrain": "Plain meets a single heavy pine mass covering the west ~45% of the field; the edge snakes diagonally and throws tongues of wood into the open. A hidden forest track links three clearings; the edge road runs just outside the trees.",
        "tactical": "Open maneuver (east) against concealed, slow approach (west). Forest blocks sight at range 3+, costs 2 MP (scouts 1) and allows ambush; the notch village on the edge is the hinge both sides fight over.",
        "asymmetry": "Flank-asymmetric: the forest flank favours infantry/archer infiltration and ambush (RED has a picket in the northern clearing), the open east flank favours RED's 3-cavalry wing. BLUE must decide which flank to accept risk on.",
    }


# ======================================================================
# BF03 DEEP FOREST
# ======================================================================
def bf03():
    from bf_lib import chain
    m = Map("BF03", "deep_forest", "Deep Forest", "黑松林", 303, base="F")
    s = m.seed
    C = {"S": (0.0, -0.58, 0.07), "SW": (-0.45, -0.34, 0.05), "SE": (0.43, -0.30, 0.05),
         "W": (-0.56, 0.05, 0.045), "C": (0.02, 0.02, 0.095), "E": (0.50, 0.08, 0.05),
         "NW": (-0.35, 0.39, 0.05), "NE": (0.38, 0.40, 0.05), "N": (0.0, 0.60, 0.07)}
    for i, (k, (u, v, rr)) in enumerate(C.items()):
        m.blob(u, v, rr, rr * 0.85, ".", rough=0.35, seed=i)
    trails = [("S", "SW"), ("S", "SE"), ("SW", "W"), ("SE", "E"), ("W", "NW"), ("E", "NE"),
              ("C", "W"), ("C", "E"), ("NW", "N"), ("NE", "N")]
    for i, (a, b) in enumerate(trails):
        (au, av), (bu, bv) = C[a][:2], C[b][:2]
        L = ((bu - au) ** 2 + (bv - av) ** 2) ** 0.5
        k = (hrand(i, 7, s) - 0.5) * 0.45 * L          # bowed, not straight
        mid = ((au + bu) / 2 - (bv - av) / L * k, (av + bv) / 2 + (bu - au) / L * k)
        m.set(chain([(au, av), mid, (bu, bv)], 0.045, s + 40 + i, 9.0), ".")
    m.road([C["S"][:2], (0.03, -0.3), C["C"][:2]], wiggle=0.025, seed=1)
    m.road([C["C"][:2], (-0.03, 0.3), C["N"][:2]], wiggle=0.025, seed=2)
    m.blob(-0.58, 0.07, 0.03, 0.025, "S", rough=0.4, seed=60)          # bog in the west clearing
    m.blob(0.25, -0.12, 0.035, 0.03, "S", rough=0.4, seed=61, only=("F",))
    m.blob(-0.20, 0.20, 0.025, 0.022, "M", rough=0.3, seed=62, only=("F",))  # rocky knolls
    m.blob(0.26, 0.25, 0.02, 0.02, "M", rough=0.3, seed=63, only=("F",))
    m.village(0.03, 0.03)
    m.village(0.42, -0.31)
    b, r = "blue", "red"
    m.group(b, 0.0, -0.60, ["hq"])
    m.group(b, 0.0, -0.53, ["infantry", "spearman", "archer", "conscript", "siege"])
    m.group(b, -0.45, -0.34, ["scout", "infantry", "archer"])
    m.group(b, 0.43, -0.30, ["scout", "spearman", "infantry"])
    m.group(b, -0.22, -0.46, ["scout"], allow=("F",))
    m.group(b, 0.22, -0.44, ["scout"], allow=("F",))
    m.group(r, 0.0, 0.62, ["hq"])
    m.group(r, 0.0, 0.55, ["conscript", "siege", "archer"])
    m.group(r, 0.02, 0.06, ["infantry", "spearman", "archer"])
    m.group(r, -0.35, 0.39, ["infantry", "archer"])
    m.group(r, 0.38, 0.40, ["spearman", "scout", "infantry"])
    m.group(r, -0.56, 0.06, ["scout"])
    return m, {
        "terrain": "Unbroken pine forest (~92%) cut by nine clearings joined by one-hex trails; a forest road runs south-north through the central village clearing. Two bogs and two rocky knolls break the canopy.",
        "tactical": "Sight is broken everywhere (forest blocks LOS at 3+), so fights are local and sudden at clearing mouths and trail junctions. Every trail is a one-hex defile; the central clearing is the only place a line can deploy.",
        "asymmetry": "Information vs. position: RED already holds the central village clearing; BLUE fields 4 scouts (forest costs them 1 MP) to find gaps and bypass it along the side-trails.",
    }


# ======================================================================
# BF04 MOUNTAIN PASS
# ======================================================================
def bf04():
    from bf_lib import chain
    m = Map("BF04", "mountain_pass", "Mountain Pass", "雁門關", 404)
    s = m.seed
    m.paint(lambda u, v, c: -0.17 + 0.05 * fnoise(u, 0, s, 5) < v < 0.17 + 0.06 * fnoise(u, 1, s + 1, 5), "M")
    m.scatter("M", 0.16, region=lambda u, v: -0.27 < v < -0.12 or 0.12 < v < 0.26, seed=5)
    m.blob(-0.45, -0.28, 0.12, 0.05, "F", rough=0.4, seed=6, only=(".",))   # wooded south slopes
    m.blob(0.35, -0.26, 0.08, 0.04, "F", rough=0.4, seed=7, only=(".",))
    m.blob(-0.50, 0.30, 0.10, 0.05, "F", rough=0.4, seed=8, only=(".",))
    # the pass: road through the massif, floor widened to two hexes in places
    road = m.road([(0.0, -0.95), (0.0, -0.30), (-0.05, -0.15), (0.05, 0.0), (-0.03, 0.14), (0.02, 0.30), (0.0, 0.95)], seed=1)
    for c in road:
        u, v = UV[c]
        if -0.15 < v < 0.15 and hrand(c[0], c[1], s + 3) < 0.5:
            n = (c[0], c[1] + 1)
            if m.T.get(n) == "M":
                m.T[n] = "."
    # the alternative: a long goat track on the east flank (no road)
    m.set(chain([(0.55, -0.34), (0.63, -0.15), (0.55, 0.0), (0.64, 0.15), (0.56, 0.32)], 0.012, s + 9), ".")
    m.road([(0.0, -0.62), (-0.30, -0.46)], seed=2)
    m.road([(0.0, 0.5), (0.30, 0.50)], seed=3)
    for u, v in [(-0.31, -0.46), (0.36, -0.56), (0.31, 0.50), (-0.25, 0.46)]:
        m.village(u, v)
    m.stronghold("BF04_Yanmen_Fort", "안문관 (雁門關)", "fortress", "red", 0.09, 0.265)
    b, r = "blue", "red"
    m.group(b, 0.0, -0.64, ["hq"])
    m.group(b, 0.0, -0.40, ["infantry", "infantry", "spearman", "spearman", "archer", "archer", "conscript"])
    m.group(b, 0.08, -0.52, ["siege", "siege"])
    m.group(b, -0.25, -0.34, ["infantry", "spearman", "archer"])
    m.group(b, 0.50, -0.42, ["scout", "scout", "infantry", "archer", "spearman"])
    m.group(b, 0.20, -0.50, ["cavalry", "cavalry"])
    m.garrison("BF04_Yanmen_Fort", ["spearman", "archer", "infantry"])
    m.group(r, 0.0, 0.31, ["spearman", "infantry", "archer"])
    m.group(r, -0.07, 0.07, ["archer"], allow=("M",))
    m.group(r, 0.12, 0.05, ["archer"], allow=("M",))
    m.group(r, 0.56, 0.37, ["infantry", "archer", "scout"])
    m.group(r, 0.0, 0.50, ["cavalry", "cavalry", "conscript"])
    m.group(r, 0.0, 0.63, ["hq"])
    return m, {
        "terrain": "A continuous mountain wall (12-14 hexes deep) splits the field. One road pass winds through it (1-2 hex floor between pass walls); a long unmarked goat track crosses on the far east. Wooded south slopes, open plateau to the north.",
        "tactical": "Narrow strategic corridor with strong defensive geometry: the pass exit is covered by the Yanmen fort and archers on the pass walls (mountain: DEF x1.5, archer range +1, blocks sight). The goat track is the only real alternative - slower and far from support.",
        "asymmetry": "Strong defender advantage. RED holds the fort (3-unit garrison) and the pass mouth with ~16 units; BLUE brings ~25 including siege and must choose between forcing the pass and the long flank track.",
    }


# ======================================================================
# BF05 RIDGE & VALLEY
# ======================================================================
def bf05():
    m = Map("BF05", "ridge_valley", "Ridge and Valley", "三嶺", 505)
    s = m.seed
    ridges = [(-0.42, 0.034), (-0.02, 0.048), (0.38, 0.04)]
    for i, (c, w) in enumerate(ridges):
        m.band([(-1.0, c - 0.5), (1.0, c + 0.5)], w, "M", rough=0.35, seed=i, nscale=8.0)
    # wooded flanks under the crests
    for i, (c, w) in enumerate(ridges):
        m.band([(-1.0, c - 0.5), (1.0, c + 0.5)], w + 0.045, "F", rough=0.6, seed=10 + i, only=(".",))
    m.scatter(".", 0.45, only=("F",), seed=13)   # thin the woods so bands stay readable
    # saddles
    for i, (u, c) in enumerate([(0.30, -0.42), (-0.55, -0.42), (0.20, -0.02), (-0.45, -0.02), (0.60, -0.02), (0.0, 0.38), (-0.5, 0.38)]):
        m.blob(u, c + 0.5 * u, 0.035, 0.035, ".", rough=0.2, seed=20 + i, only=("M", "F"))
    # valley-floor stream (valley A) and roads
    m.river([(-0.95, -0.22 - 0.475), (0.95, -0.22 + 0.475)], wiggle=0.02, seed=1, wscale=6.0)
    m.road([(0.0, -0.95), (0.12, -0.52), (0.30, -0.27), (0.20, 0.08), (0.02, 0.37), (0.0, 0.95)], seed=1)
    m.road([(-0.95, 0.18 - 0.475), (0.95, 0.18 + 0.475)], wiggle=0.015, seed=2)
    for u, v in [(-0.36, -0.36), (0.46, 0.02), (-0.30, 0.04), (0.42, 0.40), (-0.22, 0.60)]:
        m.village(u, v)
    b, r = "blue", "red"
    m.group(b, 0.0, -0.64, ["hq"])
    m.group(b, 0.05, -0.56, ["siege", "conscript"])
    m.group(b, -0.05, -0.44, ["archer", "archer"], allow=("M",))
    m.group(b, -0.32, -0.34, ["infantry", "spearman", "archer"])
    m.group(b, 0.14, -0.16, ["infantry", "spearman", "archer", "conscript"])
    m.group(b, 0.50, 0.02, ["cavalry", "cavalry", "scout"])
    m.group(b, -0.60, -0.47, ["scout", "infantry"])
    m.group(r, 0.0, 0.64, ["hq"])
    m.group(r, 0.10, 0.56, ["siege", "conscript"])
    m.group(r, 0.36, 0.155, ["archer", "spearman", "infantry"], allow=("M",))
    m.group(r, -0.12, 0.13, ["infantry", "spearman", "archer", "conscript"])
    m.group(r, 0.45, 0.42, ["cavalry", "cavalry", "scout"])
    m.group(r, -0.22, 0.28, ["archer", "archer"], allow=("M",))
    return m, {
        "terrain": "Three long parallel ridges run diagonally (lower-left to upper-right) across the whole field, cut by saddles; wooded flanks, open valley floors. A stream runs down the first valley, a road down the second, and the main north road crosses every ridge through saddles.",
        "tactical": "High ground (DEF x1.5, archer range +1, blocks sight) against movement along the low valleys. The central ridge is the key terrain: whoever holds its crest sees and shoots into both adjacent valleys. Advancing straight means crossing ridges; the valleys pull movement diagonally toward the east.",
        "asymmetry": "RED already holds the east end of the central ridge and the third crest; BLUE holds the first crest and starts closer to the western saddles. The valleys favour whoever moves east first.",
    }


# ======================================================================
# BF06 RIVER CROSSING
# ======================================================================
def bf06():
    m = Map("BF06", "river_crossing", "River Crossing", "白馬渡", 606)
    s = m.seed
    river = m.river([(-0.9, 0.0), (-0.52, 0.10), (-0.20, -0.02), (0.15, 0.08), (0.50, 0.0), (0.9, 0.10)], wiggle=0.02, seed=1)
    rv = {}
    for c in river:
        u, v = UV[c]
        rv[round(u, 2)] = v

    def river_v(u):
        k = min(rv, key=lambda x: abs(x - u))
        return rv[k]
    pts = [UV[c] for c in river]
    # floodplain marsh: wide on the north (RED) bank, patchy on the south bank
    def marsh(u, v, c):
        d = poly_dist(u, v, pts)
        north = v > river_v(u)
        lim = 0.085 if north else 0.04
        return 0.012 < d < lim * (1.0 + 0.35 * fnoise(u, v, s + 3, 9.0))
    m.paint(marsh, "S", only=(".",))
    # crossings: two bridges on roads, one ford (no marsh on either bank)
    m.blob(-0.02, river_v(-0.02), 0.06, 0.07, ".", rough=0.2, seed=4, only=("S",))
    m.road([(0.0, -0.95), (0.0, -0.58)], seed=1)
    m.road([(0.0, -0.58), (-0.18, -0.40), (-0.36, -0.18), (-0.36, 0.20), (-0.20, 0.42), (0.0, 0.50)], seed=2)
    m.road([(0.0, -0.58), (0.20, -0.40), (0.34, -0.18), (0.36, 0.20), (0.18, 0.42), (0.0, 0.50)], seed=3)
    m.road([(0.0, 0.50), (0.0, 0.95)], seed=4)
    m.blob(-0.62, -0.22, 0.10, 0.06, "F", rough=0.45, seed=5, only=(".",))
    m.blob(0.62, 0.32, 0.09, 0.06, "F", rough=0.45, seed=6, only=(".",))
    m.blob(0.55, -0.40, 0.05, 0.04, "F", rough=0.45, seed=7, only=(".",))
    m.blob(-0.45, 0.45, 0.05, 0.04, "F", rough=0.45, seed=8, only=(".",))
    for u, v in [(0.44, river_v(0.44) + 0.13), (-0.44, -0.22), (0.01, 0.50), (0.24, -0.46), (-0.28, 0.30)]:
        m.village(u, v)
    b, r = "blue", "red"
    m.group(b, 0.0, -0.64, ["hq"])
    m.group(b, -0.30, -0.36, ["infantry", "spearman", "archer", "conscript"])
    m.group(b, 0.30, -0.36, ["infantry", "infantry", "spearman", "archer"])
    m.group(b, 0.12, -0.52, ["siege", "siege"])
    m.group(b, 0.0, -0.32, ["scout", "scout", "cavalry", "cavalry", "archer"])
    m.group(r, 0.0, 0.62, ["hq"])
    m.group(r, 0.37, river_v(0.36) + 0.07, ["spearman", "infantry", "archer", "archer"])
    m.group(r, -0.34, river_v(-0.36) + 0.08, ["infantry", "archer", "spearman"])
    m.group(r, 0.0, river_v(0.0) + 0.10, ["archer", "scout"])
    m.group(r, 0.05, 0.38, ["cavalry", "cavalry", "conscript", "infantry"])
    return m, {
        "terrain": "A single river crosses the full width of the field, with a wide marsh floodplain on the north bank and patchy marsh on the south. Two roads converge on two bridges; one dry ford sits between them. The roads rejoin at a market town behind the river.",
        "tactical": "Crossing concentration: every crossing puts the unit into a RED march (river rule) and the marsh (2 MP) funnels approaches onto the bridge causeways and the ford. The defender can mass archers on the few dry exits.",
        "asymmetry": "Defender advantage along the river. RED is strongest at the east bridge (nearest its town) and thin at the ford; BLUE has more troops, siege and cavalry but must commit to one or two crossings.",
    }


# ======================================================================
# BF07 FORTIFIED APPROACH
# ======================================================================
def bf07():
    m = Map("BF07", "fortified_approach", "Fortified Approach", "潼關", 707)
    s = m.seed
    m.band([(-0.86, 0.03), (-0.36, 0.25), (-0.10, 0.41)], 0.05, "M", rough=0.3, seed=1)
    m.band([(0.86, -0.02), (0.40, 0.22), (0.12, 0.41)], 0.055, "M", rough=0.3, seed=2)
    m.scatter("M", 0.10, region=lambda u, v: u > 0.35 and v > 0.2, seed=3)
    m.blob(-0.57, 0.40, 0.16, 0.13, "F", rough=0.35, seed=4, only=(".",))   # flank wood behind the west arm
    m.blob(-0.21, 0.335, 0.03, 0.03, ".", rough=0.1, seed=5, only=("M",))   # the west saddle
    for i, (u, v) in enumerate([(-0.18, -0.06), (0.22, 0.03), (-0.45, -0.35), (0.40, -0.40), (0.05, -0.48)]):
        m.blob(u, v, 0.025, 0.02, "F", rough=0.5, seed=10 + i, only=(".",))
    m.road([(0.0, -0.95), (0.0, 0.335)], wiggle=0.008, seed=1)
    m.road([(-0.07, 0.44), (-0.02, 0.62), (0.0, 0.95)], seed=2)
    m.band([(-0.26, 0.20), (0.26, 0.20)], 0.018, "S", rough=0.3, seed=6, only=(".",))  # flooded paddies
    m.stronghold("BF07_Tong_Fortress", "동관 (潼關)", "fortress", "red", 0.0, 0.385, hp=1200)
    for u, v in [(-0.11, 0.17), (0.14, 0.18), (-0.30, -0.30), (0.30, -0.28), (0.55, 0.40)]:
        m.village(u, v)
    b, r = "blue", "red"
    m.group(b, 0.0, -0.64, ["hq"])
    m.group(b, 0.0, -0.36, ["infantry", "infantry", "infantry", "spearman", "spearman", "archer", "archer", "conscript", "conscript"])
    m.group(b, 0.03, -0.50, ["siege", "siege", "siege"])
    m.group(b, -0.40, -0.25, ["infantry", "spearman", "archer", "scout"])
    m.group(b, 0.40, -0.30, ["cavalry", "cavalry", "cavalry", "scout"])
    m.garrison("BF07_Tong_Fortress", ["spearman", "archer", "infantry"])
    m.group(r, -0.11, 0.19, ["archer", "spearman"])
    m.group(r, 0.14, 0.20, ["archer", "infantry"])
    m.group(r, 0.14, 0.34, ["spearman"])
    m.group(r, -0.13, 0.35, ["infantry"])
    m.group(r, -0.22, 0.37, ["archer"])
    m.group(r, 0.0, 0.62, ["hq", "cavalry", "cavalry", "conscript"])
    return m, {
        "terrain": "Two mountain arms form a funnel that narrows onto one fortress standing on the apex (one visual hex). The funnel floor is an open glacis with two outpost hamlets and a line of flooded paddies; a thick wood lies outside the west arm and ends at a small saddle beside the fortress.",
        "tactical": "Prepared-position assault. The only wide approach is the killing ground up the funnel road; the west wood + saddle is a concealed but long flanking route; the east arm is solid rock.",
        "asymmetry": "Intentionally defender-favoured: RED holds the Tong fortress (1200 HP, 3 garrison) and forward outposts with ~13 units. BLUE attacks with ~24 units including 3 siege engines.",
    }


# ======================================================================
# BF08 BASIN TRAP
# ======================================================================
def bf08():
    import math
    m = Map("BF08", "basin_trap", "Basin Trap", "狼谷盆地", 808)
    s = m.seed
    cu, cv, ru, rv = 0.0, -0.08, 0.34, 0.36

    def nd(u, v):
        return math.hypot((u - cu) / ru, (v - cv) / rv)
    m.paint(lambda u, v, c: 1.0 + 0.08 * fnoise(u, v, s, 7) < nd(u, v) < 1.42 + 0.12 * fnoise(u, v, s + 1, 6), "M")
    m.scatter("M", 0.18, region=lambda u, v: 1.42 < nd(u, v) < 1.62, seed=2)
    m.blob(0.12, -0.02, 0.06, 0.05, "S", rough=0.35, seed=3)                  # the basin's wet low point
    for i, (u, v) in enumerate([(-0.18, -0.25), (0.20, -0.30), (-0.22, 0.12)]):
        m.blob(u, v, 0.03, 0.025, "F", rough=0.5, seed=10 + i, only=(".",))
    for i, (u, v, rr) in enumerate([(-0.55, 0.40, 0.09), (0.60, 0.35, 0.08), (0.62, -0.30, 0.06), (-0.62, -0.25, 0.07)]):
        m.blob(u, v, rr, rr * 0.8, "F", rough=0.4, seed=20 + i, only=(".",))

    def gate(angle, wide):
        a = math.radians(angle)
        p0 = (cu + math.cos(a) * ru * 0.85, cv + math.sin(a) * rv * 0.85)
        p1 = (cu + math.cos(a) * ru * 1.75, cv + math.sin(a) * rv * 1.75)
        from bf_lib import chain
        cells = chain([p0, p1], 0.0, s)
        m.set(cells, ".")
        if wide:
            m.set([(c[0], c[1] + 1) for c in cells if m.T.get((c[0], c[1] + 1)) == "M"], ".")
        return p0, p1
    gate(-90, True)          # south gate: the escape route
    gate(125, False)
    gate(55, False)
    gate(-8, False)          # east goat track (no road)
    centre = (cu - 0.04, cv - 0.02)
    m.road([(0.0, -0.95), (0.0, -0.44), centre], seed=1)
    m.road([centre, (-0.20, 0.20), (-0.32, 0.40), (-0.30, 0.95)], seed=2)
    m.road([centre, (0.20, 0.20), (0.32, 0.40), (0.30, 0.95)], seed=3)
    m.village(*centre)
    for u, v in [(-0.45, 0.55), (0.45, 0.55), (0.0, 0.70), (0.25, -0.65)]:
        m.village(u, v)
    b, r = "blue", "red"
    m.group(b, 0.0, -0.36, ["hq"])
    m.group(b, 0.05, -0.29, ["siege"])
    m.group(b, -0.13, -0.20, ["infantry", "spearman", "archer", "conscript"])
    m.group(b, 0.15, -0.18, ["infantry", "spearman", "archer"])
    m.group(b, 0.0, 0.07, ["infantry", "spearman", "cavalry", "cavalry", "archer"])
    m.group(b, -0.22, 0.02, ["scout", "archer"])
    m.group(r, -0.40, 0.46, ["infantry", "spearman", "archer", "cavalry"])
    m.group(r, 0.40, 0.46, ["infantry", "spearman", "archer", "cavalry"])
    m.group(r, 0.60, -0.10, ["cavalry", "cavalry", "scout"])
    m.group(r, 0.40, -0.06, ["archer", "archer"], allow=("M",))
    m.group(r, 0.36, -0.58, ["infantry", "cavalry", "spearman"])
    m.group(r, 0.0, 0.66, ["hq", "conscript", "siege"])
    return m, {
        "terrain": "A round central basin (open floor, wet low point, a village at the road hub) ringed by a 5-7 hex mountain wall. Four gaps: a wide south gate, two narrow north-west / north-east road gaps, and an unroaded east goat track.",
        "tactical": "The basin reads as a bowl from HIGH. The force inside has interior lines but can be pressed from several gaps at once, and the rim (mountain: DEF x1.5, archer +1, blocks sight) looks down into it. The south gate is the only wide escape route - and it is threatened.",
        "asymmetry": "Positional: BLUE starts concentrated inside the basin; RED holds exterior lines in four detachments (NW, NE, E rim, and a south-east group aimed at the escape gate). Numbers are close; geometry is not.",
    }


# ======================================================================
# BF09 SPLIT FRONT
# ======================================================================
def bf09():
    m = Map("BF09", "split_front", "Split Front", "三路", 909)
    s = m.seed
    # east separator: a long ridge with a forest skirt and one saddle
    ridge = [(0.30, -0.32), (0.25, 0.08), (0.32, 0.50), (0.22, 0.80)]
    m.band(ridge, 0.032, "M", rough=0.3, seed=1)
    m.band(ridge, 0.075, "F", rough=0.4, seed=2, only=(".",))
    m.blob(0.26, 0.08, 0.035, 0.03, ".", rough=0.1, seed=3, only=("M", "F"))
    # east sector: broken hills
    m.scatter("M", 0.12, region=lambda u, v: u > 0.40 and -0.3 < v < 0.55, seed=4)
    m.scatter("F", 0.12, region=lambda u, v: u > 0.40 and -0.3 < v < 0.55, seed=5)
    # west separator: a river from the north edge bending out through the west edge
    river = m.river([(-0.22, 0.84), (-0.32, 0.45), (-0.25, 0.08), (-0.33, -0.24), (-0.45, -0.46), (-0.62, -0.62)], wiggle=0.02, seed=1)
    pts = [UV[c] for c in river]
    m.paint(lambda u, v, c: 0.012 < poly_dist(u, v, pts) < 0.04 * (1 + 0.5 * fnoise(u, v, s + 6, 9)) and v > -0.3, "S", only=(".",))
    m.blob(-0.28, 0.24, 0.04, 0.05, ".", rough=0.2, seed=7, only=("S",))      # west ford
    # roads: one per sector
    m.road([(0.0, -0.95), (0.02, 0.0), (0.0, 0.34)], seed=1)
    m.road([(-0.05, 0.48), (0.0, 0.95)], seed=2)
    m.road([(0.0, -0.62), (-0.25, -0.52), (-0.42, -0.38), (-0.55, 0.10), (-0.45, 0.42), (-0.30, 0.66)], seed=3)
    m.road([(0.02, -0.55), (0.45, -0.35), (0.55, 0.20), (0.40, 0.55)], wiggle=0.01, seed=4)
    m.stronghold("BF09_Center_Fort", "중로 요새 (中路砦)", "fortress", "red", 0.0, 0.40)
    for u, v in [(-0.55, 0.10), (-0.60, -0.15), (0.55, 0.20), (0.12, -0.20), (-0.13, 0.62)]:
        m.village(u, v)
    for i, (u, v) in enumerate([(-0.10, -0.05), (0.12, 0.22), (-0.62, 0.30), (0.05, -0.62)]):
        m.blob(u, v, 0.025, 0.02, "F", rough=0.5, seed=20 + i, only=(".",))
    b, r = "blue", "red"
    m.group(b, 0.0, -0.64, ["hq"])
    m.group(b, 0.0, -0.40, ["infantry", "infantry", "spearman", "spearman", "archer", "archer", "conscript"])
    m.group(b, 0.06, -0.54, ["siege"])
    m.group(b, -0.15, -0.50, ["cavalry", "cavalry", "cavalry"])
    m.group(b, 0.20, -0.46, ["scout", "scout", "infantry", "archer"])
    m.garrison("BF09_Center_Fort", ["spearman", "archer", "infantry"])
    m.group(r, 0.0, 0.30, ["infantry", "spearman", "archer", "conscript"])
    m.group(r, -0.55, 0.30, ["infantry", "archer", "cavalry"])
    m.group(r, 0.56, 0.36, ["spearman", "archer", "scout", "infantry"], allow=(".", "R", "F", "V", "M"))
    m.group(r, 0.02, 0.62, ["hq", "siege", "cavalry"])
    return m, {
        "terrain": "Two different barriers split the front into three sectors: a marsh-banked river in the west (one bridge in BLUE's rear, one ford) and a long wooded ridge in the east (one saddle). West = open farmland with villages, centre = road corridor to a fort, east = broken hills.",
        "tactical": "Concentration vs. dispersion. Each sector has its own objective and its own terrain; lateral movement between sectors is slow (river/ford, ridge/saddle) so a force committed to one sector cannot easily help another. The shared rear areas keep it one battlefield.",
        "asymmetry": "RED is spread over all three sectors with the fort as a strong centre; BLUE starts concentrated in the centre rear with a mobile cavalry reserve and must decide where to mass.",
    }


# ======================================================================
# BF10 MIXED FRONTIER
# ======================================================================
def bf10():
    m = Map("BF10", "mixed_frontier", "Mixed Frontier", "幽州邊", 1010)
    s = m.seed
    m.blob(-0.56, 0.0, 0.26, 0.44, "F", rough=0.25, rot=12, seed=1)          # the western wood
    m.blob(-0.52, -0.10, 0.06, 0.05, ".", rough=0.3, seed=2, only=("F",))     # a clearing
    m.blob(0.62, 0.15, 0.20, 0.28, "M", rough=0.3, seed=3)                     # the eastern hills
    m.scatter("M", 0.2, region=lambda u, v: u > 0.35 and -0.3 < v < 0.5, seed=4)
    m.scatter("F", 0.15, region=lambda u, v: u > 0.30 and -0.35 < v < 0.5, seed=5)
    river = m.river([(0.64, 0.62), (0.30, 0.45), (0.0, 0.38), (-0.16, 0.34), (-0.36, 0.23), (-0.60, 0.26), (-0.9, 0.22)], wiggle=0.015, seed=1)
    m.blob(-0.45, 0.30, 0.10, 0.04, "S", rough=0.4, seed=6, only=(".", "F"))   # river marsh by the wood
    m.road([(0.0, -0.95), (-0.05, -0.30), (0.02, 0.17)], seed=1)
    m.road([(0.06, 0.26), (0.03, 0.50), (0.0, 0.95)], seed=2)
    m.road([(0.40, -0.52), (0.52, -0.18), (0.50, 0.12), (0.10, 0.22)], wiggle=0.01, seed=3)
    m.road([(0.0, -0.62), (0.40, -0.52)], seed=4)
    m.stronghold("BF10_Fanyang", "범양 (范陽)", "capital", "red", 0.03, 0.215, hp=1500, slots=6)
    for u, v in [(-0.16, -0.36), (0.22, -0.22), (0.52, -0.18), (-0.22, 0.55), (0.30, 0.62)]:
        m.village(u, v)
    for i, (u, v) in enumerate([(0.12, -0.05), (-0.18, 0.05), (0.08, -0.45)]):
        m.blob(u, v, 0.025, 0.02, "F", rough=0.5, seed=20 + i, only=(".",))
    b, r = "blue", "red"
    m.group(b, 0.0, -0.64, ["hq"])
    m.group(b, 0.0, -0.40, ["infantry", "infantry", "spearman", "spearman", "archer", "archer", "conscript"])
    m.group(b, 0.05, -0.53, ["siege", "siege"])
    m.group(b, -0.36, -0.32, ["scout", "infantry", "archer", "spearman"], allow=(".", "F", "R", "V"))
    m.group(b, 0.36, -0.48, ["cavalry", "cavalry", "scout", "infantry"])
    m.garrison("BF10_Fanyang", ["infantry", "spearman", "archer"])
    m.group(r, 0.0, 0.11, ["spearman", "archer"])
    m.group(r, 0.55, 0.10, ["archer", "archer", "infantry"], allow=("M", ".", "F"))
    m.group(r, -0.30, 0.10, ["scout", "infantry"], allow=(".", "F"))
    m.group(r, 0.05, 0.50, ["cavalry", "cavalry", "conscript", "spearman"])
    m.group(r, 0.0, 0.66, ["hq", "siege"])
    return m, {
        "terrain": "Combined frontier: open farmland in the south, a great wood in the west, broken hills in the east, a river across the north that comes out of the hills, marsh where it meets the wood, and the walled town of Fanyang at the road junction in the middle.",
        "tactical": "Each region has a job: the plain is the direct approach and a killing ground; the wood is a concealed western approach; the hills overlook the eastern hill road; the river shields the town's rear and RED's reinforcements must use the single bridge. Fanyang (capital) is the objective.",
        "asymmetry": "Central-objective control: RED holds the town (6-slot capital, 3 garrison) plus hill archers and a reserve behind the river; BLUE has the numbers and three approach axes but only one of them is fast.",
    }


BUILDERS = [bf01, bf02, bf03, bf04, bf05, bf06, bf07, bf08, bf09, bf10]


def build(ids, preview_dir, check=False):
    """check=True: regenerate in memory and compare with the files on disk
    (reproducibility guard for the frozen RL set); nothing is written."""
    DATA.mkdir(parents=True, exist_ok=True)
    report = {}
    ok = True
    manifest = []
    for fn in BUILDERS:
        m, info = fn()
        if ids and m.id not in ids:
            continue
        m.tidy_roads()
        errs = validate(m)
        bhq = next(u for u in m.units if u["faction"] == "blue" and u["class"] == "hq")
        rhq = next(u for u in m.units if u["faction"] == "red" and u["class"] == "hq")
        cost, path = route_cost(m, (bhq["q"], bhq["r"]), (rhq["q"], rhq["r"]))
        info = dict(info)
        info["composition_pct"] = composition(m)
        info["units"] = {"blue": sum(1 for u in m.units if u["faction"] == "blue"),
                         "red": sum(1 for u in m.units if u["faction"] == "red")}
        info["hq_route_cost_std"] = round(cost, 1)
        info["hq_distance_hexes"] = hex_dist((bhq["q"], bhq["r"]), (rhq["q"], rhq["r"]))
        out = DATA / ("%s_%s.json" % (m.id.lower(), m.slug))
        text = json.dumps(m.to_json(info), ensure_ascii=False, indent=1)
        data = text.encode("utf-8")
        if check:
            same = out.exists() and out.read_bytes() == data
            if not same:
                errs = errs + ["file on disk differs from a fresh build"]
        else:
            out.write_bytes(data)
        manifest.append({"id": m.id, "file": out.name, "sha256": hashlib.sha256(data).hexdigest(),
                         "units": info["units"], "strongholds": [s_["id"] for s_ in m.strongholds]})
        if preview_dir:
            Path(preview_dir).mkdir(parents=True, exist_ok=True)
            render_preview(m, Path(preview_dir) / ("%s_%s.png" % (m.id.lower(), m.slug)), route=path)
        report[m.id] = {"errors": errs, **{k: info[k] for k in ("units", "hq_route_cost_std", "hq_distance_hexes", "composition_pct")}}
        print("%s %-20s units B%d/R%d route %.1f dist %d  %s" % (
            m.id, m.slug, info["units"]["blue"], info["units"]["red"], cost, info["hq_distance_hexes"],
            "OK" if not errs else "ERRORS: " + "; ".join(errs[:6])))
        ok = ok and not errs
    if not ids:
        man = {"set": SET_ID, "purpose": "rl", "format": "canonical_battlefield_v1",
               "generator": "tools/battlefields/build_canonical_battlefields.py", "maps": manifest}
        mpath = DATA / "SET_MANIFEST.json"
        mtext = json.dumps(man, ensure_ascii=False, indent=1).encode("utf-8")
        if check:
            if not (mpath.exists() and mpath.read_bytes() == mtext):
                print("SET_MANIFEST.json differs from a fresh build")
                ok = False
        else:
            mpath.write_bytes(mtext)
    return ok, report


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("ids", nargs="*")
    ap.add_argument("--preview-dir", default="")
    ap.add_argument("--check", action="store_true", help="verify the files on disk match a fresh build")
    a = ap.parse_args()
    good, _ = build([i.upper() for i in a.ids], a.preview_dir, a.check)
    if a.check:
        print("CHECK", "OK: set is reproducible" if good else "FAILED")
    sys.exit(0 if good else 1)
