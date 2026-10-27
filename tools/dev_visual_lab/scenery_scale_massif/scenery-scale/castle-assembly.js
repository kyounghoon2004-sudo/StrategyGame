import * as THREE from 'three';
import * as BufferGeometryUtils from 'three/addons/utils/BufferGeometryUtils.js';
import { readFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import {
  createSharedFortificationMaterial,
  auditCastleGeometry
} from './mesh-optimizer.js';

// Polyfill FileReader & self for Three.js in Node.js
if (typeof globalThis.self === 'undefined') {
  globalThis.self = globalThis;
}
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

export const FORTIFICATION_SOURCES = Object.freeze({
  stone_wall: {
    filename: '02-stone-earth-defensive-wall.glb',
    sha256: '315908a5bdb8d1c6136051d3f55d3c0e884ae6a2bd5a6f985f2e1c23065176ee'
  },
  layered_gatehouse: {
    filename: '03-layered-gatehouse.glb',
    sha256: 'e013eb27da7bd3430ab8062a537e6dfcb970b2b81f377bf389b224f1210e2d2e'
  },
  major_stronghold: {
    filename: '06-major-stronghold.glb',
    sha256: '27518537afb7b572eaf13dff25eecd14f1b444b1cc5cb3d1117f9c7407989833'
  }
});

/**
 * Strips only the flat ground baseplate triangles (maxY <= 0.03) from an optimized fortification geometry,
 * while preserving 100% of elevated courtyard steps, terraces, rocks, walls, timber, and roofs.
 */
function stripGroundBasePlate(geom) {
  const pos = geom.attributes.position;
  const norm = geom.attributes.normal;
  const col = geom.attributes.color;
  const idx = geom.index;
  const triCount = idx ? idx.count / 3 : pos.count / 3;

  const newPos = [];
  const newNorm = [];
  const newCol = [];

  for (let t = 0; t < triCount; t++) {
    const iA = idx ? idx.getX(t * 3) : t * 3;
    const iB = idx ? idx.getX(t * 3 + 1) : t * 3 + 1;
    const iC = idx ? idx.getX(t * 3 + 2) : t * 3 + 2;

    const yA = pos.getY(iA);
    const yB = pos.getY(iB);
    const yC = pos.getY(iC);
    const maxY = Math.max(yA, yB, yC);

    // Strip flat ground baseplate at y <= 0.03 and downward-facing bottom caps
    if (maxY <= 0.03) continue;
    if (norm) {
      const avgNy = (norm.getY(iA) + norm.getY(iB) + norm.getY(iC)) / 3;
      if (avgNy < -0.92 && maxY <= 0.25) continue;
    }

    for (const i of [iA, iB, iC]) {
      newPos.push(pos.getX(i), Math.max(0.0, pos.getY(i)), pos.getZ(i));
      if (norm) newNorm.push(norm.getX(i), norm.getY(i), norm.getZ(i));
      else newNorm.push(0, 1, 0);
      if (col) newCol.push(col.getX(i), col.getY(i), col.getZ(i));
      else newCol.push(0.65, 0.65, 0.65);
    }
  }

  const out = new THREE.BufferGeometry();
  out.setAttribute('position', new THREE.Float32BufferAttribute(newPos, 3));
  out.setAttribute('normal', new THREE.Float32BufferAttribute(newNorm, 3));
  out.setAttribute('color', new THREE.Float32BufferAttribute(newCol, 3));
  return out;
}

/**
 * Extracts only the central straight stone/earth wall slice (|x| <= 2.0, y <= 3.70) from stone_wall
 * to serve as seamless wing connectors on either side of the front gatehouse.
 */
function extractWallWingSlice(geom) {
  const pos = geom.attributes.position;
  const norm = geom.attributes.normal;
  const col = geom.attributes.color;
  const triCount = pos.count / 3;

  const newPos = [];
  const newNorm = [];
  const newCol = [];

  for (let t = 0; t < triCount; t++) {
    const iA = t * 3, iB = t * 3 + 1, iC = t * 3 + 2;
    const maxAbsX = Math.max(Math.abs(pos.getX(iA)), Math.abs(pos.getX(iB)), Math.abs(pos.getX(iC)));
    const maxY = Math.max(pos.getY(iA), pos.getY(iB), pos.getY(iC));
    if (maxAbsX <= 2.15 && maxY <= 3.75) {
      for (const i of [iA, iB, iC]) {
        newPos.push(pos.getX(i), pos.getY(i), pos.getZ(i));
        newNorm.push(norm.getX(i), norm.getY(i), norm.getZ(i));
        newCol.push(col.getX(i), col.getY(i), col.getZ(i));
      }
    }
  }

  const out = new THREE.BufferGeometry();
  out.setAttribute('position', new THREE.Float32BufferAttribute(newPos, 3));
  out.setAttribute('normal', new THREE.Float32BufferAttribute(newNorm, 3));
  out.setAttribute('color', new THREE.Float32BufferAttribute(newCol, 3));
  return out;
}

/**
 * Loads the pre-baked, artifact-free QEM LOD meshes (near/mid/far) from outputs/full-map-lab/optimized/
 * for stronghold, gatehouse, and stone_wall — the exact crisp meshes used in before-unit-castle-hq.png.
 */
export async function loadSourceFortifications(loader, sourceDir, kitDir) {
  const optDir = resolve(sourceDir, '../../../../Documents/Codex/2026-10-18/strategygame-godot-4-2-2-repo/outputs/full-map-lab/optimized');
  const fallbackOptDir = resolve(kitDir || '', '../../full-map-lab/optimized');

  async function loadOptLodSet(prefix) {
    const lodNames = ['near', 'mid', 'far'];
    const lods = [];
    for (const suffix of lodNames) {
      let filePath = join(fallbackOptDir, `${prefix}_${suffix}.glb`);
      let buf;
      try {
        buf = await readFile(filePath);
      } catch {
        filePath = join(optDir, `${prefix}_${suffix}.glb`);
        buf = await readFile(filePath);
      }
      const gltf = await loader.parseAsync(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength), '');
      gltf.scene.updateMatrixWorld(true);
      const geoms = [];
      gltf.scene.traverse(o => {
        if (o.isMesh && o.geometry) {
          const g = o.geometry.clone();
          delete g.attributes.uv;
          g.applyMatrix4(o.matrixWorld);
          geoms.push(stripGroundBasePlate(g));
        }
      });
      lods.push(BufferGeometryUtils.mergeGeometries(geoms, false));
    }
    return lods;
  }

  const stronghold = await loadOptLodSet('stronghold');
  const gatehouse = await loadOptLodSet('gatehouse');
  const stone_wall = await loadOptLodSet('stone_wall');
  const wall_wing = stone_wall.map(g => extractWallWingSlice(g));

  return {
    stronghold,
    gatehouse,
    stone_wall,
    wall_wing
  };
}

