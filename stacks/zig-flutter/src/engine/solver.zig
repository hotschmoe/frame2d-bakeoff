//! Direct stiffness solver (SPEC 4): RCM numbering, skyline LDL^T, reactions, end forces, equilibrium.
//! A `Solver` is reusable: `prepare` builds the numbering/profile once per topology, `solve` can then be
//! called repeatedly (e.g. while dragging a node) reusing every buffer.
const std = @import("std");
const builtin = @import("builtin");
const model = @import("model.zig");
const rcm = @import("rcm.zig");
const Model = model.Model;
const Diag = model.Diag;

pub const station_count = 11;
/// A pivot at or below `pivot_tol * max diagonal` aborts with `unstable`.
const pivot_tol = 1e-12; // BENCH-EDIT:leaf

pub const Stats = struct {
    nodes: u32 = 0,
    members: u32 = 0,
    free_dofs: u32 = 0,
    profile_before: u64 = 0,
    profile_after: u64 = 0,
    assemble_ms: f64 = 0,
    factor_ms: f64 = 0,
    solve_ms: f64 = 0,
};

pub const CaseResult = struct {
    solved: bool = false,
    /// nodes*3 (ux, uy, rz) in id order.
    disp: []f64 = &.{},
    /// nodes*3, zero on unrestrained DOFs.
    reactions: []f64 = &.{},
    /// members*6 local end forces acting on the member.
    end_forces: []f64 = &.{},
    /// members: total UDL in local y.
    w: []f64 = &.{},
    /// members: largest |M| over the 11 stations.
    max_m: []f64 = &.{},
    /// members*11: bending moment M at each station (for the moment diagram).
    m_stations: []f64 = &.{},
    residual: f64 = 0,
};

extern "env" fn f2d_now_ms() f64;

pub fn nowMs() f64 {
    if (comptime builtin.cpu.arch.isWasm()) {
        return f2d_now_ms();
    } else {
        const io = std.Io.Threaded.global_single_threaded.io();
        const ns: i128 = std.Io.Timestamp.now(io, .awake).nanoseconds;
        return @as(f64, @floatFromInt(ns)) / 1.0e6;
    }
}

/// Numbering of the free DOFs and the skyline layout for one topology.
pub const Plan = struct {
    n_free: u32,
    /// node*3+d -> free DOF index in RCM numbering, or -1 when restrained.
    dof_of: []i32,
    dof_node: []u32,
    dof_comp: []u8,
    /// Column heights and start offsets (column j occupies col_ptr[j]..col_ptr[j+1], diagonal last).
    height: []u32,
    col_ptr: []usize,
    profile_before: u64,
    profile_after: u64,
    /// Nodes whose rz was restrained automatically because releases left it with no stiffness (SPEC 4.7).
    auto: []u32,

    fn deinit(p: *Plan, gpa: std.mem.Allocator) void {
        gpa.free(p.auto);
        gpa.free(p.dof_of);
        gpa.free(p.dof_node);
        gpa.free(p.dof_comp);
        gpa.free(p.height);
        gpa.free(p.col_ptr);
    }
};

/// Sum of skyline column heights for a given free-DOF numbering (SPEC 4.4 profile definition).
fn heightsFor(gpa: std.mem.Allocator, m: *const Model, dof_of: []const i32, n_free: u32, heights: []u32) !u64 {
    const first = try gpa.alloc(u32, n_free);
    defer gpa.free(first);
    for (first, 0..) |*f, k| f.* = @intCast(k);
    for (m.members) |mem| {
        var ds: [6]i32 = undefined;
        for (0..3) |d| {
            ds[d] = dof_of[mem.i * 3 + d];
            ds[3 + d] = dof_of[mem.j * 3 + d];
        }
        var lowest: i32 = std.math.maxInt(i32);
        for (ds) |x| if (x >= 0 and x < lowest) {
            lowest = x;
        };
        if (lowest == std.math.maxInt(i32)) continue;
        for (ds) |x| if (x >= 0) {
            const xi: usize = @intCast(x);
            if (@as(u32, @intCast(lowest)) < first[xi]) first[xi] = @intCast(lowest);
        };
    }
    var total: u64 = 0;
    for (first, 0..) |f, j| {
        heights[j] = @as(u32, @intCast(j)) - f;
        total += heights[j];
    }
    return total;
}

