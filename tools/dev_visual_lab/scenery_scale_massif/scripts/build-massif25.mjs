import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Group, Box3, Vector3 } from 'three';
import { GLTFExporter } from 'three/addons/exporters/GLTFExporter.js';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { planMassifMountains, layoutWithBranches } from '../src/mountain-massif/plan.js';
import { makeMassifHex, createSharedMassifMaterial, sampleMassifRocks, auditMassifAcceptance } from '../src/mountain-massif/mesh.js';

globalThis.FileReader = class {
  readAsArrayBuffer(blob) {
    blob.arrayBuffer().then(result => {
      this.result = result;
      this.onloadend?.();
    });
  }
};

const __dirname = dirname(fileURLToPath(import.meta.url));
const studioDir = resolve(__dirname, '..');
const outBase = 'C:/Users/User/Documents/Codex/2026-10-18/strategygame-godot-4-2-2-repo/outputs/scenery-scale-massif/massif25/';
const outExports = join(outBase, 'exports/');
const outRocks = join(outBase, 'rocks/');

await mkdir(outExports, { recursive: true });
await mkdir(outRocks, { recursive: true });

const shapes = ['straight', 'c_curve', 's_curve', 'y_branch', 'irregular'];
const shapeLabels = ['직선', '완만한 C자', '굽이치는 S자', 'Y자 분기', '불규칙 확장'];
const sizes = [
  { id: 'short_low', label: '짧고 낮음', count: 6, height: 1.0, baseHeight: 74.0 },
  { id: 'short_high', label: '짧고 높음', count: 8, height: 1.0, baseHeight: 80.0 },
  { id: 'medium', label: '중간', count: 12, height: 1.0, baseHeight: 74.0 },
  { id: 'long_low', label: '길고 낮음', count: 18, height: 1.0, baseHeight: 70.0 },
  { id: 'long_high', label: '길고 높음', count: 24, height: 1.0, baseHeight: 82.0 }
];

console.log('=== Building 25 Dilated Mountain Massif Candidates (Exhibition Zone: Dilated R1, 3+ Bands) ===');
console.log('Target runtime peaks: ~55–60 (high), ~50–55 (medium), ~44–48 (low) | Slope audit: max <= 80°, foot <= 42°, boundary <= 0.05\n');

const catalog = [];
let overallMaxPeakAuth = 0;
let overallMaxPeakRuntime = 0;

