//! Reverse Cuthill-McKee ordering and skyline (profile) LDL^T factorization (SPEC 4.3, 4.4).
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Undirected node graph in CSR form (duplicate edges removed, neighbors sorted by index).
pub const Graph = struct {
    start: []u32, // n + 1
    adj: []u32,
    adj_cap: usize = 0,

    pub fn degree(g: Graph, v: u32) u32 {
        return g.start[v + 1] - g.start[v];
    }
    pub fn neighbors(g: Graph, v: u32) []const u32 {
        return g.adj[g.start[v]..g.start[v + 1]];
    }

    /// `edges` are (a, b) node-index pairs, one per member.
    pub fn build(gpa: Allocator, n: usize, edges: []const [2]u32) !Graph {
        const start = try gpa.alloc(u32, n + 1);
        errdefer gpa.free(start);
        @memset(start, 0);
        for (edges) |e| {
            if (e[0] == e[1]) continue;
            start[e[0] + 1] += 1;
            start[e[1] + 1] += 1;
        }
        for (1..n + 1) |k| start[k] += start[k - 1];
        const raw = try gpa.alloc(u32, start[n]);
        defer gpa.free(raw);
        const fill = try gpa.alloc(u32, n);
        defer gpa.free(fill);
        @memcpy(fill, start[0..n]);
        for (edges) |e| {
            if (e[0] == e[1]) continue;
            raw[fill[e[0]]] = e[1];
            fill[e[0]] += 1;
            raw[fill[e[1]]] = e[0];
            fill[e[1]] += 1;
        }
        // sort + dedupe each row, compacting in place
        var out: u32 = 0;
        const adj = try gpa.alloc(u32, start[n]);
        errdefer gpa.free(adj);
        var row_start: u32 = 0;
        for (0..n) |v| {
            const row = raw[start[v]..start[v + 1]];
            std.mem.sort(u32, row, {}, std.sort.asc(u32));
            var last: ?u32 = null;
            for (row) |x| {
                if (last != null and last.? == x) continue;
                adj[out] = x;
                out += 1;
                last = x;
            }
            start[v] = row_start;
            row_start = out;
        }
        start[n] = out;
        return .{ .start = start, .adj = adj[0..out], .adj_cap = adj.len };
    }

    pub fn deinit(g: Graph, gpa: Allocator) void {
        gpa.free(g.start);
        gpa.free(g.adj.ptr[0..g.adj_cap]);
    }
};

const Bfs = struct {
    /// Rooted level structure from `root` restricted to the current component. Returns
    /// (number of levels, last level slice in `queue`).
    fn levels(g: Graph, root: u32, mark: []u32, stamp: u32, queue: []u32, level_of: []u32) struct { depth: u32, last_lo: usize, count: usize } {
        var head: usize = 0;
        var tail: usize = 1;
        queue[0] = root;
        mark[root] = stamp;
        level_of[root] = 0;
        var last_lo: usize = 0;
        var depth: u32 = 0;
        while (head < tail) : (head += 1) {
            const v = queue[head];
            if (level_of[v] != depth) {
                depth = level_of[v];
                last_lo = head;
            }
            for (g.neighbors(v)) |u| {
                if (mark[u] != stamp) {
                    mark[u] = stamp;
                    level_of[u] = level_of[v] + 1;
                    queue[tail] = u;
                    tail += 1;
                }
            }
        }
        return .{ .depth = depth, .last_lo = last_lo, .count = tail };
    }
};

