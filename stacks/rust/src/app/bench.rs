//! Bench modes (SPEC 5.5): drag, render, startup, ready, boundary. Desktop prints `BENCH {...}` to
//! stdout and exits; web prints to console.log and stays idle.

use super::{Frame2dApp, canvas};
use eframe::egui::{Context, ViewportCommand};
use std::f64::consts::PI;

const FRAMES: usize = 600;

#[derive(Clone, Copy, PartialEq)]
pub enum Mode {
    Drag,
    Render,
    Startup,
    Ready,
}

pub struct Bench {
    mode: Mode,
    frame: usize,
    prev_start: Option<f64>,
    frame_ms: Vec<f64>,
    solve_ms: Vec<f64>,
    lag: Vec<u32>,
    node: usize,
    base: [f64; 2],
    initial_solve_ms: f64,
    done: bool,
}

// ---------------------------------------------------------------------------------------------
// Platform helpers
// ---------------------------------------------------------------------------------------------

#[cfg(not(target_arch = "wasm32"))]
static START: std::sync::OnceLock<web_time::Instant> = std::sync::OnceLock::new();

/// Call first thing in `main` (desktop); `startup` is measured from here.
pub fn mark_process_start() {
    #[cfg(not(target_arch = "wasm32"))]
    START.get_or_init(web_time::Instant::now);
}

/// Milliseconds since process start (desktop) or navigation start (web).
fn clock_ms() -> f64 {
    #[cfg(not(target_arch = "wasm32"))]
    {
        START.get_or_init(web_time::Instant::now).elapsed().as_secs_f64() * 1000.0
    }
    #[cfg(target_arch = "wasm32")]
    {
        web_sys::window().and_then(|w| w.performance()).map_or(0.0, |p| p.now())
    }
}

fn emit(line: String) {
    #[cfg(not(target_arch = "wasm32"))]
    println!("{line}");
    #[cfg(target_arch = "wasm32")]
    web_sys::console::log_1(&line.into());
}

/// Resident memory in MiB: peak working set on Windows, VmHWM on Linux, linear memory size on web.
fn rss_mb() -> f64 {
    #[cfg(target_os = "windows")]
    {
        #[repr(C)]
        struct Pmc {
            cb: u32,
            page_faults: u32,
            peak_working_set: usize,
            working_set: usize,
            rest: [usize; 6],
        }
        unsafe extern "system" {
            fn GetCurrentProcess() -> isize;
            fn K32GetProcessMemoryInfo(h: isize, p: *mut Pmc, cb: u32) -> i32;
        }
        let mut p = Pmc { cb: std::mem::size_of::<Pmc>() as u32, page_faults: 0, peak_working_set: 0, working_set: 0, rest: [0; 6] };
        // SAFETY: `p` is a correctly sized, writable PROCESS_MEMORY_COUNTERS for the current process.
        let ok = unsafe { K32GetProcessMemoryInfo(GetCurrentProcess(), &mut p, p.cb) };
        if ok != 0 { p.peak_working_set as f64 / 1048576.0 } else { 0.0 }
    }
    #[cfg(target_os = "linux")]
    {
        std::fs::read_to_string("/proc/self/status")
            .ok()
            .and_then(|s| s.lines().find(|l| l.starts_with("VmHWM:")).map(str::to_owned))
            .and_then(|l| l.split_whitespace().nth(1).and_then(|v| v.parse::<f64>().ok()))
            .map_or(0.0, |kb| kb / 1024.0)
    }
    #[cfg(target_arch = "wasm32")]
    {
        (core::arch::wasm32::memory_size(0) * 65536) as f64 / 1048576.0
    }
    #[cfg(not(any(target_os = "windows", target_os = "linux", target_arch = "wasm32")))]
    {
        0.0
    }
}

fn percentile(sorted: &[f64], p: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    let rank = ((p / 100.0) * sorted.len() as f64).ceil() as usize;
    sorted[rank.clamp(1, sorted.len()) - 1]
}

fn sorted(v: &[f64]) -> Vec<f64> {
    let mut s = v.to_vec();
    s.sort_by(|a, b| a.total_cmp(b));
    s
}

// ---------------------------------------------------------------------------------------------
// Setup and per-frame hooks
// ---------------------------------------------------------------------------------------------

pub fn setup(app: &mut Frame2dApp, mode: Option<String>) {
    let mode = match mode.as_deref() {
        Some("drag") => Mode::Drag,
        Some("render") => Mode::Render,
        Some("startup") => Mode::Startup,
        Some("ready") => Mode::Ready,
        _ => return,
    };
    let (bays, stories) = match mode {
        Mode::Render => (200, 200),
        Mode::Drag | Mode::Startup => (50, 50),
        Mode::Ready => (10, 10),
    };
    app.case_id = "D".into();
    app.generate(bays, stories);
    let initial_solve_ms = app.last_solve_ms;
    app.overlays.moment = mode == Mode::Render;

    // Roof, middle node: id S*(B+1) + B/2 + 1.
    let id = (stories * (bays + 1) + bays / 2 + 1) as i64;
    let node = app.scene.node_ids.binary_search(&id).unwrap_or(0);
    app.selected_node = Some(node);
    app.bench = Some(Bench {
        mode,
        frame: 0,
        prev_start: None,
        frame_ms: Vec::new(),
        solve_ms: Vec::new(),
        lag: Vec::new(),
        node,
        base: app.scene.pos[node],
        initial_solve_ms,
        done: false,
    });
}