/// Skyline profile for the numbering that follows `ord` (or id order when null) under `restraint`.
fn profileOf(gpa: std.mem.Allocator, m: *const Model, restraint: []const u8, ord: ?[]const u32) !u64 {
    const nn = m.nodes.len;
    const dof_of = try gpa.alloc(i32, nn * 3);
    defer gpa.free(dof_of);
    var count: u32 = 0;
    for (0..nn) |q| {
        const nd = if (ord) |o| o[q] else q;
        for (0..3) |d| {
            if (restraint[nd] & (@as(u8, 1) << @intCast(d)) != 0) {
                dof_of[nd * 3 + d] = -1;
            } else {
                dof_of[nd * 3 + d] = @intCast(count);
                count += 1;
            }
        }
    }
    const heights = try gpa.alloc(u32, count);
    defer gpa.free(heights);
    return heightsFor(gpa, m, dof_of, count, heights);
}

/// Effective restraints: the model's supports plus every free rz that no member (after releases) or spring
/// stiffens. Returns the auto-restrained node indices; `eff` is filled in either way.
fn autoRestrain(gpa: std.mem.Allocator, m: *const Model, eff: []u8) ![]u32 {
    const nn = m.nodes.len;
    @memcpy(eff, m.restraint);
    var any_release = false;
    for (m.members) |mem| {
        if (mem.rel != 0) any_release = true;
    }
    if (!any_release) return gpa.alloc(u32, 0);
    const rz = try gpa.alloc(f64, nn);
    defer gpa.free(rz);
    @memset(rz, 0);
    if (m.springs.len > 0) {
        for (0..nn) |k| rz[k] = m.springs[k * 3 + 2];
    }
    for (m.members, 0..) |mem, k| {
        const L = m.memberLength(k);
        const ei = m.materials[mem.mat].E * m.sections[mem.sec].I;
        // Rotational stiffness at an unreleased end: 4EI/L, or 3EI/L when the far end is released.
        if (mem.rel & 1 == 0) rz[mem.i] += (if (mem.rel & 2 != 0) @as(f64, 3) else 4) * ei / L;
        if (mem.rel & 2 == 0) rz[mem.j] += (if (mem.rel & 1 != 0) @as(f64, 3) else 4) * ei / L;
    }
    var list: std.ArrayList(u32) = .empty;
    errdefer list.deinit(gpa);
    for (0..nn) |k| {
        if (eff[k] & model.RZ == 0 and rz[k] <= 0) {
            eff[k] |= model.RZ;
            try list.append(gpa, @intCast(k));
        }
    }
    return list.toOwnedSlice(gpa);
}

fn buildPlan(gpa: std.mem.Allocator, m: *const Model, diag: *Diag) error{ Model, OutOfMemory }!Plan {
    const nn = m.nodes.len;
    const eff = try gpa.alloc(u8, nn);
    defer gpa.free(eff);
    const auto = try autoRestrain(gpa, m, eff);
    errdefer gpa.free(auto);
    // Original (id order) numbering for profile_before.
    const dof_of = try gpa.alloc(i32, nn * 3);
    errdefer gpa.free(dof_of);
    var count: u32 = 0;
    for (0..nn) |k| {
        for (0..3) |d| {
            if (eff[k] & (@as(u8, 1) << @intCast(d)) != 0) {
                dof_of[k * 3 + d] = -1;
            } else {
                dof_of[k * 3 + d] = @intCast(count);
                count += 1;
            }
        }
    }
    if (count == 0) return diag.set(.no_free_dofs, "every degree of freedom is restrained", .{});
    const n_free = count;
    const heights = try gpa.alloc(u32, n_free);
    errdefer gpa.free(heights);
    const before = try heightsFor(gpa, m, dof_of, n_free, heights);

    // RCM numbering.
    const ord = try rcm.order(gpa, nn, m.members);
    defer gpa.free(ord);
    const dof_node = try gpa.alloc(u32, n_free);
    errdefer gpa.free(dof_node);
    const dof_comp = try gpa.alloc(u8, n_free);
    errdefer gpa.free(dof_comp);
    count = 0;
    for (ord) |nd| {
        for (0..3) |d| {
            if (eff[nd] & (@as(u8, 1) << @intCast(d)) != 0) {
                dof_of[nd * 3 + d] = -1;
            } else {
                dof_of[nd * 3 + d] = @intCast(count);
                dof_node[count] = nd;
                dof_comp[count] = @intCast(d);
                count += 1;
            }
        }
    }
    const after = try heightsFor(gpa, m, dof_of, n_free, heights);
    var before_stat = before;
    var after_stat = after;
    if (auto.len > 0) {
        before_stat = try profileOf(gpa, m, m.restraint, null);
        after_stat = try profileOf(gpa, m, m.restraint, ord);
    }
    const col_ptr = try gpa.alloc(usize, n_free + 1);
    errdefer gpa.free(col_ptr);
    var off: usize = 0;
    for (0..n_free) |j| {
        col_ptr[j] = off;
        off += heights[j] + 1;
    }
    col_ptr[n_free] = off;
    return .{
        .n_free = n_free,
        .dof_of = dof_of,
        .dof_node = dof_node,
        .dof_comp = dof_comp,
        .height = heights,
        .col_ptr = col_ptr,
        .profile_before = before_stat,
        .profile_after = after_stat,
        .auto = auto,
    };
}

