//! Frame2D analysis engine (SPEC 4): RCM ordering, skyline LDL^T, post-processing.
//! Pure Zig, no OS dependencies, so it also builds for wasm32-freestanding.
const std = @import("std");
const Allocator = std.mem.Allocator;
const model_mod = @import("model.zig");
const Model = model_mod.Model;

/// Clock hook (nanoseconds). Front ends install a real clock; the engine only uses it for `stats`.
pub var clock_ns: *const fn () u64 = zeroClock;
fn zeroClock() u64 {
    return 0;
}

pub const Code = enum {
    invalid_ref,
    zero_length,
    duplicate_id,
    unstable,
    no_free_dofs,
};

/// Filled in when `solve` returns `error.ModelError`.
pub const ErrorInfo = struct {
    code: Code = .invalid_ref,
    detail_buf: [200]u8 = undefined,
    detail_len: usize = 0,

    pub fn detail(self: *const ErrorInfo) []const u8 {
        return self.detail_buf[0..self.detail_len];
    }

    fn set(self: *ErrorInfo, code: Code, comptime fmt: []const u8, args: anytype) error{ModelError} {
        self.code = code;
        const s = std.fmt.bufPrint(&self.detail_buf, fmt, args) catch self.detail_buf[0..0];
        self.detail_len = s.len;
        return error.ModelError;
    }
};

pub const SolveError = error{ ModelError, OutOfMemory };

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

pub const Reaction = struct { node: u32, f: [3]f64 };

pub const CaseResult = struct {
    id: []const u8,
    /// 3 per node (ux, uy, rz), nodes sorted by id.
    u: []f64,
    reactions: []Reaction,
    /// 6 per member (local, acting on the member), members sorted by id.
    end_forces: []f64,
    /// Total UDL per member (local y).
    w: []f64,
    residual: f64,
};

pub const Results = struct {
    gpa: Allocator,
    cases: []CaseResult,
    /// Member length per member (sorted by id).
    length: []f64,
    stats: Stats,

    pub fn deinit(self: *Results) void {
        for (self.cases) |c| freeCase(self.gpa, c);
        self.gpa.free(self.cases);
        self.gpa.free(self.length);
        self.* = undefined;
    }
};

fn freeCase(gpa: Allocator, c: CaseResult) void {
    gpa.free(c.u);
    gpa.free(c.reactions);
    gpa.free(c.end_forces);
    gpa.free(c.w);
}

// ------------------------------------------------------------------ model preparation

fn nodeLess(_: void, a: model_mod.Node, b: model_mod.Node) bool {
    return a.id < b.id;
}
fn memberLess(_: void, a: model_mod.Member, b: model_mod.Member) bool {
    return a.id < b.id;
}

/// Sorts nodes and members by id in place and rejects duplicates.
pub fn normalize(m: *Model, err: *ErrorInfo) error{ModelError}!void {
    if (!std.sort.isSorted(model_mod.Node, m.nodes, {}, nodeLess)) std.sort.pdq(model_mod.Node, m.nodes, {}, nodeLess);
    if (!std.sort.isSorted(model_mod.Member, m.members, {}, memberLess)) std.sort.pdq(model_mod.Member, m.members, {}, memberLess);
    for (m.nodes, 0..) |n, k| {
        if (k > 0 and m.nodes[k - 1].id == n.id) return err.set(.duplicate_id, "duplicate node id {d}", .{n.id});
    }
    for (m.members, 0..) |n, k| {
        if (k > 0 and m.members[k - 1].id == n.id) return err.set(.duplicate_id, "duplicate member id {d}", .{n.id});
    }
}

pub fn findNode(nodes: []const model_mod.Node, id: i64) ?u32 {
    var lo: usize = 0;
    var hi: usize = nodes.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (nodes[mid].id < id) lo = mid + 1 else hi = mid;
    }
    if (lo < nodes.len and nodes[lo].id == id) return @intCast(lo);
    return null;
}

pub fn findMember(members: []const model_mod.Member, id: i64) ?u32 {
    var lo: usize = 0;
    var hi: usize = members.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (members[mid].id < id) lo = mid + 1 else hi = mid;
    }
    if (lo < members.len and members[lo].id == id) return @intCast(lo);
    return null;
}

