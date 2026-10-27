import http from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';

const __dirname = dirname(fileURLToPath(import.meta.url));
const STUDIO_DIR = resolve(__dirname, '../..');
const CHROME_PATH = 'C:/Program Files/Google/Chrome/Application/chrome.exe';

export function getCastlePreviewHtml(castleManifest) {
  return `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>Scaled Castle 4 Variants Preview</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      background: #0b0f17;
      color: #c9d1d9;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      width: 2400px;
      height: 1600px;
      overflow: hidden;
      position: relative;
    }
    #canvas {
      position: absolute;
      left: 0;
      top: 0;
      width: 2400px;
      height: 1600px;
    }
    #overlay {
      position: absolute;
      top: 16px;
      left: 24px;
      z-index: 10;
      background: rgba(13, 17, 23, 0.90);
      border: 1px solid #30363d;
      padding: 14px 20px;
      border-radius: 8px;
    }
    h1 { font-size: 22px; color: #58a6ff; margin-bottom: 4px; }
    p { font-size: 13px; color: #8b949e; line-height: 1.4; }
    .legend { display: flex; gap: 20px; margin-top: 8px; font-size: 12px; font-weight: bold; }
    .legend-hq { color: #f0883e; }
    .legend-ord { color: #e34c26; }
    .legend-keep { color: #7ee787; }
    .view-title-top {
      position: absolute;
      top: 1020px;
      left: 24px;
      z-index: 10;
      background: rgba(13, 17, 23, 0.90);
      border: 1px solid #30363d;
      padding: 8px 16px;
      border-radius: 6px;
      font-size: 14px;
      color: #79c0ff;
      font-weight: bold;
    }
    .labels {
      position: absolute;
      bottom: 16px;
      left: 0;
      width: 2400px;
      display: flex;
      justify-content: space-around;
      z-index: 10;
      pointer-events: none;
    }
    .card {
      background: rgba(22, 27, 34, 0.94);
      border: 1px solid #30363d;
      border-radius: 6px;
      padding: 8px 14px;
      text-align: center;
      width: 520px;
    }
    .card h2 { font-size: 15px; color: #79c0ff; margin-bottom: 2px; }
    .card p { font-size: 11px; color: #8b949e; }
    .card .stats { font-size: 11px; color: #a5d6ff; font-weight: bold; margin-top: 2px; }
  </style>
  <script type="importmap">
  {
    "imports": {
      "three": "/node_modules/three/build/three.module.js",
      "three/addons/": "/node_modules/three/examples/jsm/"
    }
  }
  </script>
</head>
<body>
  <div id="overlay">
    <h1>StrategyGame — Scaled Castle (Original Hex Stronghold + Closed 6-Sided Curtain Wall & Gatehouse)</h1>
    <p>Based on Original Castle (06-major-stronghold + 02-stone-earth-defensive-wall + 03-layered-gatehouse) | ~22.6m–24.8m (~2x HQ) | Closed Hex Ring</p>
    <div class="legend">
      <span class="legend-hq">■ HQ Unit Reference Box (Height 12.0)</span>
      <span class="legend-ord">■ Ordinary Unit Reference Box (Height 9.6)</span>
      <span class="legend-keep">▲ Castle Keeps (Height 22.6m - 24.8m, 100% original fortress architecture)</span>
    </div>
  </div>

  <div class="view-title-top">▼ TOP-DOWN SILHOUETTE VIEW (Closed 6-Sided Stone Curtain Wall + Central Stronghold + Front Gatehouse)</div>

  <div class="labels">
    <div class="card">
      <h2>v1: Grand Stone Stronghold (Standard Hex Curtain)</h2>
      <p>Central 06-major-stronghold (23.4m) + closed 6-sided stone curtain wall (9.8m) + layered gatehouse (13.0m)</p>
      <div class="stats">Keep: 23.4m | Curtain Wall: 9.8m | Gate: 13.0m | Radius: ≤15.2m (≤16.2m)</div>
    </div>
    <div class="card">
      <h2>v2: High Citadel Stronghold (Elevated Stone Keep)</h2>
      <p>Elevated rocky citadel stronghold (24.8m) + closed 6-sided stone curtain wall (10.2m) + layered gatehouse (13.5m)</p>
      <div class="stats">Keep: 24.8m | Curtain Wall: 10.2m | Gate: 13.5m | Radius: ≤15.4m (≤16.2m)</div>
    </div>
    <div class="card">
      <h2>v3: Heavy Bastion Stronghold (Reinforced Curtain Ring)</h2>
      <p>Heavy stone stronghold (23.8m) + thickened 6-sided stone curtain wall (10.7m) + monumental gatehouse (13.9m)</p>
      <div class="stats">Keep: 23.8m | Curtain Wall: 10.7m | Gate: 13.9m | Radius: ≤15.3m (≤16.2m)</div>
    </div>
    <div class="card">
      <h2>v4: Broad Courtyard Stronghold (Deep Muster Plaza)</h2>
      <p>Broad courtyard stone stronghold (22.6m) + wide closed 6-sided stone curtain wall (9.4m) + layered gatehouse (12.5m)</p>
      <div class="stats">Keep: 22.6m | Curtain Wall: 9.4m | Gate: 12.5m | Radius: ≤15.5m (≤16.2m)</div>
    </div>
  </div>

  <canvas id="canvas" width="2400" height="1600"></canvas>
  <script type="module">
    import * as THREE from 'three';
    import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';

    const canvas = document.getElementById('canvas');
    const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: false, preserveDrawingBuffer: true });
    renderer.setSize(2400, 1600);
    renderer.setPixelRatio(1);
    renderer.setClearColor(0x0a0e16, 1);
    renderer.toneMapping = THREE.ACESFilmicToneMapping;
    renderer.toneMappingExposure = 1.15;
    renderer.shadowMap.enabled = true;
    renderer.shadowMap.type = THREE.PCFSoftShadowMap;

    const scene = new THREE.Scene();

    const groundMat = new THREE.MeshStandardMaterial({ color: 0x141a24, roughness: 0.95, metalness: 0.05 });
    const ground = new THREE.Mesh(new THREE.PlaneGeometry(360, 200), groundMat);
    ground.rotation.x = -Math.PI / 2;
    ground.receiveShadow = true;
    scene.add(ground);

    const grid = new THREE.GridHelper(360, 72, 0x30363d, 0x1f242c);
    grid.position.y = 0.01;
    scene.add(grid);

    const hemiLight = new THREE.HemisphereLight(0xddeeff, 0x223344, 0.95);
    scene.add(hemiLight);

    const sun = new THREE.DirectionalLight(0xfff3e0, 2.2);
    sun.position.set(40, 70, 50);
    sun.castShadow = true;
    sun.shadow.mapSize.width = 4096;
    sun.shadow.mapSize.height = 4096;
    scene.add(sun);

    const fillSun = new THREE.DirectionalLight(0x88aacc, 0.75);
    fillSun.position.set(-50, 35, -40);
    scene.add(fillSun);

    // Oblique Perspective (~35 deg angle)
    const cameraOblique = new THREE.PerspectiveCamera(35, 2400 / 1060, 1, 500);
    cameraOblique.position.set(0, 34, 98);
    cameraOblique.lookAt(0, 12, 0);

    // Top-Down Orthogonal View
    const cameraTopDown = new THREE.OrthographicCamera(-125, 125, 25, -25, 1, 250);
    cameraTopDown.position.set(0, 100, 0);
    cameraTopDown.lookAt(0, 0, 0);

    const loader = new GLTFLoader();

    const variantKeys = ['castle_v1', 'castle_v2', 'castle_v3', 'castle_v4'];
    const xPositions = [-54, -18, 18, 54];

    for (let i = 0; i < 4; i++) {
      const vk = variantKeys[i];
      const cx = xPositions[i];

      // Hex Boundary Circle (R=18) and Safe Footprint Circle (R=16.2)
      const ringGeom = new THREE.RingGeometry(17.8, 18.0, 48);
      const ringMat = new THREE.MeshBasicMaterial({ color: 0x388bfd, side: THREE.DoubleSide });
      const ring = new THREE.Mesh(ringGeom, ringMat);
      ring.rotation.x = -Math.PI / 2;
      ring.position.set(cx, 0.02, 0);
      scene.add(ring);

      const safeRingGeom = new THREE.RingGeometry(16.1, 16.2, 48);
      const safeRingMat = new THREE.MeshBasicMaterial({ color: 0x2ea043, side: THREE.DoubleSide });
      const safeRing = new THREE.Mesh(safeRingGeom, safeRingMat);
      safeRing.rotation.x = -Math.PI / 2;
      safeRing.position.set(cx, 0.03, 0);
      scene.add(safeRing);

      // Reference Figures next to front gate
      // HQ figure box: 2.4 x 12.0 x 2.4 (gold)
      const hqBox = new THREE.Mesh(
        new THREE.BoxGeometry(2.4, 12.0, 2.4),
        new THREE.MeshStandardMaterial({ color: 0xf0883e, roughness: 0.3, metalness: 0.1 })
      );
      hqBox.position.set(cx - 3.5, 6.0, 14.5);
      hqBox.castShadow = true;
      scene.add(hqBox);

      // Ordinary unit box: 2.0 x 9.6 x 2.0 (red/crimson)
      const ordBox = new THREE.Mesh(
        new THREE.BoxGeometry(2.0, 9.6, 2.0),
        new THREE.MeshStandardMaterial({ color: 0xe34c26, roughness: 0.3, metalness: 0.1 })
      );
      ordBox.position.set(cx + 3.5, 4.8, 14.5);
      ordBox.castShadow = true;
      scene.add(ordBox);

      // Height Marker Pole at 24.0m (2.0x HQ line)
      const markerMat = new THREE.MeshBasicMaterial({ color: 0x58a6ff });
      const markerLine = new THREE.Mesh(new THREE.CylinderGeometry(0.08, 0.08, 30, 8), markerMat);
      markerLine.position.set(cx - 15.0, 15.0, 0);
      scene.add(markerLine);

      // Marker flag at 24m
      const flag = new THREE.Mesh(new THREE.BoxGeometry(2.5, 1.2, 0.1), new THREE.MeshBasicMaterial({ color: 0x2ea043 }));
      flag.position.set(cx - 13.5, 24.0, 0);
      scene.add(flag);

      // Load Castle Model
      const gltf = await loader.loadAsync('/castle4/exports/' + vk + '_lod0.glb');
      const model = gltf.scene;
      model.position.set(cx, 0, 0);
      model.traverse(o => {
        if (o.isMesh) {
          o.castShadow = true;
          o.receiveShadow = true;
        }
      });
      scene.add(model);
    }

    renderer.setScissorTest(true);
    renderer.setViewport(0, 540, 2400, 1060);
    renderer.setScissor(0, 540, 2400, 1060);
    renderer.render(scene, cameraOblique);

    renderer.setViewport(0, 0, 2400, 540);
    renderer.setScissor(0, 0, 2400, 540);
    renderer.render(scene, cameraTopDown);

    renderer.setScissorTest(false);
    window.__RENDER_DONE__ = true;
  </script>
</body>
</html>`;
}

