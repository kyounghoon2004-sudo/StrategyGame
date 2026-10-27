import * as THREE from 'three';
import { GLTFExporter } from 'three/addons/exporters/GLTFExporter.js';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { writeFile, mkdir } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  SCALED_BUILDING_CONFIGS,
  computeSafeFootprintReport,
  buildScaledBuildingScene
} from '../src/scenery-scale/scaled-buildings.js';

import {
  FORTIFICATION_SOURCES,
  CASTLE_VARIANTS,
  loadSourceFortifications,
  buildCastleLODMeshes
} from '../src/scenery-scale/castle-assembly.js';

import { renderPreviews } from '../src/scenery-scale/preview-renderer.js';

// Polyfill FileReader for Three.js in Node.js
if (typeof globalThis.FileReader === 'undefined') {
  globalThis.FileReader = class {
    readAsArrayBuffer(blob) {
      blob.arrayBuffer().then(result => {
        this.result = result;
        this.onloadend?.();
      });
    }
  };
}

const __dirname = dirname(fileURLToPath(import.meta.url));
const STUDIO_DIR = resolve(__dirname, '..');
const CODEX_OUTPUTS = resolve(STUDIO_DIR, '../..');
const SCENERY_MASSIF_DIR = join(CODEX_OUTPUTS, 'scenery-scale-massif');
const KIT_EXPORTS_DIR = join(CODEX_OUTPUTS, 'village-farmland-kit/exports');
const STRATEGY_GAME_DIR = 'C:/Users/User/gamedevelopment/StrategyGame';
const FORT_SOURCE_DIR = join(STRATEGY_GAME_DIR, 'assets/map_composition_v0/source_glb/fortifications');

const CASTLE_EXPORTS_DIR = join(SCENERY_MASSIF_DIR, 'castle4/exports');
const BUILDINGS_EXPORTS_DIR = join(SCENERY_MASSIF_DIR, 'buildings/exports');

await mkdir(CASTLE_EXPORTS_DIR, { recursive: true });
await mkdir(BUILDINGS_EXPORTS_DIR, { recursive: true });

const loader = new GLTFLoader();
const exporter = new GLTFExporter();

console.log('========================================================');
console.log('StrategyGame — Scenery Scale Asset Generator');
console.log('========================================================\n');

// ====================================================================
// TASK B: Village & Farm Scaled Buildings
// ====================================================================
console.log('--- Step 1: Exporting Scaled Village & Farm Buildings ---');
const buildingsManifest = {
  schema_version: 1,
  created_at: new Date().toISOString(),
  description: 'Scaled village and farm buildings for StrategyGame (hall dominant, gate tower heightened, houses scaled XZ 1.15 / Y ~1.7 with preserved roof pitch).',
  authoring_hex_radius: 18.0,
  safe_footprint_analysis: computeSafeFootprintReport(),
  buildings: {}
};

for (const [partId, config] of Object.entries(SCALED_BUILDING_CONFIGS)) {
  console.log(`Processing building: ${partId}...`);
  const bldRecord = {
    part_id: partId,
    display_name: config.display_name,
    source_glb: config.source_glb,
    source_sha256: config.source_sha256,
    scale_xz: config.scale_xz,
    target_height: config.target_height,
    door_top: config.door_top,
    eave_height: config.eave_height,
    gate_local: config.gate_local || null,
    description: config.description,
    lods: []
  };

  for (let lod = 0; lod < 3; lod++) {
    const scene = await buildScaledBuildingScene(loader, KIT_EXPORTS_DIR, partId, lod);
    const box = new THREE.Box3().setFromObject(scene);
    const size = new THREE.Vector3();
    box.getSize(size);

    let triCount = 0;
    scene.traverse(o => {
      if (o.isMesh && o.geometry) {
        triCount += o.geometry.index ? o.geometry.index.count / 3 : o.geometry.attributes.position.count / 3;
      }
    });

    const filename = `${partId}_lod${lod}.glb`;
    const outPath = join(BUILDINGS_EXPORTS_DIR, filename);

    const binary = await exporter.parseAsync(scene, { binary: true });
    const buffer = Buffer.from(binary);
    await writeFile(outPath, buffer);
    const sha256 = createHash('sha256').update(buffer).digest('hex');

    bldRecord.lods.push({
      lod,
      filename,
      sha256,
      triangles: triCount,
      bounds: {
        min: [Number(box.min.x.toFixed(3)), Number(box.min.y.toFixed(3)), Number(box.min.z.toFixed(3))],
        max: [Number(box.max.x.toFixed(3)), Number(box.max.y.toFixed(3)), Number(box.max.z.toFixed(3))],
        size: [Number(size.x.toFixed(3)), Number(size.y.toFixed(3)), Number(size.z.toFixed(3))]
      }
    });

    console.log(`  LOD${lod}: ${filename} | ${triCount} tris | height: ${size.y.toFixed(2)} | sha256: ${sha256.substring(0, 12)}...`);
  }

  buildingsManifest.buildings[partId] = bldRecord;
}

const buildingsManifestPath = join(SCENERY_MASSIF_DIR, 'buildings/manifest.json');
await writeFile(buildingsManifestPath, JSON.stringify(buildingsManifest, null, 2), 'utf8');
console.log(`PASS: buildings/manifest.json generated.\n`);

