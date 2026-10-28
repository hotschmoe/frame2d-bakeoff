//! Client state: the Teak Model, its Msgs and `update` (all mutation lives here).
const std = @import("std");
const teak = @import("teak");
const engine = @import("engine.zig");
const model = engine.model;
const bench = @import("bench.zig");
const table = @import("table.zig");

/// Millisecond clock, set by the platform entry point (native: std.Io; web: performance.now()).
pub var clock: *const fn () f64 = zeroClock;
fn zeroClock() f64 {
    return 0;
}
/// Bench mode requested on the command line / query string, read by `Model.init`.
pub var boot_bench: ?bench.Mode = null;

pub const CANVAS_ID: u32 = 1;
pub const TABLE_ID: u32 = 2;
pub const GRIP_BASE: u32 = 100;
pub const TOOLBAR_H: f32 = 96;
pub const TABLE_W: f32 = 560;

pub const Effects = enum(u32) { open = 1, save = 2, bench_query = 3 };

pub const Msg = union(enum) {
    window: [2]f32,
    canvas: teak.CanvasEvent,
    table: table.Table.Msg,
    open_file,
    save_file,
    effect: EffectDone,
    gen_open,
    gen_close,
    gen_bays: i32,
    gen_stories: i32,
    gen_preset: [2]u32,
    gen_run,
    solve,
    toggle_deflected,
    toggle_moment,
    toggle_color,
    defl_scale: f32,
    case: usize,
    fit,
    bench_tick: u32,
};

pub const EffectDone = struct { id: u32, ok: bool, bytes: []const u8 = "" };

