//! Frame2D analysis engine (SPEC 4): validation, RCM ordering, skyline LDL^T, post-processing.
const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");
const util = @import("util.zig");
const Model = model.Model;
const Diag = model.Diag;

/// Relative pivot threshold of the factorization (SPEC 4.4).
const pivot_tol = 1e-12; // BENCH-EDIT:leaf

pub const Stats = struct {
    nodes: usize = 0,
    members: usize = 0,
    free_dofs: usize = 0,
    profile_before: usize = 0,
    profile_after: usize = 0,
    assemble_ms: f64 = 0,
    factor_ms: f64 = 0,
    solve_ms: f64 = 0,
};

pub const Case = struct { id: []const u8, nodal: []f64, w: []f64 };
const Rel = struct { i: bool, j: bool };
const Geom = struct { l: f64, c: f64, s: f64 };

/// Flat result buffers of one load case (caller-owned): nodes*3, nodes*3, members*6.
pub const CaseOut = struct {
    u: []f64 = &.{},
    react: []f64 = &.{},
    ef: []f64 = &.{},
    residual: f64 = 0,

    pub fn alloc(a: Allocator, p: *const Prepared) Allocator.Error!CaseOut {
        return .{
            .u = try a.alloc(f64, p.node_ids.len * 3),
            .react = try a.alloc(f64, p.node_ids.len * 3),
            .ef = try a.alloc(f64, p.mem_ids.len * 6),
        };
    }
};

/// A validated, indexed and ordered model, ready to solve repeatedly. Node coordinates may change
/// between solves (`setCoord`) without redoing the topology work. Lives in its own arena.
pub const Prepared = struct {
    arena: std.heap.ArenaAllocator,
    node_ids: []i64,
    node_src: []u32, // model index of each sorted node
    x: []f64,
    y: []f64,
    mem_ids: []i64,
    mem_src: []u32,
    mi: []u32,
    mj: []u32,
    m_e: []f64,
    m_a: []f64,
    m_i: []f64,
    dof_of: []i32, // nodes*3 -> free dof index or -1
    restr: []bool,
    auto_r: []bool, // restrained automatically (SPEC 4.7)
    spring: []f64,
    rel: []Rel,
    n_free: usize,
    warns: []i64, // node ids with an auto_restrained rz
    top: []u32, // per free dof: first row of its skyline column
    col_ptr: []usize, // per free dof: start of its column in vals
    vals: []f64,
    prof_before: usize,
    prof_after: usize,
    cases: []Case,
    // workspace reused by every solve
    geom: []Geom,
    bvec: []f64,
    loads: []f64,
    sum: []f64,
    ffix: [][6]f64,
    owns_topology: bool,

    pub fn deinit(self: *Prepared) void {
        var ar = self.arena;
        ar.deinit();
    }

    pub fn nodeCount(self: *const Prepared) usize {
        return self.node_ids.len;
    }

    pub fn memberCount(self: *const Prepared) usize {
        return self.mem_ids.len;
    }

    pub fn setCoord(self: *Prepared, k: usize, x: f64, y: f64) void {
        self.x[k] = x;
        self.y[k] = y;
    }

    /// Restrained by the user (auto-restrained DOFs are hidden, SPEC 4.7).
    pub fn restrained(self: *const Prepared, k: usize, d: usize) bool {
        return self.restr[k * 3 + d] and !self.auto_r[k * 3 + d];
    }

    pub fn memberLength(self: *const Prepared, m: usize) f64 {
        return std.math.hypot(self.x[self.mj[m]] - self.x[self.mi[m]], self.y[self.mj[m]] - self.y[self.mi[m]]);
    }

    /// Copy that shares the immutable topology but owns its stiffness values, workspace and section data,
    /// so it can be solved concurrently with the original (used by the sweep).
    pub fn fork(self: *const Prepared, gpa: Allocator) Allocator.Error!*Prepared {
        var ar = std.heap.ArenaAllocator.init(gpa);
        errdefer ar.deinit();
        const a = ar.allocator();
        const p = try a.create(Prepared);
        p.* = self.*;
        p.owns_topology = false;
        p.x = try a.dupe(f64, self.x);
        p.y = try a.dupe(f64, self.y);
        p.m_i = try a.dupe(f64, self.m_i);
        p.vals = try a.alloc(f64, self.vals.len);
        try p.allocWorkspace(a);
        p.arena = ar;
        return p;
    }

    fn allocWorkspace(self: *Prepared, a: Allocator) Allocator.Error!void {
        const nn = self.node_ids.len;
        const nm = self.mem_ids.len;
        self.geom = try a.alloc(Geom, nm);
        self.bvec = try a.alloc(f64, self.n_free);
        self.loads = try a.alloc(f64, nn * 3);
        self.sum = try a.alloc(f64, nn * 3);
        self.ffix = try a.alloc([6]f64, nm);
    }
};

