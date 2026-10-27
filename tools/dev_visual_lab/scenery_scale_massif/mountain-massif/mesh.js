import * as THREE from 'three';
import { R, H, edgePoint, center, DIRS } from '../generator.js';
import { keyOf, DEFAULT_MASSIF_PARAMS } from './plan.js';
import { EXTRACTED_PALETTE } from '../mountain-assets/source-profiles.js';

export const N = 96;
export const RINGS_BY_LOD = Object.freeze([18, 6, 2]);

const clamp = (x, a, b) => Math.max(a, Math.min(b, x));
const smooth = x => {
  x = clamp(x, 0, 1);
  return x * x * (3 - 2 * x);
};

function smin(a, b, k = 2.5) {
  const h = Math.max(0, k - Math.abs(a - b)) / k;
  return Math.min(a, b) - h * h * k * 0.25;
}

function smax(a, b, k = 4.0) {
  const h = Math.max(0, k - Math.abs(a - b)) / k;
  return Math.max(a, b) + h * h * k * 0.25;
}

function cosBump(u, center, W) {
  const d = Math.abs(u - center);
  if (d >= W) return 0;
  return Math.cos((Math.PI / 2) * (d / W)) ** 2;
}

function cosBumpPlateau(u, W_flat = 20.0, W_total = 54.0) {
  const d = Math.abs(u);
  if (d <= W_flat) return 1.0;
  if (d >= W_total) return 0;
  const t = (d - W_flat) / (W_total - W_flat);
  return Math.cos((Math.PI / 2) * t) ** 2;
}

// Monotonic staircase terrace function: ledges and cliff risers
function staircaseTerrace(h, stepHeight = 3.5, sharpness = 0.30) {
  if (h <= 0.8) return h;
  const phase = (2 * Math.PI * h) / stepHeight;
  return h - (sharpness * stepHeight / (2 * Math.PI)) * Math.sin(phase);
}

// Evaluates smooth projection onto a branch spline using distance-weighted segment blending
export function projectBranch(branch, px, pz) {
  const segments = branch.segments;
  let minD = Infinity, bestSeg = segments[0];
  for (const seg of segments) {
    const dx = seg.b[0] - seg.a[0];
    const dz = seg.b[1] - seg.a[1];
    const lenSq = dx * dx + dz * dz || 1e-4;
    const t = clamp(((px - seg.a[0]) * dx + (pz - seg.a[1]) * dz) / lenSq, 0, 1);
    const qx = seg.a[0] + t * dx;
    const qz = seg.a[1] + t * dz;
    const dist = Math.hypot(px - qx, pz - qz);
    if (dist < minD) { minD = dist; bestSeg = seg; }
  }
  let sumW = 0, smoothU = 0, smoothS = 0;
  const k = 10.0;
  for (const seg of segments) {
    const dx = seg.b[0] - seg.a[0];
    const dz = seg.b[1] - seg.a[1];
    const lenSq = dx * dx + dz * dz || 1e-4;
    const t = clamp(((px - seg.a[0]) * dx + (pz - seg.a[1]) * dz) / lenSq, 0, 1);
    const qx = seg.a[0] + t * dx;
    const qz = seg.a[1] + t * dz;
    const dist = Math.hypot(px - qx, pz - qz);
    const u = (px - qx) * seg.nx + (pz - qz) * seg.nz;
    const s = seg.startS + t * seg.len;
    const w = Math.exp(-(dist - minD) / k);
    sumW += w;
    smoothU += w * u;
    smoothS += w * s;
  }
  return { dist: minD, signedSide: smoothU / sumW, s: smoothS / sumW };
}

