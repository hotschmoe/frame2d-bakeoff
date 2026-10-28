//! Frame canvas: members, supports, nodes, deflected shape and moment diagram as Teak
//! canvas primitives (big `lines` batches, culled to the viewport).
const std = @import("std");
const teak = @import("teak");
const state = @import("state.zig");
const engine = @import("engine.zig");

const Prim = teak.CanvasPrimitive;
const n_colors = 6;
const heat = [n_colors][4]f32{
    .{ 0.35, 0.55, 0.95, 1 },
    .{ 0.30, 0.80, 0.85, 1 },
    .{ 0.40, 0.85, 0.40, 1 },
    .{ 0.95, 0.85, 0.30, 1 },
    .{ 0.98, 0.55, 0.20, 1 },
    .{ 0.95, 0.25, 0.25, 1 },
};
const plain = [4]f32{ 0.75, 0.78, 0.85, 1 };
const defl_color = [4]f32{ 0.95, 0.45, 0.85, 1 };
const moment_color = [4]f32{ 0.98, 0.75, 0.25, 0.9 };
const support_color = [4]f32{ 0.40, 0.95, 0.55, 1 };
const node_color = [4]f32{ 0.85, 0.88, 0.95, 1 };
const spring_color = [4]f32{ 0.35, 0.85, 0.95, 1 };
const hinge_color = [4]f32{ 0.98, 0.98, 0.98, 1 };

fn visible(m: *const state.Model, a: [2]f32, b: [2]f32, margin: f32) bool {
    const w = m.canvas_w;
    const h = m.canvas_h;
    return !((a[0] < -margin and b[0] < -margin) or (a[0] > w + margin and b[0] > w + margin) or
        (a[1] < -margin and b[1] < -margin) or (a[1] > h + margin and b[1] > h + margin));
}

pub fn view(m: *const state.Model, cb: anytype) void {
    const arena = cb.arena.allocator();
    const prims = build(m, arena) catch &.{};
    cb.canvasInteractive(.{ .width = m.canvas_w, .height = m.canvas_h, .bg = .{ 0.06, 0.07, 0.09, 1 } }, prims, state.CANVAS_ID, "frame canvas");
}