// ---------------------------------------------------------------- preparation

fn idLess(ids: []const i64, a: u32, b: u32) bool {
    return ids[a] < ids[b];
}

const NodeSortCtx = struct {
    nodes: []const model.Node,
    fn less(self: NodeSortCtx, a: u32, b: u32) bool {
        return self.nodes[a].id < self.nodes[b].id;
    }
};

const MemberSortCtx = struct {
    members: []const model.Member,
    fn less(self: MemberSortCtx, a: u32, b: u32) bool {
        return self.members[a].id < self.members[b].id;
    }
};

fn findId(ids: []const i64, id: i64) ?usize {
    var lo: usize = 0;
    var hi: usize = ids.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (ids[mid] < id) lo = mid + 1 else hi = mid;
    }
    return if (lo < ids.len and ids[lo] == id) lo else null;
}

fn findStr(list: anytype, id: []const u8) ?usize {
    for (list, 0..) |x, k| if (std.mem.eql(u8, x.id, id)) return k;
    return null;
}

const dof_names = [3][]const u8{ "ux", "uy", "rz" };

pub fn prepare(gpa: Allocator, m: *const Model, d: *Diag) model.Error!*Prepared {
    var ar = std.heap.ArenaAllocator.init(gpa);
    errdefer ar.deinit();
    const a = ar.allocator();
    var scratch_arena = std.heap.ArenaAllocator.init(gpa);
    defer scratch_arena.deinit();
    const sa = scratch_arena.allocator();

    const p = try a.create(Prepared);
    p.owns_topology = true;
    const nn = m.nodes.len;
    const nm = m.members.len;

    // nodes sorted by id
    p.node_src = try a.alloc(u32, nn);
    for (p.node_src, 0..) |*s, k| s.* = @intCast(k);
    std.mem.sort(u32, p.node_src, NodeSortCtx{ .nodes = m.nodes }, NodeSortCtx.less);
    p.node_ids = try a.alloc(i64, nn);
    p.x = try a.alloc(f64, nn);
    p.y = try a.alloc(f64, nn);
    for (p.node_src, 0..) |src, k| {
        const n = m.nodes[src];
        if (k > 0 and p.node_ids[k - 1] == n.id) return d.set(.duplicate_id, "duplicate node id {d}", .{n.id});
        p.node_ids[k] = n.id;
        p.x[k] = n.x;
        p.y[k] = n.y;
    }

    for (m.materials, 0..) |x, k| for (m.materials[0..k]) |y| {
        if (std.mem.eql(u8, x.id, y.id)) return d.set(.duplicate_id, "duplicate material id \"{s}\"", .{x.id});
    };
    for (m.sections, 0..) |x, k| for (m.sections[0..k]) |y| {
        if (std.mem.eql(u8, x.id, y.id)) return d.set(.duplicate_id, "duplicate section id \"{s}\"", .{x.id});
    };

    // members sorted by id
    p.mem_src = try a.alloc(u32, nm);
    for (p.mem_src, 0..) |*s, k| s.* = @intCast(k);
    std.mem.sort(u32, p.mem_src, MemberSortCtx{ .members = m.members }, MemberSortCtx.less);
    p.mem_ids = try a.alloc(i64, nm);
    p.mi = try a.alloc(u32, nm);
    p.mj = try a.alloc(u32, nm);
    p.m_e = try a.alloc(f64, nm);
    p.m_a = try a.alloc(f64, nm);
    p.m_i = try a.alloc(f64, nm);
    p.rel = try a.alloc(Rel, nm);
    for (p.mem_src, 0..) |src, k| {
        const mb = m.members[src];
        if (k > 0 and p.mem_ids[k - 1] == mb.id) return d.set(.duplicate_id, "duplicate member id {d}", .{mb.id});
        const i = findId(p.node_ids, mb.i);
        const j = findId(p.node_ids, mb.j);
        if (i == null or j == null) return d.set(.invalid_ref, "member {d} references missing node", .{mb.id});
        const mat = findStr(m.materials, mb.material);
        const sec = findStr(m.sections, mb.section);
        if (mat == null or sec == null) return d.set(.invalid_ref, "member {d} references missing material or section", .{mb.id});
        p.mem_ids[k] = mb.id;
        p.mi[k] = @intCast(i.?);
        p.mj[k] = @intCast(j.?);
        p.m_e[k] = m.materials[mat.?].E;
        p.m_a[k] = m.sections[sec.?].A;
        p.m_i[k] = m.sections[sec.?].I;
        p.rel[k] = if (mb.release) |r| .{ .i = r.i_mz, .j = r.j_mz } else .{ .i = false, .j = false };
    }

    p.restr = try a.alloc(bool, nn * 3);
    @memset(p.restr, false);
    for (m.supports) |s| {
        const k = findId(p.node_ids, s.node) orelse return d.set(.invalid_ref, "support references missing node {d}", .{s.node});
        p.restr[k * 3] = p.restr[k * 3] or s.ux;
        p.restr[k * 3 + 1] = p.restr[k * 3 + 1] or s.uy;
        p.restr[k * 3 + 2] = p.restr[k * 3 + 2] or s.rz;
    }
    p.auto_r = try a.alloc(bool, nn * 3);
    @memset(p.auto_r, false);
    p.spring = try a.alloc(f64, nn * 3);
    @memset(p.spring, 0);
    for (m.springs) |sp| {
        const k = findId(p.node_ids, sp.node) orelse return d.set(.invalid_ref, "spring references missing node {d}", .{sp.node});
        const ks = [3]f64{ sp.kx, sp.ky, sp.kr };
        for (ks, 0..) |v, dd| {
            if (v == 0) continue;
            if (p.restr[k * 3 + dd]) return d.set(.support_conflict, "node {d} {s} is both restrained and sprung", .{ sp.node, dof_names[dd] });
            p.spring[k * 3 + dd] += v;
        }
    }

    // Auto-restraint (SPEC 4.7): a free rz with no stiffness because every attached member releases mz there.
    const attached = try sa.alloc(u32, nn);
    const released = try sa.alloc(u32, nn);
    @memset(attached, 0);
    @memset(released, 0);
    for (0..nm) |mm| {
        attached[p.mi[mm]] += 1;
        attached[p.mj[mm]] += 1;
        if (p.rel[mm].i) released[p.mi[mm]] += 1;
        if (p.rel[mm].j) released[p.mj[mm]] += 1;
    }
    var warns: util.List(i64) = .{};
    for (0..nn) |k| {
        if (!p.restr[k * 3 + 2] and p.spring[k * 3 + 2] == 0 and attached[k] > 0 and attached[k] == released[k]) {
            p.restr[k * 3 + 2] = true;
            p.auto_r[k * 3 + 2] = true;
            try warns.append(a, p.node_ids[k]);
        }
    }
    p.warns = warns.items();

    // load cases
    p.cases = try a.alloc(Case, m.load_cases.len);
    for (m.load_cases, 0..) |lc, ci| {
        const nodal = try a.alloc(f64, nn * 3);
        @memset(nodal, 0);
        const w = try a.alloc(f64, nm);
        @memset(w, 0);
        for (lc.nodal) |l| {
            const k = findId(p.node_ids, l.node) orelse return d.set(.invalid_ref, "load case \"{s}\" references missing node {d}", .{ lc.id, l.node });
            nodal[k * 3] += l.fx;
            nodal[k * 3 + 1] += l.fy;
            nodal[k * 3 + 2] += l.mz;
        }
        for (lc.udl) |l| {
            const k = findId(p.mem_ids, l.member) orelse return d.set(.invalid_ref, "load case \"{s}\" references missing member {d}", .{ lc.id, l.member });
            w[k] += l.w;
        }
        p.cases[ci] = .{ .id = lc.id, .nodal = nodal, .w = w };
    }

    // ordering and profiles
    const identity = try sa.alloc(u32, nn);
    for (identity, 0..) |*v, k| v.* = @intCast(k);
    const dof_tmp = try sa.alloc(i32, nn * 3);
    const top_tmp = try sa.alloc(u32, nn * 3);
    const nf0 = numberDofs(p, dof_tmp, identity);
    p.prof_before = skylineTop(p, dof_tmp, nf0, top_tmp);

    const order = try rcmOrder(sa, p, nn);
    p.dof_of = try a.alloc(i32, nn * 3);
    p.n_free = numberDofs(p, p.dof_of, order);
    p.top = try a.alloc(u32, p.n_free);
    p.prof_after = skylineTop(p, p.dof_of, p.n_free, p.top);
    if (p.n_free == 0) return d.set(.no_free_dofs, "every DOF is restrained", .{});
    p.col_ptr = try a.alloc(usize, p.n_free + 1);
    p.col_ptr[0] = 0;
    for (0..p.n_free) |j| p.col_ptr[j + 1] = p.col_ptr[j] + (j - p.top[j] + 1);
    p.vals = try a.alloc(f64, p.col_ptr[p.n_free]);
    @memset(p.vals, 0);
    try p.allocWorkspace(a);
    p.arena = ar;
    return p;
}