/**
 * Smooth C1 piecewise vertical scaling + optional middle-span X stretching for stone walls:
 * - Stretches the lower stone/rock wall body (y in [0, ySplit]) by scaleYBase,
 *   and transitions smoothly over [ySplit - blend, ySplit + blend] to scaleYTop for upper battlements & roofs.
 * - When xSplit > 0 (used on stone_wall), stretches ONLY the middle straight wall span (|x| <= xSplit)
 *   by scaleXMid so adjacent hex walls meet corner-to-corner with zero gap, while keeping the two end-turrets
 *   (|x| > xSplit) at 1:1 square aspect ratio (scaleXEnd = sz)!
 */
function applyPiecewiseTransform(
  sourceGeom,
  pos,
  rotY,
  scaleXZ,
  ySplit,
  scaleYBase,
  scaleYTop,
  blend = 0.35,
  xSplit = 0.0,
  scaleXMid = 1.0
) {
  const g = sourceGeom.clone();
  const sx = Array.isArray(scaleXZ) ? scaleXZ[0] : scaleXZ;
  const sz = Array.isArray(scaleXZ) ? scaleXZ[1] : scaleXZ;

  const pAttr = g.attributes.position;
  const nAttr = g.attributes.normal;

  const y0 = ySplit - blend;
  const y1 = ySplit + blend;

  function mapY(y) {
    if (y <= y0) {
      return y * scaleYBase;
    } else if (y >= y1) {
      const midVal = y0 * scaleYBase + 0.5 * (y1 - y0) * (scaleYBase + scaleYTop);
      return midVal + (y - y1) * scaleYTop;
    } else {
      const t = (y - y0) / (y1 - y0);
      return y0 * scaleYBase + (y - y0) * (scaleYBase + 0.5 * t * (scaleYTop - scaleYBase));
    }
  }

  function dMapY(y) {
    if (y <= y0) return scaleYBase;
    if (y >= y1) return scaleYTop;
    const t = (y - y0) / (y1 - y0);
    return scaleYBase + t * (scaleYTop - scaleYBase);
  }

  function mapX(x) {
    if (xSplit <= 0.0) return x * sx;
    const ax = Math.abs(x);
    const sgn = x < 0 ? -1 : 1;
    if (ax <= xSplit) {
      return sgn * (ax * scaleXMid);
    } else {
      return sgn * (xSplit * scaleXMid + (ax - xSplit) * sx);
    }
  }

  function dMapX(x) {
    if (xSplit <= 0.0) return sx;
    return Math.abs(x) <= xSplit ? scaleXMid : sx;
  }

  const cosY = Math.cos(rotY);
  const sinY = Math.sin(rotY);
  const tx = pos[0], ty = pos[1], tz = pos[2];

  const vNorm = new THREE.Vector3();

  for (let i = 0; i < pAttr.count; i++) {
    const rawX = pAttr.getX(i);
    const lx = mapX(rawX);
    const ly = mapY(Math.max(0.0, pAttr.getY(i)));
    const lz = pAttr.getZ(i) * sz;

    const wx = lx * cosY + lz * sinY + tx;
    const wy = ly + ty;
    const wz = -lx * sinY + lz * cosY + tz;
    pAttr.setXYZ(i, wx, wy, wz);

    if (nAttr) {
      const dx = dMapX(rawX);
      const dy = dMapY(Math.max(0.0, pAttr.getY(i)));
      const nx = nAttr.getX(i) / dx;
      const ny = nAttr.getY(i) / dy;
      const nz = nAttr.getZ(i) / sz;
      const rnx = nx * cosY + nz * sinY;
      const rnz = -nx * sinY + nz * cosY;
      vNorm.set(rnx, ny, rnz).normalize();
      nAttr.setXYZ(i, vNorm.x, vNorm.y, vNorm.z);
    }
  }

  return g;
}

