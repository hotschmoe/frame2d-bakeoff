//! `/sweep` (SPEC 5.4): scale every BM section's I over N variants, solved concurrently on all cores.
const std = @import("std");
const engine = @import("engine.zig");
const model = engine.model;

pub const Variant = struct { scale: f64, roof_drift_W: f64, max_abs_M: f64 };

pub const SweepResult = union(enum) {
    ok: []Variant,
    err: engine.ModelError,
};

const Shared = struct {
    m: model.Model,
    lo: f64,
    hi: f64,
    out: []Variant,
    next: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),
    err: ?engine.ModelError = null,
    err_arena: std.mem.Allocator,
    top_left_src: u32,
    w_case: ?usize,
};

fn worker(sh: *Shared) void {
    const n = sh.out.len;
    while (!sh.failed.load(.monotonic)) {
        const k = sh.next.fetchAdd(1, .monotonic);
        if (k >= n) return;
        runOne(sh, k) catch {
            sh.failed.store(true, .monotonic);
            return;
        };
    }
}

fn runOne(sh: *Shared, k: usize) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = sh.out.len;
    const scale = if (n == 1) sh.lo else sh.lo + (sh.hi - sh.lo) * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n - 1));
    // engine.solve does not mutate the model: only the scaled sections need a private copy
    var mm = sh.m;
    const secs = try a.dupe(model.Section, sh.m.sections);
    for (secs) |*s| if (std.mem.eql(u8, s.id, "BM")) {
        s.I *= scale;
    };
    mm.sections = secs;
    const o = try engine.solve(a, mm, .{ .skip_profile_before = true });
    switch (o) {
        .err => |e| {
            if (!sh.failed.swap(true, .monotonic)) {
                sh.err = .{ .code = e.code, .detail = try sh.err_arena.dupe(u8, e.detail) };
            }
        },
        .ok => |r| {
            var drift: f64 = std.math.nan(f64); // no case "W": written as null
            if (sh.w_case) |wc| {
                for (r.node_src, 0..) |src, pos| if (src == sh.top_left_src) {
                    drift = r.cases[wc].disp[pos][0];
                };
            }
            var mx: f64 = 0;
            for (r.cases) |c| mx = @max(mx, c.max_abs_m);
            sh.out[k] = .{ .scale = scale, .roof_drift_W = drift, .max_abs_M = mx };
        },
    }
}

/// `err_arena` receives error details; `out` is allocated from `gpa`.
pub fn run(gpa: std.mem.Allocator, err_arena: std.mem.Allocator, m: model.Model, variants: usize, lo: f64, hi: f64) !SweepResult {
    const out = try gpa.alloc(Variant, variants);
    if (variants == 0) return .{ .ok = out };
    // top-left node: highest y, then lowest x
    var tl: u32 = 0;
    for (m.nodes, 0..) |nd, k| {
        const best = m.nodes[tl];
        if (nd.y > best.y or (nd.y == best.y and (nd.x < best.x or (nd.x == best.x and nd.id < best.id)))) tl = @intCast(k);
    }
    var w_case: ?usize = null;
    for (m.load_cases, 0..) |lc, k| if (std.mem.eql(u8, lc.id, "W")) {
        w_case = k;
    };
    var sh = Shared{ .m = m, .lo = lo, .hi = hi, .out = out, .err_arena = err_arena, .top_left_src = tl, .w_case = w_case };
    const cores = std.Thread.getCpuCount() catch 4;
    const nt = @min(cores, variants);
    const threads = try gpa.alloc(std.Thread, nt);
    defer gpa.free(threads);
    var spawned: usize = 0;
    for (threads) |*t| {
        t.* = std.Thread.spawn(.{}, worker, .{&sh}) catch break;
        spawned += 1;
    }
    if (spawned == 0) worker(&sh);
    for (threads[0..spawned]) |t| t.join();
    if (sh.err) |e| {
        gpa.free(out);
        return .{ .err = e };
    }
    if (sh.failed.load(.monotonic)) {
        gpa.free(out);
        return error.SweepFailed;
    }
    return .{ .ok = out };
}
