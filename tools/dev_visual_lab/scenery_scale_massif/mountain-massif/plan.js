import * as THREE from 'three';
import { center, DIRS, edgePoint, R, H } from '../generator.js';

export const keyOf = (q, r) => `${q},${r}`;

export const DEFAULT_MASSIF_PARAMS = Object.freeze({
  baseHeight: 34.0,            // Base peak height in authoring units (34 * 0.75 = 25.5 runtime base; scaled per size)
  frontHeightRatio: 0.72,      // Front supporting ridge relative height (~0.70-0.75)
  rearHeightRatio: 0.80,       // Rear supporting massif relative height (~0.78-0.82)
  saddleDepthRatio: 0.60,      // Saddles between bands (~0.58-0.62)
  boundaryFadeWidth: 24.0,     // Outer boundary foot ramp
  seed: 20261019
});

const sortCells = (a, b) => a.q - b.q || a.r - b.r;

// 1-ring axial hex dilation: expands path hexes by adding all immediate neighbor hexes
export function dilate1Ring(cells) {
  const set = new Set();
  const result = [];
  function add(q, r, isPath) {
    const k = `${q},${r}`;
    if (!set.has(k)) {
      set.add(k);
      result.push({ q, r, kind: 'mountain', isPath: Boolean(isPath) });
    }
  }
  for (const c of cells) add(c.q, c.r, true);
  for (const c of cells) {
    for (const [dq, dr] of DIRS) add(c.q + dq, c.r + dr, false);
  }
  return result.sort(sortCells);
}

const clamp = (x, a, b) => Math.max(a, Math.min(b, x));

export function distribute(n, weights) {
  const result = weights.map(w => Math.floor((n * w) / weights.reduce((a, b) => a + b)));
  while (result.reduce((a, b) => a + b) < n) {
    for (let i = 0; i < result.length && result.reduce((a, b) => a + b) < n; i++) result[i]++;
  }
  return result;
}

// Builds layout and explicit branch paths for all 5 mountain shapes
export function layoutWithBranches(shape, n) {
  const points = [[0, 0]], seen = new Set(['0,0']);
  function step(from, d) {
    const p = [from[0] + DIRS[d][0], from[1] + DIRS[d][1]], k = p.join(',');
    if (!seen.has(k)) { points.push(p); seen.add(k); }
    return p;
  }
  function path(start, dirs, lengths) {
    let p = start;
    const branchPts = [p];
    dirs.forEach((d, i) => {
      for (let s = 0; s < lengths[i]; s++) {
        p = step(p, d);
        branchPts.push(p);
      }
    });
    return branchPts;
  }

  let branches = [];
  if (shape === 'straight') {
    path(points[0], [0], [n - 1]);
    branches = [points];
  } else if (shape === 'c_curve') {
    path(points[0], [5, 0, 1, 2], distribute(n - 1, [1, 1, 1, 1]));
    branches = [points];
  } else if (shape === 's_curve') {
    path(points[0], [0, 1, 0, 5, 0], distribute(n - 1, [1, 1, 1, 1, 1]));
    branches = [points];
  } else if (shape === 'y_branch') {
    const lengths = distribute(n - 1, [1, 1, 1]);
    branches = [0, 2, 4].map((d, i) => path(points[0], [d], [lengths[i]]));
  } else if (shape === 'irregular') {
    const counts = distribute(n - 1, [5, 3, 2]);
    const trunkPts = path(points[0], [0, 5, 0], distribute(counts[0], [2, 1, 2]));
    const trunk = points.map(p => [...p]);
    const a1 = trunk[Math.max(1, Math.floor(trunk.length * 0.33))];
    const b1Pts = path(a1, [4, 5], distribute(counts[1], [2, 1]));
    const a2 = trunk[Math.max(1, Math.floor(trunk.length * 0.68))];
    const b2Pts = path(a2, [1, 0, 1], distribute(counts[2], [1, 1, 1]));
    let tip = points.at(-1);
    while (points.length < n) { tip = step(tip, 1); b2Pts.push(tip); }
    branches = [trunkPts, b1Pts, b2Pts];
  }

  return { points: points.map(([q, r]) => ({ q, r, kind: 'mountain' })), branches };
}

