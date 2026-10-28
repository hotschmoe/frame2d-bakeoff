//! Frame2D model types (SPEC 5.1), JSON parsing, JSON writing and the `gen B S` generator (SPEC 4.8).
const std = @import("std");

pub const Material = struct { id: []const u8, E: f64 };
pub const Section = struct { id: []const u8, A: f64, I: f64 };

pub const Node = struct {
    id: i64,
    x: f64,
    y: f64,
    bench_pad: u32 = 0, // BENCH-EDIT:struct
};

pub const Support = struct { node: i64, ux: bool = false, uy: bool = false, rz: bool = false };

pub const Member = struct {
    id: i64,
    i: i64,
    j: i64,
    material: []const u8,
    section: []const u8,
    release: ?Release = null,
};

/// P2 (SPEC 4.7): end releases per member end; only "mz" is meaningful.
pub const Release = struct { i: []const []const u8 = &.{}, j: []const []const u8 = &.{} };

/// P2 (SPEC 4.7): spring support stiffnesses on free DOFs (null = absent).
pub const Spring = struct { node: i64, kx: ?f64 = null, ky: ?f64 = null, kr: ?f64 = null };

pub fn hasMz(names: []const []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, "mz")) return true;
    return false;
}

pub const NodalLoad = struct { node: i64, fx: f64 = 0, fy: f64 = 0, mz: f64 = 0 };
pub const Udl = struct { member: i64, w: f64 };

pub const LoadCase = struct {
    id: []const u8,
    nodal: []const NodalLoad = &.{},
    member_udl: []const Udl = &.{},
};

pub const Model = struct {
    materials: []const Material = &.{},
    sections: []const Section = &.{},
    nodes: []Node = &.{},
    supports: []const Support = &.{},
    springs: []const Spring = &.{},
    members: []const Member = &.{},
    load_cases: []const LoadCase = &.{},
};

pub const ParseError = error{InvalidModelJson} || std.mem.Allocator.Error;

/// Parse model JSON. All memory lives in `arena` (pass an arena allocator).
pub fn parse(arena: std.mem.Allocator, text: []const u8) ParseError!Model {
    return std.json.parseFromSliceLeaky(Model, arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidModelJson,
    };
}

/// Deep copy (strings are shared; arrays are copied) so a variant can be edited.
pub fn clone(arena: std.mem.Allocator, m: Model) !Model {
    var out = m;
    out.nodes = try arena.dupe(Node, m.nodes);
    out.sections = try arena.dupe(Section, m.sections);
    return out;
}

// ── generator (SPEC 4.8) ──────────────────────────────────────────────

pub const bay_width = 6.0;
pub const story_height = 3.5;

pub fn gen(arena: std.mem.Allocator, bays: u32, stories: u32) !Model {
    const nb = bays + 1;
    const n_nodes = nb * (stories + 1);
    const nodes = try arena.alloc(Node, n_nodes);
    for (0..stories + 1) |s| {
        for (0..nb) |b| {
            const id = s * nb + b + 1;
            nodes[id - 1] = .{
                .id = @intCast(id),
                .x = @as(f64, @floatFromInt(b)) * bay_width,
                .y = @as(f64, @floatFromInt(s)) * story_height,
            };
        }
    }
    const n_cols = nb * stories;
    const n_beams = bays * stories; // beams at levels 1..S (level 0 is the fixed base)
    const members = try arena.alloc(Member, n_cols + n_beams);
    var mid: usize = 0;
    for (0..nb) |b| {
        for (0..stories) |s| {
            members[mid] = .{ .id = @intCast(mid + 1), .i = @intCast(s * nb + b + 1), .j = @intCast((s + 1) * nb + b + 1), .material = "steel", .section = "COL" };
            mid += 1;
        }
    }
    for (1..stories + 1) |s| {
        for (0..bays) |b| {
            members[mid] = .{ .id = @intCast(mid + 1), .i = @intCast(s * nb + b + 1), .j = @intCast(s * nb + b + 2), .material = "steel", .section = "BM" };
            mid += 1;
        }
    }
    const supports = try arena.alloc(Support, nb);
    for (0..nb) |b| supports[b] = .{ .node = @intCast(b + 1), .ux = true, .uy = true, .rz = true };

    const d_udl = try arena.alloc(Udl, n_beams);
    const l_udl = try arena.alloc(Udl, n_beams);
    for (0..n_beams) |k| {
        d_udl[k] = .{ .member = @intCast(n_cols + k + 1), .w = -20000 };
        l_udl[k] = .{ .member = @intCast(n_cols + k + 1), .w = -10000 };
    }
    const w_nodal = try arena.alloc(NodalLoad, stories);
    for (1..stories + 1) |s| w_nodal[s - 1] = .{ .node = @intCast(s * nb + 1), .fx = 15000 };

    const cases = try arena.alloc(LoadCase, 3);
    cases[0] = .{ .id = "D", .member_udl = d_udl };
    cases[1] = .{ .id = "L", .member_udl = l_udl };
    cases[2] = .{ .id = "W", .nodal = w_nodal };

    const mats = try arena.alloc(Material, 1);
    mats[0] = .{ .id = "steel", .E = 200e9 };
    const secs = try arena.alloc(Section, 2);
    secs[0] = .{ .id = "COL", .A = 0.015, .I = 1.2e-4 };
    secs[1] = .{ .id = "BM", .A = 0.010, .I = 8.0e-5 };

    return .{ .materials = mats, .sections = secs, .nodes = nodes, .supports = supports, .members = members, .load_cases = cases };
}