export function getBuildingPreviewHtml() {
  return `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>Scaled Village & Farm Buildings Preview</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      background: #0b0f17;
      color: #c9d1d9;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      width: 2400px;
      height: 1200px;
      overflow: hidden;
      position: relative;
    }
    #canvas {
      position: absolute;
      left: 0;
      top: 0;
      width: 2400px;
      height: 1200px;
    }
    #overlay {
      position: absolute;
      top: 20px;
      left: 30px;
      z-index: 10;
      background: rgba(13, 17, 23, 0.90);
      border: 1px solid #30363d;
      padding: 16px 24px;
      border-radius: 8px;
    }
    h1 { font-size: 24px; color: #58a6ff; margin-bottom: 6px; }
    p { font-size: 14px; color: #8b949e; line-height: 1.5; }
    .legend { display: flex; gap: 20px; margin-top: 10px; font-size: 13px; font-weight: bold; }
    .legend-hq { color: #f0883e; }
    .legend-ord { color: #e34c26; }
    .legend-hall { color: #7ee787; }
    .labels {
      position: absolute;
      bottom: 24px;
      left: 0;
      width: 2400px;
      display: flex;
      justify-content: space-around;
      z-index: 10;
      pointer-events: none;
    }
    .card {
      background: rgba(22, 27, 34, 0.94);
      border: 1px solid #30363d;
      border-radius: 6px;
      padding: 8px 12px;
      text-align: center;
      width: 320px;
    }
    .card h2 { font-size: 14px; color: #79c0ff; margin-bottom: 2px; }
    .card p { font-size: 11px; color: #8b949e; }
    .card .stats { font-size: 11px; color: #a5d6ff; font-weight: bold; margin-top: 2px; }
  </style>
  <script type="importmap">
  {
    "imports": {
      "three": "/node_modules/three/build/three.module.js",
      "three/addons/": "/node_modules/three/examples/jsm/"
    }
  }
  </script>
</head>
<body>
  <div id="overlay">
    <h1>StrategyGame — Scaled Village & Farm Buildings Evaluation View</h1>
    <p>100% Original Single-Storey Historical Silhouettes | Clean Proportional Scaling | Zero Stacking / Zero Plinth Boxes</p>
    <div class="legend">
      <span class="legend-hq">■ HQ Unit Reference Box (Height 12.0)</span>
      <span class="legend-ord">■ Ordinary Unit Reference Box (Height 9.6)</span>
      <span class="legend-hall">▲ Communal Great Hall (Dominates at 15.0m, > 12m HQ)</span>
    </div>
  </div>

  <div class="labels">
    <div class="card">
      <h2>Small Peasant House</h2>
      <p>Single-storey authentic peasant dwelling</p>
      <div class="stats">Height: 8.20m | XZ: 1.32</div>
    </div>
    <div class="card">
      <h2>Medium Family House</h2>
      <p>Single-storey family house, natural roof</p>
      <div class="stats">Height: 9.50m | XZ: 1.38</div>
    </div>
    <div class="card">
      <h2>Utility Workshop</h2>
      <p>Single-storey forge bay & hearth loft</p>
      <div class="stats">Height: 9.00m | XZ: 1.35</div>
    </div>
    <div class="card">
      <h2>Raised Granary</h2>
      <p>Stilt-pillar grain storehouse</p>
      <div class="stats">Height: 9.40m | XZ: 1.35</div>
    </div>
    <div class="card">
      <h2>Communal Great Hall</h2>
      <p>Wide majestic single-roof communal hall</p>
      <div class="stats">Height: 15.00m | Footprint: 16.8x14.6m</div>
    </div>
    <div class="card">
      <h2>Walled Village Gate</h2>
      <p>Single-tier fortified stone arch gatehouse</p>
      <div class="stats">Height: 14.00m | Width: 11.8m</div>
    </div>
    <div class="card">
      <h2>Rural Farm Granary</h2>
      <p>Single compound with round thatch bins</p>
      <div class="stats">Height: 6.80m | XZ: 1.25</div>
    </div>
  </div>

  <canvas id="canvas" width="2400" height="1200"></canvas>
  <script type="module">
    import * as THREE from 'three';
    import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';

    const canvas = document.getElementById('canvas');
    const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: false, preserveDrawingBuffer: true });
    renderer.setSize(2400, 1200);
    renderer.setPixelRatio(1);
    renderer.setClearColor(0x0a0e16, 1);
    renderer.toneMapping = THREE.ACESFilmicToneMapping;
    renderer.toneMappingExposure = 1.18;
    renderer.shadowMap.enabled = true;
    renderer.shadowMap.type = THREE.PCFSoftShadowMap;

    const scene = new THREE.Scene();

    const groundMat = new THREE.MeshStandardMaterial({ color: 0x141a24, roughness: 0.95, metalness: 0.05 });
    const ground = new THREE.Mesh(new THREE.PlaneGeometry(280, 140), groundMat);
    ground.rotation.x = -Math.PI / 2;
    ground.receiveShadow = true;
    scene.add(ground);

    const grid = new THREE.GridHelper(280, 56, 0x30363d, 0x1f242c);
    grid.position.y = 0.01;
    scene.add(grid);

    const hemiLight = new THREE.HemisphereLight(0xddeeff, 0x223344, 0.95);
    scene.add(hemiLight);

    const sun = new THREE.DirectionalLight(0xfff3e0, 2.2);
    sun.position.set(30, 50, 45);
    sun.castShadow = true;
    sun.shadow.mapSize.width = 4096;
    sun.shadow.mapSize.height = 4096;
    scene.add(sun);

    const fillSun = new THREE.DirectionalLight(0x88aacc, 0.8);
    fillSun.position.set(-30, 30, -30);
    scene.add(fillSun);

    // Oblique Perspective (~35 deg angle)
    const camera = new THREE.PerspectiveCamera(34, 2400 / 1200, 1, 350);
    camera.position.set(0, 22, 68);
    camera.lookAt(0, 5.5, 0);

    const loader = new GLTFLoader();

    const parts = [
      'building_small_house',
      'building_medium_house',
      'building_workshop',
      'building_granary',
      'building_hall',
      'building_gate',
      'building_farm_granary'
    ];
    const xCoords = [-44, -29, -14, 0, 16, 32, 47];

    for (let i = 0; i < parts.length; i++) {
      const p = parts[i];
      const cx = xCoords[i];

      // Reference Figures in front-left of each building
      const hq = new THREE.Mesh(
        new THREE.BoxGeometry(1.6, 12.0, 1.6),
        new THREE.MeshStandardMaterial({ color: 0xf0883e, roughness: 0.3 })
      );
      hq.position.set(cx - 5.5, 6.0, 7.5);
      hq.castShadow = true;
      scene.add(hq);

      const ord = new THREE.Mesh(
        new THREE.BoxGeometry(1.4, 9.6, 1.4),
        new THREE.MeshStandardMaterial({ color: 0xe34c26, roughness: 0.3 })
      );
      ord.position.set(cx - 3.2, 4.8, 7.5);
      ord.castShadow = true;
      scene.add(ord);

      // Load building model
      const gltf = await loader.loadAsync('/buildings/exports/' + p + '_lod0.glb');
      const m = gltf.scene;
      m.position.set(cx, 0, 0);
      m.traverse(o => {
        if (o.isMesh) {
          o.castShadow = true;
          o.receiveShadow = true;
        }
      });
      scene.add(m);
    }

    renderer.render(scene, camera);
    window.__RENDER_DONE__ = true;
  </script>
</body>
</html>`;
}