/**
 * Builds a unified hexagonal stone fortress based on before-unit-castle-hq.png:
 * - Central 06-major-stronghold seated at [0, 0, keepZ]
 * - 5-sided outer 02-stone-earth-defensive-wall curtain ring at angles 30°, -30°, -90°, -150°, 150°
 *   with continuous corner-to-corner mitering (zero corner gaps, 1:1 square end-turrets!)
 * - Front 03-layered-gatehouse + flanking stone wall wings at angle 90° ([0, 0, +wallApothem]) facing +Z road
 */
function buildHexFortressVariant(sources, lodIdx, cfg) {
  const geoms = [];

  // Use full-detail near meshes for LOD0 so outer wall turrets keep all wooden posts & eaves!
  const shLod = lodIdx;
  const ghLod = lodIdx;
  const wallLod = lodIdx;

  // 1. Central 06-major-stronghold (ySplit = 3.35m separates rock/stone ramparts from upper roofs)
  geoms.push(
    applyPiecewiseTransform(
      sources.stronghold[shLod],
      [0, 0, cfg.keepZ],
      0,
      [cfg.keepScaleXZ, cfg.keepScaleXZ],
      3.35,
      cfg.keepScaleYBase,
      cfg.keepScaleYTop,
      0.40
    )
  );

  // 2. Front 03-layered-gatehouse on the +Z hex face (angle = 90° = PI/2, yaw = 0 facing +Z)
  geoms.push(
    applyPiecewiseTransform(
      sources.gatehouse[ghLod],
      [0, 0, cfg.wallApothem],
      0,
      [cfg.gateScaleX, cfg.gateScaleZ],
      3.40,
      cfg.gateScaleYBase,
      cfg.gateScaleYTop,
      0.30
    )
  );

  // Exact hexagon half-side length so corner wing segments close all 6 corners seamlessly:
  const targetHalfSide = cfg.wallApothem * Math.tan(Math.PI / 6);
  const wingOffset = targetHalfSide - 1.25;

  // Flanking stone wall wings on the front +Z face
  for (const sgn of [-1, 1]) {
    geoms.push(
      applyPiecewiseTransform(
        sources.wall_wing[wallLod],
        [sgn * wingOffset, 0, cfg.wallApothem],
        0,
        [0.72, cfg.wallScaleZ],
        3.40,
        cfg.wallScaleYBase,
        cfg.wallScaleYTop,
        0.30
      )
    );
  }

  // 3. 5 outer 02-stone-earth-defensive-wall segments on the remaining 5 faces of the hexagon
  // Scaled uniformly in X and Z (zero xSplit stretching!) + short stone corner wings at the ends
  const wallAngles = [
    Math.PI / 6,       // +30° (Front-Right)
    -Math.PI / 6,      // -30° (Rear-Right)
    -Math.PI / 2,      // -90° (Rear, -Z)
    -5 * Math.PI / 6,  // -150° (Rear-Left)
    5 * Math.PI / 6    // +150° (Front-Left)
  ];

  for (const a of wallAngles) {
    const wx = cfg.wallApothem * Math.cos(a);
    const wz = cfg.wallApothem * Math.sin(a);
    const yaw = Math.PI / 2 - a;
    // Tangent vector along the wall face
    const tx = Math.cos(yaw);
    const tz = -Math.sin(yaw);

    geoms.push(
      applyPiecewiseTransform(
        sources.stone_wall[wallLod],
        [wx, 0, wz],
        yaw,
        [cfg.wallScaleZ, cfg.wallScaleZ],
        3.40,
        cfg.wallScaleYBase,
        cfg.wallScaleYTop,
        0.30
      )
    );

    // Corner connector stone wall wings at both ends of the wall face
    for (const sgn of [-1, 1]) {
      geoms.push(
        applyPiecewiseTransform(
          sources.wall_wing[wallLod],
          [wx + sgn * wingOffset * tx, 0, wz + sgn * wingOffset * tz],
          yaw,
          [0.72, cfg.wallScaleZ],
          3.40,
          cfg.wallScaleYBase,
          cfg.wallScaleYTop,
          0.30
        )
      );
    }
  }

  return BufferGeometryUtils.mergeGeometries(geoms, false);
}