/// Deterministic reverse Cuthill-McKee (SPEC 4.4). Node indices are assumed sorted by id, so
/// "lowest id" == lowest index. Returns `order[k]` = node index at RCM position k.
pub fn rcm(gpa: Allocator, g: Graph) ![]u32 {
    const n: u32 = @intCast(g.start.len - 1);
    const order = try gpa.alloc(u32, n);
    errdefer gpa.free(order);
    const visited = try gpa.alloc(bool, n);
    defer gpa.free(visited);
    @memset(visited, false);
    const mark = try gpa.alloc(u32, n);
    defer gpa.free(mark);
    @memset(mark, 0);
    const queue = try gpa.alloc(u32, n);
    defer gpa.free(queue);
    const level_of = try gpa.alloc(u32, n);
    defer gpa.free(level_of);
    var stamp: u32 = 0;
    var pos: usize = 0;

    // Components are processed in ascending order of their minimum node index: scanning
    // indices upward, the first unvisited node starts a new component and is its minimum.
    var scan: u32 = 0;
    while (scan < n) : (scan += 1) {
        if (visited[scan]) continue;
        // collect the component, pick its min-degree node (ties: lowest index)
        stamp += 1;
        const comp = Bfs.levels(g, scan, mark, stamp, queue, level_of);
        var start = queue[0];
        for (queue[0..comp.count]) |v| {
            const dv = g.degree(v);
            const ds = g.degree(start);
            if (dv < ds or (dv == ds and v < start)) start = v;
        }
        // George-Liu pseudo-peripheral node search
        stamp += 1;
        var cur = Bfs.levels(g, start, mark, stamp, queue, level_of);
        while (true) {
            var cand = queue[cur.last_lo];
            for (queue[cur.last_lo..cur.count]) |v| {
                const dv = g.degree(v);
                const dc = g.degree(cand);
                if (dv < dc or (dv == dc and v < cand)) cand = v;
            }
            stamp += 1;
            const next = Bfs.levels(g, cand, mark, stamp, queue, level_of);
            if (next.depth > cur.depth) {
                start = cand;
                cur = next;
            } else break;
        }
        // Cuthill-McKee BFS, neighbors in ascending (degree, index)
        const base = pos;
        order[pos] = start;
        pos += 1;
        visited[start] = true;
        var head = base;
        var nb: std.ArrayList(u32) = .empty;
        defer nb.deinit(gpa);
        while (head < pos) : (head += 1) {
            const v = order[head];
            nb.clearRetainingCapacity();
            for (g.neighbors(v)) |u| {
                if (!visited[u]) try nb.append(gpa, u);
            }
            std.mem.sort(u32, nb.items, g, struct {
                fn lt(gg: Graph, a: u32, b: u32) bool {
                    const da = gg.degree(a);
                    const db = gg.degree(b);
                    return da < db or (da == db and a < b);
                }
            }.lt);
            for (nb.items) |u| {
                visited[u] = true;
                order[pos] = u;
                pos += 1;
            }
        }
    }
    std.mem.reverse(u32, order);
    return order;
}