inline fn dot(a: []const f64, b: []const f64) f64 {
    const V = @Vector(4, f64);
    var acc0: V = @splat(0);
    var acc1: V = @splat(0);
    var i: usize = 0;
    while (i + 8 <= a.len) : (i += 8) {
        const x0: V = a[i..][0..4].*;
        const y0: V = b[i..][0..4].*;
        const x1: V = a[i + 4 ..][0..4].*;
        const y1: V = b[i + 4 ..][0..4].*;
        acc0 += x0 * y0;
        acc1 += x1 * y1;
    }
    var s = @reduce(.Add, acc0 + acc1);
    while (i < a.len) : (i += 1) s += a[i] * b[i];
    return s;
}

/// Member geometry and local stiffness terms.
const Geom = struct {
    L: f64,
    c: f64,
    s: f64,
    a: f64, // EA/L
    b1: f64, // 12EI/L^3
    b2: f64, // 6EI/L^2
    b3: f64, // 4EI/L
    b4: f64, // 2EI/L
    rel: u8, // end releases (SPEC 4.7)

    fn of(m: *const Model, sections: []const model.Section, k: usize) Geom {
        const mem = m.members[k];
        const ni = m.nodes[mem.i];
        const nj = m.nodes[mem.j];
        const dx = nj.x - ni.x;
        const dy = nj.y - ni.y;
        const L = std.math.hypot(dx, dy);
        const E = m.materials[mem.mat].E;
        const sec = sections[mem.sec];
        const EI = E * sec.I;
        return .{
            .L = L,
            .c = dx / L,
            .s = dy / L,
            .a = E * sec.A / L,
            .b1 = 12 * EI / (L * L * L),
            .b2 = 6 * EI / (L * L),
            .b3 = 4 * EI / L,
            .b4 = 2 * EI / L,
            .rel = mem.rel,
        };
    }

    /// Static condensation of the released rotational DOFs (local index 2 = mz at i, 5 = mz at j) out of
    /// the stiffness `k` and the fixed-end vector `f`. Released rows and columns end up zero.
    fn condense(g: Geom, k: *[6][6]f64, f: *[6]f64) void {
        const dofs = [2]usize{ 2, 5 };
        for (dofs, 0..) |r, bit| {
            if (g.rel & (@as(u8, 1) << @intCast(bit)) == 0) continue;
            const piv = k[r][r];
            const col = [6]f64{ k[0][r], k[1][r], k[2][r], k[3][r], k[4][r], k[5][r] };
            const row = k[r];
            const fr = f[r];
            for (0..6) |i| {
                for (0..6) |j| k[i][j] -= col[i] * row[j] / piv;
                f[i] -= col[i] * fr / piv;
            }
        }
    }

    fn localK(g: Geom) [6][6]f64 {
        var k = g.rawK();
        if (g.rel != 0) {
            var f = [6]f64{ 0, 0, 0, 0, 0, 0 };
            g.condense(&k, &f);
        }
        return k;
    }

    fn rawK(g: Geom) [6][6]f64 {
        return .{
            .{ g.a, 0, 0, -g.a, 0, 0 },
            .{ 0, g.b1, g.b2, 0, -g.b1, g.b2 },
            .{ 0, g.b2, g.b3, 0, -g.b2, g.b4 },
            .{ -g.a, 0, 0, g.a, 0, 0 },
            .{ 0, -g.b1, -g.b2, 0, g.b1, -g.b2 },
            .{ 0, g.b2, g.b4, 0, -g.b2, g.b3 },
        };
    }

    /// Global -> local rotation of a 6-vector (and its transpose, local -> global).
    fn toLocal(g: Geom, v: [6]f64) [6]f64 {
        return .{
            g.c * v[0] + g.s * v[1], -g.s * v[0] + g.c * v[1], v[2],
            g.c * v[3] + g.s * v[4], -g.s * v[3] + g.c * v[4], v[5],
        };
    }

    fn toGlobal(g: Geom, v: [6]f64) [6]f64 {
        return .{
            g.c * v[0] - g.s * v[1], g.s * v[0] + g.c * v[1], v[2],
            g.c * v[3] - g.s * v[4], g.s * v[3] + g.c * v[4], v[5],
        };
    }

    fn fixedEnd(g: Geom, w: f64) [6]f64 {
        const wl = w * g.L;
        var f = [6]f64{ 0, -wl / 2, -wl * g.L / 12, 0, -wl / 2, wl * g.L / 12 };
        if (g.rel != 0) {
            var k = g.rawK();
            g.condense(&k, &f);
        }
        return f;
    }
};