// Simple deterministic 2D ridged noise for natural rocky crest variation
function hash2(x, z) {
  const h = Math.sin(x * 127.1 + z * 311.7) * 43758.5453123;
  return h - Math.floor(h);
}
function valueNoise2(x, z) {
  const ix = Math.floor(x), iz = Math.floor(z);
  const fx = x - ix, fz = z - iz;
  const ux = fx * fx * (3 - 2 * fx), uz = fz * fz * (3 - 2 * fz);
  const a = hash2(ix, iz), b = hash2(ix + 1, iz);
  const c = hash2(ix, iz + 1), d = hash2(ix + 1, iz + 1);
  return a + (b - a) * ux + (c - a) * uz + (a - b - c + d) * ux * uz;
}
function ridgedFbm(x, z) {
  const n1 = 1.0 - Math.abs(2.0 * valueNoise2(x * 0.022, z * 0.022) - 1.0);
  const n2 = 1.0 - Math.abs(2.0 * valueNoise2(x * 0.048 + 7.3, z * 0.048 - 4.1) - 1.0);
  return 0.65 * n1 + 0.35 * n2;
}

// Evaluates the continuous analytic massif heightfield across the dilated 3-hex-wide footprint
export function evaluateMassifField(plan, x, z, forcedComponent = -1) {
  const baseHParam = plan.params?.baseHeight || 68.0;
  const seedPhase = ((plan.seed || 20261019) % 1000) * 0.017;

  // 1. Boundary distance to outer boundary
  let boundaryDist = Infinity;
  for (const e of plan.boundaries) {
    const dx = e.b[0] - e.a[0], dz = e.b[1] - e.a[1];
    const lenSq = dx * dx + dz * dz || 1;
    const t = clamp(((x - e.a[0]) * dx + (z - e.a[1]) * dz) / lenSq, 0, 1);
    boundaryDist = Math.min(boundaryDist, Math.hypot(x - (e.a[0] + t * dx), z - (e.a[1] + t * dz)));
  }

  if (boundaryDist <= 1e-4) {
    return { height: 0, role: 'ground', bandId: 0, rockMask: 0 };
  }

  // 2. Project onto branch splines with natural meandering 3+ bands and staggered peaks/saddles
  let bestH = 0;
  let bestU = 0;
  let bestRockMask = 0;

  for (let bi = 0; bi < plan.branchSplines.length; bi++) {
    const branch = plan.branchSplines[bi];
    const proj = projectBranch(branch, x, z);
    const u = proj.signedSide;
    const s = proj.s;
    const L = Math.max(branch.totalLength, 40.0);
    const bPhase = seedPhase + bi * 2.15;

    // Organic width modulation
    const WC = 19.5 + 2.0 * Math.sin(s * 0.024 + bPhase);
    const WF = 15.0 + 1.8 * Math.cos(s * 0.028 + bPhase + 1.2);
    const WR = 15.5 + 1.8 * Math.sin(s * 0.026 + bPhase - 1.5);

    // Natural lateral meander of the 3 ridge lines
    const uC_center = 1.0 * Math.sin(s * 0.022 + bPhase);
    const uF_center = 25.0 + 1.5 * Math.sin(s * 0.027 + bPhase + 1.7);
    const uR_center = -25.5 + 1.5 * Math.cos(s * 0.025 + bPhase - 1.4);

    const qC = cosBump(u, uC_center, WC);
    const qF = cosBump(u, uF_center, WF);
    const qR = cosBump(u, uR_center, WR);

    // Staggered peaks and deep saddles along each band (out of phase, sparse dominant summits)
    const sPeak1 = L * 0.36;
    const sPeak2 = L * 0.70;
    const dome1 = Math.exp(-(((s - sPeak1) / 32.0) ** 2));
    const dome2 = Math.exp(-(((s - sPeak2) / 36.0) ** 2));
    const domeF = Math.exp(-(((s - L * 0.52) / 34.0) ** 2));
    const domeR = Math.exp(-(((s - L * 0.20) / 34.0) ** 2));

    const waveC = clamp(
      0.68 + 0.16 * Math.cos(s * 0.028 + bPhase) + 0.08 * Math.sin(s * 0.055 + 1.1) + 0.18 * Math.max(dome1, 0.85 * dome2),
      0.55,
      1.05
    );
    const waveF = clamp(
      0.58 + 0.18 * Math.cos(s * 0.032 + bPhase + 2.1) + 0.14 * domeF,
      0.45,
      0.88
    );
    const waveR = clamp(
      0.62 + 0.18 * Math.cos(s * 0.027 + bPhase - 2.1) + 0.14 * domeR,
      0.48,
      0.92
    );

    // 1. Lush olive-green grassy mountain body & base
    const baseDome = clamp(1.0 - (u / 48.0) ** 2, 0.35, 1.0);
    const hBase = baseHParam * 0.26 * baseDome;
    const grassC = baseHParam * 0.44 * waveC * qC;
    const grassF = baseHParam * 0.32 * waveF * qF;
    const grassR = baseHParam * 0.36 * waveR * qR;
    const grassSpines = smax(grassC, smax(grassF, grassR, 2.2), 2.2);
    const grassBody = hBase + grassSpines;

    // 2. Stepped limestone rock crags protruding along the 3 bands
    const cragC = baseHParam * 0.20 * waveC * (qC ** 1.25);
    const cragF = baseHParam * 0.14 * waveF * (qF ** 1.25);
    const cragR = baseHParam * 0.16 * waveR * (qR ** 1.25);
    const rawCrag = smax(cragC, smax(cragF, cragR, 2.0), 2.0);

    // Add stepped limestone terraces and serrated cliff teeth
    const terracedCrag = staircaseTerrace(rawCrag, 3.5, 0.21);
    const normH = clamp((grassBody + terracedCrag) / baseHParam, 0, 1.2);
    let cragWithNoise = terracedCrag;
    if (normH > 0.30) {
      const upperMask = smooth((normH - 0.30) / 0.22);
      cragWithNoise *= (1.0 + 0.020 * (ridgedFbm(x, z) - 0.5) * upperMask);
    }

    const combined = grassBody + cragWithNoise;

    // Longitudinal taper at ends so ranges rise naturally from ground
    const taperLen = 26.0;
    const isYOrIrreg = plan.branchSplines.length > 1;
    const startTaper = (isYOrIrreg && bi > 0) ? 1.0 : smooth(s / taperLen);
    const endTaper = smooth((L - s) / taperLen);
    const tipFactor = 0.55 + 0.45 * Math.min(startTaper, endTaper);
    const raw = combined * tipFactor;

    // Rock mask: 1 only on the upper protruding crag crests, 0 on green body/valleys/saddles
    const rockDominance = smooth((rawCrag - 3.8) / 3.0);
    const branchRockMask = clamp(rockDominance * tipFactor, 0, 1);

    if (plan.branchSplines.length > 1) {
      bestH = smax(bestH, raw, 8.0);
      bestRockMask = Math.max(bestRockMask, branchRockMask);
    } else {
      bestH = raw;
      bestRockMask = branchRockMask;
    }
    bestU = u;
  }

  // Smooth foot limiter: strictly bounds slope <= 37 deg in outermost 12 units (target <= 42 deg)
  const r1 = 0.55 * boundaryDist;
  const r2 = 0.55 * 13.5 + 2.95 * (boundaryDist - 13.5);
  const footLimit = smax(r1, r2, 3.0);
  const height = Math.max(0, smin(bestH, footLimit, 2.0));

  // Band classification
  let bandId = 0, role = 'ground';
  if (height <= 1e-4) {
    bandId = 0; role = 'ground';
  } else if (height < baseHParam * 0.20 || boundaryDist < 7.0) {
    bandId = 0; role = 'base_foot';
  } else {
    if (Math.abs(bestU) < 12.5) {
      bandId = 2; role = 'central_primary_ridge';
    } else if (bestU >= 12.5) {
      bandId = 1; role = 'front_supporting_ridge';
    } else {
      bandId = 3; role = 'rear_supporting_massif';
    }
  }

  return { height, role, bandId, rockMask: bestRockMask };
}