// ── JSON writing ──────────────────────────────────────────────────────

/// Shortest round-trip representation of an f64 (SPEC 5.2).
pub fn writeNum(w: *std.Io.Writer, v: f64) !void {
    if (v == 0) return w.writeAll(if (std.math.signbit(v)) "-0.0" else "0.0");
    if (!std.math.isFinite(v)) return w.writeAll("null");
    const a = @abs(v);
    if (a >= 1e-5 and a < 1e16) try w.print("{d}", .{v}) else try w.print("{e}", .{v});
}

pub fn writeStr(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        0...9, 11...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

pub fn write(w: *std.Io.Writer, m: Model) !void {
    try w.writeAll("{\"materials\":[");
    for (m.materials, 0..) |x, k| {
        if (k > 0) try w.writeByte(',');
        try w.writeAll("{\"id\":");
        try writeStr(w, x.id);
        try w.writeAll(",\"E\":");
        try writeNum(w, x.E);
        try w.writeByte('}');
    }
    try w.writeAll("],\"sections\":[");
    for (m.sections, 0..) |x, k| {
        if (k > 0) try w.writeByte(',');
        try w.writeAll("{\"id\":");
        try writeStr(w, x.id);
        try w.writeAll(",\"A\":");
        try writeNum(w, x.A);
        try w.writeAll(",\"I\":");
        try writeNum(w, x.I);
        try w.writeByte('}');
    }
    try w.writeAll("],\n\"nodes\":[");
    for (m.nodes, 0..) |x, k| {
        if (k > 0) try w.writeByte(',');
        try w.print("{{\"id\":{d},\"x\":", .{x.id});
        try writeNum(w, x.x);
        try w.writeAll(",\"y\":");
        try writeNum(w, x.y);
        try w.writeByte('}');
    }
    try w.writeAll("],\n\"supports\":[");
    for (m.supports, 0..) |x, k| {
        if (k > 0) try w.writeByte(',');
        try w.print("{{\"node\":{d},\"ux\":{},\"uy\":{},\"rz\":{}}}", .{ x.node, x.ux, x.uy, x.rz });
    }
    try w.writeAll("],\n\"members\":[");
    for (m.members, 0..) |x, k| {
        if (k > 0) try w.writeByte(',');
        try w.print("{{\"id\":{d},\"i\":{d},\"j\":{d},\"material\":", .{ x.id, x.i, x.j });
        try writeStr(w, x.material);
        try w.writeAll(",\"section\":");
        try writeStr(w, x.section);
        if (x.release) |r| {
            try w.print(",\"release\":{{\"i\":[{s}],\"j\":[{s}]}}", .{
                if (hasMz(r.i)) "\"mz\"" else "", if (hasMz(r.j)) "\"mz\"" else "",
            });
        }
        try w.writeByte('}');
    }
    try w.writeAll("],\n\"springs\":[");
    for (m.springs, 0..) |x, k| {
        if (k > 0) try w.writeByte(',');
        try w.print("{{\"node\":{d}", .{x.node});
        inline for (.{ "kx", "ky", "kr" }) |f| if (@field(x, f)) |v| {
            try w.writeAll(",\"" ++ f ++ "\":");
            try writeNum(w, v);
        };
        try w.writeByte('}');
    }
    try w.writeAll("],\n\"load_cases\":[");
    for (m.load_cases, 0..) |lc, k| {
        if (k > 0) try w.writeByte(',');
        try w.writeAll("{\"id\":");
        try writeStr(w, lc.id);
        try w.writeAll(",\"nodal\":[");
        for (lc.nodal, 0..) |x, q| {
            if (q > 0) try w.writeByte(',');
            try w.print("{{\"node\":{d},\"fx\":", .{x.node});
            try writeNum(w, x.fx);
            try w.writeAll(",\"fy\":");
            try writeNum(w, x.fy);
            try w.writeAll(",\"mz\":");
            try writeNum(w, x.mz);
            try w.writeByte('}');
        }
        try w.writeAll("],\"member_udl\":[");
        for (lc.member_udl, 0..) |x, q| {
            if (q > 0) try w.writeByte(',');
            try w.print("{{\"member\":{d},\"w\":", .{x.member});
            try writeNum(w, x.w);
            try w.writeByte('}');
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]}\n");
}

test "gen sizes match SPEC 4.8" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = try gen(arena.allocator(), 10, 10);
    try std.testing.expectEqual(@as(usize, 121), m.nodes.len);
    try std.testing.expectEqual(@as(usize, 210), m.members.len);
    try std.testing.expectEqual(@as(i64, 111), m.load_cases[2].nodal[9].node);
}