export const CASTLE_VARIANTS = Object.freeze({
  castle_v1: {
    id: 'castle_v1',
    name: 'Grand Stone Stronghold (Standard Hex Curtain)',
    config: {
      keepZ: -1.6,
      keepScaleXZ: 1.52,
      keepScaleYBase: 3.45, // total ~23.4m
      keepScaleYTop: 2.55,
      wallApothem: 11.2,
      wallScaleZ: 1.15,
      wallScaleYBase: 2.08, // total ~9.8m
      wallScaleYTop: 1.20,
      gateScaleX: 1.18,
      gateScaleZ: 1.18,
      gateScaleYBase: 2.55, // total ~13.0m
      gateScaleYTop: 1.55
    },
    gate_local: { x: 0.0, y: 0.0, z: 11.2 },
    description: 'Authentic scaled original stronghold (23.4m) + closed 6-sided stone curtain wall (9.8m) + layered gatehouse (13.0m).'
  },
  castle_v2: {
    id: 'castle_v2',
    name: 'High Citadel Stronghold (Elevated Stone Keep)',
    config: {
      keepZ: -1.6,
      keepScaleXZ: 1.55,
      keepScaleYBase: 3.75, // total ~24.8m
      keepScaleYTop: 2.65,
      wallApothem: 11.3,
      wallScaleZ: 1.18,
      wallScaleYBase: 2.18, // total ~10.2m
      wallScaleYTop: 1.22,
      gateScaleX: 1.20,
      gateScaleZ: 1.20,
      gateScaleYBase: 2.68, // total ~13.5m
      gateScaleYTop: 1.60
    },
    gate_local: { x: 0.0, y: 0.0, z: 11.3 },
    description: 'Elevated rocky citadel stronghold (24.8m) + closed 6-sided stone curtain wall (10.2m) + layered gatehouse (13.5m).'
  },
  castle_v3: {
    id: 'castle_v3',
    name: 'Heavy Bastion Stronghold (Reinforced Curtain Ring)',
    config: {
      keepZ: -1.5,
      keepScaleXZ: 1.50,
      keepScaleYBase: 3.55, // total ~23.8m
      keepScaleYTop: 2.58,
      wallApothem: 11.1,
      wallScaleZ: 1.26,     // thicker outer bastion walls
      wallScaleYBase: 2.30, // total ~10.7m
      wallScaleYTop: 1.25,
      gateScaleX: 1.22,
      gateScaleZ: 1.26,
      gateScaleYBase: 2.78, // total ~13.9m
      gateScaleYTop: 1.62
    },
    gate_local: { x: 0.0, y: 0.0, z: 11.1 },
    description: 'Heavy stone stronghold (23.8m) + thickened 6-sided stone curtain wall (10.7m) + monumental layered gatehouse (13.9m).'
  },
  castle_v4: {
    id: 'castle_v4',
    name: 'Broad Courtyard Stronghold (Deep Muster Plaza)',
    config: {
      keepZ: -1.9,
      keepScaleXZ: 1.48,
      keepScaleYBase: 3.32, // total ~22.6m
      keepScaleYTop: 2.48,
      wallApothem: 11.4,
      wallScaleZ: 1.15,
      wallScaleYBase: 1.98, // total ~9.4m
      wallScaleYTop: 1.18,
      gateScaleX: 1.22,
      gateScaleZ: 1.20,
      gateScaleYBase: 2.45, // total ~12.5m
      gateScaleYTop: 1.52
    },
    gate_local: { x: 0.0, y: 0.0, z: 11.4 },
    description: 'Broad courtyard stone stronghold (22.6m) + wide closed 6-sided stone curtain wall (9.4m) + layered gatehouse (12.5m).'
  }
});