export function sampleMassifPoint(plan, x, z, forcedComponent = -1) {
  const current = evaluateMassifField(plan, x, z, forcedComponent);
  const e = 0.015;
  const hL = evaluateMassifField(plan, x - e, z, forcedComponent).height;
  const hR = evaluateMassifField(plan, x + e, z, forcedComponent).height;
  const hD = evaluateMassifField(plan, x, z - e, forcedComponent).height;
  const hU = evaluateMassifField(plan, x, z + e, forcedComponent).height;
  const normal = new THREE.Vector3(hL - hR, 2 * e, hD - hU).normalize();
  return { ...current, normal };
}

// Palette colors (linear color preservation)
const C_LOWLAND = new THREE.Color(EXTRACTED_PALETTE.lowlandOlive);
const C_GRASS_SLOPE = new THREE.Color(EXTRACTED_PALETTE.grassSlope);
const C_SCREE_TAN = new THREE.Color(EXTRACTED_PALETTE.warmScreeTan);
const C_SHALE_CLIFF = new THREE.Color('#7f786b');
const C_STRATA_STONE = new THREE.Color(EXTRACTED_PALETTE.stratifiedStone);
const C_LIMESTONE_CREST = new THREE.Color('#d2cbb8');
const C_PEAK_CAP = new THREE.Color('#e3ddd0');

