// SPEC 8.4 / 15.3 web benchmark: headless Chromium via Playwright, cache disabled, N runs per mode.
//   node harness/bench_web.mjs --root <static dir> --out <file.json> [--stack s] [--label default] [--runs 5]
//        [--modes ready,startup,drag,render,boundary] [--playwright <dir>] [--cache <brotli cache dir>]
// Playwright location: --playwright, $F2D_PLAYWRIGHT_DIR, or ~/dev/tools/playwright (1.64.1 on the run1 machines).
// Extra launch args: $F2D_PW_ARGS (space separated), appended to the defaults recorded in the output.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import url from 'node:url';
import { createRequire } from 'node:module';
import { startServer } from './runtime/web_common.mjs';

const args = Object.fromEntries(process.argv.slice(2).reduce((a, v, i, all) => {
  if (v.startsWith('--')) a.push([v.slice(2), all[i + 1] && !all[i + 1].startsWith('--') ? all[i + 1] : true]);
  return a;
}, []));
const here = path.dirname(url.fileURLToPath(import.meta.url));
if (!args.root || !args.out) { console.error('usage: bench_web.mjs --root <dir> --out <json> [--stack s] [--label l] [--runs 5] [--modes ...]'); process.exit(2); }

const pwDir = args.playwright || process.env.F2D_PLAYWRIGHT_DIR || path.join(os.homedir(), 'dev', 'tools', 'playwright');
const req = createRequire(path.join(pwDir, 'package.json'));
const pw = req('playwright');
let pwVersion = null;
try { pwVersion = JSON.parse(fs.readFileSync(path.join(pwDir, 'node_modules', 'playwright', 'package.json'), 'utf8')).version; } catch { /* */ }

const runs = Number(args.runs || 5);
const modes = String(args.modes || 'ready,startup,drag,render,boundary').split(',');
const TIMEOUT_S = { ready: 180, startup: 240, drag: 400, render: 900, boundary: 600 };
const LAUNCH_ARGS = [
  '--ignore-gpu-blocklist', '--enable-unsafe-swiftshader',
  '--disable-background-timer-throttling', '--disable-renderer-backgrounding', '--disable-backgrounding-occluded-windows',
  ...(process.env.F2D_PW_ARGS ? process.env.F2D_PW_ARGS.split(/\s+/).filter(Boolean) : []),
];
const VIEWPORT = { width: 1280, height: 800 };
const cacheDir = args.cache || path.join(here, 'runtime', '.work', 'brotli-cache');
const log = (m) => console.error(m);

const srv = await startServer({ root: args.root, cacheDir, log });
const base = `http://127.0.0.1:${srv.port}/`;

const median = (xs) => { xs = xs.filter((x) => typeof x === 'number' && Number.isFinite(x)).sort((a, b) => a - b); if (!xs.length) return null; const m = xs.length >> 1; return xs.length % 2 ? xs[m] : (xs[m - 1] + xs[m]) / 2; };
const medianFields = (objs) => { const keys = new Set(); objs.forEach((o) => Object.entries(o).forEach(([k, v]) => typeof v === 'number' && keys.add(k))); return Object.fromEntries([...keys].map((k) => [k, median(objs.map((o) => o[k]))])); };

