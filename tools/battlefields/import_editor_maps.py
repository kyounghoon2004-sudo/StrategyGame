#!/usr/bin/env python3
"""Import Schema v1 editor maps into canonical gameplay battlefield format (editor_v1).

Maps editor JSON (radius 20 axial hex disk) into game battlefield format compatible
with TutorialBattlefieldCatalog and Step2RBattlefieldShell.

Terrain Precedence:
  fort/castle (X, 9) > building (V, 5) > mountain/hill (M, 1) > water (W, 7) >
  road/bridge (R, 6) > forest/tree (F, 2) > farm (., 0) > plains (., 0)

Bridges (wooden_bridge, stone_bridge) are mapped to ROAD ('R', 6) and added to river_cells.
Water (including shallow_ford) is mapped to RIVER ('W', 7) and added to river_cells.
Fort and castle footprints become strongholds (type fortress/capital).
"""

from __future__ import annotations

import json
from pathlib import Path
from collections import Counter


ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = ROOT / "data" / "battlefields" / "editor_v1"

MAP_SOURCES = {
    "m1": {
        "id": "EDITOR_M1",
        "name": "M1 (River Roads)",
        "name_zh": "河流道路",
        "source": Path(r"D:\StrategyGame_Transfer\maps\map_river_roads_20261028.json"),
    },
    "m2": {
        "id": "EDITOR_M2",
        "name": "M2 (Gate Fort Polished)",
        "name_zh": "關門要塞",
        "source": Path(r"D:\StrategyGame_Transfer\maps\map_m2_gate_fort_polished_20261029.json"),
    },
    "m3": {
        "id": "EDITOR_M3",
        "name": "M3 (Open Battle)",
        "name_zh": "曠野交戰",
        "source": Path(r"D:\StrategyGame_Transfer\maps\map_1793259718_132100896.json"),
    },
    "m4": {
        "id": "EDITOR_M4",
        "name": "M4 (Roads & Forts)",
        "name_zh": "道路要塞",
        "source": Path(r"D:\StrategyGame_Transfer\maps\map_1793262735_49462960.json"),
    },
    "m5": {
        "id": "EDITOR_M5",
        "name": "M5 (Fortified Frontier)",
        "name_zh": "要塞前線",
        "source": Path(r"D:\StrategyGame_Transfer\maps\map_1793266255_19431872.json"),
    },
}

RADIUS = 20
WIDTH = RADIUS * 2 + 1
HEIGHT = RADIUS * 2 + 1
Q_MIN = -RADIUS
R_MIN = -RADIUS

# Precedence rank (lower number = higher precedence)
# fort/castle > building > mountain/hill > water > road > forest/tree > farm > plains
def classify_object(obj: dict) -> tuple[int, int, str, bool]:
    """Return (precedence_rank, terrain_id, glyph, is_river_cell)."""
    kind = str(obj.get("kind", ""))
    variant = str(obj.get("variant", ""))

    if kind in ("fort", "castle"):
        # Stronghold footprint: impassable, blocks supply
        return (1, 9, "X", False)
    if kind == "building":
        # Village
        return (2, 5, "V", False)
    if kind in ("mountain", "hill"):
        # Mountain / Hill: impassable, LOS block
        return (3, 1, "M", False)
    if kind == "water":
        if variant in ("wooden_bridge", "stone_bridge"):
            # Bridge: road across water (road movement + in river_cells)
            return (4, 6, "R", True)
        # River: crossing penalty, traversable, in river_cells
        return (4, 7, "W", True)
    if kind == "road":
        # Fast movement
        return (5, 6, "R", False)
    if kind in ("forest", "tree"):
        # Slow move, LOS block
        return (6, 2, "F", False)
    if kind == "farm":
        # Plains
        return (7, 0, ".", False)
    # Default plains
    return (8, 0, ".", False)


