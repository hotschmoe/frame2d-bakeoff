// Frame2D bridge (passed to zunk via linkWebWgpu .bridge_js): bench-mode query, and the boundary bench
// (SPEC 5.5) that calls the wasm exports f2d_noop / f2d_echo from JS.
const F2D_MODES = ['drag', 'render', 'startup', 'ready', 'boundary'];
const f2dMode = new URLSearchParams(location.search).get('bench');
env.f2d_bench_mode = () => F2D_MODES.indexOf(f2dMode) + 1;

addEventListener('ZunkApplicationStarted', () => {
  if (f2dMode !== 'boundary') return;
  setTimeout(() => {
    const e = window.wasmBindings;
    const N = 1000000;
    let t0 = performance.now();
    for (let i = 0; i < N; i++) e.f2d_noop();
    const noopNs = (performance.now() - t0) * 1e6 / N;
    const n = 38103;
    let sink = 0;
    t0 = performance.now();
    for (let i = 0; i < 1000; i++) {
      const p = e.f2d_echo(n);
      const v = new Float64Array(window.wasmMemory.buffer, p, n);
      sink += v[n - 1];
    }
    const transferUs = (performance.now() - t0) * 1e3 / 1000;
    console.log('BENCH ' + JSON.stringify({ mode: 'boundary', noop_ns: noopNs, transfer_us: transferUs, mechanism: 'zero-copy view (Float64Array over wasm memory)', sink }));
  }, 50);
});
