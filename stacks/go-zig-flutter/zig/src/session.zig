//! Handle-based flat-buffer session API used by the Flutter client (dart:ffi and WASM). All analysis
//! stays in engine.zig; this only marshals into the fixed layouts the Dart side reads.
const std = @import("std");
const Allocator = std.mem.Allocator;
const engine = @import("engine.zig");
const model = @import("model.zig");
const util = @import("util.zig");

// Layout constants shared with the Dart side (app/lib/engine/engine.dart).
pub const node_stride = 4; // id, x, y, restraint bitmask (1=ux 2=uy 4=rz)
pub const member_stride = 3; // id, node index i, node index j
pub const res_member = 18; // 6 end forces, max |M|, 11 M stations
pub const stat_count = 7; // free_dofs, profile_before, profile_after, assemble_ms, factor_ms, solve_ms, residual

pub const Session = struct {
    arena: std.heap.ArenaAllocator,
    model: model.Model,
    p: *engine.Prepared,
    geo: []f64,
    res: []f64,
    stats: [stat_count]f64,
    out: engine.CaseOut,
    case_ids: []u8, // JSON array
    json: []u8, // last serialized model (kept alive for the caller)

    pub fn counts(self: *const Session) [3]i32 {
        return .{ @intCast(self.p.nodeCount()), @intCast(self.p.memberCount()), @intCast(self.p.cases.len) };
    }

    /// Move node `k` (sorted index) in the session.
    pub fn setNode(self: *Session, k: usize, x: f64, y: f64) void {
        if (k >= self.p.nodeCount()) return;
        self.p.setCoord(k, x, y);
        const n = &self.model.nodes[self.p.node_src[k]];
        n.x = x;
        n.y = y;
        self.geo[k * node_stride + 1] = x;
        self.geo[k * node_stride + 2] = y;
    }

    /// Solve load case `c`, filling the result and stats buffers.
    pub fn solve(self: *Session, c_in: i32, d: *model.Diag) model.Error!void {
        const p = self.p;
        const nc = p.cases.len;
        const c: usize = if (c_in < 0 or c_in >= nc) 0 else @intCast(c_in);
        var st: engine.Stats = undefined;
        // only case c gets buffers; engine.solve skips the others
        var outs_buf: [64]engine.CaseOut = undefined;
        const outs: []engine.CaseOut = if (nc <= outs_buf.len) outs_buf[0..nc] else return d.set(.bad_request, "too many load cases", .{});
        outs[c] = self.out;
        try engine.solve(p, c, outs, &st, d);
        const co = outs[c];
        const nn = p.nodeCount();
        @memcpy(self.res[0 .. nn * 3], co.u);
        const w = p.cases[c].w;
        for (0..p.memberCount()) |m| {
            const row = self.res[nn * 3 + m * res_member ..][0..res_member];
            const ef = co.ef[m * 6 ..][0..6];
            @memcpy(row[0..6], ef);
            const l = p.memberLength(m);
            var mx: f64 = 0;
            for (0..11) |k| {
                const s = engine.station(w[m], ef, l, k);
                row[7 + k] = s.m;
                mx = @max(mx, @abs(s.m));
            }
            row[6] = mx;
        }
        self.stats = .{
            @floatFromInt(st.free_dofs),   @floatFromInt(st.profile_before), @floatFromInt(st.profile_after),
            st.assemble_ms,                st.factor_ms,                     st.solve_ms,
            co.residual,
        };
    }

    pub fn toJson(self: *Session) Allocator.Error![]u8 {
        var b = util.Buf{ .a = util.backing };
        try model.writeModel(&b, &self.model);
        const out = try b.finish();
        if (self.json.len > 0) util.backing.free(self.json);
        self.json = out;
        return self.json;
    }
};

/// Build a session from a parsed model. `ar` must be the arena that owns `m`'s memory.
pub fn create(ar: std.heap.ArenaAllocator, m: model.Model, d: *model.Diag) model.Error!*Session {
    var arena = ar;
    errdefer arena.deinit();
    const a = arena.allocator();
    const mm = try a.create(model.Model);
    mm.* = m;
    const p = try engine.prepare(util.backing, mm, d);
    errdefer p.deinit();
    const s = try a.create(Session);
    const nn = p.nodeCount();
    const nm = p.memberCount();
    s.* = .{
        .arena = undefined,
        .model = m,
        .p = p,
        .geo = try a.alloc(f64, nn * node_stride + nm * member_stride),
        .res = try a.alloc(f64, nn * 3 + nm * res_member),
        .stats = @splat(0),
        .out = try engine.CaseOut.alloc(a, p),
        .case_ids = &.{},
        .json = &.{},
    };
    for (0..nn) |k| {
        var mask: f64 = 0;
        for (0..3) |dd| if (p.restrained(k, dd)) {
            mask += @floatFromInt(@as(u32, 1) << @intCast(dd));
        };
        const g = s.geo[k * node_stride ..][0..node_stride];
        g.* = .{ @floatFromInt(p.node_ids[k]), p.x[k], p.y[k], mask };
    }
    const base = nn * node_stride;
    for (0..nm) |k| {
        const g = s.geo[base + k * member_stride ..][0..member_stride];
        g.* = .{ @floatFromInt(p.mem_ids[k]), @floatFromInt(p.mi[k]), @floatFromInt(p.mj[k]) };
    }
    var b = util.Buf{ .a = a };
    try b.byte('[');
    for (p.cases, 0..) |c, k| {
        if (k > 0) try b.byte(',');
        try b.str(c.id);
    }
    try b.byte(']');
    s.case_ids = b.slice();
    s.arena = arena;
    return s;
}

pub fn destroy(s: *Session) void {
    if (s.json.len > 0) util.backing.free(s.json);
    s.p.deinit();
    var ar = s.arena;
    ar.deinit();
}
