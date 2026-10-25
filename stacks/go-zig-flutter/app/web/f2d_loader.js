// Loads the Zig engine (engine.wasm, wasm32-freestanding, no Emscripten) and exposes a promise `f2dReady` that
// resolves once the global `f2dEngine` API is registered. Kicked off before Flutter boots so both download in
// parallel. The API mirrors the C ABI of the desktop library (zig/include/frame2d_engine.h); float buffers are
// copied out of wasm memory into fresh Float64Arrays (memory may grow, which would detach a view).
(function () {
  let x; // wasm exports
  const enc = new TextEncoder();
  const dec = new TextDecoder();
  const mem = () => x.memory.buffer;
  const f64 = (ptr, n) => new Float64Array(mem(), ptr, n).slice();
  const i32 = (ptr, n) => new Int32Array(mem(), ptr, n);

  // 16 bytes of scratch for out-parameters
  let scratch = 0;
  const counts = (h) => {
    x.f2d_counts(h, scratch);
    return Array.from(i32(scratch, 3));
  };
  const cstr = (ptr) => {
    const u8 = new Uint8Array(mem());
    let end = ptr;
    while (u8[end] !== 0) end++;
    return dec.decode(u8.subarray(ptr, end));
  };

  const api = {
    noop: () => x.f2d_noop(),
    echo: (n) => f64(x.f2d_echo(n), n),
    loadJson: (json) => {
      const bytes = enc.encode(json);
      const p = x.f2d_alloc(bytes.length);
      if (!p) return x.f2d_load_json(0, bytes.length); // out of memory: the engine records the error for lastError()
      new Uint8Array(mem(), p, bytes.length).set(bytes);
      const h = x.f2d_load_json(p, bytes.length);
      x.f2d_dealloc(p, bytes.length);
      return h;
    },
    gen: (b, s) => x.f2d_gen(b, s),
    free: (h) => x.f2d_free(h),
    lastError: () => cstr(x.f2d_last_error()),
    counts: (h) => Float64Array.from(counts(h)),
    geometry: (h) => { const c = counts(h); return f64(x.f2d_geometry(h), c[0] * 4 + c[1] * 3); },
    result: (h) => { const c = counts(h); return f64(x.f2d_result(h), c[0] * 3 + c[1] * 18); },
    stats: (h) => f64(x.f2d_stats(h), 7),
    caseIds: (h) => {
      let cap = 1024;
      for (;;) {
        const p = x.f2d_alloc(cap);
        if (!p) return '[]';
        const n = x.f2d_case_ids(h, p, cap);
        const s = n > 0 && n < cap ? dec.decode(new Uint8Array(mem(), p, n)) : '[]';
        x.f2d_dealloc(p, cap);
        if (n < cap) return s;
        cap = n + 1; // too small: the engine reported the needed length
      }
    },
    setNode: (h, i, px, py) => x.f2d_set_node(h, i, px, py),
    solve: (h, c) => x.f2d_solve(h, c),
    toJson: (h) => {
      const p = x.f2d_to_json(h, scratch);
      return p ? dec.decode(new Uint8Array(mem(), p, i32(scratch, 1)[0])) : '';
    },
  };

  window.f2dReady = (async () => {
    const imports = { env: { f2d_now_ms: () => performance.now() } };
    let result;
    try {
      result = await WebAssembly.instantiateStreaming(fetch('engine.wasm'), imports);
    } catch (e) {
      result = await WebAssembly.instantiate(await (await fetch('engine.wasm')).arrayBuffer(), imports);
    }
    x = result.instance.exports;
    scratch = x.f2d_alloc(16);
    window.f2dEngine = api;
    return true;
  })();
})();
