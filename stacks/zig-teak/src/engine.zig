//! Frame2D analysis (SPEC 4): validation, DOF numbering, assembly, factor once / solve per case,
//! post-processing (end forces, reactions, station diagrams, equilibrium check).
const std = @import("std");
const Allocator = std.mem.Allocator;
pub const model = @import("model.zig");
pub const solver = @import("solver.zig");

const NONE: u32 = std.math.maxInt(u32);
pub const n_stations = 11;

pub const ModelError = struct {
    code: []const u8,
    detail: []const u8,
};

pub const Stats = struct {
    nodes: usize = 0,
    members: usize = 0,
    free_dofs: usize = 0,
    profile_before: u64 = 0,
    profile_after: u64 = 0,
    assemble_ms: f64 = 0,
    factor_ms: f64 = 0,
    solve_ms: f64 = 0,
    alloc_count: ?u64 = null,
    alloc_bytes: ?u64 = null,
    peak_heap_bytes: ?u64 = null,
};

pub const Station = struct { x: f64, N: f64, V: f64, M: f64 };

pub const CaseResult = struct {
    id: []const u8,
    /// by sorted node position
    disp: [][3]f64,
    react: [][3]f64,
    /// by sorted member position
    end_forces: [][6]f64,
    stations: [][n_stations]Station,
    residual: f64,
    max_abs_m: f64,
};

pub const Results = struct {
    /// node_src[k] = index into model.nodes of the k-th node in id order (same for members)
    node_src: []u32,
    member_src: []u32,
    /// sorted node position -> supported (any DOF restrained) / restraint flags
    restrained: [][3]bool,
    supported: []bool,
    /// P2 auto-restrained rotational DOFs (SPEC 4.7), by sorted node position, ascending
    auto_restrained: []u32,
    cases: []CaseResult,
    stats: Stats,
};

pub const Outcome = union(enum) {
    ok: Results,
    err: ModelError,
};

pub const Options = struct {
    /// Solve only this load case index (the drag bench and the UI drag use it).
    only_case: ?usize = null,
    /// Millisecond clock for the stats timers; null = timers report 0.
    clock: ?*const fn () f64 = null,
    /// Skip computing profile_before (the UI drag path does not need it).
    skip_profile_before: bool = false,
};

const Elem = struct {
    ni: u32,
    nj: u32,
    E: f64,
    A: f64,
    I: f64,
    L: f64,
    c: f64,
    s: f64,
    /// P2 end releases (SPEC 4.7): mz released at end i / end j
    rel_i: bool = false,
    rel_j: bool = false,
};

fn fail(a: Allocator, code: []const u8, comptime fmt: []const u8, args: anytype) !Outcome {
    return .{ .err = .{ .code = code, .detail = try std.fmt.allocPrint(a, fmt, args) } };
}

fn lessId(ids: []const i64, x: u32, y: u32) bool {
    return ids[x] < ids[y];
}

/// Local stiffness (acting on member, local axes), statically condensed for end releases.
pub fn localK(e: Elem) [6][6]f64 {
    var k = rigidK(e);
    if (e.rel_i) condenseK(&k, 2);
    if (e.rel_j) condenseK(&k, 5);
    return k;
}

/// Static condensation of local DOF r out of k: k' = k - k[:,r] k[r,:] / k[r][r] (row/col r become 0).
fn condenseK(k: *[6][6]f64, r: usize) void {
    const d = k[r][r];
    if (d == 0) return;
    const old = k.*;
    for (0..6) |p| for (0..6) |q| {
        k[p][q] = old[p][q] - old[p][r] * old[r][q] / d;
    };
    for (0..6) |p| {
        k[p][r] = 0;
        k[r][p] = 0;
    }
}

/// Condense fixed-end forces with the same step: f' = f - k[:,r] f[r] / k[r][r], then condense k.
fn condenseF(k: *[6][6]f64, f: *[6]f64, r: usize) void {
    const d = k[r][r];
    if (d == 0) return;
    const fr = f[r];
    for (0..6) |p| f[p] -= k[p][r] * fr / d;
    f[r] = 0;
    condenseK(k, r);
}

