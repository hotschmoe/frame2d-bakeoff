// Loads the Go js/wasm engine (engine.wasm) and exposes a promise `f2dReady` that resolves once the
// global `f2dEngine` API is registered. Kicked off before Flutter boots so both download in parallel.
(function () {
  const go = new Go();
  window.f2dReady = (async () => {
    let result;
    if (WebAssembly.instantiateStreaming) {
      try {
        result = await WebAssembly.instantiateStreaming(fetch('engine.wasm'), go.importObject);
      } catch (e) {
        result = await WebAssembly.instantiate(await (await fetch('engine.wasm')).arrayBuffer(), go.importObject);
      }
    } else {
      result = await WebAssembly.instantiate(await (await fetch('engine.wasm')).arrayBuffer(), go.importObject);
    }
    go.run(result.instance);  // never returns (Go main blocks); f2dEngine is registered synchronously
    return true;
  })();
})();