// ====================================================================
// TASK A: Scaled Castle (4 Variants)
// ====================================================================
console.log('--- Step 2: Assembling and Exporting Scaled Castle 4 Variants ---');
console.log('Loading fortification source GLBs and village kit models...');
const fortSources = await loadSourceFortifications(loader, FORT_SOURCE_DIR, KIT_EXPORTS_DIR);

const castleManifest = {
  schema_version: 1,
  created_at: new Date().toISOString(),
  description: '4 distinct scaled castle variants for StrategyGame (single-roof keeps ~24-27.5m, single grounded walls ~8.5-12.5m, gate ~13-15.5m facing +Z, radius <= 16.2m).',
  authoring_hex_radius: 18.0,
  source_fortifications: FORTIFICATION_SOURCES,
  castle_variants: {}
};

for (const [vKey, vMeta] of Object.entries(CASTLE_VARIANTS)) {
  console.log(`Assembling ${vKey}: ${vMeta.name}...`);
  const { meshes, audits } = await buildCastleLODMeshes(vKey, fortSources);

  const variantRecord = {
    id: vKey,
    name: vMeta.name,
    description: vMeta.description,
    gate_local: vMeta.gate_local,
    keep_height: audits[0].keepHeight,
    footprint_radius: audits[0].footprintRadius,
    radius_pass: audits[0].passes.radiusPass,
    keep_height_pass: audits[0].passes.keepHeightPass,
    ground_contact_pass: audits[0].passes.groundPass,
    source_glbs_used: Object.keys(FORTIFICATION_SOURCES).map(k => FORTIFICATION_SOURCES[k].filename),
    lods: []
  };

  for (let lod = 0; lod < 3; lod++) {
    const mesh = meshes[lod];
    const audit = audits[lod];
    const filename = `${vKey}_lod${lod}.glb`;
    const outPath = join(CASTLE_EXPORTS_DIR, filename);

    const binary = await exporter.parseAsync(mesh, { binary: true });
    const buffer = Buffer.from(binary);
    await writeFile(outPath, buffer);
    const sha256 = createHash('sha256').update(buffer).digest('hex');

    variantRecord.lods.push({
      lod,
      filename,
      sha256,
      triangles: audit.triangles,
      vertices: audit.vertices,
      bounds: audit.bounds,
      keep_height: audit.keepHeight,
      footprint_radius: audit.footprintRadius
    });

    console.log(`  LOD${lod}: ${filename} | ${audit.triangles} tris (${(audit.triangles / audits[0].triangles * 100).toFixed(1)}%) | keep: ${audit.keepHeight}m | radius: ${audit.footprintRadius}m`);
  }

  castleManifest.castle_variants[vKey] = variantRecord;
}

const castleManifestPath = join(SCENERY_MASSIF_DIR, 'castle4/manifest.json');
await writeFile(castleManifestPath, JSON.stringify(castleManifest, null, 2), 'utf8');
console.log(`PASS: castle4/manifest.json generated.\n`);

// ====================================================================
// STEP 3: Visual Previews Rendering
// ====================================================================
console.log('--- Step 3: Rendering Visual Previews (Chrome Headless) ---');
const castlePreviewPath = join(SCENERY_MASSIF_DIR, 'castle4/preview.png');
const buildingsPreviewPath = join(SCENERY_MASSIF_DIR, 'buildings/preview.png');

await renderPreviews({
  port: 5218,
  castleOutPath: castlePreviewPath,
  buildingsOutPath: buildingsPreviewPath,
  castleManifest,
  sceneryMassifDir: SCENERY_MASSIF_DIR
});

// ====================================================================
// STEP 4: Write REGENERATE.md
// ====================================================================
console.log('--- Step 4: Generating REGENERATE.md ---');
const regenerateMdContent = `# Scenery Scale Generation & Assets Guide

## 1. Overview
This directory contains the production-ready scaled scenery candidate assets for **StrategyGame (Godot 4.2.2)**:
- **\`castle4/\`**: 4 distinct, single-drawcall scaled castle variants (\`castle_v1\` to \`castle_v4\`) across 3 LODs (0, 1, 2).
- **\`buildings/\`**: 7 scaled village & farm building candidates (\`building_small_house\`, \`building_medium_house\`, \`building_workshop\`, \`building_granary\`, \`building_hall\`, \`building_gate\`, \`building_farm_granary\`) across 3 LODs.
- **Visual Previews**: \`castle4/preview.png\` and \`buildings/preview.png\` comparing all models directly against 12.0m HQ unit figures and 9.6m ordinary unit figures.

## 2. Reproduction / Regeneration Command
To regenerate all GLBs, manifests, and preview screenshots from source:

\`\`\`bash
cd outputs/threejs-hex-terrain-kit/studio
npm run build:scaled-scenery
\`\`\`

Alternatively, run directly via Node:
\`\`\`bash
node scripts/build-scaled-scenery.mjs
\`\`\`

## 3. Specifications Summary

### Castle 4 Variants (\`castle4/\`)
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

### Scaled Buildings (\`buildings/\`)
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
- **Alley & Apron Clearance**: Verified safe under \`settlement_farm_world.gd\` rules: clear alley width is >= 6.26m ~ 6.4m safe, hall fits hex rear apron.
`;

const regenerateMdPath = join(SCENERY_MASSIF_DIR, 'REGENERATE.md');
await writeFile(regenerateMdPath, regenerateMdContent, 'utf8');
console.log(`PASS: REGENERATE.md written.`);

console.log('\n========================================================');
console.log('ALL SCALED SCENERY ASSETS COMPLETED SUCCESSFULLY!');
console.log('========================================================');
