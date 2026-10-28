// Runs the web bridge regression test (bridge_lifetime_web.dart) under node, once per compiler.
// usage: node run.mjs <engine.wasm> <dart2js out.js> <dart2wasm out.mjs>
// Each run gets a fresh engine instance. Also replays the report's raw repro (webtest/detach.mjs) to show
// that a plain JS view really detaches here, so a PASS means the bridge, not luck, kept the data.
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { pathToFileURL } from 'node:url';

const [enginePath, jsPath, mjsPath] = process.argv.slice(2);
const engineBytes = fs.readFileSync(enginePath);

async function engine() {
  const { instance } = await WebAssembly.instantiate(engineBytes, { env: { f2d_now_ms: () => performance.now() } });
  return instance.exports;
}

let failed = false;
function report(name, verdict) {
  const ok = typeof verdict === 'string' && verdict.startsWith('PASS');
  if (!ok) failed = true;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}: ${verdict}`);
}

// 0. The bug this guards against: a held raw view goes to length 0 when the engine grows memory.
{
  const x = await engine();
  x.f2d_generate(50, 50);
  x.f2d_solve(1);
  const slot = (x.f2d_alloc(24) + 7) & ~7;
  x.f2d_disp(0, slot);
  const [ptr, len] = new Uint32Array(x.memory.buffer, slot, 2);
  const view = new Float64Array(x.memory.buffer, ptr, len);
  const before = view.length;
  x.f2d_export_results(slot);
  report('raw view detaches on growth (control)', before > 0 && view.length === 0
    ? `PASS (length ${before} -> 0)` : `unexpected: length ${before} -> ${view.length}`);
}

// 1. dart2js
if (jsPath) {
  globalThis.f2dExports = await engine();
  globalThis.f2dTestResult = undefined;
  globalThis.self ??= globalThis;
  vm.runInThisContext(fs.readFileSync(jsPath, 'utf8'), { filename: jsPath });
  await new Promise((r) => setTimeout(r, 0));
  report('dart2js', globalThis.f2dTestResult);
}

// 2. dart2wasm
if (mjsPath) {
  globalThis.f2dExports = await engine();
  globalThis.f2dTestResult = undefined;
  const mod = await import(pathToFileURL(path.resolve(mjsPath)).href);
  const wasmPath = mjsPath.replace(/\.mjs$/, '.wasm');
  const compiled = await mod.compile(fs.readFileSync(wasmPath));
  const app = await compiled.instantiate({});
  app.invokeMain();
  await new Promise((r) => setTimeout(r, 0));
  report('dart2wasm', globalThis.f2dTestResult);
}

process.exit(failed ? 1 : 0);
