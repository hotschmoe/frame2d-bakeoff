//! Frame2D model types (SPEC 5.1), JSON in/out and the 5.x generator (SPEC 4.8).
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Material = struct { id: []const u8, E: f64 };
pub const Section = struct { id: []const u8, A: f64, I: f64 };
pub const Node = struct {
    id: i64,
    x: f64,
    y: f64,
    bench_pad: u32 = 0, // BENCH-EDIT:struct
};
pub const Support = struct { node: i64, ux: bool = false, uy: bool = false, rz: bool = false };
pub const Member = struct { id: i64, i: i64, j: i64, material: []const u8, section: []const u8 };
pub const NodalLoad = struct { node: i64, fx: f64 = 0, fy: f64 = 0, mz: f64 = 0 };
pub const MemberUdl = struct { member: i64, w: f64 };
pub const LoadCase = struct {
    id: []const u8,
    nodal: []const NodalLoad = &.{},
    member_udl: []const MemberUdl = &.{},
};

pub const Model = struct {
    materials: []const Material = &.{},
    sections: []const Section = &.{},
    nodes: []Node = &.{},
    supports: []const Support = &.{},
    members: []Member = &.{},
    load_cases: []const LoadCase = &.{},
};

/// Parses model JSON into `arena` (strings are copied, so `text` may be freed afterwards).
/// The arena must outlive the returned model.
pub fn parse(arena: Allocator, text: []const u8) !Model {
    return std.json.parseFromSliceLeaky(Model, arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

/// Writes the model as compact JSON.
pub fn write(w: *std.Io.Writer, m: *const Model) std.Io.Writer.Error!void {
    try w.writeAll("{\"materials\":[");
    for (m.materials, 0..) |x, k| {
        if (k > 0) try w.writeByte(',');
        try w.print("{{\"id\":\"{s}\",\"E\":{}}}", .{ x.id, x.E });
    }
    try w.writeAll("],\"sections\":[");
    for (m.sections, 0..) |x, k| {
        if (k > 0) try w.writeByte(',');
        try w.print("{{\"id\":\"{s}\",\"A\":{},\"I\":{}}}", .{ x.id, x.A, x.I });
    }
    try w.writeAll("],\"nodes\":[");
    for (m.nodes, 0..) |x, k| {
        if (k > 0) try w.writeByte(',');
        try w.print("{{\"id\":{},\"x\":{},\"y\":{}}}", .{ x.id, x.x, x.y });
    }
    try w.writeAll("],\"supports\":[");
    for (m.supports, 0..) |x, k| {
        if (k > 0) try w.writeByte(',');
        try w.print("{{\"node\":{},\"ux\":{},\"uy\":{},\"rz\":{}}}", .{ x.node, x.ux, x.uy, x.rz });
    }
    try w.writeAll("],\"members\":[");
    for (m.members, 0..) |x, k| {
        if (k > 0) try w.writeByte(',');
        try w.print("{{\"id\":{},\"i\":{},\"j\":{},\"material\":\"{s}\",\"section\":\"{s}\"}}", .{ x.id, x.i, x.j, x.material, x.section });
    }
    try w.writeAll("],\"load_cases\":[");
    for (m.load_cases, 0..) |lc, k| {
        if (k > 0) try w.writeByte(',');
        try w.print("{{\"id\":\"{s}\",\"nodal\":[", .{lc.id});
        for (lc.nodal, 0..) |x, q| {
            if (q > 0) try w.writeByte(',');
            try w.print("{{\"node\":{},\"fx\":{},\"fy\":{},\"mz\":{}}}", .{ x.node, x.fx, x.fy, x.mz });
        }
        try w.writeAll("],\"member_udl\":[");
        for (lc.member_udl, 0..) |x, q| {
            if (q > 0) try w.writeByte(',');
            try w.print("{{\"member\":{},\"w\":{}}}", .{ x.member, x.w });
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]}\n");
}

/// Deterministic B-bay by S-story moment frame (SPEC 4.8). Everything is allocated from `arena`.
pub fn generate(arena: Allocator, bays: usize, stories: usize) Allocator.Error!Model {
    const cols = bays + 1;
    const n_nodes = cols * (stories + 1);
    const n_cols = cols * stories;
    const n_beams = bays * stories;

    const materials = try arena.dupe(Material, &.{.{ .id = "steel", .E = 200e9 }});
    const sections = try arena.dupe(Section, &.{
        .{ .id = "COL", .A = 0.015, .I = 1.2e-4 },
        .{ .id = "BM", .A = 0.010, .I = 8.0e-5 },
    });

    const nodes = try arena.alloc(Node, n_nodes);
    for (0..stories + 1) |s| {
        for (0..cols) |b| {
            const id = s * cols + b + 1;
            nodes[id - 1] = .{ .id = @intCast(id), .x = 6.0 * @as(f64, @floatFromInt(b)), .y = 3.5 * @as(f64, @floatFromInt(s)) };
        }
    }

    const supports = try arena.alloc(Support, cols);
    for (supports, 0..) |*sp, b| sp.* = .{ .node = @intCast(b + 1), .ux = true, .uy = true, .rz = true };

    const members = try arena.alloc(Member, n_cols + n_beams);
    var mid: usize = 0;
    for (0..cols) |b| {
        for (0..stories) |s| {
            members[mid] = .{ .id = @intCast(mid + 1), .i = @intCast(s * cols + b + 1), .j = @intCast((s + 1) * cols + b + 1), .material = "steel", .section = "COL" };
            mid += 1;
        }
    }
    const beam_first = mid;
    for (1..stories + 1) |s| {
        for (0..bays) |b| {
            members[mid] = .{ .id = @intCast(mid + 1), .i = @intCast(s * cols + b + 1), .j = @intCast(s * cols + b + 2), .material = "steel", .section = "BM" };
            mid += 1;
        }
    }

    const udl_d = try arena.alloc(MemberUdl, n_beams);
    const udl_l = try arena.alloc(MemberUdl, n_beams);
    for (0..n_beams) |k| {
        const id: i64 = @intCast(beam_first + k + 1);
        udl_d[k] = .{ .member = id, .w = -20000.0 };
        udl_l[k] = .{ .member = id, .w = -10000.0 };
    }
    const wind = try arena.alloc(NodalLoad, stories);
    for (wind, 0..) |*ld, k| ld.* = .{ .node = @intCast((k + 1) * cols + 1), .fx = 15000.0 };

    const cases = try arena.dupe(LoadCase, &.{
        .{ .id = "D", .member_udl = udl_d },
        .{ .id = "L", .member_udl = udl_l },
        .{ .id = "W", .nodal = wind },
    });
    return .{ .materials = materials, .sections = sections, .nodes = nodes, .supports = supports, .members = members, .load_cases = cases };
}

test "generator sizes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = try generate(arena.allocator(), 10, 10);
    try std.testing.expectEqual(@as(usize, 121), m.nodes.len);
    try std.testing.expectEqual(@as(usize, 210), m.members.len);
    try std.testing.expectEqual(@as(i64, 111), m.load_cases[2].nodal[9].node);
}
