"""Author HC01 Cheongha Gorge for the live battle shell.

The geography and encounter axes below are fixed design choices. This script
serializes them into the game's existing radius-40 terrain schema; it never
touches the frozen RL battlefield set.
"""
from __future__ import annotations

import json
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from bf_lib import (CELLS, DIRS, Map, UV, composition, hex_dist, hexline,
                    nearest, playable, render_preview, route_cost, validate)

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "data" / "battlefields" / "handcrafted_v1" / "hc01_cheongha_gorge.json"
PREVIEW = ROOT / "evidence" / "handcrafted_v1" / "hc01_layout.png"


def along(m: Map, *stops):
    """Paint one connected authored road through exact axial waypoints."""
    cells = []
    for a, b in zip(stops, stops[1:]):
        segment = hexline(a, b)
        cells.extend(segment if not cells else segment[1:])
    m.road_cells(cells)


def nearest_on_chain(m: Map, desired_u: float):
    return min(m.rivers[0], key=lambda c: abs(UV[c][0] - desired_u))


def bank_neighbors(m: Map, bridge):
    river = set(m.rivers[0])
    candidates = [(bridge[0] + dq, bridge[1] + dr) for dq, dr in DIRS]
    south = min((c for c in candidates if c in m.T and c not in river),
                key=lambda c: UV[c][1])
    north = max((c for c in candidates if c in m.T and c not in river),
                key=lambda c: UV[c][1])
    assert UV[south][1] < UV[bridge][1] < UV[north][1]
    return south, north