pub fn before_frame(app: &mut Frame2dApp, ctx: &Context) {
    let Some(mut b) = app.bench.take() else { return };
    if !b.done {
        let now = clock_ms();
        if let Some(prev) = b.prev_start.replace(now) {
            b.frame_ms.push(now - prev);
        }
        match b.mode {
            Mode::Drag | Mode::Render if b.frame >= FRAMES => finish(&mut b, ctx),
            Mode::Drag => {
                let th = 2.0 * PI * b.frame as f64 / FRAMES as f64;
                let w = [b.base[0] + 0.5 * th.cos(), b.base[1] + 0.5 * th.sin()];
                let t0 = clock_ms();
                canvas::move_node(app, b.node, w);
                b.solve_ms.push(clock_ms() - t0);
                b.lag.push(0);
            }
            Mode::Render => {
                let t = b.frame as f64 / FRAMES as f64;
                let z = 1.0 + 7.0 * (PI * t).sin();
                app.view.zoom = app.fit_zoom * z as f32;
                app.view.center = [app.scene.min[0] + t * (app.scene.max[0] - app.scene.min[0]), (app.scene.min[1] + app.scene.max[1]) / 2.0];
                app.fit_pending = false;
            }
            Mode::Startup if b.frame == 1 => {
                emit(format!("BENCH {{\"mode\":\"startup\",\"first_frame_ms\":{:.3}}}", now));
                b.done = true;
                close(ctx);
            }
            _ => {}
        }
    }
    app.bench = Some(b);
}

pub fn after_frame(app: &mut Frame2dApp, ctx: &Context) {
    let Some(b) = app.bench.as_mut() else { return };
    if b.done {
        return;
    }
    if b.mode == Mode::Ready && b.frame == 0 {
        emit(format!("BENCH {{\"mode\":\"ready\",\"tti_ms\":{:.3}}}", clock_ms()));
        b.done = true;
        return;
    }
    b.frame += 1;
    ctx.request_repaint();
}

fn finish(b: &mut Bench, ctx: &Context) {
    let f = sorted(&b.frame_ms);
    let solve_p50 = match b.mode {
        Mode::Drag => percentile(&sorted(&b.solve_ms), 50.0),
        _ => b.initial_solve_ms,
    };
    let name = if b.mode == Mode::Drag { "drag" } else { "render" };
    emit(format!(
        "BENCH {{\"mode\":\"{name}\",\"p50\":{:.3},\"p95\":{:.3},\"p99\":{:.3},\"max\":{:.3},\"solve_p50\":{:.3},\"lag_max\":{},\"rss_mb\":{:.1}}}",
        percentile(&f, 50.0),
        percentile(&f, 95.0),
        percentile(&f, 99.0),
        f.last().copied().unwrap_or(0.0),
        solve_p50,
        b.lag.iter().copied().max().unwrap_or(0),
        rss_mb()
    ));
    b.done = true;
    close(ctx);
}

fn close(ctx: &Context) {
    #[cfg(not(target_arch = "wasm32"))]
    ctx.send_viewport_cmd(ViewportCommand::Close);
    #[cfg(target_arch = "wasm32")]
    let _ = (ctx, ViewportCommand::Close);
}

// ---------------------------------------------------------------------------------------------
// Boundary mode
// ---------------------------------------------------------------------------------------------

/// Number of f64 values in a 50x50 result transfer (2,601 nodes x 3 + 5,050 members x 6).
const ECHO_N: usize = 38_103;

#[cfg_attr(target_arch = "wasm32", wasm_bindgen::prelude::wasm_bindgen)]
pub fn f2d_noop() {
    std::hint::black_box(());
}

#[cfg_attr(target_arch = "wasm32", wasm_bindgen::prelude::wasm_bindgen)]
pub fn f2d_echo(n: u32) -> Vec<f64> {
    (0..n).map(f64::from).collect()
}

/// Desktop boundary bench: there is no language boundary, so this times direct Rust calls.
/// (On web the JS harness in index.html times the same two functions through wasm-bindgen.)
pub fn boundary_bench() {
    let t = web_time::Instant::now();
    for _ in 0..1_000_000 {
        f2d_noop();
    }
    let noop_ns = t.elapsed().as_secs_f64() * 1e9 / 1e6;
    let t = web_time::Instant::now();
    let mut sink = 0.0;
    for _ in 0..1000 {
        sink += std::hint::black_box(f2d_echo(ECHO_N as u32))[ECHO_N - 1];
    }
    std::hint::black_box(sink);
    let transfer_us = t.elapsed().as_secs_f64() * 1e6 / 1000.0;
    emit(format!(
        "BENCH {{\"mode\":\"boundary\",\"noop_ns\":{noop_ns:.2},\"transfer_us\":{transfer_us:.2},\"mechanism\":\"none (same-language call; result is an owned Vec, no marshalling)\"}}"
    ));
}
