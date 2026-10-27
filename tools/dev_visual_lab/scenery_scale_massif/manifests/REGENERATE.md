# Scenery Scale Generation & Assets Guide

## 1. Overview
This directory contains the production-ready scaled scenery candidate assets for **StrategyGame (Godot 4.2.2)**:
- **`castle4/`**: 4 distinct, single-drawcall scaled castle variants (`castle_v1` to `castle_v4`) across 3 LODs (0, 1, 2).
- **`buildings/`**: 7 scaled village & farm building candidates (`building_small_house`, `building_medium_house`, `building_workshop`, `building_granary`, `building_hall`, `building_gate`, `building_farm_granary`) across 3 LODs.
- **Visual Previews**: `castle4/preview.png` and `buildings/preview.png` comparing all models directly against 12.0m HQ unit figures and 9.6m ordinary unit figures.

## 2. Reproduction / Regeneration Command
To regenerate all GLBs, manifests, and preview screenshots from source:

```bash
cd outputs/threejs-hex-terrain-kit/studio
npm run build:scaled-scenery
```

Alternatively, run directly via Node:
```bash
node scripts/build-scaled-scenery.mjs
```

## 3. Specifications Summary

### Castle 4 Variants (`castle4/`)
| Variant | Name | Concept / Silhouette | Peak Height | Walls | Gate | Gate Local [X,Y,Z] | Footprint Radius | LOD0 Tris | LOD1 Tris | LOD2 Tris |
|---|---|---|---|---|---|---|---|---|---|---|
| **castle_v1** | Grand Imperial Stronghold | Grounded citadel base + monumental single-roof keep + square curtain wall | 25.0m | 9.5m | 13.5m | [0.0, 0.0, 10.5] | 14.14m (<=16.2) | ~38.0k | ~11.5k | ~3.8k |
| **castle_v2** | Crag Mountain Fortress | Natural rocky cliff plateau (8.5m) + citadel & single-roof keep | 27.5m | 10.8m | 14.0m | [0.0, 0.0, 11.0] | 15.05m (<=16.2) | ~38.0k | ~11.5k | ~3.8k |
| **castle_v3** | Heavy Polygonal Citadel | Polygonal stone curtain wall ring (12.5m) + 15.5m gate + 24.5m keep & courtyard | 24.5m | 12.5m | 15.5m | [0.0, 0.0, 11.2] | 13.88m (<=16.2) | ~38.0k | ~11.5k | ~3.8k |
| **castle_v4** | Earth Mound & Courtyard Fort | Natural earth motte (8.0m) + 24.0m hilltop main hall & courtyard + stone ring & gate | 23.9m | 8.5m | 13.0m | [0.0, 0.0, 11.5] | 14.63m (<=16.2) | ~38.0k | ~11.5k | ~3.8k |

- **Zero Cake-Stacking**: Exactly ONE main central stronghold per castle. Authentic historical fortress concepts (~27–33m, 2.3–2.8x HQ).
- **Pivot**: Hex center strictly at ground [0, 0, 0].
- **Gate Direction**: Facing local +Z on all variants with precise outside road entrance coordinates recorded.
- **Drawcalls**: Exactly 1 unified mesh per LOD with shared vertex-colored material (zero external texture overhead).
- **No Base Plates**: Individual ground flat plates eliminated; no artificial hex base plates.

### Scaled Buildings (`buildings/`)
| Building Part | Source GLB | Scale XZ | Target Height | Resulting AABB Size [X, Y, Z] | Architecture / Role | LOD0 Tris (1.0x Kit) | LOD1 Tris | LOD2 Tris |
|---|---|---|---|---|---|---|---|---|
| **building_small_house** | 01-small-peasant-house.glb | 1.32 | 8.20m | 8.14 x 8.20 x 6.38 | Single-storey authentic peasant dwelling | 32,785 | 8,613 | 2,825 |
| **building_medium_house** | 02-medium-family-house.glb | 1.38 | 9.50m | 9.95 x 9.50 x 7.33 | Single-storey family house, natural roof | 36,816 | 13,756 | 4,754 |
| **building_workshop** | 04-workshop-utility.glb | 1.35 | 9.00m | 10.78 x 9.00 x 7.08 | Single-storey forge bay & hearth loft | 35,804 | 9,908 | 4,100 |
| **building_granary** | 03-raised-granary.glb | 1.35 | 9.40m | 8.38 x 9.40 x 7.21 | Single-storey stilt-pillar grain storehouse | 36,865 | 9,562 | 2,520 |
| **building_hall** | 05-communal-hall.glb | 2.10 | 15.00m | 16.83 x 15.00 x 14.63 | **Dominant single-roof communal hall (>12m HQ)** | 44,843 | 16,519 | 5,502 |
| **building_gate** | 06-walled-village-gate.glb | 1.35 | 14.00m | 11.81 x 14.00 x 4.50 | Single-tier fortified stone arch gatehouse | 22,494 | 11,334 | 4,440 |
| **building_farm_granary** | 04-ruralgranary.glb | 1.25 | 6.80m | 15.06 x 6.80 x 15.39 | Single-tier compound with round thatch bins | 65,646 | 24,056 | 3,329 |

- **100% Period-Authentic Single-Storey Silhouettes**: Zero multi-tier vertical stacking, zero plinth boxes, zero vertex band stretching. Clean proportional scaling directly on original kit models.
- **Alley & Apron Clearance**: Verified safe under `settlement_farm_world.gd` rules: clear alley width is >= 6.26m ~ 6.4m safe, hall fits hex rear apron.