fn build(m: *const state.Model, arena: std.mem.Allocator) ![]const Prim {
    var prims: std.ArrayList(Prim) = .empty;
    const nm = m.m.members.len;
    const res = m.res;
    const cr = m.caseResult();
    const key_base: u64 = m.rev *% 64;

    // node index (model order) -> sorted position, for results lookup
    var pos_of: []u32 = &.{};
    if (res) |r| {
        pos_of = try arena.alloc(u32, r.node_src.len);
        for (r.node_src, 0..) |src, k| pos_of[src] = @intCast(k);
    }
    // member endpoints in screen space; members in id order when solved, model order otherwise
    var node_map: std.AutoHashMapUnmanaged(i64, u32) = .empty;
    try node_map.ensureTotalCapacity(arena, @intCast(m.m.nodes.len));
    for (m.m.nodes, 0..) |n, k| node_map.putAssumeCapacity(n.id, @intCast(k));
    const scr = try arena.alloc([2]f32, m.m.nodes.len);
    for (m.m.nodes, 0..) |n, k| scr[k] = m.toScreen(n.x, n.y);

    var max_m: f64 = 0;
    if (cr) |c| max_m = c.max_abs_m;

    // members, bucketed by colour
    var buckets: [n_colors]std.ArrayList([4]f32) = @splat(.empty);
    for (buckets[0..]) |*b| try b.ensureTotalCapacity(arena, nm / n_colors + 16);
    var moment: std.ArrayList([4]f32) = .empty;
    var defl: std.ArrayList([4]f32) = .empty;
    const want_moment = m.show_moment and cr != null and max_m > 0;
    const want_defl = m.show_deflected and cr != null;
    var max_d: f64 = 0;
    if (want_defl) for (cr.?.disp) |d| {
        max_d = @max(max_d, @max(@abs(d[0]), @abs(d[1])));
    };
    // moment diagram height: 40 px at max |M|; deflection: up to 15% of the canvas
    const m_scale: f64 = if (max_m > 0) 40.0 / max_m else 0;
    const d_scale: f64 = if (max_d > 0) @as(f64, m.defl_scale) * 0.15 * @as(f64, @min(m.canvas_w, m.canvas_h)) / (max_d * m.zoom) else 0;

    for (0..nm) |k| {
        const src = if (res) |r| r.member_src[k] else @as(u32, @intCast(k));
        const mb = m.m.members[src];
        const ni = node_map.get(mb.i) orelse continue;
        const nj = node_map.get(mb.j) orelse continue;
        const a = scr[ni];
        const b = scr[nj];
        if (!visible(m, a, b, 50)) continue;
        var bucket: usize = 0;
        if (m.color_by_m and cr != null and max_m > 0) {
            var mm: f64 = 0;
            for (cr.?.stations[k]) |s| mm = @max(mm, @abs(s.M));
            bucket = @min(n_colors - 1, @as(usize, @intFromFloat(mm / max_m * n_colors)));
        }
        try buckets[bucket].append(arena, .{ a[0], a[1], b[0], b[1] });

        if (want_moment) {
            const st = cr.?.stations[k];
            const dx = b[0] - a[0];
            const dy = b[1] - a[1];
            const len = @sqrt(dx * dx + dy * dy);
            if (len > 0.5) {
                // local y in screen space (screen y points down)
                const ny = -dx / len;
                const nyy = -dy / len;
                var prev: [2]f32 = a;
                for (st, 0..) |s, q| {
                    const t: f32 = @as(f32, @floatFromInt(q)) / @as(f32, @floatFromInt(st.len - 1));
                    const off: f32 = @floatCast(-s.M * m_scale); // sagging drawn below the member
                    const p = [2]f32{ a[0] + dx * t - ny * off, a[1] + dy * t - nyy * off };
                    if (q == 0) try moment.append(arena, .{ a[0], a[1], p[0], p[1] }) else try moment.append(arena, .{ prev[0], prev[1], p[0], p[1] });
                    prev = p;
                }
                try moment.append(arena, .{ prev[0], prev[1], b[0], b[1] });
            }
        }
        if (want_defl) {
            const d = cr.?.disp;
            const di = d[pos_of[ni]];
            const dj = d[pos_of[nj]];
            const zs: f32 = @floatCast(d_scale * m.zoom);
            const pa = [2]f32{ a[0] + @as(f32, @floatCast(di[0])) * zs, a[1] - @as(f32, @floatCast(di[1])) * zs };
            const pb = [2]f32{ b[0] + @as(f32, @floatCast(dj[0])) * zs, b[1] - @as(f32, @floatCast(dj[1])) * zs };
            try defl.append(arena, .{ pa[0], pa[1], pb[0], pb[1] });
        }
    }
    for (buckets, 0..) |b, k| {
        if (b.items.len == 0) continue;
        try prims.append(arena, .{ .lines = .{ .segs = b.items, .color = if (m.color_by_m and cr != null) heat[k] else plain, .thickness = 2, .key = key_base + k + 1 } });
    }
    if (defl.items.len > 0) try prims.append(arena, .{ .lines = .{ .segs = defl.items, .color = defl_color, .thickness = 1.5, .key = key_base + 20 } });
    if (moment.items.len > 0) try prims.append(arena, .{ .lines = .{ .segs = moment.items, .color = moment_color, .thickness = 1, .key = key_base + 21 } });

    // supports (triangles-ish: a filled square under the node) and node markers when zoomed in
    for (m.m.supports) |sp| {
        const k = node_map.get(sp.node) orelse continue;
        const p = scr[k];
        if (p[0] < -10 or p[1] < -10 or p[0] > m.canvas_w + 10 or p[1] > m.canvas_h + 10) continue;
        try prims.append(arena, .{ .filled_rect = .{ .x = p[0] - 6, .y = p[1], .w = 12, .h = 6, .color = support_color } });
    }
    // P2: springs (zigzag under/beside the node) and mz releases (hinge dots near the released end)
    var springs: std.ArrayList([4]f32) = .empty;
    for (m.m.springs) |sp| {
        const k = node_map.get(sp.node) orelse continue;
        const p = scr[k];
        if (p[0] < -20 or p[1] < -20 or p[0] > m.canvas_w + 20 or p[1] > m.canvas_h + 20) continue;
        const zig = [_]f32{ 0, 3, -3, 3, -3, 0 };
        if (sp.ky != null) for (0..zig.len - 1) |q| {
            const y0 = p[1] + @as(f32, @floatFromInt(q)) * 3;
            try springs.append(arena, .{ p[0] + zig[q], y0, p[0] + zig[q + 1], y0 + 3 });
        };
        if (sp.kx != null) for (0..zig.len - 1) |q| {
            const x0 = p[0] - @as(f32, @floatFromInt(q + 1)) * 3;
            try springs.append(arena, .{ x0 + 3, p[1] + zig[q], x0, p[1] + zig[q + 1] });
        };
        if (sp.kr != null) try prims.append(arena, .{ .marker = .{ .x = p[0], .y = p[1], .size = 12, .color = spring_color } });
    }
    if (springs.items.len > 0) try prims.append(arena, .{ .lines = .{ .segs = springs.items, .color = spring_color, .thickness = 1.5, .key = key_base + 22 } });
    for (m.m.members) |mb| {
        const rl = mb.release orelse continue;
        const ni = node_map.get(mb.i) orelse continue;
        const nj = node_map.get(mb.j) orelse continue;
        const a = scr[ni];
        const b = scr[nj];
        const dx = b[0] - a[0];
        const dy = b[1] - a[1];
        const len = @sqrt(dx * dx + dy * dy);
        if (len < 16 or !visible(m, a, b, 10)) continue;
        const off = @min(8, len / 4) / len;
        if (engine.model.hasMz(rl.i)) try prims.append(arena, .{ .marker = .{ .x = a[0] + dx * off, .y = a[1] + dy * off, .size = 6, .color = hinge_color } });
        if (engine.model.hasMz(rl.j)) try prims.append(arena, .{ .marker = .{ .x = b[0] - dx * off, .y = b[1] - dy * off, .size = 6, .color = hinge_color } });
    }

    const spacing_ok = m.zoom * 1.0 > 4; // ~1 m apart at >= 4 px
    if (spacing_ok and m.m.nodes.len <= 20000) {
        for (scr, 0..) |p, k| {
            if (p[0] < 0 or p[1] < 0 or p[0] > m.canvas_w or p[1] > m.canvas_h) continue;
            const sel = if (m.drag_node) |d| d == k else false;
            try prims.append(arena, .{ .marker = .{ .x = p[0], .y = p[1], .size = if (sel) 9 else 5, .color = if (sel) defl_color else node_color } });
        }
    }
    return prims.items;
}