/// Assign free DOF indices walking nodes in `order`; returns the number of free DOFs.
fn numberDofsImpl(restr: []const bool, dof_of: []i32, order: []const u32) usize {
    var n: usize = 0;
    for (order) |k| {
        for (0..3) |dd| {
            if (restr[k * 3 + dd]) {
                dof_of[k * 3 + dd] = -1;
            } else {
                dof_of[k * 3 + dd] = @intCast(n);
                n += 1;
            }
        }
    }
    return n;
}

fn skylineTopImpl(p: *const Prepared, dof_of: []const i32, n_free: usize, top: []u32) usize {
    for (0..n_free) |j| top[j] = @intCast(j);
    var ds: [6]u32 = undefined;
    for (0..p.mem_ids.len) |mm| {
        var cnt: usize = 0;
        var lo: u32 = std.math.maxInt(u32);
        for ([2]u32{ p.mi[mm], p.mj[mm] }) |k| {
            for (0..3) |dd| {
                const q = dof_of[k * 3 + dd];
                if (q >= 0) {
                    ds[cnt] = @intCast(q);
                    cnt += 1;
                    if (@as(u32, @intCast(q)) < lo) lo = @intCast(q);
                }
            }
        }
        for (ds[0..cnt]) |q| if (lo < top[q]) {
            top[q] = lo;
        };
    }
    var prof: usize = 0;
    for (0..n_free) |j| prof += j - top[j];
    return prof;
}