const Geometry = struct {
    mi: []u32,
    mj: []u32,
    len: []f64,
    c: []f64,
    s: []f64,
    ea: []f64,
    ei: []f64,
    /// bit mask of restrained dofs per node (bit0 ux, bit1 uy, bit2 rz)
    fixed: []u8,

    fn init(gpa: Allocator, n: usize, m: usize) !Geometry {
        const mi = try gpa.alloc(u32, m);
        errdefer gpa.free(mi);
        const mj = try gpa.alloc(u32, m);
        errdefer gpa.free(mj);
        const len = try gpa.alloc(f64, m);
        errdefer gpa.free(len);
        const c = try gpa.alloc(f64, m);
        errdefer gpa.free(c);
        const s = try gpa.alloc(f64, m);
        errdefer gpa.free(s);
        const ea = try gpa.alloc(f64, m);
        errdefer gpa.free(ea);
        const ei = try gpa.alloc(f64, m);
        errdefer gpa.free(ei);
        const fixed = try gpa.alloc(u8, n);
        @memset(fixed, 0);
        return .{ .mi = mi, .mj = mj, .len = len, .c = c, .s = s, .ea = ea, .ei = ei, .fixed = fixed };
    }

    fn deinit(g: Geometry, gpa: Allocator) void {
        gpa.free(g.mi);
        gpa.free(g.mj);
        gpa.free(g.len);
        gpa.free(g.c);
        gpa.free(g.s);
        gpa.free(g.ea);
        gpa.free(g.ei);
        gpa.free(g.fixed);
    }
};

fn buildGeometry(gpa: Allocator, m: *const Model, err: *ErrorInfo) SolveError!Geometry {
    const g = try Geometry.init(gpa, m.nodes.len, m.members.len);
    errdefer g.deinit(gpa);
    for (m.members, 0..) |mem, k| {
        const a = findNode(m.nodes, mem.i) orelse
            return err.set(.invalid_ref, "member {d} references missing node {d}", .{ mem.id, mem.i });
        const b = findNode(m.nodes, mem.j) orelse
            return err.set(.invalid_ref, "member {d} references missing node {d}", .{ mem.id, mem.j });
        var mat: ?usize = null;
        for (m.materials, 0..) |x, q| {
            if (std.mem.eql(u8, x.id, mem.material)) {
                mat = q;
                break;
            }
        }
        const mat_i = mat orelse return err.set(.invalid_ref, "member {d} references missing material '{s}'", .{ mem.id, mem.material });
        var sec: ?usize = null;
        for (m.sections, 0..) |x, q| {
            if (std.mem.eql(u8, x.id, mem.section)) {
                sec = q;
                break;
            }
        }
        const sec_i = sec orelse return err.set(.invalid_ref, "member {d} references missing section '{s}'", .{ mem.id, mem.section });
        const dx = m.nodes[b].x - m.nodes[a].x;
        const dy = m.nodes[b].y - m.nodes[a].y;
        const l = @sqrt(dx * dx + dy * dy);
        if (!(l >= 1e-9)) return err.set(.zero_length, "member {d} has zero length", .{mem.id});
        g.mi[k] = a;
        g.mj[k] = b;
        g.len[k] = l;
        g.c[k] = dx / l;
        g.s[k] = dy / l;
        g.ea[k] = m.materials[mat_i].E * m.sections[sec_i].A;
        g.ei[k] = m.materials[mat_i].E * m.sections[sec_i].I;
    }
    for (m.supports) |sp| {
        const nd = findNode(m.nodes, sp.node) orelse
            return err.set(.invalid_ref, "support references missing node {d}", .{sp.node});
        g.fixed[nd] |= @as(u8, @intFromBool(sp.ux)) | (@as(u8, @intFromBool(sp.uy)) << 1) | (@as(u8, @intFromBool(sp.rz)) << 2);
    }
    for (m.load_cases) |lc| {
        for (lc.nodal) |ld| {
            _ = findNode(m.nodes, ld.node) orelse
                return err.set(.invalid_ref, "load case '{s}' references missing node {d}", .{ lc.id, ld.node });
        }
        for (lc.member_udl) |ld| {
            _ = findMember(m.members, ld.member) orelse
                return err.set(.invalid_ref, "load case '{s}' references missing member {d}", .{ lc.id, ld.member });
        }
    }
    return g;
}