/// Fixed-end forces of a local-y UDL on member e, condensed for its releases.
fn memberFixedEnd(e: Elem, w: f64) [6]f64 {
    var f = fixedEnd(w, e.L);
    if (!e.rel_i and !e.rel_j) return f;
    var k = rigidK(e);
    if (e.rel_i) condenseF(&k, &f, 2);
    if (e.rel_j) condenseF(&k, &f, 5);
    return f;
}

fn rigidK(e: Elem) [6][6]f64 {
    const L = e.L;
    const ea = e.E * e.A / L;
    const ei = e.E * e.I;
    const k1 = 12 * ei / (L * L * L);
    const k2 = 6 * ei / (L * L);
    const k3 = 4 * ei / L;
    const k4 = 2 * ei / L;
    return .{
        .{ ea, 0, 0, -ea, 0, 0 },
        .{ 0, k1, k2, 0, -k1, k2 },
        .{ 0, k2, k3, 0, -k2, k4 },
        .{ -ea, 0, 0, ea, 0, 0 },
        .{ 0, -k1, -k2, 0, k1, -k2 },
        .{ 0, k2, k4, 0, -k2, k3 },
    };
}

/// global -> local for one 6-vector
inline fn toLocal(e: Elem, g: [6]f64) [6]f64 {
    return .{
        e.c * g[0] + e.s * g[1],  -e.s * g[0] + e.c * g[1], g[2],
        e.c * g[3] + e.s * g[4], -e.s * g[3] + e.c * g[4], g[5],
    };
}

/// local -> global for one 6-vector (T^T)
inline fn toGlobal(e: Elem, l: [6]f64) [6]f64 {
    return .{
        e.c * l[0] - e.s * l[1], e.s * l[0] + e.c * l[1], l[2],
        e.c * l[3] - e.s * l[4], e.s * l[3] + e.c * l[4], l[5],
    };
}

fn globalK(e: Elem) [6][6]f64 {
    const kl = localK(e);
    // kg = T^T kl T, column by column: kg[:,q] = T^T (kl (T e_q))
    var kg: [6][6]f64 = undefined;
    for (0..6) |q| {
        var unit = @as([6]f64, @splat(0));
        unit[q] = 1;
        const tl = toLocal(e, unit);
        var col: [6]f64 = undefined;
        for (0..6) |r| {
            var sum: f64 = 0;
            for (0..6) |k| sum += kl[r][k] * tl[k];
            col[r] = sum;
        }
        const g = toGlobal(e, col);
        for (0..6) |r| kg[r][q] = g[r];
    }
    return kg;
}

/// Fixed-end forces of a local-y UDL, local, acting on the member (SPEC 4.2).
pub fn fixedEnd(w: f64, L: f64) [6]f64 {
    return .{ 0, -w * L / 2, -w * L * L / 12, 0, -w * L / 2, w * L * L / 12 };
}

fn numberDofs(order: []const u32, restr: []const [3]bool, dof: []u32) u32 {
    var next: u32 = 0;
    for (order) |v| {
        for (0..3) |c| {
            if (restr[v][c]) {
                dof[v * 3 + c] = NONE;
            } else {
                dof[v * 3 + c] = next;
                next += 1;
            }
        }
    }
    return next;
}

fn columnFirst(elems: []const Elem, dof: []const u32, first: []u32) void {
    for (first, 0..) |*f, j| f.* = @intCast(j);
    for (elems) |e| {
        var ds: [6]u32 = undefined;
        var lo: u32 = NONE;
        for (0..3) |c| {
            ds[c] = dof[e.ni * 3 + c];
            ds[3 + c] = dof[e.nj * 3 + c];
        }
        for (ds) |d| if (d != NONE and d < lo) {
            lo = d;
        };
        for (ds) |d| if (d != NONE and lo < first[d]) {
            first[d] = lo;
        };
    }
}

fn now(o: Options) f64 {
    return if (o.clock) |c| c() else 0;
}

