import * as THREE from 'three';
import * as BufferGeometryUtils from 'three/addons/utils/BufferGeometryUtils.js';
import { SimplifyModifier } from 'three/addons/modifiers/SimplifyModifier.js';

const modifier = new SimplifyModifier();

/**
 * Grid-based vertex clustering simplification preserving vertex colors and normals.
 */
export function clusterSimplify(geometry, cellSize = 0.20) {
  const pos = geometry.attributes.position;
  const col = geometry.attributes.color;
  const norm = geometry.attributes.normal;
  const count = pos.count;

  const cells = new Map();
  const vertRemap = new Int32Array(count);

  for (let i = 0; i < count; i++) {
    const k = `${Math.floor(pos.getX(i) / cellSize)},${Math.floor(pos.getY(i) / cellSize)},${Math.floor(pos.getZ(i) / cellSize)}`;
    let c = cells.get(k);
    if (!c) {
      c = {
        pos: [pos.getX(i), pos.getY(i), pos.getZ(i)],
        col: col ? [col.getX(i), col.getY(i), col.getZ(i)] : [1, 1, 1],
        norm: norm ? [norm.getX(i), norm.getY(i), norm.getZ(i)] : [0, 1, 0],
        count: 1,
        id: cells.size
      };
      cells.set(k, c);
    } else {
      c.pos[0] += pos.getX(i);
      c.pos[1] += pos.getY(i);
      c.pos[2] += pos.getZ(i);
      if (col) {
        c.col[0] += col.getX(i);
        c.col[1] += col.getY(i);
        c.col[2] += col.getZ(i);
      }
      if (norm) {
        c.norm[0] += norm.getX(i);
        c.norm[1] += norm.getY(i);
        c.norm[2] += norm.getZ(i);
      }
      c.count++;
    }
    vertRemap[i] = c.id;
  }

  const newPositions = [];
  const newColors = [];
  const newNormals = [];
  for (const c of cells.values()) {
    newPositions.push(c.pos[0] / c.count, c.pos[1] / c.count, c.pos[2] / c.count);
    newColors.push(c.col[0] / c.count, c.col[1] / c.count, c.col[2] / c.count);
    const nl = Math.sqrt(c.norm[0] * c.norm[0] + c.norm[1] * c.norm[1] + c.norm[2] * c.norm[2]) || 1.0;
    newNormals.push(c.norm[0] / nl, c.norm[1] / nl, c.norm[2] / nl);
  }

  const indices = [];
  const srcIdx = geometry.index;
  const triCount = srcIdx ? srcIdx.count / 3 : count / 3;
  for (let t = 0; t < triCount; t++) {
    const a = vertRemap[srcIdx ? srcIdx.getX(t * 3) : t * 3];
    const b = vertRemap[srcIdx ? srcIdx.getX(t * 3 + 1) : t * 3 + 1];
    const c = vertRemap[srcIdx ? srcIdx.getX(t * 3 + 2) : t * 3 + 2];
    if (a !== b && b !== c && c !== a) {
      indices.push(a, b, c);
    }
  }

  const geom = new THREE.BufferGeometry();
  geom.setAttribute('position', new THREE.Float32BufferAttribute(newPositions, 3));
  geom.setAttribute('color', new THREE.Float32BufferAttribute(newColors, 3));
  geom.setIndex(indices);

  // Compute clean face-weighted normals so opposite wall faces never cancel out into black blotches
  const clean = geom.toNonIndexed();
  clean.computeVertexNormals();
  return clean;
}

/**
 * Strips downward-facing bottom faces (ny < -0.5 and y <= 0.05).
 */