// methods on Prepared declared here to keep the struct body short
fn numberDofs(p: *const Prepared, dof_of: []i32, order: []const u32) usize {
    return numberDofsImpl(p.restr, dof_of, order);
}
fn skylineTop(p: *const Prepared, dof_of: []const i32, n_free: usize, top: []u32) usize {
    return skylineTopImpl(p, dof_of, n_free, top);
}

// ------------------------------------------------------------------- RCM

const DegCtx = struct {
    start: []const u32,
    fn less(self: DegCtx, a: u32, b: u32) bool {
        const da = self.start[a + 1] - self.start[a];
        const db = self.start[b + 1] - self.start[b];
        if (da != db) return da < db;
        return a < b;
    }
};

fn u32Less(_: void, a: u32, b: u32) bool {
    return a < b;
}

/// Deterministic reverse Cuthill-McKee (SPEC 4.4) over the member graph; returns node indices in final order.
fn rcmOrder(sa: Allocator, p: *const Prepared, n: usize) Allocator.Error![]u32 {
    const nm = p.mem_ids.len;
    // CSR adjacency, sorted and de-duplicated
    const start = try sa.alloc(u32, n + 1);
    @memset(start, 0);
    for (0..nm) |mm| {
        if (p.mi[mm] == p.mj[mm]) continue;
        start[p.mi[mm] + 1] += 1;
        start[p.mj[mm] + 1] += 1;
    }
    for (0..n) |k| start[k + 1] += start[k];
    const raw = try sa.alloc(u32, start[n]);
    const fill = try sa.alloc(u32, n);
    @memcpy(fill, start[0..n]);
    for (0..nm) |mm| {
        const i = p.mi[mm];
        const j = p.mj[mm];
        if (i == j) continue;
        raw[fill[i]] = j;
        fill[i] += 1;
        raw[fill[j]] = i;
        fill[j] += 1;
    }
    const cstart = try sa.alloc(u32, n + 1);
    var w: u32 = 0;
    for (0..n) |k| {
        cstart[k] = w;
        const row = raw[start[k]..start[k + 1]];
        std.mem.sort(u32, row, {}, u32Less);
        for (row, 0..) |v, q| {
            if (q == 0 or v != row[q - 1]) {
                raw[w] = v;
                w += 1;
            }
        }
    }
    cstart[n] = w;
    const adj = raw[0..w];
    const deg_ctx = DegCtx{ .start = cstart };

    const order = try sa.alloc(u32, n);
    var olen: usize = 0;
    const visited = try sa.alloc(bool, n);
    const placed = try sa.alloc(bool, n);
    @memset(visited, false);
    @memset(placed, false);
    const mark = try sa.alloc(u32, n);
    @memset(mark, 0);
    const queue = try sa.alloc(u32, n);
    const comp = try sa.alloc(u32, n);
    var max_deg: usize = 0;
    for (0..n) |k| max_deg = @max(max_deg, cstart[k + 1] - cstart[k]);
    const nb = try sa.alloc(u32, max_deg);
    var stamp: u32 = 0;

    const Bfs = struct { lo: usize, hi: usize, ecc: u32 };
    const S = struct {
        fn bfsLast(root: u32, st: *u32, mk: []u32, q: []u32, cs: []const u32, ad: []const u32) Bfs {
            st.* += 1;
            mk[root] = st.*;
            q[0] = root;
            var head: usize = 0;
            var tail: usize = 1;
            var level_start: usize = 0;
            var ecc: u32 = 0;
            while (true) {
                const level_end = tail;
                while (head < level_end) {
                    const v = q[head];
                    head += 1;
                    for (ad[cs[v]..cs[v + 1]]) |nbr| {
                        if (mk[nbr] != st.*) {
                            mk[nbr] = st.*;
                            q[tail] = nbr;
                            tail += 1;
                        }
                    }
                }
                if (tail == level_end) return .{ .lo = level_start, .hi = level_end, .ecc = ecc };
                level_start = level_end;
                ecc += 1;
            }
        }

        fn minDeg(vs: []const u32, ctx: DegCtx) u32 {
            var best = vs[0];
            for (vs[1..]) |v| if (ctx.less(v, best)) {
                best = v;
            };
            return best;
        }
    };

    for (0..n) |s| { // ascending min node id of each component
        if (visited[s]) continue;
        var clen: usize = 1;
        comp[0] = @intCast(s);
        visited[s] = true;
        var kk: usize = 0;
        while (kk < clen) : (kk += 1) {
            for (adj[cstart[comp[kk]]..cstart[comp[kk] + 1]]) |nbr| {
                if (!visited[nbr]) {
                    visited[nbr] = true;
                    comp[clen] = nbr;
                    clen += 1;
                }
            }
        }
        var root = S.minDeg(comp[0..clen], deg_ctx);
        var ecc = S.bfsLast(root, &stamp, mark, queue, cstart, adj).ecc;
        while (true) {
            const last = S.bfsLast(root, &stamp, mark, queue, cstart, adj);
            const cand = S.minDeg(queue[last.lo..last.hi], deg_ctx);
            const e2 = S.bfsLast(cand, &stamp, mark, queue, cstart, adj).ecc;
            if (e2 > ecc) {
                root = cand;
                ecc = e2;
            } else break;
        }
        // Cuthill-McKee BFS
        const first = olen;
        order[olen] = root;
        olen += 1;
        placed[root] = true;
        var h = first;
        while (h < olen) : (h += 1) {
            const v = order[h];
            var cnt: usize = 0;
            for (adj[cstart[v]..cstart[v + 1]]) |nbr| {
                if (!placed[nbr]) {
                    nb[cnt] = nbr;
                    cnt += 1;
                }
            }
            std.mem.sort(u32, nb[0..cnt], deg_ctx, DegCtx.less);
            for (nb[0..cnt]) |nbr| {
                placed[nbr] = true;
                order[olen] = nbr;
                olen += 1;
            }
        }
    }
    std.mem.reverse(u32, order);
    return order;
}