/// Skyline storage of the upper triangle, by column. Column j holds rows first[j]..j
/// (diagonal last) at vals[ptr[j] .. ptr[j+1]].
pub const Skyline = struct {
    n: usize,
    first: []u32,
    ptr: []usize,
    vals: []f64,

    pub fn init(gpa: Allocator, first: []u32) !Skyline {
        const n = first.len;
        const ptr = try gpa.alloc(usize, n + 1);
        errdefer gpa.free(ptr);
        ptr[0] = 0;
        for (0..n) |j| ptr[j + 1] = ptr[j] + (j - first[j]) + 1;
        const vals = try gpa.alloc(f64, ptr[n]);
        @memset(vals, 0);
        return .{ .n = n, .first = first, .ptr = ptr, .vals = vals };
    }

    pub fn deinit(s: Skyline, gpa: Allocator) void {
        gpa.free(s.ptr);
        gpa.free(s.vals);
    }

    /// Entry (r, c) with r <= c and r >= first[c].
    pub inline fn at(s: Skyline, r: usize, c: usize) *f64 {
        return &s.vals[s.ptr[c] + (r - s.first[c])];
    }

    pub fn profile(first: []const u32) u64 {
        var p: u64 = 0;
        for (first, 0..) |f, j| p += j - f;
        return p;
    }

    pub const FactorError = error{Unstable};

    /// In-place LDL^T. On success column j holds L(r, j) for r < j and D(j) on the diagonal.
    /// On a failed pivot `bad_dof` is set and error.Unstable returned.
    pub fn factor(s: Skyline, bad_dof: *usize) FactorError!void {
        var maxdiag: f64 = 0;
        for (0..s.n) |j| maxdiag = @max(maxdiag, @abs(s.vals[s.ptr[j + 1] - 1]));
        const tol = 1e-12 * maxdiag; // BENCH-EDIT:leaf
        for (0..s.n) |j| {
            const fj = s.first[j];
            const colj = s.vals[s.ptr[j]..s.ptr[j + 1]];
            // g(i, j) = K(i, j) - sum_k L(k, i) g(k, j)
            var i: usize = fj;
            while (i < j) : (i += 1) {
                const fi = s.first[i];
                const lo = @max(fi, fj);
                if (lo < i) {
                    const coli = s.vals[s.ptr[i] + (lo - fi) .. s.ptr[i] + (i - fi)];
                    const cj = colj[lo - fj .. i - fj];
                    colj[i - fj] -= dot(coli, cj);
                }
            }
            // L(i, j) = g / D(i);  D(j) = K(j,j) - sum g L
            var d = colj[j - fj];
            i = fj;
            while (i < j) : (i += 1) {
                const g = colj[i - fj];
                const l = g / s.vals[s.ptr[i + 1] - 1];
                d -= g * l;
                colj[i - fj] = l;
            }
            if (!(d > tol)) {
                bad_dof.* = j;
                return error.Unstable;
            }
            colj[j - fj] = d;
        }
    }

    /// Solve L D L^T x = b in place.
    pub fn solve(s: Skyline, x: []f64) void {
        // forward: L z = b (column oriented: z_j = b_j - sum_{i<j} L(i,j) z_i)
        for (0..s.n) |j| {
            const fj = s.first[j];
            if (fj < j) x[j] -= dot(s.vals[s.ptr[j] .. s.ptr[j + 1] - 1], x[fj..j]);
        }
        for (0..s.n) |j| x[j] /= s.vals[s.ptr[j + 1] - 1];
        // backward: L^T x = y (x_i -= L(i,j) x_j, j descending)
        var j = s.n;
        while (j > 0) {
            j -= 1;
            const fj = s.first[j];
            const xj = x[j];
            if (xj == 0) continue;
            const col = s.vals[s.ptr[j] .. s.ptr[j + 1] - 1];
            for (col, fj..) |l, r| x[r] -= l * xj;
        }
    }
};

inline fn dot(a: []const f64, b: []const f64) f64 {
    const V = @Vector(4, f64);
    var acc: V = @splat(0);
    var k: usize = 0;
    while (k + 4 <= a.len) : (k += 4) {
        const va: V = a[k..][0..4].*;
        const vb: V = b[k..][0..4].*;
        acc += va * vb;
    }
    var sum = @reduce(.Add, acc);
    while (k < a.len) : (k += 1) sum += a[k] * b[k];
    return sum;
}

test "skyline LDLT solves a small SPD system" {
    const gpa = std.testing.allocator;
    var first = [_]u32{ 0, 0, 1 };
    const s = try Skyline.init(gpa, &first);
    defer s.deinit(gpa);
    // K = [[4,1,0],[1,3,1],[0,1,2]]
    s.at(0, 0).* = 4;
    s.at(0, 1).* = 1;
    s.at(1, 1).* = 3;
    s.at(1, 2).* = 1;
    s.at(2, 2).* = 2;
    var bad: usize = 0;
    try s.factor(&bad);
    var x = [_]f64{ 5, 5, 3 }; // solution 1,1,1
    s.solve(&x);
    for (x) |v| try std.testing.expectApproxEqAbs(@as(f64, 1), v, 1e-12);
}

test "rcm on a path graph is a valid permutation" {
    const gpa = std.testing.allocator;
    const edges = [_][2]u32{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 1, 2 } };
    const g = try Graph.build(gpa, 4, &edges);
    defer g.deinit(gpa);
    const o = try rcm(gpa, g);
    defer gpa.free(o);
    var seen = @as([4]bool, @splat(false));
    for (o) |v| seen[v] = true;
    for (seen) |b| try std.testing.expect(b);
}
