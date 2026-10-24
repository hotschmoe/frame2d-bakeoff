//! Parametric sweep (SPEC 5.4): scale every "BM" section's I and solve each variant, concurrently.
const std = @import("std");
const model = @import("model.zig");
const solver = @import("solver.zig");

pub const Variant = struct { scale: f64, roof_drift_w: f64, max_abs_m: f64 };

pub const Result = struct {
    variants: []Variant,
    max_roof_drift_w: f64,
    max_abs_m: f64,
};

const Shared = struct {
    gpa: std.mem.Allocator,
    m: *const model.Model,
    out: []Variant,
    lo: f64,
    hi: f64,
    roof: usize,
    w_case: ?usize,
    next: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),
    diag: model.Diag = .{},
    oom: bool = false,
    lock: std.atomic.Mutex = .unlocked,
};

fn worker(sh: *Shared) void {
    var s = solver.Solver.init(sh.gpa);
    defer s.deinit();
    var diag: model.Diag = .{};
    const sections = sh.gpa.dupe(model.Section, sh.m.sections) catch {
        sh.failed.store(true, .release);
        sh.oom = true;
        return;
    };
    defer sh.gpa.free(sections);
    const n = sh.out.len;
    while (!sh.failed.load(.acquire)) {
        const k = sh.next.fetchAdd(1, .monotonic);
        if (k >= n) break;
        const t: f64 = if (n > 1) @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n - 1)) else 0;
        const scale = sh.lo + (sh.hi - sh.lo) * t;
        for (sections, sh.m.sections) |*dst, src| {
            dst.* = src;
            if (std.mem.eql(u8, src.id, "BM")) dst.I = src.I * scale;
        }
        s.solve(sh.m, sections, std.math.maxInt(u32), &diag) catch |e| {
            while (!sh.lock.tryLock()) {}
            defer sh.lock.unlock();
            if (!sh.failed.load(.acquire)) {
                if (e == error.OutOfMemory) sh.oom = true else sh.diag = diag;
                sh.failed.store(true, .release);
            }
            return;
        };
        var mx: f64 = 0;
        for (s.cases) |c| {
            if (!c.solved) continue;
            for (c.max_m) |v| mx = @max(mx, v);
        }
        const drift = if (sh.w_case) |wc| s.cases[wc].disp[sh.roof * 3] else 0;
        sh.out[k] = .{ .scale = scale, .roof_drift_w = drift, .max_abs_m = mx };
    }
}

pub fn run(
    gpa: std.mem.Allocator,
    m: *const model.Model,
    variants: usize,
    lo: f64,
    hi: f64,
    diag: *model.Diag,
) error{ Model, OutOfMemory }!Result {
    const out = try gpa.alloc(Variant, variants);
    errdefer gpa.free(out);
    var roof: usize = 0;
    for (m.nodes, 0..) |n, k| {
        const r = m.nodes[roof];
        if (n.y > r.y or (n.y == r.y and n.x < r.x)) roof = k;
    }
    var w_case: ?usize = null;
    for (m.load_cases, 0..) |c, k| if (std.mem.eql(u8, c.id, "W")) {
        w_case = k;
    };
    var sh: Shared = .{ .gpa = gpa, .m = m, .out = out, .lo = lo, .hi = hi, .roof = roof, .w_case = w_case };
    const cpus = std.Thread.getCpuCount() catch 4;
    const n_threads = @max(1, @min(cpus, variants));
    const threads = try gpa.alloc(std.Thread, n_threads);
    defer gpa.free(threads);
    var spawned: usize = 0;
    while (spawned < n_threads) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(.{}, worker, .{&sh}) catch break;
    }
    if (spawned == 0) worker(&sh);
    for (threads[0..spawned]) |t| t.join();
    if (sh.failed.load(.acquire)) {
        if (sh.oom) return error.OutOfMemory;
        diag.* = sh.diag;
        return error.Model;
    }
    var res: Result = .{ .variants = out, .max_roof_drift_w = -std.math.inf(f64), .max_abs_m = 0 };
    for (out) |v| {
        res.max_roof_drift_w = @max(res.max_roof_drift_w, v.roof_drift_w);
        res.max_abs_m = @max(res.max_abs_m, v.max_abs_m);
    }
    if (variants == 0) res.max_roof_drift_w = 0;
    return res;
}

pub fn writeJson(w: *std.Io.Writer, r: Result) std.Io.Writer.Error!void {
    const writeNum = @import("model_json.zig").writeNum;
    try w.writeAll("{\"variants\":[");
    for (r.variants, 0..) |v, k| {
        if (k > 0) try w.writeByte(',');
        try w.writeAll("{\"scale\":");
        try writeNum(w, v.scale);
        try w.writeAll(",\"roof_drift_W\":");
        try writeNum(w, v.roof_drift_w);
        try w.writeAll(",\"max_abs_M\":");
        try writeNum(w, v.max_abs_m);
        try w.writeByte('}');
    }
    try w.writeAll("],\"envelope\":{\"max_roof_drift_W\":");
    try writeNum(w, r.max_roof_drift_w);
    try w.writeAll(",\"max_abs_M\":");
    try writeNum(w, r.max_abs_m);
    try w.writeAll("}}");
}