/// Analyse `m`. Scratch is freed before returning, but on a model error (`.err`) the partly built
/// result slices and the error detail are not: pass an arena (server, UI, sweep do), or accept the
/// leak in a process that exits right after (CLI).
pub fn solve(a: Allocator, m: model.Model, opts: Options) !Outcome {
    const nn = m.nodes.len;
    const nm = m.members.len;

    // ── sorted views and validation ──
    const node_ids = try a.alloc(i64, nn);
    defer a.free(node_ids);
    for (m.nodes, 0..) |n, k| node_ids[k] = n.id;
    const node_src = try a.alloc(u32, nn);
    for (node_src, 0..) |*x, k| x.* = @intCast(k);
    std.mem.sort(u32, node_src, @as([]const i64, node_ids), lessId);
    // (guarded: `1..0` is an invalid range, and an empty model must reach `no_free_dofs`, not crash)
    if (nn > 1) for (1..nn) |k| if (node_ids[node_src[k]] == node_ids[node_src[k - 1]])
        return fail(a, "duplicate_id", "duplicate node id {d}", .{node_ids[node_src[k]]});

    const mem_ids = try a.alloc(i64, nm);
    defer a.free(mem_ids);
    for (m.members, 0..) |x, k| mem_ids[k] = x.id;
    const member_src = try a.alloc(u32, nm);
    for (member_src, 0..) |*x, k| x.* = @intCast(k);
    std.mem.sort(u32, member_src, @as([]const i64, mem_ids), lessId);
    if (nm > 1) for (1..nm) |k| if (mem_ids[member_src[k]] == mem_ids[member_src[k - 1]])
        return fail(a, "duplicate_id", "duplicate member id {d}", .{mem_ids[member_src[k]]});

    var node_map: std.AutoHashMapUnmanaged(i64, u32) = .empty;
    defer node_map.deinit(a);
    try node_map.ensureTotalCapacity(a, @intCast(nn));
    for (node_src, 0..) |src, k| node_map.putAssumeCapacity(node_ids[src], @intCast(k));
    var mem_map: std.AutoHashMapUnmanaged(i64, u32) = .empty;
    defer mem_map.deinit(a);
    try mem_map.ensureTotalCapacity(a, @intCast(nm));
    for (member_src, 0..) |src, k| mem_map.putAssumeCapacity(mem_ids[src], @intCast(k));

    // sorted node coordinates
    const xy = try a.alloc([2]f64, nn);
    defer a.free(xy);
    for (node_src, 0..) |src, k| xy[k] = .{ m.nodes[src].x, m.nodes[src].y };

    const elems = try a.alloc(Elem, nm);
    defer a.free(elems);
    for (member_src, 0..) |src, k| {
        const mb = m.members[src];
        const ni = node_map.get(mb.i) orelse return fail(a, "invalid_ref", "member {d} references missing node {d}", .{ mb.id, mb.i });
        const nj = node_map.get(mb.j) orelse return fail(a, "invalid_ref", "member {d} references missing node {d}", .{ mb.id, mb.j });
        var E: ?f64 = null;
        for (m.materials) |mat| if (std.mem.eql(u8, mat.id, mb.material)) {
            E = mat.E;
        };
        var sec: ?model.Section = null;
        for (m.sections) |s| if (std.mem.eql(u8, s.id, mb.section)) {
            sec = s;
        };
        if (E == null) return fail(a, "invalid_ref", "member {d} references missing material '{s}'", .{ mb.id, mb.material });
        if (sec == null) return fail(a, "invalid_ref", "member {d} references missing section '{s}'", .{ mb.id, mb.section });
        const dx = xy[nj][0] - xy[ni][0];
        const dy = xy[nj][1] - xy[ni][1];
        const L = @sqrt(dx * dx + dy * dy);
        elems[k] = .{ .ni = ni, .nj = nj, .E = E.?, .A = sec.?.A, .I = sec.?.I, .L = L, .c = 0, .s = 0 };
        if (mb.release) |rl| {
            elems[k].rel_i = model.hasMz(rl.i);
            elems[k].rel_j = model.hasMz(rl.j);
        }
    }
    for (elems, 0..) |*e, k| {
        if (!(e.L >= 1e-9)) return fail(a, "zero_length", "member {d} has length {e}", .{ mem_ids[member_src[k]], e.L });
        e.c = (xy[e.nj][0] - xy[e.ni][0]) / e.L;
        e.s = (xy[e.nj][1] - xy[e.ni][1]) / e.L;
    }

    const restr = try a.alloc([3]bool, nn);
    @memset(restr, .{ false, false, false });
    const supported = try a.alloc(bool, nn);
    @memset(supported, false);
    for (m.supports) |sp| {
        const k = node_map.get(sp.node) orelse return fail(a, "invalid_ref", "support references missing node {d}", .{sp.node});
        if (sp.ux) restr[k][0] = true;
        if (sp.uy) restr[k][1] = true;
        if (sp.rz) restr[k][2] = true;
        if (sp.ux or sp.uy or sp.rz) supported[k] = true;
    }

    // ── P2: springs (SPEC 4.7) ──
    const comp_names = [_][]const u8{ "ux", "uy", "rz" };
    const spring_k = try a.alloc([3]f64, nn);
    defer a.free(spring_k);
    @memset(spring_k, .{ 0, 0, 0 });
    var any_spring = false;
    for (m.springs) |sp| {
        const k = node_map.get(sp.node) orelse return fail(a, "invalid_ref", "spring references missing node {d}", .{sp.node});
        const ks = [3]?f64{ sp.kx, sp.ky, sp.kr };
        for (ks, 0..) |kv, c| if (kv) |v| {
            if (restr[k][c]) return fail(a, "support_conflict", "node {d} {s} is both restrained and sprung", .{ sp.node, comp_names[c] });
            spring_k[k][c] += v;
            any_spring = true;
        };
    }

    // ── P2: auto-restrain rotations that releases leave with zero stiffness (SPEC 4.7) ──
    var auto_list: std.ArrayList(u32) = .empty;
    {
        const n_inc = try a.alloc(u32, nn); // incident members
        defer a.free(n_inc);
        const n_rigid = try a.alloc(u32, nn); // incident members not released in mz at that end
        defer a.free(n_rigid);
        @memset(n_inc, 0);
        @memset(n_rigid, 0);
        var any_rel = false;
        for (elems) |e| {
            n_inc[e.ni] += 1;
            n_inc[e.nj] += 1;
            if (!e.rel_i) n_rigid[e.ni] += 1;
            if (!e.rel_j) n_rigid[e.nj] += 1;
            if (e.rel_i or e.rel_j) any_rel = true;
        }
        if (any_rel) for (0..nn) |v| {
            if (restr[v][2] or n_inc[v] == 0 or n_rigid[v] > 0 or spring_k[v][2] != 0) continue;
            restr[v][2] = true;
            try auto_list.append(a, @intCast(v));
        };
    }
    const auto_restrained = try auto_list.toOwnedSlice(a);
    for (m.load_cases) |lc| {
        for (lc.nodal) |p| if (node_map.get(p.node) == null)
            return fail(a, "invalid_ref", "load case '{s}' references missing node {d}", .{ lc.id, p.node });
        for (lc.member_udl) |u| if (mem_map.get(u.member) == null)
            return fail(a, "invalid_ref", "load case '{s}' references missing member {d}", .{ lc.id, u.member });
    }

    const t0 = now(opts);

    // ── DOF numbering and profile ──
    const dof = try a.alloc(u32, nn * 3);
    defer a.free(dof);
    var stats: Stats = .{ .nodes = nn, .members = nm };

    const first = try a.alloc(u32, nn * 3); // big enough for any numbering
    defer a.free(first);

    if (!opts.skip_profile_before) {
        const ident = try a.alloc(u32, nn);
        defer a.free(ident);
        for (ident, 0..) |*x, k| x.* = @intCast(k);
        const nf0 = numberDofs(ident, restr, dof);
        columnFirst(elems, dof, first[0..nf0]);
        stats.profile_before = solver.Skyline.profile(first[0..nf0]);
    }

    const edges = try a.alloc([2]u32, nm);
    defer a.free(edges);
    for (elems, 0..) |e, k| edges[k] = .{ e.ni, e.nj };
    const graph = try solver.Graph.build(a, nn, edges);
    defer graph.deinit(a);
    const order = try solver.rcm(a, graph);
    defer a.free(order);
    const nf = numberDofs(order, restr, dof);
    stats.free_dofs = nf;
    if (nf == 0) return fail(a, "no_free_dofs", "every DOF is restrained", .{});
    columnFirst(elems, dof, first[0..nf]);
    stats.profile_after = solver.Skyline.profile(first[0..nf]);

    // ── assembly ──
    var sky = try solver.Skyline.init(a, first[0..nf]);
    defer sky.deinit(a);
    for (elems) |e| {
        const kg = globalK(e);
        var ds: [6]u32 = undefined;
        for (0..3) |c| {
            ds[c] = dof[e.ni * 3 + c];
            ds[3 + c] = dof[e.nj * 3 + c];
        }
        for (0..6) |p| {
            const dp = ds[p];
            if (dp == NONE) continue;
            for (0..6) |q| {
                const dq = ds[q];
                if (dq == NONE or dp > dq) continue;
                sky.at(dp, dq).* += kg[p][q];
            }
        }
    }
    if (any_spring) for (0..nn) |v| for (0..3) |c| {
        const d = dof[v * 3 + c];
        if (d != NONE and spring_k[v][c] != 0) sky.at(d, d).* += spring_k[v][c];
    };
    const t1 = now(opts);
    stats.assemble_ms = t1 - t0;

    // ── factor once ──
    var bad: usize = 0;
    sky.factor(&bad) catch {
        for (0..nn) |v| for (0..3) |c| if (dof[v * 3 + c] == bad) {
            return fail(a, "unstable", "pivot failed at node {d} {s}", .{ node_ids[node_src[v]], comp_names[c] });
        };
        return fail(a, "unstable", "pivot failed", .{});
    };
    const t2 = now(opts);
    stats.factor_ms = t2 - t1;

    // ── solve each case ──
    const case_lo: usize = opts.only_case orelse 0;
    const case_hi: usize = if (opts.only_case) |c| c + 1 else m.load_cases.len;
    const cases = try a.alloc(CaseResult, case_hi - case_lo);
    // length scale for the moment residual: model bounding-box size (>= 1 m)
    var span: f64 = 1;
    if (nn > 0) {
        var lo_xy = xy[0];
        var hi_xy = xy[0];
        for (xy) |p| for (0..2) |c| {
            lo_xy[c] = @min(lo_xy[c], p[c]);
            hi_xy[c] = @max(hi_xy[c], p[c]);
        };
        span = @max(span, @max(hi_xy[0] - lo_xy[0], hi_xy[1] - lo_xy[1]));
    }
    const rhs = try a.alloc(f64, nf);
    defer a.free(rhs);
    const udl_w = try a.alloc(f64, nm);
    defer a.free(udl_w);
    const pnode = try a.alloc([3]f64, nn);
    defer a.free(pnode);

    for (case_lo..case_hi, 0..) |ci, out_i| {
        const lc = m.load_cases[ci];
        @memset(rhs, 0);
        @memset(udl_w, 0);
        @memset(pnode, .{ 0, 0, 0 });
        for (lc.nodal) |p| {
            const k = node_map.get(p.node).?;
            pnode[k][0] += p.fx;
            pnode[k][1] += p.fy;
            pnode[k][2] += p.mz;
        }
        for (lc.member_udl) |u| udl_w[mem_map.get(u.member).?] += u.w;
        for (0..nn) |v| for (0..3) |c| {
            const d = dof[v * 3 + c];
            if (d != NONE) rhs[d] += pnode[v][c];
        };
        for (elems, 0..) |e, k| {
            if (udl_w[k] == 0) continue;
            const eq = toGlobal(e, memberFixedEnd(e, udl_w[k]));
            for (0..3) |c| {
                const di = dof[e.ni * 3 + c];
                const dj = dof[e.nj * 3 + c];
                if (di != NONE) rhs[di] -= eq[c];
                if (dj != NONE) rhs[dj] -= eq[3 + c];
            }
        }
        sky.solve(rhs);

        const disp = try a.alloc([3]f64, nn);
        for (0..nn) |v| for (0..3) |c| {
            const d = dof[v * 3 + c];
            disp[v][c] = if (d == NONE) 0 else rhs[d];
        };
        const nodal_sum = try a.alloc([3]f64, nn);
        defer a.free(nodal_sum);
        @memset(nodal_sum, .{ 0, 0, 0 });
        const ef = try a.alloc([6]f64, nm);
        const st = try a.alloc([n_stations]Station, nm);
        var max_m: f64 = 0;
        var load_sum = [3]f64{ 0, 0, 0 }; // fx, fy, moment about origin
        var load_abs: f64 = 0;
        var mz_abs: f64 = 0; // applied nodal moments
        for (elems, 0..) |e, k| {
            const ug = [6]f64{ disp[e.ni][0], disp[e.ni][1], disp[e.ni][2], disp[e.nj][0], disp[e.nj][1], disp[e.nj][2] };
            const ul = toLocal(e, ug);
            const kl = localK(e);
            const w = udl_w[k];
            var f = if (w != 0) memberFixedEnd(e, w) else @as([6]f64, @splat(0));
            for (0..6) |r| {
                var sum: f64 = 0;
                for (0..6) |q| sum += kl[r][q] * ul[q];
                f[r] += sum;
            }
            ef[k] = f;
            const fg = toGlobal(e, f);
            for (0..3) |c| {
                nodal_sum[e.ni][c] += fg[c];
                nodal_sum[e.nj][c] += fg[3 + c];
            }
            for (0..n_stations) |q| {
                const x = e.L * @as(f64, @floatFromInt(q)) / (n_stations - 1);
                const s = Station{ .x = x, .N = -f[0], .V = f[1] + w * x, .M = -f[2] + f[1] * x + w * x * x / 2 };
                st[k][q] = s;
                max_m = @max(max_m, @abs(s.M));
            }
            if (w != 0) {
                // UDL resultant: w L along local y, at midspan
                const rx = -e.s * w * e.L;
                const ry = e.c * w * e.L;
                const mx = (xy[e.ni][0] + xy[e.nj][0]) / 2;
                const my = (xy[e.ni][1] + xy[e.nj][1]) / 2;
                load_sum[0] += rx;
                load_sum[1] += ry;
                load_sum[2] += mx * ry - my * rx;
                load_abs += @abs(w * e.L);
            }
        }
        const react = try a.alloc([3]f64, nn);
        for (0..nn) |v| {
            const p = pnode[v];
            load_sum[0] += p[0];
            load_sum[1] += p[1];
            load_sum[2] += p[2] + xy[v][0] * p[1] - xy[v][1] * p[0];
            load_abs += @abs(p[0]) + @abs(p[1]);
            mz_abs += @abs(p[2]);
            for (0..3) |c| react[v][c] = if (restr[v][c]) nodal_sum[v][c] - p[c] else 0;
            var r = react[v];
            // spring forces act on the structure like reactions: -k u
            for (0..3) |c| r[c] -= spring_k[v][c] * disp[v][c];
            load_sum[0] += r[0];
            load_sum[1] += r[1];
            load_sum[2] += r[2] + xy[v][0] * r[1] - xy[v][1] * r[0];
        }
        // SPEC 4.5: force balance and moment balance (about the origin); a moment is made relative
        // to (total load x model size) so both residuals are dimensionless.
        const scale = @max(load_abs, 1.0);
        const f_resid = @sqrt(load_sum[0] * load_sum[0] + load_sum[1] * load_sum[1]) / scale;
        const m_resid = @abs(load_sum[2]) / (scale * span + mz_abs);
        const resid = @max(f_resid, m_resid);
        cases[out_i] = .{ .id = lc.id, .disp = disp, .react = react, .end_forces = ef, .stations = st, .residual = resid, .max_abs_m = max_m };
    }
    stats.solve_ms = now(opts) - t2;

    return .{ .ok = .{
        .node_src = node_src,
        .member_src = member_src,
        .restrained = restr,
        .supported = supported,
        .auto_restrained = auto_restrained,
        .cases = cases,
        .stats = stats,
    } };
}

