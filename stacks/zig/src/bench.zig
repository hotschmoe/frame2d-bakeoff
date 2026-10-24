//! Bench modes (SPEC 5.5): drag, render, startup, ready, boundary. Driven once per frame from the canvas.
const std = @import("std");
const dvui = @import("dvui");
const engine = @import("engine");
const solver = engine.solver;
const platform = @import("platform.zig");
const state = @import("state.zig");
const canvas = @import("canvas.zig");
const App = state.App;

const frames = 600;

var frame_idx: usize = 0;
var last_tick_ms: f64 = 0;
var finished = false;
var frame_ms: [frames + 2]f32 = undefined;
var solve_ms: [frames + 2]f32 = undefined;
var lag: [frames + 2]u16 = undefined;
var n_rec: usize = 0;

var drag_node: usize = 0;
var base_x: f64 = 0;
var base_y: f64 = 0;
var fit_scale: f64 = 1;

pub fn isFinished() bool {
    return finished and !platform.is_web;
}

pub fn active() bool {
    return platform.bench_mode != .none and !finished;
}

fn pct(sorted: []const f32, p: f64) f64 {
    if (sorted.len == 0) return 0;
    const idx: usize = @intFromFloat(@floor(p * @as(f64, @floatFromInt(sorted.len - 1)) + 0.5));
    return sorted[@min(idx, sorted.len - 1)];
}

fn finishFrames(mode: []const u8) void {
    const ft = frame_ms[0..n_rec];
    std.sort.pdq(f32, ft, {}, std.sort.asc(f32));
    const st = solve_ms[0..n_rec];
    std.sort.pdq(f32, st, {}, std.sort.asc(f32));
    var lag_max: u16 = 0;
    for (lag[0..n_rec]) |l| lag_max = @max(lag_max, l);
    platform.emitBench(
        "{{\"mode\":\"{s}\",\"p50\":{d:.3},\"p95\":{d:.3},\"p99\":{d:.3},\"max\":{d:.3},\"solve_p50\":{d:.3},\"lag_max\":{d},\"rss_mb\":{d:.1}}}",
        .{ mode, pct(ft, 0.5), pct(ft, 0.95), pct(ft, 0.99), pct(ft, 1.0), pct(st, 0.5), lag_max, platform.rssMb() },
    );
    finished = true;
}

fn record(ms: f64, solve: f64, lg: u16) void {
    if (n_rec >= frame_ms.len) return;
    frame_ms[n_rec] = @floatCast(ms);
    solve_ms[n_rec] = @floatCast(solve);
    lag[n_rec] = lg;
    n_rec += 1;
}

var noop_sink: u64 = 0;
fn noop() callconv(.c) void {
    noop_sink +%= 1;
}
var echo_buf: [38103]f64 = undefined;

/// Desktop has no language boundary; report the in-process cost for completeness.
fn boundaryDesktop() void {
    var f: *const fn () callconv(.c) void = &noop;
    std.mem.doNotOptimizeAway(&f);
    const t0 = platform.nowMs();
    for (0..1_000_000) |_| f();
    const noop_ns = (platform.nowMs() - t0) * 1.0e6 / 1_000_000.0;
    var dst: [38103]f64 = undefined;
    for (&echo_buf, 0..) |*e, k| e.* = @floatFromInt(k);
    const t1 = platform.nowMs();
    for (0..1000) |_| {
        @memcpy(&dst, &echo_buf);
        std.mem.doNotOptimizeAway(&dst);
    }
    const transfer_us = (platform.nowMs() - t1) * 1000.0 / 1000.0;
    platform.emitBench("{{\"mode\":\"boundary\",\"noop_ns\":{d:.3},\"transfer_us\":{d:.3},\"mechanism\":\"in-process (no boundary)\"}}", .{ noop_ns, transfer_us });
    finished = true;
}

/// Called once per frame before drawing. May mutate the app (model, view, solve).
pub fn tick(app: *App, g: canvas.Geometry) void {
    const mode = platform.bench_mode;
    if (mode == .none or finished) return;
    if (g.r.w < 50 or g.r.h < 50) {
        dvui.refresh(null, @src(), null);
        return; // wait for the first real layout
    }
    const now = platform.nowMs();
    const dt = now - last_tick_ms;
    last_tick_ms = now;
    dvui.refresh(null, @src(), null); // keep frames flowing
    defer frame_idx += 1;

    switch (mode) {
        .none => {},
        .boundary => {
            if (frame_idx == 1 and !platform.is_web) boundaryDesktop();
            if (platform.is_web) finished = true; // measured from JS (see index.html)
        },
        .ready => {
            if (frame_idx == 1) {
                platform.emitBench("{{\"mode\":\"ready\",\"tti_ms\":{d:.1}}}", .{platform.sinceStartMs()});
                finished = true;
            }
        },
        .startup => {
            if (frame_idx == 0) {
                app.generate(50, 50);
                canvas.fitView(app, g);
            } else if (frame_idx == 1) {
                platform.emitBench("{{\"mode\":\"startup\",\"first_frame_ms\":{d:.1}}}", .{platform.sinceStartMs()});
                finished = true;
            }
        },
        .drag => {
            const b: usize = 50;
            const s: usize = 50;
            if (frame_idx == 0) {
                app.generate(b, s);
                canvas.fitView(app, g);
                const id: i64 = @intCast(s * (b + 1) + b / 2 + 1);
                drag_node = solver.findNode(app.model.nodes, id) orelse 0;
                base_x = app.model.nodes[drag_node].x;
                base_y = app.model.nodes[drag_node].y;
                app.selected_node = drag_node;
                app.case = 0;
                return;
            }
            const k = frame_idx - 1;
            const th = 2.0 * std.math.pi * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(frames));
            app.model.nodes[drag_node].x = base_x + 0.5 * @cos(th);
            app.model.nodes[drag_node].y = base_y + 0.5 * @sin(th);
            app.resolve(0);
            if (k > 0) record(dt, app.last_solve_ms, 0);
            if (k + 1 >= frames) finishFrames("drag");
        },
        .render => {
            if (frame_idx == 0) {
                app.generate(200, 200);
                app.show_moment = true;
                app.show_deflected = false;
                canvas.fitView(app, g);
                fit_scale = app.view.scale;
                return;
            }
            const k = frame_idx - 1;
            const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(frames - 1));
            const z = 1.0 + 7.0 * (1.0 - @abs(2.0 * t - 1.0));
            const nodes = app.model.nodes;
            const minx = nodes[0].x;
            const maxx = nodes[nodes.len - 1].x;
            app.view.scale = fit_scale * z;
            app.view.cx = minx + (maxx - minx) * t;
            if (k > 0) record(dt, 0, 0);
            if (k + 1 >= frames) finishFrames("render");
        },
    }
}