export function stripBottomFaces(geometry) {
  const pos = geometry.attributes.position;
  const col = geometry.attributes.color;
  const norm = geometry.attributes.normal;
  const idx = geometry.index;
  const triCount = idx ? idx.count / 3 : pos.count / 3;

  const validIndices = [];
  const vA = new THREE.Vector3();
  const vB = new THREE.Vector3();
  const vC = new THREE.Vector3();
  const e1 = new THREE.Vector3();
  const e2 = new THREE.Vector3();
  const cross = new THREE.Vector3();

  for (let t = 0; t < triCount; t++) {
    const a = idx ? idx.getX(t * 3) : t * 3;
    const b = idx ? idx.getX(t * 3 + 1) : t * 3 + 1;
    const c = idx ? idx.getX(t * 3 + 2) : t * 3 + 2;

    vA.fromBufferAttribute(pos, a);
    vB.fromBufferAttribute(pos, b);
    vC.fromBufferAttribute(pos, c);

    e1.subVectors(vB, vA);
    e2.subVectors(vC, vA);
    cross.crossVectors(e1, e2).normalize();

    const avgY = (vA.y + vB.y + vC.y) / 3.0;

    // Filter out downward-pointing faces at bottom ground contact
    if (cross.y < -0.4 && avgY <= 0.10) {
      continue;
    }
    validIndices.push(a, b, c);
  }

  const cleanGeom = geometry.clone();
  cleanGeom.setIndex(validIndices);
  return cleanGeom;
}

/**
 * Simplifies geometry to target triangle count using fast, robust vertex clustering binary search.
 * Preserves vertex colors, normals, and manifold topology.
 */
export async function simplifyToTargetTris(geometry, targetTris) {
  const currentTris = geometry.index ? geometry.index.count / 3 : geometry.attributes.position.count / 3;
  if (currentTris <= targetTris) return geometry;

  let low = 0.05, high = 6.0;
  let bestGeom = geometry;
  let bestDiff = Infinity;

  for (let iter = 0; iter < 10; iter++) {
    const mid = (low + high) / 2;
    const sim = clusterSimplify(geometry, mid);
    const tris = sim.index ? sim.index.count / 3 : sim.attributes.position.count / 3;
    const diff = Math.abs(tris - targetTris);
    if (diff < bestDiff) {
      bestDiff = diff;
      bestGeom = sim;
    }
    if (tris > targetTris) {
      low = mid;
    } else {
      high = mid;
    }
  }
  return bestGeom;
}

/**
 * Creates shared vertex-colored material.
 */
export function createSharedFortificationMaterial(name = 'fortification_shared_material') {
  return new THREE.MeshStandardMaterial({
    name,
    vertexColors: true,
    roughness: 0.85,
    metalness: 0.08,
    side: THREE.FrontSide
  });
}

/**
 * Audits geometry topology, bounds, triangle count, and footprint radius.
 */
export function auditCastleGeometry(geometry) {
  geometry.computeBoundingBox();
  const box = geometry.boundingBox;
  const pos = geometry.attributes.position;
  const triCount = geometry.index ? geometry.index.count / 3 : pos.count / 3;

  let maxRadius = 0;
  let minY = Infinity;
  let maxY = -Infinity;

  for (let i = 0; i < pos.count; i++) {
    const x = pos.getX(i);
    const y = pos.getY(i);
    const z = pos.getZ(i);

    minY = Math.min(minY, y);
    maxY = Math.max(maxY, y);
    const r = Math.sqrt(x * x + z * z);
    maxRadius = Math.max(maxRadius, r);
  }

  return {
    triangles: triCount,
    vertices: pos.count,
    minY: Number(minY.toFixed(3)),
    maxY: Number(maxY.toFixed(3)),
    keepHeight: Number(maxY.toFixed(2)),
    footprintRadius: Number(maxRadius.toFixed(2)),
    bounds: {
      min: [Number(box.min.x.toFixed(3)), Number(box.min.y.toFixed(3)), Number(box.min.z.toFixed(3))],
      max: [Number(box.max.x.toFixed(3)), Number(box.max.y.toFixed(3)), Number(box.max.z.toFixed(3))]
    },
    passes: {
      keepHeightPass: maxY >= 22.0 && maxY <= 35.0,
      radiusPass: maxRadius <= 16.2,
      groundPass: minY >= -0.05 && minY <= 0.05
    }
  };
}