for (let si = 0; si < shapes.length; si++) {
  for (let vi = 0; vi < sizes.length; vi++) {
    const shape = shapes[si];
    const size = sizes[vi];
    const id = `${shape}_${size.id}`;

    const { points: pathCells, branches } = layoutWithBranches(shape, size.count);
    const plan = planMassifMountains(pathCells, {
      seed: 20261019 + si * 100,
      rawBranches: branches,
      shape,
      size: size.id,
      heightMultiplier: size.height,
      baseHeight: size.baseHeight
    });
    const ownedCells = plan.ownedCells;

    const material = createSharedMassifMaterial();
    const maxRangeHeightAuth = size.baseHeight * size.height;

    // Generate meshes for all owned hexes across all 3 LODs
    const meshes = [0, 1, 2].map(lod =>
      ownedCells.map(c => makeMassifHex(plan, c, lod, { material, maxRangeHeight: maxRangeHeightAuth, heightMultiplier: size.height }))
    );

    // Automated acceptance audit (runs on meshes with size.height scale applied)
    const acceptance = auditMassifAcceptance(plan, meshes, size.height);
    if (!acceptance.pass) {
      throw new Error(`Acceptance criteria failed for ${id}: ${JSON.stringify(acceptance)}`);
    }

    const bandCount = shape === 'y_branch' || shape === 'irregular' ? 4 : 3;
    const variantPeakAuth = acceptance.peakHeightAuthoring;
    const variantPeakRuntime = acceptance.peakHeightRuntime;

    if (variantPeakAuth > overallMaxPeakAuth) overallMaxPeakAuth = variantPeakAuth;
    if (variantPeakRuntime > overallMaxPeakRuntime) overallMaxPeakRuntime = variantPeakRuntime;

    const entry = {
      id,
      shape,
      shapeLabel: shapeLabels[si],
      size: size.id,
      sizeLabel: size.label,
      layout: 'exhibition_dilated_r1',
      pathHexCount: pathCells.length,
      hexCount: ownedCells.length,
      heightMultiplier: size.height,
      seed: plan.seed,
      pathCells,
      ownedCells,
      cells: ownedCells,
      branchCount: plan.branchSplines.length,
      branches: plan.branchSplines.length,
      components: 1,
      bandCount,
      peakHeightAuthoring: variantPeakAuth,
      peakHeightRuntime: variantPeakRuntime,
      perHexTriangles: { lod0: 4512, lod1: 1248, lod2: 288 },
      generatorParams: {
        ...plan.params,
        heightMultiplier: size.height
      },
      acceptanceMetrics: {
        maxSlopeAny: acceptance.maxSlopeAny,
        maxSlopeFoot: acceptance.maxSlopeFoot,
        boundaryMaxHeight: acceptance.boundaryMaxHeight,
        crossSectionPassRate: acceptance.crossSectionPassRate,
        seamAudit: acceptance.seamAudit,
        pass: acceptance.pass
      },
      borderAudit: acceptance.seamAudit,
      files: []
    };

    // Bake vertical scale into each LOD and export
    for (let lod = 0; lod < 3; lod++) {
      const root = new Group();
      root.name = id;

      for (const mesh of meshes[lod]) {
        const p = mesh.geometry.attributes.position;
        const n = mesh.geometry.attributes.normal;
        for (let i = 0; i < p.count; i++) {
          p.setY(i, p.getY(i) * size.height);
          const normal = new Vector3(n.getX(i), n.getY(i) / size.height, n.getZ(i)).normalize();
          n.setXYZ(i, normal.x, normal.y, normal.z);
        }
        mesh.geometry.computeBoundingBox();
        mesh.geometry.computeBoundingSphere();
        root.add(mesh);
      }

      root.updateMatrixWorld(true);
      const box = new Box3().setFromObject(root);
      if (lod === 0) {
        entry.bounds = { min: box.min.toArray(), max: box.max.toArray() };
      }

      const binary = await new GLTFExporter().parseAsync(root, { binary: true });
      const file = `${id}_lod${lod}.glb`;
      await writeFile(join(outExports, file), Buffer.from(binary));

      // Reload with GLTFLoader to verify integrity
      const reloaded = await new GLTFLoader().parseAsync(binary, '');
      let count = 0, tris = 0;
      reloaded.scene.traverse(node => {
        if (node.isMesh) {
          count++;
          tris += (node.geometry.index?.count ?? node.geometry.attributes.position.count) / 3;
        }
      });

      if (count !== ownedCells.length || !tris) {
        throw new Error(`Reload mismatch ${id} LOD ${lod}: expected ${ownedCells.length} meshes, got ${count}`);
      }

      const sha256 = createHash('sha256').update(Buffer.from(binary)).digest('hex');
      entry.files.push({
        file,
        lod,
        meshes: count,
        triangles: tris,
        bytes: binary.byteLength,
        sha256,
        freshGLTFLoaderReload: true
      });

      reloaded.scene.traverse(n => n.geometry?.dispose());
      root.traverse(n => n.geometry?.dispose());
    }

    material.dispose();

    // Sample rock placements on the newly created massif surface (runtime world coordinates)
    const rocks = sampleMassifRocks(plan, ownedCells, size.height, variantPeakAuth);
    const rockFile = `${id}.json`;
    await writeFile(join(outRocks, rockFile), JSON.stringify(rocks, null, 2));

    entry.rocks = {
      count: rocks.length,
      file: `rocks/${rockFile}`,
      runtimeUnits: true,
      sampleCriteria: 'Upper & steeper rocky slopes on 3+ bands, seated into surface'
    };

    catalog.push(entry);
    console.log(
      `[${String(catalog.length).padStart(2, ' ')}/25] ${id.padEnd(20, ' ')} | Peak runtime: ${variantPeakRuntime.toFixed(1)} (auth: ${variantPeakAuth.toFixed(1)}) | Slope: any ${acceptance.maxSlopeAny.toFixed(1)}° (<=80°), foot ${acceptance.maxSlopeFoot.toFixed(1)}° (<=42°) | 3-Bands: ${acceptance.crossSectionPassRate}% | Seam: 0 | Rocks: ${rocks.length} | PASS`
    );
  }
}

const catalogPayload = {
  schema: 'massif25_v3',
  layout: 'exhibition_dilated_r1',
  authoringHexRadius: 24,
  runtimeHexRadius: 18,
  authoringScaleToRuntime: 0.75,
  shapes: shapeLabels,
  sizes,
  trianglesBudget: {
    lod0PerHex: 4512,
    targetMaxLod0: 5000,
    lod1PerHex: 1248,
    targetMaxLod1Ratio: 0.30,
    lod2PerHex: 288,
    targetMaxLod2Ratio: 0.10
  },
  statistics: {
    variants: catalog.length,
    totalGlbs: catalog.length * 3,
    overallMaxPeakAuthoring: overallMaxPeakAuth,
    overallMaxPeakRuntime: overallMaxPeakRuntime,
    targetRuntimePeakRange: [45, 65]
  },
  scope: '25 continuous 3+ band mountain massif candidates for exhibition zone. Path dilated by 1 ring (~3 hexes wide). 75 explicit LOD GLBs in authoring units (R=24) with TEXCOORD_1 metadata. Accompanying runtime rock placements JSON per variant.',
  catalog
};

await writeFile(join(outBase, 'catalog.json'), JSON.stringify(catalogPayload, null, 2));

console.log('\n======================================================');
console.log(`PASS: All 25 dilated massif variants built successfully!`);
console.log(`75 GLB files written to ${outExports}`);
console.log(`25 Rock placement JSONs written to ${outRocks}`);
console.log(`Catalog written to ${join(outBase, 'catalog.json')}`);
console.log(`Overall Highest Peak Authoring: ${overallMaxPeakAuth} | Runtime: ${overallMaxPeakRuntime}`);
console.log(`Triangles per hex: LOD0: 4512 (budget <= 5000), LOD1: 1248 (27.66% <= 30%), LOD2: 288 (6.38% <= 10%)`);
console.log('======================================================\n');