pub const Model = struct {
    // model + results (each in its own arena, swapped wholesale)
    model_arena: *std.heap.ArenaAllocator,
    result_arena: *std.heap.ArenaAllocator,
    m: model.Model = .{},
    res: ?engine.Results = null,
    err: ?[]const u8 = null,
    status_len: usize = 0,
    status_buf: [160]u8 = undefined,
    rev: u64 = 1,
    last_solve_ms: f64 = 0,

    // view
    win_w: f32 = 1280,
    win_h: f32 = 800,
    cx: f64 = 0, // world point at the canvas centre
    cy: f64 = 0,
    zoom: f64 = 10, // px per m
    canvas_w: f32 = 700,
    canvas_h: f32 = 600,
    drag_node: ?u32 = null, // index into m.nodes
    panning: bool = false,

    // overlays
    show_deflected: bool = true,
    defl_scale: f32 = 0.3,
    show_moment: bool = false,
    color_by_m: bool = true,
    case: usize = 0,

    // generate dialog
    gen_open: bool = false,
    gen_b: u32 = 10,
    gen_s: u32 = 10,

    // member table
    tbl: *table.Table.Model,

    // effects in flight
    fx: [2]teak.Effect = undefined,
    fx_n: usize = 0,
    next_fx: u32 = 10,
    save_bytes: []const u8 = "",

    bench: ?*bench.State = null,

    pub fn init() Model {
        const pa = std.heap.page_allocator;
        const ma = pa.create(std.heap.ArenaAllocator) catch @panic("oom");
        ma.* = .init(pa);
        const ra = pa.create(std.heap.ArenaAllocator) catch @panic("oom");
        ra.* = .init(pa);
        const t = pa.create(table.Table.Model) catch @panic("oom");
        t.* = .{};
        t.setColumns(&table.columns);
        var m = Model{ .model_arena = ma, .result_arena = ra, .tbl = t };
        if (boot_bench) |mode| {
            m.bench = bench.State.create(mode);
            bench.setup(&m);
        } else {
            m.generate(10, 10);
        }
        return m;
    }

    pub fn generate(self: *Model, b: u32, s: u32) void {
        _ = self.model_arena.reset(.retain_capacity);
        self.m = model.gen(self.model_arena.allocator(), b, s) catch @panic("oom");
        self.solveNow(null);
        self.fit();
    }

    pub fn loadJson(self: *Model, bytes: []const u8) void {
        var fresh = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        const parsed = model.parse(fresh.allocator(), bytes) catch {
            fresh.deinit();
            self.setStatus("open failed: not a valid model JSON", .{});
            return;
        };
        self.model_arena.deinit();
        self.model_arena.* = fresh;
        self.m = parsed;
        self.case = 0;
        self.solveNow(null);
        self.fit();
    }

    pub fn setStatus(self: *Model, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.status_buf, fmt, args) catch self.status_buf[0..0];
        self.status_len = s.len;
    }

    /// Status line text (a slice of the Model's own buffer, so it survives Model copies).
    pub fn status(self: *const Model) []const u8 {
        return self.status_buf[0..self.status_len];
    }

    /// Re-solve the current model. `only_case` limits the work (drag bench: case D).
    pub fn solveNow(self: *Model, only_case: ?usize) void {
        _ = self.result_arena.reset(.retain_capacity);
        const a = self.result_arena.allocator();
        const t0 = clock();
        const o = engine.solve(a, self.m, .{ .clock = clock, .only_case = only_case, .skip_profile_before = true }) catch {
            self.res = null;
            self.err = "out of memory";
            return;
        };
        self.last_solve_ms = clock() - t0;
        self.rev +%= 1;
        switch (o) {
            .ok => |r| {
                self.res = r;
                self.err = null;
                const n = r.member_src.len;
                if (self.tbl.n_rows != n) self.tbl.setRows(n);
                self.setStatus("{d} nodes, {d} members, {d} free DOFs, solve {d:.1} ms", .{ r.stats.nodes, r.stats.members, r.stats.free_dofs, self.last_solve_ms });
            },
            .err => |e| {
                self.res = null;
                self.err = std.fmt.allocPrint(a, "{s}: {s}", .{ e.code, e.detail }) catch e.code;
                if (self.tbl.n_rows != 0) self.tbl.setRows(0);
                self.setStatus("model error", .{});
            },
        }
    }

    /// Index of the load case to show within `res.cases` (a single-case solve has one).
    pub fn caseResult(self: *const Model) ?*const engine.CaseResult {
        const r = self.res orelse return null;
        if (r.cases.len == 0) return null;
        return &r.cases[@min(self.case, r.cases.len - 1)];
    }

    pub fn fit(self: *Model) void {
        if (self.m.nodes.len == 0) return;
        var lo = [2]f64{ std.math.inf(f64), std.math.inf(f64) };
        var hi = [2]f64{ -std.math.inf(f64), -std.math.inf(f64) };
        for (self.m.nodes) |n| {
            lo = .{ @min(lo[0], n.x), @min(lo[1], n.y) };
            hi = .{ @max(hi[0], n.x), @max(hi[1], n.y) };
        }
        self.cx = (lo[0] + hi[0]) / 2;
        self.cy = (lo[1] + hi[1]) / 2;
        const w = @max(hi[0] - lo[0], 1e-3);
        const h = @max(hi[1] - lo[1], 1e-3);
        self.zoom = 0.85 * @min(@as(f64, self.canvas_w) / w, @as(f64, self.canvas_h) / h);
        self.rev +%= 1;
    }

    pub fn toScreen(self: *const Model, x: f64, y: f64) [2]f32 {
        return .{
            @floatCast(@as(f64, self.canvas_w) / 2 + (x - self.cx) * self.zoom),
            @floatCast(@as(f64, self.canvas_h) / 2 - (y - self.cy) * self.zoom),
        };
    }

    pub fn toWorld(self: *const Model, sx: f32, sy: f32) [2]f64 {
        return .{
            self.cx + (@as(f64, sx) - @as(f64, self.canvas_w) / 2) / self.zoom,
            self.cy - (@as(f64, sy) - @as(f64, self.canvas_h) / 2) / self.zoom,
        };
    }

    fn pickNode(self: *const Model, sx: f32, sy: f32) ?u32 {
        var best: ?u32 = null;
        var best_d: f32 = 10 * 10;
        for (self.m.nodes, 0..) |n, k| {
            const p = self.toScreen(n.x, n.y);
            const d = (p[0] - sx) * (p[0] - sx) + (p[1] - sy) * (p[1] - sy);
            if (d < best_d) {
                best_d = d;
                best = @intCast(k);
            }
        }
        return best;
    }

    fn pushEffect(self: *Model, e: teak.Effect) void {
        if (self.fx_n < self.fx.len) {
            self.fx[self.fx_n] = e;
            self.fx_n += 1;
        }
    }

    fn dropEffect(self: *Model, id: u32) void {
        var k: usize = 0;
        while (k < self.fx_n) {
            if (self.fx[k].id() == id) {
                self.fx[k] = self.fx[self.fx_n - 1];
                self.fx_n -= 1;
            } else k += 1;
        }
    }
};