fn matVec(k: *const [6][6]f64, v: [6]f64) [6]f64 {
    var out: [6]f64 = undefined;
    for (0..6) |r| {
        var s: f64 = 0;
        for (0..6) |c| s += k[r][c] * v[c];
        out[r] = s;
    }
    return out;
}

/// Station values at x = k*L/10 (SPEC 4.5).
pub const Station = struct { x: f64, N: f64, V: f64, M: f64 };
pub fn station(L: f64, w: f64, ef: []const f64, k: usize) Station {
    const x = L * @as(f64, @floatFromInt(k)) / 10.0;
    return .{ .x = x, .N = -ef[0], .V = ef[1] + w * x, .M = -ef[2] + ef[1] * x + w * x * x / 2 };
}

pub const Solver = struct {
    gpa: std.mem.Allocator,
    plan: ?Plan = null,
    k: []f64 = &.{},
    work: []f64 = &.{},
    dinv: []f64 = &.{},
    rhs: []f64 = &.{},
    applied: []f64 = &.{},
    cases: []CaseResult = &.{},
    stats: Stats = .{},
    /// Time spent building the plan, charged to the next solve's assemble time.
    pending_prepare_ms: f64 = 0,

    pub fn init(gpa: std.mem.Allocator) Solver {
        return .{ .gpa = gpa };
    }

    pub fn deinit(s: *Solver) void {
        s.invalidate();
        s.freeCases();
        s.* = undefined;
    }

    fn freeCases(s: *Solver) void {
        for (s.cases) |c| {
            s.gpa.free(c.disp);
            s.gpa.free(c.reactions);
            s.gpa.free(c.end_forces);
            s.gpa.free(c.w);
            s.gpa.free(c.max_m);
            s.gpa.free(c.m_stations);
        }
        s.gpa.free(s.cases);
        s.cases = &.{};
    }

    /// Drop everything derived from the topology; call when the model's connectivity or supports change.
    pub fn invalidate(s: *Solver) void {
        if (s.plan) |*p| p.deinit(s.gpa);
        s.plan = null;
        s.gpa.free(s.k);
        s.gpa.free(s.work);
        s.gpa.free(s.dinv);
        s.gpa.free(s.rhs);
        s.gpa.free(s.applied);
        s.applied = &.{};
        s.k = &.{};
        s.work = &.{};
        s.dinv = &.{};
        s.rhs = &.{};
    }

    pub fn prepare(s: *Solver, m: *const Model, diag: *Diag) error{ Model, OutOfMemory }!void {
        if (s.plan != null) return;
        const t0 = nowMs();
        s.plan = try buildPlan(s.gpa, m, diag);
        const p = &s.plan.?;
        s.k = try s.gpa.alloc(f64, p.col_ptr[p.n_free]);
        s.work = try s.gpa.alloc(f64, p.n_free);
        s.dinv = try s.gpa.alloc(f64, p.n_free);
        s.pending_prepare_ms = nowMs() - t0;
        s.stats.profile_before = p.profile_before;
        s.stats.profile_after = p.profile_after;
        s.stats.free_dofs = p.n_free;
        s.stats.nodes = @intCast(m.nodes.len);
        s.stats.members = @intCast(m.members.len);
    }

    fn ensureCases(s: *Solver, m: *const Model) !void {
        if (s.cases.len == m.load_cases.len and
            (s.cases.len == 0 or s.cases[0].disp.len == m.nodes.len * 3)) return;
        s.freeCases();
        s.cases = try s.gpa.alloc(CaseResult, m.load_cases.len);
        for (s.cases) |*c| c.* = .{};
    }

    fn ensureCaseBuffers(s: *Solver, m: *const Model, c: *CaseResult) !void {
        if (c.disp.len == m.nodes.len * 3 and c.end_forces.len == m.members.len * 6) return;
        s.gpa.free(c.disp);
        s.gpa.free(c.reactions);
        s.gpa.free(c.end_forces);
        s.gpa.free(c.w);
        s.gpa.free(c.max_m);
        s.gpa.free(c.m_stations);
        c.* = .{};
        c.disp = try s.gpa.alloc(f64, m.nodes.len * 3);
        c.reactions = try s.gpa.alloc(f64, m.nodes.len * 3);
        c.end_forces = try s.gpa.alloc(f64, m.members.len * 6);
        c.w = try s.gpa.alloc(f64, m.members.len);
        c.max_m = try s.gpa.alloc(f64, m.members.len);
        c.m_stations = try s.gpa.alloc(f64, m.members.len * station_count);
    }

    /// Solve the load cases whose bit is set in `mask` (bit k = case k). One assembly and factorization.
    pub fn solve(s: *Solver, m: *const Model, sections: []const model.Section, mask: u32, diag: *Diag) error{ Model, OutOfMemory }!void {
        for (m.members, 0..) |mem, k| {
            const a = m.nodes[mem.i];
            const b = m.nodes[mem.j];
            if (std.math.hypot(b.x - a.x, b.y - a.y) < 1e-9)
                return diag.set(.zero_length, "member {d} has zero length", .{m.members[k].id});
        }
        try s.prepare(m, diag);
        const plan = &s.plan.?;
        try s.ensureCases(m);

        const t0 = nowMs();
        s.assemble(m, sections);
        const t1 = nowMs();
        try s.factor(m, diag);
        const t2 = nowMs();
        for (m.load_cases, 0..) |lc, ci| {
            if (ci >= 32 or mask & (@as(u32, 1) << @intCast(ci)) == 0) continue;
            try s.solveCase(m, sections, lc, &s.cases[ci]);
        }
        const t3 = nowMs();
        _ = plan;
        s.stats.assemble_ms = (t1 - t0) + s.pending_prepare_ms;
        s.pending_prepare_ms = 0;
        s.stats.factor_ms = t2 - t1;
        s.stats.solve_ms = t3 - t2;
    }

    fn assemble(s: *Solver, m: *const Model, sections: []const model.Section) void {
        const plan = &s.plan.?;
        @memset(s.k, 0);
        for (0..m.members.len) |mk| {
            const mem = m.members[mk];
            const g = Geom.of(m, sections, mk);
            const kl = g.localK();
            // kg = T^T kl T, with T = blockdiag(R, R).
            var kt: [6][6]f64 = undefined;
            for (0..6) |r| kt[r] = g.toGlobal(kl[r]);
            var kg: [6][6]f64 = undefined;
            for (0..6) |c| {
                const col: [6]f64 = .{ kt[0][c], kt[1][c], kt[2][c], kt[3][c], kt[4][c], kt[5][c] };
                const gc = g.toGlobal(col);
                for (0..6) |r| kg[r][c] = gc[r];
            }
            var ds: [6]i32 = undefined;
            for (0..3) |d| {
                ds[d] = plan.dof_of[mem.i * 3 + d];
                ds[3 + d] = plan.dof_of[mem.j * 3 + d];
            }
            for (0..6) |cc| {
                const col = ds[cc];
                if (col < 0) continue;
                const cj: usize = @intCast(col);
                const top = plan.col_ptr[cj] + plan.height[cj]; // diagonal position
                for (0..6) |rr| {
                    const row = ds[rr];
                    if (row < 0 or row > col) continue;
                    s.k[top - @as(usize, @intCast(col - row))] += kg[rr][cc];
                }
            }
        }
        if (m.springs.len > 0) {
            for (0..m.nodes.len * 3) |q| {
                const dof = plan.dof_of[q];
                if (dof < 0 or m.springs[q] == 0) continue;
                const cj: usize = @intCast(dof);
                s.k[plan.col_ptr[cj] + plan.height[cj]] += m.springs[q];
            }
        }
    }

    fn factor(s: *Solver, m: *const Model, diag: *Diag) error{Model}!void {
        const plan = &s.plan.?;
        const n = plan.n_free;
        const k = s.k;
        var max_diag: f64 = 0;
        for (0..n) |j| max_diag = @max(max_diag, k[plan.col_ptr[j] + plan.height[j]]);
        const limit = pivot_tol * max_diag;
        const v = s.work;
        for (0..n) |j| {
            const hj = plan.height[j];
            const mj = j - hj;
            const cj = plan.col_ptr[j];
            var i = mj;
            while (i < j) : (i += 1) {
                const hi = plan.height[i];
                const mi = i - hi;
                const ci = plan.col_ptr[i];
                const k0 = @max(mi, mj);
                const sum = dot(k[ci + (k0 - mi) .. ci + hi], v[k0..i]);
                v[i] = k[cj + (i - mj)] - sum;
            }
            var acc: f64 = 0;
            i = mj;
            while (i < j) : (i += 1) {
                const u = v[i] * s.dinv[i];
                k[cj + (i - mj)] = u;
                acc += u * v[i];
            }
            const d = k[cj + hj] - acc;
            if (!(d > limit)) {
                const comp = [_][]const u8{ "ux", "uy", "rz" };
                return diag.set(.unstable, "pivot {e} <= {e} at node {d} dof {s}", .{
                    d, limit, m.nodes[plan.dof_node[j]].id, comp[plan.dof_comp[j]],
                });
            }
            k[cj + hj] = d;
            s.dinv[j] = 1.0 / d;
        }
    }

    fn solveCase(s: *Solver, m: *const Model, sections: []const model.Section, lc: model.LoadCase, c: *CaseResult) !void {
        try s.ensureCaseBuffers(m, c);
        const plan = &s.plan.?;
        const n = plan.n_free;
        if (s.rhs.len != n) {
            s.gpa.free(s.rhs);
            s.rhs = try s.gpa.alloc(f64, n);
        }
        const b = s.rhs;
        @memset(b, 0);
        @memset(c.w, 0);
        @memset(c.reactions, 0);
        // Applied loads (kept per node for the reaction / equilibrium step).
        if (s.applied.len != m.nodes.len * 3) {
            s.gpa.free(s.applied);
            s.applied = try s.gpa.alloc(f64, m.nodes.len * 3);
        }
        const applied = s.applied;
        @memset(applied, 0);
        for (lc.nodal) |l| {
            const f = [3]f64{ l.fx, l.fy, l.mz };
            for (0..3) |d| {
                applied[l.node * 3 + d] += f[d];
                const dof = plan.dof_of[l.node * 3 + d];
                if (dof >= 0) b[@intCast(dof)] += f[d];
            }
        }
        for (lc.udl) |u| c.w[u.member] += u.w;
        for (lc.udl) |u| {
            const mem = m.members[u.member];
            const g = Geom.of(m, sections, u.member);
            const fe = g.toGlobal(g.fixedEnd(u.w));
            for (0..6) |q| {
                const node = if (q < 3) mem.i else mem.j;
                const dof = plan.dof_of[node * 3 + q % 3];
                if (dof >= 0) b[@intCast(dof)] -= fe[q];
            }
        }
        // Forward: U^T y = b, scale by D^-1, back: U x = z.
        const k = s.k;
        for (0..n) |j| {
            const hj = plan.height[j];
            const mj = j - hj;
            const cj = plan.col_ptr[j];
            b[j] -= dot(k[cj .. cj + hj], b[mj..j]);
        }
        for (0..n) |j| b[j] *= s.dinv[j];
        var j = n;
        while (j > 0) {
            j -= 1;
            const hj = plan.height[j];
            const mj = j - hj;
            const cj = plan.col_ptr[j];
            const xj = b[j];
            if (xj != 0) {
                for (0..hj) |q| b[mj + q] -= k[cj + q] * xj;
            }
        }
        for (0..m.nodes.len * 3) |q| {
            const dof = plan.dof_of[q];
            c.disp[q] = if (dof >= 0) b[@intCast(dof)] else 0;
        }
        postProcess(m, sections, c, applied);
        c.solved = true;
    }
};

