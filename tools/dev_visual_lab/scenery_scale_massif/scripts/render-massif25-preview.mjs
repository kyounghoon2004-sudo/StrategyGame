import http from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';

const __dirname = dirname(fileURLToPath(import.meta.url));
const STUDIO_DIR = resolve(__dirname, '..');
const MASSIF_DIR = 'C:/Users/User/Documents/Codex/2026-10-18/strategygame-godot-4-2-2-repo/outputs/scenery-scale-massif/massif25';
const EXPORTS_DIR = join(MASSIF_DIR, 'exports');
const THREE_DIR = join(STUDIO_DIR, 'node_modules/three');

const PORT = 5198;

const server = http.createServer(async (req, res) => {
  const url = req.url.split('?')[0];

  try {
    if (url === '/' || url === '/preview.html' || url === '/preview-25.html') {
      const data = await readFile(join(STUDIO_DIR, 'preview-25.html'));
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(data);
    } else if (url === '/closeups.html' || url === '/preview-closeups.html') {
      const data = await readFile(join(STUDIO_DIR, 'preview-closeups.html'));
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(data);
    } else if (url === '/hillshade.html' || url === '/preview-hillshade.html') {
      const data = await readFile(join(STUDIO_DIR, 'preview-hillshade.html'));
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(data);
    } else if (url.startsWith('/three/')) {
      const rel = url.replace('/three/', '');
      const p = join(THREE_DIR, rel);
      const data = await readFile(p);
      res.writeHead(200, { 'Content-Type': 'application/javascript' });
      res.end(data);
    } else if (url.startsWith('/exports/')) {
      const filename = url.replace('/exports/', '');
      const p = join(EXPORTS_DIR, filename);
      const data = await readFile(p);
      res.writeHead(200, { 'Content-Type': 'model/gltf-binary' });
      res.end(data);
    } else {
      res.writeHead(404);
      res.end('Not found: ' + url);
    }
  } catch (err) {
    res.writeHead(500);
    res.end('Server error: ' + err.message);
  }
});

server.listen(PORT, '127.0.0.1', async () => {
  console.log(`Preview server listening on http://127.0.0.1:${PORT}`);
  const chromePath = 'C:/Program Files/Google/Chrome/Application/chrome.exe';
  const previewPngPath = join(MASSIF_DIR, 'preview-25.png');
  const closeupsPngPath = join(MASSIF_DIR, 'preview-closeups.png');
  const hillshadePngPath = join(MASSIF_DIR, 'preview-hillshade.png');

  // Render 1: preview-25.png
  console.log('Rendering 25-variant contact sheet to preview-25.png (2600x1900, 40° elevation)...');
  const args1 = [
    '--headless=new',
    '--enable-webgl',
    '--use-gl=angle',
    '--use-angle=d3d11',
    '--virtual-time-budget=15000',
    '--run-all-compositor-stages-before-draw',
    '--window-size=2600,1900',
    `--screenshot=${previewPngPath}`,
    `http://127.0.0.1:${PORT}/preview-25.html`
  ];

  await new Promise((resolve, reject) => {
    const p = spawn(chromePath, args1, { stdio: 'inherit' });
    p.on('close', code => (code === 0 ? resolve() : reject(new Error('Chrome failed with ' + code))));
  });

  const st1 = await stat(previewPngPath);
  console.log(`PASS: preview-25.png rendered (${(st1.size / 1024).toFixed(1)} KB)`);

  // Render 2: preview-closeups.png
  console.log('Rendering 4 closeups to preview-closeups.png (2600x2200, 30° elevation)...');
  const args2 = [
    '--headless=new',
    '--enable-webgl',
    '--use-gl=angle',
    '--use-angle=d3d11',
    '--virtual-time-budget=15000',
    '--run-all-compositor-stages-before-draw',
    '--window-size=2600,2200',
    `--screenshot=${closeupsPngPath}`,
    `http://127.0.0.1:${PORT}/preview-closeups.html`
  ];

  await new Promise((resolve, reject) => {
    const p = spawn(chromePath, args2, { stdio: 'inherit' });
    p.on('close', code => (code === 0 ? resolve() : reject(new Error('Chrome failed with ' + code))));
  });

  const st2 = await stat(closeupsPngPath);
  console.log(`PASS: preview-closeups.png rendered (${(st2.size / 1024).toFixed(1)} KB)`);

  // Render 3: preview-hillshade.png
  console.log('Rendering hillshade to preview-hillshade.png (2600x1800, top-down)...');
  const args3 = [
    '--headless=new',
    '--enable-webgl',
    '--use-gl=angle',
    '--use-angle=d3d11',
    '--virtual-time-budget=15000',
    '--run-all-compositor-stages-before-draw',
    '--window-size=2600,1800',
    `--screenshot=${hillshadePngPath}`,
    `http://127.0.0.1:${PORT}/preview-hillshade.html`
  ];

  await new Promise((resolve, reject) => {
    const p = spawn(chromePath, args3, { stdio: 'inherit' });
    p.on('close', code => (code === 0 ? resolve() : reject(new Error('Chrome failed with ' + code))));
  });

  const st3 = await stat(hillshadePngPath);
  console.log(`PASS: preview-hillshade.png rendered (${(st3.size / 1024).toFixed(1)} KB)`);

  server.close(() => {
    console.log('\nPreview HTTP server closed. All 3 visual sheets rendered cleanly.');
  });
});