async function probeEnv() {
  const browser = await pw.chromium.launch({ headless: true, args: LAUNCH_ARGS });
  const info = { browser_version: browser.version(), playwright_version: pwVersion, launch_args: LAUNCH_ARGS, headless: true, viewport: VIEWPORT, node: process.version, platform: `${process.platform}/${process.arch}` };
  const ctx = await browser.newContext({ viewport: VIEWPORT });
  const page = await ctx.newPage();
  try {
    await page.goto(base + '__probe_blank__').catch(() => {});
    info.gl = await page.evaluate(async () => {
      const out = {};
      for (const kind of ['webgl2', 'webgl']) {
        const c = document.createElement('canvas');
        const gl = c.getContext(kind);
        out[kind] = !!gl;
        if (gl) {
          const ext = gl.getExtension('WEBGL_debug_renderer_info');
          out[kind + '_renderer'] = ext ? gl.getParameter(ext.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER);
          out[kind + '_vendor'] = ext ? gl.getParameter(ext.UNMASKED_VENDOR_WEBGL) : gl.getParameter(gl.VENDOR);
        }
      }
      try {
        const a = navigator.gpu && (await navigator.gpu.requestAdapter());
        out.webgpu = !!a;
        if (a) out.webgpu_info = { vendor: a.info?.vendor, architecture: a.info?.architecture, description: a.info?.description, isFallbackAdapter: a.info?.isFallbackAdapter };
      } catch (e) { out.webgpu = 'error: ' + e; }
      out.crossOriginIsolated = self.crossOriginIsolated;
      out.hardwareConcurrency = navigator.hardwareConcurrency;
      out.userAgent = navigator.userAgent;
      return out;
    });
    const r = info.gl?.webgl2_renderer || info.gl?.webgl_renderer || '';
    info.software_rendering_suspected = /swiftshader|software|llvmpipe|softpipe|basic render/i.test(r);
  } catch (e) { info.gl_error = String(e); }
  try {
    const g = await ctx.newPage();
    await g.goto('chrome://gpu', { timeout: 15000 });
    await g.waitForTimeout(2500);
    const txt = await g.evaluate(() => document.body.innerText);
    info.chrome_gpu = txt.split('\n').filter((l) => /GL_RENDERER|GL_VENDOR|Canvas:|Rasterization|WebGL:|WebGL2:|WebGPU:|Compositing|Skia Graphite|Vulkan|ANGLE|Direct3D|Driver|Display type|Video Decode|Problems|Disabled|Software/i.test(l)).map((l) => l.trim()).slice(0, 40);
  } catch (e) { info.chrome_gpu_error = String(e).split('\n')[0]; }
  await browser.close();
  return info;
}

async function oneRun(mode) {
  const browser = await pw.chromium.launch({ headless: true, args: LAUNCH_ARGS });
  const ctx = await browser.newContext({ viewport: VIEWPORT, serviceWorkers: 'block', bypassCSP: false });
  const page = await ctx.newPage();
  const cdp = await ctx.newCDPSession(page);
  await cdp.send('Network.enable');
  await cdp.send('Network.setCacheDisabled', { cacheDisabled: true });
  let wire = 0, nfin = 0;
  cdp.on('Network.loadingFinished', (e) => { wire += e.encodedDataLength || 0; nfin++; });
  const errors = [], consoleHead = [];
  let bench = null, t0 = 0, tBench = 0;
  const done = new Promise((resolve) => {
    page.on('console', (m) => {
      const t = m.text();
      if (consoleHead.length < 8 && !t.includes('BENCH {')) consoleHead.push(t.slice(0, 200));
      const i = t.indexOf('BENCH {');
      if (i >= 0) {
        try { const b = JSON.parse(t.slice(i + 6)); if (b.mode === mode || b.error) { bench = b; tBench = performance.now(); resolve(); } } catch { /* */ }
      }
    });
    page.on('pageerror', (e) => { if (errors.length < 5) errors.push(String(e).slice(0, 300)); });
  });
  srv.reset();
  t0 = performance.now();
  let timedOut = false;
  try {
    await page.goto(`${base}?bench=${mode}`, { waitUntil: 'commit', timeout: 60000 });
    const to = new Promise((r) => setTimeout(() => { timedOut = true; r(); }, (TIMEOUT_S[mode] || 600) * 1000));
    await Promise.race([done, to]);
    await page.waitForTimeout(600); // let trailing requests land
  } catch (e) { errors.push(String(e).split('\n')[0]); }
  const snap = srv.snapshot();
  const rec = { bench, nav_to_bench_wall_ms: bench ? Math.round(tBench - t0) : null, timed_out: timedOut, page_errors: errors, console_head: consoleHead,
    transfer: { transferred_body_bytes: snap.transferred_body_bytes, uncompressed_bytes: snap.uncompressed_bytes, wire_bytes_cdp: wire, requests: snap.requests, not_found: snap.not_found, files: snap.files } };
  await browser.close();
  return rec;
}