// ------------------------------------------------------------------ reverse Cuthill-McKee (SPEC 4.4)

const Graph = struct {
    off: []u32,
    buf: []u32, // allocation backing `adj`
    adj: []u32,

    fn deinit(self: Graph, gpa: Allocator) void {
        gpa.free(self.off);
        gpa.free(self.buf);
    }
    fn deg(self: Graph, v: u32) u32 {
        return self.off[v + 1] - self.off[v];
    }
    fn neighbors(self: Graph, v: u32) []const u32 {
        return self.adj[self.off[v]..self.off[v + 1]];
    }
};

fn buildGraph(gpa: Allocator, n: usize, g: *const Geometry) !Graph {
    const m = g.mi.len;
    const off = try gpa.alloc(u32, n + 1);
    errdefer gpa.free(off);
    @memset(off, 0);
    for (0..m) |k| {
        off[g.mi[k] + 1] += 1;
        off[g.mj[k] + 1] += 1;
    }
    for (0..n) |v| off[v + 1] += off[v];
    const buf = try gpa.alloc(u32, off[n]);
    errdefer gpa.free(buf);
    const fill = try gpa.alloc(u32, n);
    defer gpa.free(fill);
    @memcpy(fill, off[0..n]);
    for (0..m) |k| {
        buf[fill[g.mi[k]]] = g.mj[k];
        fill[g.mi[k]] += 1;
        buf[fill[g.mj[k]]] = g.mi[k];
        fill[g.mj[k]] += 1;
    }
    // sort and dedupe each list, compacting in place
    var w: u32 = 0;
    var start: u32 = 0;
    for (0..n) |v| {
        const end = off[v + 1];
        const list = buf[start..end];
        std.sort.pdq(u32, list, {}, std.sort.asc(u32));
        const new_start = w;
        var prev: ?u32 = null;
        for (list) |x| {
            if (prev == null or prev.? != x) {
                buf[w] = x;
                w += 1;
                prev = x;
            }
        }
        start = end;
        off[v] = new_start;
    }
    off[n] = w;
    return .{ .off = off, .buf = buf, .adj = buf[0..w] };
}

const Rcm = struct {
    graph: Graph,
    stamp: []u32,
    cur: u32 = 0,
    queue: []u32,
    level: []u32,

    /// BFS from `root`; fills queue[0..count] and level[]; returns count. Uses stamps so no clearing.
    fn bfs(self: *Rcm, root: u32) usize {
        self.cur += 1;
        self.stamp[root] = self.cur;
        self.level[root] = 0;
        self.queue[0] = root;
        var head: usize = 0;
        var tail: usize = 1;
        while (head < tail) {
            const v = self.queue[head];
            head += 1;
            for (self.graph.neighbors(v)) |w| {
                if (self.stamp[w] != self.cur) {
                    self.stamp[w] = self.cur;
                    self.level[w] = self.level[v] + 1;
                    self.queue[tail] = w;
                    tail += 1;
                }
            }
        }
        return tail;
    }

    /// a sorts before b in (degree, id) order
    fn before(self: *const Rcm, a: u32, b: u32) bool {
        const da = self.graph.deg(a);
        const db = self.graph.deg(b);
        return da < db or (da == db and a < b);
    }

    /// George-Liu pseudo-peripheral node search starting at `start`.
    fn pseudoPeripheral(self: *Rcm, start: u32) u32 {
        var count = self.bfs(start);
        var root = start;
        var depth = self.level[self.queue[count - 1]];
        while (true) {
            // minimum-degree node (ties: lowest id) in the last level
            var cand: u32 = self.queue[count - 1];
            var q = count;
            while (q > 0) {
                q -= 1;
                const v = self.queue[q];
                if (self.level[v] != depth) break;
                if (self.before(v, cand)) cand = v;
            }
            const c2 = self.bfs(cand);
            const d2 = self.level[self.queue[c2 - 1]];
            if (d2 > depth) {
                root = cand;
                depth = d2;
                count = c2;
            } else break;
        }
        return root;
    }
};

