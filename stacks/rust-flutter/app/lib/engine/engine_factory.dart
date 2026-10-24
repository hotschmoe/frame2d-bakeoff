/// Picks the engine implementation for the platform: FFI on desktop, WASM on web.
library;
export 'engine_stub.dart'
    if (dart.library.io) 'engine_native.dart'
    if (dart.library.js_interop) 'engine_web.dart';