const result = {
  stack: args.stack || null, label: args.label || 'default', root: args.root, runs, modes, date: new Date().toISOString(),
  server: { kind: 'node static_server (harness/runtime/web_common.mjs)', brotli: srv.manifest.brotli, headers: { ...{ 'Content-Encoding': 'br (precompressed)' }, ...{ 'Cross-Origin-Opener-Policy': 'same-origin', 'Cross-Origin-Embedder-Policy': 'require-corp' } }, cache: 'Cache-Control: no-store + CDP Network.setCacheDisabled + fresh browser per run + service workers blocked' },
  manifest: { total_raw: srv.manifest.total_raw, total_br: srv.manifest.total_br, files: srv.manifest.files },
  env: await probeEnv(), modes_out: {},
};
for (const mode of modes) {
  const rs = [];
  for (let i = 0; i < runs; i++) {
    const r = await oneRun(mode);
    rs.push(r);
    console.error(`[${args.stack || ''}/${result.label}] web ${mode} run ${i + 1}/${runs}: ${r.bench ? JSON.stringify(r.bench).slice(0, 220) : 'NO BENCH LINE' + (r.timed_out ? ' (timeout)' : '') + ' ' + r.page_errors.join(' | ').slice(0, 200)} | body ${r.transfer.transferred_body_bytes} B br / ${r.transfer.uncompressed_bytes} B raw`);
  }
  const ok = rs.filter((r) => r.bench && !r.bench.error).map((r) => r.bench);
  result.modes_out[mode] = {
    ok_runs: ok.length, median: medianFields(ok), mechanism: ok.find((b) => b.mechanism)?.mechanism || null,
    transferred_body_bytes_median: median(rs.map((r) => r.transfer.transferred_body_bytes)),
    uncompressed_bytes_median: median(rs.map((r) => r.transfer.uncompressed_bytes)),
    wire_bytes_cdp_median: median(rs.map((r) => r.transfer.wire_bytes_cdp)),
    nav_to_bench_wall_ms_median: median(rs.map((r) => r.nav_to_bench_wall_ms)),
    runs: rs,
  };
}
// headline fields (SPEC 8.4)
const g = (m, k) => result.modes_out[m]?.median?.[k] ?? null;
result.summary = {
  transferred_br_bytes: result.modes_out.ready?.transferred_body_bytes_median ?? result.modes_out[modes[0]]?.transferred_body_bytes_median ?? null,
  uncompressed_bytes: result.modes_out.ready?.uncompressed_bytes_median ?? result.modes_out[modes[0]]?.uncompressed_bytes_median ?? null,
  tti_ms: g('ready', 'tti_ms'), startup_first_frame_ms: g('startup', 'first_frame_ms'),
  drag: { p50: g('drag', 'p50'), p95: g('drag', 'p95'), p99: g('drag', 'p99'), max: g('drag', 'max'), lag_max: g('drag', 'lag_max') },
  render: { p50: g('render', 'p50'), p95: g('render', 'p95'), p99: g('render', 'p99'), max: g('render', 'max') },
  solve_p50_ms: g('drag', 'solve_p50'),
  boundary: { noop_ns: g('boundary', 'noop_ns'), transfer_us: g('boundary', 'transfer_us'), mechanism: result.modes_out.boundary?.mechanism ?? null },
  directory_total_br_bytes: srv.manifest.total_br, directory_total_raw_bytes: srv.manifest.total_raw,
};
fs.mkdirSync(path.dirname(path.resolve(args.out)), { recursive: true });
fs.writeFileSync(args.out, JSON.stringify(result, null, 2) + '\n');
await srv.close();
process.exit(0);
