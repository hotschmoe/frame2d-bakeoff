//! Platform glue for the dvui client: clock, memory, process start, BENCH output, file helpers.
//! Desktop (SDL3) and web (wasm32-freestanding) differ only here.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");

pub const is_web = dvui.backend.kind == .web;
const web = if (is_web) @import("web-backend") else struct {};

pub const Mode = enum { none, drag, render, startup, ready, boundary };

/// Bench mode requested on the command line (desktop) or the URL (web, via f2d_set_bench).
pub var bench_mode: Mode = .none;

fn theIo() std.Io {
    if (dvui.App.main_init) |m| return m.io;
    return dvui.io;
}

pub fn download(name: []const u8, data: []const u8) void {
    if (is_web) web.downloadData(name, data) catch {};
}

/// Monotonic milliseconds.
pub fn nowMs() f64 {
    if (is_web) return web.wasm.wasm_now();
    const ns = std.Io.Clock.awake.now(theIo()).nanoseconds;
    return @as(f64, @floatFromInt(ns)) / 1.0e6;
}

pub fn nowNs() u64 {
    return @intFromFloat(nowMs() * 1.0e6);
}

// ---- Windows process info (desktop on Windows only)
const win = struct {
    const FILETIME = extern struct { lo: u32, hi: u32 };
    const Counters = extern struct {
        cb: u32,
        page_faults: u32,
        peak_ws: usize,
        ws: usize,
        q1: usize,
        q2: usize,
        q3: usize,
        q4: usize,
        pagefile: usize,
        peak_pagefile: usize,
    };
    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) *anyopaque;
    extern "kernel32" fn GetProcessTimes(h: *anyopaque, c: *FILETIME, e: *FILETIME, k: *FILETIME, u: *FILETIME) callconv(.winapi) i32;
    extern "kernel32" fn GetSystemTimeAsFileTime(t: *FILETIME) callconv(.winapi) void;
    extern "kernel32" fn K32GetProcessMemoryInfo(h: *anyopaque, c: *Counters, cb: u32) callconv(.winapi) i32;
    fn ticks(t: FILETIME) u64 {
        return (@as(u64, t.hi) << 32) | t.lo;
    }
};

var entry_ms: f64 = 0;
/// Call as early as possible; used as the process start on platforms without a cheaper source.
pub fn markEntry() void {
    entry_ms = nowMs();
}

/// Milliseconds since process start (desktop) or navigation start (web).
pub fn sinceStartMs() f64 {
    if (is_web) return web.wasm.wasm_now(); // performance.now() counts from navigation start
    if (builtin.os.tag == .windows) {
        var c: win.FILETIME = undefined;
        var e: win.FILETIME = undefined;
        var k: win.FILETIME = undefined;
        var u: win.FILETIME = undefined;
        var n: win.FILETIME = undefined;
        if (win.GetProcessTimes(win.GetCurrentProcess(), &c, &e, &k, &u) != 0) {
            win.GetSystemTimeAsFileTime(&n);
            return @as(f64, @floatFromInt(win.ticks(n) -| win.ticks(c))) / 1.0e4;
        }
    }
    return nowMs() - entry_ms;
}

/// Resident memory in MiB (wasm: linear memory size).
pub fn rssMb() f64 {
    if (is_web) return @as(f64, @floatFromInt(@wasmMemorySize(0))) * 65536.0 / (1024.0 * 1024.0);
    if (builtin.os.tag == .windows) {
        var c: win.Counters = undefined;
        c.cb = @sizeOf(win.Counters);
        if (win.K32GetProcessMemoryInfo(win.GetCurrentProcess(), &c, c.cb) != 0)
            return @as(f64, @floatFromInt(c.ws)) / (1024.0 * 1024.0);
    }
    return 0;
}

var console_buf: [1024]u8 = undefined;

/// Prints one BENCH line: stdout on desktop, console.log on web.
pub fn emitBench(comptime fmt: []const u8, args: anytype) void {
    if (is_web) {
        var console = web.Console.init(&console_buf);
        console.writer.print("BENCH " ++ fmt, args) catch return;
        console.flushAtLevel(null);
        return;
    }
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "BENCH " ++ fmt ++ "\n", args) catch return;
    std.Io.File.stdout().writeStreamingAll(theIo(), s) catch {};
}

/// Parses `--bench=<mode>` from the process arguments (desktop).
pub fn parseArgs() void {
    if (is_web) return;
    const init = dvui.App.main_init orelse return;
    var it = init.minimal.args.iterateAllocator(std.heap.page_allocator) catch return;
    defer it.deinit();
    _ = it.next();
    while (it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--bench=")) {
            bench_mode = std.meta.stringToEnum(Mode, arg["--bench=".len..]) orelse .none;
        }
    }
}

pub fn modeFromIndex(i: i32) Mode {
    return switch (i) {
        1 => .drag,
        2 => .render,
        3 => .startup,
        4 => .ready,
        5 => .boundary,
        else => .none,
    };
}

// ---- files

/// Reads a whole file (desktop only).
pub fn readFile(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(theIo(), path, gpa, .limited(1 << 30));
}

pub fn writeFile(path: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(theIo(), .{ .sub_path = path, .data = data });
}
