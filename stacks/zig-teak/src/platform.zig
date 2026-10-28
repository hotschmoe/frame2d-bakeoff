//! Desktop entry point: Teak native Host (Win32 / X11) + wgpu-native, our own frame loop around
//! `teak.Runtime` so bench modes can time every frame, plus process-level probes (start time, RSS).
const std = @import("std");
const builtin = @import("builtin");
const teak = @import("teak");
const platform = @import("teak-platform-native");
const gpu_native = @import("teak-gpu-native");
const App = @import("ui.zig");
const state = @import("state.zig");
const bench = @import("bench.zig");

const Host = platform.Host;
const Gpu = gpu_native.Gpu;
const Runtime = teak.Runtime(App, Host, Gpu);

var g_io: std.Io = undefined;

fn clockMs() f64 {
    const t = std.Io.Clock.awake.now(g_io);
    return @as(f64, @floatFromInt(t.nanoseconds)) / 1e6;
}

// ── Windows process probes ──
const win = struct {
    const FILETIME = extern struct { lo: u32, hi: u32 };
    const PMC = extern struct {
        cb: u32,
        page_faults: u32,
        peak_ws: usize,
        ws: usize,
        a: usize,
        b: usize,
        c: usize,
        d: usize,
        pagefile: usize,
        peak_pagefile: usize,
    };
    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetProcessTimes(h: ?*anyopaque, c: *FILETIME, e: *FILETIME, k: *FILETIME, u: *FILETIME) callconv(.winapi) i32;
    extern "kernel32" fn GetSystemTimePreciseAsFileTime(t: *FILETIME) callconv(.winapi) void;
    extern "kernel32" fn K32GetProcessMemoryInfo(h: ?*anyopaque, p: *PMC, cb: u32) callconv(.winapi) i32;
    fn ft(t: FILETIME) u64 {
        return (@as(u64, t.hi) << 32) | t.lo;
    }
};

/// Milliseconds since the OS created this process (Windows); since `main` elsewhere.
fn msSinceProcessStart(t_main: f64) f64 {
    if (builtin.os.tag == .windows) {
        var c: win.FILETIME = undefined;
        var e: win.FILETIME = undefined;
        var k: win.FILETIME = undefined;
        var u: win.FILETIME = undefined;
        var n: win.FILETIME = undefined;
        if (win.GetProcessTimes(win.GetCurrentProcess(), &c, &e, &k, &u) != 0) {
            win.GetSystemTimePreciseAsFileTime(&n);
            return @as(f64, @floatFromInt(win.ft(n) -% win.ft(c))) / 10_000.0;
        }
    }
    return clockMs() - t_main;
}

fn rssMb() f64 {
    if (builtin.os.tag == .windows) {
        var p: win.PMC = undefined;
        p.cb = @sizeOf(win.PMC);
        if (win.K32GetProcessMemoryInfo(win.GetCurrentProcess(), &p, @sizeOf(win.PMC)) != 0)
            return @as(f64, @floatFromInt(p.ws)) / (1024 * 1024);
    }
    return 0;
}

fn say(line: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(g_io, line) catch {};
    std.Io.File.stdout().writeStreamingAll(g_io, "\n") catch {};
}

// ── boundary probe (pure Zig: the engine is called in-process, no language boundary) ──
noinline fn f2dNoop() void {
    asm volatile ("" ::: .{ .memory = true });
}
noinline fn f2dEcho(buf: []f64, n: usize) []f64 {
    for (buf[0..n], 0..) |*x, k| x.* = @floatFromInt(k);
    return buf[0..n];
}

fn boundary() void {
    const n_calls = 1_000_000;
    const t0 = clockMs();
    for (0..n_calls) |_| f2dNoop();
    const t1 = clockMs();
    const n = 38_103;
    const buf = std.heap.page_allocator.alloc(f64, n) catch return;
    var sink: f64 = 0;
    const t2 = clockMs();
    for (0..1000) |_| sink += f2dEcho(buf, n)[n - 1];
    const t3 = clockMs();
    var line_buf: [256]u8 = undefined;
    say(std.fmt.bufPrint(&line_buf, "BENCH {{\"mode\":\"boundary\",\"noop_ns\":{d:.3},\"transfer_us\":{d:.3},\"mechanism\":\"none (pure Zig, in-process call; slice returned by reference)\",\"sink\":{d}}}", .{
        (t1 - t0) * 1e6 / n_calls, (t3 - t2) * 1e3 / 1000, sink,
    }) catch return);
}

pub fn main(init: std.process.Init) !void {
    g_io = init.io;
    state.clock = clockMs;
    const t_main = clockMs();

    var mode: ?bench.Mode = null;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args[1..]) |a| {
        if (std.mem.startsWith(u8, a, "--bench=")) mode = std.meta.stringToEnum(bench.Mode, a["--bench=".len..]);
    }
    if (mode == .boundary) {
        boundary();
        return;
    }
    state.boot_bench = mode;

    const gpa = std.heap.smp_allocator;
    var host = try Host.init("Frame2D", 1280, 800);
    defer host.deinit();
    var gpu = try Gpu.init(host.nativeHandle(), 1280, 800);
    defer gpu.deinit();
    var rt = try Runtime.init(gpa, &host, &gpu, .{ .idle_skip = mode == null, .app_name = "frame2d" });
    defer rt.deinit();

    var rec: bench.Recorder = .{};
    var line_buf: [512]u8 = undefined;
    while (!host.shouldClose()) {
        const t0 = clockMs();
        const before: u32 = if (rt.model.bench) |b| b.frame else 0;
        try rt.frame();
        if (mode) |md| switch (md) {
            .startup, .ready => {
                const t = msSinceProcessStart(t_main);
                const line = if (md == .startup)
                    std.fmt.bufPrint(&line_buf, "BENCH {{\"mode\":\"startup\",\"first_frame_ms\":{d:.3}}}", .{t})
                else
                    std.fmt.bufPrint(&line_buf, "BENCH {{\"mode\":\"ready\",\"tti_ms\":{d:.3}}}", .{t});
                say(line catch "BENCH {\"error\":\"format\"}");
                std.process.exit(0);
            },
            .drag, .render => {
                const b = rt.model.bench.?;
                if (b.frame > before) rec.mark(t0);
                if (!b.running()) {
                    rec.mark(clockMs());
                    var ft: [bench.frames]f64 = undefined;
                    const nf = rec.n - 1;
                    for (0..nf) |k| ft[k] = rec.starts[k + 1] - rec.starts[k];
                    say(bench.line(&line_buf, b, ft[0..nf], rssMb()));
                    std.process.exit(0);
                }
            },
            .boundary => {},
        };
        if (rt.quiet and !host.shouldClose()) host.waitEvents(rt.idleTimeoutMs());
    }
}
