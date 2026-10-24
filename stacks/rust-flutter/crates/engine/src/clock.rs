//! Millisecond clock for the stats timers. `std::time::Instant` is unavailable on wasm32-unknown-unknown,
//! so front ends there install their own clock with `set_clock`.

use std::sync::OnceLock;

static CLOCK: OnceLock<fn() -> f64> = OnceLock::new();

/// Installs the clock (first call wins).
pub fn set_clock(f: fn() -> f64) {
    let _ = CLOCK.set(f);
}

#[cfg(not(target_arch = "wasm32"))]
fn default_clock() -> f64 {
    use std::time::Instant;
    static EPOCH: OnceLock<Instant> = OnceLock::new();
    EPOCH.get_or_init(Instant::now).elapsed().as_secs_f64() * 1000.0
}

#[cfg(target_arch = "wasm32")]
fn default_clock() -> f64 {
    0.0
}

pub fn now_ms() -> f64 {
    match CLOCK.get() {
        Some(f) => f(),
        None => default_clock(),
    }
}