/**
 * Builds the 3 LOD meshes (0, 1, 2) for a given castle variant directly from the clean pre-authored QEM LODs.
 */
export async function buildCastleLODMeshes(variantKey, sources) {
  const variant = CASTLE_VARIANTS[variantKey];
  if (!variant) throw new Error(`Unknown castle variant: ${variantKey}`);

  const geomLod0 = buildHexFortressVariant(sources, 0, variant.config);
  const geomLod1 = buildHexFortressVariant(sources, 1, variant.config);
  const geomLod2 = buildHexFortressVariant(sources, 2, variant.config);

  // Ground alignment check: ensure lowest contact sits exactly at y=0.000
  for (const g of [geomLod0, geomLod1, geomLod2]) {
    const audit = auditCastleGeometry(g);
    if (audit.minY < -1e-4 || audit.minY > 1e-4) {
      g.translate(0, -audit.minY, 0);
    }
  }

  const auditLod0 = auditCastleGeometry(geomLod0);
  const auditLod1 = auditCastleGeometry(geomLod1);
  const auditLod2 = auditCastleGeometry(geomLod2);

  const mat = createSharedFortificationMaterial(`${variantKey}_shared_material`);

  const meshLod0 = new THREE.Mesh(geomLod0, mat);
  meshLod0.name = `${variantKey}_lod0`;

  const meshLod1 = new THREE.Mesh(geomLod1, mat);
  meshLod1.name = `${variantKey}_lod1`;

  const meshLod2 = new THREE.Mesh(geomLod2, mat);
  meshLod2.name = `${variantKey}_lod2`;

  return {
    variantKey,
    variantMeta: variant,
    meshes: [meshLod0, meshLod1, meshLod2],
    audits: [auditLod0, auditLod1, auditLod2]
  };
}
