//! Parametric sweep (SPEC 5.4): scale every `BM` section's I across N variants, solved concurrently.
const std = @import("std");
const Allocator = std.mem.Allocator;
const engine = @import("engine");
const model_mod = engine.model;
const solver = engine.solver;

pub const Variant = struct { scale: f64, roof_drift_W: f64, max_abs_M: f64 };

const Shared = struct {
    gpa: Allocator,
    base: *const model_mod.Model,
    out: []Variant,
    lo: f64,
    hi: f64,
    roof: u32,
    w_case: ?usize,
    next: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),
    first_error: solver.ErrorInfo = .{},
    oom: std.atomic.Value(bool) = .init(false),
};

fn scaleOf(lo: f64, hi: f64, k: usize, n: usize) f64 {
    if (n <= 1) return lo;
    return lo + (hi - lo) * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n - 1));
}

fn worker(sh: *Shared) void {
    const gpa = sh.gpa;
    const sections = gpa.dupe(model_mod.Section, sh.base.sections) catch {
        sh.oom.store(true, .release);
        return;
    };
    defer gpa.free(sections);
    while (!sh.failed.load(.acquire)) {
        const k = sh.next.fetchAdd(1, .monotonic);
        if (k >= sh.out.len) return;
        const scale = scaleOf(sh.lo, sh.hi, k, sh.out.len);
        for (sections, sh.base.sections) |*dst, src| {
            dst.* = src;
            if (std.mem.eql(u8, src.id, "BM")) dst.I = src.I * scale;
        }
        var m = sh.base.*;
        m.sections = sections;
        var info: solver.ErrorInfo = .{};
        var res = solver.solve(gpa, &m, &info) catch |e| {
            if (e == error.OutOfMemory) {
                sh.oom.store(true, .release);
            } else if (!sh.failed.swap(true, .acq_rel)) {
                sh.first_error = info;
            }
            return;
        };
        defer res.deinit();
        var max_m: f64 = 0;
        for (res.cases) |c| {
            for (0..m.members.len) |mi| max_m = @max(max_m, solver.maxAbsM(c.end_forces[mi * 6 ..][0..6], c.w[mi], res.length[mi]));
        }
        const drift = if (sh.w_case) |wc| res.cases[wc].u[sh.roof * 3] else 0;
        sh.out[k] = .{ .scale = scale, .roof_drift_W = drift, .max_abs_M = max_m };
    }
}

pub const SweepError = error{ ModelError, OutOfMemory };

/// Runs the sweep and returns one Variant per step. `base` is normalized (sorted) first so worker threads only read it.
pub fn run(gpa: Allocator, base: *model_mod.Model, n: usize, lo: f64, hi: f64, err: *solver.ErrorInfo) SweepError![]Variant {
    try solver.normalize(base, err);
    const out = try gpa.alloc(Variant, n);
    errdefer gpa.free(out);

    // top-left node: highest y, then lowest x
    var roof: u32 = 0;
    for (base.nodes, 0..) |nd, k| {
        const best = base.nodes[roof];
        if (nd.y > best.y or (nd.y == best.y and nd.x < best.x)) roof = @intCast(k);
    }
    var w_case: ?usize = null;
    for (base.load_cases, 0..) |lc, k| {
        if (std.mem.eql(u8, lc.id, "W")) w_case = k;
    }

    var sh = Shared{ .gpa = gpa, .base = base, .out = out, .lo = lo, .hi = hi, .roof = roof, .w_case = w_case };
    const cpus = std.Thread.getCpuCount() catch 1;
    const n_threads = @max(1, @min(cpus, n));
    const threads = try gpa.alloc(std.Thread, n_threads - 1);
    defer gpa.free(threads);
    var spawned: usize = 0;
    while (spawned < threads.len) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(.{}, worker, .{&sh}) catch break;
    }
    worker(&sh); // the calling thread works too
    for (threads[0..spawned]) |t| t.join();

    if (sh.failed.load(.acquire)) {
        err.* = sh.first_error;
        return error.ModelError;
    }
    if (sh.oom.load(.acquire)) return error.OutOfMemory;
    return out;
}

pub fn write(w: *std.Io.Writer, variants: []const Variant) std.Io.Writer.Error!void {
    var max_drift: f64 = -std.math.inf(f64);
    var max_m: f64 = 0;
    try w.writeAll("{\"variants\":[");
    for (variants, 0..) |v, k| {
        if (k > 0) try w.writeByte(',');
        try w.print("{{\"scale\":{},\"roof_drift_W\":{},\"max_abs_M\":{}}}", .{ v.scale, v.roof_drift_W, v.max_abs_M });
        max_drift = @max(max_drift, v.roof_drift_W);
        max_m = @max(max_m, v.max_abs_M);
    }
    if (variants.len == 0) max_drift = 0;
    try w.print("],\"envelope\":{{\"max_roof_drift_W\":{},\"max_abs_M\":{}}}}}\n", .{ max_drift, max_m });
}
