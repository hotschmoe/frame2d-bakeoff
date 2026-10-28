//! Bench modes (SPEC 5.5): drag, render, startup, ready, boundary. The per-frame work runs as an
//! ordinary Msg (`bench_tick`, from the animation-frame subscription); frame timing is recorded by
//! the platform loop in a `Recorder`, outside the Model.
const std = @import("std");
const state = @import("state.zig");
const engine = @import("engine.zig");

pub const Mode = enum { drag, render, startup, ready, boundary };
pub const frames = 600;

pub const State = struct {
    mode: Mode,
    frame: u32 = 0,
    solve_ms: [frames]f64 = undefined,
    node: u32 = 0,
    center: [2]f64 = .{ 0, 0 },
    base_zoom: f64 = 1,
    x_lo: f64 = 0,
    x_hi: f64 = 0,

    pub fn create(mode: Mode) *State {
        const s = std.heap.page_allocator.create(State) catch @panic("oom");
        s.* = .{ .mode = mode };
        return s;
    }

    pub fn running(s: *const State) bool {
        return (s.mode == .drag or s.mode == .render) and s.frame < frames;
    }
};

pub fn setup(m: *state.Model) void {
    const s = m.bench.?;
    switch (s.mode) {
        .drag => {
            m.generate(50, 50);
            const id: i64 = 50 * 51 + 25 + 1;
            for (m.m.nodes, 0..) |n, k| if (n.id == id) {
                s.node = @intCast(k);
            };
            s.center = .{ m.m.nodes[s.node].x, m.m.nodes[s.node].y };
        },
        .render => {
            m.show_moment = true;
            m.show_deflected = false;
            m.generate(200, 200);
            s.base_zoom = m.zoom;
            s.x_lo = 0;
            s.x_hi = 200 * 6.0;
        },
        .startup => m.generate(50, 50),
        .ready, .boundary => m.generate(10, 10),
    }
}

pub fn tick(m: *state.Model, dt: u32) void {
    _ = dt;
    const s = m.bench orelse return;
    if (!s.running()) return;
    const k = s.frame;
    const t = @as(f64, @floatFromInt(k)) / @as(f64, frames);
    switch (s.mode) {
        .drag => {
            const th = 2 * std.math.pi * t;
            m.m.nodes[s.node].x = s.center[0] + 0.5 * @cos(th);
            m.m.nodes[s.node].y = s.center[1] + 0.5 * @sin(th);
            m.solveNow(0); // case D
            s.solve_ms[k] = m.last_solve_ms;
        },
        .render => {
            const u = @as(f64, @floatFromInt(k)) / @as(f64, frames - 1);
            m.zoom = s.base_zoom * (1 + 7 * @sin(std.math.pi * u));
            m.cx = s.x_lo + (s.x_hi - s.x_lo) * u;
            s.solve_ms[k] = 0;
        },
        else => {},
    }
    s.frame += 1;
}

/// Frame-start timestamps of the bench frames, kept by the platform loop.
pub const Recorder = struct {
    starts: [frames + 1]f64 = undefined,
    n: usize = 0,

    pub fn mark(r: *Recorder, t: f64) void {
        if (r.n < r.starts.len) {
            r.starts[r.n] = t;
            r.n += 1;
        }
    }
};

fn pct(sorted: []const f64, p: f64) f64 {
    if (sorted.len == 0) return 0;
    const idx = @min(sorted.len - 1, @as(usize, @intFromFloat(@ceil(p / 100 * @as(f64, @floatFromInt(sorted.len))))) -| 1);
    return sorted[idx];
}

/// Formats the BENCH line for drag / render. `ft` = frame_ms per frame (scratch, sorted in place).
pub fn line(buf: []u8, s: *State, ft: []f64, rss_mb: f64) []const u8 {
    std.mem.sort(f64, ft, {}, std.sort.asc(f64));
    var sm = s.solve_ms;
    std.mem.sort(f64, sm[0..], {}, std.sort.asc(f64));
    const mode = if (s.mode == .drag) "drag" else "render";
    return std.fmt.bufPrint(buf, "BENCH {{\"mode\":\"{s}\",\"p50\":{d:.3},\"p95\":{d:.3},\"p99\":{d:.3},\"max\":{d:.3},\"solve_p50\":{d:.3},\"lag_max\":0,\"rss_mb\":{d:.1},\"frames\":{d}}}", .{
        mode, pct(ft, 50), pct(ft, 95), pct(ft, 99), ft[ft.len - 1], pct(&sm, 50), rss_mb, ft.len,
    }) catch "BENCH {\"error\":\"format\"}";
}