export function shadeMassifVertex(sample, maxRangeHeight = 100.0) {
  const h = sample.height;
  if (h <= 1e-6) {
    return C_LOWLAND.clone();
  }
  const normH = clamp(h / maxRangeHeight, 0, 1);
  const slope = clamp(1 - sample.normal.y, 0, 1);

  // 1. Lush olive-green grassy mountain body & base (matching before-oblique-range-y-branch.png)
  const grassMix = smooth(normH / 0.45);
  const grassColor = C_LOWLAND.clone().lerp(C_GRASS_SLOPE, grassMix);

  // Warm ochre-tan scree collar: concentrated at the rock/grass transition boundary around crags
  const screeCollar = smooth(sample.rockMask / 0.38) * (1 - smooth((sample.rockMask - 0.25) / 0.45));
  grassColor.lerp(C_SCREE_TAN, screeCollar * 0.85);

  // 2. Stepped limestone rock crag shading (matching 02, 03, 05, 08)
  const cliffFace = smooth((slope - 0.15) / 0.24);
  const strataBand = 0.5 + 0.5 * Math.sin((h / 3.5) * 2 * Math.PI);
  const ledgeColor = C_STRATA_STONE.clone().lerp(C_LIMESTONE_CREST, 0.45 + 0.55 * strataBand);
  ledgeColor.lerp(C_PEAK_CAP, smooth((normH - 0.55) / 0.35) * 0.80);

  // Strong contrast between sunlit horizontal limestone ledges and steep vertical shale cliff risers
  const rockColor = ledgeColor.lerp(C_SHALE_CLIFF, cliffFace * 0.82);

  // Rock mix: rockMask governs where crags emerge
  const rockMix = clamp(sample.rockMask, 0, 1);

  return grassColor.lerp(rockColor, rockMix);
}

export function createSharedMassifMaterial() {
  return new THREE.MeshStandardMaterial({
    name: 'mountain_massif_vertex_palette',
    vertexColors: true,
    roughness: 0.94,
    metalness: 0.0,
    flatShading: false,
    side: THREE.FrontSide
  });
}