def import_map(map_key: str, spec: dict) -> dict:
    source_path: Path = spec["source"]
    if not source_path.exists():
        raise FileNotFoundError(f"Source map file missing: {source_path}")

    source_data = json.loads(source_path.read_text(encoding="utf-8"))
    source_objects = source_data.get("objects", [])

    # Map axial coords to highest precedence object
    cell_best: dict[tuple[int, int], tuple[int, int, str, bool, dict]] = {}
    for obj in source_objects:
        rank, t_id, glyph, is_river = classify_object(obj)
        # Multi-hex mountains carry the hexes they still cover (map editor writes "cells" after cuts).
        coords = [(int(c[0]), int(c[1])) for c in obj.get("cells", [])] or [(int(obj["q"]), int(obj["r"]))]
        for coord in coords:
            if coord not in cell_best or rank < cell_best[coord][0]:
                cell_best[coord] = (rank, t_id, glyph, is_river, obj)

    # Build axial grid rows and river cells
    rows: list[str] = []
    river_cells: list[list[int]] = []
    strongholds: list[dict] = []
    stronghold_idx = 1
    histogram = Counter()

    for q in range(Q_MIN, Q_MIN + WIDTH):
        row_chars = []
        for r in range(R_MIN, R_MIN + HEIGHT):
            # Axial hex disk containment: max(|q|, |r|, |q + r|) <= RADIUS
            if max(abs(q), abs(r), abs(q + r)) <= RADIUS:
                coord = (q, r)
                if coord in cell_best:
                    rank, t_id, glyph, is_river, obj = cell_best[coord]
                    row_chars.append(glyph)
                    histogram[glyph] += 1
                    if is_river:
                        river_cells.append([q, r])
                    if glyph == "X":
                        kind = str(obj.get("kind", "fort"))
                        var = str(obj.get("variant", "stronghold"))
                        sh_type = "capital" if kind == "castle" else "fortress"
                        strongholds.append({
                            "id": f"{spec['id']}_SH_{stronghold_idx}",
                            "name": f"{var} ({q},{r})",
                            "type": sh_type,
                            "owner": "red",
                            "footprint": [[q, r]],
                            "hp": 1000,
                            "slots": 4,
                        })
                        stronghold_idx += 1
                else:
                    # Unoccupied cell in radius: base plains
                    row_chars.append(".")
                    histogram["."] += 1
            else:
                # Outside playable axial hex disk
                row_chars.append("#")
        rows.append("".join(row_chars))

    # Sort river_cells for deterministic output
    river_cells.sort()

    # Sort strongholds by footprint
    strongholds.sort(key=lambda s: (s["footprint"][0][0], s["footprint"][0][1]))

    # Set of impassable coords (mountains + strongholds)
    impassable_cells = set()
    for coord, (rank, t_id, glyph, is_river, obj) in cell_best.items():
        if glyph in ("M", "X"):
            impassable_cells.add(coord)

    CLASS_NORM = {
        "infantry": "infantry",
        "spearman": "spearman",
        "spearmen": "spearman",
        "archer": "archer",
        "archers": "archer",
        "cavalry": "cavalry",
        "scout": "scout",
        "scouts": "scout",
        "conscript": "conscript",
        "conscripts": "conscript",
        "siege": "siege",
        "hq": "hq",
    }

    imported_units: list[list] = []
    seen_unit_cells = set()
    blue_hq = None
    red_hq = None
    blue_unit_ids: list[str] = []
    red_unit_ids: list[str] = []

    for u in source_data.get("units", []):
        if isinstance(u, dict):
            uid = str(u.get("id", ""))
            raw_cls = str(u.get("class", "")).lower()
            uclass = CLASS_NORM.get(raw_cls, raw_cls)
            faction = str(u.get("faction", "")).lower()
            q = int(u.get("q", 0))
            r = int(u.get("r", 0))
            count = int(u.get("soldier_count", 0))
        elif isinstance(u, list) and len(u) == 6:
            uid = str(u[0])
            raw_cls = str(u[1]).lower()
            uclass = CLASS_NORM.get(raw_cls, raw_cls)
            faction = str(u[2]).lower()
            q = int(u[3])
            r = int(u[4])
            count = int(u[5])
        else:
            continue

        coord = (q, r)
        if max(abs(q), abs(r), abs(q + r)) > RADIUS:
            print(f"  [REJECT] Unit {uid} rejected: ({q},{r}) outside radius {RADIUS}")
            continue

        if coord in impassable_cells:
            print(f"  [REJECT] Unit {uid} rejected: ({q},{r}) is on impassable terrain (mountain/hill/stronghold)")
            continue

        if coord in seen_unit_cells:
            print(f"  [REJECT] Unit {uid} rejected: duplicate cell ({q},{r})")
            continue

        seen_unit_cells.add(coord)
        imported_units.append([uid, uclass, faction, q, r, count])
        if faction == "blue":
            blue_unit_ids.append(uid)
            if uclass == "hq" and blue_hq is None:
                blue_hq = {"id": uid, "q": q, "r": r}
        elif faction == "red":
            red_unit_ids.append(uid)
            if uclass == "hq" and red_hq is None:
                red_hq = {"id": uid, "q": q, "r": r}

    out_doc = {
        "format": "tutorial_battlefield_v1",
        "set": "editor_v1",
        "id": spec["id"],
        "name": spec["name"],
        "name_zh": spec["name_zh"],
        "source_map": str(source_path.as_posix()),
        "q_min": Q_MIN,
        "r_min": R_MIN,
        "width_hexes": WIDTH,
        "height_hexes": HEIGHT,
        "rows": rows,
        "river_cells": river_cells,
        "units": imported_units,
        "strongholds": strongholds,
        "scenario": {
            "schema": "tutorial_scenario_v1",
            "mission_id": spec["id"],
            "mission_family": "editor_battlefield",
            "side_role": {
                "blue": "defender",
                "red": "attacker",
            },
            "objectives": [],
            "control_sites": [],
            "round_limit": 20,
            "round_limit_provisional": True,
            "fortified_objective_refs": [s["id"] for s in strongholds],
            "hq": {
                "blue": {"unit_id": blue_hq["id"], "location": [blue_hq["q"], blue_hq["r"]]} if blue_hq else {"unit_id": "B_HQ", "location": [0, 0]},
                "red": {"unit_id": red_hq["id"], "location": [red_hq["q"], red_hq["r"]]} if red_hq else {"unit_id": "R_HQ", "location": [0, 0]},
                "universal_override": {
                    "enemy_hq_destroyed": "immediate_victory",
                    "own_hq_destroyed": "immediate_defeat",
                },
            },
            "deployment": {
                "player_formations": len(blue_unit_ids),
                "red_formations_including_garrisons": len(red_unit_ids),
                "unlocked_unit": "none",
                "unit_placements": [],
                "blue_unit_ids": blue_unit_ids,
                "red_unit_ids": red_unit_ids,
                "field_unit_ids": blue_unit_ids + red_unit_ids,
                "garrison_unit_ids": [],
                "hq_unit_ids": ([blue_hq["id"]] if blue_hq else []) + ([red_hq["id"]] if red_hq else []),
            },
            "collapse_withdrawal": {
                "loss_ratio": 0.30,
            },
        },
        "info": {
            "terrain": f"Editor imported map: {spec['name']}",
            "tactical": "Phase A terrain import",
            "asymmetry": "neutral",
            "units": {"blue": len(blue_unit_ids), "red": len(red_unit_ids)},
            "strongholds": [s["name"] for s in strongholds],
        },
        "map_metadata": {
            "playable_dimensions": {
                "q": WIDTH,
                "r": HEIGHT,
                "hexes": 1261,
                "shape": "regular_axial_hexagon",
                "hex_radius": RADIUS,
            },
            "primary_terrain": ["plains"],
            "defender_bias": "neutral",
            "histogram": dict(sorted(histogram.items())),
        },
    }

    return out_doc


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Import editor maps into battlefield JSON")
    parser.add_argument("--input", "-i", type=Path, help="Custom editor map JSON input")
    parser.add_argument("--output", "-o", type=Path, help="Custom battlefield JSON output")
    parser.add_argument("--id", default="CUSTOM_M", help="Map ID")
    parser.add_argument("--name", default="Custom Map", help="Map Name")
    parser.add_argument("--name-zh", default="自定義地圖", help="Map Name ZH")
    args = parser.parse_args()

    if args.input:
        if not args.output:
            parser.error("--output is required when --input is provided")
        spec = {
            "id": args.id,
            "name": args.name,
            "name_zh": args.name_zh,
            "source": args.input,
        }
        out_doc = import_map(args.id.lower(), spec)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with open(args.output, "w", encoding="utf-8") as f:
            json.dump(out_doc, f, indent=2, ensure_ascii=False)
            f.write("\n")
        print(f"[custom] {args.input} -> {args.output}: {len(out_doc.get('units', []))} units imported")
        return

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    print("Importing 5 editor maps...")

    for key, spec in MAP_SOURCES.items():
        out_doc = import_map(key, spec)
        out_path = OUT_DIR / f"{key}.json"
        with open(out_path, "w", encoding="utf-8") as f:
            json.dump(out_doc, f, indent=2, ensure_ascii=False)
            f.write("\n")

        hist = out_doc["map_metadata"]["histogram"]
        impassable = hist.get("M", 0) + hist.get("X", 0)
        print(f"[{key}] -> {out_path.name}: {out_doc['id']} | cells: 1261 | strongholds: {len(out_doc['strongholds'])} | impassable (M+X): {impassable}")
        print(f"       histogram: {hist}")

    print("All 5 maps imported successfully.")


if __name__ == "__main__":
    main()