fn rcmLess(r: *const Rcm, a: u32, b: u32) bool {
    return r.before(a, b);
}

/// Returns `order` such that order[p] = node at RCM position p.
fn rcmOrder(gpa: Allocator, n: usize, graph: Graph) ![]u32 {
    const order = try gpa.alloc(u32, n);
    errdefer gpa.free(order);
    const visited = try gpa.alloc(bool, n);
    defer gpa.free(visited);
    @memset(visited, false);
    const stamp = try gpa.alloc(u32, n);
    defer gpa.free(stamp);
    @memset(stamp, 0);
    const queue = try gpa.alloc(u32, n);
    defer gpa.free(queue);
    const level = try gpa.alloc(u32, n);
    defer gpa.free(level);
    var r = Rcm{ .graph = graph, .stamp = stamp, .queue = queue, .level = level };
    var max_deg: u32 = 0;
    for (0..n) |v| max_deg = @max(max_deg, graph.deg(@intCast(v)));
    const tmp = try gpa.alloc(u32, max_deg);
    defer gpa.free(tmp);

    var out: usize = 0;
    for (0..n) |s| {
        if (visited[s]) continue;
        // component of the lowest unvisited id: start from its minimum (degree, id) node
        const count = r.bfs(@intCast(s));
        var seed: u32 = @intCast(s);
        for (r.queue[0..count]) |v| {
            if (r.before(v, seed)) seed = v;
        }
        const root = r.pseudoPeripheral(seed);
        // Cuthill-McKee BFS from root
        var head = out;
        order[out] = root;
        out += 1;
        visited[root] = true;
        while (head < out) {
            const v = order[head];
            head += 1;
            var cnt: usize = 0;
            for (graph.neighbors(v)) |w| {
                if (!visited[w]) {
                    visited[w] = true;
                    tmp[cnt] = w;
                    cnt += 1;
                }
            }
            const list = tmp[0..cnt];
            std.sort.insertion(u32, list, &r, rcmLess);
            @memcpy(order[out .. out + cnt], list);
            out += cnt;
        }
    }
    std.mem.reverse(u32, order);
    return order;
}

// ------------------------------------------------------------------ skyline storage

const unset: u32 = std.math.maxInt(u32);

const Skyline = struct {
    n: usize,
    colptr: []usize,
    a: []f64,

    /// Column j: rows (j-height .. j), diagonal last.
    inline fn col(self: *const Skyline, j: usize) []f64 {
        return self.a[self.colptr[j]..self.colptr[j + 1]];
    }
    inline fn diag(self: *const Skyline, j: usize) f64 {
        return self.a[self.colptr[j + 1] - 1];
    }
};

fn dot(a: []const f64, b: []const f64) f64 {
    std.debug.assert(a.len == b.len);
    const V = @Vector(4, f64);
    var acc0: V = @splat(0);
    var acc1: V = @splat(0);
    var i: usize = 0;
    while (i + 8 <= a.len) : (i += 8) {
        const a0: V = a[i..][0..4].*;
        const b0: V = b[i..][0..4].*;
        const a1: V = a[i + 4 ..][0..4].*;
        const b1: V = b[i + 4 ..][0..4].*;
        acc0 += a0 * b0;
        acc1 += a1 * b1;
    }
    var s: f64 = @reduce(.Add, acc0 + acc1);
    while (i < a.len) : (i += 1) s += a[i] * b[i];
    return s;
}