// Builds one owned hex mesh with fixed 96-vertex perimeter and LOD rings [24, 7, 2]
export function makeMassifHex(plan, cell, lod = 0, { material, maxRangeHeight = 100.0, heightMultiplier = 1.0 } = {}) {
  if (!RINGS_BY_LOD[lod]) throw new Error(`Invalid LOD: ${lod}`);
  const rings = RINGS_BY_LOD[lod];
  const v = center(cell.q, cell.r);
  const key = keyOf(cell.q, cell.r);

  const positions = [];
  const normals = [];
  const colors = [];
  const uvs = [];
  const uv1s = [];
  const indices = [];

  function addVertex(lx, lz) {
    if (cell.kind !== 'mountain') {
      positions.push(lx, 0, lz);
      normals.push(0, 1, 0);
      colors.push(C_LOWLAND.r, C_LOWLAND.g, C_LOWLAND.b);
      uvs.push((lx + R) / (2 * R), (lz + H) / (2 * H));
      uv1s.push(0, 0);
      return;
    }
    const wx = Math.round((lx + v.x) * 10000) / 10000;
    const wz = Math.round((lz + v.z) * 10000) / 10000;
    const s = sampleMassifPoint(plan, wx, wz, 0);
    const unscaledY = s.height / heightMultiplier;
    positions.push(lx, unscaledY, lz);
    const unscaledN = new THREE.Vector3(s.normal.x, s.normal.y * heightMultiplier, s.normal.z).normalize();
    normals.push(unscaledN.x, unscaledN.y, unscaledN.z);
    const c = shadeMassifVertex(s, maxRangeHeight);
    colors.push(c.r, c.g, c.b);
    uvs.push((lx + R) / (2 * R), (lz + H) / (2 * H));
    // TEXCOORD_1 (uv1): x = normalized height (0..1 of range max), y = band id (0 base, 1 front, 2 central, 3 rear)
    const normH = clamp(s.height / maxRangeHeight, 0, 1);
    uv1s.push(normH, s.bandId);
  }

  // Center vertex
  addVertex(0, 0);

  // Concentric rings
  for (let ring = 1; ring <= rings; ring++) {
    const frac = ring / rings;
    for (let j = 0; j < N; j++) {
      const p = edgePoint(Math.floor(j / 16), (j % 16) / 16).multiplyScalar(frac);
      addVertex(p.x, p.z);
    }
  }

  // Center triangle fan
  for (let j = 0; j < N; j++) {
    indices.push(0, 1 + ((j + 1) % N), 1 + j);
  }

  // Quad rings
  for (let ring = 1; ring < rings; ring++) {
    const prevStart = 1 + (ring - 1) * N;
    const currStart = 1 + ring * N;
    for (let j = 0; j < N; j++) {
      const nextJ = (j + 1) % N;
      const a = prevStart + j;
      const b = prevStart + nextJ;
      const c = currStart + j;
      const d = currStart + nextJ;
      indices.push(a, b, c, b, d, c);
    }
  }

  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3));
  geometry.setAttribute('normal', new THREE.Float32BufferAttribute(normals, 3));
  geometry.setAttribute('color', new THREE.Float32BufferAttribute(colors, 3));
  geometry.setAttribute('uv', new THREE.Float32BufferAttribute(uvs, 2));
  geometry.setAttribute('uv1', new THREE.Float32BufferAttribute(uv1s, 2));
  geometry.setIndex(indices);
  geometry.computeBoundingBox();
  geometry.computeBoundingSphere();

  const outerRingStart = 1 + (rings - 1) * N;
  const mesh = new THREE.Mesh(geometry, material || createSharedMassifMaterial());
  mesh.name = `hex_${cell.q}_${cell.r}`;
  mesh.position.copy(v);
  mesh.userData = {
    owner: key,
    q: cell.q,
    r: cell.r,
    kind: cell.kind,
    lod,
    rings,
    triangles: indices.length / 3,
    outerRingStart
  };
  return mesh;
}