// Builds a smooth Catmull-Rom spline through a sequence of 2D points with dense arc-length parameterization
export function buildSplineBranch(rawPts, branchId = 0, isClosed = false) {
  const densePts = [];
  const N_SUB = 16;
  for (let i = 0; i < rawPts.length - 1; i++) {
    const p0 = rawPts[Math.max(0, i - 1)];
    const p1 = rawPts[i];
    const p2 = rawPts[i + 1];
    const p3 = rawPts[Math.min(rawPts.length - 1, i + 2)];
    for (let s = 0; s < N_SUB; s++) {
      const t = s / N_SUB;
      const t2 = t * t, t3 = t2 * t;
      const x = 0.5 * ((2 * p1[0]) + (-p0[0] + p2[0]) * t + (2 * p0[0] - 5 * p1[0] + 4 * p2[0] - p3[0]) * t2 + (-p0[0] + 3 * p1[0] - 3 * p2[0] + p3[0]) * t3);
      const z = 0.5 * ((2 * p1[1]) + (-p0[1] + p2[1]) * t + (2 * p0[1] - 5 * p1[1] + 4 * p2[1] - p3[1]) * t2 + (-p0[1] + 3 * p1[1] - 3 * p2[1] + p3[1]) * t3);
      densePts.push([x, z]);
    }
  }
  densePts.push(rawPts[rawPts.length - 1]);

  const segments = [];
  let cumS = 0;
  for (let i = 0; i < densePts.length - 1; i++) {
    const a = densePts[i];
    const b = densePts[i + 1];
    const dx = b[0] - a[0], dz = b[1] - a[1];
    const len = Math.hypot(dx, dz) || 1e-4;
    const tx = dx / len, tz = dz / len;
    // Natural continuous curve normal (left-hand normal)
    const nx = -tz, nz = tx;
    segments.push({ a, b, tx, tz, nx, nz, len, startS: cumS });
    cumS += len;
  }

  return {
    branchId,
    rawPts,
    segments,
    totalLength: cumS
  };
}

// Builds the mountain massif plan with dilated 1-ring footprint and smooth spline branches
export function planMassifMountains(pathInput, userParams = {}) {
  const params = { ...DEFAULT_MASSIF_PARAMS, ...userParams };

  const pathCells = pathInput
    .map(v => (Array.isArray(v) ? { q: v[0], r: v[1], kind: 'mountain' } : { ...v }))
    .sort(sortCells);

  const ownedCells = dilate1Ring(pathCells);

  const ownedLookup = new Map();
  for (const c of ownedCells) {
    ownedLookup.set(keyOf(c.q, c.r), c);
  }

  // Outer boundary segments of the dilated footprint for ground fade
  const boundaries = [];
  for (const c of ownedCells) {
    const key = keyOf(c.q, c.r);
    const v = center(c.q, c.r);
    DIRS.forEach(([dq, dr], edge) => {
      if (ownedLookup.has(keyOf(c.q + dq, c.r + dr))) return;
      const p1 = edgePoint(edge, 0).add(v);
      const p2 = edgePoint(edge, 1).add(v);
      boundaries.push({
        owner: key,
        component: 0,
        a: [p1.x, p1.z],
        b: [p2.x, p2.z]
      });
    });
  }

  const branchSplines = [];

  if (params.rawBranches && params.rawBranches.length) {
    params.rawBranches.forEach((b, i) => {
      const coords = b.map(p => {
        const q = Array.isArray(p) ? p[0] : (p.q ?? 0);
        const r = Array.isArray(p) ? p[1] : (p.r ?? 0);
        const v = center(q, r);
        return [v.x, v.z];
      });
      branchSplines.push(buildSplineBranch(coords, i + 1));
    });
  } else {
    // Single continuous spline through pathCells
    const pathCoords = pathCells.map(c => {
      const v = center(c.q, c.r);
      return [v.x, v.z];
    });
    branchSplines.push(buildSplineBranch(pathCoords, 1));
  }

  return {
    schema: 'mountain_massif_plan_v3',
    layout: 'exhibition_dilated_r1',
    seed: params.seed,
    params,
    pathCells,
    ownedCells,
    cells: ownedCells,
    mountains: ownedCells,
    components: [ownedCells.map(c => keyOf(c.q, c.r))],
    boundaries,
    branches: branchSplines,
    branchSplines,
    branchCount: branchSplines.length
  };
}