/// Column heights for a given dof numbering; returns the profile (sum of heights).
fn columnHeights(g: *const Geometry, dofidx: []const u32, heights: []u32) u64 {
    @memset(heights, 0);
    for (0..g.mi.len) |k| {
        var idx: [6]u32 = undefined;
        var cnt: usize = 0;
        var lo: u32 = unset;
        for ([2]u32{ g.mi[k], g.mj[k] }) |nd| {
            for (0..3) |c| {
                const d = dofidx[nd * 3 + c];
                if (d != unset) {
                    idx[cnt] = d;
                    cnt += 1;
                    lo = @min(lo, d);
                }
            }
        }
        for (idx[0..cnt]) |d| heights[d] = @max(heights[d], d - lo);
    }
    var sum: u64 = 0;
    for (heights) |h| sum += h;
    return sum;
}

/// Numbers free dofs walking nodes in `order` (null = identity). Returns the free dof count.
fn numberDofs(g: *const Geometry, order: ?[]const u32, dofidx: []u32, dof_node: ?[]u32, dof_comp: ?[]u8) usize {
    var next: u32 = 0;
    for (0..g.fixed.len) |p| {
        const nd: u32 = if (order) |o| o[p] else @intCast(p);
        for (0..3) |c| {
            if ((g.fixed[nd] >> @intCast(c)) & 1 == 1) {
                dofidx[nd * 3 + c] = unset;
            } else {
                dofidx[nd * 3 + c] = next;
                if (dof_node) |dn| dn[next] = nd;
                if (dof_comp) |dc| dc[next] = @intCast(c);
                next += 1;
            }
        }
    }
    return next;
}

// ------------------------------------------------------------------ element math

/// Local stiffness (6x6, row-major) of an Euler-Bernoulli frame member.
fn localStiffness(ea: f64, ei: f64, l: f64) [36]f64 {
    const ax = ea / l;
    const a = 12.0 * ei / (l * l * l);
    const b = 6.0 * ei / (l * l);
    const c4 = 4.0 * ei / l;
    const c2 = 2.0 * ei / l;
    var k: [36]f64 = @splat(0);
    const set = struct {
        fn f(kk: *[36]f64, i: usize, j: usize, v: f64) void {
            kk[i * 6 + j] = v;
            kk[j * 6 + i] = v;
        }
    }.f;
    set(&k, 0, 0, ax);
    set(&k, 0, 3, -ax);
    set(&k, 3, 3, ax);
    set(&k, 1, 1, a);
    set(&k, 1, 2, b);
    set(&k, 1, 4, -a);
    set(&k, 1, 5, b);
    set(&k, 2, 2, c4);
    set(&k, 2, 4, -b);
    set(&k, 2, 5, c2);
    set(&k, 4, 4, a);
    set(&k, 4, 5, -b);
    set(&k, 5, 5, c4);
    return k;
}

/// Global -> local rotation of a 6-vector (block diagonal [[c s 0][-s c 0][0 0 1]]).
fn toLocal(c: f64, s: f64, v: [6]f64) [6]f64 {
    return .{
        c * v[0] + s * v[1], -s * v[0] + c * v[1], v[2],
        c * v[3] + s * v[4], -s * v[3] + c * v[4], v[5],
    };
}
fn toGlobal(c: f64, s: f64, v: [6]f64) [6]f64 {
    return .{
        c * v[0] - s * v[1], s * v[0] + c * v[1], v[2],
        c * v[3] - s * v[4], s * v[3] + c * v[4], v[5],
    };
}

/// kg = T^T kl T
fn globalStiffness(kl: *const [36]f64, c: f64, s: f64) [36]f64 {
    var tmp: [36]f64 = undefined; // kl * T: each row rotated
    for (0..6) |r| {
        const row = [6]f64{ kl[r * 6], kl[r * 6 + 1], kl[r * 6 + 2], kl[r * 6 + 3], kl[r * 6 + 4], kl[r * 6 + 5] };
        const rot = toGlobal(c, s, row);
        for (0..6) |q| tmp[r * 6 + q] = rot[q];
    }
    var out: [36]f64 = undefined; // T^T * tmp: each column rotated
    for (0..6) |q| {
        const colv = [6]f64{ tmp[q], tmp[6 + q], tmp[12 + q], tmp[18 + q], tmp[24 + q], tmp[30 + q] };
        const rot = toGlobal(c, s, colv);
        for (0..6) |r| out[r * 6 + q] = rot[r];
    }
    return out;
}