/// End forces, reactions, max |M| and equilibrium residual. `applied` holds the applied nodal loads (nodes*3).
fn postProcess(m: *const Model, sections: []const model.Section, c: *CaseResult, applied: []const f64) void {
    const nn = m.nodes.len;
    var udl_fx: f64 = 0;
    var udl_fy: f64 = 0;
    var udl_mo: f64 = 0;
    var udl_abs: f64 = 0;
    var udl_mabs: f64 = 0;
    for (0..m.members.len) |k| {
        const mem = m.members[k];
        const g = Geom.of(m, sections, k);
        const ni = m.nodes[mem.i];
        const nj = m.nodes[mem.j];
        const ug: [6]f64 = .{
            c.disp[mem.i * 3],  c.disp[mem.i * 3 + 1],  c.disp[mem.i * 3 + 2],
            c.disp[mem.j * 3], c.disp[mem.j * 3 + 1], c.disp[mem.j * 3 + 2],
        };
        const kl = g.localK();
        const ul = g.toLocal(ug);
        var f = matVec(&kl, ul);
        const fe = g.fixedEnd(c.w[k]);
        for (0..6) |q| f[q] += fe[q];
        @memcpy(c.end_forces[k * 6 ..][0..6], &f);
        const fg = g.toGlobal(f);
        for (0..3) |d| {
            c.reactions[mem.i * 3 + d] += fg[d];
            c.reactions[mem.j * 3 + d] += fg[3 + d];
        }
        var mx: f64 = 0;
        for (0..station_count) |q| {
            const mq = station(g.L, c.w[k], &f, q).M;
            c.m_stations[k * station_count + q] = mq;
            mx = @max(mx, @abs(mq));
        }
        c.max_m[k] = mx;
        // UDL resultant in global axes, acting at the member midpoint.
        const w = c.w[k];
        if (w != 0) {
            const fx = -w * g.L * g.s;
            const fy = w * g.L * g.c;
            const mxp = (ni.x + nj.x) / 2;
            const myp = (ni.y + nj.y) / 2;
            udl_fx += fx;
            udl_fy += fy;
            udl_mo += mxp * fy - myp * fx;
            udl_abs += @abs(fx) + @abs(fy);
            udl_mabs += @abs(mxp * fy) + @abs(myp * fx);
        }
    }
    // Reactions = member end forces at the node minus applied nodal loads, on restrained DOFs only.
    var sum_x: f64 = udl_fx;
    var sum_y: f64 = udl_fy;
    var sum_m: f64 = udl_mo;
    var scale_f: f64 = udl_abs;
    var scale_m: f64 = udl_mabs;
    for (0..nn) |nd| {
        const r = m.restraint[nd];
        const x = m.nodes[nd].x;
        const y = m.nodes[nd].y;
        const a_fx = applied[nd * 3];
        const a_fy = applied[nd * 3 + 1];
        const a_mz = applied[nd * 3 + 2];
        sum_x += a_fx;
        sum_y += a_fy;
        sum_m += a_mz + x * a_fy - y * a_fx;
        scale_f += @abs(a_fx) + @abs(a_fy);
        scale_m += @abs(a_mz) + @abs(x * a_fy) + @abs(y * a_fx);
        for (0..3) |d| {
            if (r & (@as(u8, 1) << @intCast(d)) != 0) {
                c.reactions[nd * 3 + d] -= applied[nd * 3 + d];
            } else {
                c.reactions[nd * 3 + d] = 0;
            }
        }
        var rx = c.reactions[nd * 3];
        var ry = c.reactions[nd * 3 + 1];
        var rm = c.reactions[nd * 3 + 2];
        if (m.springs.len > 0) { // spring forces are reactions too
            rx -= m.springs[nd * 3] * c.disp[nd * 3];
            ry -= m.springs[nd * 3 + 1] * c.disp[nd * 3 + 1];
            rm -= m.springs[nd * 3 + 2] * c.disp[nd * 3 + 2];
        }
        sum_x += rx;
        sum_y += ry;
        sum_m += rm + x * ry - y * rx;
        scale_f += @abs(rx) + @abs(ry);
        scale_m += @abs(rm) + @abs(x * ry) + @abs(y * rx);
    }
    c.residual = if (scale_f == 0 and scale_m == 0) 0 else @max(
        @max(@abs(sum_x), @abs(sum_y)) / @max(scale_f, 1.0),
        @abs(sum_m) / @max(scale_m, 1.0),
    );
}