/**
 * Spawns an internal HTTP server and invokes Chrome headless screenshot.
 */
export async function renderPreviews(options) {
  const {
    port = 5218,
    castleOutPath,
    buildingsOutPath,
    castleManifest,
    sceneryMassifDir
  } = options;

  const server = http.createServer(async (req, res) => {
    try {
      const url = req.url.split('?')[0];

      if (url === '/castle-preview.html') {
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        res.end(getCastlePreviewHtml(castleManifest));
      } else if (url === '/building-preview.html') {
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        res.end(getBuildingPreviewHtml());
      } else if (url.startsWith('/node_modules/three/')) {
        const relPath = url.replace('/node_modules/three/', '');
        const p = join(STUDIO_DIR, 'node_modules/three', relPath);
        const data = await readFile(p);
        const ext = p.endsWith('.js') ? 'application/javascript' : 'application/octet-stream';
        res.writeHead(200, { 'Content-Type': ext });
        res.end(data);
      } else if (url.startsWith('/castle4/exports/')) {
        const fn = url.replace('/castle4/exports/', '');
        const p = join(sceneryMassifDir, 'castle4/exports', fn);
        const data = await readFile(p);
        res.writeHead(200, { 'Content-Type': 'model/gltf-binary' });
        res.end(data);
      } else if (url.startsWith('/buildings/exports/')) {
        const fn = url.replace('/buildings/exports/', '');
        const p = join(sceneryMassifDir, 'buildings/exports', fn);
        const data = await readFile(p);
        res.writeHead(200, { 'Content-Type': 'model/gltf-binary' });
        res.end(data);
      } else {
        res.writeHead(404);
        res.end('Not found');
      }
    } catch (err) {
      res.writeHead(500);
      res.end('Server error: ' + err.message);
    }
  });

  await new Promise((resolveServer) => {
    server.listen(port, '127.0.0.1', () => resolveServer());
  });

  console.log(`Internal Preview Server running at http://127.0.0.1:${port}`);

  async function takeScreenshot(pageUrl, outputPath, width = 2400, height = 1200) {
    const args = [
      '--headless=new',
      '--enable-webgl',
      '--use-gl=angle',
      '--use-angle=d3d11',
      '--virtual-time-budget=9000',
      '--run-all-compositor-stages-before-draw',
      `--window-size=${width},${height}`,
      `--screenshot=${outputPath}`,
      pageUrl
    ];

    await new Promise((resolveProc, rejectProc) => {
      const proc = spawn(CHROME_PATH, args, { stdio: 'inherit' });
      proc.on('close', code => (code === 0 ? resolveProc() : rejectProc(new Error(`Chrome failed with code ${code}`))));
    });

    const s = await stat(outputPath);
    console.log(`PASS: Rendered ${outputPath} (${(s.size / 1024).toFixed(1)} KB)`);
  }

  // 1. Castle Preview (2400x1600 with split oblique + top-down viewports)
  console.log('Rendering Castle Preview (Oblique + Top-Down Views)...');
  await takeScreenshot(`http://127.0.0.1:${port}/castle-preview.html`, castleOutPath, 2400, 1600);

  // 2. Buildings Preview (2400x1200 oblique ~35 deg view)
  console.log('Rendering Buildings Preview (Oblique ~35 deg View)...');
  await takeScreenshot(`http://127.0.0.1:${port}/building-preview.html`, buildingsOutPath, 2400, 1200);

  server.close();
  console.log('Preview server closed.');
}