test "cantilever tip deflection (F01)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var nodes = [_]model.Node{ .{ .id = 1, .x = 0, .y = 0 }, .{ .id = 2, .x = 5, .y = 0 } };
    const m = model.Model{
        .materials = &.{.{ .id = "s", .E = 200e9 }},
        .sections = &.{.{ .id = "b", .A = 0.01, .I = 8e-5 }},
        .nodes = &nodes,
        .supports = &.{.{ .node = 1, .ux = true, .uy = true, .rz = true }},
        .members = &.{.{ .id = 1, .i = 1, .j = 2, .material = "s", .section = "b" }},
        .load_cases = &.{.{ .id = "P", .nodal = &.{.{ .node = 2, .fy = -10000 }} }},
    };
    const r = (try solve(a, m, .{})).ok;
    try std.testing.expectApproxEqRel(@as(f64, -0.02604166667), r.cases[0].disp[1][1], 1e-9);
    try std.testing.expectApproxEqRel(@as(f64, 50000), r.cases[0].react[0][2], 1e-9);
}

test "beam with no supports is unstable (F13)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var nodes = [_]model.Node{ .{ .id = 1, .x = 0, .y = 0 }, .{ .id = 2, .x = 5, .y = 0 } };
    const m = model.Model{
        .materials = &.{.{ .id = "s", .E = 200e9 }},
        .sections = &.{.{ .id = "b", .A = 0.01, .I = 8e-5 }},
        .nodes = &nodes,
        .members = &.{.{ .id = 1, .i = 1, .j = 2, .material = "s", .section = "b" }},
    };
    const o = try solve(arena.allocator(), m, .{});
    try std.testing.expectEqualStrings("unstable", o.err.code);
}