fn fixedEndForces(w: f64, l: f64) [6]f64 {
    return .{ 0, -w * l / 2, -w * l * l / 12, 0, -w * l / 2, w * l * l / 12 };
}

// ------------------------------------------------------------------ factor / solve

/// In-place LDL^T on the skyline: the strict upper part becomes L^T (unit), the diagonal becomes D.
/// Returns the failing dof on a bad pivot.
fn factor(sk: *Skyline, max_diag: f64) ?usize {
    const pivot_tol = 1e-12; // BENCH-EDIT:leaf
    var j: usize = 0;
    while (j < sk.n) : (j += 1) {
        const cj = sk.col(j);
        const hj = cj.len - 1;
        const mj = j - hj;
        var i = mj + 1;
        while (i < j) : (i += 1) {
            const ci = sk.col(i);
            const mi = i - (ci.len - 1);
            const m = @max(mi, mj);
            if (m < i) cj[i - mj] -= dot(ci[m - mi .. i - mi], cj[m - mj .. i - mj]);
        }
        var d = cj[hj];
        i = mj;
        while (i < j) : (i += 1) {
            const g = cj[i - mj];
            const l = g / sk.diag(i);
            d -= l * g;
            cj[i - mj] = l;
        }
        if (!(d > pivot_tol * max_diag)) return j;
        cj[hj] = d;
    }
    return null;
}

fn solveInPlace(sk: *const Skyline, b: []f64) void {
    // forward: L y = b
    var j: usize = 0;
    while (j < sk.n) : (j += 1) {
        const cj = sk.col(j);
        const hj = cj.len - 1;
        if (hj > 0) b[j] -= dot(cj[0..hj], b[j - hj .. j]);
    }
    j = 0;
    while (j < sk.n) : (j += 1) b[j] /= sk.diag(j);
    // backward: L^T x = z
    j = sk.n;
    while (j > 0) {
        j -= 1;
        const cj = sk.col(j);
        const hj = cj.len - 1;
        const bj = b[j];
        if (hj > 0 and bj != 0) {
            for (cj[0..hj], j - hj..) |l, i| b[i] -= l * bj;
        }
    }
}

// ------------------------------------------------------------------ driver

fn msBetween(t0: u64, t1: u64) f64 {
    return @as(f64, @floatFromInt(t1 -| t0)) / 1.0e6;
}

