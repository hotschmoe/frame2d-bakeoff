//! Web entry point (wasm32-freestanding, zunk + WebGPU). zunk owns the rAF loop and calls the
//! exported init / resize / frame; each tick runs one `teak.Runtime.frame`. Bench timing and the
//! boundary exports (f2d_noop / f2d_echo, called from js/bridge.js) live here.
const std = @import("std");
const teak = @import("teak");
const platform = @import("teak-platform-wasm");
const gpu_web = @import("teak-gpu-web");
const app = @import("frame2d_app");
const App = app;
const state = app.state_mod;
const bench = app.bench;

pub const std_options: std.Options = .{ .logFn = platform.logFn };

const Host = platform.Host;
const Gpu = gpu_web.Gpu;
const Runtime = teak.Runtime(App, Host, Gpu);

extern "env" fn zunk_app_performance_now() f64;
/// js/bridge.js: index of ?bench=<mode> in bench.Mode + 1, or 0.
extern "env" fn f2d_bench_mode() u32;

fn clockMs() f64 {
    return zunk_app_performance_now();
}

var host: Host = undefined;
var gpu: Gpu = undefined;
var runtime: Runtime = undefined;
var mode: ?bench.Mode = null;
var rec: bench.Recorder = .{};
var reported = false;
var line_buf: [512]u8 = undefined;

export fn init() void {
    state.clock = clockMs;
    const bm = f2d_bench_mode();
    if (bm > 0 and bm <= @typeInfo(bench.Mode).@"enum".field_names.len) mode = @fromBackingInt(@as(u3, @intCast(bm - 1)));
    state.boot_bench = if (mode == .boundary) null else mode;
    host = Host.init("Frame2D", 1280, 800) catch @panic("host init failed");
    host.activate();
    gpu = Gpu.init(host.nativeHandle(), 1280, 800) catch @panic("gpu init failed");
    runtime = Runtime.init(std.heap.wasm_allocator, &host, &gpu, .{}) catch @panic("runtime init failed");
}

export fn resize(w: u32, h: u32) void {
    gpu.resize(w, h);
}

export fn frame(_: f32) void {
    const t0 = clockMs();
    const before: u32 = if (runtime.model.bench) |b| b.frame else 0;
    runtime.frame() catch @panic("teak: frame failed (out of memory)");
    if (reported) return;
    const md = mode orelse return;
    switch (md) {
        .startup => report(std.fmt.bufPrint(&line_buf, "BENCH {{\"mode\":\"startup\",\"first_frame_ms\":{d:.3}}}", .{clockMs()})),
        .ready => report(std.fmt.bufPrint(&line_buf, "BENCH {{\"mode\":\"ready\",\"tti_ms\":{d:.3}}}", .{clockMs()})),
        .drag, .render => {
            const b = runtime.model.bench.?;
            if (b.frame > before) rec.mark(t0);
            if (!b.running()) {
                rec.mark(clockMs());
                var ft: [bench.frames]f64 = undefined;
                const nf = rec.n - 1;
                for (0..nf) |k| ft[k] = rec.starts[k + 1] - rec.starts[k];
                report(bench.line(&line_buf, b, ft[0..nf], wasmHeapMb()));
            }
        },
        .boundary => reported = true, // measured from JS (js/bridge.js)
    }
}

fn report(line: anyerror![]const u8) void {
    reported = true;
    std.log.info("{s}", .{line catch "BENCH {\"error\":\"format\"}"});
}

fn wasmHeapMb() f64 {
    return @as(f64, @floatFromInt(@wasmMemorySize(0) * 65536)) / (1024 * 1024);
}

// ── boundary exports (SPEC 5.5): JS -> wasm call cost and a zero-copy f64 view ──
var echo_buf: []f64 = &.{};

export fn f2d_noop() void {}

/// Fills n f64 values and returns a pointer into wasm memory; JS reads them through a
/// Float64Array view (zero copy).
export fn f2d_echo(n: u32) [*]f64 {
    if (echo_buf.len < n) echo_buf = std.heap.wasm_allocator.alloc(f64, n) catch @panic("oom");
    for (echo_buf[0..n], 0..) |*x, k| x.* = @floatFromInt(k);
    return echo_buf.ptr;
}