// ------------------------------------------------------------------- element matrices

const K6 = [6][6]f64;

fn rawK(p: *const Prepared, m: usize, l: f64, k: *K6) void {
    k.* = std.mem.zeroes(K6);
    const ea = p.m_e[m] * p.m_a[m] / l;
    const ei = p.m_e[m] * p.m_i[m];
    const l2 = l * l;
    const l3 = l2 * l;
    const a = 12 * ei / l3;
    const b = 6 * ei / l2;
    const c = 4 * ei / l;
    const dd = 2 * ei / l;
    k[0][0] = ea;
    k[0][3] = -ea;
    k[3][0] = -ea;
    k[3][3] = ea;
    k[1][1] = a;
    k[1][2] = b;
    k[1][4] = -a;
    k[1][5] = b;
    k[2][1] = b;
    k[2][2] = c;
    k[2][4] = -b;
    k[2][5] = dd;
    k[4][1] = -a;
    k[4][2] = -b;
    k[4][4] = a;
    k[4][5] = -b;
    k[5][1] = b;
    k[5][2] = dd;
    k[5][4] = -b;
    k[5][5] = c;
}

/// Static condensation of released rotations (local dof 2 at i, 5 at j) from k and, if given, f.
fn condense(rel: Rel, k: *K6, f: ?*[6]f64) void {
    const rows = [2]usize{ 2, 5 };
    const flags = [2]bool{ rel.i, rel.j };
    for (rows, flags) |r, on| {
        if (!on) continue;
        const piv = k[r][r];
        if (piv == 0) continue;
        var col: [6]f64 = undefined;
        for (0..6) |i| col[i] = k[i][r];
        for (0..6) |i| for (0..6) |j| {
            k[i][j] -= col[i] * k[r][j] / piv;
        };
        if (f) |ff| {
            const fr = ff[r];
            for (0..6) |i| ff[i] -= col[i] * fr / piv;
            ff[r] = 0;
        }
        for (0..6) |i| {
            k[i][r] = 0;
            k[r][i] = 0;
        }
    }
}

