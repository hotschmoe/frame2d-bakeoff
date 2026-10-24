//! Results JSON writer (SPEC 5.2) and the beam-stiffness sweep (SPEC 5.4).
const std = @import("std");
const Allocator = std.mem.Allocator;
const engine = @import("engine.zig");
const model = @import("model.zig");
const util = @import("util.zig");
const Prepared = engine.Prepared;
const CaseOut = engine.CaseOut;

pub const AllocStats = struct { count: u64, bytes: u64, peak: u64 };

pub fn writeStats(b: *util.Buf, st: engine.Stats, al: ?AllocStats) Allocator.Error!void {
    try b.raw("{\"nodes\":");
    try b.int(st.nodes);
    try b.raw(",\"members\":");
    try b.int(st.members);
    try b.raw(",\"free_dofs\":");
    try b.int(st.free_dofs);
    try b.raw(",\"profile_before\":");
    try b.int(st.profile_before);
    try b.raw(",\"profile_after\":");
    try b.int(st.profile_after);
    try b.raw(",\"assemble_ms\":");
    try b.num(st.assemble_ms);
    try b.raw(",\"factor_ms\":");
    try b.num(st.factor_ms);
    try b.raw(",\"solve_ms\":");
    try b.num(st.solve_ms);
    if (al) |a| {
        try b.raw(",\"alloc_count\":");
        try b.int(a.count);
        try b.raw(",\"alloc_bytes\":");
        try b.int(a.bytes);
        try b.raw(",\"peak_heap_bytes\":");
        try b.int(a.peak);
    } else {
        try b.raw(",\"alloc_count\":null,\"alloc_bytes\":null,\"peak_heap_bytes\":null");
    }
    try b.byte('}');
}

pub fn writeResults(b: *util.Buf, p: *const Prepared, outs: []const CaseOut, st: engine.Stats, al: ?AllocStats) Allocator.Error!void {
    try b.raw("{\"load_cases\":[");
    for (outs, 0..) |co, c| {
        if (c > 0) try b.byte(',');
        try b.raw("{\"id\":");
        try b.str(p.cases[c].id);
        try b.raw(",\"displacements\":[");
        for (p.node_ids, 0..) |id, k| {
            if (k > 0) try b.byte(',');
            try b.raw("{\"node\":");
            try b.int(id);
            try b.raw(",\"ux\":");
            try b.num(co.u[k * 3]);
            try b.raw(",\"uy\":");
            try b.num(co.u[k * 3 + 1]);
            try b.raw(",\"rz\":");
            try b.num(co.u[k * 3 + 2]);
            try b.byte('}');
        }
        try b.raw("],\"reactions\":[");
        var first = true;
        for (p.node_ids, 0..) |id, k| {
            if (!(p.restrained(k, 0) or p.restrained(k, 1) or p.restrained(k, 2))) continue;
            if (!first) try b.byte(',');
            first = false;
            try b.raw("{\"node\":");
            try b.int(id);
            try b.raw(",\"fx\":");
            try b.num(co.react[k * 3]);
            try b.raw(",\"fy\":");
            try b.num(co.react[k * 3 + 1]);
            try b.raw(",\"mz\":");
            try b.num(co.react[k * 3 + 2]);
            try b.byte('}');
        }
        try b.raw("],\"members\":[");
        for (p.mem_ids, 0..) |id, m| {
            if (m > 0) try b.byte(',');
            const ef = co.ef[m * 6 ..][0..6];
            try b.raw("{\"id\":");
            try b.int(id);
            try b.raw(",\"end_forces\":[");
            for (ef, 0..) |v, q| {
                if (q > 0) try b.byte(',');
                try b.num(v);
            }
            try b.raw("],\"stations\":[");
            const l = p.memberLength(m);
            for (0..11) |k| {
                if (k > 0) try b.byte(',');
                const s = engine.station(p.cases[c].w[m], ef, l, k);
                try b.raw("{\"x\":");
                try b.num(s.x);
                try b.raw(",\"N\":");
                try b.num(s.n);
                try b.raw(",\"V\":");
                try b.num(s.v);
                try b.raw(",\"M\":");
                try b.num(s.m);
                try b.byte('}');
            }
            try b.raw("]}");
        }
        try b.raw("],\"equilibrium_residual\":");
        try b.num(co.residual);
        try b.byte('}');
    }
    try b.raw("],\"warnings\":[");
    for (p.warns, 0..) |node, k| {
        if (k > 0) try b.byte(',');
        try b.raw("{\"warning\":\"auto_restrained\",\"node\":");
        try b.int(node);
        try b.raw(",\"dof\":\"rz\"}");
    }
    try b.raw("],\"stats\":");
    try writeStats(b, st, al);
    try b.byte('}');
}