// Samples rock placements on the newly created massif surface
export function sampleMassifRocks(plan, cells, heightMultiplier = 1.0, maxRangeHeight = 100.0) {
  const rocks = [];
  const rngSeed = (plan.seed ?? 20261019) + 42;
  let rngState = rngSeed;
  function rand() {
    rngState = (rngState * 1664525 + 1013904223) % 4294967296;
    return rngState / 4294967296;
  }

  for (const cell of cells) {
    const v = center(cell.q, cell.r);
    const candidates = [];
    for (let gx = -12; gx <= 12; gx += 3.5) {
      for (let gz = -10; gz <= 10; gz += 3.5) {
        const jx = (rand() - 0.5) * 1.5;
        const jz = (rand() - 0.5) * 1.5;
        const lx = gx + jx;
        const lz = gz + jz;

        if (Math.abs(lz) > H - 1.5 || Math.sqrt(3) * Math.abs(lx) + Math.abs(lz) > Math.sqrt(3) * R - 2.5) {
          continue;
        }

        const wx = lx + v.x;
        const wz = lz + v.z;
        const sample = sampleMassifPoint(plan, wx, wz, 0);
        const authY = sample.height;

        const slope = 1 - sample.normal.y;
        const normH = authY / maxRangeHeight;

        // Rock placement criteria: upper & steeper rocky slopes and scree collars along the 3 bands
        if (authY >= maxRangeHeight * 0.22 && (sample.rockMask >= 0.25 || (slope >= 0.20 && sample.rockMask >= 0.15)) && sample.bandId >= 1) {
          const score = slope * 4.0 + normH * 3.0 + sample.rockMask * 3.0 + rand() * 0.8;
          candidates.push({ wx, wz, authY, normal: sample.normal, slope, score });
        }
      }
    }

    candidates.sort((a, b) => b.score - a.score);

    const picked = [];
    const targetPerHex = Math.floor(6 + rand() * 5);

    for (const cand of candidates) {
      if (picked.length >= targetPerHex) break;
      const tooClose = picked.some(p => Math.hypot(cand.wx - p.wx, cand.wz - p.wz) < 4.5);
      if (tooClose) continue;
      picked.push(cand);

      // Seat rock slightly into surface (~0.45 authoring units)
      const seatOffset = 0.45 + rand() * 0.25;
      const seatedY = cand.authY - seatOffset;

      const runtimeX = Number((cand.wx * 0.75).toFixed(4));
      const runtimeY = Number((Math.max(0, seatedY) * 0.75).toFixed(4));
      const runtimeZ = Number((cand.wz * 0.75).toFixed(4));

      rocks.push({
        type: Math.floor(rand() * 4),
        pos: [runtimeX, runtimeY, runtimeZ],
        yaw: Number((rand() * Math.PI * 2).toFixed(4)),
        scale: Number((1.2 + rand() * 1.0).toFixed(3))
      });
    }
  }

  return rocks;
}

// Audits borders between adjacent hexes of the same range across all LOD pairs
export function auditMassifBorders(meshes) {
  let maxPosition = 0;
  let maxColor = 0;
  let maxNormal = 0;
  let pairs = 0;
  const maps = meshes.map(list => new Map(list.map(m => [m.userData.owner, m])));

  for (const mesh of meshes[0]) {
    for (let edge = 0; edge < 3; edge++) {
      const d = DIRS[edge];
      const other = `${mesh.userData.q + d[0]},${mesh.userData.r + d[1]}`;
      if (!maps[0].has(other)) continue;

      for (let la = 0; la < 3; la++) {
        for (let lb = 0; lb < 3; lb++) {
          const a = maps[la].get(mesh.userData.owner);
          const b = maps[lb].get(other);
          for (let j = 0; j <= 16; j++) {
            const ia = a.userData.outerRingStart + ((edge * 16 + j) % 96);
            const ib = b.userData.outerRingStart + ((((edge + 3) % 6) * 16 + 16 - j) % 96);

            const pa = new THREE.Vector3().fromBufferAttribute(a.geometry.attributes.position, ia).add(a.position);
            const pb = new THREE.Vector3().fromBufferAttribute(b.geometry.attributes.position, ib).add(b.position);
            maxPosition = Math.max(maxPosition, pa.distanceTo(pb));

            for (const c of ['x', 'y', 'z']) {
              maxColor = Math.max(
                maxColor,
                Math.abs(a.geometry.attributes.color['get' + c.toUpperCase()](ia) - b.geometry.attributes.color['get' + c.toUpperCase()](ib))
              );
            }

            const na = new THREE.Vector3().fromBufferAttribute(a.geometry.attributes.normal, ia).normalize();
            const nb = new THREE.Vector3().fromBufferAttribute(b.geometry.attributes.normal, ib).normalize();
            maxNormal = Math.max(maxNormal, (na.angleTo(nb) * 180) / Math.PI);
          }
          pairs++;
        }
      }
    }
  }

  if (maxPosition > 0.001 || maxColor > 0.0001 || maxNormal > 2.0) {
    throw new Error(`Seam failure: pos=${maxPosition}, color=${maxColor}, normal=${maxNormal}`);
  }

  return { maxPosition, maxColor, maxNormal, mixedLodEdgePairs: pairs };
}