fn localK(p: *const Prepared, m: usize, l: f64, k: *K6) void {
    rawK(p, m, l, k);
    condense(p.rel[m], k, null);
}

fn fixedEnd(w: f64, l: f64) [6]f64 {
    return .{ 0, -w * l / 2, -w * l * l / 12, 0, -w * l / 2, w * l * l / 12 };
}

fn fixedEndM(p: *const Prepared, m: usize, w: f64, l: f64) [6]f64 {
    var f = fixedEnd(w, l);
    if (p.rel[m].i or p.rel[m].j) {
        var k: K6 = undefined;
        rawK(p, m, l, &k);
        condense(p.rel[m], &k, &f);
    }
    return f;
}

/// local = T g (to_local) or g = T^T local.
fn rotate(g: Geom, v: *const [6]f64, to_local: bool) [6]f64 {
    var o: [6]f64 = undefined;
    const c = g.c;
    const s = if (to_local) g.s else -g.s;
    var e: usize = 0;
    while (e < 6) : (e += 3) {
        o[e] = c * v[e] + s * v[e + 1];
        o[e + 1] = -s * v[e] + c * v[e + 1];
        o[e + 2] = v[e + 2];
    }
    return o;
}

// ------------------------------------------------------------------- solve

fn dot(a: []const f64, b: []const f64) f64 {
    const V = @Vector(4, f64);
    const n = a.len;
    var acc: V = @splat(0);
    var i: usize = 0;
    while (i + 4 <= n) : (i += 4) {
        const x: V = a[i..][0..4].*;
        const y: V = b[i..][0..4].*;
        acc += x * y;
    }
    var s = @reduce(.Add, acc);
    while (i < n) : (i += 1) s += a[i] * b[i];
    return s;
}

fn computeGeometry(p: *Prepared, d: *Diag) model.Error!void {
    for (p.geom, 0..) |*g, m| {
        const dx = p.x[p.mj[m]] - p.x[p.mi[m]];
        const dy = p.y[p.mj[m]] - p.y[p.mi[m]];
        const l = std.math.hypot(dx, dy);
        if (l < 1e-9) return d.set(.zero_length, "member {d} has zero length", .{p.mem_ids[m]});
        g.* = .{ .l = l, .c = dx / l, .s = dy / l };
    }
}