// ------------------------------------------------------------------ sweep

/// Shared, read-only part of a sweep: the prepared base model plus what variants need to know.
pub const SweepBase = struct {
    arena: std.heap.ArenaAllocator,
    p: *Prepared,
    w_case: usize,
    roof: usize,
    is_bm: []bool, // per sorted member: section id is "BM"
};

/// Per-thread part of a sweep: a forked Prepared and result buffers.
pub const SweepWorker = struct {
    arena: std.heap.ArenaAllocator,
    base: *const SweepBase,
    p: *Prepared,
    outs: []CaseOut,
    base_i: []f64,
};

pub fn sweepOpen(gpa: Allocator, text: []const u8, d: *model.Diag) model.Error!*SweepBase {
    var ar = std.heap.ArenaAllocator.init(gpa);
    errdefer ar.deinit();
    const a = ar.allocator();
    const owned = try a.dupe(u8, text);
    const m = try a.create(model.Model);
    m.* = try model.parseModel(a, owned, d);
    const p = try engine.prepare(gpa, m, d);
    errdefer p.deinit();
    var w_case: ?usize = null;
    for (p.cases, 0..) |c, k| if (std.mem.eql(u8, c.id, "W")) {
        w_case = k;
    };
    if (w_case == null) return d.set(.invalid_ref, "sweep needs a load case with id W", .{});
    var roof: usize = 0;
    for (0..p.nodeCount()) |k| {
        if (p.y[k] > p.y[roof] or (p.y[k] == p.y[roof] and p.x[k] < p.x[roof])) roof = k;
    }
    const is_bm = try a.alloc(bool, p.memberCount());
    for (is_bm, 0..) |*f, k| f.* = std.mem.eql(u8, m.members[p.mem_src[k]].section, "BM");
    const base = try a.create(SweepBase);
    base.* = .{ .arena = ar, .p = p, .w_case = w_case.?, .roof = roof, .is_bm = is_bm };
    return base;
}

pub fn sweepClose(base: *SweepBase) void {
    base.p.deinit();
    var ar = base.arena;
    ar.deinit();
}

pub fn sweepWorkerNew(gpa: Allocator, base: *const SweepBase) Allocator.Error!*SweepWorker {
    var ar = std.heap.ArenaAllocator.init(gpa);
    errdefer ar.deinit();
    const a = ar.allocator();
    const w = try a.create(SweepWorker);
    const p = try base.p.fork(gpa);
    errdefer p.deinit();
    const outs = try a.alloc(CaseOut, p.cases.len);
    for (outs) |*o| o.* = try CaseOut.alloc(a, p);
    w.* = .{ .arena = ar, .base = base, .p = p, .outs = outs, .base_i = base.p.m_i };
    return w;
}

pub fn sweepWorkerFree(w: *SweepWorker) void {
    w.p.deinit();
    var ar = w.arena;
    ar.deinit();
}

pub const SweepPoint = struct { drift: f64, max_m: f64 };

pub fn sweepRun(w: *SweepWorker, scale: f64, d: *model.Diag) model.Error!SweepPoint {
    const p = w.p;
    for (p.m_i, w.base_i, w.base.is_bm) |*mi, bi, bm| mi.* = if (bm) bi * scale else bi;
    var st: engine.Stats = undefined;
    try engine.solve(p, null, w.outs, &st, d);
    var max_m: f64 = 0;
    for (w.outs, 0..) |co, c| {
        for (0..p.memberCount()) |m| {
            max_m = @max(max_m, engine.maxAbsM(p.cases[c].w[m], co.ef[m * 6 ..][0..6], p.memberLength(m)));
        }
    }
    return .{ .drift = w.outs[w.base.w_case].u[w.base.roof * 3], .max_m = max_m };
}
