//! Deterministic reverse Cuthill-McKee (SPEC 4.4) with George-Liu pseudo-peripheral start nodes.
//! Node "id" in tie-breaks means the node index in id-sorted order.
const std = @import("std");
const model = @import("model.zig");

const Adjacency = struct {
    start: []u32,
    list: []u32,
    degree: []u32,

    fn neighbors(g: Adjacency, v: u32) []const u32 {
        return g.list[g.start[v]..g.start[v + 1]];
    }
};

/// (degree, index) ordering used by every tie-break.
fn lessDegree(deg: []const u32, a: u32, b: u32) bool {
    if (deg[a] != deg[b]) return deg[a] < deg[b];
    return a < b;
}

fn buildAdjacency(a: std.mem.Allocator, n: usize, members: []const model.Member) !Adjacency {
    const start = try a.alloc(u32, n + 1);
    @memset(start, 0);
    for (members) |m| {
        if (m.i == m.j) continue;
        start[m.i + 1] += 1;
        start[m.j + 1] += 1;
    }
    for (0..n) |k| start[k + 1] += start[k];
    const list = try a.alloc(u32, start[n]);
    const fill = try a.dupe(u32, start[0..n]);
    defer a.free(fill);
    for (members) |m| {
        if (m.i == m.j) continue;
        list[fill[m.i]] = m.j;
        fill[m.i] += 1;
        list[fill[m.j]] = m.i;
        fill[m.j] += 1;
    }
    // Sort and deduplicate each list, compacting in place.
    const degree = try a.alloc(u32, n);
    var out: u32 = 0;
    var prev_end: u32 = 0;
    for (0..n) |v| {
        const seg = list[prev_end..start[v + 1]];
        prev_end = start[v + 1];
        std.mem.sort(u32, seg, {}, std.sort.asc(u32));
        const begin = out;
        var last: ?u32 = null;
        for (seg) |x| {
            if (last != null and last.? == x) continue;
            last = x;
            list[out] = x;
            out += 1;
        }
        start[v] = begin;
        degree[v] = out - begin;
    }
    start[n] = out;
    // Neighbor lists are visited in ascending (degree, id) order.
    for (0..n) |v| {
        const seg = list[start[v]..start[v + 1]];
        std.mem.sort(u32, seg, degree, struct {
            fn lt(deg: []u32, x: u32, y: u32) bool {
                return lessDegree(deg, x, y);
            }
        }.lt);
    }
    return .{ .start = start, .list = list[0..out], .degree = degree };
}

const Levels = struct {
    /// Number of levels (eccentricity + 1) of the rooted level structure.
    count: u32,
    /// Min (degree, id) node of the last level.
    best_last: u32,
};

/// BFS level structure from `root`. `stamp`/`level` are scratch of size n; `queue` of size >= component.
fn levelStructure(g: Adjacency, root: u32, level: []i32, queue: []u32) Levels {
    var head: usize = 0;
    var tail: usize = 0;
    queue[tail] = root;
    tail += 1;
    level[root] = 0;
    var max_level: i32 = 0;
    while (head < tail) {
        const v = queue[head];
        head += 1;
        const lv = level[v];
        max_level = lv;
        for (g.neighbors(v)) |w| {
            if (level[w] < 0) {
                level[w] = lv + 1;
                queue[tail] = w;
                tail += 1;
            }
        }
    }
    var best: u32 = root;
    var have = false;
    for (queue[0..tail]) |v| {
        if (level[v] != max_level) continue;
        if (!have or lessDegree(g.degree, v, best)) {
            best = v;
            have = true;
        }
    }
    for (queue[0..tail]) |v| level[v] = -1;
    return .{ .count = @intCast(max_level + 1), .best_last = best };
}

/// Returns the node order: result[k] = index of the node placed k-th.
pub fn order(a: std.mem.Allocator, n: usize, members: []const model.Member) ![]u32 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const t = arena.allocator();
    const g = try buildAdjacency(t, n, members);
    const result = try a.alloc(u32, n);
    errdefer a.free(result);
    const level = try t.alloc(i32, n);
    @memset(level, -1);
    const queue = try t.alloc(u32, n);
    const comp_seen = try t.alloc(bool, n);
    @memset(comp_seen, false);
    const placed = try t.alloc(bool, n);
    @memset(placed, false);
    const comp_nodes = try t.alloc(u32, n);

    var count: usize = 0;
    for (0..n) |seed| {
        if (comp_seen[seed]) continue;
        // Collect the component (seed is its lowest-id node because seeds ascend).
        var csize: usize = 0;
        comp_nodes[0] = @intCast(seed);
        comp_seen[seed] = true;
        csize = 1;
        var head: usize = 0;
        while (head < csize) {
            const v = comp_nodes[head];
            head += 1;
            for (g.neighbors(v)) |w| {
                if (!comp_seen[w]) {
                    comp_seen[w] = true;
                    comp_nodes[csize] = w;
                    csize += 1;
                }
            }
        }
        var root = comp_nodes[0];
        for (comp_nodes[0..csize]) |v| {
            if (lessDegree(g.degree, v, root)) root = v;
        }
        // George-Liu pseudo-peripheral search.
        var ls = levelStructure(g, root, level, queue);
        while (true) {
            const cand = ls.best_last;
            const lc = levelStructure(g, cand, level, queue);
            if (lc.count > ls.count) {
                root = cand;
                ls = lc;
            } else break;
        }
        // Cuthill-McKee BFS.
        const base = count;
        result[count] = root;
        placed[root] = true;
        count += 1;
        var qh = base;
        while (qh < count) {
            const v = result[qh];
            qh += 1;
            for (g.neighbors(v)) |w| {
                if (!placed[w]) {
                    placed[w] = true;
                    result[count] = w;
                    count += 1;
                }
            }
        }
    }
    std.mem.reverse(u32, result);
    return result;
}