def main():
    m = Map("HC01", "cheongha_gorge", "청하 협곡", "Cheongha Gorge", 20261002)

    # 1. Two readable flanks: a layered forest on the western lowland and a
    # broad eastern massif with a deliberately open saddle for the pass road.
    m.blob(-0.53, -0.17, 0.23, 0.49, "F", rough=0.08, rot=-8, seed=1)
    m.blob(-0.36, 0.33, 0.19, 0.26, "F", rough=0.07, rot=22, seed=2)
    m.blob(0.54, 0.18, 0.24, 0.52, "M", rough=0.07, rot=14, seed=3)
    m.blob(0.42, -0.36, 0.14, 0.27, "M", rough=0.05, rot=-13, seed=4)
    m.band([(0.39, -0.60), (0.37, -0.20), (0.38, 0.12), (0.43, 0.54)],
           0.044, ".", rough=0.0, only=("M",))
    # Forest edge and floodplain are tactical cover/slow ground, while the
    # centre and BLUE deployment keep open room for manoeuvre.
    m.band([(-0.68, -0.18), (-0.23, -0.05), (0.20, 0.035), (0.71, 0.14)],
           0.045, "S", rough=0.0, only=(".",))
    m.blob(-0.19, 0.22, 0.12, 0.10, "F", rough=0.0, seed=5, only=(".",))

    # 2. The Cheongha crosses the whole tactical middle. Only the two
    # designated bridge cells become road+river cells; the rest remains fordable
    # under the existing river movement rule, with slower marsh approaches.
    m.river([(-0.80, -0.13), (-0.54, -0.10), (-0.30, -0.035),
             (0.02, 0.015), (0.33, 0.07), (0.70, 0.16), (0.78, 0.20)],
            wiggle=0.0)
    west_bridge = nearest_on_chain(m, -0.28)
    east_bridge = nearest_on_chain(m, 0.31)
    assert hex_dist(west_bridge, east_bridge) >= 12
    west_south, west_north = bank_neighbors(m, west_bridge)
    east_south, east_north = bank_neighbors(m, east_bridge)

    # 3. Two attack routes start together, divide before the river and reunite
    # at the northern market. A forest detour and the eastern saddle provide
    # different cover/cost profiles without dead-end roads.
    blue_gate = nearest(0.00, -0.77)
    south_fork = nearest(0.00, -0.36)
    west_stage = nearest(-0.27, -0.19)
    east_stage = nearest(0.31, -0.17)
    north_join = nearest(0.04, 0.33)
    capital_approach = nearest(0.07, 0.58)
    along(m, blue_gate, south_fork)
    along(m, south_fork, west_stage, west_south, west_bridge, west_north, north_join)
    along(m, south_fork, east_stage, east_south, east_bridge, east_north, north_join)
    along(m, north_join, capital_approach, nearest(0.05, 0.78))
    along(m, nearest(-0.55, -0.54), nearest(-0.49, -0.25), west_stage)
    along(m, nearest(0.41, -0.64), nearest(0.38, -0.31), east_stage)
    along(m, east_north, nearest(0.44, 0.31), nearest(0.41, 0.58))

    # Keep precisely the two authored bridges. Some direct hex-line joins can
    # graze the river at one extra cell; return those accidental crossings to
    # water before checking the connected road graph.
    selected_bridges = {west_bridge, east_bridge}
    for c, terrain in list(m.T.items()):
        if terrain == "B" and c not in selected_bridges:
            m.T[c] = "W"
    assert {c for c, t in m.T.items() if t == "B"} == selected_bridges

    # 4. Villages mark the approach rhythm; the capital is the primary goal.
    # The small eastern fort guards the hill route without sealing the pass.
    m.village(-0.51, -0.56)
    m.village(0.11, -0.46)
    m.village(-0.13, 0.34)
    m.village(0.29, 0.43)
    m.stronghold("HC01_Saddle_Fort", "동령 보루", "fortress", "red", 0.52, 0.38,
                 hp=1000, slots=4)
    m.stronghold("HC01_Cheongha_Capital", "청하성", "capital", "red", 0.06, 0.66,
                 hp=1500, slots=6)
    # The capital footprint replaces the straight road. Route its northern
    # continuation along the western wall so the HQ approach remains connected.
    m.road_cells([(24, 3), (24, 2), (25, 2), (26, 2), (27, 2)])

    # 5. Opening forces have three clear tasks: BLUE centre fixes the bridges,
    # woods flank pressures west, cavalry probes the saddle. RED has a bridge
    # line, a hill fort and an identifiable capital reserve.
    m.unit_at("blue", "hq", blue_gate)
    m.group("blue", -0.04, -0.56,
            ["infantry", "infantry", "spearman", "archer", "siege", "conscript"])
    m.group("blue", -0.45, -0.37,
            ["scout", "infantry", "spearman", "archer", "conscript"])
    m.group("blue", 0.36, -0.49,
            ["cavalry", "cavalry", "scout", "spearman"])

    m.unit_at("red", "hq", nearest(0.05, 0.80))
    m.garrison("HC01_Cheongha_Capital", ["infantry", "spearman", "archer"])
    m.garrison("HC01_Saddle_Fort", ["spearman", "archer"])
    m.group("red", -0.23, 0.18,
            ["infantry", "archer", "spearman", "scout"])
    m.group("red", 0.30, 0.23,
            ["infantry", "archer", "cavalry"])
    m.group("red", 0.12, 0.57, ["infantry", "siege"])

    errs = validate(m)
    assert not errs, "\n".join(errs)
    assert len(m.T) == 4921
    assert sum(u["faction"] == "blue" for u in m.units) == 16
    assert sum(u["faction"] == "red" for u in m.units) == 15
    hq_blue = next(u for u in m.units if u["faction"] == "blue" and u["class"] == "hq")
    hq_red = next(u for u in m.units if u["faction"] == "red" and u["class"] == "hq")
    hq_cost, hq_route = route_cost(m, (hq_blue["q"], hq_blue["r"]),
                                   (hq_red["q"], hq_red["r"]))
    assert math.isfinite(hq_cost)

    info = {
        "terrain": "청하강이 전장 중앙을 가로지르고 서쪽 숲과 동쪽 산줄기가 두 접근로를 만든다. 두 다리, 습지, 산길, 네 마을과 두 성채가 이어진다.",
        "tactical": "남쪽에서 출발한 청군은 서쪽 숲길과 동쪽 고갯길 중 병력을 배분해 두 다리를 건넌다. 북쪽 수비군은 교두보와 청하성을 지킨다.",
        "asymmetry": "BLUE has a flexible three-pronged advance; RED starts with bridge guards, a hill fort and capital garrisons.",
        "composition_pct": composition(m),
        "units": {"blue": 16, "red": 15},
        "hq_route_cost_std": hq_cost,
        "hq_distance_hexes": hex_dist((hq_blue["q"], hq_blue["r"]),
                                      (hq_red["q"], hq_red["r"])),
        "bridges": [list(west_bridge), list(east_bridge)],
    }
    data = m.to_json(info)
    data.update({"set": "handcrafted_v1", "purpose": "handcrafted_playable",
                 "generator": "tools/battlefields/build_handcrafted_cheongha.py"})
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(data, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    PREVIEW.parent.mkdir(parents=True, exist_ok=True)
    render_preview(m, PREVIEW, route=hq_route)
    print(f"HC01 PASS cells={len(m.T)} blue=16 red=15 bridges={info['bridges']} "
          f"hq_cost={hq_cost:.1f} roads={sum(t in ('R','B') for t in m.T.values())} "
          f"river={sum(t in ('W','B') for t in m.T.values())}")
    print(OUT)
    print(PREVIEW)


if __name__ == "__main__":
    main()