pub fn update(m: *Model, msg: Msg) void {
    m.rev +%= 1;
    switch (msg) {
        .window => |wh| {
            m.win_w = wh[0];
            m.win_h = wh[1];
            m.canvas_w = @max(200, wh[0] - TABLE_W - 24);
            m.canvas_h = @max(200, wh[1] - TOOLBAR_H - 24);
        },
        .canvas => |ev| onCanvas(m, ev),
        .table => |t| table.Table.update(m.tbl, t, table.Rows{ .m = m }),
        .open_file => {
            m.pushEffect(.{ .open_file = .{ .id = m.next_fx, .accept = ".json" } });
            m.next_fx += 1;
        },
        .save_file => {
            var aw: std.Io.Writer.Allocating = .init(m.model_arena.allocator());
            model.write(&aw.writer, m.m) catch return;
            m.save_bytes = aw.written();
            m.pushEffect(.{ .download = .{ .id = m.next_fx, .name = "model.json", .mime = "application/json", .bytes = m.save_bytes, .pick = true } });
            m.next_fx += 1;
        },
        .effect => |d| {
            m.dropEffect(d.id);
            if (d.ok and d.bytes.len > 0) m.loadJson(d.bytes);
        },
        .gen_open => m.gen_open = true,
        .gen_close => m.gen_open = false,
        .gen_bays => |d| m.gen_b = @intCast(std.math.clamp(@as(i32, @intCast(m.gen_b)) + d, 1, 200)),
        .gen_stories => |d| m.gen_s = @intCast(std.math.clamp(@as(i32, @intCast(m.gen_s)) + d, 1, 200)),
        .gen_preset => |bs| {
            m.gen_b = bs[0];
            m.gen_s = bs[1];
        },
        .gen_run => {
            m.gen_open = false;
            m.generate(m.gen_b, m.gen_s);
        },
        .solve => m.solveNow(null),
        .toggle_deflected => m.show_deflected = !m.show_deflected,
        .toggle_moment => m.show_moment = !m.show_moment,
        .toggle_color => m.color_by_m = !m.color_by_m,
        .defl_scale => |v| m.defl_scale = std.math.clamp(v, 0, 1),
        .case => |c| m.case = c,
        .fit => m.fit(),
        .bench_tick => |dt| bench.tick(m, dt),
    }
}

fn onCanvas(m: *Model, ev: teak.CanvasEvent) void {
    switch (ev.kind) {
        .layout => {},
        .down => {
            if (ev.button == .left) {
                m.drag_node = m.pickNode(ev.x, ev.y);
                m.panning = m.drag_node == null;
            } else m.panning = true;
        },
        .move => {
            if (m.drag_node) |k| {
                const w = m.toWorld(ev.x, ev.y);
                m.m.nodes[k].x = w[0];
                m.m.nodes[k].y = w[1];
                m.solveNow(null);
            } else if (m.panning and ev.buttons.any()) {
                m.cx -= ev.dx / m.zoom;
                m.cy += ev.dy / m.zoom;
            }
        },
        .up => {
            m.drag_node = null;
            m.panning = false;
        },
        .wheel => {
            // wheel / trackpad / web pinch (ctrl+wheel): zoom about the cursor
            const before = m.toWorld(ev.x, ev.y);
            const k: f64 = if (ev.mods.ctrl) 0.01 else 0.002;
            m.zoom = std.math.clamp(m.zoom * @exp(-@as(f64, ev.dy) * k), 1e-3, 1e6);
            const after = m.toWorld(ev.x, ev.y);
            m.cx += before[0] - after[0];
            m.cy += before[1] - after[1];
        },
        .leave, .key => {},
    }
}