fn findReaction(react: []const Reaction, node: u32) usize {
    var lo: usize = 0;
    var hi: usize = react.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (react[mid].node < node) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// Solves every load case of `m`. Sorts the model's nodes and members by id in place.
/// On `error.ModelError`, `err` says what is wrong.
pub fn solve(gpa: Allocator, m: *Model, err: *ErrorInfo) SolveError!Results {
    const t_start = clock_ns();
    try normalize(m, err);
    const n_nodes = m.nodes.len;
    const n_mem = m.members.len;

    const geo = try buildGeometry(gpa, m, err);
    defer geo.deinit(gpa);

    const graph = try buildGraph(gpa, n_nodes, &geo);
    defer graph.deinit(gpa);
    const order = try rcmOrder(gpa, n_nodes, graph);
    defer gpa.free(order);

    const dofidx = try gpa.alloc(u32, n_nodes * 3);
    defer gpa.free(dofidx);
    const n_free = numberDofs(&geo, null, dofidx, null, null); // original (id) order
    if (n_free == 0) return err.set(.no_free_dofs, "every degree of freedom is restrained", .{});
    const heights = try gpa.alloc(u32, n_free);
    defer gpa.free(heights);
    const profile_before = columnHeights(&geo, dofidx, heights);

    const dof_node = try gpa.alloc(u32, n_free);
    defer gpa.free(dof_node);
    const dof_comp = try gpa.alloc(u8, n_free);
    defer gpa.free(dof_comp);
    _ = numberDofs(&geo, order, dofidx, dof_node, dof_comp); // RCM order
    const profile_after = columnHeights(&geo, dofidx, heights);

    const colptr = try gpa.alloc(usize, n_free + 1);
    defer gpa.free(colptr);
    colptr[0] = 0;
    for (0..n_free) |j| colptr[j + 1] = colptr[j] + heights[j] + 1;
    const store = try gpa.alloc(f64, colptr[n_free]);
    defer gpa.free(store);
    @memset(store, 0);
    var sk = Skyline{ .n = n_free, .colptr = colptr, .a = store };

    // assembly
    for (0..n_mem) |k| {
        const kl = localStiffness(geo.ea[k], geo.ei[k], geo.len[k]);
        const kg = globalStiffness(&kl, geo.c[k], geo.s[k]);
        var di: [6]u32 = undefined;
        for (0..3) |c| {
            di[c] = dofidx[geo.mi[k] * 3 + c];
            di[3 + c] = dofidx[geo.mj[k] * 3 + c];
        }
        for (0..6) |r| {
            if (di[r] == unset) continue;
            for (r..6) |q| {
                if (di[q] == unset) continue;
                const lo = @min(di[r], di[q]);
                const hi = @max(di[r], di[q]);
                store[colptr[hi + 1] - 1 - (hi - lo)] += kg[r * 6 + q];
            }
        }
    }
    var max_diag: f64 = 0;
    for (0..n_free) |j| max_diag = @max(max_diag, sk.diag(j));

    const length = try gpa.dupe(f64, geo.len);
    errdefer gpa.free(length);

    const t_asm = clock_ns();
    if (factor(&sk, max_diag)) |bad| {
        const names = [_][]const u8{ "ux", "uy", "rz" };
        const comp = names[dof_comp[bad]];
        return err.set(.unstable, "zero pivot at node {d} dof {s}", .{ m.nodes[dof_node[bad]].id, comp });
    }
    const t_fac = clock_ns();

    var n_react: usize = 0;
    for (geo.fixed) |f| n_react += @intFromBool(f != 0);

    const cases = try gpa.alloc(CaseResult, m.load_cases.len);
    var built: usize = 0;
    errdefer {
        for (cases[0..built]) |c| freeCase(gpa, c);
        gpa.free(cases);
    }
    const rhs = try gpa.alloc(f64, n_free);
    defer gpa.free(rhs);

    for (m.load_cases, 0..) |lc, ci| {
        const u = try gpa.alloc(f64, n_nodes * 3);
        errdefer gpa.free(u);
        const react = try gpa.alloc(Reaction, n_react);
        errdefer gpa.free(react);
        const ef = try gpa.alloc(f64, n_mem * 6);
        errdefer gpa.free(ef);
        const wv = try gpa.alloc(f64, n_mem);
        errdefer gpa.free(wv);
        @memset(wv, 0);
        @memset(rhs, 0);

        for (lc.nodal) |ld| {
            const nd = findNode(m.nodes, ld.node).?;
            const vals = [3]f64{ ld.fx, ld.fy, ld.mz };
            for (0..3) |c| {
                const d = dofidx[nd * 3 + c];
                if (d != unset) rhs[d] += vals[c];
            }
        }
        for (lc.member_udl) |ld| wv[findMember(m.members, ld.member).?] += ld.w;
        for (0..n_mem) |k| {
            if (wv[k] == 0) continue;
            const fe = toGlobal(geo.c[k], geo.s[k], fixedEndForces(wv[k], geo.len[k]));
            for (0..3) |c| {
                const d1 = dofidx[geo.mi[k] * 3 + c];
                if (d1 != unset) rhs[d1] -= fe[c];
                const d2 = dofidx[geo.mj[k] * 3 + c];
                if (d2 != unset) rhs[d2] -= fe[3 + c];
            }
        }
        solveInPlace(&sk, rhs);
        for (0..n_nodes * 3) |q| {
            const d = dofidx[q];
            u[q] = if (d == unset) 0 else rhs[d];
        }

        // reactions: member end forces summed at restrained dofs, minus applied loads
        var ri: usize = 0;
        for (geo.fixed, 0..) |f, nd| {
            if (f != 0) {
                react[ri] = .{ .node = @intCast(nd), .f = .{ 0, 0, 0 } };
                ri += 1;
            }
        }
        for (0..n_mem) |k| {
            const ug = [6]f64{
                u[geo.mi[k] * 3], u[geo.mi[k] * 3 + 1], u[geo.mi[k] * 3 + 2],
                u[geo.mj[k] * 3], u[geo.mj[k] * 3 + 1], u[geo.mj[k] * 3 + 2],
            };
            const ul = toLocal(geo.c[k], geo.s[k], ug);
            const kl = localStiffness(geo.ea[k], geo.ei[k], geo.len[k]);
            const ff = fixedEndForces(wv[k], geo.len[k]);
            var f6: [6]f64 = undefined;
            for (0..6) |r| {
                var sum: f64 = ff[r];
                for (0..6) |q| sum += kl[r * 6 + q] * ul[q];
                f6[r] = sum;
                ef[k * 6 + r] = sum;
            }
            const gl = toGlobal(geo.c[k], geo.s[k], f6);
            for ([2]u32{ geo.mi[k], geo.mj[k] }, 0..) |nd, side| {
                const fx = geo.fixed[nd];
                if (fx == 0) continue;
                const r = findReaction(react, nd);
                for (0..3) |c| {
                    if ((fx >> @intCast(c)) & 1 == 1) react[r].f[c] += gl[side * 3 + c];
                }
            }
        }
        for (lc.nodal) |ld| {
            const nd = findNode(m.nodes, ld.node).?;
            const fx = geo.fixed[nd];
            if (fx == 0) continue;
            const r = findReaction(react, nd);
            const vals = [3]f64{ ld.fx, ld.fy, ld.mz };
            for (0..3) |c| {
                if ((fx >> @intCast(c)) & 1 == 1) react[r].f[c] -= vals[c];
            }
        }

        // equilibrium: reactions + applied loads + UDL resultants, moments about the origin
        var sx: f64 = 0;
        var sy: f64 = 0;
        var mag: f64 = 1;
        for (react) |r| {
            sx += r.f[0];
            sy += r.f[1];
            mag += @abs(r.f[0]) + @abs(r.f[1]);
        }
        for (lc.nodal) |ld| {
            sx += ld.fx;
            sy += ld.fy;
            mag += @abs(ld.fx) + @abs(ld.fy);
        }
        for (0..n_mem) |k| {
            if (wv[k] == 0) continue;
            const l = geo.len[k];
            const fxg = -geo.s[k] * wv[k] * l;
            const fyg = geo.c[k] * wv[k] * l;
            sx += fxg;
            sy += fyg;
            mag += @abs(fxg) + @abs(fyg);
        }
        const resid = @max(@abs(sx), @abs(sy)) / mag;
        cases[ci] = .{ .id = lc.id, .u = u, .reactions = react, .end_forces = ef, .w = wv, .residual = resid };
        built += 1;
    }
    const t_end = clock_ns();

    return .{
        .gpa = gpa,
        .cases = cases,
        .length = length,
        .stats = .{
            .nodes = n_nodes,
            .members = n_mem,
            .free_dofs = n_free,
            .profile_before = profile_before,
            .profile_after = profile_after,
            .assemble_ms = msBetween(t_start, t_asm),
            .factor_ms = msBetween(t_asm, t_fac),
            .solve_ms = msBetween(t_fac, t_end),
        },
    };
}

// ------------------------------------------------------------------ station diagrams (SPEC 4.5)

pub const stations = 11;

pub const Station = struct { x: f64, N: f64, V: f64, M: f64 };

pub fn station(ef: []const f64, w: f64, l: f64, k: usize) Station {
    const x = l * @as(f64, @floatFromInt(k)) / 10.0;
    return .{
        .x = x,
        .N = -ef[0],
        .V = ef[1] + w * x,
        .M = -ef[2] + ef[1] * x + w * x * x / 2,
    };
}

pub fn maxAbsM(ef: []const f64, w: f64, l: f64) f64 {
    var mx: f64 = 0;
    for (0..stations) |k| mx = @max(mx, @abs(station(ef, w, l, k).M));
    return mx;
}
