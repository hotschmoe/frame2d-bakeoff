// Web bridge lifetime regression test (run by test_all in stack.sh; plain Node, no browser).
//   node app/test/web/lifetime_test.mjs <engine.wasm>
// Loads the real web/f2d_loader.js against the real engine.wasm and checks that everything the Dart side keeps
// (geometry, results, stats) survives calls that grow wasm memory (toJson = Save, loadJson, gen of a different
// size, solve) and freeing the session. A control case first shows that a raw view on memory.buffer *does* detach,
// so the test would catch a loader that returned views instead of copies.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const here = path.dirname(fileURLToPath(import.meta.url));
const wasmPath = process.argv[2] ?? path.join(here, '../../../build/dev/engine.wasm');
const wasmBytes = readFileSync(wasmPath);
const imports = { env: { f2d_now_ms: () => performance.now() } };

let failures = 0;
async function test(name, fn) {
  try {
    await fn();
    console.log(`ok   ${name}`);
  } catch (e) {
    failures++;
    console.log(`FAIL ${name}\n     ${e?.stack ?? e}`);
  }
}

// ---- control: raw views detach on memory.grow (the sibling-stack bug class)
await test('control: a raw Float64Array view on memory.buffer detaches when toJson grows memory', async () => {
  const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
  const x = instance.exports;
  const h = x.f2d_gen(50, 50);
  assert.ok(h > 0);
  assert.equal(x.f2d_solve(h, 0), 0);
  const view = new Float64Array(x.memory.buffer, x.f2d_result(h), 100);
  const before = x.memory.buffer.byteLength;
  const lenp = x.f2d_alloc(16);
  for (let i = 0; i < 4 && x.memory.buffer.byteLength === before; i++) x.f2d_to_json(h, lenp);
  if (x.memory.buffer.byteLength === before) x.f2d_gen(100, 100); // force a grow if Save alone did not
  assert.ok(x.memory.buffer.byteLength > before, 'memory did not grow; the control cannot show detachment');
  assert.equal(view.length, 0, 'raw view should be detached after memory.grow');
});

// ---- the shipped loader
globalThis.window = globalThis;
globalThis.fetch = async () => ({ arrayBuffer: async () => wasmBytes }); // instantiateStreaming rejects -> fallback path
vm.runInThisContext(readFileSync(path.join(here, '../../web/f2d_loader.js'), 'utf8'));
await window.f2dReady;
const api = window.f2dEngine;

const snap = (a) => Float64Array.from(a);
const same = (a, b, what) => {
  assert.equal(a.length, b.length, `${what}: length changed (${b.length} -> ${a.length})`);
  for (let i = 0; i < a.length; i++) if (!Object.is(a[i], b[i])) assert.fail(`${what}[${i}] changed: ${b[i]} -> ${a[i]}`);
};

await test('held geometry/results/stats survive Save, load, gen of another size, solve and free', async () => {
  const h1 = api.gen(50, 50);
  assert.ok(h1 > 0);
  assert.equal(api.solve(h1, 0), 0);
  const [n, m] = api.counts(h1);
  const geo = api.geometry(h1), res = api.result(h1), st = api.stats(h1);
  assert.equal(geo.length, n * 4 + m * 3);
  assert.equal(res.length, n * 3 + m * 18);
  assert.ok(res.some((v) => v !== 0), 'results are all zero');
  const g0 = snap(geo), r0 = snap(res), s0 = snap(st);

  const json = api.toJson(h1); // Save: grows memory for the serialized model
  assert.ok(json.length > 100000);
  const h2 = api.gen(7, 3); // different size
  assert.equal(api.solve(h2, 0), 0);
  const h3 = api.loadJson(json); // load: grows memory again
  assert.ok(h3 > 0, api.lastError());
  assert.equal(api.solve(h3, 1), 0);
  api.toJson(h3);
  const h4 = api.gen(100, 100); // forces memory.grow
  assert.ok(h4 > 0);
  api.free(h1);
  api.free(h4);

  same(geo, g0, 'geometry');
  same(res, r0, 'result');
  same(st, s0, 'stats');

  // the reloaded model solves to the same case-0 numbers
  assert.equal(api.solve(h3, 0), 0);
  const r3 = api.result(h3);
  assert.equal(r3.length, r0.length);
  for (let i = 0; i < r0.length; i++) assert.ok(Math.abs(r3[i] - r0[i]) <= 1e-9 * (1 + Math.abs(r0[i])), `reload result[${i}]`);
  api.free(h2);
  api.free(h3);
});

await test('loadJson after memory growth reads the right bytes (buffer taken after alloc)', async () => {
  const big = api.toJson((() => { const h = api.gen(60, 60); return h; })());
  const h = api.loadJson(big);
  assert.ok(h > 0, api.lastError());
  assert.equal(api.solve(h, 0), 0);
  api.free(h);
});

await test('a freed handle is dead even after its slot is reused', async () => {
  const h1 = api.gen(2, 2);
  api.free(h1);
  const h2 = api.gen(30, 30); // reuses the freed slot
  assert.notEqual(h2, h1, 'a new session got the handle of a freed one');
  assert.deepEqual(Array.from(api.counts(h1)), [0, 0, 0], 'counts of a freed handle must be zero');
  assert.equal(api.geometry(h1).length, 0);
  assert.equal(api.result(h1).length, 0);
  assert.ok(api.solve(h1, 0) < 0, 'solve on a freed handle must fail');
  assert.equal(api.toJson(h1), '');
  api.free(h1); // double free is a no-op and must not free h2
  assert.equal(api.solve(h2, 0), 0);
  api.free(h2);
});

await test('lastError is copied out (survives later calls)', async () => {
  const h = api.loadJson('{not json');
  assert.ok(h < 0);
  const e = api.lastError();
  assert.ok(e.length > 0);
  api.gen(40, 40);
  api.loadJson('{"nodes":5}');
  assert.ok(e.length > 0 && typeof e === 'string');
});

if (failures) {
  console.log(`${failures} web lifetime test(s) failed`);
  process.exit(1);
}
console.log('web lifetime tests: all passed');