test "gen 10 10 profile matches the reference statistic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = try model.gen(arena.allocator(), 10, 10);
    const r = (try solve(arena.allocator(), m, .{})).ok;
    try std.testing.expectEqual(@as(u64, 10221), r.stats.profile_before);
    try std.testing.expectEqual(@as(u64, 7575), r.stats.profile_after);
    try std.testing.expectEqual(@as(usize, 330), r.stats.free_dofs);
}

test "P2: internal hinge, auto-restraint and support_conflict (F23-F25)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var nodes = [_]model.Node{ .{ .id = 1, .x = 0, .y = 0 }, .{ .id = 2, .x = 2.5, .y = 0 }, .{ .id = 3, .x = 5, .y = 0 } };
    const fixed = [_]model.Support{ .{ .node = 1, .ux = true, .uy = true, .rz = true }, .{ .node = 3, .ux = true, .uy = true, .rz = true } };
    const lcs = [_]model.LoadCase{.{ .id = "P", .nodal = &.{.{ .node = 2, .fy = -10000 }} }};
    var m = model.Model{
        .materials = &.{.{ .id = "s", .E = 200e9 }},
        .sections = &.{.{ .id = "b", .A = 0.01, .I = 8e-5 }},
        .nodes = &nodes,
        .supports = &fixed,
        .members = &.{
            .{ .id = 1, .i = 1, .j = 2, .material = "s", .section = "b", .release = .{ .j = &.{"mz"} } },
            .{ .id = 2, .i = 2, .j = 3, .material = "s", .section = "b" },
        },
        .load_cases = &lcs,
    };
    const r23 = (try solve(a, m, .{})).ok;
    try std.testing.expectApproxEqRel(@as(f64, -0.001627604167), r23.cases[0].disp[1][1], 1e-9);
    try std.testing.expectApproxEqRel(@as(f64, 12500), r23.cases[0].react[0][2], 1e-9);
    try std.testing.expectEqual(@as(usize, 0), r23.auto_restrained.len);

    m.members = &.{
        .{ .id = 1, .i = 1, .j = 2, .material = "s", .section = "b", .release = .{ .j = &.{"mz"} } },
        .{ .id = 2, .i = 2, .j = 3, .material = "s", .section = "b", .release = .{ .i = &.{"mz"} } },
    };
    const r24 = (try solve(a, m, .{})).ok;
    try std.testing.expectEqualSlices(u32, &.{1}, r24.auto_restrained);
    try std.testing.expectApproxEqRel(@as(f64, -0.001627604167), r24.cases[0].disp[1][1], 1e-9);
    try std.testing.expectEqual(@as(f64, 0), r24.cases[0].disp[1][2]);

    m.springs = &.{.{ .node = 3, .ky = 1e6 }};
    try std.testing.expectEqualStrings("support_conflict", (try solve(a, m, .{})).err.code);
}

