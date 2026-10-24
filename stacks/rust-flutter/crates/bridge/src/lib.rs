//! Bridge between the Frame2D engine and Flutter.
//!
//! * `api` is the session API (plain Rust, shared by both targets).
//! * Desktop: flutter_rust_bridge generates the FFI glue from `api` into `frb_generated`.
//! * Web: `web` exposes the same functions through wasm-bindgen.

pub mod api;

#[cfg(not(target_arch = "wasm32"))]
mod frb_generated;

#[cfg(target_arch = "wasm32")]
mod web;