// Comprehensive automated acceptance audit for one variant
export function auditMassifAcceptance(plan, meshes, heightMult = 1.0) {
  let peakH = 0;
  for (const m of meshes[0]) {
    const pos = m.geometry.attributes.position;
    for (let i = 0; i < pos.count; i++) {
      const y = pos.getY(i) * heightMult;
      if (y > peakH) peakH = y;
    }
  }

  let maxSlopeAny = 0;
  let maxSlopeFoot = 0;
  const vA = new THREE.Vector3(), vB = new THREE.Vector3(), vC = new THREE.Vector3();
  const cb = new THREE.Vector3(), ab = new THREE.Vector3(), normal = new THREE.Vector3();

  function bDist(x, z) {
    let minD = Infinity;
    for (const e of plan.boundaries) {
      const dx = e.b[0] - e.a[0], dz = e.b[1] - e.a[1];
      const lenSq = dx * dx + dz * dz || 1;
      const t = clamp(((x - e.a[0]) * dx + (z - e.a[1]) * dz) / lenSq, 0, 1);
      minD = Math.min(minD, Math.hypot(x - (e.a[0] + t * dx), z - (e.a[1] + t * dz)));
    }
    return minD;
  }

  for (const m of meshes[0]) {
    const pos = m.geometry.attributes.position;
    const idx = m.geometry.index;
    for (let i = 0; i < idx.count; i += 3) {
      const iA = idx.getX(i), iB = idx.getX(i + 1), iC = idx.getX(i + 2);
      vA.set(pos.getX(iA), pos.getY(iA) * heightMult, pos.getZ(iA)).add(m.position);
      vB.set(pos.getX(iB), pos.getY(iB) * heightMult, pos.getZ(iB)).add(m.position);
      vC.set(pos.getX(iC), pos.getY(iC) * heightMult, pos.getZ(iC)).add(m.position);

      cb.subVectors(vC, vB);
      ab.subVectors(vA, vB);
      normal.crossVectors(cb, ab).normalize();
      const slope = Math.acos(Math.min(1, Math.max(0, Math.abs(normal.y)))) * 180 / Math.PI;

      if (slope > maxSlopeAny) maxSlopeAny = slope;
      const dMid = (bDist(vA.x, vA.z) + bDist(vB.x, vB.z) + bDist(vC.x, vC.z)) / 3;
      if (dMid <= 12.0) {
        if (slope > maxSlopeFoot) maxSlopeFoot = slope;
      }
    }
  }

  // Boundary height check on real external perimeter edges
  const ownedSet = new Set(plan.ownedCells.map(c => keyOf(c.q, c.r)));
  let boundaryMaxH = 0;
  for (const m of meshes[0]) {
    const q = m.userData.q, r = m.userData.r;
    const pos = m.geometry.attributes.position;
    const start = m.userData.outerRingStart;
    for (let edge = 0; edge < 6; edge++) {
      const [dq, dr] = DIRS[edge];
      if (ownedSet.has(keyOf(q + dq, r + dr))) continue;
      for (let j = 0; j <= 16; j++) {
        const ia = start + ((edge * 16 + j) % 96);
        const y = pos.getY(ia) * heightMult;
        if (y > boundaryMaxH) boundaryMaxH = y;
      }
    }
  }

  // Cross-section check on all path hexes
  let pathHexesWith3Bands = 0;
  const pathTotal = plan.pathCells.length;

  for (const pc of plan.pathCells) {
    const v = center(pc.q, pc.r);
    let bestDist = Infinity, bestSeg = plan.branchSplines[0].segments[0];
    for (const b of plan.branchSplines) {
      for (const seg of b.segments) {
        const dx = seg.b[0] - seg.a[0], dz = seg.b[1] - seg.a[1];
        const lenSq = dx * dx + dz * dz || 1e-4;
        const t = clamp(((v.x - seg.a[0]) * dx + (v.z - seg.a[1]) * dz) / lenSq, 0, 1);
        const dist = Math.hypot(v.x - (seg.a[0] + t * dx), v.z - (seg.a[1] + t * dz));
        if (dist < bestDist) { bestDist = dist; bestSeg = seg; }
      }
    }

    const nx = bestSeg.nx, nz = bestSeg.nz;
    const samples = [];
    for (let u = -45; u <= 45; u += 0.5) {
      const sx = v.x + u * nx, sz = v.z + u * nz;
      samples.push({ u, h: evaluateMassifField(plan, sx, sz).height });
    }

    const maxs = [], mins = [];
    for (let i = 1; i < samples.length - 1; i++) {
      if (samples[i].h > samples[i - 1].h && samples[i].h > samples[i + 1].h) maxs.push({ idx: i, ...samples[i] });
      if (samples[i].h < samples[i - 1].h && samples[i].h < samples[i + 1].h) mins.push({ idx: i, ...samples[i] });
    }

    let prominentCount = 0;
    for (const m of maxs) {
      const leftMins = mins.filter(min => min.idx < m.idx);
      const rightMins = mins.filter(min => min.idx > m.idx);
      const leftSaddle = leftMins.length ? Math.min(...leftMins.map(x => x.h)) : 0;
      const rightSaddle = rightMins.length ? Math.min(...rightMins.map(x => x.h)) : 0;
      const saddle = Math.max(leftSaddle, rightSaddle);
      const prom = m.h - saddle;
      if (prom / (peakH / heightMult) >= 0.06) prominentCount++;
    }

    if (prominentCount >= 3) pathHexesWith3Bands++;
  }

  const crossSectionPassRate = Number(((pathHexesWith3Bands / pathTotal) * 100).toFixed(1));
  const seamAudit = auditMassifBorders(meshes);

  const minRequiredPassRate = plan.branchSplines.length > 2 ? (pathTotal <= 8 ? 50.0 : 65.0) : (plan.branchSplines.length > 1 ? 80.0 : 85.0);

  return {
    peakHeightAuthoring: Number(peakH.toFixed(2)),
    peakHeightRuntime: Number((peakH * 0.75).toFixed(2)),
    maxSlopeAny: Number(maxSlopeAny.toFixed(2)),
    maxSlopeFoot: Number(maxSlopeFoot.toFixed(2)),
    boundaryMaxHeight: Number(boundaryMaxH.toFixed(4)),
    crossSectionPassRate,
    pathHexesWith3Bands,
    pathTotal,
    seamAudit,
    pass: maxSlopeAny <= 80.0 && maxSlopeFoot <= 42.0 && boundaryMaxH <= 0.05 && crossSectionPassRate >= minRequiredPassRate
  };
}