test "empty and member-less models return model errors, not a crash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("no_free_dofs", (try solve(a, .{}, .{})).err.code);
    var one = [_]model.Node{.{ .id = 1, .x = 0, .y = 0 }};
    const fixed = model.Model{ .nodes = &one, .supports = &.{.{ .node = 1, .ux = true, .uy = true, .rz = true }} };
    try std.testing.expectEqualStrings("no_free_dofs", (try solve(a, fixed, .{})).err.code);
    try std.testing.expectEqualStrings("unstable", (try solve(a, .{ .nodes = &one }, .{})).err.code);
}

test "validation errors: duplicate_id, invalid_ref, zero_length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var nodes = [_]model.Node{ .{ .id = 1, .x = 0, .y = 0 }, .{ .id = 2, .x = 0, .y = 0 } };
    var m = model.Model{
        .materials = &.{.{ .id = "s", .E = 200e9 }},
        .sections = &.{.{ .id = "b", .A = 0.01, .I = 8e-5 }},
        .nodes = &nodes,
        .supports = &.{.{ .node = 1, .ux = true, .uy = true, .rz = true }},
        .members = &.{.{ .id = 1, .i = 1, .j = 2, .material = "s", .section = "b" }},
    };
    try std.testing.expectEqualStrings("zero_length", (try solve(a, m, .{})).err.code);
    m.members = &.{.{ .id = 1, .i = 1, .j = 3, .material = "s", .section = "b" }};
    try std.testing.expectEqualStrings("invalid_ref", (try solve(a, m, .{})).err.code);
    m.members = &.{.{ .id = 1, .i = 1, .j = 2, .material = "x", .section = "b" }};
    try std.testing.expectEqualStrings("invalid_ref", (try solve(a, m, .{})).err.code);
    nodes[1].id = 1;
    try std.testing.expectEqualStrings("duplicate_id", (try solve(a, m, .{})).err.code);
}