/// Assemble, factor once and solve the load cases. `only` restricts the solve to one case (others are
/// left untouched); otherwise every case needs buffers in `outs` (len == number of cases).
pub fn solve(p: *Prepared, only: ?usize, outs: []CaseOut, st: *Stats, d: *Diag) model.Error!void {
    try computeGeometry(p, d);
    const nn = p.node_ids.len;
    const nm = p.mem_ids.len;
    const n = p.n_free;

    const t0 = util.nowMs();
    const vals = p.vals;
    @memset(vals, 0);
    var kl: K6 = undefined;
    var kg: K6 = undefined;
    var tmp: K6 = undefined;
    var gd: [6]i32 = undefined;
    for (0..nm) |m| {
        const g = p.geom[m];
        localK(p, m, g.l, &kl);
        for (0..6) |r| {
            var e: usize = 0;
            while (e < 6) : (e += 3) {
                tmp[r][e] = kl[r][e] * g.c - kl[r][e + 1] * g.s;
                tmp[r][e + 1] = kl[r][e] * g.s + kl[r][e + 1] * g.c;
                tmp[r][e + 2] = kl[r][e + 2];
            }
        }
        for (0..6) |ci| {
            var e: usize = 0;
            while (e < 6) : (e += 3) {
                kg[e][ci] = g.c * tmp[e][ci] - g.s * tmp[e + 1][ci];
                kg[e + 1][ci] = g.s * tmp[e][ci] + g.c * tmp[e + 1][ci];
                kg[e + 2][ci] = tmp[e + 2][ci];
            }
        }
        for (0..3) |dd| {
            gd[dd] = p.dof_of[p.mi[m] * 3 + dd];
            gd[3 + dd] = p.dof_of[p.mj[m] * 3 + dd];
        }
        for (0..6) |ra| {
            if (gd[ra] < 0) continue;
            const ia: usize = @intCast(gd[ra]);
            for (0..6) |rb| {
                if (gd[rb] < ia) continue;
                const ib: usize = @intCast(gd[rb]);
                vals[p.col_ptr[ib] + ia - p.top[ib]] += kg[ra][rb];
            }
        }
    }
    for (p.dof_of, 0..) |q, k| {
        if (q >= 0 and p.spring[k] != 0) vals[p.col_ptr[@as(usize, @intCast(q)) + 1] - 1] += p.spring[k];
    }
    var max_diag: f64 = 0;
    for (0..n) |j| {
        const dv = vals[p.col_ptr[j + 1] - 1];
        if (dv > max_diag) max_diag = dv;
    }
    const t_asm = util.nowMs();

    try factor(p, max_diag, d);
    const t_fac = util.nowMs();

    const b = p.bvec;
    for (p.cases, 0..) |*pc, ci| {
        if (only) |o| if (ci != o) continue;
        const co = &outs[ci];
        @memcpy(p.loads, pc.nodal);
        @memset(p.ffix, std.mem.zeroes([6]f64));
        for (0..nm) |m| {
            if (pc.w[m] == 0) continue;
            const f = fixedEndM(p, m, pc.w[m], p.geom[m].l);
            p.ffix[m] = f;
            const fg = rotate(p.geom[m], &f, false);
            for (0..3) |dd| {
                p.loads[p.mi[m] * 3 + dd] -= fg[dd];
                p.loads[p.mj[m] * 3 + dd] -= fg[3 + dd];
            }
        }
        for (p.dof_of, 0..) |q, k| if (q >= 0) {
            b[@intCast(q)] = p.loads[k];
        };
        solveInPlace(p, b);
        for (p.dof_of, 0..) |q, k| {
            co.u[k] = if (q >= 0) b[@intCast(q)] else 0;
        }
        @memset(co.react, 0);
        @memset(p.sum, 0);
        for (0..nm) |m| {
            const g = p.geom[m];
            var ug: [6]f64 = undefined;
            for (0..3) |dd| {
                ug[dd] = co.u[p.mi[m] * 3 + dd];
                ug[3 + dd] = co.u[p.mj[m] * 3 + dd];
            }
            const ul = rotate(g, &ug, true);
            localK(p, m, g.l, &kl);
            var f: [6]f64 = undefined;
            for (0..6) |r| {
                var s = p.ffix[m][r];
                for (0..6) |c| s += kl[r][c] * ul[c];
                f[r] = s;
            }
            @memcpy(co.ef[m * 6 ..][0..6], &f);
            const fg = rotate(g, &f, false);
            for (0..3) |dd| {
                p.sum[p.mi[m] * 3 + dd] += fg[dd];
                p.sum[p.mj[m] * 3 + dd] += fg[3 + dd];
            }
        }
        var rx: f64 = 0;
        var ry: f64 = 0;
        var scale: f64 = 0;
        for (0..nn) |k| {
            for (0..3) |dd| if (p.restr[k * 3 + dd]) {
                co.react[k * 3 + dd] = p.sum[k * 3 + dd] - pc.nodal[k * 3 + dd];
            };
            const sx = -p.spring[k * 3] * co.u[k * 3];
            const sy = -p.spring[k * 3 + 1] * co.u[k * 3 + 1];
            rx += co.react[k * 3] + pc.nodal[k * 3] + sx;
            ry += co.react[k * 3 + 1] + pc.nodal[k * 3 + 1] + sy;
            scale += @abs(co.react[k * 3]) + @abs(co.react[k * 3 + 1]) + @abs(pc.nodal[k * 3]) + @abs(pc.nodal[k * 3 + 1]);
        }
        for (0..nm) |m| {
            const w = pc.w[m];
            if (w != 0) {
                const wl = w * p.geom[m].l;
                rx += -p.geom[m].s * wl;
                ry += p.geom[m].c * wl;
                scale += @abs(wl);
            }
        }
        co.residual = std.math.hypot(rx, ry) / @max(scale, 1);
    }
    const t_end = util.nowMs();
    st.* = .{
        .nodes = nn,
        .members = nm,
        .free_dofs = n,
        .profile_before = p.prof_before,
        .profile_after = p.prof_after,
        .assemble_ms = t_asm - t0,
        .factor_ms = t_fac - t_asm,
        .solve_ms = t_end - t_fac,
    };
}