test "equilibrium residual covers moments (UDL + nodal moment, offset origin)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var nodes = [_]model.Node{ .{ .id = 1, .x = 100, .y = 50 }, .{ .id = 2, .x = 103, .y = 54 } };
    const m = model.Model{
        .materials = &.{.{ .id = "s", .E = 200e9 }},
        .sections = &.{.{ .id = "b", .A = 0.01, .I = 8e-5 }},
        .nodes = &nodes,
        .supports = &.{.{ .node = 1, .ux = true, .uy = true, .rz = true }},
        .members = &.{.{ .id = 1, .i = 1, .j = 2, .material = "s", .section = "b" }},
        .load_cases = &.{.{ .id = "L", .nodal = &.{.{ .node = 2, .fx = 3000, .mz = 5e4 }}, .member_udl = &.{.{ .member = 1, .w = -2000 }} }},
    };
    const r = (try solve(arena.allocator(), m, .{})).ok;
    try std.testing.expect(r.cases[0].residual < 1e-12);
    // cantilever: fixed-end moment balances every load's moment about node 1
    const mz_fix = r.cases[0].react[0][2];
    const udl_m = -2000.0 * 5.0 * 2.5; // w L at midspan, lever arm L/2 along the member (perpendicular load)
    try std.testing.expectApproxEqRel(-(5e4 + udl_m - 3000.0 * 4.0), mz_fix, 1e-9);
}