/// In-place skyline LDL^T. Afterwards off-diagonals of column j hold U (unit upper) and the diagonal holds D.
fn factor(p: *Prepared, max_diag: f64, d: *Diag) model.Error!void {
    const a = p.vals;
    const top = p.top;
    const cp = p.col_ptr;
    for (0..p.n_free) |j| {
        const mj: usize = top[j];
        const cj = cp[j];
        var i = mj + 1;
        while (i < j) : (i += 1) {
            const ti: usize = top[i];
            const lo = @max(ti, mj);
            const ci = cp[i];
            a[cj + i - mj] -= dot(a[ci + lo - ti .. ci + i - ti], a[cj + lo - mj .. cj + i - mj]);
        }
        var dv = a[cp[j + 1] - 1];
        i = mj;
        while (i < j) : (i += 1) {
            const g = a[cj + i - mj];
            const u = g / a[cp[i + 1] - 1];
            a[cj + i - mj] = u;
            dv -= u * g;
        }
        if (!(dv > pivot_tol * max_diag)) return unstable(p, j, d);
        a[cp[j + 1] - 1] = dv;
    }
}

fn unstable(p: *const Prepared, dof: usize, d: *Diag) error{Model} {
    for (p.dof_of, 0..) |q, k| {
        if (q >= 0 and @as(usize, @intCast(q)) == dof) {
            return d.set(.unstable, "pivot failed at node {d} {s}", .{ p.node_ids[k / 3], dof_names[k % 3] });
        }
    }
    return d.set(.unstable, "pivot failed at dof {d}", .{dof});
}

fn solveInPlace(p: *const Prepared, b: []f64) void {
    const a = p.vals;
    const top = p.top;
    const cp = p.col_ptr;
    const n = p.n_free;
    for (0..n) |j| { // forward: U^T y = b
        const mj: usize = top[j];
        b[j] -= dot(a[cp[j] .. cp[j] + j - mj], b[mj..j]);
    }
    for (0..n) |j| b[j] /= a[cp[j + 1] - 1]; // D z = y
    var j = n;
    while (j > 0) { // back: U x = z
        j -= 1;
        const mj: usize = top[j];
        const bj = b[j];
        const col = a[cp[j] .. cp[j] + j - mj];
        const dst = b[mj..j];
        for (col, dst) |u, *x| x.* -= u * bj;
    }
}

// ------------------------------------------------------------------- stations

pub const Station = struct { x: f64, n: f64, v: f64, m: f64 };

/// N, V, M at station k (0..10) of a member with end forces `ef` and UDL `w` (SPEC 4.5).
pub fn station(w: f64, ef: []const f64, l: f64, k: usize) Station {
    const x = l * @as(f64, @floatFromInt(k)) / 10;
    return .{ .x = x, .n = -ef[0], .v = ef[1] + w * x, .m = -ef[2] + ef[1] * x + w * x * x / 2 };
}

/// Largest |M| over the 11 stations.
pub fn maxAbsM(w: f64, ef: []const f64, l: f64) f64 {
    var mx: f64 = 0;
    for (0..11) |k| mx = @max(mx, @abs(station(w, ef, l, k).m));
    return mx;
}
